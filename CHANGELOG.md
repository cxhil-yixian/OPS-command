# 變更記錄

本檔案記錄本專案所有值得注意的變更。

格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本號依循[語意化版本](https://semver.org/lang/zh-TW/)。

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
