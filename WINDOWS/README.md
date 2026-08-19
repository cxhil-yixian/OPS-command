# WINDOWS/

Windows 10 / 11 的系統管理工具箱，PowerShell 寫的分類選單。跟 Linux 那邊同一個原則：
**遠端操作時不要把自己鎖在門外。**

| 檔案 | 用途 |
|---|---|
| `ops-win.ps1` | 一行指令的進入點：下載主腳本到 `%ProgramData%\OPS-command\` 再執行 |
| `Win_Admin_Tool.bat` | 本機進入點，雙擊即可（設好編碼並用 `-ExecutionPolicy Bypass` 呼叫 .ps1） |
| `Win_Admin_Tool.ps1` | 本體，1091 行的 PowerShell 分類選單 |

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

## 選單

```
  A. 遠端桌面 (RDP)     - 換 Port / 確認 / 還原 / 多開 / CredSSP / 登入紀錄
  B. 帳號與安全         - 鎖定 / Administrator / 改密碼
  C. 系統與更新         - Windows 更新 / Store / 時間時區
  D. 網路與防火牆       - Ping / Port / 批量加 IP
  E. 虛擬化 (Hyper-V)   - 與 VMware 切換 / 啟用停用
  F. 磁碟管理           - diskpart 視覺化
  S. 檢查現況           - 驗證設定 (免管理員)
```

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

- **這裡的東西沒有在 Windows 上實測過。** 修改是在 Linux 上做的，PowerShell 語法經過
  結構檢查（括號平衡、函式定義），但沒有真的跑過——`ops-win.ps1` 這條一行指令的路徑
  也一樣。第一次用請先在測試機上驗證，尤其是換 RDP Port 那條流程。
- 一行指令這條路徑另外有三個只有實機能確認的點：`irm | iex` 對 UTF-8 無 BOM 檔案的
  解析、`Invoke-WebRequest -OutFile` 之後 `Unblock-File` 有沒有真的解掉 MOTW、
  以及管線跑法下的提權（`$PSCommandPath` 為空 -> 寫檔 -> `RunAs`）。
- 「RDP 多開」在用戶端版（家用 / 專業版）受 `termsrv.dll` 限制，本工具只放寬工作階段
  規則；要真正多人同時連線需搭配 RDP Wrapper，且涉及授權條款，請自行評估。
- Hyper-V 與 VMware 的切換需要重新開機才會生效。
