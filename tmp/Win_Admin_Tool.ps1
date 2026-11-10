# Windows 10/11 系統管理工具 (PowerShell 版)

# 工具版本（Windows 圖形介面自己的版本號，跟 Linux ops.sh 的版本無關）。
# 改了程式就遞增：修 bug 加第三段、加功能加第二段、介面大改加第一段（見 README「版本號」）。
# 主面板開啟後會到線上讀這一行比對版本，所以這一行要留在檔案開頭、格式不要改。
$Script:ToolVersion = '2.0.0'

# ===== 檢查目前是否為系統管理員 (不強制提權,先記錄狀態) =====
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 不要用 SilentlyContinue：那會讓每個失敗都無聲無息，然後畫面照樣印「[完成]」。
# 設成 Continue，錯誤訊息會出現，會改到系統的動作再各自讀回來驗證。
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# 不要把 [Console]::OutputEncoding 設成 UTF-8。畫面是 WinForms，不經過主控台；
# 那個設定只會影響 PowerShell 怎麼解讀外部指令的輸出。實測繁中 Windows 10（字碼頁 950）
# 設成 UTF-8 後，w32tm 的輸出變亂碼，net accounts、bcdedit 則自動改成英文。

# 這支腳本自己的位置。走 ops-win.ps1 或 .bat 進來時 $PSCommandPath 有值;
# 但用 irm | iex 這種管線跑法時它是空的 -- 而提權一定要有實體路徑
# (Start-Process -Verb RunAs 只能指定檔案,沒有「把這段程式碼交給新的 elevated
# 行程」這種辦法)。所以管線跑法要先把自己的原始碼寫到 %LOCALAPPDATA% 再提權。
#
# 為什麼是 %LOCALAPPDATA% 不是 %ProgramData%：要以管理員身分執行的檔案，絕不能放在
# 別的使用者寫得到的地方。%ProgramData% 的子目錄預設讓 BUILTIN\Users 建立檔案
# （實測 icacls：Users:(CI)(WD,AD)），別人先放一個同名檔就成了擁有者，等你提權時跑的
# 就是他改過的內容。%LOCALAPPDATA% 只有你自己（和 SYSTEM / Administrators）進得去。
$Script:SelfPath   = $PSCommandPath
$Script:SelfSource = $MyInvocation.MyCommand.ScriptBlock.ToString()
$Script:LocalDir   = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }) 'OPS-command'

# 檢查新版用的來源，跟 ops-win.ps1 同一個規則：有設 OPS_RAW_BASE 就用它（fork／內網鏡像）。
$Script:RawBase = if ($env:OPS_RAW_BASE) { $env:OPS_RAW_BASE.TrimEnd('/') } else { 'https://raw.githubusercontent.com/cxhil-yixian/OPS-command/main' }

# 背景檢查新版（主面板開啟後在另一個 runspace 跑，看不到這支腳本的函式）。
# 只抓線上主程式的開頭幾 KB，讀出 $Script:ToolVersion 那一行，逐段比數字（1.10 > 1.9）。
# 比目前新才輸出 'NEWER <版本>'；一樣、比較舊、讀不到都不輸出。離線或失敗會丟例外，呼叫端一律安靜略過。
$Script:WorkerVersionCheck = @'
param([string]$Url, [string]$Current)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$req = [Net.HttpWebRequest]::Create($Url)
$req.Timeout = 8000; $req.ReadWriteTimeout = 8000
$req.UserAgent = 'OPS-command-version-check'
$req.AddRange(0, 8191)
$resp = $req.GetResponse()
try {
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $head = $sr.ReadToEnd()
} finally { $resp.Close() }
$m = [regex]::Match($head, "(?m)^\`$Script:ToolVersion\s*=\s*'(\d+(?:\.\d+)*)'")
if (-not $m.Success) { return }
$latest = $m.Groups[1].Value
$a = @($Current.Split('.')); $b = @($latest.Split('.'))
$n = [Math]::Max($a.Count, $b.Count)
for ($i = 0; $i -lt $n; $i++) {
    $x = [long]0; $y = [long]0
    if ($i -lt $a.Count) { [void][long]::TryParse($a[$i], [ref]$x) }
    if ($i -lt $b.Count) { [void][long]::TryParse($b[$i], [ref]$y) }
    if ($y -gt $x) { "NEWER $latest"; return }
    if ($y -lt $x) { return }
}
'@

function Get-SelfPath {
    if ($Script:SelfPath -and (Test-Path $Script:SelfPath)) { return $Script:SelfPath }
    $dir  = $Script:LocalDir
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $p = Join-Path $dir 'Win_Admin_Tool.ps1'
        # Set-Content -Encoding UTF8 在 5.1 會寫出 with BOM,跟原檔一致,-File 讀得對
        Set-Content -Path $p -Value $Script:SelfSource -Encoding UTF8
        $Script:SelfPath = $p
        return $p
    } catch {
        return $null
    }
}

# 以系統管理員身分重新啟動自己
function Restart-AsAdmin {
    $self = Get-SelfPath
    if (-not $self) {
        [Windows.Forms.MessageBox]::Show("取不到本腳本的實體路徑，也寫不進 %LOCALAPPDATA%，沒辦法提權。`r`n請改以系統管理員身分開啟 PowerShell 再執行一次。", '無法提權', 'OK', 'Error') | Out-Null
        return $false
    }
    # UAC 按「否」時 Start-Process 會丟 Win32Exception（1223 = 使用者取消）。
    # 一定要接住：沒接住的話例外會從按鈕事件漏出去，畫面上什麼都不會發生；
    # 而且呼叫端不能在失敗時關掉舊面板，否則使用者按「否」之後整個工具就不見了。
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$self`"" -Verb RunAs -ErrorAction Stop
    } catch {
        $msg = if ($_.Exception.GetBaseException().NativeErrorCode -eq 1223) { '已取消提權，面板維持一般權限。' } else { "無法以系統管理員身分重新啟動：$($_.Exception.Message)" }
        [Windows.Forms.MessageBox]::Show($msg, '未提權', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }
    # 在 WinForms 按鈕事件中使用 exit 會拋出 ExitException，.NET 會將它當成
    # 未處理的 UI 例外並顯示 JIT 錯誤框；正常關閉舊面板即可讓管理員版接手。
    # 管理員版已經起來了，舊面板要讓位。這裡只關「子視窗」並立旗標，主面板留給
    # 按鈕事件結束後再關（Close-PanelIfElevated）：在子視窗的模態迴圈還沒結束時就關
    # 主面板，WinForms 的行為不可靠。
    if ($script:PanelForm) {
        foreach ($f in @([Windows.Forms.Application]::OpenForms)) {
            if ($f -ne $script:PanelForm) { $f.Close() }
        }
        $script:PanelCloseAfterAction = $true
        return $true
    }
    exit
}

# ---- 操作記錄 ----
# 每個會改到系統的動作都留紀錄：時間、誰（是否管理員）、功能、動作、輸入、結果。
# 寫兩份：%LOCALAPPDATA%\OPS-command\actions.log 給人讀；Windows 事件記錄（應用程式，
# 來源 OPS-command，200 = 成功、201 = 失敗）給稽核——檔案刪得掉，事件記錄要管理員才清得掉。
# 記錄本身失敗絕不能影響操作，所以全部包在 try 裡。密碼一律不記。
$Script:ActionLogPath = Join-Path $Script:LocalDir 'actions.log'
function Write-OpsLog {
    param([string]$Feature, [string]$Action, [string]$Result, [string]$Detail = '')
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name + $(if ($IsAdmin) { '（管理員）' } else { '' })
    $detailOne = ((($Detail -split "`r?`n") | Where-Object { $_.Trim() }) -join ' / ').Trim().TrimStart('；')
    $line = '{0} | {1} | {2} > {3} | {4} | {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $who, $Feature, $Action, $Result, $detailOne
    try {
        if (-not (Test-Path $Script:LocalDir)) { New-Item -ItemType Directory -Path $Script:LocalDir -Force | Out-Null }
        Add-Content -Path $Script:ActionLogPath -Value $line -Encoding UTF8
    } catch { }
    if ($IsAdmin) {
        try {
            if (-not [Diagnostics.EventLog]::SourceExists('OPS-command')) { [Diagnostics.EventLog]::CreateEventSource('OPS-command', 'Application') }
            $type = if ($Result -eq '成功') { 'Information' } else { 'Warning' }
            $id = if ($Result -eq '成功') { 200 } else { 201 }
            [Diagnostics.EventLog]::WriteEntry('OPS-command', $line, $type, $id)
        } catch { }
    }
}

function Format-OpsInputs {
    param([hashtable]$Values)
    if (-not $Values -or -not $Values.Count) { return '' }
    ($Values.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
}

# 面板是用隱藏的 PowerShell 視窗跑的，錯誤訊息印在主控台等於沒人看得到。
# 一律跳訊息框，並把完整內容（含呼叫堆疊）寫進 %TEMP%\OPS-command-error.log 方便回報。
$Script:ErrorLogPath = Join-Path $env:TEMP 'OPS-command-error.log'
function Show-PanelError {
    param([string]$Title = 'OPS-command', $ErrorRecord)
    $msg = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    try {
        $detail = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { ($ErrorRecord | Out-String) + $ErrorRecord.ScriptStackTrace } else { $msg }
        Add-Content -Path $Script:ErrorLogPath -Encoding UTF8 -Value ("[{0}] {1}`r`n{2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Title, $detail)
        $msg += "`r`n`r`n詳細內容已寫入：`r`n$Script:ErrorLogPath"
    } catch { }
    [Windows.Forms.MessageBox]::Show($msg, "$Title｜發生錯誤", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

# 按鈕事件結束時呼叫：剛才已成功以管理員身分另開面板，就把舊的一般權限面板關掉。
function Close-PanelIfElevated {
    if ($script:PanelCloseAfterAction -and $script:PanelForm) {
        $script:PanelCloseAfterAction = $false
        $script:PanelForm.Close()
    }
}

function Request-PanelAdmin {
    if($IsAdmin){return $true}
    $answer=[Windows.Forms.MessageBox]::Show('此功能需要系統管理員權限。要重新以管理員身分開啟面板嗎?','需要管理員權限',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
    if($answer -eq [Windows.Forms.DialogResult]::Yes){ [void](Restart-AsAdmin) }
    return $false
}

# ---- 1. 更換 RDP Port ----
# 設計原則跟 SSH/ssh-port.sh 一樣:不讓你把自己鎖在門外。
#
# 換 port 一定要重啟 TermService,目前這條 RDP 連線必然會斷;新 port 若被雲端安全
# 群組、路由器或防火牆擋住,就再也連不回來,只能走主控台。所以:
#   1. 先確認新 port 沒有被別的程式佔用(佔用的話 RDP 根本起不來)
#   2. 新舊 port 的防火牆規則同時放行,舊規則留到你「確認」之後才收
#   3. 註冊排程工作當看門狗,時限內沒有確認就自動改回舊 port 並重啟服務
#   4. 看門狗建不起來就「不做」這次變更 —— 沒有還原機制的換 port 不能接受
$Script:RdpKey       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$Script:RdpTask      = 'OPS-RdpPort-Watchdog'
# 狀態存在 HKLM 而不是 %ProgramData% 底下的檔案。%ProgramData% 的子目錄預設給
# BUILTIN\Users「建立檔案」的權限（實測 icacls：Users:(CI)(WD,AD)），建檔的人就是
# 擁有者、之後還能改。任何一般使用者都能先放一個同名的空檔，等管理員寫入內容後
# 再改掉 —— 以前看門狗是用 SYSTEM 執行那裡的 rdp-revert.ps1，等於直接送出 SYSTEM 權限。
# HKLM\SOFTWARE 只有管理員寫得進去。
$Script:RdpStateKey  = 'HKLM:\SOFTWARE\OPS-command\RdpPort'
# 舊版留下的狀態檔，只在升級後還有進行中的變更時讀一次
$Script:RdpLegacyStateFile = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }) 'OPS-command\rdp-port.state'

function Get-RdpPort {
    (Get-ItemProperty -Path $Script:RdpKey -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
}

function Test-RdpWatchdog {
    [bool](Get-ScheduledTask -TaskName $Script:RdpTask -ErrorAction SilentlyContinue)
}

function Get-RdpOldPort {
    $v = (Get-ItemProperty -Path $Script:RdpStateKey -Name OldPort -ErrorAction SilentlyContinue).OldPort
    if ($v) { return [string]$v }
    # 舊版的看門狗還在跑時，狀態只在舊的檔案裡
    if (Test-Path $Script:RdpLegacyStateFile) {
        $m = Select-String -Path $Script:RdpLegacyStateFile -Pattern '^OldPort=(\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return $null
}

function Save-RdpState {
    param([int]$OldPort, [int]$NewPort, [int]$Minutes)
    New-Item -Path $Script:RdpStateKey -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $Script:RdpStateKey -Name OldPort -Value $OldPort -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $Script:RdpStateKey -Name NewPort -Value $NewPort -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $Script:RdpStateKey -Name Since -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -ErrorAction Stop
    Set-ItemProperty -Path $Script:RdpStateKey -Name DeadlineMinutes -Value $Minutes -Type DWord -ErrorAction Stop
}

function Clear-RdpState {
    Remove-Item -Path $Script:RdpStateKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $Script:RdpLegacyStateFile -Force -ErrorAction SilentlyContinue
}

function Add-RdpFirewallRule {
    param([int]$Port)
    netsh advfirewall firewall add rule name="OPS-RDP-$Port-TCP" dir=in action=allow protocol=TCP localport=$Port | Out-Null
    netsh advfirewall firewall add rule name="OPS-RDP-$Port-UDP" dir=in action=allow protocol=UDP localport=$Port | Out-Null
}

function Remove-RdpFirewallRule {
    param([int]$Port)
    netsh advfirewall firewall delete rule name="OPS-RDP-$Port-TCP" | Out-Null
    netsh advfirewall firewall delete rule name="OPS-RDP-$Port-UDP" | Out-Null
}

# 看門狗:用排程工作而不是背景行程,這樣即使這支腳本被關掉、使用者登出、
# 甚至 RDP 連線整個斷掉,還原動作照樣會執行。
#
# 還原指令用 -EncodedCommand 直接放進排程本身，不落地成腳本檔：排程存在系統保護的
# 位置，一般使用者改不到；放在 %ProgramData% 的 .ps1 則改得到（見上面 RdpStateKey 的說明）。
# 同樣的理由，以 SYSTEM 執行的還原動作也不碰任何使用者寫得到的路徑：
# 紀錄寫進 Windows 事件記錄（應用程式，來源 OPS-command，事件 100），不寫檔案。
function Register-RdpWatchdog {
    param([int]$OldPort, [int]$Minutes)
    # 純 ASCII：事件訊息經 eventcreate 寫入，避開編碼問題
    $body = @"
`$ErrorActionPreference = 'Continue'
Set-ItemProperty -Path '$($Script:RdpKey)' -Name PortNumber -Value $OldPort
netsh advfirewall firewall add rule name="OPS-RDP-$OldPort-TCP" dir=in action=allow protocol=TCP localport=$OldPort | Out-Null
netsh advfirewall firewall add rule name="OPS-RDP-$OldPort-UDP" dir=in action=allow protocol=UDP localport=$OldPort | Out-Null
Restart-Service TermService -Force
Remove-Item -Path '$($Script:RdpStateKey)' -Recurse -Force -ErrorAction SilentlyContinue
eventcreate /L APPLICATION /SO OPS-command /ID 100 /T WARNING /D "OPS-command RDP watchdog: not confirmed within $Minutes minutes, RDP port reverted to $OldPort." | Out-Null
Unregister-ScheduledTask -TaskName '$($Script:RdpTask)' -Confirm:`$false
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    try {
        $ps        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action    = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($Minutes)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $Script:RdpTask -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $Script:WatchdogError = $_.Exception.Message
        return $false
    }
}

function Unregister-RdpWatchdog {
    if (Test-RdpWatchdog) {
        Unregister-ScheduledTask -TaskName $Script:RdpTask -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Show-PortManagementPanel {
    $form=New-Object Windows.Forms.Form
    $form.Text='防火牆 Port 管理'
    $form.Size=New-Object Drawing.Size(820,560)
    $form.MinimumSize=New-Object Drawing.Size(820,560)
    $form.StartPosition='CenterParent'
    $form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $head=New-Object Windows.Forms.Panel; $head.Dock='Top'; $head.Height=66; $head.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $title=New-Object Windows.Forms.Label
    $title.Text='防火牆 Port 管理'
    $title.Location=New-Object Drawing.Point(18,15)
    $title.Size=New-Object Drawing.Size(500,34)
    $title.Font=New-Object Drawing.Font('Microsoft JhengHei UI',15,[Drawing.FontStyle]::Bold)
    $title.ForeColor=[Drawing.Color]::White
    $head.Controls.Add($title)
    $label=New-Object Windows.Forms.Label
    $label.Text='Port 號碼'
    $label.Location=New-Object Drawing.Point(22,88)
    $label.Size=New-Object Drawing.Size(100,28)
    $form.Controls.Add($label)
    $portBox=New-Object Windows.Forms.TextBox
    $portBox.Location=New-Object Drawing.Point(125,84)
    $portBox.Size=New-Object Drawing.Size(150,30)
    $form.Controls.Add($portBox)
    $protoLabel=New-Object Windows.Forms.Label
    $protoLabel.Text='通訊協定'
    $protoLabel.Location=New-Object Drawing.Point(300,88)
    $protoLabel.Size=New-Object Drawing.Size(90,28)
    $form.Controls.Add($protoLabel)
    $proto=New-Object Windows.Forms.ComboBox
    $proto.DropDownStyle='DropDownList'
    [void]$proto.Items.AddRange(@('TCP','UDP','TCP + UDP'))
    $proto.SelectedIndex=0
    $proto.Location=New-Object Drawing.Point(390,84)
    $proto.Size=New-Object Drawing.Size(180,30)
    $form.Controls.Add($proto)
    $result=New-Object Windows.Forms.TextBox
    $result.Multiline=$true
    $result.ReadOnly=$true
    $result.ScrollBars='Both'
    $result.WordWrap=$false
    $result.Location=New-Object Drawing.Point(22,140)
    $result.Size=New-Object Drawing.Size(755,315)
    $result.Anchor='Top,Bottom,Left,Right'
    $result.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $result.BackColor=[Drawing.Color]::FromArgb(15,23,42)
    $result.ForeColor=[Drawing.Color]::FromArgb(226,232,240)
    $form.Controls.Add($result)
    $open=New-Object Windows.Forms.Button
    $open.Text='開啟 Port'
    $open.Location=New-Object Drawing.Point(22,470)
    $open.Size=New-Object Drawing.Size(120,36)
    $open.Anchor='Bottom,Left'
    $open.FlatStyle='Flat'
    $open.BackColor=[Drawing.Color]::FromArgb(21,94,75)
    $open.ForeColor=[Drawing.Color]::White
    $form.Controls.Add($open)
    $query=New-Object Windows.Forms.Button
    $query.Text='查詢狀態'
    $query.Location=New-Object Drawing.Point(155,470)
    $query.Size=New-Object Drawing.Size(120,36)
    $query.Anchor='Bottom,Left'
    $query.FlatStyle='Flat'
    $query.BackColor=[Drawing.Color]::FromArgb(37,67,119)
    $query.ForeColor=[Drawing.Color]::White
    $form.Controls.Add($query)
    $remove=New-Object Windows.Forms.Button
    $remove.Text='關閉本工具規則'
    $remove.Location=New-Object Drawing.Point(288,470)
    $remove.Size=New-Object Drawing.Size(160,36)
    $remove.Anchor='Bottom,Left'
    $remove.FlatStyle='Flat'
    $remove.BackColor=[Drawing.Color]::FromArgb(127,29,29)
    $remove.ForeColor=[Drawing.Color]::White
    $form.Controls.Add($remove)
    $close=New-Object Windows.Forms.Button
    $close.Text='關閉視窗'
    $close.Location=New-Object Drawing.Point(687,470)
    $close.Size=New-Object Drawing.Size(90,36)
    $close.Anchor='Bottom,Right'
    $close.FlatStyle='Flat'
    $close.BackColor=[Drawing.Color]::FromArgb(254,226,226)
    $close.ForeColor=[Drawing.Color]::FromArgb(153,27,27)
    $close.Add_Click({$form.Close()}.GetNewClosure())
    $form.Controls.Add($close)
    $getPort={ if([string]::IsNullOrWhiteSpace($portBox.Text)){return $null}
        $n=0
        if(-not [int]::TryParse($portBox.Text.Trim(),[ref]$n) -or $n -lt 1 -or $n -gt 65535){throw 'Port 必須是 1 到 65535 的整數。'}
        return $n }.GetNewClosure()
    $open.Add_Click({try{$p=& $getPort
            if(-not $p){throw '請先輸入 Port 號碼。'}
            if(-not (Request-PanelAdmin)){return}
            $protos=if($proto.SelectedIndex -eq 2){@('TCP','UDP')}else{@([string]$proto.SelectedItem)}
            foreach($pr in $protos){& netsh advfirewall firewall add rule name="Open-$pr-$p" dir=in action=allow protocol=$pr localport=$p | Out-Null
                if($LASTEXITCODE -ne 0){throw "建立 $pr 規則失敗，netsh exit code=$LASTEXITCODE"}}
            $result.Text="已建立入站放行規則：Port $p / $($protos -join ', ')`r`n`r`n提醒：若是雲端主機，也要在雲端防火牆／安全群組放行。";Write-OpsLog '防火牆 Port 管理' '開啟 Port' '成功' "Port $p / $($protos -join ', ')"}catch{$result.Text="開啟失敗：$($_.Exception.Message)";Write-OpsLog '防火牆 Port 管理' '開啟 Port' '失敗' $_.Exception.Message}}.GetNewClosure())
    $query.Add_Click({try{$p=& $getPort
            $protocols=if($proto.SelectedIndex -eq 0){@('tcp')}elseif($proto.SelectedIndex -eq 1){@('udp')}else{@('tcp','udp')}
            $lines=@()
            foreach($pr in $protocols){$lines+=@(netstat -ano -p $pr)}
            $lines=@($lines | Where-Object {$fields=($_.Trim() -split '\s+')
                $fields.Count -ge 4 -and ($fields[0] -eq 'UDP' -or $fields[3] -eq 'LISTENING')})
            if(-not $p){$result.Text=($lines | Out-String -Width 180)}else{$hits=@($lines | Where-Object { $fields=($_.Trim() -split '\s+')
                    $fields[1] -match (':' + [regex]::Escape([string]$p) + '$') })
                if($hits.Count){$result.Text=$hits -join "`r`n"}else{$result.Text="本機目前沒有 Port $p 的監聽項目。"}}}catch{$result.Text="查詢失敗：$($_.Exception.Message)"}}.GetNewClosure())
    $remove.Add_Click({try{$p=& $getPort
            if(-not $p){throw '請先輸入 Port 號碼。'}
            if(-not (Request-PanelAdmin)){return}
            $answer=[Windows.Forms.MessageBox]::Show("確定移除本工具建立的 Port $p TCP/UDP 規則?",'確認',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
            if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
            foreach($pr in @('TCP','UDP')){& netsh advfirewall firewall delete rule name="Open-$pr-$p" | Out-Null}
            $result.Text="已移除本工具規則：Open-TCP-$p、Open-UDP-$p。其他名稱的防火牆規則未修改。";Write-OpsLog '防火牆 Port 管理' '移除本工具規則' '成功' "Port $p"}catch{$result.Text="關閉失敗：$($_.Exception.Message)";Write-OpsLog '防火牆 Port 管理' '移除本工具規則' '失敗' $_.Exception.Message}}.GetNewClosure())
    $form.Controls.Add($head); [void]$form.ShowDialog($script:PanelForm); $form.Dispose()
}

# ---- 9. 磁碟管理 ----

function Show-DiskVisualPanel {
    $form=New-Object Windows.Forms.Form
    $form.Text='磁碟與磁碟區概覽'
    $form.Size=New-Object Drawing.Size(1120,720)
    $form.MinimumSize=New-Object Drawing.Size(900,560)
    $form.StartPosition='CenterParent'
    $form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $header=New-Object Windows.Forms.Panel; $header.Dock='Top'; $header.Height=74; $header.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $title=New-Object Windows.Forms.Label
    $title.Text='磁碟與磁碟區概覽'
    $title.Location=New-Object Drawing.Point(20,10)
    $title.Size=New-Object Drawing.Size(600,34)
    $title.Font=New-Object Drawing.Font('Microsoft JhengHei UI',16,[Drawing.FontStyle]::Bold)
    $title.ForeColor=[Drawing.Color]::White
    $header.Controls.Add($title)
    $subtitle=New-Object Windows.Forms.Label
    $subtitle.Text='唯讀檢視｜選取磁碟查看分割區；右側顯示磁碟區空間使用情況'
    $subtitle.Location=New-Object Drawing.Point(22,45)
    $subtitle.Size=New-Object Drawing.Size(850,22)
    $subtitle.ForeColor=[Drawing.Color]::FromArgb(219,234,254)
    $header.Controls.Add($subtitle)
    $split=New-Object Windows.Forms.SplitContainer
    $split.Size=New-Object Drawing.Size(1080,590)
    $split.SplitterDistance=600
    $split.Dock='Fill'
    $split.BackColor=[Drawing.Color]::FromArgb(226,232,240)
    $diskLabel=New-Object Windows.Forms.Label
    $diskLabel.Text='實體磁碟與分割區'
    $diskLabel.Dock='Top'
    $diskLabel.Height=34
    $diskLabel.Padding=New-Object Windows.Forms.Padding(12,8,0,0)
    $diskLabel.Font=New-Object Drawing.Font('Microsoft JhengHei UI',11,[Drawing.FontStyle]::Bold)
    $diskGrid=New-Object Windows.Forms.DataGridView
    $diskGrid.Dock='Fill'
    $diskGrid.ReadOnly=$true
    $diskGrid.AllowUserToAddRows=$false
    $diskGrid.AllowUserToDeleteRows=$false
    $diskGrid.SelectionMode='FullRowSelect'
    $diskGrid.MultiSelect=$false
    $diskGrid.AutoSizeColumnsMode='Fill'
    $diskGrid.RowHeadersVisible=$false
    $diskGrid.BackgroundColor=[Drawing.Color]::White
    $diskGrid.EnableHeadersVisualStyles=$false
    $diskGrid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $diskGrid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White
    $diskGrid.DefaultCellStyle.Font=New-Object Drawing.Font('Microsoft JhengHei UI',9)
    $diskGrid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(239,246,255)
    foreach($col in @(@{Name='Disk'
        Header='磁碟'},@{Name='Partition'
        Header='分割區'},@{Name='Size'
        Header='容量 GB'},@{Name='Letter'
        Header='磁碟代號'},@{Name='Style'
        Header='樣式'},@{Name='Health'
        Header='狀態'})){[void]$diskGrid.Columns.Add($col.Name,$col.Header)}
    $split.Panel1.Controls.Add($diskGrid); $split.Panel1.Controls.Add($diskLabel)
    $volumeHeader=New-Object Windows.Forms.Label
    $volumeHeader.Text='磁碟區使用量'
    $volumeHeader.Dock='Top'
    $volumeHeader.Height=34
    $volumeHeader.Padding=New-Object Windows.Forms.Padding(12,8,0,0)
    $volumeHeader.Font=New-Object Drawing.Font('Microsoft JhengHei UI',11,[Drawing.FontStyle]::Bold)
    $volumeFlow=New-Object Windows.Forms.FlowLayoutPanel
    $volumeFlow.Dock='Fill'
    $volumeFlow.FlowDirection='TopDown'
    $volumeFlow.WrapContents=$false
    $volumeFlow.AutoScroll=$true
    $volumeFlow.Padding=New-Object Windows.Forms.Padding(12)
    $volumeFlow.BackColor=[Drawing.Color]::White
    $split.Panel2.Controls.Add($volumeFlow); $split.Panel2.Controls.Add($volumeHeader)
    $footer=New-Object Windows.Forms.Panel; $footer.Dock='Bottom'; $footer.Height=48; $footer.BackColor=[Drawing.Color]::FromArgb(226,232,240)
    $refresh=New-Object Windows.Forms.Button
    $refresh.Text='重新整理'
    $refresh.Size=New-Object Drawing.Size(110,32)
    $refresh.Location=New-Object Drawing.Point(12,8)
    $refresh.FlatStyle='Flat'
    $refresh.BackColor=[Drawing.Color]::FromArgb(219,234,254)
    $refresh.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
    $footer.Controls.Add($refresh)
    $close=New-Object Windows.Forms.Button
    $close.Text='關閉'
    $close.Size=New-Object Drawing.Size(90,32)
    $close.Location=New-Object Drawing.Point(0,8)
    $close.Anchor='Top,Right'
    $close.FlatStyle='Flat'
    $footer.Controls.Add($close)
    $positionClose={ $close.Location=New-Object Drawing.Point([Math]::Max(10,$footer.ClientSize.Width-102),8) }.GetNewClosure()
    $footer.Add_Resize($positionClose)
    & $positionClose
    $close.Add_Click({$form.Close()}.GetNewClosure())
    $form.Controls.Add($split); $form.Controls.Add($footer); $form.Controls.Add($header)
    $reload={
        $diskGrid.Rows.Clear(); $volumeFlow.Controls.Clear()
        $disks=@(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)
        foreach($disk in $disks){
            $parts=@(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Sort-Object Offset)
            if(-not $parts.Count){$i=$diskGrid.Rows.Add($disk.Number,'(無分割區)',[math]::Round($disk.Size/1GB,1),'—',$disk.PartitionStyle,$disk.HealthStatus)
                continue}
            foreach($part in $parts){$letter=if($part.DriveLetter){"$($part.DriveLetter):"}else{'—'}
                $i=$diskGrid.Rows.Add($disk.Number,$part.Type,[math]::Round($part.Size/1GB,1),$letter,$disk.PartitionStyle,$disk.HealthStatus)
                if($disk.IsBoot -or $disk.IsSystem){$diskGrid.Rows[$i].DefaultCellStyle.Font=New-Object Drawing.Font('Microsoft JhengHei UI',9,[Drawing.FontStyle]::Bold)}}
        }
        $volumes=@(Get-Volume -ErrorAction SilentlyContinue | Where-Object {$_.DriveLetter -and $_.Size -gt 0} | Sort-Object DriveLetter)
        foreach($volume in $volumes){
            $used=$volume.Size-$volume.SizeRemaining; $pct=[math]::Min(100,[math]::Max(0,[math]::Round($used/$volume.Size*100)))
            $card=New-Object Windows.Forms.Panel
            $card.Width=[Math]::Max(250,$volumeFlow.ClientSize.Width-42)
            $card.Height=94
            $card.Margin=New-Object Windows.Forms.Padding(4,4,4,10)
            $card.BackColor=[Drawing.Color]::FromArgb(248,250,252)
            $name=New-Object Windows.Forms.Label
            $name.Text="$($volume.DriveLetter):  $($volume.FileSystemLabel)"
            $name.Location=New-Object Drawing.Point(12,8)
            $name.Size=New-Object Drawing.Size(390,24)
            $name.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10,[Drawing.FontStyle]::Bold)
            $card.Controls.Add($name)
            $bar=New-Object Windows.Forms.ProgressBar
            $bar.Location=New-Object Drawing.Point(12,36)
            $bar.Size=New-Object Drawing.Size(390,18)
            $bar.Minimum=0
            $bar.Maximum=100
            $bar.Value=$pct
            $bar.Style='Continuous'
            $card.Controls.Add($bar)
            $stats=New-Object Windows.Forms.Label
            $stats.Text="已用 $([math]::Round($used/1GB,1)) GB / $([math]::Round($volume.Size/1GB,1)) GB（$pct%）　可用 $([math]::Round($volume.SizeRemaining/1GB,1)) GB"
            $stats.Location=New-Object Drawing.Point(12,61)
            $stats.Size=New-Object Drawing.Size([Math]::Max(220,$card.Width-24),24)
            $stats.ForeColor=[Drawing.Color]::FromArgb(51,65,85)
            $card.Controls.Add($stats)
            $volumeFlow.Controls.Add($card)
        }
        if(-not $disks.Count){$i=$diskGrid.Rows.Add('—','讀取不到磁碟資訊','—','—','—','—')}
        if(-not $volumes.Count){$empty=New-Object Windows.Forms.Label; $empty.Text='沒有可顯示的磁碟區'; $empty.AutoSize=$true; $volumeFlow.Controls.Add($empty)}
    }.GetNewClosure()
    $refresh.Add_Click($reload); & $reload
    $owner=if($script:ActiveFeatureForm){$script:ActiveFeatureForm}else{$script:PanelForm}; [void]$form.ShowDialog($owner); $form.Dispose()
}

function Show-DiskManagementPanel {
    param([Parameter(Mandatory=$true)][ValidateSet('Change','Format','Wipe')][string]$Mode)
    if(-not (Request-PanelAdmin)){return}
    $titleMap=@{Change='變更磁碟機代號';Format='格式化磁碟區';Wipe='清除整顆磁碟'}
    $titleText=$titleMap[$Mode]
    $form=New-Object Windows.Forms.Form
    $form.Text=$titleText
    $form.Size=New-Object Drawing.Size(820,560)
    $form.MinimumSize=New-Object Drawing.Size(820,560)
    $form.StartPosition='CenterParent'
    $form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $head=New-Object Windows.Forms.Panel; $head.Dock='Top'; $head.Height=66; $head.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $heading=New-Object Windows.Forms.Label
    $heading.Text=$titleText
    $heading.Location=New-Object Drawing.Point(18,15)
    $heading.Size=New-Object Drawing.Size(600,34)
    $heading.Font=New-Object Drawing.Font('Microsoft JhengHei UI',15,[Drawing.FontStyle]::Bold)
    $heading.ForeColor=[Drawing.Color]::White
    $head.Controls.Add($heading)
    $info=New-Object Windows.Forms.Label
    $info.Location=New-Object Drawing.Point(22,82)
    $info.Size=New-Object Drawing.Size(750,52)
    $info.ForeColor=[Drawing.Color]::FromArgb(51,65,85)
    $form.Controls.Add($info)
    $log=New-Object Windows.Forms.TextBox
    $log.Multiline=$true
    $log.ReadOnly=$true
    $log.ScrollBars='Vertical'
    $log.Location=New-Object Drawing.Point(22,350)
    $log.Size=New-Object Drawing.Size(755,100)
    $log.Anchor='Bottom,Left,Right'
    $log.BackColor=[Drawing.Color]::White
    $log.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $form.Controls.Add($log)
    $go=New-Object Windows.Forms.Button
    $go.Text=if($Mode -eq 'Change'){'變更代號'}elseif($Mode -eq 'Format'){'開始格式化'}else{'清除整顆磁碟'}
    $go.Location=New-Object Drawing.Point(22,465)
    $go.Size=New-Object Drawing.Size(170,38)
    $go.Anchor='Bottom,Left'
    $go.FlatStyle='Flat'
    $go.BackColor=if($Mode -eq 'Wipe' -or $Mode -eq 'Format'){[Drawing.Color]::FromArgb(127,29,29)}else{[Drawing.Color]::FromArgb(37,67,119)}
    $go.ForeColor=[Drawing.Color]::White
    $form.Controls.Add($go)
    $close=New-Object Windows.Forms.Button
    $close.Text='關閉視窗'
    $close.Location=New-Object Drawing.Point(687,465)
    $close.Size=New-Object Drawing.Size(90,38)
    $close.Anchor='Bottom,Right'
    $close.FlatStyle='Flat'
    $close.BackColor=[Drawing.Color]::FromArgb(254,226,226)
    $close.ForeColor=[Drawing.Color]::FromArgb(153,27,27)
    $close.Add_Click({$form.Close()}.GetNewClosure())
    $form.Controls.Add($close)
    if($Mode -eq 'Change'){
        $info.Text='選擇現有磁碟機代號與未使用的新代號。此操作不會格式化磁碟。'
        $source=New-Object Windows.Forms.ComboBox
        $source.DropDownStyle='DropDownList'
        $source.Location=New-Object Drawing.Point(22,150)
        $source.Size=New-Object Drawing.Size(250,30)
        $form.Controls.Add($source)
        $newLabel=New-Object Windows.Forms.Label
        $newLabel.Text='新代號'
        $newLabel.Location=New-Object Drawing.Point(300,154)
        $newLabel.Size=New-Object Drawing.Size(80,25)
        $form.Controls.Add($newLabel)
        $target=New-Object Windows.Forms.ComboBox
        $target.DropDownStyle='DropDownList'
        $target.Location=New-Object Drawing.Point(390,150)
        $target.Size=New-Object Drawing.Size(150,30)
        $form.Controls.Add($target)
        $used=@(Get-Volume -ErrorAction SilentlyContinue | Where-Object {$_.DriveLetter} | ForEach-Object {[string]$_.DriveLetter})
        foreach($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object {$_.DriveLetter} | Sort-Object DriveLetter)){$source.Items.Add("$($v.DriveLetter):  $($v.FileSystemLabel)")|Out-Null}
        # 'D'..'Z' 這種字元範圍要 PowerShell 7 才支援；5.1 會丟「無法將 "D" 轉換為 Int32」，整個視窗打不開
        foreach($letter in ([char[]](68..90) | ForEach-Object { [string]$_ })){if($letter -notin $used){$target.Items.Add($letter)|Out-Null}}
        if($source.Items.Count){$source.SelectedIndex=0}; if($target.Items.Count){$target.SelectedIndex=0}
        $go.Add_Click({try{if(-not $source.SelectedItem -or -not $target.SelectedItem){throw '請選擇來源與新代號。'}
                $old=([string]$source.SelectedItem).Substring(0,1)
                $new=[string]$target.SelectedItem
                if($old -eq 'C'){throw '拒絕變更系統磁碟 C: 的代號。'}
                Set-Partition -DriveLetter $old -NewDriveLetter $new -ErrorAction Stop
                $log.Text="已將 $old`: 變更為 $new`:。";Write-OpsLog '變更磁碟機代號' '變更代號' '成功' "$old`: -> $new`:"}catch{$log.Text="變更失敗：$($_.Exception.Message)";Write-OpsLog '變更磁碟機代號' '變更代號' '失敗' $_.Exception.Message}}.GetNewClosure())
    }elseif($Mode -eq 'Format'){
        $info.Text='格式化會清除所選磁碟區的資料。系統磁碟 C: 不可選；需再次輸入磁碟機代號確認。'
        $volLabel=New-Object Windows.Forms.Label
        $volLabel.Text='磁碟區'
        $volLabel.Location=New-Object Drawing.Point(22,150)
        $volLabel.Size=New-Object Drawing.Size(100,25)
        $form.Controls.Add($volLabel)
        $volume=New-Object Windows.Forms.ComboBox
        $volume.DropDownStyle='DropDownList'
        $volume.Location=New-Object Drawing.Point(130,146)
        $volume.Size=New-Object Drawing.Size(350,30)
        $form.Controls.Add($volume)
        foreach($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object {$_.DriveLetter -and $_.DriveLetter -ne 'C'} | Sort-Object DriveLetter)){$volume.Items.Add("$($v.DriveLetter):  $($v.FileSystemLabel)  [$($v.FileSystemType)]")|Out-Null}
        if($volume.Items.Count){$volume.SelectedIndex=0}
        $fsLabel=New-Object Windows.Forms.Label
        $fsLabel.Text='檔案系統'
        $fsLabel.Location=New-Object Drawing.Point(22,198)
        $fsLabel.Size=New-Object Drawing.Size(100,25)
        $form.Controls.Add($fsLabel)
        $fs=New-Object Windows.Forms.ComboBox
        $fs.DropDownStyle='DropDownList'
        [void]$fs.Items.AddRange(@('NTFS','exFAT','FAT32'))
        $fs.SelectedIndex=0
        $fs.Location=New-Object Drawing.Point(130,194)
        $fs.Size=New-Object Drawing.Size(160,30)
        $form.Controls.Add($fs)
        $labelName=New-Object Windows.Forms.Label
        $labelName.Text='磁碟區標籤'
        $labelName.Location=New-Object Drawing.Point(22,244)
        $labelName.Size=New-Object Drawing.Size(100,25)
        $form.Controls.Add($labelName)
        $labelBox=New-Object Windows.Forms.TextBox
        $labelBox.Location=New-Object Drawing.Point(130,240)
        $labelBox.Size=New-Object Drawing.Size(300,30)
        $form.Controls.Add($labelBox)
        $confirmLabel=New-Object Windows.Forms.Label
        $confirmLabel.Text='再次輸入代號'
        $confirmLabel.Location=New-Object Drawing.Point(22,290)
        $confirmLabel.Size=New-Object Drawing.Size(100,25)
        $form.Controls.Add($confirmLabel)
        $confirmBox=New-Object Windows.Forms.TextBox
        $confirmBox.Location=New-Object Drawing.Point(130,286)
        $confirmBox.Size=New-Object Drawing.Size(160,30)
        $form.Controls.Add($confirmBox)
        $go.Add_Click({try{if(-not $volume.SelectedItem){throw '沒有可格式化的磁碟區。'}
                $dl=([string]$volume.SelectedItem).Substring(0,1)
                if($dl -eq 'C'){throw '拒絕格式化系統磁碟 C:。'}
                if($confirmBox.Text.TrimEnd(':').ToUpperInvariant() -ne $dl.ToUpperInvariant()){throw '代號確認不符，已取消。'}
                $answer=[Windows.Forms.MessageBox]::Show("格式化 $dl`: 將刪除該磁碟區的所有資料。確定繼續?",'最後確認',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
                if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
                Format-Volume -DriveLetter $dl -FileSystem ([string]$fs.SelectedItem) -NewFileSystemLabel $labelBox.Text -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $log.Text="格式化完成：$dl`:，檔案系統 $($fs.SelectedItem)。";Write-OpsLog '格式化磁碟區' '格式化' '成功' "$dl`: $($fs.SelectedItem)"}catch{$log.Text="格式化失敗：$($_.Exception.Message)";Write-OpsLog '格式化磁碟區' '格式化' '失敗' $_.Exception.Message}}.GetNewClosure())
    }else{
        $info.Text='清除整顆磁碟會移除所有分割區與資料，無法復原。系統磁碟與開機磁碟會被拒絕。'
        $diskLabel=New-Object Windows.Forms.Label
        $diskLabel.Text='目標磁碟'
        $diskLabel.Location=New-Object Drawing.Point(22,150)
        $diskLabel.Size=New-Object Drawing.Size(100,25)
        $form.Controls.Add($diskLabel)
        $diskBox=New-Object Windows.Forms.ComboBox
        $diskBox.DropDownStyle='DropDownList'
        $diskBox.Location=New-Object Drawing.Point(130,146)
        $diskBox.Size=New-Object Drawing.Size(600,30)
        $form.Controls.Add($diskBox)
        $disks=@(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)
        foreach($d in $disks){$diskBox.Items.Add("Disk $($d.Number)｜$($d.FriendlyName)｜$([math]::Round($d.Size/1GB,1)) GB$(if($d.IsBoot -or $d.IsSystem){'｜系統/開機，禁止清除'})")|Out-Null}
        if($diskBox.Items.Count){$diskBox.SelectedIndex=0}
        $diskConfirmLabel=New-Object Windows.Forms.Label
        $diskConfirmLabel.Text='再次輸入磁碟編號'
        $diskConfirmLabel.Location=New-Object Drawing.Point(22,198)
        $diskConfirmLabel.Size=New-Object Drawing.Size(130,25)
        $form.Controls.Add($diskConfirmLabel)
        $diskConfirm=New-Object Windows.Forms.TextBox
        $diskConfirm.Location=New-Object Drawing.Point(160,194)
        $diskConfirm.Size=New-Object Drawing.Size(150,30)
        $form.Controls.Add($diskConfirm)
        $eraseLabel=New-Object Windows.Forms.Label
        $eraseLabel.Text='最後確認輸入 ERASE'
        $eraseLabel.Location=New-Object Drawing.Point(22,244)
        $eraseLabel.Size=New-Object Drawing.Size(130,25)
        $form.Controls.Add($eraseLabel)
        $eraseConfirm=New-Object Windows.Forms.TextBox
        $eraseConfirm.Location=New-Object Drawing.Point(160,240)
        $eraseConfirm.Size=New-Object Drawing.Size(200,30)
        $form.Controls.Add($eraseConfirm)
        $go.Add_Click({try{if(-not $diskBox.SelectedItem){throw '沒有可清除的磁碟。'}
                $m=[regex]::Match([string]$diskBox.SelectedItem,'^Disk (\d+)')
                if(-not $m.Success){throw '無法辨識磁碟編號。'}
                $n=[int]$m.Groups[1].Value
                $disk=Get-Disk -Number $n -ErrorAction Stop
                if($disk.IsBoot -or $disk.IsSystem){throw '拒絕清除系統磁碟或開機磁碟。'}
                if($diskConfirm.Text.Trim() -ne [string]$n){throw '磁碟編號確認不符。'}
                if($eraseConfirm.Text -cne 'ERASE'){throw '未輸入大寫 ERASE，已取消。'}
                $answer=[Windows.Forms.MessageBox]::Show("即將清除 Disk $n：$($disk.FriendlyName)（$([math]::Round($disk.Size/1GB,1)) GB）。資料無法復原，確定繼續?",'危險操作',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Error)
                if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
                Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                $log.Text="磁碟 $n 已清除，現在需要重新初始化與分割。";Write-OpsLog '清除整顆磁碟' '清除' '成功' "Disk $n"}catch{$log.Text="清除失敗：$($_.Exception.Message)";Write-OpsLog '清除整顆磁碟' '清除' '失敗' $_.Exception.Message}}.GetNewClosure())
    }
    $form.Controls.Add($head); [void]$form.ShowDialog($script:PanelForm); $form.Dispose()
}

# ---- 記錄檔: 事件檢視器 (唯讀) ----
# 這裡只讀不寫。沒有「清除記錄檔」是刻意的:清除無法復原,而且會摧毀事後稽核的
# 能力,不該藏在一個叫「查看」的選單裡。真要清請自己用 wevtutil cl。
#
# 查詢一律走 Get-WinEvent -FilterHashtable,讓過濾在底層完成。先撈全部再用
# Where-Object 過濾,在幾十萬筆的記錄檔上會慢到不能用。

# 情境定義:一個情境 = 一組查詢;一個查詢 = 記錄檔 + (可選) 來源 + (可選) 事件 ID。
# 指定 Provider 是必要的 —— 例如事件 ID 1001 在 System 裡有好幾個來源都在用,
# 只比對 ID 會撈進一堆不相干的東西。
function Get-EventScenarios {
    @(
        @{ Key='1'; Name='非預期關機 / 重開機'; NeedAdmin=$false
           Hint='查「這台為什麼會自己重開」。1074 會寫出是誰、用哪個程式要求的。'
           Queries=@(
               @{ Log='System'; Provider='Microsoft-Windows-Kernel-Power';             Ids=@(41)   }
               @{ Log='System'; Provider='EventLog';                                   Ids=@(6008) }
               @{ Log='System'; Provider='User32';                                     Ids=@(1074) }
               @{ Log='System'; Provider='Microsoft-Windows-WER-SystemErrorReporting'; Ids=@(1001) }
           ) }
        @{ Key='2'; Name='藍畫面與硬體錯誤'; NeedAdmin=$false
           Hint='BugCheck 會帶停止碼與傾印檔位置;WHEA 是 CPU/記憶體/PCIe 回報的硬體錯誤。'
           Queries=@(
               @{ Log='System'; Provider='BugCheck';                        Ids=@(1001) }
               @{ Log='System'; Provider='Microsoft-Windows-WHEA-Logger';   Ids=@(17,18,19,20,47) }
           ) }
        @{ Key='3'; Name='磁碟與儲存'; NeedAdmin=$false
           Hint='disk 7/51 是壞軌等級的徵兆,Ntfs 55 是檔案系統結構損毀,要盡快備份。'
           Queries=@(
               @{ Log='System'; Provider='disk';                     Ids=@(7,11,51,153) }
               @{ Log='System'; Provider='Microsoft-Windows-Ntfs';   Ids=@(55,98,130,137) }
               @{ Log='Application'; Provider='Wininit';             Ids=@(1001) }
           ) }
        @{ Key='4'; Name='服務異常'; NeedAdmin=$false
           Hint='7040 是「啟動類型被改」—— 本工具停用 Windows 更新後被系統改回去,就是在這裡現形的。'
           Queries=@(
               @{ Log='System'; Provider='Service Control Manager'; Ids=@(7000,7001,7011,7022,7023,7024,7031,7034,7040,7045) }
           ) }
        @{ Key='5'; Name='應用程式當機 / 無回應'; NeedAdmin=$false
           Hint='1000 是當掉,1002 是沒回應。詳細內容裡有出錯的模組名稱與位移。'
           Queries=@(
               @{ Log='Application'; Provider='Application Error';        Ids=@(1000) }
               @{ Log='Application'; Provider='Application Hang';         Ids=@(1002) }
               @{ Log='Application'; Provider='.NET Runtime';             Ids=@(1026) }
               @{ Log='Application'; Provider='Windows Error Reporting';  Ids=@(1001) }
           ) }
        @{ Key='6'; Name='登入與帳號'; NeedAdmin=$true
           Hint='4740 是帳號被鎖定。對外的機器如果它一直出現,代表有人在猜密碼、而且已經把你鎖在外面。'
           Queries=@(
               @{ Log='Security'; Ids=@(4624,4625,4740,4648) }
               @{ Log='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Ids=@(1149) }
               @{ Log='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational';     Ids=@(21,23,24,25) }
           ) }
        @{ Key='7'; Name='Windows 更新'; NeedAdmin=$false
           Hint='裝了什麼、失敗了什麼。更新被系統自己改回啟用的痕跡要看第 4 項的 7040。'
           Queries=@(
               @{ Log='System'; Provider='Microsoft-Windows-WindowsUpdateClient'; Ids=@(19,20,43) }
           ) }
    )
}

# 執行一組查詢,回傳 Rows (依時間新到舊) 與 Problems。
# Problems 跟「沒有紀錄」是兩回事,呼叫端必須分開呈現。
function Invoke-EventQuery {
    param([array]$Queries, [int]$Days = 7, [int]$Max = 50)
    $start = (Get-Date).AddDays(-$Days)
    $rows  = New-Object System.Collections.ArrayList
    $probs = New-Object System.Collections.ArrayList
    foreach ($q in $Queries) {
        $f = @{ LogName = $q.Log; StartTime = $start }
        if ($q.Provider) { $f['ProviderName'] = $q.Provider }
        if ($q.Ids)      { $f['Id']           = $q.Ids }
        try {
            $ev = Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction Stop
            foreach ($e in $ev) { [void]$rows.Add($e) }
        } catch {
            # NoMatchingEventsFound = 正常的「這段期間沒有這種事件」,不是問題。
            # NoMatchingProvidersFound = 這台從來沒發生過這類事件，來源還沒被註冊
            # （實測：沒藍屏過的機器沒有 BugCheck、沒跑過 chkdsk 的沒有 Wininit），也是「沒有事件」。
            # 其他的 (沒權限、記錄檔不存在) 一定要讓使用者看到,不能吞掉。
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.FullyQualifiedErrorId -like 'NoMatchingProvidersFound*') { continue }
            $src = $q.Log
            if ($q.Provider) { $src = $src + " / " + $q.Provider }
            [void]$probs.Add(("{0}: {1}" -f $src, $_.Exception.Message))
        }
    }
    @{
        Rows     = @($rows | Sort-Object TimeCreated -Descending | Select-Object -First $Max)
        Problems = @($probs)
    }
}

function Get-EventBrief {
    param($Ev, [int]$Width = 60)
    if ([string]::IsNullOrWhiteSpace($Ev.Message)) { return '(這筆事件沒有描述文字)' }
    $s = (($Ev.Message -split "`r?`n")[0] -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Width) { $s = $s.Substring(0, $Width - 1) + '…' }
    $s
}

# ================= 共用視窗元件 =================
# 每個功能都是同一種版面：標題列、說明、「目前狀態」、輸入欄、動作按鈕、執行結果。
# 以前是把文字選單的 Read-Host / Write-Host 偷換成對話框，靠「猜提示文字」決定要跳
# 輸入框還是選項按鈕，猜錯就出怪畫面（W1 第 1 項）。現在每個功能明確宣告自己要什麼。
$Script:Ui = @{
    Font      = 'Microsoft JhengHei UI'
    Bg        = [Drawing.Color]::FromArgb(241,245,249)
    Header    = [Drawing.Color]::FromArgb(30,58,138)
    HeaderSub = [Drawing.Color]::FromArgb(219,234,254)
    Footer    = [Drawing.Color]::FromArgb(226,232,240)
    Text      = [Drawing.Color]::FromArgb(51,65,85)
    LogBg     = [Drawing.Color]::FromArgb(15,23,42)
    LogFg     = [Drawing.Color]::FromArgb(226,232,240)
    Styles    = @{
        primary = @([Drawing.Color]::FromArgb(37,67,119),  [Drawing.Color]::White)
        success = @([Drawing.Color]::FromArgb(21,94,75),   [Drawing.Color]::White)
        danger  = @([Drawing.Color]::FromArgb(127,29,29),  [Drawing.Color]::White)
        light   = @([Drawing.Color]::FromArgb(219,234,254),[Drawing.Color]::FromArgb(30,64,175))
        close   = @([Drawing.Color]::FromArgb(254,226,226),[Drawing.Color]::FromArgb(153,27,27))
    }
}

function New-UiFont {
    param([single]$Size = 10, [switch]$Bold, [string]$Family = $Script:Ui.Font)
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    New-Object Drawing.Font($Family, $Size, $style)
}

function New-UiButton {
    param([string]$Text, [string]$Style = 'primary', [int]$Width = 170, [int]$Height = 36)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object Drawing.Size($Width, $Height)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Script:Ui.Styles[$Style][0]
    $b.ForeColor = $Script:Ui.Styles[$Style][1]
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 8)
    $b
}

# 標題列 + 內容區 + 底部按鈕列（右下角固定有「關閉視窗」）
function New-UiWindow {
    param([string]$Title, [string]$Subtitle, [int]$Width = 860, [int]$Height = 640)
    $form = New-Object Windows.Forms.Form
    $form.Text = "OPS-command｜$Title"
    $form.Size = New-Object Drawing.Size($Width, $Height)
    $form.MinimumSize = New-Object Drawing.Size([Math]::Min($Width, 720), [Math]::Min($Height, 480))
    $form.StartPosition = 'CenterParent'
    $form.Font = New-UiFont 10
    $form.BackColor = $Script:Ui.Bg

    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'
    $head.Height = if ($Subtitle) { 76 } else { 58 }
    $head.BackColor = $Script:Ui.Header
    $t = New-Object Windows.Forms.Label
    $t.Text = $Title; $t.AutoSize = $true; $t.Location = New-Object Drawing.Point(18, 10)
    $t.Font = New-UiFont 15 -Bold; $t.ForeColor = [Drawing.Color]::White
    $head.Controls.Add($t)
    if ($Subtitle) {
        $s = New-Object Windows.Forms.Label
        $s.Text = $Subtitle; $s.AutoSize = $true; $s.Location = New-Object Drawing.Point(20, 46)
        $s.ForeColor = $Script:Ui.HeaderSub
        $head.Controls.Add($s)
    }

    $foot = New-Object Windows.Forms.FlowLayoutPanel
    $foot.Dock = 'Bottom'; $foot.Height = 54; $foot.FlowDirection = 'RightToLeft'
    $foot.Padding = New-Object Windows.Forms.Padding(14, 9, 4, 0)
    $foot.BackColor = $Script:Ui.Footer
    $close = New-UiButton '關閉視窗' close 110
    $close.Add_Click({ $form.Close() }.GetNewClosure())
    $foot.Controls.Add($close)

    $body = New-Object Windows.Forms.Panel
    $body.Dock = 'Fill'
    $body.Padding = New-Object Windows.Forms.Padding(18, 14, 18, 10)

    $form.Controls.Add($body); $form.Controls.Add($foot); $form.Controls.Add($head)
    $body.BringToFront()
    $form.CancelButton = $close
    @{ Form = $form; Body = $body; Footer = $foot }
}

function Show-UiWindow {
    param([hashtable]$Window)
    $owner = [Windows.Forms.Form]::ActiveForm
    if (-not $owner) { $owner = $script:PanelForm }
    [void]$Window.Form.ShowDialog($owner)
    $Window.Form.Dispose()
}

# 長時間的動作放到另一個 runspace 跑，介面才不會變成「沒有回應」。
# 背景 runspace 看不到這支腳本的函式，所以 $Script 必須是自給自足的程式碼字串。
# 執行中不讓使用者關視窗：Hyper-V、Windows 更新這類動作中途被拔掉，比等它跑完更糟。
function Start-UiBackground {
    param([Windows.Forms.Form]$Form, [string]$Script, [object[]]$Arguments = @(), [scriptblock]$OnDone)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $job = @{ PS = $ps; RS = $rs; Async = $ps.BeginInvoke(); Done = $false; Timer = (New-Object Windows.Forms.Timer) }
    $job.Timer.Interval = 400
    $job.Timer.Add_Tick({
        if (-not $job.Async.IsCompleted) { return }
        $job.Timer.Stop(); $job.Done = $true
        $out = @(); $err = @()
        try { $out = @($job.PS.EndInvoke($job.Async) | ForEach-Object { [string]$_ }) }
        catch { $err += $_.Exception.GetBaseException().Message }
        $err += @($job.PS.Streams.Error | ForEach-Object { [string]$_ })
        $job.PS.Dispose(); $job.RS.Dispose(); $job.Timer.Dispose()
        # 計時器事件裡沒接住的例外會變成 .NET 的「未處理例外」對話框，一定要自己接
        try { & $OnDone $out $err } catch { Show-PanelError -Title '背景作業' -ErrorRecord $_ }
    }.GetNewClosure())
    $Form.Add_FormClosing({
        param($s, $e)
        if (-not $job.Done) {
            $e.Cancel = $true
            [Windows.Forms.MessageBox]::Show($s, '作業還在進行，請等它完成再關閉視窗。', '請稍候', 'OK', 'Information') | Out-Null
        }
    }.GetNewClosure())
    $job.Timer.Start()
}

# 一個功能視窗。參數：
#   -Status   回傳狀態文字的 scriptblock，開窗與每次動作後自動重讀
#   -Inputs   @{ Name; Label; Type = Text | Number | Combo; Default; Min; Max; Items; Width }
#   -Actions  @{ Text; Style; Admin; Confirm; Run; Worker; WorkerArgs; AskWorker }
#               Confirm    字串或 { param($v) ... } 回傳確認訊息；回傳空字串表示不用問
#               Run        { param($v) ... } 在介面執行緒跑，回傳的文字印在結果區；throw 會顯示成 [錯誤]
#               Worker     背景執行的程式碼字串（Run 成功後才跑）；WorkerArgs { param($v) ... } 回傳參數陣列
#               AskWorker  跑 Worker 前再問一次（例如「現在重啟服務嗎？」），選否就略過
#             $v 是輸入欄的值（以 Name 為鍵）。Run / Confirm 用到外面的變數時記得 .GetNewClosure()。
#   -OnOpen   開窗後自動執行的動作（報告類功能用）
function Show-FeaturePanel {
    param(
        [string]$Title, [string]$Subtitle, [string]$Note,
        [scriptblock]$Status, [array]$Inputs = @(), [array]$Actions = @(),
        [hashtable]$OnOpen, [switch]$Mono,
        [int]$Width = 860, [int]$Height = 640
    )
    $win  = New-UiWindow -Title $Title -Subtitle $Subtitle -Width $Width -Height $Height
    $form = $win.Form
    $inner = $Width - 60

    $top = New-Object Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.AutoSize = $true; $top.AutoSizeMode = 'GrowAndShrink'
    $top.FlowDirection = 'TopDown'; $top.WrapContents = $false

    if ($Note) {
        $n = New-Object Windows.Forms.Label
        $n.Text = $Note; $n.AutoSize = $true; $n.MaximumSize = New-Object Drawing.Size($inner, 0)
        $n.ForeColor = $Script:Ui.Text; $n.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10)
        $top.Controls.Add($n)
    }

    $statusLabel = $null
    if ($Status) {
        $box = New-Object Windows.Forms.GroupBox
        $box.Text = '目前狀態'; $box.AutoSize = $true; $box.AutoSizeMode = 'GrowAndShrink'
        $box.MinimumSize = New-Object Drawing.Size($inner, 0)
        $box.Padding = New-Object Windows.Forms.Padding(10, 4, 10, 6)
        $statusLabel = New-Object Windows.Forms.Label
        $statusLabel.AutoSize = $true; $statusLabel.MaximumSize = New-Object Drawing.Size(($inner - 30), 0)
        $statusLabel.Location = New-Object Drawing.Point(12, 24); $statusLabel.Text = '讀取中…'
        $box.Controls.Add($statusLabel)
        $top.Controls.Add($box)
    }

    $fields = @{}
    if ($Inputs.Count) {
        $grid = New-Object Windows.Forms.TableLayoutPanel
        $grid.ColumnCount = 2; $grid.AutoSize = $true; $grid.AutoSizeMode = 'GrowAndShrink'
        $grid.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
        foreach ($in in $Inputs) {
            $l = New-Object Windows.Forms.Label
            $l.Text = $in.Label; $l.AutoSize = $true; $l.Anchor = 'Left'
            $l.Margin = New-Object Windows.Forms.Padding(0, 6, 12, 6)
            $w = if ($in.Width) { $in.Width } else { 320 }
            switch ($in.Type) {
                'Number' {
                    $c = New-Object Windows.Forms.NumericUpDown
                    $c.Minimum = $in.Min; $c.Maximum = $in.Max; $c.Value = $in.Default; $c.Width = 130
                }
                'Combo' {
                    $c = New-Object Windows.Forms.ComboBox
                    $c.DropDownStyle = 'DropDownList'; $c.Width = $w
                    foreach ($i in @($in.Items)) { [void]$c.Items.Add([string]$i) }
                    if ($in.Default -and $c.Items.Contains([string]$in.Default)) { $c.SelectedItem = [string]$in.Default }
                    elseif ($c.Items.Count) { $c.SelectedIndex = 0 }
                }
                default {
                    $c = New-Object Windows.Forms.TextBox
                    $c.Text = [string]$in.Default; $c.Width = $w
                }
            }
            $c.Anchor = 'Left'
            $grid.Controls.Add($l); $grid.Controls.Add($c)
            $fields[$in.Name] = @{ Type = $in.Type; Control = $c }
        }
        $top.Controls.Add($grid)
    }

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.AutoSize = $true; $bar.AutoSizeMode = 'GrowAndShrink'; $bar.WrapContents = $true
    $bar.MaximumSize = New-Object Drawing.Size($inner, 0)
    $bar.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 4)
    if ($Actions.Count) { $top.Controls.Add($bar) }

    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $true
    $log.Dock = 'Fill'; $log.BorderStyle = 'FixedSingle'
    $log.BackColor = $Script:Ui.LogBg; $log.ForeColor = $Script:Ui.LogFg
    $log.Font = if ($Mono) { New-UiFont 10 -Family 'Consolas' } else { New-UiFont 10 }

    $win.Body.Controls.Add($top); $win.Body.Controls.Add($log)
    $log.BringToFront()

    $ctx = @{ Title = $Title; Form = $form; Log = $log; StatusLabel = $statusLabel; Status = $Status; Fields = $fields; Buttons = @(); Busy = $false }

    $append = {
        param([object[]]$Lines)
        foreach ($l in $Lines) { if (-not $ctx.Log.IsDisposed) { $ctx.Log.AppendText("$l`r`n") } }
    }.GetNewClosure()

    $refresh = {
        if (-not $ctx.StatusLabel) { return }
        try { $ctx.StatusLabel.Text = ((& $ctx.Status 2>&1 | ForEach-Object { [string]$_ }) -join "`r`n") }
        catch { $ctx.StatusLabel.Text = "讀取狀態失敗：$($_.Exception.Message)" }
    }.GetNewClosure()

    $getValues = {
        $v = @{}
        foreach ($k in $ctx.Fields.Keys) {
            $f = $ctx.Fields[$k]
            $v[$k] = switch ($f.Type) {
                'Number' { [int]$f.Control.Value }
                'Combo'  { [string]$f.Control.SelectedItem }
                default  { $f.Control.Text.Trim() }
            }
        }
        $v
    }.GetNewClosure()

    $runAction = {
        param([hashtable]$act)
        if ($ctx.Busy) { return }
        if ($act.Admin -and -not (Request-PanelAdmin)) { return }
        $v = & $getValues
        try {
            if ($act.Confirm) {
                $msg = if ($act.Confirm -is [scriptblock]) { & $act.Confirm $v } else { [string]$act.Confirm }
                if ($msg -and [Windows.Forms.MessageBox]::Show($ctx.Form, $msg, $act.Text, 'YesNo', 'Warning') -ne 'Yes') {
                    & $append "（已取消：$($act.Text)）"
                    return
                }
            }
            & $append '', "▶ $($act.Text)"
            if ($act.Run) {
                $runOut = @(& $act.Run $v 2>&1 | ForEach-Object { [string]$_ })
                & $append $runOut
                # Admin = 會改到系統的動作，才需要留紀錄；唯讀的查詢不記
                if ($act.Admin) { Write-OpsLog $ctx.Title $act.Text '成功' ("$(Format-OpsInputs $v)；" + ($runOut | Select-Object -First 1)) }
            }
        } catch {
            & $append "[錯誤] $($_.Exception.Message)"
            if ($act.Admin) { Write-OpsLog $ctx.Title $act.Text '失敗' "$(Format-OpsInputs $v)；$($_.Exception.Message)" }
            & $refresh
            return
        }
        if (-not $act.Worker) { & $refresh; return }
        if ($act.AskWorker -and [Windows.Forms.MessageBox]::Show($ctx.Form, $act.AskWorker, $act.Text, 'YesNo', 'Question') -ne 'Yes') {
            & $append '（略過）'
            & $refresh
            return
        }
        $workerArgs = if ($act.WorkerArgs) { @(& $act.WorkerArgs $v) } else { @() }
        $ctx.Busy = $true
        foreach ($b in $ctx.Buttons) { $b.Enabled = $false }
        & $append '執行中，請稍候（視窗可以拖動，不會卡住）…'
        # GetNewClosure() 只帶走「當下這一層」的變數。$append / $refresh / $ctx 在外面一層
        # （$runAction 自己的閉包裡），不先複製下來，回呼由計時器呼叫時就找不到它們
        # （測試機實測：跳 .NET 未處理例外框，視窗卡在「執行中」關不掉）。
        $append = $append; $refresh = $refresh; $ctx = $ctx
        $onDone = {
            param($out, $err)
            & $append $out
            if ($act.Admin) {
                $r = if (@($err).Count) { '失敗' } else { '成功' }
                $d = if (@($err).Count) { @($err)[0] } else { @($out) | Select-Object -Last 1 }
                Write-OpsLog $ctx.Title "$($act.Text)（背景）" $r "$(Format-OpsInputs $v)；$d"
            }
            foreach ($e in $err) { & $append "[錯誤] $e" }
            $ctx.Busy = $false
            foreach ($b in $ctx.Buttons) { if (-not $b.IsDisposed) { $b.Enabled = $true } }
            & $refresh
        }.GetNewClosure()
        Start-UiBackground -Form $ctx.Form -Script $act.Worker -Arguments $workerArgs -OnDone $onDone
    }.GetNewClosure()

    foreach ($act in $Actions) {
        $style = if ($act.Style) { $act.Style } else { 'primary' }
        $b = New-UiButton $act.Text $style $(if ($act.Width) { $act.Width } else { 170 })
        $a = $act
        $b.Add_Click({ & $runAction $a }.GetNewClosure())
        $bar.Controls.Add($b)
        $ctx.Buttons += $b
    }

    if ($Status) {
        $rb = New-UiButton '重新整理' light 110
        $rb.Add_Click({ & $refresh }.GetNewClosure())
        $win.Footer.Controls.Add($rb)
    }

    $form.Add_Shown({
        & $refresh
        if ($OnOpen) { & $runAction $OnOpen }
    }.GetNewClosure())

    Show-UiWindow $win
}

# ================= 背景執行的工作 =================
# 這些字串在另一個 runspace 跑，看不到上面的函式，需要的東西都要自己帶。

$Script:WorkerTermService = @'
Restart-Service TermService -Force -ErrorAction Stop
"遠端桌面服務已重新啟動。"
'@

$Script:WorkerWindowsUpdate = @'
param([string]$Mode)
$ErrorActionPreference='Stop'
if($Mode -eq 'Stop'){
    $warnings=@()
    foreach($serviceName in @('wuauserv','UsoSvc')){
        try { Stop-Service $serviceName -Force -ErrorAction Stop } catch { if($_.Exception.Message -notmatch 'cannot be stopped|無法停止|尚未啟動|not started'){ $warnings += "停止 $serviceName 服務：$($_.Exception.Message)" } }
        try { Set-Service $serviceName -StartupType Disabled -ErrorAction Stop } catch { $warnings += "設定 $serviceName 為停用：$($_.Exception.Message)" }
    }
    try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' -Name Start -Value 4 -ErrorAction Stop } catch { $warnings += "設定 WaaSMedicSvc：$($_.Exception.Message)" }
    $au='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if(-not (Test-Path $au)){New-Item -Path $au -Force | Out-Null}
    Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -ErrorAction Stop
    Set-ItemProperty -Path $au -Name AUOptions -Value 1 -ErrorAction Stop
    # 不能設完立刻讀一次就說成功。實測 Windows 10 22H2：設成 Disabled 之後兩秒內，
    # 更新自我修復（Update Orchestrator / WaaSMedic）就會改回 Manual 並重新啟動服務，
    # 而立刻讀的那一眼還是 Disabled。上面 WaaSMedicSvc Start=4 要重開機才生效，
    # 所以等 6 秒再讀；被改回去時要講明，重開機後再執行一次才留得住。
    # 事件檢視器的系統記錄檔會看到 SCM 7040「啟動類型已變更」一來一回兩筆。
    Start-Sleep -Seconds 6
    $wu=Get-Service wuauserv
    if($wu.StartType -eq 'Disabled' -and $wu.Status -ne 'Running'){ 'Windows Update 已停止。' } else { $warnings += "Windows Update 被系統改回來了：$($wu.StartType) / $($wu.Status)。這是 Windows 的更新自我修復（WaaSMedic）；WaaSMedic 已設為停用，但要重新開機後才生效——重開機後再執行一次「停止 Windows 更新」才留得住。若仍不行，請檢查群組原則。" }
    if($warnings.Count){"`r`n需要留意："; $warnings | ForEach-Object { "- $_" }}
}else{
    Set-Service wuauserv -StartupType Manual -ErrorAction Stop
    Start-Service wuauserv -ErrorAction Stop
    Set-Service UsoSvc -StartupType Manual -ErrorAction Stop
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' -Name Start -Value 3 -ErrorAction Stop
    $au='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Remove-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $au -Name AUOptions -ErrorAction SilentlyContinue
    $wu=Get-Service wuauserv
    "Windows Update 已恢復；wuauserv=$($wu.Status)，啟動類型=$($wu.StartType)。"
}
'@

$Script:WorkerHyperV = @'
param([string]$Mode)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Enable') {
    $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    & bcdedit /set hypervisorlaunchtype auto | Out-Null
    "已啟用 Hyper-V 元件，hypervisorlaunchtype = auto。"
} else {
    $r = Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
    & bcdedit /set hypervisorlaunchtype off | Out-Null
    "已移除 Hyper-V 元件，hypervisorlaunchtype = off。"
}
if ($r.RestartNeeded) { "需要重新開機才會生效。" }
'@

$Script:WorkerTime = @'
param([string]$Mode, [string]$Ntp)
$ErrorActionPreference = 'Stop'
$svc = Get-Service w32time
if ($Mode -eq 'Ntp') {
    Set-Service w32time -StartupType Automatic
    if ($svc.Status -ne 'Running') { Start-Service w32time }
    $out = & w32tm /config "/manualpeerlist:$Ntp,0x8" /syncfromflags:manual /update 2>&1
    if ($LASTEXITCODE -ne 0) { throw "w32tm /config 失敗：$($out -join ' ')" }
    Restart-Service w32time
    Start-Sleep -Seconds 2
    "NTP 伺服器已設為 $Ntp（用戶端模式），Windows Time 設為自動啟動。"
} else {
    if ($svc.StartType -eq 'Disabled') { Set-Service w32time -StartupType Manual }
    if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time }
}
$out = & w32tm /resync /force 2>&1
$out | ForEach-Object { [string]$_ }
if ($LASTEXITCODE -ne 0) { "同步沒有成功（exit $LASTEXITCODE）。常見原因：連不到 NTP 伺服器（UDP 123 被擋）。" }
& w32tm /query /source 2>&1 | ForEach-Object { "目前時間來源：$_" }
if ((& w32tm /query /configuration 2>&1) -match 'Policy') { "[注意] 偵測到原則管理的時間設定，網域群組原則可能會覆寫這裡的 NTP 設定。" }
'@

# ================= 遠端桌面 RDP =================

function Invoke-RdpPortChange {
    param([int]$NewPort, [int]$Minutes)
    $cur = Get-RdpPort
    if (-not $cur) { throw '讀不到目前的 RDP Port 設定。' }
    if (Test-RdpWatchdog) { throw '有一次尚未確認的換 Port 作業進行中。請先「確認新 Port 可用」或「立即還原」。' }
    if ($NewPort -eq [int]$cur) { throw "新 Port 與目前相同（$cur）。" }
    # 新 port 被別的程式佔用的話，TermService 會 bind 失敗，RDP 直接起不來
    $busy = Get-NetTCPConnection -State Listen -LocalPort $NewPort -ErrorAction SilentlyContinue
    if ($busy) { throw ("Port $NewPort 已經有程式在監聽（PID {0}），換過去 RDP 會起不來。" -f (($busy.OwningProcess | Sort-Object -Unique) -join ',')) }

    Add-RdpFirewallRule -Port $NewPort
    if (-not (Register-RdpWatchdog -OldPort ([int]$cur) -Minutes $Minutes)) {
        Remove-RdpFirewallRule -Port $NewPort
        throw "看門狗建不起來（$Script:WatchdogError），這次不做變更——沒有自動還原就換 Port 太危險。"
    }
    # 狀態要在改 port「之前」寫好：「立即還原」靠它知道舊 port 是多少。
    try { Save-RdpState -OldPort ([int]$cur) -NewPort $NewPort -Minutes $Minutes }
    catch {
        Unregister-RdpWatchdog; Remove-RdpFirewallRule -Port $NewPort
        throw "狀態寫不進登錄檔（$($_.Exception.Message)），這次不做變更。"
    }
    Set-ItemProperty -Path $Script:RdpKey -Name PortNumber -Value $NewPort
    $now = Get-RdpPort
    if ([int]$now -ne $NewPort) {
        Unregister-RdpWatchdog; Clear-RdpState; Remove-RdpFirewallRule -Port $NewPort
        throw "寫入後讀回來還是 $now，設定沒有生效（可能被群組原則鎖住）。已撤回看門狗與防火牆規則，系統維持原狀。"
    }
    "[完成] 登錄檔已改為 $NewPort；看門狗 $Minutes 分鐘後會自動還原成 $cur。"
    "接下來："
    "  1. 重啟遠端桌面服務讓新 Port 生效（這條 RDP 連線會斷）"
    "  2. 用『另一台電腦』連 IP:$NewPort 確認能登入"
    "  3. 連得上就回到這裡按「確認新 Port 可用」"
    "  * 連不上就什麼都別做，$Minutes 分鐘後自動還原"
    "[提醒] 雲端主機還要在安全群組／網路 ACL 放行 $NewPort，本機防火牆放行不代表外面連得進來。"
}

function Invoke-RdpPortConfirm {
    if (-not (Test-RdpWatchdog)) { throw '目前沒有進行中的換 Port 作業（看門狗不存在）。' }
    $cur = Get-RdpPort
    $old = Get-RdpOldPort
    Unregister-RdpWatchdog
    "[完成] 看門狗已取消，RDP Port 固定為 $cur。"
    if ($old -and [int]$old -ne [int]$cur) {
        $ans = [Windows.Forms.MessageBox]::Show("要移除舊 Port $old 的防火牆規則（OPS-RDP-$old-TCP / UDP）嗎？`r`n只會移除本工具建立的規則。", '收掉舊 Port', 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Remove-RdpFirewallRule -Port ([int]$old); "已移除舊 Port $old 的規則。" }
        else { "保留舊 Port $old 的規則。" }
    }
    Clear-RdpState
}

function Invoke-RdpPortRestore {
    $old = Get-RdpOldPort
    if (-not $old) { throw "找不到進行中的變更紀錄（$Script:RdpStateKey），沒有可還原的變更。" }
    Set-ItemProperty -Path $Script:RdpKey -Name PortNumber -Value ([int]$old)
    Add-RdpFirewallRule -Port ([int]$old)
    Unregister-RdpWatchdog
    $now = Get-RdpPort
    if ([int]$now -ne [int]$old) { throw "寫入後讀回來是 $now，還原沒有生效。看門狗已取消，請手動檢查登錄檔 $Script:RdpKey" }
    Clear-RdpState
    "[完成] 登錄檔已改回 $old。"
}

function Show-RdpPortPanel {
    $cur = Get-RdpPort
    Show-FeaturePanel -Title '更換 RDP Port' -Subtitle '新舊 Port 並存 + 看門狗自動還原，不會把自己關在門外' `
        -Note '流程：更換 Port → 重啟遠端桌面服務（這條連線會斷）→ 用另一台電腦連新 Port → 回來按「確認新 Port 可用」。時限內沒有確認，看門狗會自動改回舊 Port 並重啟服務。' `
        -Status {
            $p = Get-RdpPort
            $listening = [bool](Get-NetTCPConnection -State Listen -LocalPort ([int]$p) -ErrorAction SilentlyContinue)
            "設定的 RDP Port：$p　　目前" + $(if ($listening) { '有在監聽' } else { '沒有在監聽（可能還沒重啟遠端桌面服務）' })
            if (Test-RdpWatchdog) {
                $at = $null
                try { $at = [datetime](Get-ScheduledTask -TaskName $Script:RdpTask).Triggers[0].StartBoundary } catch { }
                "進行中：從 $(Get-RdpOldPort) 換到 $p，尚未確認。" + $(if ($at) { "看門狗會在 $($at.ToString('HH:mm:ss')) 自動還原。" } else { '' })
            } else { '沒有進行中的變更。' }
            "遠端桌面服務：$((Get-Service TermService).Status)"
        } `
        -Inputs @(
            @{ Name = 'Port'; Label = '新的 Port'; Type = 'Number'; Min = 1; Max = 65535; Default = $(if ($cur) { [int]$cur } else { 3389 }) }
            @{ Name = 'Minutes'; Label = '看門狗時限（分鐘）'; Type = 'Number'; Min = 1; Max = 120; Default = 10 }
        ) `
        -Actions @(
            @{ Text = '更換 Port'; Style = 'danger'; Admin = $true
               Confirm = { param($v) "將把 RDP Port 改成 $($v.Port)，看門狗 $($v.Minutes) 分鐘。`r`n`r`n1. 防火牆放行 $($v.Port)（舊 Port 規則保留）`r`n2. 登錄檔 PortNumber 改為 $($v.Port)`r`n3. 建立看門狗排程`r`n`r`n雲端主機請先在安全群組放行 $($v.Port)。確定執行？" }
               Run = { param($v) Invoke-RdpPortChange -NewPort $v.Port -Minutes $v.Minutes }
               Worker = $Script:WorkerTermService
               AskWorker = "現在重啟遠端桌面服務讓新 Port 生效嗎？`r`n這條 RDP 連線會斷，請用新 Port 重新連線。`r`n`r`n選「否」的話，新 Port 要等你之後重啟服務或重開機才生效；看門狗照樣會在時限到時還原。" }
            @{ Text = '確認新 Port 可用'; Style = 'success'; Admin = $true
               Confirm = '請確認你是「用新 Port 連進來的」，或已另外開一條新連線登入成功。舊視窗還活著不算數——那條連線是在服務重啟前就建立的。已經確認了嗎？'
               Run = { Invoke-RdpPortConfirm } }
            @{ Text = '立即還原'; Style = 'danger'; Admin = $true
               Confirm = '將把 RDP Port 改回變更前的設定，並重啟遠端桌面服務（這條連線可能會斷）。確定還原？'
               Run = { Invoke-RdpPortRestore }
               Worker = $Script:WorkerTermService }
            @{ Text = '重啟遠端桌面服務'; Style = 'primary'; Admin = $true
               Confirm = '重啟遠端桌面服務（TermService），目前所有 RDP 連線都會斷，工作階段會保留。確定？'
               Worker = $Script:WorkerTermService }
        )
}

function Show-RdpMultiPanel {
    $tsCtrl = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tsPol  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    Show-FeaturePanel -Title 'RDP 多工作階段' -Subtitle '允許同一個帳號同時開多個遠端桌面工作階段' `
        -Note '用戶端版 Windows（家用版／專業版）原生仍限制「同時 1 個連線」，這個限制在系統檔 termsrv.dll，登錄檔改不了。要真正讓多人同時連線需要 RDP Wrapper 這類工具，本工具不會修改該系統檔，且可能涉及 Microsoft 授權條款，請自行確認。Windows Server 不受此限制。' `
        -Status {
            $single = (Get-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -ErrorAction SilentlyContinue).fSingleSessionPerUser
            $maxc = (Get-ItemProperty -Path $tsPol -Name MaxInstanceCount -ErrorAction SilentlyContinue).MaxInstanceCount
            "fSingleSessionPerUser = $single　（0 = 允許同帳號多工作階段）"
            "MaxInstanceCount = $(if ($null -ne $maxc) { $maxc } else { '未設定' })"
        }.GetNewClosure() `
        -Actions @(
            @{ Text = '開啟多工作階段'; Style = 'primary'; Admin = $true
               Run = {
                   Set-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -Type DWord -Value 0
                   if (-not (Test-Path $tsPol)) { New-Item -Path $tsPol -Force | Out-Null }
                   Set-ItemProperty -Path $tsPol -Name fSingleSessionPerUser -Type DWord -Value 0
                   Set-ItemProperty -Path $tsPol -Name MaxInstanceCount -Type DWord -Value 999999
                   '[完成] 已開啟。'
               }.GetNewClosure() }
            @{ Text = '關閉（單一工作階段）'; Style = 'light'; Admin = $true
               Run = {
                   Set-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -Type DWord -Value 1
                   if (Test-Path $tsPol) {
                       Set-ItemProperty -Path $tsPol -Name fSingleSessionPerUser -Type DWord -Value 1
                       Remove-ItemProperty -Path $tsPol -Name MaxInstanceCount -ErrorAction SilentlyContinue
                   }
                   '[完成] 已還原為單一工作階段。'
               }.GetNewClosure() }
        )
}

function Show-CredSspPanel {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters'
    Show-FeaturePanel -Title 'CredSSP 加密預示修復' -Subtitle 'Encryption Oracle Remediation（CVE-2018-0886）' `
        -Note '連線到「尚未修補 CVE-2018-0886」的主機時，會出現「CredSSP 加密 Oracle 修復」錯誤。設為「易受攻擊」可以連得上，但本機也會重新暴露於該弱點；長期作法是兩端都更新。改完要重新開機才完全生效。' `
        -Status {
            $cur = (Get-ItemProperty -Path $key -Name AllowEncryptionOracle -ErrorAction SilentlyContinue).AllowEncryptionOracle
            'AllowEncryptionOracle = ' + $(switch ($cur) { 0 { '0　強制更新的用戶端' } 1 { '1　已降低影響' } 2 { '2　易受攻擊（已關閉修復）' } default { '尚未設定（系統預設）' } })
        }.GetNewClosure() `
        -Actions @(
            @{ Text = '設為「易受攻擊」'; Style = 'danger'; Admin = $true
               Confirm = '設為「易受攻擊」可連到尚未修補的主機，但本機會重新暴露於 CredSSP 弱點。仍要繼續？'
               Run = {
                   if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                   Set-ItemProperty -Path $key -Name AllowEncryptionOracle -Type DWord -Value 2
                   '[完成] AllowEncryptionOracle = 2，等同 gpedit「加密預示修復 = 已啟用，保護層級 = 易受攻擊」。請重新開機。'
               }.GetNewClosure() }
            @{ Text = '還原為「尚未設定」'; Style = 'success'; Admin = $true
               Run = {
                   Remove-ItemProperty -Path $key -Name AllowEncryptionOracle -ErrorAction SilentlyContinue
                   '[完成] 已移除此原則，恢復系統預設。請重新開機。'
               }.GetNewClosure() }
        )
}

# 底層查詢跟「事件檢視器」共用 Invoke-EventQuery。
# 「查不到紀錄」和「沒權限讀 Security」要分開講：讀不到不等於沒有人嘗試登入。
function Get-RdpLoginReport {
    '--- 最近的 RDP 連線（通過驗證，事件 1149）---'
    $r1 = Invoke-EventQuery -Queries @(@{ Log = 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Ids = @(1149) }) -Days 365 -Max 25
    if ($r1.Problems.Count) { $r1.Problems | ForEach-Object { "[讀不到] $_" } }
    elseif (-not $r1.Rows.Count) { '（最近一年沒有這類紀錄）' }
    else { foreach ($e in $r1.Rows) { '{0}  帳號：{1}\{2}  來源：{3}' -f $e.TimeCreated, $e.Properties[1].Value, $e.Properties[0].Value, $e.Properties[2].Value } }
    ''
    '--- 最近的登入失敗（Security 4625，可能是被嘗試暴力破解）---'
    $r2 = Invoke-EventQuery -Queries @(@{ Log = 'Security'; Ids = @(4625) }) -Days 365 -Max 25
    if ($r2.Problems.Count) {
        $r2.Problems | ForEach-Object { "[讀不到] $_" }
        '讀不到「不等於」沒有人嘗試登入，別把這個當成安全的證據。Security 記錄檔需要管理員權限。'
    }
    elseif (-not $r2.Rows.Count) { '（最近一年沒有登入失敗紀錄）' }
    else {
        foreach ($e in $r2.Rows) {
            $x = [xml]$e.ToXml()
            $u  = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
            $ip = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
            '{0}  帳號：{1}  來源 IP：{2}' -f $e.TimeCreated, $u, $ip
        }
    }
}

function Show-RdpLoginsPanel {
    $report = @{ Text = '重新查詢'; Style = 'primary'; Run = { Get-RdpLoginReport } }
    Show-FeaturePanel -Title 'RDP 登入紀錄' -Subtitle '最近一年的遠端連線與登入失敗（唯讀）' -Mono `
        -Note $(if ($IsAdmin) { '要看更完整的登入事件，請用「事件檢視器」的「登入與帳號」。' } else { '目前不是管理員：登入失敗紀錄在 Security 記錄檔，一般權限讀不到，會標示「讀不到」。' }) `
        -Actions @($report) -OnOpen $report
}

# ================= 帳號與安全 =================

# ---- RDP 暴力破解自動封鎖（Windows 版 fail2ban，E2）----
# 帳號鎖定擋不住來源：攻擊者一直猜，被鎖的是合法使用者（見 README「已知限制」）。
# 這裡改成依「來源 IP」封鎖：Security 4625（登入失敗）的 IpAddress，同一個 IP 在
# 時間窗內失敗次數達到門檻，就建一條本工具自己的防火牆封鎖規則，到期自動解封。
#
# 安全設計（同 W2 看門狗）：
#   - 以 SYSTEM 執行的排程（OPS-RdpGuard，每 1 分鐘），程式碼用 -EncodedCommand 放進排程本身，
#     不落地成檔案；一般使用者改不到。
#   - 設定與封鎖清單存 HKLM:\SOFTWARE\OPS-command\RdpGuard（只有 Administrators / SYSTEM 可寫）：
#       Threshold / WindowMin / BanMin / Scope(Rdp|All) / Whitelist(MultiString)
#       Bans\<IP>    = "到期時間|失敗次數"
#       Forgive\<IP> = 解封時間；這之前的失敗不再計數（否則剛解封就被時間窗裡的舊紀錄再封一次）
#       LastRun / LastResult / RuleSig / TotalBans
#   - SYSTEM 不寫任何檔案，紀錄寫 Windows 事件記錄（應用程式，來源 OPS-command）：
#       300 = 封鎖、301 = 解封（到期／白名單／手動）、302 = 守護執行失敗
#     （100 是 RDP 看門狗，200/201 是操作記錄）
#   - 白名單一定生效：127.0.0.0/8、::1、本機自己的位址固定加入；啟用時把目前連進來的來源
#     （Established 且本機端是監聽中的 Port）自動加入。已封鎖的 IP 後來進了白名單，下一輪就解封。
#   - 防火牆規則名稱固定 OPS-RdpGuard-<IP>-TCP / -UDP / -ALL，群組 OPS-RdpGuard；只刪自己建的。
#   - 預設只擋 RDP Port（TCP+UDP，登錄檔實際值；換 Port 看門狗進行中時新舊兩個都擋），
#     SSH 等其他管道留著當救援；可改成「全部連入」。4625 不分服務（RDP、SMB、SSH 都會產生），
#     攻擊者若同時打別的服務，選「全部連入」才擋得完。
#
# 下面 $Script:RdpGuardCoreFunctions 列的函式會原封不動放進排程，所以它們只能用字面值、
# 不能用 $Script: 變數或這支腳本的其他函式。Get-RdpGuardPlan 是純函式（不讀系統），
# 測試時可以餵假事件驗證門檻、時間窗與到期。
$Script:RdpGuardKey  = 'HKLM:\SOFTWARE\OPS-command\RdpGuard'
$Script:RdpGuardTask = 'OPS-RdpGuard'
$Script:RdpGuardAuditGuid = '{0CCE9215-69AE-11D9-BED3-505054503030}'   # 稽核「登入」子類別（zh-TW 名稱是中文，用 GUID 查）
$Script:RdpGuardCoreFunctions = @('Test-RdpGuardIpIn', 'Get-RdpGuardPlan', 'Get-RdpGuardFailures', 'Write-RdpGuardEvent',
    'Set-RdpGuardRule', 'Remove-RdpGuardRule', 'Get-RdpGuardList', 'Remove-RdpGuardBan', 'Invoke-RdpGuard')

# IP 是否在清單裡；清單可以是單一 IP 或 CIDR（IPv4 / IPv6 都可）
function Test-RdpGuardIpIn {
    param([string]$Ip, [string[]]$List)
    $a = $null
    if (-not [Net.IPAddress]::TryParse(($Ip -replace '^::ffff:', ''), [ref]$a)) { return $false }
    foreach ($w in @($List)) {
        $w = "$w".Trim()
        if (-not $w) { continue }
        $p = $w -split '/'
        $n = $null
        if (-not [Net.IPAddress]::TryParse($p[0], [ref]$n) -or $n.AddressFamily -ne $a.AddressFamily) { continue }
        if ($p.Count -eq 1) { if ($n.Equals($a)) { return $true }; continue }
        $bits = 0
        if (-not [int]::TryParse($p[1], [ref]$bits)) { continue }
        $x = $a.GetAddressBytes(); $y = $n.GetAddressBytes(); $ok = $true
        for ($i = 0; $i -lt $x.Length -and $bits -gt 0; $i++) {
            $m = if ($bits -ge 8) { 255 } else { (0xFF -shl (8 - $bits)) -band 0xFF }
            if (($x[$i] -band $m) -ne ($y[$i] -band $m)) { $ok = $false; break }
            $bits -= 8
        }
        if ($ok) { return $true }
    }
    $false
}

# 純判斷：給事件（Time, Ip）、現在時間、設定、目前封鎖與寬恕清單，回傳要封、要解封的 IP。
# 門檻是「達到」就封（同 fail2ban 的 maxretry）。
function Get-RdpGuardPlan {
    param([object[]]$Events, [datetime]$Now, [int]$Threshold, [int]$WindowMin, [int]$BanMin,
          [string[]]$Whitelist, [hashtable]$Bans = @{}, [hashtable]$Forgive = @{})
    $since = $Now.AddMinutes(-$WindowMin)
    $count = @{}
    foreach ($e in @($Events)) {
        if (-not $e) { continue }
        $ip = ([string]$e.Ip).Trim() -replace '^::ffff:', ''
        if (-not $ip -or $ip -eq '-') { continue }
        $t = [datetime]$e.Time
        if ($t -lt $since -or $t -gt $Now) { continue }
        if ($Forgive.ContainsKey($ip) -and $t -le $Forgive[$ip]) { continue }
        if (Test-RdpGuardIpIn $ip $Whitelist) { continue }
        $count[$ip] = 1 + [int]$count[$ip]
    }
    $ban = @(foreach ($ip in $count.Keys) {
        if ($count[$ip] -ge $Threshold -and -not $Bans.ContainsKey($ip)) {
            [pscustomobject]@{ Ip = $ip; Count = $count[$ip]; Until = $Now.AddMinutes($BanMin) }
        }
    }) | Sort-Object Count -Descending
    $unban = @(foreach ($ip in @($Bans.Keys)) {
        if (Test-RdpGuardIpIn $ip $Whitelist) { [pscustomobject]@{ Ip = $ip; Reason = '在白名單內' } }
        elseif ($Bans[$ip] -le $Now) { [pscustomobject]@{ Ip = $ip; Reason = '封鎖到期' } }
    })
    @{ Ban = @($ban); Unban = $unban; Counts = $count }
}

# Security 4625 的 IpAddress 是第 20 個欄位（Properties[19]）。沒有事件不是錯誤。
function Get-RdpGuardFailures {
    param([datetime]$Since)
    try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $Since } -MaxEvents 20000 -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingProvidersFound') { return @() }
        throw "讀不到 Security 記錄檔（需要管理員權限）：$($_.Exception.Message)"
    }
    foreach ($e in $ev) { [pscustomobject]@{ Time = $e.TimeCreated; Ip = [string]$e.Properties[19].Value } }
}

function Write-RdpGuardEvent {
    param([int]$Id, [string]$Message, [string]$Type = 'Information')
    try {
        if (-not [Diagnostics.EventLog]::SourceExists('OPS-command')) { [Diagnostics.EventLog]::CreateEventSource('OPS-command', 'Application') }
        [Diagnostics.EventLog]::WriteEntry('OPS-command', $Message, $Type, $Id)
    } catch { }
}

function Remove-RdpGuardRule {
    param([string]$Ip)
    Get-NetFirewallRule -Name "OPS-RdpGuard-$Ip-TCP", "OPS-RdpGuard-$Ip-UDP", "OPS-RdpGuard-$Ip-ALL" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

function Set-RdpGuardRule {
    param([string]$Ip, [string]$Scope, [int[]]$Ports)
    Remove-RdpGuardRule $Ip
    $common = @{ Group = 'OPS-RdpGuard'; Direction = 'Inbound'; Action = 'Block'; RemoteAddress = $Ip; Description = 'OPS-command RDP brute-force guard'; ErrorAction = 'Stop' }
    if ($Scope -eq 'All') { New-NetFirewallRule -Name "OPS-RdpGuard-$Ip-ALL" -DisplayName "OPS-RdpGuard-$Ip-ALL" @common | Out-Null; return }
    foreach ($pr in 'TCP', 'UDP') { New-NetFirewallRule -Name "OPS-RdpGuard-$Ip-$pr" -DisplayName "OPS-RdpGuard-$Ip-$pr" -Protocol $pr -LocalPort $Ports @common | Out-Null }
}

# 讀 HKLM 底下的子機碼（Bans / Forgive），回傳 @{ IP = 時間 }
function Get-RdpGuardList {
    param([string]$Name)
    $k = "HKLM:\SOFTWARE\OPS-command\RdpGuard\$Name"
    $h = @{}
    if (-not (Test-Path $k)) { return $h }
    $p = Get-ItemProperty -Path $k
    foreach ($n in (Get-Item -Path $k).Property) {
        try { $h[$n] = [datetime]::ParseExact((([string]$p.$n) -split '\|')[0], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    $h
}

function Remove-RdpGuardBan {
    param([string]$Ip, [string]$Reason, [datetime]$Now = (Get-Date))
    $k = 'HKLM:\SOFTWARE\OPS-command\RdpGuard'
    Remove-RdpGuardRule $Ip
    Remove-ItemProperty -Path "$k\Bans" -Name $Ip -ErrorAction SilentlyContinue
    if (-not (Test-Path "$k\Forgive")) { New-Item -Path "$k\Forgive" -Force | Out-Null }
    Set-ItemProperty -Path "$k\Forgive" -Name $Ip -Value $Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    Write-RdpGuardEvent 301 "RdpGuard 解封 $Ip（$Reason）"
}

# 一輪：讀設定 → 讀 4625 → 判斷 → 解封 / 封鎖 → 補回被刪掉的規則。回傳給人看的文字。
#   -Events  測試用：不讀 Security，用這些假事件（Time, Ip）
#   -Now     測試用：假裝現在是這個時間（驗證到期解封）
#   -Config  用這組設定而不是登錄檔（試算用）
#   -DryRun  只回報會做什麼，不動防火牆與登錄檔
#   -SyncOnly 不更新「上次執行」（套用設定時順手同步用）
function Invoke-RdpGuard {
    param([object[]]$Events, [datetime]$Now = (Get-Date), [hashtable]$Config, [switch]$DryRun, [switch]$SyncOnly)
    $k = 'HKLM:\SOFTWARE\OPS-command\RdpGuard'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $c = if ($Config) { $Config } else { Get-ItemProperty -Path $k -ErrorAction SilentlyContinue }
    if (-not $c -or -not $c.Threshold) { throw '尚未設定（請先按「啟用／套用設定」）。' }
    $th = [int]$c.Threshold; $win = [int]$c.WindowMin; $banMin = [int]$c.BanMin
    $scope = if ($c.Scope -eq 'All') { 'All' } else { 'Rdp' }
    $wl = @($c.Whitelist) + @('127.0.0.0/8', '::1') + @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress -replace '%.*$', '' })
    $bans = Get-RdpGuardList 'Bans'
    $forgive = Get-RdpGuardList 'Forgive'
    if (-not $PSBoundParameters.ContainsKey('Events')) { $Events = @(Get-RdpGuardFailures $Now.AddMinutes(-$win)) }
    $plan = Get-RdpGuardPlan -Events $Events -Now $Now -Threshold $th -WindowMin $win -BanMin $banMin -Whitelist $wl -Bans $bans -Forgive $forgive
    $ports = @(@((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).PortNumber,
                 (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OPS-command\RdpPort' -ErrorAction SilentlyContinue).OldPort) | Where-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if (-not $ports.Count) { $ports = @(3389) }
    $sig = if ($scope -eq 'All') { 'All' } else { 'Rdp:' + ($ports -join ',') }

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add(('最近 {0} 分鐘有 {1} 筆登入失敗，{2} 個來源（白名單與沒有 IP 的不算）；門檻 {3} 次。' -f $win, @($Events).Count, $plan.Counts.Count, $th))
    foreach ($ip in @($plan.Counts.Keys | Sort-Object { $plan.Counts[$_] } -Descending | Select-Object -First 10)) {
        [void]$out.Add(('  {0,-40} {1} 次' -f $ip, $plan.Counts[$ip]))
    }
    $newBans = @($plan.Ban | Select-Object -First 100)
    if ($DryRun) {
        foreach ($b in $newBans) { [void]$out.Add("[試算] 會封鎖 $($b.Ip)（$($b.Count) 次），到 $($b.Until.ToString('yyyy-MM-dd HH:mm:ss', $inv))") }
        foreach ($u in $plan.Unban) { [void]$out.Add("[試算] 會解封 $($u.Ip)（$($u.Reason)）") }
        if (-not $newBans.Count -and -not @($plan.Unban).Count) { [void]$out.Add('[試算] 這一輪不會封鎖或解封任何 IP。') }
        return $out
    }

    foreach ($u in $plan.Unban) { Remove-RdpGuardBan -Ip $u.Ip -Reason $u.Reason -Now $Now; $bans.Remove($u.Ip); $forgive[$u.Ip] = $Now; [void]$out.Add("解封 $($u.Ip)（$($u.Reason)）") }
    if (-not (Test-Path "$k\Bans")) { New-Item -Path "$k\Bans" -Force | Out-Null }
    $total = [int]$c.TotalBans
    foreach ($b in $newBans) {
        try { Set-RdpGuardRule -Ip $b.Ip -Scope $scope -Ports $ports }
        catch { Write-RdpGuardEvent 302 "RdpGuard 封鎖 $($b.Ip) 失敗：$($_.Exception.Message)" 'Error'; [void]$out.Add("[錯誤] 封鎖 $($b.Ip) 失敗：$($_.Exception.Message)"); continue }
        $until = $b.Until.ToString('yyyy-MM-dd HH:mm:ss', $inv)
        Set-ItemProperty -Path "$k\Bans" -Name $b.Ip -Value "$until|$($b.Count)"
        $bans[$b.Ip] = $b.Until; $total++
        $what = if ($scope -eq 'All') { '全部連入' } else { "RDP Port $($ports -join ',')" }
        Write-RdpGuardEvent 300 "RdpGuard 封鎖 $($b.Ip)：$win 分鐘內登入失敗 $($b.Count) 次（門檻 $th），封鎖 $what 到 $until" 'Warning'
        [void]$out.Add("封鎖 $($b.Ip)（$($b.Count) 次），到 $until")
    }
    # 規則被別人刪掉、或 RDP Port / 封鎖範圍變了：照目前設定重建
    $fresh = @($newBans | ForEach-Object { $_.Ip })
    $sigChanged = $c.RuleSig -and $c.RuleSig -ne $sig
    foreach ($ip in @($bans.Keys | Where-Object { $fresh -notcontains $_ })) {
        $need =if ($scope -eq 'All') { @("OPS-RdpGuard-$ip-ALL") } else { @("OPS-RdpGuard-$ip-TCP", "OPS-RdpGuard-$ip-UDP") }
        $have = @(Get-NetFirewallRule -Name $need -ErrorAction SilentlyContinue).Count
        if ($sigChanged -or $have -ne $need.Count) {
            try { Set-RdpGuardRule -Ip $ip -Scope $scope -Ports $ports; [void]$out.Add("重建 $ip 的封鎖規則") }
            catch { Write-RdpGuardEvent 302 "RdpGuard 重建 $ip 的規則失敗：$($_.Exception.Message)" 'Error' }
        }
    }
    foreach ($ip in @($forgive.Keys)) { if ($forgive[$ip] -lt $Now.AddMinutes(-$win)) { Remove-ItemProperty -Path "$k\Forgive" -Name $ip -ErrorAction SilentlyContinue } }
    if (-not $Config) {
        Set-ItemProperty -Path $k -Name RuleSig -Value $sig
        Set-ItemProperty -Path $k -Name TotalBans -Value $total -Type DWord
        if (-not $SyncOnly) {
            $summary = '失敗 {0} 筆，新封鎖 {1}，解封 {2}，封鎖中 {3}' -f @($Events).Count, $newBans.Count, @($plan.Unban).Count, $bans.Count
            Set-ItemProperty -Path $k -Name LastRun -Value $Now.ToString('yyyy-MM-dd HH:mm:ss', $inv)
            Set-ItemProperty -Path $k -Name LastResult -Value $summary
            [void]$out.Add($summary)
        }
    }
    $out
}

# ---- 以下只在介面裡用 ----

# 把上面的核心函式組成一段獨立的程式碼（排程與背景作業共用同一份）。
# 去掉註解行與縮排，排程的命令列有 32767 字元上限，Base64 會把長度放大約 2.7 倍。
function Get-RdpGuardScript {
    $parts = foreach ($n in $Script:RdpGuardCoreFunctions) { "function $n {`n" + (Get-Item "function:$n").ScriptBlock.ToString() + "`n}" }
    $lines = ($parts -join "`n") -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    "`$ErrorActionPreference = 'Continue'`n" + ($lines -join "`n")
}

function Register-RdpGuardTask {
    param([string]$TaskName = $Script:RdpGuardTask, [string]$Invocation = 'Invoke-RdpGuard | Out-Null', [int]$EveryMinutes = 1)
    $body = (Get-RdpGuardScript) + "`ntry { $Invocation } catch { Write-RdpGuardEvent 302 ('RdpGuard 執行失敗：' + `$_.Exception.Message) 'Error' }"
    $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    if ($arg.Length -gt 32000) { throw "排程指令太長（$($arg.Length) 字元），Windows 命令列上限 32767。" }
    $ps        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action    = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'OPS-command：RDP 暴力破解自動封鎖。設定在 HKLM\SOFTWARE\OPS-command\RdpGuard，紀錄在應用程式事件記錄（來源 OPS-command，300/301/302）。' -Force -ErrorAction Stop | Out-Null
}

# 稽核「登入」的失敗沒開，就不會有 4625，守護等於沒作用。auditpol /r 的欄位名稱是英文。
function Get-RdpGuardAudit {
    $raw = & auditpol.exe /get "/subcategory:$($Script:RdpGuardAuditGuid)" /r 2>&1
    if ($LASTEXITCODE -ne 0) { return @{ Known = $false; Failure = $false; Text = '讀不到（需要管理員權限）' } }
    $row = @($raw | Where-Object { $_ -match ',' } | ConvertFrom-Csv) | Select-Object -First 1
    $set = [string]$row.'Inclusion Setting'
    @{ Known = $true; Failure = ($set -match 'Failure'); Text = $set }
}

# 目前連進來的來源：Established 且本機端是監聽中的 Port（排除本機連出去的，例如 Windows Update）
function Get-RdpGuardConnectedIps {
    $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalPort } | Sort-Object -Unique)
    @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $listen -contains $_.LocalPort } |
        ForEach-Object { $_.RemoteAddress -replace '^::ffff:', '' } |
        Where-Object { $_ -and $_ -notmatch '^(127\.|::1$|0\.0\.0\.0$|::$)' } | Sort-Object -Unique)
}

function Split-RdpGuardList {
    param([string]$Text)
    @(($Text -split '[\s,;，、]+') | Where-Object { $_ } | Select-Object -Unique)
}

function Get-RdpGuardStatus {
    $c = Get-ItemProperty -Path $Script:RdpGuardKey -ErrorAction SilentlyContinue
    $t = Get-ScheduledTask -TaskName $Script:RdpGuardTask -ErrorAction SilentlyContinue
    if ($t) {
        $info = Get-ScheduledTaskInfo -TaskName $Script:RdpGuardTask -ErrorAction SilentlyContinue
        "守護排程：已啟用（$($Script:RdpGuardTask)，每 1 分鐘以 SYSTEM 執行，排程狀態 $($t.State)）" + $(if ($info -and $info.LastTaskResult -and $info.LastTaskResult -ne 267011) { "　上次結束代碼 $($info.LastTaskResult)" } else { '' })
    } else { '守護排程：未啟用' }
    if ($c -and $c.Threshold) {
        "上次執行：$(if ($c.LastRun) { "$($c.LastRun)　$($c.LastResult)" } else { '還沒執行過' })"
        "規則：$($c.WindowMin) 分鐘內登入失敗 $($c.Threshold) 次 → 封鎖 $($c.BanMin) 分鐘，" + $(if ($c.Scope -eq 'All') { '擋全部連入' } else { '只擋 RDP Port' })
        "白名單：$(@($c.Whitelist) -join '、')"
    } else { '尚未設定。' }
    $a = Get-RdpGuardAudit
    '稽核登入失敗：' + $(if (-not $a.Known) { $a.Text } elseif ($a.Failure) { "已開啟（$($a.Text)）" } else { "沒開（$($a.Text)）→ 不會產生 4625，守護抓不到任何人，請按「開啟稽核登入失敗」" })
    $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($off.Count) { "[注意] 防火牆設定檔 $($off -join '、') 是關閉的，封鎖規則在這些網路上不會生效。" }
    $recent = 0
    try { $recent = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'OPS-command'; Id = 300; StartTime = (Get-Date).AddHours(-24) } -ErrorAction Stop).Count } catch { }
    "最近 24 小時封鎖 $recent 次；累計 $(if ($c) { [int]$c.TotalBans } else { 0 }) 次"
    $bans = Get-RdpGuardList 'Bans'
    if (-not $bans.Count) { '封鎖中：無' } else {
        "封鎖中 $($bans.Count) 個（到期時間）："
        $bans.GetEnumerator() | Sort-Object Value | Select-Object -First 15 | ForEach-Object { "　$($_.Key)　到 $($_.Value.ToString('MM-dd HH:mm'))" }
        if ($bans.Count -gt 15) { "　…另外 $($bans.Count - 15) 個" }
    }
}

# 確認視窗用：把輸入整理成設定，並列出會自動加入白名單的目前連線
function Get-RdpGuardPending {
    param([hashtable]$v)
    $list = Split-RdpGuardList $v.Whitelist
    $bad = @($list | Where-Object { $_ -ne '-' -and -not (Test-RdpGuardIpIn ($_ -split '/')[0] @(($_ -split '/')[0])) })
    if ($bad.Count) { throw "白名單裡有看不懂的項目：$($bad -join '、')（只接受 IP、CIDR 或 -）" }
    $auto = @(@('127.0.0.1', '::1', '-') + @(Get-RdpGuardConnectedIps) | Where-Object { $list -notcontains $_ })
    @{ Whitelist = @($list + $auto); Auto = $auto; Scope = $(if ($v.Scope -like '全部*') { 'All' } else { 'Rdp' })
       Threshold = [int]$v.Threshold; WindowMin = [int]$v.WindowMin; BanMin = [int]$v.BanMin }
}

function Enable-RdpGuard {
    param([hashtable]$v)
    $p = Get-RdpGuardPending $v
    $k = $Script:RdpGuardKey
    New-Item -Path $k -Force -ErrorAction Stop | Out-Null   # -Force 對已存在的機碼不會清掉內容
    Set-ItemProperty -Path $k -Name Threshold -Value $p.Threshold -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $k -Name WindowMin -Value $p.WindowMin -Type DWord
    Set-ItemProperty -Path $k -Name BanMin -Value $p.BanMin -Type DWord
    Set-ItemProperty -Path $k -Name Scope -Value $p.Scope
    Set-ItemProperty -Path $k -Name Whitelist -Value ([string[]]$p.Whitelist) -Type MultiString
    # 已封鎖但現在進了白名單的，馬上解封（空事件跑一輪：只做解封與規則同步，不會新封鎖）
    $sync = @(Invoke-RdpGuard -Events @() -SyncOnly | Where-Object { $_ -match '^(解封|重建)' })
    Register-RdpGuardTask
    "[完成] 守護已啟用：$($p.WindowMin) 分鐘內失敗 $($p.Threshold) 次就封鎖 $($p.BanMin) 分鐘，每 1 分鐘檢查一次。"
    if ($p.Auto.Count) { "已自動加入白名單：$($p.Auto -join '、')" }
    $sync
    $a = Get-RdpGuardAudit
    if ($a.Known -and -not $a.Failure) { '[注意] 稽核登入失敗沒開，不會產生 4625 事件，守護抓不到任何人。請按「開啟稽核登入失敗」。' }
}

function Disable-RdpGuard {
    Unregister-ScheduledTask -TaskName $Script:RdpGuardTask -Confirm:$false -ErrorAction SilentlyContinue
    $n = Unblock-RdpGuardAll
    "[完成] 守護排程已刪除，解封 $n 個 IP。設定保留在 $($Script:RdpGuardKey)，下次啟用沿用。"
}

function Unblock-RdpGuardAll {
    $bans = Get-RdpGuardList 'Bans'
    foreach ($ip in @($bans.Keys)) { Remove-RdpGuardBan -Ip $ip -Reason '手動解封全部' }
    # 登錄檔裡沒有、但規則還在的（例如狀態被手動刪掉）一併清掉；只動群組 OPS-RdpGuard
    Get-NetFirewallRule -Group 'OPS-RdpGuard' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $bans.Count
}

function Show-RdpGuardPanel {
    $c = Get-ItemProperty -Path $Script:RdpGuardKey -ErrorAction SilentlyContinue
    $wl = if ($c -and $c.Whitelist) { @($c.Whitelist) } else { @('127.0.0.1', '::1', '-') + @(Get-RdpGuardConnectedIps) }
    # 背景作業看不到這支腳本的函式，把核心函式整段帶過去
    $worker = "param([hashtable]`$Cfg, [bool]`$Dry)`n" + (Get-RdpGuardScript) + "`nif (`$Dry) { Invoke-RdpGuard -Config `$Cfg -DryRun } else { Invoke-RdpGuard }"
    Show-FeaturePanel -Title 'RDP 暴力破解自動封鎖' -Subtitle '同一個來源 IP 登入失敗太多次，就用防火牆擋掉，到期自動解封（Windows 版 fail2ban）' -Width 980 -Height 800 `
        -Note '讀 Security 4625（登入失敗）的來源 IP；任何服務的登入失敗都算。白名單裡的 IP 永遠不封，啟用時會把目前連進來的來源自動加入——請確認你自己的 IP 在裡面。設定改完要按「啟用／套用設定」才生效。紀錄在應用程式事件記錄：來源 OPS-command，300 封鎖、301 解封、302 失敗。' `
        -Status { Get-RdpGuardStatus } `
        -Inputs @(
            @{ Name = 'Threshold'; Label = '門檻（失敗幾次）'; Type = 'Number'; Min = 2; Max = 100; Default = $(if ($c -and $c.Threshold) { [int]$c.Threshold } else { 5 }) }
            @{ Name = 'WindowMin'; Label = '統計時間窗（分鐘）'; Type = 'Number'; Min = 1; Max = 1440; Default = $(if ($c -and $c.WindowMin) { [int]$c.WindowMin } else { 10 }) }
            @{ Name = 'BanMin'; Label = '封鎖時間（分鐘）'; Type = 'Number'; Min = 1; Max = 43200; Default = $(if ($c -and $c.BanMin) { [int]$c.BanMin } else { 60 }) }
            @{ Name = 'Scope'; Label = '封鎖範圍'; Type = 'Combo'; Items = @('只擋 RDP Port（TCP + UDP）', '全部連入（含 SSH 等救援管道）'); Default = $(if ($c -and $c.Scope -eq 'All') { '全部連入（含 SSH 等救援管道）' } else { '只擋 RDP Port（TCP + UDP）' }) }
            @{ Name = 'Whitelist'; Label = '白名單（逗號分隔，IP 或 CIDR）'; Width = 600; Default = ($wl -join ', ') }
            @{ Name = 'UnbanIp'; Label = '要解封的 IP'; Width = 260; Default = '' }
        ) `
        -Actions @(
            @{ Text = '啟用／套用設定'; Style = 'success'; Admin = $true
               Confirm = { param($v)
                   $p = Get-RdpGuardPending $v
                   "每 1 分鐘以 SYSTEM 檢查一次：$($p.WindowMin) 分鐘內同一 IP 登入失敗 $($p.Threshold) 次，就封鎖 $($p.BanMin) 分鐘（" + $(if ($p.Scope -eq 'All') { '全部連入' } else { '只擋 RDP Port' }) + "）。`r`n`r`n" +
                   "白名單（永遠不封）：`r`n  $($p.Whitelist -join "`r`n  ")`r`n`r`n" +
                   $(if ($p.Auto.Count) { "其中這些是自動加入的（本機與目前連進來的來源）：$($p.Auto -join '、')`r`n`r`n" } else { '' }) +
                   "你自己連進來的 IP 在上面嗎？不在的話請先按「否」、把它加進白名單。確定啟用？" }
               Run = { param($v) Enable-RdpGuard $v } }
            @{ Text = '停用'; Style = 'danger'; Admin = $true
               Confirm = '停用會刪除守護排程，並解封目前所有被封鎖的 IP（設定保留）。確定？'
               Run = { Disable-RdpGuard } }
            @{ Text = '立即執行一次'; Style = 'primary'; Admin = $true
               Confirm = '用已儲存的設定立即跑一輪，達到門檻的 IP 會真的被封鎖。確定？'
               Worker = $worker; WorkerArgs = { $null, $false } }
            @{ Text = '試算（不封鎖）'; Style = 'light'
               Worker = $worker; WorkerArgs = { param($v) (Get-RdpGuardPending $v), $true } }
            @{ Text = '解封指定 IP'; Style = 'primary'; Admin = $true
               Run = { param($v)
                   $ip = $v.UnbanIp.Trim()
                   $a = $null
                   if (-not [Net.IPAddress]::TryParse($ip, [ref]$a)) { throw "「$ip」不是有效的 IP。" }
                   $bans = Get-RdpGuardList 'Bans'
                   $rules = @(Get-NetFirewallRule -Name "OPS-RdpGuard-$ip-TCP", "OPS-RdpGuard-$ip-UDP", "OPS-RdpGuard-$ip-ALL" -ErrorAction SilentlyContinue)
                   if (-not $bans.ContainsKey($ip) -and -not $rules.Count) { throw "$ip 目前沒有被封鎖。" }
                   Remove-RdpGuardBan -Ip $ip -Reason '手動解封'
                   "[完成] 已解封 $ip。它之前的失敗紀錄不再計數；之後再失敗達到門檻還是會被封——要永遠放行請加進白名單。"
               } }
            @{ Text = '解封全部'; Style = 'danger'; Admin = $true
               Confirm = '解封目前所有被封鎖的 IP（守護繼續運作）。確定？'
               Run = { "[完成] 已解封 $(Unblock-RdpGuardAll) 個 IP。" } }
            @{ Text = '開啟稽核登入失敗'; Style = 'light'; Admin = $true
               Run = {
                   $out = & auditpol.exe /set "/subcategory:$($Script:RdpGuardAuditGuid)" /failure:enable 2>&1
                   $a = Get-RdpGuardAudit
                   if (-not $a.Failure) { throw "設定後讀回來還是「$($a.Text)」：$($out -join ' ')。可能被網域群組原則覆寫。" }
                   "[完成] 稽核「登入」的失敗已開啟（目前：$($a.Text)），之後登入失敗會產生 4625 事件。"
               } }
        )
}

function Show-AdminAccountPanel {
    Show-FeaturePanel -Title '內建 Administrator 帳戶' -Subtitle '以 SID 結尾 -500 辨識，帳號被改名也找得到' `
        -Status {
            $a = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value.EndsWith('-500') }
            if (-not $a) { '讀不到帳號資訊。'; return }
            "帳號名稱：$($a.Name)　　狀態：$(if ($a.Enabled) { '已啟用' } else { '已停用' })"
            if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $a.SID.Value) { '注意：你現在就是用這個帳號登入的。' }
        } `
        -Actions @(
            @{ Text = '啟用'; Style = 'primary'; Admin = $true
               Run = {
                   $a = Get-LocalUser | Where-Object { $_.SID.Value.EndsWith('-500') }
                   Enable-LocalUser -SID $a.SID -ErrorAction Stop
                   "[完成] 已啟用 $($a.Name)。建議接著用「變更本機帳號密碼」設定強密碼。"
               } }
            @{ Text = '停用'; Style = 'danger'; Admin = $true
               Confirm = {
                   $a = Get-LocalUser | Where-Object { $_.SID.Value.EndsWith('-500') }
                   if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $a.SID.Value) {
                       "你現在就是用 $($a.Name) 登入的。停用後，這次登出就再也無法用它登入；如果這台沒有其他管理員帳號，等於把自己鎖在外面。`r`n`r`n確定要停用？"
                   } else { "確定要停用 $($a.Name)？" }
               }
               Run = {
                   $a = Get-LocalUser | Where-Object { $_.SID.Value.EndsWith('-500') }
                   Disable-LocalUser -SID $a.SID -ErrorAction Stop
                   "[完成] 已停用 $($a.Name)。"
               } }
        )
}

# ================= 系統與更新 =================

function Show-WindowsUpdatePanel {
    Show-FeaturePanel -Title 'Windows 更新' -Subtitle '停止或還原 Windows Update 服務' `
        -Note '停止後將無法自動取得安全性修補程式。Windows 的更新自我修復（WaaSMedic）可能在幾秒內把服務改回來，畫面會如實顯示；遇到這種情況，重新開機後再執行一次「停止」才留得住。' `
        -Status {
            $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
            "wuauserv：$($wu.Status)　啟動類型：$($wu.StartType)　（Disabled + Stopped = 已停止；Manual = 預設）"
        } `
        -Actions @(
            @{ Text = '停止 Windows 更新'; Style = 'danger'; Admin = $true
               Confirm = '停止後將無法自動取得安全性修補程式。確定繼續？'
               Worker = $Script:WorkerWindowsUpdate; WorkerArgs = { , 'Stop' } }
            @{ Text = '還原 Windows 更新'; Style = 'success'; Admin = $true
               Worker = $Script:WorkerWindowsUpdate; WorkerArgs = { , 'Restore' } }
        )
}

function Show-StorePanel {
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    Show-FeaturePanel -Title 'Microsoft Store 自動更新' -Subtitle '關閉可解決 wsappx 持續占用 CPU／硬碟' `
        -Status {
            $cur = (Get-ItemProperty -Path $key -Name AutoDownload -ErrorAction SilentlyContinue).AutoDownload
            'AutoDownload = ' + $(switch ($cur) { 2 { '2　已關閉自動更新' } 4 { '4　開啟自動更新' } default { '尚未設定（預設會自動更新）' } })
        }.GetNewClosure() `
        -Actions @(
            @{ Text = '關閉自動更新'; Style = 'primary'; Admin = $true
               Run = {
                   if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                   Set-ItemProperty -Path $key -Name AutoDownload -Type DWord -Value 2
                   '[完成] 已關閉。wsappx 占用通常幾分鐘後下降。'
               }.GetNewClosure() }
            @{ Text = '開啟自動更新'; Style = 'light'; Admin = $true
               Run = {
                   if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                   Set-ItemProperty -Path $key -Name AutoDownload -Type DWord -Value 4
                   '[完成] 已開啟。'
               }.GetNewClosure() }
        )
}

function Show-HyperVPanel {
    Show-FeaturePanel -Title 'Hyper-V／VMware 切換' -Subtitle '所有變更都要重新開機才生效' `
        -Note '已裝 VMware 又想用 Hyper-V → 「Hyper-V 優先」；要改用 VMware → 「VMware 優先」。啟用／移除元件可能要好幾分鐘，會在背景執行。家用版 Windows 沒有 Hyper-V。' `
        -Status {
            if (-not $IsAdmin) { '查詢需要系統管理員權限。'; return }
            $lt = & bcdedit /enum '{current}' 2>&1 | Select-String 'hypervisorlaunchtype' | Select-Object -First 1
            if ($lt) { $lt.ToString().Trim() } else { 'hypervisorlaunchtype：未設定（通常等同 Auto）' }
            try { "Hyper-V 元件：$((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop).State)" }
            catch { "Hyper-V 元件：查不到（$($_.Exception.Message)）" }
        } `
        -Actions @(
            @{ Text = 'Hyper-V 優先（auto）'; Style = 'primary'; Admin = $true
               Run = { $o = & bcdedit /set hypervisorlaunchtype auto 2>&1
                   if ($LASTEXITCODE -ne 0) { throw ($o -join ' ') }
                   '[完成] hypervisorlaunchtype = auto，請重新開機。' } }
            @{ Text = 'VMware 優先（off）'; Style = 'primary'; Admin = $true
               Run = { $o = & bcdedit /set hypervisorlaunchtype off 2>&1
                   if ($LASTEXITCODE -ne 0) { throw ($o -join ' ') }
                   '[完成] hypervisorlaunchtype = off，請重新開機。' } }
            @{ Text = '啟用 Hyper-V 元件'; Style = 'success'; Admin = $true
               Worker = $Script:WorkerHyperV; WorkerArgs = { , 'Enable' } }
            @{ Text = '移除 Hyper-V 元件'; Style = 'danger'; Admin = $true
               Confirm = '這會移除 Hyper-V 元件，現有的 Hyper-V 虛擬機器將無法啟動，直到重新啟用。確定？'
               Worker = $Script:WorkerHyperV; WorkerArgs = { , 'Disable' } }
        )
}

function Show-TimePanel {
    $zones = @(Get-TimeZone -ListAvailable)
    Show-FeaturePanel -Title '時間與時區' -Subtitle '網路校時與時區設定' `
        -Status {
            "目前時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "目前時區：$((Get-TimeZone).DisplayName)"
            $src = & w32tm /query /source 2>&1
            "時間來源：$(($src | ForEach-Object { [string]$_ }) -join ' ')"
        } `
        -Inputs @(
            @{ Name = 'Ntp'; Label = 'NTP 伺服器'; Type = 'Text'; Default = 'time.windows.com' }
            @{ Name = 'Zone'; Label = '時區'; Type = 'Combo'; Items = @($zones | ForEach-Object DisplayName); Default = (Get-TimeZone).DisplayName; Width = 480 }
        ) `
        -Actions @(
            @{ Text = '立即校時'; Style = 'primary'; Admin = $true
               Worker = $Script:WorkerTime; WorkerArgs = { , 'Resync' } }
            @{ Text = '設定 NTP 並校時'; Style = 'primary'; Admin = $true
               Confirm = { param($v) if (-not $v.Ntp) { '' } else { "NTP 伺服器設為 $($v.Ntp)，並把 Windows Time 服務改成自動啟動。確定？" } }
               WorkerArgs = { param($v) if (-not $v.Ntp) { throw '請輸入 NTP 伺服器。' }; 'Ntp', $v.Ntp }
               Worker = $Script:WorkerTime }
            @{ Text = '套用時區'; Style = 'success'; Admin = $true
               Run = {
                   param($v)
                   $z = $zones | Where-Object { $_.DisplayName -eq $v.Zone } | Select-Object -First 1
                   if (-not $z) { throw '請選擇時區。' }
                   Set-TimeZone -Id $z.Id -ErrorAction Stop
                   "[完成] 時區已設為 $($z.DisplayName)。"
               }.GetNewClosure() }
        )
}

# ================= 網路與防火牆 =================

function Show-PingPanel {
    Show-FeaturePanel -Title 'Ping（ICMP）' -Subtitle '允許或拒絕本機回應 ping' `
        -Note '只管理本工具建立的規則（ICMP-Echo-Allow / ICMPv6-Echo-Allow / ICMP-Echo-Block）。是否真的 ping 得到，必須從另一台電腦測。' `
        -Status {
            $allow = Get-NetFirewallRule -DisplayName 'ICMP-Echo-Allow' -ErrorAction SilentlyContinue
            $block = Get-NetFirewallRule -DisplayName 'ICMP-Echo-Block' -ErrorAction SilentlyContinue
            if ($allow) { '找到允許規則：目前「開啟」' } elseif ($block) { '找到封鎖規則：目前「關閉」' } else { '沒有本工具建立的規則（維持系統預設）' }
        } `
        -Actions @(
            @{ Text = '開啟 Ping'; Style = 'primary'; Admin = $true
               Run = {
                   & netsh advfirewall firewall delete rule name="ICMP-Echo-Block" | Out-Null
                   & netsh advfirewall firewall add rule name="ICMP-Echo-Allow" protocol=icmpv4:8,any dir=in action=allow | Out-Null
                   if ($LASTEXITCODE -ne 0) { throw "建立 IPv4 規則失敗（netsh exit $LASTEXITCODE）" }
                   & netsh advfirewall firewall add rule name="ICMPv6-Echo-Allow" protocol=icmpv6:128,any dir=in action=allow | Out-Null
                   '[完成] 已開啟 Ping。'
               } }
            @{ Text = '關閉 Ping'; Style = 'danger'; Admin = $true
               Run = {
                   & netsh advfirewall firewall delete rule name="ICMP-Echo-Allow" | Out-Null
                   & netsh advfirewall firewall delete rule name="ICMPv6-Echo-Allow" | Out-Null
                   & netsh advfirewall firewall add rule name="ICMP-Echo-Block" protocol=icmpv4:8,any dir=in action=block | Out-Null
                   if ($LASTEXITCODE -ne 0) { throw "建立封鎖規則失敗（netsh exit $LASTEXITCODE）" }
                   '[完成] 已關閉 Ping。'
               } }
        )
}

function Show-BatchIpPanel {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object Name | ForEach-Object Name)
    Show-FeaturePanel -Title '批量新增 IP' -Subtitle '在同一張網卡加上一段連續的 IPv4 位址' `
        -Note '只支援固定 IP 的網卡。DHCP 網卡加上固定位址，Windows 會把整張網卡改成固定 IP、原本 DHCP 拿到的位址可能不見，遠端操作時等於斷線，所以會直接拒絕。' `
        -Inputs @(
            @{ Name = 'Adapter'; Label = '網卡'; Type = 'Combo'; Items = $adapters }
            @{ Name = 'Base'; Label = 'IP 前三段（例 192.168.1）'; Type = 'Text'; Width = 200 }
            @{ Name = 'Start'; Label = '起始第四段'; Type = 'Number'; Min = 1; Max = 254; Default = 100 }
            @{ Name = 'End'; Label = '結束第四段'; Type = 'Number'; Min = 1; Max = 254; Default = 110 }
            @{ Name = 'Prefix'; Label = '遮罩長度'; Type = 'Number'; Min = 1; Max = 32; Default = 24 }
        ) `
        -Actions @(
            @{ Text = '新增'; Style = 'primary'; Admin = $true
               Confirm = { param($v) if ($v.Base -match '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -and $v.Start -le $v.End) { "將在 [$($v.Adapter)] 新增 $($v.Base).$($v.Start) ~ $($v.Base).$($v.End) / $($v.Prefix)，共 $($v.End - $v.Start + 1) 個。確定？" } else { '' } }
               Run = {
                   param($v)
                   if (-not $v.Adapter) { throw '沒有可用的網卡。' }
                   if ($v.Base -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or @($v.Base.Split('.') | Where-Object { [int]$_ -gt 255 }).Count) { throw 'IP 前三段格式不對，應該像 192.168.1' }
                   if ($v.Start -gt $v.End) { throw '起始不可大於結束。' }
                   $ipif = Get-NetIPInterface -InterfaceAlias $v.Adapter -AddressFamily IPv4 -ErrorAction Stop
                   if ($ipif.Dhcp -eq 'Enabled') { throw "網卡 $($v.Adapter) 是 DHCP。加上固定位址會讓整張網卡變成固定 IP，遠端操作時可能直接斷線，所以不執行。請先把網卡改成固定 IP。" }
                   $added = 0
                   for ($i = $v.Start; $i -le $v.End; $i++) {
                       $ip = "$($v.Base).$i"
                       try { New-NetIPAddress -InterfaceAlias $v.Adapter -IPAddress $ip -PrefixLength $v.Prefix -ErrorAction Stop | Out-Null
                           "  + $ip"
                           $added++ }
                       catch { "  ! $ip 略過（$($_.Exception.Message.Split([char]10)[0])）" }
                   }
                   "[完成] 共新增 $added 個。移除可用：Remove-NetIPAddress -IPAddress <IP>"
               } }
        )
}

# ================= 檢查與紀錄 =================

function Get-StatusReport {
    $port = Get-RdpPort
    "[1] RDP Port　　　　目前 = $port"
    if (Test-RdpWatchdog) { "　　　** 有未確認的換 Port 作業進行中，看門狗會自動還原為 $(Get-RdpOldPort)。請到「更換 RDP Port」確認或還原。" }
    $wu = Get-Service wuauserv
    "[2] Windows 更新　　wuauserv = $($wu.Status) / 啟動類型 = $($wu.StartType)　（Disabled + Stopped = 已停止）"
    $lock = & net accounts 2>&1 | Select-String '鎖定閾值|Lockout threshold' | Select-Object -First 1
    "[3] 帳號鎖定閾值　　$(if ($lock) { ($lock.ToString() -split ':\s*', 2)[-1].Trim() } else { '讀不到' })　（從不 / Never = 已關閉鎖定保護）"
    $single = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fSingleSessionPerUser -ErrorAction SilentlyContinue).fSingleSessionPerUser
    "[4] RDP 多工作階段　fSingleSessionPerUser = $single　（0 = 已開啟）"
    $ping = if (Get-NetFirewallRule -DisplayName 'ICMP-Echo-Allow' -ErrorAction SilentlyContinue) { '開啟' } elseif (Get-NetFirewallRule -DisplayName 'ICMP-Echo-Block' -ErrorAction SilentlyContinue) { '關閉' } else { '未設定（系統預設）' }
    "[5] Ping　　　　　　$ping"
    $ceo = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Name AllowEncryptionOracle -ErrorAction SilentlyContinue).AllowEncryptionOracle
    "[6] CredSSP　　　　 AllowEncryptionOracle = $(switch ($ceo) { 0 { '0 強制更新用戶端' } 1 { '1 已降低影響' } 2 { '2 易受攻擊' } default { '尚未設定' } })"
    ''
    '[7] 目前監聽中的 TCP Port'
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort -Unique |
        ForEach-Object { '　　{0,-6} PID {1,-6} {2}' -f $_.LocalPort, $_.OwningProcess, (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
    ''
    '提醒：RDP、Ping、Port 連不連得到，必須從「另一台電腦」測才準。'
}

function Show-ActionLogPanel {
    $report = @{ Text = '重新讀取'; Style = 'primary'; Run = {
        if (-not (Test-Path $Script:ActionLogPath)) { '（還沒有任何操作記錄）'; return }
        $lines = @(Get-Content -Path $Script:ActionLogPath -Encoding UTF8 -Tail 200)
        "最近 $($lines.Count) 筆（新的在下面）："
        ''
        $lines
    } }
    $open = @{ Text = '用記事本開啟'; Style = 'light'; Run = {
        if (-not (Test-Path $Script:ActionLogPath)) { throw '還沒有記錄檔。' }
        Start-Process notepad.exe -ArgumentList "`"$Script:ActionLogPath`""
        "已開啟 $Script:ActionLogPath"
    } }
    Show-FeaturePanel -Title '操作記錄' -Subtitle '這個工具做過的每一項系統變更' -Mono -Width 1000 `
        -Note "記錄檔：$Script:ActionLogPath（只有這個帳號的記錄）。以管理員執行的動作，另外寫進 Windows 事件記錄：應用程式，來源 OPS-command，事件 200 = 成功、201 = 失敗。" `
        -Actions @($report, $open) -OnOpen $report
}

function Show-StatusPanel {
    $report = @{ Text = '重新檢查'; Style = 'primary'; Run = { Get-StatusReport } }
    # 匯出：重新檢查一次再存檔（不是存畫面上的舊結果），交給別人或留存比對用。
    # UTF-8 含 BOM：記事本、Excel 與舊版工具都能正確認出中文。
    $export = @{ Text = '匯出成文字檔'; Style = 'light'; Run = {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dlg = New-Object Windows.Forms.SaveFileDialog
        $dlg.Title = '匯出系統現況'
        $dlg.Filter = '文字檔 (*.txt)|*.txt|所有檔案 (*.*)|*.*'
        $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        $dlg.FileName = "OPS-status_$($env:COMPUTERNAME)_$stamp.txt"
        $dlg.OverwritePrompt = $true
        try {
            $owner = [Windows.Forms.Form]::ActiveForm
            $ok = if ($owner) { $dlg.ShowDialog($owner) } else { $dlg.ShowDialog() }
            if ($ok -ne [Windows.Forms.DialogResult]::OK) { '（已取消匯出）'; return }
            $path = $dlg.FileName
        } finally { $dlg.Dispose() }
        $lines = @(
            'OPS-command 系統現況'
            "主機名稱：$env:COMPUTERNAME"
            "檢查時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
            "工具版本：$Script:ToolVersion"
            "執行帳號：$env:USERDOMAIN\$env:USERNAME（$(if ($IsAdmin) { '系統管理員' } else { '一般使用者，部分項目可能讀不到' })）"
            ('=' * 60)
            ''
        ) + @(Get-StatusReport 2>&1 | ForEach-Object { [string]$_ })
        [IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
        "已匯出：$path"
    } }
    Show-FeaturePanel -Title '檢查系統現況' -Subtitle '確認各項設定目前的實際狀態（唯讀）' -Mono -Actions @($report, $export) -OnOpen $report
}

# ===== Windows 原生視窗：自動排程管理 =====
function Open-TaskManagerPanel {
    # 用管線跑起來時 $PSScriptRoot 是空的，Join-Path 會直接丟錯；
    # 那種情況改找 ops-win.ps1 的落地目錄。
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { $Script:LocalDir }
    $gui = Join-Path $baseDir 'Win_Schedule_Panel.ps1'
    if (-not (Test-Path $gui -PathType Leaf)) {
        [Windows.Forms.MessageBox]::Show("找不到自動排程面板：`r`n$gui",'檔案不存在',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        return
    }
    # 主面板本身已在 STA 執行緒；直接載入並顯示子面板，避免隱藏子程序失敗時看不到錯誤。
    $previousPreference=$ErrorActionPreference
    try { . $gui }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.ToString(),'自動排程面板啟動失敗',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null }
    finally { $ErrorActionPreference=$previousPreference }
}

$script:PanelForm = $null
$script:ActiveFeatureForm = $null
$script:PanelCloseAfterAction = $false

function Set-UserPasswordPanel {
    if (-not (Request-PanelAdmin)) { return }
    $users=@(Get-LocalUser | Select-Object -ExpandProperty Name)
    if (-not $users) { [Windows.Forms.MessageBox]::Show('讀不到本機帳號。','錯誤','OK','Error') | Out-Null; return }
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='變更本機帳號密碼'
    $dialog.Size=New-Object Drawing.Size(480,260)
    $dialog.StartPosition='CenterParent'
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $user=New-Object Windows.Forms.ComboBox
    $user.DropDownStyle='DropDownList'
    [void]$user.Items.AddRange([string[]]$users)
    $user.Location=New-Object Drawing.Point(150,25)
    $user.Size=New-Object Drawing.Size(280,25)
    $user.SelectedIndex=0
    $pass1=New-Object Windows.Forms.TextBox
    $pass1.UseSystemPasswordChar=$true
    $pass1.Location=New-Object Drawing.Point(150,70)
    $pass1.Size=New-Object Drawing.Size(280,25)
    $pass2=New-Object Windows.Forms.TextBox
    $pass2.UseSystemPasswordChar=$true
    $pass2.Location=New-Object Drawing.Point(150,115)
    $pass2.Size=New-Object Drawing.Size(280,25)
    foreach($pair in @(@{Text='帳號'
        Y=25},@{Text='新密碼'
        Y=70},@{Text='再次輸入'
        Y=115})){$l=New-Object Windows.Forms.Label
        $l.Text=$pair.Text
        $l.Location=New-Object Drawing.Point(20,$pair.Y)
        $l.Size=New-Object Drawing.Size(115,25)
        $dialog.Controls.Add($l)}
    $dialog.Controls.AddRange(@($user,$pass1,$pass2))
    $ok=New-Object Windows.Forms.Button; $ok.Text='變更'; $ok.Location=New-Object Drawing.Point(250,165); $ok.DialogResult='OK'; $dialog.Controls.Add($ok)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'
    $cancel.Location=New-Object Drawing.Point(340,165)
    $cancel.DialogResult='Cancel'
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$ok
    $dialog.CancelButton=$cancel
    if($dialog.ShowDialog($script:PanelForm) -eq [Windows.Forms.DialogResult]::OK){
        if(-not $pass1.Text -or $pass1.Text -ne $pass2.Text){[Windows.Forms.MessageBox]::Show('密碼不可空白，且兩次輸入必須一致。','檢查密碼','OK','Warning')|Out-Null}
        else {try{$secure=ConvertTo-SecureString $pass1.Text -AsPlainText -Force
                Set-LocalUser -Name ([string]$user.SelectedItem) -Password $secure -ErrorAction Stop
                Write-OpsLog '變更本機帳號密碼' '變更密碼' '成功' "帳號 $($user.SelectedItem)"
                [Windows.Forms.MessageBox]::Show('密碼已變更。','完成','OK','Information')|Out-Null}catch{Write-OpsLog '變更本機帳號密碼' '變更密碼' '失敗' "帳號 $($user.SelectedItem)；$($_.Exception.Message)";[Windows.Forms.MessageBox]::Show($_.Exception.Message,'變更失敗','OK','Error')|Out-Null}}
    }
    $pass1.Clear();$pass2.Clear();$dialog.Dispose()
}

function Set-LockoutThreshold {
    param([int]$Threshold)
    if(-not (Request-PanelAdmin)){return}
    if($Threshold -lt 0 -or $Threshold -gt 999){[Windows.Forms.MessageBox]::Show('閾值必須介於 0 到 999。','數值錯誤','OK','Warning')|Out-Null;return}
    if($Threshold -eq 0){
        $answer=[Windows.Forms.MessageBox]::Show('關閉後，密碼錯誤將不會觸發帳號鎖定，可能增加暴力猜密碼風險。確定要關閉嗎?','安全性確認',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
    }
    try {
        $output=& net.exe accounts "/lockoutthreshold:$Threshold" 2>&1
        if($LASTEXITCODE -eq 0){
            $description=if($Threshold -eq 0){'帳號鎖定保護已關閉。'}else{"帳號鎖定保護已啟用：連續錯誤 $Threshold 次後鎖定。"}
            Write-OpsLog '帳號鎖定防護' "閾值設為 $Threshold" '成功' $description
            [Windows.Forms.MessageBox]::Show($description,'設定完成','OK','Information')|Out-Null
        } else {Write-OpsLog '帳號鎖定防護' "閾值設為 $Threshold" '失敗' ($output -join ' ');[Windows.Forms.MessageBox]::Show(($output -join "`r`n"),'設定失敗','OK','Error')|Out-Null}
    } catch {Write-OpsLog '帳號鎖定防護' "閾值設為 $Threshold" '失敗' $_.Exception.Message;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'設定失敗','OK','Error')|Out-Null}
}

function Show-LockoutPolicyPanel {
    if(-not (Request-PanelAdmin)){return}
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='帳號鎖定保護'
    $dialog.Size=New-Object Drawing.Size(570,310)
    $dialog.StartPosition='CenterParent'
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $dialog.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $info=New-Object Windows.Forms.Label
    $info.Text='設定連續登入錯誤幾次後鎖定帳號。建議啟用 5–10 次；0 代表關閉鎖定保護。'
    $info.Location=New-Object Drawing.Point(18,18)
    $info.Size=New-Object Drawing.Size(520,52)
    $dialog.Controls.Add($info)
    $label=New-Object Windows.Forms.Label
    $label.Text='自訂錯誤次數'
    $label.Location=New-Object Drawing.Point(22,87)
    $label.Size=New-Object Drawing.Size(130,28)
    $dialog.Controls.Add($label)
    $value=New-Object Windows.Forms.NumericUpDown
    $value.Minimum=1
    $value.Maximum=999
    $value.Value=5
    $value.Location=New-Object Drawing.Point(160,84)
    $value.Size=New-Object Drawing.Size(100,28)
    $dialog.Controls.Add($value)
    $custom=New-Object Windows.Forms.Button
    $custom.Text='套用自訂次數'
    $custom.Location=New-Object Drawing.Point(290,82)
    $custom.Size=New-Object Drawing.Size(180,34)
    $custom.FlatStyle='Flat'
    $custom.BackColor=[Drawing.Color]::FromArgb(219,234,254)
    $custom.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
    $dialog.Controls.Add($custom)
    $enable=New-Object Windows.Forms.Button
    $enable.Text='啟用防護（5 次）'
    $enable.Location=New-Object Drawing.Point(22,150)
    $enable.Size=New-Object Drawing.Size(190,46)
    $enable.FlatStyle='Flat'
    $enable.BackColor=[Drawing.Color]::FromArgb(220,252,231)
    $enable.ForeColor=[Drawing.Color]::FromArgb(22,101,52)
    $dialog.Controls.Add($enable)
    $disable=New-Object Windows.Forms.Button
    $disable.Text='關閉防護'
    $disable.Location=New-Object Drawing.Point(230,150)
    $disable.Size=New-Object Drawing.Size(190,46)
    $disable.FlatStyle='Flat'
    $disable.BackColor=[Drawing.Color]::FromArgb(254,226,226)
    $disable.ForeColor=[Drawing.Color]::FromArgb(153,27,27)
    $dialog.Controls.Add($disable)
    $close=New-Object Windows.Forms.Button
    $close.Text='關閉視窗'
    $close.Location=New-Object Drawing.Point(420,220)
    $close.Size=New-Object Drawing.Size(100,34)
    $dialog.Controls.Add($close)
    $custom.Add_Click({Set-LockoutThreshold -Threshold ([int]$value.Value)}.GetNewClosure())
    $enable.Add_Click({Set-LockoutThreshold -Threshold 5})
    $disable.Add_Click({Set-LockoutThreshold -Threshold 0})
    $close.Add_Click({$dialog.Close()}.GetNewClosure())
    [void]$dialog.ShowDialog($script:PanelForm); $dialog.Dispose()
}

function Show-EventDetailDialog {
    param($EventRecord)
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text="事件詳細內容｜ID $($EventRecord.Id)"
    $dialog.Size=New-Object Drawing.Size(900,650)
    $dialog.StartPosition='CenterParent'
    $dialog.MinimumSize=New-Object Drawing.Size(700,500)
    $dialog.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10); $dialog.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $text=New-Object Windows.Forms.TextBox
    $text.Multiline=$true
    $text.ReadOnly=$true
    $text.ScrollBars='Both'
    $text.WordWrap=$true
    $text.Dock='Fill'
    $text.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $text.BackColor=[Drawing.Color]::White
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("時間：$($EventRecord.TimeCreated)")
    [void]$sb.AppendLine("記錄檔：$($EventRecord.LogName)")
    [void]$sb.AppendLine("來源：$($EventRecord.ProviderName)")
    [void]$sb.AppendLine("事件 ID：$($EventRecord.Id)    層級：$($EventRecord.LevelDisplayName)")
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('--- 事件描述 ---')
    if($EventRecord.Message){[void]$sb.AppendLine($EventRecord.Message)}else{[void]$sb.AppendLine('(沒有描述文字)')}
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('--- 原始資料 (EventData) ---')
    try {
        $xml=[xml]$EventRecord.ToXml(); $data=$xml.Event.EventData.Data
        if($data){foreach($item in $data){$n=[string]$item.Name;if(-not $n){$n='(未命名)'};[void]$sb.AppendLine("$n = $($item.'#text')")}}
        else{[void]$sb.AppendLine('(沒有結構化 EventData)')}
    } catch {[void]$sb.AppendLine("(原始資料解析失敗：$($_.Exception.Message))")}
    $text.Text=$sb.ToString()
    $close=New-Object Windows.Forms.Button; $close.Text='關閉'; $close.Dock='Bottom'; $close.Height=36; $close.Add_Click({$dialog.Close()}.GetNewClosure())
    $dialog.Controls.Add($text); $dialog.Controls.Add($close)
    $owner=if($script:EventViewerForm){$script:EventViewerForm}else{$script:PanelForm}; [void]$dialog.ShowDialog($owner)
    $dialog.Dispose()
}

function Show-CustomEventQueryDialog {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='自訂事件查詢'
    $dialog.Size=New-Object Drawing.Size(500,290)
    $dialog.StartPosition='CenterParent'
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $dialog.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $dialog.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $log=New-Object Windows.Forms.TextBox; $log.Text='System'; $log.Location=New-Object Drawing.Point(150,25); $log.Size=New-Object Drawing.Size(300,25)
    $ids=New-Object Windows.Forms.TextBox; $ids.Location=New-Object Drawing.Point(150,70); $ids.Size=New-Object Drawing.Size(300,25)
    $days=New-Object Windows.Forms.NumericUpDown
    $days.Minimum=1
    $days.Maximum=3650
    $days.Value=7
    $days.Location=New-Object Drawing.Point(150,115)
    $days.Size=New-Object Drawing.Size(100,25)
    foreach($row in @(@{Text='記錄檔名稱'
        Y=25},@{Text='事件 ID（逗號分隔，可留空）'
        Y=70},@{Text='查詢最近幾天'
        Y=115})){$label=New-Object Windows.Forms.Label
        $label.Text=$row.Text
        $label.Location=New-Object Drawing.Point(18,$row.Y)
        $label.Size=New-Object Drawing.Size(125,28)
        $dialog.Controls.Add($label)}
    $dialog.Controls.AddRange(@($log,$ids,$days))
    $ok=New-Object Windows.Forms.Button; $ok.Text='查詢'; $ok.Location=New-Object Drawing.Point(280,180); $ok.DialogResult='OK'; $dialog.Controls.Add($ok)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'
    $cancel.Location=New-Object Drawing.Point(370,180)
    $cancel.DialogResult='Cancel'
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$ok
    $dialog.CancelButton=$cancel
    if($dialog.ShowDialog($script:EventViewerForm) -ne [Windows.Forms.DialogResult]::OK){$dialog.Dispose();return $null}
    $eventIds=@()
    if($ids.Text.Trim()){foreach($part in ($ids.Text -split ',')){if($part.Trim() -match '^\d+$'){$eventIds += [int]$part.Trim()}else{[Windows.Forms.MessageBox]::Show("無效的事件 ID：$part",'輸入錯誤','OK','Warning')|Out-Null
                $dialog.Dispose()
                return $null}}}
    $query=@{Log=$log.Text.Trim()}; if(-not $query.Log){$query.Log='System'}; if($eventIds.Count){$query['Ids']=$eventIds}
    $result=@{Name="自訂 - $($query.Log)";Queries=@($query);Days=[int]$days.Value}
    $dialog.Dispose(); return $result
}

function Show-EventViewerPanel {
    $form=New-Object Windows.Forms.Form
    $form.Text='事件檢視器'
    $form.Size=New-Object Drawing.Size(1100,700)
    $form.MinimumSize=New-Object Drawing.Size(850,550)
    $form.StartPosition='CenterParent'
    $form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10); $form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $script:EventViewerForm=$form; $state=@{Days=7;CurrentRows=@();CurrentName='';CurrentQueries=@();Reload=$null}
    $invokeEventQueryAction=${function:Invoke-EventQuery}
    $eventBriefAction=${function:Get-EventBrief}
    $eventDetailAction=${function:Show-EventDetailDialog}
    $customQueryAction=${function:Show-CustomEventQueryDialog}
    $restartAdminAction=${function:Restart-AsAdmin}
    $left=New-Object Windows.Forms.FlowLayoutPanel
    $left.Dock='Left'
    $left.Width=255
    $left.FlowDirection='TopDown'
    $left.WrapContents=$false
    $left.AutoScroll=$true
    $left.Padding=New-Object Windows.Forms.Padding(8)
    $top=New-Object Windows.Forms.FlowLayoutPanel
    $top.Dock='Top'
    $top.Height=48
    $top.FlowDirection='LeftToRight'
    $top.Padding=New-Object Windows.Forms.Padding(8,6,0,0)
    $grid=New-Object Windows.Forms.DataGridView
    $grid.Dock='Fill'
    $grid.ReadOnly=$true
    $grid.AllowUserToAddRows=$false
    $grid.AllowUserToDeleteRows=$false
    $grid.MultiSelect=$false
    $grid.SelectionMode='FullRowSelect'
    $grid.AutoSizeColumnsMode='Fill'
    $grid.RowHeadersVisible=$false
    $grid.BackgroundColor=[Drawing.Color]::White
    $grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White
    $grid.DefaultCellStyle.Font=New-Object Drawing.Font('Microsoft JhengHei UI',9)
    $grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(239,246,255)
    [void]$grid.Columns.Add('When','時間')
    [void]$grid.Columns.Add('Id','事件 ID')
    [void]$grid.Columns.Add('Level','層級')
    [void]$grid.Columns.Add('Provider','來源')
    [void]$grid.Columns.Add('Brief','摘要')
    $bottom=New-Object Windows.Forms.Panel; $bottom.Dock='Bottom'; $bottom.Height=54; $bottom.BackColor=[Drawing.Color]::FromArgb(226,232,240)
    $status=New-Object Windows.Forms.Label
    $status.Text='請點選左側事件情境。'
    $status.Dock='Fill'
    $status.TextAlign='MiddleLeft'
    $status.Padding=New-Object Windows.Forms.Padding(10,0,0,0)
    $detail=New-Object Windows.Forms.Button
    $detail.Text='查看詳細'
    $detail.Width=105
    $detail.Dock='Right'
    $detail.FlatStyle='Flat'
    $detail.BackColor=[Drawing.Color]::FromArgb(30,64,175)
    $detail.ForeColor=[Drawing.Color]::White
    $export=New-Object Windows.Forms.Button
    $export.Text='匯出 CSV'
    $export.Width=105
    $export.Dock='Right'
    $export.FlatStyle='Flat'
    $export.BackColor=[Drawing.Color]::FromArgb(22,101,52)
    $export.ForeColor=[Drawing.Color]::White
    $custom=New-Object Windows.Forms.Button
    $custom.Text='自訂查詢'
    $custom.Width=105
    $custom.Dock='Right'
    $custom.FlatStyle='Flat'
    $custom.BackColor=[Drawing.Color]::FromArgb(219,234,254)
    $custom.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
    $elevate=$null
    if(-not $IsAdmin){$elevate=New-Object Windows.Forms.Button;$elevate.Text='以管理員重新開啟';$elevate.Width=150;$elevate.Dock='Right'}
    $eventClose=New-Object Windows.Forms.Button
    $eventClose.Text='關閉視窗'
    $eventClose.Width=100
    $eventClose.Dock='Right'
    $eventClose.FlatStyle='Flat'
    $eventClose.BackColor=[Drawing.Color]::FromArgb(254,226,226)
    $eventClose.ForeColor=[Drawing.Color]::FromArgb(153,27,27)
    $eventClose.Add_Click({$form.Close()}.GetNewClosure())
    $bottom.Controls.Add($status)
    $bottom.Controls.Add($detail)
    $bottom.Controls.Add($export)
    $bottom.Controls.Add($custom)
    if($elevate){$bottom.Controls.Add($elevate)}
    $bottom.Controls.Add($eventClose)
    $form.Controls.Add($grid); $form.Controls.Add($left); $form.Controls.Add($top); $form.Controls.Add($bottom)

    $loadQuery={
        $grid.Rows.Clear(); $state.CurrentRows=@(); $status.Text='查詢中…'; $form.Refresh(); [Windows.Forms.Application]::DoEvents()
        try {
            $result=& $invokeEventQueryAction -Queries $state.CurrentQueries -Days $state.Days -Max 200
            $state.CurrentRows=@($result.Rows)
            foreach($ev in $state.CurrentRows){$i=$grid.Rows.Add($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'),$ev.Id,$ev.LevelDisplayName,$ev.ProviderName,(& $eventBriefAction $ev -Width 100))
                $grid.Rows[$i].Tag=$ev}
            $status.Text="$($state.CurrentName)｜最近 $($state.Days) 天｜找到 $($state.CurrentRows.Count) 筆"
            if($result.Problems.Count){$status.Text += '｜部分記錄檔讀取失敗（已顯示提示）'}
            if($result.Problems.Count){[Windows.Forms.MessageBox]::Show("部分事件記錄檔無法讀取：`r`n`r`n"+($result.Problems -join "`r`n"),'事件讀取提示',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}
        } catch {$status.Text="查詢失敗：$($_.Exception.Message)"}
    }.GetNewClosure()
    $state.Reload=$loadQuery

    foreach($spec in @(@{Text='最近 24 小時';Days=1},@{Text='最近 7 天';Days=7},@{Text='最近 30 天';Days=30})){
        $button=New-Object Windows.Forms.Button
        $button.Text=$spec.Text
        $button.Width=115
        $button.Height=32
        $button.FlatStyle='Flat'
        $button.BackColor=[Drawing.Color]::FromArgb(219,234,254)
        $button.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
        $d=$spec.Days
        $button.Add_Click({$state.Days=$d;& $state.Reload}.GetNewClosure());$top.Controls.Add($button)
    }
    foreach($scenario in (Get-EventScenarios)){
        $button=New-Object Windows.Forms.Button
        $button.Text=$scenario.Name
        $button.Width=220
        $button.Height=40
        $button.FlatStyle='Flat'
        $button.BackColor=[Drawing.Color]::FromArgb(30,64,175)
        $button.ForeColor=[Drawing.Color]::White
        $s=$scenario
        $button.Add_Click({
            if($s.NeedAdmin -and -not $IsAdmin){
                $answer=[Windows.Forms.MessageBox]::Show('此情境包含 Security 登入事件，一般權限可能讀不到。要以管理員權限重新開啟面板嗎?','需要管理員權限',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question)
                if($answer -eq [Windows.Forms.DialogResult]::Yes){[void](& $restartAdminAction);return}
            }
            $state.CurrentName=$s.Name;$state.CurrentQueries=$s.Queries;& $state.Reload
        }.GetNewClosure());$left.Controls.Add($button)
    }
    $grid.Add_CellDoubleClick({if($grid.SelectedRows.Count -gt 0){& $eventDetailAction $grid.SelectedRows[0].Tag}}.GetNewClosure())
    $detail.Add_Click({if($grid.SelectedRows.Count -gt 0){& $eventDetailAction $grid.SelectedRows[0].Tag}else{[Windows.Forms.MessageBox]::Show('請先選取一筆事件。','提示','OK','Information')|Out-Null}}.GetNewClosure())
    $custom.Add_Click({
        $query=& $customQueryAction
        if($query){$state.CurrentName=$query.Name;$state.CurrentQueries=$query.Queries;$state.Days=$query.Days;& $state.Reload}
    }.GetNewClosure())
    $export.Add_Click({
        if(-not $state.CurrentRows.Count){[Windows.Forms.MessageBox]::Show('目前沒有可匯出的事件。','提示','OK','Information')|Out-Null;return}
        $save=New-Object Windows.Forms.SaveFileDialog
        $save.Filter='CSV 檔案 (*.csv)|*.csv'
        $save.FileName=("事件紀錄-{0}-{1}.csv" -f ($state.CurrentName -replace '[\\/:*?"<>|]','_'),(Get-Date -Format 'yyyyMMdd-HHmmss'))
        if($save.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK){try{$state.CurrentRows|Select-Object @{n='時間'
                    e={$_.TimeCreated}},@{n='記錄檔'
                    e={$_.LogName}},@{n='來源'
                    e={$_.ProviderName}},@{n='事件ID'
                    e={$_.Id}},@{n='層級'
                    e={$_.LevelDisplayName}},@{n='描述'
                    e={($_.Message -replace "`r?`n",' ')}}|Export-Csv -Path $save.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                [Windows.Forms.MessageBox]::Show("已匯出 $($state.CurrentRows.Count) 筆事件：`r`n$($save.FileName)",'完成','OK','Information')|Out-Null}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'匯出失敗','OK','Error')|Out-Null}}
        $save.Dispose()
    }.GetNewClosure())
    if($elevate){$elevate.Add_Click({[void](& $restartAdminAction)}.GetNewClosure())}
    $owner=if($script:ActiveFeatureForm){$script:ActiveFeatureForm}else{$script:PanelForm}; [void]$form.ShowDialog($owner)
    $state.Reload=$null; $script:EventViewerForm=$null; $form.Dispose()
}

function Show-WindowsPanel {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form; $script:PanelForm=$form
    $form.Text="OPS-command｜Windows 系統管理面板　v$Script:ToolVersion"
    $form.Size=New-Object Drawing.Size(1320,820)
    $form.MinimumSize=New-Object Drawing.Size(1050,650)
    $form.StartPosition='CenterScreen'
    $form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $sidebar=New-Object Windows.Forms.FlowLayoutPanel
    $sidebar.Dock='Left'
    $sidebar.Width=335
    $sidebar.FlowDirection='TopDown'
    $sidebar.WrapContents=$false
    $sidebar.AutoScroll=$true
    $sidebar.Padding=New-Object Windows.Forms.Padding(12,8,12,12)
    $sidebar.BackColor=[Drawing.Color]::FromArgb(15,23,42)
    $right=New-Object Windows.Forms.Panel; $right.Dock='Fill'; $right.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $head=New-Object Windows.Forms.Panel; $head.Dock='Top'; $head.Height=76; $head.BackColor=[Drawing.Color]::FromArgb(30,58,138)
    $role=if($IsAdmin){'目前權限：系統管理員'}else{'目前權限：一般使用者（修改功能會提示提權）'}
    $title=New-Object Windows.Forms.Label
    $title.Text="OPS-command｜Windows 系統管理面板　v$Script:ToolVersion"
    $title.Font=New-Object Drawing.Font('Microsoft JhengHei UI',16,[Drawing.FontStyle]::Bold)
    $title.ForeColor=[Drawing.Color]::White
    $title.Location=New-Object Drawing.Point(22,10)
    $title.Size=New-Object Drawing.Size(650,34)
    $head.Controls.Add($title)
    $badge=New-Object Windows.Forms.Label
    $badge.Text=$role
    $badge.ForeColor=[Drawing.Color]::FromArgb(219,234,254)
    $badge.Location=New-Object Drawing.Point(24,46)
    $badge.AutoSize=$true
    $head.Controls.Add($badge)
    # 有新版時顯示在權限說明右邊；平常是空的。
    $updateLabel=New-Object Windows.Forms.Label
    $updateLabel.AutoSize=$true
    $updateLabel.ForeColor=[Drawing.Color]::FromArgb(253,224,71)
    $updateLabel.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10,[Drawing.FontStyle]::Bold)
    $updateLabel.Location=New-Object Drawing.Point(($badge.Right+24),46)
    $head.Controls.Add($updateLabel)
    # 開窗後才在背景檢查新版：不拖慢開啟；離線、逾時、任何錯誤都安靜略過，不跳訊息框。
    # 計時器與 Shown 都在這一層建立，共用 $upd 這個 hashtable，不需要巢狀閉包。
    $upd=@{ PS=$null; RS=$null; Async=$null; Timer=(New-Object Windows.Forms.Timer); Worker=$Script:WorkerVersionCheck
            Url="$Script:RawBase/WINDOWS/Win_Admin_Tool.ps1"; Current=$Script:ToolVersion }
    $upd.Timer.Interval=500
    $upd.Timer.Add_Tick({
        if (-not $upd.Async -or -not $upd.Async.IsCompleted) { return }
        $upd.Timer.Stop()
        $res=@()
        try { $res=@($upd.PS.EndInvoke($upd.Async) | ForEach-Object { [string]$_ }) } catch { }
        try { $upd.PS.Dispose(); $upd.RS.Dispose() } catch { }
        $upd.PS=$null
        $hit=@($res | Where-Object { $_ -like 'NEWER *' }) | Select-Object -First 1
        if ($hit -and -not $form.IsDisposed) {
            $ver=$hit.Substring(6)
            $updateLabel.Location=New-Object Drawing.Point(($badge.Right+24),46)
            $updateLabel.Text="有新版 $ver，重新執行一行指令即可更新"
            $form.Text="$($form.Text)　（有新版 $ver）"
        }
    }.GetNewClosure())
    $form.Add_Shown({
        try {
            $upd.RS=[runspacefactory]::CreateRunspace(); $upd.RS.Open()
            $upd.PS=[powershell]::Create(); $upd.PS.Runspace=$upd.RS
            [void]$upd.PS.AddScript($upd.Worker); [void]$upd.PS.AddArgument($upd.Url); [void]$upd.PS.AddArgument($upd.Current)
            $upd.Async=$upd.PS.BeginInvoke()
            $upd.Timer.Start()
        } catch { }
    }.GetNewClosure())
    $form.Add_FormClosed({
        try { $upd.Timer.Stop(); $upd.Timer.Dispose() } catch { }
        # 還在等網路就不等了：背景 runspace 的執行緒不會擋住行程結束
        try { if ($upd.PS) { $upd.PS.BeginStop($null, $null) | Out-Null } } catch { }
    }.GetNewClosure())
    $close=New-Object Windows.Forms.Button
    $close.Text='關閉面板'
    $close.Anchor='Top,Right'
    $close.Location=New-Object Drawing.Point(0,19)
    $close.Size=New-Object Drawing.Size(110,38)
    $close.BackColor=[Drawing.Color]::FromArgb(254,226,226)
    $close.ForeColor=[Drawing.Color]::FromArgb(153,27,27)
    $close.FlatStyle='Flat'
    $close.Add_Click({$form.Close()}.GetNewClosure())
    $head.Controls.Add($close)
    $positionHeaderButtons={ $close.Location=New-Object Drawing.Point([Math]::Max(20,$head.ClientSize.Width-130),19) }.GetNewClosure()
    $head.Add_Resize($positionHeaderButtons); & $positionHeaderButtons

    $homePanel=New-Object Windows.Forms.Panel
    $homePanel.Dock='Fill'
    $homePanel.BackColor=[Drawing.Color]::FromArgb(248,250,252)
    $homePanel.Padding=New-Object Windows.Forms.Padding(34)
    $welcome=New-Object Windows.Forms.Label
    $welcome.Text='選擇左側功能開始'
    $welcome.Location=New-Object Drawing.Point(38,40)
    $welcome.Size=New-Object Drawing.Size(700,44)
    $welcome.Font=New-Object Drawing.Font('Microsoft JhengHei UI',22,[Drawing.FontStyle]::Bold)
    $welcome.ForeColor=[Drawing.Color]::FromArgb(15,23,42)
    $homePanel.Controls.Add($welcome)
    $welcomeSub=New-Object Windows.Forms.Label
    $welcomeSub.Text='功能會在獨立視窗中操作，輸入、狀態與結果都集中在該功能頁面。'
    $welcomeSub.Location=New-Object Drawing.Point(40,92)
    $welcomeSub.Size=New-Object Drawing.Size(800,32)
    $welcomeSub.Font=New-Object Drawing.Font('Microsoft JhengHei UI',11)
    $welcomeSub.ForeColor=[Drawing.Color]::FromArgb(71,85,105)
    $homePanel.Controls.Add($welcomeSub)
    $tiles=New-Object Windows.Forms.FlowLayoutPanel
    $tiles.Location=New-Object Drawing.Point(34,160)
    $tiles.Size=New-Object Drawing.Size(850,390)
    $tiles.Anchor='Top,Bottom,Left,Right'
    $tiles.AutoScroll=$true
    $tiles.FlowDirection='LeftToRight'
    $tiles.WrapContents=$true
    $tiles.BackColor=[Drawing.Color]::FromArgb(248,250,252)
    foreach($tile in @(
        @{Title='先看目前狀態';Body='每個功能視窗上方都會顯示目前的實際設定，改完自動重新讀取。'}
        @{Title='危險操作會再確認';Body='換 RDP Port 有看門狗自動還原；格式化、清除磁碟要再輸入一次才執行。'}
        @{Title='長時間作業不卡畫面';Body='Hyper-V、校時、Windows 更新在背景執行，完成前不能關閉視窗。'}
        @{Title='出錯會告訴你';Body="錯誤會跳出訊息，詳細內容寫在 %TEMP%\OPS-command-error.log。"}
    )){
        $tilePanel=New-Object Windows.Forms.Panel
        $tilePanel.Size=New-Object Drawing.Size(390,105)
        $tilePanel.Margin=New-Object Windows.Forms.Padding(6)
        $tilePanel.BackColor=[Drawing.Color]::White
        $tilePanel.BorderStyle='FixedSingle'
        $tileTitle=New-Object Windows.Forms.Label
        $tileTitle.Text=$tile.Title
        $tileTitle.Location=New-Object Drawing.Point(16,12)
        $tileTitle.Size=New-Object Drawing.Size(350,28)
        $tileTitle.Font=New-Object Drawing.Font('Microsoft JhengHei UI',11,[Drawing.FontStyle]::Bold)
        $tileTitle.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
        $tilePanel.Controls.Add($tileTitle)
        $tileText=New-Object Windows.Forms.Label
        $tileText.Text=$tile.Body
        $tileText.Location=New-Object Drawing.Point(16,45)
        $tileText.Size=New-Object Drawing.Size(350,46)
        $tileText.ForeColor=[Drawing.Color]::FromArgb(71,85,105)
        $tilePanel.Controls.Add($tileText)
        $tiles.Controls.Add($tilePanel)
    }
    $homePanel.Controls.Add($tiles)
    $sizeTiles={ $tiles.Width=[Math]::Max(320,$homePanel.ClientSize.Width-68)
        $tiles.Height=[Math]::Max(180,$homePanel.ClientSize.Height-180) }.GetNewClosure()
    $homePanel.Add_Resize($sizeTiles)
    & $sizeTiles
    $right.Controls.Add($homePanel); $right.Controls.Add($head)

    $addSection={
        param([string]$SectionTitle,[array]$Items)
        # GetNewClosure() 只帶走「當下這一層」的變數；$sidebar 在外層，不先複製下來，
        # 分類標題的點擊事件裡就是 $null，每點一次就跳 .NET 未處理例外框（測試機實測）。
        $sidebar=$sidebar
        $section=New-Object Windows.Forms.Panel
        $section.Width=295
        $section.Height=38
        $section.Margin=New-Object Windows.Forms.Padding(2,7,2,4)
        $section.BackColor=[Drawing.Color]::FromArgb(15,23,42)
        $header=New-Object Windows.Forms.Button
        $header.Text="▸  $SectionTitle  ·  $($Items.Count)"
        $header.Size=New-Object Drawing.Size(295,36)
        $header.Location=New-Object Drawing.Point(0,0)
        $header.FlatStyle='Flat'
        $header.FlatAppearance.BorderSize=0
        $header.TextAlign='MiddleLeft'
        $header.Padding=New-Object Windows.Forms.Padding(10,0,0,0)
        $header.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10,[Drawing.FontStyle]::Bold)
        $header.BackColor=[Drawing.Color]::FromArgb(30,41,59)
        $header.ForeColor=[Drawing.Color]::FromArgb(191,219,254)
        $section.Controls.Add($header)
        $body=New-Object Windows.Forms.Panel
        $body.Location=New-Object Drawing.Point(0,40)
        $body.Size=New-Object Drawing.Size(295,($Items.Count*46))
        $body.BackColor=[Drawing.Color]::FromArgb(15,23,42)
        $body.Visible=$false
        $section.Controls.Add($body)
        foreach($item in $Items){
            $button=New-Object Windows.Forms.Button
            $button.Text=$item.Title
            $button.Size=New-Object Drawing.Size(285,40)
            $button.Location=New-Object Drawing.Point(5,(($body.Controls.Count)*46))
            $button.FlatStyle='Flat'
            $button.FlatAppearance.BorderSize=0
            $button.Font=New-Object Drawing.Font('Microsoft JhengHei UI',9)
            $button.TextAlign='MiddleLeft'
            $button.Padding=New-Object Windows.Forms.Padding(12,0,8,0)
            $button.AutoEllipsis=$true
            switch($item.Style){
                'danger' {$button.BackColor=[Drawing.Color]::FromArgb(127,29,29);$button.ForeColor=[Drawing.Color]::White}
                'success' {$button.BackColor=[Drawing.Color]::FromArgb(21,94,75);$button.ForeColor=[Drawing.Color]::White}
                'info' {$button.BackColor=[Drawing.Color]::FromArgb(37,67,119);$button.ForeColor=[Drawing.Color]::White}
                default {$button.BackColor=[Drawing.Color]::FromArgb(51,65,85);$button.ForeColor=[Drawing.Color]::White}
            }
            $button.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(71,85,105)
            $actionTitle=$item.Title; $action=$item.Action
            # 事件處理程式裡沒接住的例外，在隱藏主控台的面板上等於石沉大海，使用者只看到「按了沒反應」。
            $button.Add_Click({
                try { & $action }
                catch [System.OperationCanceledException] { }
                catch { Show-PanelError -Title $actionTitle -ErrorRecord $_ }
                Close-PanelIfElevated
            }.GetNewClosure())
            $body.Controls.Add($button)
        }
        $header.Add_Click({$body.Visible=-not $body.Visible
            if($body.Visible){$section.Height=40+($Items.Count*46)
                $header.Text="▾  $SectionTitle  ·  $($Items.Count)"}else{$section.Height=38
                $header.Text="▸  $SectionTitle  ·  $($Items.Count)"}
            $sidebar.PerformLayout()}.GetNewClosure())
        $sidebar.Controls.Add($section)
    }.GetNewClosure()

    & $addSection '遠端桌面 RDP' @(
        @{Title='更換 RDP Port（含確認／還原）';Action={Show-RdpPortPanel};Style='danger'}
        @{Title='RDP 多工作階段（開／關）';Action={Show-RdpMultiPanel};Style='info'}
        @{Title='CredSSP 加密預示修復';Action={Show-CredSspPanel};Style='info'}
        @{Title='RDP 登入紀錄';Action={Show-RdpLoginsPanel};Style='success'}
    )
    & $addSection '帳號與安全' @(
        @{Title='帳號鎖定防護';Action={Show-LockoutPolicyPanel};Style='info'}
        @{Title='RDP 暴力破解自動封鎖';Action={Show-RdpGuardPanel};Style='danger'}
        @{Title='內建 Administrator 帳戶';Action={Show-AdminAccountPanel};Style='info'}
        @{Title='變更本機帳號密碼';Action={Set-UserPasswordPanel};Style='info'}
    )
    & $addSection '系統與更新' @(
        @{Title='Windows 更新（停止／還原）';Action={Show-WindowsUpdatePanel};Style='danger'}
        @{Title='Microsoft Store 自動更新';Action={Show-StorePanel};Style='info'}
        @{Title='Hyper-V／VMware 切換';Action={Show-HyperVPanel};Style='info'}
        @{Title='時間與時區';Action={Show-TimePanel};Style='info'}
    )
    & $addSection '網路與防火牆' @(
        @{Title='Ping (ICMP) 設定';Action={Show-PingPanel};Style='info'}
        @{Title='防火牆 Port 管理';Action={Show-PortManagementPanel};Style='info'}
        @{Title='批量新增 IP';Action={Show-BatchIpPanel};Style='success'}
    )
    & $addSection '磁碟管理' @(
        @{Title='變更磁碟機代號';Action={Show-DiskManagementPanel -Mode Change};Style='info'}
        @{Title='格式化磁碟區';Action={Show-DiskManagementPanel -Mode Format};Style='danger'}
        @{Title='清除整顆磁碟';Action={Show-DiskManagementPanel -Mode Wipe};Style='danger'}
        @{Title='唯讀磁碟視覺化';Action={Show-DiskVisualPanel};Style='success'}
    )
    & $addSection '檢查與紀錄' @(
        @{Title='檢查系統現況';Action={Show-StatusPanel};Style='success'}
        @{Title='事件檢視器';Action={Show-EventViewerPanel};Style='success'}
        @{Title='操作記錄';Action={Show-ActionLogPanel};Style='success'}
    )
    & $addSection '自動排程' @(
        @{Title='開啟自動排程管理';Action={Open-TaskManagerPanel};Style='info'}
    )

    $form.Controls.Add($right); $form.Controls.Add($sidebar)
    [void]$form.ShowDialog()
    $script:PanelForm=$null
}

# 最外層的保險：面板建立失敗（缺元件、權限、程式錯誤）時，至少要讓人看到原因。
try {
    Show-WindowsPanel
} catch {
    try { Add-Type -AssemblyName System.Windows.Forms } catch { }
    Show-PanelError -Title '面板無法啟動' -ErrorRecord $_
}
