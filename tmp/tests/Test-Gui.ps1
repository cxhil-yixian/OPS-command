<#
.SYNOPSIS
    畫面測試：開啟主面板，逐一點側邊欄的每個功能、截圖、記錄狀態，確認沒有未處理的例外。

.DESCRIPTION
    必須在「已登入的桌面工作階段」（RDP 視窗開著、沒有最小化）裡、以 -STA 執行。
    從 SSH 或排程跑時，用 Invoke-Interactive.ps1 把它丟到桌面上執行。

    做法：載入主程式的函式（不執行最後啟動面板那一段），用 WinForms 計時器驅動：
      1. 開主面板，展開每個側邊欄分類（點分類標題）。
      2. 側邊欄的功能清單從主程式原始碼的 & $addSection 定義自動取得，和畫面上的按鈕比對。
      3. 逐一點每個功能按鈕 → 等視窗開出來、狀態讀完 → 截圖 → 記錄狀態欄與結果區 → 關閉。
      4. 期間跳出的訊息框自動關閉（有「否」按「否」、有「取消」按「取消」），內容寫進結果；
         .NET 未處理例外、%TEMP%\OPS-command-error.log 新增的內容、標題含「錯誤／失敗」的訊息框、
         狀態欄「讀取狀態失敗」、結果區「[錯誤]」都算失敗。
      5. 測試前後比對系統設定（RDP Port、Store、Windows 更新、帳號鎖定、防火牆 ICMP 規則、OPS 排程…），
         唯讀模式下前後必須相同。

    預設「唯讀」：只開視窗、不按任何會改系統的按鈕。
    加 -Modify 才做「會改動但會自動還原」的測試（需要系統管理員）：
      - Microsoft Store 自動更新：切換一次、讀登錄確認，再還原成原本的值。
      - 時間與時區：按「立即校時」，確認在背景執行、執行中不能關視窗、介面沒有卡住；
        測完把 w32time 服務的啟動類型與執行狀態還原。（系統時間本身會被校正，這無法還原也不需要。）
      - 自動排程：新增一個「定時執行腳本」排程（指向測試用的空腳本），再用面板的「移除」刪掉。
      - 操作記錄：確認上面幾個動作都寫進 actions.log 與 Windows 事件記錄；測完從 actions.log 刪掉測試寫的那幾行。
        事件記錄無法逐筆刪除，會留下（應用程式，來源 OPS-command，事件 200/201）。

.PARAMETER Path
    工具所在的資料夾（裡面要有 Win_Admin_Tool.ps1），預設是這支腳本的上一層。

.PARAMETER OutDir
    截圖與結果檔的資料夾，預設 %TEMP%\OPS-command-tests\gui-日期時間。

.PARAMETER Modify
    執行會改動系統、但會自動還原的測試。

.PARAMETER Only
    只測標題包含這些字的功能，例如 -Only Store,時間。

.PARAMETER PanelTimeoutSec
    每個功能視窗從點擊到開出來的最長等待秒數，預設 45。

.OUTPUTS
    <OutDir>\result.txt：逐項結果與摘要（UTF-8）。
    <OutDir>\NN.png：每個視窗的截圖，對照表在 result.txt。
    結束碼：全部通過 0，有失敗 1，無法執行（不是 STA、沒有桌面、找不到主程式）2。
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$OutDir,
    [switch]$Modify,
    [string[]]$Only,
    [int]$PanelTimeoutSec = 45
)

$ErrorActionPreference = 'Stop'
# 計時器步驟用 .GetNewClosure()，閉包只看得到全域的函式：一定要用 powershell -File 執行
# （-File 的腳本跑在全域）。在 PowerShell 視窗裡打 .\Test-Gui.ps1 或用 & 呼叫時，每一步都會
# 「無法辨識詞彙」，與其跑完半小時全部失敗，不如現在就停。
function Test-OpsGuiScope { $true }
if (-not @(& ({ Get-Command Test-OpsGuiScope -CommandType Function -ErrorAction SilentlyContinue }.GetNewClosure())).Count) {
    Write-Host '[無法執行] 請用 powershell -STA -File Test-Gui.ps1 執行（或透過 Invoke-Interactive.ps1），不要用 .\ 或 & 呼叫。'
    exit 2
}
if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("OPS-command-tests\gui-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResultFile = Join-Path $OutDir 'result.txt'
[IO.File]::WriteAllText($ResultFile, '', (New-Object System.Text.UTF8Encoding($true)))

function Log([string]$Text) {
    Add-Content -LiteralPath $ResultFile -Value $Text -Encoding UTF8
    Write-Host $Text
}

$global:GT = @{
    Fails = New-Object System.Collections.ArrayList     # 整體失敗項目
    Results = New-Object System.Collections.ArrayList   # 每個功能的結果
    Msgs = New-Object System.Collections.ArrayList      # 所有出現過的訊息框
    Unhandled = New-Object System.Collections.ArrayList # .NET 未處理例外
    Steps = New-Object System.Collections.ArrayList
    Idx = 0; StepTicks = 0; Ticks = 0; InTick = $false
    YesTitles = @()          # 這些標題的訊息框按「是」
    Handled = @{}            # 已送出按鍵的訊息框（避免每個 tick 重送）
    Main = $null; Cur = $null; Panel = $null
    Restore = New-Object System.Collections.ArrayList  # 還原動作（finally 一定會跑）
}

function Add-TestFail([string]$Text) {
    [void]$global:GT.Fails.Add($Text)
    if ($global:GT.Panel) { [void]$global:GT.Panel.Fails.Add($Text) }
    Log "    [失敗] $Text"
}

Log "OPS-command 畫面測試　$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "工具資料夾：$Path"
Log "輸出資料夾：$OutDir"
Log "模式：$(if ($Modify) { '會改動並自動還原（-Modify）' } else { '唯讀' })"

# ---------------------------------------------------------------- 前置檢查
$target = Join-Path $Path 'Win_Admin_Tool.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$problems = @()
if (-not (Test-Path -LiteralPath $target)) { $problems += "找不到 $target" }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { $problems += '不是 STA 執行緒，請用 powershell -STA -File 執行' }
if ((Get-Process -Id $PID).SessionId -eq 0 -or -not [Environment]::UserInteractive) { $problems += '不在桌面工作階段（Session 0 / 服務），請用 Invoke-Interactive.ps1 執行' }
if ($Modify -and -not $isAdmin) { $problems += '-Modify 需要系統管理員權限' }
if ($problems) { foreach ($p in $problems) { Log "[無法執行] $p" }; exit 2 }
Log "權限：$(if ($isAdmin) { '系統管理員' } else { '一般使用者' })　PowerShell $($PSVersionTable.PSVersion)"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }
[Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        $m = $e.Exception.Message
        [void]$global:GT.Unhandled.Add($m)
        Add-TestFail ".NET 未處理例外：$m"
    })

if (-not ('OpsGuiTestW32' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class OpsGuiTestW32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static string TextOf(IntPtr h) { var sb = new StringBuilder(2048); GetWindowText(h, sb, 2048); return sb.ToString(); }
    // 這個行程自己的對話框（MessageBox 的視窗類別是 #32770）；別的行程的視窗一律不碰
    public static IntPtr[] Dialogs(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && ClassOf(h) == "#32770") list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static string Body(IntPtr h) {
        var sb = new StringBuilder();
        EnumChildWindows(h, delegate(IntPtr c, IntPtr l) {
            if (ClassOf(c) == "Static") { var t = TextOf(c); if (t.Length > 0) sb.Append(t).Append(' '); }
            return true;
        }, IntPtr.Zero);
        return sb.ToString().Trim();
    }
}
'@
}

# ---------------------------------------------------------------- 工具函式
function Get-AllControls($c) { foreach ($x in $c.Controls) { $x; Get-AllControls $x } }
function Save-Shot($Form, [string]$Name) {
    try {
        if (-not $Form -or $Form.IsDisposed -or $Form.Width -le 0) { return }
        $bmp = New-Object Drawing.Bitmap $Form.Width, $Form.Height
        $Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $Form.Width, $Form.Height))
        $bmp.Save((Join-Path $OutDir "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    } catch { Log "    [截圖失敗] $Name：$($_.Exception.Message)" }
}
function Get-LogBox($Form) { Get-AllControls $Form | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.Multiline } | Select-Object -First 1 }
function Get-StatusLabel($Form) {
    $g = Get-AllControls $Form | Where-Object { $_ -is [Windows.Forms.GroupBox] -and $_.Text -eq '目前狀態' } | Select-Object -First 1
    if ($g) { $g.Controls | Where-Object { $_ -is [Windows.Forms.Label] } | Select-Object -First 1 }
}
function Get-Button($Root, [string]$Text) { Get-AllControls $Root | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq $Text } | Select-Object -First 1 }
function Get-VisibleForms { @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Visible -and -not $_.IsDisposed }) }
function OneLine([string]$Text, [int]$Max = 6) { (($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First $Max) -join ' / ') }
function Invoke-Later($Control, [scriptblock]$Action) { [void]$Control.BeginInvoke([Action]$Action) }

# 系統設定快照：唯讀模式前後必須相同；-Modify 還原後也必須相同
function Get-StateSnapshot {
    $s = [ordered]@{}
    $g = { param($k, $n) try { (Get-ItemProperty -Path $k -Name $n -ErrorAction Stop).$n } catch { '（無）' } }
    $s['RDP Port'] = & $g 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' PortNumber
    $s['fDenyTSConnections'] = & $g 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections
    $s['fSingleSessionPerUser'] = & $g 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fSingleSessionPerUser
    $s['CredSSP AllowEncryptionOracle'] = & $g 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' AllowEncryptionOracle
    $s['Store 登錄機碼存在'] = Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    $s['Store AutoDownload'] = & $g 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' AutoDownload
    foreach ($svc in 'wuauserv', 'UsoSvc', 'w32time', 'TermService') {
        $o = Get-Service $svc -ErrorAction SilentlyContinue
        $s["$svc 啟動類型"] = if ($o) { [string]$o.StartType } else { '（無）' }
    }
    $s['WaaSMedicSvc Start'] = & $g 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' Start
    $s['WindowsUpdate AU NoAutoUpdate'] = & $g 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate
    $lock = & net accounts 2>&1 | Select-String '鎖定閾值|Lockout threshold' | Select-Object -First 1
    $s['帳號鎖定閾值'] = if ($lock) { ($lock.ToString() -split ':\s*', 2)[-1].Trim() } else { '讀不到' }
    $s['ICMP 規則'] = (@(Get-NetFirewallRule -DisplayName 'ICMP*-Echo-*' -ErrorAction SilentlyContinue | ForEach-Object DisplayName | Sort-Object) -join ',')
    $s['OPS 排程'] = (@(Get-ScheduledTask -TaskName 'OPS-*' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -notlike 'OPS-Test-*' } | ForEach-Object { "$($_.TaskName)=$($_.State)" } | Sort-Object) -join ',')
    $s['時區'] = (Get-TimeZone).Id
    $s['IPv4 位址數'] = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).Count
    $adm = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-500' } | Select-Object -First 1
    $s['內建 Administrator 啟用'] = if ($adm) { $adm.Enabled } else { '（無）' }
    if ($isAdmin) {
        $lt = & bcdedit /enum '{current}' 2>&1 | Select-String 'hypervisorlaunchtype' | Select-Object -First 1
        $s['hypervisorlaunchtype'] = if ($lt) { ($lt.ToString() -split '\s+')[-1] } else { '未設定' }
    }
    $s
}
function Compare-Snapshot($Before, $After, [string]$When) {
    $diff = @()
    foreach ($k in $Before.Keys) { if ([string]$Before[$k] -ne [string]$After[$k]) { $diff += "$k：$($Before[$k]) → $($After[$k])" } }
    if ($diff) {
        foreach ($d in $diff) { Add-TestFail "$When 系統設定不同：$d（若同時有其他測試在改這台機器，也可能是它造成的）" }
    } else { Log "  [通過] $When 系統設定與測試前相同（$($Before.Count) 項）" }
}

# ---------------------------------------------------------------- 載入主程式的函式
# 只執行到最外層第一個呼叫 Show-WindowsPanel 的敘述之前（也就是不自動開面板）。
# 寫到暫存資料夾再 dot-source：函式裡的 $PSScriptRoot 才會指向那個資料夾，
# 排程面板（Win_Schedule_Panel.ps1）也複製過去，「開啟自動排程管理」才找得到。
$WorkDir = Join-Path $env:TEMP "OPS-gui-test-$PID"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$srcText = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$tk = $null; $pe = $null
$srcAst = [Management.Automation.Language.Parser]::ParseInput($srcText, [ref]$tk, [ref]$pe)
if ($pe.Count) { Log "[失敗] 主程式解析錯誤：$($pe[0].Message)（第 $($pe[0].Extent.StartLineNumber) 行）"; exit 1 }
$launch = $srcAst.EndBlock.Statements | Where-Object {
    $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
    $_.Find({ $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Show-WindowsPanel' }, $true)
} | Select-Object -First 1
$cut = if ($launch) { $launch.Extent.StartOffset } else { $srcText.Length }
$funcFile = Join-Path $WorkDir 'Win_Admin_Tool.functions.ps1'
[IO.File]::WriteAllText($funcFile, $srcText.Substring(0, $cut), (New-Object System.Text.UTF8Encoding($true)))
foreach ($extra in Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'Win_Admin_Tool.ps1' }) {
    Copy-Item -LiteralPath $extra.FullName -Destination $WorkDir -Force
}

# 側邊欄定義：& $addSection '分類' @( @{Title='…';Action={…}} … )
$SidebarDef = @()
foreach ($c in $srcAst.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
    $first = $c.CommandElements[0]
    if ($first -isnot [Management.Automation.Language.VariableExpressionAst] -or $first.VariablePath.UserPath -ne 'addSection') { continue }
    $section = $c.CommandElements[1].Value
    foreach ($h in $c.FindAll({ $args[0] -is [Management.Automation.Language.HashtableAst] }, $true)) {
        $title = $null; $action = ''
        foreach ($kv in $h.KeyValuePairs) {
            $key = $kv.Item1.Extent.Text.Trim("'`"")
            if ($key -eq 'Title') { $sc = $kv.Item2.Find({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] }, $true); if ($sc) { $title = $sc.Value } }
            if ($key -eq 'Action') { $action = $kv.Item2.Extent.Text }
        }
        if ($title) { $SidebarDef += [pscustomobject]@{ Section = $section; Title = $title; Action = $action } }
    }
}
Log "側邊欄定義（從原始碼）：$($SidebarDef.Count) 個功能"

$StateBefore = Get-StateSnapshot
$ErrLogPath = Join-Path $env:TEMP 'OPS-command-error.log'
$ErrLogSize = if (Test-Path $ErrLogPath) { (Get-Item $ErrLogPath).Length } else { 0 }
$ActionLogPath = Join-Path $env:LOCALAPPDATA 'OPS-command\actions.log'
$TestStart = Get-Date
$TestTag = "OPS-GUI-Test-$PID-$(Get-Random -Maximum 99999)"

$ErrorActionPreference = 'Continue'
. $funcFile
$ErrorActionPreference = 'Continue'
$Script:SelfPath = $target
$ErrorBase = $Error.Count

# ---------------------------------------------------------------- 計時器驅動
# 每 250 ms 一次：先處理訊息框，再跑目前的步驟。步驟回傳 $false = 還沒好、下次再試。
# 任何可能跳出模態視窗的動作（點按鈕、關視窗）都用 BeginInvoke 丟出去，
# 不能在計時器事件裡同步執行，否則模態迴圈會卡在這個事件裡，計時器就再也不會進來。
function Add-Step([string]$Name, [scriptblock]$Do, [int]$TimeoutSec = 30, [scriptblock]$OnTimeout) {
    [void]$global:GT.Steps.Add(@{ Name = $Name; Do = $Do; Timeout = [Math]::Max(1, $TimeoutSec * 4); OnTimeout = $OnTimeout })
}
function Insert-Steps([array]$Steps) {
    # 插在目前步驟的後面
    $at = $global:GT.Idx + 1
    foreach ($s in $Steps) { $global:GT.Steps.Insert($at, $s); $at++ }
}
function New-Step([string]$Name, [scriptblock]$Do, [int]$TimeoutSec = 30, [scriptblock]$OnTimeout) {
    @{ Name = $Name; Do = $Do; Timeout = [Math]::Max(1, $TimeoutSec * 4); OnTimeout = $OnTimeout }
}

$tick = {
    $G = $global:GT
    $G.Ticks++
    # 1. 這個行程的訊息框：記錄後關掉（即使正在處理步驟也要做，PostMessage 不會重入）
    foreach ($h in [OpsGuiTestW32]::Dialogs([uint32]$PID)) {
        $key = [string]$h
        if ($G.Handled.ContainsKey($key) -and $G.Ticks - $G.Handled[$key] -lt 8) { continue }
        $title = [OpsGuiTestW32]::TextOf($h)
        $body = [OpsGuiTestW32]::Body($h)
        if (-not $G.Handled.ContainsKey($key)) {
            [void]$G.Msgs.Add([pscustomobject]@{ Title = $title; Body = $body; Panel = $(if ($G.Panel) { $G.Panel.Title } else { '' }) })
            if ($G.Panel) { [void]$G.Panel.Msgs.Add("$title｜$body") }
        }
        $G.Handled[$key] = $G.Ticks
        $id = if ($title -in $G.YesTitles -and [OpsGuiTestW32]::GetDlgItem($h, 6) -ne [IntPtr]::Zero) { 6 }
        elseif ([OpsGuiTestW32]::GetDlgItem($h, 7) -ne [IntPtr]::Zero) { 7 }      # 否
        elseif ([OpsGuiTestW32]::GetDlgItem($h, 2) -ne [IntPtr]::Zero) { 2 }      # 取消
        else { 1 }                                                                 # 確定
        [void][OpsGuiTestW32]::PostMessage($h, 0x0111, [IntPtr]$id, [IntPtr]::Zero)
    }
    if ($G.InTick) { return }
    $G.InTick = $true
    try {
        if ((Get-Date) -gt $G.Deadline -and -not $G.Aborted) {
            $G.Aborted = $true
            Add-TestFail '整體逾時，強制關閉所有視窗'
            foreach ($f in @(Get-VisibleForms) | Sort-Object { $_ -eq $G.Main }) { Invoke-Later $f { $f.Close() }.GetNewClosure() }
            $G.Idx = $G.Steps.Count
            return
        }
        if ($G.Idx -ge $G.Steps.Count) { return }
        $s = $G.Steps[$G.Idx]
        $G.StepTicks++
        $r = $true
        try { $r = & $s.Do } catch { Add-TestFail "步驟「$($s.Name)」出錯：$($_.Exception.Message)"; $r = $true }
        if ($r -ne $false) { $G.Idx++; $G.StepTicks = 0 }
        elseif ($G.StepTicks -ge $s.Timeout) {
            Add-TestFail "步驟「$($s.Name)」逾時（$([int]($s.Timeout / 4)) 秒）"
            if ($s.OnTimeout) { try { & $s.OnTimeout } catch { } }
            $G.Idx++; $G.StepTicks = 0
        }
    } finally { $G.InTick = $false }
}

# ---------------------------------------------------------------- 功能視窗的步驟
function Start-Panel($Index, $Button, $Def) {
    $title = $Button.Text
    $p = @{ Index = $Index; Title = $title; Action = $Def.Action; Fails = (New-Object System.Collections.ArrayList); Msgs = (New-Object System.Collections.ArrayList)
        Unhandled = $global:GT.Unhandled.Count; Start = Get-Date; ClickDone = $false; Form = $null; Shot = ('{0:D2}' -f $Index) }
    $global:GT.Panel = $p
    $global:GT.Before = @(Get-VisibleForms)
    Log ''
    Log ("[{0:D2}] {1}" -f $Index, $title)
    $btn = $Button
    Invoke-Later $global:GT.Main {
        try { $btn.PerformClick() } finally { $global:GT.Panel.ClickDone = $true }
    }.GetNewClosure()
}

function Get-NewForm {
    Get-VisibleForms | Where-Object { $_ -ne $global:GT.Main -and $_ -notin $global:GT.Before } | Select-Object -Last 1
}

function Add-PanelSteps($Index, $Button, $Def) {
    $btn = $Button; $def = $Def; $idx = $Index
    $steps = @()
    $steps += New-Step '點側邊欄按鈕' { Start-Panel $idx $btn $def; $true }.GetNewClosure()
    $steps += New-Step '等視窗開啟' {
        $p = $global:GT.Panel
        $f = Get-NewForm
        if ($f) { $p.Form = $f; $global:GT.Cur = $f; $p.WaitTicks = 0; return $true }
        if ($p.ClickDone) {
            Add-TestFail '按鈕事件已結束，但沒有開出視窗'
            $global:GT.Cur = $null
            return $true
        }
        $false
    } $PanelTimeoutSec
    $steps += New-Step '等狀態讀完' {
        $p = $global:GT.Panel
        if (-not $p.Form) { return $true }
        $p.WaitTicks++
        if ($p.WaitTicks -lt 6) { return $false }
        $st = Get-StatusLabel $p.Form
        if ($st -and $st.Text -eq '讀取中…') { return $false }
        $lb = Get-LogBox $p.Form
        if ($lb -and $lb.Text -match '執行中，請稍候' -and $lb.Text -notmatch '\[錯誤\]') { return $false }
        $true
    } 40
    $steps += New-Step '截圖與記錄' {
        $p = $global:GT.Panel
        $f = $p.Form
        if (-not $f) { return $true }
        Save-Shot $f $p.Shot
        Log "    視窗：$($f.Text)　截圖：$($p.Shot).png　開啟 $([Math]::Round(((Get-Date) - $p.Start).TotalSeconds, 1)) 秒"
        $st = Get-StatusLabel $f
        if ($st) {
            Log "    狀態：$(OneLine $st.Text 8)"
            if ($st.Text -like '讀取狀態失敗*') { Add-TestFail "狀態讀取失敗：$($st.Text)" }
        }
        $lb = Get-LogBox $f
        if ($lb -and $lb.Text.Trim()) {
            Log "    結果區：$(OneLine $lb.Text 8)"
            if ($lb.Text -match '\[錯誤\][^\r\n]*') { Add-TestFail "結果區出現錯誤：$($Matches[0])" }
        }
        foreach ($g in Get-AllControls $f | Where-Object { $_ -is [Windows.Forms.DataGridView] }) { Log "    表格：$($g.Rows.Count) 列" }
        $tabs = Get-AllControls $f | Where-Object { $_ -is [Windows.Forms.TabControl] } | Select-Object -First 1
        if ($tabs) { Log "    分頁：$(@($tabs.TabPages | ForEach-Object Text) -join '、')" }
        $btns = @(Get-AllControls $f | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Visible } | ForEach-Object Text)
        Log "    按鈕：$($btns -join '、')"
        # -Modify 時，依功能插入會改動的測試步驟
        if ($Modify) {
            $extra = Get-ModifySteps $p
            if ($extra) { Insert-Steps $extra }
        }
        $true
    }
    $steps += New-Step '關閉視窗' {
        $f = $global:GT.Panel.Form
        if ($f -and -not $f.IsDisposed) { Invoke-Later $f { $f.Close() }.GetNewClosure() }
        $true
    }
    $steps += New-Step '等視窗關閉' {
        $p = $global:GT.Panel
        if (-not $p.ClickDone) { return $false }
        $p.Seconds = [Math]::Round(((Get-Date) - $p.Start).TotalSeconds, 1)
        foreach ($m in $p.Msgs) {
            Log "    訊息框：$m"
            if ($m -match '^[^｜]*(錯誤|失敗|無法|不存在)') { Add-TestFail "跳出錯誤訊息框：$m" }
        }
        if ($global:GT.Unhandled.Count -gt $p.Unhandled) { Add-TestFail "期間有 $($global:GT.Unhandled.Count - $p.Unhandled) 個未處理例外" }
        $newErr = $Error.Count - $global:GT.ErrorCount
        if ($newErr -gt 0) {
            Log "    （PowerShell `$Error 新增 $newErr 筆，僅供參考：$(OneLine (($Error | Select-Object -First ([Math]::Min(3, $newErr)) | ForEach-Object { $_.ToString() }) -join "`n") 3)）"
        }
        $global:GT.ErrorCount = $Error.Count
        $verdict = if ($p.Fails.Count) { '失敗' } else { '通過' }
        Log "    → $verdict（$($p.Seconds) 秒）"
        [void]$global:GT.Results.Add([pscustomobject]@{ No = $p.Index; Title = $p.Title; Result = $verdict; Shot = "$($p.Shot).png"; Why = ($p.Fails -join '；') })
        $global:GT.Panel = $null; $global:GT.Cur = $null
        $true
    } 30 { Log '    （視窗關不掉，可能有背景作業還在跑）' }
    foreach ($s in $steps) { [void]$global:GT.Steps.Add($s) }
}

# ---------------------------------------------------------------- -Modify：會改動並自動還原的測試
function Get-ModifySteps($p) {
    $a = $p.Action
    if ($a -match 'Show-StorePanel') { return Get-StoreSteps }
    if ($a -match 'Show-TimePanel') { return Get-TimeSteps }
    if ($a -match 'Open-TaskManagerPanel') { return Get-ScheduleSteps }
    @()
}

$StoreKey = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
function Get-StoreSteps {
    $global:GT.Store = @{
        KeyExisted = Test-Path $StoreKey
        Before = (Get-ItemProperty -Path $StoreKey -Name AutoDownload -ErrorAction SilentlyContinue).AutoDownload
    }
    [void]$global:GT.Restore.Add({ Restore-Store })
    @(
        (New-Step 'Store：切換' {
            $st = $global:GT.Store
            if ($st.Before -eq 2) { $st.Button = '開啟自動更新'; $st.Expect = 4 } else { $st.Button = '關閉自動更新'; $st.Expect = 2 }
            $b = Get-Button $global:GT.Panel.Form $st.Button
            if (-not $b) { Add-TestFail "找不到按鈕「$($st.Button)」"; return $true }
            Log "    [改動] Store AutoDownload 原本 = $(if ($null -eq $st.Before) { '未設定' } else { $st.Before })，按「$($st.Button)」"
            Invoke-Later $b { $b.PerformClick() }.GetNewClosure()
            $true
        }),
        (New-Step 'Store：確認結果' {
            $lb = Get-LogBox $global:GT.Panel.Form
            if ($lb.Text -notmatch '\[完成\]|\[錯誤\]') { return $false }
            $st = $global:GT.Store
            $now = (Get-ItemProperty -Path $StoreKey -Name AutoDownload -ErrorAction SilentlyContinue).AutoDownload
            Save-Shot $global:GT.Panel.Form "$($global:GT.Panel.Shot)-modify"
            Log "    狀態：$(OneLine (Get-StatusLabel $global:GT.Panel.Form).Text)"
            if ($now -eq $st.Expect) { Log "    [通過] 登錄值已變成 $now" } else { Add-TestFail "登錄值是 $now，預期 $($st.Expect)" }
            $st.Logged = "Microsoft Store 自動更新 > $($st.Button)"
            Restore-Store
            $true
        } 15)
    )
}
function Restore-Store {
    $st = $global:GT.Store
    if (-not $st -or $st.Restored) { return }
    if (-not $st.KeyExisted) { Remove-Item -Path $StoreKey -Recurse -Force -ErrorAction SilentlyContinue }
    elseif ($null -eq $st.Before) { Remove-ItemProperty -Path $StoreKey -Name AutoDownload -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $StoreKey -Name AutoDownload -Value $st.Before -Type DWord }
    $st.Restored = $true
    Log "    [還原] Store 設定已還原為：$(if (-not $st.KeyExisted) { '機碼不存在' } elseif ($null -eq $st.Before) { '未設定' } else { $st.Before })"
}

function Get-TimeSteps {
    $svc = Get-Service w32time
    $global:GT.Time = @{ StartType = [string]$svc.StartType; Status = [string]$svc.Status }
    [void]$global:GT.Restore.Add({ Restore-Time })
    @(
        (New-Step '時間：立即校時' {
            $b = Get-Button $global:GT.Panel.Form '立即校時'
            if (-not $b) { Add-TestFail '找不到按鈕「立即校時」'; return $true }
            Log "    [改動] w32time 原本：$($global:GT.Time.StartType) / $($global:GT.Time.Status)，按「立即校時」"
            Invoke-Later $b { $b.PerformClick() }.GetNewClosure()
            $true
        }),
        (New-Step '時間：確認在背景執行' {
            $lb = Get-LogBox $global:GT.Panel.Form
            if ($lb.Text -notmatch '執行中') { return $false }
            $global:GT.Time.T0 = $global:GT.Ticks
            $global:GT.Time.MsgCount = $global:GT.Msgs.Count
            $f = $global:GT.Panel.Form
            Invoke-Later $f { $f.Close() }.GetNewClosure()   # 執行中按關閉，應該被擋下來
            $global:GT.Time.Wait = 0
            $true
        } 15),
        (New-Step '時間：執行中不能關視窗' {
            $global:GT.Time.Wait++
            $f = $global:GT.Panel.Form
            $done = (Get-LogBox $f).Text -match '目前時間來源|同步沒有成功|\[錯誤\]'
            $asked = @($global:GT.Msgs | Select-Object -Skip $global:GT.Time.MsgCount | Where-Object { $_.Title -eq '請稍候' }).Count
            if (-not $asked -and -not $done -and $global:GT.Time.Wait -lt 12) { return $false }
            if ($done -and -not $asked) { Log '    （背景作業在測試按關閉前就結束了，略過「執行中不能關」的檢查）' }
            elseif ($f.Visible -and -not $f.IsDisposed -and $asked) { Log '    [通過] 執行中按關閉：跳出「請稍候」，視窗仍開著' }
            else { Add-TestFail "執行中按關閉：視窗仍開著=$($f.Visible)，跳出請稍候=$asked" }
            $true
        } 10),
        (New-Step '時間：等背景作業完成' {
            $lb = Get-LogBox $global:GT.Panel.Form
            if ($lb.Text -notmatch '目前時間來源|同步沒有成功|\[錯誤\]') { return $false }
            $ticks = $global:GT.Ticks - $global:GT.Time.T0
            Save-Shot $global:GT.Panel.Form "$($global:GT.Panel.Shot)-modify"
            Log "    背景作業期間介面計時器跑了 $ticks 次（介面沒有卡住才會持續跑）"
            Log "    結果區最後幾行：$((($lb.Text.Trim() -split "`r?`n") | Select-Object -Last 5) -join ' / ')"
            if ($lb.Text -match '\[錯誤\][^\r\n]*') { Add-TestFail "校時出錯：$($Matches[0])" }
            elseif ($lb.Text -match '同步沒有成功') { Log '    [警告] w32tm 同步沒有成功（多半是連不到 NTP，屬環境問題）' }
            else { Log '    [通過] 背景校時完成' }
            if ($ticks -lt 4) { Add-TestFail '背景作業期間介面計時器幾乎沒跑，介面可能卡住' }
            $global:GT.Time.Logged = '時間與時區 > 立即校時（背景）'
            Restore-Time
            $true
        } 120)
    )
}
function Restore-Time {
    $t = $global:GT.Time
    if (-not $t -or $t.Restored) { return }
    $now = Get-Service w32time
    if ([string]$now.StartType -ne $t.StartType) { Set-Service w32time -StartupType $t.StartType }
    if ($t.Status -eq 'Stopped' -and $now.Status -ne 'Stopped') { Stop-Service w32time -Force -ErrorAction SilentlyContinue }
    if ($t.Status -eq 'Running' -and $now.Status -ne 'Running') { Start-Service w32time -ErrorAction SilentlyContinue }
    $t.Restored = $true
    $after = Get-Service w32time
    Log "    [還原] w32time：$($after.StartType) / $($after.Status)（原本 $($t.StartType) / $($t.Status)）"
}

function Get-ScheduleSteps {
    $dummy = Join-Path $WorkDir 'gui-test-dummy.ps1'
    Set-Content -LiteralPath $dummy -Value 'exit 0' -Encoding ASCII
    $global:GT.Sch = @{ Label = $global:TestTagValue; Dummy = $dummy }
    [void]$global:GT.Restore.Add({ Restore-Schedule })
    @(
        (New-Step '排程：切到「定時執行腳本」' {
            $tabs = Get-AllControls $global:GT.Panel.Form | Where-Object { $_ -is [Windows.Forms.TabControl] } | Select-Object -First 1
            if (-not $tabs) { Add-TestFail '找不到分頁'; return $true }
            $tabs.SelectedIndex = 1
            $global:GT.Sch.Tab = $tabs.SelectedTab
            $true
        }),
        (New-Step '排程：按「新增」' {
            $b = Get-Button $global:GT.Sch.Tab '新增'
            if (-not $b) { Add-TestFail '找不到按鈕「新增」'; return $true }
            Log "    [改動] 新增定時腳本排程「$($global:GT.Sch.Label)」"
            $global:GT.Sch.Before = @(Get-VisibleForms)
            $global:GT.Sch.AddDone = $false
            Invoke-Later $b { try { $b.PerformClick() } finally { $global:GT.Sch.AddDone = $true } }.GetNewClosure()
            $true
        }),
        (New-Step '排程：填表並建立' {
            $f = Get-VisibleForms | Where-Object { $_.Text -like '新增定時腳本*' } | Select-Object -First 1
            if (-not $f) { return $false }
            $tb = @(Get-AllControls $f | Where-Object { $_ -is [Windows.Forms.TextBox] })
            $tb[0].Text = $global:GT.Sch.Label
            $tb[1].Text = $global:GT.Sch.Dummy
            Save-Shot $f "$($global:GT.Panel.Shot)-add"
            $ok = Get-Button $f '建立'
            Invoke-Later $ok { $ok.PerformClick() }.GetNewClosure()
            $true
        } 15),
        (New-Step '排程：確認已建立' {
            if (-not $global:GT.Sch.AddDone) { return $false }
            $label = $global:GT.Sch.Label
            $task = Get-ScheduledTask -TaskName 'OPS-Task-*' -ErrorAction SilentlyContinue | Where-Object { $_.Description -like "*$label*" } | Select-Object -First 1
            $grid = Get-AllControls $global:GT.Sch.Tab | Where-Object { $_ -is [Windows.Forms.DataGridView] } | Select-Object -First 1
            $row = $grid.Rows | Where-Object { [string]$_.Cells[0].Value -eq $label } | Select-Object -First 1
            if (-not $task -or -not $row) { Add-TestFail "排程沒有建立（工作排程器：$([bool]$task)，表格：$([bool]$row)）"; return $true }
            Log "    [通過] 已建立 $($task.TaskName)，表格也有這一列"
            $global:GT.Sch.TaskName = $task.TaskName
            $grid.ClearSelection(); $row.Selected = $true; $grid.CurrentCell = $row.Cells[0]
            $global:GT.YesTitles = @('確認')
            $rm = Get-Button $global:GT.Sch.Tab '移除'
            $global:GT.Sch.RemoveDone = $false
            Invoke-Later $rm { try { $rm.PerformClick() } finally { $global:GT.Sch.RemoveDone = $true } }.GetNewClosure()
            $true
        } 20),
        (New-Step '排程：確認已移除' {
            if (-not $global:GT.Sch.RemoveDone) { return $false }
            $global:GT.YesTitles = @()
            $left = Get-ScheduledTask -TaskName $global:GT.Sch.TaskName -ErrorAction SilentlyContinue
            Save-Shot $global:GT.Panel.Form "$($global:GT.Panel.Shot)-modify"
            if ($left) { Add-TestFail '按「移除」後排程還在' } else { Log '    [通過] 用面板的「移除」刪掉了' }
            $global:GT.Sch.Logged = @('自動排程 > 新增（Script）', '自動排程 > 移除')
            Restore-Schedule
            $true
        } 20)
    )
}
function Restore-Schedule {
    $s = $global:GT.Sch
    if (-not $s -or $s.Restored) { return }
    $left = @(Get-ScheduledTask -TaskName 'OPS-Task-*' -ErrorAction SilentlyContinue | Where-Object { $_.Description -like "*$($s.Label)*" })
    foreach ($t in $left) { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    $s.Restored = $true
    Log "    [還原] 測試排程殘留 $($left.Count) 個$(if ($left.Count) { '，已刪除' })"
}

# 操作記錄：確認改動都有記錄，然後把測試寫的那幾行從 actions.log 拿掉
function Test-ActionLog {
    $expect = @()
    if ($global:GT.Store.Logged) { $expect += $global:GT.Store.Logged }
    if ($global:GT.Time.Logged) { $expect += $global:GT.Time.Logged }
    if ($global:GT.Sch.Logged) { $expect += $global:GT.Sch.Logged }
    if (-not $expect) { return }
    Log ''
    Log '[操作記錄]'
    $lines = @(if (Test-Path $ActionLogPath) { Get-Content -LiteralPath $ActionLogPath -Encoding UTF8 })
    $since = $TestStart.ToString('yyyy-MM-dd HH:mm:ss')
    $mine = @($lines | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $since })
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'OPS-command'; Id = 200, 201; StartTime = $TestStart } -ErrorAction SilentlyContinue | ForEach-Object Message)
    foreach ($x in $expect) {
        $inFile = @($mine | Where-Object { $_.Contains($x) }).Count
        $inEvt = @($events | Where-Object { $_.Contains($x) }).Count
        if ($inFile -and $inEvt) { Log "  [通過] 「$x」：actions.log $inFile 筆、事件記錄 $inEvt 筆" }
        else { Add-TestFail "「$x」沒有完整記錄：actions.log $inFile 筆、事件記錄 $inEvt 筆" }
    }
    # 只刪測試期間、符合上面動作的行（排程那兩行還要含測試標籤）
    $remove = @($mine | Where-Object {
            $l = $_
            ($expect | Where-Object { $l.Contains($_) }) -and (($l -notmatch '自動排程 >') -or $l.Contains($global:TestTagValue))
        })
    if ($remove.Count) {
        $keep = @($lines | Where-Object { $_ -notin $remove })
        if ($global:GT.ActionLogExisted -or $keep.Count) {
            [IO.File]::WriteAllLines($ActionLogPath, [string[]]$keep, (New-Object System.Text.UTF8Encoding($true)))
        } else { Remove-Item -LiteralPath $ActionLogPath -Force }
        Log "  [還原] 從 actions.log 刪掉測試寫入的 $($remove.Count) 行（事件記錄無法逐筆刪除，保留）"
    }
}

# ---------------------------------------------------------------- 主流程的步驟
$global:TestTagValue = $TestTag
$global:GT.ActionLogExisted = Test-Path $ActionLogPath
$global:GT.ErrorCount = $Error.Count
$global:GT.Deadline = (Get-Date).AddSeconds(60 + [Math]::Max(1, $SidebarDef.Count) * ($PanelTimeoutSec + 20) + $(if ($Modify) { 300 } else { 0 }))

Add-Step '等主面板' {
    $m = if ($script:PanelForm) { $script:PanelForm } else { Get-VisibleForms | Select-Object -First 1 }
    if (-not $m -or -not $m.Visible) { return $false }
    if (-not $global:GT.Main) { $global:GT.Main = $m; $global:GT.MainWait = 0 }
    $global:GT.MainWait++
    if ($global:GT.MainWait -lt 6) { return $false }
    Save-Shot $m '00-main'
    Log ''
    Log "[主面板] $($m.Text)　截圖：00-main.png"
    $true
} 30 { Add-TestFail '主面板沒有出現' }

Add-Step '展開所有分類' {
    $m = $global:GT.Main
    $headers = @(Get-AllControls $m | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -match '^[▸▾]' })
    $bad = 0
    foreach ($h in $headers) {
        if ($h.Text -notmatch '^▸') { continue }
        try { $h.PerformClick() } catch { $bad++; Add-TestFail "點分類標題「$($h.Text)」出錯：$($_.Exception.Message)" }
    }
    $global:GT.Headers = $headers
    $global:GT.HeaderUnhandled = $global:GT.Unhandled.Count
    Log "  分類 $($headers.Count) 個"
    $true
}

Add-Step '列出側邊欄功能' {
    $m = $global:GT.Main
    $closed = @($global:GT.Headers | Where-Object { $_.Text -match '^▸' })
    if ($closed.Count) { Add-TestFail "有 $($closed.Count) 個分類點了沒有展開：$(($closed | ForEach-Object Text) -join '、')" }
    else { Log '  [通過] 每個分類點一下都展開了' }
    Save-Shot $m '00-sidebar'
    $side = Get-AllControls $m | Where-Object { $_ -is [Windows.Forms.FlowLayoutPanel] -and $_.Dock -eq 'Left' } | Select-Object -First 1
    $root = if ($side) { $side } else { $m }
    $buttons = @(Get-AllControls $root | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -notmatch '^[▸▾]' -and $_.Text -ne '關閉面板' })
    $titles = @($buttons | ForEach-Object Text)
    foreach ($d in $SidebarDef) { if ($d.Title -notin $titles) { Add-TestFail "原始碼有「$($d.Title)」，畫面上找不到這個按鈕" } }
    foreach ($t in $titles) { if ($SidebarDef.Count -and $t -notin @($SidebarDef | ForEach-Object Title)) { Log "  [資訊] 畫面上有「$t」，原始碼的側邊欄定義裡沒有" } }
    Log "  畫面上的功能按鈕 $($buttons.Count) 個（截圖：00-sidebar.png）"
    $i = 0
    foreach ($b in $buttons) {
        $i++
        if ($Only -and -not ($Only | Where-Object { $b.Text -like "*$_*" })) { continue }
        $def = $SidebarDef | Where-Object { $_.Title -eq $b.Text } | Select-Object -First 1
        if (-not $def) { $def = [pscustomobject]@{ Title = $b.Text; Action = '' } }
        Add-PanelSteps $i $b $def
    }
    Add-Step '關閉主面板' {
        $m = $global:GT.Main
        Invoke-Later $m { $m.Close() }.GetNewClosure()
        $true
    }
    $true
}

# ---------------------------------------------------------------- 執行
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick($tick)
$exitCode = 0
try {
    $timer.Start()
    try { Show-WindowsPanel }
    catch { Add-TestFail "主面板無法啟動：$($_.Exception.Message)（第 $($_.InvocationInfo.ScriptLineNumber) 行）" }
    $timer.Stop()
    if ($global:GT.Idx -lt $global:GT.Steps.Count -and -not $global:GT.Aborted) {
        Add-TestFail "主面板提早關閉，還有 $($global:GT.Steps.Count - $global:GT.Idx) 個步驟沒跑（停在「$($global:GT.Steps[$global:GT.Idx].Name)」）"
    }
    if ($Modify) { Test-ActionLog }
} catch {
    Add-TestFail "測試程式本身出錯：$($_.Exception.Message)（第 $($_.InvocationInfo.ScriptLineNumber) 行）"
} finally {
    $timer.Stop(); $timer.Dispose()
    foreach ($r in $global:GT.Restore) { try { & $r } catch { Log "  [還原失敗] $($_.Exception.Message)" } }
    foreach ($f in @([Windows.Forms.Application]::OpenForms)) { try { $f.Close() } catch { } }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Log ''
Log '[收尾檢查]'
if (Test-Path $ErrLogPath) {
    $len = (Get-Item $ErrLogPath).Length
    if ($len -gt $ErrLogSize) {
        $fs = [IO.File]::Open($ErrLogPath, 'Open', 'Read', 'ReadWrite')
        try { $fs.Position = $ErrLogSize; $buf = New-Object byte[] ($len - $ErrLogSize); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
        Add-TestFail "%TEMP%\OPS-command-error.log 新增了內容：$(OneLine ([Text.Encoding]::UTF8.GetString($buf)) 6)"
    } else { Log '  [通過] OPS-command-error.log 沒有新增內容' }
} else { Log '  [通過] 沒有 OPS-command-error.log' }
if ($global:GT.Unhandled.Count) { Log "  [失敗] .NET 未處理例外共 $($global:GT.Unhandled.Count) 個" } else { Log '  [通過] 沒有 .NET 未處理例外' }
Compare-Snapshot $StateBefore (Get-StateSnapshot) $(if ($Modify) { '還原後' } else { '測試後' })

Log ''
Log '========== 摘要 =========='
foreach ($r in $global:GT.Results) {
    Log ("  {0:D2} {1}  {2}  {3}{4}" -f $r.No, $r.Result, $r.Shot, $r.Title, $(if ($r.Why) { "　← $($r.Why)" } else { '' }))
}
$pass = @($global:GT.Results | Where-Object Result -eq '通過').Count
$fail = @($global:GT.Results | Where-Object Result -eq '失敗').Count
Log "功能視窗：通過 $pass、失敗 $fail；全部失敗項目 $($global:GT.Fails.Count) 項"
if ($global:GT.Fails.Count) {
    Log '失敗項目：'
    foreach ($x in $global:GT.Fails) { Log "  - $x" }
    $exitCode = 1
}
Log "結論：$(if ($exitCode) { '不通過' } else { '通過' })　結果檔：$ResultFile"
exit $exitCode
