#!/bin/sh
# ops.sh — OPS-command 視覺化操作選單
#
# 一支入口把 SSH/ 底下的工具包起來，用選單操作，不必記參數。
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 用法：
#   本機執行（git clone 後）
#     ./ops.sh            進入互動選單
#     ./ops.sh doctor     只做環境檢查後離開（可寫進巡檢排程）
#     ./ops.sh -h         說明
#
#   一行指令執行（不落地 repo）
#     bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh)
#     curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh | sh
#
# 設計原則：
#   1. POSIX sh 撰寫，Alpine 的 busybox ash 與 CentOS 7 的舊 bash 都能跑，
#      本身零相依（不需要 dialog / whiptail / ncurses）。
#   2. 只做「導覽 + 前置檢查 + 呼叫」，所有實際變更都在被呼叫的腳本裡，
#      選單不自己碰系統設定，出事時追查範圍才不會擴散。
#   3. 每個危險動作在執行前先把「會動到什麼」印出來，並要求二次確認。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

OPS_VERSION=1.1

# 遠端來源。想指到自己的 fork、內網鏡像或其他分支，執行前設 OPS_RAW_BASE 即可：
#   OPS_RAW_BASE=https://git.example.com/ops/raw/dev bash <(curl -fsSL .../ops.sh)
OPS_RAW_BASE="${OPS_RAW_BASE:-https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main}"

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
BASE=$(dirname "$SELF")

SSH_PORT_REL='SSH/ssh-port.sh'
SELFHEAL_REL='SSH/selfheal-ssh.sh'
MIRROR_URL_REL='REPO/URL'

# SSH/ 底下的腳本產出的東西統一收在這裡；export 讓它們沿用同一個值
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
export OPS_SSH_DIR

PORT_STATE="$OPS_SSH_DIR/ssh-port/state"
LEGACY_PORT_STATE=/var/lib/ssh-port/state    # 1.1.0 之前的位置，換埠進行中時仍會用

has() { command -v "$1" >/dev/null 2>&1; }

# =========================================================
# 工具來源解析
#   一行指令執行時（bash <(curl …)）$0 是 /dev/fd/NN、管線執行時是 "sh"，
#   兩種情況都拿不到 repo 目錄，SSH/ 底下的腳本必須改成下載到本機再呼叫。
# =========================================================

# 快取目錄一定要是「長期存在」的路徑，不能用 mktemp -d 後離開時刪掉：
# ssh-port.sh 的看門狗會把「本腳本路徑 rollback --auto」寫進背景排程，
# 檔案被刪等於自動還原機制失效，換埠失敗時真的會被鎖在門外。
cache_dir() {
    if [ "$(id -u)" = 0 ]; then
        printf '%s\n' /var/lib/ops-command
    elif [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s\n' "$XDG_CACHE_HOME/ops-command"
    elif [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
        printf '%s\n' "$HOME/.cache/ops-command"
    else
        printf '%s\n' "${TMPDIR:-/tmp}/ops-command-$(id -u)"
    fi
}

CACHE_DIR=$(cache_dir)
CACHE_MARK="$CACHE_DIR/.ops-remote"

# 判為本機模式的條件：$0 旁邊就有完整的 SSH/，而且那個目錄不是我們自己的快取
# （快取裡也會有這些檔案，若不排除，第二次執行就會誤判成 git clone 的 repo，
#  導致選單少掉「更新腳本快取」而一直用舊版）
if [ -f "$BASE/$SSH_PORT_REL" ] && [ -f "$BASE/$SELFHEAL_REL" ] &&
   [ ! -f "$BASE/.ops-remote" ] && [ "$BASE" != "$CACHE_DIR" ]; then
    RUN_MODE=local
    ASSET_DIR="$BASE"
    RERUN_HINT="$SELF"
else
    RUN_MODE=remote
    ASSET_DIR="$CACHE_DIR"
    RERUN_HINT="bash <(curl -fsSL $OPS_RAW_BASE/ops.sh)"
fi

SSH_DIR="$ASSET_DIR/SSH"
SSH_PORT_SH="$ASSET_DIR/$SSH_PORT_REL"
SELFHEAL_SH="$ASSET_DIR/$SELFHEAL_REL"
MIRROR_URL_FILE="$ASSET_DIR/$MIRROR_URL_REL"

FETCH_ERR=''

# 下載單一檔案到指定路徑（僅負責取得，不做驗證）
fetch_url() {
    _u=$1; _d=$2
    if has curl; then
        curl -fsSL --connect-timeout 10 --max-time 180 -o "$_d" "$_u" 2>/dev/null
    elif has wget; then
        wget -q --timeout=20 -O "$_d" "$_u" 2>/dev/null
    else
        FETCH_ERR='需要 curl 或 wget 才能下載工具'
        return 127
    fi
}

# 取得 repo 中的某個腳本，成功後才覆蓋既有檔案（下載中斷不會留下半截檔）
fetch_script() {
    _rel=$1
    _dst="$ASSET_DIR/$_rel"
    _tmp="$_dst.part"
    FETCH_ERR=''

    if ! mkdir -p "$(dirname "$_dst")" 2>/dev/null; then
        FETCH_ERR="無法建立目錄 $(dirname "$_dst")"
        return 1
    fi
    if ! fetch_url "$OPS_RAW_BASE/$_rel" "$_tmp"; then
        rm -f "$_tmp"
        [ -z "$FETCH_ERR" ] && FETCH_ERR="下載失敗：$OPS_RAW_BASE/$_rel"
        return 1
    fi
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        FETCH_ERR="下載到空檔案：$OPS_RAW_BASE/$_rel"
        return 1
    fi
    # 被 captive portal / 代理攔截時拿到的會是 HTML，直接跑會很難查，先擋掉
    case $(head -1 "$_tmp" 2>/dev/null) in
        '#!'*) : ;;
        *) rm -f "$_tmp"
           FETCH_ERR="$_rel 內容不是腳本，可能被代理或入口網頁攔截"
           return 1 ;;
    esac
    if ! mv -f "$_tmp" "$_dst" 2>/dev/null; then
        rm -f "$_tmp"
        FETCH_ERR="無法寫入 $_dst"
        return 1
    fi
    chmod 755 "$_dst" 2>/dev/null || true
    return 0
}

# 遠端模式的開場下載。一次抓齊，讓選單與 doctor 看到的狀態一致。
# $1 = force 時強制重抓（選單的 u）
assets_sync() {
    [ "$RUN_MODE" = remote ] || return 0
    if ! has curl && ! has wget; then
        nomsg "遠端執行需要 curl 或 wget"
        row "請改用：git clone https://github.com/cxhil-yixian/OPS-command.git"
        return 1
    fi
    ensure_asset_dir || return 1

    _rc=0
    for _rel in "$SSH_PORT_REL" "$SELFHEAL_REL"; do
        if [ "${1:-}" = force ] || [ ! -f "$ASSET_DIR/$_rel" ]; then
            printf ' 取得 %s … ' "$_rel"
            if fetch_script "$_rel"; then
                printf '%s%s%s\n' "$CG" "$MK_OK" "$C0"
            else
                printf '%s%s%s  %s\n' "$CR" "$MK_NO" "$C0" "$FETCH_ERR"
                _rc=1
            fi
        fi
    done
    # 換源網址檔沒抓到不影響，act_mirror 會退回內建預設值
    if [ "${1:-}" = force ] || [ ! -f "$MIRROR_URL_FILE" ]; then
        mkdir -p "$(dirname "$MIRROR_URL_FILE")" 2>/dev/null &&
            fetch_url "$OPS_RAW_BASE/$MIRROR_URL_REL" "$MIRROR_URL_FILE" 2>/dev/null || true
    fi
    return $_rc
}

# 快取目錄要能放「等一下會被 root 執行」的腳本，所以權限一定要收得起來。
# cache_dir 的最後一層退路是 TMPDIR，那是所有人可寫的：同名目錄若已被別人建好，
# mkdir -p 會「成功」但 chmod 會失敗——這種情況直接停下，不接受降級。
ensure_asset_dir() {
    mkdir -p "$ASSET_DIR" 2>/dev/null || { nomsg "無法建立 $ASSET_DIR"; return 1; }
    if ! chmod 700 "$ASSET_DIR" 2>/dev/null; then
        nomsg "$ASSET_DIR 的權限設不上（目錄可能不屬於你）"
        row "拒絕把要執行的腳本放進去。請改用 git clone，或把 TMPDIR 設到自己的目錄"
        return 1
    fi
    : > "$CACHE_MARK" 2>/dev/null || true
    return 0
}

# 把 ops.sh 自己落地成檔案，供「curl … | sh」時重新 exec 用
SELF_FILE=''
ensure_self() {
    if [ "$RUN_MODE" = local ] && [ -f "$SELF" ]; then
        SELF_FILE="$SELF"
        return 0
    fi
    ensure_asset_dir || return 1
    fetch_script ops.sh || return 1
    SELF_FILE="$ASSET_DIR/ops.sh"
    return 0
}

# =========================================================
# 介面初始化
#   顏色與框線都要能退化：非終端機輸出、NO_COLOR、沒有 UTF-8 locale
#   的機器（常見於最小化安裝的 CentOS 7）都要還能讀。
# =========================================================
ui_init() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
        CC=$(printf '\033[36m'); CB=$(printf '\033[1m');  CD=$(printf '\033[2m')
        C0=$(printf '\033[0m')
    else
        CR=''; CG=''; CY=''; CC=''; CB=''; CD=''; C0=''
    fi

    UTF8_OK=0
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) UTF8_OK=1 ;;
    esac
    if [ "$UTF8_OK" = 0 ]; then
        _loc=$(locale -a 2>/dev/null | grep -iE '^(C|en_US|zh_TW|zh_CN)\.(utf-?8)$' | head -1)
        [ -z "$_loc" ] && _loc=$(locale -a 2>/dev/null | grep -i 'utf-\?8$' | head -1)
        if [ -n "$_loc" ]; then
            LC_CTYPE="$_loc"; export LC_CTYPE; UTF8_OK=1
        fi
    fi

    if [ "$UTF8_OK" = 1 ]; then
        HR='────────────────────────────────────────────────────────────────────'
        MK_OK='✓'; MK_NO='✗'; MK_WARN='!'
    else
        HR='--------------------------------------------------------------------'
        MK_OK='+'; MK_NO='x'; MK_WARN='!'
    fi
}

hr()     { printf '%s%s%s\n' "$CD" "$HR" "$C0"; }
sect()   { printf '%s%s%s\n' "$CB$CC" " $*" "$C0"; }
row()    { printf '   %s\n' "$*"; }
okmsg()  { printf ' %s%s%s %s\n' "$CG" "$MK_OK" "$C0" "$*"; }
nomsg()  { printf ' %s%s%s %s\n' "$CR" "$MK_NO" "$C0" "$*"; }
wmsg()   { printf ' %s%s%s %s\n' "$CY" "$MK_WARN" "$C0" "$*"; }
dim()    { printf '%s%s%s\n' "$CD" "$*" "$C0"; }

pause() {
    printf '\n%s按 Enter 回到選單…%s' "$CD" "$C0"
    read -r _ignored 2>/dev/null || true
}

confirm() {
    printf '%s%s%s [y/N] ' "$CY" "$1" "$C0"
    read -r _a 2>/dev/null || _a=''
    case "$_a" in y|Y|yes|YES) return 0 ;; *) printf ' 已取消\n'; return 1 ;; esac
}

need_root() {
    [ "$(id -u)" = 0 ] && return 0
    nomsg "這個動作需要 root 權限，目前身分是 $(id -un)"
    row "請用 sudo -i 或 su - 切換後重跑：$RERUN_HINT"
    return 1
}

# =========================================================
# 環境偵測
#   os-release 會設 VERSION / ID 等變數，故本腳本自己的版本號命名為
#   OPS_VERSION，避免被蓋掉。
# =========================================================
detect() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
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

    # 套件管理器：診斷時要給出「這台機器實際可用」的安裝指令
    if   has apk;    then PKG=apk;  PKG_INSTALL='apk add --no-cache'
    elif has dnf;    then PKG=dnf;  PKG_INSTALL='dnf install -y'
    elif has yum;    then PKG=yum;  PKG_INSTALL='yum install -y'
    elif has apt-get;then PKG=apt;  PKG_INSTALL='apt-get install -y'
    else                  PKG=none; PKG_INSTALL='(找不到套件管理器)'
    fi

    if   [ -d /run/systemd/system ]; then INIT=systemd
    elif has rc-service;             then INIT=openrc
    else                                  INIT=sysv
    fi

    # 服務名：RHEL / Alpine 是 sshd，Debian 系是 ssh
    SSH_SVC=sshd
    if [ "$INIT" = systemd ]; then
        if   systemctl cat sshd.service >/dev/null 2>&1; then SSH_SVC=sshd
        elif systemctl cat ssh.service  >/dev/null 2>&1; then SSH_SVC=ssh
        fi
    elif [ "$OS_FAMILY" = debian ]; then
        SSH_SVC=ssh
    fi

    SSH_STATE=n/a
    case "$INIT" in
        systemd) SSH_STATE=$(systemctl is-active "$SSH_SVC" 2>/dev/null || echo inactive) ;;
        openrc)  rc-service "$SSH_SVC" status >/dev/null 2>&1 && SSH_STATE=active || SSH_STATE=inactive ;;
        *)       service "$SSH_SVC" status >/dev/null 2>&1 && SSH_STATE=active || SSH_STATE=unknown ;;
    esac

    # socket activation：Ubuntu 24.04 預設啟用，此時 sshd_config 的 Port 無效
    SOCKET_UNIT=''
    if [ "$INIT" = systemd ]; then
        for _u in ssh.socket sshd.socket; do
            if systemctl is-active "$_u" >/dev/null 2>&1 || systemctl is-enabled "$_u" >/dev/null 2>&1; then
                SOCKET_UNIT="$_u"; break
            fi
        done
    fi

    SELINUX=disabled
    if has getenforce; then
        SELINUX=$(getenforce 2>/dev/null | tr 'A-Z' 'a-z')
    elif [ -r /sys/fs/selinux/enforce ]; then
        [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = 1 ] && SELINUX=enforcing || SELINUX=permissive
    fi

    FW=none
    if   has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then FW=firewalld
    elif has ufw && ufw status 2>/dev/null | head -1 | grep -qi active; then FW=ufw
    elif has nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then FW=nftables
    elif has iptables && iptables -S 2>/dev/null | grep -qE '^-A INPUT'; then FW=iptables
    fi

    # 生效中的埠：sshd -T 才是唯一可靠來源，但需要 root
    PORTS=''
    if [ "$(id -u)" = 0 ] && has sshd; then
        PORTS=$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}')
    fi
    if [ -z "$PORTS" ]; then
        PORTS=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
                /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}')
    fi
    [ -z "$PORTS" ] && PORTS=22
    PORTS=$(printf '%s\n' $PORTS | sort -un | tr '\n' ',' | sed 's/,$//')

    PENDING=0
    { [ -f "$PORT_STATE" ] || [ -f "$LEGACY_PORT_STATE" ]; } && PENDING=1
}

# =========================================================
# 相依檢查
#   兩支腳本都是 POSIX sh，本身不需要 bash。真正會缺的是 procps 版的 ps
#   （沒有它就分不出「已登入 / 認證中」）與 iproute2。Alpine 最小安裝兩者
#   都沒有，事前講清楚比執行到一半才降級好。
# =========================================================
DEP_MISSING=''
dep_note() { DEP_MISSING="$DEP_MISSING $1"; }

# 探測可用的 ps -o 寫法。注意 procps 的陷阱：`ps -eo pid=,etime=,args=`
# 會把「,etime=,args=」整串當成 pid 欄的標題，只印出一欄——看起來成功，
# 實際上行程標題全空。故用逐欄 -o 的寫法探測。
ps_probe() {
    for _c in "-eo pid= -o etime= -o args=" \
              "-o pid= -o etime= -o args=" \
              "-eo pid,etime,args" \
              "-o pid,etime,args"; do
        # shellcheck disable=SC2086
        if [ "$(ps $_c 2>/dev/null | awk '$1+0>0 && $2 ~ /:/' | grep -c .)" -ge 3 ]; then
            echo "$_c"; return 0
        fi
    done
    echo none
}

check_deps() {
    DEP_MISSING=''
    DEP_HARD=0        # 缺了就跑不動
    DEP_SOFT=0        # 缺了會降級

    if has ss; then okmsg "ss (iproute2)"
    elif has netstat; then wmsg "無 ss，退回 netstat（可用但較慢）"; DEP_SOFT=1
    else nomsg "ss / netstat 皆無 — 無法取得連線資訊"
         case "$PKG" in apk|apt) dep_note iproute2 ;; *) dep_note iproute ;; esac
         DEP_HARD=1
    fi

    _psm=$(ps_probe)
    if [ "$_psm" != none ]; then okmsg "ps 可用（$_psm）— 能分辨已登入 / 認證中"
    else nomsg "找不到可用的 ps -o（busybox 精簡版）— 連線階段分類會失效"
         dep_note procps; DEP_HARD=1
    fi

    if has flock; then okmsg "flock"
    else wmsg "無 flock — 一次性取證的重入保護會停用（仍會正常採集）"; dep_note util-linux; DEP_SOFT=1
    fi

    if has timeout; then okmsg "timeout"
    else wmsg "無 timeout — 採集指令沒有逾時保護"; dep_note coreutils; DEP_SOFT=1
    fi

    if has who; then okmsg "who"
    else wmsg "無 who — session 數改由 sshd 行程標題推估"; dep_note coreutils; DEP_SOFT=1
    fi

    # 只有換源那支第三方腳本需要 bash，兩支自家腳本都不用
    has bash && okmsg "bash（選單第 9 項換源腳本需要）" \
             || wmsg "無 bash — 只影響第 9 項換源，SSH 工具不需要"

    if [ "$OS_FAMILY" = rhel ] && [ "$SELINUX" != disabled ]; then
        if has semanage; then okmsg "semanage（SELinux 為 $SELINUX，換埠時必要）"
        else
            nomsg "SELinux 是 $SELINUX 但沒有 semanage — 換埠會失敗"
            if [ "${OS_VER%%.*}" = 7 ]; then dep_note policycoreutils-python
            else dep_note policycoreutils-python-utils; fi
            DEP_HARD=1
        fi
    fi

    # 認證日誌讀不到的話「登入失敗數」會恆為 0，那是讀不到而不是沒被攻擊，
    # 這種靜默的 0 比報錯危險，所以獨立檢查一次。
    _logsrc=none
    if has journalctl && [ -n "$(journalctl -u "$SSH_SVC" -n 1 --no-pager -q 2>/dev/null)" ]; then
        _logsrc=journal
    else
        for _g in /var/log/secure /var/log/auth.log /var/log/messages; do
            [ -f "$_g" ] && { _logsrc="$_g"; break; }
        done
        [ "$_logsrc" = none ] && has logread && _logsrc='logread (busybox 環狀緩衝)'
    fi
    if [ "$_logsrc" != none ]; then
        okmsg "認證日誌來源：$_logsrc"
    else
        nomsg "讀不到認證日誌 — 登入失敗統計會恆為 0（連線層統計不受影響）"
        if [ "$OS_FAMILY" = alpine ]; then
            row "Alpine 請啟用 syslog：rc-update add syslog && rc-service syslog start"
        fi
        DEP_SOFT=1
    fi

    if has fail2ban-client; then okmsg "fail2ban（取證會一併輸出封鎖狀態）"
    else dim "   （未安裝 fail2ban，非必要）"
    fi
}

# =========================================================
# 標頭
# =========================================================
banner() {
    clear 2>/dev/null || printf '\n\n'
    hr
    printf '%s OPS-command 運維工具箱%s  %sv%s%s\n' "$CB$CC" "$C0" "$CD" "$OPS_VERSION" "$C0"
    hr
    printf ' 系統   %s\n' "$OS_PRETTY  ${CD}(family=$OS_FAMILY, init=$INIT, pkg=$PKG)$C0"
    printf ' SSH    服務 %s = %s' "$SSH_SVC" \
        "$([ "$SSH_STATE" = active ] && printf '%sactive%s' "$CG" "$C0" || printf '%s%s%s' "$CR" "$SSH_STATE" "$C0")"
    printf '   埠 %s%s%s' "$CB" "$PORTS" "$C0"
    [ -n "$SOCKET_UNIT" ] && printf '   %s[%s 接管中]%s' "$CY" "$SOCKET_UNIT" "$C0"
    printf '\n'
    printf ' 防護   防火牆 %s   SELinux %s   身分 %s\n' "$FW" "$SELINUX" "$(id -un)"
    if [ "$RUN_MODE" = remote ]; then
        printf ' 工具   %s遠端執行%s  腳本快取於 %s\n' "$CY" "$C0" "$ASSET_DIR"
    else
        printf ' 工具   本機 %s\n' "$ASSET_DIR"
    fi

    if [ "$PENDING" = 1 ]; then
        printf '\n'
        printf ' %s%s 有未確認的換埠作業進行中%s\n' "$CY$CB" "$MK_WARN" "$C0"
        row "若新埠已測通請選 3 確認；不確定就選 4 還原。逾時看門狗會自動還原。"
    fi
    hr
}

menu() {
    sect "SSH 連接埠  (SSH/ssh-port.sh)"
    row "1) 查看目前狀態"
    row "2) 變更連接埠      ${CD}新舊埠並存 + 看門狗，不會把自己鎖在門外${C0}"
    row "3) 確認新埠可用    ${CD}收掉舊埠，取消看門狗${C0}"
    row "4) 立即還原        ${CD}回到變更前的設定${C0}"
    printf '\n'
    sect "SSH 監控與取證  (SSH/selfheal-ssh.sh)"
    row "5) 即時監看        ${CD}每秒刷新，看得到誰在連、卡在哪個階段${C0}"
    row "6) 一次性取證      ${CD}完整報告寫入 $OPS_SSH_DIR/${C0}"
    row "7) 追蹤認證日誌    ${CD}即時 tail 登入成功/失敗事件${C0}"
    row "8) 解析排查        ${CD}傾印原始 ss / ps 資料，回報問題時用${C0}"
    printf '\n'
    sect "系統"
    row "9) 更換套件來源鏡像 ${CD}呼叫 linuxmirrors.cn 的外部腳本${C0}"
    row "d) 環境自我診斷     ${CD}檢查相依套件與已知相容性問題${C0}"
    row "i) 安裝缺少的相依套件"
    [ "$RUN_MODE" = remote ] && \
        row "u) 更新腳本快取     ${CD}重新下載 SSH/ 底下的工具${C0}"
    row "q) 離開"
    printf '\n'
}

# =========================================================
# 動作
# =========================================================
# $1 = 完整路徑，$2 = repo 內的相對路徑（遠端模式要用它補下載）
require_script() {
    [ -f "$1" ] && return 0
    if [ "$RUN_MODE" = remote ]; then
        printf ' 取得 %s … ' "$2"
        if fetch_script "$2"; then
            printf '%s%s%s\n' "$CG" "$MK_OK" "$C0"
            return 0
        fi
        printf '%s%s%s\n' "$CR" "$MK_NO" "$C0"
        nomsg "$FETCH_ERR"
        row "可改用 git clone 在本機執行，或設 OPS_RAW_BASE 指到連得到的鏡像"
        return 1
    fi
    nomsg "找不到 $1"
    row "請確認是從 repo 根目錄執行 ops.sh，且 SSH/ 目錄完整"
    return 1
}

act_port_status() {
    require_script "$SSH_PORT_SH" "$SSH_PORT_REL" || return 0
    sh "$SSH_PORT_SH" status
}

act_port_set() {
    require_script "$SSH_PORT_SH" "$SSH_PORT_REL" || return 0
    need_root || return 0

    printf '\n'
    sect "變更 SSH 連接埠"
    dim " 流程：設定新舊埠同時監聽 -> 你另開視窗用新埠登入 -> 回來確認 -> 收掉舊埠"
    dim " 看門狗會在時限內沒收到確認時自動還原全部變更（設定檔 / 防火牆 / SELinux）"
    printf '\n'
    row "目前的埠：${CB}${PORTS}${C0}"
    [ -n "$SOCKET_UNIT" ] && wmsg "$SOCKET_UNIT 接管中，實際生效的是 ListenStream，腳本會一併處理"
    [ "$OS_FAMILY" = rhel ] && [ "$SELINUX" != disabled ] && \
        wmsg "SELinux 為 $SELINUX，腳本會用 semanage 標記新埠為 ssh_port_t"
    # 看門狗是背景執行「$SSH_PORT_SH rollback --auto」，遠端模式下這是快取檔案，
    # 在 confirm 之前把它刪掉，自動還原就沒得跑了。
    [ "$RUN_MODE" = remote ] && \
        wmsg "看門狗會呼叫 $SSH_PORT_SH，confirm 之前請不要刪掉 $ASSET_DIR"
    printf '\n'

    printf ' 要換到哪個埠？(1-65535，直接 Enter 取消) '
    read -r _p 2>/dev/null || _p=''
    [ -z "$_p" ] && { printf ' 已取消\n'; return 0; }

    printf ' 看門狗時限幾秒？(Enter = 600) '
    read -r _t 2>/dev/null || _t=''
    [ -z "$_t" ] && _t=600

    printf '\n'
    dim " 先跑一次乾跑，看看會動到什麼："
    hr
    sh "$SSH_PORT_SH" set "$_p" -t "$_t" -n
    hr
    printf '\n'
    confirm "以上動作要實際執行嗎？" || return 0
    printf '\n'
    sh "$SSH_PORT_SH" set "$_p" -t "$_t"
}

act_port_confirm() {
    require_script "$SSH_PORT_SH" "$SSH_PORT_REL" || return 0
    need_root || return 0
    printf '\n'
    wmsg "確認前請先在「另一個新視窗」用新埠登入成功，不要只看這個舊連線還活著"
    confirm "已經用新埠登入成功了嗎？" || return 0
    sh "$SSH_PORT_SH" confirm
}

act_port_rollback() {
    require_script "$SSH_PORT_SH" "$SSH_PORT_REL" || return 0
    need_root || return 0
    printf '\n'
    confirm "要立即還原 SSH 埠設定嗎？" || return 0
    sh "$SSH_PORT_SH" rollback
}

selfheal_guard() {
    require_script "$SELFHEAL_SH" "$SELFHEAL_REL" || return 1
    if [ "$(ps_probe)" = none ]; then
        wmsg "找不到可用的 ps -o，「已登入 / 認證中」分類會失效"
        row "安裝：$PKG_INSTALL procps（或按 i 自動安裝）"
    fi
    if [ "$(id -u)" != 0 ]; then
        wmsg "非 root 執行：抓不到連線對應的行程，「已登入 / 認證中」分類會退回粗略模式"
    fi
    return 0
}

act_watch() {
    selfheal_guard || return 0
    printf '\n 每幾秒刷新？(Enter = 1) '
    read -r _i 2>/dev/null || _i=''
    [ -z "$_i" ] && _i=1
    dim " Ctrl-C 離開監看，會回到本選單"
    sleep 1
    sh "$SELFHEAL_SH" watch "$_i"
}

act_forensic() {
    selfheal_guard || return 0
    printf '\n'
    dim " 完整報告寫入 $OPS_SSH_DIR/ssh-health.log，以下是摘要："
    hr
    sh "$SELFHEAL_SH" oneshot
}

act_tail() {
    selfheal_guard || return 0
    dim " Ctrl-C 離開，會回到本選單"
    sleep 1
    sh "$SELFHEAL_SH" tail
}

act_debug() {
    selfheal_guard || return 0
    sh "$SELFHEAL_SH" debug
}

act_mirror() {
    _url='https://linuxmirrors.cn/main.sh'
    [ -r "$MIRROR_URL_FILE" ] && _url=$(head -1 "$MIRROR_URL_FILE" | tr -d ' \r\n')

    printf '\n'
    sect "更換套件來源鏡像"
    nomsg "這會從網路下載並以 root 執行第三方腳本，且會改寫本機的套件來源設定"
    row "來源：${CB}${_url}${C0}"
    row "維護者：linuxmirrors.cn（非本 repo）"
    row "本 repo 只記錄這個網址，不對其內容負責；不放心請先自行下載檢視再執行"
    printf '\n'
    row "會被改寫的檔案："
    case "$OS_FAMILY" in
        rhel)   row "  /etc/yum.repos.d/*.repo" ;;
        debian) row "  /etc/apt/sources.list 與 /etc/apt/sources.list.d/*" ;;
        alpine) row "  /etc/apk/repositories" ;;
        *)      row "  （未知發行版，腳本可能不支援）" ;;
    esac
    printf '\n'

    need_root || return 0
    if ! has curl && ! has wget; then
        nomsg "需要 curl 或 wget"
        row "安裝：$PKG_INSTALL curl"
        return 0
    fi
    if ! has bash; then
        nomsg "該腳本需要 bash"
        row "安裝：$PKG_INSTALL bash"
        return 0
    fi

    printf ' %s請輸入 %sYES%s%s 以確認執行（其他任何輸入都會取消）：%s ' "$CY" "$CB" "$C0" "$CY" "$C0"
    read -r _a 2>/dev/null || _a=''
    [ "$_a" = YES ] || { printf ' 已取消\n'; return 0; }

    printf '\n'
    if has curl; then
        curl -sSL "$_url" | bash
    else
        wget -qO- "$_url" | bash
    fi
}

act_doctor() {
    printf '\n'
    sect "環境自我診斷"
    hr
    row "系統      : $OS_PRETTY (family=$OS_FAMILY, version=$OS_VER)"
    row "init      : $INIT"
    row "套件管理  : $PKG"
    row "SSH 服務  : $SSH_SVC ($SSH_STATE)"
    row "SSH 埠    : $PORTS"
    [ -n "$SOCKET_UNIT" ] && row "socket    : $SOCKET_UNIT 接管中（sshd_config 的 Port 無效）"
    row "SELinux   : $SELINUX"
    row "防火牆    : $FW"
    row "執行身分  : $(id -un) (uid=$(id -u))"
    if [ "$RUN_MODE" = remote ]; then
        row "工具來源  : 遠端 $OPS_RAW_BASE"
        row "腳本快取  : $ASSET_DIR"
    else
        row "工具來源  : 本機 $ASSET_DIR"
    fi
    row "產出目錄  : $OPS_SSH_DIR$([ -d "$OPS_SSH_DIR" ] || printf '   （尚未建立）')"
    [ -f "$LEGACY_PORT_STATE" ] && \
        row "            換埠進行中且使用舊路徑 /var/lib/ssh-port，confirm 後會自動搬移"
    hr
    sect "相依套件"
    check_deps
    hr
    sect "腳本"
    for _s in "$SSH_PORT_SH" "$SELFHEAL_SH"; do
        if [ -f "$_s" ]; then
            [ -x "$_s" ] && okmsg "$_s" || wmsg "$_s（無執行權限，本選單以 sh/bash 呼叫故仍可用）"
        elif [ "$RUN_MODE" = remote ]; then
            nomsg "$_s 尚未下載成功（選 u 重試，或檢查對外連線）"
        else
            nomsg "$_s 不存在"
        fi
    done
    hr

    if [ "$DEP_HARD" = 1 ]; then
        nomsg "有必要套件缺失，部分功能無法運作。選 i 可自動安裝"
    elif [ "$DEP_SOFT" = 1 ]; then
        wmsg "有非必要項目缺失，功能可用但會降級"
    else
        okmsg "環境完整"
    fi

    # 已知相容性事項，講在前面比出事後查好
    printf '\n'
    sect "已知事項"
    case "$OS_FAMILY" in
        rhel)
            if [ "${OS_VER%%.*}" = 7 ]; then
                row "CentOS/RHEL 7 的 OpenSSH 7.4 不支援 Include，換埠會直接改主設定檔開頭"
                row "（腳本會避開寫到 Match 區塊裡，這是常見的誤設）"
            else
                row "使用 sshd_config.d drop-in 方式寫入，不動主設定檔"
            fi
            [ "$SELINUX" != disabled ] && row "SELinux 啟用中，換埠一定要有 semanage，否則 sshd 會 bind 失敗"
            ;;
        debian)
            if [ -n "$SOCKET_UNIT" ]; then
                row "$SOCKET_UNIT 接管中（Ubuntu 24.04 預設）：改 sshd_config 的 Port 完全無效，"
                row "真正決定監聽埠的是 socket 的 ListenStream，ssh-port.sh 會一併寫 override"
            fi
            ;;
        alpine)
            row "兩支腳本都是 POSIX sh，busybox ash 可直接執行，不需要安裝 bash"
            row "認證日誌會依序找 /var/log/messages、/var/log/auth.log、logread"
            row "階段分類（已登入 / 認證中）需要 procps 版的 ps，缺了會降級為粗略統計"
            row "who 需要 utmp，Alpine 預設不維護，session 數會改由 sshd 行程標題推估"
            ;;
        *)
            row "未能辨識的發行版，兩支腳本會退回通用路徑，建議先跑一次乾跑（選 2）確認"
            ;;
    esac

    if [ "$RUN_MODE" = remote ]; then
        printf '\n'
        sect "遠端執行注意"
        row "腳本是下載到 $ASSET_DIR 後執行，不是隨用隨丟"
        row "換埠的看門狗會呼叫 $SSH_PORT_SH 做自動還原，"
        row "所以在 confirm 完成之前，這個目錄不能刪除或搬移"
        row "要換來源（fork / 內網鏡像 / 其他分支）：設環境變數 OPS_RAW_BASE"
    fi
}

act_refresh() {
    printf '\n'
    sect "更新腳本快取"
    if [ "$RUN_MODE" != remote ]; then
        okmsg "目前是本機模式，直接 git pull 即可"
        return 0
    fi
    if [ "$PENDING" = 1 ]; then
        wmsg "有未確認的換埠作業進行中，此時覆蓋腳本會影響看門狗的還原行為"
        confirm "還是要更新嗎？" || return 0
    fi
    row "來源：${CB}${OPS_RAW_BASE}${C0}"
    row "目標：${CB}${ASSET_DIR}${C0}"
    printf '\n'
    assets_sync force
}

act_install_deps() {
    printf '\n'
    sect "相依檢查"
    check_deps
    printf '\n'

    _pkgs=$(printf '%s\n' $DEP_MISSING | sort -u | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$_pkgs" ]; then
        okmsg "沒有缺少的套件"
        return 0
    fi
    if [ "$PKG" = none ]; then
        nomsg "找不到套件管理器，請自行安裝：$_pkgs"
        return 0
    fi

    row "將要執行：${CB}${PKG_INSTALL} ${_pkgs}${C0}"
    printf '\n'
    need_root || return 0
    confirm "要執行嗎？" || return 0
    printf '\n'
    [ "$PKG" = apt ] && apt-get update
    # shellcheck disable=SC2086
    $PKG_INSTALL $_pkgs
}

# =========================================================
# 進入點
# =========================================================
# 一行指令執行時 $0 是管線 / fd，讀不回自己的註解，所以說明文字直接內嵌。
usage() {
    cat <<EOF
ops.sh — OPS-command 視覺化操作選單  v$OPS_VERSION

本機執行（git clone 後）
    ./ops.sh            進入互動選單
    ./ops.sh doctor     只做環境檢查後離開（可寫進巡檢排程）
    ./ops.sh -h         本說明

一行指令執行（不落地 repo）
    bash <(curl -fsSL $OPS_RAW_BASE/ops.sh)
    curl -fsSL $OPS_RAW_BASE/ops.sh | sh

    此模式會把 SSH/ 底下的腳本下載到 $(cache_dir) 後再呼叫。
    換埠的看門狗會回頭呼叫該路徑做自動還原，確認完成前請勿刪除。

環境變數
    OPS_RAW_BASE   遠端來源前綴（fork / 內網鏡像 / 其他分支）
                   目前：$OPS_RAW_BASE
    OPS_SSH_DIR    SSH/ 腳本的產出目錄（狀態、備份、看門狗、日誌、取證報告）
                   目前：$OPS_SSH_DIR
    NO_COLOR       關閉顏色

目前模式：$RUN_MODE（工具路徑 $ASSET_DIR）
EOF
    exit 0
}

ui_init
detect

case "${1:-}" in
    -h|--help|help) usage ;;
    doctor|--doctor)
        assets_sync || true         # 抓不到也要把環境資訊印完
        act_doctor
        printf '\n'
        [ "${DEP_HARD:-0}" = 1 ] && exit 1
        exit 0 ;;
    '') : ;;
    *) printf '未知參數：%s（可用 doctor / -h）\n' "$1"; exit 1 ;;
esac

# 「curl … | sh」時 stdin 是腳本本身，讀不到鍵盤。此時把自己落地成檔案，
# 改用 /dev/tty 當 stdin 重新執行，使用者就不必先 clone 也能用選單。
if [ ! -t 0 ] && [ -z "${OPS_TTY_REEXEC:-}" ] && ( exec 3</dev/tty ) 2>/dev/null; then
    if ensure_self; then
        OPS_TTY_REEXEC=1; export OPS_TTY_REEXEC
        exec sh "$SELF_FILE" ${1+"$@"} < /dev/tty
    fi
    nomsg "$FETCH_ERR"
fi

if [ ! -t 0 ]; then
    printf '%s\n' "ops.sh 是互動選單，需要終端機。"
    printf '%s\n' "非互動場合請直接呼叫底層腳本，例如："
    printf '%s\n' "    sh $SSH_PORT_SH status"
    printf '%s\n' "    sh $SELFHEAL_SH oneshot"
    printf '%s\n' "或執行 ops.sh doctor 做環境檢查。"
    exit 1
fi

assets_sync || true                 # 缺哪支腳本，選到時 require_script 會再試一次

while :; do
    detect                      # 每輪重測，換完埠後標頭要能立刻反映
    banner
    menu
    printf ' 請選擇：'
    read -r choice 2>/dev/null || break
    printf '\n'
    case "$choice" in
        1) act_port_status ;;
        2) act_port_set ;;
        3) act_port_confirm ;;
        4) act_port_rollback ;;
        5) act_watch ;;
        6) act_forensic ;;
        7) act_tail ;;
        8) act_debug ;;
        9) act_mirror ;;
        d|D) act_doctor ;;
        i|I) act_install_deps ;;
        u|U) act_refresh ;;
        q|Q|exit|quit) printf ' 離開\n'; exit 0 ;;
        '') continue ;;
        *) nomsg "無此選項：$choice" ;;
    esac
    pause
done
