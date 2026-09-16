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
#   ./fail2ban.sh report              fail2ban 做了哪些事：終端機摘要 + 單檔 HTML（唯讀）
#
#   共用選項：-j <jail> 指定 jail、-t <秒|perm> 封鎖時長、-y 免確認、-n 乾跑
#   report 選項：--days <N|all> 範圍（預設 7）、-o <檔案> HTML 輸出路徑
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

# =========================================================
# 封鎖後端
#   「INPUT 鏈裡沒有規則」不等於「不能封鎖」——fail2ban 會自己建 f2b-* 鏈並在
#   INPUT 插一條 jump，原本空的也照樣生效。真正會讓封鎖失效的是「連鏈都建不起
#   來」（容器缺 netfilter 模組）或「banaction 指到這台沒有的後端」。
# =========================================================
fw_backend() {
    if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld\n'; return 0; fi
    if has ufw && ufw status 2>/dev/null | head -1 | grep -qi active;  then printf 'ufw\n';       return 0; fi
    if has nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then printf 'nftables\n';  return 0; fi
    if has iptables; then printf 'iptables\n'; return 0; fi     # 有指令就算數，不看有沒有規則
    printf 'none\n'
}

# 每種後端該用哪個 banaction。firewalld 特別重要：它 reload 時會把 iptables 上的
# f2b 鏈整個沖掉，用 iptables-* 的話封鎖會靜默失效（清單裡有、防火牆裡沒有）。
banaction_for() {
    case "$1" in
        firewalld) printf 'firewallcmd-rich-rules\n' ;;
        ufw)       printf 'ufw\n' ;;
        nftables)  printf 'nftables-multiport\n' ;;
        iptables)  printf 'iptables-multiport\n' ;;
        *)         printf '\n' ;;
    esac
}

# 選一個「這個 fail2ban 版本真的有」的 banaction。action.d 裡沒有對應檔案就回空，
# 讓 fail2ban 用發行版預設值，而不是寫一個會讓服務起不來的名字進去。
banaction_pick() {
    _w=$(banaction_for "$(fw_backend)")
    [ -n "$_w" ] || return 0
    [ -f "${F2B_ETC}/action.d/${_w}.conf" ] && printf '%s\n' "$_w"
}

# 目前設定檔裡實際生效的 banaction（取最後一個，載入順序越後面越優先）
banaction_current() {
    _files=''
    for _f in "${F2B_ETC}/jail.conf" "${F2B_ETC}/jail.local" \
              "${F2B_JAILD}"/*.conf "${F2B_JAILD}"/*.local; do
        [ -f "$_f" ] && _files="$_files $_f"
    done
    [ -n "$_files" ] || return 0
    # shellcheck disable=SC2086
    grep -hE '^[[:space:]]*banaction[[:space:]]*=' $_files 2>/dev/null |
        sed 's/^[^=]*=[[:space:]]*//' | tr -d ' \t\r' | grep -v '^$' | tail -1
}

container_kind() {
    _k=$(systemd-detect-virt -c 2>/dev/null)      # 非容器時會印 none 且回傳非 0
    [ -n "$_k" ] || _k=none
    if [ "$_k" = none ]; then
        [ -f /.dockerenv ] && _k=docker
        grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && _k=lxc
    fi
    printf '%s\n' "$_k"
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
    [ $# -ge 1 ] || die "請給要封鎖的 IP，例如：$SELF ban 203.0.113.5"
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
                # 不支援 --time 的版本（實測 0.11.2）不會報錯，而是把每個參數都當成 IP 封下去：
                # 目標 IP 照樣進清單（時長是 jail 預設），另外多出「--time」與秒數兩筆垃圾。
                # 所以只看「目標 IP 有沒有進清單」會誤判成支援——要看有沒有多出 --time。
                if jail_banned "$_j" | grep -qx -- '--time'; then
                    BANTIME_OK=no
                    fail2ban-client set "$_j" unbanip --time "$BANTIME" >/dev/null 2>&1
                    warn "這個 fail2ban 版本的 banip 不接受指定時長（它把 --time 與秒數也當成 IP 封了，已清掉）"
                    info "$_ip 已用 jail 本身的 bantime 封鎖；要改 jail 的預設時長：$SELF bantime <jail> <秒>"
                elif jail_banned "$_j" | grep -qx "$_ip"; then
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
    [ $# -ge 1 ] || die "請給要解除封鎖的 IP，例如：$SELF unban 203.0.113.5"
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
    [ $# -ge 1 ] || die "請給要查詢的 IP，例如：$SELF check 203.0.113.5"
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
    [ $# -ge 1 ] || die "請給要加白名單的 IP，例如：$SELF allow 203.0.113.5"
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
    # 只收長得像 IP 的：舊版 banip 不認得 --time 時，日誌裡會留下「Ban 600」「Ban --time」
    # 這種紀錄（見「封鎖時長」一節），不能把它們算成來源
    log_cat | grep -E '\] Ban ' |
        awk '{ ip = $NF; if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ip ~ /:/) print ip }' |
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

    _fw=$(fw_backend)
    _ba=$(banaction_pick)

    step "將建立 sshd jail"
    info "檔案      : $SSHD_JAIL_FILE"
    info "監控埠    : $_ports   （取自實際生效的 sshd 設定）"
    info "backend   : $_backend"
    if [ -n "$_ba" ]; then
        info "banaction : $_ba   （依偵測到的防火牆 $_fw 選的）"
    else
        info "banaction : 不寫入，沿用發行版預設"
        [ "$_fw" = none ] && warn "這台偵測不到可用的防火牆，封鎖會寫不進去（先跑 doctor）"
        [ "$_fw" != none ] && info "（這個 fail2ban 版本沒有 $(banaction_for "$_fw") 這個 action 檔）"
    fi
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
        if [ -n "$_ba" ]; then
            printf '%s\n' "# banaction 依偵測到的防火牆（$_fw）選。用錯的話封鎖會靜默失效："
            printf '%s\n' "# firewalld 每次 reload 都會把 iptables 上的 f2b 鏈沖掉，變成清單裡有、"
            printf '%s\n' "# 防火牆裡沒有。換過防火牆方案之後重跑 enable-sshd 即可。"
            printf '%s\n' "banaction = $_ba"
        fi
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

    # ban 動作到底有沒有地方可以寫（規則是空的不影響，重點是能不能建鏈）
    _fw=$(fw_backend)
    _ct=$(container_kind)
    info "防火牆後端 : $_fw$([ "$_ct" != none ] && printf ' （容器：%s）' "$_ct")"
    case "$_fw" in
        none)
            err "找不到任何可用的防火牆工具 — fail2ban 沒有地方可以寫封鎖規則"
            info "封鎖清單會一直長大，但封包照樣進得來。安裝 iptables 或 firewalld 再說" ;;
        iptables)
            # 建一條臨時空鏈再刪掉：這是唯一能證明「ban 動作真的能執行」的方式。
            # 空鏈不掛在任何地方，不影響現有規則。
            _probe="f2b-probe-$$"
            if iptables -w -N "$_probe" 2>/dev/null || iptables -N "$_probe" 2>/dev/null; then
                iptables -w -X "$_probe" 2>/dev/null || iptables -X "$_probe" 2>/dev/null
                ok "iptables 可建鏈 — ban 動作有地方可寫（INPUT 現在有沒有規則都不影響）"
            else
                err "iptables 存在但建不了鏈 — fail2ban 的封鎖不會生效"
                [ "$_ct" != none ] && info "這台是 $_ct 容器，多半是缺 netfilter 模組，宿主機沒開就無解"
                info "只能改用雲端安全群組 / 上層設備擋，或改用金鑰登入並關閉密碼驗證"
            fi ;;
        *)  ok "$_fw 可用 — ban 動作有地方可寫" ;;
    esac

    # banaction 對不對得上這台的後端
    _rec=$(banaction_pick)
    _cur=$(banaction_current)
    [ -n "$_cur" ] && info "設定的 banaction : $_cur"
    if [ -n "$_cur" ] && [ -n "$_rec" ] && [ "$_cur" != "$_rec" ]; then
        warn "banaction 是 $_cur，但這台的防火牆後端是 $_fw — 建議改成 $_rec"
        [ "$_fw" = firewalld ] && \
            info "firewalld 每次 reload 都會把 iptables 上的 f2b 鏈沖掉，封鎖會靜默失效"
        info "修正：$SELF enable-sshd（會依偵測到的後端寫入）"
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
        _ba=$(banaction_current)
        [ -n "$_ba" ] && info "生效中的 banaction : $_ba"

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

# 給 ops.sh 開場呼叫：沒問題就完全安靜，有問題才印一行。
# 刻意做得很輕：不呼叫 fail2ban-client 以外的重東西，也不做任何變更。
cmd_preflight() {
    has fail2ban-client || return 0          # 沒裝就不關我們的事
    [ "$(id -u)" = 0 ] || return 0           # 非 root 讀不到狀態，別亂報

    _fw=$(fw_backend)
    if [ "$_fw" = none ]; then
        warn "fail2ban 已安裝，但找不到可用的防火牆後端 — 封鎖不會生效（選 b → d 看細節）"
        return 0
    fi
    if [ "$_fw" = iptables ]; then
        _probe="f2b-probe-$$"
        if iptables -w -N "$_probe" 2>/dev/null || iptables -N "$_probe" 2>/dev/null; then
            iptables -w -X "$_probe" 2>/dev/null || iptables -X "$_probe" 2>/dev/null
        else
            warn "iptables 建不了鏈 — fail2ban 的封鎖不會生效（選 b → d 看細節）"
            return 0
        fi
    fi

    f2b_ping || { warn "fail2ban 已安裝但服務沒有回應（選 b → d 看細節）"; return 0; }

    [ -z "$(jails)" ] && {
        warn "fail2ban 在跑但沒有任何 jail — 不會封任何東西（選 b → e 建立 sshd jail）"
        return 0
    }

    _rec=$(banaction_pick); _cur=$(banaction_current)
    if [ -n "$_cur" ] && [ -n "$_rec" ] && [ "$_cur" != "$_rec" ]; then
        warn "banaction=$_cur 與這台的防火牆（$_fw）不符，封鎖可能失效（選 b → d 看細節）"
    fi
    return 0
}

# =========================================================
# report — fail2ban 做了哪些事（終端機摘要 + 單檔 HTML）
#
#   全程唯讀：只讀日誌、資料庫、fail2ban-client status 與防火牆規則，不改任何設定。
#   HTML 的圖是內嵌 SVG，不載入任何 JS 函式庫、不連 CDN，下載下來離線也能開、能轉寄。
#
#   資料來源與分工（每個來源各涵蓋到哪一天，報告上都會寫出來）：
#     fail2ban 日誌   Found / Ban / Unban 的時間軸與排行（含 .1、.2.gz 等輪替檔）
#     sqlite 資料庫   目前封鎖中的 IP 什麼時候到期；讀不到就退回「日誌的 Ban 時間 + jail 的 bantime」
#     認證日誌        攻擊者試了哪些帳號（fail2ban 自己沒有這個資訊）
#     防火牆          fail2ban 說封了的 IP，規則裡找不找得到
#
#   日期換算全部在 awk 裡自己做（days_from_civil），不依賴 date -d：busybox / BSD 的
#   date 吃的格式各不相同，mawk 也沒有 mktime / strftime。需要的只有本地時區的偏移量。
# =========================================================
REPORT_DAYS=7
REPORT_OUT=''

rpt_tzoff() {
    _z=$(date +%z 2>/dev/null)
    case "$_z" in
        [+-][0-9][0-9][0-9][0-9]) : ;;
        *) printf '0\n'; return 0 ;;
    esac
    _hh=$(printf '%s' "$_z" | cut -c2-3 | sed 's/^0//')
    _mm=$(printf '%s' "$_z" | cut -c4-5 | sed 's/^0//')
    _o=$(( ${_hh:-0} * 3600 + ${_mm:-0} * 60 ))
    case "$_z" in -*) _o=$(( 0 - _o )) ;; esac
    printf '%s\n' "$_o"
}

rpt_cat() {
    case "$1" in
        *.gz) gzip -dc "$1" 2>/dev/null ;;
        *.xz) xz -dc "$1" 2>/dev/null ;;
        *)    cat "$1" 2>/dev/null ;;
    esac
}

# awk 共用函式：民曆 <-> 日數（Howard Hinnant 的演算法，純整數）、本地時間字串 <-> epoch、
# 千分位、時間長度、HTML 跳脫。
RPT_AWK_LIB='
function c2d(y, m, d,   era, yoe, doy, doe, mp) {
    if (m <= 2) y--
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    mp = (m > 2) ? m - 3 : m + 9
    doy = int((153 * mp + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
function d2c(z,   era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1
    m = (mp < 10) ? mp + 3 : mp - 9
    if (m <= 2) y++
    return sprintf("%04d-%02d-%02d", y, m, d)
}
function ep(ts) {
    return c2d(substr(ts, 1, 4) + 0, substr(ts, 6, 2) + 0, substr(ts, 9, 2) + 0) * 86400 \
         + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2) - TZOFF
}
function lt(e,   l, d, s) {
    l = e + TZOFF; d = int(l / 86400); s = l - d * 86400
    return d2c(d) sprintf(" %02d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60)
}
function fmtn(n,   s, r) {
    s = sprintf("%d", n); r = ""
    while (length(s) > 3) { r = "," substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) }
    return s r
}
function dur(s,   d, h, m) {
    if (s < 0) s = 0
    d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
    if (d > 0) return d " 天 " h " 小時"
    if (h > 0) return h " 小時 " m " 分"
    return m " 分"
}
function esc(s) {
    gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
    return s
}
'

# fail2ban 日誌 -> 「epoch  類型  jail  IP」。類型：F=Found B=Ban U=Unban R=Restore Ban I=Ignore
# 同時吃檔案格式（開頭是 YYYY-MM-DD HH:MM:SS）與 journalctl -o short-iso 格式。
RPT_AWK_F2B='
{
    if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)
        ts = substr($0, 1, 19)
    else if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)
        ts = substr($0, 1, 10) " " substr($0, 12, 8)
    else next
    if (!match($0, /\[[^]]*\] (Found|Ban|Unban|Restore Ban|Ignore) [0-9A-Fa-f:.]+/)) next
    s = substr($0, RSTART, RLENGTH)
    p = index(s, "]"); jl = substr(s, 2, p - 2); r = substr(s, p + 2)
    if (substr(r, 1, 12) == "Restore Ban ") { t = "R"; ip = substr(r, 13) }
    else {
        q = index(r, " "); w = substr(r, 1, q - 1); ip = substr(r, q + 1)
        t = (w == "Found") ? "F" : (w == "Ban") ? "B" : (w == "Unban") ? "U" : "I"
    }
    # 只收長得像 IP 的：舊版 banip 不認得 --time 時會留下「Ban 600」這種紀錄，不能算成一個來源
    if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /:/) next
    printf "%d\t%s\t%s\t%s\n", ep(ts), t, jl, ip
}'

# sshd 認證日誌 -> 「epoch  帳號  不存在(1/0)  IP  連線鍵」
# syslog 格式沒有年份：月份比現在大就當成去年（日誌跨年時才不會算到未來去）。
# 連線鍵 = sshd 的 pid + 日期。同一條連線會寫好幾行（Invalid user、Failed password、
# Connection closed …），用它去重才不會把一次連線算成三次。
RPT_AWK_AUTH='
BEGIN { MON = "JanFebMarAprMayJunJulAugSepOctNovDec" }
/sshd/ {
    if ($0 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)
        ts = substr($0, 1, 10) " " substr($0, 12, 8)
    else {
        m = index(MON, substr($0, 1, 3)); if (m == 0 || (m - 1) % 3) next
        m = (m + 2) / 3; y = NOWY; if (m > NOWM) y--
        tm = substr($0, 8, 8)
        if (tm !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) next
        ts = sprintf("%04d-%02d-%02d %s", y, m, substr($0, 5, 2) + 0, tm)
    }
    # sshd filter 在預設 normal 模式下不計數的連線（aggressive / ddos 模式才會）：
    # 連上就斷的掃描、還沒到認證就斷線、協商失敗、根本不是 SSH 的探測。另外寫到 UNSEEN。
    uc = ""
    if (index($0, "Did not receive identification string")) uc = "noid"
    else if (index($0, "Bad protocol version identification") || index($0, "banner exchange: ")) uc = "proto"
    else if (index($0, "Unable to negotiate with ")) uc = "nego"
    else if ($0 ~ /(Connection closed by|Connection reset by|Disconnected from) [0-9A-Fa-f:.]+ port [0-9]+ \[preauth\]/) uc = "preauth"
    if (uc != "") {
        ip = "?"
        if (match($0, / (from|by|with) [0-9A-Fa-f:.]+ port [0-9]+/) || match($0, / from [0-9A-Fa-f:.]+$/)) {
            ip = substr($0, RSTART + 1, RLENGTH - 1); sub(/^[a-z]+ /, "", ip); sub(/ .*$/, "", ip)
        }
        printf "%d\t%s\t%s\n", ep(ts), uc, ip > UNSEEN
        next
    }
    pid = ""
    if (match($0, /sshd\[[0-9]+\]/)) pid = substr($0, RSTART + 5, RLENGTH - 6)
    inv = 0; mode = "from"
    if ((p = index($0, "Invalid user ")) > 0) { rest = substr($0, p + 13); inv = 1 }
    else if (match($0, /Failed [a-z\/-]+ for /) || match($0, /maximum authentication attempts exceeded for /)) {
        rest = substr($0, RSTART + RLENGTH)
        if (substr(rest, 1, 13) == "invalid user ") { rest = substr(rest, 14); inv = 1 }
    }
    else if (match($0, /(Connection closed by|Disconnected from) (invalid|authenticating) user /)) {
        inv = (index(substr($0, RSTART, RLENGTH), "invalid") > 0)
        rest = substr($0, RSTART + RLENGTH); mode = "sp"
    }
    else next
    if (mode == "from") {
        if (!match(rest, / from [0-9A-Fa-f:.]+/)) next
        u = substr(rest, 1, RSTART - 1); ip = substr(rest, RSTART + 6, RLENGTH - 6)
    } else {
        if (!match(rest, / [0-9A-Fa-f:.]+ port /)) next
        u = substr(rest, 1, RSTART - 1); ip = substr(rest, RSTART + 1, RLENGTH - 7)
    }
    gsub(/\t/, " ", u)
    if (length(u) > 64) u = substr(u, 1, 64) "..."
    printf "%d\t%s\t%d\t%s\t%s@%s\n", ep(ts), u, inv, ip, pid, substr(ts, 1, 10)
}'

# 目前封鎖中的每個 IP：什麼時候封的、什麼時候解、防火牆裡找不找得到。
# 輸入依序：db.tsv（jail ip timeofban bantime）、ev.tsv、jl.tsv、fw.txt、cb.tsv（jail ip）
# 輸出：排序鍵  jail  ip  開始  結束(-1 永久 / 0 不明)  來源  防火牆(1/0/-)
RPT_AWK_CUR='
function infw(ip,   i, s, p, b, a) {
    for (i = 1; i <= nfw; i++) {
        s = fw[i]
        while ((p = index(s, ip)) > 0) {
            b = (p > 1) ? substr(s, p - 1, 1) : ""
            a = substr(s, p + length(ip), 1)
            if (b !~ /[0-9A-Fa-f.:]/ && a !~ /[0-9A-Fa-f.:]/) return 1
            s = substr(s, p + length(ip))
        }
    }
    return 0
}
FILENAME ~ /db\.tsv$/ { dbs[$1 SUBSEP $2] = $3; dbt[$1 SUBSEP $2] = $4; next }
# 取最大值而不是「最後讀到的」：輪替檔是照 glob 順序讀的（.log、.log.1、.log.2.gz），
# 最後讀到的反而是最舊的那份
FILENAME ~ /ev\.tsv$/ {
    k = $3 SUBSEP $4
    if ($2 == "B" && $1 + 0 > lb[k] + 0) lb[k] = $1
    else if ($2 == "R" && $1 + 0 > lr[k] + 0) lr[k] = $1
    next
}
FILENAME ~ /jl\.tsv$/ { jbt[$1] = $7; next }
FILENAME ~ /fw\.txt$/ { fw[++nfw] = $0; hasfw = 1; next }
FILENAME ~ /cb\.tsv$/ {
    k = $1 SUBSEP $2; st = 0; bt = ""; src = ""
    if (k in dbs) { st = dbs[k]; bt = dbt[k]; src = "資料庫" }
    else if (k in lb) { st = lb[k]; src = "日誌" }
    else if (k in lr) { st = lr[k]; src = "日誌（重啟時間，實際更早）" }
    if (bt == "" || bt == -2) bt = jbt[$1]
    if (st == 0 || bt == "" || bt ~ /[^0-9-]/) en = 0
    else if (bt + 0 < 0) en = -1
    else en = st + bt
    f = (FWOK == 1) ? infw($2) : "-"
    printf "%d\t%s\t%s\t%d\t%d\t%s\t%s\n", (en > 0 ? en : 9999999999), $1, $2, st, en, (src == "" ? "不明" : src), f
}'

# 統計：讀 ev.tsv、au.tsv、jl.tsv，吐出帶標籤的紀錄給兩個輸出端用
#   S 名稱 值 / T 桶序 標籤 Found Ban / J jail Found Ban 被偵測來源 被封來源
#   I IP 封鎖次數 Found 首次 最後 jail / N IP Found 首次 最後（從沒被封）/ U 帳號 來源數 連線數 不存在
RPT_AWK_AN='
function seen(ip, e) {
    if (!(ip in ipfirst) || e < ipfirst[ip]) ipfirst[ip] = e
    if (e > iplast[ip]) iplast[ip] = e
}
function addj(l, j) { return index("," l ",", "," j ",") ? l : (l == "" ? j : l "," j) }
# 白名單（ignoreip）裡的來源是管理員自己，不能算成攻擊者。CIDR 用「除以 2^(32-prefix) 比商」
# 判斷，跟 covers() 同一招（POSIX awk 沒有位元運算）；IPv6 只比完全相同。
function ign(ip,   i, I, x) {
    if (ip in igx) return 1
    if (ip ~ /:/ || ngc == 0) return 0
    split(ip, I, ".")
    x = I[1] * 16777216 + I[2] * 65536 + I[3] * 256 + I[4]
    for (i = 1; i <= ngc; i++) if (int(x / igd[i]) == igb[i]) return 1
    return 0
}
FILENAME ~ /ig\.txt$/ {
    if ($0 ~ /:/) { igx[$0] = 1; next }
    if ($0 ~ /\//) {
        split($0, N, "/"); split(N[1], Bq, ".")
        ngc++; igd[ngc] = 2 ^ (32 - N[2]); igb[ngc] = int((Bq[1] * 16777216 + Bq[2] * 65536 + Bq[3] * 256 + Bq[4]) / igd[ngc])
    } else igx[$0] = 1
    next
}
FILENAME ~ /ev\.tsv$/ {
    e = $1 + 0
    if (!allf || e < allf) allf = e
    if (e < SINCE || e > NOW + 300) next
    if (!f2bf || e < f2bf) f2bf = e
    if (e > f2bl) f2bl = e
    k = int((e + TZOFF) / B); jails[$3] = 1; id = $3 SUBSEP $4
    if ($2 == "F") {
        nf++; bf[k]++; jf[$3]++; ipf[$4]++; seen($4, e)
        if (!(id in jfi)) { jfi[id] = 1; jfips[$3]++ }
    } else if ($2 == "B") {
        nb++; bb[k]++; jb[$3]++; ipb[$4]++; seen($4, e); ipj[$4] = addj(ipj[$4], $3)
        if (!(id in jbi)) { jbi[id] = 1; jbips[$3]++ }
    } else if ($2 == "U") nu++
    else if ($2 == "R") nr++
    else if ($2 == "I") ni++
    next
}
FILENAME ~ /au\.tsv$/ {
    e = $1 + 0
    if (!aallf || e < aallf) aallf = e
    if (e < SINCE || e > NOW + 300) next
    if (ign($4)) { nign++; next }
    if (!auf || e < auf) auf = e
    if (e > aul) aul = e
    u = $2
    if (!((u SUBSEP $4) in uip)) { uip[u SUBSEP $4] = 1; uips[u]++ }
    c = u SUBSEP $5
    if (!(c in uc)) { uc[c] = 1; uconn[u]++; nconn++ }
    # sshd 只要對這個帳號回報過一次「密碼錯誤」而不是「invalid user」，就代表帳號存在
    if ($3 == 0) uinv[u] = 0; else if (!(u in uinv)) uinv[u] = 1
    next
}
FILENAME ~ /un\.tsv$/ {
    e = $1 + 0
    if (e < SINCE || e > NOW + 300) next
    if (ign($3)) { nign++; next }
    xn[$2]++; nx++
    if (!(($2 SUBSEP $3) in xi)) { xi[$2 SUBSEP $3] = 1; xips[$2]++ }
    if (!($3 in xa)) { xa[$3] = 1; nxa++ }
    next
}
FILENAME ~ /jl\.tsv$/ { jails[$1] = 1; next }
END {
    for (ip in xa) if (!(ip in ipf) && !(ip in ipb)) ninvis++
    printf "S\tunseen\t%d\nS\tunseenips\t%d\nS\tinvisible\t%d\nS\tignored\t%d\n", nx, nxa, ninvis, nign
    for (c in xn) printf "X\t%s\t%d\t%d\n", c, xn[c], xips[c]
    for (ip in ipf) { nipf++; if (!(ip in ipb)) { nnever++; if (ipf[ip] >= MAXR) nslow++ } }
    for (ip in ipb) { nipb++; if (ipb[ip] >= 2) nrep++ }
    for (u in uips) nusers++
    printf "S\tfound\t%d\nS\tban\t%d\nS\tunban\t%d\nS\trestore\t%d\nS\tignore\t%d\n", nf, nb, nu, nr, ni
    printf "S\tipf\t%d\nS\tipb\t%d\nS\tnever\t%d\nS\tslow\t%d\nS\trepeat\t%d\n", nipf, nipb, nnever, nslow, nrep
    printf "S\tf2bfirst\t%d\nS\tf2blast\t%d\nS\tf2ballfirst\t%d\n", f2bf, f2bl, allf
    printf "S\taufirst\t%d\nS\taulast\t%d\nS\tauallfirst\t%d\nS\tconns\t%d\nS\tusers\t%d\n", auf, aul, aallf, nconn, nusers
    k0 = int((SINCE + TZOFF) / B); k1 = int((NOW + TZOFF) / B)
    for (k = k0; k <= k1; k++) {
        lab = lt(k * B - TZOFF)
        printf "T\t%d\t%s\t%d\t%d\n", k, (B < 86400 ? substr(lab, 6, 8) : substr(lab, 6, 5)), bf[k], bb[k]
    }
    for (j in jails) printf "J\t%s\t%d\t%d\t%d\t%d\n", j, jf[j], jb[j], jfips[j], jbips[j]
    for (ip in ipb) printf "I\t%s\t%d\t%d\t%d\t%d\t%s\n", ip, ipb[ip], ipf[ip], ipfirst[ip], iplast[ip], ipj[ip]
    for (ip in ipf) if (!(ip in ipb)) printf "N\t%s\t%d\t%d\t%d\n", ip, ipf[ip], ipfirst[ip], iplast[ip]
    for (u in uips) printf "U\t%s\t%d\t%d\t%d\n", u, uips[u], uconn[u], uinv[u]
}'

# 終端機摘要。讀 st.sorted、cur.tsv、jl.tsv
RPT_AWK_TXT='
function xlab(c) {
    return (c == "noid") ? "連上就斷（掃描）" : (c == "preauth") ? "認證前就斷線" : (c == "nego") ? "協商失敗（老舊工具）" : "不是 SSH 的探測"
}
function bar(n, max, w,   k, s) {
    if (max <= 0 || n <= 0) return ""
    k = int(n * w / max + 0.5); if (k < 1) k = 1
    s = ""; while (k-- > 0) s = s BLK
    return s
}
FILENAME ~ /st\.sorted$/ {
    if ($1 == "S") S[$2] = $3
    else if ($1 == "T") { nt++; tl[nt] = $3; tf[nt] = $4; tb[nt] = $5; if ($5 > tmax) tmax = $5 }
    else if ($1 == "J") { nj++; jn[nj] = $2; jfd[nj] = $3; jbn[nj] = $4 }
    else if ($1 == "I") { ni++; iip[ni] = $2; ibn[ni] = $3; ifd[ni] = $4; if ($3 > imax) imax = $3 }
    else if ($1 == "N") { nn++; nip[nn] = $2; nfd[nn] = $3 }
    else if ($1 == "U") { nu++; un[nu] = $2; uipn[nu] = $3; ucn[nu] = $4; uiv[nu] = $5; if ($3 > umax) umax = $3 }
    else if ($1 == "X") { nx++; xc[nx] = $2; xe[nx] = $3; xp[nx] = $4 }
    next
}
FILENAME ~ /cur\.tsv$/ { nc++; cj[nc] = $2; cip[nc] = $3; cen[nc] = $5; cfw[nc] = $7; if ($7 == 1) cok++; next }
FILENAME ~ /jl\.tsv$/ { mr[$1] = $5; ft[$1] = $6; btm[$1] = $7; next }
END {
    printf "\n  範圍  %s ~ %s（%s）\n", substr(lt(SINCE), 1, 16), substr(lt(NOW), 1, 16), RANGE
    printf "  總計  Found %s 次 · Ban %s 次 · 被封過的來源 %s 個（其中 %s 個被封 2 次以上）· 目前封鎖中 %d 個\n", \
        fmtn(S["found"]), fmtn(S["ban"]), fmtn(S["ipb"]), fmtn(S["repeat"]), nc
    if (S["f2ballfirst"] > SINCE) printf "  %s!%s fail2ban 日誌最早只到 %s，範圍前面那段是沒有資料，不是沒有攻擊\n", CY, C0, substr(lt(S["f2ballfirst"]), 1, 16)

    printf "\n  %s1. 時間軸%s  每%s的 Ban 次數（括號是 Found）\n", CB, C0, (B < 86400 ? "小時" : (B < 604800 ? "天" : "週"))
    if (nt > 48) { step = int((nt + 47) / 48) } else step = 1
    for (i = 1; i <= nt; i++) {
        if (B < 86400 && tb[i] == 0 && tf[i] == 0) { quiet++; continue }
        printf "    %-8s %s %s%s  (%s)\n", tl[i], bar(tb[i], tmax, 30), (tb[i] > 0 ? "" : "-"), (tb[i] > 0 ? fmtn(tb[i]) : ""), fmtn(tf[i])
    }
    if (quiet) printf "    %s（另有 %d 個小時完全沒有事件，已略過）%s\n", CD, quiet, C0

    printf "\n  %s2. 偵測與封鎖%s\n", CB, C0
    for (i = 1; i <= nj; i++) {
        if (jbn[i] > 0 && jfd[i] > 0) r = sprintf("每 %.1f 次 Found 換一次 Ban", jfd[i] / jbn[i])
        else if (jbn[i] > 0) r = "Ban 都沒有對應的 Found（手動封鎖，或 Found 在範圍之前）"
        else r = "沒有封鎖"
        printf "    %-18s Found %-7s Ban %-6s %s  %s(maxretry=%s findtime=%s bantime=%s)%s\n", jn[i], fmtn(jfd[i]), fmtn(jbn[i]), r, CD, mr[jn[i]], ft[jn[i]], btm[jn[i]], C0
    }
    if (S["slow"] > 0) printf "    %s!%s %d 個來源累計 Found >= %d 次卻從沒被封：嘗試拉得很開，每個 findtime 視窗都不滿 maxretry（慢速爆破）\n", CY, C0, S["slow"], MAXR
    for (i = 1; i <= nn && i <= 5; i++) if (nfd[i] >= MAXR) printf "      %-40s Found %s 次\n", nip[i], fmtn(nfd[i])

    printf "\n  %s3. 封鎖最多次的來源%s  TOP %d\n", CB, C0, (ni < 10 ? ni : 10)
    for (i = 1; i <= ni && i <= 10; i++)
        printf "    %-40s %s %s 次  (Found %s)\n", iip[i], bar(ibn[i], imax, 20), fmtn(ibn[i]), fmtn(ifd[i])
    if (ni == 0) print "    （範圍內沒有封鎖）"

    printf "\n  %s4. 目前封鎖中%s  %d 個\n", CB, C0, nc
    for (i = 1; i <= nc && i <= 15; i++) {
        if (cen[i] == -1) left = "永久"
        else if (cen[i] == 0) left = "到期時間不明"
        else if (cen[i] <= NOW) left = "已到期，等待解封"
        else left = "還剩 " dur(cen[i] - NOW)
        printf "    %-40s %-16s %s\n", cip[i], cj[i], left
    }
    if (nc > 15) printf "    …另外 %d 個見 HTML\n", nc - 15
    if (SERVER != 1) print "    （fail2ban 伺服器沒有回應，無法取得目前的封鎖清單）"

    printf "\n  %s5. 各 jail%s  ", CB, C0
    if (nj <= 1) printf "只有 %s 一個 jail\n", (nj ? jn[1] : "（無）")
    else { printf "\n"; for (i = 1; i <= nj; i++) printf "    %-18s %s %s\n", jn[i], bar(jbn[i], jbn[1], 20), fmtn(jbn[i]) }

    printf "\n  %s6. 封鎖有沒有真的生效%s  ", CB, C0
    if (SERVER != 1) print "無法比對（伺服器沒有回應）"
    else if (nc == 0) print "目前沒有封鎖中的 IP，無從比對"
    else if (FWOK != 1) print "讀不到防火牆規則，無法比對"
    else if (cok == nc) printf "%s+%s %d/%d 個封鎖中的 IP 都在防火牆規則裡找得到（%s）\n", CG, C0, cok, nc, FWB
    else {
        printf "%sx%s %d 個封鎖中的 IP，防火牆裡只找得到 %d 個（%s）\n", CR, C0, nc, cok, FWB
        for (i = 1; i <= nc; i++) if (cfw[i] == 0) printf "      找不到：%s（%s）\n", cip[i], cj[i]
        print "      封鎖清單有、防火牆沒有 = 封包照樣進得來。原因與修正：" SELF " doctor"
    }
    if (BA != "" && BAREC != "" && BA != BAREC) printf "    %s!%s banaction 是 %s，但這台的防火牆後端是 %s，建議 %s\n", CY, C0, BA, FWB, BAREC

    printf "\n  %s7. 攻擊者試了哪些帳號%s", CB, C0
    if (AUTHSRC == "") print "  讀不到 sshd 認證日誌"
    else {
        printf "  %s 個帳號，TOP %d（依來源數）\n", fmtn(S["users"]), (nu < 10 ? nu : 10)
        for (i = 1; i <= nu && i <= 10; i++)
            printf "    %-20s %s %s 個來源 · %s 次連線%s\n", (un[i] == "" ? "(空白)" : un[i]), bar(uipn[i], umax, 20), fmtn(uipn[i]), fmtn(ucn[i]), (uiv[i] == 1 ? "  （帳號不存在）" : "")
        if (nu == 0) print "    （範圍內沒有人真的送出帳號：沒有 Failed / Invalid user 紀錄）"
        if (S["ignored"] > 0) printf "    %s（已排除白名單來源的 %s 筆紀錄，那是管理員自己）%s\n", CD, fmtn(S["ignored"]), C0
        if (S["unseen"] > 0) {
            printf "\n    %sfail2ban 預設不計的連線%s  %s 次 · %s 個來源（其中 %s 個從沒出現在 fail2ban 的 Found / Ban 裡）\n", \
                CB, C0, fmtn(S["unseen"]), fmtn(S["unseenips"]), fmtn(S["invisible"])
            # 數字在前、標籤在後：中文的寬度各家 awk 算法不同（byte / 字元），拿它來對齊會歪
            for (i = 1; i <= nx; i++) printf "      %6s 次 · %5s 個來源  %s\n", fmtn(xe[i]), fmtn(xp[i]), xlab(xc[i])
            if (MODE == "normal")
                print "      sshd jail 是 mode=normal：這些都不計數。改 aggressive 會算進去，但監控系統檢查 SSH 埠的連線也會被封"
            else
                printf "      sshd jail 是 mode=%s：其中會計數的已經算進上面的 Found\n", MODE
        }
    }
}'

# HTML 報告。讀 st.sorted、cur.tsv、jl.tsv；配色與標記規格見 FAIL2BAN/README.md 的「報告」一節
RPT_AWK_HTML='
# Y 軸刻度間隔：1 / 2 / 5 × 10^n，約 4 格。刻度一律是間隔的整數倍，
# 不能「最大值切 4 等分」——最大值 6 時會變成 0 / 1.5 / 3 / 4.5 / 6，取整之後標籤就錯了。
function nstep(m,   raw, p, f) {
    if (m <= 5) return 1
    raw = m / 4; p = 1
    while (p * 10 <= raw) p *= 10
    f = raw / p
    return ((f <= 1) ? 1 : (f <= 2) ? 2 : (f <= 5) ? 5 : 10) * p
}
function colbar(x, y, w, h, cls, r) {
    if (h <= 0) return ""
    r = (w < 8) ? w / 2 : 4; if (r > h) r = h
    return sprintf("<path class=\"%s\" d=\"M%.1f,%.1fV%.1fQ%.1f,%.1f %.1f,%.1fH%.1fQ%.1f,%.1f %.1f,%.1fV%.1fZ\"/>", \
        cls, x, y + h, y + r, x, y, x + r, y, x + w - r, x + w, y, x + w, y + r, y + h)
}
# 橫條 + 數值。長條只佔「欄寬扣掉數值」的比例，最長的那條也不會把數字擠到下一行
function hbar(n, max, cls,   f) {
    f = (max > 0 && n > 0) ? n / max : 0
    return sprintf("<div class=\"hb\"><span class=\"bar %s\" style=\"width:calc((100%% - 4.5em) * %.4f)\"></span><span class=\"v\">%s</span></div>", cls, f, fmtn(n))
}
function tile(lab, val, hint) {
    printf "<div class=\"tile\"><div class=\"lab\">%s</div><div class=\"val\">%s</div><div class=\"hint\">%s</div></div>\n", lab, val, hint
}
function ts16(e) { return (e > 0) ? substr(lt(e), 1, 16) : "—" }
FILENAME ~ /st\.sorted$/ {
    if ($1 == "S") S[$2] = $3
    else if ($1 == "T") { nt++; tl[nt] = $3; tf[nt] = $4; tb[nt] = $5; if ($4 > tmax) tmax = $4; if ($5 > tmax) tmax = $5 }
    else if ($1 == "J") { nj++; jn[nj] = $2; jfd[nj] = $3; jbn[nj] = $4; jfi[nj] = $5; jbi[nj] = $6; if ($4 > jmax) jmax = $4 }
    else if ($1 == "I") { ni++; iip[ni] = $2; ibn[ni] = $3; ifd[ni] = $4; ifs[ni] = $5; ila[ni] = $6; ijl[ni] = $7; if ($3 > imax) imax = $3 }
    else if ($1 == "N") { nn++; nip[nn] = $2; nfd[nn] = $3; nfs[nn] = $4; nla[nn] = $5; if ($3 > nmax) nmax = $3 }
    else if ($1 == "U") { nu++; un[nu] = $2; uipn[nu] = $3; ucn[nu] = $4; uiv[nu] = $5; if ($3 > umax) umax = $3 }
    else if ($1 == "X") { nx++; xc[nx] = $2; xe[nx] = $3; xp[nx] = $4; if ($3 > xmax) xmax = $3 }
    next
}
FILENAME ~ /cur\.tsv$/ { nc++; cj[nc] = $2; cip[nc] = $3; cst[nc] = $4; cen[nc] = $5; csrc[nc] = $6; cfw[nc] = $7; if ($7 == 1) cok++; next }
FILENAME ~ /jl\.tsv$/ { mr[$1] = $5; ft[$1] = $6; btm[$1] = $7; jcur[$1] = $2; next }
END {
    unit = (B < 86400) ? "小時" : (B < 604800 ? "天" : "週")
    print "<!doctype html>"
    print "<html lang=\"zh-Hant\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
    printf "<title>fail2ban 報告 · %s</title>\n", esc(HOST)
    print "<style>"
    print ":root{color-scheme:light;--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,.10);--s1:#2a78d6;--s2:#eb6834;--track:#cde2fb;--good:#0ca30c;--bad:#d03b3b;--warn:#fab219}"
    print "@media (prefers-color-scheme:dark){:root{color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;--ink:#fff;--ink2:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,.10);--s1:#3987e5;--s2:#d95926;--track:#184f95}}"
    print "*{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--ink);font:14px/1.55 system-ui,-apple-system,\"Segoe UI\",\"Noto Sans TC\",\"Microsoft JhengHei\",sans-serif}"
    print "main{max-width:1080px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:0 0 4px}h3{font-size:14px;margin:16px 0 4px}"
    print ".sub,.note{color:var(--ink2);margin:4px 0 10px}.note b{color:var(--ink)}"
    print "section{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:16px 18px;margin-top:16px}"
    print ".tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-top:16px}"
    print ".tile{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:12px 14px}.tile .lab{color:var(--ink2);font-size:13px}.tile .val{font-size:26px;font-weight:600;line-height:1.3}.tile .hint{color:var(--muted);font-size:12px}"
    print ".legend{display:flex;flex-wrap:wrap;gap:16px;color:var(--ink2);font-size:13px;margin:6px 0}.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}"
    print ".scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13px}th{text-align:left;color:var(--ink2);font-weight:500;border-bottom:1px solid var(--axis);padding:6px 8px;white-space:nowrap}"
    print "td{border-bottom:1px solid var(--grid);padding:6px 8px;vertical-align:middle}td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:nowrap}"
    print ".bc{width:34%;min-width:160px}.hb{display:flex;align-items:center;gap:6px}.hb .v{font-variant-numeric:tabular-nums;white-space:nowrap}"
    print ".bar{display:inline-block;height:10px;min-width:2px;border-radius:0 4px 4px 0;flex:none}.b1{background:var(--s1)}.b2{background:var(--s2)}"
    print ".path{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all;min-width:18em}.scroll svg{min-width:640px}"
    print ".meter{display:inline-block;width:110px;height:8px;border-radius:4px;background:var(--track);vertical-align:middle;margin-right:8px;overflow:hidden}.meter i{display:block;height:100%;background:var(--s1)}"
    print ".f{fill:var(--s1)}.b{fill:var(--s2)}.g{stroke:var(--grid)}.a{stroke:var(--axis)}svg text{fill:var(--muted);font-size:11px;font-family:inherit}svg .hit{fill:transparent}svg g:hover .hit{fill:var(--grid);opacity:.5}"
    print ".st{font-size:15px;font-weight:600;margin:4px 0}.ic{display:inline-block;width:18px;height:18px;border-radius:50%;color:#fff;text-align:center;line-height:18px;font-size:12px;margin-right:6px}.ic.ok{background:var(--good)}.ic.no{background:var(--bad)}.ic.wa{background:var(--warn);color:#0b0b0b}"
    print ".tag{font-size:12px;color:var(--ink2);border:1px solid var(--border);border-radius:4px;padding:0 5px;white-space:nowrap}details{margin-top:8px;color:var(--ink2)}summary{cursor:pointer}footer{color:var(--muted);font-size:12px;margin-top:16px}"
    print "</style></head><body><main>"

    printf "<h1>fail2ban 做了哪些事</h1>\n<p class=\"sub\"><b>%s</b> · 範圍 %s ~ %s（%s）· 產生於 %s</p>\n", esc(HOST), ts16(SINCE), ts16(NOW), RANGE, ts16(NOW)
    if (S["f2ballfirst"] > SINCE)
        printf "<p class=\"note\"><span class=\"ic wa\">!</span>fail2ban 日誌最早只到 <b>%s</b>，範圍前面那段是<b>沒有資料</b>，不是沒有攻擊。</p>\n", ts16(S["f2ballfirst"])

    print "<div class=\"tiles\">"
    tile("偵測到失敗（Found）", fmtn(S["found"]), fmtn(S["ipf"]) " 個來源")
    tile("封鎖（Ban）", fmtn(S["ban"]), fmtn(S["ipb"]) " 個來源被封過")
    tile("被封 2 次以上", fmtn(S["repeat"]), "個來源一再回來")
    tile("目前封鎖中", (SERVER == 1 ? nc + 0 : "—"),(SERVER == 1 ? "fail2ban-client status" : "伺服器沒有回應"))
    if (SERVER != 1 || nc == 0 || FWOK != 1) fwv = "—"
    else fwv = (cok == nc) ? "<span class=\"ic ok\">✓</span>" (cok + 0) "/" nc : "<span class=\"ic no\">✗</span>" (cok + 0) "/" nc
    tile("防火牆裡找得到", fwv, esc(FWB))
    print "</div>"

    # ---- 1. 時間軸 ----
    printf "<section><h2>1. 時間軸</h2><p class=\"note\">每%s偵測到幾次失敗（Found）、封了幾次（Ban）。滑過長條看數字，完整數字在下方表格。</p>\n", unit
    print "<div class=\"legend\"><span><i class=\"sw\" style=\"background:var(--s1)\"></i>Found</span><span><i class=\"sw\" style=\"background:var(--s2)\"></i>Ban</span></div>"
    W = 960; H = 240; L = 48; R = 8; T = 10; BOT = 26; pw = W - L - R; ph = H - T - BOT
    ystep = nstep(tmax); top = ystep * int((tmax + ystep - 1) / ystep); if (top < ystep) top = ystep
    gw = (nt > 0) ? pw / nt : pw
    bw = (gw - 6) / 2; if (bw > 24) bw = 24; if (bw < 1) bw = 1
    printf "<div class=\"scroll\"><svg viewBox=\"0 0 %d %d\" width=\"100%%\" role=\"img\" aria-label=\"每%s Found 與 Ban 次數\">\n", W, H, unit
    for (v = 0; v <= top; v += ystep) {
        y = T + ph - ph * v / top
        printf "<line class=\"%s\" x1=\"%d\" x2=\"%d\" y1=\"%.1f\" y2=\"%.1f\"/><text x=\"%d\" y=\"%.1f\" text-anchor=\"end\">%s</text>\n", (v == 0 ? "a" : "g"), L, W - R, y, y, L - 6, y + 4, fmtn(v)
    }
    lstep = int((nt + 11) / 12); if (lstep < 1) lstep = 1
    for (i = 1; i <= nt; i++) {
        gx = L + (i - 1) * gw; cx = gx + gw / 2
        hf = ph * tf[i] / top; hb = ph * tb[i] / top
        printf "<g><title>%s：Found %s 次，Ban %s 次</title><rect class=\"hit\" x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\"/>", tl[i], fmtn(tf[i]), fmtn(tb[i]), gx, T, gw, ph
        printf "%s%s</g>\n", colbar(cx - bw - 1, T + ph - hf, bw, hf, "f"), colbar(cx + 1, T + ph - hb, bw, hb, "b")
        if ((i - 1) % lstep == 0) printf "<text x=\"%.1f\" y=\"%d\" text-anchor=\"middle\">%s</text>\n", cx, H - 8, tl[i]
    }
    print "</svg></div>"
    printf "<details><summary>表格檢視</summary><div class=\"scroll\"><table><tr><th>時間（每%s）</th><th>Found</th><th>Ban</th></tr>\n", unit
    for (i = 1; i <= nt; i++) printf "<tr><td class=\"mono\">%s</td><td class=\"n\">%s</td><td class=\"n\">%s</td></tr>\n", tl[i], fmtn(tf[i]), fmtn(tb[i])
    print "</table></div></details></section>"

    # ---- 2. 偵測與封鎖 ----
    print "<section><h2>2. 偵測與封鎖</h2>"
    if (S["ban"] > 0 && S["found"] == 0)
        print "<p class=\"note\">範圍內的 Ban <b>都沒有對應的 Found</b>：是手動封鎖（<code>fail2ban.sh ban</code>），或觸發它們的 Found 在範圍之前。</p>"
    else if (S["ban"] > 0)
        printf "<p class=\"note\">平均 <b>每 %.1f 次 Found 換到一次 Ban</b>。maxretry 是 %d 時，接近 %d 代表攻擊者多半一口氣打到被封；遠大於 %d 代表很多來源試了幾次就走，或是把嘗試拉開的慢速爆破。</p>\n", S["found"] / S["ban"], MAXR, MAXR, MAXR
    print "<div class=\"scroll\"><table><tr><th>jail</th><th>Found</th><th>Ban</th><th>被偵測的來源</th><th>被封的來源</th><th>設定</th></tr>"
    for (i = 1; i <= nj; i++)
        printf "<tr><td class=\"mono\">%s</td><td class=\"n\">%s</td><td class=\"n\">%s</td><td class=\"n\">%s</td><td class=\"n\">%s</td><td><span class=\"tag\">maxretry %s · findtime %s · bantime %s</span></td></tr>\n", \
            esc(jn[i]), fmtn(jfd[i]), fmtn(jbn[i]), fmtn(jfi[i]), fmtn(jbi[i]), esc(mr[jn[i]]), esc(ft[jn[i]]), esc(btm[jn[i]])
    print "</table></div>"
    printf "<h3>只被偵測、從沒被封的來源（%s 個）</h3>\n", fmtn(S["never"])
    if (S["slow"] > 0)
        printf "<p class=\"note\"><span class=\"ic wa\">!</span>其中 <b>%d 個</b>累計 Found 已經 ≥ %d 次卻從沒被封：它們把嘗試拉得很開，每個 findtime 視窗裡都不滿 maxretry。這是慢速爆破的特徵，預設設定抓不到（見 README「一個 IP 走一遍」）。</p>\n", S["slow"], MAXR
    if (nn == 0) print "<p class=\"note\">沒有。</p>"
    else {
        print "<div class=\"scroll\"><table><tr><th>來源</th><th class=\"bc\">Found 次數</th><th>首次</th><th>最後</th></tr>"
        for (i = 1; i <= nn; i++)
            printf "<tr><td class=\"mono\">%s</td><td>%s</td><td class=\"mono\">%s</td><td class=\"mono\">%s</td></tr>\n", esc(nip[i]), hbar(nfd[i], nmax, "b1"), ts16(nfs[i]), ts16(nla[i])
        print "</table></div>"
    }
    print "</section>"

    # ---- 3. 慣犯 ----
    printf "<section><h2>3. 封鎖最多次的來源</h2><p class=\"note\">%s 個來源被封過，其中 <b>%s 個被封 2 次以上</b>。封鎖到期就完全放行、回來重新計數，所以同一個 IP 被封很多次代表它一直回來，不是封鎖沒效。</p>\n", fmtn(S["ipb"]), fmtn(S["repeat"])
    if (ni == 0) print "<p class=\"note\">範圍內沒有封鎖。</p>"
    else {
        print "<div class=\"scroll\"><table><tr><th>來源</th><th class=\"bc\">封鎖次數</th><th>Found</th><th>首次</th><th>最後</th><th>jail</th></tr>"
        for (i = 1; i <= ni; i++)
            printf "<tr><td class=\"mono\">%s</td><td>%s</td><td class=\"n\">%s</td><td class=\"mono\">%s</td><td class=\"mono\">%s</td><td class=\"mono\">%s</td></tr>\n", \
                esc(iip[i]), hbar(ibn[i], imax, "b2"), fmtn(ifd[i]), ts16(ifs[i]), ts16(ila[i]), esc(ijl[i])
        print "</table></div>"
    }
    print "</section>"

    # ---- 4. 目前封鎖中 ----
    printf "<section><h2>4. 目前封鎖中</h2>"
    if (SERVER != 1) print "<p class=\"note\">fail2ban 伺服器沒有回應，無法取得目前的封鎖清單。</p></section>"
    else if (nc == 0) print "<p class=\"note\">目前沒有封鎖中的 IP。</p></section>"
    else {
        printf "<p class=\"note\">%d 個，依到期時間排序。長條是剩餘時間佔整段封鎖的比例。</p>\n", nc
        print "<div class=\"scroll\"><table><tr><th>來源</th><th>jail</th><th>封鎖於</th><th>剩餘</th><th>到期</th><th>防火牆</th><th>時間來源</th></tr>"
        for (i = 1; i <= nc; i++) {
            if (cen[i] == -1) { left = "<span class=\"tag\">永久</span>"; exp_ = "—" }
            else if (cen[i] == 0) { left = "不明"; exp_ = "—" }
            else if (cen[i] <= NOW) { left = "已到期，等待解封"; exp_ = ts16(cen[i]) }
            else {
                fr = (cen[i] > cst[i]) ? (cen[i] - NOW) / (cen[i] - cst[i]) : 0
                if (fr < 0) fr = 0; if (fr > 1) fr = 1
                left = sprintf("<span class=\"meter\"><i style=\"width:%.0f%%\"></i></span>%s", fr * 100, dur(cen[i] - NOW)); exp_ = ts16(cen[i])
            }
            fwc = (cfw[i] == 1) ? "<span class=\"ic ok\">✓</span>找得到" : (cfw[i] == 0) ? "<span class=\"ic no\">✗</span>找不到" : "—"
            printf "<tr><td class=\"mono\">%s</td><td class=\"mono\">%s</td><td class=\"mono\">%s</td><td>%s</td><td class=\"mono\">%s</td><td>%s</td><td>%s</td></tr>\n", \
                esc(cip[i]), esc(cj[i]), ts16(cst[i]), left, exp_, fwc, esc(csrc[i])
        }
        print "</table></div></section>"
    }

    # ---- 5. 各 jail ----
    print "<section><h2>5. 各 jail 的封鎖分布</h2>"
    if (nj <= 1) printf "<p class=\"note\">只有 <b>%s</b> 一個 jail。</p>\n", (nj ? esc(jn[1]) : "（無）")
    else {
        print "<div class=\"scroll\"><table><tr><th>jail</th><th class=\"bc\">Ban</th><th>目前封鎖中</th></tr>"
        for (i = 1; i <= nj; i++) printf "<tr><td class=\"mono\">%s</td><td>%s</td><td class=\"n\">%s</td></tr>\n", esc(jn[i]), hbar(jbn[i], jmax, "b2"), esc(jcur[jn[i]])
        print "</table></div>"
    }
    print "</section>"

    # ---- 6. 防火牆 ----
    printf "<section><h2>6. 封鎖有沒有真的生效</h2><p class=\"note\">fail2ban 說封了的 IP，拿去防火牆規則裡實際找（%s，banaction %s）。服務顯示綠燈不代表有在擋。</p>\n", esc(FWB), (BA == "" ? "未明寫，沿用預設" : esc(BA))
    if (SERVER != 1) print "<p class=\"st\"><span class=\"ic wa\">!</span>無法比對：fail2ban 伺服器沒有回應</p>"
    else if (nc == 0) print "<p class=\"st\"><span class=\"ic wa\">!</span>目前沒有封鎖中的 IP，無從比對</p>"
    else if (FWOK != 1) print "<p class=\"st\"><span class=\"ic wa\">!</span>讀不到防火牆規則，無法比對</p>"
    else if (cok == nc) printf "<p class=\"st\"><span class=\"ic ok\">✓</span>%d/%d 個封鎖中的 IP 都在防火牆規則裡找得到</p>\n", cok, nc
    else {
        printf "<p class=\"st\"><span class=\"ic no\">✗</span>%d 個封鎖中的 IP，防火牆裡只找得到 %d 個</p>\n", nc, cok
        print "<p class=\"note\">封鎖清單有、防火牆沒有，就是封包照樣進得來。常見原因：banaction 與防火牆後端不符、防火牆被 reload 把規則沖掉（fail2ban 不會自己補，要重啟 fail2ban 從資料庫還原）。執行 <code>fail2ban.sh doctor</code> 會直接指出是哪一種。</p><ul>"
        for (i = 1; i <= nc; i++) if (cfw[i] == 0) printf "<li class=\"mono\">%s（%s）</li>\n", esc(cip[i]), esc(cj[i])
        print "</ul>"
    }
    if (BA != "" && BAREC != "" && BA != BAREC)
        printf "<p class=\"note\"><span class=\"ic wa\">!</span>banaction 是 <b>%s</b>，但這台的防火牆後端是 %s，建議改成 <b>%s</b>（重跑 <code>fail2ban.sh enable-sshd</code>）。</p>\n", esc(BA), esc(FWB), esc(BAREC)
    print "</section>"

    # ---- 7. 帳號 ----
    print "<section><h2>7. 攻擊者試了哪些帳號</h2>"
    if (AUTHSRC == "") print "<p class=\"note\">讀不到 sshd 認證日誌。</p>"
    else {
        printf "<p class=\"note\">%s 個不同的帳號、%s 次連線。依<b>試過它的來源數</b>排序；同一條連線寫的好幾行只算一次。「不存在」是 sshd 回報這台沒有這個帳號。</p>\n", fmtn(S["users"]), fmtn(S["conns"])
        if (nu > 0) {
            print "<div class=\"scroll\"><table><tr><th>帳號</th><th class=\"bc\">來源數</th><th>連線數</th><th></th></tr>"
            for (i = 1; i <= nu; i++)
                printf "<tr><td class=\"mono\">%s</td><td>%s</td><td class=\"n\">%s</td><td>%s</td></tr>\n", (un[i] == "" ? "（空白）" : esc(un[i])), hbar(uipn[i], umax, "b1"), fmtn(ucn[i]), (uiv[i] == 1 ? "<span class=\"tag\">不存在</span>" : "")
            print "</table></div>"
        } else print "<p class=\"note\">範圍內沒有人真的送出帳號（沒有 Failed / Invalid user 紀錄）。</p>"
        if (S["ignored"] > 0) printf "<p class=\"note\">已排除白名單（ignoreip）來源的 %s 筆紀錄——那是管理員自己，不算攻擊者。</p>\n", fmtn(S["ignored"])
        if (S["unseen"] > 0) {
            printf "<h3>fail2ban 預設不計的連線（%s 次 · %s 個來源）</h3>\n", fmtn(S["unseen"]), fmtn(S["unseenips"])
            if (MODE == "normal")
                printf "<p class=\"note\"><span class=\"ic wa\">!</span>這台的 sshd jail 是 <b>mode=normal</b>：只數「真的送出帳號或密碼」的失敗。下面這些連線<b>一次都不會算進 Found</b>，其中 <b>%s 個來源從沒出現在 fail2ban 的 Found / Ban 裡</b>——對 fail2ban 來說它們是隱形的。改成 <code>mode = aggressive</code> 會把它們算進去，代價是監控系統定期檢查 SSH 埠的連線也會被當成失敗而封鎖。</p>\n", fmtn(S["invisible"])
            else
                printf "<p class=\"note\">這台的 sshd jail 是 <b>mode=%s</b>，其中會計數的已經算進上面的 Found。</p>\n", esc(MODE)
            print "<div class=\"scroll\"><table><tr><th>類型</th><th class=\"bc\">次數</th><th>來源數</th><th>sshd 的紀錄長這樣</th></tr>"
            for (i = 1; i <= nx; i++) {
                c = xc[i]
                lab = (c == "noid") ? "連上就斷（掃描）" : (c == "preauth") ? "認證前就斷線" : (c == "nego") ? "協商失敗（老舊工具）" : "不是 SSH 的探測"
                smp = (c == "noid") ? "Did not receive identification string" : (c == "preauth") ? "Connection closed by … [preauth]" : (c == "nego") ? "Unable to negotiate with …" : "Bad protocol version identification"
                printf "<tr><td>%s</td><td>%s</td><td class=\"n\">%s</td><td class=\"mono\">%s</td></tr>\n", lab, hbar(xe[i], xmax, "b1"), fmtn(xp[i]), smp
            }
            print "</table></div>"
        }
    }
    print "</section>"

    # ---- 資料來源 ----
    print "<section><h2>資料來源</h2><div class=\"scroll\"><table><tr><th>來源</th><th>用在</th><th>範圍內的資料</th><th>最早可讀到</th></tr>"
    printf "<tr><td class=\"path\">%s</td><td>1 · 2 · 3 · 5</td><td class=\"mono\">%s ~ %s</td><td class=\"mono\">%s</td></tr>\n", (F2BSRC == "" ? "（讀不到）" : esc(F2BSRC)), ts16(S["f2bfirst"]), ts16(S["f2blast"]), ts16(S["f2ballfirst"])
    if (DBSRC == "-")
        print "<tr><td class=\"path\">sqlite 資料庫</td><td>4</td><td colspan=\"2\">目前沒有封鎖中的 IP，不需要讀取</td></tr>"
    else
        printf "<tr><td class=\"path\">%s</td><td>4</td><td colspan=\"2\">%s</td></tr>\n", (DBSRC == "" ? "（讀不到資料庫）" : esc(DBSRC)), (DBSRC == "" ? "到期時間改用日誌的 Ban 時間 + jail 的 bantime" : "目前封鎖中的封鎖時間與長度")
    printf "<tr><td class=\"path\">%s</td><td>6</td><td colspan=\"2\">%s</td></tr>\n", esc(FWB), (FWOK == 1 ? "iptables / nftables / ipset / firewalld 規則" : "沒有讀取")
    printf "<tr><td class=\"path\">%s</td><td>7</td><td class=\"mono\">%s ~ %s</td><td class=\"mono\">%s</td></tr>\n", (AUTHSRC == "" ? "（讀不到）" : esc(AUTHSRC)), ts16(S["aufirst"]), ts16(S["aulast"]), ts16(S["auallfirst"])
    print "</table></div></section>"
    printf "<footer>由 OPS-command <span class=\"mono\">fail2ban.sh report</span> 產生（fail2ban %s）。產生過程全程唯讀，沒有改動任何設定。</footer>\n", esc(VER)
    print "</main></body></html>"
}'

cmd_report() {
    need_root
    case "$REPORT_DAYS" in
        all) : ;;
        ''|*[!0-9]*|0) die "--days 要是正整數或 all：$REPORT_DAYS" ;;
    esac
    _tmp=$(mktemp -d 2>/dev/null) || { _tmp="/tmp/f2b-report.$$"; mkdir -p "$_tmp" || die "無法建立暫存目錄"; }
    chmod 700 "$_tmp" 2>/dev/null
    trap 'rm -rf "$_tmp"' EXIT
    trap 'rm -rf "$_tmp"; exit 130' HUP INT TERM
    TAB=$(printf '\t')
    _now=$(date +%s)
    _tz=$(rpt_tzoff)
    _host=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo host)

    step "fail2ban 報告：收集資料（唯讀）"

    # ---- fail2ban 日誌：含輪替檔；沒有檔案才退回 journal ----
    _f2bsrc=''
    : > "$_tmp/f2b.raw"
    for _f in "${PREFIX}"/var/log/fail2ban.log*; do
        [ -f "$_f" ] || continue
        rpt_cat "$_f" >> "$_tmp/f2b.raw"
        _f2bsrc="$_f2bsrc $(basename "$_f")"
    done
    if [ ! -s "$_tmp/f2b.raw" ] && has journalctl; then
        journalctl -u "$F2B_SVC" --no-pager -q -o short-iso 2>/dev/null > "$_tmp/f2b.raw"
        [ -s "$_tmp/f2b.raw" ] && _f2bsrc="journal（-u $F2B_SVC）"
    fi
    [ -n "$_f2bsrc" ] && _f2bsrc="${_f2bsrc# }"
    [ -n "$_f2bsrc" ] && case "$_f2bsrc" in journal*) : ;; *) _f2bsrc="${PREFIX}/var/log/ 的 $_f2bsrc" ;; esac
    awk -v TZOFF="$_tz" "$RPT_AWK_LIB$RPT_AWK_F2B" "$_tmp/f2b.raw" > "$_tmp/ev.tsv"
    info "fail2ban 日誌：${_f2bsrc:-讀不到}（$(cnt . "$_tmp/ev.tsv") 筆事件）"

    # ---- 範圍 ----
    if [ "$REPORT_DAYS" = all ]; then
        _since=$(awk -F"$TAB" 'NR == 1 || $1 < m { m = $1 } END { print m + 0 }' "$_tmp/ev.tsv")
        [ "${_since:-0}" -gt 0 ] || _since=$((_now - 7 * 86400))
        _range='全部'
    else
        _since=$((_now - REPORT_DAYS * 86400))
        _range="最近 $REPORT_DAYS 天"
    fi
    _span=$((_now - _since))
    if   [ "$_span" -le 172800 ];   then _bucket=3600
    elif [ "$_span" -le 10368000 ]; then _bucket=86400
    else                                 _bucket=604800
    fi

    # ---- sshd 認證日誌：/var/log/secure*、auth.log*；都沒有就退回 journal ----
    _ausrc=''
    : > "$_tmp/auth.raw"
    for _f in "${PREFIX}"/var/log/secure* "${PREFIX}"/var/log/auth.log*; do
        [ -f "$_f" ] || continue
        rpt_cat "$_f" >> "$_tmp/auth.raw"
        _ausrc="$_ausrc $(basename "$_f")"
    done
    if [ ! -s "$_tmp/auth.raw" ] && has journalctl; then
        _sts=$(awk -v TZOFF="$_tz" -v E="$_since" "$RPT_AWK_LIB"'BEGIN { print lt(E) }')
        journalctl _COMM=sshd --no-pager -q -o short-iso --since "$_sts" 2>/dev/null > "$_tmp/auth.raw"
        [ -s "$_tmp/auth.raw" ] && _ausrc=' journal（sshd）'
    fi
    _ausrc="${_ausrc# }"
    [ -n "$_ausrc" ] && case "$_ausrc" in journal*) : ;; *) _ausrc="${PREFIX}/var/log/ 的 $_ausrc" ;; esac
    : > "$_tmp/un.tsv"
    awk -v TZOFF="$_tz" -v NOWY="$(date +%Y)" -v NOWM="$(date +%m | sed 's/^0//')" -v UNSEEN="$_tmp/un.tsv" \
        "$RPT_AWK_LIB$RPT_AWK_AUTH" "$_tmp/auth.raw" > "$_tmp/au.tsv"
    rm -f "$_tmp/f2b.raw" "$_tmp/auth.raw"
    info "認證日誌    ：${_ausrc:-讀不到}（$(cnt . "$_tmp/au.tsv") 筆）"

    # ---- jail 與目前的封鎖：要伺服器活著 ----
    : > "$_tmp/jl.tsv"; : > "$_tmp/cb.tsv"
    _server=0
    if f2b_ping; then
        _server=1
        for _j in $(jails); do
            _g() { _v=$(fail2ban-client get "$_j" "$1" 2>/dev/null | tail -1 | tr -d ' \t\r'); case "$_v" in ''|*[!0-9-]*) echo '?' ;; *) echo "$_v" ;; esac; }
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_j" \
                "$(jail_num "$_j" 'Currently banned')" "$(jail_num "$_j" 'Total banned')" "$(jail_num "$_j" 'Currently failed')" \
                "$(_g maxretry)" "$(_g findtime)" "$(_g bantime)" >> "$_tmp/jl.tsv"
            jail_banned "$_j" | sed "s/^/$_j$TAB/" >> "$_tmp/cb.tsv"
        done
    else
        warn "fail2ban 伺服器沒有回應 — 「目前封鎖中」與防火牆比對會略過，其餘照日誌算"
        cut -f3 "$_tmp/ev.tsv" | sort -u | while read -r _j; do
            printf '%s\t?\t?\t?\t?\t?\t?\n' "$_j"
        done > "$_tmp/jl.tsv"
    fi
    _maxr=$(awk -F"$TAB" '$1 == "sshd" && $5 ~ /^[0-9]+$/ { print $5; f = 1; exit } END { if (!f) print "" }' "$_tmp/jl.tsv")
    [ -n "$_maxr" ] || _maxr=$(awk -F"$TAB" '$5 ~ /^[0-9]+$/ { print $5; exit }' "$_tmp/jl.tsv")
    [ -n "$_maxr" ] || _maxr=5

    # ---- 資料庫：到期時間。sqlite3 CLI -> fail2ban 自己的 python ----
    : > "$_tmp/db.tsv"
    _dbsrc=''
    _db=$(fail2ban-client get dbfile 2>/dev/null | sed -n 's/^.*- *\(\/.*\)$/\1/p' | tail -1)
    [ -n "$_db" ] || _db="${PREFIX}/var/lib/fail2ban/fail2ban.sqlite3"
    if [ -s "$_tmp/cb.tsv" ] && [ -r "$_db" ]; then
        _q='SELECT jail, ip, MAX(timeofban), bantime FROM bans GROUP BY jail, ip;'
        _q2='SELECT jail, ip, MAX(timeofban), -2 FROM bans GROUP BY jail, ip;'   # 0.10 之前沒有 bantime 欄
        if has sqlite3; then
            sqlite3 -separator "$TAB" "$_db" "$_q" > "$_tmp/db.tsv" 2>/dev/null ||
                sqlite3 -separator "$TAB" "$_db" "$_q2" > "$_tmp/db.tsv" 2>/dev/null
        fi
        if [ ! -s "$_tmp/db.tsv" ]; then
            _py=$(head -1 "$(command -v fail2ban-client)" 2>/dev/null | sed -n 's/^#! *//p')
            case "$_py" in *env\ *) _py=${_py#*env } ;; esac
            _py=${_py%% *}
            if [ -n "$_py" ] && "$_py" -c 'import sqlite3' 2>/dev/null; then
                "$_py" - "$_db" > "$_tmp/db.tsv" 2>/dev/null <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
try:
    rows = c.execute("SELECT jail, ip, MAX(timeofban), bantime FROM bans GROUP BY jail, ip").fetchall()
except Exception:
    rows = [tuple(r) + (-2,) for r in c.execute("SELECT jail, ip, MAX(timeofban) FROM bans GROUP BY jail, ip").fetchall()]
for r in rows:
    sys.stdout.write("%s\t%s\t%s\t%s\n" % tuple(r))
PY
            fi
        fi
        [ -s "$_tmp/db.tsv" ] && _dbsrc="$_db"
    fi
    # 沒有封鎖中的 IP 時根本不需要資料庫——跟「這台沒有資料庫」是兩回事，報告上要分得出來
    [ -s "$_tmp/cb.tsv" ] || _dbsrc='-'

    # ---- 防火牆：把所有後端的規則倒出來，逐一找封鎖中的 IP ----
    : > "$_tmp/fw.txt"
    _fwok=0
    _fwb=$(fw_backend)
    if [ -s "$_tmp/cb.tsv" ]; then
        {
            has iptables-save  && iptables-save 2>/dev/null
            has ip6tables-save && ip6tables-save 2>/dev/null
            has nft            && nft list ruleset 2>/dev/null
            has ipset          && ipset list 2>/dev/null
            if [ "$_fwb" = firewalld ]; then
                firewall-cmd --list-all-zones 2>/dev/null
                firewall-cmd --direct --get-all-rules 2>/dev/null
            fi
        } > "$_tmp/fw.txt"
        [ -s "$_tmp/fw.txt" ] && _fwok=1
    fi
    awk -F"$TAB" -v FWOK="$_fwok" \
        "$RPT_AWK_CUR" "$_tmp/db.tsv" "$_tmp/ev.tsv" "$_tmp/jl.tsv" "$_tmp/fw.txt" "$_tmp/cb.tsv" |
        sort -t "$TAB" -k1,1n > "$_tmp/cur.tsv"      # 第 1 欄是排序鍵，兩個輸出端都照這個欄位順序讀

    # ---- 統計 ----
    ignore_effective 2>/dev/null | sort -u > "$_tmp/ig.txt"
    awk -F"$TAB" -v NOW="$_now" -v SINCE="$_since" -v B="$_bucket" -v TZOFF="$_tz" -v MAXR="$_maxr" \
        "$RPT_AWK_LIB$RPT_AWK_AN" "$_tmp/ig.txt" "$_tmp/ev.tsv" "$_tmp/au.tsv" "$_tmp/un.tsv" "$_tmp/jl.tsv" > "$_tmp/st.raw"

    # sshd jail 的 filter 模式：決定上面那些「不計數的連線」到底有沒有被算進去。
    # 取 [sshd] 的 mode，沒寫就看 [DEFAULT]，都沒有就是 fail2ban 的預設 normal。
    _mode=normal
    _jf=''
    for _f in "${F2B_ETC}/jail.conf" "${F2B_ETC}/jail.local" "${F2B_JAILD}"/*.conf "${F2B_JAILD}"/*.local; do
        [ -f "$_f" ] && _jf="$_jf $_f"
    done
    if [ -n "$_jf" ]; then
        # shellcheck disable=SC2086
        _mode=$(awk '
            /^[[:space:]]*\[/ { sec = $0; gsub(/[][[:space:]]/, "", sec) }
            (sec == "sshd" || sec == "DEFAULT") && /^[[:space:]]*mode[[:space:]]*=/ {
                v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); m[sec] = v }
            END { print (m["sshd"] != "" ? m["sshd"] : (m["DEFAULT"] != "" ? m["DEFAULT"] : "normal")) }' $_jf)
    fi
    {
        grep "^S$TAB" "$_tmp/st.raw"
        grep "^T$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k2,2n
        grep "^J$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k4,4nr -k3,3nr
        grep "^I$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k3,3nr -k4,4nr | head -n 20
        grep "^N$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k3,3nr | head -n 15
        grep "^U$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k3,3nr -k4,4nr | head -n 20
        grep "^X$TAB" "$_tmp/st.raw" | sort -t "$TAB" -k3,3nr
    } > "$_tmp/st.sorted"

    _ba=$(banaction_current); _barec=$(banaction_pick)

    # ---- 終端機 ----
    _blk='#'
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]*) _blk='█' ;; esac
    awk -F"$TAB" -v NOW="$_now" -v SINCE="$_since" -v B="$_bucket" -v TZOFF="$_tz" -v MAXR="$_maxr" \
        -v RANGE="$_range" -v SERVER="$_server" -v FWOK="$_fwok" -v FWB="$_fwb" -v BA="$_ba" -v BAREC="$_barec" \
        -v AUTHSRC="$_ausrc" -v SELF="$SELF" -v BLK="$_blk" -v MODE="$_mode" \
        -v CB="$CB" -v CD="$CD" -v CY="$CY" -v CG="$CG" -v CR="$CR" -v C0="$C0" \
        "$RPT_AWK_LIB$RPT_AWK_TXT" "$_tmp/st.sorted" "$_tmp/cur.tsv" "$_tmp/jl.tsv"

    # ---- HTML ----
    if [ -z "$REPORT_OUT" ]; then
        _hn=$(printf '%s' "$_host" | tr -c 'A-Za-z0-9._-' '_')
        REPORT_OUT="${PREFIX}${OPS_SSH_DIR}/fail2ban-report-$_hn-$(date +%Y%m%d-%H%M).html"
    fi
    mkdir -p "$(dirname "$REPORT_OUT")" 2>/dev/null
    if awk -F"$TAB" -v NOW="$_now" -v SINCE="$_since" -v B="$_bucket" -v TZOFF="$_tz" -v MAXR="$_maxr" \
        -v RANGE="$_range" -v SERVER="$_server" -v FWOK="$_fwok" -v FWB="$_fwb" -v BA="$_ba" -v BAREC="$_barec" \
        -v AUTHSRC="$_ausrc" -v F2BSRC="$_f2bsrc" -v DBSRC="$_dbsrc" -v HOST="$_host" -v VER="${F2B_VER:-?}" -v MODE="$_mode" \
        "$RPT_AWK_LIB$RPT_AWK_HTML" "$_tmp/st.sorted" "$_tmp/cur.tsv" "$_tmp/jl.tsv" > "$REPORT_OUT" 2>/dev/null; then
        chmod 640 "$REPORT_OUT" 2>/dev/null
        plain ""
        ok "HTML 報告：$REPORT_OUT"
        info "單一檔案、不連外部資源，可以直接下載或轉寄。裡面有完整的來源 IP。"
    else
        err "HTML 寫不進去：$REPORT_OUT"
        return 1
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
  $SELF report              fail2ban 做了哪些事：終端機摘要 + 單檔 HTML（唯讀）

選項：
  -j <jail>   只對這個 jail 動作（預設：全部）
  -t <秒>     封鎖時長，perm = 永久（需 fail2ban 支援 banip --time）
  -y          不問確認
  -n          乾跑，只印出將要做什麼
  --force     即使會鎖到自己也照做（風險自負）
  --days <N>  report 的範圍，預設 7 天，all = 日誌裡全部
  -o <檔案>   report 的 HTML 輸出路徑（預設 $OPS_SSH_DIR/fail2ban-report-<主機>-<時間>.html）

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
        --days)    [ $# -ge 2 ] || { printf '%s\n' "--days 後面要接天數或 all" >&2; exit 1; }
                   REPORT_DAYS="$2"; shift 2 ;;
        -o|--out)  [ $# -ge 2 ] || { printf '%s\n' "-o 後面要接輸出檔路徑" >&2; exit 1; }
                   REPORT_OUT="$2"; shift 2 ;;
        -*) printf '%s\n' "未知選項：$1（可用 -j / -t / -y / -n / --force / --days / -o）" >&2; exit 1 ;;
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
    report)                cmd_report ;;
    preflight)             cmd_preflight ;;      # ops.sh 開場自檢用，沒事不出聲
    *) printf '%s\n' "未知命令：$CMD（跑 $SELF -h 看用法）" >&2; exit 1 ;;
esac
