#!/bin/sh
# ops.sh — OPS-command 視覺化操作選單
#
# 一支入口把 SSH/、FAIL2BAN/ 與 STRESS/ 底下的工具包起來，用選單操作，不必記參數。
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

OPS_VERSION=1.5

# 遠端來源。想指到自己的 fork、內網鏡像或其他分支，執行前設 OPS_RAW_BASE 即可：
#   OPS_RAW_BASE=https://git.example.com/ops/raw/dev bash <(curl -fsSL .../ops.sh)
OPS_RAW_BASE="${OPS_RAW_BASE:-https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main}"

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
BASE=$(dirname "$SELF")

SSH_PORT_REL='SSH/ssh-port.sh'
SELFHEAL_REL='SSH/selfheal-ssh.sh'
F2B_REL='FAIL2BAN/fail2ban.sh'
STRESS_REL='STRESS/stress-test.sh'
MIRROR_URL_REL='REPO/URL'

# 各工具腳本產出的東西統一收在這裡；export 讓它們沿用同一個值
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
export OPS_SSH_DIR

# 壓測報告的輸出目錄。stress-test.sh 是「寫進當下工作目錄底下的 logs/」，
# 不吃路徑參數，所以選單的做法是 cd 過去再呼叫（見 stress_run）。
# 預設用啟動 ops.sh 時所在的目錄，跟直接執行那支腳本的行為一致。
OPS_STRESS_DIR="${OPS_STRESS_DIR:-$PWD}"
STRESS_DUR=60

PORT_STATE="$OPS_SSH_DIR/ssh-port/state"
LEGACY_PORT_STATE=/var/lib/ssh-port/state    # 1.1.0 之前的位置，換埠進行中時仍會用

has() { command -v "$1" >/dev/null 2>&1; }

# =========================================================
# 工具來源解析
#   一行指令執行時（bash <(curl …)）$0 是 /dev/fd/NN、管線執行時是 "sh"，
#   兩種情況都拿不到 repo 目錄，各工具腳本必須改成下載到本機再呼叫。
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
F2B_SH="$ASSET_DIR/$F2B_REL"
STRESS_SH="$ASSET_DIR/$STRESS_REL"
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

# 遠端模式的下載。一次抓齊，讓選單與 doctor 看到的狀態一致。
# $1 = ''      只補下載缺的
#      force   全部重抓，逐檔顯示（選單的 u）
#      update  全部重抓，只印一行摘要（開場自動更新）
assets_sync() {
    [ "$RUN_MODE" = remote ] || return 0
    if ! has curl && ! has wget; then
        nomsg "遠端執行需要 curl 或 wget"
        row "請改用：git clone https://github.com/cxhil-yixian/OPS-command.git"
        return 1
    fi
    ensure_asset_dir || return 1

    _mode="${1:-}"
    _rc=0; _n=0; _fail=''
    for _rel in "$SSH_PORT_REL" "$SELFHEAL_REL" "$F2B_REL" "$STRESS_REL"; do
        if [ "$_mode" = force ] || [ "$_mode" = update ] || [ ! -f "$ASSET_DIR/$_rel" ]; then
            [ "$_mode" = update ] || printf ' 取得 %s … ' "$_rel"
            if fetch_script "$_rel"; then
                _n=$((_n + 1))
                [ "$_mode" = update ] || printf '%s%s%s\n' "$CG" "$MK_OK" "$C0"
            else
                _rc=1; _fail="$_fail $_rel"
                [ "$_mode" = update ] || printf '%s%s%s  %s\n' "$CR" "$MK_NO" "$C0" "$FETCH_ERR"
            fi
        fi
    done
    if [ "$_mode" = update ]; then
        if [ -z "$_fail" ]; then
            printf ' %s%s%s 工具已更新（%s 支）\n' "$CG" "$MK_OK" "$C0" "$_n"
        else
            printf ' %s%s%s 更新失敗：%s\n' "$CY" "$MK_WARN" "$C0" "$_fail"
            printf '   %s\n' "$FETCH_ERR"
            printf '   沿用既有快取繼續執行\n'
        fi
    fi
    # 換源網址檔沒抓到不影響，act_mirror 會退回內建預設值。
    # 但一定要驗證內容：下載失敗會留下 0 bytes 的檔案，而「檔案存在」會讓
    # act_mirror 拿空字串蓋掉內建預設網址，也會讓這裡以為抓過了不再重試。
    if [ "${1:-}" = force ] || [ ! -s "$MIRROR_URL_FILE" ]; then
        if mkdir -p "$(dirname "$MIRROR_URL_FILE")" 2>/dev/null &&
           fetch_url "$OPS_RAW_BASE/$MIRROR_URL_REL" "${MIRROR_URL_FILE}.part" 2>/dev/null &&
           grep -qE '^[[:space:]]*https?://' "${MIRROR_URL_FILE}.part" 2>/dev/null; then
            mv -f "${MIRROR_URL_FILE}.part" "$MIRROR_URL_FILE" 2>/dev/null
        else
            rm -f "${MIRROR_URL_FILE}.part" 2>/dev/null
        fi
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

    if has fail2ban-client; then okmsg "fail2ban（選單 b 可管理封鎖清單）"
    else dim "   （未安裝 fail2ban，非必要；選單 b -> i 可安裝）"
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
    sect "封鎖管理  (FAIL2BAN/fail2ban.sh)"
    row "b) 進入封鎖選單    ${CD}手動封鎖 / 解封 / 白名單 / 排行，底層走 fail2ban${C0}"
    printf '\n'
    sect "壓力測試  (STRESS/stress-test.sh)"
    row "s) 進入壓測選單    ${CD}CPU / 記憶體 / 磁碟 / SWAP / NTP / 網路，會把機器操到滿載${C0}"
    printf '\n'
    sect "系統"
    row "9) 更換套件來源鏡像 ${CD}呼叫 linuxmirrors.cn 的外部腳本${C0}"
    row "d) 環境自我診斷     ${CD}檢查相依套件與已知相容性問題${C0}"
    row "i) 安裝缺少的相依套件"
    [ "$RUN_MODE" = remote ] && \
        row "u) 更新腳本快取     ${CD}重新下載所有工具腳本${C0}"
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

# =========================================================
# 封鎖管理（fail2ban）
#   自成一個子選單：項目多，塞進主選單會讓最常用的 SSH 工具被淹掉。
#   IP 相關動作一律不帶 -y，讓 fail2ban.sh 自己把「將要做什麼」印出來再問，
#   確認的邏輯只留在底層一份。
# =========================================================
f2b_ask_ip() {
    printf ' %s（可空白分隔多個，直接 Enter 取消）：' "$1"
    read -r _ips 2>/dev/null || _ips=''
    [ -n "$_ips" ]
}

act_f2b_menu() {
    require_script "$F2B_SH" "$F2B_REL" || return 0
    while :; do
        clear 2>/dev/null || printf '\n\n'
        hr
        printf '%s 封鎖管理%s  %sFAIL2BAN/fail2ban.sh%s\n' "$CB$CC" "$C0" "$CD" "$C0"
        hr
        if has fail2ban-client; then
            sh "$F2B_SH" status 2>/dev/null | sed -n '1,12p'
        else
            wmsg "這台機器還沒安裝 fail2ban（選 i 安裝）"
        fi
        hr
        row "1) 已封鎖清單"
        row "2) 手動封鎖 IP    ${CD}預設所有 jail，會先檢查會不會鎖到自己${C0}"
        row "3) 解除封鎖        ${CD}自動找出是哪些 jail 封的${C0}"
        row "4) 查詢某個 IP     ${CD}封鎖狀態 / 白名單 / 歷史次數${C0}"
        row "5) 白名單：加入    ${CD}ignoreip，寫進 jail.d 並即時生效${C0}"
        row "6) 白名單：移除"
        row "7) 封鎖次數排行    ${CD}讀 fail2ban 日誌${C0}"
        row "8) 追蹤 fail2ban 日誌"
        row "9) 清空所有封鎖    ${CD}要打 y 二次確認${C0}"
        printf '\n'
        row "e) 建立 sshd jail  ${CD}埠號取實際生效值，換過 SSH 埠後要重跑${C0}"
        row "t) 封鎖時長設定"
        row "d) 環境檢查        ${CD}含「設了但不會生效」的常見情況${C0}"
        row "i) 安裝 fail2ban"
        row "b) 返回主選單"
        printf '\n 請選擇：'
        read -r _c 2>/dev/null || return 0
        printf '\n'
        case "$_c" in
            1) sh "$F2B_SH" list ;;
            2) if f2b_ask_ip "要封鎖的 IP / CIDR"; then
                   printf ' 封鎖多久？(秒，perm = 永久，Enter = 用 jail 預設) '
                   read -r _t 2>/dev/null || _t=''
                   # shellcheck disable=SC2086
                   if [ -n "$_t" ]; then sh "$F2B_SH" ban $_ips -t "$_t"; else sh "$F2B_SH" ban $_ips; fi
               fi ;;
            3) f2b_ask_ip "要解除封鎖的 IP" && sh "$F2B_SH" unban $_ips ;;
            4) f2b_ask_ip "要查詢的 IP" && sh "$F2B_SH" check $_ips ;;
            5) f2b_ask_ip "要加白名單的 IP / CIDR" && sh "$F2B_SH" allow $_ips ;;
            6) f2b_ask_ip "要移出白名單的 IP" && sh "$F2B_SH" disallow $_ips ;;
            7) printf ' 顯示前幾名？(Enter = 15) '
               read -r _n 2>/dev/null || _n=''
               sh "$F2B_SH" top "${_n:-15}" ;;
            8) dim " Ctrl-C 離開，會回到本選單"; sleep 1; sh "$F2B_SH" tail ;;
            9) sh "$F2B_SH" unban-all ;;
            e|E) sh "$F2B_SH" enable-sshd ;;
            t|T) sh "$F2B_SH" bantime
                 printf ' 要改哪個 jail？(Enter 略過) '
                 read -r _j 2>/dev/null || _j=''
                 if [ -n "$_j" ]; then
                     printf ' 改成幾秒？(-1 = 永久) '
                     read -r _s 2>/dev/null || _s=''
                     [ -n "$_s" ] && sh "$F2B_SH" bantime "$_j" "$_s"
                 fi ;;
            d|D) sh "$F2B_SH" doctor ;;
            i|I) sh "$F2B_SH" install ;;
            b|B|q|Q|'') return 0 ;;
            *) nomsg "無此選項：$_c" ;;
        esac
        pause
    done
}

# =========================================================
# 壓力測試（stress-test.sh）
#   跟其他工具的差別有三個，都直接影響這裡怎麼包：
#   1. 它是 bash 腳本（local / pipefail / {1..78}），不是 POSIX sh，要用 bash 呼叫。
#   2. 報告一律寫進「當下工作目錄」底下的 logs/，不吃路徑參數 —— 所以是 cd 過去
#      再呼叫，而不是傳參數進去。
#   3. 參數全部走環境變數（DUR / URL / DL_URL …），選單先問完再組起來執行。
#   這些測試會真的把機器操到滿載，每一項執行前都先把「會發生什麼」攤開來再問。
# =========================================================
stress_guard() {
    require_script "$STRESS_SH" "$STRESS_REL" || return 1
    # 這支是唯一需要 bash 的自家腳本，Alpine 最小安裝上真的可能沒有
    if ! has bash; then
        nomsg "stress-test.sh 需要 bash（用到 local / pipefail 等 bash 語法）"
        row "安裝：$PKG_INSTALL bash"
        return 1
    fi
    return 0
}

# 各項目需要的工具。缺工具時 stress-test.sh 自己也會擋，但那是報告開頭才擋，
# 這裡先講可以省掉一次「跑起來才發現沒裝」。
stress_tools_of() {
    case "$1" in
        cpu)      echo "stress-ng mpstat" ;;
        ram)      echo "stress-ng" ;;
        disk)     echo "fio" ;;
        swap)     echo "stress-ng vmstat" ;;
        ntp)      echo "chronyc" ;;
        all)      echo "stress-ng mpstat fio vmstat" ;;
        baseline) echo "wrk" ;;
        traffic)  echo "curl" ;;
        mixed)    echo "wrk curl" ;;
    esac
}

# 工具 -> 套件名。發行版之間差在 procps 系列與 wrk 的來源。
stress_pkg_for() {
    case "$1" in
        stress-ng) echo stress-ng ;;
        mpstat)    echo sysstat ;;
        fio)       echo fio ;;
        chronyc)   echo chrony ;;
        curl)      echo curl ;;
        wrk)       echo wrk ;;
        vmstat)    case "$PKG" in apk|apt) echo procps ;; *) echo procps-ng ;; esac ;;
        *)         echo "$1" ;;
    esac
}

# $1 = 項目，缺的工具印到 stdout（空字串代表齊了）
stress_missing() {
    _miss=''
    for _t in $(stress_tools_of "$1"); do
        has "$_t" || _miss="$_miss $_t"
    done
    printf '%s' "${_miss# }"
}

# 選單標頭那行「工具 …」的內容
stress_tool_status() {
    _out=''
    for _t in stress-ng fio mpstat vmstat chronyc wrk curl; do
        if has "$_t"; then _out="$_out $_t $CG$MK_OK$C0 "
        else               _out="$_out $CD$_t$C0 $CR$MK_NO$C0 "
        fi
    done
    printf '%s' "${_out# }"
}

# 缺工具就印出缺什麼與怎麼補，回傳 1（呼叫端據此放棄執行）
stress_check_deps() {
    _miss=$(stress_missing "$1")
    [ -z "$_miss" ] && return 0
    nomsg "$1 需要的工具還沒裝：$_miss"
    row "按 i 安裝，或自行執行：$PKG_INSTALL $(for _t in $_miss; do stress_pkg_for "$_t"; done | sort -u | tr '\n' ' ')"
    case " $_miss " in
        *' wrk '*) row "wrk 不在 RHEL 系的 base repo，需要 EPEL 或自行編譯 https://github.com/wg/wrk" ;;
    esac
    return 1
}

stress_install() {
    printf '\n'
    sect "安裝壓測相依套件"

    # 把七項工具缺的全部湊齊一次裝完，而不是每個項目跑到才裝一次
    _miss=''
    for _t in stress-ng fio mpstat vmstat chronyc wrk curl; do
        has "$_t" || _miss="$_miss $_t"
    done
    _miss="${_miss# }"
    if [ -z "$_miss" ]; then
        okmsg "壓測工具都在，不用裝"
        return 0
    fi
    if [ "$PKG" = none ]; then
        nomsg "找不到套件管理器，請自行安裝：$_miss"
        return 0
    fi

    _pkgs=$(for _t in $_miss; do stress_pkg_for "$_t"; done | sort -u | tr '\n' ' ' | sed 's/ *$//')
    # RHEL 系的 stress-ng 與 wrk 都在 EPEL，沒先開就會是「找不到套件」
    _epel=0
    if [ "$OS_FAMILY" = rhel ]; then
        case " $_miss " in
            *' stress-ng '*|*' wrk '*) _epel=1 ;;
        esac
    fi

    row "缺少：${CB}${_miss}${C0}"
    [ "$_epel" = 1 ] && row "將先安裝 ${CB}epel-release${C0}（stress-ng / wrk 在 EPEL）"
    row "將要執行：${CB}${PKG_INSTALL} ${_pkgs}${C0}"
    case " $_miss " in
        *' wrk '*) dim "   wrk 在部分發行版沒有現成套件，裝不起來就自行編譯 https://github.com/wg/wrk" ;;
    esac
    printf '\n'
    need_root || return 0
    confirm "要執行嗎？" || return 0
    printf '\n'
    [ "$PKG" = apt ] && apt-get update
    [ "$_epel" = 1 ] && $PKG_INSTALL epel-release
    # shellcheck disable=SC2086
    $PKG_INSTALL $_pkgs
}

stress_set_dir() {
    printf '\n'
    row "報告與 fio 測試檔會寫進 ${CB}<目錄>/logs/${C0}"
    dim "   磁碟測試的測試檔最大 4GB，跑完（含 Ctrl-C）會自動刪除"
    ask_default "輸出目錄：" "$OPS_STRESS_DIR"
    [ -z "$REPLY_VAL" ] && return 0
    if ! mkdir -p "$REPLY_VAL" 2>/dev/null; then
        nomsg "建不出 $REPLY_VAL"
        return 0
    fi
    if [ ! -w "$REPLY_VAL" ]; then
        nomsg "$REPLY_VAL 不可寫"
        return 0
    fi
    OPS_STRESS_DIR=$(cd "$REPLY_VAL" 2>/dev/null && pwd) || OPS_STRESS_DIR="$REPLY_VAL"
    okmsg "輸出目錄改為 $OPS_STRESS_DIR"
}

stress_set_dur() {
    printf '\n'
    dim " 每個項目的持續秒數。disk 會把這個值平分給隨機讀 / 隨機寫 / 循序讀 / 循序寫。"
    ask_default "每項持續幾秒？" "$STRESS_DUR"
    case "$REPLY_VAL" in
        ''|*[!0-9]*) nomsg "要是正整數：$REPLY_VAL"; return 0 ;;
    esac
    [ "$REPLY_VAL" -ge 1 ] || { nomsg "要 >= 1"; return 0; }
    STRESS_DUR="$REPLY_VAL"
    okmsg "每項持續 $STRESS_DUR 秒"
}

# 執行一個項目。$1 = cpu/ram/disk/swap/ntp/all/baseline/traffic/mixed
stress_run() {
    _cmd=$1
    stress_guard || return 0
    need_root || return 0
    stress_check_deps "$_cmd" || return 0

    _url=''; _dl=''; _workers=4

    printf '\n'
    sect "壓力測試：$_cmd"
    case "$_cmd" in
        cpu)  row "把所有核心拉滿，每 3 秒記一次 loadavg 與 mpstat（含 steal）" ;;
        ram)  row "吃掉總記憶體的 80%，觀察 MemAvailable 與 SwapFree" ;;
        disk) row "隨機讀 / 隨機寫 / 循序讀 / 循序寫各跑一輪，測試檔最大 4GB，跑完自動刪除"
              row "輸出目錄可用空間：$(df -h "$OPS_STRESS_DIR" 2>/dev/null | awk 'NR==2{print $4}')" ;;
        swap) wmsg "吃到 RAM 的 95% + swap 的 50%，逼出換頁 —— 有觸發 OOM killer 的風險"
              row "開始前會把所有 sshd 的 oom_score_adj 設成 -1000（結束或中斷都會還原），"
              row "但 sshd 以外的程序仍可能被殺。建議另開一個視窗跑 dmesg -w 看著" ;;
        ntp)  wmsg "會停掉 chronyd 並把系統時鐘往前撥 2 分鐘，觀察 $STRESS_DUR 秒後還原"
              row "還原是先 date -s \"-2 minutes\" 確定性扣回，再讓 chronyd makestep 修殘差；"
              row "正常結束與 Ctrl-C 都會還原，但觀察期間這台機器的時間是錯的" ;;
        all)  row "依序跑 cpu -> ram -> disk -> swap，寫在同一份報告裡（不含 ntp）"
              row "預估耗時：約 $(( STRESS_DUR * 4 / 60 + 1 )) 分鐘" ;;
    esac

    # 網路測試的目標是「你授權要打的東西」，沒有預設值，一定要問
    case "$_cmd" in
        baseline|mixed)
            row "wrk 會對目標產生真實高併發請求（預設 2 執行緒 / 50 連線）"
            nomsg "只能填你自己有權壓測的網站，打別人的站等同一次小型 DoS"
            ask_default "壓測目標 URL（例 http://127.0.0.1/）：" "${URL:-}"
            _url="$REPLY_VAL"
            case "$_url" in
                http://*|https://*) : ;;
                '') printf ' 已取消\n'; return 0 ;;
                *)  nomsg "URL 要以 http:// 或 https:// 開頭"; return 0 ;;
            esac ;;
    esac
    case "$_cmd" in
        traffic|mixed)
            row "curl 會反覆下載到測試結束，內容丟 /dev/null，不落磁碟"
            row "建議用你自己控制的來源；公開測速檔只適合短時間驗證，別長時間連續灌"
            ask_default "下載來源 DL_URL（逗號分隔可多個）：" "${DL_URL:-}"
            _dl="$REPLY_VAL"
            case "$_dl" in
                http://*|https://*) : ;;
                '') printf ' 已取消\n'; return 0 ;;
                *)  nomsg "DL_URL 要以 http:// 或 https:// 開頭"; return 0 ;;
            esac
            ask_default "同時幾個下載程序？" "${DL_WORKERS:-4}"
            _workers="$REPLY_VAL"
            case "$_workers" in
                ''|*[!0-9]*) nomsg "下載程序數要是正整數：$_workers"; return 0 ;;
            esac
            [ "$_workers" -ge 1 ] || { nomsg "下載程序數要 >= 1"; return 0; } ;;
    esac

    printf '\n'
    row "每項持續 ${CB}${STRESS_DUR}${C0} 秒"
    row "報告寫入 ${CB}${OPS_STRESS_DIR}/logs/${_cmd}-<時間戳>.log${C0}"
    [ -n "$_url" ] && row "壓測目標 ${CB}${_url}${C0}"
    [ -n "$_dl" ]  && row "下載來源 ${CB}${_dl}${C0}（$_workers 個程序）"
    dim "   Ctrl-C 中斷仍會輸出摘要並清乾淨，前面跑完的項目不會白費"
    printf '\n'
    wmsg "這會真的把機器操到滿載，不要在正式環境跑"
    confirm "要開始嗎？" || return 0
    printf '\n'

    # cd 過去再跑：那支腳本把報告與 fio 測試檔寫在「當下工作目錄」底下的 logs/。
    # 用子 shell 包起來，選單本身的工作目錄不會被換掉。
    ( cd "$OPS_STRESS_DIR" 2>/dev/null || { nomsg "進不去 $OPS_STRESS_DIR"; exit 1; }
      DUR="$STRESS_DUR" URL="$_url" DL_URL="$_dl" DL_WORKERS="$_workers" \
          bash "$STRESS_SH" "$_cmd" )
}

act_stress_menu() {
    stress_guard || return 0
    while :; do
        clear 2>/dev/null || printf '\n\n'
        hr
        printf '%s 壓力測試%s  %sSTRESS/stress-test.sh%s\n' "$CB$CC" "$C0" "$CD" "$C0"
        hr
        printf ' 輸出   %s%s/logs/%s\n' "$CB" "$OPS_STRESS_DIR" "$C0"
        printf ' 參數   每項持續 %s%s%s 秒\n' "$CB" "$STRESS_DUR" "$C0"
        printf ' 工具   %s\n' "$(stress_tool_status)"
        hr
        sect "本機壓測"
        row "1) CPU             ${CD}所有核心拉滿，看 bogo ops 與 steal${C0}"
        row "2) 記憶體          ${CD}吃掉總記憶體 80%${C0}"
        row "3) 磁碟讀寫        ${CD}隨機/循序 各讀寫一輪，重點在 p99 尾端延遲${C0}"
        row "4) SWAP            ${CD}逼出換頁，有 OOM 風險，會先保護 sshd${C0}"
        row "5) NTP 時間偏移    ${CD}時鐘往前撥 2 分鐘再還原，要單獨跑${C0}"
        row "6) 全部            ${CD}cpu -> ram -> disk -> swap，同一份報告（不含 ntp）${C0}"
        printf '\n'
        sect "網路測試  (主機扛下載流量時網站還通不通)"
        row "7) baseline        ${CD}只壓網站建立基準，需要 URL${C0}"
        row "8) traffic         ${CD}只灌下載流量，需要 DL_URL${C0}"
        row "9) mixed           ${CD}下載流量 + 網站壓測同時，兩者都要${C0}"
        printf '\n'
        sect "設定"
        row "t) 每項持續秒數    ${CD}目前 $STRESS_DUR${C0}"
        row "o) 輸出目錄        ${CD}目前 $OPS_STRESS_DIR${C0}"
        row "i) 安裝壓測相依套件"
        row "b) 返回主選單"
        printf '\n 請選擇：'
        read -r _c 2>/dev/null || return 0
        printf '\n'
        case "$_c" in
            1) stress_run cpu ;;
            2) stress_run ram ;;
            3) stress_run disk ;;
            4) stress_run swap ;;
            5) stress_run ntp ;;
            6) stress_run all ;;
            7) stress_run baseline ;;
            8) stress_run traffic ;;
            9) stress_run mixed ;;
            t|T) stress_set_dur ;;
            o|O) stress_set_dir ;;
            i|I) stress_install ;;
            b|B|q|Q|'') return 0 ;;
            *) nomsg "無此選項：$_c" ;;
        esac
        pause
    done
}

# 問一題：$1=提示 $2=預設值，回答放進 REPLY_VAL
ask_default() {
    printf ' %s%s%s ' "$CC" "$1" "$C0"
    [ -n "$2" ] && printf '%s(Enter = %s)%s ' "$CD" "$2" "$C0"
    read -r REPLY_VAL 2>/dev/null || REPLY_VAL=''
    [ -z "$REPLY_VAL" ] && REPLY_VAL="$2"
}

# 問 true/false：$1=提示 $2=預設（true/false）
ask_bool() {
    ask_default "$1" "$2"
    case "$REPLY_VAL" in
        y|Y|yes|YES|true|TRUE|1|是)  REPLY_VAL=true ;;
        n|N|no|NO|false|FALSE|0|否)  REPLY_VAL=false ;;
        *) REPLY_VAL="$2" ;;
    esac
}

act_mirror() {
    _url='https://linuxmirrors.cn/main.sh'      # 內建預設，讀不到 REPO/URL 時用這個
    if [ -r "$MIRROR_URL_FILE" ]; then
        # 取「第一行看起來像網址的」，不是 head -1：那個檔案可能開頭有空行或註解，
        # head -1 會拿到空字串，然後把空網址丟給 curl（curl: (3) <url> malformed）。
        _u=$(awk '/^[ \t]*https?:\/\// { gsub(/[ \t\r]/, ""); print; exit }' \
             "$MIRROR_URL_FILE" 2>/dev/null)
        case "$_u" in
            http://*|https://*) _url="$_u" ;;
            *) wmsg "$MIRROR_URL_FILE 裡找不到網址，改用內建預設" ;;
        esac
    fi

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

    # 先把參數問完再執行。那支腳本本來會在跑到一半時逐項互動詢問（協議、內外網、
    # 要不要覆蓋 EPEL、要不要順便升級套件…），問題散在輸出中間很容易看漏就按下去。
    # 這裡先一次問完並組成命令列參數，執行前把完整指令攤開來看。
    sect "參數設定（直接 Enter 用預設值）"
    _args=''

    printf '\n'
    row "鏡像站："
    row "  ${CB}1${C0}) 阿里云      mirrors.aliyun.com"
    row "  ${CB}2${C0}) 腾讯云      mirrors.tencent.com"
    row "  ${CB}3${C0}) 华为云      mirrors.huaweicloud.com"
    row "  ${CB}4${C0}) 网易        mirrors.163.com"
    row "  ${CB}5${C0}) 清华大学    mirrors.tuna.tsinghua.edu.cn"
    row "  ${CB}6${C0}) 中科大      mirrors.ustc.edu.cn"
    row "  ${CB}c${C0}) 自訂網域"
    row "  ${CD}Enter = 不指定，讓腳本自己列選單讓你挑${C0}"
    ask_default "選擇：" ""
    case "$REPLY_VAL" in
        1) _args="$_args --source mirrors.aliyun.com" ;;
        2) _args="$_args --source mirrors.tencent.com" ;;
        3) _args="$_args --source mirrors.huaweicloud.com" ;;
        4) _args="$_args --source mirrors.163.com" ;;
        5) _args="$_args --source mirrors.tuna.tsinghua.edu.cn" ;;
        6) _args="$_args --source mirrors.ustc.edu.cn" ;;
        c|C) ask_default "鏡像站網域（例如 mirrors.example.com）：" ""
             [ -n "$REPLY_VAL" ] && _args="$_args --source $REPLY_VAL" ;;
        *) : ;;
    esac

    ask_default "連線協議 http / https：" "http"
    case "$REPLY_VAL" in
        http|https) _args="$_args --protocol $REPLY_VAL" ;;
        *) _args="$_args --protocol http" ;;
    esac

    ask_bool "優先使用內網位址？（雲主機內網通常較快）" "false"
    _args="$_args --use-intranet-source $REPLY_VAL"

    if [ "$OS_FAMILY" = rhel ]; then
        ask_bool "安裝 / 覆蓋 EPEL 附加軟體源？" "true"
        _args="$_args --install-epel $REPLY_VAL"
    fi

    ask_bool "備份原有的軟體源設定？" "true"
    _args="$_args --backup $REPLY_VAL"
    if [ "$REPLY_VAL" = true ]; then
        ask_bool "已有舊備份時直接覆蓋？（選 false 會在執行中途問你）" "true"
        [ "$REPLY_VAL" = true ] && _args="$_args --ignore-backup-tips"
    fi

    ask_bool "換源後順便升級所有軟體包？" "false"
    _args="$_args --upgrade-software $REPLY_VAL"
    if [ "$REPLY_VAL" = true ]; then
        ask_bool "升級後清理下載快取？" "true"
        _args="$_args --clean-cache $REPLY_VAL"
    fi

    printf '\n'
    row "將要執行："
    if has curl; then
        row "  ${CB}curl -sSL $_url | bash -s --$_args${C0}"
    else
        row "  ${CB}wget -qO- $_url | bash -s --$_args${C0}"
    fi
    dim "   （沒指定的項目仍會由該腳本自己詢問）"
    printf '\n'

    case "$_url" in
        http://*|https://*) : ;;
        *) nomsg "取不到合法的來源網址（$MIRROR_URL_FILE 內容異常）"
           row "請重新執行選單的 u 更新快取，或自行執行："
           row "  curl -sSL https://linuxmirrors.cn/main.sh | bash"
           return 0 ;;
    esac

    printf ' %s請輸入 %sYES%s%s 以確認執行（其他任何輸入都會取消）：%s ' "$CY" "$CB" "$C0" "$CY" "$C0"
    read -r _a 2>/dev/null || _a=''
    [ "$_a" = YES ] || { printf ' 已取消\n'; return 0; }

    printf '\n'
    # shellcheck disable=SC2086
    if has curl; then
        curl -sSL "$_url" | bash -s -- $_args
    else
        wget -qO- "$_url" | bash -s -- $_args
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
    for _s in "$SSH_PORT_SH" "$SELFHEAL_SH" "$F2B_SH" "$STRESS_SH"; do
        if [ -f "$_s" ]; then
            [ -x "$_s" ] && okmsg "$_s" || wmsg "$_s（無執行權限，本選單以 sh/bash 呼叫故仍可用）"
        elif [ "$RUN_MODE" = remote ]; then
            nomsg "$_s 尚未下載成功（選 u 重試，或檢查對外連線）"
        else
            nomsg "$_s 不存在"
        fi
    done
    hr
    # 壓測工具刻意不併進上面的相依檢查：缺了只影響壓力測試，主選單的 i
    # 不該因此去裝 fio / stress-ng。要裝走壓測選單的 i。
    sect "壓測工具（缺了只影響壓力測試，選單 s -> i 安裝）"
    row "$(stress_tool_status)"
    row "壓測報告輸出：$OPS_STRESS_DIR/logs/"
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
# 開場：更新快取 + 自檢
#   選單開出來之前先把「等一下會用到的東西」準備好並確認可用，不要等到選下去
#   才發現工具是舊的、或封鎖根本寫不進防火牆。
# =========================================================
startup_tasks() {
    _notes=0        # 有東西要講才停下來等 Enter，沒事就直接進選單

    if [ "$RUN_MODE" = remote ]; then
        if [ "${OPS_NO_UPDATE:-0}" = 1 ]; then
            dim " 已略過自動更新（OPS_NO_UPDATE=1）"
        elif [ "$PENDING" = 1 ]; then
            # 換埠進行中時覆蓋 ssh-port.sh 會影響看門狗的還原行為，跟選單 u 同樣的顧慮
            wmsg "有未確認的換埠作業，本次略過自動更新（confirm / rollback 之後再更新）"
            _notes=1
        else
            printf ' 更新工具… '
            if assets_sync update >/dev/null 2>&1; then
                printf '%s%s%s\n' "$CG" "$MK_OK" "$C0"
            else
                printf '%s%s%s 失敗，沿用既有快取\n' "$CY" "$MK_WARN" "$C0"
                _notes=1
            fi
        fi
    fi

    # 相依：只在有硬缺失時出聲
    check_deps >/dev/null 2>&1
    if [ "${DEP_HARD:-0}" = 1 ]; then
        nomsg "有必要套件缺失，部分功能無法運作（按 d 看細節、i 安裝）"
        _notes=1
    fi

    # 封鎖後端：沒問題就完全安靜。判斷邏輯留在 fail2ban.sh 裡，這邊不複製一份。
    if [ -f "$F2B_SH" ]; then
        _pf=$(sh "$F2B_SH" preflight 2>/dev/null)
        [ -n "$_pf" ] && { printf '%s\n' "$_pf"; _notes=1; }
    fi

    if [ "$_notes" = 1 ]; then
        printf '\n%s按 Enter 進入選單…%s' "$CD" "$C0"
        read -r _ignored 2>/dev/null || true
    fi
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

    此模式會把各工具腳本下載到 $(cache_dir) 後再呼叫。
    換埠的看門狗會回頭呼叫該路徑做自動還原，確認完成前請勿刪除。

選項
    --no-update    略過開場的自動更新（等同 OPS_NO_UPDATE=1）

環境變數
    OPS_RAW_BASE   遠端來源前綴（fork / 內網鏡像 / 其他分支）
                   目前：$OPS_RAW_BASE
    OPS_SSH_DIR    SSH/ 腳本的產出目錄（狀態、備份、看門狗、日誌、取證報告）
                   目前：$OPS_SSH_DIR
    OPS_STRESS_DIR 壓測報告的輸出目錄（報告落在它底下的 logs/）
                   預設是執行 ops.sh 時所在的目錄，目前：$OPS_STRESS_DIR
    NO_COLOR       關閉顏色

目前模式：$RUN_MODE（工具路徑 $ASSET_DIR）
EOF
    exit 0
}

ui_init
detect

# 選項可以出現在子命令前後
for _a in "$@"; do
    case "$_a" in
        --no-update) OPS_NO_UPDATE=1 ;;
    esac
done

case "${1:-}" in
    --no-update) shift ;;
esac

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
    printf '%s\n' "    DUR=60 bash $STRESS_SH cpu"
    printf '%s\n' "或執行 ops.sh doctor 做環境檢查。"
    exit 1
fi

startup_tasks

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
        b|B) act_f2b_menu ;;
        s|S) act_stress_menu ;;
        d|D) act_doctor ;;
        i|I) act_install_deps ;;
        u|U) act_refresh ;;
        q|Q|exit|quit) printf ' 離開\n'; exit 0 ;;
        '') continue ;;
        *) nomsg "無此選項：$choice" ;;
    esac
    pause
done
