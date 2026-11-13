# WINDOWS/

Windows 10 / 11 的系統管理工具箱，用圖形面板操作。跟 Linux 那邊同一個原則：
**遠端操作時不要把自己鎖在門外。**

工具版本：**2.5.0**（Windows 圖形介面自己的版本號，跟 Linux `ops.sh` 無關）

| 檔案 | 用途 |
|---|---|
| `ops-win.ps1` | 一行指令的進入點：下載主程式與排程面板到 `%LOCALAPPDATA%\OPS-command\`、核對 SHA256、再執行 |
| `Win_Admin_Tool.bat` | 本機進入點，雙擊即可（不顯示黑色主控台視窗） |
| `Win_Admin_Tool.ps1` | 主程式與圖形面板 |
| `Win_Schedule_Panel.ps1` | 「自動排程」視窗：登入啟動程式、定時腳本、定時關機／重啟、查看、編輯、刪除這台電腦所有排程 |
| `SHA256SUMS` | 一行指令下載後核對用的雜湊清單 |
| `tools/Update-Sha256Sums.ps1` | 改了程式之後重新產生 `SHA256SUMS` |
| `launcher/` | `OPS-command.exe`（線上啟動器）的原始碼與編譯腳本，見「點兩下的 exe」 |
| `tests/` | 靜態檢查、畫面測試、在桌面上執行測試的工具（見「測試」） |

---

## 兩種跑法

**一行指令**（不必先下載檔案）：

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
irm https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/WINDOWS/ops-win.ps1 | iex
```

第一行是 **Windows PowerShell 5.1（Win10 / Win11 內建的那個）需要的**：它預設不啟用
TLS 1.2，而 GitHub 只收 1.2 以上，不設就是一句 `無法建立 SSL/TLS 通道`。

**本機**（離線、或想自己看過內容再跑）：下載整個 `WINDOWS` 資料夾，雙擊 `Win_Admin_Tool.bat`。

**點兩下的 exe**：`OPS-command.exe`，做的事跟一行指令一樣，見下面「點兩下的 exe」。

幾種方式進去之後完全一樣。不必事先改執行原則（都帶 `-ExecutionPolicy Bypass`，只作用在那一次），
也不必先用系統管理員身分開：**會改系統的按鈕按下去時才問你要不要提權**，唯讀的功能一般帳號就能用。

### 一行指令做了什麼

1. 下載 `Win_Admin_Tool.ps1`、`Win_Schedule_Panel.ps1` 和 `SHA256SUMS`。
2. **兩支程式的 SHA256 都要跟清單對得上才往下走**；對不上就拒絕執行，也不會覆蓋上次留下的副本。
3. 放到 `%LOCALAPPDATA%\OPS-command\`，用 `powershell -File` 開啟主面板。

為什麼要先落地、不直接 `iex` 主程式：提權（`Start-Process -Verb RunAs`）只能指定檔案；而且主程式的
介面靠 `.GetNewClosure()`，只有用 `-File` 執行時腳本才在全域範圍，閉包才看得到它的函式。

| 開關（環境變數） | 作用 |
|---|---|
| `$env:OPS_RAW_BASE` | 改從自己的 fork、內網鏡像或其他分支下載（新版提示也從這裡檢查） |
| `$env:OPS_USE_CACHED=1` | **下載失敗**時改用上次留下的副本。SHA256 對不上不算下載失敗，不會改用舊副本 |

`SHA256SUMS` 跟程式來自同一個地方，所以它防的是「下載不完整、被代理或入口網頁換掉、單一檔案被竄改」；
repo 本身被入侵時兩者會一起被換掉，這裡擋不住。剛推上新版的幾分鐘內 GitHub 快取可能新舊混雜，稍候再試即可。

### 點兩下的 exe（OPS-command.exe）

> **目前還沒提供下載**：簽章完成後才會放上 GitHub Releases。想先用可以自己編譯（見「維護：改了程式之後」），或用上面的一行指令。

給不想開 PowerShell 打指令的人。`OPS-command.exe` 是很小的**線上啟動器**，做的事和一行指令完全一樣：
從 GitHub 下載最新的程式與 `SHA256SUMS`、核對、放到 `%LOCALAPPDATA%\OPS-command\`、開主面板。
程式本身不在 exe 裡，所以工具改版不用重新下載 exe，每次點開都是 GitHub 上的最新版；
也因此**一定要能連上 GitHub**，離線請用本機那種跑法。

- 一般權限執行，跟一行指令一樣，要改系統時主面板才問提權。
- 核對失敗、下載失敗的處理也一樣：對不上就拒絕執行、不覆蓋舊副本；連不上時預設不用舊副本，
  要用就從命令列加 `--use-cached`。`--base-url <網址>` 或 `OPS_RAW_BASE` 可改用自己的 fork／鏡像。
- 黑色視窗會顯示下載與核對結果，主面板開起來後自己關掉；出錯時停在畫面上等你按 Enter。

**第一次執行時 Windows 可能跳出藍色的「Windows 已保護您的電腦」**（SmartScreen）。這是 Windows 對
「還不認識的程式」的提醒，不代表有毒。確認檔案是從本專案的 GitHub Releases 下載的、SHA256 對得上之後：

1. 按「**其他資訊**」。
2. 確認「發行者」：已簽章的版本會顯示發行者名稱；顯示「未知的發行者」表示這份沒有簽章。
3. 按「**仍要執行**」。

核對 exe 的 SHA256（跟 Releases 上的 `OPS-command.exe.sha256` 比對）：

```powershell
Get-FileHash .\OPS-command.exe -Algorithm SHA256
```

編譯與簽章見「維護：改了程式之後」。

> **不要把 `ops-win.ps1` 下載下來用 `-File` 執行。** 它刻意存成 UTF-8 無 BOM（`irm | iex` 需要），
> Windows PowerShell 5.1 讀檔時會當成系統字碼頁（繁中是 950），中文會把引號吃掉而解析失敗。
> 在 PowerShell 視窗裡打 `.\Win_Admin_Tool.ps1` 也沒關係：主程式偵測到不是用 `-File` 啟動，會自己另開一個。

---

## 功能一覽

主面板左側是分類，點分類展開、點功能開出那個功能自己的視窗。每個視窗上方顯示**目前的實際狀態**，
改完自動重讀。標「改系統」的按下去會問提權，並寫進操作記錄。

| 分類 | 功能 | 改系統 |
|---|---|---|
| 遠端桌面 RDP | 更換 RDP Port（新舊並存＋看門狗） | ✔ |
| | RDP 只允許指定來源 IP（看門狗） | ✔ |
| | RDP 多工作階段（開／關） | ✔ |
| | CredSSP 加密預示修復 | ✔ |
| | RDP 登入紀錄 | — |
| 帳號與安全 | 帳號鎖定防護（門檻） | ✔ |
| | RDP 暴力破解自動封鎖（Windows 版 fail2ban） | ✔ |
| | 內建 Administrator 帳戶（啟用／停用） | ✔ |
| | 變更本機帳號密碼 | ✔ |
| 系統與更新 | Windows 更新（停止／還原） | ✔ |
| | Microsoft Store 自動更新 | ✔ |
| | 常用登錄檔設定（勾選開關，套用前自動備份） | ✔（整台電腦的項目） |
| | Hyper-V／VMware 切換 | ✔（要重開機） |
| | 時間與時區 | ✔ |
| | 常用軟體安裝（winget） | ✔ |
| 網路與防火牆 | Ping（ICMP） | ✔ |
| | OpenSSH Server（一鍵啟用／停用） | ✔ |
| | IP / DNS 設定（新舊並存＋看門狗） | ✔ |
| | 防火牆 Port 管理 | ✔ |
| | 批量新增 IP | ✔ |
| 磁碟管理 | 變更磁碟機代號、格式化磁碟區、清除整顆磁碟 | ✔（格式化、清除會刪資料） |
| | 唯讀磁碟視覺化 | — |
| 檢查與紀錄 | 檢查系統現況（可匯出成文字檔） | — |
| | 事件檢視器 | — |
| | 操作記錄 | — |
| 自動排程 | 開啟自動排程管理 | ✔（只動本面板建的排程） |
| | └ 所有排程：查看、編輯、刪除、停用／啟用、立即執行、停止、還原備份 | ✔（改之前自動備份） |
| | └ 執行時機：單次、每天、每週幾、每隔 5 分鐘～12 小時、登入時、開機時 | — |

主面板開啟後會在背景檢查新版：線上版本比較新時，標題列顯示「有新版 x.y.z，重新執行一行指令即可更新」。
離線或檢查失敗都安靜略過，不跳訊息。

長時間的動作（Hyper-V、校時、Windows 更新、winget、事件檢查…）在背景執行，畫面不會卡住。
**會改系統的作業做完前不能關視窗**（中途拔掉比等它做完更糟）；只是查詢的可以直接關。

### 用完自動清除

主面板右上角有「**關閉時清除本工具的檔案**」（預設不勾）。勾的時候會先跳視窗說明會刪什麼，
確定之後，**關閉主面板時**刪掉：

- `%LOCALAPPDATA%\OPS-command\` 整個資料夾：下載的程式、操作記錄、錯誤紀錄、匯出的檔案（存在預設位置的）、排程與登錄檔備份、測試輸出。
  匯出的檔案要留，請先搬走。
- PowerShell 指令歷史（PSReadLine 的 `*_history.txt`）裡跟 OPS 有關的行，以及緊接在它前面的那行 TLS 設定；
  其他指令不動。還開著的 PowerShell 視窗裡按方向鍵上仍看得到，關掉那個視窗就沒了。

不會刪：Windows 事件記錄（只能整個記錄檔清，會連別的程式一起刪）、以 SYSTEM 執行的狀態與排程
（看門狗確認或還原後本來就會自己刪；暴力破解封鎖、RDP 來源限制、自動排程是你要它們繼續運作的）、
`OPS-command.exe` 本身（它在你自己放的位置，例如「下載」資料夾，要刪請自己刪）。

- 按「以系統管理員身分重新啟動」時，勾選會帶到新的管理員面板，舊面板關閉時不清除（新面板還要用這些檔）。
- 還有其他 OPS 面板開著時不清除，並告訴你是哪一個；在最後關的那個勾選即可。

---

## 會斷線的動作：怎麼保護你

### 更換 RDP Port

改 Port 一定要重啟遠端桌面服務（TermService），目前這條 RDP 連線必然會斷；新 Port 若被雲端安全群組、
路由器或防火牆擋住，就再也連不回來。做法跟 [`../SSH/ssh-port.sh`](../SSH/README.md) 一致：

```
更換 Port
  ├─ 新 Port 被別的程式佔用 → 拒絕
  ├─ 防火牆放行新 Port（舊 Port 規則保留；已有同名規則就不重複建）
  ├─ 註冊看門狗（SYSTEM 排程，預設 10 分鐘）── 建不起來就不做
  ├─ 寫入登錄檔後讀回來驗證，沒生效就全部撤回
  └─ 問「現在重啟遠端桌面服務嗎？」→ 是 → 這條連線斷
        │
        ▼
  用新 Port 連回來
  ├─ 連得上 → 按「確認新 Port 可用」→ 取消看門狗，可選擇收掉舊 Port 規則
  └─ 連不上 → 什麼都別做，時限到自動改回舊 Port、收掉這次建的新 Port 規則
```

看門狗是排程工作，不是背景行程：就算面板被關、使用者登出、整條 RDP 斷線，照樣會執行。
還原指令用 `-EncodedCommand` 放在排程本身，不落地成檔案（一般使用者改不到）。

> **雲端主機還要另外開安全群組／網路 ACL。** 本機防火牆放行不代表外面連得進來。

### RDP 只允許指定來源 IP

白名單以外的來源連不進遠端桌面。只擋 RDP 的 Port（TCP 與 UDP），SSH 等其他服務不受影響，可以當救援管道。

- **做法**：一條「封鎖」規則，封鎖範圍＝白名單以外的所有位址（IPv4 與 IPv6）。Windows 防火牆的封鎖規則優先於放行規則，
  所以不管原本有幾條放行 RDP 的規則都擋得住，也不去改別人建的規則。
- **套用前**：目前所有 RDP 連線的來源都必須在白名單裡，否則拒絕套用（斷線重連就會被擋在外面）；算出封鎖範圍後再核對一次。
- **看門狗**：先建好才動規則，時限內沒按「確認可以連線」就恢復成套用前（原本沒限制 → 拿掉規則；原本有 → 回到上一份白名單）。
- **確認**：已經建立的連線不受新規則影響，所以要另外開一條**新的**遠端桌面連線；面板會列出「套用之後才建立」的連線當作證據。
- **跟換 RDP Port 連動**：換 Port 進行中新舊兩個 Port 都擋，確認或還原後只擋目前的 Port。
- 你的 IP 會變（家用網路、手機熱點）就不適合用；防火牆設定檔關閉的網路上規則不會生效，面板會提醒。

### IP / DNS 設定

- 位址的新增、移除、替換都先寫狀態、建好看門狗才動網卡；時限內沒按「確認 IP 變更」就自動還原。
- **替換分兩階段**：先加新位址（新舊並存），要有從「別台機器」連到新位址的連線，才准確認、才移除舊位址。
- 有連線正在用的位址、網卡上唯一的位址、移除後閘道會斷的位址，都不准移除。
- 新加的位址設「只收不發」（SkipAsSource），這台主動連出去仍用原本的位址。
- 只做 IPv4、不改閘道；DHCP 網卡只能改 DNS。
- DNS 改錯不會斷遠端連線，所以不開看門狗，改用實際解析驗證：新 DNS 查不到就不改；改完系統解析失敗就自動改回。

### OpenSSH Server

- **啟用**：沒裝就裝（Windows 選用功能，要能連 Windows Update）→ 設 Port → 防火牆 `OPS-SSH-<Port>` → 開機自動啟動。
  設定一樣就什麼都不改、不重啟 sshd，重按是安全的。
- **sshd 執行中不換 Port**（會斷線、沒有看門狗）；要換請先停用再用新 Port 啟用。
- **停用**：停止並停用 sshd、停用放行規則（不刪除），確認視窗會列出會被斷掉的 SSH 連線。
- 管理員帳號的金鑰放在 `C:\ProgramData\ssh\administrators_authorized_keys`，不是使用者資料夾。

### RDP 暴力破解自動封鎖

Windows 沒有 fail2ban，帳號鎖定又擋不住來源（攻擊者一直猜，被鎖的是合法使用者）。這個功能讀
Security 4625（登入失敗）的來源 IP，同一個 IP 在時間窗內失敗達到門檻，就建防火牆封鎖規則，到期自動解封。

- 以 SYSTEM 排程 `OPS-RdpGuard` 每 1 分鐘跑一次；預設只擋 RDP Port，可改成擋全部連入。
- 白名單一定生效：本機位址固定加入；**啟用時會把「當下連在這台任何監聽 Port 上的來源」自動加入**。
  確認視窗會逐一列出，**請核對**——測試時就出現過一個不認得的來源（可能是掃描連線），不是自己的就先按「否」把它拿掉。
- 「試算」用目前設定跑一輪但不封鎖，先看會封到誰。
- 稽核「登入失敗」沒開就不會有 4625，面板會提醒並提供「開啟稽核登入失敗」。

> **防火牆設定檔關閉時，封鎖規則不會生效。** 面板狀態會標出哪個設定檔是關的。

---

## 其他會改系統的功能

| 功能 | 做法與防呆 |
|---|---|
| Windows 更新 | 停止前把 wuauserv、UsoSvc 原本的啟動設定記在 HKLM；「還原」照原值恢復、拿掉停止時加的更新原則。Windows 的自我修復（WaaSMedic）可能幾秒內改回來，畫面會如實顯示 |
| 帳號鎖定防護 | 設門檻；設 0（關閉）會再問一次 |
| 內建 Administrator | 以 SID 結尾 -500 辨識（被改名也找得到）；停用的正是自己登入的帳號時會特別警告 |
| 變更密碼 | 兩次輸入要一致；操作記錄只記帳號、不記密碼 |
| 格式化磁碟區 | 拒絕 `C:`；要再輸入一次代號；最後再確認一次 |
| 清除整顆磁碟 | 拒絕系統／開機磁碟；要再輸入一次磁碟編號、再輸入大寫 `ERASE`、最後再確認一次 |
| 批量新增 IP | 拒絕 DHCP 網卡（加上固定位址會讓整張網卡變固定 IP，遠端操作等於斷線） |
| 常用登錄檔設定 | 只能開關表上列出的項目，不能寫任意機碼；套用前把原本的值存成 JSON（`reg-backup\`），「還原備份」只認得表上的項目，備份檔被改過也寫不到別的地方；整台電腦的項目要系統管理員 |
| 常用軟體安裝 | 只用官方 winget 來源、`--exact --id`；安裝檔 SHA256 由 winget 依官方清單核對；裝完用 `winget export` 回頭確認真的在 |
| 自動排程 | 前三頁只動本面板建立的 `OPS-Task-*` 排程。「所有排程」分頁可以改任何排程，但：編輯、刪除前一定先把原本的設定備份成 XML（`task-backup\`，可用「還原備份」放回）；每個修改都要再確認一次；刪除 Microsoft 的系統排程要再輸入一次排程名稱，並建議改用停用；OPS-command 自己的看門狗、守護排程（`OPS-*`）不從這裡改；「用帳號密碼執行」的排程不在這裡編輯（要重新輸入密碼，請用工作排程器）；不是系統管理員時改不了系統排程，會說明原因 |

### 常用登錄檔設定

系統與更新 → 常用登錄檔設定。每一項只有「開啟」與「Windows 預設」兩種狀態：勾選＝開啟，取消勾選＝改回預設；
勾選跟目前不一樣的列會標黃底，按「套用變更」才寫入。滑鼠停在某一列會顯示完整說明與登錄位置。

| 分類 | 項目 | 範圍 |
|------|------|------|
| 檔案總管 | 顯示副檔名、顯示隱藏的檔案、一開就是「本機」、Windows 11 舊版右鍵選單 | 目前使用者 |
| 工作列 | 時鐘顯示秒數 | 目前使用者 |
| 安全／隱私 | 關閉自動播放、不記錄最近開過的檔案、關閉廣告識別碼 | 目前使用者 |
| 系統 | 允許超過 260 字元的長路徑、關閉快速啟動、開機時 NumLock 開啟、關閉 Windows 錯誤報告 | 整台電腦 |
| 伺服器 | 登入時不自動開伺服器管理員、關機不用填原因 | 整台電腦（只有 Windows Server） |

- 「目前使用者」的項目只影響開面板的那個帳號；用另一個管理員帳號提權時，改到的是那個帳號。
- 要重開檔案總管才生效的項目，套用後會問要不要現在重新啟動檔案總管（工作列會消失一兩秒）。
- 不適用這台系統的項目（例如 Windows 10 上的「舊版右鍵選單」）顯示「只有 Win11」、不能勾。

### 常用軟體安裝（winget）

推薦清單打勾就裝，已經裝了的顯示版本、不能勾：Nmap、WinMTR、Sysinternals Suite、Wireshark、PuTTY、WinSCP、
7-Zip、Notepad++、Git、PowerShell 7、Windows Terminal、Everything、TreeSize Free、CrystalDiskInfo、Chrome、
Firefox、VC++ 2015-2022、.NET 8 桌面執行環境、windows_exporter。其他軟體用「搜尋」分頁找，安裝前會先查出發行者給你確認。

- Wireshark 的抓包驅動 Npcap 授權不允許自動安裝，裝完要另外到 npcap.com 手動裝。
- windows_exporter 會建立服務、監聽 9182 Port。
- 找不到 winget 時，Windows 10/11 會顯示安裝說明與「開啟 Microsoft Store」按鈕；Windows Server 沒有驗證過的安裝方式，只會說明不支援。
- winget 是跟著**每個帳號**安裝的：輸入另一個管理員帳號的密碼來提權時，那個帳號可能沒有 winget。

### 事件檢視器

打開就在背景檢查最近 7 天（可改 24 小時／30 天），每一類一張卡片：✔ 沒有異常／⚠ N 筆需要注意／需要管理員。
點卡片看清單，清單只有「時間、這代表什麼、建議怎麼做」，需要注意的黃底排最前面；事件 ID、來源、原始訊息
在雙擊的詳細內容與匯出的 CSV 裡。

| 卡片 | 查什麼 |
|---|---|
| 非預期關機 / 重開機 | Kernel-Power 41、EventLog 6008、User32 1074（誰要求關機）、WER 1001 |
| 藍畫面與硬體錯誤 | BugCheck 1001、WHEA-Logger 17/18/19/20/47 |
| 磁碟與儲存 | disk 7/11/51/153、Ntfs 55/98/130/137、chkdsk 結果 |
| 服務異常 | Service Control Manager 7000～7045（含 7040「啟動類型被改」） |
| 應用程式當機 / 無回應 | Application Error 1000、Application Hang 1002、.NET Runtime 1026、Windows Error Reporting 1001 |
| 登入與帳號 | Security 4625/4740/4648、RDP 1149 與 21/23/24/25 |
| Windows 更新 | WindowsUpdateClient 19/20/43 |

白話說明對照過實際事件的內容（例如 Ntfs 98 是「磁碟健康檢查的結果」，只有層級是警告以上才算要注意）。
這裡只讀不寫，沒有「清除記錄檔」。只有「登入與帳號」需要管理員；讀不到會標「需要管理員」，不會說成「沒有紀錄」。

---

## 狀態與紀錄放在哪

以 SYSTEM 執行的動作（看門狗、暴力破解封鎖）**不碰一般使用者寫得到的路徑**：
`%ProgramData%` 的子目錄預設讓 `BUILTIN\Users` 建檔，誰先放一個同名檔就成了擁有者。所以狀態存 HKLM、
還原指令放在排程本身、紀錄寫 Windows 事件記錄。

| 位置 | 內容 |
|---|---|
| `%LOCALAPPDATA%\OPS-command\` | **工具寫出的檔案都在這裡**（「關閉時清除本工具的檔案」刪的就是這個資料夾）：一行指令與 exe 下載的程式、`actions.log`（操作記錄）、`error.log`（出錯時的完整訊息與呼叫堆疊，回報問題用）、匯出檔的預設位置、「所有排程」修改前的備份（`task-backup\`）、「常用登錄檔設定」套用前的備份（`reg-backup\`）、測試工具的輸出（`tests\`）。「操作記錄」視窗有「開啟資料夾」按鈕 |
| `HKLM\SOFTWARE\OPS-command\RdpPort` | 換 RDP Port 進行中的狀態 |
| `HKLM\SOFTWARE\OPS-command\NetChange` | IP 變更進行中的狀態 |
| `HKLM\SOFTWARE\OPS-command\RdpGuard` | 暴力破解封鎖的設定、封鎖清單 |
| `HKLM\SOFTWARE\OPS-command\RdpAllow` | RDP 來源白名單、等待確認的狀態 |
| `HKLM\SOFTWARE\OPS-command\WindowsUpdate` | 停止 Windows 更新前的原始設定（還原後刪除） |
| 排程 `OPS-RdpPort-Watchdog`、`OPS-NetChange-Watchdog`、`OPS-RdpAllow-Watchdog` | 看門狗（SYSTEM，到期自動還原、自己刪除） |
| 排程 `OPS-RdpGuard` | 暴力破解封鎖（SYSTEM，每 1 分鐘） |
| 排程 `OPS-Task-*` | 自動排程面板建立的工作 |
| 事件記錄「應用程式」、來源 `OPS-command` | 100 看門狗、200／201 操作成功／失敗、300／301／302 封鎖／解封／封鎖失敗 |

查有沒有看門狗還在等確認：

```powershell
Get-ScheduledTask -TaskName 'OPS-*Watchdog' -ErrorAction SilentlyContinue
```

---

## 維護：改了程式之後

1. `Win_Admin_Tool.ps1` 開頭的 `$Script:ToolVersion`：修 bug 加第三段、加功能加第二段、介面大改加第一段。主面板用這一行比對新版，格式不要改。
2. **重新產生 `SHA256SUMS`，跟程式一起 commit**，不然一行指令會因為「對不上」拒絕執行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\tools\Update-Sha256Sums.ps1          # 產生
   powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\tools\Update-Sha256Sums.ps1 -Check   # 只核對
   ```

   雜湊是「CRLF 換成 LF 之後」算的，跟 GitHub raw 給的內容一致，在 Windows 或 Linux 的 checkout 上算結果都一樣。
3. 跑「測試」那一節的靜態檢查，最好也跑一次畫面測試。

`OPS-command.exe` 只是啟動器，**工具改版不用重新編譯**；只有改了 `launcher/OpsLauncher.cs` 才要重出：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\launcher\build.ps1
```

用 Windows 內建的 .NET Framework 4.x 編譯器，不必裝 Visual Studio；產物在 `WINDOWS\launcher\dist\`（不進 git，發布放 GitHub Releases），
同時產生 `OPS-command.exe.sha256`。簽章參數三選一，不給就是未簽章版本：

| 參數 | 用在 |
|---|---|
| `-CertThumbprint <指紋>` | 憑證已裝在這台電腦（USB 金鑰、雲端簽章服務的用戶端），從「目前使用者\個人」存放區取用 |
| `-PfxPath <檔案>`（密碼放 `OPS_SIGN_PFX_PASSWORD`） | 能匯出成 .pfx 的憑證 |
| `-TrustedSigningMetadata <json> -DlibPath <dll>` | Azure Trusted Signing |

簽章需要 Windows SDK 的 `signtool.exe`（找不到時用 `-SignTool` 指定），簽完會自動 `signtool verify` 一次。

---

## 測試

`tests/` 裡的工具都要在 **Windows PowerShell 5.1** 跑。

| 工具 | 做什麼 | 會改系統 |
|---|---|---|
| `Test-Static.ps1` | 編碼（BOM、CRLF）、語法、點不到的函式、閉包少帶變數、閉包呼叫區域函式、呼叫不存在的指令、對唯讀自動變數賦值（`$home`）、PowerShell 7 才有的語法 | 不會 |
| `Test-Gui.ps1` | 開主面板、逐一點每個功能、截圖、記錄狀態，抓 .NET 未處理例外與錯誤訊息框；前後比對系統設定 | 預設不會；`-Modify` 會改並自動還原（Store、校時、排程、實裝並移除 PuTTY） |
| `Invoke-Interactive.ps1` | 從 SSH 等沒有桌面的地方，把腳本丟到已登入的桌面上執行並取回輸出 | 看跑的是什麼 |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\tests\Test-Static.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\tests\Invoke-Interactive.ps1 -Script C:\path\WINDOWS\tests\Test-Gui.ps1 -Arguments "-OutDir C:\gui-test"
```

畫面測試要有登入中的桌面（RDP 視窗開著、**不要最小化**，否則截圖會失敗），而且要用 `-File` 執行（`Invoke-Interactive.ps1` 已經這樣做）。

靜態檢查拿改版前的原版跑會抓到 23 項（含 `$home`、側邊欄閉包、`'D'..'Z'` 三個實機會壞的 bug），現在 0 項。

---

## 編碼

| 檔案 | 編碼 |
|---|---|
| `Win_Admin_Tool.ps1`、`Win_Schedule_Panel.ps1`、`tests\*.ps1`、`tools\*.ps1` | UTF-8 **含** BOM、CRLF（5.1 用 `-File` 讀檔，沒 BOM 會當成系統字碼頁） |
| `ops-win.ps1` | UTF-8 **無** BOM、CRLF（要被 `irm \| iex`；開頭有 BOM 的字串 `iex` 會失敗） |
| `launcher\OpsLauncher.cs`、`launcher\build.ps1` | UTF-8 含 BOM、CRLF（C# 原始碼用 `/codepage:65001` 編譯） |
| `Win_Admin_Tool.bat` | 純 ASCII、CRLF（cmd 用主控台字碼頁解析批次檔，非 ASCII 會隨地區設定而壞） |

repo 根目錄的 `.gitattributes` 強制 `*.bat` / `*.ps1` 用 CRLF。

工具刻意**不**把主控台改成 UTF-8：繁中 Windows 上改了之後 `w32tm` 輸出變亂碼、`net`、`bcdedit` 變成英文。
需要讀 UTF-8 輸出的指令（winget）另外用 Process 直接以 UTF-8 讀。

---

## 實測紀錄與已知限制

2026-11 在一台 Windows 10 專業版 22H2（繁中、字碼頁 950、KVM 雲端虛擬機）上，**每個功能都在 RDP 桌面上實際按過按鈕**，
核對系統實際狀態並還原；包含 RDP 換 Port 兩輪（看門狗自動還原、確認後保留）、停用再啟用 SSH、
Windows 更新停止／還原、臨時帳號的鎖定與改密碼、在 1GB 虛擬磁碟上改代號／格式化／清除、
實際安裝並移除軟體、一行指令（`irm | iex`）對本機假網站的 SHA256 核對；`OPS-command.exe` 從 GitHub 下載核對、被竄改／入口網頁／連不上／`--use-cached` 各種情況，以及在桌面上點開後主面板可見；「關閉時清除」的實際刪除與指令歷史只刪 OPS 那幾行。過程中修掉的問題記在 [CHANGELOG](../CHANGELOG.md)。

還沒驗證或有限制的：

- **Hyper-V 元件啟用／移除與重開機後的效果**：測試機沒開放巢狀虛擬化，只驗證了「Hyper-V 優先／VMware 優先」的開機設定。
- **防火牆設定檔關閉的機器上，封鎖類功能（RDP 來源限制、暴力破解封鎖）不會生效**；測試機的 Public 設定檔是關的，這兩個功能只驗證了規則建得對、看門狗與還原正確，還沒驗證「真的擋得住」。
- **Windows Server 2019 / 2022** 沒測過。
- 「RDP 多工作階段」在家用／專業版受系統檔 `termsrv.dll` 限制，本工具只放寬工作階段規則，不修改系統檔。
- Hyper-V 與 VMware 的切換要重新開機才生效。
- **帳號鎖定在對外的機器上會反過來把自己擋在外面**：攻擊者不必猜中密碼，一直猜就能讓帳號一直被鎖，
  被鎖時連 SSH 都會在認證前被切斷。對外的機器請用「RDP 暴力破解自動封鎖」或限制來源 IP，不要只靠鎖定門檻。
