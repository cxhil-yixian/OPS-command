# ops-win.ps1 -- OPS-command 的 Windows 進入點（一行指令用）
#
#   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
#   irm https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/WINDOWS/ops-win.ps1 | iex
#
# 它只做三件事：把主選單與視窗面板下載到 %LOCALAPPDATA%\OPS-command\、驗一下內容
# 不是被攔截的網頁、然後從主腳本的實體路徑執行它。
#
# 完整性檢查：先下載同一個來源的 SHA256SUMS，兩支檔案的 SHA256 都要對得上才會落地執行。
# 這只防「下載不完整、被代理／入口網頁換掉、單一檔案被竄改」；清單和檔案來自同一個來源，
# repo 本身被入侵時兩者會一起被換掉，這裡擋不住（README「下載完整性檢查」有說明）。
# 雜湊算法：先把 CRLF 換成 LF 再算。GitHub raw 給的是 repo 裡的 LF 版本，本機 checkout 與
# 鏡像可能是 CRLF，統一成 LF 兩邊都對得上；換行以外的任何一個位元組不同都會被抓出來。
#
# 為什麼是「落地再跑」而不是直接把主腳本 irm | iex：
#   1. 提權。主腳本的「以系統管理員身分重新啟動」需要自己的實體路徑
#      （Start-Process -Verb RunAs 只能指定檔案，沒有「把這段程式碼交給新的
#      elevated 行程」的辦法）。管線跑進來的腳本 $PSCommandPath 是空的。
#   2. 放在 %LOCALAPPDATA% 而不是 %ProgramData%：這個檔等一下要以管理員身分執行，
#      不能放在別的使用者寫得到的地方。%ProgramData% 的子目錄預設讓 BUILTIN\Users
#      建立檔案（Users:(CI)(WD,AD)），別人先放一個同名檔就成了擁有者，之後能隨意改。
#   3. 主腳本是 UTF-8 with BOM。字串化之後餵給 iex，在 Windows PowerShell 5.1 上
#      不保證解析得過；存成檔案用 -File 執行反而最穩。
#
# 這支自己則是 UTF-8 無 BOM —— 它就是要被 irm | iex 的那一支。

param(
    # 下載失敗時，允許改用上次留在 %LOCALAPPDATA% 的副本（也可設 OPS_USE_CACHED=1）
    [switch]$UseCached,
    # 指到自己的 fork / 內網鏡像 / 其他分支（也可設 OPS_RAW_BASE）
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
# Windows PowerShell 5.1 預設不啟用 TLS 1.2，而 GitHub 只收 1.2 以上 —— 不設就是連不上。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# 參數也吃環境變數：irm | iex 這種跑法沒辦法帶參數，設環境變數最省事。
if (-not $BaseUrl) {
    if ($env:OPS_RAW_BASE) { $BaseUrl = $env:OPS_RAW_BASE }
    else { $BaseUrl = 'https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main' }
}
if (-not $UseCached -and $env:OPS_USE_CACHED -eq '1') { $UseCached = $true }

$root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
$dir  = Join-Path $root 'OPS-command'
$dst  = Join-Path $dir 'Win_Admin_Tool.ps1'
$gui  = Join-Path $dir 'Win_Schedule_Panel.ps1'
$tmp  = "$dst.part"
$guiTmp = "$gui.part"
$url  = "$BaseUrl/WINDOWS/Win_Admin_Tool.ps1"
$guiUrl = "$BaseUrl/WINDOWS/Win_Schedule_Panel.ps1"
$sumUrl = "$BaseUrl/WINDOWS/SHA256SUMS"
$sumTmp = Join-Path $dir 'SHA256SUMS.part'

# SHA256（先把 CRLF 換成 LF）。用 ISO-8859-1 轉字串再轉回來，位元組一對一不變，只換掉換行。
function Get-OpsLfSha256([string]$Path) {
    $latin = [Text.Encoding]::GetEncoding(28591)
    $bytes = $latin.GetBytes($latin.GetString([IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

Write-Host ""
Write-Host " OPS-command Windows 工具" -ForegroundColor Cyan
Write-Host " 來源  $url"
Write-Host " 落地  $dst"
Write-Host " 面板  $gui"
Write-Host ""

$ready = $false
$integrityFailed = $false
try {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Host " 下載中 ... " -NoNewline
    # -OutFile 寫的是原始位元組，BOM 與換行都照原樣落地
    Invoke-WebRequest -Uri $sumUrl -OutFile $sumTmp -UseBasicParsing
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Invoke-WebRequest -Uri $guiUrl -OutFile $guiTmp -UseBasicParsing
    # 清單格式同 sha256sum：<64 位十六進位>  <檔名>
    $sums = @{}
    foreach ($line in [IO.File]::ReadAllLines($sumTmp)) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') { $sums[$Matches[2]] = $Matches[1].ToLower() }
    }
    # 被 captive portal / 代理攔截時拿到的會是 HTML，直接跑會很難查，先擋掉
    $head = (Get-Content -Path $tmp -TotalCount 5) -join "`n"
    if ($head -notmatch 'Windows 10/11') {
        throw "內容不像 Win_Admin_Tool.ps1，可能被代理或入口網頁攔截"
    }
    $guiHead = (Get-Content -Path $guiTmp -TotalCount 5) -join "`n"
    if ($guiHead -notmatch 'Windows schedule panel') {
        throw "內容不像 Win_Schedule_Panel.ps1，可能被代理或入口網頁攔截"
    }
    $bad = @()
    foreach ($pair in @(@('Win_Admin_Tool.ps1', $tmp), @('Win_Schedule_Panel.ps1', $guiTmp))) {
        $want = $sums[$pair[0]]
        if (-not $want) { $integrityFailed = $true; throw "SHA256SUMS 裡沒有 $($pair[0])，無法確認檔案完整，拒絕執行" }
        $got = Get-OpsLfSha256 $pair[1]
        if ($got -ne $want) { $bad += "   $($pair[0])`n     清單  $want`n     下載  $got" }
    }
    if ($bad.Count) {
        $integrityFailed = $true
        throw ("下載的檔案和 SHA256SUMS 對不上，拒絕執行：`n" + ($bad -join "`n") +
            "`n   可能原因：下載不完整、被代理或入口網頁換掉、檔案被竄改；" +
            "`n   剛推上新版的幾分鐘內 GitHub 快取也可能新舊混雜，稍候再試。")
    }
    Move-Item -Path $tmp -Destination $dst -Force
    Move-Item -Path $guiTmp -Destination $gui -Force
    # 清掉 MOTW，不然某些環境的執行原則會擋下「從網路下載的檔案」
    Unblock-File -Path $dst -ErrorAction SilentlyContinue
    Unblock-File -Path $gui -ErrorAction SilentlyContinue
    Write-Host "完成（SHA256 已核對）" -ForegroundColor Green
    $ready = $true
} catch {
    Write-Host "失敗" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)"
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    if (Test-Path $guiTmp) { Remove-Item $guiTmp -Force -ErrorAction SilentlyContinue }
} finally {
    if (Test-Path $sumTmp) { Remove-Item $sumTmp -Force -ErrorAction SilentlyContinue }
}

if (-not $ready) {
    if ($integrityFailed) {
        # 核對失敗不是「沒下載到」，而是「下載到的東西不對」：不改用舊副本，也不執行任何東西。
        Write-Host ""
        Write-Host " 完整性檢查沒通過，什麼都沒有執行；上次留下的副本也沒有被覆蓋。" -ForegroundColor Red
        Write-Host " 這種情況不會改用舊副本（OPS_USE_CACHED / -UseCached 只在「下載失敗」時才有效）。"
        Write-Host " 請先查清楚原因：換個網路、關掉代理再試，或手動下載整個 WINDOWS 資料夾比對。"
    } elseif (-not (Test-Path $dst) -or -not (Test-Path $gui)) {
        Write-Host ""
        Write-Host " 沒有完整的主腳本與視窗面板副本，無法繼續。" -ForegroundColor Red
        Write-Host " 改成手動下載整個 WINDOWS 資料夾、雙擊 Win_Admin_Tool.bat 也可以。"
    } elseif (-not $UseCached) {
        # 舊副本可能是好幾版以前的，跟線上說明對不起來 —— 要用可以，但必須是你明確決定的。
        $when = (Get-Item $dst).LastWriteTime
        Write-Host ""
        Write-Host " 這台有一份 $when 的舊副本，但沒有重新下載就不會用它。" -ForegroundColor Yellow
        Write-Host " 舊副本可能不是最新版，畫面和功能會跟線上說明對不起來。"
        Write-Host " 確定要用就加 -UseCached（或設 OPS_USE_CACHED=1）重跑。"
    } else {
        $when = (Get-Item $dst).LastWriteTime
        Write-Host " 改用 $when 的舊副本（-UseCached）" -ForegroundColor Yellow
        $ready = $true
    }
}

if ($ready) {
    Write-Host ""
    # 用 STA PowerShell 行程承載 WinForms 主面板，用 -File 另起行程而不是 dot-source 進目前的 session：
    #   * 主腳本要拿得到 $PSCommandPath（提權時要用），dot-source 拿不到
    #   * 介面的閉包只看得到全域函式，-File 執行的腳本才在全域
    #   * -ExecutionPolicy Bypass 只作用在這一次執行，不動系統設定
    # 隱藏主控台要用 powershell 自己的 -WindowStyle Hidden，不能用 Start-Process -WindowStyle Hidden：
    # 後者會讓 Windows 把這個行程「第一個顯示的視窗」也設成隱藏，而那正是主面板——
    # 行程在跑、畫面卻什麼都沒有（實測：從 GitHub 跑一行指令，面板視窗存在但是隱藏的）。
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$dst`""
    )
}
