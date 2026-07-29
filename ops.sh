#!/bin/sh
# ops.sh — OPS-command 視覺化操作選單
#
# 一支入口把 SSH/ 底下的工具包起來，用選單操作，不必記參數。
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 用法：
#   ./ops.sh            進入互動選單
#   ./ops.sh doctor     只做環境檢查後離開（可寫進巡檢排程）
#   ./ops.sh -h         說明
#
# 設計原則：
#   1. POSIX sh 撰寫，Alpine 的 busybox ash 與 CentOS 7 的舊 bash 都能跑，
#      本身零相依（不需要 dialog / whiptail / ncurses）。
#   2. 只做「導覽 + 前置檢查 + 呼叫」，所有實際變更都在被呼叫的腳本裡，
#      選單不自己碰系統設定，出事時追查範圍才不會擴散。
#   3. 每個危險動作在執行前先把「會動到什麼」印出來，並要求二次確認。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

OPS_VERSION=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
BASE=$(dirname "$SELF")

SSH_DIR="$BASE/SSH"
SSH_PORT_SH="$SSH_DIR/ssh-port.sh"
SELFHEAL_SH="$SSH_DIR/selfheal-ssh.sh"
MIRROR_URL_FILE="$BASE/REPO/URL"

PORT_STATE=/var/lib/ssh-port/state

has() { command -v "$1" >/dev/null 2>&1; }

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
    row "請用 sudo -i 或 su - 切換後重跑：$SELF"
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
    [ -f "$PORT_STATE" ] && PENDING=1
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
    row "6) 一次性取證      ${CD}完整報告寫入 /var/log/n9e-selfheal/${C0}"
    row "7) 追蹤認證日誌    ${CD}即時 tail 登入成功/失敗事件${C0}"
    row "8) 解析排查        ${CD}傾印原始 ss / ps 資料，回報問題時用${C0}"
    printf '\n'
    sect "系統"
    row "9) 更換套件來源鏡像 ${CD}呼叫 linuxmirrors.cn 的外部腳本${C0}"
    row "d) 環境自我診斷     ${CD}檢查相依套件與已知相容性問題${C0}"
    row "i) 安裝缺少的相依套件"
    row "q) 離開"
    printf '\n'
}

# =========================================================
# 動作
# =========================================================
require_script() {
    [ -f "$1" ] && return 0
    nomsg "找不到 $1"
    row "請確認是從 repo 根目錄執行 ops.sh，且 SSH/ 目錄完整"
    return 1
}

act_port_status() {
    require_script "$SSH_PORT_SH" || return 0
    sh "$SSH_PORT_SH" status
}

act_port_set() {
    require_script "$SSH_PORT_SH" || return 0
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
    require_script "$SSH_PORT_SH" || return 0
    need_root || return 0
    printf '\n'
    wmsg "確認前請先在「另一個新視窗」用新埠登入成功，不要只看這個舊連線還活著"
    confirm "已經用新埠登入成功了嗎？" || return 0
    sh "$SSH_PORT_SH" confirm
}

act_port_rollback() {
    require_script "$SSH_PORT_SH" || return 0
    need_root || return 0
    printf '\n'
    confirm "要立即還原 SSH 埠設定嗎？" || return 0
    sh "$SSH_PORT_SH" rollback
}

selfheal_guard() {
    require_script "$SELFHEAL_SH" || return 1
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
    dim " 完整報告寫入 /var/log/n9e-selfheal/ssh-health.log，以下是摘要："
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
    hr
    sect "相依套件"
    check_deps
    hr
    sect "腳本"
    for _s in "$SSH_PORT_SH" "$SELFHEAL_SH"; do
        if [ -f "$_s" ]; then
            [ -x "$_s" ] && okmsg "$_s" || wmsg "$_s（無執行權限，本選單以 sh/bash 呼叫故仍可用）"
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
usage() {
    sed -n '3,20p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
}

ui_init
detect

case "${1:-}" in
    -h|--help|help) usage ;;
    doctor|--doctor)
        act_doctor
        printf '\n'
        [ "${DEP_HARD:-0}" = 1 ] && exit 1
        exit 0 ;;
    '') : ;;
    *) printf '未知參數：%s（可用 doctor / -h）\n' "$1"; exit 1 ;;
esac

if [ ! -t 0 ]; then
    printf '%s\n' "ops.sh 是互動選單，需要終端機。"
    printf '%s\n' "非互動場合請直接呼叫底層腳本，例如："
    printf '%s\n' "    sh SSH/ssh-port.sh status"
    printf '%s\n' "    sh SSH/selfheal-ssh.sh oneshot"
    printf '%s\n' "或執行 ops.sh doctor 做環境檢查。"
    exit 1
fi

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
        q|Q|exit|quit) printf ' 離開\n'; exit 0 ;;
        '') continue ;;
        *) nomsg "無此選項：$choice" ;;
    esac
    pause
done
