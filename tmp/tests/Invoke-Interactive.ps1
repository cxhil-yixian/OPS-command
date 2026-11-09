<#
.SYNOPSIS
    在已登入的桌面工作階段（例如 RDP）裡執行一支腳本，等它結束、印出輸出，再把暫時排程刪掉。

.DESCRIPTION
    SSH 或 Session 0 裡的 PowerShell 沒有桌面，WinForms 視窗開不出來、也無法截圖。
    這支腳本建立一個暫時的排程工作（以目前帳號、互動式登入、最高權限），立即執行，
    讓目標腳本跑在該帳號「已登入的桌面」上；結束或逾時後一定刪除排程。

    需求：
      - 以系統管理員身分執行（註冊最高權限的排程需要）。
      - 目前帳號必須已經登入桌面（RDP 視窗開著、不要最小化，否則截圖會是黑的或失敗）。
      - 多個測試同時跑在同一台機器時，每個要用不同的 -TaskName。

    目標腳本的所有輸出（含錯誤）會寫到 -LogFile，結束後印出來。
    結束碼 = 目標腳本的結束碼；逾時 124；無法執行 2。

.PARAMETER Script
    要執行的 .ps1 完整路徑。

.PARAMETER Arguments
    傳給目標腳本的參數（原樣接在後面，例如 "-Modify -OutDir C:\OPS-test\gui"）。

.PARAMETER TimeoutSec
    最長等待秒數，逾時會強制停止，預設 600。

.PARAMETER TaskName
    暫時排程的名稱，預設 OPS-Test-Run。

.PARAMETER LogFile
    目標腳本輸出的存放位置，預設 %TEMP%\<TaskName>.log（印出後刪除）；有指定就保留。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Interactive.ps1 -Script C:\OPS-test\tests\Test-Gui.ps1 -Arguments "-OutDir C:\OPS-test\gui" -TaskName OPS-Test-gui
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Script,
    [string]$Arguments = '',
    [int]$TimeoutSec = 600,
    [string]$TaskName = 'OPS-Test-Run',
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '[無法執行] 需要系統管理員權限（要註冊最高權限的排程）。'; exit 2 }
if (-not [IO.Path]::IsPathRooted($Script)) { $Script = Join-Path (Get-Location).ProviderPath $Script }
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) { Write-Host "[無法執行] 找不到 $Script"; exit 2 }

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$shortUser = $user.Split('\')[-1]
# 確認這個帳號有登入中的桌面工作階段（quser 在中文系統的輸出用系統字碼頁，只比對帳號名稱）
$sessions = @(& quser 2>$null | Select-Object -Skip 1 | Where-Object { $_ -match "^\s*>?$([regex]::Escape($shortUser))\s" })
if (-not $sessions.Count) {
    Write-Host "[無法執行] $user 沒有登入中的桌面工作階段。請先用 RDP 登入這個帳號（視窗保持開著、不要最小化）。"
    exit 2
}

$keepLog = [bool]$LogFile
if (-not $LogFile) { $LogFile = Join-Path $env:TEMP "$TaskName.log" }
Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue

# 包一層：把目標腳本的所有輸出寫進記錄檔，並把它的結束碼帶出來
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$wrapper = @"
`$global:LASTEXITCODE = 0
try {
    & $(& $q $Script) $Arguments *>&1 | Out-File -LiteralPath $(& $q $LogFile) -Encoding UTF8 -Width 500
} catch {
    `$_ | Out-String | Out-File -LiteralPath $(& $q $LogFile) -Encoding UTF8 -Append
    exit 1
}
exit `$LASTEXITCODE
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -EncodedCommand $encoded"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSec + 60))
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

$code = 0
try {
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Start-Sleep -Seconds 2
    while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName
        Write-Host "[逾時] $TimeoutSec 秒內沒結束，已強制停止"
        $code = 124
    } else {
        $code = [int](Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult
        Write-Host "[結束] 結束碼 $code"
    }
} finally {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $LogFile) {
    Write-Host '---------- 輸出 ----------'
    Get-Content -LiteralPath $LogFile -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    if (-not $keepLog) { Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue }
}
exit $code
