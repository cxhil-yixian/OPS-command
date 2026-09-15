#!/bin/sh
# apps.sh — 常用軟體安裝：docker / nc / tcpping / mtr / nginx
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux / Fedora
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine
#       openSUSE（zypper）/ Arch（pacman）—— 套件名有對應，未實測
#
# 用法：
#   ./apps.sh status                    五項軟體的安裝狀態與版本
#   ./apps.sh install <名稱...>          安裝指定項目，例：install nc mtr
#   ./apps.sh install all               五項裡還沒裝的全部裝
#
#   名稱：docker / nc / tcpping / mtr / nginx
#   共用選項：-y 免確認、-n 乾跑
#
# 各項的裝法：
#   docker   官方的 get.docker.com 腳本（先下載成檔案、驗過內容再 sh 執行）；
#            Alpine 不在它的支援清單裡，改用 apk；AlmaLinux 等它不認得的 RHEL 系
#            改走 Docker 官方文件的 docker-ce repo 手動裝法
#   tcpping  不在任何發行版的套件庫裡：先用套件管理器裝 traceroute（tcpping 實際
#            是靠它送 TCP SYN），再從 GitHub 下載固定版本的 tcpping 腳本
#   其他     依套件管理器對應套件名（nc 在 RHEL 系叫 nmap-ncat、Debian 系叫
#            netcat-openbsd；mtr 在 Debian 系叫 mtr-tiny）
#
# 設計原則：
#   1. 裝之前把「會跑什麼指令、會改到什麼」全部攤開，一次確認。
#   2. 已經裝好的不重裝。get-docker.sh 對已裝 docker 的機器會重設 repo 設定，
#      那是它自己警告過的事，這裡直接略過而不是讓它跑。
#   3. 裝完回頭驗證指令真的在，不以套件管理器的回傳碼為準。
#   4. 服務要不要開機啟動不替你決定（docker 例外，見下）；有「裝完就自動起來」
#      的發行版行為先講，例如 Debian 系的 nginx 會立刻去搶 80 埠。
#
# 以 POSIX sh 撰寫，Alpine 不需額外安裝 bash。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

APPS_SH_VER=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# 產出檔案跟其他工具收在一起（見 ../SSH/README.md 的「檔案位置」）
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
LOGFILE="$OPS_SSH_DIR/apps-ops.log"

# docker 安裝腳本。內網鏡像可用 OPS_DOCKER_URL 換掉。
DOCKER_URL="${OPS_DOCKER_URL:-https://get.docker.com}"
# get-docker.sh 內建的鏡像：Aliyun / AzureChinaCloud。空 = 直接用 download.docker.com
DOCKER_MIRROR="${OPS_DOCKER_MIRROR:-}"

# tcpping 釘在 release tag，不抓 master：master 是 -dev 版，行為隨時會變。
TCPPING_VER=v2.7
TCPPING_URL="${OPS_TCPPING_URL:-https://raw.githubusercontent.com/deajan/tcpping/$TCPPING_VER/tcpping}"
TCPPING_DEST=/usr/local/bin/tcpping

ALL_APPS='docker nc tcpping mtr nginx'

DRY=0
YES=0

# ---------- 輸出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
    CB=$(printf '\033[1m');  CD=$(printf '\033[2m');  C0=$(printf '\033[0m')
else
    CR=''; CG=''; CY=''; CB=''; CD=''; C0=''
fi

# 乾跑的每一行都標 [乾跑]，事後翻日誌才分得出哪些真的做過（同 time-set.sh）
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
    info "請用 sudo -i 或 su - 切換後重跑：$SELF"
    exit 1
}

confirm() {
    [ "$YES" = 1 ] && return 0
    printf '%s%s%s [y/N] ' "$CY" "$1" "$C0"
    read -r _a 2>/dev/null || _a=''
    case "$_a" in y|Y|yes|YES) return 0 ;; *) info "已取消"; return 1 ;; esac
}

# 乾跑時只印不做。回傳 1 讓呼叫端知道「沒有真的執行」
run() {
    if [ "$DRY" = 1 ]; then
        printf '   %s[乾跑]%s %s\n' "$CD" "$C0" "$*"
        return 1
    fi
    info "執行：$*"
    "$@"
}

# 下載單一檔案（不做驗證，驗證由呼叫端依內容決定）
fetch() {
    if has curl; then
        curl -fsSL --connect-timeout 10 --max-time 180 -o "$2" "$1"
    elif has wget; then
        wget -q --timeout=20 -O "$2" "$1"
    else
        err "需要 curl 或 wget 才能下載"
        return 127
    fi
}

# =========================================================
# 環境偵測
#   套件名跟著「套件管理器」走，不跟著發行版名稱走：ID_LIKE 沒寫或寫得怪的
#   衍生版（其他類）只要用的是 apt / dnf / yum / apk / zypper / pacman，一樣對得上。
# =========================================================
detect_env() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
    else
        ID=unknown; ID_LIKE=''; PRETTY_NAME=unknown; VERSION_ID=''
    fi
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    OS_VER="${VERSION_ID:-}"
    OS_MAJOR="${OS_VER%%.*}"
    case " ${ID_LIKE:-} ${ID:-} " in
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) OS_FAMILY=rhel ;;
        *debian*|*ubuntu*)                            OS_FAMILY=debian ;;
        *alpine*)                                     OS_FAMILY=alpine ;;
        *suse*)                                       OS_FAMILY=suse ;;
        *arch*)                                       OS_FAMILY=arch ;;
        *)                                            OS_FAMILY=unknown ;;
    esac

    if   has apk;     then PKG=apk;    PKG_INSTALL='apk add --no-cache'
    elif has dnf;     then PKG=dnf;    PKG_INSTALL='dnf install -y'
    elif has yum;     then PKG=yum;    PKG_INSTALL='yum install -y'
    elif has apt-get; then PKG=apt;    PKG_INSTALL='apt-get install -y'
    elif has zypper;  then PKG=zypper; PKG_INSTALL='zypper --non-interactive install'
    elif has pacman;  then PKG=pacman; PKG_INSTALL='pacman -S --noconfirm --needed'
    else                   PKG=none;   PKG_INSTALL='(找不到套件管理器)'
    fi

    if   [ -d /run/systemd/system ]; then INIT=systemd
    elif has rc-service;             then INIT=openrc
    else                                  INIT=sysv
    fi

    CONTAINER=''
    if   [ -f /.dockerenv ];        then CONTAINER=docker
    elif [ -f /run/.containerenv ]; then CONTAINER=podman
    elif grep -qE '(docker|lxc|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then CONTAINER=container
    fi
}

# 項目 -> 這台要裝的套件名。空字串 = 這個套件管理器沒有對應（呼叫端要講）
pkg_of() {
    case "$1:$PKG" in
        nc:dnf|nc:yum)        echo nmap-ncat ;;
        nc:apt|nc:apk)        echo netcat-openbsd ;;
        nc:zypper)            echo netcat-openbsd ;;
        nc:pacman)            echo openbsd-netcat ;;
        mtr:apt)              echo mtr-tiny ;;          # mtr 那個會拉進整套 GTK
        mtr:*)                echo mtr ;;
        nginx:*)              echo nginx ;;
        # tcpping 的前置：GNU traceroute 2.x 才有 -T（TCP SYN）。
        # Alpine 的 traceroute 是 busybox 版不支援 -T，改裝 tcptraceroute（tcpping 會自動改用它）
        tcpping:apk)          echo tcptraceroute ;;
        tcpping:*)            echo traceroute ;;
        *)                    echo '' ;;
    esac
}

# 項目 -> 用來判斷「裝好了沒」的指令
cmd_of() {
    case "$1" in
        nc)      echo nc ;;
        *)       echo "$1" ;;
    esac
}

is_app() {
    case " $ALL_APPS " in *" $1 "*) return 0 ;; esac
    return 1
}

# 裝好了嗎？tcpping 還要看前置的 traceroute 在不在，只有腳本沒有它是跑不動的
installed() {
    case "$1" in
        tcpping) has tcpping && { has traceroute || has tcptraceroute; } ;;
        *)       has "$(cmd_of "$1")" ;;
    esac
}

# 版本字串，給 status 與裝完的驗證用。拿不到就回傳空的
ver_of() {
    case "$1" in
        docker)  docker --version 2>/dev/null | head -1 ;;
        nginx)   nginx -v 2>&1 | sed -n 's/^nginx version: //p' | head -1 ;;
        mtr)     mtr --version 2>/dev/null | head -1 ;;
        tcpping) _p=$(command -v tcpping 2>/dev/null)
                 [ -n "$_p" ] && sed -n 's/^ver="\(.*\)"$/tcpping \1/p' "$_p" 2>/dev/null | head -1 ;;
        nc)      # ncat 會報版本；openbsd 版沒有 --version，只好不給。
                 # busybox 的 nc 要標出來：它能用，但沒有 -z / -w 以外的大部分選項
                 case "$(readlink -f "$(command -v nc 2>/dev/null)" 2>/dev/null)" in
                     */busybox) echo "busybox nc（精簡版，要完整版：$PKG_INSTALL $(pkg_of nc)）"; return ;;
                 esac
                 nc --version 2>&1 | grep '^Ncat: Version' | head -1 ;;
    esac
}

svc_state() {
    case "$INIT" in
        systemd) _st=$(systemctl is-active "$1" 2>/dev/null); _en=$(systemctl is-enabled "$1" 2>/dev/null)
                 printf '%s，開機啟動 %s' "${_st:-inactive}" "${_en:-disabled}" ;;
        openrc)  if rc-service "$1" status >/dev/null 2>&1; then printf 'active'; else printf 'inactive'; fi
                 if rc-update show 2>/dev/null | grep -q "^ *$1 "; then printf '，開機啟動 enabled'
                 else printf '，開機啟動 disabled'; fi ;;
        *)       printf 'unknown' ;;
    esac
}

# 80 埠有沒有人在聽。Debian 系裝 nginx 會立刻啟動它去 bind 80，被佔住的話
# postinst 會失敗、dpkg 把套件標成半裝狀態 —— 裝之前先講比事後修好。
port80_owner() {
    if has ss; then
        ss -ltnpH 2>/dev/null | awk '$4 ~ /:80$/ {print; exit}'
    elif has netstat; then
        netstat -ltnp 2>/dev/null | awk '$4 ~ /:80$/ {print; exit}'
    fi
}

# =========================================================
# status
# =========================================================
# $1 = bare 時只印資料列（ops.sh 的子選單自己有標頭，同 time-set.sh）
cmd_status() {
    if [ "${1:-}" != bare ]; then
        plain ""
        plain "${CB} 常用軟體${C0}  ${CD}$OS_PRETTY（pkg=$PKG）${C0}"
        plain " ──────────────────────────────────────────────"
    fi
    for _a in $ALL_APPS; do
        if installed "$_a"; then
            _v=$(ver_of "$_a")
            [ -z "$_v" ] && _v=$(command -v "$(cmd_of "$_a")")
            printf '   %-8s %s已安裝%s  %s' "$_a" "$CG" "$C0" "$_v"
            case "$_a" in
                docker|nginx) [ "$INIT" != sysv ] && printf '  %s(%s)%s' "$CD" "$(svc_state "$_a")" "$C0" ;;
            esac
            printf '\n'
        elif [ "$_a" = tcpping ] && has tcpping; then
            printf '   %-8s %s缺 traceroute%s  %s(腳本在，但沒有它送不出 TCP SYN)%s\n' \
                   "$_a" "$CY" "$C0" "$CD" "$C0"
        else
            printf '   %-8s %s未安裝%s\n' "$_a" "$CD" "$C0"
        fi
    done
    [ "${1:-}" != bare ] && plain ""
    return 0
}

# =========================================================
# install
# =========================================================
# RHEL/CentOS 7 的 nginx 在 EPEL；8 之後在 AppStream，不需要。
need_epel() {
    [ "$PKG" = yum ] || [ "$PKG" = dnf ] || return 1
    case "$OS_ID" in
        centos|rhel|rocky|almalinux|ol) : ;;
        *) return 1 ;;
    esac
    [ "$OS_MAJOR" = 7 ] || return 1
    rpm -q epel-release >/dev/null 2>&1 && return 1
    ls /etc/yum.repos.d/ 2>/dev/null | grep -qi epel && return 1
    return 0
}

# docker 走哪條路：
#   getdocker  官方 get.docker.com（使用者指定的做法）
#   apk        Alpine：get-docker.sh 會直接回 Unsupported distribution
#   rhelrepo   AlmaLinux / Oracle Linux 等：get-docker.sh 只認 centos/rhel/rocky/fedora，
#              其他 RHEL 系會被拒絕，改用 Docker 文件給 RHEL 相容版的做法（centos repo）
docker_route() {
    if [ "$PKG" = apk ]; then echo apk; return; fi
    case "$OS_ID" in
        centos|rhel|rocky|fedora|ubuntu|debian|raspbian) echo getdocker ;;
        *) if [ "$OS_FAMILY" = rhel ] && { [ "$PKG" = dnf ] || [ "$PKG" = yum ]; }; then
               echo rhelrepo
           else
               # 其他 Debian 衍生版 get-docker.sh 會自己用 lsb_release / debian_version 對回上游
               echo getdocker
           fi ;;
    esac
}

# get-docker.sh 會把這些版本標成 EOL，印一段警告後 sleep 10 秒再繼續。
# 不先講的話，畫面停住十秒會以為當掉了。
docker_eol() {
    case "$OS_ID.$OS_MAJOR" in
        centos.7|centos.8|rhel.7) return 0 ;;
        debian.9|debian.10|debian.11) return 0 ;;
    esac
    case "$OS_ID.$OS_VER" in
        ubuntu.16.04|ubuntu.18.04|ubuntu.20.04) return 0 ;;
    esac
    return 1
}

# 印出 docker 這一項的說明（計畫階段用）
plan_docker() {
    DOCKER_HOW=$(docker_route)
    info "${CB}docker${C0}"
    case "$DOCKER_HOW" in
        getdocker)
            _args=''
            [ -n "$DOCKER_MIRROR" ] && _args=" --mirror $DOCKER_MIRROR"
            info "  下載 ${CB}$DOCKER_URL${C0} 成 get-docker.sh，驗過內容後執行 ${CB}sh get-docker.sh$_args${C0}"
            info "  ${CD}Docker 官方腳本，會以 root 新增 docker-ce 套件來源並安裝 docker-ce / cli / containerd / compose 外掛${C0}"
            info "  ${CD}裝完它會自己 systemctl enable --now docker（開機啟動 + 立刻啟動）${C0}"
            docker_eol && \
                warn "  $OS_PRETTY 已 EOL，get-docker.sh 會印 DEPRECATION WARNING 並停 10 秒才繼續，不是當掉" ;;
        apk)
            info "  get-docker.sh 不支援 Alpine，改用：${CB}$PKG_INSTALL docker docker-cli-compose${C0}"
            info "  ${CD}不會自動啟動；要用請：rc-update add docker default && rc-service docker start${C0}" ;;
        rhelrepo)
            info "  get-docker.sh 不認得 $OS_ID（只認 centos / rhel / rocky / fedora），改走 Docker 文件的 RHEL 相容做法："
            if [ "$PKG" = dnf ]; then _cm='dnf config-manager'; else _cm='yum-config-manager'; fi
            info "  ${CB}$_cm --add-repo https://download.docker.com/linux/centos/docker-ce.repo${C0}"
            info "  ${CB}$PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin${C0}"
            info "  ${CD}不會自動啟動；要用請：systemctl enable --now docker${C0}" ;;
    esac

    # RHEL 8+ 預設有 podman / buildah，它們帶的 runc 跟 containerd.io 衝突，dnf 會整個失敗
    if [ "$OS_FAMILY" = rhel ] && has rpm; then
        _conf=$(rpm -q podman buildah runc 2>/dev/null | grep -v 'not installed' | tr '\n' ' ')
        [ -n "$_conf" ] && {
            warn "  已裝 $_conf—— 跟 containerd.io 衝突時安裝會失敗"
            info "  ${CD}確定不用 podman 的話先移除：$PKG remove -y podman buildah runc${C0}"
        }
    fi
    [ -n "$CONTAINER" ] && \
        warn "  這是容器環境（$CONTAINER）：容器裡再裝 docker 需要 privileged，通常不是你要的"
    # 這條是最常見、也最傷的誤會，一定要在裝之前講
    warn "  docker 發佈的埠（-p）會繞過 firewalld / ufw 的規則（它自己寫 iptables 的 DOCKER 鏈）"
    info "  ${CD}只想給本機用的服務請綁 127.0.0.1：-p 127.0.0.1:8080:80${C0}"
}

plan_nginx() {
    info "${CB}nginx${C0}  套件 nginx"
    case "$PKG" in
        apt)
            warn "  Debian / Ubuntu 裝完會${CB}立刻啟動${C0}並監聽 80 埠（套件的 postinst 做的，不是本腳本）"
            _p80=$(port80_owner)
            if [ -n "$_p80" ]; then
                err "  80 埠已經有人在聽 —— nginx 會啟動失敗，dpkg 會把套件留在半裝狀態："
                info "  ${CD}$_p80${C0}"
                info "  ${CD}先把那個服務停掉，或裝完改 /etc/nginx/sites-enabled/default 的 listen 再 dpkg --configure -a${C0}"
            fi ;;
        *)
            info "  ${CD}裝完不會自動啟動；要用請：$(svc_hint nginx)${C0}" ;;
    esac
    info "  ${CD}防火牆不會幫你開 80 / 443，要對外請自己放行${C0}"
}

svc_hint() {
    case "$INIT" in
        systemd) printf 'systemctl enable --now %s' "$1" ;;
        openrc)  printf 'rc-update add %s default && rc-service %s start' "$1" "$1" ;;
        *)       printf 'service %s start' "$1" ;;
    esac
}

plan_tcpping() {
    _pre=$(pkg_of tcpping)
    info "${CB}tcpping${C0}  前置套件 $_pre + 下載腳本"
    info "  ${CB}$TCPPING_URL${C0}"
    info "  -> ${CB}$TCPPING_DEST${C0}（$TCPPING_VER，GPL，第三方：deajan/tcpping）"
    info "  ${CD}它是呼叫 traceroute -T 送 TCP SYN 量延遲，要 root 才送得出去${C0}"
}

# 下載 tcpping，驗過內容才放到定位。先落 .part 再 mv，中斷不會留下半截檔。
install_tcpping() {
    if [ "$DRY" = 1 ]; then
        printf '   %s[乾跑]%s 下載 %s -> %s\n' "$CD" "$C0" "$TCPPING_URL" "$TCPPING_DEST"
        return 0
    fi
    info "下載 $TCPPING_URL"
    _tmp="$TCPPING_DEST.part"
    mkdir -p "$(dirname "$TCPPING_DEST")" 2>/dev/null
    if ! fetch "$TCPPING_URL" "$_tmp" || [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        err "tcpping 下載失敗（連不到 raw.githubusercontent.com？內網請設 OPS_TCPPING_URL）"
        return 1
    fi
    # 被 captive portal / 代理攔截時拿到的會是 HTML；還要確認真的是 tcpping 而不是別的腳本
    if [ "$(head -c 2 "$_tmp" 2>/dev/null)" != '#!' ] || ! grep -q '^ver="' "$_tmp"; then
        rm -f "$_tmp"
        err "下載到的內容不是 tcpping 腳本，可能被代理或入口網頁攔截"
        return 1
    fi
    chmod 755 "$_tmp" && mv -f "$_tmp" "$TCPPING_DEST" || {
        rm -f "$_tmp"; err "無法寫入 $TCPPING_DEST"; return 1; }
    return 0
}

install_docker() {
    case "$DOCKER_HOW" in
        apk)
            run $PKG_INSTALL docker docker-cli-compose ;;
        rhelrepo)
            if [ "$PKG" = dnf ]; then
                run dnf install -y dnf-plugins-core
                run dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            else
                run yum install -y yum-utils
                run yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            fi
            run $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
        getdocker)
            # 照使用者給的做法：先 curl -o get-docker.sh，再 sh ./get-docker.sh。
            # 落地成檔案而不是 curl | sh：下載一半斷掉時 sh 不會執行到半截的內容，
            # 也才有機會先檢查內容。放在用完就刪的暫存目錄，這支腳本不需要留著。
            _mirror=''
            [ -n "$DOCKER_MIRROR" ] && _mirror="--mirror $DOCKER_MIRROR"
            if [ "$DRY" = 1 ]; then
                printf '   %s[乾跑]%s curl -fsSL %s -o get-docker.sh\n' "$CD" "$C0" "$DOCKER_URL"
                printf '   %s[乾跑]%s sh ./get-docker.sh%s\n' "$CD" "$C0" "${_mirror:+ $_mirror}"
                return 0
            fi
            _dir=$(mktemp -d 2>/dev/null || echo "/tmp/ops-docker.$$")
            mkdir -p "$_dir" && chmod 700 "$_dir"
            info "執行：curl -fsSL $DOCKER_URL -o get-docker.sh"
            if ! fetch "$DOCKER_URL" "$_dir/get-docker.sh" || [ ! -s "$_dir/get-docker.sh" ]; then
                rm -rf "$_dir"
                err "get-docker.sh 下載失敗（連不到 get.docker.com？內網請設 OPS_DOCKER_URL）"
                return 1
            fi
            if [ "$(head -c 2 "$_dir/get-docker.sh")" != '#!' ] || ! grep -q 'do_install' "$_dir/get-docker.sh"; then
                rm -rf "$_dir"
                err "下載到的內容不是 docker 安裝腳本，可能被代理或入口網頁攔截"
                return 1
            fi
            info "執行：sh ./get-docker.sh${_mirror:+ $_mirror}"
            # shellcheck disable=SC2086
            ( cd "$_dir" && sh ./get-docker.sh $_mirror )
            _rc=$?
            rm -rf "$_dir"
            return $_rc ;;
    esac
}

cmd_install() {
    [ $# -ge 1 ] || die "要指定項目：$SELF install <docker|nc|tcpping|mtr|nginx|all>"
    need_root

    # ---- 整理清單：展開 all、擋掉打錯的、略過已經裝好的 ----
    _want=''
    for _a in "$@"; do
        if [ "$_a" = all ]; then _want="$_want $ALL_APPS"; continue; fi
        is_app "$_a" || die "不認得的項目：$_a（可用：$ALL_APPS all）"
        _want="$_want $_a"
    done
    _todo=''
    for _a in $ALL_APPS; do                      # 用固定順序走一遍，順便去重
        case " $_want " in *" $_a "*) : ;; *) continue ;; esac
        if installed "$_a"; then
            _v=$(ver_of "$_a")
            ok "$_a 已安裝${_v:+（$_v）}，略過"
        else
            _todo="$_todo $_a"
        fi
    done
    _todo="${_todo# }"
    [ -n "$_todo" ] || { ok "要裝的都已經在了"; return 0; }

    # ---- 組出套件管理器要裝的東西 ----
    _pkgs=''
    for _a in $_todo; do
        [ "$_a" = docker ] && continue
        _p=$(pkg_of "$_a")
        if [ -z "$_p" ]; then
            die "$_a 在 $PKG 上沒有對應的套件名，請自行安裝"
        fi
        _pkgs="$_pkgs $_p"
    done
    _pkgs="${_pkgs# }"
    if [ -n "$_pkgs" ] && [ "$PKG" = none ]; then
        die "找不到套件管理器（apt / dnf / yum / apk / zypper / pacman），請自行安裝：$_pkgs"
    fi
    _epel=0
    case " $_todo " in *' nginx '*) need_epel && _epel=1 ;; esac

    case " $_todo " in
        *' tcpping '*|*' docker '*)
            has curl || has wget || die "docker / tcpping 要從網路下載，需要 curl 或 wget：$PKG_INSTALL curl" ;;
    esac

    # ---- 攤開計畫 ----
    step "安裝常用軟體：$_todo"
    info "系統：$OS_PRETTY（family=$OS_FAMILY，pkg=$PKG）"
    plain ""
    if [ -n "$_pkgs" ]; then
        info "套件管理器："
        [ "$PKG" = apt ]    && info "  ${CB}apt-get update${C0}"
        [ "$PKG" = pacman ] && info "  ${CD}（pacman 不先 -Sy：只同步不升級是 Arch 明講不支援的「部分升級」）${C0}"
        [ "$_epel" = 1 ]    && info "  ${CB}$PKG_INSTALL epel-release${C0}  ${CD}（CentOS/RHEL 7 的 nginx 在 EPEL）${C0}"
        info "  ${CB}$PKG_INSTALL $_pkgs${C0}"
        plain ""
    fi
    for _a in $_todo; do
        case "$_a" in
            docker)  plan_docker; plain "" ;;
            nginx)   plan_nginx; plain "" ;;
            tcpping) plan_tcpping; plain "" ;;
        esac
    done

    confirm "要開始安裝嗎？" || exit 1
    plain ""

    # ---- 執行 ----
    _fail=''
    if [ -n "$_pkgs" ]; then
        [ "$PKG" = apt ] && { run apt-get update || [ "$DRY" = 1 ] || warn "apt-get update 失敗，照樣試著安裝"; }
        [ "$_epel" = 1 ] && { run $PKG_INSTALL epel-release || [ "$DRY" = 1 ] || warn "epel-release 裝不起來，nginx 可能會找不到"; }
        # shellcheck disable=SC2086
        run $PKG_INSTALL $_pkgs || [ "$DRY" = 1 ] || warn "套件管理器回報失敗，下面逐項確認實際裝上了哪些"
    fi
    case " $_todo " in
        *' tcpping '*) install_tcpping || _fail="$_fail tcpping" ;;
    esac
    case " $_todo " in
        *' docker '*)
            plain ""
            install_docker || { [ "$DRY" = 1 ] || _fail="$_fail docker"; } ;;
    esac

    [ "$DRY" = 1 ] && { plain ""; info "乾跑結束，沒有動到任何東西"; return 0; }

    # ---- 驗證：以「指令真的在」為準，不看套件管理器的回傳碼 ----
    plain ""
    step "驗證"
    hash -r 2>/dev/null || true
    for _a in $_todo; do
        if installed "$_a"; then
            _v=$(ver_of "$_a")
            ok "$_a${_v:+  $_v}"
        else
            err "$_a 沒有裝上"
            case " $_fail " in *" $_a "*) : ;; *) _fail="$_fail $_a" ;; esac
        fi
    done

    # 服務現況只講事實，要不要開機啟動留給使用者
    for _a in docker nginx; do
        case " $_todo " in *" $_a "*) : ;; *) continue ;; esac
        installed "$_a" || continue
        [ "$INIT" = sysv ] && continue
        info "$_a 服務：$(svc_state "$_a")"
        case "$(svc_state "$_a")" in
            active*) : ;;
            *) info "  ${CD}要啟動：$(svc_hint "$_a")${C0}" ;;
        esac
    done
    case " $_todo " in
        *' docker '*)
            installed docker && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && \
                info "要讓 $SUDO_USER 免 sudo 用 docker：usermod -aG docker $SUDO_USER ${CD}（等同給 root 權限）${C0}" ;;
    esac

    plain ""
    if [ -n "$_fail" ]; then
        err "沒有裝上：${_fail# }（原因見上方輸出）"
        exit 1
    fi
    ok "全部完成"
}

# =========================================================
# 進入點
# =========================================================
usage() {
    cat <<EOF
apps.sh — 常用軟體安裝  v$APPS_SH_VER

用法
    $SELF status                   五項軟體的安裝狀態與版本
    $SELF install <名稱...>         安裝指定項目，例：install nc mtr
    $SELF install all              還沒裝的全部裝

名稱
    docker    官方 get.docker.com 腳本（Alpine 改用 apk、AlmaLinux 等改用 docker-ce repo）
    nc        netcat（RHEL 系 nmap-ncat，Debian / Alpine 系 netcat-openbsd）
    tcpping   traceroute + deajan/tcpping $TCPPING_VER（裝到 $TCPPING_DEST）
    mtr       mtr（Debian 系 mtr-tiny）
    nginx     nginx（CentOS/RHEL 7 會先裝 epel-release）

選項
    -y    免確認
    -n    乾跑，只印出會做什麼

環境變數
    OPS_DOCKER_URL     docker 安裝腳本的網址，目前：$DOCKER_URL
    OPS_DOCKER_MIRROR  交給 get-docker.sh 的 --mirror（Aliyun / AzureChinaCloud）
    OPS_TCPPING_URL    tcpping 腳本的網址（內網鏡像用）
    OPS_SSH_DIR        操作記錄的位置（$LOGFILE）
    NO_COLOR           關閉顏色
EOF
    exit 0
}

detect_env

ARGS=''
CMD=''
for _a in "$@"; do
    case "$_a" in
        -y|--yes)     YES=1 ;;
        -n|--dry-run) DRY=1 ;;
        -h|--help|help) usage ;;
        *) if [ -z "$CMD" ]; then CMD="$_a"; else ARGS="$ARGS $_a"; fi ;;
    esac
done
# shellcheck disable=SC2086
set -- $ARGS

[ "$DRY" = 1 ] && info "${CD}乾跑模式：只印出會做什麼，不會真的改${C0}"

case "${CMD:-status}" in
    status|st)  cmd_status "$@" ;;
    install|i)  cmd_install "$@" ;;
    *) err "未知的指令：$CMD"; plain ""; usage ;;
esac
