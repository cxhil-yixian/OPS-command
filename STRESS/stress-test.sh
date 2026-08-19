#!/usr/bin/env bash
#
# stress-test.sh -- 壓力測試 (CentOS 7.9 / KVM VM)
#
# 用法說明見下面的 usage()，或不帶參數直接執行。
#
# 每次執行只產生一份報告，五個項目依 CPU -> RAM -> DISK -> SWAP -> NTP 的順序
# 寫在同一個檔案裡，最後附一段摘要。
#
# 腳本刻意不 cd 到自己所在的目錄：測試產物 (報告、fio 測試檔) 都落在
# 「你執行時所在的目錄」底下的 logs/，跟腳本放在哪無關。要換地方就 cd 過去再跑。

set -uo pipefail

# 用法說明寫成字串常數，不要回頭讀腳本自己。
# bash <(curl -fsSL ...) 這類跑法餵給 bash 的是一次性的 pipe (/dev/fd/63)，
# bash 讀完腳本後它就到 EOF 了，回頭讀只會拿到空字串 --
# 而「參數打錯」正是最需要用法說明的時候。
usage() {
    cat <<'EOF'
用法:
  stress-test.sh cpu           CPU 壓測
  stress-test.sh ram           記憶體壓測
  stress-test.sh disk          磁碟讀寫
  stress-test.sh swap          SWAP 壓測
  stress-test.sh ntp           NTP 時間偏移 2 分鐘
  stress-test.sh all           以上全跑 (不含 ntp，時鐘要自己單獨測)

參數:
  DUR=60            每項持續秒數
  DISK_DIR=./logs   fio 測試檔位置 (測完自動刪除)
  DISK_SIZE_MB=     fio 測試檔大小 MB (空 = 可用空間的一半，上限 4096)
                    要讓「讀取」數據可信就得大過 KVM host 的 cache，通常 8192 起跳
  RAM_PCT=80        ram 要吃掉「總記憶體」的百分之幾 (1-100)
                    >90 會先回收 page cache、接著狂換頁，機器可能卡到連不進去

範例:
  DUR=10 stress-test.sh all        每項只跑 10 秒，先確認流程
  DUR=300 stress-test.sh disk      拉長時間量磁碟尾端延遲
  RAM_PCT=95 stress-test.sh ram    記憶體壓更兇

不落地直接跑 (參數要接在 <(...) 之後，環境變數放最前面):
  DUR=120 bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/STRESS/stress-test.sh) all

也可以走 ops.sh 的選單 (第 s 項)，參數由選單問完再帶進來:
  bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh)

每次執行產生一份報告 logs/<項目>-<時間戳>.log，內容依序寫在同一個檔案裡。
EOF
    # 參數是在建立 logs/ 之前驗的，所以打錯字時 LOGDIR 還沒設 -- 這裡自己算，
    # 印出「本來會寫到哪」但不真的建目錄。
    echo "這次的輸出會寫到: ${LOGDIR:-$PWD/logs}"
}

# 先驗身分再建目錄，不然非 root 執行會留下一個空的 logs/ 才跟你說不能跑
[ "$(id -u)" = "0" ] || { echo "要 root"; exit 1; }

DUR="${DUR:-60}"
# DUR 會進到算術展開跟 fio --runtime，非數字的話錯誤訊息會很難懂，先擋掉
case "$DUR" in ''|*[!0-9]*) echo "DUR 要是正整數，收到: $DUR"; exit 2 ;; esac
[ "$DUR" -ge 1 ] || { echo "DUR 要 >= 1"; exit 2; }

# ram 要吃掉總記憶體的百分之幾。預設 80 是「壓得有感、但還留得住收尾與報告」的線。
# 上限就是 100：user space 本來就拿不到 100% (kernel 自己要用 page table / slab /
# 網路緩衝)，寫更大的數字只是讓它更早開始換頁，沒有額外意義。
RAM_PCT="${RAM_PCT:-80}"
case "$RAM_PCT" in ''|*[!0-9]*) echo "RAM_PCT 要是 1-100 的整數，收到: $RAM_PCT"; exit 2 ;; esac
{ [ "$RAM_PCT" -ge 1 ] && [ "$RAM_PCT" -le 100 ]; } || { echo "RAM_PCT 要在 1-100 之間，收到: $RAM_PCT"; exit 2; }

# ---------- 參數解析 ----------
# 一定要在建立 logs/ 之前驗完：打錯字就結束的話，不該在使用者的目錄留下一個空的 logs/。
case "${1:-}" in
    cpu|ram|disk|swap|ntp|all) CMD="$1" ;;
    *) usage; exit 2 ;;
esac
# fio 測試檔大小。留空 = 沿用「可用空間的一半、上限 4096MB」的自動算法。
# 會想手動指定通常只有一個原因：自動算出來的檔案比 host 的 cache 小，
# 讀取數據等於在量 host RAM。要壓過 cache 就得把它開大 (見 t_disk 的註解)。
DISK_SIZE_MB="${DISK_SIZE_MB:-}"
if [ -n "$DISK_SIZE_MB" ]; then
    case "$DISK_SIZE_MB" in ''|*[!0-9]*) echo "DISK_SIZE_MB 要是正整數 (MB)，收到: $DISK_SIZE_MB"; exit 2 ;; esac
    [ "$DISK_SIZE_MB" -ge 512 ] || { echo "DISK_SIZE_MB 至少 512，收到: $DISK_SIZE_MB"; exit 2; }
fi

# 相對於 CWD 建立，再轉成絕對路徑存起來。
# 轉絕對路徑有兩個好處：報告裡印出的路徑不會有「這是相對誰」的疑問，
# 而且之後任何 cd 都不會讓 trap 清錯檔案。
LOGDIR="./logs"
mkdir -p "$LOGDIR" || { echo "無法在目前目錄建立 logs/ (pwd: $PWD)"; exit 1; }
LOGDIR="$(cd "$LOGDIR" && pwd)"

# fio 測試檔預設就寫在 logs/ 裡，跑完由 trap 刪掉。
# 注意這跟 /tmp 在同一個檔案系統時，數據不會有差別。
DISK_DIR="${DISK_DIR:-$LOGDIR}"
mkdir -p "$DISK_DIR" || { echo "無法建立 $DISK_DIR"; exit 1; }
DISK_DIR="$(cd "$DISK_DIR" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)

# 整份報告就一個檔案，主流程決定檔名後才設定
LOG=""

# fio 測試檔的路徑存成全域，讓中斷時的 trap 也清得到。
# t_disk 自己的 RETURN trap 只在正常返回時觸發，Ctrl-C 走的是下面這條，
# 不處理的話會留一個 4GB 的檔案在 logs/ 裡。
FIO_FILE=""
# t_swap 動過的 sshd oom_score_adj，格式 "pid:原值 pid:原值"
OOM_SAVED=""
# 目前正在跑的前景工作 (stress-ng / fio / sleep)。它們一律丟背景再 wait，
# 中斷時由 work_stop 連同子程序一起收掉 -- 原因見 isleep 上面那段。
WORK_PID=""
# cap_run 用來接輸出的暫存檔與內容
CAP_FILE=""
CAP_OUT=""

# ---------- 摘要用的全域 ----------
# 每個 t_* 跑完自己填。沒跑到的維持「未執行」，摘要才會永遠列滿五項，
# 讓人一眼看出「這項沒測」而不是「這項沒問題」-- 兩者差很多。
SUM_CPU="未執行"
SUM_RAM="未執行"
SUM_DISK="未執行"
SUM_SWAP="未執行"
SUM_NTP="未執行 (需單獨執行 ntp)"

WARNINGS=""

# 腳本被 Ctrl-C / kill 時：收掉前景工作與背景監看 + 還原 oom_score_adj + 清測試檔，
# 然後把已經跑完的部分做成摘要 -- 中斷不該讓前面的結果白跑
trap 'work_stop 2>/dev/null; mon_stop 2>/dev/null
      oom_restore 2>/dev/null
      [ -n "$FIO_FILE" ] && rm -f "$FIO_FILE"; [ -n "$CAP_FILE" ] && rm -f "$CAP_FILE"
      echo; echo "已中斷，已清理"; [ -n "$LOG" ] && report_summary "已中斷"; exit 130' INT TERM

# 掃掉上次沒清乾淨的殘骸 (例如被 kill -9)
_scan_stale() {
    local d="$1" f
    for f in "$d"/.fio-test.*; do
        [ -e "$f" ] || continue
        echo "清掉上次殘留的測試檔: $f ($(du -h "$f" 2>/dev/null | cut -f1))"
        rm -f "$f"
    done
}
_scan_stale "$LOGDIR"
# DISK_DIR 指到別的地方時那邊也要掃。-ef 比對 device+inode，
# 所以 ./logs 跟 logs 跟 /abs/path/logs 都認得出是同一個目錄，不會掃兩次。
[ "$DISK_DIR" -ef "$LOGDIR" ] || _scan_stale "$DISK_DIR"

# 缺工具時給明確訊息，而不是讓它噴 command not found
need() {
    local miss="" t
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
    [ -z "$miss" ] && return 0
    log "缺少工具:$miss"
    case "$miss" in
        *fio*|*stress-ng*|*mpstat*|*vmstat*|*chronyc*)
            log "  yum install -y fio sysstat stress-ng chrony" ;;
    esac
    return 1
}

# ---------- 排版 ----------
RULE=$(printf '%.0s=' {1..78})
THIN=$(printf '%.0s-' {1..78})

# LOG 要到主流程才建立。中斷 trap 可能在那之前就呼叫到 log()，
# 這時 set -u 會讓整個 trap 炸掉，所以給個預設值。
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG:-/dev/null}"; }

# 警告同時進報告本文與摘要。摘要裡再列一次是刻意的：
# 跑 all 時本文有好幾百行，警告很容易被捲過去。
warn() {
    log "  !! $*"
    WARNINGS="$WARNINGS
  !! $*"
}

# sec <編號> <標題> -- 章節標頭。
# 編號固定用 n/5 的正式順序 (CPU=1 RAM=2 DISK=3 SWAP=4 NTP=5)，
# 就算只跑單項也看得出它在整體流程裡的位置。
sec() {
    { echo
      echo
      echo "$RULE"
      echo "  $1  $2"
      echo "$RULE"
    } | tee -a "$LOG"
}

report_head() {
    local model
    model=$(awk -F: '/model name/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
    { echo "$RULE"
      echo "                              壓 力 測 試 報 告"
      echo "$RULE"
      echo
      echo "  主機          $(hostname)"
      echo "  作業系統      $(sed -n '1p' /etc/redhat-release 2>/dev/null || uname -o)"
      echo "  核心版本      $(uname -r)"
      echo "  虛擬化        $(systemd-detect-virt 2>/dev/null || echo '未知')"
      echo "  CPU           ${model:-未知}"
      echo "  核心數        $(getconf _NPROCESSORS_ONLN)"
      echo "  記憶體        $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
      echo "  SWAP          $(awk '/SwapTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
      echo
      echo "  執行項目      $1"
      echo "  每項持續      ${DUR} s"
      echo "  開始時間      $(date '+%F %T %Z')"
      echo "  報告位置      $LOG"
      echo "  fio 測試檔    $DISK_DIR"
    } | tee "$LOG"
}

# sum_row <標籤> <內容>，內容可以是多行，續行自動對齊
sum_row() {
    local label="$1" first=1 l
    while IFS= read -r l; do
        if [ "$first" = 1 ]; then printf '  %-6s %s\n' "$label" "$l"; first=0
        else                      printf '  %-6s %s\n' ""      "$l"; fi
    done <<< "$2"
}

report_summary() {
    { echo
      echo
      echo "$RULE"
      echo "  摘要${1:+  ($1)}"
      echo "$RULE"
      echo
      sum_row "CPU"  "$SUM_CPU"
      sum_row "RAM"  "$SUM_RAM"
      sum_row "DISK" "$SUM_DISK"
      sum_row "SWAP" "$SUM_SWAP"
      sum_row "NTP"  "$SUM_NTP"
      echo
      if [ -n "$WARNINGS" ]; then
          echo "$THIN"
          echo "  警告"
          echo "$THIN"
          echo "$WARNINGS"
          echo
      fi
      echo "$THIN"
      echo "  判讀提示"
      echo "$THIN"
      echo "  * steal 持續 >0 代表 CPU 被 hypervisor 拿去給別的 VM，"
      echo "    此時 bogo ops 低是 host 超賣，不是這台機器的問題。"
      echo "  * VM 內的磁碟「讀取」數據普遍不可信 -- guest 的 direct=1 繞不過"
      echo "    hypervisor 的 cache。以「寫入的 p99 尾端延遲」為準。"
      echo "  * 平均延遲會把快慢兩群混在一起。p99 才是你的服務真正會遇到的。"
      echo
      echo "  結束時間      $(date '+%F %T %Z')"
      echo "  完整報告      $LOG"
      echo "$RULE"
    } | tee -a "$LOG"
}

# ---------- 背景監看 ----------
# 血淚教訓：不要寫成  ( while ...; done ) | sed | tee &
#   1. $! 拿到的是 tee 的 PID，不是 while 迴圈的
#   2. wait $! 會等「整條 pipeline 這個 job」結束，kill 掉 tee 不夠，job 不結束 -> 永遠卡住
#   3. 中間那個 sed 的 stdout 是 pipe，會區塊緩衝(4KB)，監看輸出要等 4 分鐘才吐出來
# 正解：監看函式直接丟背景(不接 pipeline)，$! 就是它本人；tee 放在迴圈「裡面」。
MON_PID=""

mon_start() {
    "$1" &            # 單一函式丟背景，不是 pipeline -> $! 即為其 PID
    MON_PID=$!
    # 把 job 從 bash 的 job table 移除。不然我們 kill -9 它之後，
    # bash 會回報 "line 69: 22074 Killed  "$1"" 到 stderr。
    # 先用 %% (剛丟到背景的就是 current job)：CentOS 7 的 bash 4.2 只吃 jobspec，
    # 給 PID 會被當成 job number 而找不到。新版 bash 才支援 PID，留作後備。
    # disown 之後不能再 wait 它，但我們用 kill -9 直接確保它死透，不需要 wait。
    disown %% 2>/dev/null || disown "$MON_PID" 2>/dev/null || true
}

# 遞迴殺整棵程序樹（由下往上）。
# 為什麼不能只用 pkill -P：監看迴圈裡是 `{ ...; } | tee`，本身又是一條 pipeline，
# 會再 fork 出孫程序。pkill -P 只殺直接子程序，孫程序會漏網並多吐一行出來。
_killtree() {
    local pid="$1" child children
    # 必須先「收集」子程序清單，再殺父程序：父死之後 pgrep -P 就查不到了。
    children=$(pgrep -P "$pid" 2>/dev/null)
    # 先殺父再殺子。反過來的話父程序還活著，會回報 job control 訊息
    # (line 125: 1407 Killed  vmstat 1 2) 噴到 stderr 弄髒輸出。
    kill -9 "$pid" 2>/dev/null
    for child in $children; do
        _killtree "$child"
    done
}

mon_stop() {
    [ -n "$MON_PID" ] || return 0
    # 監看只是印統計，沒有東西需要優雅收尾，直接 -9 最乾脆，
    # 也不用擔心 bash「等前景子程序跑完才處理訊號」那個行為拖時間。
    # 已 disown，所以不能也不需要 wait。
    _killtree "$MON_PID"
    MON_PID=""
}

# ---------- 前景工作 (會吃掉整個 DUR 的那些) ----------
# 為什麼不直接寫 sleep / stress-ng / fio，而要丟背景再 wait：
# bash 在等前景子程序時收到訊號，會壓著不處理，等子程序結束才跑 trap。
# 終端機 Ctrl-C 沒事 (整個 process group 一起收到)，但訊號只送給腳本本身時
# -- timeout、kill、systemd 停服務、選單以外的任何非互動呼叫 --
# 中斷會被延後最多 DUR 秒。實測 kill -TERM 之後還要再等 13 秒 trap 才動，
# 這段期間機器繼續滿載、下載繼續灌、ntp 的時鐘也繼續錯著。
# 丟背景之後主流程停在 wait，wait 會被訊號立刻打斷，trap 馬上就跑得到。
#
# 代價：背景工作在非互動 shell 底下 SIGINT 是 ignored，而且會被子程序繼承，
# 所以 Ctrl-C 不再「順便」殺掉 stress-ng/fio -- 一律由 work_stop 明確
# _killtree 掉。這樣兩種訊號來源的行為反而一致了。
work_stop() {
    [ -n "$WORK_PID" ] || return 0
    _killtree "$WORK_PID"
    # 跟 dl_kill 一樣要自己收屍，否則 bash 會補一行
    #   stress-test.sh: line 2: 3100 Killed  "$@" > "$CAP_FILE" 2>&1
    # 到 stderr。輸出丟掉，這裡不在乎它怎麼死的。
    wait "$WORK_PID" 2>/dev/null
    WORK_PID=""
}

# 可被中斷的 sleep
isleep() {
    sleep "$1" &
    WORK_PID=$!
    wait "$WORK_PID" 2>/dev/null
    WORK_PID=""
}

# run_fg <指令...> -- 輸出即時進報告 (原本的 `指令 | tee -a "$LOG"`)。
# 整條 pipeline 包在子殼裡再丟背景，$! 才會是子殼本身而不是 tee；
# _killtree 會把子殼連同 tee 與真正的工具一起收掉。
run_fg() {
    ( "$@" 2>&1 | tee -a "$LOG" ) &
    WORK_PID=$!
    wait "$WORK_PID" 2>/dev/null
    WORK_PID=""
}

# cap_run <指令...> -- 輸出要整份留著解析 (fio)，存進 $CAP_OUT。
# 這裡不能用 out=$(...)：命令替換是前景子程序，一樣會把中斷壓到它結束為止。
cap_run() {
    CAP_OUT=""
    CAP_FILE=$(mktemp "${TMPDIR:-/tmp}/st-cap.XXXXXX") || { log "無法建立暫存檔"; return 1; }
    "$@" >"$CAP_FILE" 2>&1 &
    WORK_PID=$!
    wait "$WORK_PID" 2>/dev/null
    WORK_PID=""
    CAP_OUT=$(cat "$CAP_FILE" 2>/dev/null)
    rm -f "$CAP_FILE"; CAP_FILE=""
}

# 取得目前報告的行數，之後用 tail -n +N 就能只撈這一段的監看數據。
# 報告現在是單一檔案，不記位置的話會把前面項目的數據也算進來。
mark() { wc -l < "$LOG"; }
# since <行號> -- 印出該行之後的報告內容
since() { tail -n +$(( $1 + 1 )) "$LOG"; }

# ---------- OOM 保護的還原 ----------
# oom_score_adj=-1000 等於永久豁免 OOM killer，測完不還原的話，
# 這台機器之後就再也不會 OOM 掉 sshd 了，跟系統預期行為不符。
oom_restore() {
    [ -n "$OOM_SAVED" ] || return 0
    local e p old n=0
    for e in $OOM_SAVED; do
        p="${e%%:*}"; old="${e##*:}"
        [ -d "/proc/$p" ] && echo "$old" > "/proc/$p/oom_score_adj" 2>/dev/null && n=$(( n + 1 ))
    done
    OOM_SAVED=""
    # 印出來才有辦法確認保險真的有生效，不然只能自己去 cat /proc/<pid>/oom_score_adj
    [ "$n" -gt 0 ] && log "已還原 $n 個 sshd 的 oom_score_adj"
    return 0
}

# 把 sshd 拉出 OOM killer 的名單 (-1000 = 永久豁免)，原值存進 OOM_SAVED。
# ram 與 swap 都要：兩者都可能吃到核心開始殺程序，而被殺的若是 sshd，
# 遠端機器當場斷線 -- 那時候連進去看 dmesg 都做不到。
# 呼叫端記得掛 trap 'oom_restore' RETURN，中斷則走頂層 INT/TERM。
oom_protect_sshd() {
    local p old
    OOM_SAVED=""
    for p in $(pgrep -x sshd 2>/dev/null); do
        old=$(cat "/proc/$p/oom_score_adj" 2>/dev/null) || continue
        echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null && OOM_SAVED="$OOM_SAVED $p:$old"
    done
    [ -n "$OOM_SAVED" ] && log "已把 sshd 的 oom_score_adj 設成 -1000 (測完還原)"
    return 0
}

# 把 dmesg 裡的 OOM 記錄印進報告。有記錄回 0、沒有回 1。
# 先 grep 再 tail：反過來的話 OOM 之後只要再多幾行 kernel 訊息，記錄就被 tail 切掉了。
# dmesg 沒辦法只看「這次測試」，撈到的可能是開機以來的舊記錄，所以警告文字
# 一律寫成「出現 OOM 記錄」，請人自己看時間與被殺的程序。
oom_dmesg() {
    local oom
    echo "$THIN" | tee -a "$LOG"
    log "OOM 記錄"
    oom=$(dmesg | grep -iE 'oom|killed process' | tail -30)
    if [ -n "$oom" ]; then
        printf '%s\n' "$oom" | sed 's/^/  /' | tee -a "$LOG"
        return 0
    fi
    log "  (無 OOM)"
    return 1
}

# ---------- CPU ----------
# 注意：一定要「整行組好再印」，不能邊算邊印。
# mpstat 1 1 要花整整一秒才回來，如果先 printf 前半段再等它，
# 這一秒空窗期 stress-ng 的輸出會插進來把行切斷：
#   load=... stress-ng: info: [22075] dispatching hogs
#   usr=97% sys=2%
_mon_cpu() {
    local ts load cpu
    while :; do
        ts=$(date +%H:%M:%S)
        load=$(cut -d' ' -f1-3 /proc/loadavg)
        # steal 對 KVM guest 是最關鍵的一項：它代表 CPU 被 hypervisor 拿去給別的 VM。
        # 壓測分數低但 steal 高 -> 問題在 host 超賣，不是這台機器慢。
        #
        # 千萬不要拿「表頭的欄號」去索引 Average 行 -- 兩者欄數不一樣。
        # CentOS 7 預設 en_US.UTF-8，mpstat 的時間印成 12 小時制:
        #   02:57:18 PM  CPU  %usr ...   <- 表頭前面兩欄 (時間 + PM)，%idle 在第 13 欄
        #   Average:     all  99.75 ...  <- 資料行前面只有一欄，idle 其實在第 12 欄
        # 照表頭的欄號讀會整排錯位一格，讀到的 usr 其實是 %nice、steal 其實是 %guest，
        # idle 則指到不存在的欄位而變成空字串。這個 bug 靜靜地錯，數字看起來很正常。
        #
        # 正解: 以資料行自己的 "all" 那欄當基準往後數，不管前面有幾欄時間戳都對。
        # CPU 之後的順序 (usr nice sys iowait irq soft steal guest gnice idle) 跨
        # sysstat 版本固定，新欄位一律往後加，所以 idle 取 $NF 最保險。
        # LC_ALL=C 則確保關鍵字是 Average/all 而不是被翻譯過的字串。
        cpu=$(LC_ALL=C mpstat 1 1 2>/dev/null | awk '
            /Average|平均/ {
                a = 0
                for (i = 1; i <= NF; i++) if ($i == "all") a = i
                if (!a) next
                printf "usr=%s%% sys=%s%% steal=%s%% idle=%s%%", $(a+1), $(a+3), $(a+7), $NF
            }')
        printf '  %s  load=%s  %s\n' "$ts" "$load" "$cpu" | tee -a "$LOG"
        sleep 3
    done
}
t_cpu() {
    sec "1/5" "CPU"
    need stress-ng mpstat || { SUM_CPU="跳過 (缺工具)"; return 1; }
    local n m ops steal
    n=$(getconf _NPROCESSORS_ONLN)
    log "拉滿 $n 核，${DUR}s，方法 all"
    m=$(mark)
    mon_start _mon_cpu
    run_fg stress-ng --cpu "$n" --cpu-method all -t "${DUR}s" --metrics-brief
    mon_stop

    # stress-ng --metrics-brief 的資料行:
    #   stress-ng: info:  [23801] cpu   9360   10.03   39.67   0.01   933.17   235.89
    #   $4=stressor $5=bogo ops ...      $(NF-1)=bogo ops/s (real time)
    ops=$(since "$m" | awk '$4=="cpu" && $5 ~ /^[0-9]+$/ {print $(NF-1)}' | tail -1)
    steal=$(since "$m" | grep -oE 'steal=[0-9.]+' | cut -d= -f2 | sort -rn | head -1)
    SUM_CPU="${ops:-?} bogo ops/s (${n} 核)，steal 峰值 ${steal:-?}%"
    # steal 超過幾個百分點就代表 host 上有人在跟你搶 CPU
    if [ -n "$steal" ] && awk -v s="$steal" 'BEGIN{exit !(s > 5)}'; then
        warn "CPU steal 峰值 ${steal}% -> host 超賣，這個 bogo ops 不代表這台 VM 的實力"
    fi
}

# ---------- RAM ----------
_mon_ram() {
    while :; do
        awk '/MemTotal|MemAvailable|SwapFree/{sub(/:$/,"",$1); printf "  %s=%dMB",$1,$2/1024} END{print ""}' \
            /proc/meminfo | tee -a "$LOG"
        sleep 3
    done
}
t_ram() {
    sec "2/5" "RAM"
    need stress-ng || { SUM_RAM="跳過 (缺工具)"; return 1; }
    # 總記憶體的 80%，分 2 個 worker
    local total_mb per_mb avail_mb want_mb m ops minavail
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    per_mb=$(( total_mb * RAM_PCT / 100 / 2 ))
    want_mb=$(( per_mb * 2 ))
    log "總 ${total_mb}MB，2 worker x ${per_mb}MB = ${want_mb}MB (RAM_PCT=${RAM_PCT}%)"
    # 吃的是「總記憶體」的百分比，不是「可用」的 -- 機器上已經有服務佔著記憶體時，
    # 配置量會超過剩下的量，換頁之後 OOM killer 就可能出手。這一項原本沒有任何保險，
    # 現在跟 swap 一樣先把 sshd 保護起來，並在事前把數字攤開。
    if [ "$want_mb" -gt "${avail_mb:-0}" ]; then
        warn "要配置 ${want_mb}MB，但目前只剩 ${avail_mb}MB 可用 -> 會換頁，OOM killer 可能出手"
        log "!! 另開一個 terminal 跑 dmesg -w 可以即時看到"
    fi
    # 拉高比例的代價要在跑之前講，不是事後看報告才知道
    if [ "$RAM_PCT" -gt 90 ]; then
        warn "RAM_PCT=${RAM_PCT}% -> page cache 會被回收光，之後多半是狂換頁而不是乾脆 OOM"
        log "!! 這台有 swap 的話機器會慢到近乎沒有回應 (SSH 也會卡)，oom_score_adj 保險對這種卡死沒有用"
        log "!! 真的 OOM 時第一個被挑中的通常是 stress-ng worker 自己 (RSS 最大)，測試會自己斷掉"
    fi
    oom_protect_sshd
    trap 'oom_restore' RETURN

    m=$(mark)
    mon_start _mon_ram
    run_fg stress-ng --vm 2 --vm-bytes "${per_mb}M" --vm-keep -t "${DUR}s" --metrics-brief
    mon_stop

    ops=$(since "$m" | awk '$4=="vm" && $5 ~ /^[0-9]+$/ {print $(NF-1)}' | tail -1)
    minavail=$(since "$m" | grep -oE 'MemAvailable=[0-9]+' | cut -d= -f2 | sort -n | head -1)
    SUM_RAM="${ops:-?} bogo ops/s，配置 ${want_mb}MB (總記憶體 ${RAM_PCT}%)，最低可用 ${minavail:-?}MB"
    if oom_dmesg; then
        warn "RAM 測試期間出現 OOM 記錄，請確認被殺掉的是哪些程序"
        SUM_RAM="$SUM_RAM，!! 有 OOM 記錄"
    fi
    # bogo ops 為 0 不是壞掉，是 DUR 太短跑不完一輪 -- 講清楚免得被當成故障
    if [ "${ops:-1}" = "0" ] || [ "${ops:-1}" = "0.00" ]; then
        SUM_RAM="$SUM_RAM
(bogo ops 0 = ${DUR}s 內跑不完一輪，DUR 加大即可)"
    fi
}

# ---------- SWAP ----------
# 同 _mon_cpu：vmstat 1 2 要等一秒，必須整行組好再印，
# 否則會變成  SwapFree=1583MBstress-ng: info: [22075] dispatching hogs
_mon_swap() {
    local mem swp
    while :; do
        mem=$(awk '/SwapTotal|SwapFree|MemAvailable/{sub(/:$/,"",$1); printf "  %s=%dMB",$1,$2/1024}' /proc/meminfo)
        swp=$(vmstat 1 2 2>/dev/null | awk 'NR==4{printf "  si=%s so=%s",$7,$8}')
        printf '%s%s\n' "$mem" "$swp" | tee -a "$LOG"
        sleep 2
    done
}
t_swap() {
    sec "4/5" "SWAP"
    need stress-ng vmstat || { SUM_SWAP="跳過 (缺工具)"; return 1; }
    local total_mb swap_mb target_mb m maxso minavail
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb="${swap_mb:-0}"
    [ "$swap_mb" -eq 0 ] && { log "沒有 swap，跳過"; SUM_SWAP="跳過 (這台沒有 swap)"; return; }
    # RAM 的 95% + swap 的 50%，逼出換頁但不至於 OOM
    target_mb=$(( total_mb * 95 / 100 + swap_mb / 2 ))
    log "RAM=${total_mb}MB swap=${swap_mb}MB -> 吃 ${target_mb}MB，逼出換頁"
    log "!! OOM killer 可能出手。另開一個 terminal 跑 dmesg -w 可以即時看到"

    # 保護 sshd 不被 OOM 殺掉。先存原值，測完由 oom_restore 還原。
    oom_protect_sshd
    trap 'oom_restore' RETURN

    m=$(mark)
    mon_start _mon_swap
    run_fg stress-ng --vm 1 --vm-bytes "${target_mb}M" --vm-keep -t "${DUR}s" --metrics-brief
    mon_stop

    maxso=$(since "$m" | grep -oE 'so=[0-9]+' | cut -d= -f2 | sort -rn | head -1)
    minavail=$(since "$m" | grep -oE 'MemAvailable=[0-9]+' | cut -d= -f2 | sort -n | head -1)

    if oom_dmesg; then
        warn "SWAP 測試期間出現 OOM 記錄，請確認被殺掉的是哪些程序"
        SUM_SWAP="換出峰值 ${maxso:-?} KB/s，最低可用 ${minavail:-?}MB，!! 有 OOM 記錄"
    else
        SUM_SWAP="換出峰值 ${maxso:-?} KB/s，最低可用 ${minavail:-?}MB，無 OOM"
    fi
}

# ---------- DISK ----------
t_disk() {
    sec "3/5" "DISK"
    need fio || { SUM_DISK="跳過 (缺工具)"; return 1; }
    local avail_mb size mem_mb rt mode out iops bw_str bw p99 punit p99ms line extra
    avail_mb=$(df -Pm "$DISK_DIR" | awk 'NR==2{print $4}')
    if [ -n "$DISK_SIZE_MB" ]; then
        size="$DISK_SIZE_MB"
        [ "$size" -gt "$avail_mb" ] && { log "$DISK_DIR 只剩 ${avail_mb}MB，放不下 DISK_SIZE_MB=${size}MB"; SUM_DISK="跳過 (空間不足，要 ${size}MB 只剩 ${avail_mb}MB)"; return 1; }
        log "$DISK_DIR 可用 ${avail_mb}MB -> 測試檔 ${size}MB (DISK_SIZE_MB 指定)"
    else
        # 沒指定就取可用空間的一半，上限 4096MB
        size=$(( avail_mb / 2 ))
        [ "$size" -gt 4096 ] && size=4096
        [ "$size" -lt 512 ] && { log "$DISK_DIR 只剩 ${avail_mb}MB，空間不足"; SUM_DISK="跳過 (空間不足，只剩 ${avail_mb}MB)"; return 1; }
        log "$DISK_DIR 可用 ${avail_mb}MB -> 測試檔 ${size}MB"
    fi
    log "註: direct=1 繞過 guest 的 page cache，但繞不過 KVM host 的"

    # 存全域而不是 local，頂層的 INT/TERM trap 才清得到同一個檔案
    FIO_FILE="$DISK_DIR/.fio-test.$$"
    trap 'rm -f "$FIO_FILE"; FIO_FILE=""; log "已清掉測試檔"' RETURN

    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if [ "$size" -lt "$mem_mb" ]; then
        warn "測試檔 ${size}MB < RAM ${mem_mb}MB，讀取數據會被 cache 汙染"
        log "   要壓過 cache 就把檔案開大: DISK_SIZE_MB=$(( mem_mb * 2 )) (需要同等的可用空間)"
    fi

    # DUR < 5 時整數除法會得到 0，而 fio 的 --runtime=0 是「不設限」，
    # 配上 --time_based 就永遠跑不完。至少留 1 秒。
    rt=$(( DUR / 5 )); [ "$rt" -lt 1 ] && rt=1
    log "每個模式跑 ${rt}s (DUR 五等分)"
    # 太短的話 iodepth=32 只發得出幾十個 IO，百分位數純粹是雜訊。
    # 不講的話它會安靜地產出看起來很正常、實際沒意義的數字。
    [ "$rt" -lt 5 ] && warn "每個模式只有 ${rt}s，IO 樣本太少，百分位數不具參考價值 (建議 DUR>=240)"

    # 模式規格: <fio rw> <標籤> <bs> <ioengine> <iodepth> <sync>
    #
    # 循序寫排第一個是刻意的：檔案由這一輪的 direct 寫入建立起來。讀取與隨機模式
    # 需要檔案先存在，fio 會自己先 layout 一遍 —— 那一遍是 buffered 的，等於在
    # 開始量之前先把整個檔案灌進 host cache，既浪費時間又汙染後面的讀取數據。
    #
    # 最後一項是「同步寫延遲」：iodepth=1 + O_SYNC + psync，一次只發一個 IO 並等它
    # 真的落地。前四項的 iodepth=32 量的是「排隊排滿時的吞吐」，把單一 IO 的延遲藏
    # 在佇列後面；資料庫 commit、fsync、寫 log 感受到的是這個數字，不是那個吞吐。
    SUM_DISK=""
    # 標籤一律四個字：摘要那幾列是 printf 對齊的，而 bash 的 %-Ns 是按 byte 補空白、
    # 中文字卻佔兩欄，長度不一致的話整排會歪掉。
    for mode in "write 循序寫入 1M libaio 32 0" \
                "randwrite 隨機寫入 4k libaio 32 0" \
                "read 循序讀取 1M libaio 32 0" \
                "randread 隨機讀取 4k libaio 32 0" \
                "randwrite 同步延遲 4k psync 1 1"; do
        set -- $mode
        echo "$THIN" | tee -a "$LOG"
        log "$2 ($1 bs=$3 iodepth=$5${6:+ sync=$6})"
        [ "$6" = "1" ] && extra="--sync=1" || extra=""
        # shellcheck disable=SC2086
        cap_run fio --name="$1" --filename="$FIO_FILE" --size="${size}M" \
            --rw="$1" --bs="$3" --ioengine="$4" --iodepth="$5" $extra --direct=1 \
            --runtime="$rt" --time_based --group_reporting
        out="$CAP_OUT"

        # 收 IOPS/BW、平均延遲、以及 p95/p99/p99.99 尾端延遲。
        # 尾端才是重點：共享雲端磁碟的平均值好看，p99 會差兩個數量級。
        # 一定要一起收 "clat percentiles (usec):" 那行 -- fio 會依數值大小自己換單位，
        # 少了它，log 裡的 848 和 3473 長得一模一樣，實際上差 1000 倍。
        printf '%s\n' "$out" \
            | grep -E 'IOPS=|BW=|lat \((usec|msec|nsec)\): min=|percentiles \(|95\.00th|99\.00th|99\.99th' \
            | sed 's/^/  /' | tee -a "$LOG"

        iops=$(printf '%s\n' "$out" | grep -oE 'IOPS=[0-9.]+k?' | head -1 | cut -d= -f2)
        bw_str=$(printf '%s\n' "$out" | grep -oE 'BW=[0-9.]+[KMGT]iB/s' | head -1 | cut -d= -f2)
        # 百分位數的單位由 "clat percentiles (usec):" 決定，不是固定的
        punit=$(printf '%s\n' "$out" | sed -nE 's/.*clat percentiles \((usec|msec|nsec)\).*/\1/p' | head -1)
        p99=$(printf '%s\n' "$out" | sed -nE 's/.*99\.00th=\[[[:space:]]*([0-9]+)\].*/\1/p' | head -1)
        # 統一換算成 ms 才能跨模式比較
        if [ -n "$p99" ] && [ -n "$punit" ]; then
            p99ms=$(awk -v v="$p99" -v u="$punit" 'BEGIN{
                if (u=="usec") v/=1000; else if (u=="nsec") v/=1000000
                printf "%.1fms", v }')
        else
            p99ms="?"
        fi
        line=$(printf '%s  %-8s IOPS  %-12s p99 %s' "$2" "${iops:-?}" "${bw_str:-?}" "$p99ms")

        # host cache 偵測：guest 的 direct=1 繞不過 hypervisor 的 cache。
        # 一般雲端磁碟不可能超過 2GB/s，超過就是在量 host RAM 不是磁碟。
        # fio 依數值大小自己挑單位跟小數位 (BW=48.0MiB/s / BW=3054MiB/s / BW=11.7GiB/s)，
        # 所以要連單位一起抓再換算成 MiB/s。只比對整數 MiB 的話，
        # 高速時 fio 早就改印 GiB/s 了，這個警告永遠不會觸發 -- 正是最需要它的時候。
        bw=$(printf '%s\n' "$out" | grep -oE 'BW=[0-9.]+[KMGT]iB/s' | tail -1 | awk '
            { match($0, /[0-9.]+/); v = substr($0, RSTART, RLENGTH) + 0
              if (/KiB/) v /= 1024; else if (/GiB/) v *= 1024; else if (/TiB/) v *= 1048576
              printf "%d", v }')
        if [ -n "$bw" ] && [ "$bw" -gt 2000 ]; then
            warn "$2 ${bw}MiB/s 超出實體磁碟合理範圍 -> 這是 KVM host 的 cache，此數據無效"
            line="$line   !! 無效 (host cache)"
        fi
        SUM_DISK="${SUM_DISK:+$SUM_DISK
}$line"
    done
}

# ---------- NTP 時間偏移 ----------
NTP_SHIFTED=0
t_ntp() {
    sec "5/5" "NTP"
    need chronyc || { SUM_NTP="跳過 (缺工具)"; return 1; }
    local before after
    before=$(date '+%F %T')
    log "現在時間: $before"
    log "chronyd 狀態: $(systemctl is-active chronyd)"

    # 一定要有還原保險：腳本被 Ctrl-C 也要把時鐘拉回來
    restore_ntp() {
        echo "$THIN" | tee -a "$LOG"
        log "還原"
        # 先把自己撥掉的 2 分鐘扣回來。只靠 chronyc makestep 的話，
        # 機器連不到 NTP 來源時時鐘就一直錯 2 分鐘；這一步是確定性的，不依賴網路。
        # NTP_SHIFTED 擋重入：這個函式若跑兩次就會倒扣 4 分鐘。
        if [ "$NTP_SHIFTED" = "1" ]; then
            NTP_SHIFTED=0
            date -s "-2 minutes" > /dev/null
        fi
        # 不管有沒有撥過時鐘都要把 chronyd 拉回來 -- 上面撥時鐘失敗而提早 return 時，
        # chronyd 已經是停的了。
        systemctl start chronyd 2>/dev/null
        sleep 2
        # 再讓 chronyd 修掉剩下的殘差
        chronyc makestep 2>&1 | sed 's/^/  /' | tee -a "$LOG"
        sleep 3
        log "還原後: $(date '+%F %T')"
        chronyc tracking 2>&1 | grep -E 'System time|Last offset' | sed 's/^/  /' | tee -a "$LOG"
        SUM_NTP="偏移 +2min 觀察 ${DUR}s 後已還原 (現在 $(date '+%T'))"
    }
    # RETURN 管正常結束。INT/TERM 要自己收尾：先關掉 RETURN trap 避免還原跑兩次
    # (Ctrl-C 會中斷 sleep -> 跑 INT handler -> 函式繼續往下 return -> RETURN trap 又觸發)，
    # 而且要自己 exit 130，不然中斷後 exit code 會是 0。
    trap 'restore_ntp' RETURN
    trap 'trap - RETURN; restore_ntp; echo; echo "已中斷，已還原"; report_summary "已中斷"; exit 130' INT TERM

    log "停掉 chronyd (不停的話兩秒後就被拉回，你會以為沒生效)"
    systemctl stop chronyd
    sleep 1

    log "把系統時鐘往前撥 2 分鐘"
    if date -s "+2 minutes" | sed 's/^/  /' | tee -a "$LOG"; then
        NTP_SHIFTED=1
    else
        log "date -s 失敗，取消測試"
        SUM_NTP="失敗 (date -s 沒成功)"
        return 1    # RETURN trap 會把 chronyd 拉回來
    fi
    after=$(date '+%F %T')
    log "偏移後: $after"

    echo "$THIN" | tee -a "$LOG"
    log "觀察 ${DUR}s -- 這期間去看你的應用有沒有異常"
    log "  TLS 憑證驗證 / cron / DB replication / log 時序都可能出事"
    isleep "$DUR"
    # trap RETURN 會自動呼叫 restore_ntp
}

# ---------- 主 ----------
# 參數在檔案上半部就驗完了 (見「參數解析」)，這裡直接開報告。
LOG="$LOGDIR/$CMD-$TS.log"
report_head "$CMD"

case "$CMD" in
    cpu)   t_cpu ;;
    ram)   t_ram ;;
    disk)  t_disk ;;
    swap)  t_swap ;;
    ntp)   t_ntp ;;
    # 順序固定 CPU -> RAM -> DISK -> SWAP。ntp 不含在內：時鐘是全機共用的狀態，
    # 順手跑掉風險太高，要測就自己單獨跑。
    all)   t_cpu; t_ram; t_disk; t_swap ;;
esac

report_summary
