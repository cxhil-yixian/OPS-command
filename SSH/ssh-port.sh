#!/bin/sh
# ssh-port.sh — 安全變更 SSH 連接埠
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 設計原則：不讓你把自己鎖在門外。
#
#   1. set  階段：新舊埠「同時」監聽，並啟動看門狗
#   2. 你用新埠開一個新連線確認可以登入
#   3. confirm 階段：收掉舊埠，取消看門狗
#
#   若在時限內沒有 confirm，看門狗會自動還原所有變更（設定檔、防火牆、
#   SELinux、socket override），因此就算新埠完全連不上也不會失聯。
#
# 用法：
#   ./ssh-port.sh set 58763          變更為 58763（雙埠並存 + 看門狗）
#   ./ssh-port.sh set 58763 -t 900   看門狗時限改 900 秒（預設 600）
#   ./ssh-port.sh confirm            確認新埠可用，收掉舊埠
#   ./ssh-port.sh rollback           立即還原
#   ./ssh-port.sh status             顯示目前狀態
#   ./ssh-port.sh set 58763 -n       只印出將要做什麼，不實際變更
#
# 以 POSIX sh 撰寫，Alpine 不需額外安裝 bash。

set -u

VERSION=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# 一行指令執行（bash <(curl …)、curl … | sh）時 $0 是行程替換的 fd 或 "sh"，
# 不是實體檔案。看門狗必須把「本腳本路徑 rollback --auto」寫進背景排程才能
# 自動還原，路徑不存在就等於還原機制失效——換埠失敗時會真的被鎖在門外，
# 所以這種執行方式直接拒絕，不做降級。
if [ ! -f "$SELF" ]; then
    {
        echo "ssh-port.sh 不能用管線 / 行程替換的方式執行（\$0 = $0）。"
        echo "看門狗需要本腳本的實體路徑才能自動還原，否則換埠失敗會把你鎖在門外。"
        echo
        echo "請改用選單入口，它會先把腳本下載到本機再呼叫："
        echo "  bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh)"
        echo "或直接取得 repo："
        echo "  git clone https://github.com/cxhil-yixian/OPS-command.git"
        echo "  sh OPS-command/SSH/ssh-port.sh status"
    } >&2
    exit 1
fi

# SSHPORT_TEST_ROOT 僅供測試用，會把所有設定檔路徑加上前綴
PREFIX="${SSHPORT_TEST_ROOT:-}"

SSHD_CONFIG="${PREFIX}/etc/ssh/sshd_config"
SSHD_CONFD="${PREFIX}/etc/ssh/sshd_config.d"
DROPIN="${SSHD_CONFD}/00-ssh-port.conf"
SOCKET_DIR="${PREFIX}/etc/systemd/system/ssh.socket.d"
SOCKET_OVERRIDE="${SOCKET_DIR}/override.conf"

STATE_DIR="${PREFIX}/var/lib/ssh-port"
STATE="${STATE_DIR}/state"
LOGFILE="${PREFIX}/var/log/ssh-port.log"

MARK_BEGIN="# >>> ssh-port.sh 管理區塊 開始 >>>"
MARK_END="# <<< ssh-port.sh 管理區塊 結束 <<<"

DEFAULT_TIMEOUT=600

# ---------- 輸出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
    CB=$(printf '\033[1m');  CD=$(printf '\033[2m');  C0=$(printf '\033[0m')
else
    CR=''; CG=''; CY=''; CB=''; CD=''; C0=''
fi

_log()  { printf '%s\n' "$*" ; [ -w "$(dirname "$LOGFILE")" ] 2>/dev/null && \
          printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$LOGFILE" 2>/dev/null; return 0; }
info()  { _log "  $*"; }
step()  { _log "${CB}==>${C0} $*"; }
ok()    { _log "${CG}  ✓${C0} $*"; }
warn()  { _log "${CY}  !${C0} $*"; }
err()   { _log "${CR}  ✗${C0} $*"; }
die()   { err "$*"; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# 對外 IP。busybox 的 hostname 沒有 -I，且失敗時會走 awk 而不觸發 ||，
# 結果是印出空字串——提示訊息裡少了 IP 等於少了最關鍵的那一行，故逐一退回。
primary_ip() {
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$_ip" ] && _ip=$(ip -4 -o addr show scope global 2>/dev/null \
                           | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -z "$_ip" ] && _ip=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' \
                           | sed 's/addr://' | grep -v '^127\.' | head -1)
    [ -z "$_ip" ] && _ip='<主機IP>'
    echo "$_ip"
}

usage() {
    sed -n '3,30p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 0
}

# =========================================================
# 環境偵測
# =========================================================
detect_env() {
    # --- 發行版 ---
    if [ -r "${PREFIX}/etc/os-release" ]; then
        . "${PREFIX}/etc/os-release"
    else
        ID=unknown; ID_LIKE=''; PRETTY_NAME=unknown
    fi
    OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
    case " ${ID_LIKE:-} ${ID:-} " in
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) OS_FAMILY=rhel ;;
        *debian*|*ubuntu*)                            OS_FAMILY=debian ;;
        *alpine*)                                     OS_FAMILY=alpine ;;
        *)                                            OS_FAMILY=unknown ;;
    esac

    # --- init 系統 ---
    if [ -d /run/systemd/system ]; then
        INIT=systemd
    elif has rc-service; then
        INIT=openrc
    else
        INIT=sysv
    fi

    # --- 服務名（RHEL/Alpine 是 sshd，Debian 系是 ssh）---
    SSH_SVC=sshd
    if [ "$INIT" = systemd ]; then
        if systemctl cat sshd.service >/dev/null 2>&1; then
            SSH_SVC=sshd
        elif systemctl cat ssh.service >/dev/null 2>&1; then
            SSH_SVC=ssh
        fi
    elif [ "$OS_FAMILY" = debian ]; then
        SSH_SVC=ssh
    fi

    # --- socket activation：Ubuntu 24.04 預設啟用，此時 sshd_config 的 Port 完全無效 ---
    SOCKET_UNIT=''
    if [ "$INIT" = systemd ]; then
        for u in ssh.socket sshd.socket; do
            if systemctl is-active "$u" >/dev/null 2>&1; then SOCKET_UNIT="$u"; break; fi
            if systemctl is-enabled "$u" >/dev/null 2>&1; then SOCKET_UNIT="$u"; break; fi
        done
    fi
    # override 目錄要跟著實際的 unit 名字走
    if [ -n "$SOCKET_UNIT" ]; then
        SOCKET_DIR="${PREFIX}/etc/systemd/system/${SOCKET_UNIT}.d"
        SOCKET_OVERRIDE="${SOCKET_DIR}/override.conf"
    fi

    # --- sshd_config 是否支援 / 已使用 Include（OpenSSH 8.2+）---
    USE_DROPIN=0
    if grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null; then
        USE_DROPIN=1
    fi

    # --- SELinux ---
    SELINUX=disabled
    if has getenforce; then
        SELINUX=$(getenforce 2>/dev/null | tr 'A-Z' 'a-z')
    elif [ -r /sys/fs/selinux/enforce ]; then
        [ "$(cat /sys/fs/selinux/enforce)" = 1 ] && SELINUX=enforcing || SELINUX=permissive
    fi

    # --- 防火牆 ---
    FW=none
    if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        FW=firewalld
    elif has ufw && ufw status 2>/dev/null | head -1 | grep -qi active; then
        FW=ufw
    elif has nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
        FW=nftables
    elif has iptables && iptables -S 2>/dev/null | grep -qE '^-A INPUT'; then
        FW=iptables
    fi
}

# 目前實際生效的埠。sshd -T 是唯一可靠來源，設定檔可能被 Include 或 Match 影響。
current_ports() {
    p=''
    if [ -z "$PREFIX" ] && has sshd; then
        p=$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}')
    fi
    if [ -z "$p" ]; then
        p=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
            "$SSHD_CONFIG" "$SSHD_CONFD"/*.conf 2>/dev/null | awk '{print $2}')
    fi
    [ -z "$p" ] && p=22
    echo "$p" | sort -un
}

# socket 模式下真正生效的是 ListenStream
current_socket_ports() {
    [ -n "$SOCKET_UNIT" ] || return 0
    systemctl show "$SOCKET_UNIT" -p Listen 2>/dev/null \
        | tr ' ' '\n' | grep -oE '[0-9]+$' | sort -un
}

# =========================================================
# 埠號檢查
# =========================================================
validate_port() {
    _p="$1"
    case "$_p" in
        ''|*[!0-9]*) die "埠號必須是數字：$_p" ;;
    esac
    [ "$_p" -ge 1 ] 2>/dev/null && [ "$_p" -le 65535 ] || die "埠號需在 1-65535 之間：$_p"

    if [ "$_p" -lt 1024 ]; then
        warn "埠號 $_p 屬於特權埠，僅 root 可綁定（sshd 是 root 執行，可用但要確認沒被佔）"
    fi
    if [ "$_p" = 22 ]; then
        warn "指定的就是預設埠 22，這樣做沒有意義"
    fi

    # 被別的程式佔用？（排除 sshd 自己）
    if [ -z "$PREFIX" ]; then
        _used=''
        if has ss; then
            _used=$(ss -ltnp 2>/dev/null | awk -v p=":$_p\$" '$4 ~ p {print $0}')
        elif has netstat; then
            _used=$(netstat -ltnp 2>/dev/null | awk -v p=":$_p\$" '$4 ~ p {print $0}')
        fi
        if [ -n "$_used" ] && ! printf '%s' "$_used" | grep -q sshd; then
            err "埠 $_p 已被其他程式佔用："
            printf '%s\n' "$_used" | sed 's/^/      /'
            [ "$FORCE" = 1 ] || die "換一個埠，或加 --force 強制繼續"
        fi
    fi

    # 常見服務埠提醒
    case "$_p" in
        80|443|3306|5432|6379|8080|8443|9200|27017)
            warn "埠 $_p 是常見服務埠，容易與其他服務衝突或被掃描" ;;
    esac
}

# =========================================================
# 備份與狀態
# =========================================================
backup_all() {
    BACKUP="${STATE_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP" || die "無法建立備份目錄 $BACKUP"
    cp -a "$SSHD_CONFIG" "$BACKUP/sshd_config" 2>/dev/null
    if [ -d "$SSHD_CONFD" ]; then
        mkdir -p "$BACKUP/sshd_config.d"
        cp -a "$SSHD_CONFD"/. "$BACKUP/sshd_config.d/" 2>/dev/null
    fi
    if [ -n "$SOCKET_UNIT" ] && [ -f "$SOCKET_OVERRIDE" ]; then
        mkdir -p "$BACKUP/socket.d"
        cp -a "$SOCKET_OVERRIDE" "$BACKUP/socket.d/override.conf" 2>/dev/null
    fi
    ok "設定已備份到 $BACKUP"
}

state_set() {
    mkdir -p "$STATE_DIR"
    {
        echo "OLD_PORTS='$OLD_PORTS'"
        echo "NEW_PORT='$NEW_PORT'"
        echo "BACKUP='$BACKUP'"
        echo "SOCKET_UNIT='$SOCKET_UNIT'"
        echo "SOCKET_EXISTED='$SOCKET_EXISTED'"
        echo "USE_DROPIN='$USE_DROPIN'"
        echo "FW='$FW'"
        echo "FW_ADDED='$FW_ADDED'"
        echo "SEL_ADDED='$SEL_ADDED'"
        echo "SSH_SVC='$SSH_SVC'"
        echo "STAMP='$(date -Is 2>/dev/null || date)'"
    } > "$STATE"
    chmod 600 "$STATE" 2>/dev/null
}

state_load() {
    [ -f "$STATE" ] || die "找不到狀態檔 $STATE，沒有進行中的變更"
    # shellcheck disable=SC1090
    . "$STATE"
}

# =========================================================
# 設定檔寫入
#   PORTS 參數為以空白分隔的埠號列表，sshd 的 Port 指令是累加的，
#   寫多行就會同時監聽多個埠——雙埠並存就是靠這個特性。
# =========================================================
write_sshd_ports() {
    # 去重：新埠與既有埠相同時若寫出兩行 Port，sshd 會重複 bind 而啟動失敗
    _ports=$(printf '%s\n' $1 | sort -un | tr '\n' ' ' | sed 's/ *$//')
    _block=$(
        printf '%s\n' "$MARK_BEGIN"
        printf '%s\n' "# 由 ssh-port.sh 於 $(date '+%F %T') 產生，勿手動編輯此區塊"
        for _q in $_ports; do printf 'Port %s\n' "$_q"; done
        printf '%s\n' "$MARK_END"
    )

    # 先移除本腳本先前寫過的區塊，否則重複執行會疊加，
    # 舊區塊裡的 Port 仍會生效（Port 是累加的），等於舊埠根本沒收掉。
    remove_our_block "$SSHD_CONFIG"

    if [ "$USE_DROPIN" = 1 ]; then
        mkdir -p "$SSHD_CONFD"
        printf '%s\n' "$_block" > "$DROPIN"
        chmod 600 "$DROPIN" 2>/dev/null
        ok "已寫入 drop-in：$DROPIN"
        # 主設定檔若另有 Port 會與 drop-in 累加，必須註解掉
        comment_main_ports
    else
        # 舊版 OpenSSH 不支援 Include（CentOS 7 = 7.4），只能改主設定檔。
        # 一定要插在檔案「最前面」：附加到檔尾可能落入 Match 區塊內，
        # 那樣設定只對特定條件生效，是很難察覺的錯誤。
        comment_main_ports
        _tmp="${SSHD_CONFIG}.sshport.$$"
        { printf '%s\n\n' "$_block"; cat "$SSHD_CONFIG"; } > "$_tmp" || die "寫入暫存檔失敗"
        cat "$_tmp" > "$SSHD_CONFIG" && rm -f "$_tmp"
        ok "已寫入主設定檔開頭：$SSHD_CONFIG"
    fi
}

remove_our_block() {
    _f="$1"
    [ -f "$_f" ] || return 0
    grep -qF "$MARK_BEGIN" "$_f" 2>/dev/null || return 0
    sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$_f"
    info "已移除 $_f 內既有的管理區塊"
}

# 註解掉不是由本腳本管理的 Port 行
comment_main_ports() {
    for _f in "$SSHD_CONFIG" "$SSHD_CONFD"/*.conf; do
        [ -f "$_f" ] || continue
        [ "$_f" = "$DROPIN" ] && continue
        grep -qiE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$_f" 2>/dev/null || continue
        sed -i 's/^[[:space:]]*[Pp]ort[[:space:]]\+\([0-9]\+\)/#ssh-port.sh# Port \1/' "$_f"
        info "已註解 $_f 內既有的 Port 設定"
    done
}

# 清掉本腳本寫過的所有內容（rollback 用備份還原，這裡是保險）
clean_our_config() {
    [ -f "$DROPIN" ] && rm -f "$DROPIN"
    if [ -f "$SSHD_CONFIG" ]; then
        sed -i "\|$MARK_BEGIN|,\|$MARK_END|d" "$SSHD_CONFIG" 2>/dev/null
        sed -i 's/^#ssh-port\.sh# Port /Port /' "$SSHD_CONFIG" 2>/dev/null
    fi
}

# socket activation：這才是 Ubuntu 24.04 真正決定監聽埠的地方
write_socket_ports() {
    [ -n "$SOCKET_UNIT" ] || return 0
    _ports=$(printf '%s\n' $1 | sort -un | tr '\n' ' ' | sed 's/ *$//')
    mkdir -p "$SOCKET_DIR"
    {
        echo "# 由 ssh-port.sh 產生"
        echo "[Socket]"
        echo "ListenStream="          # 空值用來清掉 unit 原本的設定，不可省略
        for _q in $_ports; do echo "ListenStream=$_q"; done
    } > "$SOCKET_OVERRIDE"
    ok "已寫入 socket override：$SOCKET_OVERRIDE"
}

# =========================================================
# SELinux
#   RHEL 系上沒做這步，sshd 會在 bind 時被拒絕，服務起不來 = 直接失聯。
# =========================================================
selinux_add() {
    SEL_ADDED=0
    [ "$OS_FAMILY" = rhel ] || return 0
    case "$SELINUX" in enforcing|permissive) : ;; *) return 0 ;; esac

    if ! has semanage; then
        err "SELinux 為 $SELINUX 但找不到 semanage 指令"
        info "sshd 將無法綁定非標準埠。請先安裝："
        if [ "${VERSION_ID%%.*}" = 7 ]; then
            info "    yum install -y policycoreutils-python"
        else
            info "    dnf install -y policycoreutils-python-utils"
        fi
        die "安裝後再重新執行"
    fi

    if semanage port -l 2>/dev/null | grep -E '^ssh_port_t' | grep -qw "$NEW_PORT"; then
        ok "SELinux：埠 $NEW_PORT 已標記為 ssh_port_t"
        return 0
    fi

    step "SELinux：標記埠 $NEW_PORT 為 ssh_port_t"
    if semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null; then
        SEL_ADDED=1; ok "已新增標籤"
    elif semanage port -m -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null; then
        SEL_ADDED=1; ok "已修改既有標籤（該埠原屬其他類型）"
    else
        die "semanage 設定失敗，中止以免 sshd 無法啟動"
    fi
}

selinux_del() {
    [ "${SEL_ADDED:-0}" = 1 ] || return 0
    has semanage || return 0
    semanage port -d -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null \
        && ok "已移除 SELinux 埠標籤 $NEW_PORT"
}

# =========================================================
# 防火牆
# =========================================================
fw_add() {
    FW_ADDED=0
    case "$FW" in
        firewalld)
            step "firewalld：放行 $NEW_PORT/tcp"
            firewall-cmd --permanent --add-port="${NEW_PORT}/tcp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 \
                && { FW_ADDED=1; ok "已放行並重新載入"; } || warn "firewalld 設定失敗，請手動確認"
            ;;
        ufw)
            step "ufw：放行 $NEW_PORT/tcp"
            ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1 \
                && { FW_ADDED=1; ok "已放行"; } || warn "ufw 設定失敗，請手動確認"
            ;;
        iptables)
            step "iptables：放行 $NEW_PORT/tcp"
            iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null \
                && { FW_ADDED=1; ok "已插入規則"; } || warn "iptables 設定失敗"
            warn "iptables 規則重開機不會保留，請自行存檔："
            info "    RHEL:   service iptables save"
            info "    Debian: netfilter-persistent save"
            info "    Alpine: rc-service iptables save"
            ;;
        nftables)
            warn "偵測到 nftables，規則結構因人而異，未自動修改。請手動放行："
            info "    nft add rule inet filter input tcp dport $NEW_PORT accept"
            ;;
        none)
            info "未偵測到啟用中的本機防火牆"
            ;;
    esac
    warn "雲端主機請另外確認安全群組 / 網路 ACL 是否已放行 $NEW_PORT"
}

fw_del_port() {
    _p="$1"
    case "$FW" in
        firewalld)
            firewall-cmd --permanent --remove-port="${_p}/tcp" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld：已移除 ${_p}/tcp" ;;
        ufw)
            ufw delete allow "${_p}/tcp" >/dev/null 2>&1 && ok "ufw：已移除 ${_p}/tcp" ;;
        iptables)
            iptables -D INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null \
                && ok "iptables：已移除 ${_p}/tcp" ;;
        *) : ;;
    esac
}

# =========================================================
# 服務控制與驗證
# =========================================================
config_test() {
    [ -z "$PREFIX" ] || return 0
    has sshd || { warn "找不到 sshd 執行檔，略過設定檔語法檢查"; return 0; }
    _out=$(sshd -t 2>&1)
    if [ -n "$_out" ]; then
        err "sshd 設定檔語法檢查未通過："
        printf '%s\n' "$_out" | sed 's/^/      /'
        return 1
    fi
    ok "sshd -t 語法檢查通過"
    return 0
}

svc_restart() {
    [ -z "$PREFIX" ] || return 0
    step "重新啟動 SSH 服務（既有連線不會被中斷）"
    case "$INIT" in
        systemd)
            systemctl daemon-reload >/dev/null 2>&1
            if [ -n "$SOCKET_UNIT" ]; then
                systemctl restart "$SOCKET_UNIT" >/dev/null 2>&1 || return 1
                systemctl restart "$SSH_SVC" >/dev/null 2>&1
            else
                systemctl restart "$SSH_SVC" >/dev/null 2>&1 || return 1
            fi
            ;;
        openrc)  rc-service "$SSH_SVC" restart >/dev/null 2>&1 || return 1 ;;
        *)       service "$SSH_SVC" restart >/dev/null 2>&1 \
                 || "/etc/init.d/$SSH_SVC" restart >/dev/null 2>&1 || return 1 ;;
    esac
    return 0
}

# 確認埠真的在 LISTEN，並試著抓 SSH banner
verify_port() {
    _p="$1"; _i=0
    [ -z "$PREFIX" ] || return 0
    while [ "$_i" -lt 10 ]; do
        if has ss; then
            ss -ltn 2>/dev/null | grep -qE "[:.]${_p}[[:space:]]" && break
        elif has netstat; then
            netstat -ltn 2>/dev/null | grep -qE "[:.]${_p}[[:space:]]" && break
        else
            return 0
        fi
        _i=$((_i+1)); sleep 1
    done
    if [ "$_i" -ge 10 ]; then
        err "埠 $_p 沒有進入 LISTEN 狀態"
        return 1
    fi
    ok "埠 $_p 已在監聽"

    if has nc; then
        _banner=$(printf '' | timeout 3 nc 127.0.0.1 "$_p" 2>/dev/null | head -1)
        case "$_banner" in
            SSH-*) ok "本機交握正常：$_banner" ;;
            *)     warn "埠有監聽但抓不到 SSH banner，可能是防火牆或服務異常" ;;
        esac
    fi
    return 0
}

# =========================================================
# 看門狗：沒 confirm 就自動還原
# =========================================================
watchdog_start() {
    _t="$1"
    mkdir -p "$STATE_DIR"
    rm -f "${STATE_DIR}/confirmed"
    cat > "${STATE_DIR}/watchdog.sh" <<EOF
#!/bin/sh
sleep $_t
[ -f "${STATE_DIR}/confirmed" ] && exit 0
printf '%s 看門狗逾時，自動還原\n' "\$(date -Is 2>/dev/null || date)" >> "$LOGFILE" 2>/dev/null
"$SELF" rollback --auto >> "$LOGFILE" 2>&1
EOF
    chmod +x "${STATE_DIR}/watchdog.sh"
    if has setsid; then
        setsid "${STATE_DIR}/watchdog.sh" </dev/null >/dev/null 2>&1 &
    else
        nohup "${STATE_DIR}/watchdog.sh" </dev/null >/dev/null 2>&1 &
    fi
    echo $! > "${STATE_DIR}/watchdog.pid"
    ok "看門狗已啟動，${_t} 秒內未確認將自動還原"
}

watchdog_cancel() {
    touch "${STATE_DIR}/confirmed" 2>/dev/null
    if [ -f "${STATE_DIR}/watchdog.pid" ]; then
        kill "$(cat "${STATE_DIR}/watchdog.pid")" 2>/dev/null
        rm -f "${STATE_DIR}/watchdog.pid"
    fi
    has pkill && pkill -f "${STATE_DIR}/watchdog.sh" 2>/dev/null
    rm -f "${STATE_DIR}/watchdog.sh" 2>/dev/null
    return 0
}

# =========================================================
# 子指令
# =========================================================
cmd_set() {
    NEW_PORT="$1"
    detect_env
    validate_port "$NEW_PORT"

    OLD_PORTS=$(current_ports | tr '\n' ' ' | sed 's/ *$//')
    for _p in $OLD_PORTS; do
        if [ "$_p" = "$NEW_PORT" ]; then
            [ "$(echo "$OLD_PORTS" | wc -w)" = 1 ] && die "SSH 目前已經在使用埠 $NEW_PORT，無需變更"
            warn "埠 $NEW_PORT 已在目前的監聽清單中，本次將收掉其餘埠"
        fi
    done
    SOCKET_EXISTED=0
    [ -f "$SOCKET_OVERRIDE" ] && SOCKET_EXISTED=1

    printf '\n'
    step "環境"
    info "系統      : $OS_PRETTY (family=$OS_FAMILY)"
    info "init      : $INIT     服務名: $SSH_SVC"
    info "設定方式  : $([ "$USE_DROPIN" = 1 ] && echo 'drop-in (支援 Include)' || echo '主設定檔 (不支援 Include)')"
    info "socket    : $([ -n "$SOCKET_UNIT" ] && echo "$SOCKET_UNIT 接管中，Port 指令無效，改寫 ListenStream" || echo '未使用')"
    info "SELinux   : $SELINUX"
    info "防火牆    : $FW"
    info "目前埠    : $OLD_PORTS"
    info "目標埠    : $NEW_PORT"
    printf '\n'

    if [ -n "${SSH_CONNECTION:-}" ]; then
        info "你正透過 SSH 連線操作（${SSH_CONNECTION}）"
        info "本階段新舊埠並存，這條連線不會斷"
        printf '\n'
    fi

    if [ "$DRYRUN" = 1 ]; then
        step "乾跑模式，以下為將要執行的動作"
        info "1. 備份 $SSHD_CONFIG 與 sshd_config.d/"
        info "2. 設定同時監聽：$OLD_PORTS $NEW_PORT"
        [ -n "$SOCKET_UNIT" ] && info "   並寫入 $SOCKET_OVERRIDE"
        # SELinux 停用時 selinux_add 會直接 return，乾跑就不該列出這步造成誤導
        if [ "$OS_FAMILY" = rhel ] && [ "$SELINUX" != disabled ]; then
            info "3. semanage port -a -t ssh_port_t -p tcp $NEW_PORT"
        fi
        info "4. 防火牆($FW) 放行 $NEW_PORT/tcp"
        info "5. sshd -t 檢查後重啟服務"
        info "6. 啟動 ${TIMEOUT}s 看門狗"
        exit 0
    fi

    if [ "$ASSUME_YES" != 1 ]; then
        printf '確定要繼續嗎？新舊埠將同時監聽 [y/N] '
        read -r _a
        case "$_a" in y|Y|yes|YES) : ;; *) die "已取消" ;; esac
    fi
    printf '\n'

    backup_all
    step "設定雙埠並存：$OLD_PORTS $NEW_PORT"
    write_sshd_ports "$OLD_PORTS $NEW_PORT"
    [ -n "$SOCKET_UNIT" ] && write_socket_ports "$OLD_PORTS $NEW_PORT"

    selinux_add
    fw_add

    if ! config_test; then
        err "設定檔有誤，還原後中止"
        restore_backup; svc_restart; exit 1
    fi

    if ! svc_restart; then
        err "服務重啟失敗，還原後中止"
        restore_backup; svc_restart; exit 1
    fi

    if ! verify_port "$NEW_PORT"; then
        err "新埠未能監聽，還原後中止"
        restore_backup; svc_restart; exit 1
    fi

    state_set
    watchdog_start "$TIMEOUT"

    printf '\n'
    printf '%s\n' "${CG}${CB}────────────────────────────────────────────────────────${C0}"
    printf '%s\n' "${CB} 現在請「不要關閉這個視窗」，另外開一個新終端機測試：${C0}"
    printf '\n'
    printf '%s\n' "     ssh -p ${NEW_PORT} $(id -un)@$(primary_ip)"
    printf '\n'
    printf '%s\n' "${CB} 登入成功後，回到這裡執行：${C0}"
    printf '%s\n' "     $SELF confirm"
    printf '\n'
    printf '%s\n' "${CY} ${TIMEOUT} 秒內沒有 confirm，所有變更會自動還原（含防火牆與 SELinux）${C0}"
    printf '%s\n' "${CG}${CB}────────────────────────────────────────────────────────${C0}"
}

cmd_confirm() {
    detect_env
    state_load
    step "確認新埠 $NEW_PORT 可用，收掉舊埠：$OLD_PORTS"

    watchdog_cancel
    ok "看門狗已取消"

    write_sshd_ports "$NEW_PORT"
    [ -n "$SOCKET_UNIT" ] && write_socket_ports "$NEW_PORT"

    if ! config_test; then
        err "設定檔有誤，維持雙埠狀態不變更"
        write_sshd_ports "$OLD_PORTS $NEW_PORT"
        [ -n "$SOCKET_UNIT" ] && write_socket_ports "$OLD_PORTS $NEW_PORT"
        svc_restart; exit 1
    fi

    svc_restart || die "服務重啟失敗，請立即檢查 $SELF status"
    verify_port "$NEW_PORT" || die "新埠未監聽，請立即執行 $SELF rollback"

    if [ "$KEEP_FW" != 1 ]; then
        for _p in $OLD_PORTS; do
            [ "$_p" = "$NEW_PORT" ] && continue
            fw_del_port "$_p"
        done
    fi

    printf '\n'
    ok "完成。SSH 現在只監聽埠 $NEW_PORT"
    info "備份保留在 $BACKUP，確認穩定後可自行刪除"
    info "若要還原：$SELF rollback"
}

restore_backup() {
    [ -n "${BACKUP:-}" ] && [ -d "$BACKUP" ] || { warn "找不到備份，改用清除管理區塊的方式還原"; clean_our_config; return 0; }
    [ -f "$BACKUP/sshd_config" ] && cp -a "$BACKUP/sshd_config" "$SSHD_CONFIG"
    if [ -d "$BACKUP/sshd_config.d" ]; then
        rm -f "$SSHD_CONFD"/*.conf 2>/dev/null
        cp -a "$BACKUP/sshd_config.d/." "$SSHD_CONFD/" 2>/dev/null
    else
        rm -f "$DROPIN" 2>/dev/null
    fi
    if [ -n "${SOCKET_UNIT:-}" ]; then
        if [ -f "$BACKUP/socket.d/override.conf" ]; then
            mkdir -p "$SOCKET_DIR"
            cp -a "$BACKUP/socket.d/override.conf" "$SOCKET_OVERRIDE"
        elif [ "${SOCKET_EXISTED:-0}" != 1 ]; then
            rm -f "$SOCKET_OVERRIDE" 2>/dev/null
        fi
    fi
    ok "設定已由備份還原"
}

cmd_rollback() {
    detect_env
    state_load
    step "還原 SSH 埠設定"
    watchdog_cancel
    restore_backup
    [ "${FW_ADDED:-0}" = 1 ] && fw_del_port "$NEW_PORT"
    selinux_del

    if config_test && svc_restart; then
        for _p in $OLD_PORTS; do verify_port "$_p" || true; done
        ok "已還原並重啟，SSH 回到埠：$OLD_PORTS"
    else
        err "重啟失敗，請立即用主控台（VNC / IPMI / 雲端 Console）介入處理"
        exit 1
    fi
    rm -f "$STATE" "${STATE_DIR}/confirmed"
    [ "${AUTO:-0}" = 1 ] && info "（此次為看門狗逾時自動還原）"
    return 0
}

cmd_status() {
    detect_env
    printf '\n'
    step "SSH 埠狀態"
    info "系統      : $OS_PRETTY"
    info "服務      : $SSH_SVC ($INIT)"
    if [ -z "$PREFIX" ] && [ "$INIT" = systemd ]; then
        info "服務狀態  : $(systemctl is-active "$SSH_SVC" 2>/dev/null)"
        [ -n "$SOCKET_UNIT" ] && info "socket    : $SOCKET_UNIT ($(systemctl is-active "$SOCKET_UNIT" 2>/dev/null))"
    fi
    info "設定檔埠  : $(current_ports | tr '\n' ' ')"
    [ -n "$SOCKET_UNIT" ] && info "socket 埠 : $(current_socket_ports | tr '\n' ' ')"
    if [ -z "$PREFIX" ]; then
        info "實際監聽  :"
        for _p in $(current_ports); do
            if has ss && ss -ltn 2>/dev/null | grep -qE "[:.]${_p}[[:space:]]"; then
                info "    $_p  ${CG}LISTEN${C0}"
            else
                info "    $_p  ${CR}未監聽${C0}"
            fi
        done
    fi
    info "SELinux   : $SELINUX"
    info "防火牆    : $FW"
    if [ -f "$STATE" ]; then
        printf '\n'
        warn "有進行中的變更尚未確認："
        sed 's/^/      /' "$STATE"
        if [ -f "${STATE_DIR}/watchdog.pid" ] && kill -0 "$(cat "${STATE_DIR}/watchdog.pid")" 2>/dev/null; then
            warn "看門狗執行中，逾時將自動還原。確認可用請執行：$SELF confirm"
        fi
    fi
    printf '\n'
}

# =========================================================
# 進入點
# =========================================================
CMD=''; NEW_PORT=''; TIMEOUT=$DEFAULT_TIMEOUT
DRYRUN=0; ASSUME_YES=0; FORCE=0; KEEP_FW=0; AUTO=0

[ $# -eq 0 ] && usage

CMD="$1"; shift
case "$CMD" in
    set)
        [ $# -ge 1 ] || die "請指定埠號，例如：$SELF set 58763"
        NEW_PORT="$1"; shift ;;
    confirm|rollback|status) : ;;
    -h|--help|help) usage ;;
    *) die "未知指令：$CMD（可用 set / confirm / rollback / status）" ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout) TIMEOUT="${2:-}"; shift 2 ;;
        -n|--dry-run) DRYRUN=1; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        --force)      FORCE=1; shift ;;
        --keep-fw)    KEEP_FW=1; shift ;;
        --auto)       AUTO=1; ASSUME_YES=1; shift ;;
        *) die "未知選項：$1" ;;
    esac
done

case "$TIMEOUT" in ''|*[!0-9]*) die "逾時秒數必須是數字" ;; esac
[ "$TIMEOUT" -lt 60 ] && die "逾時秒數不應小於 60，你需要時間開新視窗測試"

if [ "$(id -u)" != 0 ] && [ "$CMD" != status ]; then
    die "需要 root 權限執行"
fi

mkdir -p "$STATE_DIR" 2>/dev/null

case "$CMD" in
    set)      cmd_set "$NEW_PORT" ;;
    confirm)  cmd_confirm ;;
    rollback) cmd_rollback ;;
    status)   cmd_status ;;
esac
