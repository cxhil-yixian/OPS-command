# SSH/

兩支互補的 SSH 運維腳本：一支負責**安全地改埠**，一支負責**看清楚誰在連**。

兩支都可以透過根目錄的 `../ops.sh` 選單操作（選項 1-4 與 5-8），以下是直接呼叫的說明。

| 腳本 | 用途 | Shell | 會改系統嗎 |
|---|---|---|---|
| [`ssh-port.sh`](#ssh-portsh) | 變更 SSH 連接埠 | POSIX sh | 會（有完整還原機制） |
| [`selfheal-ssh.sh`](#selfheal-sshsh) | 連線取證與即時監看 | POSIX sh | **不會**，純唯讀 |

兩支都是 POSIX sh，Alpine 的 busybox ash 可直接執行，不需要安裝 bash。

---

# ssh-port.sh

安全變更 SSH 連接埠。核心設計原則只有一句：**不讓你把自己鎖在門外**。

```bash
./ssh-port.sh set 58763          變更為 58763（雙埠並存 + 看門狗）
./ssh-port.sh set 58763 -t 900   看門狗時限改 900 秒（預設 600）
./ssh-port.sh confirm            確認新埠可用，收掉舊埠
./ssh-port.sh rollback           立即還原
./ssh-port.sh status             顯示目前狀態
./ssh-port.sh set 58763 -n       乾跑：只印出將要做什麼
```

其他選項：`-y` 略過確認、`--force` 埠被佔用時仍繼續、`--keep-fw` confirm 時保留舊埠的
防火牆規則。除 `status` 外都需要 root。

## 標準流程

```
  ./ssh-port.sh set 58763
        │
        ├─ 備份 sshd_config 與 sshd_config.d/
        ├─ 設定「舊埠 + 新埠」同時監聽   ← 現有連線完全不受影響
        ├─ SELinux 標記 / 防火牆放行
        ├─ sshd -t 語法檢查 → 重啟 → 確認新埠真的在 LISTEN
        └─ 啟動看門狗（預設 600 秒）
        │
        ▼
  ★ 不要關掉這個視窗，另外開一個新終端機：
        ssh -p 58763 user@host
        │
        ├─ 登入成功 ──→ 回原視窗執行 ./ssh-port.sh confirm
        │                  └─ 收掉舊埠、取消看門狗、移除舊埠防火牆規則
        │
        └─ 登入失敗 ──→ 什麼都不用做，等看門狗逾時自動還原
                          （或在原視窗執行 ./ssh-port.sh rollback 立刻還原）
```

**為什麼一定要另開視窗測試**：目前這條連線是在舊埠上建立的，改設定不會踢掉它。所以
「這條連線還活著」完全不能證明新埠可用。只有真的用新埠開一條新連線登入成功，才算數。

## 這支腳本在處理什麼

改 SSH 埠看起來只是改一行設定，實際上有四個各自獨立的坑，任何一個沒處理都會失聯：

**1. systemd socket activation**
Ubuntu 24.04 預設啟用 `ssh.socket`。這種模式下 `sshd_config` 裡的 `Port` **完全無效**，
真正決定監聽埠的是 socket unit 的 `ListenStream`。腳本偵測到 socket 接管時，會一併寫
`/etc/systemd/system/ssh.socket.d/override.conf`（而且必須先寫一行空的
`ListenStream=` 清掉原設定，否則新舊值會疊加）。

**2. OpenSSH 版本差異**
8.2+ 支援 `Include /etc/ssh/sshd_config.d/*.conf`，腳本走 drop-in，不動主設定檔。
CentOS/RHEL 7 的 OpenSSH 是 7.4，不支援 Include，只能改主設定檔——而且必須插在**檔案最
前面**。附加到檔尾可能落進某個 `Match` 區塊裡，那樣設定只對特定條件生效，是很難察覺的
錯誤。

**3. SELinux**
RHEL 系上非標準埠沒有 `ssh_port_t` 標籤，sshd 會在 bind 階段被拒絕，服務直接起不來。
腳本會用 `semanage port -a`（失敗時退 `-m`）標記；找不到 `semanage` 時直接中止並印出
該裝哪個套件，而不是硬幹下去讓你失聯。

**4. `Port` 指令是累加的**
sshd_config 寫兩行 `Port` 就會監聽兩個埠——雙埠並存正是靠這個特性。但這也代表重複執行
腳本會疊加區塊，舊埠其實根本沒收掉。所以寫入前一定先移除自己上次寫的區塊，並把不是自己
管理的 `Port` 行註解掉。

## 看門狗

`set` 之後會 fork 一個背景行程（`setsid`，脫離目前 session，SSH 斷線也殺不掉它）：

```
sleep <timeout>
若 /var/lib/ssh-port/confirmed 存在 → 什麼都不做
否則 → ssh-port.sh rollback --auto
```

還原的範圍是**全部**：設定檔（從備份還原）、防火牆規則、SELinux 埠標籤、socket
override。所以就算新埠完全連不上、你連視窗都關了，時限到了機器會自己回到原狀。

`confirm` 做的第一件事就是取消看門狗。

因為看門狗排程裡寫的是**這支腳本的實體路徑**，所以：

- `ssh-port.sh` 不接受用管線 / 行程替換執行（`curl … | sh`、`bash <(curl …)`），
  這種情況 `$0` 是 `sh` 或 `/dev/fd/NN`，寫進排程會是無效路徑——沒有自動還原、
  卻讓人以為有保護。腳本會直接拒絕並提示改用 `ops.sh` 或 `git clone`。
- 用 `ops.sh` 的一行指令模式時，腳本會被下載到 `/var/lib/ops-command`，
  **在 `confirm` 完成前不要刪除或搬移該目錄**。

## 檔案位置

| 路徑 | 用途 |
|---|---|
| `/var/lib/ssh-port/state` | 進行中變更的狀態（舊埠、新埠、備份路徑…） |
| `/var/lib/ssh-port/backup-<時間戳>/` | 設定檔備份，`confirm` 後仍保留，確認穩定可自行刪 |
| `/var/lib/ssh-port/watchdog.sh` / `.pid` | 看門狗 |
| `/var/log/ssh-port.log` | 操作記錄（含看門狗的自動還原記錄） |
| `/etc/ssh/sshd_config.d/00-ssh-port.conf` | drop-in（僅 OpenSSH 8.2+） |

腳本寫進主設定檔的內容一律包在標記區塊裡，方便肉眼辨識與手動清除：

```
# >>> ssh-port.sh 管理區塊 開始 >>>
Port 22
Port 58763
# <<< ssh-port.sh 管理區塊 結束 <<<
```

被它註解掉的既有設定會標成 `#ssh-port.sh# Port 22`。

## 疑難排解

**新埠連不上，但看門狗還沒逾時**
先確認雲端安全群組 / 網路 ACL 有沒有放行——這是最常見的原因，本機防火牆放行不代表雲端
那層放行。真的不行就什麼都別做，等看門狗自動還原。

**偵測到 nftables**
nftables 的規則結構因人而異，腳本不會自動改，只會提示你手動放行：
`nft add rule inet filter input tcp dport <埠> accept`

**iptables 規則重開機後不見了**
腳本用 `iptables -I` 插入的規則不會自動持久化，需自行存檔：
`service iptables save`（RHEL）/ `netfilter-persistent save`（Debian）/
`rc-service iptables save`（Alpine）。

**已經失聯了**
唯一的路是走主控台（雲端 Console / VNC / IPMI），登入後執行
`./ssh-port.sh rollback`，或直接從 `/var/lib/ssh-port/backup-*/` 把設定檔複製回去。

**`status` 顯示有未確認的變更，但我忘記做到哪了**
`status` 會把狀態檔內容和看門狗是否還在跑印出來。不確定就選 `rollback`，回到原狀最安全。

---

# selfheal-ssh.sh

SSH 連線取證與即時監看。原本是夜鶯（n9e）「SSH連接數超限」告警的自愈腳本，也能單獨當
排查工具用。

**純取證，不改變系統任何狀態，不封鎖任何 IP。** 這是刻意的設計——自建封鎖腳本誤封跳板機
或監控伺服器會讓機器直接失聯，要自動封鎖請用 fail2ban。

```bash
./selfheal-ssh.sh              一次性取證，完整報告寫入 log（n9e 自愈呼叫此模式）
./selfheal-ssh.sh watch [秒]   即時監看，預設每 1 秒更新（Ctrl-C 離開）
./selfheal-ssh.sh snap         輸出單次即時快照（watch 內部呼叫，也可單獨用）
./selfheal-ssh.sh tail         即時追蹤 sshd 認證日誌
./selfheal-ssh.sh debug        傾印原始 ss / ps 輸出與解析結果，用於排查
```

## 核心概念：ESTAB 不等於已登入

這是整支腳本最重要的一件事。`ss` 看到的 `ESTAB` 只代表 **TCP 三次握手完成**，跟有沒有
通過 SSH 認證是兩回事。爆破攻擊會建立大量 TCP 連線卻永遠不通過認證——它們全部堆在
ESTAB 裡。只看 ESTAB 數字，你分不出「50 個人在用」和「正在被爆破」。

腳本把連線拆成三個階段：

| 階段 | 判定方式 | 意義 |
|---|---|---|
| **握手中** | `SYN_RECV` | 送了 SYN 但沒完成三次握手。大量出現 = SYN flood 或掃描 |
| **認證中** | `ESTAB` + sshd 行程標題**不含** `@` | TCP 建好但卡在認證。**爆破/掃描全堆在這** |
| **已登入** | `ESTAB` + sshd 行程標題**含** `@` | 真的通過認證了（`sshd: root@pts/0`） |

判定原理：OpenSSH 認證通過後才會把行程標題改成 `user@tty`。腳本用 `ss -p` 取得每條連線
的 sshd pid，再比對該 pid 在 `ps` 裡的標題。這個特徵跨 OpenSSH 版本成立，含 9.8+ 拆出
`sshd-session` 之後。

「正常登入是瞬間完成的」——所以同時有十幾條連線停在認證階段，幾乎一定有問題。

> **這段依賴 `ps` 能印出行程標題。** procps 的 `-o` 語法有個陷阱：
> `ps -eo pid=,etime=,args=` 會把「`,etime=,args=`」整串當成 pid 欄的**標題**，
> 結果只印出 pid 一欄——指令回傳成功、輸出看起來正常，但標題全空，階段分類
> 就靜默退回粗略模式。正確寫法是每欄各給一個 `-o`：
> `ps -eo pid= -o etime= -o args=`。
> 腳本現在會依序探測四種寫法（procps 兩種、busybox 兩種）取第一個真的有輸出的，
> 全都不行時在畫面上標紅說明，不會假裝正常。`debug` 模式的「ps 用法」那行會顯示
> 實際選中的是哪一種。

## 即時監看（watch）

```
 SSH 即時監看 web-01  2026-07-29 16:40:12  (Ctrl-C 離開)
 Rocky Linux 9.4 | sshd=active | 埠 22
────────────────────────────────────────────────────────────────────────
 TCP 層
   SYN_RECV 握手中      0     ESTAB 已建立     47     新連線        3 /秒
   CLOSE_WAIT           1     TIME_WAIT       12     來源 IP      31
 SSH 層（ESTAB 細分）
   已認證登入           2     認證中未認證    44     無法判定      1
   互動 session         2     sshd 行程       49     近1分失敗   118
────────────────────────────────────────────────────────────────────────
 [已登入] 已通過認證的來源            數量 / 來源IP / 行程 / 連線時間
     2  10.0.1.9           root@pts/0               02:13:44
 [認證中] TCP 建好但尚未通過認證  ← 爆破/掃描會堆在這
    41  103.x.x.x          sshd: unknown [priv]     00:04
     3  45.x.x.x           sshd: unknown [priv]     00:11
────────────────────────────────────────────────────────────────────────
 判讀: 暴力破解 (近一分鐘 118 次登入失敗)
 建議: 看失敗來源 IP TOP15。建議安裝 fail2ban，或改用金鑰登入並關閉密碼驗證
```

超過門檻的數字會標紅。`snap` 模式不取鎖、不寫檔、不 sleep，所以可以安全地被每秒呼叫。

## 判讀門檻

判讀邏輯由上而下取第一個命中的條件，可直接改腳本開頭的變數：

| 變數 | 預設 | 命中時的判讀 |
|---|---|---|
| `TH_FAILED_1H` | 100 | 近一小時失敗數 → 暴力破解（oneshot 用） |
| `TH_FAILED_1M` | 10 | 近一分鐘失敗數 → 正在被爆破（watch 用） |
| `TH_PREAUTH` | 10 | 同時卡在認證階段的連線數 → 爆破/掃描 |
| `TH_PREAUTH_AGE` | 180 | 單一連線停在認證階段的秒數 → 慢速掃描 |
| `TH_SYNRECV` | 20 | SYN_RECV 數 → 半開連線過多 |
| `TH_DISTINCT` | 30 | 不同來源 IP 數 → 分散式掃描 |
| `TH_NEWCONN` | 20 | 每秒新進連線數 → 連線風暴 |
| `TH_SINGLE_PCT` | 50 | 單一來源佔比（%） → 來源集中 |
| `TH_CLOSEWAIT` | 30 | CLOSE_WAIT 數 → 連線洩漏 |
| `TH_ESTAB` | 50 | established 數 → 連線數偏多 |

「認證中 ≥ 10 且已登入 = 0」會單獨判成**疑似爆破/掃描**——只建 TCP 從不通過認證，是很
乾淨的掃描器特徵。

## 一次性取證（oneshot）

完整報告寫到 `/var/log/n9e-selfheal/ssh-health.log`（非 root 時退到 `/tmp/n9e-selfheal/`），
stdout 只印摘要。超過 5MB 自動輪替，保留 3 份；用 `flock` 防重入。

報告內容包含連線統計、三個階段各自的來源排名、互動 session 與**每個 session 正在跑什麼
行程**、近期登入記錄、失敗來源與被嘗試的帳號 TOP 15、fail2ban 狀態、sshd 關鍵設定、
`authorized_keys` 的時間戳。

其中最該先看的是這一段：

```
===== 可疑：失敗後成功的來源 IP =====
```

同一個 IP 大量失敗之後出現成功登入，代表**可能已經被攻破**。命中時判讀結果會被覆寫成
「疑似已被攻破」，建議立即比對 `authorized_keys`、新增帳號與 cron，必要時隔離主機。

環境變數 `SSH_FORENSIC_LOGDIR` 可改輸出目錄，`IDENT` 可改報告裡的主機識別名。

## 與 n9e 整合

綁定規則「SSH連接數超限」，自愈動作直接呼叫本腳本不帶參數即可。腳本以 root 執行效果最好
（能取得連線對應的行程資訊）；非 root 時會退回用 `ps` 標題與 `who` 統計，數量還在，但
無法標出對應的來源 IP。

## 疑難排解

**畫面上中文和框線都不見了，只剩 ASCII**
機器上沒有 UTF-8 locale。腳本會偵測並印出修法：
`localedef -i en_US -f UTF-8 en_US.UTF-8`，或 `yum reinstall glibc-common`。

> 腳本刻意把 locale 拆開設定（`LC_COLLATE`/`LC_TIME` 保持 C 以確保排序與 syslog
> 時間戳比對正確，`LC_CTYPE` 設成 UTF-8）。**不要改回 `LC_ALL=C`**，那會讓寬字元轉換
> 把中文與框線全部吃掉。

**「無法判定」數字很大**
`ss` 取不到行程對應，通常是非 root 執行。跑 `./selfheal-ssh.sh debug` 會把原始 `ss`
輸出、`ps` 快照與解析結果全部印出來，能直接看出是哪一步斷掉。

**「已登入 / 認證中」都是 0，只有「無法判定」有數字**
`ps` 抓不到行程標題。`debug` 模式的「ps 用法」若顯示 `none`，代表四種 `ps -o` 寫法
都探測失敗（busybox 精簡版），`apk add procps` 即可。

**「登入失敗」永遠是 0**
先看報告裡的「資料來源」那一行（或 `debug` 的「可用來源」）：

- 顯示 `none` → 讀不到認證日誌，這個 0 是**讀不到**而不是**沒被攻擊**。
  腳本會依序找 `journalctl` → `/var/log/secure*` / `auth.log*` / `messages*` →
  busybox 的 `logread`。Alpine 上通常是 syslog 沒啟用：
  `rc-update add syslog && rc-service syslog start`。
- 顯示 `journal` / 某個檔案 → 來源讀得到而確實 0 筆，那就是真的沒有失敗記錄。

連線層的統計與判讀（認證中堆積、SYN_RECV、來源集中）完全不依賴日誌，不受影響。

**Alpine 上「線上使用者」是空的、session 數卻不是 0**
`who` 需要 utmp，Alpine 與多數容器預設不維護。此時 session 數會改由「已認證且掛在
pts/tty 上的 sshd 行程」推估，畫面上會標注「系統未維護 utmp」。

**PARSED 是空的**
`ss` 版本差異造成解析失敗。腳本已針對 iproute2 3.x（CentOS 7）、4.x 與 `netstat -p`
三種 pid 格式做處理；仍有問題請把 `debug` 模式裡的原始 `ss -tanp` 輸出貼出來回報。

---

## 支援矩陣

| 發行版 | ssh-port.sh | selfheal-ssh.sh |
|---|---|---|
| CentOS 7.9 | ✅ 走主設定檔（OpenSSH 7.4 無 Include） | ✅ |
| RHEL 8 / 9 / 10 | ✅ drop-in + SELinux | ✅ |
| Rocky / AlmaLinux 8 / 9 | ✅ | ✅ |
| Debian 9 / 10 / 11 / 12 | ✅ | ✅ |
| Ubuntu 18.04 / 20.04 / 22.04 | ✅ | ✅ |
| Ubuntu 24.04 | ✅ 含 `ssh.socket` 處理 | ✅ |
| Alpine (OpenRC + busybox) | ✅ | ✅ 完整功能建議加裝 `procps` 並啟用 syslog |

## 為 busybox 做的相容處理

Alpine 的預設環境幾乎每個外部指令都跟 GNU 版本有出入。兩支腳本都改成**先探測能力
再用**，探測不到就降級並在輸出中寫明，不靜默失效：

| 指令 | busybox 的差異 | 處理方式 |
|---|---|---|
| `ps` | 不吃 `-e`，欄位規格較少 | 四種寫法逐一探測，全失敗則標紅提示裝 procps |
| `date -d` | 不支援 `"1 hour ago"` 這種相對時間 | 改用 `-d @epoch`，再退 `-D %s`，最後退回現在時刻 |
| `hostname -I` | 沒有 `-I`，且失敗時 pipeline 仍成功而印出空字串 | 退 `ip -4 -o addr`，再退 `ifconfig` |
| `watch` | 不一定支援 `-t` / `--color` | 解析 `--help` 後只帶支援的選項 |
| `last` | 不吃 `-Fa` | 先試完整格式，失敗退陽春格式，再失敗就註明無此指令 |
| `flock` | 最小安裝可能沒有 | 先確認指令存在再取鎖，避免 `flock \|\| exit 0` 誤判成「已有程序執行中」而整輪不採集 |
| `stat -c %s` | 行為一致，但仍加保險 | 退回 `wc -c` |
| `who` / `last` | 需要 utmp/wtmp，Alpine 預設不維護 | session 數改由 sshd 行程標題推估並標注 |
| syslog | 寫 `/var/log/messages`，或只留在 `logread` 環狀緩衝 | 日誌來源依序探測，含 `logread` |
| 服務管理 | OpenRC 而非 systemd | `rc-service` / `systemctl` / `service` 三路判斷 |

腳本本身也移除了所有 bash 專屬語法（process substitution、`<<<`、`$'...'`），
改用分隔標記串流、`printf | while read`、`printf '\033[..m'` 等 POSIX 寫法。
