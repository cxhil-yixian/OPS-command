# WINDOWS/

Windows 10 / 11 的系統管理工具箱，PowerShell 寫的分類選單。跟 Linux 那邊同一個原則：
**遠端操作時不要把自己鎖在門外。**

| 檔案 | 用途 |
|---|---|
| `Win_Admin_Tool.bat` | 進入點，雙擊即可（設好編碼並用 `-ExecutionPolicy Bypass` 呼叫 .ps1） |
| `Win_Admin_Tool.ps1` | 本體，1060 行的 PowerShell 分類選單 |

```
下載整個 WINDOWS 資料夾 -> 雙擊 Win_Admin_Tool.bat
```

不必事先改執行原則（`.bat` 已帶 `-ExecutionPolicy Bypass -NoProfile`），
也不必先用系統管理員身分開啟：**修改類功能會在需要時才問你要不要提權**，
唯讀的「檢查現況」一般帳號就能用。

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

`.ps1` 是 UTF-8 with BOM、CRLF；`.bat` 是純 ASCII、CRLF。

`.bat` 用 `chcp 65001` 搭配 UTF-8 的 `.ps1`（原本是 `chcp 950`/Big5，與檔案編碼不一致，
一旦用到 Big5 沒有的字元就會變亂碼）。`.bat` 自己的訊息刻意保持全英文：cmd 是用**主控台
當下的字碼頁**解析批次檔的，非 ASCII 內容會隨系統地區設定而壞掉。

repo 根目錄的 `.gitattributes` 會強制 `*.bat` / `*.ps1` 用 CRLF、`*.sh` 用 LF——
shell 腳本被寫成 CRLF 的話，shebang 會變成 `/bin/sh\r` 而直接執行失敗。

---

## 已知限制

- **這支腳本沒有在 Windows 上實測過。** 修改是在 Linux 上做的，PowerShell 語法經過
  結構檢查（括號平衡、函式定義），但沒有真的跑過。第一次用請先在測試機上驗證，
  尤其是換 RDP Port 那條流程。
- 「RDP 多開」在用戶端版（家用 / 專業版）受 `termsrv.dll` 限制，本工具只放寬工作階段
  規則；要真正多人同時連線需搭配 RDP Wrapper，且涉及授權條款，請自行評估。
- Hyper-V 與 VMware 的切換需要重新開機才會生效。
