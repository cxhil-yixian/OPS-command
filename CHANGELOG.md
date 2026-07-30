# 變更記錄

本檔案記錄本專案所有值得注意的變更。

格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本號依循[語意化版本](https://semver.org/lang/zh-TW/)。

---

## [1.2.0] - 2026-07-30

新增 fail2ban 封鎖管理工具。

### 新增

- **`FAIL2BAN/fail2ban.sh` — fail2ban 封鎖管理**（POSIX sh，Alpine 可直接執行）
  - 手動封鎖 / 解封、清空封鎖、白名單增刪、IP 查詢、封鎖排行、日誌追蹤、
    封鎖時長設定、建立 sshd jail、安裝、環境檢查。支援 IP 與 CIDR。
  - **封鎖前先算會不會鎖到自己**：比對目前的 SSH 來源（`SSH_CONNECTION` →
    `who` → 從 `ss` 找「本地埠 = 實際 SSH 埠」的連線反推）、本機所有位址、loopback。
    CIDR 是真的做網段涵蓋計算——POSIX awk 沒有位元運算，改用「除以 2^(32-prefix)
    後比商」，效果等同遮罩比對且不需要 gawk 擴充。命中就擋下，要硬幹得加 `--force`。
  - **專門抓「設了但不會生效」**（`doctor`）：沒有任何 jail（RHEL 系裝完預設全部
    `enabled = false`）、jail 的 `port` 沒跟上實際 SSH 埠、有封鎖中但 iptables /
    nftables 裡找不到對應規則。這三種情況服務都是「綠的」，但一個攻擊都擋不住。
  - 封鎖一律透過 `fail2ban-client`，**不自己寫防火牆規則**——手寫規則與 fail2ban
    自己的狀態不一致，是這類工具最難查的問題。
  - 設定只寫 `jail.d/zz-ops-*.local`，不碰發行版的 `jail.conf`（套件升級會覆寫它）。
    白名單寫入前會先讀回目前生效的 `ignoreip` 合併，因為 `jail.d/*.local` 載入順序
    在最後，直接寫會把管理員原有的白名單默默吃掉。
  - 相容 fail2ban 0.9（Debian 9 內建）到 1.x：狀態解析 `status` 輸出而非 0.10+ 才有的
    `get` 子命令；`banip --time` 與 `addignoreip` 用「試一次看結果」判斷能力，
    不比版本號（發行版常有 backport）也不解析 help 文字（各版用詞不同），
    不支援就降級並在畫面上講明一次。
  - 操作稽核寫入 `/var/log/OPS-ssh/fail2ban-ops.log`。
- **`FAIL2BAN/README.md`** — 自鎖防護、三種「設了但不會生效」、白名單的載入順序陷阱、
  封鎖時長的 best-effort 行為、相容性對照表、疑難排解。
- **`ops.sh` 封鎖子選單**（主選單按 `b`）：項目多，塞進主選單會把最常用的 SSH 工具淹掉，
  所以獨立成子選單。IP 相關動作一律不帶 `-y`，讓底層腳本自己印出「將要做什麼」再確認，
  確認邏輯只留一份。遠端模式會一併下載 `FAIL2BAN/fail2ban.sh`。

### 修正

- `ops.sh` 的 `doctor` 腳本清單、相依檢查的 fail2ban 說明改指向新工具。
- `.gitignore` 補上 `OPS-ssh/`（產出目錄改名後的殘留防護）。

### 移除

- `.claude/`（Claude Code 的本機權限快取，與專案無關；1.0.0 移除過，之後又被重建）。

---

## [1.1.0] - 2026-07-30

兩件事：支援一行指令直接執行不必先 clone，以及 `SSH/` 腳本的產出檔案統一收到
`/var/log/OPS-ssh/`。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh)
curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/ops.sh | sh
```

### 新增

- **`ops.sh` 遠端模式**：以 `bash <(curl …)` 執行時 `$0` 是 `/dev/fd/NN`，管線執行時是
  `sh`，兩者都取不到 repo 目錄，原本所有以 `$0` 為基準的本地路徑（`SSH/ssh-port.sh`、
  `SSH/selfheal-ssh.sh`、`REPO/URL`）都會失效。現在會判斷執行方式：`$0` 旁邊有完整的
  `SSH/` 就直接用本機檔案，否則把需要的腳本下載到快取目錄後再呼叫。
  - 快取位置：root 為 `/var/lib/ops-command`，非 root 依序取 `$XDG_CACHE_HOME`、
    `~/.cache`、`$TMPDIR`，目錄權限 700。
  - **刻意不用 `mktemp -d` 後自動清除**：`ssh-port.sh` 的看門狗是背景執行
    「本腳本路徑 `rollback --auto`」來自動還原，腳本檔案在 `confirm` 之前被刪掉，
    等於自動還原機制失效，換埠失敗時會真的被鎖在門外。換埠前的提示會一併講明這點。
  - 下載先落 `.part` 再改名，中斷不會留下半截檔；內容第一行不是 `#!` 就丟棄，
    避免被 captive portal / 代理回傳的 HTML 當成腳本執行。
  - 開場一次抓齊，讓選單與 `doctor` 看到的狀態一致；個別選項被選到時若檔案仍缺，
    會再補抓一次。
- **`OPS_RAW_BASE`**：改寫遠端來源前綴，可指向 fork、內網鏡像或其他分支。
- **選單 `u`（僅遠端模式）**：重新下載 `SSH/` 底下的工具。有未確認的換埠作業進行中時
  會先警告再問，因為覆蓋腳本會影響看門狗的還原行為。
- **`curl … | sh` 的互動支援**：這種寫法的 stdin 是腳本本身，讀不到鍵盤。現在會把
  `ops.sh` 自己落地成檔案，改以 `/dev/tty` 當 stdin 重新 `exec`，選單照樣可操作；
  真的沒有控制終端（cron / CI）才維持原本的擋下行為。
- 標頭與 `doctor` 會顯示工具來源（本機路徑或遠端 URL + 快取位置），
  `doctor` 另外多一段「遠端執行注意」。

### 變更

- **產出路徑統一到 `/var/log/OPS-ssh/`**（權限 750），原本散在四個地方：

  | 舊路徑 | 新路徑 |
  |---|---|
  | `/var/log/ssh-port.log` | `/var/log/OPS-ssh/ssh-port.log` |
  | `/var/lib/ssh-port/` | `/var/log/OPS-ssh/ssh-port/` |
  | `/var/log/n9e-selfheal/ssh-health.log` | `/var/log/OPS-ssh/ssh-health.log` |
  | `/run/selfheal-ssh.rate` | `/var/log/OPS-ssh/selfheal.rate` |
  | `/var/lock/selfheal-ssh.lock` | `/var/log/OPS-ssh/selfheal.lock` |

  - 舊路徑會在下次執行時自動搬過來（含 `backup-*` 目錄與既有日誌），搬完移除舊目錄。
  - **換埠進行中不搬**：看門狗行程此刻正在執行舊目錄下的 `watchdog.sh`，跨檔案系統的
    `mv` 會把它腳下的檔案抽掉，等於毀掉自動還原。這種情況會沿用舊路徑並印出說明，
    等 `confirm` / `rollback` 結束後下一次執行才搬。`ops.sh` 的 `doctor` 會顯示
    目前處於這個狀態。
  - 舊的 `/var/lock/selfheal-ssh.lock` 不主動刪除：可能正被另一個行程持有，刪掉會讓
    重入保護失效一次。它是 0 bytes 的死檔，要清可自行 `rm`。
  - 速率基準從 `/run`（tmpfs，重開機清空）移到持久目錄不影響正確性：讀回來的基準
    只在 1~120 秒內且計數沒回捲時才採用，重開機後的舊值會自動被忽略。
- 新增 `OPS_SSH_DIR` 環境變數可換整個產出目錄；`ops.sh` 會 export 給子腳本，
  兩邊一定一致。`SSH_FORENSIC_LOGDIR`（只改取證報告輸出）仍然有效且優先。
- `selfheal-ssh.sh` 寫不進產出目錄時（非 root）退到 `$TMPDIR/OPS-ssh`，
  原本是 `/tmp/n9e-selfheal`。這個退路同樣是 750，且不再有檔案散落在 `/tmp` 根層
  （重入鎖原本直接落在 `/tmp/selfheal-ssh.lock`，現在也在目錄裡）。

> 這個目錄**不要套 logrotate 或定期清空**：`ssh-port/` 底下是狀態與看門狗腳本，
> 不是日誌，清掉會讓進行中的換埠失去自動還原能力。取證報告本身已有輪替（5MB × 3）。

### 修正

- `ops.sh` 的 `-h` 原本是 `sed` 讀自己的註解區塊（`sed -n '3,20p' "$SELF"`），
  一行指令執行時 `$SELF` 是已被讀完的管線，說明會印不出來。改為內嵌文字。
- `need_root` 提示的重跑指令原本固定印 `$SELF`，遠端模式下會印出 `/dev/fd/63`
  這種沒有意義的路徑。改為依執行方式給出可直接複製的指令。
- 快取目錄裡的 `ops.sh` 被再次執行時，因為旁邊就有 `SSH/`，會被誤判成本機 clone
  而少掉 `u` 選項並一直用舊版。改為比對快取路徑並加上 `.ops-remote` 標記檔排除。

### 安全性

- **`SSH/ssh-port.sh` 拒絕以管線 / 行程替換方式執行**。看門狗必須把腳本的實體路徑
  寫進背景排程才能自動還原，`$0` 是 fd 或 `sh` 時寫進去的是無效路徑——換埠失敗時
  不但不會自動還原，還會讓人誤以為有保護。這種情況直接拒絕並提示改用 `ops.sh`
  或 clone，不做降級。
- `SSH/selfheal-ssh.sh` 的 `watch` 在同樣情況下無法反覆呼叫自己刷新，改為輸出一次
  快照並說明原因，不再每輪失敗。
- **`/tmp` 退路的目錄劫持防護**。`/tmp` 是所有人可寫的，同名目錄若已經被別的使用者
  建好，`mkdir -p` 會「成功」（目錄已存在）但 `chmod` 會失敗——單純加 `chmod 750`
  並不能保證目錄是自己的。兩支腳本改用 `chmod` 的結果來判斷：
  - `selfheal-ssh.sh`：不是自己的目錄就換成 `$TMPDIR/OPS-ssh-<uid>`，避免把含來源 IP
    與帳號的取證報告寫進別人控制得到的目錄。
  - `ops.sh`：快取目錄放的是「等一下會被 root 執行」的腳本，權限設不上時**直接停下**
    並提示改用 `git clone` 或改 `TMPDIR`，不接受降級。

---

## [1.0.0] - 2026-07-29

首個完整版本。

在此之前 repo 內只有 `LICENSE` 進入版本控制，`ssh-port.sh` 與 `selfheal-ssh.sh`
以未追蹤的檔案存在於工作目錄。本次將兩者一併納入版控，並在納入前修掉下列問題。

### 新增

- **`ops.sh` — 跨發行版的視覺化操作選單**
  - 純 POSIX sh，零相依：不需要 `dialog` / `whiptail` / ncurses，Alpine 的
    busybox ash 與 CentOS 7 的舊 bash 都能直接執行。
  - 選單本身不碰系統設定，只做「導覽 + 前置檢查 + 呼叫」，實際變更全在底層腳本裡。
  - 危險動作先攤開再確認：換埠會自動先跑一次乾跑印出「將要動到什麼」；
    換源需輸入完整的 `YES`。
  - `doctor` 模式可單獨執行，有必要套件缺失時回傳 exit 1，可寫進巡檢排程。
  - `i` 選項依偵測結果組出該機器實際需要的安裝指令並執行。
  - 沒有 UTF-8 locale 時自動退回 ASCII 框線；非終端機執行會擋下並提示改用底層腳本。
- **`README.md`** — 快速開始、目錄結構、支援矩陣、相依套件、降級行為對照表、安全須知。
- **`SSH/README.md`** — 兩支腳本的完整說明：換埠三步流程、socket activation /
  OpenSSH 版本差異 / SELinux / `Port` 累加特性這四個坑、看門狗機制、判讀門檻表、
  busybox 相容處理對照表、疑難排解。
- **`.gitignore`** — 擋掉編輯器與工具的本機狀態檔。
- `selfheal-ssh.sh` 的 `debug` 模式新增偵測結果輸出：實際採用的 `ps` 寫法、
  認證日誌來源、`who` 是否走推估模式。

### 修正

- **`ps -eo pid=,etime=,args=` 語法錯誤導致階段分類靜默失效。**
  procps 會把「`,etime=,args=`」整串當成 pid 欄的**標題**，結果只印出 pid 一欄。
  指令回傳成功、輸出看起來正常，但行程標題全空，使「已登入 / 認證中」的分類
  在所有 procps 系統上都退回粗略模式——而這正是分辨「50 個人在用」與「正在被
  爆破」的關鍵。改為逐欄 `-o`，並加上四種寫法（procps 兩種、busybox 兩種）的
  能力探測，全部失敗時在畫面上標紅說明而非假裝正常。
- **`flock` 不存在時整輪不採集。**
  原本 `flock -n 9 || { echo "已有診斷程序執行中"; exit 0; }` 在沒有 `flock` 的
  最小安裝上會因 command-not-found 觸發 `||`，看起來像正常跳過，實際上從未採集。
  改為先確認指令存在再取鎖。
- **`hostname -I` 在 busybox 上靜默回傳空字串。**
  原本的 `|| echo '<主機IP>'` 接在 `awk` 之後永遠不會觸發，導致換埠後的測試提示
  少了主機 IP——那是整段提示裡最關鍵的一行。改為 `ip -4 -o addr` → `ifconfig`
  逐層退回。
- 「登入失敗數 = 0」不再有歧義：區分「讀不到認證日誌」與「來源正常但確實 0 筆」。
  前者會明講這代表讀不到而非沒被攻擊。
- `ssh-port.sh` 乾跑不再列出 SELinux 停用時根本不會執行的 `semanage` 步驟。
- 缺少 `date -Is` 時的退回路徑補齊（看門狗腳本內原本沒有）。

### 變更

- **`selfheal-ssh.sh` 由 bash 改寫為 POSIX sh**，Alpine 不再需要 `apk add bash`。
  移除的 bash 專屬語法：
  - process substitution → 用分隔標記把兩份輸入串成單一資料流餵給 awk
  - here-string（`<<<`）→ `printf | while read`
  - `$'\e[..m'` → `printf '\033[..m'`
  - `grep -Fxf <(...)` → awk 取交集
- **外部指令一律先探測能力再用**，探測不到就降級並在輸出中寫明降級了什麼，
  不靜默失效：

  | 情況 | 行為 |
  |---|---|
  | 沒有 `ss` | 退回 `netstat` |
  | 沒有 procps 版 `ps` | 階段分類降級為粗略統計並標紅 |
  | 沒有 `journalctl` | 依序找 `secure*` / `auth.log*` / `messages*` / `logread` |
  | 沒有 `flock` | 跳過重入保護，照常採集 |
  | 沒有 `who` 或系統不維護 utmp | session 數改由 sshd 行程標題推估 |
  | busybox `date` 不支援 `"1 hour ago"` | 改用 `-d @epoch` → `-D %s` → 退回現在時刻 |
  | busybox `watch` 不支援 `-t` / `--color` | 解析 `--help` 後只帶支援的選項 |
  | busybox `last` 不支援 `-Fa` | 先試完整格式，再退陽春格式 |
  | busybox `stat -c %s` 不可用 | 退回 `wc -c` |

- **Alpine 正式納入支援矩陣**：服務名 `sshd`、OpenRC 三路服務狀態判斷、
  認證日誌涵蓋 `/var/log/messages` 與 busybox 的 `logread` 環狀緩衝。
- 未知發行版改為實際探測 systemd unit 名稱，而非硬猜 `ssh` / `sshd`。
- `sshd 行程清單` 在 procps 可用時仍輸出 ppid / user / stat 欄位，
  busybox 上才退回精簡欄位。

### 移除

- `.claude/`（Claude Code 的本機權限快取，與專案無關）。

### 已知限制

- POSIX 相容性以靜態檢查確認（逐項移除已知 bashism 並掃描殘留），
  **未在真實的 ash / dash 上執行過**——驗證環境只有 bash。
  要完全確認請在 Alpine 上執行 `./ops.sh doctor`。
- Alpine 若未啟用 syslog，登入失敗統計會是 0（連線層統計不受影響）。
  `doctor` 會明確指出這是「讀不到」而非「沒被攻擊」。

---

## [0.1.0] - 2026-07-29

### 新增

- `LICENSE`（MIT）。

[1.0.0]: https://github.com/cxhil-yixian/OPS-command/commit/eadb122
[0.1.0]: https://github.com/cxhil-yixian/OPS-command/commit/8504221
