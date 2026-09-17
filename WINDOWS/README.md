# WINDOWS/

Windows 10 / 11 的系統管理工具箱，PowerShell 寫的分類選單。跟 Linux 那邊同一個原則：
**遠端操作時不要把自己鎖在門外。**

| 檔案 | 用途 |
|---|---|
| `ops-win.ps1` | 一行指令的進入點：下載主腳本到 `%ProgramData%\OPS-command\` 再執行 |
| `Win_Admin_Tool.bat` | 本機進入點，雙擊即可（設好編碼並用 `-ExecutionPolicy Bypass` 呼叫 .ps1） |
| `Win_Admin_Tool.ps1` | 本體，1420 行的 PowerShell 分類選單 |

## 兩種跑法

**一行指令**（不必先下載檔案，對應 Linux 那邊的 `bash <(curl …)`）：

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
irm https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/WINDOWS/ops-win.ps1 | iex
```

第一行是 **Windows PowerShell 5.1（Win10 / Win11 內建的那個）需要的**：它預設不啟用
TLS 1.2，而 GitHub 只收 1.2 以上，不設就是一句 `無法建立 SSL/TLS 通道`。PowerShell 7
可以省略，加了也無害。

**本機**（離線、或想自己看過內容再跑）：

```
下載整個 WINDOWS 資料夾 -> 雙擊 Win_Admin_Tool.bat
```

兩種方式進去之後完全一樣。不必事先改執行原則（`.bat` 與 `ops-win.ps1` 都帶
`-ExecutionPolicy Bypass -NoProfile`，只作用在那一次執行），也不必先用系統管理員身分
開啟：**修改類功能會在需要時才問你要不要提權**，唯讀的「檢查現況」一般帳號就能用。

### 一行指令為什麼要先落地，不直接把主腳本 `iex` 掉

`ops-win.ps1` 做的事只有三件：把 `Win_Admin_Tool.ps1` 下載到
`%ProgramData%\OPS-command\`、驗一下內容不是被攔截的網頁、然後用 `-File` 執行它。

| 原因 | 說明 |
|---|---|
| **提權需要實體路徑** | `Start-Process -Verb RunAs` 只能指定一個檔案，沒有「把這段程式碼交給新的 elevated 行程」的辦法。管線跑進來的腳本 `$PSCommandPath` 是空的，直接 `iex` 主腳本的話「以系統管理員身分重新啟動」會壞掉 |
| **狀態檔本來就在那** | RDP 換 port 的狀態、還原腳本與看門狗記錄都落在 `%ProgramData%\OPS-command\`，主腳本放同一個目錄最直覺 |
| **編碼** | 主腳本是 UTF-8 **with BOM**；字串化之後餵給 `iex`，在 PowerShell 5.1 上不保證解析得過。存成檔案用 `-File` 執行反而最穩 |

> 主腳本本身也補了保險：真的被人用管線跑起來（`$PSCommandPath` 是空的），要提權時
> 它會先把自己的原始碼寫到 `%ProgramData%\OPS-command\Win_Admin_Tool.ps1` 再
> `RunAs`，寫不進去才放棄並叫你自己開系統管理員視窗。

**下載失敗時不會默默用舊檔**。`%ProgramData%` 一般使用者也寫得進去，直接跑上次留下的
副本等於相信那份檔案沒被動過手腳——要用可以，但得你明確決定：

```powershell
irm https://raw.githubusercontent.com/.../WINDOWS/ops-win.ps1 | iex   # 下載失敗 -> 停下來告訴你
$env:OPS_USE_CACHED=1; irm https://.../ops-win.ps1 | iex              # 明確允許用舊副本
```

指到自己的 fork、內網鏡像或其他分支：設 `$env:OPS_RAW_BASE`（對應 Linux 那邊的
同名變數），或用檔案跑法的 `-BaseUrl` 參數。`irm | iex` 沒辦法帶參數，所以這兩個
開關都吃環境變數。

---

## 第一次在 Windows 上跑：建議的順序

這支從來沒有在 Windows 上實際執行過（見最後的「已知限制」），所以第一次跑請照這個順序，
**把最危險的留到最後**：

| 順序 | 做什麼 | 要確認的 |
|---|---|---|
| 1 | **用一般帳號**（不要右鍵「以系統管理員身分執行」）開 PowerShell，跑上面那兩行一行指令 | 下載有沒有成功、選單有沒有出來 |
| 2 | 看主選單的中文有沒有亂碼，按 `S` 檢查現況 | 唯讀功能一般帳號就能用，數字有沒有正常 |
| 3 | 挑一個會改東西但無害的功能（例如 `D` → 開一個沒人用的 Port，測完自己關掉） | **提權流程**：答 `Y` 之後有沒有跳 UAC、有沒有開出新的提權視窗 |
| 4 | **最後**才試 `A` → `1` 換 RDP Port | 見上面那節；**必須先確定有主控台能救** |

第 3 步是重點——一行指令跑進來時腳本沒有實體路徑，提權要靠「把自己寫到
`%ProgramData%` 再 `RunAs`」那條退路。提權後可以確認檔案在不在：

```powershell
dir $env:ProgramData\OPS-command\
```

第 4 步做完，確認看門狗排程有被收掉：

```powershell
Get-ScheduledTask -TaskName OPS-RdpPort-Watchdog -ErrorAction SilentlyContinue
```

**只能透過 RDP 連進去、又沒有主控台（雲端 Console / iDRAC / VNC）的機器，做到第 3 步就停。**
換 port 一定會斷線，沒有救援管道時看門狗雖然會自動還原，但那 10 分鐘你是完全連不上的。

常見的失敗長相：

| 訊息 | 意思 |
|---|---|
| `無法建立 SSL/TLS 通道` | 一行指令的第一行沒生效（Windows PowerShell 5.1 預設不用 TLS 1.2） |
| `因為這個系統上已停用指令碼執行` | 執行原則擋住了，`-ExecutionPolicy Bypass` 沒吃到 |
| UAC 跳出來但新視窗一閃就沒 | 提權拿到的路徑是空的（1.10.0 修掉的問題，若復現請回報） |

---

## 選單

```
  A. 遠端桌面 (RDP)     - 換 Port / 確認 / 還原 / 多開 / CredSSP / 登入紀錄
  B. 帳號與安全         - 鎖定 / Administrator / 改密碼
  C. 系統與更新         - Windows 更新 / Store / 時間時區
  D. 網路與防火牆       - Ping / Port / 批量加 IP
  E. 虛擬化 (Hyper-V)   - 與 VMware 切換 / 啟用停用
  F. 磁碟管理           - diskpart 視覺化
  S. 檢查現況           - 驗證設定 (免管理員)
  L. 事件檢視器         - 依症狀查事件紀錄 (免管理員)
```

`S` 與 `L` 是僅有的兩個**唯讀**入口，按了不會改動任何設定；A～F 都會動到系統。

`L` 用「症狀」而不是事件 ID 分類，因為排錯的人腦袋裡是症狀：

| 情境 | 查什麼 |
|---|---|
| 1. 非預期關機 / 重開機 | Kernel-Power 41、EventLog 6008、User32 1074（**誰**要求關機的）、WER 1001 |
| 2. 藍畫面與硬體錯誤 | BugCheck 1001（停止碼與傾印檔位置）、WHEA-Logger 17/18/19/20/47 |
| 3. 磁碟與儲存 | disk 7/11/51/153、Ntfs 55/98/130/137、chkdsk 結果 |
| 4. 服務異常 | SCM 7000～7045，含 **7040「啟動類型被改」** |
| 5. 應用程式當機 / 無回應 | Application Error 1000、Application Hang 1002、.NET Runtime 1026、Windows Error Reporting 1001 |
| 6. 登入與帳號 | Security 4624/4625/**4740（帳號被鎖定）**/4648、RDP 1149 與 21/23/24/25 |
| 7. Windows 更新 | WindowsUpdateClient 19/20/43 |

另有 `C. 自訂查詢`，自己指定記錄檔與事件 ID，給情境清單沒涵蓋到的狀況用。

每個情境進去後：輸入編號展開完整內容與原始 EventData、`T` 切換 24 小時 / 7 天 / 30 天、
`E` 匯出 CSV（存到桌面，UTF-8 含 BOM，Excel 直接開不會亂碼）。

**這裡只讀不寫，沒有「清除記錄檔」。** 清除無法復原，而且會摧毀事後稽核的能力——
第 4 項和第 6 項之所以有用，正是因為紀錄還在。真要清請自己用 `wevtutil cl`。

只有第 6 項需要管理員（Security 記錄檔一般帳號讀不到），而且是**進去那一項才問**，
不是一進 `L` 就擋。讀不到的時候會明確標示「讀不到」，不會印成「沒有紀錄」——
這兩者混為一談會讓「沒權限看」被當成「沒有人嘗試登入」。

---

## 換 RDP Port 不會把你鎖在外面

這是整個工具最需要小心的功能，做法跟 [`../SSH/ssh-port.sh`](../SSH/README.md) 一致。

**為什麼危險**：改 port 一定要重啟 `TermService`，目前這條 RDP 連線必然會斷。新 port
若被雲端安全群組、路由器或防火牆擋住，就再也連不回來，只能走主控台（雲端 Console /
iDRAC / iLO）。

**流程**：

```
  A -> 1  更換 RDP 連接埠
        │
        ├─ 檢查新 port 有沒有被別的程式佔用（佔用的話 RDP 根本起不來）
        ├─ 防火牆放行新 port，舊 port 的規則保留
        ├─ 註冊看門狗排程（預設 10 分鐘）
        ├─ 寫入登錄檔後『讀回來驗證』，沒生效就自動撤回
        └─ 重啟 TermService（本連線中斷）
        │
        ▼
  ★ 用『另一台電腦』連 IP:新Port
        │
        ├─ 連得上 ──→ 回 A -> 2 確認新 Port 可用（取消看門狗、可收掉舊規則）
        │
        └─ 連不上 ──→ 什麼都別做，時限到了自動還原
                       （或從主控台進來選 A -> 3 立即還原）
```

**看門狗是排程工作（`OPS-RdpPort-Watchdog`），不是背景行程** —— 就算這支腳本被關掉、
使用者登出、整條 RDP 斷線，還原動作照樣會由系統執行。

**看門狗建不起來就不做這次變更。** 沒有自動還原機制的換 port 不能接受，寧可不換。

| 路徑 | 用途 |
|---|---|
| `%ProgramData%\OPS-command\rdp-port.state` | 進行中變更的狀態（舊 port / 新 port / 時間） |
| `%ProgramData%\OPS-command\rdp-revert.ps1` | 看門狗執行的還原腳本 |
| `%ProgramData%\OPS-command\rdp-port.log` | 看門狗實際觸發過的記錄 |
| 排程工作 `OPS-RdpPort-Watchdog` | 看門狗本體，以 SYSTEM 身分執行 |

主選單、A 子選單與「S 檢查現況」都會在有未確認的變更時把狀態標出來，
不會讓你忘記自己正處在中途狀態。

> **雲端主機還要另外開安全群組 / 網路 ACL。** 本機防火牆放行不代表外面連得進來，
> 這是換 port 之後連不上最常見的原因。

---

## 破壞性操作的防呆

磁碟管理（F）底下兩個功能會不可逆地毀掉資料，所以確認層層疊：

| 功能 | 防呆 |
|---|---|
| 格式化磁碟區 | 拒絕 `C:`、確認磁碟機存在、**再輸入一次代號**才執行 |
| 清除整顆磁碟 (`clean`) | 拒絕系統/開機碟、印出磁碟型號與容量、**再輸入一次編號**、最後還要輸入大寫 `ERASE` |

「解除帳號密碼鎖定」會先警告這等於**關閉帳號鎖定保護**（密碼可被無限次嘗試），
要你確認之後才做，並附上恢復指令。這台若有對外開放 RDP，請務必事後改回去。

---

## 不靜默失效

原本腳本開頭是 `$ErrorActionPreference = 'SilentlyContinue'`，那會讓每個失敗都無聲無息，
然後畫面照樣印「[完成]」——被群組原則鎖住的登錄檔、權限不足的服務設定，全都會變成
「看起來成功」。現在改成 `Continue`（錯誤訊息會出現），而且會改到系統的動作都**讀回來驗證**：

- 換 RDP Port：寫入後讀回 `PortNumber`，不符就撤回看門狗與防火牆規則，並說明可能是群組原則
- 停止 / 還原 Windows 更新：讀回 `wuauserv` 的啟動類型，不是預期值就講明「未完成」
- 關閉防火牆 Port：講清楚只移除**本工具建立的**規則，並附上查其他規則的指令

---

## 編碼

`Win_Admin_Tool.ps1` 是 UTF-8 with BOM、CRLF；`.bat` 是純 ASCII、CRLF。

**`ops-win.ps1` 是唯一的例外：UTF-8 無 BOM。** 它就是要被 `irm | iex` 的那一支，
而字串開頭多一個 BOM 字元在 Windows PowerShell 5.1 上有機會讓解析出錯。
主腳本反過來需要 BOM——它是用 `-File` 讀的，有 BOM 才保證 5.1 用 UTF-8 解碼。

`.bat` 用 `chcp 65001` 搭配 UTF-8 的 `.ps1`（原本是 `chcp 950`/Big5，與檔案編碼不一致，
一旦用到 Big5 沒有的字元就會變亂碼）。`.bat` 自己的訊息刻意保持全英文：cmd 是用**主控台
當下的字碼頁**解析批次檔的，非 ASCII 內容會隨系統地區設定而壞掉。

repo 根目錄的 `.gitattributes` 會強制 `*.bat` / `*.ps1` 用 CRLF、`*.sh` 用 LF——
shell 腳本被寫成 CRLF 的話，shebang 會變成 `/bin/sh\r` 而直接執行失敗。

---

## 已知限制

- **只有六個功能在真的 Windows 上跑過，其餘全部未驗證。** 在一台 Windows 10 22H2 上實際
  執行 `Win_Admin_Tool.ps1`，選單起得來、提權正常，以下六項跑過並且全部還原成原狀：

  | 功能 | 實機結果 |
  |---|---|
  | 停止 Windows 更新 | **抓到假成功的 bug**（見下一節與 [CHANGELOG](../CHANGELOG.md)） |
  | 還原 Windows 更新 | 正確把 `wuauserv` 還原成 `Manual` 並啟動 |
  | Ping (ICMP) 設定 | 開啟 / 關閉都建立了對應防火牆規則，事後清除乾淨 |
  | 解除帳號密碼鎖定 | 鎖定閾值 10 → 從不 → 10，來回都正確 |
  | CredSSP 加密預示修復 | `AllowEncryptionOracle` 設為 2、再還原成「尚未設定」 |
  | RDP 多開 | `fSingleSessionPerUser` 開啟後還原 |

  **沒跑過的**：`L. 事件檢視器`（1.14.0 新增，完全沒在 Windows 上跑過）、換 RDP Port 的
  完整流程（含看門狗排程）、磁碟管理、Hyper-V 切換、時間同步、Store 自動更新、
  防火牆 Port 管理、帳號相關功能，以及 `ops-win.ps1` 這條一行指令路徑。
  第一次用請先在測試機上驗證，尤其是換 RDP Port 那條——它會重啟 `TermService`。

  事件檢視器是唯讀的，跑錯了最多是查不到東西，不會改到系統——但「查不到」跟「沒發生」
  是兩件事，第一次用請拿一個你已經知道答案的情境去對（例如剛重開過機就查第 1 項）。

  靜態檢查倒是做完了（在 Linux 的 PowerShell 容器裡跑，不需要 Windows）：

  | 檢查 | 結果 |
  |---|---|
  | `[Parser]::ParseFile` 真正的語法解析 | 兩支都 **0 個解析錯誤**（`Win_Admin_Tool.ps1` 46 個函式、8328 個 token） |
  | 編碼與行尾 | 符合 `.gitattributes`：`ops-win.ps1` 無 BOM、`Win_Admin_Tool.ps1` 有 BOM、三個檔都是 CRLF |
  | PSScriptAnalyzer 1.22 | 修正前 `Win_Admin_Tool.ps1` 343 筆，**其中一筆是真的 bug**；修正後 342 筆、`ops-win.ps1` 21 筆 |

  1.14.0 這一輪分析器抓到一個真的缺陷（`PSUseDeclaredVarsMoreThanAssignments`：自訂查詢
  問了使用者「往回幾天」，卻沒把 `$days` 傳進 `Show-EventScenario`，該函式內部又寫死 7 天
  ——輸入 30 天實際只查 7 天，而且畫面照樣標「最近 7 天」，不報錯、只給錯答案）。已修正，
  修正後那條規則歸零。所以「分析器的告警都是雜訊」這個說法是錯的，值得逐筆看完。

  剩下的 342 筆確認過不需要改：319 筆 `PSAvoidUsingWriteHost`（互動式選單本來就該用它）、
  12 筆 `PSUseShouldProcessForStateChangingFunctions`（這些是選單動作，每個危險操作都已經
  有自己的確認步驟，再加一層 `-WhatIf` / `-Confirm` 沒有意義）、7 筆 `PSUseApprovedVerbs`
  與 3 筆 `PSUseSingularNouns`（`Require-Admin`、`Manage-*`、`Menu-*` 這些名字是選單語意，
  換成核准動詞反而難讀）、1 筆空 `catch`。`ops-win.ps1` 那 21 筆是 18 筆 `Write-Host`、
  2 筆刻意留空的 `catch`（包的是 `[Console]::OutputEncoding` 與 TLS 1.2 設定，失敗時本來
  就該繼續跑）、1 筆 `PSUseBOMForUnicodeEncodedFile`（**刻意**不加 BOM，見上面「編碼」一節）。

  （那 319 筆不等於原始碼裡 `Write-Host` 的數量——實際有 412 次呼叫、分布在 393 行，
  而分析器報的 319 筆落在 300 個不同的行。這兩個數字本來就不會一致，不必去「修正」它。）

  **解析過不代表跑得起來——實機行為仍然是零驗證。**
- 一行指令這條路徑另外有三個只有實機能確認的點：`irm | iex` 對 UTF-8 無 BOM 檔案的
  解析、`Invoke-WebRequest -OutFile` 之後 `Unblock-File` 有沒有真的解掉 MOTW、
  以及管線跑法下的提權（`$PSCommandPath` 為空 -> 寫檔 -> `RunAs`）。
- 「RDP 多開」在用戶端版（家用 / 專業版）受 `termsrv.dll` 限制，本工具只放寬工作階段
  規則；要真正多人同時連線需搭配 RDP Wrapper，且涉及授權條款，請自行評估。
- Hyper-V 與 VMware 的切換需要重新開機才會生效。
- **帳號鎖定政策在對外曝露的機器上會反過來變成阻斷自己的管道。** 測試那台（RDP 3389 直接
  對外）在測試期間被持續暴力破解，內建 Administrator 每 10 分鐘就被鎖一次。帳號被鎖住時
  **連 SSH 都會在認證開始前就被切斷**——sshd 無法替鎖定帳號建立存取權杖，連線直接 reset，
  而且 sshd 自己的紀錄裡一筆都不會留（不存在的帳號反而會留下正常的 `Invalid user` 紀錄，
  這個差異是判斷的關鍵）。攻擊者不需要猜中密碼，只要一直猜就能讓合法使用者永遠登不進去。
  Windows 這邊沒有 fail2ban 的對應機制，本工具的「解除帳號密碼鎖定」只能調整閾值、
  擋不住來源。對外的機器請靠「限制來源 IP」，不要只靠鎖定閾值。
