# 變更記錄

本檔案記錄本專案所有值得注意的變更。

格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本號依循[語意化版本](https://semver.org/lang/zh-TW/)。

每個版本都有對應的 git tag（`v1.9.0` 這種形式），標題上的版本號連到它與前一版的差異。

---

## [1.13.0] - 2026-09-15

fail2ban 圖形化：機制圖寫進 README，另外新增 `fail2ban.sh report` 看「這台實際做了哪些事」。

### 新增

- **`FAIL2BAN/README.md`「fail2ban 到底做了哪些事」**：三張 Mermaid 圖，GitHub 上直接畫出來。
  - **從日誌到防火牆**：sshd 寫日誌 → filter 比對 → ignoreip → findtime / maxretry 計數 →
    Ban 寫資料庫 → banaction → 防火牆規則 → bantime 到期 Unban，以及重啟時的 Restore Ban。
    四個「服務是綠的但一個都擋不住」的點用紅色標在對應的那一步（讀不到日誌、沒有 jail、
    port 對不上、banaction 與防火牆不符 / reload 沖掉規則）。
  - **`fail2ban.sh` 碰的是哪一段**：子命令分四組（改封鎖狀態 / 改設定 / 查詢 / 檢查），
    實線改狀態、虛線唯讀；腳本與防火牆之間沒有實線。細節另附一張「命令 × 碰到的東西」對照表。
  - **一個 IP 走一遍**：用 `enable-sshd` 實際寫入的 maxretry 5 / findtime 600 / bantime 3600，
    示範 findtime 是往前滑動的視窗——每 3 分鐘試一次的慢速爆破永遠到不了 5 次。
- **`fail2ban.sh report`**（封鎖選單 `r`）：終端機摘要 + 單檔 HTML，回答七件事——時間軸、
  Found 與 Ban 的比例（含「只被偵測、從沒被封」的慢速爆破）、慣犯排行、目前封鎖中與剩餘時間、
  各 jail 分布、封鎖中的 IP 在防火牆規則裡找不找得到、攻擊者試了哪些帳號。
  - **全程唯讀**，不需要 fail2ban 以外的套件。伺服器沒在跑時略過「目前封鎖中」與防火牆比對，
    其餘照日誌算。`--days <N|all>`（預設 7；2 天以內每小時一格，否則每天一格）、`-o <檔案>`。
  - 讀 fail2ban 日誌的**輪替檔**（`.1`、`.2.gz`…），沒有檔案才退回 journal；認證日誌讀
    `secure*` / `auth.log*`，都沒有才退回 `journalctl _COMM=sshd`。每個來源各涵蓋到哪一天寫在
    報告最下面，日誌比範圍短時開頭直接標出「前面是沒有資料，不是沒有攻擊」。
  - 到期時間優先讀 sqlite 資料庫（`sqlite3` CLI，沒有就用 fail2ban 自己的 python），
    讀不到才退回「日誌的 Ban 時間 + jail 的 bantime」，表格上註明來源。
  - 帳號用 sshd 的 pid 去重（一條連線寫的好幾行只算一次），依「試過它的來源數」排序；
    sshd 回報過「密碼錯誤」的帳號標為存在。
  - **白名單（ignoreip）裡的來源不算攻擊者**：帳號排行與「不計數的連線」都先排除（CIDR 照樣
    做網段比對），並註明排除了幾筆。沒有這一步，管理員自己打錯一次密碼、測一下埠，都會被畫成攻擊。
  - 範圍內的 Ban 全都沒有對應的 Found 時（手動封鎖，或 Found 在範圍之前），直接這樣講，
    不印「每 0.0 次 Found 換一次 Ban」這種沒有意義的比例。
  - **另外列出 fail2ban 預設不計數的連線**：連上就斷的掃描、認證前斷線、協商失敗、非 SSH 探測，
    各自的次數與來源數，以及「從沒出現在 Found / Ban 裡」的來源有幾個。說明依 sshd jail 實際的
    `mode` 走（normal 時講清楚這些一次都不會算、改 aggressive 的代價）。起因是在測試機上實測：
    只收金鑰的 22 埠半小時內 14 筆這類紀錄，`fail2ban-regex` 用 normal 一筆都沒比對到、
    aggressive 全中——沒有 Found 不代表沒人在試。
  - **HTML 是單一檔案**：內嵌 SVG，不載入 JS 函式庫、不連 CDN，離線可開、可轉寄；亮 / 暗色跟
    系統設定走；時間軸每根長條都有 hover 提示並附表格檢視。攻擊者可控的字串（帳號名稱）一律
    HTML 跳脫——測試資料裡放了 `<script>alert(1)</script>` 當帳號名稱驗過。
  - 日期換算全部在 awk 裡自己做（days_from_civil），不用 `date -d` 也不用 gawk 才有的
    `mktime` / `strftime`。同一份測試資料在 gawk 4.0、mawk（Debian 12）、busybox awk
    （Alpine 3.20）上跑出完全相同的總計。

### 修正

- **`ban -t` 在 fail2ban 0.11.2 上會把 `--time` 與秒數也當成 IP 封下去。** 0.11.2（EPEL 7）
  不支援 `banip --time`，但它不報錯，而是把每個參數都當成 IP：目標 IP 照樣進清單（時長是
  jail 預設），另外多出 `--time`、`600`（或 `-1`）兩筆垃圾，日誌出現
  `Failed to execute ban … INVALID_ADDR: -1`。原本的能力探測只看「目標 IP 有沒有進清單」，
  於是誤判成支援——指定的時長靜靜地沒生效，畫面上也沒有任何警告。改成看清單裡有沒有多出
  `--time`：有就把垃圾解掉、降級成 jail 的 bantime 並明講。這是在測試機上實際手動封鎖時抓到的。
- `report` 只收長得像 IP 的紀錄，上面那種 bug 留在日誌裡的 `Ban 600` 不會被算成一個來源。

### 變更

- `OPS_VERSION` 升到 `1.13`；主選單 `b` 那一列、根 `README.md` 的選單示意與目錄結構補上「報告」。

### 已驗證

- **測試機實裝**（CentOS 7.9、Hyper-V VM）：`install`（EPEL 7 已封存，epel-release 7-11 的 metalink
  仍指得到封存鏡像，照原樣裝得起來）→ `allow` → `enable-sshd`（自動取到 `22,24672` 與
  `firewallcmd-rich-rules`）→ `doctor` 全數通過；手動封鎖的 IP 在 firewalld rich rule 裡都找得到。
- **`report` 在真實攻擊資料上跑過**：gawk 4.0、sqlite 3.7.17、firewalld。24 小時的那一份實際內容：
  Found 45 次 / Ban 13 次 / 9 個來源（2 個被封 2 次以上）、封鎖中 1 個（到期時間讀自 sqlite，
  且在 firewalld rich rule 裡找得到——第 6 項的比對是對真的規則做的）、攻擊者試了 23 個帳號。
  最值得看的是最後一段：**同一段時間裡有 948 次連線是 fail2ban 預設不計數的**（認證前斷線 495、
  連上就斷的掃描 446），其中 67 個來源從頭到尾沒進過 Found / Ban。
- 第一次跑抓到四個測試資料不會觸發的問題，都已修正：
  - Y 軸刻度原本是「最大值切 4 等分」，最大值 5 時標籤變成 0 / 1 / 3 / 4 / 6，長條看起來對不上。
    改成 1 / 2 / 5 × 10ⁿ 的整數間隔。
  - 目前封鎖中為 0 時磁磚是空白（未初始化的變數印成空字串）。
  - 沒有封鎖中的 IP 時不會去讀資料庫，資料來源卻寫「沒有資料庫」——改成講清楚是「不需要讀取」。
  - 管理員自己的連線被算成攻擊者（見上面的白名單排除）。
- **測試資料**：合成的 fail2ban 日誌（含 `.gz` 輪替）、認證日誌、sqlite 資料庫與模擬 0.11.2 行為的
  假 `fail2ban-client`，涵蓋尖峰、慣犯、慢速爆破、白名單、永久封鎖、Restore Ban、掃描類連線與
  藏了 `<script>` 的帳號名稱。HTML 在亮色 / 暗色 / 400px 手機寬度下截圖檢查過，沒有水平溢出。

---

## [1.12.0] - 2026-09-15

新增常用軟體安裝：`APPS/apps.sh`，主選單按 `a`。

### 新增

- **`APPS/apps.sh`** —— 安裝 `docker` / `nc` / `tcpping` / `mtr` / `nginx`，POSIX sh，子命令
  `status` / `install <名稱...|all>`，共用 `-y` 免確認與 `-n` 乾跑。
  - **docker 走官方 `get.docker.com`**：`curl -fsSL https://get.docker.com -o get-docker.sh`
    再 `sh ./get-docker.sh`。落地成檔案、先驗內容（開頭 `#!` 且含 `do_install`）才執行，
    放在用完就刪的暫存目錄。它不支援的發行版改走別條路：Alpine 用 `apk add docker`；
    AlmaLinux / Oracle Linux 這類它不認得的 RHEL 系（get-docker.sh 只認 centos / rhel /
    rocky / fedora，其他會回 `Unsupported distribution`）改用 Docker 文件的 docker-ce repo 做法。
    `OPS_DOCKER_MIRROR` 可帶 `--mirror Aliyun` / `AzureChinaCloud`。
  - **其他四項依套件管理器對應套件名**，不依發行版名稱——`ID_LIKE` 沒寫的衍生版一樣對得上：
    `nc` 在 RHEL 系是 `nmap-ncat`、Debian / Alpine 系是 `netcat-openbsd`；`mtr` 在 Debian 系
    用 `mtr-tiny`（避開 GTK）；CentOS / RHEL 7 的 nginx 在 EPEL，會先裝 `epel-release`。
    除了 apt / dnf / yum / apk，另外對了 zypper / pacman 的套件名（未實測）。
  - **tcpping 不在任何套件庫裡**：先裝 `traceroute`（它實際是靠 `traceroute -T` 送 TCP SYN；
    Alpine 的 busybox traceroute 不支援 `-T`，改裝 `tcptraceroute`），再從 GitHub 下載
    deajan/tcpping 的 **`v2.7`** 到 `/usr/local/bin/tcpping`——釘 release tag 不抓 `master`
    （那是 `-dev` 版）。
  - **已經裝好的略過**。get-docker.sh 對已裝 docker 的機器會停 20 秒並重設 repo 設定，那不是
    「安裝常用軟體」該順手做的事。
  - **裝之前把後果講完**：get-docker.sh 會自己 `enable --now docker`；EOL 發行版上它會停
    10 秒印 DEPRECATION WARNING（先講，免得以為當掉）；RHEL 8+ 已裝 podman 會跟
    `containerd.io` 衝突；docker 的 `-p` 會繞過 firewalld / ufw；Debian 系裝 nginx 會立刻
    啟動去搶 80 埠，80 埠已有人在聽就先標紅。
  - **裝完逐項驗證指令真的在**，不以套件管理器的回傳碼為準；沒裝上的列出來並回傳非 0。
- **`ops.sh` 主選單新增 `a) 進入安裝選單`**：一項、全部、或自選多項。說明與確認一律留在
  `apps.sh` 裡一份——跟時間、壓測選單同樣的分工。遠端模式的自動更新與 `u` 會一併抓
  `APPS/apps.sh`，`doctor` 的腳本清單也列上它。
- **[`APPS/README.md`](APPS/README.md)**，以及根 `README.md` 的目錄結構、選單示意、
  支援矩陣、安全須知、環境變數。

### 變更

- `OPS_VERSION` 升到 `1.12`。`ops.sh` 開頭註解的工具目錄清單補上 `TIME/`（1.11.0 漏改）與 `APPS/`。

### 已知限制

- 驗證是在 docker 容器裡**實際安裝**：Debian 12 / Rocky 9 / Alpine 3.20 裝 nc、tcpping、mtr、
  nginx（tcpping 都實際量到 1.1.1.1:443 的延遲），Ubuntu 24.04 與 AlmaLinux 9 連 docker 一起裝，
  分別走過 get-docker.sh 與 docker-ce repo 兩條路徑。容器沒有 systemd，**「裝完服務會不會自動
  啟動」沒有驗到**。CentOS 7 的官方 repo 已下線，只驗了 `status` 與乾跑（EPEL 判斷、EOL 提示）。
  zypper / pacman 沒有實跑過。

---

## [1.11.0] - 2026-08-19

新增時區與系統時間設定：`TIME/time-set.sh`，主選單按 `t`。

### 新增

- **`TIME/time-set.sh`** —— 時區與系統時間設定，POSIX sh，子命令 `status` / `list` /
  `set-zone` / `set-time` / `sync` / `ntp on|off` / `rtc` / `doctor` / `install`，
  共用 `-y` 免確認與 `-n` 乾跑。設計上把幾件事分清楚：

  - **時區與時間是兩件事**。`set-zone` 不動絕對時刻，`set-time` 才會。log 時間戳差
    8 小時通常是時區問題，用 `set-zone` 就沒有下面那些風險。
  - **改時鐘之前先算差距與方向**，再依方向講後果：往回撥會讓 cron / systemd timer 把
    已經跑過的工作再跑一次、DB 時序錯亂；往前撥會讓該跑的被跳過、session 立刻過期。
    兩者共通的是 TLS 憑證的有效期是絕對時間，差太多連線直接失敗。
  - **不順手啟動或關閉校時服務**（同 `stress-test.sh` 對 chronyd 的態度）。`set-time`
    遇到 chronyd / ntpd / systemd-timesyncd 正在跑會停下來問要不要先停用；
    **`-y` 免確認模式一律拒絕**，要使用者先明確 `ntp off`——停用別人的校時服務是有
    後果的決定，不該因為加了 `-y` 就替他做掉。`install` 裝完 chrony 也不會順手啟動。
  - **`ntp on` 先警告偏差**：目前偏差多少，服務起來就會跳多少（1.10.3 那台 chronyd
    停用、時鐘快 8 小時的 VM 就是這個情況）。
  - **設完一定回讀比對**。`date -s` 各家實作吃的格式不同，而且失敗時常常「回傳 0 但
    沒改到」。四種寫法依序試（`timedatectl set-time` → `date -s 'YYYY-MM-DD HH:MM:SS'`
    → `date -s MMDDhhmmCCYY.ss` → `date MMDDhhmmCCYY.ss`），每一種都回讀，差超過
    120 秒就換下一種，四種都不行才回報失敗，不留下「看起來成功」的假象。
  - **`doctor` 專門查「改了但不會生效 / 會被拉回去」**：容器（沒有自己的時鐘）、
    缺 `CAP_SYS_TIME`、沒有 tzdata、同時有兩套校時服務在跑、RTC 記本地時間、
    以及虛擬機主機端的時間同步（Hyper-V / VMware / KVM 各自給出關閉方式）。
- **`ops.sh` 主選單新增 `t) 進入時間選單`**，標頭多一列「時間 / 時區」。時間選單的
  參數（時區關鍵字、目標時間、NTP 伺服器）先問完再帶進底層腳本，說明與確認一律留在
  `time-set.sh` 裡一份——跟壓測選單同樣的分工。
- **[`TIME/README.md`](TIME/README.md)**，以及根 `README.md` 的目錄結構、選單示意、
  支援矩陣、相依套件、安全須知、環境變數。
- 相鄰文件的交叉引用：`SSH/README.md` 的檔案位置表補上 `time-ops.log`；
  `STRESS/README.md` 的 `ntp` 一節標明「那是壓力測試，要真的改時間請走 `TIME/`」；
  `FAIL2BAN/README.md` 的封鎖時長一節補上「到期時間是按系統時鐘算的，改時鐘會連帶影響」。

### 修正

- **`time-set.sh` 對 CentOS 7 的 `timedatectl` 探測**。systemd 219 根本沒有
  `timedatectl show`（回「Unknown operation show」），但 `set-timezone` / `set-time` /
  `set-ntp` 都在。原本拿 `show` 當「timedatectl 能不能用」的探測，會把整個 RHEL 7
  誤判成不能用而退回手改檔案——那條路徑不處理硬體時鐘，也不會擋「NTP 開著不准設時間」。
  改成用 `status` 探測「能不能設定」、用 `show` 探測「能不能查屬性」，兩者分開；
  沒有 `show` 的機器改解析 `LC_ALL=C timedatectl status`（強制 C locale，否則標籤會被
  翻譯；新舊版的 `NTP synchronized` 與 `System clock synchronized` 兩種標籤都比對）。

### 已知事項

- **`/etc/localtime` 排在 `timedatectl` 前面**當作時區的來源。實測 CentOS 7：直接換掉
  `/etc/localtime` 之後 `date` 立刻是新時區，但 `timedatectl` 在那之後一小段時間仍回
  舊值（`systemd-timedated` 快取著，`daemon-reexec` 也不會讓它更新，要等它閒置退出）。
  以「程式實際看到的」為準才不會跟現實對不上；兩邊講的不一樣時由 `doctor` 指出來。
- 支援矩陣的 `time-set.sh` × CentOS 7.9 標 ✅ 的範圍：`status` / `list` / `doctor`、
  時區變更的兩條路徑（`timedatectl` 與直接改檔案，都實機跑過、回讀確認過並已還原）、
  `set-time` 的格式解析與差距計算、乾跑、以及「校時服務在跑時擋下 `-y`」。時間換算與
  回讀比對的退路邏輯是用替身模擬各種 `date` 實作驗的（含「回傳 0 但沒設到」的假成功）。
  **`set-time` 真的把時鐘改下去，以及 `sync` / `ntp on|off` / `rtc` 的實機行為尚未有
  系統地驗證**；其他發行版全部未驗證。

---

## [1.10.4] - 2026-08-19

文件：Windows 的第一次執行順序，以及 `ntp` 對 chronyd 的態度。

### 變更

- **`WINDOWS/README.md` 加一節「第一次在 Windows 上跑：建議的順序」。** 這支從來沒有
  在 Windows 上實際執行過，第一次跑的順序很重要：一般帳號 → `S` 檢查現況 → 提權流程
  → **最後**才碰換 RDP Port。附上三種常見失敗的長相（TLS 1.2、執行原則、提權視窗一閃
  就沒），以及「只能透過 RDP 連進去又沒有主控台的機器，做到第 3 步就停」。
- **根 `README.md` 的安全須知補上 chronyd 的行為**：`ntp` 測完不會順手啟動原本沒在跑的
  chronyd（1.10.3 的修正），並附上那個實測案例——一台 chronyd 停用、時鐘快 8 小時的 VM，
  順手啟動它會讓時間直接跳 8 小時。

---

## [1.10.3] - 2026-08-19

`ntp` 不再順手幫你把 chronyd 打開。

### 修正

- **`ntp` 測完會啟動 chronyd，即使它本來就沒在跑。** 還原邏輯寫的是「不管怎樣都把
  chronyd 拉回來」，前提是「它本來在跑」——對停用 chronyd 的機器來說，那是壓測順手
  改了系統狀態，而且後果可能很大：實測一台 chronyd 停用、**時鐘快 8 小時**的 VM，
  測試結束時啟動 chronyd，`makestep` 直接把時間跳了 8 小時（報告上還印著「已還原
  (現在 21:05:51)」，實際時鐘已經是 13:05:5x）。

  現在測試前先記 `NTP_WAS_ACTIVE`，兩條路徑對稱：

  | 測試前 chronyd | 測試中 | 測試後 |
  |---|---|---|
  | `active` | 停掉再撥時鐘 | 啟動 + `makestep` 修殘差 |
  | `inactive` | 不用停 | **維持停用**，時鐘由 `date -s` 確定性扣回 |

  chronyd 沒在跑時另外警告一句「這台的時鐘沒有人在校正」——那通常是該處理的問題，
  但不該由壓測替你決定。
- **摘要的「現在 XX:XX:XX」可能不是最終時間。** `chronyc makestep` 回的 `200 OK` 只代表
  指令收到了，真正的跳躍要等 chronyd 拿到有效測量；偏差大時會在報告印完之後才跳。
  報告補一行註記講這件事（`inactive` 那條路徑沒有這個問題，時間是 `date -s` 直接扣的）。

### 變更

- 支援矩陣的 `stress-test.sh` × CentOS 7.9 改成純 **✅**：五項在兩台互補的環境上全部
  實機驗過（一台實體機、一台 Hyper-V VM，後者走 `ops.sh` 選單），`ntp` 是最後一項。

---

## [1.10.2] - 2026-08-19

第二台實機（Hyper-V VM）跑完之後的三個補強。

### 變更

- **`ram` / `swap` 的監看列補上時間戳**，跟 `cpu` 一致。`DUR=120` 會印四十幾行，
  沒有時間就沒辦法跟 `dmesg` 或應用的日誌對時間。
- **`ram` 摘要會講「測試期間吃掉多少 swap」。** 這一項的目標是吃記憶體而不是逼出換頁，
  真的換到 swap 就表示 `RAM_PCT` 對這台太貪心，`bogo ops` 裡混了換頁的代價。
  實測一台 RAM 3.7GB 的 VM，80% 就已經把 SwapFree 從 1774MB 吃到 1282MB。
- **`>2GB/s 判無效` 的警告現在直接給你該用多大的測試檔。** 同一台 VM 用 4096MB 測試檔
  （已經大過 guest 的 3789MB RAM）跑循序讀，還是量出 5813MiB/s —— 因為要壓過的是
  **host** 那層 cache，host 的記憶體通常比 guest 大得多。警告後面補一行
  `DISK_SIZE_MB=<guest RAM × 2> 開始試`，跟其他警告一樣「能處理才叫警告」。

### 已驗證

- 這一輪是走 `ops.sh` 選單跑的（`t` 改 120 秒 → `6` 全部），完整驗到選單這條路徑：
  參數帶進子腳本、預估耗時（顯示 9 分鐘、實際 8 分 13 秒）、執行前的攤開與確認。
- **`swap` 這次真的逼出換頁了**：34 次取樣有 32 次在換頁，換出峰值 346188 KB/s、
  平均 105479 KB/s，最低可用 11MB 且沒有觸發 OOM——sshd 的保護與還原都正常。
- 虛擬機分支（1.10.1 新加的 `IS_VM`）確認可用：報告印
  `繞不過 hypervisor (microsoft) 的`，循序讀取被正確判成 `!! 無效 (host cache)`。

---

## [1.10.1] - 2026-08-19

第一次實機跑壓測抓到的三件事。

### 修正

- **實體機的「虛擬化」那行會印成兩行。** `systemd-detect-virt` 在非虛擬機上會印 `none`
  但 **exit 1**，而報告寫的是 `$(systemd-detect-virt 2>/dev/null || echo '未知')` ——
  兩邊都執行，於是報告變成 `none` 換行 `未知`。改成只有「沒有輸出」才退回未知，
  回傳碼不管。這台是 KVM，所以開發時完全踩不到。
- **磁碟的 cache 判讀在實體機上是錯的。** 「測試檔要大過 RAM」「頻寬 >2GB/s 就是
  host cache、此數據無效」這兩條的前提都是「guest 的 `direct=1` 繞不過 hypervisor 的
  cache」，實體機的 `direct=1` 是真的直達裝置。現在用 `systemd-detect-virt` 分流：
  - 實體機不再警告測試檔小於 RAM（無關）
  - 實體機的 >2GB/s 不判「無效」，改成提醒確認是不是量到 RAID 卡 / 裝置快取
    （NVMe 本來就跑得到）
  - 報告開頭的註記與摘要的判讀提示都跟著換成對應版本

### 新增

- **`ram` / `swap` 事前就估「`DUR` 夠不夠」。** 實機跑 `DUR=10 all` 的結果：`ram` 的
  bogo ops 是 0（25578MB 在 10 秒內碰不完一輪）、`swap` 整段沒有任何換出（RAM 都還沒
  吃滿）。兩者原本都只在跑完之後才補一句，事前講才來得及改 `DUR`：
  - `ram`：配置量 ÷ 2GB/s（實測 25578MB / 11.9s ≈ 2.1GB/s）就是至少需要的秒數
  - `swap`：先估填滿 RAM 要多久，`DUR` 不到它的兩倍就警告，並建議一個值

### 變更

- 支援矩陣的 `stress-test.sh` × CentOS 7.9 從「⚠️ 只有 1.5.0」改成「✅ 除 `ntp`」，
  並把實機驗到什麼寫清楚（`cpu` / `ram` / `disk` / `swap` 都正常，磁碟第五輪的
  `psync + --sync=1 + --direct=1` 確認 fio 吃得下）。`ntp` 仍未實跑。

---

## [1.10.0] - 2026-08-19

Windows 也有一行指令了。

### 新增

- **`WINDOWS/ops-win.ps1`** —— Windows 的一行指令進入點，對應 Linux 那邊的
  `bash <(curl …)`：

  ```powershell
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  irm https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/WINDOWS/ops-win.ps1 | iex
  ```

  第一行是 Windows PowerShell 5.1（Win10/11 內建）需要的：它預設不啟用 TLS 1.2，
  而 GitHub 只收 1.2 以上，不設就是一句「無法建立 SSL/TLS 通道」。

  它只做三件事：把 `Win_Admin_Tool.ps1` 下載到 `%ProgramData%\OPS-command\`、
  驗一下內容不是被代理攔截的網頁、然後用 `-File` 執行它。**為什麼要落地而不是直接
  把主腳本 `iex` 掉**：
  - 提權需要實體路徑。`Start-Process -Verb RunAs` 只能指定檔案，沒有「把這段程式碼
    交給新的 elevated 行程」的辦法，而管線跑進來的腳本 `$PSCommandPath` 是空的。
  - RDP 換 port 的狀態、還原腳本與看門狗記錄本來就落在 `%ProgramData%\OPS-command\`。
  - 主腳本是 UTF-8 **with BOM**，字串化之後餵給 `iex` 在 5.1 上不保證解析得過。
  - `ops-win.ps1` 自己則刻意是 UTF-8 **無 BOM**——它就是要被 `iex` 的那一支。

  **下載失敗不會默默用舊檔**：`%ProgramData%` 一般使用者也寫得進去，跑上次留下的副本
  等於相信它沒被動過手腳，所以要用得明確加 `-UseCached`（或 `OPS_USE_CACHED=1`）。
  來源可用 `OPS_RAW_BASE` / `-BaseUrl` 指到 fork 或內網鏡像，跟 Linux 那邊同名。

### 修正

- **`Win_Admin_Tool.ps1` 的提權在沒有實體路徑時會壞掉。** `Restart-AsAdmin` 直接用
  `$PSCommandPath` 組 `-File`，而用管線跑起來時那是空字串 —— 等於 `-File ""`。
  現在改成先問 `Get-SelfPath`：有路徑就用；沒有就把自己的原始碼
  （`$MyInvocation.MyCommand.ScriptBlock`）寫到 `%ProgramData%\OPS-command\` 再
  `RunAs`；連寫都寫不進去才放棄，並叫使用者自己開系統管理員視窗，而不是靜靜地失敗。

### 變更

- 根 `README.md` 的快速開始多一段 Windows 一行指令；開頭那句壓力測試的說明
  漏改的「/ 網路」補掉（1.6.0 已移除）。
- **支援矩陣改成講實話。** 加了符號說明（✅ 實機驗證過／⚠️ 應該能跑但沒驗／❌ 不支援／
  ❔ 從未執行過），`stress-test.sh` 在 CentOS 7.9 那格從 ✅ 降成「⚠️ 只有 1.5.0」——
  1.6.0 之後的每一版都只用替身腳本驗過流程，真機沒跑過就不該標 ✅。另外補上 Windows
  兩個進入點的狀態（都是 ❔），它們從來沒有在 Windows 上執行過。
- `OPS_VERSION` 升到 `1.10`。

### 已知限制

- **這條路徑一樣沒有在 Windows 上實測過**（`WINDOWS/` 底下的東西從來沒有）。只有實機
  能確認的有三點：`irm | iex` 對無 BOM 檔案的解析、`Invoke-WebRequest -OutFile` 之後
  `Unblock-File` 有沒有真的解掉 MOTW、以及管線跑法下的提權
  （`$PSCommandPath` 為空 -> 寫檔 -> `RunAs`）。

---

## [1.9.0] - 2026-08-19

磁碟佇列深度可調，CPU 測試看得到網卡流量。

### 新增

- **`DISK_QD`（預設 `32`，1-256）** —— 磁碟前四輪的佇列深度。32 是「把盤餵飽、量得到
  吞吐上限」的常見值，但那也表示單一 IO 的延遲被藏在佇列後面；想看淺佇列的樣子就調小，
  想確認深佇列還有沒有餘裕就調大。**超過 64 會警告**：多數雲端磁碟在那之後 IOPS 早就
  到頂，只有延遲線性往上加，於是「p99 很難看」變成是自己造成的。第五輪的同步延遲固定
  `iodepth=1`，那正是它存在的理由，不受這個參數影響。
- **CPU 測試與壓力前基準都帶上網卡收發** —— 有人在灌流量的話，軟中斷會吃掉一塊 CPU，
  bogo ops 就不是這台的真實算力，而報告上原本完全看不出來。現在：
  - `cpu` 的監看列多兩欄：`rx=118KB/s tx=154KB/s`
  - `0/5` 基準與摘要的「基準」列多一段：`網卡 收 1.2MB/s 發 2.3MB/s`
  - 測試期間峰值 ≥10MB/s 才會警告（`-> 這台不是閒著的，軟中斷會分掉 CPU，bogo ops
    偏低是正常的`）。閒著的機器完全安靜，不製造常態噪音。
  - `_nic_bytes` / `_hr` 這兩個函式是 1.6.0 隨網路測試一起刪掉的，這次因為上面的理由
    放回來；另外加了 `_peak_rate`，從監看列的人類單位（`1.2MB/s`）換算回 bytes 取峰值
    —— 跟 fio 那個 BW 換算同一招，只比數字不看單位的話 MB 與 KB 會被當成同一個量級。

### 變更

- 壓測選單 `1) CPU` 與 `3) 磁碟讀寫` 的執行前說明同步（網卡警告、`DISK_QD`）。
- `OPS_VERSION` 升到 `1.9`。

---

## [1.8.1] - 2026-08-19

清掉文件裡的真實 IP，把磁碟那條常態警告降噪。

### 修正

- **文件範例裡的真實 IP 換成 RFC 5737 的文件保留網段。** `FAIL2BAN/README.md` 的
  自鎖示範用的是這台機器實際的 SSH 來源（`61.219.171.56` 與涵蓋它的 `/16`），
  CHANGELOG 1.2.1 那則 `ssh_peers` 的修正記錄裡也有同一個位址，外加兩個當時正在
  爆破的來源位址。示範的效果不變，但這些是真實可路由的位址，不該躺在公開 repo 裡：
  - 自己的來源 → `203.0.113.56`、網段 → `203.0.113.0/24`
  - 兩個攻擊來源 → `198.51.100.7` / `198.51.100.112`
  - `fail2ban.sh` 四處說明訊息裡的 `1.2.3.4` → `203.0.113.5`（前者是真的有人在用的位址）
- **「測試檔 < RAM」不再無條件進警告區。** 自動大小的上限是 4096MB，所以在記憶體
  大的機器上這條每次都會觸發，每份報告都掛著同一條沒人能處理的警告，久了整個警告區
  就沒人看了。改成分三種：
  - 卡在 4096MB 上限、而這台空間夠 → **維持警告**，並附上該指定的 `DISK_SIZE_MB`（RAM×2）
  - 空間本來就開不大 → 降級成報告本文的註記，並建議把 `DISK_DIR` 指到別的檔案系統
  - 大小是使用者自己指定的 → 降級成註記（他已經知道自己在做什麼）

  原則是**警告區只放「你這次可以動手處理」的事**。頻寬 >2GB/s 那條有實際證據，不受影響。

---

## [1.8.0] - 2026-08-19

壓測數據終於有了對照組。

### 新增

- **`0/5` 壓力前基準（每次執行都會先跑）** —— 只有「壓力下」的數字，回答不了
  「這是壓出來的，還是它本來就長這樣」。開跑前先取 5 秒閒置樣本（`DUR` 比 5 小就取
  `DUR` 秒），記錄 steal、loadavg、可用記憶體、SwapFree 與換出速率，寫成報告的
  `0/5` 一節，摘要多一行「基準」，後面每一項再拿它對照：
  - `CPU  … steal 峰值 6.20% (壓力前 0.10%)`
  - `RAM  … 最低可用 178MB (壓力前 22355MB)`
  - 三種情況在這一節就先警告：壓力前 steal >5%（host 已在超賣）、壓力前就在換頁
    （記憶體本來就不夠）、壓力前可用記憶體低於總量 15%（會比預期更早 OOM）。
  - 換出速率直接讀 `/proc/vmstat` 的 `pswpout` 前後相減，不另外開 `vmstat`：整段基準
    只花 `mpstat` 那一次取樣的時間，也不多一個工具相依。沒有 `mpstat` 就只少掉 CPU
    那幾個數字，其餘照取。
- **`MON_SEC`（預設 3）** —— 監看的取樣間隔秒數（1-60）。固定 3 秒會漏掉短促的谷底
  （`MemAvailable` 一瞬間掉到底、換頁只噴一兩秒），要抓那種就調小。`cpu` 與 `swap` 的
  監看各自會扣掉 `mpstat 1 1` / `vmstat 1 2` 自己吃掉的那一秒，實際節奏才真的是 `MON_SEC`。

### 變更

- **`swap` 的換出不只給峰值** —— 加上平均與「幾次取樣有在換頁」，峰值一個數字看不出
  是全程在換頁還是只噴了一下：`換出峰值 420640 KB/s、平均 118203 KB/s，14/20 次取樣有在換頁`。
  壓力前就在換頁的話會附註原本有多少，不把既有的換頁算到壓測頭上。
- **整段測試都沒觀察到換出就直接警告** —— 那代表根本沒逼出換頁，這組數字說明不了
  swap 的表現，不該被當成「撐得住」。
- 摘要多「基準」一列，判讀提示多一條（先看基準那一列）。
- 壓測選單執行前的說明補上「開跑前會先取 5 秒基準」。
- `OPS_VERSION` 升到 `1.8`。

### 已知限制

- 基準取樣讓每次執行多 5 秒。這是刻意的固定成本，沒有開關——**「沒有對照的數字」
  正是這個工具最想避免的東西**。
- 基準的 CPU 數字仰賴 `mpstat`（sysstat）。缺了不會失敗，只是那幾欄空著。

---

## [1.7.0] - 2026-08-19

磁碟測試：補上同步寫延遲，測試檔大小可調。

### 新增

- **第五輪「同步延遲」** —— `randwrite` bs=4k **`iodepth=1` + `O_SYNC`**（`psync` 引擎）。
  前四輪的 `iodepth=32` 量的是「佇列排滿時的吞吐」，單一 IO 的延遲被藏在佇列後面；
  資料庫 commit、`fsync`、寫 WAL/binlog 感受到的卻是「發一個 IO、等它真的落地」的時間。
  吞吐好看但同步延遲很爛，是共享雲端儲存最常見的樣子，原本的四輪完全看不出來。
- **`DISK_SIZE_MB`** —— 自己指定 fio 測試檔大小（MB，至少 512；留空維持原本的
  「可用空間一半、上限 4096」）。超過可用空間會在跑之前擋下。
  「測試檔 < RAM」那個警告現在會順便把建議值（RAM 的兩倍）算好給你，
  因為要讓讀取數據不只是在量 KVM host 的 cache，唯一的辦法就是把檔案開到壓過那層 cache。

### 變更

- **磁碟四輪的順序改成「循序寫 → 隨機寫 → 循序讀 → 隨機讀」**（原本讀在前）。
  測試檔現在由第一輪的 direct 寫入建立：讀取與隨機模式需要檔案先存在，fio 會自己
  先 layout 一遍，而那一遍是 buffered 的——等於在開始量之前先把整個檔案灌進 host
  cache，既浪費時間又汙染後面的讀取數據。
- `DUR` 由四等分改為五等分（多了同步延遲那一輪）。
- 摘要的磁碟標籤改成四個字（`循序寫入` / `隨機寫入` / `循序讀取` / `隨機讀取` /
  `同步延遲`）。bash 的 `printf %-Ns` 是按 byte 補空白、中文字卻佔兩欄，長度不一致
  整排就會歪掉，所以五個標籤一律等長。
- 壓測選單 `3) 磁碟讀寫` 的說明與執行前的攤開內容同步（五輪、`DISK_SIZE_MB`）。
- `OPS_VERSION` 升到 `1.7`。

### 已知限制

- 同步延遲那一輪用 `psync` + `--sync=1`，**沒有在裝了 fio 的機器上實跑過**
  （這台沒有 fio，驗證是用替身腳本走完流程）。第一次跑請確認 fio 版本吃這組參數。
- 「測試檔要多大才壓得過 host cache」只能靠猜——host 的記憶體大小 guest 看不到，
  建議值 RAM×2 是經驗法則而不是保證。

---

## [1.6.0] - 2026-08-19

移除壓力測試的網路測試，只留本機五項。

### 移除

- **`baseline` / `traffic` / `mixed` 三個網路測試模式整組移除** —— 原本用 `wrk` 壓網站、
  `curl` 多路下載灌流量，旁邊記錄網卡收發與 TCP 狀態，回答「主機扛大量下載流量時網站
  還答不答得動」。連帶拿掉的東西：
  - `stress-test.sh`：`t_baseline` / `t_traffic` / `t_mixed`、`_wrk_run`、`_dl_worker` /
    `_dl_start` / `_dl_stop` / `_dl_bytes` / `dl_kill`、`_mon_net` / `_mon_peak` /
    `_net_finish`、`_split_csv` / `_nic_bytes` / `_cpu_snap` / `_hr` / `_hb`、
    `_net_setup` / `NET_CLEANUP`，以及 `URL` / `DL_URL` / `WRK_THREADS` / `WRK_CONNS` /
    `DL_WORKERS` / `HOST_HEADER` / `UA` / `INSECURE` 這幾個參數。報告的 `SUITE`
    （local / net 兩套摘要與兩套判讀提示）機制也跟著消失，只剩一套。**1052 行 → 708 行。**
  - `ops.sh`：壓測選單的 `7` / `8` / `9` 與「網路測試」小節、`stress_run` 裡問
    `URL` / `DL_URL` / 下載程序數的那一段（含 1.5.1 才加上的逐段驗證）、工具狀態列與
    安裝流程裡的 `wrk` / `curl`。
  - 文件：`STRESS/README.md` 的整個「網路測試」章節與參數說明（424 → 289 行）、
    根 `README.md` 相依表的 wrk / curl 兩列、安全須知裡 `URL` / `DL_URL` 那一條。
- **不再需要 `wrk`**，也就不用再為它處理 EPEL 與「base repo 沒有、要自己編」那串說明。
  壓測相依只剩 `stress-ng`、`fio`、`sysstat`、`procps`、`chrony`（`stress-ng` 仍在 EPEL）。

> 需要那段程式碼的話在 git 歷史裡：`git show d7ed115:STRESS/stress-test.sh`（1.5.1 的版本）。

### 變更

- 壓測選單的「本機壓測」小節改名為「項目」（只剩一組，不需要跟誰對比），主選單 `s`
  那一列與 `STRESS/README.md` 的選單截圖同步拿掉「網路」。
- `OPS_VERSION` 升到 `1.6`（README 的選單截圖同步改成 `v1.6`）。

### 未變更

- `cpu` / `ram` / `disk` / `swap` / `ntp` / `all` 六項的行為、參數（`DUR` / `RAM_PCT` /
  `DISK_DIR`）與報告格式完全不動。
- 1.5.1 加的中斷處理（`isleep` / `run_fg` / `cap_run` / `work_stop`）全部保留 ——
  `stress-ng` 與 `fio` 一樣需要它們。

---

## [1.5.1] - 2026-08-18

壓力測試的中斷處理與 OOM 保險。

### 新增

- **`RAM_PCT`（預設 `80`）** —— 記憶體壓測要吃掉「總記憶體」的百分之幾，1-100，
  壓測選單的 `p` 也能改，選單標頭與 `2) 記憶體` 那一列都會顯示目前值。
  超過 90 時腳本與選單都會先把後果列出來（page cache 被回收光、有 swap 的機器會變成
  狂換頁而不是乾脆 OOM、機器慢到 SSH 也卡、真的 OOM 時第一個被殺的通常是 stress-ng
  worker 自己），選單再多一道確認。`STRESS/README.md` 補了一段「能不能撐到 100%」。

### 修正

- **中斷不再被壓到整個 `DUR` 跑完**。`sleep "$DUR"`、`stress-ng … | tee`、`out=$(fio …)`
  都是前景子程序，而 bash 在等前景子程序時收到訊號會壓著不處理。終端機 Ctrl-C 沒事
  （整個 process group 一起收到），但訊號只送給腳本本身時——`timeout`、`kill`、systemd
  停服務——中斷會被延後最多 `DUR` 秒，這期間機器繼續滿載、下載繼續灌、`ntp` 的時鐘也
  繼續錯著（實測 `kill -TERM` 之後還要再等 13 秒 trap 才動）。改成一律丟背景再 `wait`
  （`isleep` / `run_fg` / `cap_run`），主流程停在 `wait` 就會被訊號立刻打斷，實測改為
  同一秒 `exit 130`。代價是背景工作的 SIGINT 是 ignored 且會被子程序繼承，所以
  stress-ng / fio / curl 一律改由 `work_stop` 明確 `_killtree`，兩種訊號來源行為反而一致。
- **中斷時 curl 不再變成孤兒繼續下載**。清理原本是 `kill $DL_PIDS`，殺掉的只是
  `_dl_worker` 的 bash 外殼，底下真正在下載的 curl 會被 init 收養、繼續灌到
  `--max-time 30` 為止，畫面卻已經印了「已清理」。改用既有的 `_killtree` 遞迴收乾淨
  （`dl_kill`）。順帶補上 `kill -9` 之後的收屍，否則 bash 會往中斷畫面補一行
  `… Killed  _dl_worker …`。
- **`ram` 補上跟 `swap` 一樣的 OOM 保險**。它吃的是「總記憶體」的 80%（不是可用的 80%），
  機器上已有服務佔著記憶體時會換頁甚至觸發 OOM killer，而這一項原本沒有任何保護。
  現在開始前會把所有 sshd 的 `oom_score_adj` 設成 -1000（結束或中斷都還原）、配置量超過
  目前可用時先警告、跑完撈 `dmesg` 的 OOM 記錄寫進報告與摘要。相關程式抽成
  `oom_protect_sshd` / `oom_dmesg` 兩個共用函式，`swap` 一併改用。
- **參數打錯不再留下一個空的 `logs/`**。項目名稱與 `URL` / `DL_URL` 的驗證搬到建立目錄
  之前；用法說明改成自己算出「本來會寫到哪」，而不是印一個已經建好的路徑。
- **選單的 `DL_URL` 改成逐段驗證**。這個參數用逗號分隔可以給多個來源，原本只比對整串
  開頭，`http://a,ftp://b` 會過關、要等 curl 跑起來才發作。空白（`a,,b`）也一併擋下。

### 變更

- 壓測選單 `2) 記憶體` 與 `6) 全部` 的事前說明補上 OOM 風險與 sshd 保護，跟 `4) SWAP` 對齊；
  `2) 記憶體` 那一列與選單標頭改為顯示目前的 `RAM_PCT`。
- `mixed` / `traffic` / `baseline` 三種模式與 `all` 的行為沒有改變，摘要格式只多了
  RAM 那一列的比例（`配置 3030MB (總記憶體 80%)`）。
- 文件同步：`STRESS/README.md` 的 `ram` 段、環境變數表、選單截圖、報告範例與中斷說明；
  根 `README.md` 的環境變數表、壓測段落與安全須知（`ram` 也有 OOM 風險、
  `RAM_PCT` >90 會變成狂換頁）。

### 已知限制

- 本次驗證用本機 http server 與替身工具（假的 `stress-ng` / `fio` / `wrk` / `mpstat`）跑完
  `cpu` / `ram` / `disk` / `swap` / `baseline` / `traffic` 各一輪，中斷情境測了
  `cap_run`（disk）與 `isleep`（traffic）兩條路徑：`kill -TERM` 後同一秒 `exit 130`、
  curl 殘留 0、暫存與 fio 測試檔都沒留、摘要標成「已中斷」。
- **`ntp` 沒有實跑**（會動系統時鐘），真實 `stress-ng` / `fio` 的長時間壓測也仍未驗證。
- `OPS_VERSION` 維持 `1.5`：跟 1.2.1 / 1.2.2 一樣，修正版不動選單上的版本字串。

---

## [1.5.0] - 2026-07-31

納入壓力測試工具。

### 新增

- **`STRESS/`** — 壓力測試腳本（原本是獨立的 repo
  [cxhil-yixian/stress-test](https://github.com/cxhil-yixian/stress-test)）。
  本機壓測 CPU / 記憶體 / 磁碟 / SWAP / NTP，網路測試 `baseline` / `traffic` / `mixed`
  （主機扛下載流量時網站還通不通）。跑測試的同時持續輸出系統監看數據，每次執行產生
  一份報告。除了用法說明裡的網址改指到本 repo 之外，內容與上游相同，仍可單獨執行。
- **主選單第 `s` 項：壓測子選單**。持續秒數、輸出目錄、`URL` / `DL_URL` / 下載程序數
  先問完，接著把「這一項會做什麼」印出來才問要不要開始——SWAP 的 OOM 風險、NTP 會動
  系統時鐘、磁碟測試檔最大 4GB、`wrk` 打別人的站等同 DoS，都寫在確認之前。
  - **缺工具在按下去的當下就擋**，並依這台機器的套件管理器組出安裝指令；`i` 一次補齊，
    RHEL 系會一併處理 `stress-ng` / `wrk` 需要的 `epel-release`。
  - **壓測相依刻意不併進主選單的 `i`**：缺 `fio` / `stress-ng` 只影響壓力測試，不該讓
    「安裝缺少的相依套件」順手裝一堆壓測工具。`doctor` 只列出現況供參考。
  - 底層腳本把報告寫進「當下工作目錄」底下的 `logs/`、不吃路徑參數，所以選單是用
    子 shell `cd` 過去再呼叫（選單自己的工作目錄不變）。輸出目錄預設為執行 `ops.sh`
    時所在的目錄，可用 `OPS_STRESS_DIR` 或選單的 `o` 改。
  - `WRK_THREADS` / `WRK_CONNS` / `HOST_HEADER` / `UA` / `INSECURE` / `DISK_DIR` 選單不問，
    在執行 `ops.sh` 前設成環境變數即可，會被子腳本原封不動繼承。
- **`STRESS/README.md`** — 各項目實際做了什麼、數據怎麼判讀（尾端延遲、steal、KVM host
  cache 汙染）、網路測試的目標怎麼給、報告長什麼樣。

### 變更

- `stress-test.sh` 是 repo 內**唯一需要 bash 的腳本**（用到 `local`、`pipefail`），
  其餘仍是 POSIX sh。壓測選單進入前會檢查 bash，缺了就擋下並提示安裝——Alpine
  最小安裝真的沒有。README 的「四支腳本全部是 POSIX sh」一句同步改寫。
- 遠端模式的自動更新與 `u` 會一併抓 `STRESS/stress-test.sh`；`doctor` 的腳本清單加上它，
  並多一行壓測工具現況（`stress-ng` / `fio` / `mpstat` / `vmstat` / `chronyc` / `wrk` / `curl`）。
- `.gitignore` 增加 `logs/` 與 `.fio-test.*`：從 repo 目錄直接跑壓測時報告會生在
  `./logs/`，而被 `kill -9` 留下的 fio 殘骸可能是個 4GB 的檔案。

### 已知限制

- 壓測腳本只在 CentOS 7.9 / KVM 上驗證過，其他發行版未實測。
- 本次整合的驗證做到「選單流程 + 參數傳遞 + 缺工具攔截」（含用替身腳本確認 `cd`
  與環境變數確實有帶進去），**沒有在缺少 `fio` / `stress-ng` 的環境上實際跑完一輪壓測**。

---

## [1.4.0] - 2026-07-31

納入 Windows 工具並補上還原機制。

### 新增

- **`WINDOWS/`** — Windows 10 / 11 系統管理工具（PowerShell 分類選單 + `.bat` 進入點）：
  RDP（換 Port / 多開 / CredSSP / 登入紀錄）、帳號與安全、Windows 更新 / Store /
  時間時區、Ping / 防火牆 Port / 批量加 IP、Hyper-V 切換、磁碟管理（視覺化 + 破壞性
  操作多重確認）、免管理員的「檢查現況」。
- **換 RDP Port 的看門狗**。原本改完登錄檔就直接重啟 `TermService`，這條 RDP 連線
  必然中斷；新 port 若被雲端安全群組或路由器擋住就再也連不回來——跟 `ssh-port.sh`
  處理的是同一個問題，但 Windows 這邊原本完全沒有還原機制。現在：
  - 先檢查新 port 有沒有被別的程式佔用（佔用的話 `TermService` 會 bind 失敗）
  - 新舊 port 的防火牆規則同時放行，舊規則留到「確認」之後才收
  - 註冊排程工作 `OPS-RdpPort-Watchdog` 當看門狗（預設 10 分鐘）。**用排程工作而不是
    背景行程**：腳本被關掉、使用者登出、連線整個斷掉，還原動作照樣會由系統執行
  - **看門狗建不起來就不做這次變更**，並把剛加的防火牆規則收回去
  - 新增「確認新 Port 可用」（取消看門狗、可收掉舊規則）與「立即還原」兩個選項；
    主選單 / A 子選單 / 檢查現況都會標示「有未確認的變更」
- **`WINDOWS/README.md`** — 換 port 三步流程、看門狗機制與檔案位置、破壞性操作的防呆、
  編碼取捨、已知限制。
- **`.gitattributes`** — `*.bat` / `*.ps1` 強制 CRLF、`*.sh` 強制 LF。shell 腳本被存成
  CRLF 的話 shebang 會變成 `/bin/sh\r`，直接執行就失敗。

### 修正

- **`$ErrorActionPreference = 'SilentlyContinue'` 改成 `Continue`。** 原本每個失敗都
  無聲無息，然後畫面照樣印「[完成]」——被群組原則鎖住的登錄檔、權限不足的服務設定
  全都會變成「看起來成功」。同時把會改到系統的動作改成**讀回來驗證**：換 RDP Port
  讀回 `PortNumber`（不符就撤回看門狗與防火牆規則）、停止 / 還原 Windows 更新讀回
  `wuauserv` 的啟動類型。
- 「解除帳號密碼鎖定」改為先警告這等於關閉帳號鎖定保護（密碼可被無限次嘗試）並要求
  確認，事後附上恢復指令。
- 防火牆關閉 Port 補上數值驗證，並講明只會移除**本工具建立的**規則。
- 批量加 IP 補上前三段格式與數值範圍驗證。
- `.bat` 改用 `chcp 65001` 對應 UTF-8 的 `.ps1`（原本是 Big5 950，與檔案編碼不一致），
  並加上「找不到 .ps1」「找不到 powershell.exe」的處理。`.bat` 內的訊息刻意保持全英文：
  cmd 是用主控台當下的字碼頁解析批次檔，非 ASCII 內容會隨地區設定而壞掉。
- 「檢查現況」的項目編號原本跳號（1,2,4,5,6,10,7），改成連續。

### 已知限制

- **Windows 腳本沒有在 Windows 上實測過**：修改是在 Linux 上做的，只做了結構檢查
  （括號平衡、函式定義），沒有真的執行。第一次用請先在測試機驗證換 RDP Port 流程。

---

## [1.3.0] - 2026-07-31

### 新增

- **開場自動更新 + 自檢**（`startup_tasks`）。選單開出來之前先把等一下要用的東西
  準備好並確認可用，不要等到選下去才發現工具是舊的、或封鎖根本寫不進防火牆。
  - 遠端模式每次啟動重新下載工具腳本（原本只有缺檔才抓，要靠手動按 `u`）。
    **換埠進行中會跳過**——覆蓋 `ssh-port.sh` 會影響看門狗的還原行為，跟選單 `u`
    同樣的顧慮。下載失敗就沿用既有快取繼續跑。
  - 自檢：必要套件缺失、fail2ban 的封鎖後端不可用 / 服務沒回應 / 沒有任何 jail /
    `banaction` 與後端不符。**沒問題就完全安靜直接進選單**，有問題才停下來等 Enter，
    免得訊息被選單的 `clear` 洗掉。
  - `--no-update` / `OPS_NO_UPDATE=1` 可略過自動更新。
- **`fail2ban.sh preflight`** 子命令：給 `ops.sh` 開場用的安靜自檢，沒事不出聲。
  判斷邏輯留在 fail2ban.sh 裡，`ops.sh` 不複製一份。
- **換源改成先問參數再執行**。那支第三方腳本本來是跑到一半才逐項互動詢問（協議、
  內外網、要不要覆蓋 EPEL、要不要順便升級套件…），問題散在大量輸出中間，很容易
  看漏就按下去。現在一次問完並組成命令列參數，執行前把完整指令攤開來看：
  鏡像站（六個常用 + 自訂 + 不指定）、`--protocol`、`--use-intranet-source`、
  `--install-epel`（僅 RHEL 系）、`--backup` / `--ignore-backup-tips`、
  `--upgrade-software` / `--clean-cache`。
  選項名稱是**下載該腳本讀它實際的參數解析得到的**，不是猜的。

---

## [1.2.2] - 2026-07-31

### 新增

- **`doctor` 事前檢查封鎖後端能不能用。** 起因是另一台機器顯示「防火牆 none」——
  但那只代表 INPUT 鏈裡沒有規則，不代表 fail2ban 不能運作（它會自己建 `f2b-*` 鏈
  並在 INPUT 插 jump）。真正會讓封鎖失效的是「連鏈都建不起來」，常見於 OpenVZ /
  LXC 容器缺 netfilter 模組。現在會：偵測後端（firewalld / ufw / nftables /
  iptables / none）、判斷是不是容器、對 iptables 實際建一條臨時空鏈再刪掉來驗證
  能力（空鏈不掛在任何地方，不影響現有規則）。
- **`enable-sshd` 依偵測到的後端寫 `banaction`**：firewalld → `firewallcmd-rich-rules`、
  ufw → `ufw`、nftables → `nftables-multiport`、iptables → `iptables-multiport`。
  firewalld 那條最重要：它每次 reload 都會把 iptables 上的 f2b 鏈沖掉，用錯的話
  封鎖會靜默失效。`action.d/` 沒有對應檔案就不寫，沿用發行版預設，而不是寫一個
  會讓服務起不來的名字進去。`doctor` 也會比對現行值與建議值，不一致時警告。

### 修正

- **選單第 9 項（換源）把空網址丟給 curl**，畫面上「來源：」是空的，確認後只得到
  `curl: (3) <url> malformed`。原因是 `REPO/URL` 這個檔案第一個字元就是換行，
  而 `act_mirror` 用 `head -1` 讀它——拿到的是那個空行。**檔案內容一直是好的，
  是解析錯了。** 改為取「第一行看起來像網址的內容」，允許開頭空行與 `#` 註解；
  找不到網址時警告並退回內建預設。執行前再擋一次，不合法的網址絕不丟給 curl。
- `REPO/URL` 一併整理：移除開頭空行，加上說明用的註解。
- 遠端模式下載 `REPO/URL` 時改成先落 `.part`、確認內容含網址才改名，並把
  「已存在就不重抓」的判斷從 `-f` 改成 `-s`。原本下載失敗留下的 0 bytes 檔案
  會被當成「抓過了」而永遠不再重試，同時又蓋掉內建預設值。

---

## [1.2.1] - 2026-07-30

`fail2ban.sh` 上線第一天在真實環境（正在被爆破的機器）抓到的兩個問題。

### 修正

- **`ssh_peers` 把攻擊者當成「你自己的 SSH 來源」。** 原本的反推邏輯是「連到 SSH 埠
  的所有 established 連線」，但爆破攻擊的連線也在同一個埠上。實際輸出長這樣：

  ```
  你的來源  : 198.51.100.7 198.51.100.112 203.0.113.56
  ```

  前兩個是正在爆破這台機器的來源。後果不只是顯示錯誤：`lockout_check` 會因此
  **拒絕封鎖正在攻擊你的 IP**（說那是你的來源），而 `doctor` 還會建議把攻擊者
  加進白名單——照做的話那些 IP 就永遠封不了了。

  改成兩個條件同時成立才算數：連線的持有行程在自己的**祖先鏈**上（排除攻擊者），
  **而且**本地埠是實際的 SSH 埠（排除自己祖先行程持有的對外連線——登入後在這條
  session 裡跑的 yum / curl / agent 的對端，只比對祖先鏈會把它們也算進來）。
  另加 `who`（只列通過認證的 session，爆破連線不會出現在裡面）。
- **防火牆規則的驗證改成找 IP，不找名稱。** 原本是看 iptables / nftables 裡有沒有
  `f2b` 字樣，banaction 走 firewalld 或 ipset 時規則不叫這個名字，會誤報成
  「封鎖沒有生效」。改成拿一個現在真的被封的 IP，去 iptables / nftables / ipset /
  firewalld 裡實際找——這是唯一跟 banaction 寫法無關的驗證方式。找不到時會給出
  該查哪個設定，以及 fail2ban 日誌裡對應的錯誤關鍵字。
- `doctor` 的「你的來源」不再只印前 3 筆（真正屬於自己的那筆可能被截掉）。

### 新增

- 防火牆規則對不上時，`doctor` 直接把原因挖出來而不是叫人自己 grep：實際的
  `banaction` 設定、`f2b` 鏈存不存在（存在但沒規則 = 防火牆被 reload 沖掉，
  fail2ban 不會自己補；連鏈都沒有 = ban 動作根本沒成功），以及 fail2ban 日誌裡
  最後 3 筆 ban 失敗的錯誤。沒有錯誤本身也是線索：代表當下有套上、是事後被沖掉的。

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

- **`selfheal-ssh.sh` 判到暴力破解時不再無條件叫人「安裝 fail2ban」。** 在真實環境
  （SSH 埠 41119、fail2ban 正在跑、四個來源已被 ban 卻仍持續累積失敗數）發現這句
  建議會把真正的問題蓋掉：fail2ban 明明在跑，失敗數還在漲，代表封鎖根本沒擋住封包
  ——多半是 jail 的 `port` 還停在預設的 22。現在依 fail2ban 現況給三種建議
  （在跑 / 已裝沒跑 / 沒裝），前兩種都指向 `FAIL2BAN/fail2ban.sh doctor`。
  建議文字不寫死猜「port 停在 22」——真實案例裡 port 已經對了，失效原因是規則
  根本沒進防火牆。兩種可能都提，判斷交給 `doctor`。
  狀態用 socket 是否存在判斷，不呼叫 `fail2ban-client`：`watch` 每秒刷新一次，
  每秒 fork 一支 python 程式太貴。
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

[1.13.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.12.0...v1.13.0
[1.12.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.11.0...v1.12.0
[1.11.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.10.4...v1.11.0
[1.10.4]: https://github.com/cxhil-yixian/OPS-command/compare/v1.10.3...v1.10.4
[1.10.3]: https://github.com/cxhil-yixian/OPS-command/compare/v1.10.2...v1.10.3
[1.10.2]: https://github.com/cxhil-yixian/OPS-command/compare/v1.10.1...v1.10.2
[1.10.1]: https://github.com/cxhil-yixian/OPS-command/compare/v1.10.0...v1.10.1
[1.10.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.8.1...v1.9.0
[1.8.1]: https://github.com/cxhil-yixian/OPS-command/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/cxhil-yixian/OPS-command/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/cxhil-yixian/OPS-command/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/cxhil-yixian/OPS-command/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/cxhil-yixian/OPS-command/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/cxhil-yixian/OPS-command/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/cxhil-yixian/OPS-command/releases/tag/v0.1.0
