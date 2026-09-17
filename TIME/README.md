# TIME/

`time-set.sh` — 系統時區與時間設定：改時區、手動改時鐘、校時、硬體時鐘、環境檢查。

可以透過根目錄的 [`../ops.sh`](../README.md) 選單操作（主選單按 `t`），以下是直接呼叫的說明。

| | |
|---|---|
| Shell | POSIX sh（Alpine 的 busybox ash 可直接執行） |
| 需要 root | 是（`status` / `list` / `doctor` / `-h` 除外） |
| 會改系統嗎 | 會：時區、系統時鐘、硬體時鐘，以及校時服務的執行與開機狀態 |
| 相依 | `tzdata`（改時區用）、`chrony`（自動校時用）；沒裝可以用 `install` 裝 |

```bash
./time-set.sh status                  時區 / 系統時間 / 硬體時鐘 / 校時服務
./time-set.sh list [關鍵字]           列出時區（不給關鍵字只列常用的，all = 全部）
./time-set.sh set-zone <時區>         設定時區，例：Asia/Taipei
./time-set.sh set-time <時間>         手動設定系統時間
./time-set.sh sync [伺服器]           立刻校時一次（不改變服務的開機狀態）
./time-set.sh ntp on|off              啟用 / 停用自動校時
./time-set.sh rtc                     把目前系統時間寫回硬體時鐘
./time-set.sh doctor                  環境檢查
./time-set.sh install                 安裝 chrony 與 tzdata
```

選項：`-y` 免確認、`-n` 乾跑。

時間格式（`set-time`）：

| 寫法 | 意思 |
|---|---|
| `'2026-08-19 15:30:00'` | 完整 |
| `'2026-08-19 15:30'` | 秒補 0 |
| `'2026-08-19T15:30:00'` | ISO 8601，一樣當本地時間 |
| `'2026-08-19'` | 當天 00:00:00 |
| `'15:30:00'` | 今天的這個時刻 |
| `@1755590000` | epoch |

月份與日可以不補零（`2026-8-9`）。**格式對但日子不存在的會被擋下來**——`2026-02-30`
在某些 `date` 實作上會被默默進位成 3 月 2 日而且不報錯，那是最難發現的一種錯。

---

## 時區與時間是兩件事

這是用這支腳本之前唯一要先想清楚的事：

| | 改什麼 | 絕對時刻（UTC） | 什麼時候用 |
|---|---|---|---|
| `set-zone` | 顯示與換算方式 | **不變** | 機器擺錯時區、搬機房、log 時間看起來差 8 小時 |
| `set-time` | 時鐘本身 | **會變** | 時鐘真的錯了，而且沒有校時服務可用 |

log 的時間戳差 8 小時，通常是時區的問題，不是時鐘的問題。這種情況要用 `set-zone`，
它不會動到絕對時刻，也就沒有下面那一整節的風險。

---

## 改時鐘之前

`set-time` 會先算出「跟現在差多少、往哪個方向」再問你要不要做，因為兩個方向的後果不一樣：

**往回撥**（把時鐘調回過去）風險比較大：

- cron / systemd timer 會把這段時間內**已經跑過的工作再跑一次**
- 資料庫與 replication 的時序會亂（同一個時刻出現兩次）
- 單調遞增的 log、序號、快取到期判斷都可能出錯

**往前撥**：

- 跳過去這段期間該執行的 cron 會被略過，或在跳完後一次補跑
- session / token / sudo 的時間戳可能立刻過期

兩個方向共通的：TLS 憑證的有效期是絕對時間，差太多會變成「尚未生效」或「已過期」，
連線會直接失敗；fail2ban 的封鎖到期時間也跟著算。

```
==> 設定系統時間
  目前  2026-08-19 15:20:50 CST
  設成  2026-08-25 08:00:00
  差距  往前撥 5 天 16 小時 39 分 10 秒

  ! 時鐘往前撥會有這些後果：
    跳過去這段期間該執行的 cron 會被略過，或在跳完後一次補跑
    ...
```

---

## 三種「改了又跳回去」

改完時間過幾分鐘又變回舊值，是這類操作最常見的抱怨。來源有三個，`doctor` 三個都會查：

### 1. 校時服務把它校回去

`chronyd` / `ntpd` / `systemd-timesyncd` 在跑的時候，手動設定的時間會在幾秒到幾分鐘內被拉回正確值。

所以 `set-time` 偵測到校時服務正在跑時會**停下來問**，同意之後才停用它（含開機啟動）再設定：

```
! chronyd 正在跑 —— 手動設定的時間會在幾秒到幾分鐘內被它校回去
  接下來會停用它（含開機啟動），設定完要恢復自動校時請執行：… ntp on
要停用 chronyd 並繼續設定時間嗎？ [y/N]
```

`-y` 免確認模式**一律拒絕執行**，並要你先明確跑一次 `ntp off`。停用別人的校時服務
是有後果的決定，不該因為加了 `-y` 就替使用者做掉。（同 [`../STRESS/README.md`](../STRESS/README.md)
對 chronyd 的態度：本來什麼狀態，動完就是什麼狀態，要改要問。）

### 2. 硬體時鐘沒跟著改

重開機時系統時間是從硬體時鐘（RTC）讀回來的。只改系統時間、沒寫回 RTC，重開機就跳回舊值。

`timedatectl` 那條路徑會自己寫回去；走 `date -s` 的機器由腳本補一次 `hwclock --systohc`，
失敗也會講（虛擬機與雲端主機常常沒有可寫的 RTC，那種情況正常）。要單獨補做這一步用 `rtc`。

### 3. 虛擬機的主機時間同步

這個不在這台機器上，關不掉的話怎麼設都會被拉回去。`doctor` 會依平台指出來：

| 平台 | 誰在拉 | 怎麼關 |
|---|---|---|
| Hyper-V | 主機的 Time Synchronization 整合服務 | 主機端 `Disable-VMIntegrationService -Name 'Time Synchronization'` |
| VMware | VMware Tools 的時間同步 | `vmware-toolbox-cmd timesync disable` |
| KVM/QEMU | `qemu-guest-agent` 的 `guest-set-time` | 通常只在暫停 / 恢復後才動 |

---

## 啟用自動校時之前

`ntp on` 會先警告一句：**這台的時鐘目前偏差多少，服務起來之後就會跳多少。**

這是實測踩過的坑——一台 chronyd 停用、時鐘快 8 小時的 VM，啟動 chronyd 之後
`makestep` 直接把時間跳了 8 小時。偏差 8 小時就跳 8 小時，跳完的後果跟手動改時間完全一樣。
不確定偏多少就先跑 `status` 看一眼。

`install` 裝完 chrony **不會**順手把它啟動，理由同上。要啟用請另外執行 `ntp on`。

`sync` 是「立刻校時一次」，不改變服務的開機狀態。用哪條路徑依這台有什麼決定：

| 情況 | 做法 |
|---|---|
| chronyd 正在跑 | `chronyc makestep`（用它既有的來源與統計） |
| 裝了 chrony 但沒在跑 | `chronyd -q`（一次性，不留下常駐程序） |
| 有 ntpdate / sntp / busybox ntpd | 各自的一次性校時，可用參數指定伺服器 |
| systemd-timesyncd 正在跑 | 重啟該服務逼它重新對時，完成後印出同步狀態與來源 |

timesyncd 是 Debian / Ubuntu 的預設校時服務，但它**沒有「立刻校時一次」的指令**，所以這條
路徑的做法是重啟服務。如果 timesyncd 裝了卻沒在跑，`sync` 會叫你先 `ntp on`——在 1.13.2
之前，一台正在正常同步的 Ubuntu 會被告知「找不到校時工具，請安裝 chrony」，那是錯的建議。

`chronyc` 回的 `200 OK` **只代表指令收到了**，真正的跳躍要等 chronyd 拿到有效測量才發生，
偏差大時會晚幾秒到幾十秒。腳本會等 3 秒再印結果，並在畫面上註明這件事。

---

## 設完一定回讀

`date -s` 各家實作吃的格式不一樣，而且失敗時常常**回傳 0 但沒改到**，只看 exit code
會得到「設定成功」的假象。所以每設一次就回讀比對一次，差超過 120 秒就換下一種寫法：

1. `timedatectl set-time`（有 systemd 且 timedatectl 連得上時；會一併更新 RTC）
2. `date -s 'YYYY-MM-DD HH:MM:SS'`
3. `date -s MMDDhhmmCCYY.ss`（POSIX 老格式，busybox 一定吃）
4. `date MMDDhhmmCCYY.ss`

四種都對不上就明講失敗，不會留下「看起來成功」的輸出。

時區同樣回讀確認，而且讀的來源跟寫的來源不同（寫 `timedatectl` / symlink，讀 `/etc/localtime`），
這樣才驗得出來。

---

## 這台的時區到底是哪個

`/etc/localtime` 才是 libc 真正在用的東西，`date` 與所有程式看到的時間都由它決定。
所以腳本判斷時區的順序是：

1. `/etc/localtime` 的 symlink 目標
2. `timedatectl`
3. `/etc/timezone`（Debian / Alpine）
4. `/etc/sysconfig/clock` 的 `ZONE=`（RHEL 6/7 的舊寫法）

**`timedatectl` 刻意排在第二**：實測 CentOS 7 直接換掉 `/etc/localtime` 之後，`date` 立刻是新時區，
但 `timedatectl` 在那之後一小段時間仍回舊值——`systemd-timedated` 快取著，
`daemon-reexec` 也不會讓它更新（那個重載的是 PID 1，不是它），要等它閒置退出。
兩邊講的不一樣時，`doctor` 會把差異指出來並給出讓它們一致的指令。

---

## 環境檢查（doctor）

重點放在「你改了但不會生效 / 會被拉回去」的情況：

```
  + 時區資料庫：/usr/share/zoneinfo（419 個時區）
  + timedatectl 可用（時區與時間都走它，會一併更新硬體時鐘）
    這版沒有 timedatectl show（systemd 230 之前），查詢改解析 status，設定不受影響
  + hwclock 可讀寫硬體時鐘
  + 有 CAP_SYS_TIME，改得動系統時鐘
  KVM/QEMU 虛擬機：qemu-guest-agent 在主機下 guest-set-time 時會改時間
  校時服務  : chronyd(執行中)
  + chronyd 執行中（開機啟動：enabled）
    目前偏差：0.000065746 seconds fast of NTP time
  + 硬體時鐘以 UTC 為基準（Linux 的標準做法）
```

會標紅（並讓 `doctor` 回傳非 0）的情況：

- **容器環境**：容器沒有自己的時鐘，看到的是主機的，這裡改不動也不該改（時區倒是可以改）
- **沒有 CAP_SYS_TIME**：系統時間改不動，常見於容器、受限的 systemd unit 與部分雲端映像檔
- **沒有時區資料庫**：Alpine 最小安裝預設就沒有 `/usr/share/zoneinfo`，只能用 UTC
- **同時有兩套校時服務在跑**：它們會互相搶著校正，時鐘反而更不穩

---

## 相容性

| 情況 | 行為 |
|---|---|
| CentOS 7 的 `timedatectl` 沒有 `show` 子命令 | 探測改用 `status`（設定功能都在），查詢退回解析 `LC_ALL=C timedatectl status` |
| 沒有 systemd / timedatectl 連不上 | 時區改寫 `/etc/localtime`（+ `/etc/timezone`、`/etc/sysconfig/clock`），時間走 `date -s` |
| busybox 的 `date` 不吃 `-d @epoch` | 退到 `-D %s`；設定則有 `MMDDhhmmCCYY.ss` 的相容寫法 |
| 沒有 `hwclock` 或沒有 RTC | 照樣設系統時間，但會警告「重開機可能跳回舊值」 |
| Alpine 沒裝 tzdata | `set-zone` 直接擋下並給出 `apk add tzdata` |
| `timedatectl status` 的標籤各版不同 | `NTP synchronized` 與 `System clock synchronized` 兩種都比對，且強制 `LC_ALL=C` 避免被翻譯 |

---

## 檔案位置

操作記錄寫在 `/var/log/OPS-ssh/time-ops.log`（跟其他工具收在一起，可用 `OPS_SSH_DIR` 改）。

改時鐘的記錄**同一行裡就寫著「改前 -> 改後」**：時間一改，日誌自己的時間戳也跟著跳，
只靠時間戳排不出先後。

乾跑（`-n`）寫進去的每一行都標 `[乾跑]`。畫面上有「乾跑模式」那句提示，但日誌是一行
一行往下接的，沒有標記的話事後翻起來，「執行：停用並關閉 chronyd」看起來就跟真的做過
一模一樣。

---

## 環境變數

| 變數 | 作用 |
|---|---|
| `OPS_NTP_SERVER` | `sync` 預設要問哪台，預設 `pool.ntp.org`；內網機器連不到就設它 |
| `OPS_SSH_DIR` | 操作記錄的位置，預設 `/var/log/OPS-ssh` |
| `NO_COLOR` | 關閉顏色 |
