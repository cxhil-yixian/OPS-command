# 進度總表

最後更新：2026-11-09 20:30

這份檔案隨時更新，是唯一的進度來源。
標記：🔄 進行中　⏳ 等你　✅ 完成　⏸ 暫停　❄ 凍結　▶ 排隊

---

## 總覽

**Windows 圖形介面**（工作目錄 `tmp/`，完成後搬回 `WINDOWS/`）

| 編號 | 項目 | 狀態 |
|---|---|---|
| W1 | 修正行為錯誤（8 項） | ✅ |
| W2 | 安全：SYSTEM／管理員會執行的檔案不放在別人寫得到的地方 | ✅ |
| W3 | 結構整理：刪點不到的程式碼、改成正式表單、背景執行 | ✅ |
| W4 | 介面細節：DPI、中文星期、改名、首頁說明 | ✅ |
| W5 | 測試機逐項實測（含會改系統的按鈕），截圖、還原 | ▶ |
| W6 | 文件更新、`tmp/` 搬回 `WINDOWS/` | ▶ |
| E1 | RDP 只允許指定來源 IP（看門狗保護） | ▶ 第二波 |
| E2 | RDP 暴力破解自動封鎖 | ⏸ 做到一半 |
| E3 | Windows Server 2019 / 2022 相容性 | ⏸ 你決定先不測 |
| E4 | IP / DNS 變更加看門狗 | ⏸ 做到一半 |
| E5 | 一鍵開啟 OpenSSH Server | ▶ 第二波 |
| E6 | 常用軟體安裝（winget） | ⏸ 只查完 winget ID |
| E7 | 操作記錄 | ✅ |
| E8 | 下載檔案完整性檢查（SHA256） | ⏸ 做到一半 |
| E9 | 版本號與新版提示 | ⏸ 做到一半 |
| E10 | 測試程式放進 repo | ⏸ 做到一半 |
| E11 | 檢查系統現況匯出成檔案 | ⏸ 做到一半 |

**其他**

| 項目 | 狀態 |
|---|---|
| SSH 換埠 firewalld 保留／停用（`ssh-port.sh` 1.2）真機驗證 | ⏸ 等 Linux 測試機 |
| 封鎖通知（Telegram / Webhook） | ❄ |

---

## 🔄 進行中

（目前沒有。agent 已全部收回。）

## ⏳ 等你

- **測試期間請讓測試機的 RDP 視窗保持開著、不要最小化**，工作階段維持登入。最小化時遠端桌面不繪製畫面，截圖會失敗。
- **要不要推上 GitHub**：本機有兩樣東西還沒推：
  - `main` 上的 `012353d`（SSH 換埠 firewalld、fail2ban sync-port，9 個檔）
  - 分支 `windows-ui`（Windows 圖形介面，`ab62f39`）。建議等 W6 搬回 `WINDOWS/` 後再推，只推一半會讓一行指令下載失敗。
- **全部測完後**：建議改掉測試機 administrator 密碼；SSH 要不要保留由你決定。

## ▶ 下一步（依序）

1. **收尾第一波**：逐一檢查 E8/E9/E11、E10、E2、E4 的分支，補完測試，合併回 `windows-ui`。
2. **E6**：照「附錄 C」的規格實作；先找 WinMTR、windows_exporter 的正確 winget ID。
3. **第二波**：E1、E5。會動到 RDP 防火牆與 sshd（你和我連進測試機的管道），單獨做、不和其他測試同時跑。
4. **W5**：全部功能逐項實測，含 RDP 換 Port、Windows 更新、Hyper-V、Ping、批量 IP、磁碟、帳號鎖定、密碼、Administrator 停用。
5. **W6**：README（路徑表、看門狗說明、操作記錄、新功能）、CHANGELOG、WIKI，`tmp/` 搬回 `WINDOWS/`，刪除測試機上的 `C:\OPS-test\`。

## ⏸ 暫停

### 第一波 agent 做到一半的工作

2026-11-09 20:00 依你的指示收回。每份都 commit 在各自的本機分支（**未推送、未合併、未驗證**）：

| 項目 | 分支 / commit | 停下時的進度 |
|---|---|---|
| E2 | `worktree-agent-a14249db0a51d7973` / `c507a4a` | 主程式 +392 行（20 個函式＋側邊欄「帳號與安全」入口）；在修測試的乾跑模式 |
| E4 | `worktree-agent-a2fd20b6dbf1693d3` / `a684a8c` | 主程式 +503 行（28 個函式＋側邊欄「網路與防火牆」入口）；邏輯測試寫好，正在跑 |
| E8 / E9 / E11 | `worktree-agent-a8e5265082966b8d6` / `d145cd8` | 主程式 +115 行、`ops-win.ps1` +48 行、`tools/Update-Sha256Sums.ps1`；`SHA256SUMS` 還沒產生；agent 自述下載與版本比對在測試機跑過一次 |
| E10 | `worktree-agent-ade8188efefc35ccb` / `00e276a` | `tests/Test-Static.ps1`、`Test-Gui.ps1`、`Invoke-Interactive.ps1`；README 未寫 |
| E6 | 沒有程式碼 | winget ID：17 個確認存在；`WinMTR.WinMTR`、`Prometheus.WMIExporter` 查不到 |

收回後的測試機清理（20:10 複查）：
- 已刪：排程 `OPS-Test-agentA` 及其測試行程（含下載測試用的本機網站）、`HKLM\SOFTWARE\OPS-command\RdpGuard`。
- 複查：OPS 開頭的排程 0、OPS-command 登錄子項 0、TEST-NET 位址 0、沒有封鎖類防火牆規則；RDP 59527、TermService 與 sshd 執行中、DNS 正常。
- 確認原本就有、保持原樣：稽核「登入失敗」＝成功與失敗（3 小時內無 4719 事件）、7-Zip 24.09、第二張網卡 第二張網卡位址/16、DNS 8.8.8.8 / 1.1.1.1、防火牆規則 `OPS-RDP-59527-TCP/UDP`。
- `C:\OPS-test\agentA`～`agentE` 只剩測試檔，W6 時一起刪。

### 其他

- **E3 Windows Server 相容性**：你決定先不測。E6 在 Server 2019/2022 上只顯示「沒有驗證過的 winget 安裝方式」。
- **firewalld 停用 → confirm / rollback 真機驗證**（`ssh-port.sh` 1.2）：目前只有邏輯測試，等有 firewalld 的 Linux 測試機。

## ❄ 凍結

- **封鎖通知（Telegram / Webhook）**：CHANGELOG 記載「這一版討論後決定先不做」。

---

## ✅ 完成（依時間順序）

全部日期 2026-11-09。所有驗證都在測試機上做，不在本機執行。

1. **pull GitHub 最新**（v1.16.1）：本機修改保留，`CHANGELOG.md` 衝突已處理。
2. **commit `012353d`**：SSH 換埠 firewalld 可選保留或停用、fail2ban sync-port 同步封鎖方式（9 個檔，未推送）。
3. **讀完 `tmp/` 並整理問題清單**；W1–W4 範圍經你確認。
4. **測試機連線**：RDP 59527、SSH 59528；每次連線用密碼，沒在測試機留金鑰（裝金鑰被自動權限檢查擋下）。
5. **W1 修正行為錯誤**：同一支測試程式跑修改前後兩版對照。

   | 測試 | 修改前 | 修改後 |
   |---|---|---|
   | 看門狗時限「(Enter = 10)」 | 只有一顆「r. 10)」按鈕，無法輸入 | 輸入框 |
   | 通訊協定選項 | 「3. 兩者)」多一個括號 | 「3. 兩者」 |
   | 輸出順序 | 1 > 3 > 2 > 4 | 1 > 2 > 3 > 4 |
   | 非管理員按「是」提權 | **會被當成已是管理員繼續修改系統** | 正確回報未提權 |
   | UAC 按「否」 | 例外沒人接 | 跳「未提權」，面板保留 |
   | 程式出錯 | 隱藏視窗裡看不到 | 跳訊息框並寫 `%TEMP%\OPS-command-error.log` |
   | 中文 Windows 指令輸出 | `w32tm` 亂碼，`net`、`bcdedit` 變英文 | 正常中文 |
   | 管線跑法開排程面板 | Join-Path 錯誤 | 改找 `%LOCALAPPDATA%\OPS-command` |

   另外實測：`ops-win.ps1` 不能加 BOM（開頭有 BOM 的字串 `iex` 會失敗），README 改成不建議用檔案方式執行它。
6. **W2 安全**：實測 `%ProgramData%` 子目錄預設讓 `BUILTIN\Users` 建檔（`Users:(CI)(WD,AD)`），任何人先放同名空檔就成了擁有者。
   - 看門狗還原指令改用 `-EncodedCommand` 放進排程，不再有 `rdp-revert.ps1`。
   - 換 port 狀態改存 `HKLM\SOFTWARE\OPS-command\RdpPort`（實測只有 Administrators / SYSTEM 可寫）。
   - 看門狗紀錄改寫事件記錄（應用程式，來源 OPS-command，事件 100）。
   - 主程式落地改到 `%LOCALAPPDATA%`（`ops-win.ps1` 與管線跑法提權都改）。
   - 以 SYSTEM 實跑還原指令（RDP 相關動作換成測試值）四步正常；真正的 RDP port 沒被動到。
7. **W3 結構整理**：
   - 刪 19 個點不到的函式（537 行）、合併重複的 RDP 多工作階段功能。
   - 共用視窗元件＋背景執行工具；13 個功能改成正式表單，`Read-Host`／`Write-Host`／`Clear-Host` 偽裝版全部移除。
   - 長時間操作（Hyper-V、校時、重啟遠端桌面服務、Windows 更新）背景執行，執行中不能關視窗。
   - 新防呆：批量 IP 拒絕 DHCP 網卡；停用正在登入的內建 Administrator 會特別警告。
   - 超長單行 60 → 0 行，前後 17,234 個語法單元完全相同。
   - 畫面測試：22 個視窗（含主面板）全部正常開關；Store 切換、背景校時、事件查詢實際操作通過。
8. **在本機分支 `windows-ui` commit 進度**（`ab62f39`，未推送）。
9. **W4 介面細節**：
   - DPI：實測 `powershell.exe` 不感知 DPI，Windows 整個放大只會略模糊、不會截字，所以**不改**。
   - 自動排程「每週」改中文星期，實測建出的排程正確（星期一 = 2）。
   - `Win_Task_Manager.ps1` → `Win_Schedule_Panel.ps1`（避免和「工作管理員」混淆）。
   - 主面板首頁說明卡片改成目前的行為。
10. **E7 操作記錄**：每個會改系統的動作記時間、帳號、功能、結果；寫 `%LOCALAPPDATA%\OPS-command\actions.log` 與事件記錄（200 成功 / 201 失敗）；新增「操作記錄」視窗。實測 4 筆同時寫進兩處。
11. **規劃 E1–E11**（你決定全部要做）；E6 規格確認（附錄 C）。

---

## 附錄 A：實測抓到的原版 bug

| # | 問題 | 影響 | 狀態 |
|---|---|---|---|
| 1 | 主面板變數 `$home` 撞到 PowerShell 內建唯讀 `$HOME` | 主面板一啟動就出錯，隱藏視窗下畫面什麼都沒有 | ✅ 已修 |
| 2 | 側邊欄分類標題的閉包沒帶到 `$sidebar` | 每點一次分類就跳 .NET 錯誤框 | ✅ 已修 |
| 3 | `'D'..'Z'` 字元範圍要 PowerShell 7 | 「變更磁碟機代號」打不開 | ✅ 已修 |
| 4 | 事件來源不存在被當成讀取失敗 | 沒藍屏過的機器誤報「讀不到」 | ✅ 已修 |
| 5 | 非管理員提權時回傳值外漏 | 按「是」後被當成已是管理員繼續改系統 | ✅ 已修（W1） |
| 6 | `%ProgramData%` 一般使用者可建檔 | 可替換 SYSTEM 執行的還原腳本 | ✅ 已修（W2） |

**同類陷阱：** `GetNewClosure()` 只帶走「當下這一層」的變數。第 2 項、背景作業回呼、排程面板「移除」都是這類。已寫語法樹掃描程式專抓這種寫法（舊版抓得到，新版 0 個）。

## 附錄 B：測試環境

- **測試機**：Windows 10 專業版 19045、zh-TW、字碼頁 950、PowerShell 5.1、winget v1.29；主 IP 測試機 IP（固定），第二張網卡 第二張網卡位址/16。
- **連線**：RDP 59527、SSH 59528；你和我的來源 IP 都是 你的來源 IP。
- **測試機上的工具**（`C:\OPS-test\`）：`run-interactive.ps1`（在 RDP 桌面執行，可指定排程名稱）、`closure-scan.ps1`、`reach.ps1`、`tokcmp.ps1`。
- **安全規則**：不改 RDP port、不重啟 TermService、不動 sshd、不動主 IP／網卡；**絕不封鎖 你的來源 IP**；封鎖與位址測試只用 TEST-NET（192.0.2.0/24 等）；每項變更測完都要還原。

## 附錄 C：E6 常用軟體安裝規格（已確認）

- 只用 winget（官方 `winget` 來源、`--exact --id`），不自己維護下載網址與 SHA256；不用 `--ignore-security-hash`。
- 推薦清單（打勾安裝，已裝的顯示版本並略過）＋ 搜尋其他軟體；搜尋結果顯示 ID 與發行者，安裝前再確認一次。
- 偵測不到 winget：Win10/11 顯示安裝說明與 Microsoft Store 按鈕、「重新偵測」；Server 2019/2022 不寫未驗證的步驟。提權換帳號時 winget 可能找不到，要分開說明。
- 裝完回頭確認程式真的在，不只看回傳碼。
- 推薦清單：Nmap、WinMTR、Sysinternals Suite、Wireshark（Npcap 要手動點）、PuTTY、WinSCP、7-Zip、Notepad++、Git、PowerShell 7、Windows Terminal、Everything、TreeSize Free、CrystalDiskInfo、Chrome、Firefox、VC++ 2015-2022、.NET 8 桌面執行環境、windows_exporter。
  Docker Desktop、TeamViewer、AnyDesk 不放推薦清單，可從搜尋安裝。
