#!/bin/sh
# net-set.sh — IP 與 DNS 伺服器的增加 / 減少 / 替換
#
# 支援（會改設定）：Ubuntu 22.04 / 24.04
# 其餘發行版目前只有 status / doctor，改設定會直接拒絕。
#
# 用法：
#   ./net-set.sh status                         網卡 / IP / 閘道 / DNS / 進行中的變更
#   ./net-set.sh ip-add <IP[/前綴]> [-i 網卡]   增加 IP
#   ./net-set.sh ip-del <IP>                    刪除 IP
#   ./net-set.sh ip-replace <舊IP> <新IP>       替換 IP（同網段，閘道不變）
#   ./net-set.sh dns-add <DNS> [--first]        增加 DNS，預設加在最後
#   ./net-set.sh dns-del <DNS>                  刪除 DNS
#   ./net-set.sh dns-replace <舊DNS> <新DNS>    替換 DNS，保留原本的順序位置
#   ./net-set.sh confirm                        確認 IP 變更（替換時才移除舊 IP）
#   ./net-set.sh rollback                       立刻還原到變更前
#   ./net-set.sh doctor                         環境檢查（含「改了會被蓋回去」的情況）
#
#   共用選項：-y 免確認、-n 乾跑、-t 秒數 看門狗時限（預設 300）
#
# 設計原則：
#   1. 依「實際生效的網路管理方式」分流，不依系統版本猜。Ubuntu 22.04 也可能是
#      ifupdown（廠商映像常見）。判斷不出來或有衝突就拒絕，不賭。
#   2. IP 變更一律先備份、先開看門狗再動手，時限內沒 confirm 就自動還原。
#   3. ip-replace 分兩階段：先新舊並存，從新 IP 登入後 confirm 才移除舊 IP。
#   4. 目前 SSH 連線正在用的 IP 不能用 ip-del 刪，-y 也不能跳過。
#   5. DNS 改錯不會斷 SSH，所以不開看門狗，改用變更前後的實際解析來驗證。
#   6. rsService、cloud-init 這類覆寫來源只警告，不停用 —— 那是廠商的東西。
#
# 以 POSIX sh 撰寫。netplan 後端需要 python3-yaml（netplan 本身的相依）。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# os-release 會設 VERSION，所以本腳本自己的版本號不能叫 VERSION
NET_SH_VER=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# 產出檔案跟其他工具收在一起（見 ../SSH/README.md 的「檔案位置」）
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
LOGFILE="$OPS_SSH_DIR/net-ops.log"
STATE_DIR="$OPS_SSH_DIR/net-set"
STATE="$STATE_DIR/state"
# 只在 IP 變更進行中存在。看門狗是背景行程，活不過重開機，開機後由這個服務接手
WD_UNIT=ops-net-watchdog.service
WD_UNIT_FILE="/etc/systemd/system/$WD_UNIT"

IFACES_MAIN=/etc/network/interfaces
IFACES_DIR=/etc/network/interfaces.d
NETPLAN_DIR=/etc/netplan
RESOLV=/etc/resolv.conf

# 驗證解析用的網域。內網 DNS 查不到外部網域時，設 OPS_NET_TESTNAME 指到內部網域。
TESTNAME="${OPS_NET_TESTNAME:-cloudflare.com}"

DRY=0
YES=0
AUTO=0
TIMEOUT=300
IFACE_OPT=''
DNS_FIRST=0

# ---------- 輸出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
    CB=$(printf '\033[1m');  CD=$(printf '\033[2m');  C0=$(printf '\033[0m')
else
    CR=''; CG=''; CY=''; CB=''; CD=''; C0=''
fi

_log()  {
    _lp=''
    [ "${DRY:-0}" = 1 ] && _lp='[乾跑] '
    printf '%s\n' "$*"
    [ -w "$(dirname "$LOGFILE")" ] 2>/dev/null && \
        printf '%s %s%s\n' "$(date -Is 2>/dev/null || date)" "$_lp" "$*" >> "$LOGFILE" 2>/dev/null
    return 0
}
info()  { _log "  $*"; }
step()  { _log "${CB}==>${C0} $*"; }
ok()    { _log "${CG}  +${C0} $*"; }
warn()  { _log "${CY}  !${C0} $*"; }
err()   { _log "${CR}  x${C0} $*"; }
die()   { err "$*"; exit 1; }
plain() { printf '%s\n' "$*"; }

has() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" = 0 ] && return 0
    err "這個動作需要 root 權限，目前是 $(id -un)"
    exit 1
}

confirm() {
    [ "$YES" = 1 ] && return 0
    printf '%s%s%s [y/N] ' "$CY" "$1" "$C0"
    read -r _a 2>/dev/null || _a=''
    case "$_a" in y|Y|yes|YES) return 0 ;; *) info "已取消"; return 1 ;; esac
}

# =========================================================
# 位址運算
# =========================================================
ip4_valid() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    _old=$IFS; IFS=.; set -- $1; IFS=$_old
    [ $# = 4 ] || return 1
    for _o in "$@"; do
        case "$_o" in 0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) : ;; *) return 1 ;; esac
    done
    return 0
}

ip6_like() {
    case "$1" in
        *:*) case "$1" in *[!0-9a-fA-F:.]*) return 1 ;; *) return 0 ;; esac ;;
    esac
    return 1
}

ip2n() {
    _old=$IFS; IFS=.; set -- $1; IFS=$_old
    printf '%s' $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

n2ip() {
    printf '%s.%s.%s.%s' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) \
        $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

maskn() { printf '%s' $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); }

prefix2mask() { n2ip "$(maskn "$1")"; }

mask2prefix() {
    _m=$(ip2n "$1"); _p=0
    while [ $(( _m & 0x80000000 )) != 0 ]; do
        _p=$(( _p + 1 )); _m=$(( (_m << 1) & 0xFFFFFFFF ))
    done
    printf '%s' "$_p"
}

# $1 位址 $2 前綴 → 網段的整數值
netn() { printf '%s' $(( $(ip2n "$1") & $(maskn "$2") )); }

# 位址能不能拿來設在網卡上。前綴給了才檢查網路位址 / 廣播位址。
ip_usable() {
    _n=$(ip2n "$1"); _a=$(( _n >> 24 ))
    if [ "$_a" = 0 ] || [ "$_a" = 127 ] || [ "$_a" -ge 224 ]; then
        return 1
    fi
    if [ -n "${2:-}" ] && [ "$2" -lt 31 ]; then
        _nw=$(netn "$1" "$2")
        _bc=$(( _nw | (~$(maskn "$2") & 0xFFFFFFFF) ))
        { [ "$_n" = "$_nw" ] || [ "$_n" = "$_bc" ]; } && return 1
    fi
    return 0
}

# =========================================================
# 環境偵測
# =========================================================
detect_env() {
    OS_ID=''; OS_VER=''; OS_NAME=''
    if [ -r /etc/os-release ]; then
        OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
        OS_VER=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
        OS_NAME=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-}")
    fi
}

os_supported() {
    case "$OS_ID:$OS_VER" in
        ubuntu:22.04|ubuntu:24.04) return 0 ;;
    esac
    return 1
}

svc_active() {
    has systemctl && [ "$(systemctl is-active "$1" 2>/dev/null)" = active ]
}

netplan_files() {
    for _f in "$NETPLAN_DIR"/*.yaml; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
}

ifupdown_files() {
    [ -f "$IFACES_MAIN" ] && printf '%s\n' "$IFACES_MAIN"
    for _f in "$IFACES_DIR"/*; do
        [ -f "$_f" ] || continue
        case "$(basename "$_f")" in *.*) : ;; *) printf '%s\n' "$_f" ;; esac
    done
}

# 除了 lo 以外有沒有 iface 段落
ifupdown_used() {
    has ifquery || has ifup || return 1
    _fl=$(ifupdown_files)
    [ -n "$_fl" ] || return 1
    # shellcheck disable=SC2086
    awk '$1 == "iface" && $2 != "lo" { f = 1 } END { exit !f }' $_fl 2>/dev/null
}

netplan_used() {
    has netplan && [ -n "$(netplan_files)" ]
}

# BACKEND = netplan | ifupdown | none；BACKEND_WHY 是拒絕時要講的原因
detect_backend() {
    BACKEND=none; BACKEND_WHY=''
    _np=0; _if=0
    netplan_used && _np=1
    ifupdown_used && _if=1
    if [ "$_np" = 1 ] && [ "$_if" = 1 ]; then
        BACKEND_WHY="netplan 與 ifupdown 同時有設定，無法判斷哪一邊生效"
        return 0
    fi
    if svc_active NetworkManager; then
        BACKEND_WHY="NetworkManager 正在執行，這個版本還沒有 NetworkManager 後端"
        return 0
    fi
    if [ "$_np" = 1 ]; then
        if ! has python3 || ! python3 -c 'import yaml' 2>/dev/null; then
            BACKEND_WHY="netplan 後端需要 python3-yaml"
            return 0
        fi
        if grep -hqE '^[[:space:]]*renderer:[[:space:]]*NetworkManager' $(netplan_files) 2>/dev/null; then
            BACKEND_WHY="netplan 的 renderer 是 NetworkManager，這個版本還沒有支援"
            return 0
        fi
        BACKEND=netplan
    elif [ "$_if" = 1 ]; then
        BACKEND=ifupdown
    else
        BACKEND_WHY="找不到 netplan 或 ifupdown 的網卡設定"
    fi
    return 0
}

# 拿 resolv.conf 的實際來源判斷 DNS 要寫哪裡。
# DNS_MODE = file | netplan-resolved | none
detect_dns_mode() {
    DNS_MODE=none; DNS_WHY=''
    if [ -L "$RESOLV" ]; then
        _t=$(readlink "$RESOLV")
        case "$_t" in
            *systemd/resolve*)
                if ! svc_active systemd-resolved; then
                    DNS_WHY="$RESOLV 指向 systemd-resolved，但它沒有在執行"
                elif [ "$BACKEND" = netplan ]; then
                    DNS_MODE=netplan-resolved
                else
                    DNS_WHY="systemd-resolved 生效中，但網卡不是 netplan 管理，這個組合還沒有支援"
                fi ;;
            *) DNS_WHY="$RESOLV 是連結（指向 $_t），這個來源還沒有支援" ;;
        esac
    elif [ -f "$RESOLV" ]; then
        if svc_active NetworkManager; then
            DNS_WHY="NetworkManager 可能改寫 $RESOLV，這個版本還沒有支援"
        else
            DNS_MODE=file
        fi
    else
        DNS_WHY="找不到 $RESOLV"
    fi
    return 0
}

# cloud-init 管不管網路：0 = 會管，1 = 沒裝或已停用。
# 停用有三種寫法：標記檔、開機參數、network: {config: disabled}，只查一種會誤報。
cloud_init_manages_net() {
    has cloud-init || return 1
    [ -e /etc/cloud/cloud-init.disabled ] && return 1
    [ -e /run/cloud-init/disabled ] && return 1
    grep -qs 'cloud-init=disabled' /proc/cmdline && return 1
    grep -rqsE '^[[:space:]]*network:[[:space:]]*\{[[:space:]]*config:[[:space:]]*disabled|^[[:space:]]+config:[[:space:]]*disabled' \
        /etc/cloud/cloud.cfg.d /etc/cloud/cloud.cfg && return 1
    return 0
}

# 會在重開機時蓋回設定的來源。只回報，不處理。
override_sources() {
    if [ -x /usr/local/bin/rsService ] || svc_active rsService; then
        printf '%s\n' "rsService（廠商代理程式）：可能在開機時重寫網路設定"
    fi
    if cloud_init_manages_net; then
        printf '%s\n' "cloud-init：網路設定未停用，開機時可能重新產生"
        [ -f "$NETPLAN_DIR/50-cloud-init.yaml" ] && \
            printf '%s\n' "$NETPLAN_DIR/50-cloud-init.yaml：這份檔案由 cloud-init 產生"
    fi
    return 0
}

warn_overrides() {
    _ov=$(override_sources)
    [ -n "$_ov" ] || return 0
    warn "這台機器的設定來源可能不一致，重開機後變更可能被還原："
    printf '%s\n' "$_ov" | while IFS= read -r _l; do warn "  $_l"; done
    warn "  若 IP / DNS 是由廠商面板管理，面板也要同步修改。"
    warn "  本工具不會停用這些服務。"
}

# =========================================================
# 現況查詢
# =========================================================
live_addrs() { ip -o -4 addr show dev "$1" scope global 2>/dev/null | awk '{print $4}'; }

iface_of_ip() {
    ip -o -4 addr show 2>/dev/null | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) { print $2; exit } }'
}

prefix_of_ip() {
    ip -o -4 addr show 2>/dev/null | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) { print a[2]; exit } }'
}

default_gw()    { ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'; }
default_iface() { ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }

# 這條 SSH 連線連進來的本機位址；不是 SSH 或被 sudo 洗掉時為空
session_ip() {
    # shellcheck disable=SC2086
    set -- ${SSH_CONNECTION:-}
    [ $# -ge 3 ] && printf '%s' "$3" | sed 's/^::ffff://'
}

# 所有已建立 SSH 連線的本機位址
sshd_ips() {
    has ss || return 0
    ss -tnp state established 2>/dev/null | grep -F '"sshd' | \
        awk '{print $3}' | sed -e 's/:[0-9]*$//' -e 's/^\[::ffff://' -e 's/^::ffff://' -e 's/\]$//' | sort -u
}

ip_in_ssh_use() {
    [ "$(session_ip)" = "$1" ] && return 0
    sshd_ips | grep -qxF "$1"
}

# sshd 綁定的位址；回傳 0 代表它會聽這個 IP
sshd_listens_on() {
    has sshd || return 0
    _la=$(sshd -T 2>/dev/null | awk '$1 == "listenaddress" { print $2 }' | sed -e 's/:[0-9]*$//' -e 's/^\[//' -e 's/\]$//')
    [ -n "$_la" ] || return 0
    printf '%s\n' "$_la" | grep -qxE '0\.0\.0\.0|::' && return 0
    printf '%s\n' "$_la" | grep -qxF "$1"
}

# 綁在這個 IP 上的服務，刪掉位址之後它們會停止服務
warn_bound_services() {
    has ss || return 0
    _b=$(ss -ltnup 2>/dev/null | awk -v ip="$1" 'index($5, ip ":") == 1 { print $5, $NF }')
    [ -n "$_b" ] || return 0
    warn "以下服務綁定在 $1，移除後會失去這個入口："
    printf '%s\n' "$_b" | while IFS= read -r _l; do warn "  $_l"; done
}

# 有人回應 = 這個 IP 已經有人在用。
# VPS 的閘道常常代答 ARP（proxy ARP），整段位址都解析成閘道的 MAC，所以 ARP 有回應
# 不算數，MAC 要跟閘道不同才是真的有別台機器。arping -D 分不出這件事，不用它。
ip_taken() {
    ping -c 1 -W 1 "$1" >/dev/null 2>&1 && return 0
    _mac=$(ip neigh show to "$1" dev "$2" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1) }')
    [ -n "$_mac" ] || return 1
    _gw=$(default_gw)
    [ -n "$_gw" ] || return 0
    _gwmac=$(ip neigh show to "$_gw" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1) }')
    [ "$_mac" != "$_gwmac" ]
}

# 位址所在的網卡與前綴
pick_iface_for_add() {
    ADD_IFACE=''; ADD_PREFIX=''
    _want=$1; _pfx=$2
    for _d in $(ls /sys/class/net 2>/dev/null); do
        [ "$_d" = lo ] && continue
        for _a in $(live_addrs "$_d"); do
            _i=${_a%/*}; _p=${_a#*/}
            if [ "$(netn "$_want" "$_p")" = "$(netn "$_i" "$_p")" ]; then
                if [ -z "$IFACE_OPT" ] || [ "$IFACE_OPT" = "$_d" ]; then
                    ADD_IFACE=$_d; ADD_PREFIX=$_p
                    return 0
                fi
            fi
        done
    done
    ADD_IFACE=${IFACE_OPT:-$(default_iface)}
    ADD_PREFIX=$_pfx
}

# =========================================================
# ifupdown 後端
#   註解、順序、其他網卡的段落一律不動，只改需要改的那幾行。
# =========================================================
# 這個 IP 在哪個段落 → "檔案|介面|方法|有閘道|位址數|其他選項"
# 這台測試機就是選項不縮排的寫法，所以段落邊界看關鍵字，不看縮排。
if_find() {
    _fl=$(ifupdown_files)
    # shellcheck disable=SC2086
    awk -v ip="$1" '
        function flush() {
            if (hit) printf "%s|%s|%s|%d|%d|%s\n", sfile, sif, smeth, sgw, scnt, sext
            hit = 0; sif = ""
        }
        FNR == 1 { flush() }
        /^[[:space:]]*(#|$)/ { next }
        $1 == "iface" { flush(); sif = $2; smeth = $4; sfile = FILENAME; sgw = 0; scnt = 0; sext = ""; next }
        $1 ~ /^(auto|allow-|mapping|source|no-auto-down|no-scripts)/ { flush(); next }
        sif != "" {
            if ($1 == "address") {
                scnt++
                split($2, a, "/")
                if (a[1] == ip) hit = 1
            } else if ($1 == "gateway") {
                sgw = 1
            } else if ($1 !~ /^(netmask|network|broadcast|dns-)/) {
                sext = sext " " $1
            }
        }
        END { flush() }
    ' $_fl 2>/dev/null | head -1
}

# 這個 IP 在設定檔裡寫的前綴
if_prefix_of() {
    _fl=$(ifupdown_files)
    # shellcheck disable=SC2086
    awk -v ip="$1" '
        /^[[:space:]]*(#|$)/ { next }
        $1 == "iface" { inb = 0; next }
        $1 == "address" { split($2, a, "/"); if (a[1] == ip) { inb = 1; if (a[2] != "") { print a[2]; exit } } next }
        inb && $1 == "netmask" { print $2; exit }
    ' $_fl 2>/dev/null
}

# 同一張實體網卡有幾個 static 主段落（不含 eth0:0 這種別名）
if_base_count() {
    _fl=$(ifupdown_files)
    # shellcheck disable=SC2086
    awk -v n="$1" '$1 == "iface" && $2 == n { c++ } END { print c + 0 }' $_fl 2>/dev/null
}

if_next_label() {
    _base=$1; _n=0
    _fl=$(ifupdown_files)
    while :; do
        # shellcheck disable=SC2086
        if ! grep -qE "^[[:space:]]*iface[[:space:]]+$_base:$_n[[:space:]]" $_fl 2>/dev/null && \
           ! ip -o -4 addr show dev "$_base" 2>/dev/null | grep -qE "[[:space:]]$_base:$_n[[:space:]]"; then
            printf '%s:%s' "$_base" "$_n"
            return 0
        fi
        _n=$(( _n + 1 ))
    done
}

# 暫存檔放同一個目錄再 rename，中途斷線不會留下寫一半的設定檔
if_commit() {   # $1 = 目標檔，暫存內容在 $1.ops-new
    chmod --reference="$1" "$1.ops-new" 2>/dev/null
    mv -f "$1.ops-new" "$1"
}

if_append() {   # $1 網卡 $2 位址 $3 前綴 → 回傳段落名到 IF_LABEL
    IF_LABEL=$(if_next_label "$1")
    {
        cat "$IFACES_MAIN"
        printf 'auto %s\niface %s inet static\naddress %s\nnetmask %s\n' \
            "$IF_LABEL" "$IF_LABEL" "$2" "$(prefix2mask "$3")"
    } > "$IFACES_MAIN.ops-new" && if_commit "$IFACES_MAIN"
}

# 移除段落。段落裡的 dns-* 不能跟著消失（這台機器的 dns-nameservers 就寫在
# eth0:0 底下），搬到基底網卡的段落去。
if_remove_stanza() {   # $1 檔案 $2 段落名
    _dns=$(awk -v n="$2" '
        /^[[:space:]]*(#|$)/ { next }
        $1 == "iface" { inb = ($2 == n); next }
        $1 ~ /^(auto|allow-|mapping|source|no-auto-down|no-scripts)/ { inb = 0; next }
        inb && $1 ~ /^dns-/ { print }
    ' "$1")
    awk -v n="$2" -v dns="$_dns" -v base="${2%%:*}" '
        $1 == "iface" {
            inb = ($2 == n)
            if (inb) next
            print
            if ($2 == base && dns != "" && !done) { print dns; done = 1 }
            next
        }
        $1 ~ /^(auto|allow-)/ {
            inb = 0
            line = $1; c = 0
            for (i = 2; i <= NF; i++) if ($i != n) { line = line " " $i; c++ }
            if (c > 0) print line
            next
        }
        $1 ~ /^(mapping|source|no-auto-down|no-scripts)/ { inb = 0; print; next }
        inb && !/^[[:space:]]*#/ && NF > 0 { next }
        { print }
    ' "$1" > "$1.ops-new" && if_commit "$1"
}

if_replace_addr() {   # $1 檔案 $2 舊位址 $3 新位址
    awk -v o="$2" -v w="$3" '
        $1 == "address" {
            split($2, a, "/")
            if (a[1] == o) { sub(o, w) }
        }
        { print }
    ' "$1" > "$1.ops-new" && if_commit "$1"
}

# =========================================================
# netplan 後端
#   YAML 用 python3-yaml 處理，不用 sed 硬改。代價是註解會消失，動手前先警告；
#   原檔在備份裡。netplan 自己就相依 python3-yaml，不會多裝東西。
# =========================================================
NP_PY='
import fnmatch, glob, os, sys, tempfile
import yaml

SECTIONS = ("ethernets", "bonds", "bridges", "vlans", "wifis", "tunnels", "vrfs", "dummy-devices", "modems")
DIR = os.environ.get("NET_NETPLAN_DIR", "/etc/netplan")

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(3)

def mac_of(iface):
    try:
        with open("/sys/class/net/%s/address" % iface) as f:
            return f.read().strip().lower()
    except OSError:
        return ""

def matches(key, dev, iface):
    if key == iface or dev.get("set-name") == iface:
        return True
    m = dev.get("match")
    if not isinstance(m, dict):
        return False
    if "name" in m and not fnmatch.fnmatch(iface, str(m["name"])):
        return False
    if "macaddress" in m and str(m["macaddress"]).lower() != mac_of(iface):
        return False
    return "name" in m or "macaddress" in m

def load(iface):
    found = []
    for path in sorted(glob.glob(os.path.join(DIR, "*.yaml"))):
        with open(path) as f:
            text = f.read()
        doc = yaml.safe_load(text) or {}
        net = doc.get("network") or {}
        for sec in SECTIONS:
            for key, dev in (net.get(sec) or {}).items():
                if isinstance(dev, dict) and matches(str(key), dev, iface):
                    found.append(dict(path=path, doc=doc, dev=dev, text=text))
    if not found:
        fail("netplan 設定裡找不到網卡 %s" % iface)
    return found

def host(item):
    return str(next(iter(item)) if isinstance(item, dict) else item).split("/")[0]

def owner(found, want, what):
    hits = [e for e in found if want(e)]
    if len(hits) > 1:
        fail("%s 同時寫在多個檔案（%s），請先手動整理" % (what, ", ".join(e["path"] for e in hits)))
    return hits[0] if hits else None

def addr_owner(found):
    return owner(found, lambda e: "addresses" in e["dev"], "addresses") or found[-1]

def dns_owner(found):
    def has_dns(e):
        return "addresses" in (e["dev"].get("nameservers") or {})
    return owner(found, has_dns, "nameservers") or addr_owner(found)

def save(e):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(e["path"]), prefix=".ops-")
    with os.fdopen(fd, "w") as f:
        yaml.safe_dump(e["doc"], f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    os.chmod(tmp, os.stat(e["path"]).st_mode & 0o777)
    os.replace(tmp, e["path"])

def find_addr(lst, ip):
    for i, item in enumerate(lst):
        if host(item) == ip:
            return i
    return -1

def main():
    op, iface = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    found = load(iface)
    if op == "show":
        for e in found:
            print("file", e["path"])
            for a in e["dev"].get("addresses") or []:
                print("addr", host(a))
            for s in (e["dev"].get("nameservers") or {}).get("addresses") or []:
                print("dns", s)
            if e["dev"].get("dhcp4") in (True, "true", "yes", "on"):
                print("dhcp4")
        return
    if op == "comments":
        print(addr_owner(found)["path"] if any("#" in l for l in addr_owner(found)["text"].splitlines()) else "")
        return
    if op == "dns-set":
        e = dns_owner(found)
        e["dev"].setdefault("nameservers", {})["addresses"] = args
        save(e)
        return
    e = addr_owner(found)
    lst = e["dev"].setdefault("addresses", [])
    if op == "addr-add":
        if find_addr(lst, args[0].split("/")[0]) < 0:
            lst.append(args[0])
    elif op == "addr-del":
        i = find_addr(lst, args[0])
        if i < 0:
            fail("netplan 設定裡沒有 %s" % args[0])
        del lst[i]
    elif op == "addr-replace":
        i = find_addr(lst, args[0])
        if i < 0:
            fail("netplan 設定裡沒有 %s" % args[0])
        j = find_addr(lst, args[1].split("/")[0])
        if j >= 0:
            del lst[j]
            i = find_addr(lst, args[0])
        lst[i] = args[1]
    else:
        fail("未知操作 %s" % op)
    save(e)

main()
'

np() { NET_NETPLAN_DIR="$NETPLAN_DIR" python3 -c "$NP_PY" "$@"; }

# 這個 IP 寫在 netplan 裡才算我們管得到；DHCP 拿到的改設定也沒用
np_has_addr() { np show "$1" 2>/dev/null | grep -qxF "addr $2"; }

np_apply() {
    if ! _o=$(netplan generate 2>&1); then
        err "netplan generate 失敗：$_o"
        return 1
    fi
    netplan apply 2>&1 | while IFS= read -r _l; do info "$_l"; done
    # 管線吃掉 netplan apply 的結束碼，成敗由呼叫端回讀實際狀態判斷
    return 0
}

warn_comment_loss() {
    [ "$BACKEND" = netplan ] || return 0
    _c=$(np comments "$1" 2>/dev/null)
    [ -n "$_c" ] && warn "$_c 含有註解，改寫後註解會消失（原檔在備份裡）"
    return 0
}

# =========================================================
# 備份與狀態
# =========================================================
backup_net() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    BACKUP="$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S).tar"
    _l=''
    for _p in "$RESOLV" "$IFACES_MAIN" "$IFACES_DIR" "$NETPLAN_DIR"; do
        [ -e "$_p" ] && _l="$_l ${_p#/}"
    done
    # shellcheck disable=SC2086
    tar -cpf "$BACKUP" -C / $_l 2>/dev/null || die "備份失敗：$BACKUP"
    ok "設定已備份到 $BACKUP"
    # shellcheck disable=SC2012
    ls -1t "$STATE_DIR"/backup-*.tar 2>/dev/null | sed 1,20d | while IFS= read -r _o; do rm -f "$_o"; done
}

restore_backup() {
    [ -f "$1" ] || { err "找不到備份 $1"; return 1; }
    tar -xpf "$1" -C / 2>/dev/null
}

state_set() {
    {
        printf "OP='%s'\n" "$OP"
        printf "IFACE='%s'\n" "$IFACE"
        printf "OLD_IP='%s'\n" "$OLD_IP"
        printf "NEW_IP='%s'\n" "$NEW_IP"
        printf "PREFIX='%s'\n" "$PREFIX"
        printf "IF_LABEL='%s'\n" "${IF_LABEL:-}"
        printf "BACKEND='%s'\n" "$BACKEND"
        printf "BACKUP='%s'\n" "$BACKUP"
        printf "ADDRS_BEFORE='%s'\n" "$ADDRS_BEFORE"
        printf "GW_BEFORE='%s'\n" "$GW_BEFORE"
        printf "GWDEV_BEFORE='%s'\n" "$GWDEV_BEFORE"
        printf "DEADLINE='%s'\n" "$(( $(date +%s) + TIMEOUT ))"
    } > "$STATE"
    chmod 600 "$STATE" 2>/dev/null
}

state_load() {
    [ -f "$STATE" ] || die "沒有進行中的 IP 變更"
    # shellcheck disable=SC1090
    . "$STATE"
}

pending_desc() {
    (
        . "$STATE"
        printf '%s %s%s' "$OP" "${OLD_IP:+$OLD_IP }" "${NEW_IP:+→ $NEW_IP}"
    )
}

pending_guard() {
    [ -f "$STATE" ] || return 0
    err "還有一筆進行中的 IP 變更沒有結束：$(pending_desc)"
    die "請先 confirm 或 rollback"
}

watchdog_start() {
    rm -f "$STATE_DIR/confirmed"
    # 重開機後原本的路徑不一定還在（ops.sh 的快取目錄），看門狗用自己的副本
    _wd_self="$STATE_DIR/net-set.sh"
    cp -f "$SELF" "$_wd_self" 2>/dev/null || _wd_self=$SELF
    # 開機接手時要重新倒數，所以期限由看門狗自己寫
    cat > "$STATE_DIR/watchdog.sh" <<EOF
#!/bin/sh
sed -i "s/^DEADLINE=.*/DEADLINE='\$(( \$(date +%s) + $TIMEOUT ))'/" "$STATE" 2>/dev/null
sleep $TIMEOUT
[ -f "$STATE_DIR/confirmed" ] && exit 0
printf '%s 看門狗逾時，自動還原\n' "\$(date -Is 2>/dev/null || date)" >> "$LOGFILE" 2>/dev/null
OPS_SSH_DIR="$OPS_SSH_DIR" sh "$_wd_self" rollback --auto >/dev/null 2>&1
EOF
    chmod 700 "$STATE_DIR/watchdog.sh"
    if has setsid; then
        setsid "$STATE_DIR/watchdog.sh" </dev/null >/dev/null 2>&1 &
    else
        nohup "$STATE_DIR/watchdog.sh" </dev/null >/dev/null 2>&1 &
    fi
    echo $! > "$STATE_DIR/watchdog.pid"
    ok "看門狗已啟動，${TIMEOUT} 秒內未確認將自動還原"
    watchdog_boot_arm
}

# 只在開機時啟動：現在這一輪由上面的背景行程負責
# 排在 network-online 之後，開機等網路的時間才不會吃掉登入 confirm 的時限
watchdog_boot_arm() {
    if has systemctl && cat > "$WD_UNIT_FILE" <<EOF
[Unit]
Description=OPS net-set: restore unconfirmed IP change after reboot
ConditionPathExists=$STATE
After=network.target network-online.target

[Service]
Type=simple
ExecStart=/bin/sh $STATE_DIR/watchdog.sh

[Install]
WantedBy=multi-user.target
EOF
    then
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable "$WD_UNIT" >/dev/null 2>&1 && return 0
    fi
    warn "開機接手的服務裝不起來：這次變更若碰上重開機，不會自動還原"
    rm -f "$WD_UNIT_FILE" 2>/dev/null
}

watchdog_boot_disarm() {
    [ -e "$WD_UNIT_FILE" ] || return 0
    # 看門狗自己在這個服務裡跑 rollback 時不能 stop，會把自己殺掉
    if [ "$AUTO" = 1 ]; then
        systemctl disable "$WD_UNIT" >/dev/null 2>&1
    else
        systemctl disable --now "$WD_UNIT" >/dev/null 2>&1
    fi
    rm -f "$WD_UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1
}

watchdog_cancel() {
    touch "$STATE_DIR/confirmed" 2>/dev/null
    # 看門狗自己呼叫 rollback 時不能殺自己，confirmed 標記已足夠
    [ "$AUTO" = 1 ] && return 0
    has pkill && pkill -f "$STATE_DIR/watchdog.sh" 2>/dev/null
    watchdog_boot_disarm
    rm -f "$STATE_DIR/watchdog.pid" "$STATE_DIR/watchdog.sh" "$STATE_DIR/net-set.sh" 2>/dev/null
}

watchdog_alive() {
    has pgrep && pgrep -f "$STATE_DIR/watchdog.sh" >/dev/null 2>&1
}

# =========================================================
# 動手
# =========================================================
live_add() {   # $1 網卡 $2 位址/前綴 $3 標籤（可空）
    ip -o -4 addr show dev "$1" | awk '{print $4}' | grep -qxF "$2" && return 0
    if [ -n "${3:-}" ]; then
        ip addr add "$2" brd + dev "$1" label "$3"
    else
        ip addr add "$2" brd + dev "$1"
    fi
}

live_del() {   # $1 網卡 $2 位址
    _p=$(prefix_of_ip "$2")
    [ -n "$_p" ] || return 0
    ip addr del "$2/$_p" dev "$1"
}

# promote_secondaries=0 時刪掉主位址，核心會連同同網段的副位址一起砍，
# 預設路由也跟著消失。實際生效的是 all 或網卡自己其中一個為 1。
# 刪之前在這張網卡上暫時打開，刪完恢復原值。
promote_on() {
    PROMOTE_OLD=$(sysctl -n "net.ipv4.conf.$1.promote_secondaries" 2>/dev/null)
    sysctl -qw "net.ipv4.conf.$1.promote_secondaries=1" >/dev/null 2>&1
}

promote_off() {
    [ -n "${PROMOTE_OLD:-}" ] && \
        sysctl -qw "net.ipv4.conf.$1.promote_secondaries=$PROMOTE_OLD" >/dev/null 2>&1
    return 0
}

# 不管哪個後端，動完都要把執行中的狀態對回「應該有的樣子」。
ensure_addrs() {   # $1 網卡 $2 應有清單（位址/前綴，空白分隔）
    for _r in 1 2; do
        for _a in $(live_addrs "$1"); do
            case " $2 " in *" $_a "*) : ;; *) ip addr del "$_a" dev "$1" 2>/dev/null ;; esac
        done
        for _a in $2; do
            ip addr add "$_a" brd + dev "$1" 2>/dev/null
        done
    done
    return 0
}

ensure_gw() {   # $1 閘道 $2 網卡
    [ -n "$1" ] || return 0
    [ "$(default_gw)" = "$1" ] && return 0
    ip route replace default via "$1" dev "$2" onlink 2>/dev/null
    [ "$(default_gw)" = "$1" ]
}

verify_change() {   # $1 應該存在 $2 應該消失（都可空）
    if [ -n "$1" ] && [ "$(iface_of_ip "$1")" != "$IFACE" ]; then
        err "回讀失敗：$IFACE 上沒有 $1"
        return 1
    fi
    if [ -n "$2" ] && [ -n "$(iface_of_ip "$2")" ]; then
        err "回讀失敗：$2 還在網卡上"
        return 1
    fi
    if ! ensure_gw "$GW_BEFORE" "$GWDEV_BEFORE"; then
        err "預設閘道 $GW_BEFORE 不見了"
        return 1
    fi
    return 0
}

apply_add() {   # $1 位址 $2 前綴
    case "$BACKEND" in
        ifupdown)
            if_append "$IFACE" "$1" "$2" || return 1
            live_add "$IFACE" "$1/$2" "$IF_LABEL" ;;
        netplan)
            np addr-add "$IFACE" "$1/$2" || return 1
            np_apply || return 1
            live_add "$IFACE" "$1/$2" '' ;;
    esac
}

apply_del() {   # $1 位址
    _want=$(live_addrs "$IFACE" | grep -vF "$1/" | tr '\n' ' ')
    promote_on "$IFACE"
    case "$BACKEND" in
        ifupdown)
            _rec=$(if_find "$1")
            if_remove_stanza "$(printf '%s' "$_rec" | cut -d'|' -f1)" "$(printf '%s' "$_rec" | cut -d'|' -f2)" || { promote_off "$IFACE"; return 1; }
            live_del "$IFACE" "$1" ;;
        netplan)
            np addr-del "$IFACE" "$1" || { promote_off "$IFACE"; return 1; }
            np_apply || { promote_off "$IFACE"; return 1; }
            live_del "$IFACE" "$1" ;;
    esac
    promote_off "$IFACE"
    ensure_addrs "$IFACE" "$_want"
}

# 第二階段：讓新位址接手舊位址在設定檔裡的位置，再從網卡拿掉舊的
apply_finish_replace() {   # $1 舊 $2 新 $3 前綴
    _want=$(live_addrs "$IFACE" | grep -vF "$1/" | tr '\n' ' ')
    promote_on "$IFACE"
    case "$BACKEND" in
        ifupdown)
            _rec=$(if_find "$2")
            if_remove_stanza "$(printf '%s' "$_rec" | cut -d'|' -f1)" "$(printf '%s' "$_rec" | cut -d'|' -f2)" || { promote_off "$IFACE"; return 1; }
            _rec=$(if_find "$1")
            if_replace_addr "$(printf '%s' "$_rec" | cut -d'|' -f1)" "$1" "$2" || { promote_off "$IFACE"; return 1; }
            live_del "$IFACE" "$1" ;;
        netplan)
            np addr-replace "$IFACE" "$1" "$2/$3" || { promote_off "$IFACE"; return 1; }
            np_apply || { promote_off "$IFACE"; return 1; }
            live_del "$IFACE" "$1" ;;
    esac
    promote_off "$IFACE"
    ensure_addrs "$IFACE" "$_want"
}

do_rollback() {
    restore_backup "$BACKUP" || return 1
    [ "$BACKEND" = netplan ] && np_apply
    ensure_addrs "$IFACE" "$ADDRS_BEFORE"
    ensure_gw "$GW_BEFORE" "$GWDEV_BEFORE" || err "預設閘道還原失敗，請從主控台確認"
    rm -f "$STATE"
    ok "已還原：$IFACE = $ADDRS_BEFORE"
}

change_guard() {
    need_root
    case "$0" in
        /dev/fd/*|/proc/*|sh|bash|dash|-sh|-bash)
            die "看門狗需要本腳本的實體路徑，請改用 ops.sh 或 git clone 後執行" ;;
    esac
    [ -f "$SELF" ] || die "看門狗需要本腳本的實體路徑，請改用 ops.sh 或 git clone 後執行"
    os_supported || die "${OS_NAME:-這個系統} 還沒有支援改設定（目前只支援 Ubuntu 22.04 / 24.04）"
    detect_backend
    [ "$BACKEND" != none ] || die "拒絕變更：$BACKEND_WHY"
    has ip || die "找不到 ip 指令"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    pending_guard
}

# 替換與刪除共用：這個 IP 真的是我們管得到的嗎
managed_guard() {   # $1 位址 $2 網卡
    case "$BACKEND" in
        ifupdown)
            _rec=$(if_find "$1")
            [ -n "$_rec" ] || die "$1 不在 ifupdown 設定檔裡（可能是暫時加上的），這裡不處理"
            case "$(printf '%s' "$_rec" | cut -d'|' -f3)" in
                static) : ;;
                *) die "$1 不是靜態設定，改設定檔沒有意義" ;;
            esac
            [ "$(printf '%s' "$_rec" | cut -d'|' -f5)" = 1 ] || \
                die "$1 所在的段落有多個 address，這個寫法請手動處理"
            _ext=$(printf '%s' "$_rec" | cut -d'|' -f6)
            [ -z "$_ext" ] || die "$1 所在的段落有其他選項（$_ext），請手動處理" ;;
        netplan)
            np_has_addr "$2" "$1" || \
                die "$1 不在 netplan 設定裡（可能是 DHCP 或暫時加上的），這裡不處理" ;;
    esac
}

begin_ip_change() {
    backup_net
    ADDRS_BEFORE=$(live_addrs "$IFACE" | tr '\n' ' ' | sed 's/ $//')
    GW_BEFORE=$(default_gw)
    GWDEV_BEFORE=$(default_iface)
    state_set
    watchdog_start
}

fail_ip_change() {
    err "$1"
    warn "馬上還原到變更前"
    watchdog_cancel
    do_rollback
    exit 1
}

next_step_hint() {
    plain ""
    plain "  下一步：確認連線正常後執行  $0 confirm"
    plain "  反悔：$0 rollback；${TIMEOUT} 秒內沒確認會自動還原"
}

parse_ip_arg() {   # $1 = IP[/前綴] → ARG_IP / ARG_PFX
    ARG_IP=${1%%/*}; ARG_PFX=''
    case "$1" in */*) ARG_PFX=${1#*/} ;; esac
    if ip6_like "$ARG_IP"; then
        die "第一版的 IP 操作只支援 IPv4，不處理 $ARG_IP"
    fi
    ip4_valid "$ARG_IP" || die "IP 格式不對：$1"
    case "$ARG_PFX" in
        '') : ;;
        *[!0-9]*) die "前綴格式不對：$1" ;;
        *) { [ "$ARG_PFX" -ge 1 ] && [ "$ARG_PFX" -le 32 ]; } || die "前綴超出範圍：$1" ;;
    esac
}

cmd_ip_add() {
    [ $# -ge 1 ] || die "用法：ip-add <IP[/前綴]> [-i 網卡]"
    change_guard
    parse_ip_arg "$1"
    NEW_IP=$ARG_IP; OLD_IP=''; OP=add; IF_LABEL=''
    [ -z "$(iface_of_ip "$NEW_IP")" ] || die "$NEW_IP 已經在 $(iface_of_ip "$NEW_IP") 上"
    pick_iface_for_add "$NEW_IP" "$ARG_PFX"
    IFACE=$ADD_IFACE; PREFIX=$ADD_PREFIX
    [ -n "$IFACE" ] || die "找不到要加在哪張網卡，請用 -i 指定"
    [ -d "/sys/class/net/$IFACE" ] || die "沒有這張網卡：$IFACE"
    [ -n "$PREFIX" ] || die "$NEW_IP 不在現有網段裡，請帶前綴（例：$NEW_IP/24）"
    if [ -n "$ARG_PFX" ] && [ "$ARG_PFX" != "$PREFIX" ]; then
        warn "$NEW_IP 落在 /$PREFIX 網段內，你給的 /$ARG_PFX 不一致，改用 /$PREFIX"
    fi
    ip_usable "$NEW_IP" "$PREFIX" || die "$NEW_IP/$PREFIX 不能設在網卡上（網路位址、廣播或保留位址）"
    [ "$NEW_IP" != "$(default_gw)" ] || die "$NEW_IP 是預設閘道"
    if ip_taken "$NEW_IP" "$IFACE"; then
        die "$NEW_IP 在網路上已經有人回應，疑似被使用中"
    fi

    step "增加 IP"
    info "網卡 $IFACE，位址 $NEW_IP/$PREFIX，後端 $BACKEND"
    info "預設閘道不會變動"
    warn_comment_loss "$IFACE"
    warn_overrides
    [ "$DRY" = 1 ] && { info "乾跑：不做任何變更"; return 0; }
    confirm "確定要增加 $NEW_IP/$PREFIX 嗎？" || return 1

    begin_ip_change
    apply_add "$NEW_IP" "$PREFIX" || fail_ip_change "寫入設定失敗"
    verify_change "$NEW_IP" '' || fail_ip_change "驗證失敗"
    state_set
    ok "$NEW_IP/$PREFIX 已加到 $IFACE"
    next_step_hint
}

cmd_ip_del() {
    [ $# -ge 1 ] || die "用法：ip-del <IP>"
    change_guard
    parse_ip_arg "$1"
    OLD_IP=$ARG_IP; NEW_IP=''; OP=del; IF_LABEL=''
    IFACE=$(iface_of_ip "$OLD_IP")
    [ -n "$IFACE" ] || die "$OLD_IP 不在任何網卡上"
    PREFIX=$(prefix_of_ip "$OLD_IP")

    # 這條不看 -y，也沒有開關可以繞過
    if ip_in_ssh_use "$OLD_IP"; then
        die "$OLD_IP 正被 SSH 連線使用，不能直接刪除。請改用 ip-replace"
    fi
    managed_guard "$OLD_IP" "$IFACE"

    if [ "$BACKEND" = ifupdown ]; then
        _rec=$(if_find "$OLD_IP")
        [ "$(printf '%s' "$_rec" | cut -d'|' -f4)" = 0 ] || \
            die "$OLD_IP 所在的段落帶著閘道，不能刪除。要換位址請用 ip-replace"
        _lbl=$(printf '%s' "$_rec" | cut -d'|' -f2)
        case "$_lbl" in
            *:*) : ;;
            *) [ "$(if_base_count "$_lbl")" -gt 1 ] || \
                   die "$OLD_IP 是 $_lbl 唯一的主位址，不能刪除。要換位址請用 ip-replace" ;;
        esac
    fi

    # 預設閘道要還到得了：刪掉之後同網卡必須還有位址跟閘道同網段
    _gw=$(default_gw)
    if [ -n "$_gw" ] && [ "$(default_iface)" = "$IFACE" ]; then
        _reach=0
        for _a in $(live_addrs "$IFACE"); do
            _i=${_a%/*}; _p=${_a#*/}
            [ "$_i" = "$OLD_IP" ] && continue
            [ "$(netn "$_i" "$_p")" = "$(netn "$_gw" "$_p")" ] && _reach=1
        done
        [ "$_reach" = 1 ] || die "刪掉 $OLD_IP 之後預設閘道 $_gw 會到不了，拒絕"
    fi

    step "刪除 IP"
    info "網卡 $IFACE，位址 $OLD_IP/$PREFIX，後端 $BACKEND"
    warn_bound_services "$OLD_IP"
    warn_comment_loss "$IFACE"
    warn_overrides
    [ "$DRY" = 1 ] && { info "乾跑：不做任何變更"; return 0; }
    confirm "確定要刪除 $OLD_IP 嗎？" || return 1

    begin_ip_change
    apply_del "$OLD_IP" || fail_ip_change "寫入設定失敗"
    verify_change '' "$OLD_IP" || fail_ip_change "驗證失敗"
    ok "$OLD_IP 已從 $IFACE 移除"
    next_step_hint
}

cmd_ip_replace() {
    [ $# -ge 2 ] || die "用法：ip-replace <舊IP> <新IP>"
    change_guard
    parse_ip_arg "$1"; OLD_IP=$ARG_IP
    parse_ip_arg "$2"; NEW_IP=$ARG_IP; _newpfx=$ARG_PFX
    OP=replace; IF_LABEL=''
    [ "$OLD_IP" != "$NEW_IP" ] || die "新舊 IP 相同"
    IFACE=$(iface_of_ip "$OLD_IP")
    [ -n "$IFACE" ] || die "$OLD_IP 不在任何網卡上"
    PREFIX=$(prefix_of_ip "$OLD_IP")
    [ -z "$(iface_of_ip "$NEW_IP")" ] || die "$NEW_IP 已經在 $(iface_of_ip "$NEW_IP") 上"
    if [ "$(netn "$OLD_IP" "$PREFIX")" != "$(netn "$NEW_IP" "$PREFIX")" ]; then
        die "$NEW_IP 跟 $OLD_IP/$PREFIX 不同網段。第一版只支援同網段替換；跨網段請用 ip-add 加副 IP"
    fi
    if [ -n "$_newpfx" ] && [ "$_newpfx" != "$PREFIX" ]; then
        die "替換不改前綴：$OLD_IP 是 /$PREFIX，你給的是 /$_newpfx"
    fi
    ip_usable "$NEW_IP" "$PREFIX" || die "$NEW_IP/$PREFIX 不能設在網卡上（網路位址、廣播或保留位址）"
    [ "$NEW_IP" != "$(default_gw)" ] || die "$NEW_IP 是預設閘道"
    managed_guard "$OLD_IP" "$IFACE"
    if ip_taken "$NEW_IP" "$IFACE"; then
        die "$NEW_IP 在網路上已經有人回應，疑似被使用中"
    fi
    # sshd 只綁舊 IP 的話，新 IP 根本登不進來，看門狗倒數完就是白忙一場
    if ip_in_ssh_use "$OLD_IP" && ! sshd_listens_on "$NEW_IP"; then
        die "sshd 的 ListenAddress 沒有包含 $NEW_IP，換過去會登不進來。請先調整 sshd_config"
    fi

    step "替換 IP（兩階段）"
    info "網卡 $IFACE，$OLD_IP/$PREFIX → $NEW_IP/$PREFIX，後端 $BACKEND"
    info "第一階段：加上 $NEW_IP，新舊並存"
    info "第二階段：你從 $NEW_IP 登入並 confirm 後，才移除 $OLD_IP"
    warn_bound_services "$OLD_IP"
    warn_comment_loss "$IFACE"
    warn_overrides
    [ "$DRY" = 1 ] && { info "乾跑：不做任何變更"; return 0; }
    confirm "確定要開始替換嗎？" || return 1

    begin_ip_change
    apply_add "$NEW_IP" "$PREFIX" || fail_ip_change "寫入設定失敗"
    verify_change "$NEW_IP" '' || fail_ip_change "驗證失敗"
    state_set
    ok "$NEW_IP/$PREFIX 已加到 $IFACE，新舊並存中"
    plain ""
    plain "  下一步：開新終端機從 $NEW_IP 登入，再執行  $0 confirm"
    plain "  反悔：$0 rollback；${TIMEOUT} 秒內沒確認會自動還原"
}

cmd_confirm() {
    need_root
    state_load
    if [ "$OP" = replace ]; then
        _me=$(session_ip)
        # 這條不看 -y：沒從新 IP 登入過就收掉舊 IP，等於賭新 IP 一定通
        if [ "$_me" = "$OLD_IP" ]; then
            die "你現在是從舊 IP $OLD_IP 連進來的。請從 $NEW_IP 登入後再 confirm"
        fi
        if [ -z "$_me" ] && sshd_ips | grep -qxF "$OLD_IP" && ! sshd_ips | grep -qxF "$NEW_IP"; then
            die "判斷不出這條連線的來源，而且 $NEW_IP 上沒有任何 SSH 連線。請從 $NEW_IP 登入後再 confirm"
        fi
        if sshd_ips | grep -qxF "$OLD_IP"; then
            warn "還有其他 SSH 連線走 $OLD_IP，移除後會中斷"
        fi
        watchdog_cancel
        step "第二階段：移除 $OLD_IP"
        apply_finish_replace "$OLD_IP" "$NEW_IP" "$PREFIX" || { do_rollback; die "寫入設定失敗，已還原"; }
        verify_change "$NEW_IP" "$OLD_IP" || { do_rollback; die "驗證失敗，已還原"; }
        ok "替換完成：$OLD_IP → $NEW_IP"
    else
        watchdog_cancel
        ok "已確認，看門狗取消"
    fi
    rm -f "$STATE"
    warn_overrides
}

cmd_rollback() {
    need_root
    state_load
    step "還原 IP 變更"
    watchdog_cancel
    do_rollback || die "還原失敗，請手動從 $BACKUP 取回設定"
    if [ "$AUTO" = 1 ]; then
        info "（此次為看門狗逾時自動還原）"
        watchdog_boot_disarm
        rm -f "$STATE_DIR/watchdog.pid" "$STATE_DIR/watchdog.sh" "$STATE_DIR/net-set.sh" 2>/dev/null
    fi
    return 0
}

# =========================================================
# DNS
# =========================================================
dns_valid() {
    ip4_valid "$1" || ip6_like "$1" || return 1
    case "$1" in 127.*|::1) return 1 ;; esac
    return 0
}

dns_iface() { default_iface; }

# 目前「設定上」的清單，增刪都以它為基準
dns_list() {
    case "$DNS_MODE" in
        file) awk '$1 == "nameserver" { print $2 }' "$RESOLV" ;;
        netplan-resolved) np show "$(dns_iface)" 2>/dev/null | awk '$1 == "dns" { print $2 }' ;;
    esac
}

# 向指定的 DNS 查一次：0 通 / 1 不通 / 2 沒有工具可以查
dns_probe() {
    if has dig; then
        # dig 逾時時會把 ";; connection timed out" 印在 stdout，不能只看有沒有輸出
        dig "@$1" +time=2 +tries=1 +short A "$TESTNAME" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        return $?
    fi
    if has nslookup; then
        nslookup -timeout=2 "$TESTNAME" "$1" >/dev/null 2>&1; return $?
    fi
    if has python3; then
        python3 - "$1" "$TESTNAME" <<'PY'
import socket, struct, sys
srv, name = sys.argv[1:3]
q = struct.pack(">HHHHHH", 0x4f50, 0x100, 1, 0, 0, 0)
q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
q += struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET6 if ":" in srv else socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.sendto(q, (srv, 53))
    r = s.recv(1024)
except OSError:
    sys.exit(1)
sys.exit(0 if len(r) > 12 and r[3] & 15 == 0 and r[6:8] != b"\0\0" else 1)
PY
        return $?
    fi
    return 2
}

dns_probe_guard() {   # $1 = 要加入的 DNS
    dns_probe "$1"
    case $? in
        0) ok "$1 可以解析 $TESTNAME" ;;
        2) warn "沒有 dig / nslookup / python3，無法事先向 $1 查詢" ;;
        *)
            warn "$1 查不到 $TESTNAME（DNS 不通，或它只服務內部網域）"
            [ "$DRY" = 1 ] && return 0
            # -y 是給排程用的，沒有人看著就不賭
            [ "$YES" = 1 ] && die "免確認模式下拒絕加入查不到的 DNS"
            confirm "仍然要繼續嗎？" || exit 1 ;;
    esac
}

dns_file_write() {   # $@ = 新清單。search / options 與註解保留
    if has lsattr && lsattr -d "$RESOLV" 2>/dev/null | awk '{print $1}' | grep -q i; then
        err "$RESOLV 設了不可變更屬性（chattr +i）"
        return 1
    fi
    _list=$(printf '%s ' "$@")
    awk -v list="$_list" '
        BEGIN { n = split(list, s, " ") }
        function emit() { for (i = 1; i <= n; i++) print "nameserver " s[i]; done = 1 }
        $1 == "nameserver" { if (!done) emit(); next }
        { print }
        END { if (!done) emit() }
    ' "$RESOLV" > "$RESOLV.ops-new" || return 1
    chmod 644 "$RESOLV.ops-new"
    mv -f "$RESOLV.ops-new" "$RESOLV"
}

dns_write() {
    case "$DNS_MODE" in
        file) dns_file_write "$@" ;;
        netplan-resolved)
            np dns-set "$(dns_iface)" "$@" || return 1
            np_apply ;;
    esac
}

# systemd-resolved 有快取，不先清掉的話 DNS 全壞了也查得到
resolves_now() {
    if [ "$DNS_MODE" = netplan-resolved ] && has resolvectl; then
        resolvectl flush-caches 2>/dev/null
    fi
    getent ahosts "$TESTNAME" >/dev/null 2>&1
}

dns_guard() {
    need_root
    os_supported || die "${OS_NAME:-這個系統} 還沒有支援改設定（目前只支援 Ubuntu 22.04 / 24.04）"
    detect_backend
    detect_dns_mode
    [ "$DNS_MODE" != none ] || die "拒絕變更：$DNS_WHY"
    # 在 netplan 模式下還原 IP 會把同一份檔案蓋回去，所以不交錯進行
    pending_guard
    DNS_CUR=$(dns_list | tr '\n' ' ' | sed 's/ $//')
}

# $1 = 動作說明；其餘 = 新清單
dns_change() {
    _what=$1; shift
    step "$_what"
    info "目前：${DNS_CUR:-（空）}"
    info "改為：$*"
    case "$DNS_MODE" in
        file)
            info "寫入 $RESOLV（這台由它直接決定）"
            [ $# -gt 3 ] && warn "glibc 只會用前 3 台，第 4 台之後不會被查"
            if [ "$BACKEND" = ifupdown ] && grep -hqE '^[[:space:]]*dns-nameservers' $(ifupdown_files) 2>/dev/null; then
                info "interfaces 裡的 dns-nameservers 在這台沒有作用，不更動"
            fi ;;
        netplan-resolved)
            info "寫入 netplan 的 $(dns_iface) nameservers，再由 systemd-resolved 套用"
            warn_comment_loss "$(dns_iface)" ;;
    esac
    warn_overrides
    [ "$DRY" = 1 ] && { info "乾跑：不做任何變更"; return 0; }
    confirm "確定要變更 DNS 嗎？" || return 1

    _base=0
    resolves_now && _base=1
    backup_net
    if ! dns_write "$@"; then
        err "寫入失敗，還原"
        restore_backup "$BACKUP"
        [ "$DNS_MODE" = netplan-resolved ] && np_apply
        exit 1
    fi

    _now=$(dns_list | tr '\n' ' ' | sed 's/ $//')
    if [ "$_now" != "$*" ]; then
        err "回讀不符：$_now"
        restore_backup "$BACKUP"
        [ "$DNS_MODE" = netplan-resolved ] && np_apply
        exit 1
    fi

    if resolves_now; then
        ok "解析 $TESTNAME 正常"
    elif [ "$_base" = 1 ]; then
        err "變更後解析不了 $TESTNAME，變更前可以，還原"
        restore_backup "$BACKUP"
        [ "$DNS_MODE" = netplan-resolved ] && np_apply
        exit 1
    else
        warn "解析 $TESTNAME 失敗，但變更前也失敗，不視為這次變更造成"
    fi
    ok "DNS 已更新：$*"
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

cmd_dns_add() {
    [ $# -ge 1 ] || die "用法：dns-add <DNS> [--first]"
    dns_valid "$1" || die "DNS 格式不對：$1"
    dns_guard
    in_list "$1" "$DNS_CUR" && die "$1 已經在清單裡"
    dns_probe_guard "$1"
    if [ "$DNS_FIRST" = 1 ]; then
        # shellcheck disable=SC2086
        dns_change "增加 DNS（放最前面）" "$1" $DNS_CUR
    else
        # shellcheck disable=SC2086
        dns_change "增加 DNS" $DNS_CUR "$1"
    fi
}

cmd_dns_del() {
    [ $# -ge 1 ] || die "用法：dns-del <DNS>"
    dns_valid "$1" || die "DNS 格式不對：$1"
    dns_guard
    in_list "$1" "$DNS_CUR" || die "$1 不在清單裡（目前：${DNS_CUR:-空}）"
    _new=''
    for _d in $DNS_CUR; do
        [ "$_d" = "$1" ] || _new="$_new $_d"
    done
    [ -n "$_new" ] || die "$1 是最後一台 DNS，不能刪除。要換請用 dns-replace"
    # shellcheck disable=SC2086
    dns_change "刪除 DNS" $_new
}

cmd_dns_replace() {
    [ $# -ge 2 ] || die "用法：dns-replace <舊DNS> <新DNS>"
    dns_valid "$1" || die "DNS 格式不對：$1"
    dns_valid "$2" || die "DNS 格式不對：$2"
    dns_guard
    in_list "$1" "$DNS_CUR" || die "$1 不在清單裡（目前：${DNS_CUR:-空}）"
    in_list "$2" "$DNS_CUR" && die "$2 已經在清單裡"
    dns_probe_guard "$2"
    _new=''
    for _d in $DNS_CUR; do
        if [ "$_d" = "$1" ]; then _new="$_new $2"; else _new="$_new $_d"; fi
    done
    # shellcheck disable=SC2086
    dns_change "替換 DNS" $_new
}

# =========================================================
# 查詢
# =========================================================
cmd_status() {
    detect_backend
    detect_dns_mode
    plain " 系統    ${OS_NAME:-未知}"
    if [ "$BACKEND" = none ]; then
        plain " 後端    ${CY}無法使用${C0}：$BACKEND_WHY"
    else
        plain " 後端    $BACKEND"
    fi
    _me=$(session_ip)
    for _d in $(ls /sys/class/net 2>/dev/null); do
        [ "$_d" = lo ] && continue
        _al=$(live_addrs "$_d" | tr '\n' ' ')
        plain " 網卡    $_d  ${_al:-（無 IPv4）}"
    done
    plain " 閘道    $(default_gw) dev $(default_iface)"
    [ -n "$_me" ] && plain " SSH     這條連線走 $_me"
    if [ "$DNS_MODE" = none ]; then
        plain " DNS     ${CY}無法判斷${C0}：$DNS_WHY"
    else
        plain " DNS     $(dns_list | tr '\n' ' ') ${CD}（$DNS_MODE）${C0}"
    fi
    if [ -f "$STATE" ]; then
        (
            . "$STATE"
            _left=$(( DEADLINE - $(date +%s) ))
            if watchdog_alive; then
                plain " ${CY}進行中${C0}  $(pending_desc)  剩 ${_left} 秒自動還原"
            else
                plain " ${CY}進行中${C0}  $(pending_desc)"
                plain " ${CR}看門狗已不在${C0}，不會自動還原，請手動 confirm 或 rollback"
            fi
        )
    fi
    [ "${1:-}" = bare ] && return 0
    _ov=$(override_sources)
    if [ -n "$_ov" ]; then
        plain " 覆寫來源"
        printf '%s\n' "$_ov" | sed 's/^/   /'
    fi
}

cmd_doctor() {
    step "環境檢查"
    if os_supported; then
        ok "${OS_NAME}：支援改設定"
    else
        warn "${OS_NAME:-未知系統}：只能查詢，還不能改設定"
    fi
    detect_backend
    detect_dns_mode
    if [ "$BACKEND" = none ]; then
        err "後端無法使用：$BACKEND_WHY"
    else
        ok "網路後端：$BACKEND"
    fi
    if [ "$DNS_MODE" = none ]; then
        err "DNS：$DNS_WHY"
    else
        ok "DNS 寫入位置：$DNS_MODE"
    fi
    for _t in ip ss tar getent; do
        has "$_t" && ok "$_t" || err "缺少 $_t"
    done
    { has dig || has nslookup; } || info "沒有 dig / nslookup，事先查詢改用 python3"
    # 核心看的是 all 跟網卡自己其中一個為 1
    _pd=$(default_iface)
    if [ -n "$_pd" ] && [ "$(sysctl -n net.ipv4.conf.all.promote_secondaries 2>/dev/null)" != 1 ] && \
       [ "$(sysctl -n "net.ipv4.conf.$_pd.promote_secondaries" 2>/dev/null)" != 1 ]; then
        info "$_pd 的 promote_secondaries 沒開：刪主位址時核心會連副位址一起移除，工具動手時會暫時打開"
    fi
    if [ "$BACKEND" = ifupdown ] && [ "$DNS_MODE" = file ] && \
       grep -hqE '^[[:space:]]*dns-nameservers' $(ifupdown_files) 2>/dev/null; then
        info "interfaces 裡的 dns-nameservers 沒有作用（沒裝 resolvconf），DNS 以 $RESOLV 為準"
    fi
    _ov=$(override_sources)
    if [ -n "$_ov" ]; then
        warn_overrides
    else
        ok "沒有偵測到已知的覆寫來源"
    fi
}

usage() {
    sed -n '2,/^# 設計原則/p' "$SELF" 2>/dev/null | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 0
}

# =========================================================
# 進入點
# =========================================================
detect_env

CMD="${1:-}"
[ $# -gt 0 ] && shift

# 選項可以出現在參數前後，其餘留給子指令
_args=''
_n=$#
while [ "$_n" -gt 0 ]; do
    _a=$1; shift; _n=$(( _n - 1 ))
    case "$_a" in
        -y|--yes) YES=1 ;;
        -n|--dry-run) DRY=1 ;;
        --first) DNS_FIRST=1 ;;
        --auto) AUTO=1 ;;
        -i) IFACE_OPT=${1:-}; [ $# -gt 0 ] && { shift; _n=$(( _n - 1 )); } ;;
        -t) TIMEOUT=${1:-}; [ $# -gt 0 ] && { shift; _n=$(( _n - 1 )); } ;;
        *) set -- "$@" "$_a" ;;
    esac
done

case "$TIMEOUT" in
    ''|*[!0-9]*) die "-t 要給秒數" ;;
esac
[ "$TIMEOUT" -ge 30 ] || die "-t 至少 30 秒，太短會來不及從新 IP 登入"

case "$CMD" in
    status) cmd_status "$@" ;;
    doctor) cmd_doctor ;;
    ip-add) cmd_ip_add "$@" ;;
    ip-del) cmd_ip_del "$@" ;;
    ip-replace) cmd_ip_replace "$@" ;;
    dns-add) cmd_dns_add "$@" ;;
    dns-del) cmd_dns_del "$@" ;;
    dns-replace) cmd_dns_replace "$@" ;;
    confirm) cmd_confirm ;;
    rollback) cmd_rollback ;;
    -h|--help|help|'') usage ;;
    *) err "未知指令：$CMD"; usage ;;
esac
