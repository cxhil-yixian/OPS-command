#!/bin/sh
# time-set.sh — 系統時區與時間設定
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 用法：
#   ./time-set.sh status                  時區 / 系統時間 / 硬體時鐘 / 校時服務
#   ./time-set.sh list [關鍵字]           列出時區（不給關鍵字只列常用的）
#   ./time-set.sh list all                列出全部（六百多筆）
#   ./time-set.sh set-zone <時區>         設定時區，例：Asia/Taipei
#   ./time-set.sh set-time <時間>         手動設定系統時間
#   ./time-set.sh sync [伺服器]           立刻校時一次（不改變服務的開機狀態）
#   ./time-set.sh ntp on|off              啟用 / 停用自動校時
#   ./time-set.sh rtc                     把目前系統時間寫回硬體時鐘
#   ./time-set.sh doctor                  環境檢查（含「改了會被拉回去」的情況）
#   ./time-set.sh install                 安裝 chrony / tzdata
#
#   時間格式：'2026-08-19 15:30:00'、'2026-08-19 15:30'、'2026-08-19'
#             '15:30:00'（今天）、@1755590000（epoch）
#   共用選項：-y 免確認、-n 乾跑
#
# 設計原則：
#   1. 改之前先把「差多少、往哪個方向、會影響什麼」印出來再問。往回撥跟往前撥的
#      後果不一樣（往回撥 cron 會重跑已經跑過的工作），所以方向要分開講。
#   2. 不順手啟動或關閉校時服務。手動設定時間時如果 chronyd 正在跑，設完兩分鐘內
#      就會被拉回去 —— 這時停下來問，不自己決定；-y 免確認模式一律拒絕，
#      要先明確執行 ntp off。（同 STRESS/stress-test.sh 對 chronyd 的態度。）
#   3. 每一步都驗證結果。date -s 各家實作吃的格式不同，設完一定回讀比對，
#      對不上就換一種格式重試，再不行就明講失敗，不留下「看起來成功」的假象。
#   4. 容器裡沒有 CAP_SYS_TIME、VM 的主機時間同步會把時鐘拉回去 —— 這兩件事
#      在動手之前就先檢查出來講，不要等使用者發現時間又跳回去才查半天。
#
# 以 POSIX sh 撰寫，Alpine 不需額外安裝 bash。

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# os-release 會設 VERSION，所以本腳本自己的版本號不能叫 VERSION（會被 detect_env 蓋掉）
TIME_SH_VER=1.0
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

ZONEINFO=/usr/share/zoneinfo

# 產出檔案跟其他工具收在一起（見 ../SSH/README.md 的「檔案位置」）
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
LOGFILE="$OPS_SSH_DIR/time-ops.log"

# sync 時預設問哪台。內網機器連不到 pool.ntp.org，設 OPS_NTP_SERVER 或用參數指定。
NTP_SERVER="${OPS_NTP_SERVER:-pool.ntp.org}"

DRY=0
YES=0

# ---------- 輸出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    CR=$(printf '\033[31m'); CG=$(printf '\033[32m'); CY=$(printf '\033[33m')
    CB=$(printf '\033[1m');  CD=$(printf '\033[2m');  C0=$(printf '\033[0m')
else
    CR=''; CG=''; CY=''; CB=''; CD=''; C0=''
fi

# 改時鐘是會被追究的動作，留下稽核記錄。
# 記錄一律同時寫「動作前」與「動作後」的時間 —— 改完時鐘之後，日誌自己的時間戳
# 也跟著跳，只記一個時間點的話事後根本分不出哪一行在前哪一行在後。
#
# 乾跑的每一行都標 [乾跑]：畫面上有「乾跑模式」那句提示，但日誌是一行一行往下接的，
# 沒有標記的話事後翻起來，「執行：停用並關閉 chronyd」看起來就跟真的做過一模一樣。
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

# 去掉前導 0 再交給算術／printf。POSIX printf 的 %d 會把 "08" 當八進位而報錯，
# 使用者打 2026-08-19 是完全正常的寫法，不能在這裡炸掉。
num() {
    _n=$(printf '%s' "$1" | sed 's/^0*//')
    [ -z "$_n" ] && _n=0
    printf '%s' "$_n"
}

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
    "$@"
}

# =========================================================
# 環境偵測
# =========================================================
detect_env() {
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

    # timedatectl「存在」不等於「能用」：容器裡連不到 systemd 的 bus 時它會卡住
    # 或直接失敗，那種情況要退回改檔案的做法。所以這裡實際打一次才算數。
    #
    # 探測用 status 而不是 show：CentOS 7 的 systemd 219 根本沒有 show 這個子命令
    # （「Unknown operation show」），但 set-timezone / set-time / set-ntp 都在。
    # 拿 show 當探測會把整個 RHEL 7 誤判成「不能用 timedatectl」而退回手改檔案，
    # 那條路徑不會處理 RTC、也不會擋「NTP 開著不准設時間」。
    TDC=0        # 能不能用 timedatectl 做「設定」
    TDC_SHOW=0   # 能不能用 timedatectl show 查屬性（systemd 230 之後才有）
    if [ "$INIT" = systemd ] && has timedatectl; then
        timedatectl status >/dev/null 2>&1 && TDC=1
        timedatectl show -p Timezone >/dev/null 2>&1 && TDC_SHOW=1
    fi

    detect_virt
    detect_container
}

# 查 timedatectl 的屬性，統一用 show 的命名與值域（Timezone / LocalRTC=0|1 /
# NTP=yes|no / NTPSynchronized=yes|no）。
#
# 舊 systemd 沒有 show，只能退回解析 status —— 那個輸出會跟著 locale 翻譯，
# 所以強制 LC_ALL=C 才拿得到固定的英文標籤。新舊版的標籤又不一樣
# （219 是 "NTP synchronized"，新版是 "System clock synchronized"），兩種都比對。
tdc_get() {
    [ "$TDC" = 1 ] || return 1

    if [ "$TDC_SHOW" = 1 ]; then
        _v=$(timedatectl show -p "$1" 2>/dev/null | sed -n "s/^$1=//p")
        [ -n "$_v" ] || return 1
        printf '%s\n' "$_v"
        return 0
    fi

    _st=$(LC_ALL=C timedatectl status 2>/dev/null)
    [ -n "$_st" ] || return 1
    case "$1" in
        Timezone)
            # "Time zone: Asia/Taipei (CST, +0800)" -> Asia/Taipei
            _v=$(printf '%s\n' "$_st" | sed -n 's/^[[:space:]]*Time zone:[[:space:]]*//p' | awk '{print $1}') ;;
        LocalRTC)
            _v=$(printf '%s\n' "$_st" | sed -n 's/^[[:space:]]*RTC in local TZ:[[:space:]]*//p')
            case "$_v" in yes) _v=1 ;; no) _v=0 ;; *) _v='' ;; esac ;;
        NTP)
            _v=$(printf '%s\n' "$_st" | sed -n -e 's/^[[:space:]]*NTP enabled:[[:space:]]*//p' \
                                               -e 's/^[[:space:]]*NTP service:[[:space:]]*//p')
            case "$_v" in active) _v=yes ;; inactive) _v=no ;; esac ;;
        NTPSynchronized)
            _v=$(printf '%s\n' "$_st" | sed -n -e 's/^[[:space:]]*NTP synchronized:[[:space:]]*//p' \
                                               -e 's/^[[:space:]]*System clock synchronized:[[:space:]]*//p') ;;
        *) _v='' ;;
    esac
    [ -n "$_v" ] || return 1
    printf '%s\n' "$_v"
}

# 虛擬化平台：VM 的主機時間同步會把手動設定的時間拉回去，這是「改完又跳回去」
# 最常見的原因，要在動手前就講。
detect_virt() {
    VIRT=''
    if has systemd-detect-virt; then
        VIRT=$(systemd-detect-virt 2>/dev/null)
        [ "$VIRT" = none ] && VIRT=''
    fi
    if [ -z "$VIRT" ] && [ -r /sys/class/dmi/id/sys_vendor ]; then
        case "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" in
            *Microsoft*) VIRT=microsoft ;;
            *VMware*)    VIRT=vmware ;;
            *QEMU*|*Bochs*) VIRT=kvm ;;
            *Xen*)       VIRT=xen ;;
            *innotek*|*Oracle*) VIRT=oracle ;;
        esac
    fi
}

# 容器：沒有 CAP_SYS_TIME 就改不動時鐘，而且時鐘是跟主機共用的（namespace 沒有
# 隔離時間），就算改成功也是改到整台主機。兩種都要擋。
detect_container() {
    CONTAINER=''
    if has systemd-detect-virt; then
        _c=$(systemd-detect-virt -c 2>/dev/null)
        [ -n "$_c" ] && [ "$_c" != none ] && CONTAINER="$_c"
    fi
    if [ -z "$CONTAINER" ]; then
        if   [ -f /.dockerenv ];       then CONTAINER=docker
        elif [ -f /run/.containerenv ]; then CONTAINER=podman
        elif grep -qE '(docker|lxc|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then CONTAINER=container
        fi
    fi

    # CAP_SYS_TIME 是 bit 25。root 在容器裡通常被拿掉這一個能力，
    # 沒有它 date -s 會回 "Operation not permitted"。
    CAP_TIME=unknown
    _eff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null | head -1)
    case "$_eff" in
        ''|*[!0-9a-fA-F]*) : ;;                      # 讀不到或不是十六進位，維持 unknown
        *) # 只取後 8 個字元（低 32 位，CAP_SYS_TIME 在其中），避免超過整數上限
           _low=$(printf '%s' "$_eff" | sed 's/.*\(........\)$/\1/')
           if [ "$(( 0x$_low & 0x2000000 ))" != 0 ]; then CAP_TIME=yes; else CAP_TIME=no; fi ;;
    esac
}

# =========================================================
# 服務控制
#   校時服務的名字每家都不一樣（chronyd / chrony / ntpd / ntp / systemd-timesyncd /
#   busybox ntpd），先探測實際存在的那一個，之後所有操作都對它。
# =========================================================
svc_active() {
    case "$INIT" in
        systemd) systemctl is-active "$1" >/dev/null 2>&1 ;;
        openrc)  rc-service "$1" status >/dev/null 2>&1 ;;
        *)       service "$1" status >/dev/null 2>&1 ;;
    esac
}

svc_enabled() {
    case "$INIT" in
        systemd) systemctl is-enabled "$1" >/dev/null 2>&1 ;;
        openrc)  rc-update show 2>/dev/null | grep -q "^ *$1 " ;;
        *)       has chkconfig && chkconfig "$1" 2>/dev/null ;;
    esac
}

svc_do() {   # $1 = start|stop|enable|disable  $2 = 服務名
    case "$INIT" in
        systemd) run systemctl "$1" "$2" ;;
        openrc)
            case "$1" in
                start|stop) run rc-service "$2" "$1" ;;
                enable)     run rc-update add "$2" default ;;
                disable)    run rc-update del "$2" default ;;
            esac ;;
        *)
            case "$1" in
                start|stop) run service "$2" "$1" ;;
                enable)     has chkconfig && run chkconfig "$2" on ;;
                disable)    has chkconfig && run chkconfig "$2" off ;;
            esac ;;
    esac
}

# 開機啟動的開關。它失敗不影響「當下有沒有在跑」，所以正常模式吞掉輸出；
# 但乾跑時要看得到會下什麼指令，不然清單會少一行。
svc_do_boot() {
    if [ "$DRY" = 1 ]; then
        svc_do "$1" "$2"
    else
        svc_do "$1" "$2" >/dev/null 2>&1
    fi
}

# 找出這台機器上的校時服務。
#   NTP_SVC   服務名（空 = 沒裝）
#   NTP_KIND  chrony / ntpd / timesyncd / busybox
#   NTP_STATE active / inactive
#   NTP_BOOT  enabled / disabled
ntp_detect() {
    NTP_SVC=''; NTP_KIND=''; NTP_STATE=inactive; NTP_BOOT=disabled

    # 順序有意義：同一台裝了兩套時，正在跑的那個才是實際在管時鐘的。
    for _cand in 'chronyd chrony' 'chrony chrony' 'ntpd ntpd' 'ntp ntpd' \
                 'systemd-timesyncd timesyncd' 'openntpd ntpd' 'busybox-ntpd busybox'; do
        _s=${_cand%% *}; _k=${_cand##* }
        case "$INIT" in
            systemd) systemctl cat "$_s.service" >/dev/null 2>&1 || continue ;;
            openrc)  [ -f "/etc/init.d/$_s" ] || continue ;;
            *)       [ -f "/etc/init.d/$_s" ] || continue ;;
        esac
        if svc_active "$_s"; then
            NTP_SVC="$_s"; NTP_KIND="$_k"; NTP_STATE=active
            svc_enabled "$_s" && NTP_BOOT=enabled
            return 0
        fi
        # 沒在跑的先記著，繼續看有沒有正在跑的
        [ -z "$NTP_SVC" ] && { NTP_SVC="$_s"; NTP_KIND="$_k"; }
    done
    [ -n "$NTP_SVC" ] && { svc_enabled "$NTP_SVC" && NTP_BOOT=enabled; }
    return 0
}

# chrony 的偏差資訊。回傳字串，取不到就空的。
# 注意 chronyc tracking 的 "System time" 那行才是「系統時鐘偏離正確時間多少」，
# Last offset 是上一次修正量，兩者常被搞混。
chrony_offset() {
    has chronyc || return 1
    chronyc tracking 2>/dev/null | sed -n 's/^System time *: *//p' | head -1
}

# =========================================================
# 時區
# =========================================================
# 目前時區。來源依可信度排序：
#   1. /etc/localtime 的 symlink 目標 —— 這是 libc 真正在用的東西，date、所有程式
#      看到的時間都由它決定
#   2. timedatectl（systemd 自己認定的值）
#   3. /etc/timezone（Debian / Alpine 的純文字檔）
#   4. /etc/sysconfig/clock 的 ZONE=（RHEL 6/7 的舊寫法）
# 都拿不到就退回 date +%Z 的縮寫（CST 這種，不是時區名，但至少看得出來）。
#
# timedatectl 刻意排在 symlink 後面：實測 CentOS 7 直接換掉 /etc/localtime 之後，
# date 立刻是新時區，但 timedatectl 在那之後一小段時間仍回舊值（systemd-timedated
# 快取著，daemon-reexec 也不會讓它更新，要等它閒置退出）。這種時候要以「程式實際
# 看到的」為準，不然狀態畫面會跟現實對不上。兩邊不一致由 doctor 專門指出來。
tz_current() {
    if [ -L /etc/localtime ]; then
        _tz=$(readlink -f /etc/localtime 2>/dev/null)
        _tz=${_tz#"$ZONEINFO"/}
        _tz=${_tz#posix/}
        case "$_tz" in
            /*|'') _tz='' ;;
        esac
        [ -n "$_tz" ] && { printf '%s\n' "$_tz"; return 0; }
    fi

    _tz=$(tdc_get Timezone 2>/dev/null) && { printf '%s\n' "$_tz"; return 0; }

    if [ -r /etc/timezone ]; then
        _tz=$(sed -n '1s/[[:space:]]//gp' /etc/timezone 2>/dev/null)
        [ -n "$_tz" ] && { printf '%s\n' "$_tz"; return 0; }
    fi

    if [ -r /etc/sysconfig/clock ]; then
        _tz=$(sed -n 's/^[[:space:]]*ZONE="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' /etc/sysconfig/clock 2>/dev/null | head -1)
        [ -n "$_tz" ] && { printf '%s\n' "$_tz"; return 0; }
    fi

    # /etc/localtime 是複製過去的檔案（Alpine 的做法）時，比對檔案內容找回名字。
    # 找不到也沒關係，這只是顯示用。
    if [ -f /etc/localtime ] && [ -d "$ZONEINFO" ] && has cmp; then
        for _c in Asia/Taipei Asia/Shanghai Asia/Hong_Kong Asia/Tokyo UTC; do
            [ -f "$ZONEINFO/$_c" ] || continue
            cmp -s /etc/localtime "$ZONEINFO/$_c" && { printf '%s\n' "$_c"; return 0; }
        done
    fi

    printf '%s\n' "$(date +%Z 2>/dev/null || echo unknown)"
}

# 時區名合法性。這個值會被接到路徑後面，所以「檔案存在」之外還要擋掉
# 絕對路徑與 ..，不然 set-zone ../../etc/shadow 會被接受。
tz_valid() {
    case "$1" in
        ''|/*|*..*|*' '*) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9/_+-]*) return 1 ;;
    esac
    [ -f "$ZONEINFO/$1" ]
}

# 列出所有時區名
tz_all() {
    if [ "$TDC" = 1 ]; then
        timedatectl list-timezones --no-pager 2>/dev/null && return 0
    fi
    [ -d "$ZONEINFO" ] || return 1
    # right/ 與 posix/ 是同一份資料的另外兩種編法，列出來只會讓清單變三倍長；
    # *.tab / leapseconds / tzdata.zi 是資料檔不是時區。
    find "$ZONEINFO" -type f 2>/dev/null |
        sed "s|^$ZONEINFO/||" |
        grep -vE '^(posix|right)/' |
        grep -vE '(\.tab|\.list|\.zi)$' |
        grep -vE '^(leapseconds|localtime|posixrules|Factory)$' |
        sort
}

# 常用時區。台灣 / 中國 / 東南亞放前面，其他只留最常見的幾個。
TZ_COMMON='Asia/Taipei Asia/Shanghai Asia/Hong_Kong Asia/Macau Asia/Tokyo Asia/Seoul
Asia/Singapore Asia/Kuala_Lumpur Asia/Bangkok Asia/Ho_Chi_Minh Asia/Manila Asia/Jakarta
Asia/Kolkata Asia/Dubai Australia/Sydney Europe/London Europe/Paris Europe/Berlin
America/New_York America/Chicago America/Los_Angeles America/Sao_Paulo UTC'

# 印一行時區：名稱 + 目前偏移 + 當地時間，選之前看得到「現在那邊幾點」
tz_row() {
    _t=$1
    if [ -f "$ZONEINFO/$_t" ]; then
        _now=$(TZ="$_t" date '+%z  %m-%d %H:%M' 2>/dev/null)
    else
        _now=''
    fi
    if [ "$_t" = "$CUR_TZ" ]; then
        printf '   %s%-24s%s %s  %s← 目前%s\n' "$CB" "$_t" "$C0" "$_now" "$CG" "$C0"
    else
        printf '   %-24s %s\n' "$_t" "$_now"
    fi
}

# =========================================================
# 時間解析與換算
#   date -d / date -D 各家實作差很多（GNU、busybox、BSD 都不一樣），所以
#   「使用者輸入 -> 正規化字串」全部自己做，不依賴 date 去 parse。
#   換算 epoch 也自己算，才能在設定之前就把差距講出來。
# =========================================================

# 這個月有幾天（含閏年）
days_in_month() {
    case $1 in
        1|3|5|7|8|10|12) printf '31\n' ;;
        4|6|9|11)        printf '30\n' ;;
        2) _y=$2
           if [ $((_y % 4)) = 0 ] && { [ $((_y % 100)) != 0 ] || [ $((_y % 400)) = 0 ]; }
           then printf '29\n'; else printf '28\n'; fi ;;
        *) printf '0\n' ;;
    esac
}

# 民曆 -> epoch（先當成 UTC 算，之後再扣時區偏移）
# 演算法是 Howard Hinnant 的 days_from_civil，純整數，不需要外部指令。
civil_epoch() {
    _cy=$1; _cm=$2; _cd=$3
    if [ "$_cm" -le 2 ]; then _cy=$((_cy - 1)); _mp=$((_cm + 9)); else _mp=$((_cm - 3)); fi
    _era=$((_cy / 400))
    _yoe=$((_cy - _era * 400))
    _doy=$(( (153 * _mp + 2) / 5 + _cd - 1 ))
    _doe=$(( _yoe * 365 + _yoe / 4 - _yoe / 100 + _doy ))
    _days=$(( _era * 146097 + _doe - 719468 ))
    CE_EPOCH=$(( _days * 86400 + $4 * 3600 + $5 * 60 + $6 ))
}

# 目前的 UTC 偏移量（秒）。取不到就回傳 1，呼叫端要能接受「算不出差距」。
tz_offset() {
    _z=$(date +%z 2>/dev/null)
    case "$_z" in
        [+-][0-9][0-9][0-9][0-9]) : ;;
        *) return 1 ;;
    esac
    _sign=${_z%????}
    _body=${_z#[+-]}
    _oh=$(num "${_body%??}"); _om=$(num "${_body#??}")
    TZ_OFF=$(( _oh * 3600 + _om * 60 ))
    [ "$_sign" = '-' ] && TZ_OFF=$(( 0 - TZ_OFF ))
    return 0
}

# 使用者輸入 -> PT_NORM（YYYY-MM-DD HH:MM:SS）
# 接受：完整日期時間 / 只有日期 / 只有時間（當成今天）/ @epoch
parse_time() {
    _in=$1
    PT_NORM=''

    case "$_in" in
        @*)
            _e=${_in#@}
            case "$_e" in ''|*[!0-9]*) err "epoch 要是純數字：$_in"; return 1 ;; esac
            # epoch -> 日期只能靠 date，GNU 用 -d @N，busybox 用 -d N -D %s
            PT_NORM=$(date -d "@$_e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
            [ -z "$PT_NORM" ] && PT_NORM=$(date -D %s -d "$_e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
            if [ -z "$PT_NORM" ]; then
                err "這台的 date 無法把 epoch 轉成日期，請改用 'YYYY-MM-DD HH:MM:SS' 格式"
                return 1
            fi
            return 0 ;;
    esac

    _d=''; _t=''
    case "$_in" in
        *' '*) _d=${_in%% *}; _t=${_in#* } ;;
        *T*)   _d=${_in%%T*}; _t=${_in#*T} ;;   # 順手吃 ISO 8601 的 2026-08-19T15:30:00
        *:*)   _t=$_in ;;
        *-*)   _d=$_in ;;
        *)     err "看不懂的時間格式：$_in"
               info "可用：'2026-08-19 15:30:00'、'2026-08-19'、'15:30'、@1755590000"
               return 1 ;;
    esac
    _t=${_t%Z}                       # ISO 的結尾 Z 就這樣吃掉：後面一律當本地時間處理
    [ -z "$_d" ] && _d=$(date '+%Y-%m-%d')
    [ -z "$_t" ] && _t='00:00:00'

    # ---- 日期 ----
    case "$_d" in
        *-*-*) : ;;
        *) err "日期要是 YYYY-MM-DD：$_d"; return 1 ;;
    esac
    _y=${_d%%-*}; _r=${_d#*-}; _mo=${_r%%-*}; _dd=${_r##*-}
    for _f in "$_y" "$_mo" "$_dd"; do
        case "$_f" in ''|*[!0-9]*) err "日期含非數字：$_d"; return 1 ;; esac
    done
    _y=$(num "$_y"); _mo=$(num "$_mo"); _dd=$(num "$_dd")

    # ---- 時間 ----
    _hh=${_t%%:*}; _rest=${_t#*:}
    case "$_t" in
        *:*:*) _mm=${_rest%%:*}; _ss=${_rest##*:} ;;
        *:*)   _mm=$_rest; _ss=0 ;;
        *)     err "時間要是 HH:MM 或 HH:MM:SS：$_t"; return 1 ;;
    esac
    for _f in "$_hh" "$_mm" "$_ss"; do
        case "$_f" in ''|*[!0-9]*) err "時間含非數字：$_t"; return 1 ;; esac
    done
    _hh=$(num "$_hh"); _mm=$(num "$_mm"); _ss=$(num "$_ss")

    # ---- 範圍 ----
    # 2026-02-30 這種「格式對但日子不存在」的輸入，date -s 有些實作會自己進位成
    # 3 月 2 日而且不報錯 —— 那是最難發現的一種錯，所以在這裡就擋下來。
    if [ "$_y" -lt 1970 ] || [ "$_y" -gt 2099 ]; then
        err "年份要在 1970-2099 之間：$_y"; return 1
    fi
    if [ "$_mo" -lt 1 ] || [ "$_mo" -gt 12 ]; then err "月份要在 1-12 之間：$_mo"; return 1; fi
    _dim=$(days_in_month "$_mo" "$_y")
    if [ "$_dd" -lt 1 ] || [ "$_dd" -gt "$_dim" ]; then
        err "$_y 年 $_mo 月只有 $_dim 天，沒有 $_dd 日"; return 1
    fi
    if [ "$_hh" -gt 23 ]; then err "小時要在 0-23 之間：$_hh"; return 1; fi
    if [ "$_mm" -gt 59 ]; then err "分鐘要在 0-59 之間：$_mm"; return 1; fi
    if [ "$_ss" -gt 60 ]; then err "秒要在 0-60 之間：$_ss"; return 1; fi

    PT_NORM=$(printf '%04d-%02d-%02d %02d:%02d:%02d' "$_y" "$_mo" "$_dd" "$_hh" "$_mm" "$_ss")
    PT_Y=$_y; PT_MO=$_mo; PT_DD=$_dd; PT_HH=$_hh; PT_MM=$_mm; PT_SS=$_ss
    return 0
}

# 秒數 -> 人看得懂的長度
fmt_delta() {
    _s=$1
    [ "$_s" -lt 0 ] && _s=$(( 0 - _s ))
    _dy=$(( _s / 86400 )); _s=$(( _s % 86400 ))
    _hr=$(( _s / 3600 ));  _s=$(( _s % 3600 ))
    _mi=$(( _s / 60 ));    _se=$(( _s % 60 ))
    _out=''
    [ "$_dy" -gt 0 ] && _out="$_dy 天 "
    [ "$_hr" -gt 0 ] && _out="$_out$_hr 小時 "
    [ "$_mi" -gt 0 ] && _out="$_out$_mi 分 "
    _out="$_out$_se 秒"
    printf '%s\n' "$_out"
}

# 'YYYY-MM-DD HH:MM:SS' -> CE_EPOCH（當成 UTC 算）。欄位是固定寬度，直接切。
civ_of() {
    _c=$1
    civil_epoch \
        "$(num "$(printf '%s' "$_c" | cut -c1-4)")" \
        "$(num "$(printf '%s' "$_c" | cut -c6-7)")" \
        "$(num "$(printf '%s' "$_c" | cut -c9-10)")" \
        "$(num "$(printf '%s' "$_c" | cut -c12-13)")" \
        "$(num "$(printf '%s' "$_c" | cut -c15-16)")" \
        "$(num "$(printf '%s' "$_c" | cut -c18-19)")"
}

# 設完之後回讀比對。兩邊都用「本地時間欄位」換算，時區偏移在相減時抵消，
# 所以這個比對不受時區與日光節約影響。差 120 秒內算成功（設定本身要花時間）。
verify_clock() {
    civ_of "$1";                              _want=$CE_EPOCH
    civ_of "$(date '+%Y-%m-%d %H:%M:%S')";    _got=$CE_EPOCH
    _vd=$(( _got - _want ))
    [ "$_vd" -lt 0 ] && _vd=$(( 0 - _vd ))
    [ "$_vd" -le 120 ]
}

# 真正去改時鐘。四種寫法依序試，每一種都回讀驗證 ——
# date -s 在不同實作上吃的格式不一樣，而且失敗時常常「回傳 0 但沒改到」，
# 只看 exit code 會得到「設定成功」的假象。
set_clock() {
    _tgt=$1
    # POSIX 的老格式 MMDDhhmmCCYY.ss，busybox 與 GNU 都吃
    _compact=$(printf '%02d%02d%02d%02d%04d.%02d' \
               "$PT_MO" "$PT_DD" "$PT_HH" "$PT_MM" "$PT_Y" "$PT_SS")

    if [ "$TDC" = 1 ]; then
        info "執行：timedatectl set-time '$_tgt'"
        if timedatectl set-time "$_tgt" 2>/dev/null && verify_clock "$_tgt"; then
            SET_VIA=timedatectl
            return 0
        fi
    fi

    info "執行：date -s '$_tgt'"
    if date -s "$_tgt" >/dev/null 2>&1 && verify_clock "$_tgt"; then
        SET_VIA='date -s'
        return 0
    fi

    info "改用相容格式：date -s $_compact"
    if date -s "$_compact" >/dev/null 2>&1 && verify_clock "$_tgt"; then
        SET_VIA='date -s (MMDDhhmmCCYY.ss)'
        return 0
    fi

    if date "$_compact" >/dev/null 2>&1 && verify_clock "$_tgt"; then
        SET_VIA='date MMDDhhmmCCYY.ss'
        return 0
    fi

    return 1
}

# 停用自動校時。systemd 上優先走 timedatectl set-ntp false（它會連開機啟動一起關掉），
# 關完一定回頭確認服務真的停了 —— 有些機器的 NTP unit 不在 systemd 的 ntp-units.d
# 清單裡，set-ntp 對它沒有作用，那種情況要退回直接操作服務。
ntp_off_action() {
    if [ "$TDC" = 1 ]; then
        info "執行：timedatectl set-ntp false"
        run timedatectl set-ntp false 2>/dev/null
    fi
    if [ -n "$NTP_SVC" ] && svc_active "$NTP_SVC"; then
        info "執行：停用並關閉 $NTP_SVC"
        svc_do stop "$NTP_SVC"
        svc_do_boot disable "$NTP_SVC"
    fi
    [ "$DRY" = 1 ] && return 0
    if [ -n "$NTP_SVC" ] && svc_active "$NTP_SVC"; then
        err "$NTP_SVC 停不下來"
        return 1
    fi
    ok "自動校時已停用"
    return 0
}

# =========================================================
# status
# =========================================================
# $1 = bare 時只印資料列，不印標題與分隔線。ops.sh 的時間選單自己有標頭，
# 兩層標題疊在一起很難看，所以留這個給它用（同 fail2ban.sh 的 preflight）。
cmd_status() {
    CUR_TZ=$(tz_current)
    ntp_detect

    if [ "${1:-}" != bare ]; then
        plain ""
        plain "${CB} 時間與時區${C0}"
        plain " ──────────────────────────────────────────────"
    fi
    printf '   系統時間  %s%s%s\n' "$CB" "$(date '+%Y-%m-%d %H:%M:%S %Z (%z)')" "$C0"
    printf '   UTC       %s\n' "$(TZ=UTC date '+%Y-%m-%d %H:%M:%S')"
    printf '   時區      %s%s%s\n' "$CB" "$CUR_TZ" "$C0"

    # 硬體時鐘：跟系統時間差很多的話，重開機之後時間會跳回 RTC 的值
    if has hwclock && [ "$(id -u)" = 0 ]; then
        _rtc=$(hwclock -r 2>/dev/null | head -1)
        [ -z "$_rtc" ] && _rtc="(讀不到，這台可能沒有 RTC 或在容器裡)"
        printf '   硬體時鐘  %s\n' "$_rtc"
    elif has hwclock; then
        printf '   硬體時鐘  %s\n' "(需 root 才讀得到)"
    else
        printf '   硬體時鐘  %s\n' "(無 hwclock)"
    fi

    _lrtc=$(tdc_get LocalRTC 2>/dev/null)
    if [ "${_lrtc:-0}" = 1 ] || grep -q '^LOCAL' /etc/adjtime 2>/dev/null; then
        printf '   RTC 基準  %s本地時間%s  %s(與 Windows 雙開時的設定，跨時區會算錯)%s\n' \
               "$CY" "$C0" "$CD" "$C0"
    else
        printf '   RTC 基準  UTC\n'
    fi

    # 校時服務
    if [ -z "$NTP_SVC" ]; then
        printf '   自動校時  %s沒有安裝校時服務%s  %s(時鐘沒有人在校正，會慢慢漂)%s\n' \
               "$CY" "$C0" "$CD" "$C0"
    elif [ "$NTP_STATE" = active ]; then
        printf '   自動校時  %s%s 執行中%s  (開機啟動：%s)\n' "$CG" "$NTP_SVC" "$C0" "$NTP_BOOT"
        _off=$(chrony_offset 2>/dev/null)
        [ -n "$_off" ] && printf '   時鐘偏差  %s  %s(chronyc tracking 的 System time)%s\n' \
                                 "$_off" "$CD" "$C0"
        _sync=$(tdc_get NTPSynchronized 2>/dev/null)
        [ "${_sync:-}" = no ] && printf '   %s尚未同步到來源（剛啟動或連不到伺服器）%s\n' "$CY" "$C0"
    else
        printf '   自動校時  %s%s 已安裝但沒在跑%s  (開機啟動：%s)\n' "$CY" "$NTP_SVC" "$C0" "$NTP_BOOT"
    fi

    [ -n "$CONTAINER" ] && \
        printf '   %s容器環境（%s）：時鐘跟主機共用，這裡改不動也不該改%s\n' "$CY" "$CONTAINER" "$C0"
    [ -n "$VIRT" ] && [ -z "$CONTAINER" ] && \
        printf '   虛擬化    %s  %s(主機的時間同步可能把手動設定拉回去，見 doctor)%s\n' \
               "$VIRT" "$CD" "$C0"
    [ "${1:-}" != bare ] && plain ""
    return 0
}

# =========================================================
# list
# =========================================================
cmd_list() {
    CUR_TZ=$(tz_current)
    _kw="${1:-}"

    if [ ! -d "$ZONEINFO" ]; then
        err "$ZONEINFO 不存在，這台沒有裝時區資料庫"
        info "安裝：$PKG_INSTALL tzdata   （或執行 $SELF install）"
        return 1
    fi

    if [ -z "$_kw" ]; then
        plain ""
        plain "${CB} 常用時區${C0}  ${CD}（要找其他的：list <關鍵字>，全部：list all）${C0}"
        plain " ──────────────────────────────────────────────"
        for _t in $TZ_COMMON; do tz_row "$_t"; done
        plain ""
        return 0
    fi

    if [ "$_kw" = all ]; then
        tz_all
        return 0
    fi

    _hit=$(tz_all | grep -i -- "$_kw")
    if [ -z "$_hit" ]; then
        err "找不到含「$_kw」的時區"
        info "時區名是 Asia/Taipei 這種形式，可以只打 taipei 或 asia"
        return 1
    fi
    _n=$(printf '%s\n' "$_hit" | grep -c .)
    plain ""
    plain "${CB} 符合「$_kw」的時區（$_n 筆）${C0}"
    plain " ──────────────────────────────────────────────"
    # 超過 40 筆就不逐筆算當地時間了（一筆一次 date，會明顯變慢）
    if [ "$_n" -le 40 ]; then
        for _t in $_hit; do tz_row "$_t"; done
    else
        printf '%s\n' "$_hit" | sed 's/^/   /'
        plain ""
        info "筆數太多，縮小關鍵字可以順便看到各地目前時間"
    fi
    plain ""
}

# =========================================================
# set-zone
# =========================================================
cmd_setzone() {
    _new="${1:-}"
    [ -n "$_new" ] || die "要指定時區，例：$SELF set-zone Asia/Taipei"
    need_root

    if [ ! -d "$ZONEINFO" ]; then
        err "$ZONEINFO 不存在，這台沒有裝時區資料庫"
        info "安裝：$PKG_INSTALL tzdata   （或執行 $SELF install）"
        exit 1
    fi
    if ! tz_valid "$_new"; then
        err "無效的時區：$_new"
        info "用 $SELF list <關鍵字> 找正確的名字（大小寫要一致）"
        exit 1
    fi

    CUR_TZ=$(tz_current)
    if [ "$CUR_TZ" = "$_new" ]; then
        ok "時區已經是 $_new，不用改"
        exit 0
    fi

    step "變更時區"
    info "目前  $CUR_TZ    $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    info "改成  $_new    $(TZ="$_new" date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    plain ""
    info "改時區${CB}不會改變 UTC 時刻${C0}，機器的絕對時間不動，只是換一套顯示與換算方式"
    warn "但已經在跑的服務多半還記著舊時區，要重啟才會換過來："
    info "  ${CD}cron / 排程（下一次觸發時間會照舊時區算）、資料庫、應用程式的 log 時間戳${C0}"
    plain ""

    confirm "要把時區改成 $_new 嗎？" || exit 1

    if [ "$TDC" = 1 ]; then
        info "執行：timedatectl set-timezone $_new"
        run timedatectl set-timezone "$_new"
    else
        # 沒有 timedatectl 就自己寫。symlink 先建在旁邊再 mv 過去，
        # 中途被打斷不會留下「沒有 /etc/localtime」的空窗。
        info "執行：ln -sf $ZONEINFO/$_new /etc/localtime"
        if run ln -sf "$ZONEINFO/$_new" /etc/localtime.ops-new; then
            mv -f /etc/localtime.ops-new /etc/localtime || \
                { rm -f /etc/localtime.ops-new; die "寫入 /etc/localtime 失敗"; }
        fi
        # Debian / Alpine 另外讀這個檔（Alpine 的 setup-timezone 也寫它）
        if [ "$OS_FAMILY" = debian ] || [ "$OS_FAMILY" = alpine ] || [ -f /etc/timezone ]; then
            info "寫入 /etc/timezone"
            [ "$DRY" = 1 ] || printf '%s\n' "$_new" > /etc/timezone
        fi
        # RHEL 6/7 的舊寫法，存在才更新，不主動生出這個檔
        if [ -f /etc/sysconfig/clock ]; then
            info "更新 /etc/sysconfig/clock 的 ZONE"
            [ "$DRY" = 1 ] || {
                sed -i "s|^[[:space:]]*ZONE=.*|ZONE=\"$_new\"|" /etc/sysconfig/clock 2>/dev/null || true
                grep -q '^ZONE=' /etc/sysconfig/clock 2>/dev/null || \
                    printf 'ZONE="%s"\n' "$_new" >> /etc/sysconfig/clock
            }
        fi
    fi

    [ "$DRY" = 1 ] && { info "乾跑結束，沒有動到任何東西"; exit 0; }

    # 回讀確認。tz_current 走的是跟設定完全不同的來源，這樣才驗得出來。
    _now_tz=$(tz_current)
    if [ "$_now_tz" = "$_new" ]; then
        ok "時區已改為 $_new（現在 $(date '+%Y-%m-%d %H:%M:%S %Z')）"
    else
        err "設定完讀回來還是 $_now_tz，沒有生效"
        exit 1
    fi

    # 直接改檔案時 systemd 不會馬上知道。實測 CentOS 7：ln -sf 換掉 /etc/localtime
    # 之後 date 立刻是新時區，但 timedatectl 還回舊的 —— systemd-timedated 快取著，
    # 而且 daemon-reexec 也不會讓它更新（那個重載的是 PID 1，不是它）。
    # 它閒置退出後下一次查詢才會重讀，所以這是暫時的，講清楚免得以為沒改成功。
    if [ "$TDC" != 1 ] && [ "$INIT" = systemd ]; then
        warn "這台有 systemd 但 timedatectl 用不了，時區是直接改檔案的"
        info "  date 與所有程式已經是新時區了，但 timedatectl 短時間內可能還顯示舊值"
        info "  （systemd-timedated 的快取，它閒置退出後就會跟上；已經寫出去的日誌時間戳不會回頭改）"
    fi

    # RTC 用本地時間的機器，時區一換，硬體時鐘的絕對時刻就錯了，要重寫一次
    _lrtc=$(tdc_get LocalRTC 2>/dev/null)
    if [ "${_lrtc:-0}" = 1 ] || grep -q '^LOCAL' /etc/adjtime 2>/dev/null; then
        warn "這台的 RTC 記的是本地時間，換時區之後硬體時鐘要重寫一次："
        info "  $SELF rtc"
    fi

    # 有在跑 cron 才提，沒跑就不要多印一行沒用的
    for _c in crond cron; do
        if svc_active "$_c" 2>/dev/null; then
            warn "cron（$_c）正在跑，排程時間會照舊時區算到下一次重載為止，建議重啟："
            case "$INIT" in
                systemd) info "  systemctl restart $_c" ;;
                openrc)  info "  rc-service $_c restart" ;;
                *)       info "  service $_c restart" ;;
            esac
            break
        fi
    done
}

# =========================================================
# set-time
# =========================================================
# 改時鐘的後果依方向而不同，分開講。這段是給「等一下要按 y」的人看的。
warn_time_jump() {
    _dir=$1        # back = 往回撥，fwd = 往前撥
    if [ "$_dir" = back ]; then
        warn "時鐘${CB}往回撥${C0}的風險比往前撥大："
        info "  ${CD}cron / systemd timer 會把這段時間內已經跑過的工作再跑一次${C0}"
        info "  ${CD}資料庫與 replication 的時序會亂（同一個時刻出現兩次）${C0}"
        info "  ${CD}單調遞增的 log、序號、快取到期判斷都可能出錯${C0}"
    else
        warn "時鐘${CB}往前撥${C0}會有這些後果："
        info "  ${CD}跳過去這段期間該執行的 cron 會被略過，或在跳完後一次補跑${C0}"
        info "  ${CD}session / token / sudo 的時間戳可能立刻過期，需要重新輸入密碼${C0}"
    fi
    info "  ${CD}TLS 憑證的有效期是絕對時間，差太多會變成「尚未生效」或「已過期」，連線會失敗${C0}"
    info "  ${CD}fail2ban 的封鎖到期時間、憑證更新排程都跟著算${C0}"
}

cmd_settime() {
    [ $# -ge 1 ] || die "要指定時間，例：$SELF set-time '2026-08-19 15:30:00'"
    need_root

    parse_time "$*" || exit 1
    C_TGT="$PT_NORM"

    # 動手之前先把「這台根本改不動」的兩種情況擋掉
    if [ -n "$CONTAINER" ]; then
        err "這是容器環境（$CONTAINER）"
        info "容器沒有自己的時鐘，看到的是主機的時間。要改請到主機上改。"
        exit 1
    fi
    if [ "$CAP_TIME" = no ]; then
        err "目前的執行環境沒有 CAP_SYS_TIME，改不動系統時鐘"
        info "常見於容器、受限的 systemd unit 與部分雲端映像檔"
        exit 1
    fi

    C_NOW=$(date '+%Y-%m-%d %H:%M:%S')
    C_DELTA=''
    if tz_offset; then
        civ_of "$C_TGT";  C_TE=$CE_EPOCH
        civ_of "$C_NOW";  C_NE=$CE_EPOCH
        C_DELTA=$(( C_TE - C_NE ))
    fi

    step "設定系統時間"
    info "目前  $C_NOW $(date '+%Z')"
    info "設成  $C_TGT"
    if [ -n "$C_DELTA" ]; then
        if [ "$C_DELTA" -ge 0 ]; then
            info "差距  ${CB}往前撥 $(fmt_delta "$C_DELTA")${C0}"
        else
            info "差距  ${CB}往回撥 $(fmt_delta "$C_DELTA")${C0}"
        fi
    fi
    plain ""

    if [ -n "$C_DELTA" ] && [ "$C_DELTA" -lt 0 ]; then
        warn_time_jump back
    else
        warn_time_jump fwd
    fi
    plain ""

    # 自動校時正在跑的話，設完會被拉回去。這裡停下來問，不自己決定。
    ntp_detect
    if [ "$NTP_STATE" = active ]; then
        warn "$NTP_SVC 正在跑 —— 手動設定的時間會在幾秒到幾分鐘內被它校回去"
        if [ "$DRY" = 1 ]; then
            # 乾跑不該問「要不要停掉服務」，那是真的要做才需要決定的事
            info "[乾跑] 會先停用 $NTP_SVC（含開機啟動）再設定時間"
        elif [ "$YES" = 1 ]; then
            err "-y 免確認模式不會替你停用校時服務"
            info "要手動設定時間，請先明確執行：$SELF ntp off"
            exit 1
        else
            info "接下來會停用它（含開機啟動），設定完要恢復自動校時請執行：$SELF ntp on"
            plain ""
            confirm "要停用 $NTP_SVC 並繼續設定時間嗎？" || exit 1
            ntp_off_action || exit 1
        fi
        plain ""
    fi

    # VM 的主機時間同步是另一個「會被拉回去」的來源，而且它不在這台機器上
    if [ -n "$VIRT" ]; then
        case "$VIRT" in
            microsoft) warn "這是 Hyper-V 虛擬機：主機的 Time Synchronization 整合服務會把時間拉回去"
                       info "  ${CD}要讓手動設定留得住，得在主機端關掉：Disable-VMIntegrationService -Name 'Time Synchronization'${C0}" ;;
            vmware)    warn "這是 VMware 虛擬機：VMware Tools 的時間同步可能把時間拉回去"
                       info "  ${CD}查狀態：vmware-toolbox-cmd timesync status${C0}" ;;
            *)         warn "這是虛擬機（$VIRT）：主機端的時間同步機制可能把手動設定拉回去" ;;
        esac
        plain ""
    fi

    if [ "$DRY" = 1 ]; then
        info "[乾跑] 會執行：timedatectl set-time / date -s '$C_TGT'（依這台支援的寫法）"
        info "[乾跑] 接著把系統時間寫回硬體時鐘（hwclock --systohc）"
        exit 0
    fi

    confirm "確定要把系統時間設成 $C_TGT 嗎？" || exit 1
    plain ""

    # 稽核記錄要在改之前先寫一筆，改完再寫一筆。改完之後日誌自己的時間戳也跳了，
    # 只靠時間戳排不出先後，所以兩筆都把「改前 -> 改後」寫進內容裡。
    info "設定前：$C_NOW"
    SET_VIA=''
    if ! set_clock "$C_TGT"; then
        err "系統時間設定失敗，時鐘沒有改變（現在 $(date '+%Y-%m-%d %H:%M:%S')）"
        info "這台的 date / timedatectl 都不接受設定，請確認是否在受限環境中執行"
        exit 1
    fi
    ok "系統時間已設為 $(date '+%Y-%m-%d %H:%M:%S %Z')（$C_NOW -> $C_TGT，經由 $SET_VIA）"

    # 不寫回 RTC 的話，重開機時間就跳回去了 —— 這是「改了但沒用」最常見的原因。
    # timedatectl set-time 會自己寫，其他路徑要補這一步。
    case "$SET_VIA" in
        timedatectl) info "硬體時鐘由 timedatectl 一併更新" ;;
        *)
            if has hwclock; then
                if hwclock --systohc 2>/dev/null || hwclock -w 2>/dev/null; then
                    ok "已寫回硬體時鐘（重開機後不會跳回去）"
                else
                    warn "硬體時鐘寫入失敗 —— 重開機後時間可能跳回舊值"
                    info "  ${CD}虛擬機與雲端主機常常沒有可寫的 RTC，這種情況正常${C0}"
                fi
            else
                warn "這台沒有 hwclock，無法寫回硬體時鐘，重開機後時間可能跳回舊值"
            fi ;;
    esac

    plain ""
    if [ -n "$NTP_SVC" ]; then
        info "現在這台沒有自動校時了。要恢復：${CB}$SELF ntp on${C0}"
    else
        info "這台沒有校時服務，時鐘之後會依硬體誤差慢慢漂。要裝：${CB}$SELF install${C0}"
    fi
}

# =========================================================
# sync — 立刻校時一次
# =========================================================
cmd_sync() {
    _srv="${1:-$NTP_SERVER}"
    need_root
    ntp_detect

    step "立刻校時一次"
    info "目前系統時間  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _off=$(chrony_offset 2>/dev/null)
    [ -n "$_off" ] && info "chrony 估計偏差  $_off"

    # 用哪一條路徑：正在跑的 chronyd 優先（它有現成的來源設定與統計）
    _how=''
    if [ "$NTP_KIND" = chrony ] && [ "$NTP_STATE" = active ] && has chronyc; then
        _how=makestep
    elif has chronyd; then
        _how=chronyd-q
    elif has ntpdate; then
        _how=ntpdate
    elif has sntp; then
        _how=sntp
    elif has ntpd; then
        _how=ntpd-q
    elif [ "$NTP_KIND" = timesyncd ] && [ "$NTP_STATE" = active ]; then
        # Ubuntu / Debian 的預設校時就是它，而且它沒有「立刻校時」的指令：timedatectl
        # 只能開關 NTP，要逼它馬上重新對時只能重啟服務。少了這條路徑的話，一台正在
        # 正常同步的 Ubuntu 會被告知「找不到校時工具，請安裝 chrony」——那是錯的建議。
        _how=timesyncd
    else
        err "找不到可用的校時工具（chronyd / ntpdate / sntp / ntpd / systemd-timesyncd）"
        if [ -n "$NTP_SVC" ] && [ "$NTP_KIND" = timesyncd ]; then
            info "這台有 $NTP_SVC 但沒在跑，先開起來：$SELF ntp on"
        else
            info "安裝：$SELF install"
        fi
        exit 1
    fi

    case "$_how" in
        makestep)  info "做法  chronyc makestep（用 $NTP_SVC 既有的來源，不改服務狀態）" ;;
        chronyd-q) info "做法  chronyd -q（一次性，用 /etc/chrony.conf 的來源，不會留下常駐程序）" ;;
        ntpdate)   info "做法  ntpdate -u $_srv" ;;
        sntp)      info "做法  sntp -sS $_srv" ;;
        ntpd-q)    info "做法  ntpd -q -n -p $_srv（busybox）" ;;
        timesyncd) info "做法  重啟 $NTP_SVC 讓它立刻重新對時（timesyncd 沒有一次性校時的指令）" ;;
    esac
    plain ""
    warn "校時會讓時鐘跳到正確時間 —— 偏差很大時，那一跳的後果跟手動改時間一樣"
    info "  ${CD}偏差幾秒的話影響不大；偏差幾小時的機器請先確認上面沒有在跑會被時間跳動弄壞的服務${C0}"
    plain ""
    confirm "要現在校時嗎？" || exit 1
    plain ""

    _before=$(date '+%Y-%m-%d %H:%M:%S')
    _rc=0
    case "$_how" in
        makestep)
            # -a 是「立刻對所有來源生效」，舊版 chronyc 沒有這個選項，失敗就退回不帶。
            # 乾跑只印第一種，不然會印出兩行看起來要跑兩次。
            if [ "$DRY" = 1 ]; then
                run chronyc -a makestep
            else
                chronyc -a makestep || chronyc makestep
                _rc=$?
            fi
            # chronyc 回的 200 OK 只代表「指令收到了」，真正的跳躍要等 chronyd
            # 拿到有效測量才發生。偏差大的時候會在這裡印完之後才跳。
            info "chronyc 已送出 makestep。回應的 200 OK 只表示指令被接受，"
            info "  ${CD}真正的跳躍要等 chronyd 拿到有效測量，偏差大時會晚幾秒到幾十秒才發生${C0}"
            [ "$DRY" = 1 ] || sleep 3
            ;;
        chronyd-q) run chronyd -q; _rc=$? ;;
        ntpdate)   run ntpdate -u "$_srv"; _rc=$? ;;
        sntp)      run sntp -sS "$_srv"; _rc=$? ;;
        ntpd-q)    run ntpd -q -n -p "$_srv"; _rc=$? ;;
        timesyncd)
            run systemctl restart "$NTP_SVC"; _rc=$?
            [ "$DRY" = 1 ] || sleep 3
            info "同步狀態：$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')  來源：$(timedatectl timesync-status 2>/dev/null | sed -n 's/^ *Server: *//p' | head -1)"
            ;;
    esac

    [ "$DRY" = 1 ] && { info "乾跑結束"; exit 0; }

    plain ""
    if [ "$_rc" = 0 ]; then
        ok "校時完成：$_before -> $(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        err "校時指令回傳非 0（$_rc），時間可能沒有變：現在 $(date '+%Y-%m-%d %H:%M:%S')"
        info "連不到來源時最常見的原因是防火牆擋掉 UDP 123，或這台走的是內網 NTP"
        info "指定伺服器：$SELF sync <伺服器位址>"
    fi
    _off=$(chrony_offset 2>/dev/null)
    [ -n "$_off" ] && info "chrony 估計偏差  $_off"

    # chronyd 沒在跑的時候校時只有這一次，時鐘之後照樣會漂
    if [ "$NTP_STATE" != active ]; then
        plain ""
        warn "這台沒有常駐的校時服務，這次校完之後時鐘還是會慢慢漂"
        info "要開啟自動校時：$SELF ntp on"
    fi
}

# =========================================================
# ntp on|off
# =========================================================
cmd_ntp() {
    _act="${1:-}"
    case "$_act" in
        on|off) : ;;
        *) die "用法：$SELF ntp on|off" ;;
    esac
    need_root
    ntp_detect

    if [ -z "$NTP_SVC" ]; then
        err "這台沒有安裝校時服務"
        info "安裝 chrony：$SELF install"
        exit 1
    fi

    if [ "$_act" = on ]; then
        if [ "$NTP_STATE" = active ] && [ "$NTP_BOOT" = enabled ]; then
            ok "$NTP_SVC 已經在跑，開機也會啟動，不用改"
            exit 0
        fi
        step "啟用自動校時（$NTP_SVC）"
        info "目前系統時間  $(date '+%Y-%m-%d %H:%M:%S %Z')"
        plain ""
        # 這是實測踩過的坑：一台 chronyd 停用、時鐘快 8 小時的 VM，
        # 啟動 chronyd 之後 makestep 直接把時間跳了 8 小時。
        warn "如果這台的時鐘目前偏差很大，服務起來之後會${CB}直接把時間跳到正確值${C0}"
        info "  ${CD}偏差 8 小時就跳 8 小時，跳完的後果跟手動改時間一樣（cron、TLS、DB 時序）${C0}"
        info "  ${CD}不確定偏多少的話，先跑 $SELF status 看一下再決定${C0}"
        plain ""
        confirm "要啟用 $NTP_SVC 嗎？" || exit 1

        if [ "$TDC" = 1 ]; then
            info "執行：timedatectl set-ntp true"
            run timedatectl set-ntp true 2>/dev/null
        fi
        if ! svc_active "$NTP_SVC"; then
            info "執行：啟動並設定開機啟動 $NTP_SVC"
            svc_do_boot enable "$NTP_SVC"
            svc_do start "$NTP_SVC"
        fi
        [ "$DRY" = 1 ] && { info "乾跑結束"; exit 0; }

        if svc_active "$NTP_SVC"; then
            ok "$NTP_SVC 已啟動（現在 $(date '+%Y-%m-%d %H:%M:%S %Z')）"
            info "時鐘的跳躍不一定馬上發生 —— 要等它拿到有效測量，通常幾秒到幾十秒"
        else
            err "$NTP_SVC 啟動失敗"
            case "$INIT" in
                systemd) info "看原因：systemctl status $NTP_SVC -l --no-pager" ;;
                *)       info "看原因：$NTP_SVC 的服務日誌" ;;
            esac
            exit 1
        fi
    else
        if [ "$NTP_STATE" != active ] && [ "$NTP_BOOT" != enabled ]; then
            ok "$NTP_SVC 本來就沒在跑，開機也不會啟動，不用改"
            exit 0
        fi
        step "停用自動校時（$NTP_SVC）"
        warn "停用之後沒有人在校正這台的時鐘，它會依硬體誤差慢慢漂（一天幾秒到幾十秒都有）"
        info "只是要手動設一次時間的話，設完記得再 $SELF ntp on 開回來"
        plain ""
        confirm "要停用 $NTP_SVC（含開機啟動）嗎？" || exit 1
        ntp_off_action || exit 1
    fi
}

# =========================================================
# rtc — 系統時間寫回硬體時鐘
# =========================================================
cmd_rtc() {
    need_root
    has hwclock || die "這台沒有 hwclock（util-linux），無法操作硬體時鐘"

    step "把系統時間寫回硬體時鐘"
    info "系統時間  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    _rtc=$(hwclock -r 2>/dev/null | head -1)
    if [ -n "$_rtc" ]; then
        info "硬體時鐘  $_rtc"
    else
        warn "讀不到硬體時鐘（可能沒有 RTC 裝置，或在容器 / 受限環境中）"
    fi
    plain ""
    info "重開機時系統時間是從硬體時鐘讀回來的，兩者差很多就會「改了又跳回去」"
    plain ""
    confirm "要用目前的系統時間覆蓋硬體時鐘嗎？" || exit 1

    if [ "$DRY" = 1 ]; then
        info "[乾跑] 會執行：hwclock --systohc"
        exit 0
    fi
    if hwclock --systohc 2>/dev/null || hwclock -w 2>/dev/null; then
        ok "已寫回硬體時鐘：$(hwclock -r 2>/dev/null | head -1)"
    else
        err "寫入失敗 —— 虛擬機與雲端主機常常沒有可寫的 RTC"
        exit 1
    fi
}

# =========================================================
# install
# =========================================================
cmd_install() {
    need_root
    [ "$PKG" = none ] && die "找不到套件管理器，請自行安裝 chrony 與 tzdata"

    _pkgs='chrony tzdata'
    step "安裝校時與時區套件"
    info "將要執行：${CB}$PKG_INSTALL $_pkgs${C0}"
    info "  ${CD}chrony 負責自動校時，tzdata 是時區資料庫（沒有它就沒有 Asia/Taipei 可選）${C0}"
    plain ""
    warn "安裝完${CB}不會自動啟動 chronyd${C0} —— 時鐘偏差大的機器，一啟動就會跳"
    info "要啟用請另外執行：$SELF ntp on（它會先把後果講清楚再問）"
    plain ""
    confirm "要安裝嗎？" || exit 1

    [ "$PKG" = apt ] && run apt-get update
    # shellcheck disable=SC2086
    run $PKG_INSTALL $_pkgs || { [ "$DRY" = 1 ] && exit 0; die "安裝失敗"; }
    ok "安裝完成"
}

# =========================================================
# doctor
#   重點放在「你改了但不會生效 / 會被拉回去」的那幾種情況，
#   那些是改時間最常見的坑，而且事後查起來很花時間。
# =========================================================
# 這台裝了哪些校時服務。同時裝兩套（而且兩套都在跑）會互相搶著校，
# 時鐘反而更不穩，這種機器不算少。
ntp_installed() {
    for _cand in chronyd chrony ntpd ntp systemd-timesyncd openntpd busybox-ntpd; do
        case "$INIT" in
            systemd) systemctl cat "$_cand.service" >/dev/null 2>&1 || continue ;;
            *)       [ -f "/etc/init.d/$_cand" ] || continue ;;
        esac
        if svc_active "$_cand"; then printf '%s(執行中) ' "$_cand"
        else printf '%s(未執行) ' "$_cand"; fi
    done
    printf '\n'
}

cmd_doctor() {
    CUR_TZ=$(tz_current)
    ntp_detect
    _bad=0

    plain ""
    plain "${CB} 環境檢查${C0}  ${CD}time-set.sh v$TIME_SH_VER${C0}"
    plain " ──────────────────────────────────────────────"
    info "系統      : $OS_PRETTY (family=$OS_FAMILY, version=$OS_VER)"
    info "init      : $INIT    套件管理：$PKG"
    info "時區      : $CUR_TZ"
    info "系統時間  : $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    plain ""

    # ---- 時區資料庫 ----
    if [ -d "$ZONEINFO" ]; then
        _n=$(tz_all 2>/dev/null | grep -c .)
        [ -n "$_n" ] || _n=0
        ok "時區資料庫：$ZONEINFO（$_n 個時區）"
    else
        err "沒有時區資料庫（$ZONEINFO 不存在）—— 只能用 UTC，改不了時區"
        info "  Alpine 最小安裝預設就沒有：$PKG_INSTALL tzdata"
        _bad=1
    fi

    # 各來源對不上是真的會發生（手改過 /etc/localtime、或改完沒同步 /etc/timezone），
    # 症狀是「date 跟 timedatectl 講的不一樣」，不特別點出來很難聯想到。
    _tz_link=''
    if [ -L /etc/localtime ]; then
        _tz_link=$(readlink -f /etc/localtime 2>/dev/null)
        case "$_tz_link" in
            "$ZONEINFO"/*) _tz_link=${_tz_link#"$ZONEINFO"/}; _tz_link=${_tz_link#posix/} ;;
            *) _tz_link='' ;;
        esac
    fi
    _tz_tdc=$(tdc_get Timezone 2>/dev/null)
    _tz_file=''
    [ -r /etc/timezone ] && _tz_file=$(sed -n '1s/[[:space:]]//gp' /etc/timezone 2>/dev/null)
    for _pair in "timedatectl:$_tz_tdc" "/etc/timezone:$_tz_file"; do
        _src=${_pair%%:*}; _val=${_pair#*:}
        [ -n "$_val" ] || continue
        [ -n "$_tz_link" ] || continue
        if [ "$_val" != "$_tz_link" ]; then
            warn "$_src 說時區是 $_val，但 /etc/localtime 指向 $_tz_link"
            info "  程式實際看到的是 /etc/localtime 那個。重新設一次時區可以讓兩邊一致："
            info "  $SELF set-zone $_tz_link"
        fi
    done

    # ---- 設定管道 ----
    if [ "$TDC" = 1 ]; then
        ok "timedatectl 可用（時區與時間都走它，會一併更新硬體時鐘）"
        [ "$TDC_SHOW" = 0 ] && \
            info "  這版沒有 timedatectl show（systemd 230 之前），查詢改解析 status，設定不受影響"
    elif has timedatectl; then
        warn "有 timedatectl 但連不上 systemd（容器或 systemd 沒在跑）—— 改用檔案與 date -s"
    else
        info "沒有 timedatectl（非 systemd 系統）—— 時區改 /etc/localtime，時間用 date -s"
    fi

    if has hwclock; then
        if [ "$(id -u)" = 0 ] && hwclock -r >/dev/null 2>&1; then
            ok "hwclock 可讀寫硬體時鐘"
        elif [ "$(id -u)" = 0 ]; then
            warn "hwclock 讀不到 RTC —— 改完時間無法寫回，重開機可能跳回舊值（雲端 / 容器常見）"
        else
            info "hwclock 存在（要 root 才測得出讀不讀得到）"
        fi
    else
        warn "沒有 hwclock（util-linux）—— 無法把時間寫回硬體時鐘"
    fi

    # ---- 改得動嗎 ----
    plain ""
    if [ -n "$CONTAINER" ]; then
        err "容器環境（$CONTAINER）：時鐘是主機的，這裡改不動也不該改"
        info "  時區倒是可以改（那是容器自己的 /etc/localtime）"
        _bad=1
    elif [ "$CAP_TIME" = no ]; then
        err "沒有 CAP_SYS_TIME，系統時間改不動（時區不受影響）"
        _bad=1
    elif [ "$CAP_TIME" = yes ]; then
        ok "有 CAP_SYS_TIME，改得動系統時鐘"
    fi

    # ---- 會不會被拉回去 ----
    if [ -n "$VIRT" ] && [ -z "$CONTAINER" ]; then
        case "$VIRT" in
            microsoft)
                warn "Hyper-V 虛擬機：主機的 Time Synchronization 整合服務會把手動設定的時間拉回去"
                info "  主機端關閉：Disable-VMIntegrationService -VMName <名稱> -Name 'Time Synchronization'"
                info "  guest 端關閉：把 hv_utils 的 timesync 停掉（各版做法不同）" ;;
            vmware)
                warn "VMware 虛擬機：VMware Tools 的時間同步可能把手動設定拉回去"
                info "  查狀態：vmware-toolbox-cmd timesync status（關閉：… timesync disable）" ;;
            kvm|qemu)
                info "KVM/QEMU 虛擬機：qemu-guest-agent 在主機下 guest-set-time 時會改時間（通常只在暫停/恢復後）" ;;
            *)
                info "虛擬機（$VIRT）：主機端可能有時間同步機制，改完請回頭確認有沒有被改回去" ;;
        esac
    fi

    # ---- 校時服務 ----
    plain ""
    _list=$(ntp_installed)
    if [ -z "$(printf '%s' "$_list" | tr -d ' ')" ]; then
        warn "沒有安裝任何校時服務 —— 這台的時鐘沒有人在校正，會依硬體誤差慢慢漂"
        info "  安裝：$SELF install"
    else
        info "校時服務  : $_list"
        _act=$(printf '%s\n' "$_list" | tr ' ' '\n' | grep -c '(執行中)')
        if [ "$_act" -gt 1 ]; then
            err "同時有 $_act 套校時服務在跑 —— 它們會互相搶著校正，時鐘反而更不穩"
            info "  只留一套（一般是 chronyd），其他停掉並取消開機啟動"
            _bad=1
        elif [ "$NTP_STATE" = active ]; then
            ok "$NTP_SVC 執行中（開機啟動：$NTP_BOOT）"
            _off=$(chrony_offset 2>/dev/null)
            [ -n "$_off" ] && info "  目前偏差：$_off"
            _sync=$(tdc_get NTPSynchronized 2>/dev/null)
            [ "${_sync:-}" = no ] && warn "  systemd 認為尚未同步 —— 剛啟動，或連不到來源（UDP 123 被擋是最常見的原因）"
            if [ "$NTP_KIND" = chrony ] && has chronyc; then
                _src=$(chronyc sources 2>/dev/null | grep -c '^\^\*')
                [ "${_src:-0}" = 0 ] && warn "  chrony 目前沒有選定的來源（chronyc sources 沒有 ^* 那一行）"
            fi
        else
            warn "$NTP_SVC 已安裝但沒在跑（開機啟動：$NTP_BOOT）"
            info "  要開啟：$SELF ntp on（偏差大的機器一啟動就會跳，它會先問）"
        fi
    fi

    # ---- 硬體時鐘基準 ----
    plain ""
    _lrtc=$(tdc_get LocalRTC 2>/dev/null)
    if [ "${_lrtc:-0}" = 1 ] || grep -q '^LOCAL' /etc/adjtime 2>/dev/null; then
        warn "硬體時鐘記的是本地時間（LOCAL）"
        info "  這是為了跟 Windows 雙開才會用的設定。換時區之後 RTC 的絕對時刻會錯，"
        info "  要重寫一次（$SELF rtc）；純 Linux 的機器建議改用 UTC"
    else
        ok "硬體時鐘以 UTC 為基準（Linux 的標準做法）"
    fi

    plain ""
    if [ "$_bad" = 1 ]; then
        err "有會讓「改時間」失敗或無效的問題，見上面標紅的項目"
        return 1
    fi
    ok "沒有發現會影響時區 / 時間設定的問題"
    return 0
}

# =========================================================
# 進入點
# =========================================================
usage() {
    cat <<EOF
time-set.sh — 系統時區與時間設定  v$TIME_SH_VER

用法
    $SELF status                  時區 / 系統時間 / 硬體時鐘 / 校時服務
    $SELF list [關鍵字]           列出時區（不給關鍵字只列常用的，all = 全部）
    $SELF set-zone <時區>         設定時區，例：Asia/Taipei
    $SELF set-time <時間>         手動設定系統時間
    $SELF sync [伺服器]           立刻校時一次（不改變服務的開機狀態）
    $SELF ntp on|off              啟用 / 停用自動校時
    $SELF rtc                     把目前系統時間寫回硬體時鐘
    $SELF doctor                  環境檢查（含「改了會被拉回去」的情況）
    $SELF install                 安裝 chrony 與 tzdata

時間格式
    '2026-08-19 15:30:00'   完整
    '2026-08-19 15:30'      秒補 0
    '2026-08-19'            當天 00:00:00
    '15:30:00'              今天的這個時刻
    @1755590000             epoch

選項
    -y    免確認（不會替你停用校時服務，那種情況一律拒絕執行）
    -n    乾跑，只印出會做什麼

環境變數
    OPS_NTP_SERVER   sync 預設要問哪台，目前：$NTP_SERVER
    OPS_SSH_DIR      操作記錄的位置（$LOGFILE）
    NO_COLOR         關閉顏色

改時間之前值得知道的
    時區與時間是兩件事：改時區不動絕對時刻，改時間才會。
    手動設定的時間會被正在跑的校時服務拉回去，所以 set-time 會先問你要不要停用它。
    虛擬機還有第二個來源 —— 主機端的時間同步，那個要在主機上關，doctor 會指出來。
EOF
    exit 0
}

detect_env

# 選項可以出現在子命令前後
ARGS=''
CMD=''
for _a in "$@"; do
    case "$_a" in
        -y|--yes)  YES=1 ;;
        -n|--dry-run) DRY=1 ;;
        -h|--help|help) usage ;;
        *) if [ -z "$CMD" ]; then CMD="$_a"; else ARGS="$ARGS $_a"; fi ;;
    esac
done
# shellcheck disable=SC2086
set -- $ARGS

[ "$DRY" = 1 ] && info "${CD}乾跑模式：只印出會做什麼，不會真的改${C0}"

case "${CMD:-status}" in
    status|st)          cmd_status "$@" ;;
    list|ls|list-zone)  cmd_list "$@" ;;
    set-zone|setzone|zone|tz) cmd_setzone "$@" ;;
    set-time|settime|time)    cmd_settime "$@" ;;
    sync)               cmd_sync "$@" ;;
    ntp)                cmd_ntp "$@" ;;
    rtc|hwclock)        cmd_rtc ;;
    doctor|check)       cmd_doctor ;;
    install)            cmd_install ;;
    *) err "未知的指令：$CMD"; plain ""; usage ;;
esac
