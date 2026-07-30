#!/bin/sh
# fail2ban.sh — fail2ban 封鎖管理（手動封鎖 / 解封 / 白名單 / 稽核）
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 用法：
#   ./fail2ban.sh status              服務與各 jail 的封鎖概況
#   ./fail2ban.sh list [jail]         列出已封鎖的 IP
#   ./fail2ban.sh ban <IP…>           手動封鎖（預設所有 jail 都封）
#   ./fail2ban.sh unban <IP…>         解除封鎖（自動找出哪些 jail 封了它）
#   ./fail2ban.sh unban-all           清空封鎖清單
#   ./fail2ban.sh check <IP>          查這個 IP 現在的狀態
#   ./fail2ban.sh allow <IP…>         加白名單（ignoreip）
#   ./fail2ban.sh disallow <IP…>      移除白名單
#   ./fail2ban.sh top [n]             封鎖次數最多的來源（讀 fail2ban 日誌）
#   ./fail2ban.sh log [n]             最近的封鎖 / 解封事件
#   ./fail2ban.sh tail                即時追蹤 fail2ban 日誌
#   ./fail2ban.sh bantime [jail] [秒] 查看 / 設定封鎖時長
#   ./fail2ban.sh enable-sshd         建立 sshd jail（埠號取實際生效值）
#   ./fail2ban.sh reload              重載設定
#   ./fail2ban.sh install             安裝並啟用 fail2ban
#   ./fail2ban.sh doctor              環境檢查（含「設了但不會生效」的常見情況）
#
#   共用選項：-j <jail> 指定 jail、-t <秒|perm> 封鎖時長、-y 免確認、-n 乾跑
#
# 設計原則：
#   1. 封鎖一律透過 fail2ban-client，不自己寫 iptables / nftables 規則。手寫規則
#      與 fail2ban 的狀態不一致，是這類工具最難查的問題。
#   2. 封鎖前先算「這條會不會把你自己關在外面」，含 CIDR 涵蓋判斷。會命中就擋下來。
#   3. 只寫自己管理的設定檔（jail.d/zz-ops-*.local），不碰發行版的 jail.conf。
#   4. fail2ban 各版本能力差很多，一律先探測再用，不支援就講明白並降級，不靜默失效。
#
# 以 POSIX sh 撰寫，Alpine 不需額外安裝 bash。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# os-release 會設 VERSION，所以本腳本自己的版本號不能叫 VERSION（會被 detect_env 蓋掉）
F2B_SH_VER=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# FAIL2BAN_TEST_ROOT 僅供測試用，會把所有設定檔路徑加上前綴
PREFIX="${FAIL2BAN_TEST_ROOT:-}"

F2B_ETC="${PREFIX}/etc/fail2ban"
F2B_JAILD="${F2B_ETC}/jail.d"
IGNORE_FILE="${F2B_JAILD}/zz-ops-ignoreip.local"
SSHD_JAIL_FILE="${F2B_JAILD}/zz-ops-sshd.local"

# 產出檔案跟其他工具收在一起（見 ../SSH/README.md 的「檔案位置」）
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
LOGFILE="${PREFIX}${OPS_SSH_DIR}/fail2ban-ops.log"

DEFAULT_JAIL=''        # 空 = 所有 jail
DRY=0
YES=0
BANTIME=''

# ---------- 輸出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
    CB=$(printf '\033[1m');  CD=$(printf '\033[2m');  C0=$(printf '\033[0m')
else
    CR=''; CG=''; CY=''; CB=''; CD=''; C0=''
fi

# 手動封鎖 / 解封是會被追究的動作，留下稽核記錄（寫不進去就只印畫面）
_log()  { printf '%s\n' "$*" ; [ -w "$(dirname "$LOGFILE")" ] 2>/dev/null && \
          printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$LOGFILE" 2>/dev/null; return 0; }
info()  { _log "  $*"; }
step()  { _log "${CB}==>${C0} $*"; }
ok()    { _log "${CG}  +${C0} $*"; }
warn()  { _log "${CY}  !${C0} $*"; }
err()   { _log "${CR}  x${C0} $*"; }
die()   { err "$*"; exit 1; }
plain() { printf '%s\n' "$*"; }

has() { command -v "$1" >/dev/null 2>&1; }

# grep -c 在「沒有任何匹配」時會印出 0 但回傳 1，接 `|| echo 0` 會變成兩行 0，
# 之後拿去做算術就會炸掉。統一走這個 helper。
cnt()  { _c=$(grep -c "$@" 2>/dev/null); printf '%s\n' "${_c:-0}"; }

need_root() {
    [ "$(id -u)" = 0 ] && return 0
    err "這個動作需要 root 權限（fail2ban 的控制 socket 只有 root 能用），目前是 $(id -un)"
    info "請用 sudo -i 或 su - 切換後重跑：$SELF"
    exit 1
}

# =========================================================
# 環境偵測
# =========================================================
detect_env() {
    if [ -r "${PREFIX}/etc/os-release" ]; then
        . "${PREFIX}/etc/os-release"
    else
        ID=unknown; ID_LIKE=''; PRETTY_NAME=unknown; VERSION_ID=''
    fi
    OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
    OS_VER="${VERSION_ID:-}"
    case " ${ID_LIKE:-} ${ID:-} " in
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) OS_FAMILY=rhel ;;
        *debian*|*ubuntu*)                            OS_FAMILY=debian ;;
        *alpine*)                                     OS_FAMILY=alpine ;;
        *)                                            OS_FAMILY=unknown ;;
    esac

    if   has apk;     then PKG=apk;  PKG_INSTALL='apk add --no-cache'
    elif has dnf;     then PKG=dnf;  PKG_INSTALL='dnf install -y'
    elif has yum;     then PKG=yum;  PKG_INSTALL='yum install -y'
    elif has apt-get; then PKG=apt;  PKG_INSTALL='apt-get install -y'
    else                   PKG=none; PKG_INSTALL='(找不到套件管理器)'
    fi

    if   [ -d /run/systemd/system ]; then INIT=systemd
    elif has rc-service;             then INIT=openrc
    else                                  INIT=sysv
    fi

    F2B_SVC=fail2ban
    # 版本字串各版不同（"fail2ban-client v0.11.2" / "Fail2Ban v1.0.2"），只挑數字段
    F2B_VER=''
    if has fail2ban-client; then
        F2B_VER=$(fail2ban-client --version 2>/dev/null | tr ' ' '\n' |
                  sed -n 's/^[vV]\{0,1\}\([0-9][0-9.]*\)$/\1/p' | head -1)
    fi
    if [ -z "$F2B_VER" ] && has fail2ban-server; then
        F2B_VER=$(fail2ban-server --version 2>/dev/null | tr ' ' '\n' |
                  sed -n 's/^[vV]\{0,1\}\([0-9][0-9.]*\)$/\1/p' | head -1)
    fi
}

svc_state() {
    case "$INIT" in
        systemd) # is-active 會「印出 unknown 且回傳非 0」，不能用 || echo，否則印兩行
                 _s=$(systemctl is-active "$F2B_SVC" 2>/dev/null)
                 printf '%s\n' "${_s:-inactive}" ;;
        openrc)  rc-service "$F2B_SVC" status >/dev/null 2>&1 && echo active || echo inactive ;;
        *)       service "$F2B_SVC" status >/dev/null 2>&1 && echo active || echo unknown ;;
    esac
}

svc_start() {
    case "$INIT" in
        systemd) systemctl enable --now "$F2B_SVC" ;;
        openrc)  rc-update add "$F2B_SVC" default >/dev/null 2>&1; rc-service "$F2B_SVC" start ;;
        *)       service "$F2B_SVC" start ;;
    esac
}

# 伺服器有沒有在跑：ping 是唯一可靠的判斷（服務 active 但 socket 還沒起來的空窗期存在）
f2b_ping() {
    has fail2ban-client || return 1
    fail2ban-client ping 2>/dev/null | grep -qi 'pong'
}

require_f2b() {
    if ! has fail2ban-client; then
        err "找不到 fail2ban-client"
        info "安裝：$SELF install   （或手動 $PKG_INSTALL fail2ban）"
        [ "$OS_FAMILY" = rhel ] && info "RHEL 系的 fail2ban 在 EPEL，install 會一併處理"
        exit 1
    fi
    need_root
    if ! f2b_ping; then
        err "fail2ban 伺服器沒有回應（服務狀態：$(svc_state)）"
        info "啟動：$SELF install   或  $([ "$INIT" = openrc ] && echo "rc-service $F2B_SVC start" || echo "systemctl start $F2B_SVC")"
        info "起不來時先看：$SELF doctor"
        exit 1
    fi
}

# =========================================================
# jail 與封鎖狀態
#   一律解析 `fail2ban-client status` 的輸出，不用 0.10+ 才有的 get 子命令，
#   這樣 0.9（Debian 9）到 1.x 都能跑。
# =========================================================
jails() {
    # 注意：awk 的 [[:space:]] 也含 \n，所以要先去空白、再把逗號換成換行
    fail2ban-client status 2>/dev/null | awk '
        /[Jj]ail list/ { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[ \t]/, ""); gsub(/,/, "\n"); print }' |
        grep -v '^$'
}

# $1=jail → 每行一個已封鎖 IP
jail_banned() {
    fail2ban-client status "$1" 2>/dev/null | awk '
        /Banned IP list/ { sub(/^.*Banned IP list:[[:space:]]*/, ""); print }' |
        tr ' \t' '\n\n' | grep -v '^$'
}

# $1=jail $2=欄位關鍵字（Currently banned / Total banned / Currently failed …）
jail_num() {
    fail2ban-client status "$1" 2>/dev/null | awk -v k="$2" '
        index($0, k) { n=$0; sub(/^.*:[[:space:]]*/, "", n); print n; exit }'
}

jail_exists() {
    jails | grep -qx "$1"
}

# 要操作哪些 jail：-j 指定就只有它，否則全部
target_jails() {
    if [ -n "$DEFAULT_JAIL" ]; then
        jail_exists "$DEFAULT_JAIL" || die "找不到 jail：$DEFAULT_JAIL（現有：$(jails | tr '\n' ' ')）"
        printf '%s\n' "$DEFAULT_JAIL"
    else
        jails
    fi
}

# =========================================================
# 目標檢查
# =========================================================
valid_target() {
    case "$1" in
        *:*)  # IPv6（含可選前綴長度）：只做字元與結構的粗略檢查
            printf '%s' "$1" | grep -qE '^[0-9a-fA-F:]+(/[0-9]{1,3})?$' ;;
        *)
            printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' || return 1
            # 每段 0-255、前綴 0-32
            printf '%s' "$1" | awk -F'[./]' '{
                for (i=1;i<=4;i++) if ($i+0>255) exit 1
                if (NF==5 && $5+0>32) exit 1
                exit 0 }' ;;
    esac
}

# 本機自己的 IP（封鎖到自己等於自斷網路服務）
my_ips() {
    if has ip; then
        ip -o addr show 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet"||$i=="inet6"){split($(i+1),a,"/"); print a[1]}}'
    elif has ifconfig; then
        ifconfig 2>/dev/null | awk '/inet /{gsub(/addr:/,"");print $2} /inet6 /{print $2}'
    fi
}

# 本行程的祖先 pid 鏈（含自己）。用來判斷哪條 TCP 連線「確定是自己這條 session」。
ancestors() {
    _p=$$; _n=0
    while [ -n "$_p" ] && [ "$_p" != 0 ] && [ "$_n" -lt 16 ]; do
        printf '%s ' "$_p"
        _p=$(awk '/^PPid:/{print $2}' "/proc/$_p/status" 2>/dev/null)
        _n=$((_n + 1))
    done
}

# 目前這條 SSH 連線的來源 IP（可能有多條，全部列出）
#
# 只認「確定是自己」的來源。絕對不能拿「連到 SSH 埠的所有連線」充數：爆破攻擊的
# 連線也在同一個埠上，把它們當成自己的來源會造成兩件很糟的事——不准你封鎖正在
# 攻擊你的 IP，以及 doctor 反過來建議你把攻擊者加進白名單。
ssh_peers() {
    [ -n "${SSH_CONNECTION:-}" ] && printf '%s\n' "$SSH_CONNECTION" | awk '{print $1}'
    [ -n "${SSH_CLIENT:-}" ]     && printf '%s\n' "$SSH_CLIENT" | awk '{print $1}'

    # sudo / su 會把環境變數清掉。改用「兩個條件同時成立」反查，缺一不可：
    #
    #   1. 連線的持有行程在自己的祖先鏈上 —— 排除攻擊者：他們的爆破連線也在
    #      SSH 埠上，但不屬於自己這條 session。只比對埠號會把攻擊者當成自己，
    #      結果是「不准封鎖正在攻擊你的 IP」。
    #   2. 本地埠是實際的 SSH 埠 —— 排除自己祖先行程持有的對外連線（登入後在這
    #      條 session 裡跑的任何東西：yum、curl、agent…）。只比對祖先鏈會把那些
    #      對端也當成自己的來源。
    if has ss && [ -r /proc/self/status ]; then
        _anc=$(ancestors)
        _sp=$(live_ssh_ports | tr '\n' '|' | sed 's/|$//')
        [ -n "$_anc" ] && [ -n "$_sp" ] &&
        ss -tnp state established 2>/dev/null | awk -v anc=" $_anc " -v pat="^($_sp)$" '
            { pid = ""
              if (match($0, /pid=[0-9]+/))                       # iproute2 4.x
                  pid = substr($0, RSTART+4, RLENGTH-4)
              else if (match($0, /"[^"]*",[0-9]+,[0-9]+\)/)) {   # iproute2 3.x（CentOS 7）
                  t = substr($0, RSTART, RLENGTH)
                  sub(/^"[^"]*",/, "", t); sub(/,[0-9]+\)$/, "", t); pid = t
              }
              if (pid == "" || !index(anc, " " pid " ")) next
              lp = $3; sub(/.*:/, "", lp)                        # 本地埠
              if (lp !~ pat) next
              pa = $4                                            # 對端 位址:埠
              sub(/:[0-9]+$/, "", pa); gsub(/[][]/, "", pa)
              print pa }'
    fi

    # 其他已登入的 session。who 只列通過認證的使用者，爆破連線不會出現在這裡。
    who 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F:.]\{3,\}\)).*/\1/p'
}

# $1=CIDR 或 IP，$2=IP → 0 表示 $1 涵蓋 $2
covers() {
    case "$1" in
        *:*) # IPv6：只比完全相同或前綴字串，不做完整位元運算
            [ "$1" = "$2" ] && return 0
            case "$1" in
                */*) _b=$(printf '%s' "$1" | cut -d/ -f1)
                     case "$2" in "$_b"*) return 0 ;; esac ;;
            esac
            return 1 ;;
    esac
    case "$2" in *:*) return 1 ;; esac
    awk -v net="$1" -v ip="$2" 'BEGIN{
        n = split(net, N, "/")
        prefix = (n > 1) ? N[2] : 32
        if (prefix < 0 || prefix > 32) exit 1
        split(N[1], B, "."); split(ip, I, ".")
        b = B[1]*16777216 + B[2]*65536 + B[3]*256 + B[4]
        i = I[1]*16777216 + I[2]*65536 + I[3]*256 + I[4]
        d = 2 ^ (32 - prefix)                 # POSIX awk 沒有位元運算，用整除比較網段
        exit (int(b/d) == int(i/d)) ? 0 : 1
    }'
}

# 封鎖前的自鎖檢查。回傳 1 代表「會鎖到自己」
lockout_check() {
    _t="$1"; _hit=''
    case "$_t" in
        127.*|::1|localhost) _hit="loopback" ;;
    esac
    if [ -z "$_hit" ]; then
        for _p in $(ssh_peers | sort -u); do
            [ -n "$_p" ] || continue
            if covers "$_t" "$_p"; then _hit="你目前的 SSH 來源 $_p"; break; fi
        done
    fi
    if [ -z "$_hit" ]; then
        for _m in $(my_ips | sort -u); do
            [ -n "$_m" ] || continue
            if covers "$_t" "$_m"; then _hit="本機自己的位址 $_m"; break; fi
        done
    fi
    [ -z "$_hit" ] && return 0
    err "$_t 涵蓋 $_hit"
    info "封下去就是把自己關在外面。要真的執行請加 --force（風險自負）"
    return 1
}

confirm() {
    [ "$YES" = 1 ] && return 0
    printf '%s%s%s [y/N] ' "$CY" "$1" "$C0"
    read -r _a 2>/dev/null || _a=''
    case "$_a" in y|Y|yes|YES) return 0 ;; *) plain " 已取消"; return 1 ;; esac
}

# =========================================================
# 能力探測
#   fail2ban 各版本的子命令差很多，用「試一次」判斷，不用版本號比大小
#   （發行版常有 backport，版本號不可靠）。
# =========================================================
# 各版本的子命令差異不用「比版本號」判斷（發行版常有 backport，版本號不可靠），
# 也不解析 help 文字（各版用詞不同）。帶時長的封鎖是「試一次、看結果」，
# 而且判斷與提示都必須在主 shell 做：放進函式再用 $( ) 取輸出的話，
# 提示會被吃進變數裡、旗標也困在子 shell，等於靜默失效。
BANTIME_OK=''          # 空=還沒試過，yes=可用，no=這個版本不吃

# =========================================================
# 日誌來源
#   優先序：fail2ban 自己的 log 檔 -> journal -> busybox logread
# =========================================================
F2B_LOGSRC=''
log_src() {
    [ -n "$F2B_LOGSRC" ] && { printf '%s\n' "$F2B_LOGSRC"; return 0; }
    for _f in "${PREFIX}/var/log/fail2ban.log" "${PREFIX}/var/log/fail2ban.log.1"; do
        [ -r "$_f" ] && { F2B_LOGSRC="$_f"; break; }
    done
    if [ -z "$F2B_LOGSRC" ] && has journalctl && \
       [ -n "$(journalctl -u "$F2B_SVC" -n 1 --no-pager -q 2>/dev/null)" ]; then
        F2B_LOGSRC=journal
    fi
    [ -z "$F2B_LOGSRC" ] && has logread && F2B_LOGSRC=logread
    [ -z "$F2B_LOGSRC" ] && F2B_LOGSRC=none
    printf '%s\n' "$F2B_LOGSRC"
}

log_cat() {
    case "$(log_src)" in
        none)    return 1 ;;
        journal) journalctl -u "$F2B_SVC" --no-pager -q 2>/dev/null ;;
        logread) logread 2>/dev/null | grep -i fail2ban ;;
        *)       cat "${PREFIX}/var/log/fail2ban.log."[0-9] "${PREFIX}/var/log/fail2ban.log" 2>/dev/null ;;
    esac
}

log_follow() {
    case "$(log_src)" in
        none)    return 1 ;;
        journal) journalctl -u "$F2B_SVC" -f --no-pager -q 2>/dev/null ;;
        logread) logread -f 2>/dev/null | grep -i --line-buffered fail2ban ;;
        *)       tail -f "${PREFIX}/var/log/fail2ban.log" 2>/dev/null ;;
    esac
}

# =========================================================
# 白名單（ignoreip）
#   只寫 jail.d/zz-ops-ignoreip.local。jail.d/*.local 的載入順序在最後，
#   會覆蓋 jail.conf / jail.local 的 [DEFAULT] ignoreip，所以檔案裡必須
#   把「原本生效的值」一起帶上，否則會把管理員原有的白名單吃掉。
# =========================================================
ignore_effective() {
    _j=$(jails | head -1)
    if [ -n "$_j" ] && f2b_ping; then
        fail2ban-client get "$_j" ignoreip 2>/dev/null |
            tr ' \t|,`' '\n\n\n\n\n' | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$' | grep -E '[.:]'
    fi
    # 伺服器沒跑時退回讀設定檔
    grep -hE '^[[:space:]]*ignoreip[[:space:]]*=' \
        "${F2B_ETC}/jail.conf" "${F2B_ETC}/jail.local" \
        "${F2B_JAILD}"/*.conf "${F2B_JAILD}"/*.local 2>/dev/null |
        sed 's/^[^=]*=//' | tr ' \t,' '\n\n\n' | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$' | grep -E '[.:]'
}

ignore_write() {
    # $* = 完整清單（已含 loopback）
    _tmp="${IGNORE_FILE}.tmp.$$"
    mkdir -p "$F2B_JAILD" 2>/dev/null || die "無法建立 $F2B_JAILD"
    {
        printf '%s\n' "# 由 fail2ban.sh 管理（$SELF allow / disallow），手動編輯會被覆寫。"
        printf '%s\n' "# jail.d/*.local 的載入順序在最後，這裡的值會蓋掉 jail.conf 與 jail.local"
        printf '%s\n' "# 的 [DEFAULT] ignoreip，所以清單裡一定要含原本就生效的項目。"
        printf '%s\n' "[DEFAULT]"
        printf 'ignoreip = %s\n' "$*"
    } > "$_tmp" || { rm -f "$_tmp"; die "寫入暫存檔失敗"; }
    cat "$_tmp" > "$IGNORE_FILE" && rm -f "$_tmp" || { rm -f "$_tmp"; die "寫入 $IGNORE_FILE 失敗"; }
    chmod 644 "$IGNORE_FILE" 2>/dev/null
}

# =========================================================
# sshd jail 的埠號
#   換過 SSH 埠之後 jail 的 port 沒跟著改，是「設了但完全不會生效」的典型：
#   fail2ban 照樣記錄失敗、照樣封，但封的是舊埠，攻擊者從新埠進來完全沒事。
# =========================================================
live_ssh_ports() {
    _p=''
    [ "$(id -u)" = 0 ] && has sshd && _p=$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}')
    if [ -z "$_p" ]; then
        _p=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
             "${PREFIX}/etc/ssh/sshd_config" "${PREFIX}/etc/ssh/sshd_config.d"/*.conf 2>/dev/null |
             awk '{print $2}')
    fi
    [ -z "$_p" ] && _p=22
    printf '%s\n' $_p | sort -un
}

# 從設定檔裡挖出 [sshd] 區塊的 port（區塊感知，不會抓到別的 jail 的值）
#
# 檔案清單要先濾掉不存在的：awk 開不了檔是 fatal，會整個中止，後面的檔案
# 一個都不會讀——那會變成「明明寫了 port 卻說沒寫」，比報錯還難查。
jail_conf_port() {
    _want="$1"; _files=''
    for _f in "${F2B_ETC}/jail.conf" "${F2B_ETC}/jail.local" \
              "${F2B_JAILD}"/*.conf "${F2B_JAILD}"/*.local; do
        [ -f "$_f" ] && _files="$_files $_f"
    done
    [ -n "$_files" ] || return 0
    # shellcheck disable=SC2086
    awk -v want="$_want" '
        /^[[:space:]]*\[/ { sec=$0; gsub(/[][[:space:]]/, "", sec) }
        sec == want && /^[[:space:]]*port[[:space:]]*=/ {
            v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); print v
        }' $_files 2>/dev/null | tail -1
}

# =========================================================
# 動作
# =========================================================
cmd_status() {
    require_f2b
    step "fail2ban 狀態"
    info "版本      : ${F2B_VER:-未知}"
    info "服務      : $F2B_SVC ($(svc_state))"
    info "白名單    : $(ignore_effective | sort -u | tr '\n' ' ')"
    _js=$(jails)
    if [ -z "$_js" ]; then
        warn "沒有啟用中的 jail — fail2ban 在跑但不會封任何東西"
        info "建立 sshd jail：$SELF enable-sshd"
        return 0
    fi
    plain ""
    _total=0
    for _j in $_js; do
        _cb=$(jail_num "$_j" 'Currently banned'); _tb=$(jail_num "$_j" 'Total banned')
        _cf=$(jail_num "$_j" 'Currently failed')
        printf '  %-24s 封鎖中 %-6s 累計 %-6s 目前失敗 %s\n' \
            "$_j" "${_cb:-?}" "${_tb:-?}" "${_cf:-?}"
        case "${_cb:-0}" in ''|*[!0-9]*) : ;; *) _total=$((_total + _cb)) ;; esac
    done
    plain ""
    info "合計封鎖中：${_total}  （明細：$SELF list）"
}

cmd_list() {
    require_f2b
    [ -n "${1:-}" ] && DEFAULT_JAIL="$1"
    for _j in $(target_jails); do
        _ips=$(jail_banned "$_j")
        _n=$(printf '%s\n' "$_ips" | cnt .)
        step "$_j（$_n 筆）"
        [ -n "$_ips" ] && printf '%s\n' "$_ips" | sed 's/^/    /'
    done
}

cmd_ban() {
    [ $# -ge 1 ] || die "請給要封鎖的 IP，例如：$SELF ban 1.2.3.4"
    require_f2b
    _js=$(target_jails)
    [ -n "$_js" ] || die "沒有可用的 jail（$SELF enable-sshd 可建立 sshd jail）"

    # 先全部檢查完再動手，避免封了一半才發現有問題
    for _ip in "$@"; do
        valid_target "$_ip" || die "不是合法的 IP / CIDR：$_ip"
        if [ "${FORCE:-0}" != 1 ]; then
            lockout_check "$_ip" || exit 1
        else
            lockout_check "$_ip" >/dev/null 2>&1 || warn "--force：$_ip 會鎖到自己，仍照你要求執行"
        fi
    done

    _bt_note=''
    if [ -n "$BANTIME" ]; then
        if [ "$BANTIME" = -1 ]; then _bt_note=" 時長 永久"; else _bt_note=" 時長 ${BANTIME}s"; fi
        _bt_note="$_bt_note（版本不支援時會退回 jail 預設值並提示）"
    fi

    step "將封鎖：$*${_bt_note}"
    info "jail：$(printf '%s' "$_js" | tr '\n' ' ')"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "確定要封鎖嗎？" || return 0

    for _ip in "$@"; do
        for _j in $_js; do
            if [ -n "$BANTIME" ] && [ "$BANTIME_OK" != no ]; then
                _out=$(fail2ban-client set "$_j" banip --time "$BANTIME" "$_ip" 2>&1)
                if jail_banned "$_j" | grep -qx "$_ip"; then
                    BANTIME_OK=yes
                else
                    BANTIME_OK=no
                    warn "這個 fail2ban 版本的 banip 不接受指定時長，改用 jail 本身的 bantime"
                    info "要改 jail 的預設時長：$SELF bantime <jail> <秒>"
                    _out=$(fail2ban-client set "$_j" banip "$_ip" 2>&1)
                fi
            else
                _out=$(fail2ban-client set "$_j" banip "$_ip" 2>&1)
            fi
            case "$_out" in
                *[Ee]rror*|*Invalid*|*NOK*)
                    err "[$_j] $_ip 失敗：$(printf '%s' "$_out" | head -1)" ;;
                0) # 0 = 本來就在封鎖清單裡
                    warn "[$_j] $_ip 已經在封鎖清單中" ;;
                *)  ok "[$_j] 已封鎖 $_ip" ;;
            esac
        done
    done
}

cmd_unban() {
    [ $# -ge 1 ] || die "請給要解除封鎖的 IP，例如：$SELF unban 1.2.3.4"
    require_f2b
    for _ip in "$@"; do
        valid_target "$_ip" || die "不是合法的 IP / CIDR：$_ip"
    done

    for _ip in "$@"; do
        _found=''
        for _j in $(target_jails); do
            jail_banned "$_j" | grep -qx "$_ip" && _found="$_found $_j"
        done
        if [ -z "$_found" ]; then
            warn "$_ip 目前沒有被任何指定的 jail 封鎖"
            continue
        fi
        step "$_ip 目前被這些 jail 封鎖：$_found"
        [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; continue; }
        confirm "要解除嗎？" || continue
        for _j in $_found; do
            _out=$(fail2ban-client set "$_j" unbanip "$_ip" 2>&1)
            case "$_out" in
                *[Ee]rror*|*NOK*) err "[$_j] $_ip 解除失敗：$(printf '%s' "$_out" | head -1)" ;;
                *)                ok "[$_j] 已解除 $_ip" ;;
            esac
        done
    done
}

cmd_unban_all() {
    require_f2b
    _js=$(target_jails)
    _n=0
    for _j in $_js; do
        _c=$(jail_banned "$_j" | cnt .)
        _n=$((_n + _c))
        info "$_j：$_c 筆"
    done
    [ "$_n" = 0 ] && { ok "封鎖清單本來就是空的"; return 0; }
    step "將解除 $_n 筆封鎖"
    warn "這會把目前所有封鎖一次清空，攻擊來源會立刻恢復連線能力"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "確定要清空嗎？" || return 0
    for _j in $_js; do
        for _ip in $(jail_banned "$_j"); do
            fail2ban-client set "$_j" unbanip "$_ip" >/dev/null 2>&1 && ok "[$_j] 已解除 $_ip" \
                || err "[$_j] $_ip 解除失敗"
        done
    done
}

cmd_check() {
    [ $# -ge 1 ] || die "請給要查詢的 IP，例如：$SELF check 1.2.3.4"
    _ip="$1"
    valid_target "$_ip" || die "不是合法的 IP / CIDR：$_ip"
    require_f2b

    step "查詢 $_ip"

    _in=''
    for _w in $(ignore_effective | sort -u); do
        covers "$_w" "$_ip" && { _in="$_w"; break; }
    done
    if [ -n "$_in" ]; then
        warn "在白名單內（$_in）— 這個 IP 不會被 fail2ban 封鎖"
    else
        info "白名單    : 不在白名單"
    fi

    _banned=''
    for _j in $(jails); do
        jail_banned "$_j" | grep -qx "$_ip" && _banned="$_banned $_j"
    done
    if [ -n "$_banned" ]; then
        err "目前封鎖中：$_banned"
        info "解除：$SELF unban $_ip"
    else
        ok "目前沒有被封鎖"
    fi

    for _p in $(ssh_peers | sort -u); do
        [ "$_p" = "$_ip" ] && warn "這就是你目前的 SSH 來源，封它等於自斷連線"
    done

    if [ "$(log_src)" != none ]; then
        _bans=$(log_cat | grep -F " $_ip" | cnt -E '\] Ban ')
        _unbans=$(log_cat | grep -F " $_ip" | cnt -E '\] Unban ')
        info "歷史紀錄  : 封鎖 $_bans 次 / 解除 $_unbans 次（來源 $(log_src)）"
    else
        info "歷史紀錄  : 讀不到 fail2ban 日誌，無法統計"
    fi
}

cmd_allow() {
    [ $# -ge 1 ] || die "請給要加白名單的 IP，例如：$SELF allow 1.2.3.4"
    need_root
    for _ip in "$@"; do
        valid_target "$_ip" || die "不是合法的 IP / CIDR：$_ip"
    done

    _cur=$(ignore_effective | sort -u)
    _new="127.0.0.1/8
::1
$_cur"
    for _ip in "$@"; do
        _new="$_new
$_ip"
    done
    _list=$(printf '%s\n' "$_new" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')

    step "白名單將變成：$_list"
    info "寫入：$IGNORE_FILE"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "要寫入嗎？" || return 0

    ignore_write "$_list"
    ok "已寫入 $IGNORE_FILE"

    # 即時生效：新版可以直接 addignoreip，舊版只能 reload
    if f2b_ping; then
        _applied=1
        for _j in $(jails); do
            for _ip in "$@"; do
                _o=$(fail2ban-client set "$_j" addignoreip "$_ip" 2>&1)
                case "$_o" in *[Ee]rror*|*Invalid*|*NOK*) _applied=0 ;; esac
            done
        done
        if [ "$_applied" = 1 ]; then
            ok "已即時套用到現有 jail"
        else
            info "這個版本沒有 addignoreip，改用 reload 讓設定生效"
            cmd_reload
        fi
        # 白名單不會自動解除已經被封的 IP，這點很容易誤解
        for _ip in "$@"; do
            for _j in $(jails); do
                jail_banned "$_j" | grep -qx "$_ip" && \
                    warn "$_ip 目前仍被 $_j 封鎖中 — 白名單只影響「之後」，要解除請跑：$SELF unban $_ip"
            done
        done
    else
        info "fail2ban 沒在跑，設定會在下次啟動時生效"
    fi
}

cmd_disallow() {
    [ $# -ge 1 ] || die "請給要移出白名單的 IP"
    need_root
    [ -f "$IGNORE_FILE" ] || die "$IGNORE_FILE 不存在，本腳本沒有管理中的白名單"

    _cur=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$IGNORE_FILE" 2>/dev/null |
           sed 's/^[^=]*=//' | tr ' \t,' '\n\n\n' | grep -v '^$' | sort -u)
    _keep="$_cur"
    for _ip in "$@"; do
        case "$_ip" in
            127.0.0.1/8|::1) die "$_ip 是 loopback，不移除（移掉會讓 fail2ban 封到本機自己）" ;;
        esac
        _keep=$(printf '%s\n' "$_keep" | grep -vxF "$_ip")
    done
    _list=$(printf '%s\n' "$_keep" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')

    step "白名單將變成：$_list"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "要寫入嗎？" || return 0
    ignore_write "$_list"
    ok "已寫入 $IGNORE_FILE"
    info "移除白名單一定要 reload 才會生效"
    f2b_ping && cmd_reload || info "fail2ban 沒在跑，設定會在下次啟動時生效"
}

cmd_top() {
    _n="${1:-15}"
    case "$_n" in ''|*[!0-9]*) die "數量要是數字" ;; esac
    [ "$(log_src)" = none ] && die "讀不到 fail2ban 日誌（找過 /var/log/fail2ban.log、journal、logread）"
    step "封鎖次數最多的來源 TOP $_n（來源：$(log_src)）"
    log_cat | grep -E '\] Ban ' | awk '{print $NF}' |
        sort | uniq -c | sort -rn | head -n "$_n" |
        awk '{printf "  %6s 次  %s\n", $1, $2}'
}

cmd_log() {
    _n="${1:-30}"
    case "$_n" in ''|*[!0-9]*) die "數量要是數字" ;; esac
    [ "$(log_src)" = none ] && die "讀不到 fail2ban 日誌"
    step "最近 $_n 筆封鎖 / 解除事件（來源：$(log_src)）"
    log_cat | grep -E '\] (Ban|Unban|Restore Ban) ' | tail -n "$_n" | sed 's/^/  /'
}

cmd_tail() {
    [ "$(log_src)" = none ] && die "讀不到 fail2ban 日誌"
    step "追蹤 fail2ban 日誌（Ctrl-C 離開，來源：$(log_src)）"
    log_follow
}

cmd_bantime() {
    require_f2b
    if [ $# -eq 0 ]; then
        for _j in $(jails); do
            info "$(printf '%-20s bantime=%-10s findtime=%-8s maxretry=%s' "$_j" \
                "$(fail2ban-client get "$_j" bantime 2>/dev/null || echo '?')" \
                "$(fail2ban-client get "$_j" findtime 2>/dev/null || echo '?')" \
                "$(fail2ban-client get "$_j" maxretry 2>/dev/null || echo '?')")"
        done
        info ""
        info "設定：$SELF bantime <jail> <秒>   （-1 = 永久）"
        return 0
    fi
    _j="$1"; _t="${2:-}"
    jail_exists "$_j" || die "找不到 jail：$_j"
    [ -n "$_t" ] || { info "$_j bantime = $(fail2ban-client get "$_j" bantime 2>/dev/null)"; return 0; }
    case "$_t" in -1|[0-9]*) : ;; *) die "秒數要是數字，或 -1 代表永久" ;; esac
    step "$_j 的 bantime 改為 $_t"
    warn "這只改執行中的設定，重啟 fail2ban 後會回到設定檔的值"
    info "要永久生效請寫進 $F2B_JAILD 底下的 .local 檔"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "要套用嗎？" || return 0
    fail2ban-client set "$_j" bantime "$_t" >/dev/null 2>&1 && ok "已套用" || err "套用失敗"
}

cmd_enable_sshd() {
    need_root
    has fail2ban-client || die "fail2ban 還沒安裝，先跑：$SELF install"
    _ports=$(live_ssh_ports | tr '\n' ',' | sed 's/,$//')
    _backend=auto
    # RHEL 7 的 sshd 認證記錄在 /var/log/secure；若該檔不存在（純 journald）
    # 就必須用 systemd backend，否則 jail 讀不到任何東西、永遠不會封。
    if [ "$INIT" = systemd ] && [ ! -r "${PREFIX}/var/log/secure" ] && [ ! -r "${PREFIX}/var/log/auth.log" ]; then
        _backend=systemd
    fi

    step "將建立 sshd jail"
    info "檔案      : $SSHD_JAIL_FILE"
    info "監控埠    : $_ports   （取自實際生效的 sshd 設定）"
    info "backend   : $_backend"
    info "門檻      : maxretry=5 findtime=600 bantime=3600"
    [ -f "$SSHD_JAIL_FILE" ] && warn "檔案已存在，會被覆寫"
    [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
    confirm "要寫入嗎？" || return 0

    mkdir -p "$F2B_JAILD" 2>/dev/null || die "無法建立 $F2B_JAILD"
    _tmp="${SSHD_JAIL_FILE}.tmp.$$"
    {
        printf '%s\n' "# 由 fail2ban.sh 管理（$SELF enable-sshd），手動編輯會被覆寫。"
        printf '%s\n' "# port 取自實際生效的 sshd 設定；換過 SSH 埠之後要重跑本命令，"
        printf '%s\n' "# 否則封鎖規則會套在舊埠上，等於完全沒有防護。"
        printf '%s\n' "[sshd]"
        printf '%s\n' "enabled  = true"
        printf '%s\n' "backend  = $_backend"
        printf '%s\n' "port     = $_ports"
        printf '%s\n' "maxretry = 5"
        printf '%s\n' "findtime = 600"
        printf '%s\n' "bantime  = 3600"
    } > "$_tmp" || { rm -f "$_tmp"; die "寫入暫存檔失敗"; }
    cat "$_tmp" > "$SSHD_JAIL_FILE" && rm -f "$_tmp" || { rm -f "$_tmp"; die "寫入失敗"; }
    chmod 644 "$SSHD_JAIL_FILE" 2>/dev/null
    ok "已寫入 $SSHD_JAIL_FILE"

    if f2b_ping; then
        cmd_reload
    else
        info "fail2ban 沒在跑，啟動：$SELF install（會一併 enable）"
    fi
}

cmd_reload() {
    need_root
    has fail2ban-client || die "找不到 fail2ban-client"
    step "重載 fail2ban 設定"
    _out=$(fail2ban-client reload 2>&1)
    case "$_out" in
        *[Ee]rror*|*Traceback*|*NOK*)
            err "重載失敗，設定可能有語法錯誤：$(printf '%s' "$_out" | head -3)"
            info "fail2ban 會繼續用舊設定運作；修好後再跑一次"
            return 1 ;;
        *)  ok "已重載（jail：$(jails | tr '\n' ' ')）" ;;
    esac
}

cmd_install() {
    need_root
    if has fail2ban-client; then
        ok "fail2ban 已安裝（${F2B_VER:-版本未知}）"
    else
        [ "$PKG" = none ] && die "找不到套件管理器，請自行安裝 fail2ban"
        _pkgs=fail2ban
        if [ "$OS_FAMILY" = rhel ]; then
            info "RHEL 系的 fail2ban 在 EPEL，會先裝 epel-release"
            [ "${OS_VER%%.*}" = 7 ] && _pkgs="fail2ban fail2ban-systemd"
        fi
        step "將執行：$PKG_INSTALL $_pkgs"
        [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
        confirm "要安裝嗎？" || return 0
        if [ "$OS_FAMILY" = rhel ]; then
            $PKG_INSTALL epel-release || warn "epel-release 安裝失敗，繼續試裝 fail2ban"
        fi
        [ "$PKG" = apt ] && apt-get update
        # shellcheck disable=SC2086
        $PKG_INSTALL $_pkgs || die "安裝失敗"
        detect_env
        ok "已安裝 ${F2B_VER:-}"
    fi

    if [ "$(svc_state)" != active ]; then
        step "啟用並啟動 $F2B_SVC"
        [ "$DRY" = 1 ] && { info "（乾跑，不實際執行）"; return 0; }
        svc_start || warn "啟動失敗，跑 $SELF doctor 看原因"
    fi
    info "服務狀態  : $(svc_state)"
    if f2b_ping && [ -z "$(jails)" ]; then
        warn "沒有任何啟用中的 jail — 現在還不會封任何東西"
        info "建立 sshd jail：$SELF enable-sshd"
    fi
}

cmd_doctor() {
    step "fail2ban 環境檢查"
    info "系統      : $OS_PRETTY (family=$OS_FAMILY, init=$INIT, pkg=$PKG)"
    if has fail2ban-client; then
        ok "fail2ban-client 存在（${F2B_VER:-版本未知}）"
    else
        err "沒有 fail2ban-client — 安裝：$SELF install"
    fi
    info "服務      : $F2B_SVC ($(svc_state))"

    if [ "$(id -u)" != 0 ]; then
        warn "非 root 執行：讀不到控制 socket，以下 jail 相關檢查會跳過"
        info "日誌來源  : $(log_src)"
        return 0
    fi

    if ! has fail2ban-client; then return 1; fi

    if f2b_ping; then
        ok "伺服器有回應（ping = pong）"
    else
        err "伺服器沒有回應 — 服務沒起來，或 socket 權限 / SELinux 有問題"
        info "看日誌：$SELF log   或  journalctl -u $F2B_SVC -n 50"
        info "日誌來源  : $(log_src)"
        return 1
    fi

    _js=$(jails)
    if [ -z "$_js" ]; then
        err "沒有啟用中的 jail — fail2ban 在跑，但不會封任何東西"
        info "這是最常見的「以為裝了就有保護」情況。建立：$SELF enable-sshd"
    else
        ok "啟用中的 jail：$(printf '%s' "$_js" | tr '\n' ' ')"
    fi

    # sshd jail 的埠號有沒有跟上實際的 SSH 埠
    _live=$(live_ssh_ports | tr '\n' ' ' | sed 's/ *$//')
    info "實際 SSH 埠: $_live"
    if printf '%s\n' "$_js" | grep -qx sshd; then
        _jp=$(jail_conf_port sshd)
        if [ -z "$_jp" ]; then
            info "sshd jail 沒有明寫 port，用的是預設 ssh（/etc/services 的 22）"
            for _lp in $_live; do
                [ "$_lp" = 22 ] || { err "SSH 實際在 $_lp，但 jail 用預設 22 — 封鎖規則會套錯埠，等於沒有防護"
                                     info "修正：$SELF enable-sshd（會把實際埠號寫進去）"; break; }
            done
        else
            info "sshd jail 的 port: $_jp"
            for _lp in $_live; do
                case ",$(printf '%s' "$_jp" | tr -d ' '),"  in
                    *",$_lp,"*) : ;;
                    *) err "SSH 實際在 $_lp，但 jail 的 port 是「$_jp」— 封鎖會套錯埠"
                       info "修正：$SELF enable-sshd" ;;
                esac
            done
        fi
    else
        warn "沒有 sshd jail — SSH 沒有被 fail2ban 保護"
    fi

    # 白名單與自己的來源
    _ig=$(ignore_effective | sort -u | tr '\n' ' ')
    info "白名單    : ${_ig:-（空）}"
    _me=$(ssh_peers | sort -u | head -5 | tr '\n' ' ')
    if [ -n "$_me" ]; then
        info "你的來源  : $_me"
        for _p in $_me; do
            _hit=''
            for _w in $_ig; do covers "$_w" "$_p" && { _hit=1; break; }; done
            [ -z "$_hit" ] && warn "$_p 不在白名單內 — 自己打錯密碼幾次也會被關在外面（$SELF allow $_p）"
        done
    fi

    _src=$(log_src)
    if [ "$_src" = none ]; then
        warn "讀不到 fail2ban 日誌 — top / log / check 的歷史統計會不可用"
        [ "$OS_FAMILY" = alpine ] && info "Alpine 請啟用 syslog：rc-update add syslog && rc-service syslog start"
    else
        ok "日誌來源  : $_src"
    fi

    # 封鎖到底有沒有落到防火牆裡
    #
    # 不能用「規則名稱裡有沒有 f2b」判斷：banaction 走 firewalld 或 ipset 時，
    # 規則不叫這個名字，會變成誤報。改成拿一個「現在真的被封的 IP」去各個後端
    # 裡找——這是唯一跟 banaction 寫法無關的驗證方式。
    _cnt=0; _one=''
    for _j in $_js; do
        _c=$(jail_banned "$_j" | cnt .)
        _cnt=$((_cnt + _c))
        [ -z "$_one" ] && _one=$(jail_banned "$_j" | head -1)
    done

    if [ -z "$_one" ]; then
        info "封鎖規則  : 目前沒有封鎖中，無法驗證（有封鎖時這裡會實際去防火牆裡找）"
    elif has iptables && iptables-save 2>/dev/null | grep -qF "$_one"; then
        ok "封鎖規則  : iptables 裡找得到 $_one"
    elif has nft && nft list ruleset 2>/dev/null | grep -qF "$_one"; then
        ok "封鎖規則  : nftables 裡找得到 $_one"
    elif has ipset && ipset list 2>/dev/null | grep -qF "$_one"; then
        ok "封鎖規則  : ipset 裡找得到 $_one"
    elif has firewall-cmd && firewall-cmd --list-all-zones 2>/dev/null | grep -qF "$_one"; then
        ok "封鎖規則  : firewalld 裡找得到 $_one"
    else
        err "有 $_cnt 筆封鎖中，但 $_one 在 iptables / nftables / ipset / firewalld 裡都找不到"
        info "封鎖清單有它、防火牆沒有 = 封包照樣進得來"

        # 到這一步就別再叫人自己去 grep 了，直接把三件該看的東西挖出來
        _ba=$(grep -hrE '^[[:space:]]*(banaction|action)[[:space:]]*=' \
              "${F2B_ETC}/jail.conf" "${F2B_ETC}/jail.local" "${F2B_JAILD}" 2>/dev/null |
              sed 's/^[[:space:]]*//' | sort -u | tr '\n' ';' | sed 's/;$//')
        [ -n "$_ba" ] && info "設定的 banaction : $_ba"

        if has iptables; then
            if iptables -S 2>/dev/null | grep -q 'f2b'; then
                warn "f2b 鏈存在，但裡面沒有這個 IP 的規則"
                info "多半是防火牆被重啟 / reload 過，把 f2b 鏈的內容沖掉了——fail2ban 不會自己補回去"
                info "重新套用：systemctl restart $F2B_SVC （重啟時會從資料庫還原封鎖）"
            else
                warn "iptables 裡連 f2b 鏈都沒有 = ban 動作從頭到尾沒執行成功"
                info "常見原因：容器 / VPS 缺 iptables 模組、banaction 指到這台沒有的後端"
            fi
        fi

        _errs=$(log_cat 2>/dev/null |
                grep -iE 'failed to execute (ban|unban)|error banning|iptables.*(no chain|not found|permission)' |
                tail -3)
        if [ -n "$_errs" ]; then
            info "fail2ban 日誌裡的相關錯誤（最後 3 筆）："
            printf '%s\n' "$_errs" | sed 's/^/      /'
        else
            info "fail2ban 日誌裡沒有 ban 失敗的錯誤 — 那就是規則事後被沖掉，不是當下沒套上"
        fi
    fi
}

usage() {
    cat <<EOF
fail2ban.sh — fail2ban 封鎖管理  v$F2B_SH_VER

  $SELF status              服務與各 jail 的封鎖概況
  $SELF list [jail]         列出已封鎖的 IP
  $SELF ban <IP…>           手動封鎖（預設所有 jail）
  $SELF unban <IP…>         解除封鎖（自動找出哪些 jail 封了它）
  $SELF unban-all           清空封鎖清單
  $SELF check <IP>          查這個 IP 現在的狀態（封鎖 / 白名單 / 歷史次數）
  $SELF allow <IP…>         加白名單（ignoreip）
  $SELF disallow <IP…>      移除白名單
  $SELF top [n]             封鎖次數最多的來源，預設 15
  $SELF log [n]             最近的封鎖 / 解除事件，預設 30
  $SELF tail                即時追蹤 fail2ban 日誌
  $SELF bantime [jail] [秒] 查看 / 設定封鎖時長（-1 = 永久）
  $SELF enable-sshd         建立 sshd jail，埠號取實際生效值
  $SELF reload              重載設定
  $SELF install             安裝並啟用 fail2ban
  $SELF doctor              環境檢查

選項：
  -j <jail>   只對這個 jail 動作（預設：全部）
  -t <秒>     封鎖時長，perm = 永久（需 fail2ban 支援 banip --time）
  -y          不問確認
  -n          乾跑，只印出將要做什麼
  --force     即使會鎖到自己也照做（風險自負）

除 doctor / -h 外都需要 root（fail2ban 的控制 socket 只有 root 能用）。
封鎖一律透過 fail2ban-client，本腳本不自己寫防火牆規則。
設定只寫 $F2B_JAILD 底下自己管理的 .local 檔，不動發行版的 jail.conf。
EOF
    exit 0
}

# =========================================================
# 進入點
# =========================================================
CMD="${1:-status}"
[ $# -gt 0 ] && shift

case "$CMD" in
    -h|--help|help) detect_env; usage ;;
esac

# 選項可以出現在 IP 前後，先掃一遍分離出來
ARGS=''
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -j|--jail) [ $# -ge 2 ] || { printf '%s\n' "-j 後面要接 jail 名稱" >&2; exit 1; }
                   DEFAULT_JAIL="$2"; shift 2 ;;
        -t|--time) [ $# -ge 2 ] || { printf '%s\n' "-t 後面要接秒數" >&2; exit 1; }
                   case "$2" in
                       perm|permanent|forever) BANTIME=-1 ;;
                       -1|[0-9]*)              BANTIME="$2" ;;
                       *) printf '%s\n' "-t 要接秒數、-1 或 perm" >&2; exit 1 ;;
                   esac
                   shift 2 ;;
        -y|--yes)   YES=1; shift ;;
        -n|--dry-run) DRY=1; shift ;;
        --force)    FORCE=1; shift ;;
        -*) printf '%s\n' "未知選項：$1（可用 -j / -t / -y / -n / --force）" >&2; exit 1 ;;
        *)  ARGS="$ARGS $1"; shift ;;
    esac
done

detect_env

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null && chmod 750 "$(dirname "$LOGFILE")" 2>/dev/null

# shellcheck disable=SC2086
set -- $ARGS

case "$CMD" in
    status)                cmd_status ;;
    list|ls)               cmd_list "$@" ;;
    ban|block)             cmd_ban "$@" ;;
    unban|unblock)         cmd_unban "$@" ;;
    unban-all|flush)       cmd_unban_all ;;
    check|query)           cmd_check "$@" ;;
    allow|whitelist)       cmd_allow "$@" ;;
    disallow|unwhitelist)  cmd_disallow "$@" ;;
    top)                   cmd_top "$@" ;;
    log|logs)              cmd_log "$@" ;;
    tail|follow)           cmd_tail ;;
    bantime)               cmd_bantime "$@" ;;
    enable-sshd)           cmd_enable_sshd ;;
    reload)                cmd_reload ;;
    install)               cmd_install ;;
    doctor|check-env)      cmd_doctor ;;
    *) printf '%s\n' "未知命令：$CMD（跑 $SELF -h 看用法）" >&2; exit 1 ;;
esac
