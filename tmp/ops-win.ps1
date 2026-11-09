# ops-win.ps1 -- OPS-command 的 Windows 進入點（一行指令用）
#
#   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
#   irm https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main/WINDOWS/ops-win.ps1 | iex
#
# 它只做三件事：把主選單與視窗面板下載到 %LOCALAPPDATA%\OPS-command\、驗一下內容
# 不是被攔截的網頁、然後從主腳本的實體路徑執行它。
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

Write-Host ""
Write-Host " OPS-command Windows 工具" -ForegroundColor Cyan
Write-Host " 來源  $url"
Write-Host " 落地  $dst"
Write-Host " 面板  $gui"
Write-Host ""

$ready = $false
try {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Host " 下載中 ... " -NoNewline
    # -OutFile 寫的是原始位元組，BOM 與換行都照原樣落地
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Invoke-WebRequest -Uri $guiUrl -OutFile $guiTmp -UseBasicParsing
    # 被 captive portal / 代理攔截時拿到的會是 HTML，直接跑會很難查，先擋掉
    $head = (Get-Content -Path $tmp -TotalCount 5) -join "`n"
    if ($head -notmatch 'Windows 10/11') {
        throw "內容不像 Win_Admin_Tool.ps1，可能被代理或入口網頁攔截"
    }
    $guiHead = (Get-Content -Path $guiTmp -TotalCount 5) -join "`n"
    if ($guiHead -notmatch 'Windows schedule panel') {
        throw "內容不像 Win_Schedule_Panel.ps1，可能被代理或入口網頁攔截"
    }
    Move-Item -Path $tmp -Destination $dst -Force
    Move-Item -Path $guiTmp -Destination $gui -Force
    # 清掉 MOTW，不然某些環境的執行原則會擋下「從網路下載的檔案」
    Unblock-File -Path $dst -ErrorAction SilentlyContinue
    Unblock-File -Path $gui -ErrorAction SilentlyContinue
    Write-Host "完成" -ForegroundColor Green
    $ready = $true
} catch {
    Write-Host "失敗" -ForegroundColor Red
    Write-Host "   $($_.Exception.Message)"
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    if (Test-Path $guiTmp) { Remove-Item $guiTmp -Force -ErrorAction SilentlyContinue }
}

if (-not $ready) {
    if (-not (Test-Path $dst) -or -not (Test-Path $gui)) {
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
    # 用隱藏的 STA PowerShell 行程承載 WinForms 主面板；視窗本身仍會正常顯示。
    # 用 -File 另起行程，而不是 dot-source 進目前的 session：
    #   * 主腳本要拿得到 $PSCommandPath（提權時要用），dot-source 拿不到
    #   * -ExecutionPolicy Bypass 只作用在這一次執行，不動系統設定
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$dst`""
    )
}
