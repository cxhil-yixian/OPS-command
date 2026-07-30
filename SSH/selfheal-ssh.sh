#!/bin/sh
# n9e 自愈腳本：SSH 連接數超限取證 + 即時監看
#
# 純取證，不改變系統任何狀態，不封鎖任何 IP。
# 綁定規則：SSH連接數超限
#
# 支援：CentOS 7.9 / RHEL 7-10 / Rocky / AlmaLinux
#       Ubuntu 18.04-24.04 / Debian 9-12 / Alpine (OpenRC + busybox)
#
# 用法：
#   selfheal-ssh.sh              一次性取證，寫入 log（n9e 自愈呼叫此模式）
#   selfheal-ssh.sh watch [秒]   即時監看，預設每 1 秒更新（Ctrl-C 離開）
#   selfheal-ssh.sh snap         輸出單次即時快照（watch 內部呼叫，也可單獨用）
#   selfheal-ssh.sh tail         即時追蹤 sshd 認證日誌
#   selfheal-ssh.sh debug        傾印原始資料與偵測結果，用於排查
#
# 設計重點：
#   連線可能有數百筆，逐行傾印沒有意義。本腳本做「聚合分類」，
#   輸出「哪幾個來源、各佔多少、失敗幾次、人在不在、在做什麼」。
#   SSH 埠由 sshd_config 自動偵測。
#   snap 模式不取鎖、不寫檔、不 sleep，可安全地被 watch 每秒呼叫。
#   連線依階段分成三類（ESTAB 不等於已登入，爆破全部堆在「認證中」）：
#     SYN_RECV                  -> 嘗試建立 TCP，握手未完成
#     ESTAB + sshd 標題不含 @   -> TCP 建好但卡在認證階段
#     ESTAB + sshd 標題含 @     -> 已通過認證（sshd: root@pts/0）
#
# 以 POSIX sh 撰寫（Alpine 的 busybox ash 不需額外安裝 bash）。
# 外部指令一律先探測能力再用，探測不到就降級並在輸出中說明，不靜默失效。

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Locale：排序與時間戳必須維持 C（date '+%b %e %H' 要能比對 syslog 時間格式，
# sort 要位元組序），但字元處理必須是 UTF-8，否則 watch 做寬字元轉換時
# 會把所有中文與框線字元丟掉（畫面只剩 ASCII）。故拆開設定，勿改回 LC_ALL=C。
unset LC_ALL
export LC_COLLATE=C LC_NUMERIC=C LC_TIME=C LC_MESSAGES=C
if [ -z "${SSH_UTF_LOC:-}" ]; then
    SSH_UTF_LOC=$(locale -a 2>/dev/null | grep -iE '^(C|en_US|zh_TW|zh_CN)\.(utf-?8)$' | head -1)
    [ -z "$SSH_UTF_LOC" ] && SSH_UTF_LOC=$(locale -a 2>/dev/null | grep -i 'utf-\?8$' | head -1)
    export SSH_UTF_LOC="${SSH_UTF_LOC:-none}"
fi
if [ "$SSH_UTF_LOC" != none ]; then
    export LC_CTYPE="$SSH_UTF_LOC"; UTF8_OK=1
else
    export LC_CTYPE=C; UTF8_OK=0
fi

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# ---------- 判讀門檻 ----------
TH_ESTAB=50        # established 連線數超過此值視為偏多
TH_SINGLE_PCT=50   # 單一來源 IP 佔比超過此百分比 -> 來源集中
TH_DISTINCT=30     # 不同來源 IP 數超過此值 -> 分散式掃描
TH_FAILED_1H=100   # 近一小時登入失敗數超過此值 -> 暴力破解
TH_FAILED_1M=10    # 近一分鐘登入失敗數超過此值 -> 正在被爆破（watch 用）
TH_NEWCONN=20      # 每秒新進連線數超過此值 -> 連線風暴
TH_CLOSEWAIT=30    # CLOSE_WAIT 數量超過此值 -> 連線洩漏
TH_PREAUTH=10      # 同時卡在「認證中」的連線數超過此值 -> 爆破/掃描
TH_PREAUTH_AGE=180 # 單一連線停在認證階段超過此秒數 -> 慢速掃描或用戶端卡住
TH_SYNRECV=20      # SYN_RECV 超過此值 -> 半開連線過多

# ---------- 參數 ----------
MODE=oneshot
INTERVAL=1
case "${1:-}" in
    ""|oneshot|once)      MODE=oneshot ;;
    watch|-w|--watch)     MODE=watch; [ -n "${2:-}" ] && INTERVAL=$2 ;;
    snap|snapshot|-s)     MODE=snap ;;
    tail|-f|--follow)     MODE=tail ;;
    debug|-d|--debug)     MODE=debug ;;
    help|-h|--help)
        cat <<'USAGE'
用法：
  selfheal-ssh.sh              一次性取證，寫入 /var/log/OPS-ssh/ssh-health.log
  selfheal-ssh.sh watch [秒]   即時監看，預設每 1 秒更新（Ctrl-C 離開）
  selfheal-ssh.sh snap         輸出單次即時快照
  selfheal-ssh.sh tail         即時追蹤 sshd 認證日誌
  selfheal-ssh.sh debug        傾印原始資料與偵測結果，用於排查
USAGE
        exit 0 ;;
    *) echo "未知參數: $1（可用 oneshot / watch / snap / tail / debug / help）"; exit 1 ;;
esac

has() { command -v "$1" >/dev/null 2>&1; }

# ---------- 產出目錄 ----------
# 取證報告裡有來源 IP、被嘗試的帳號、authorized_keys 時間戳，不該讓其他使用者讀，
# 所以目錄一律收成 750。
#
# 退路建在 /tmp 這種所有人可寫的地方時，同名目錄可能已經被別人建好——那時 mkdir -p
# 會「成功」（目錄已存在），但 chmod 會失敗，等於把報告寫進別人控制得到的目錄。
# 所以這裡用 chmod 的結果來判斷目錄是不是自己的，不是的話換成帶 uid 的名字。
tmp_outdir() {
    _t="${TMPDIR:-/tmp}/OPS-ssh"
    mkdir -p "$_t" 2>/dev/null && chmod 750 "$_t" 2>/dev/null && { printf '%s\n' "$_t"; return 0; }
    _t="${TMPDIR:-/tmp}/OPS-ssh-$(id -u)"
    mkdir -p "$_t" 2>/dev/null && chmod 750 "$_t" 2>/dev/null
    printf '%s\n' "$_t"
}

# 設 OPS_SSH_DIR 可換位置；寫不進去（非 root）就退到暫存目錄，不讓腳本失敗。
OPS_SSH_DIR="${OPS_SSH_DIR:-/var/log/OPS-ssh}"
mkdir -p "$OPS_SSH_DIR" 2>/dev/null && chmod 750 "$OPS_SSH_DIR" 2>/dev/null
[ -w "$OPS_SSH_DIR" ] || OPS_SSH_DIR=$(tmp_outdir)

# 1.1.0 之前：報告在 /var/log/n9e-selfheal、速率基準在 /run（重開機就沒了）。
# 舊的 /var/lock/selfheal-ssh.lock 不主動刪：可能正被另一個行程持有，刪掉會讓
# 重入保護失效一次；它是 0 bytes 的死檔，要清可自行 rm。
LEGACY_FORENSIC_DIR=/var/log/n9e-selfheal
if [ -w "$OPS_SSH_DIR" ] && [ -d "$LEGACY_FORENSIC_DIR" ]; then
    for _f in "$LEGACY_FORENSIC_DIR"/ssh-health.log*; do
        [ -e "$_f" ] || continue
        [ -e "${OPS_SSH_DIR}/$(basename "$_f")" ] || mv -f "$_f" "${OPS_SSH_DIR}/" 2>/dev/null
    done
    rmdir "$LEGACY_FORENSIC_DIR" 2>/dev/null
fi
rm -f /run/selfheal-ssh.rate 2>/dev/null

# ---------- 發行版判定 ----------
if [ -r /etc/os-release ]; then . /etc/os-release; else ID=unknown; ID_LIKE=""; fi
case " ${ID_LIKE:-} ${ID:-} " in
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) OS_FAMILY=rhel ;;
    *debian*|*ubuntu*)                            OS_FAMILY=debian ;;
    *alpine*)                                     OS_FAMILY=alpine ;;
    *)                                            OS_FAMILY=unknown ;;
esac
OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"

if   [ -d /run/systemd/system ]; then INIT=systemd
elif has rc-service;             then INIT=openrc
else                                  INIT=sysv
fi

# 服務名與稽核日誌路徑跨發行版不同。
# Alpine 的服務名是 sshd（同 RHEL），但日誌走 busybox syslogd，預設寫在
# /var/log/messages 而非 /var/log/auth.log，兩個都納入搜尋範圍。
case "$OS_FAMILY" in
    rhel)   SVC_SSH=sshd; AUTHLOG_GLOB="/var/log/secure*" ;;
    debian) SVC_SSH=ssh;  AUTHLOG_GLOB="/var/log/auth.log*" ;;
    alpine) SVC_SSH=sshd; AUTHLOG_GLOB="/var/log/messages* /var/log/auth.log*" ;;
    *)      SVC_SSH=sshd; AUTHLOG_GLOB="/var/log/auth.log* /var/log/secure* /var/log/messages*" ;;
esac
# 未知發行版：用實際存在的 unit 名字覆寫猜測值
if [ "$OS_FAMILY" = unknown ] && [ "$INIT" = systemd ] && has systemctl; then
    if   systemctl cat sshd.service >/dev/null 2>&1; then SVC_SSH=sshd
    elif systemctl cat ssh.service  >/dev/null 2>&1; then SVC_SSH=ssh
    fi
fi

HAS_JOURNAL=0; has journalctl      && HAS_JOURNAL=1
HAS_SS=0;      has ss              && HAS_SS=1
HAS_F2B=0;     has fail2ban-client && HAS_F2B=1
HAS_WHO=0;     has who             && HAS_WHO=1
# busybox syslogd 可能只寫環狀緩衝區而沒有日誌檔，此時只有 logread 讀得到
HAS_LOGREAD=0; has logread         && HAS_LOGREAD=1

# busybox 舊版的 timeout 要用 -t SEC，先實測一次能不能直接吃秒數
TIMEOUT_OK=0
has timeout && timeout 1 true >/dev/null 2>&1 && TIMEOUT_OK=1

IDENT="${IDENT:-${HOSTNAME:-$(hostname 2>/dev/null)}}"

# 帶逾時執行；沒有可用的 timeout 就直接跑，不要因此整段不採集
run_t() {
    _rt=$1; shift
    if [ "$TIMEOUT_OK" = 1 ]; then timeout "$_rt" "$@"; else "$@"; fi
}

safe() {
    _st="$1"; shift
    run_t "$_st" "$@" 2>&1
    [ $? -eq 124 ] && echo "!! 指令逾時 ${_st}s: $*"
    return 0
}

svc_state() {
    if   [ "$INIT" = systemd ] && has systemctl; then
        systemctl is-active "$SVC_SSH" 2>/dev/null || echo inactive
    elif has rc-service; then
        rc-service "$SVC_SSH" status >/dev/null 2>&1 && echo active || echo inactive
    elif has service; then
        service "$SVC_SSH" status >/dev/null 2>&1 && echo active || echo unknown
    else
        echo n/a
    fi
}

# 取得自己往上的 PID 鏈：snap -> sh -> watch，用來把監看工具自身濾掉
ancestors() {
    _p=$$; _out=""
    while [ -n "$_p" ] && [ "$_p" != 1 ] && [ "$_p" != 0 ]; do
        _out="$_out $_p"
        _p=$(awk '{print $4}' /proc/"$_p"/stat 2>/dev/null)
    done
    echo "$_out"
}

# =========================================================
# ps 能力偵測
#   注意 procps 的 -o 語法陷阱：`ps -eo pid=,etime=,args=` 會把
#   「,etime=,args=」整串當成 pid 欄的標題，結果只印出 pid 一欄，
#   行程標題全空 -> 階段分類靜默失效。正確寫法是每欄各給一個 -o。
#   busybox 的 ps 不吃 -e，欄位規格也較少，故逐一探測取第一個能用的。
# =========================================================
PS_MODE=''
detect_ps() {
    [ -n "$PS_MODE" ] && return 0
    for _c in "-eo pid= -o etime= -o args=" \
              "-o pid= -o etime= -o args=" \
              "-eo pid,etime,args" \
              "-o pid,etime,args"; do
        # shellcheck disable=SC2086
        if [ "$(ps $_c 2>/dev/null | awk '$1+0>0 && $2 ~ /:/' | grep -c .)" -ge 3 ]; then
            PS_MODE="$_c"; break
        fi
    done
    [ -z "$PS_MODE" ] && PS_MODE=none
    return 0
}

# 統一輸出格式：pid<空白>etime<空白>完整命令列。過濾掉標題列與異常列。
ps_snap() {
    detect_ps
    [ "$PS_MODE" = none ] && return 0
    # shellcheck disable=SC2086
    ps $PS_MODE 2>/dev/null | awk '$1+0>0 && $2 ~ /:/'
}

# =========================================================
# 相對時間格式化
#   GNU date 吃 "-d @epoch"，busybox date 要用 "-D %s -d epoch"。
#   兩者都不行時退回現在時刻（過濾會變寬鬆，但不會整個失效）。
# =========================================================
date_ago() {
    _sec="$1"; _fmt="$2"
    _now=$(date +%s 2>/dev/null) || { date "$_fmt" 2>/dev/null; return 0; }
    _tgt=$(( _now - _sec ))
    date -d "@$_tgt"        "$_fmt" 2>/dev/null && return 0
    date -D %s -d "$_tgt"   "$_fmt" 2>/dev/null && return 0
    date -r "$_tgt"         "$_fmt" 2>/dev/null && return 0
    date "$_fmt" 2>/dev/null
    return 0
}

# =========================================================
# SSH 埠偵測
# =========================================================
SSH_PORTS=$(grep -hiE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
    | awk '{print $2}' | sort -un)
[ -z "$SSH_PORTS" ] && SSH_PORTS=22
PORT_LIST=$(echo "$SSH_PORTS" | tr '\n' ',' | sed 's/,$//')

# =========================================================
# 共用採集函式
# =========================================================

# --- 連線聚合 + SSH 階段分類 ---
# 重點：ESTAB 只代表 TCP 三次握手完成，不代表已登入。三種階段要分開看：
#   SYN_RECV                    -> 正在嘗試建立 TCP，握手還沒完成
#   ESTAB + sshd 標題不含 "@"   -> TCP 建好但卡在認證階段（爆破/掃描全堆在這）
#   ESTAB + sshd 標題含 "@"     -> 已通過認證，真的登入了（sshd: root@pts/0）
# 作法：ss -p 取得每條連線的 sshd pid，再比對該 pid 在 ps 裡的行程標題。
# OpenSSH 認證通過後才把標題改成 user@tty，此特徵跨版本成立（含 9.8+ 的 sshd-session）。
collect_conn() {
    # 注意：這裡刻意不加 ss 的 filter 表達式。CentOS 7 的 iproute2 對
    # 「state all "( sport = :N )"」處理與新版不同，會導致解析全空，
    # 效能優化不值得換來這種靜默失效。要撈的量本來就只有 SSH 埠。
    if [ "$HAS_SS" = 1 ]; then
        RAW=$(run_t 10 ss -tanp 2>/dev/null)
    else
        RAW=$(run_t 10 netstat -tanp 2>/dev/null)
    fi

    # 兩份輸入用分隔標記串成單一資料流：process substitution 是 bash 專屬，
    # 用它就沒辦法在 Alpine 的 ash 上跑。
    PARSED=$( { ps_snap; echo '@@SSDATA@@'; printf '%s\n' "$RAW"; } | awk -v ports="$PORT_LIST" '
        function esec(e,   d,p,t,q) {              # etime 字串轉秒數
            d=0
            if (index(e,"-")) { split(e,p,"-"); d=p[1]; e=p[2] }
            q=split(e,t,":")
            if (q==3) return d*86400 + t[1]*3600 + t[2]*60 + t[3]
            if (q==2) return d*86400 + t[1]*60   + t[2]
            return 0
        }
        BEGIN { n=split(ports,P,","); for(i=1;i<=n;i++) want[P[i]]=1; phase=1 }
        $0 == "@@SSDATA@@" { phase=2; next }
        # 第一段：ps 快照，建立 pid -> 標題 / 存活時間 對照表
        phase==1 {
            pid=$1; et=$2; c=""
            for(i=3;i<=NF;i++) c = c (i>3 ? " " : "") $i
            CMD[pid]=c; AGE[pid]=et
            next
        }
        {
            # --- 欄位用「內容」辨識，不依賴位置 ---
            # ss:      ESTAB 0 0 本地:埠 對端:埠 users:(("sshd",pid=N,fd=N))
            # netstat: tcp   0 0 本地:埠 對端:埠 ESTABLISHED N/sshd
            st=""; na=0
            for (i=1; i<=NF; i++) {
                f=$i
                if (f ~ /^users:/) break
                if (st=="" && f ~ /^[A-Z][A-Z0-9_-]*$/) st=f
                if (f ~ /^\[?[0-9a-fA-F:.*]+\]?:[0-9*]+$/) { na++; ADDR[na]=f }
            }
            if (na < 2 || st == "" || st == "LISTEN") next
            gsub(/-/,"_",st)
            loc=ADDR[na-1]; peer=ADDR[na]

            li=0; for(k=length(loc);k>0;k--) if(substr(loc,k,1)==":"){li=k;break}
            if(li==0) next
            lport=substr(loc,li+1)
            if(!(lport in want)) next
            pi=0; for(k=length(peer);k>0;k--) if(substr(peer,k,1)==":"){pi=k;break}
            if(pi==0) next
            pip=substr(peer,1,pi-1); gsub(/[\[\]]/,"",pip); sub(/^::ffff:/,"",pip)

            # --- pid 抽取，三種格式都支援 ---
            pid=""
            if (match($0, /pid=[0-9]+/))                    # iproute2 4.x
                pid=substr($0,RSTART+4,RLENGTH-4)
            else if (match($0, /"[^"]*",[0-9]+,[0-9]+\)/)) {  # iproute2 3.x（CentOS 7 舊版）
                t=substr($0,RSTART,RLENGTH); sub(/^"[^"]*",/,"",t); sub(/,[0-9]+\)$/,"",t); pid=t
            }
            else if (match($0, /[0-9]+\/[a-zA-Z]/))          # netstat -p
                pid=substr($0,RSTART,RLENGTH-2)

            c   = (pid != "" && (pid in CMD)) ? CMD[pid] : ""
            age = (pid != "" && (pid in AGE)) ? AGE[pid] : "-"
            if (c ~ /\[listener\]/) next
            title = c; sub(/^[^:]*: /, "", title)
            if      (c ~ /sshd/ && title ~ /@/) cls="authed"
            else if (c ~ /sshd/)                cls="preauth"
            else                                cls="unknown"
            if (title=="") title="-"
            print st "\t" pip "\t" cls "\t" age "\t" title "\t" esec(age)
        }')

    ESTAB_LIST=$(echo "$PARSED" | awk -F'\t' '$1 ~ /^ESTAB/ {print $2}' | grep -v '^$')
    ESTAB=$(echo "$ESTAB_LIST"  | grep -v '^$' | grep -c .)
    DISTINCT=$(echo "$ESTAB_LIST" | grep -v '^$' | sort -u | grep -c .)
    CLOSEWAIT=$(echo "$PARSED" | awk -F'\t' '$1=="CLOSE_WAIT"' | grep -c .)
    TIMEWAIT=$(echo "$PARSED"  | awk -F'\t' '$1=="TIME_WAIT"'  | grep -c .)
    SYNRECV=$(echo "$PARSED"   | awk -F'\t' '$1 ~ /SYN/'       | grep -c .)

    AUTHED=$(echo "$PARSED"   | awk -F'\t' '$1 ~ /^ESTAB/ && $3=="authed"'  | grep -c .)
    PREAUTH=$(echo "$PARSED"  | awk -F'\t' '$1 ~ /^ESTAB/ && $3=="preauth"' | grep -c .)
    UNKNOWNC=$(echo "$PARSED" | awk -F'\t' '$1 ~ /^ESTAB/ && $3=="unknown"' | grep -c .)

    # 已登入清單依「來源IP + 帳號@tty」分組：同一 IP 登入多個帳號時要能分別看到，
    # 只依 IP 合併會把第二個帳號藏掉。
    AUTH_DETAIL=$(echo "$PARSED" | awk -F'\t' '
        $1 ~ /^ESTAB/ && $3=="authed" { k=$2 SUBSEP $5; n[k]++; ip[k]=$2; ti[k]=$5; if(!(k in ag)) ag[k]=$4 }
        END { for (i in n) printf "%5d  %-18s %-24s %s\n", n[i], ip[i], ti[i], ag[i] }' | sort -rn -k2)
    PRE_DETAIL=$(echo "$PARSED" | awk -F'\t' '
        $1 ~ /^ESTAB/ && $3=="preauth" { n[$2]++; if($6+0 > mx[$2]) { mx[$2]=$6+0; ti[$2]=$5; ag[$2]=$4 } }
        END { for (i in n) printf "%5d  %-18s %-24s %s\n", n[i], i, ti[i], ag[i] }' | sort -rn)
    PRE_MAXAGE=$(echo "$PARSED" | awk -F'\t' '$1 ~ /^ESTAB/ && $3=="preauth" && $6+0>m {m=$6+0} END{print m+0}')
    SYN_DETAIL=$(echo "$PARSED" | awk -F'\t' '$1 ~ /SYN/ {print $2}' | sort | uniq -c | sort -rn)

    # 保險：pid 完全對應不到時（ss 版本太舊 / 非 root / 無可用的 ps）退回
    # 用 ps 標題與 who 統計。寧可少掉「哪個 IP」也不要整片空白。
    CLS_FALLBACK=0
    if [ "$AUTHED" -eq 0 ] && [ "$PREAUTH" -eq 0 ] && [ "$UNKNOWNC" -gt 0 ]; then
        CLS_FALLBACK=1
        AUTHED=$(ps_snap | grep -E 'sshd[^:]*: ' | grep -c '@')
        PREAUTH=$(ps_snap | grep -E 'sshd[^:]*: ' \
                  | grep -v '@' | grep -v '\[listener\]' | grep -c .)
        UNKNOWNC=0
        if [ "$HAS_WHO" = 1 ]; then
            AUTH_DETAIL=$(who 2>/dev/null | awk '{ printf "%5s  %-18s %-24s %s\n", "-", $NF, $1"@"$2, $3" "$4 }' | tr -d '()')
        else
            AUTH_DETAIL=""
        fi
        PRE_DETAIL=""
    fi

    TOPIP_LIST=$(echo "$ESTAB_LIST" | grep -v '^$' | sort | uniq -c | sort -rn | head -20)
    if [ -n "$TOPIP_LIST" ]; then
        TOP1_CNT=$(echo "$TOPIP_LIST" | head -1 | awk '{print $1}')
        TOP1_IP=$(echo "$TOPIP_LIST"  | head -1 | awk '{print $2}')
        if [ "$ESTAB" -gt 0 ]; then TOP1_PCT=$(( 100 * TOP1_CNT / ESTAB )); else TOP1_PCT=0; fi
    else
        TOP1_IP="-"; TOP1_CNT=0; TOP1_PCT=0
    fi

    # who 需要 utmp。Alpine 與多數容器預設不維護 utmp，who 會是空的，
    # 此時改數「已認證且掛在 pts/tty 上」的 sshd 行程，否則判讀會誤以為沒人在線。
    SESSIONS=0
    [ "$HAS_WHO" = 1 ] && SESSIONS=$(who 2>/dev/null | grep -c .)
    WHO_FALLBACK=0
    if [ "${SESSIONS:-0}" -eq 0 ]; then
        _s=$(ps_snap | grep -E 'sshd[^:]*: .*@(pts|tty)' | grep -c .)
        if [ "${_s:-0}" -gt 0 ]; then SESSIONS=$_s; WHO_FALLBACK=1; fi
    fi

    SSHD_CNT=$(ps_snap | grep -cE "[s]shd")
}

# --- 新進連線速率 ---
# /proc/net/snmp 的 Tcp 段第 7 欄是 PassiveOpens（外部連入），
# 第 6 欄是 ActiveOpens（本機對外），SSH 要看的是前者。
# watch 模式不能 sleep 1（會拖慢刷新），改用狀態檔算差值。
po() { awk '/^Tcp:/{if(h){print $7}else{h=1}}' /proc/net/snmp 2>/dev/null | head -1; }

# 基準檔改放產出目錄（原本在 /run，重開機就沒了）。這裡不怕殘留：讀回來的
# 基準只有在 1~120 秒內且計數沒回捲時才採用，重開機後的舊值會自動被忽略。
RATE_STATE="${OPS_SSH_DIR}/selfheal.rate"

collect_newconn() {
    cur=$(po); now=$(date +%s); NEWCONN=0
    if [ -r "$RATE_STATE" ]; then
        read -r prev_t prev_v < "$RATE_STATE"
        dt=$(( now - ${prev_t:-0} ))
        if [ "$dt" -ge 1 ] && [ "$dt" -le 120 ] && [ -n "${prev_v:-}" ]; then
            d=$(( ${cur:-0} - prev_v ))
            [ "$d" -ge 0 ] && NEWCONN=$(( d / dt ))
            echo "$now $cur" > "$RATE_STATE" 2>/dev/null
            return
        fi
    fi
    echo "$now $cur" > "$RATE_STATE" 2>/dev/null
    if [ "$MODE" = oneshot ]; then       # 沒有可用基準時才退回 1 秒取樣
        sleep 1
        c2=$(po); NEWCONN=$(( ${c2:-0} - ${cur:-0} ))
        [ "$NEWCONN" -lt 0 ] && NEWCONN=0
        echo "$(date +%s) $c2" > "$RATE_STATE" 2>/dev/null
    fi
}

# --- 取得指定時間範圍內的失敗 / 成功記錄 ---
# 優先序：journalctl -> 日誌檔 -> busybox logread（環狀緩衝，Alpine 常見）
FAIL_PAT='failed password|invalid user|authentication failure|not allowed because|maximum authentication attempts'
ACC_PAT='accepted (password|publickey|keyboard)'

# 判定「這台機器的認證記錄讀得到嗎」。
# 必須跟 grab_log 分開算：grab_log 都在命令替換的子 shell 裡跑，
# 在裡面設變數傳不回父層，回報來源會永遠停在初始值。
log_source() {
    if [ "$HAS_JOURNAL" = 1 ] \
       && [ -n "$(journalctl -u "$SVC_SSH" -n 1 --no-pager -q 2>/dev/null)" ]; then
        echo journal; return 0
    fi
    # shellcheck disable=SC2086
    if ls $AUTHLOG_GLOB >/dev/null 2>&1; then echo file; return 0; fi
    [ "$HAS_LOGREAD" = 1 ] && { echo logread; return 0; }
    echo none
}

# 日誌檔沒有年份，只能靠 "月 日 時" 前綴粗略過濾。
# 同時支援 syslog 傳統格式與 RFC3339（新版 rsyslog / systemd-journald 落檔）。
log_time_re() {
    _h0=$(date '+%b %e %H'); _h1=$(date_ago "$1" '+%b %e %H')
    _r0=$(date '+%Y-%m-%dT%H'); _r1=$(date_ago "$1" '+%Y-%m-%dT%H')
    printf '^(%s|%s|%s|%s)' "$_h0" "${_h1:-$_h0}" "$_r0" "${_r1:-$_r0}"
}

grab_log() {
    _since_h="$1"    # 給 journalctl 的人類可讀字串
    _since_s="$2"    # 給日誌檔過濾的秒數
    _pat="$3"
    _out=""
    if [ "$HAS_JOURNAL" = 1 ]; then
        _out=$(journalctl -u "$SVC_SSH" --since "$_since_h" --no-pager -q 2>/dev/null \
               | grep -iE "$_pat")
    fi
    if [ -z "$_out" ]; then
        # shellcheck disable=SC2086
        if ls $AUTHLOG_GLOB >/dev/null 2>&1; then
            _re=$(log_time_re "$_since_s")
            # shellcheck disable=SC2086
            _out=$(grep -hiE "$_pat" $AUTHLOG_GLOB 2>/dev/null | grep -E "$_re" | tail -2000)
        fi
    fi
    if [ -z "$_out" ] && [ "$HAS_LOGREAD" = 1 ]; then
        _re=$(log_time_re "$_since_s")
        _out=$(logread 2>/dev/null | grep -iE "$_pat" | grep -E "$_re" | tail -2000)
    fi
    echo "$_out"
}

grab_fail()   { grab_log "$1" "$2" "$FAIL_PAT"; }
grab_accept() { grab_log "$1" "$2" "$ACC_PAT"; }

fail_ips()   { echo "$1" | grep -oE 'from [0-9a-fA-F:.]+' | awk '{print $2}' | sort | uniq -c | sort -rn; }
fail_users() { echo "$1" | grep -oE 'invalid user [^ ]+|for [^ ]+ from' \
                 | sed -e 's/^invalid user //' -e 's/^for //' -e 's/ from$//' | sort | uniq -c | sort -rn; }

# --- 判讀（兩種模式共用同一套邏輯）---
# fail_cnt 依模式不同：oneshot 用近一小時，watch 用近一分鐘
judge() {
    fail_cnt="$1"; fail_th="$2"; fail_desc="$3"
    if   [ "$fail_cnt" -ge "$fail_th" ]; then
        VERDICT="暴力破解 (${fail_desc} ${fail_cnt} 次登入失敗)"
        ADVICE="看失敗來源 IP TOP15。建議安裝 fail2ban，或改用金鑰登入並關閉密碼驗證"
        LEVEL=crit
    elif [ "$PREAUTH" -ge "$TH_PREAUTH" ] && [ "$AUTHED" -eq 0 ]; then
        VERDICT="疑似爆破/掃描 (${PREAUTH} 條卡在認證階段，0 條完成登入)"
        ADVICE="這些連線只建好 TCP 卻從未通過認證，典型掃描器特徵。看下方[認證中]來源 IP"
        LEVEL=crit
    elif [ "$PREAUTH" -ge "$TH_PREAUTH" ]; then
        VERDICT="認證階段連線堆積 (認證中 ${PREAUTH} 條 / 已登入 ${AUTHED} 條)"
        ADVICE="正常登入通常瞬間完成，同時 ${PREAUTH} 條停在認證階段多為爆破或 MaxStartups 塞車"
        LEVEL=crit
    elif [ "${PRE_MAXAGE:-0}" -ge "$TH_PREAUTH_AGE" ]; then
        VERDICT="有連線長時間停在認證階段 (最久 ${PRE_MAXAGE} 秒)"
        ADVICE="超過 LoginGraceTime 仍未認證，可能是慢速掃描或用戶端卡住，看[認證中]清單"
        LEVEL=warn
    elif [ "$SYNRECV" -ge "$TH_SYNRECV" ]; then
        VERDICT="大量半開連線 (SYN_RECV=${SYNRECV}，TCP 握手未完成)"
        ADVICE="對方送了 SYN 卻沒完成握手，可能是 SYN flood 或掃描，檢查上游防火牆"
        LEVEL=crit
    elif [ "$DISTINCT" -ge "$TH_DISTINCT" ]; then
        VERDICT="分散式來源 (${DISTINCT} 個不同 IP)"
        ADVICE="疑似分散式掃描，單靠封鎖 IP 效果有限，建議限制來源網段"
        LEVEL=warn
    elif [ "$NEWCONN" -ge "$TH_NEWCONN" ]; then
        VERDICT="連線風暴 (每秒 ${NEWCONN} 條新連線)"
        ADVICE="非長連線堆積而是持續高速建立，查來源是否為失控腳本"
        LEVEL=warn
    elif [ "$TOP1_PCT" -ge "$TH_SINGLE_PCT" ] && [ "$ESTAB" -ge 10 ]; then
        VERDICT="來源集中於 ${TOP1_IP} (${TOP1_CNT} 條，佔 ${TOP1_PCT}%)"
        ADVICE="單一來源大量連線，多為自動化腳本未關閉連線，先確認該 IP 是否為己方設備"
        LEVEL=warn
    elif [ "$CLOSEWAIT" -ge "$TH_CLOSEWAIT" ]; then
        VERDICT="連線洩漏 (CLOSE_WAIT=${CLOSEWAIT})"
        ADVICE="連線未被正常關閉，通常是應用程式端沒有 close，非 SSH 本身問題"
        LEVEL=warn
    elif [ "$ESTAB" -ge "$TH_ESTAB" ] && [ "$SESSIONS" -lt 3 ]; then
        VERDICT="連線數多但無人在線 (${ESTAB} 條 / ${SESSIONS} 個 session)"
        ADVICE="連線並非人為操作，查上方來源 IP 排名找出自動化工具"
        LEVEL=warn
    elif [ "$ESTAB" -ge "$TH_ESTAB" ]; then
        VERDICT="連線數偏多 (${ESTAB} 條，${SESSIONS} 人在線)"
        ADVICE="有對應的互動 session，可能為正常運維活動"
        LEVEL=warn
    else
        VERDICT="未發現異常 (${ESTAB} 條連線，${SESSIONS} 人在線)"
        ADVICE="問題可能已自行恢復，或此為手動執行"
        LEVEL=ok
    fi
}

# =========================================================
# 模式：watch — 即時監看
# =========================================================
if [ "$MODE" = watch ]; then
    case "$INTERVAL" in ''|*[!0-9.]*) echo "間隔秒數需為數字"; exit 1 ;; esac
    # 監看是靠反覆呼叫「本腳本 snap」刷新，$0 是管線 / fd 時取不到實體路徑，
    # 每一輪都會失敗。改跑單次快照，並說明怎麼取得可監看的版本。
    if [ ! -f "$SELF" ]; then
        echo "以管線 / 行程替換方式執行時無法連續監看（\$0 = $0），先給你一次快照。" >&2
        echo "要即時監看請用選單入口 ops.sh，或 git clone 後執行本腳本。" >&2
        echo >&2
        MODE=snap
    fi
fi
if [ "$MODE" = watch ]; then
    if has watch; then
        # busybox 的 watch 與 procps 的 watch 支援的選項不同，逐項探測
        W_HELP=$(watch --help 2>&1)
        W_OPT=""
        echo "$W_HELP" | grep -q -- '-t' && W_OPT="$W_OPT -t"
        echo "$W_HELP" | grep -q -- '--color' && W_OPT="$W_OPT --color"
        # shellcheck disable=SC2086
        exec watch -n "$INTERVAL" $W_OPT "sh '$SELF' snap"
    else
        # 沒有 watch 指令時的替代迴圈
        trap 'echo; exit 0' INT
        while :; do clear 2>/dev/null; sh "$SELF" snap; sleep "$INTERVAL"; done
    fi
fi

# =========================================================
# 模式：tail — 即時追蹤認證日誌
# =========================================================
if [ "$MODE" = tail ]; then
    echo "追蹤 sshd 認證事件（Ctrl-C 離開）— 主機 $IDENT / 埠 $PORT_LIST"
    if [ "$HAS_JOURNAL" = 1 ]; then
        exec journalctl -u "$SVC_SSH" -f -n 30 --no-pager \
            | grep --line-buffered -iE 'failed|invalid|accepted|disconnect|maximum'
    fi
    # shellcheck disable=SC2086
    TAILFILE=$(ls -1 $AUTHLOG_GLOB 2>/dev/null | head -1)
    if [ -n "$TAILFILE" ]; then
        echo "來源：$TAILFILE"
        exec tail -F "$TAILFILE" 2>/dev/null \
            | grep --line-buffered -iE 'failed|invalid|accepted|disconnect'
    elif [ "$HAS_LOGREAD" = 1 ]; then
        echo "來源：logread（busybox syslogd 環狀緩衝）"
        exec logread -f | grep --line-buffered -iE 'failed|invalid|accepted|disconnect'
    else
        echo "找不到可追蹤的認證日誌（找過：$AUTHLOG_GLOB）"
        [ "$OS_FAMILY" = alpine ] && \
            echo "Alpine 請確認 syslog 已啟動：rc-update add syslog && rc-service syslog start"
        exit 1
    fi
fi

# =========================================================
# 模式：debug — 傾印原始資料，用於排查解析失敗
# =========================================================
if [ "$MODE" = debug ]; then
    detect_ps
    echo "===== 環境 ====="
    echo "OS        : $OS_PRETTY (family=$OS_FAMILY, init=$INIT)"
    echo "SSH 服務  : $SVC_SSH ($(svc_state))    偵測到的埠: $PORT_LIST"
    echo "執行身分  : $(id -un) (uid=$(id -u))   <- 非 root 會抓不到行程資訊"
    if [ -n "${BASH_VERSION:-}" ]; then echo "shell     : bash $BASH_VERSION"
    else echo "shell     : POSIX sh（非 bash，Alpine 的 ash 會落在這）"; fi
    echo "ss 版本   : $(ss -V 2>&1 | head -1)"
    echo "ps 用法   : ${PS_MODE}   <- none 代表沒有可用的 ps，階段分類會失效"
    echo "認證日誌  : $AUTHLOG_GLOB"
    # shellcheck disable=SC2086
    echo "實際存在  : $(ls -1 $AUTHLOG_GLOB 2>/dev/null | tr '\n' ' ')"
    echo "locale    : LC_CTYPE=$LC_CTYPE (UTF8_OK=$UTF8_OK)"
    echo "HAS_SS=$HAS_SS HAS_JOURNAL=$HAS_JOURNAL HAS_F2B=$HAS_F2B HAS_WHO=$HAS_WHO HAS_LOGREAD=$HAS_LOGREAD TIMEOUT_OK=$TIMEOUT_OK"
    echo
    echo "===== ss -tanp 原始輸出（前 15 行，這是解析的輸入）====="
    if [ "$HAS_SS" = 1 ]; then ss -tanp 2>&1 | head -15; else netstat -tanp 2>&1 | head -15; fi
    echo
    echo "===== ps 快照中的 sshd（pid / 存活時間 / 標題）====="
    ps_snap | grep -E "[s]shd"
    echo
    echo "===== who ====="
    if [ "$HAS_WHO" = 1 ]; then who 2>/dev/null; else echo "(無 who 指令)"; fi
    echo
    echo "===== 解析結果 PARSED ====="
    echo "欄位：狀態 / 來源IP / 階段 / 連線時間 / 行程標題 / 秒數"
    collect_conn
    if [ -n "$PARSED" ]; then echo "$PARSED"; else echo "(空 — 解析失敗，請把上面 ss 原始輸出貼出來)"; fi
    echo
    echo "===== 統計 ====="
    echo "ESTAB=$ESTAB SYN_RECV=$SYNRECV CLOSE_WAIT=$CLOSEWAIT 來源IP=$DISTINCT"
    echo "已登入=$AUTHED 認證中=$PREAUTH 無法判定=$UNKNOWNC 退回模式=$CLS_FALLBACK"
    echo "互動session=$SESSIONS (who 退回模式=$WHO_FALLBACK)"
    echo
    echo "===== 日誌抓取測試（近一小時失敗）====="
    F=$(grab_fail "1 hour ago" 3600)
    echo "可用來源: $(log_source)   命中筆數: $(echo "$F" | grep -v '^$' | grep -c .)"
    echo "（來源 none = 讀不到認證記錄，失敗數會恆為 0；有來源但 0 筆才是真的沒有攻擊）"
    echo "$F" | tail -5
    exit 0
fi

# =========================================================
# 模式：snap — 單次即時快照（給 watch 用；不寫檔、不取鎖）
# =========================================================
if [ "$MODE" = snap ]; then
    if [ -z "${NO_COLOR:-}" ]; then
        C_R=$(printf '\033[31m'); C_Y=$(printf '\033[33m'); C_G=$(printf '\033[32m')
        C_C=$(printf '\033[36m'); C_B=$(printf '\033[1m');  C_D=$(printf '\033[2m')
        C_0=$(printf '\033[0m')
    else
        C_R=; C_Y=; C_G=; C_C=; C_B=; C_D=; C_0=
    fi
    if [ "$UTF8_OK" = 1 ]; then
        LINE="${C_D}────────────────────────────────────────────────────────────────────────${C_0}"
    else
        LINE="${C_D}------------------------------------------------------------------------${C_0}"
        echo " [!] No UTF-8 locale found, CJK labels will be blank."
        echo "     Fix: localedef -i en_US -f UTF-8 en_US.UTF-8   (or: yum reinstall glibc-common)"
    fi

    # num 值 門檻 -> 超標顯示紅色
    num() {
        _v="$1"; _th="$2"
        if [ "$_th" != "-" ] && [ "$_v" -ge "$_th" ]; then printf "%s%6s%s" "$C_R$C_B" "$_v" "$C_0"
        else printf "%6s" "$_v"; fi
    }

    collect_conn
    collect_newconn
    FAIL_1M=$(grab_fail "1 min ago" 60)
    FAILED_1M=$(echo "$FAIL_1M" | grep -c .)
    [ -z "$FAIL_1M" ] && FAILED_1M=0
    judge "$FAILED_1M" "$TH_FAILED_1M" "近一分鐘"

    SSHD_STATE=$(svc_state)

    printf "%s SSH 即時監看 %s  %s  %s\n" "$C_B$C_C" "$IDENT" "$(date '+%F %T')" "$C_0${C_D}(Ctrl-C 離開)$C_0"
    printf " %s | sshd=%s | 埠 %s\n" "$OS_PRETTY" "$SSHD_STATE" "$PORT_LIST"
    echo "$LINE"
    printf " %sTCP 層%s\n" "$C_B$C_C" "$C_0"
    printf "   SYN_RECV 握手中 %s     ESTAB 已建立 %s     新連線    %s /秒\n" \
        "$(num "$SYNRECV" "$TH_SYNRECV")" "$(num "$ESTAB" "$TH_ESTAB")" "$(num "$NEWCONN" "$TH_NEWCONN")"
    printf "   CLOSE_WAIT      %s     TIME_WAIT    %s     來源 IP   %s\n" \
        "$(num "$CLOSEWAIT" "$TH_CLOSEWAIT")" "$(num "$TIMEWAIT" -)" "$(num "$DISTINCT" "$TH_DISTINCT")"
    printf " %sSSH 層（ESTAB 細分）%s\n" "$C_B$C_C" "$C_0"
    printf "   已認證登入      %s     認證中未認證 %s     無法判定  %s\n" \
        "$(num "$AUTHED" -)" "$(num "$PREAUTH" "$TH_PREAUTH")" "$(num "$UNKNOWNC" -)"
    printf "   互動 session    %s     sshd 行程    %s     近1分失敗 %s\n" \
        "$(num "$SESSIONS" -)" "$(num "$SSHD_CNT" -)" "$(num "$FAILED_1M" "$TH_FAILED_1M")"
    if [ "$UNKNOWNC" -gt 0 ]; then
        echo "   ${C_D}(無法判定 = ss 取不到行程對應，多為非 root 執行；跑 $SELF debug 可查原因)${C_0}"
    fi
    if [ "$CLS_FALLBACK" = 1 ]; then
        echo "   ${C_D}(ss 無行程資訊，已退回用 ps 標題統計，下方無法標出對應來源 IP)${C_0}"
    fi
    if [ "$PS_MODE" = none ]; then
        echo "   ${C_R}(找不到可用的 ps -o，階段分類失效。Alpine 請 apk add procps)${C_0}"
    fi
    if [ "$WHO_FALLBACK" = 1 ]; then
        echo "   ${C_D}(系統未維護 utmp，session 數改由 sshd 行程推估)${C_0}"
    fi
    echo "$LINE"

    if [ "$CLS_FALLBACK" = 1 ]; then
        echo " ${C_G}${C_B}[已登入]${C_0} 取自 who（退回模式）        來源 / 使用者@tty / 登入時間"
    else
        echo " ${C_G}${C_B}[已登入]${C_0} 已通過認證的來源            數量 / 來源IP / 行程 / 連線時間"
    fi
    if [ -n "$AUTH_DETAIL" ]; then
        echo "$AUTH_DETAIL" | head -6 | sed "s/^/  ${C_G}/;s/\$/${C_0}/"
    else
        echo "  (無)"
    fi
    echo " ${C_Y}${C_B}[認證中]${C_0} TCP 建好但尚未通過認證  ${C_D}← 爆破/掃描會堆在這${C_0}"
    if [ -n "$PRE_DETAIL" ]; then
        echo "$PRE_DETAIL" | head -8 | sed "s/^/  ${C_Y}/;s/\$/${C_0}/"
    else
        echo "  (無)"
    fi
    if [ -n "$SYN_DETAIL" ]; then
        echo " ${C_R}${C_B}[握手中]${C_0} 送了 SYN 但未完成三次握手"
        echo "$SYN_DETAIL" | head -5 | sed "s/^/  ${C_R}/;s/\$/${C_0}/"
    fi
    echo "$LINE"

    echo " ${C_B}線上使用者${C_0}"
    W=''
    [ "$HAS_WHO" = 1 ] && W=$(who 2>/dev/null | head -6)
    if [ -n "$W" ]; then echo "$W" | sed 's/^/  /'; else echo "  (目前無互動 session，或系統未維護 utmp)"; fi

    # 排除監看工具自己（watch / snap / 本次的 ps 與 awk），否則畫面一半是自己
    EXCL=" $(ancestors) "
    PS_TTY=$(ps -eo tty= -o pid= -o ppid= -o user= -o etime= -o args= 2>/dev/null | awk -v ex="$EXCL" -v me="$$" '
        $1 ~ /^(pts|tty)/ {
            if (index(ex, " "$2" ")) next      # 自己的祖先行程
            if ($3 == me) next                 # 自己叫出來的 ps / awk
            a=""; for(i=6;i<=NF;i++) a=a" "$i
            printf "%-7s %-8s %-9s%s\n", $1, $4, $5, a
        }' | head -8)
    if [ -n "$PS_TTY" ]; then
        echo " ${C_D}各 tty 行程${C_0}"
        echo "$PS_TTY" | cut -c1-104 | sed 's/^/  /'
    fi
    echo "$LINE"

    echo " ${C_B}最近登入失敗${C_0}"
    FAIL_10M=$(grab_fail "10 min ago" 600)
    RECENT_FAIL=$(echo "$FAIL_10M" | grep -v '^$' | tail -5)
    if [ -n "$RECENT_FAIL" ]; then
        echo "$RECENT_FAIL" | cut -c1-110 | sed "s/^/  ${C_Y}/;s/\$/${C_0}/"
        echo " ${C_D}失敗來源 TOP5（近10分）${C_0}"
        fail_ips "$FAIL_10M" | head -5 | sed 's/^/  /'
    else
        echo "  (近 10 分鐘無失敗記錄)"
    fi
    echo "$LINE"

    case "$LEVEL" in
        crit) printf " 判讀: %s%s%s\n" "$C_R$C_B" "$VERDICT" "$C_0" ;;
        warn) printf " 判讀: %s%s%s\n" "$C_Y" "$VERDICT" "$C_0" ;;
        *)    printf " 判讀: %s%s%s\n" "$C_G" "$VERDICT" "$C_0" ;;
    esac
    printf " ${C_D}建議: %s${C_0}\n" "$ADVICE"
    exit 0
fi

# =========================================================
# 模式：oneshot — 完整取證，輸出到 /var/log
# =========================================================
LOGDIR=${SSH_FORENSIC_LOGDIR:-$OPS_SSH_DIR}
OUT="$LOGDIR/ssh-health.log"
mkdir -p "$LOGDIR" 2>/dev/null
if ! touch "$OUT" 2>/dev/null; then          # 寫不進去時退到暫存目錄，避免整支腳本失敗
    LOGDIR=$(tmp_outdir); OUT="$LOGDIR/ssh-health.log"
    touch "$OUT" 2>/dev/null
fi
chmod 640 "$OUT" 2>/dev/null

MAX_SIZE=$((5*1024*1024))
KEEP_ROTATE=3
TS=$(date +%Y%m%d-%H%M%S)

if [ -f "$OUT" ]; then
    SZ=$(stat -c %s "$OUT" 2>/dev/null || wc -c < "$OUT" 2>/dev/null || echo 0)
    if [ "${SZ:-0}" -ge "$MAX_SIZE" ]; then
        i=$KEEP_ROTATE
        while [ "$i" -gt 1 ]; do
            [ -f "${OUT}.$((i-1))" ] && mv -f "${OUT}.$((i-1))" "${OUT}.${i}"
            i=$((i-1))
        done
        mv -f "$OUT" "${OUT}.1"
    fi
fi

# flock 不存在時（busybox 最小安裝）不能讓 `flock || exit 0` 誤判成
# 「已有程序執行中」而整輪不採集，故先確認指令存在再取鎖。
if has flock; then
    LOCK="${OPS_SSH_DIR}/selfheal.lock"
    exec 9>"$LOCK" 2>/dev/null || exec 9>"$(tmp_outdir)/selfheal.lock"
    flock -n 9 || { echo "已有診斷程序執行中，本次略過"; exit 0; }
fi

log() { echo "$@" >> "$OUT"; }
sec() { echo "" >> "$OUT"; echo "===== $* =====" >> "$OUT"; }

{
  echo ""
  echo "################################################################"
  echo "#  SSH 取證  $TS"
  echo "################################################################"
} >> "$OUT"

detect_ps
log "採集時間 : $(date -Is 2>/dev/null || date)"
log "主機     : $IDENT"
log "系統     : $OS_PRETTY (family=$OS_FAMILY, init=$INIT)"
log "SSH 服務 : $SVC_SSH"
log "SSH 埠   : $PORT_LIST"
log "sshd 狀態: $(svc_state)"
[ "$PS_MODE" = none ] && log "!! 找不到可用的 ps -o，階段分類將失效（Alpine 請 apk add procps）"

# ---------- 連線 ----------
collect_newconn
collect_conn

sec "連線統計"
log "-- TCP 層 --"
log "SYN_RECV    : $SYNRECV   (送了 SYN 但未完成三次握手，正在嘗試建立)"
log "ESTABLISHED : $ESTAB   (TCP 已建立，但不代表已登入)"
log "不同來源 IP : $DISTINCT"
log "CLOSE_WAIT  : $CLOSEWAIT   (偏高代表連線未正常關閉)"
log "TIME_WAIT   : $TIMEWAIT"
log "新進連線速率: ${NEWCONN} 條/秒"
log ""
log "-- SSH 層（ESTAB 細分）--"
log "已認證登入  : $AUTHED   (sshd 標題含 @，例如 sshd: root@pts/0)"
log "認證中未認證: $PREAUTH   (sshd 標題不含 @，例如 sshd: unknown [priv]；爆破堆在這)"
log "無法判定    : $UNKNOWNC   (ss 取不到行程資訊，通常是非 root 執行)"
log "認證階段最久停留: ${PRE_MAXAGE:-0} 秒 (超過 LoginGraceTime 預設 120s 即異常)"
log ""
log "-- 各狀態統計 --"
echo "$PARSED" | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn >> "$OUT"

sec "[已登入] 已通過認證的來源 (數量 / 來源IP / 行程標題 / 連線時間)"
if [ -n "$AUTH_DETAIL" ]; then echo "$AUTH_DETAIL" >> "$OUT"; else log "(無)"; fi

sec "[認證中] TCP 已建立但尚未通過認證的來源  <- 爆破/掃描會堆在這"
log "(數量 / 來源IP / 行程標題 / 該來源停留最久的連線時間)"
log ""
if [ -n "$PRE_DETAIL" ]; then echo "$PRE_DETAIL" >> "$OUT"; else log "(無)"; fi

sec "[握手中] 送了 SYN 但未完成三次握手的來源"
if [ -n "$SYN_DETAIL" ]; then echo "$SYN_DETAIL" >> "$OUT"; else log "(無)"; fi

sec "來源 IP 排名 TOP 20 (established，未分階段)"
if [ -n "$TOPIP_LIST" ]; then
    echo "$TOPIP_LIST" >> "$OUT"
else
    log "(無 established 連線)"
fi
log ""
log "最大來源：${TOP1_IP} 共 ${TOP1_CNT} 條，佔 ${TOP1_PCT}%"

sec "完整連線清單 (前 200 筆：狀態 / 來源IP / 階段 / 連線時間 / 行程標題 / 秒數)"
echo "$PARSED" | head -200 >> "$OUT"

# ---------- 誰在線上、在做什麼 ----------
# ss 只能告訴你有連線，這段才能回答「連進來幹了什麼」
sec "互動式登入 session"
if [ "$HAS_WHO" = 1 ]; then
    safe 5 who -u >> "$OUT" 2>/dev/null || safe 5 who >> "$OUT"
else
    log "(無 who 指令)"
fi
log ""
log "互動 session 數：$SESSIONS"
[ "$WHO_FALLBACK" = 1 ] && log "(系統未維護 utmp，此數字由 sshd 行程標題推估)"
log "(established 遠多於此值 = 連線沒正常關閉，或是自動化工具而非人)"

sec "各 session 正在執行的行程"
log "以 tty 對應，可看出每個登入者實際在跑什麼"
log ""
TTYS=''
[ "$HAS_WHO" = 1 ] && TTYS=$(who 2>/dev/null | awk '{print $2}' | sort -u)
if [ -n "$TTYS" ]; then
    printf '%s\n' "$TTYS" | while read -r t; do
        [ -n "$t" ] || continue
        WHOUSER=$(who 2>/dev/null | awk -v tt="$t" '$2==tt{print $1; exit}')
        FROM=$(who 2>/dev/null | awk -v tt="$t" '$2==tt{print $NF; exit}')
        log "--- $t  使用者=$WHOUSER  來源=$FROM ---"
        safe 5 ps -t "$t" -o pid,ppid,etime,stat,args 2>/dev/null | grep -v '^ *PID' >> "$OUT"
    done
else
    log "(目前無互動 session，或系統未維護 utmp)"
    log "改列出所有已認證的 sshd 行程："
    ps_snap | grep -E 'sshd[^:]*: .*@' >> "$OUT"
fi

sec "sshd 行程清單"
# procps 在的話多印 ppid / user / stat，busybox 上這組欄位不見得支援，抓不到就退回 ps_snap
PLIST=$(ps -eo pid= -o ppid= -o user= -o etime= -o stat= -o args= 2>/dev/null | grep -E "[s]shd" | head -40)
[ -z "$PLIST" ] && PLIST=$(ps_snap | grep -E "[s]shd" | head -40)
printf '%s\n' "$PLIST" >> "$OUT"
log ""
log "sshd 行程數：$SSHD_CNT"

sec "近期登入記錄"
# busybox 的 last 不吃 -Fa，先試完整格式再退回陽春格式
if last -Fa -n 1 >/dev/null 2>&1; then
    safe 10 last -Fa -n 40 >> "$OUT"
elif has last; then
    safe 10 last -n 40 >> "$OUT"
else
    log "(無 last 指令，或系統未維護 wtmp)"
fi

# ---------- 登入失敗（暴力破解證據）----------
sec "登入失敗統計"
LOG_SRC=$(log_source)
FAILLOG=$(grab_fail "1 hour ago" 3600)
FAILED_1H=$(echo "$FAILLOG" | grep -c .)
[ -z "$FAILLOG" ] && FAILED_1H=0
log "資料來源：$LOG_SRC"
if [ "$LOG_SRC" = none ]; then
    log "!! 找不到任何認證日誌來源（找過：journal / $AUTHLOG_GLOB / logread）"
    log "   失敗次數會是 0，但這代表「讀不到」而非「沒有攻擊」，連線層統計仍然有效"
    [ "$OS_FAMILY" = alpine ] && \
        log "   Alpine 請確認 syslog 已啟動：rc-update add syslog && rc-service syslog start"
fi
log "近一小時失敗次數：$FAILED_1H"
log ""
log "-- 失敗來源 IP TOP 15 --"
fail_ips "$FAILLOG" | head -15 >> "$OUT"
log ""
log "-- 被嘗試的帳號 TOP 15 --"
fail_users "$FAILLOG" | head -15 >> "$OUT"

sec "登入成功記錄 (近一小時)"
ACCLOG=$(grab_accept "1 hour ago" 3600)
echo "$ACCLOG" | tail -30 >> "$OUT"
ACCEPTED=$(echo "$ACCLOG" | grep -c .)
[ -z "$ACCLOG" ] && ACCEPTED=0
log ""
log "近一小時成功登入：$ACCEPTED 次"

# 同一 IP 大量失敗後出現成功 = 可能已被攻破，優先看這段
sec "可疑：失敗後成功的來源 IP"
FAILIP_TMP=$(fail_ips "$FAILLOG" | awk '$1>=10{print $2}')
ACCIP=$(echo "$ACCLOG" | grep -oE 'from [0-9a-fA-F:.]+' | awk '{print $2}' | sort -u)
SUSPECT=""
if [ -n "$FAILIP_TMP" ] && [ -n "$ACCIP" ]; then
    # 原本用 grep -Fxf <(...)，process substitution 是 bash 專屬，改用 awk 交集
    SUSPECT=$(printf '%s\n' "$FAILIP_TMP" | awk -v acc="$ACCIP" '
        BEGIN { n=split(acc, a, "\n"); for (i=1;i<=n;i++) if (a[i] != "") A[a[i]]=1 }
        $0 != "" && ($0 in A)')
fi
if [ -n "$SUSPECT" ]; then
    log "!! 下列 IP 大量失敗後仍有成功登入，請立即確認是否為己方人員："
    echo "$SUSPECT" >> "$OUT"
else
    log "(無)"
fi

# ---------- 防護狀態與設定 ----------
sec "fail2ban"
if [ "$HAS_F2B" = 1 ]; then
    safe 10 fail2ban-client status 2>/dev/null >> "$OUT"
    safe 10 fail2ban-client status sshd 2>/dev/null >> "$OUT"
else
    log "未安裝 fail2ban"
    log "(若確認為暴力破解，安裝 fail2ban 比自建封鎖腳本安全，"
    log " 自建腳本誤封跳板機或監控伺服器會讓機器直接失聯)"
fi

sec "sshd 關鍵設定"
safe 5 grep -hiE '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|MaxSessions|MaxStartups|MaxAuthTries|AllowUsers|AllowGroups|PubkeyAuthentication)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null >> "$OUT"

sec "authorized_keys 異動檢查"
log "若時間戳在近期而你沒有新增金鑰，代表可能已被入侵"
log ""
safe 10 find /root /home -maxdepth 3 -name authorized_keys -exec ls -l {} \; 2>/dev/null | head -20 >> "$OUT"

sec "系統連線總覽"
if [ "$HAS_SS" = 1 ]; then
    safe 5 ss -s >> "$OUT"
fi
log "fd 使用量：$(cat /proc/sys/fs/file-nr 2>/dev/null)"
log "somaxconn ：$(cat /proc/sys/net/core/somaxconn 2>/dev/null)"
log "tcp_max_syn_backlog：$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null)"

# ---------- 判讀 ----------
judge "$FAILED_1H" "$TH_FAILED_1H" "近一小時"
if [ -n "$SUSPECT" ]; then
    VERDICT="疑似已被攻破（大量失敗後出現成功登入）"
    ADVICE="立即比對來源 IP 與 authorized_keys、新增帳號、cron，必要時隔離主機"
fi

sec "判讀結果"
log "$VERDICT"
log "$ADVICE"

# ---------- 摘要輸出到 stdout ----------
echo "[$IDENT] $OS_PRETTY / SSH埠 $PORT_LIST"
echo "TCP層: SYN_RECV=${SYNRECV}(握手中) ESTAB=${ESTAB}(已建立) 來源IP=${DISTINCT} 新連線=${NEWCONN}/秒"
echo "SSH層: 已登入=${AUTHED} 認證中=${PREAUTH} 無法判定=${UNKNOWNC} 認證階段最久=${PRE_MAXAGE:-0}秒"
echo "其他 : CLOSE_WAIT=${CLOSEWAIT} TIME_WAIT=${TIMEWAIT}"
echo "最大來源: ${TOP1_IP} (${TOP1_CNT}條, ${TOP1_PCT}%)"
echo "互動session=${SESSIONS}  近1h 失敗=${FAILED_1H}(來源:${LOG_SRC}) 成功=${ACCEPTED}"
echo "判讀: $VERDICT"
echo "建議: $ADVICE"
echo "完整記錄: $OUT  (搜尋標記 $TS)"
echo "即時監看: $SELF watch"

log ""
log "#  取證結束  $TS"

exit 0
