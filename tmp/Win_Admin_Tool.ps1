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
           Hint='這台有沒有自己重開、突然斷電，或被人關機。'
           Queries=@(
               @{ Log='System'; Provider='Microsoft-Windows-Kernel-Power';             Ids=@(41)   }
               @{ Log='System'; Provider='EventLog';                                   Ids=@(6008) }
               @{ Log='System'; Provider='User32';                                     Ids=@(1074) }
               @{ Log='System'; Provider='Microsoft-Windows-WER-SystemErrorReporting'; Ids=@(1001) }
           ) }
        @{ Key='2'; Name='藍畫面與硬體錯誤'; NeedAdmin=$false
           Hint='有沒有當機藍畫面，或 CPU、記憶體回報硬體錯誤。'
           Queries=@(
               @{ Log='System'; Provider='BugCheck';                        Ids=@(1001) }
               @{ Log='System'; Provider='Microsoft-Windows-WHEA-Logger';   Ids=@(17,18,19,20,47) }
           ) }
        @{ Key='3'; Name='磁碟與儲存'; NeedAdmin=$false
           Hint='硬碟有沒有壞軌、檔案系統有沒有損毀。有的話要盡快備份。'
           Queries=@(
               @{ Log='System'; Provider='disk';                     Ids=@(7,11,51,153) }
               @{ Log='System'; Provider='Microsoft-Windows-Ntfs';   Ids=@(55,98,130,137) }
               @{ Log='Application'; Provider='Wininit';             Ids=@(1001) }
           ) }
        @{ Key='4'; Name='服務異常'; NeedAdmin=$false
           Hint='背景服務有沒有啟動失敗、意外停止，或被改了設定、裝了新服務。'
           Queries=@(
               @{ Log='System'; Provider='Service Control Manager'; Ids=@(7000,7001,7011,7022,7023,7024,7031,7034,7040,7045) }
           ) }
        @{ Key='5'; Name='應用程式當機 / 無回應'; NeedAdmin=$false
           Hint='有沒有程式當掉或沒有回應。'
           Queries=@(
               @{ Log='Application'; Provider='Application Error';        Ids=@(1000) }
               @{ Log='Application'; Provider='Application Hang';         Ids=@(1002) }
               @{ Log='Application'; Provider='.NET Runtime';             Ids=@(1026) }
               @{ Log='Application'; Provider='Windows Error Reporting';  Ids=@(1001) }
           ) }
        @{ Key='6'; Name='登入與帳號'; NeedAdmin=$true
           Hint='有沒有人登入失敗、帳號被鎖；誰從哪個 IP 用遠端桌面連進來。'
           Queries=@(
               @{ Log='Security'; Ids=@(4625,4740) }
               @{ Log='Security'; Ids=@(4648) }
               @{ Log='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Ids=@(1149) }
               @{ Log='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational';     Ids=@(21,23,24,25) }
           ) }
        @{ Key='7'; Name='Windows 更新'; NeedAdmin=$false
           Hint='Windows 更新有沒有裝成功或失敗。'
           Queries=@(
               @{ Log='System'; Provider='Microsoft-Windows-WindowsUpdateClient'; Ids=@(19,20,43) }
           ) }
    )
}

# 背景查詢（另一個 runspace）：每一組 Jobs = @{ Key; Queries }，結果放進 $Sync[Key] = @{ Rows; Problems }。
# 結果用共用的 hashtable 帶回來，因為 Start-UiBackground 的輸出會被轉成字串，事件物件要原樣保留。
# Problems 跟「沒有紀錄」是兩回事，呼叫端必須分開呈現。
$Script:WorkerEvents = @'
param([object[]]$Jobs, [int]$Days, $Sync)
$start = (Get-Date).AddDays(-$Days)
foreach ($j in $Jobs) {
    $rows = New-Object System.Collections.ArrayList
    $probs = New-Object System.Collections.ArrayList
    foreach ($q in $j.Queries) {
        $f = @{ LogName = $q.Log; StartTime = $start }
        if ($q.Provider) { $f['ProviderName'] = $q.Provider }
        if ($q.Ids)      { $f['Id'] = $q.Ids }
        try { foreach ($e in @(Get-WinEvent -FilterHashtable $f -MaxEvents 200 -ErrorAction Stop)) { [void]$rows.Add($e) } }
        catch {
            # NoMatchingEventsFound = 這段期間沒有這種事件；NoMatchingProvidersFound = 這台從來沒發生過、
            # 來源還沒註冊（實測：沒藍屏過的機器沒有 BugCheck）。兩個都是「沒有事件」，不是問題。
            # 其他的（沒權限、記錄檔不存在）一定要讓使用者看到。
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.FullyQualifiedErrorId -like 'NoMatchingProvidersFound*') { continue }
            $src = $q.Log; if ($q.Provider) { $src += " / $($q.Provider)" }
            [void]$probs.Add("$src：$($_.Exception.Message)")
        }
    }
    # 每個查詢各自最多 200 筆，合併後不再截斷：大量的一般紀錄（例如 SSH 登入的 4648）不能把要注意的擠掉
    $Sync[$j.Key] = @{ Rows = @($rows | Sort-Object TimeCreated -Descending); Problems = @($probs) }
}
'@

# 白話說明：鍵是「來源（去掉 Microsoft-Windows-）|事件 ID」，值是 @(這代表什麼, 建議怎麼做, 要不要注意)；
# 要不要注意填 'level' 的，依事件本身的層級（嚴重／錯誤／警告才算）。內容都對照過測試機上的實際訊息。
# 「要注意」的才會讓首頁卡片變黃；登入成功、服務設定變更這類一般紀錄只列出來，不算異常。
$Script:EventExplain = @{
    'Kernel-Power|41'                  = @('沒有正常關機就重新啟動（突然斷電、當機或被強制關機）', '對照同一時間有沒有藍畫面；常發生就檢查電源、UPS 或機器過熱', $true)
    'EventLog|6008'                    = @('上一次關機不是正常關機', '通常和「沒有正常關機」一起出現，對照時間找原因', $true)
    'User32|1074'                      = @('有人或程式要求關機／重新開機', '看是哪個帳號、哪個程式；不是你做的就要查', $false)
    'WER-SystemErrorReporting|1001'    = @('電腦曾經藍畫面，重開後回報了錯誤', '詳細內容有停止碼，拿停止碼查原因；常發生就更新驅動、檢查記憶體', $true)
    'BugCheck|1001'                    = @('電腦曾經藍畫面（當機）', '詳細內容有停止碼；常發生就更新驅動、檢查記憶體', $true)
    'WHEA-Logger|17'                   = @('硬體回報了可以自動修正的錯誤（PCIe）', '偶爾一次可以不管；一直出現就請機房或廠商檢查硬體', $true)
    'WHEA-Logger|18'                   = @('硬體發生嚴重錯誤（CPU、記憶體或主機板）', '這通常會造成當機，請機房或廠商檢查硬體', $true)
    'WHEA-Logger|19'                   = @('CPU 回報了可以自動修正的錯誤', '偶爾一次可以不管；一直出現就請機房或廠商檢查 CPU', $true)
    'WHEA-Logger|20'                   = @('硬體回報了錯誤（CPU 或主機板）', '請機房或廠商檢查硬體', $true)
    'WHEA-Logger|47'                   = @('記憶體回報了可以自動修正的錯誤', '偶爾一次可以不管；一直出現代表記憶體快壞了', $true)
    'disk|7'                           = @('硬碟有壞軌（有區塊讀不到）', '盡快備份；用 CrystalDiskInfo 看硬碟健康度，準備換硬碟', $true)
    'disk|11'                          = @('磁碟控制器回報錯誤', '檢查硬碟線材、控制器或虛擬主機平台的儲存', $true)
    'disk|51'                          = @('寫入硬碟時發生錯誤', '盡快備份，檢查硬碟健康度', $true)
    'disk|153'                         = @('讀寫硬碟要重試才成功', '偶爾可以不管；常出現代表硬碟或儲存變慢、快壞了', $true)
    'Ntfs|55'                          = @('檔案系統結構損毀', '盡快備份，排時間執行 chkdsk /f 修復', $true)
    # 98 實測是「磁碟區 D: 的健康情況良好，不需要採取任何動作」（資訊），有問題時才是警告以上，所以看層級
    'Ntfs|98'                          = @('磁碟健康檢查的結果', '描述寫的不是「狀況良好」就要排時間執行 chkdsk', 'level')
    'Ntfs|130'                         = @('檔案系統自己修好了一個問題', '留意是不是反覆出現', $false)
    'Ntfs|137'                         = @('檔案系統的交易記錄出錯', '備份資料並檢查硬碟', $true)
    'Wininit|1001'                     = @('開機時執行過磁碟檢查（chkdsk）', '詳細內容可以看修了什麼', $false)
    'Service Control Manager|7000'     = @('服務啟動失敗', '看是哪個服務；是你需要的服務就要處理，不認得的通常可以不管', $true)
    'Service Control Manager|7001'     = @('服務沒啟動，因為它依賴的服務沒起來', '先找出它依賴的那個服務為什麼沒起來', $true)
    'Service Control Manager|7011'     = @('服務沒有在時間內回應', '偶爾一次可以不管；常發生代表機器太忙或那個服務有問題', $true)
    'Service Control Manager|7022'     = @('服務啟動時卡住', '看是哪個服務；重要的服務要查原因', $true)
    'Service Control Manager|7023'     = @('服務因為錯誤而停止', '看是哪個服務；重要的服務要查原因', $true)
    'Service Control Manager|7024'     = @('服務因為錯誤而停止', '看是哪個服務；重要的服務要查原因', $true)
    'Service Control Manager|7031'     = @('服務意外停止（可能會自動重新啟動）', '一直出現代表那個服務會反覆當掉', $true)
    'Service Control Manager|7034'     = @('服務意外停止', '一直出現代表那個服務會反覆當掉', $true)
    'Service Control Manager|7040'     = @('服務的啟動方式被改了', '如果是你停用 Windows 更新後又被改回來，就是系統自己改的', $false)
    'Service Control Manager|7045'     = @('這台安裝了新的服務', '確認是你裝的軟體；不認得的服務可能是惡意程式', $false)
    'Application Error|1000'           = @('程式當掉了', '常發生就更新或重裝那個程式', $true)
    'Application Hang|1002'            = @('程式沒有回應，被關掉了', '常發生就更新或重裝那個程式', $true)
    '.NET Runtime|1026'                = @('.NET 程式發生錯誤而結束', '常發生就更新或重裝那個程式', $true)
    'Windows Error Reporting|1001'     = @('Windows 記錄了一次程式或系統錯誤', '通常和「程式當掉」一起出現，對照時間看', $false)
    'Security-Auditing|4625'           = @('登入失敗（密碼錯或帳號不存在）', '同一個來源一直失敗代表有人在猜密碼，可以開「RDP 暴力破解自動封鎖」', $true)
    'Security-Auditing|4740'           = @('帳號被鎖定了', '多半是有人一直猜密碼；到「帳號鎖定防護」看設定', $true)
    'Security-Auditing|4648'           = @('用另一組帳號密碼登入（例如「以其他使用者身分執行」、連網路磁碟）', '確認是你自己做的', $false)
    'TerminalServices-RemoteConnectionManager|1149' = @('有人用遠端桌面通過了帳號密碼驗證', '確認來源 IP 是你認得的', $false)
    'TerminalServices-LocalSessionManager|21' = @('遠端桌面登入', '確認帳號與來源是你認得的', $false)
    'TerminalServices-LocalSessionManager|23' = @('遠端桌面登出', '', $false)
    'TerminalServices-LocalSessionManager|24' = @('遠端桌面中斷連線', '', $false)
    'TerminalServices-LocalSessionManager|25' = @('遠端桌面重新連線', '確認帳號與來源是你認得的', $false)
    'WindowsUpdateClient|19'           = @('更新安裝成功', '', $false)
    'WindowsUpdateClient|20'           = @('更新安裝失敗', '詳細內容有錯誤碼；稍後再試，或到 Windows Update 手動安裝', $true)
    'WindowsUpdateClient|43'           = @('開始安裝更新', '', $false)
}

# 同步版（「RDP 登入紀錄」用，只查少量）：跟背景版用同一份程式碼，結果直接回傳
function Invoke-EventQuery {
    param([array]$Queries, [int]$Days = 7, [int]$Max = 50)
    $sync = @{}
    & ([scriptblock]::Create($Script:WorkerEvents)) @(@{ Key = 'q'; Queries = $Queries }) $Days $sync
    @{ Rows = @($sync.q.Rows | Select-Object -First $Max); Problems = @($sync.q.Problems) }
}

function Get-EventExplain {
    param($Ev)
    $p = ([string]$Ev.ProviderName) -replace '^Microsoft-Windows-', ''
    # Windows 錯誤報告 1001 什麼都報（更新、市集、元件安裝…），只有程式當掉／沒回應那幾種才跟「程式」有關。
    # 第 3 欄是類型、第 6 欄是程式；其他類型的內容是一串代碼，對新手沒有意義，統一說成「Windows 元件」。
    if ($p -eq 'Windows Error Reporting' -and $Ev.Id -eq 1001) {
        $type = try { [string]$Ev.Properties[2].Value } catch { '' }
        if ($type -match '^(APPCRASH|AppHang|BEX|CLR20r3|MoAppCrash|MoAppHang)') { return @{ What = '程式出錯的錯誤報告'; Do = '通常和「程式當掉／沒有回應」一起出現，看同一時間那筆'; Warn = $false } }
        return @{ What = 'Windows 元件的錯誤報告（更新、市集等）'; Do = '通常不用處理；Windows 更新一直失敗再看「Windows 更新」那一類'; Warn = $false }
    }
    $e = $Script:EventExplain["$p|$($Ev.Id)"]
    if ($e) { return @{ What = $e[0]; Do = $e[1]; Warn = $(if ($e[2] -eq 'level') { $Ev.Level -in 1, 2, 3 } else { [bool]$e[2] }) } }
    # 表裡沒有的（自訂查詢）：用事件描述第一行，層級是嚴重／錯誤／警告的算要注意
    @{ What = (Get-EventBrief $Ev -Width 80); Do = ''; Warn = ($Ev.Level -in 1, 2, 3) }
}

# 從事件內容抽出「是誰、哪個服務、哪個程式」，接在白話說明後面
function Get-EventSubject {
    param($Ev)
    try { $x = [xml]$Ev.ToXml() } catch { return '' }
    $d = @{}
    $first = $null
    $vals = New-Object System.Collections.ArrayList
    foreach ($n in @($x.Event.EventData.Data)) {
        if (-not $n) { continue }
        $t = if ($n -is [string]) { $n } else { [string]$n.'#text' }
        if ($null -eq $first) { $first = $t }
        [void]$vals.Add($t)
        if ($n -isnot [string] -and $n.Name) { $d[$n.Name] = $t }
    }
    if ($x.Event.UserData -and $x.Event.UserData.FirstChild) { foreach ($c in $x.Event.UserData.FirstChild.ChildNodes) { $d[$c.LocalName] = [string]$c.InnerText } }
    $ip = { param($a) if ($a -and $a -ne '-' -and $a -ne '::1' -and $a -ne '127.0.0.1') { "，來源 $a" } else { '' } }
    switch ([int]$Ev.Id) {
        { $_ -in 7000, 7001, 7011, 7022, 7023, 7024, 7031, 7034, 7040 } { if ($d.param1) { return "服務「$($d.param1)」" } }
        7045 { if ($d.ServiceName) { return "服務「$($d.ServiceName)」" } }
        1074 { if ($d.param7) { return "$($d.param7)，用 $((([string]$d.param1) -split ' ')[0] | Split-Path -Leaf)$(if ($d.param3) { "，原因：$($d.param3)" })" } }
        { $_ -in 55, 98, 130, 137 } { if ($d.DriveName) { return "磁碟 $($d.DriveName)" } }
        { $_ -in 1000, 1002 } { if ($first) { return "程式 $first" } }
        # Windows 錯誤報告 1001：只有程式當掉／沒回應的才抽程式名，其他類型的代碼不顯示
        1001 { if ($Ev.ProviderName -eq 'Windows Error Reporting' -and $vals.Count -ge 6 -and $vals[5] -and $vals[2] -match '^(APPCRASH|AppHang|BEX|CLR20r3|MoAppCrash|MoAppHang)') { return "程式 $($vals[5])" } }
        4625 { return "帳號 $($d.TargetUserName)$(& $ip $d.IpAddress)" }
        { $_ -in 4740, 4648 } { if ($d.TargetUserName) { return "帳號 $($d.TargetUserName)" } }
        1149 { return "帳號 $($d.Param1)$(& $ip $d.Param3)" }
        { $_ -in 21, 23, 24, 25 } { if ($d.User) { return "帳號 $($d.User)$(& $ip $d.Address)" } }
        { $_ -in 19, 20, 43 } { if ($d.updateTitle) { return "$($d.updateTitle)$(if ($d.errorCode) { "（錯誤碼 $($d.errorCode)）" })" } }
    }
    ''
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
# 只是讀取的作業（事件檢查、查已安裝的軟體）加 -AllowClose：關視窗就直接停掉背景作業，不用等。
function Start-UiBackground {
    param([Windows.Forms.Form]$Form, [string]$Script, [object[]]$Arguments = @(), [scriptblock]$OnDone, [switch]$AllowClose)
    $allowClose = [bool]$AllowClose
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
        if (-not $job.Done -and $allowClose) {
            # 唯讀作業：停掉、不再回呼（視窗都要關了）
            $job.Done = $true
            try { $job.Timer.Stop(); $job.Timer.Dispose() } catch { }
            try { [void]$job.PS.BeginStop($null, $null) } catch { }
            return
        }
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

# 稽核「登入」的失敗沒開，就不會有 4625，守護等於沒作用。
# auditpol /r 的欄位名稱與值跟著主控台字碼頁走：字碼頁 950 是「包含設定／成功與失敗」，
# UTF-8 才是英文「Inclusion Setting／Success and Failure」（測試機實測）。所以不靠欄位名稱，
# 用 GUID 找那一行、取第 5 欄（電腦名稱,原則目標,子類別,GUID,包含設定,排除設定），中英文都認。
function Get-RdpGuardAudit {
    $raw = & auditpol.exe /get "/subcategory:$($Script:RdpGuardAuditGuid)" /r 2>&1
    if ($LASTEXITCODE -ne 0) { return @{ Known = $false; Failure = $false; Text = '讀不到（需要管理員權限）' } }
    $line = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_ -like "*$($Script:RdpGuardAuditGuid)*" }) | Select-Object -First 1
    $cols = if ($line) { $line.Split(',') } else { @() }
    if ($cols.Count -lt 5) { return @{ Known = $false; Failure = $false; Text = "看不懂 auditpol 的輸出：$(($raw | Select-Object -First 2) -join ' / ')" } }
    $set = $cols[4].Trim()
    @{ Known = $true; Failure = ($set -match 'Failure|失敗'); Text = $set }
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
    # 一定要包 @()：只有一項時函式回傳的是字串，下面的 $list + $auto 會變成字串相加，
    # 整份白名單黏成一個看不懂的字串，自己的 IP 其實不在白名單裡（測試機實測抓到）。
    $list = @(Split-RdpGuardList $v.Whitelist)
    $bad = @($list | Where-Object {
        if ($_ -eq '-') { return $false }
        $p = $_ -split '/'; $a = $null; $bits = -1
        # .NET 會把 1.2.3、5 這種打錯的也當成 IP（1.2.0.3、0.0.0.5），IPv4 要求完整四段
        if ($p.Count -gt 2 -or -not [Net.IPAddress]::TryParse($p[0], [ref]$a)) { return $true }
        if ($p[0] -notmatch ':' -and $p[0] -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $true }
        if ($p.Count -eq 1) { return $false }
        $max = if ($a.AddressFamily -eq 'InterNetworkV6') { 128 } else { 32 }
        -not ([int]::TryParse($p[1], [ref]$bits) -and $bits -ge 0 -and $bits -le $max)
    })
    if ($bad.Count) { throw "白名單裡有看不懂的項目：$($bad -join '、')（只接受 IP、CIDR 或 -）" }
    $auto = @(@('127.0.0.1', '::1', '-') + @(Get-RdpGuardConnectedIps) | Where-Object { $list -notcontains $_ })
    @{ Whitelist = @($list) + @($auto); Auto = $auto; Scope = $(if ($v.Scope -like '全部*') { 'All' } else { 'Rdp' })
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

# ---- 常用軟體安裝（winget，E6；對應 Linux APPS）----
# 只用 winget：官方 winget 來源（--source winget）、--exact --id 指定套件，不自己維護下載網址與 SHA256；
# 安裝檔的 SHA256 由 winget 依官方套件清單核對，不加 --ignore-security-hash。
# 測試機實測（zh-TW、winget 1.29）：
#   - winget 不管主控台字碼頁，一律輸出 UTF-8。PowerShell 5.1 直接呼叫會把中文解成亂碼，
#     所以用 Process 直接讀、指定 UTF-8（也不去改 [Console]::OutputEncoding，見 W1）。
#   - 表格欄位依「顯示寬度」對齊（中文字算 2 格），欄與欄之間可能只隔 1 個空白、名稱本身也有空白，
#     所以照標題列的欄位起點切，不用空白切。
#   - 已安裝清單用 winget export（JSON，ID 與版本都精確），不解析 winget list 的表格。
#   - 每次呼叫都可能先更新來源，慢的時候一次十幾秒，所以全部放背景。
#   - 安裝後回頭用 export 確認真的在已安裝清單裡，不只看 winget 的結束碼。
$Script:AppsRecommended = @(
    @{ Id = 'Insecure.Nmap';                     Name = 'Nmap';                Use = '掃描 Port、確認服務有沒有開' }
    @{ Id = 'leeter.WinMTR';                     Name = 'WinMTR';              Use = 'ping + traceroute，看網路是哪一段掉包' }
    @{ Id = 'Microsoft.Sysinternals.Suite';      Name = 'Sysinternals Suite';  Use = '微軟官方工具組：Process Explorer、Autoruns、TCPView…' }
    @{ Id = 'WiresharkFoundation.Wireshark';     Name = 'Wireshark';           Use = '抓封包。抓包驅動 Npcap 要另外手動安裝' }
    @{ Id = 'PuTTY.PuTTY';                       Name = 'PuTTY';               Use = 'SSH / Telnet 連線' }
    @{ Id = 'WinSCP.WinSCP';                     Name = 'WinSCP';              Use = 'SFTP / SCP 傳檔' }
    @{ Id = '7zip.7zip';                         Name = '7-Zip';               Use = '壓縮／解壓縮' }
    @{ Id = 'Notepad++.Notepad++';               Name = 'Notepad++';           Use = '文字編輯器' }
    @{ Id = 'Git.Git';                           Name = 'Git';                 Use = '版本控制（含 Git Bash）' }
    @{ Id = 'Microsoft.PowerShell';              Name = 'PowerShell 7';        Use = '新版 PowerShell，和內建的 5.1 並存' }
    @{ Id = 'Microsoft.WindowsTerminal';         Name = 'Windows Terminal';    Use = '多分頁終端機' }
    @{ Id = 'voidtools.Everything';              Name = 'Everything';          Use = '瞬間找到檔案' }
    @{ Id = 'JAMSoftware.TreeSize.Free';         Name = 'TreeSize Free';       Use = '看哪個資料夾最佔空間' }
    @{ Id = 'CrystalDewWorld.CrystalDiskInfo';   Name = 'CrystalDiskInfo';     Use = '看硬碟健康度（SMART）' }
    @{ Id = 'Google.Chrome';                     Name = 'Google Chrome';       Use = '瀏覽器' }
    @{ Id = 'Mozilla.Firefox';                   Name = 'Mozilla Firefox';     Use = '瀏覽器（winget 裝的是英文版，可在設定裡加中文）' }
    @{ Id = 'Microsoft.VCRedist.2015+.x64';      Name = 'VC++ 2015-2022 執行環境 (x64)'; Use = '很多程式需要的執行環境' }
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.8'; Name = '.NET 8 桌面執行環境'; Use = '.NET 8 的視窗程式需要' }
    @{ Id = 'Prometheus.WindowsExporter';        Name = 'windows_exporter';    Use = 'Prometheus 監控。裝完會有服務監聽 9182 Port' }
)

# 背景執行（另一個 runspace，看不到這支腳本的函式）。
# 輸出：一般文字照印；PKG<tab>ID<tab>版本 = 已安裝；ROW<tab>名稱<tab>ID<tab>版本<tab>相符 = 搜尋結果；
#       SHOW<tab>文字 = 套件資訊；RES<tab>ID<tab>結束碼 = 安裝結果；NONE = 搜尋沒結果；WARNSRC = 來源更新失敗
$Script:WorkerApps = @'
param([string]$Mode, [string]$Arg, [string]$Winget)
$ErrorActionPreference = 'Stop'
$script:SrcWarn = $false
function Invoke-Wg([string]$ArgLine) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Winget; $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    # 轉圈圈與進度列用 \r 覆寫同一行：只留最後一段；█▒ 的進度條整行丟掉。
    # 行尾本身是 \r\n，要先去掉行尾的 \r 再切，不然「最後一段」永遠是空字串（實測整份輸出都被丟掉）
    $lines = @(($out + "`n" + $errTask.Result) -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].TrimEnd() } |
        Where-Object { $_ -and $_ -notmatch '[█▒]' -and $_ -notmatch '^\s*[-\\|/]\s*$' })
    $warn = @($lines | Where-Object { $_ -match '^(嘗試更新來源失敗|Failed in attempting to update the source)' })
    if ($warn.Count) { $script:SrcWarn = $true }
    @{ Code = $p.ExitCode; Lines = @($lines | Where-Object { $warn -notcontains $_ }) }
}
function Format-Code([int]$Code) { '0x{0:X8}' -f $Code }
function Get-CharWidth([char]$c) {
    $n = [int]$c
    if (($n -ge 0x1100 -and $n -le 0x115F) -or ($n -ge 0x2E80 -and $n -le 0xA4CF) -or ($n -ge 0xAC00 -and $n -le 0xD7A3) -or
        ($n -ge 0xF900 -and $n -le 0xFAFF) -or ($n -ge 0xFE30 -and $n -le 0xFE4F) -or ($n -ge 0xFF00 -and $n -le 0xFF60) -or
        ($n -ge 0xFFE0 -and $n -le 0xFFE6)) { 2 } else { 1 }
}
# 表格：找 ----- 那一行，上一行是標題；照標題每一欄的起點（顯示寬度）切每一列
function Get-Table([string[]]$Lines) {
    $d = -1
    for ($k = 1; $k -lt $Lines.Count; $k++) { if ($Lines[$k] -match '^-{10,}$') { $d = $k; break } }
    if ($d -lt 1) { return }
    $starts = @(); $col = 0; $prevSpace = $true
    foreach ($ch in $Lines[$d - 1].ToCharArray()) {
        if ($ch -ne ' ' -and $prevSpace) { $starts += $col }
        $prevSpace = ($ch -eq ' '); $col += Get-CharWidth $ch
    }
    for ($k = $d + 1; $k -lt $Lines.Count; $k++) {
        $cells = New-Object string[] ($starts.Count)
        $col = 0; $ci = 0; $sb = New-Object Text.StringBuilder
        foreach ($ch in $Lines[$k].ToCharArray()) {
            while ($ci + 1 -lt $starts.Count -and $col -ge $starts[$ci + 1]) { $cells[$ci] = $sb.ToString().Trim(); [void]$sb.Clear(); $ci++ }
            [void]$sb.Append($ch); $col += Get-CharWidth $ch
        }
        $cells[$ci] = $sb.ToString().Trim()
        , $cells
    }
}
function Get-Installed {
    $f = Join-Path ([IO.Path]::GetTempPath()) ("ops-winget-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $r = Invoke-Wg "export --output `"$f`" --source winget --include-versions --accept-source-agreements --disable-interactivity"
        if (-not (Test-Path $f)) { throw "winget export 沒有產生已安裝清單（結束碼 $(Format-Code $r.Code)）：$(($r.Lines | Select-Object -Last 3) -join ' / ')" }
        $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in @($j.Sources | ForEach-Object { $_.Packages })) { "PKG`t$($p.PackageIdentifier)`t$($p.Version)" }
    } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
$idRule = '^[A-Za-z0-9][\w\.\-\+]*$'
switch ($Mode) {
    'installed' { Get-Installed }
    'search' {
        $q = $Arg.Replace('"', '').Trim()
        $r = Invoke-Wg "search --query `"$q`" --source winget --accept-source-agreements --disable-interactivity"
        if ($r.Code -eq -1978335212) { 'NONE' }
        elseif ($r.Code -ne 0) { throw "搜尋失敗（結束碼 $(Format-Code $r.Code)）：$(($r.Lines | Select-Object -Last 3) -join ' / ')" }
        else {
            foreach ($c in @(Get-Table $r.Lines)) {
                if ($c.Count -ge 3 -and $c[1] -match '^\S+\.\S+$') { "ROW`t$($c[0])`t$($c[1])`t$($c[2])`t$(if ($c.Count -ge 4) { $c[3] })" }
            }
        }
    }
    'show' {
        if ($Arg -notmatch $idRule) { throw "套件 ID 格式不對：$Arg" }
        $r = Invoke-Wg "show --exact --id `"$Arg`" --source winget --accept-source-agreements --disable-interactivity"
        if ($r.Code -ne 0) { throw "查不到 $Arg（結束碼 $(Format-Code $r.Code)）：$(($r.Lines | Select-Object -Last 3) -join ' / ')" }
        $r.Lines | ForEach-Object { "SHOW`t$_" }
    }
    'install' {
        $ids = @($Arg.Split(',') | Where-Object { $_ })
        foreach ($id in $ids) { if ($id -notmatch $idRule) { throw "套件 ID 格式不對：$id" } }
        foreach ($id in $ids) {
            "▶ 安裝 $id …"
            $r = Invoke-Wg "install --exact --id `"$id`" --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
            $r.Lines | Select-Object -Last 8 | ForEach-Object { "    $_" }
            "RES`t$id`t$($r.Code)"
        }
        # 回頭確認：重新列出已安裝的套件，不只看結束碼
        Get-Installed
    }
    default { throw "看不懂的動作：$Mode" }
}
if ($script:SrcWarn) { 'WARNSRC' }
'@

function Get-AppsWinget {
    $c = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

# 找不到 winget 時給人看的說明。Windows Server 上沒有驗證過的安裝方式，不寫步驟（E3 先不測）。
function Get-AppsWingetHelp {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os -and $os.ProductType -ne 1) {
        return "找不到 winget。這台是 $($os.Caption)：Windows Server 上沒有驗證過的 winget 安裝方式，這個功能目前不支援，請改用手動下載安裝。"
    }
    "找不到 winget。winget 是 Windows「應用程式安裝程式」（App Installer）的一部分，Windows 10 1809 以後與 Windows 11 都能用：`r`n" +
    "　1. 按「開啟 Microsoft Store」，安裝或更新「應用程式安裝程式」`r`n" +
    "　2. 裝好後按「重新偵測」`r`n" +
    "目前執行帳號：$([Security.Principal.WindowsIdentity]::GetCurrent().Name)。winget 是跟著「每個帳號」安裝的：如果你是輸入另一個管理員帳號的密碼來提權，" +
    "那個帳號可能沒有 winget。請用那個帳號登入 Windows 一次並更新「應用程式安裝程式」，或改用本身就是管理員的帳號執行這個工具。"
}

function Show-AppsPanel {
    $win  = New-UiWindow -Title '常用軟體安裝' -Subtitle '用 winget（微軟官方的套件管理工具）安裝；下載網址與 SHA256 由 winget 依官方套件清單核對' -Width 1080 -Height 820
    $form = $win.Form
    # 閉包裡的 $Script: 指的不是這支腳本，要用的值先在這一層取出來
    $worker = $Script:WorkerApps
    $textColor = $Script:Ui.Text
    $ctx = @{ Form = $form; Winget = (Get-AppsWinget); Installed = @{}; Busy = $false; Buttons = @(); Then = $null; Pending = $null }

    # ---- 上方：winget 狀態（找不到時顯示說明與按鈕）
    $top = New-Object Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.AutoSize = $true; $top.AutoSizeMode = 'GrowAndShrink'; $top.FlowDirection = 'TopDown'; $top.WrapContents = $false
    $info = New-Object Windows.Forms.Label
    $info.AutoSize = $true; $info.MaximumSize = New-Object Drawing.Size(1010, 0); $info.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $top.Controls.Add($info)
    $noWg = New-Object Windows.Forms.FlowLayoutPanel
    $noWg.AutoSize = $true; $noWg.AutoSizeMode = 'GrowAndShrink'
    $btnStore = New-UiButton '開啟 Microsoft Store' primary 200
    $btnDetect = New-UiButton '重新偵測' light 120
    $noWg.Controls.Add($btnStore); $noWg.Controls.Add($btnDetect)
    $top.Controls.Add($noWg)

    # ---- 中間：推薦清單 / 搜尋 兩個分頁
    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $newGrid = {
        $g = New-Object Windows.Forms.DataGridView
        $g.Dock = 'Fill'; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false
        $g.RowHeadersVisible = $false; $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false
        $g.BackgroundColor = [Drawing.Color]::White; $g.BorderStyle = 'None'; $g.AutoSizeColumnsMode = 'Fill'
        $g.ColumnHeadersHeightSizeMode = 'AutoSize'; $g.RowTemplate.Height = 28
        $g
    }
    $addCol = {
        param($g, [string]$Name, [string]$Header, [int]$Weight, [switch]$Check)
        $c = if ($Check) { New-Object Windows.Forms.DataGridViewCheckBoxColumn } else { New-Object Windows.Forms.DataGridViewTextBoxColumn }
        $c.Name = $Name; $c.HeaderText = $Header; $c.FillWeight = $Weight; $c.ReadOnly = -not $Check
        [void]$g.Columns.Add($c)
    }

    $tab1 = New-Object Windows.Forms.TabPage; $tab1.Text = '推薦清單'; $tab1.Padding = New-Object Windows.Forms.Padding(8)
    $grid1 = & $newGrid
    & $addCol $grid1 'Pick' '安裝' 8 -Check
    & $addCol $grid1 'Name' '軟體' 26
    & $addCol $grid1 'Use' '用途' 46
    & $addCol $grid1 'State' '狀態' 22
    & $addCol $grid1 'Id' 'winget ID' 34
    foreach ($a in $Script:AppsRecommended) { [void]$grid1.Rows.Add($false, $a.Name, $a.Use, '', $a.Id) }
    # 勾選框點一下就生效（預設要離開儲存格才算）
    $grid1.Add_CurrentCellDirtyStateChanged({ if ($grid1.IsCurrentCellDirty) { [void]$grid1.CommitEdit('CurrentCellChange') } }.GetNewClosure())
    $bar1 = New-Object Windows.Forms.FlowLayoutPanel
    $bar1.Dock = 'Bottom'; $bar1.Height = 50; $bar1.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 0)
    $btnInstall = New-UiButton '安裝勾選的軟體' success 180
    $btnRefresh = New-UiButton '重新檢查已安裝' light 160
    $bar1.Controls.Add($btnInstall); $bar1.Controls.Add($btnRefresh)
    $tab1.Controls.Add($grid1); $tab1.Controls.Add($bar1)

    $tab2 = New-Object Windows.Forms.TabPage; $tab2.Text = '搜尋其他軟體'; $tab2.Padding = New-Object Windows.Forms.Padding(8)
    $sbar = New-Object Windows.Forms.FlowLayoutPanel
    $sbar.Dock = 'Top'; $sbar.Height = 48
    $query = New-Object Windows.Forms.TextBox; $query.Width = 320; $query.Margin = New-Object Windows.Forms.Padding(0, 6, 10, 0)
    $btnSearch = New-UiButton '搜尋' primary 100
    $sNote = New-Object Windows.Forms.Label
    $sNote.AutoSize = $true; $sNote.Margin = New-Object Windows.Forms.Padding(6, 9, 0, 0)
    $sNote.Text = '只搜尋官方 winget 來源。搜尋結果不含發行者，安裝前會先查出來給你確認。'
    $sbar.Controls.Add($query); $sbar.Controls.Add($btnSearch); $sbar.Controls.Add($sNote)
    $grid2 = & $newGrid
    & $addCol $grid2 'Name' '名稱' 30
    & $addCol $grid2 'Id' 'winget ID' 36
    & $addCol $grid2 'Ver' '版本' 14
    & $addCol $grid2 'Match' '相符' 18
    & $addCol $grid2 'State' '這台' 16
    $bar2 = New-Object Windows.Forms.FlowLayoutPanel
    $bar2.Dock = 'Bottom'; $bar2.Height = 50; $bar2.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 0)
    $btnInstall2 = New-UiButton '安裝選取的軟體' success 180
    $bar2.Controls.Add($btnInstall2)
    $tab2.Controls.Add($grid2); $tab2.Controls.Add($sbar); $tab2.Controls.Add($bar2)
    $tabs.TabPages.Add($tab1); $tabs.TabPages.Add($tab2)

    # ---- 下方：結果區
    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $true
    $log.Dock = 'Bottom'; $log.Height = 190; $log.BorderStyle = 'FixedSingle'
    $log.BackColor = $Script:Ui.LogBg; $log.ForeColor = $Script:Ui.LogFg; $log.Font = New-UiFont 10

    # Fill 要先加（z-order 在最上面、最後才排版），Top / Bottom 後加
    $win.Body.Controls.Add($tabs); $win.Body.Controls.Add($top); $win.Body.Controls.Add($log)

    $ctx.Grid1 = $grid1; $ctx.Grid2 = $grid2; $ctx.Log = $log; $ctx.Info = $info; $ctx.NoWg = $noWg; $ctx.Tabs = $tabs; $ctx.Query = $query
    $ctx.Buttons = @($btnInstall, $btnRefresh, $btnSearch, $btnInstall2)

    # 下面的閉包都直接建在這一層，只用 $ctx 與這一層的變數（GetNewClosure 只帶走當下這一層）
    $append = {
        param([object[]]$Lines)
        foreach ($l in $Lines) { if (-not $ctx.Log.IsDisposed) { $ctx.Log.AppendText("$l`r`n") } }
    }.GetNewClosure()
    $setBusy = {
        param([bool]$On)
        $ctx.Busy = $On
        foreach ($b in $ctx.Buttons) { if (-not $b.IsDisposed) { $b.Enabled = -not $On } }
    }.GetNewClosure()
    $parsePkgs = {
        param($Lines)
        $h = @{}
        foreach ($l in @($Lines)) { if ([string]$l -like "PKG`t*") { $p = ([string]$l).Split("`t"); $h[$p[1]] = $p[2] } }
        $h
    }.GetNewClosure()
    $updateGrid = {
        foreach ($row in $ctx.Grid1.Rows) {
            $id = [string]$row.Cells['Id'].Value
            if ($ctx.Installed.ContainsKey($id)) {
                $row.Cells['State'].Value = "已安裝 $($ctx.Installed[$id])"
                $row.Cells['Pick'].Value = $false; $row.Cells['Pick'].ReadOnly = $true
                $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
            } else {
                $row.Cells['State'].Value = '未安裝'
                $row.Cells['Pick'].ReadOnly = $false
                $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Empty
            }
        }
        foreach ($row in $ctx.Grid2.Rows) {
            $id = [string]$row.Cells['Id'].Value
            $row.Cells['State'].Value = if ($ctx.Installed.ContainsKey($id)) { "已安裝 $($ctx.Installed[$id])" } else { '' }
        }
    }.GetNewClosure()
    $setWinget = {
        if ($ctx.Winget) {
            $ver = try { (& $ctx.Winget --version 2>$null | Select-Object -First 1) } catch { '' }
            $ctx.Info.Text = "winget $ver　$($ctx.Winget)`r`n勾選要裝的軟體後按「安裝勾選的軟體」；已經裝了的會顯示版本、不能勾。安裝是靜默安裝，會自動同意各軟體的授權條款。"
            $ctx.Info.ForeColor = $textColor
            $ctx.NoWg.Visible = $false; $ctx.Tabs.Enabled = $true
        } else {
            $ctx.Info.Text = Get-AppsWingetHelp
            $ctx.Info.ForeColor = [Drawing.Color]::FromArgb(153, 27, 27)
            $ctx.NoWg.Visible = $true; $ctx.Tabs.Enabled = $false
            foreach ($row in $ctx.Grid1.Rows) { $row.Cells['State'].Value = '—' }
        }
    }.GetNewClosure()

    # 背景作業結束：先把共同的部分處理掉，再交給這次動作自己的處理（$ctx.Then）
    $done = {
        param($out, $err)
        & $setBusy $false
        $lines = @($out | ForEach-Object { [string]$_ })
        if ($lines -contains 'WARNSRC') { & $append '[注意] winget 這次更新套件來源失敗，用的是本機快取的清單（可能不是最新版本）。' }
        try { & $ctx.Then @($lines | Where-Object { $_ -ne 'WARNSRC' }) @($err) }
        catch { & $append "[錯誤] $($_.Exception.Message)" }
        foreach ($e in @($err)) { & $append "[錯誤] $e" }
    }.GetNewClosure()
    $run = {
        param([string]$Mode, [string]$Arg, [scriptblock]$Then, [string]$Doing)
        if ($ctx.Busy) { return }
        & $setBusy $true
        & $append '', "▶ $Doing", '執行中，請稍候（winget 每次可能要十幾秒；視窗可以拖動，不會卡住）…'
        $ctx.Then = $Then
        Start-UiBackground -Form $ctx.Form -Script $worker -Arguments @($Mode, $Arg, $ctx.Winget) -OnDone $done -AllowClose:($Mode -ne 'install')
    }.GetNewClosure()

    $onInstalled = {
        param($Lines, $Errs)
        if (@($Errs).Count) { foreach ($row in $ctx.Grid1.Rows) { $row.Cells['State'].Value = '讀不到' }; return }
        $ctx.Installed = & $parsePkgs $Lines
        & $updateGrid
        $mine = @($ctx.Grid1.Rows | Where-Object { $ctx.Installed.ContainsKey([string]$_.Cells['Id'].Value) }).Count
        & $append "這台用 winget 認得的已安裝軟體 $($ctx.Installed.Count) 個；推薦清單裡已經裝了 $mine 個。"
    }.GetNewClosure()
    $onSearch = {
        param($Lines, $Errs)
        $ctx.Grid2.Rows.Clear()
        if (@($Errs).Count) { return }
        if ($Lines -contains 'NONE') { & $append '找不到符合的套件（只搜尋官方 winget 來源）。'; return }
        foreach ($l in $Lines) {
            if ($l -notlike "ROW`t*") { continue }
            $p = $l.Split("`t")
            [void]$ctx.Grid2.Rows.Add($p[1], $p[2], $p[3], $p[4], '')
        }
        & $updateGrid
        & $append "找到 $($ctx.Grid2.Rows.Count) 個。選一個後按「安裝選取的軟體」，會先查出發行者讓你確認。"
    }.GetNewClosure()
    $onInstall = {
        param($Lines, $Errs)
        $after = & $parsePkgs $Lines
        if ($after.Count) { $ctx.Installed = $after }
        foreach ($l in $Lines) {
            if ($l -like "PKG`t*") { continue }
            if ($l -notlike "RES`t*") { & $append $l; continue }
            $p = $l.Split("`t"); $id = $p[1]; $code = [int]$p[2]
            $what = switch ($code) {
                0           { 'winget 回報安裝成功' }
                -1978335135 { 'winget 回報已經安裝過' }
                -1978335189 { 'winget 回報已經安裝、而且沒有更新的版本' }
                -1978334967 { 'winget 回報要重新開機才能完成' }
                -1978335212 { 'winget 找不到這個套件' }
                default     { 'winget 結束碼 0x{0:X8}' -f $code }
            }
            if ($after.Count -and $ctx.Installed.ContainsKey($id)) {
                & $append "[完成] $id：$what；已確認在已安裝清單裡（版本 $($ctx.Installed[$id])）。"
                Write-OpsLog '常用軟體安裝' "安裝 $id" '成功' "$what；版本 $($ctx.Installed[$id])"
            } else {
                $why = if ($code -eq 0) { '，但已安裝清單裡找不到它（有些軟體要重新登入或重新開機才會出現；也可能安裝程式其實沒有完成）' } else { '' }
                & $append "[錯誤] $id：$what$why。"
                Write-OpsLog '常用軟體安裝' "安裝 $id" '失敗' "$what$why"
            }
        }
        & $updateGrid
    }.GetNewClosure()
    $onShow = {
        param($Lines, $Errs)
        if (@($Errs).Count -or -not $ctx.Pending) { return }
        $id = $ctx.Pending; $ctx.Pending = $null
        $detail = @($Lines | Where-Object { $_ -like "SHOW`t*" } | ForEach-Object { $_.Substring(5) } |
            Where-Object { $_ -notmatch '^\s' -and $_ -notmatch '[:：]$' } | Select-Object -First 12) -join "`r`n"
        $msg = "即將用 winget 安裝（官方 winget 來源、ID 完全比對）：`r`n`r`n$detail`r`n`r`n" +
            "請確認發行者是你要的那一家。安裝是靜默安裝，會自動同意這個軟體的授權條款。確定安裝？"
        if ([Windows.Forms.MessageBox]::Show($ctx.Form, $msg, '確認安裝', 'YesNo', 'Question') -ne 'Yes') { & $append '（已取消安裝）'; return }
        & $ctx.Run 'install' $id $ctx.OnInstall "安裝 $id"
    }.GetNewClosure()
    $ctx.Run = $run; $ctx.OnInstall = $onInstall

    $btnRefresh.Add_Click({ & $run 'installed' '' $onInstalled '重新檢查已安裝的軟體' }.GetNewClosure())
    $btnInstall.Add_Click({
        if ($ctx.Busy) { return }
        $picked = @($ctx.Grid1.Rows | Where-Object { $_.Cells['Pick'].Value -eq $true })
        if (-not $picked.Count) { [void][Windows.Forms.MessageBox]::Show($ctx.Form, '請先在「安裝」欄勾選要裝的軟體。', '常用軟體安裝', 'OK', 'Information'); return }
        if (-not (Request-PanelAdmin)) { return }
        $ids = @($picked | ForEach-Object { [string]$_.Cells['Id'].Value })
        $msg = "即將用 winget 依序安裝 $($ids.Count) 個軟體（官方 winget 來源、ID 完全比對、靜默安裝，會自動同意各軟體的授權條款）：`r`n`r`n" +
            (($picked | ForEach-Object { "　$($_.Cells['Name'].Value)　$($_.Cells['Id'].Value)" }) -join "`r`n")
        if ($ids -contains 'WiresharkFoundation.Wireshark') { $msg += "`r`n`r`n※ Wireshark：抓包驅動 Npcap 的授權不允許自動安裝，裝完要另外到 npcap.com 下載手動安裝，才抓得到封包。" }
        if ($ids -contains 'Prometheus.WindowsExporter') { $msg += "`r`n`r`n※ windows_exporter：會建立 Windows 服務並監聽 9182 Port；要讓 Prometheus 從外面抓，防火牆要另外放行。" }
        $msg += "`r`n`r`n每個軟體可能要幾十秒到幾分鐘。確定開始？"
        if ([Windows.Forms.MessageBox]::Show($ctx.Form, $msg, '確認安裝', 'YesNo', 'Question') -ne 'Yes') { & $append '（已取消安裝）'; return }
        & $run 'install' ($ids -join ',') $onInstall "安裝 $($ids.Count) 個軟體"
    }.GetNewClosure())
    $btnSearch.Add_Click({
        $q = $ctx.Query.Text.Trim()
        if ($q.Length -lt 2 -or $q.Length -gt 60) { [void][Windows.Forms.MessageBox]::Show($ctx.Form, '請輸入 2～60 個字的關鍵字。', '搜尋', 'OK', 'Information'); return }
        & $run 'search' $q $onSearch "搜尋「$q」"
    }.GetNewClosure())
    $query.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $btnSearch.PerformClick() } }.GetNewClosure())
    $btnInstall2.Add_Click({
        if ($ctx.Busy) { return }
        $row = $ctx.Grid2.CurrentRow
        if (-not $row) { [void][Windows.Forms.MessageBox]::Show($ctx.Form, '請先搜尋，並在結果裡選一個。', '安裝', 'OK', 'Information'); return }
        $id = [string]$row.Cells['Id'].Value
        if ($id -match '…$') { [void][Windows.Forms.MessageBox]::Show($ctx.Form, "這個 ID 太長被 winget 截斷了（$id），請用更精確的關鍵字再搜一次。", '安裝', 'OK', 'Warning'); return }
        if ($ctx.Installed.ContainsKey($id)) { [void][Windows.Forms.MessageBox]::Show($ctx.Form, "$id 已經安裝了（版本 $($ctx.Installed[$id])）。", '安裝', 'OK', 'Information'); return }
        if (-not (Request-PanelAdmin)) { return }
        $ctx.Pending = $id
        & $run 'show' $id $onShow "查詢 $id 的發行者與版本"
    }.GetNewClosure())
    $btnStore.Add_Click({
        try { Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' } catch { & $append "[錯誤] 打不開 Microsoft Store：$($_.Exception.Message)" }
    }.GetNewClosure())
    $btnDetect.Add_Click({
        $ctx.Winget = Get-AppsWinget
        & $setWinget
        if ($ctx.Winget) { & $run 'installed' '' $onInstalled '檢查已安裝的軟體' } else { & $append '還是找不到 winget。' }
    }.GetNewClosure())

    & $setWinget
    if ($ctx.Winget) {
        foreach ($row in $grid1.Rows) { $row.Cells['State'].Value = '讀取中…' }
        $form.Add_Shown({ & $run 'installed' '' $onInstalled '檢查已安裝的軟體' }.GetNewClosure())
    }
    Show-UiWindow $win
}

# ================= 網路與防火牆 =================

# ---- OpenSSH Server（E5；對應 Linux SSH）----
# 一鍵：沒裝就裝（Windows 選用功能 OpenSSH.Server）→ 設定 Port → 防火牆放行 → 自動啟動並啟動。
# 不把自己鎖在外面：
#   - sshd 正在執行時不換 Port（換 Port 一定會斷線，這裡沒有看門狗；要換請先停用再啟用）。
#   - 設定跟現在一樣就什麼都不改、不重新啟動 sshd，重按「啟用」是安全的。
#   - 停用前列出目前的 SSH 連線，確認視窗會說哪些會被斷掉。
# 防火牆規則名稱 OPS-SSH-<Port>（跟 README 教的手動做法同名，手動建過的會被沿用）。
$Script:SshConfigPath = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }) 'ssh\sshd_config'

# 背景執行（另一個 runspace）。前半段是純函式，測試會單獨載入「# ---- 主流程」之前的部分。
$Script:WorkerSsh = @'
param([int]$Port, [string]$Shell, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'

# sshd_config 裡第一個 Match 之前、沒被註解的 Port；沒有就是 22
function Get-SshConfigPort([string[]]$Lines) {
    foreach ($l in $Lines) {
        if ($l -match '^\s*Match\s') { break }
        if ($l -match '^\s*Port\s+(\d+)\s*$') { return [int]$Matches[1] }
    }
    22
}
# 把 Port 改成 $Port：改第一個 Match 之前的 Port 行；沒有就改「#Port 22」那行；再沒有就加在最前面
function Set-SshConfigPort([string[]]$Lines, [int]$Port) {
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false; $inMatch = $false
    foreach ($l in $Lines) {
        if ($l -match '^\s*Match\s') { $inMatch = $true }
        if (-not $done -and -not $inMatch -and $l -match '^\s*Port\s+\d+\s*$') { $out.Add("Port $Port"); $done = $true; continue }
        $out.Add($l)
    }
    if (-not $done) {
        $i = -1
        for ($k = 0; $k -lt $out.Count; $k++) { if ($out[$k] -match '^\s*Match\s') { break }; if ($out[$k] -match '^\s*#\s*Port\s+\d+') { $i = $k; break } }
        if ($i -ge 0) { $out.Insert($i + 1, "Port $Port") } else { $out.Insert(0, "Port $Port") }
    }
    , $out.ToArray()
}
# ---- 主流程
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if (-not $cap) { throw '這台 Windows 沒有 OpenSSH Server 選用功能（Windows 10 1809 以後才有）。' }
if ($cap.State -ne 'Installed') {
    '安裝 OpenSSH Server（Windows 選用功能，要從 Windows Update 下載，可能要幾分鐘）…'
    try { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    catch { throw "安裝失敗：$($_.Exception.Message)。如果 Windows 更新被停用（本工具「Windows 更新」可以還原），選用功能也裝不了。" }
    '  安裝完成'
} else { 'OpenSSH Server 已經安裝' }

$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) { throw '安裝後還是找不到 sshd 服務，請重新開機後再試。' }
if (-not (Test-Path $ConfigPath)) {
    $default = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd_config_default'
    New-Item -ItemType Directory -Force -Path (Split-Path $ConfigPath) | Out-Null
    Copy-Item $default $ConfigPath
    "建立設定檔 $ConfigPath（從預設值複製）"
}
$lines = [IO.File]::ReadAllLines($ConfigPath)
$cur = Get-SshConfigPort $lines
if ($cur -ne $Port) {
    if ($svc.Status -eq 'Running') { throw "sshd 正在 Port $cur 執行。換 Port 會讓 SSH 連線斷掉，這裡沒有看門狗保護，所以不做；要換請先按「停用」再用新 Port 啟用。" }
    Copy-Item $ConfigPath "$ConfigPath.ops-bak" -Force
    [IO.File]::WriteAllLines($ConfigPath, [string[]](Set-SshConfigPort $lines $Port), (New-Object Text.UTF8Encoding($false)))
    "設定檔 Port：$cur → $Port（原檔備份為 sshd_config.ops-bak）"
} else { "設定檔 Port 已經是 $Port，不改" }

$rule = "OPS-SSH-$Port"
if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) {
    Enable-NetFirewallRule -Name $rule
    "防火牆規則 $rule 已存在（確認為啟用）"
} else {
    New-NetFirewallRule -Name $rule -DisplayName "OpenSSH ($Port)" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
    "建立防火牆規則 $rule（TCP $Port 連入允許）"
}

$shellKey = 'HKLM:\SOFTWARE\OpenSSH'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$nowShell = (Get-ItemProperty $shellKey -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($Shell -eq 'PowerShell' -and $nowShell -ne $ps) {
    if (-not (Test-Path $shellKey)) { New-Item -Path $shellKey -Force | Out-Null }
    Set-ItemProperty $shellKey -Name DefaultShell -Value $ps
    '預設殼層改成 PowerShell（新連線才生效）'
} elseif ($Shell -ne 'PowerShell' -and $nowShell) {
    Remove-ItemProperty $shellKey -Name DefaultShell
    '預設殼層改回 cmd（新連線才生效）'
} else { "預設殼層不變（$(if ($nowShell) { 'PowerShell' } else { 'cmd' })）" }

if ((Get-Service sshd).StartType -ne 'Automatic') { Set-Service sshd -StartupType Automatic; 'sshd 改成開機自動啟動' }
if ((Get-Service sshd).Status -ne 'Running') {
    Start-Service sshd
    'sshd 已啟動'
} else { 'sshd 已經在執行，不重新啟動（目前的連線不受影響）' }

for ($i = 0; $i -lt 20; $i++) {
    if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Milliseconds 500
}
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) { "[完成] sshd 在 Port $Port 監聽中。連線：ssh 帳號@這台的IP -p $Port" }
else { throw "sshd 啟動了，但 10 秒內沒有在 Port $Port 監聽，請看事件記錄（應用程式 / OpenSSH）。" }
'@

function Get-SshServerInfo {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    $lines = if (Test-Path $Script:SshConfigPath) { [IO.File]::ReadAllLines($Script:SshConfigPath) } else { @() }
    $port = 22
    foreach ($l in $lines) { if ($l -match '^\s*Match\s') { break }; if ($l -match '^\s*Port\s+(\d+)\s*$') { $port = [int]$Matches[1]; break } }
    $sessions = @(Get-NetTCPConnection -State Established -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$)' })
    @{ Svc = $svc; Port = $port; HasConfig = [bool]$lines.Count; Sessions = $sessions
       Listening = [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
       Shell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell }
}

function Get-SshServerStatus {
    $i = Get-SshServerInfo
    if (-not $i.Svc) { '尚未安裝 OpenSSH Server。按「啟用」會自動安裝（要從 Windows Update 下載）。'; return }
    "sshd 服務：$(if ($i.Svc.Status -eq 'Running') { '執行中' } else { '沒有執行' })　啟動類型：$($i.Svc.StartType)"
    "Port：$($i.Port)$(if (-not $i.HasConfig) { '（還沒有設定檔，第一次啟動會建立）' })　$(if ($i.Listening) { '監聽中' } else { '沒有在監聽' })"
    $rules = @(Get-NetFirewallRule -Name "OPS-SSH-$($i.Port)", 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
    '防火牆：' + $(if ($rules.Count) { "有放行規則（$(($rules | ForEach-Object Name) -join '、')）" } else { "沒有看到放行 Port $($i.Port) 的規則" })
    "預設殼層：$(if ($i.Shell) { 'PowerShell' } else { 'cmd（Windows 預設）' })"
    "目前 SSH 連線：$(if ($i.Sessions.Count) { ($i.Sessions | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique) -join '、' } else { '無' })"
    $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled } | ForEach-Object Name)
    if ($off.Count) { "[注意] 防火牆設定檔 $($off -join '、') 是關閉的：在這些網路上任何 Port 都是開的，SSH 也一樣。" }
}

function Disable-SshServer {
    $i = Get-SshServerInfo
    if (-not $i.Svc) { throw '沒有安裝 OpenSSH Server。' }
    Stop-Service sshd -Force -ErrorAction Stop
    Set-Service sshd -StartupType Disabled
    $n = 0
    foreach ($r in @(Get-NetFirewallRule -Name "OPS-SSH-$($i.Port)", 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) { Disable-NetFirewallRule -Name $r.Name; $n++ }
    "[完成] sshd 已停止並設為停用；停用了 $n 條防火牆放行規則（沒有刪除，重新啟用會沿用）。OpenSSH 本身沒有移除。"
}

function Show-SshServerPanel {
    $i = Get-SshServerInfo
    $worker = $Script:WorkerSsh
    $cfg = $Script:SshConfigPath
    Show-FeaturePanel -Title 'OpenSSH Server' -Subtitle '讓這台可以用 SSH 連進來（備援管道：RDP 出問題時還能用 SSH 救）' -Width 900 -Height 700 `
        -Note '「啟用」會：沒裝就安裝 OpenSSH Server → 設定 Port → 防火牆放行 → 開機自動啟動並啟動。已經在執行時重按不會重新啟動、不會斷線；執行中也不會換 Port（換 Port 會斷線）。管理員帳號的金鑰要放在 C:\ProgramData\ssh\administrators_authorized_keys，不是使用者資料夾。' `
        -Status { Get-SshServerStatus } `
        -Inputs @(
            @{ Name = 'Port'; Label = 'SSH Port'; Type = 'Number'; Min = 1; Max = 65535; Default = $i.Port }
            @{ Name = 'Shell'; Label = '連進來的預設殼層'; Type = 'Combo'; Items = @('PowerShell', 'cmd（Windows 預設）'); Default = $(if ($i.Shell -or -not $i.Svc) { 'PowerShell' } else { 'cmd（Windows 預設）' }) }
        ) `
        -Actions @(
            @{ Text = '啟用'; Style = 'success'; Admin = $true
               Confirm = { param($v)
                   $now = Get-SshServerInfo
                   if ($now.Svc -and $now.Svc.Status -eq 'Running' -and $v.Port -ne $now.Port) { return '' }   # 會在 Run 裡擋下，不用問
                   "OpenSSH Server 將在 Port $($v.Port) 啟用（沒裝會先安裝），防火牆放行 TCP $($v.Port)，開機自動啟動。確定？" }
               Run = { param($v)
                   $now = Get-SshServerInfo
                   if ($now.Svc -and $now.Svc.Status -eq 'Running' -and $v.Port -ne $now.Port) {
                       throw "sshd 正在 Port $($now.Port) 執行。換 Port 會讓 SSH 連線斷掉，這裡沒有看門狗保護，所以不做；要換請先按「停用」再用新 Port 啟用。"
                   }
                   $used = Get-NetTCPConnection -State Listen -LocalPort $v.Port -ErrorAction SilentlyContinue | Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Name -ne 'sshd' }
                   if ($used) { throw "Port $($v.Port) 已經被其他程式（$((Get-Process -Id @($used)[0].OwningProcess).Name)）佔用。" }
                   '開始設定（背景執行）…'
               }
               Worker = $worker
               WorkerArgs = { param($v) $v.Port, $(if ($v.Shell -eq 'PowerShell') { 'PowerShell' } else { 'cmd' }), $cfg }.GetNewClosure() }
            @{ Text = '停用'; Style = 'danger'; Admin = $true
               Confirm = {
                   $now = Get-SshServerInfo
                   $who = @($now.Sessions | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique)
                   '停用會停止 sshd、設為停用，並停用放行規則。' +
                   $(if ($who.Count) { "`r`n`r`n目前有 SSH 連線（$($who -join '、')），會馬上斷掉。" } else { '' }) +
                   "`r`n`r`n確定？" }
               Run = { Disable-SshServer } }
        )
}

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

# ---- IP / DNS 設定（對應 Linux NET/net-set.sh）----
# 重點同 Linux 版：遠端改 IP 不要把自己鎖在門外。
#   - 只做 IPv4、不動閘道。DHCP 網卡不改位址（理由見下方「批量新增 IP」的說明）。
#   - 每次位址變更（新增／移除／替換）都先寫狀態、建好看門狗，才動網卡；看門狗建不起來就不做。
#     時限內沒有「確認」，看門狗（SYSTEM 排程）就把網卡改回變更前。一次只能有一個變更。
#   - 替換分兩階段：先加新位址（新舊並存）；確認時必須已經有從「別台機器」連到新位址的連線，
#     證明新位址真的通，才移除舊位址。從舊位址確認一律拒絕。
#   - 有 Established 連線正在用的本機位址不能移除（要換請用替換）；移除後閘道不在任何剩下的網段、
#     或是網卡上最後一個位址，也不能移除。
#   - 新加的位址設 SkipAsSource（只收不發）：Windows 選來源位址時可能挑到新加的同網段位址，
#     讓這台主動連出去的連線（含 DNS 查詢、更新）換了來源 IP。只收不發等同 Linux 的 secondary 位址。
#     替換確認時，新位址才接手舊位址原本的設定。
#   - DNS 改錯不會斷遠端連線，所以不開看門狗，改用實際解析驗證：先向每台新 DNS 查一次，查不到就不改；
#     改完再用系統解析查一次，改之前查得到、改之後查不到就自動改回去。不能刪到一台都不剩。
# 還原指令、狀態、紀錄的放法同 RDP 換 Port（W2）：-EncodedCommand 放進排程、狀態存 HKLM、
# 紀錄寫事件記錄（應用程式，來源 OPS-command，事件 100），SYSTEM 不碰使用者寫得到的路徑。
$Script:NetStateKey = 'HKLM:\SOFTWARE\OPS-command\NetChange'
$Script:NetTask     = 'OPS-NetChange-Watchdog'

# 不用 [ipaddress]::TryParse 判斷：它接受「1」「1.2」這種寫法，前面補 0 的段還會被當成八進位。
function Test-NetIpv4Text {
    param([string]$Text)
    $Text -match '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$'
}

function ConvertTo-NetNumber {
    param([string]$Ip)
    $b = ([ipaddress]$Ip).GetAddressBytes()
    [Array]::Reverse($b)
    [uint64][BitConverter]::ToUInt32($b, 0)
}

function Test-NetSameSubnet {
    param([string]$A, [string]$B, [int]$Prefix)
    $mask = ([uint64]4294967295 -shl (32 - $Prefix)) -band [uint64]4294967295
    ((ConvertTo-NetNumber $A) -band $mask) -eq ((ConvertTo-NetNumber $B) -band $mask)
}

# 要加到網卡上的位址有沒有問題；沒問題回傳 $null
function Get-NetIpProblem {
    param([string]$Ip, [int]$Prefix)
    if (-not (Test-NetIpv4Text $Ip)) { return "「$Ip」不是 IPv4 位址（只支援 IPv4，格式像 192.168.1.10，不要補 0）。" }
    $first = [int]$Ip.Split('.')[0]
    if ($first -eq 0 -or $first -eq 127 -or $first -ge 224 -or $Ip -like '169.254.*') { return "$Ip 是保留位址（0.x、127.x、169.254.x、群播或保留段），不能設在網卡上。" }
    if ($Prefix -lt 31) {
        $hostBits = [uint64][Math]::Pow(2, 32 - $Prefix) - 1
        $h = (ConvertTo-NetNumber $Ip) -band $hostBits
        if ($h -eq 0) { return "$Ip/$Prefix 是網段位址，不能當主機位址。" }
        if ($h -eq $hostBits) { return "$Ip/$Prefix 是廣播位址，不能當主機位址。" }
    }
    if (Get-NetIPAddress -IPAddress $Ip -ErrorAction SilentlyContinue) { return "$Ip 已經在這台機器的網卡上了。" }
    $gw = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object NextHop)
    if ($gw -contains $Ip) { return "$Ip 是預設閘道的位址。" }
    $null
}

function Get-NetAdapterInfo {
    param([string]$Alias)
    if (-not $Alias) { throw '沒有選網卡。' }
    $a  = Get-NetAdapter -Name $Alias -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $a -or -not $a.InterfaceGuid) { throw "找不到網卡 [$Alias]。" }
    $if =Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop
    $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object SkipAsSource, IPAddress)
    $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        ForEach-Object NextHop | Where-Object { $_ -ne '0.0.0.0' } | Sort-Object -Unique)
    [pscustomobject]@{ Alias = $a.Name; Index = [int]$a.ifIndex; Guid = [string]$a.InterfaceGuid; Dhcp = ($if.Dhcp -eq 'Enabled'); Ips = $ips; Gateways = $gw }
}

# 登錄檔 NameServer 有值 = 手動設定的 DNS；空的 = 自動取得（DHCP）
function Get-NetDnsInfo {
    param($Info)
    $servers = @((Get-DnsClientServerAddress -InterfaceIndex $Info.Index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
    $ns = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($Info.Guid)" -Name NameServer -ErrorAction SilentlyContinue).NameServer
    [pscustomobject]@{ Servers = $servers; Static = [bool]("$ns".Trim()) }
}

function Get-NetIfIndexByGuid {
    param([string]$Guid)
    $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceGuid -eq $Guid } | Select-Object -First 1
    if (-not $a) { throw "找不到網卡 $Guid（被移除或停用了？）。" }
    [int]$a.ifIndex
}

function Test-NetHasIp {
    param([int]$Index, [string]$Ip)
    [bool](Get-NetIPAddress -InterfaceIndex $Index -IPAddress $Ip -AddressFamily IPv4 -ErrorAction SilentlyContinue)
}

# 正在使用這個本機位址的 TCP 連線。-RemoteOnly：只算從別台機器來的（拿來證明新位址從外面連得到）
function Get-NetSessionsOn {
    param([string]$Ip, [switch]$RemoteOnly)
    $c = @(Get-NetTCPConnection -State Established -LocalAddress $Ip -ErrorAction SilentlyContinue)
    if ($RemoteOnly) {
        $local = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
        $c = @($c | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0)' -and $local -notcontains $_.RemoteAddress })
    }
    $c
}

function Format-NetSessions {
    param([array]$Sessions)
    (@($Sessions | Select-Object -First 3 | ForEach-Object { "$($_.RemoteAddress) → 本機 Port $($_.LocalPort)" }) -join '、') +
        $(if (@($Sessions).Count -gt 3) { " 等 $(@($Sessions).Count) 條" } else { '' })
}

# 移除某個位址前的檢查（唯讀）。回傳拒絕的理由，空陣列 = 可以移除
function Get-NetRemoveBlockers {
    param($Info, [string]$Ip)
    $addr = @($Info.Ips | Where-Object { $_.IPAddress -eq $Ip })
    if (-not $addr.Count) { return @("$Ip 不在網卡 [$($Info.Alias)] 上。") }
    $r = @()
    if ($addr[0].PrefixOrigin -ne 'Manual') { $r += "$Ip 不是手動設定的位址（來源：$($addr[0].PrefixOrigin)）。" }
    if (@($Info.Ips).Count -le 1) { $r += "這是網卡 [$($Info.Alias)] 上唯一的 IPv4 位址。要換位址請用「替換 IP」。" }
    $s = @(Get-NetSessionsOn $Ip)
    if ($s.Count) { $r += "有 $($s.Count) 條連線正在使用 $Ip（$(Format-NetSessions $s)），移除會讓它們斷線。要換位址請用「替換 IP」。" }
    foreach ($g in $Info.Gateways) {
        $left = @($Info.Ips | Where-Object { $_.IPAddress -ne $Ip -and (Test-NetSameSubnet $_.IPAddress $g $_.PrefixLength) })
        if (-not $left.Count) { $r += "移除後閘道 $g 不在網卡剩下任何位址的網段內，對外會斷線。" }
    }
    $r
}

function Get-NetPending {
    $p = Get-ItemProperty -Path $Script:NetStateKey -ErrorAction SilentlyContinue
    if ($p -and $p.Kind) { $p } else { $null }
}

function Test-NetWatchdog {
    [bool](Get-ScheduledTask -TaskName $Script:NetTask -ErrorAction SilentlyContinue)
}

# 把網卡改回變更前的指令。看門狗（SYSTEM，-EncodedCommand）與「立即還原」跑的是同一份。
# 網卡用 GUID 找：介面編號重開機後可能變，名稱可能被改。
function Get-NetRevertScript {
    param($State, [switch]$Watchdog)
    $ip = $State.Ip; $new = $State.NewIp; $prefix = [int]$State.Prefix; $skip = if ($State.Skip -eq 'True') { '$true' } else { '$false' }
    $lines = @(
        "`$ErrorActionPreference = 'Continue'"
        "`$i = (Get-NetAdapter | Where-Object { [string]`$_.InterfaceGuid -eq '$($State.Guid)' } | Select-Object -First 1).ifIndex"
    )
    # 網卡不見了就沒有東西可以還原；照樣清掉狀態與排程並留紀錄，不要留一個永遠失敗的看門狗
    $miss = "eventcreate /L APPLICATION /SO OPS-command /ID 100 /T WARNING /D `"OPS-command network watchdog: adapter $($State.Guid) not found, nothing reverted.`" | Out-Null"
    $lines += "if (-not `$i) { $(if ($Watchdog) { "$miss; " } else { '' })Remove-Item -Path '$($Script:NetStateKey)' -Recurse -Force -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName '$($Script:NetTask)' -Confirm:`$false -ErrorAction SilentlyContinue; throw 'network adapter $($State.Guid) not found' }"
    switch ($State.Kind) {
        'Add' {
            $lines += "Remove-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -Confirm:`$false"
        }
        'Remove' {
            $lines += "if (-not (Get-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -ErrorAction SilentlyContinue)) { New-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -PrefixLength $prefix -SkipAsSource $skip | Out-Null }"
        }
        'Replace' {
            $lines += "if (-not (Get-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -ErrorAction SilentlyContinue)) { New-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -PrefixLength $prefix -SkipAsSource $skip | Out-Null } else { Set-NetIPAddress -InterfaceIndex `$i -IPAddress '$ip' -SkipAsSource $skip }"
            $lines += "if (Get-NetIPAddress -InterfaceIndex `$i -IPAddress '$new' -ErrorAction SilentlyContinue) { Remove-NetIPAddress -InterfaceIndex `$i -IPAddress '$new' -Confirm:`$false }"
        }
        default { throw "看不懂的變更紀錄：$($State.Kind)" }
    }
    $lines += "Remove-Item -Path '$($Script:NetStateKey)' -Recurse -Force -ErrorAction SilentlyContinue"
    # 純 ASCII：事件訊息經 eventcreate 寫入，避開編碼問題
    if ($Watchdog) { $lines += "eventcreate /L APPLICATION /SO OPS-command /ID 100 /T WARNING /D `"OPS-command network watchdog: not confirmed within $($State.Minutes) minutes, reverted $($State.Kind) $ip$(if ($new) { " -> $new" }).`" | Out-Null" }
    $lines += "Unregister-ScheduledTask -TaskName '$($Script:NetTask)' -Confirm:`$false -ErrorAction SilentlyContinue"
    $lines -join "`r`n"
}

# 狀態先寫好、看門狗先建好，才動網卡。任何一步失敗就不做這次變更。
function Enable-NetWatchdog {
    param([hashtable]$State, [int]$Minutes)
    $State.Minutes = $Minutes
    $State.Since = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        New-Item -Path $Script:NetStateKey -Force -ErrorAction Stop | Out-Null
        foreach ($k in $State.Keys) { Set-ItemProperty -Path $Script:NetStateKey -Name $k -Value ([string]$State[$k]) -ErrorAction Stop }
    } catch {
        Remove-Item -Path $Script:NetStateKey -Recurse -Force -ErrorAction SilentlyContinue
        throw "狀態寫不進登錄檔（$($_.Exception.Message)），這次不做變更。"
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-NetRevertScript $State -Watchdog)))
    try {
        $ps        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action    = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($Minutes)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        # 時間到時機器剛好關著，開機後補跑；筆電用電池也照樣跑
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $Script:NetTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    } catch {
        Remove-Item -Path $Script:NetStateKey -Recurse -Force -ErrorAction SilentlyContinue
        throw "看門狗建不起來（$($_.Exception.Message)），這次不做變更——沒有自動還原就改 IP 太危險。"
    }
}

function Wait-NetAddressReady {
    param([int]$Index, [string]$Ip)
    $a = $null
    for ($k = 0; $k -lt 24; $k++) {
        $a = Get-NetIPAddress -InterfaceIndex $Index -IPAddress $Ip -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($a.AddressState -eq 'Preferred') { return }
        if ($a.AddressState -eq 'Duplicate') { throw "位址衝突：網路上已經有其他機器在用 $Ip。" }
        Start-Sleep -Milliseconds 250
    }
    throw "等了 6 秒，$Ip 的狀態還是「$($a.AddressState)」。"
}

function Assert-NetIpChangeAllowed {
    param($Info)
    if (Get-NetPending) { throw '還有一個 IP 變更沒有確認。請先「確認 IP 變更」或「立即還原」，一次只做一個。' }
    if (Test-NetWatchdog) { throw "排程裡還有看門狗 $Script:NetTask，但沒有變更紀錄。請到工作排程器確認後刪除它再試。" }
    if ($Info.Dhcp) { throw "網卡 [$($Info.Alias)] 是 DHCP。加上或拿掉固定位址會讓整張網卡變成固定 IP、DHCP 拿到的位址可能不見，遠端操作時等於斷線，所以不改。DNS 可以改。" }
}

function Undo-NetChange {
    $p = Get-NetPending
    if (-not $p) { throw "找不到進行中的變更紀錄（$Script:NetStateKey），沒有可還原的變更。" }
    $out = @(& ([scriptblock]::Create((Get-NetRevertScript $p))) 2>&1 | ForEach-Object { "  $_" })
    $i = Get-NetIfIndexByGuid $p.Guid
    $ok = switch ($p.Kind) {
        'Add'     { -not (Test-NetHasIp $i $p.Ip) }
        'Remove'  { Test-NetHasIp $i $p.Ip }
        'Replace' { (Test-NetHasIp $i $p.Ip) -and -not (Test-NetHasIp $i $p.NewIp) }
    }
    $out
    if (-not $ok) { throw "還原後讀回來不對，請手動檢查網卡 [$($p.Adapter)] 的位址。看門狗與變更紀錄已清掉。" }
    switch ($p.Kind) {
        'Add'     { "[完成] 已移除剛才新增的 $($p.Ip)。" }
        'Remove'  { "[完成] 已把 $($p.Ip)/$($p.Prefix) 加回 [$($p.Adapter)]。" }
        'Replace' { "[完成] 已移除新位址 $($p.NewIp)，保留原本的 $($p.Ip)。" }
    }
}

function Invoke-NetIpAdd {
    param([string]$Alias, [string]$Ip, [int]$Prefix, [int]$Minutes)
    $info = Get-NetAdapterInfo $Alias
    Assert-NetIpChangeAllowed $info
    $bad = Get-NetIpProblem $Ip $Prefix
    if ($bad) { throw $bad }
    Enable-NetWatchdog @{ Kind = 'Add'; Adapter = $info.Alias; Guid = $info.Guid; Ip = $Ip; Prefix = $Prefix; Skip = 'True'; NewIp = '' } $Minutes
    try {
        New-NetIPAddress -InterfaceIndex $info.Index -IPAddress $Ip -PrefixLength $Prefix -SkipAsSource $true -ErrorAction Stop | Out-Null
        Wait-NetAddressReady $info.Index $Ip
    } catch {
        $msg = $_.Exception.Message
        $undo = '已撤回，網卡維持原狀'
        try { Undo-NetChange | Out-Null } catch { $undo = "撤回也失敗：$($_.Exception.Message)，請看「目前狀態」並手動檢查網卡" }
        throw "新增 $Ip 失敗：$msg（$undo）"
    }
    "[完成] [$($info.Alias)] 已新增 $Ip/$Prefix（只收不發）；看門狗 $Minutes 分鐘後會自動移除。"
    "要保留就按「確認 IP 變更」。"
}

function Invoke-NetIpRemove {
    param([string]$Alias, [string]$Ip, [int]$Minutes)
    $info = Get-NetAdapterInfo $Alias
    Assert-NetIpChangeAllowed $info
    if (-not (Test-NetIpv4Text $Ip)) { throw "「$Ip」不是 IPv4 位址。" }
    $blk = @(Get-NetRemoveBlockers $info $Ip)
    if ($blk.Count) { throw ("不能移除 $Ip：`r`n  - " + ($blk -join "`r`n  - ")) }
    $addr = @($info.Ips | Where-Object { $_.IPAddress -eq $Ip })[0]
    Enable-NetWatchdog @{ Kind = 'Remove'; Adapter = $info.Alias; Guid = $info.Guid; Ip = $Ip; Prefix = [int]$addr.PrefixLength; Skip = [string]$addr.SkipAsSource; NewIp = '' } $Minutes
    try {
        Remove-NetIPAddress -InterfaceIndex $info.Index -IPAddress $Ip -Confirm:$false -ErrorAction Stop
        if (Test-NetHasIp $info.Index $Ip) { throw '移除後讀回來還在。' }
    } catch {
        $msg = $_.Exception.Message
        $undo = '已撤回，網卡維持原狀'
        try { Undo-NetChange | Out-Null } catch { $undo = "撤回也失敗：$($_.Exception.Message)，請看「目前狀態」並手動檢查網卡" }
        throw "移除 $Ip 失敗：$msg（$undo）"
    }
    "[完成] [$($info.Alias)] 已移除 $Ip/$($addr.PrefixLength)；看門狗 $Minutes 分鐘後會自動加回來。"
    "確定不需要了就按「確認 IP 變更」。"
}

function Invoke-NetIpReplace {
    param([string]$Alias, [string]$Ip, [string]$NewIp, [int]$Minutes)
    $info = Get-NetAdapterInfo $Alias
    Assert-NetIpChangeAllowed $info
    if (-not (Test-NetIpv4Text $Ip)) { throw "舊位址「$Ip」不是 IPv4 位址。" }
    $old = @($info.Ips | Where-Object { $_.IPAddress -eq $Ip })
    if (-not $old.Count) { throw "$Ip 不在網卡 [$($info.Alias)] 上。" }
    $old = $old[0]
    if ($old.PrefixOrigin -ne 'Manual') { throw "$Ip 不是手動設定的位址（來源：$($old.PrefixOrigin)）。" }
    $prefix = [int]$old.PrefixLength
    $bad = Get-NetIpProblem $NewIp $prefix
    if ($bad) { throw $bad }
    if (-not (Test-NetSameSubnet $Ip $NewIp $prefix)) { throw "$NewIp 和 $Ip/$prefix 不在同一個網段。替換只做同網段（前綴、閘道都不變）；跨網段請用「新增 IP」另外加。" }
    Enable-NetWatchdog @{ Kind = 'Replace'; Adapter = $info.Alias; Guid = $info.Guid; Ip = $Ip; Prefix = $prefix; Skip = [string]$old.SkipAsSource; NewIp = $NewIp } $Minutes
    try {
        New-NetIPAddress -InterfaceIndex $info.Index -IPAddress $NewIp -PrefixLength $prefix -SkipAsSource $true -ErrorAction Stop | Out-Null
        Wait-NetAddressReady $info.Index $NewIp
    } catch {
        $msg = $_.Exception.Message
        $undo = '已撤回，網卡維持原狀'
        try { Undo-NetChange | Out-Null } catch { $undo = "撤回也失敗：$($_.Exception.Message)，請看「目前狀態」並手動檢查網卡" }
        throw "加上新位址 $NewIp 失敗：$msg（$undo）"
    }
    "[完成] 第一階段：[$($info.Alias)] 已加上 $NewIp/$prefix，和 $Ip 並存。看門狗 $Minutes 分鐘後會移除 $NewIp。"
    "接下來："
    "  1. 用『另一台電腦』連新位址 $NewIp（RDP 或 SSH）登入"
    "  2. 在那條連線裡按「確認 IP 變更」，這時才移除舊位址 $Ip"
    "  * 連不上就什麼都別做，時限到自動還原"
    "[提醒] 雲端主機的位址通常由平台分配，要先在平台上把 $NewIp 指給這台；防火牆／安全群組也要放行。"
}

# 確認前要問的話。替換：列出還走舊位址、確認後會斷的連線
function Get-NetConfirmPrompt {
    $p = Get-NetPending
    if (-not $p) { return '' }
    switch ($p.Kind) {
        'Add'    { "保留新增的 $($p.Ip)，取消看門狗？" }
        'Remove' { "確定不要 $($p.Ip) 了？看門狗會取消，之後不會自動加回來。" }
        'Replace' {
            $s = @(Get-NetSessionsOn $p.Ip)
            "確認後會移除舊位址 $($p.Ip)，由 $($p.NewIp) 接手。" +
                $(if ($s.Count) { "`r`n`r`n目前還有 $($s.Count) 條連線走舊位址（$(Format-NetSessions $s)），會斷線。" } else { '' }) +
                "`r`n`r`n確定？"
        }
    }
}

function Invoke-NetConfirm {
    $p = Get-NetPending
    if (-not $p) { throw '目前沒有進行中的 IP 變更。' }
    if ($p.Kind -eq 'Replace') {
        $proof = @(Get-NetSessionsOn $p.NewIp -RemoteOnly)
        if (-not $proof.Count) {
            throw "還沒有任何從別台機器連到新位址 $($p.NewIp) 的連線，不能確認——從舊位址確認不算數。請先用新位址重新連線（RDP 或 SSH），在那條連線裡再按一次。連不上就什麼都別做，看門狗會還原。"
        }
        $i = Get-NetIfIndexByGuid $p.Guid
        # 先取消看門狗再動舊位址：否則剛好到期時，看門狗會把新位址拿掉
        Unregister-ScheduledTask -TaskName $Script:NetTask -Confirm:$false -ErrorAction SilentlyContinue
        Set-NetIPAddress -InterfaceIndex $i -IPAddress $p.NewIp -SkipAsSource ($p.Skip -eq 'True') -ErrorAction Stop
        Remove-NetIPAddress -InterfaceIndex $i -IPAddress $p.Ip -Confirm:$false -ErrorAction Stop
        if (Test-NetHasIp $i $p.Ip) { throw "舊位址 $($p.Ip) 移除後讀回來還在。看門狗已取消，請手動檢查。" }
        Remove-Item -Path $Script:NetStateKey -Recurse -Force -ErrorAction SilentlyContinue
        "[完成] 已移除舊位址 $($p.Ip)，由 $($p.NewIp) 接手（確認時有 $($proof.Count) 條連線從新位址進來：$(Format-NetSessions $proof)）。"
        return
    }
    Unregister-ScheduledTask -TaskName $Script:NetTask -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $Script:NetStateKey -Recurse -Force -ErrorAction SilentlyContinue
    if ($p.Kind -eq 'Add') { "[完成] 看門狗已取消，$($p.Ip) 保留在 [$($p.Adapter)]。" }
    else { "[完成] 看門狗已取消，$($p.Ip) 不會再加回來。" }
}

# DNS：在介面執行緒先檢查輸入，真正的查詢、套用、驗證放背景（查不到時每台要等幾秒）
function Get-NetDnsPlan {
    param([string]$Alias, [string]$Dns, [string]$TestName, [switch]$Reset)
    $info = Get-NetAdapterInfo $Alias
    $cur = Get-NetDnsInfo $info
    if ($TestName -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') { throw "驗證用網域「$TestName」格式不對。" }
    if ($Reset) {
        if (-not $info.Dhcp) { throw "網卡 [$($info.Alias)] 是固定 IP，沒有 DHCP 會給 DNS；改回自動等於一台 DNS 都不剩。" }
        if (-not $cur.Static) { throw "網卡 [$($info.Alias)] 的 DNS 本來就是自動取得。" }
        $servers = @()
    } else {
        $servers = @($Dns -split '[,;，、\s]+' | Where-Object { $_ })
        if (-not $servers.Count) { throw '至少要留一台 DNS。（DHCP 網卡要改回自動取得，請按「DNS 改回自動」。）' }
        foreach ($s in $servers) { if (-not (Test-NetIpv4Text $s)) { throw "「$s」不是 IPv4 位址（只支援 IPv4 的 DNS）。" } }
        if (@($servers | Sort-Object -Unique).Count -ne $servers.Count) { throw 'DNS 清單裡有重複。' }
        if ($cur.Static -and ($servers -join ',') -eq ($cur.Servers -join ',')) { throw '和目前的設定一樣，不用改。' }
    }
    [pscustomobject]@{ Info = $info; Cur = $cur; Servers = $servers; TestName = $TestName }
}

$Script:WorkerNetDns = @'
param([int]$Index, [string]$Servers, [string]$TestName, [string]$WasStatic, [string]$Before)
$ErrorActionPreference = 'Continue'
$new = @($Servers.Split(',') | Where-Object { $_ })
$old = @($Before.Split(',') | Where-Object { $_ })
function Test-SystemDns {
    Clear-DnsClientCache
    $r = @(Resolve-DnsName -Name $TestName -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress })
    $r.Count -gt 0
}
function Restore-Dns {
    if ($WasStatic -eq '1') { Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $old -ErrorAction Stop }
    else { Set-DnsClientServerAddress -InterfaceIndex $Index -ResetServerAddresses -ErrorAction Stop }
    "  已改回：$(@((Get-DnsClientServerAddress -InterfaceIndex $Index -AddressFamily IPv4).ServerAddresses) -join ', ')" + $(if ($WasStatic -eq '1') { '' } else { '（自動取得）' })
}
foreach ($s in $new) {
    $r = @(Resolve-DnsName -Name $TestName -Server $s -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress })
    if (-not $r.Count) {
        Write-Error "DNS $s 查不到 $TestName，這次不改。（內網 DNS 查不到外部網域時，把「驗證用網域」改成內部網域。）"
        return
    }
    "  $s 查得到 $TestName（$($r[0].IPAddress)）"
}
$before = Test-SystemDns
try {
    if ($new.Count) { Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $new -ErrorAction Stop }
    else { Set-DnsClientServerAddress -InterfaceIndex $Index -ResetServerAddresses -ErrorAction Stop }
} catch {
    Write-Error "套用失敗：$($_.Exception.Message)"
    try { Restore-Dns } catch { }
    return
}
Start-Sleep -Milliseconds 500
$now = @((Get-DnsClientServerAddress -InterfaceIndex $Index -AddressFamily IPv4).ServerAddresses)
"  套用後讀回：$($now -join ', ')"
if ($new.Count -and ($now -join ',') -ne ($new -join ',')) {
    Restore-Dns
    Write-Error "讀回來的清單和設定的不一樣，已改回原本的設定。"
    return
}
if (Test-SystemDns) {
    "[完成] DNS 已更新，系統解析 $TestName 正常。"
} elseif ($before) {
    "  改之後系統解析不到 $TestName（改之前可以），自動改回原本的設定…"
    Restore-Dns
    if (Test-SystemDns) { "  改回後解析恢復正常。" } else { "  改回後仍解析不到，請手動檢查。" }
    Write-Error "新的 DNS 設定讓系統解析失敗，已還原。"
} else {
    "[注意] 改之前系統就解析不到 $TestName，改之後也一樣；設定保留，請自行確認網路。"
}
'@

function Get-NetSetStatus {
    $p = Get-NetPending
    if ($p) {
        $desc = switch ($p.Kind) {
            'Add'     { "新增 $($p.Ip)/$($p.Prefix)" }
            'Remove'  { "移除 $($p.Ip)" }
            'Replace' { "替換 $($p.Ip) → $($p.NewIp)（新舊並存中）" }
        }
        $task = Get-ScheduledTask -TaskName $Script:NetTask -ErrorAction SilentlyContinue
        if ($task) {
            $at = $null
            try { $at = [datetime]$task.Triggers[0].StartBoundary } catch { }
            "▶ 進行中：[$($p.Adapter)] $desc，尚未確認。" + $(if ($at) { "看門狗會在 $($at.ToString('HH:mm:ss')) 自動還原。" } else { '' })
        } else {
            "▶ 進行中：[$($p.Adapter)] $desc，但看門狗已經不在了！請手動「確認 IP 變更」或「立即還原」。"
        }
    } else { '沒有進行中的 IP 變更。' }
    $used = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -match '^\d+\.\d+\.\d+\.\d+$' -and $_.LocalAddress -notlike '127.*' -and $_.RemoteAddress -notlike '127.*' } |
        Group-Object LocalAddress | ForEach-Object { "$($_.Name)（$($_.Count) 條）" })
    '連線中使用的本機位址：' + $(if ($used.Count) { $used -join '、' } else { '無' }) + '　← 這些不能移除'
    foreach ($name in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object Name | ForEach-Object Name)) {
        try {
            $info = Get-NetAdapterInfo $name
            $dns = Get-NetDnsInfo $info
            "[$($info.Alias)]　" + $(if ($info.Dhcp) { 'DHCP' } else { '固定 IP' }) + '　閘道：' + $(if ($info.Gateways.Count) { $info.Gateways -join ', ' } else { '無' })
            '　IPv4：' + $(if ($info.Ips.Count) { (@($info.Ips | ForEach-Object {
                "$($_.IPAddress)/$($_.PrefixLength)" + $(if ($_.SkipAsSource) { '（只收不發）' } else { '' }) + $(if ($_.AddressState -ne 'Preferred') { "（$($_.AddressState)）" } else { '' })
            }) -join '、') } else { '無' })
            '　DNS：' + $(if ($dns.Servers.Count) { $dns.Servers -join ', ' } else { '無' }) + $(if ($dns.Static) { '（手動）' } else { '（自動取得）' })
        } catch { "[$name] 讀取失敗：$($_.Exception.Message)" }
    }
}

function Show-NetSetPanel {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Sort-Object Name | ForEach-Object Name)
    $defRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $defAlias = if ($defRoute) { (Get-NetAdapter -InterfaceIndex $defRoute.ifIndex -ErrorAction SilentlyContinue).Name } else { $null }
    $defDns = if ($defRoute) { (@((Get-DnsClientServerAddress -InterfaceIndex $defRoute.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ', ') } else { '' }
    Show-FeaturePanel -Title 'IP / DNS 設定' -Subtitle '新舊位址並存 + 看門狗自動還原；DNS 改完實際解析驗證' -Width 900 -Height 740 `
        -Note '位址的新增／移除／替換都會開看門狗，時限內沒按「確認 IP 變更」就自動還原。替換分兩階段：先加新位址，用新位址重新連線後再確認，才移除舊位址。有連線在用的位址不能移除。只做 IPv4、不改閘道；DHCP 網卡只能改 DNS。新加的位址只收不發，對外連線仍用原本的位址。' `
        -Status { Get-NetSetStatus } `
        -Inputs @(
            @{ Name = 'Adapter'; Label = '網卡'; Type = 'Combo'; Items = $adapters; Default = $defAlias }
            @{ Name = 'Ip'; Label = 'IP（新增／移除；替換時填舊的）'; Type = 'Text'; Width = 200 }
            @{ Name = 'Prefix'; Label = '前綴長度（新增用）'; Type = 'Number'; Min = 1; Max = 32; Default = 24 }
            @{ Name = 'NewIp'; Label = '替換成的新 IP'; Type = 'Text'; Width = 200 }
            @{ Name = 'Minutes'; Label = '看門狗時限（分鐘）'; Type = 'Number'; Min = 1; Max = 60; Default = 5 }
            @{ Name = 'Dns'; Label = 'DNS（逗號分隔，依優先順序）'; Type = 'Text'; Width = 320; Default = $defDns }
            @{ Name = 'TestName'; Label = '驗證 DNS 用的網域'; Type = 'Text'; Width = 200; Default = 'cloudflare.com' }
        ) `
        -Actions @(
            @{ Text = '新增 IP'; Style = 'primary'; Admin = $true; Width = 120
               Confirm = { param($v) if (Test-NetIpv4Text $v.Ip) { "將在 [$($v.Adapter)] 新增 $($v.Ip)/$($v.Prefix)（只收不發，不改閘道），看門狗 $($v.Minutes) 分鐘。確定？" } else { '' } }
               Run = { param($v) Invoke-NetIpAdd -Alias $v.Adapter -Ip $v.Ip -Prefix $v.Prefix -Minutes $v.Minutes } }
            @{ Text = '移除 IP'; Style = 'danger'; Admin = $true; Width = 120
               Confirm = { param($v) if (Test-NetIpv4Text $v.Ip) { "將從 [$($v.Adapter)] 移除 $($v.Ip)，看門狗 $($v.Minutes) 分鐘內沒確認會自動加回來。確定？" } else { '' } }
               Run = { param($v) Invoke-NetIpRemove -Alias $v.Adapter -Ip $v.Ip -Minutes $v.Minutes } }
            @{ Text = '替換 IP（新舊並存）'; Style = 'danger'; Admin = $true
               Confirm = { param($v) if ((Test-NetIpv4Text $v.Ip) -and (Test-NetIpv4Text $v.NewIp)) { "第一階段：在 [$($v.Adapter)] 加上 $($v.NewIp)，和 $($v.Ip) 並存，看門狗 $($v.Minutes) 分鐘。`r`n舊位址要等你從新位址連進來、按「確認 IP 變更」才會移除。確定？" } else { '' } }
               Run = { param($v) Invoke-NetIpReplace -Alias $v.Adapter -Ip $v.Ip -NewIp $v.NewIp -Minutes $v.Minutes } }
            @{ Text = '確認 IP 變更'; Style = 'success'; Admin = $true; Width = 140
               Confirm = { Get-NetConfirmPrompt }
               Run = { Invoke-NetConfirm } }
            @{ Text = '立即還原'; Style = 'danger'; Admin = $true; Width = 120
               Confirm = '把網卡改回這次 IP 變更之前的樣子，並取消看門狗。確定？'
               Run = { Undo-NetChange } }
            @{ Text = '設定 DNS'; Style = 'primary'; Admin = $true; Width = 120
               Run = {
                   param($v)
                   $plan = Get-NetDnsPlan -Alias $v.Adapter -Dns $v.Dns -TestName $v.TestName
                   "[$($plan.Info.Alias)] DNS：$(if ($plan.Cur.Servers.Count) { $plan.Cur.Servers -join ', ' } else { '無' }) → $($plan.Servers -join ', ')"
                   "先向每台新 DNS 查 $($plan.TestName)，查得到才改；改完用系統解析驗證，失敗會自動改回去。"
               }
               Worker = $Script:WorkerNetDns
               WorkerArgs = { param($v) $plan = Get-NetDnsPlan -Alias $v.Adapter -Dns $v.Dns -TestName $v.TestName
                   @($plan.Info.Index, ($plan.Servers -join ','), $plan.TestName, $(if ($plan.Cur.Static) { '1' } else { '0' }), ($plan.Cur.Servers -join ',')) } }
            @{ Text = 'DNS 改回自動'; Style = 'light'; Admin = $true; Width = 130
               Run = {
                   param($v)
                   $plan = Get-NetDnsPlan -Alias $v.Adapter -TestName $v.TestName -Reset
                   "[$($plan.Info.Alias)] DNS：$($plan.Cur.Servers -join ', ') → 自動取得（DHCP）；改完用系統解析驗證，失敗會自動改回去。"
               }
               Worker = $Script:WorkerNetDns
               WorkerArgs = { param($v) $plan = Get-NetDnsPlan -Alias $v.Adapter -TestName $v.TestName -Reset
                   @($plan.Info.Index, '', $plan.TestName, '1', ($plan.Cur.Servers -join ',')) } }
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
    $ex=Get-EventExplain $EventRecord; $subj=Get-EventSubject $EventRecord
    [void]$sb.AppendLine("這代表什麼：$($ex.What)$(if($subj){"（$subj）"})")
    if($ex.Do){[void]$sb.AppendLine("建議怎麼做：$($ex.Do)")}
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('--- 技術資料（查資料或回報問題時用）---')
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
    # 首頁＝健康檢查：打開就在背景掃 7 個情境，每個情境一張卡片（沒事／有幾筆要注意／需要管理員）。
    # 點卡片才看清單；清單只有「時間、這代表什麼、建議怎麼做」，事件 ID、來源收進詳細內容與 CSV。
    $win = New-UiWindow -Title '事件檢視器' -Subtitle '這台電腦最近有沒有出狀況？打開就自動檢查，點卡片看細節' -Width 1100 -Height 780
    $form = $win.Form
    $script:EventViewerForm = $form
    # 閉包裡的 $Script: 不是這支腳本，要用的值先在這一層取出來
    $worker = $Script:WorkerEvents
    $scen = @(Get-EventScenarios)
    $cOk = [Drawing.Color]::FromArgb(21, 128, 61); $cWarn = [Drawing.Color]::FromArgb(180, 83, 9)
    $cGray = [Drawing.Color]::FromArgb(100, 116, 139); $cBad = [Drawing.Color]::FromArgb(185, 28, 28)
    $cWarnBg = [Drawing.Color]::FromArgb(254, 249, 195)
    $ctx = @{ Days = 7; Results = @{}; Busy = $false; Current = $null; Rows = @(); CustomName = ''; Cards = @{} }

    # ---- 上方：時間範圍、重新檢查、總結
    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.Height = 50
    $lblRange = New-Object Windows.Forms.Label; $lblRange.Text = '檢查範圍'; $lblRange.AutoSize = $true; $lblRange.Margin = New-Object Windows.Forms.Padding(0, 9, 6, 0)
    $range = New-Object Windows.Forms.ComboBox; $range.DropDownStyle = 'DropDownList'; $range.Width = 140; $range.Margin = New-Object Windows.Forms.Padding(0, 5, 10, 0)
    foreach ($t in '最近 24 小時', '最近 7 天', '最近 30 天') { [void]$range.Items.Add($t) }
    $range.SelectedIndex = 1
    $btnScan = New-UiButton '重新檢查' primary 110
    $summary = New-Object Windows.Forms.Label; $summary.AutoSize = $true; $summary.Margin = New-Object Windows.Forms.Padding(10, 8, 0, 0); $summary.Font = New-UiFont 11 -Bold
    $bar.Controls.Add($lblRange); $bar.Controls.Add($range); $bar.Controls.Add($btnScan); $bar.Controls.Add($summary)

    # ---- 首頁：卡片
    $homeView = New-Object Windows.Forms.FlowLayoutPanel
    $homeView.Dock = 'Fill'; $homeView.AutoScroll = $true; $homeView.Padding = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    foreach ($s in $scen) {
        $card = New-Object Windows.Forms.Panel
        $card.Size = New-Object Drawing.Size(510, 112); $card.BackColor = [Drawing.Color]::White; $card.BorderStyle = 'FixedSingle'
        $card.Margin = New-Object Windows.Forms.Padding(0, 0, 14, 14); $card.Cursor = 'Hand'
        $title = New-Object Windows.Forms.Label; $title.Text = $s.Name; $title.AutoSize = $true; $title.Location = New-Object Drawing.Point(14, 10); $title.Font = New-UiFont 12 -Bold
        $state = New-Object Windows.Forms.Label; $state.Text = '檢查中…'; $state.AutoSize = $true; $state.Location = New-Object Drawing.Point(14, 40); $state.Font = New-UiFont 10.5 -Bold; $state.ForeColor = $cGray
        $hint = New-Object Windows.Forms.Label; $hint.Text = $s.Hint; $hint.AutoSize = $true; $hint.MaximumSize = New-Object Drawing.Size(480, 0); $hint.Location = New-Object Drawing.Point(14, 70); $hint.ForeColor = $cGray
        $card.Controls.Add($title); $card.Controls.Add($state); $card.Controls.Add($hint)
        $ctx.Cards[$s.Key] = @{ Panel = $card; State = $state }
        $homeView.Controls.Add($card)
    }

    # ---- 清單頁
    $listView = New-Object Windows.Forms.Panel
    $listView.Dock = 'Fill'; $listView.Visible = $false
    $listHead = New-Object Windows.Forms.Panel; $listHead.Dock = 'Top'; $listHead.Height = 78
    $btnBack = New-UiButton '← 回到總覽' light 130
    $btnBack.Location = New-Object Drawing.Point(0, 4)
    $listTitle = New-Object Windows.Forms.Label; $listTitle.AutoSize = $true; $listTitle.Location = New-Object Drawing.Point(146, 6); $listTitle.Font = New-UiFont 13 -Bold
    $listHint = New-Object Windows.Forms.Label; $listHint.AutoSize = $true; $listHint.MaximumSize = New-Object Drawing.Size(1020, 0); $listHint.Location = New-Object Drawing.Point(2, 48)
    $listHead.Controls.Add($btnBack); $listHead.Controls.Add($listTitle); $listHead.Controls.Add($listHint)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
    $grid.MultiSelect = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'Fill'; $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [Drawing.Color]::White; $grid.BorderStyle = 'None'
    $grid.DefaultCellStyle.WrapMode = 'True'; $grid.AutoSizeRowsMode = 'AllCells'
    foreach ($c in @(@('When', '時間', 16), @('What', '這代表什麼', 50), @('Do', '建議怎麼做', 40))) {
        $i = $grid.Columns.Add($c[0], $c[1]); $grid.Columns[$i].FillWeight = $c[2]
    }
    $listView.Controls.Add($grid); $listView.Controls.Add($listHead)

    # Fill 先加、Top 後加（後加的先排版）
    $win.Body.Controls.Add($homeView); $win.Body.Controls.Add($listView); $win.Body.Controls.Add($bar)

    # ---- 底部按鈕（底部列是由右往左排，「關閉視窗」在最右邊）
    $btnDetail = New-UiButton '查看詳細' primary 110
    $btnCsv = New-UiButton '匯出 CSV' success 110
    $btnCustom = New-UiButton '自訂查詢（進階）' light 160
    foreach ($b in $btnDetail, $btnCsv, $btnCustom) { $win.Footer.Controls.Add($b) }
    $btnAdmin = $null
    if (-not $IsAdmin) { $btnAdmin = New-UiButton '以管理員重新開啟' light 160; $win.Footer.Controls.Add($btnAdmin) }

    # ---- 下面的閉包都直接建在這一層，只用這一層的變數
    $renderCards = {
        $need = 0; $pending = 0
        foreach ($s in $scen) {
            $card = $ctx.Cards[$s.Key]
            $r = $ctx.Results[$s.Key]
            $card.Panel.BackColor = [Drawing.Color]::White
            if (-not $r) { $card.State.Text = '檢查中…'; $card.State.ForeColor = $cGray; $pending++; continue }
            $rows = @($r.Rows)
            $warn = @($rows | Where-Object { (Get-EventExplain $_).Warn })
            if ($r.Problems.Count -and -not $rows.Count) {
                if ($s.NeedAdmin -and -not $IsAdmin) { $card.State.Text = '● 需要管理員權限才看得到（點一下可以提權）'; $card.State.ForeColor = $cGray }
                else { $card.State.Text = '✖ 讀不到這類紀錄（點一下看原因）'; $card.State.ForeColor = $cBad }
            } elseif ($warn.Count) {
                $need++
                $card.State.Text = "⚠ $($warn.Count) 筆需要注意　最近一次 $($warn[0].TimeCreated.ToString('MM-dd HH:mm'))"
                $card.State.ForeColor = $cWarn; $card.Panel.BackColor = $cWarnBg
            } elseif ($rows.Count) { $card.State.Text = "✔ 沒有異常（有 $($rows.Count) 筆一般紀錄）"; $card.State.ForeColor = $cOk }
            else { $card.State.Text = '✔ 沒有異常'; $card.State.ForeColor = $cOk }
        }
        $span = @('24 小時', '7 天', '30 天')[[Array]::IndexOf(@(1, 7, 30), $ctx.Days)]
        if ($pending) { $summary.Text = "正在檢查最近 $span …"; $summary.ForeColor = $cGray }
        elseif ($need) { $summary.Text = "最近 $span：有 $need 類需要注意，點黃色卡片看細節"; $summary.ForeColor = $cWarn }
        else { $summary.Text = "最近 $span：沒有發現異常"; $summary.ForeColor = $cOk }
    }.GetNewClosure()

    $fillList = {
        param([string]$Key, [string]$Name, [string]$Hint, [int]$Days)
        $r = $ctx.Results[$Key]
        $ctx.Current = $Key
        $grid.Rows.Clear()
        $ctx.Rows = if ($r) { @($r.Rows) } else { @() }
        $listTitle.Text = $Name
        $span = if ($Days -eq 1) { '24 小時' } else { "$Days 天" }
        # 要注意的全部列出；一般紀錄只列最近的，免得幾百筆把畫面塞滿（CSV 還是匯出全部）
        $warnRows = @($ctx.Rows | Where-Object { (Get-EventExplain $_).Warn })
        $normal = @($ctx.Rows | Where-Object { -not (Get-EventExplain $_).Warn })
        $keep = [Math]::Max(50, 300 - $warnRows.Count)
        # 需要注意的排最前面（各自新到舊），新手一打開就看到
        $show = @(@($warnRows) + @($normal | Select-Object -First $keep))
        $text = "$Hint　（最近 $span：$($warnRows.Count) 筆需要注意（黃底、排在最前面）、$($normal.Count) 筆一般紀錄；點兩下看詳細）"
        if ($normal.Count -gt $keep) { $text += "`r`n一般紀錄太多，畫面只列最近 $keep 筆；「匯出 CSV」會匯出全部 $($ctx.Rows.Count) 筆。" }
        if (-not $ctx.Rows.Count) { $text = "$Hint　（最近 $span 沒有任何紀錄）" }
        if ($r -and $r.Problems.Count) { $text += "`r`n有些紀錄讀不到：" + ($r.Problems -join '；') }
        $listHint.Text = $text
        $listHint.ForeColor = if ($r -and $r.Problems.Count) { $cBad } else { $cGray }
        foreach ($ev in $show) {
            $ex = Get-EventExplain $ev
            $subj = Get-EventSubject $ev
            $what = if ($subj) { "$($ex.What)：$subj" } else { $ex.What }
            $i = $grid.Rows.Add($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $what, $ex.Do)
            $grid.Rows[$i].Tag = $ev
            if ($ex.Warn) { $grid.Rows[$i].DefaultCellStyle.BackColor = $cWarnBg }
        }
        $homeView.Visible = $false; $listView.Visible = $true
    }.GetNewClosure()

    $setBusy = {
        param([bool]$On)
        $ctx.Busy = $On
        foreach ($b in $btnScan, $btnCustom, $range) { $b.Enabled = -not $On }
    }.GetNewClosure()

    $onScanned = {
        param($out, $err)
        & $setBusy $false
        foreach ($k in @($ctx.Sync.Keys)) { $ctx.Results[$k] = $ctx.Sync[$k] }
        foreach ($s in $scen) { if (-not $ctx.Results[$s.Key]) { $ctx.Results[$s.Key] = @{ Rows = @(); Problems = @("檢查沒有完成：$(@($err) -join '；')") } } }
        & $renderCards
        $cur = $scen | Where-Object { $_.Key -eq $ctx.Current } | Select-Object -First 1
        if ($cur -and $listView.Visible) { & $fillList $cur.Key $cur.Name $cur.Hint $ctx.Days }
    }.GetNewClosure()

    $scan = {
        if ($ctx.Busy) { return }
        & $setBusy $true
        $ctx.Results = @{}
        & $renderCards
        $ctx.Sync = [hashtable]::Synchronized(@{})
        $jobs = @($scen | ForEach-Object { @{ Key = $_.Key; Queries = $_.Queries } })
        Start-UiBackground -Form $form -Script $worker -Arguments @($jobs, $ctx.Days, $ctx.Sync) -OnDone $onScanned -AllowClose
    }.GetNewClosure()

    $onCustom = {
        param($out, $err)
        & $setBusy $false
        $ctx.Results['custom'] = if ($ctx.Sync['custom']) { $ctx.Sync['custom'] } else { @{ Rows = @(); Problems = @("查詢沒有完成：$(@($err) -join '；')") } }
        & $fillList 'custom' $ctx.CustomName '自訂查詢的結果。' $ctx.CustomDays
    }.GetNewClosure()

    $openCard = {
        param($s)
        $r = $ctx.Results[$s.Key]
        if (-not $r) { return }
        if ($s.NeedAdmin -and -not $IsAdmin -and $r.Problems.Count -and -not @($r.Rows).Count) {
            $answer = [Windows.Forms.MessageBox]::Show($form, '登入與帳號的紀錄（Security 記錄檔）要系統管理員才看得到。要以管理員身分重新開啟面板嗎？', '需要管理員權限', 'YesNo', 'Question')
            if ($answer -eq 'Yes') { [void](Restart-AsAdmin) }
            return
        }
        & $fillList $s.Key $s.Name $s.Hint $ctx.Days
    }.GetNewClosure()

    foreach ($s in $scen) {
        $card = $ctx.Cards[$s.Key]
        $one = $s
        $click = { & $openCard $one }.GetNewClosure()
        $card.Panel.Add_Click($click)
        foreach ($c in $card.Panel.Controls) { $c.Add_Click($click) }
    }

    $btnBack.Add_Click({ $listView.Visible = $false; $homeView.Visible = $true; $ctx.Current = $null }.GetNewClosure())
    $btnScan.Add_Click({ & $scan }.GetNewClosure())
    $range.Add_SelectedIndexChanged({ $ctx.Days = @(1, 7, 30)[$range.SelectedIndex]; & $scan }.GetNewClosure())
    $showDetail = {
        if (-not $listView.Visible -or -not $grid.SelectedRows.Count) { [void][Windows.Forms.MessageBox]::Show($form, '請先點一張卡片，再選一筆紀錄。', '查看詳細', 'OK', 'Information'); return }
        Show-EventDetailDialog $grid.SelectedRows[0].Tag
    }.GetNewClosure()
    $grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $showDetail } }.GetNewClosure())
    $btnDetail.Add_Click({ & $showDetail }.GetNewClosure())
    $btnCustom.Add_Click({
        if ($ctx.Busy) { return }
        $q = Show-CustomEventQueryDialog
        if (-not $q) { return }
        $ctx.CustomName = $q.Name
        & $setBusy $true
        $ctx.Sync = [hashtable]::Synchronized(@{})
        $ctx.CustomDays = $q.Days
        Start-UiBackground -Form $form -Script $worker -Arguments @(@(@{ Key = 'custom'; Queries = $q.Queries }), $q.Days, $ctx.Sync) -OnDone $onCustom -AllowClose
    }.GetNewClosure())
    $btnCsv.Add_Click({
        if (-not $listView.Visible -or -not $ctx.Rows.Count) { [void][Windows.Forms.MessageBox]::Show($form, '請先點一張有紀錄的卡片，再匯出。', '匯出 CSV', 'OK', 'Information'); return }
        $save = New-Object Windows.Forms.SaveFileDialog
        $save.Filter = 'CSV 檔案 (*.csv)|*.csv'
        $save.FileName = ('事件紀錄-{0}-{1}.csv' -f ($listTitle.Text -replace '[\\/:*?"<>| ]', '_'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            if ($save.ShowDialog($form) -ne 'OK') { return }
            $ctx.Rows | ForEach-Object {
                $ex = Get-EventExplain $_; $subj = Get-EventSubject $_
                [pscustomobject][ordered]@{
                    '時間' = $_.TimeCreated; '這代表什麼' = $(if ($subj) { "$($ex.What)：$subj" } else { $ex.What }); '建議怎麼做' = $ex.Do
                    '需要注意' = $(if ($ex.Warn) { '是' } else { '' }); '記錄檔' = $_.LogName; '來源' = $_.ProviderName; '事件ID' = $_.Id
                    '層級' = $_.LevelDisplayName; '原始描述' = ($_.Message -replace "`r?`n", ' ')
                }
            } | Export-Csv -Path $save.FileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            [void][Windows.Forms.MessageBox]::Show($form, "已匯出 $($ctx.Rows.Count) 筆：`r`n$($save.FileName)", '完成', 'OK', 'Information')
        } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '匯出失敗', 'OK', 'Error') }
        finally { $save.Dispose() }
    }.GetNewClosure())
    if ($btnAdmin) { $btnAdmin.Add_Click({ [void](Restart-AsAdmin) }.GetNewClosure()) }

    $form.Add_Shown({ & $scan }.GetNewClosure())
    Show-UiWindow $win
    $script:EventViewerForm = $null
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
        @{Title='長時間作業不卡畫面';Body='Hyper-V、校時、Windows 更新在背景執行；會改系統的要等做完才能關視窗，只是查詢的可以直接關。'}
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
        @{Title='常用軟體安裝（winget）';Action={Show-AppsPanel};Style='success'}
    )
    & $addSection '網路與防火牆' @(
        @{Title='Ping (ICMP) 設定';Action={Show-PingPanel};Style='info'}
        @{Title='OpenSSH Server（SSH 連線）';Action={Show-SshServerPanel};Style='info'}
        @{Title='IP / DNS 設定（含看門狗）';Action={Show-NetSetPanel};Style='danger'}
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
#
# 介面大量用 .GetNewClosure()，閉包只看得到「全域」的函式。用 -File 啟動（.bat、ops-win.ps1、
# 提權重開）時腳本就在全域，沒問題；但在 PowerShell 視窗裡打 .\Win_Admin_Tool.ps1 或用 & 呼叫時，
# 函式定義在子範圍，按鈕一按就是「無法辨識詞彙」（測試機實測）。這種情況改用 -File 另開一個。
# （檢查放在這個 try 裡：測試程式載入函式時會切在「第一個呼叫 Show-WindowsPanel 的敘述」之前。）
try {
    if (@(& ({ Get-Command Get-SelfPath -CommandType Function -ErrorAction SilentlyContinue }.GetNewClosure())).Count) {
        Show-WindowsPanel
    } else {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Get-SelfPath)`"" -ErrorAction Stop
    }
} catch {
    try { Add-Type -AssemblyName System.Windows.Forms } catch { }
    Show-PanelError -Title '面板無法啟動' -ErrorRecord $_
}
