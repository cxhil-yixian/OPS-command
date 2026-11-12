# Windows schedule panel for OPS-command.
# Uses Windows PowerShell 5.1 + .NET WinForms; tasks are user-scoped and created by this panel.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Marker = 'OPS-command-managed:'
$script:CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
# 從主面板開啟時用主面板的操作記錄；單獨執行時沒有就略過
function Write-TaskLog($action, $result, $detail) { if (Get-Command Write-OpsLog -ErrorAction SilentlyContinue) { Write-OpsLog '自動排程' $action $result $detail } }

function New-TaskDefinition($meta, $action, $trigger) {
    $principal = New-ScheduledTaskPrincipal -UserId $script:CurrentUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $name = 'OPS-Task-' + [guid]::NewGuid().ToString('N')
    $description = $script:Marker + ($meta | ConvertTo-Json -Compress)
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -ErrorAction Stop | Out-Null
}

function Get-ScheduleTrigger($mode, $date, $days) {
    switch ($mode) {
        '登入時' { return New-ScheduledTaskTrigger -AtLogOn -User $script:CurrentUser }
        '單次'   { return New-ScheduledTaskTrigger -Once -At $date }
        '每天'   { return New-ScheduledTaskTrigger -Daily -At $date }
        '每週'   {
            if (-not $days -or $days.Count -eq 0) { throw '每週排程至少要選一天。' }
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $days -At $date
        }
        default  { throw '不支援的排程類型。' }
    }
}

function Show-TaskDialog($kind, $scheduleAction, $registerAction) {
    $form = New-Object Windows.Forms.Form
    # 畫面顯示中文星期，建排程時換回 New-ScheduledTaskTrigger 要的英文名稱
    $dayMap = [ordered]@{ '星期一'='Monday'; '星期二'='Tuesday'; '星期三'='Wednesday'; '星期四'='Thursday'; '星期五'='Friday'; '星期六'='Saturday'; '星期日'='Sunday' }
    $form.Text = switch ($kind) { 'Startup' {'新增登入啟動程式'} 'Script' {'新增定時腳本'} default {'新增關機／重新啟動'} }
    $form.Size = New-Object Drawing.Size(590, 390)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object Drawing.Font('Microsoft JhengHei UI',10)
    $form.BackColor = [Drawing.Color]::FromArgb(241,245,249)

    function Add-Row($label, $control, $row) {
        $l = New-Object Windows.Forms.Label
        $l.Text=$label; $l.Location=New-Object Drawing.Point(18, (20 + 42*$row)); $l.Size=New-Object Drawing.Size(125, 25)
        $control.Location=New-Object Drawing.Point(150, (17 + 42*$row)); $control.Size=New-Object Drawing.Size(400, 26)
        $form.Controls.Add($l); $form.Controls.Add($control)
    }

    $nameBox = New-Object Windows.Forms.TextBox; Add-Row '顯示名稱' $nameBox 0
    $pathBox = New-Object Windows.Forms.TextBox; Add-Row $(if($kind -eq 'Startup'){'程式路徑'} elseif($kind -eq 'Script'){'腳本路徑'} else {'動作'}) $pathBox 1
    $pathBox.Size=New-Object Drawing.Size(310,26)
    $browse = New-Object Windows.Forms.Button; $browse.Text='瀏覽…'; $browse.Location=New-Object Drawing.Point(470, 59); $browse.Size=New-Object Drawing.Size(80,26); $form.Controls.Add($browse)
    $argBox = New-Object Windows.Forms.TextBox; Add-Row $(if($kind -eq 'Shutdown'){'延遲秒數'} else {'參數'}) $argBox 2
    $schedule = New-Object Windows.Forms.ComboBox; $schedule.DropDownStyle='DropDownList'; [void]$schedule.Items.AddRange(@('單次','每天','每週'))
    if ($kind -eq 'Startup') { [void]$schedule.Items.Add('登入時') }; $schedule.SelectedItem=if($kind -eq 'Startup'){'登入時'}else{'每天'}; Add-Row '執行時機' $schedule 3
    $date = New-Object Windows.Forms.DateTimePicker; $date.Format='Custom'; $date.CustomFormat='yyyy/MM/dd HH:mm'; $date.ShowUpDown=$true; $date.Value=(Get-Date).Date.AddHours(23); Add-Row '日期／時間' $date 4
    $days = New-Object Windows.Forms.CheckedListBox; $days.Items.AddRange([object[]]@($dayMap.Keys)); $days.CheckOnClick=$true; $days.Location=New-Object Drawing.Point(150, 227); $days.Size=New-Object Drawing.Size(400, 52); $days.Visible=$false; $form.Controls.Add($days)
    $dayLabel = New-Object Windows.Forms.Label; $dayLabel.Text='每週日期'; $dayLabel.Location=New-Object Drawing.Point(18,230); $dayLabel.Size=New-Object Drawing.Size(125,25); $dayLabel.Visible=$false; $form.Controls.Add($dayLabel)
    $schedule.add_SelectedIndexChanged({ $show=$schedule.SelectedItem -eq '每週'; $days.Visible=$show; $dayLabel.Visible=$show })

    $browse.Add_Click({
        $dlg=New-Object Windows.Forms.OpenFileDialog
        if ($kind -eq 'Startup') { $dlg.Filter='程式 (*.exe)|*.exe|所有檔案 (*.*)|*.*' }
        elseif ($kind -eq 'Script') { $dlg.Filter='腳本 (*.ps1;*.bat;*.cmd)|*.ps1;*.bat;*.cmd|所有檔案 (*.*)|*.*' }
        else { $dlg.Dispose(); return }
        if ($dlg.ShowDialog() -eq 'OK') { $pathBox.Text=$dlg.FileName; if (-not $nameBox.Text) {$nameBox.Text=[IO.Path]::GetFileNameWithoutExtension($dlg.FileName)} }
        $dlg.Dispose()
    })

    $typeBox = $null
    if ($kind -eq 'Shutdown') {
        $typeBox=New-Object Windows.Forms.ComboBox; $typeBox.DropDownStyle='DropDownList'; [void]$typeBox.Items.AddRange(@('關機','重新啟動')); $typeBox.SelectedIndex=0
        $typeBox.Location=New-Object Drawing.Point(150,59); $typeBox.Size=New-Object Drawing.Size(400,26); $form.Controls.Add($typeBox)
        $browse.Visible=$false; $pathBox.Visible=$false
        $argBox.Text='60'
        $date.Value=(Get-Date).Date.AddDays(1).AddHours(23)
    }

    $ok=New-Object Windows.Forms.Button; $ok.Text='建立'; $ok.Location=New-Object Drawing.Point(370, 300); $ok.Size=New-Object Drawing.Size(85,32); $ok.DialogResult='OK'; $ok.BackColor=[Drawing.Color]::FromArgb(22,101,52); $ok.ForeColor=[Drawing.Color]::White; $ok.FlatStyle='Flat'; $form.Controls.Add($ok)
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='取消'; $cancel.Location=New-Object Drawing.Point(465,300); $cancel.Size=New-Object Drawing.Size(85,32); $cancel.DialogResult='Cancel'; $form.Controls.Add($cancel)
    $form.AcceptButton=$ok; $form.CancelButton=$cancel

    if ($form.ShowDialog() -ne 'OK') { $form.Dispose(); return }
    try {
        $label=$nameBox.Text.Trim()
        $dayNames=@($days.CheckedItems | ForEach-Object { $dayMap[[string]$_] })
        if (-not $label) { throw '請輸入顯示名稱。' }
        $meta=[ordered]@{ Type=$kind; Name=$label; Path=$pathBox.Text.Trim(); Arguments=$argBox.Text.Trim(); Schedule=[string]$schedule.SelectedItem; At=$date.Value.ToString('yyyy-MM-dd HH:mm'); Days=@($days.CheckedItems) }
        if ($kind -eq 'Startup') {
            if (-not (Test-Path $meta.Path -PathType Leaf) -or [IO.Path]::GetExtension($meta.Path) -ne '.exe') { throw '請選擇存在的 .exe 程式。' }
            $trigger=& $scheduleAction '登入時' $date.Value @()
            $action=New-ScheduledTaskAction -Execute $meta.Path -Argument $meta.Arguments -WorkingDirectory (Split-Path $meta.Path)
        } elseif ($kind -eq 'Script') {
            if (-not (Test-Path $meta.Path -PathType Leaf)) { throw '請選擇存在的腳本檔案。' }
            $trigger=& $scheduleAction $meta.Schedule $date.Value $dayNames
            $ext=[IO.Path]::GetExtension($meta.Path).ToLowerInvariant()
            if ($ext -eq '.ps1') { $exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; $actionArgs="-NoProfile -ExecutionPolicy Bypass -File `"$($meta.Path)`" $($meta.Arguments)" }
            elseif ($ext -in @('.bat','.cmd')) {
                $exe="$env:SystemRoot\System32\cmd.exe"
                $actionArgs='/c ""' + $meta.Path + '"'
                if ($meta.Arguments) { $actionArgs += ' ' + $meta.Arguments }
                $actionArgs += '"'
            }
            else { throw '腳本格式只支援 .ps1、.bat、.cmd。' }
            $action=New-ScheduledTaskAction -Execute $exe -Argument $actionArgs -WorkingDirectory (Split-Path $meta.Path)
        } else {
            if ($meta.Arguments -notmatch '^\d+$' -or [int]$meta.Arguments -lt 0 -or [int]$meta.Arguments -gt 3600) { throw '延遲秒數請輸入 0 到 3600。' }
            $meta['Action']=[string]$typeBox.SelectedItem
            $trigger=& $scheduleAction $meta.Schedule $date.Value $dayNames
            $shutdownMode=if($meta.Action -eq '關機'){'/s'}else{'/r'}
            $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\shutdown.exe" -Argument "$shutdownMode /t $($meta.Arguments)"
        }
        & $registerAction $meta $action $trigger
        Write-TaskLog "新增（$kind）" '成功' ("$($meta.Name)；$($meta.Schedule) $($meta.At)；$($meta.Path)$($meta.Action)")
        [Windows.Forms.MessageBox]::Show('排程已建立。','完成','OK','Information') | Out-Null
        $form.Tag='Created'
    } catch { Write-TaskLog "新增（$kind）" '失敗' $_.Exception.Message; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'無法建立','OK','Error') | Out-Null }
    $form.Dispose()
}

function New-TaskTab($title, $type) {
    $tab=New-Object Windows.Forms.TabPage; $tab.Text=$title
    $tab.BackColor=[Drawing.Color]::FromArgb(241,245,249)
    $grid=New-Object Windows.Forms.DataGridView; $grid.Dock='Top'; $grid.Height=330; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.SelectionMode='FullRowSelect'; $grid.MultiSelect=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.RowHeadersVisible=$false; $grid.BackgroundColor=[Drawing.Color]::White; $grid.EnableHeadersVisualStyles=$false; $grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(30,58,138); $grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::White; $grid.DefaultCellStyle.Font=New-Object Drawing.Font('Microsoft JhengHei UI',9); $grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(239,246,255)
    [void]$grid.Columns.Add('Name','名稱'); [void]$grid.Columns.Add('Details','執行內容／時機'); [void]$grid.Columns.Add('State','狀態')
    $panel=New-Object Windows.Forms.FlowLayoutPanel; $panel.Dock='Bottom'; $panel.Height=48; $panel.FlowDirection='LeftToRight'
    $add=New-Object Windows.Forms.Button; $add.Text='新增'; $add.Width=90; $add.FlatStyle='Flat'; $add.BackColor=[Drawing.Color]::FromArgb(22,101,52); $add.ForeColor=[Drawing.Color]::White
    $remove=New-Object Windows.Forms.Button; $remove.Text='移除'; $remove.Width=90; $remove.FlatStyle='Flat'; $remove.BackColor=[Drawing.Color]::FromArgb(153,27,27); $remove.ForeColor=[Drawing.Color]::White
    $disable=New-Object Windows.Forms.Button; $disable.Text='停用'; $disable.Width=90; $disable.FlatStyle='Flat'; $disable.BackColor=[Drawing.Color]::FromArgb(194,65,12); $disable.ForeColor=[Drawing.Color]::White
    $enable=New-Object Windows.Forms.Button; $enable.Text='啟用'; $enable.Width=90; $enable.FlatStyle='Flat'; $enable.BackColor=[Drawing.Color]::FromArgb(30,64,175); $enable.ForeColor=[Drawing.Color]::White
    $refresh=New-Object Windows.Forms.Button; $refresh.Text='重新整理'; $refresh.Width=90; $refresh.FlatStyle='Flat'; $refresh.BackColor=[Drawing.Color]::FromArgb(219,234,254); $refresh.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
    $panel.Controls.AddRange(@($add,$remove,$disable,$enable,$refresh)); $tab.Controls.Add($grid); $tab.Controls.Add($panel)
    if ($type -eq 'Startup') {
        $native=New-Object Windows.Forms.Button; $native.Text='Windows 啟動設定'; $native.Width=130; $native.FlatStyle='Flat'; $native.BackColor=[Drawing.Color]::FromArgb(219,234,254); $native.ForeColor=[Drawing.Color]::FromArgb(30,64,175)
        $native.Add_Click({ Start-Process 'ms-settings:startupapps' })
        $panel.Controls.Add($native)
    }

    $taskMarker=$script:Marker
    $getManagedTasks={
        @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -like 'OPS-Task-*' -and $_.Description -like "$taskMarker*"
        } | ForEach-Object {
            $task=$_
            try { $meta=$task.Description.Substring($taskMarker.Length) | ConvertFrom-Json }
            catch { return }
            [pscustomobject]@{Task=$task;Meta=$meta;State=[string]$task.State}
        })
    }.GetNewClosure()
    $reload={
        $grid.Rows.Clear()
        foreach($item in (& $getManagedTasks | Where-Object {$_.Meta.Type -eq $type})) {
            $m=$item.Meta
            $detail=if($type -eq 'Startup') { "登入時：$($m.Path) $($m.Arguments)" } elseif($type -eq 'Script') { "$($m.Schedule) $($m.At)：$($m.Path) $($m.Arguments)" } else { "$($m.Schedule) $($m.At)：$($m.Action)" }
            $state=if($item.State -eq 'Disabled'){'已停用'}else{'已啟用'}
            $i=$grid.Rows.Add($m.Name,$detail,$state); $grid.Rows[$i].Tag=$item.Task.TaskName
        }
    }.GetNewClosure()
    $refresh.Add_Click($reload)
    $taskLog=${function:Write-TaskLog}; $showTaskDialogAction=${function:Show-TaskDialog}; $scheduleAction=${function:Get-ScheduleTrigger}; $registerAction=${function:New-TaskDefinition}
    $add.Add_Click({ try { & $showTaskDialogAction $type $scheduleAction $registerAction; & $reload } catch { [Windows.Forms.MessageBox]::Show($_.Exception.ToString(),'新增排程失敗',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null } }.GetNewClosure())
    $remove.Add_Click({
        if($grid.SelectedRows.Count -eq 0){return}; $row=$grid.SelectedRows[0]
        if([Windows.Forms.MessageBox]::Show("確定移除「$($row.Cells[0].Value)」？",'確認','YesNo','Warning') -eq 'Yes') {
            try { Unregister-ScheduledTask -TaskName $row.Tag -Confirm:$false -ErrorAction Stop; & $taskLog '移除' '成功' "$($row.Cells[0].Value)（$($row.Tag)）"; & $reload }
            catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'移除失敗','OK','Error') | Out-Null }
        }
    }.GetNewClosure())
    $disable.Add_Click({
        if($grid.SelectedRows.Count -gt 0){try {Disable-ScheduledTask -TaskName $grid.SelectedRows[0].Tag -ErrorAction Stop | Out-Null; & $taskLog '停用' '成功' "$($grid.SelectedRows[0].Cells[0].Value)"; & $reload} catch {[Windows.Forms.MessageBox]::Show($_.Exception.Message,'停用失敗','OK','Error') | Out-Null}}
    }.GetNewClosure())
    $enable.Add_Click({
        if($grid.SelectedRows.Count -gt 0){try {Enable-ScheduledTask -TaskName $grid.SelectedRows[0].Tag -ErrorAction Stop | Out-Null; & $taskLog '啟用' '成功' "$($grid.SelectedRows[0].Cells[0].Value)"; & $reload} catch {[Windows.Forms.MessageBox]::Show($_.Exception.Message,'啟用失敗','OK','Error') | Out-Null}}
    }.GetNewClosure())
    & $reload
    return $tab
}

# ===== 所有排程（唯讀）=====
# 用工作排程器的 COM 介面一次讀完名稱、狀態、上次／下次執行、觸發與動作；
# Get-ScheduledTaskInfo 要一個一個查，幾百個排程會卡好幾秒。
# 這兩個函式會被事件閉包呼叫（透過變數），所以內容必須自給自足、不能再呼叫本檔的其他函式。
function Get-AllTaskRows {
    $resultText = @{
        '0x0'='成功'; '0x1'='失敗（一般錯誤）'; '0x2'='找不到檔案'
        '0x41300'='可以執行'; '0x41301'='正在執行'; '0x41302'='已停用'; '0x41303'='還沒執行過'
        '0x41304'='沒有排定下一次'; '0x41306'='被手動或逾時終止'
        '0x8004131F'='上一次還在跑，這次沒有啟動'; '0x80041326'='工作已停用'
        '0x80070002'='找不到要執行的檔案'; '0x80070005'='權限不足'
        '0x800710E0'='條件不符被拒絕（例如帳號沒登入）'; '0x8004130F'='沒有可用的帳號密碼'
        '0xC000013A'='被中斷（關機或按 Ctrl+C）'; '0xC0000142'='程式無法初始化'
        '0x80004005'='未指定的錯誤'; '0x80040154'='要用的元件沒有註冊'
    }
    $dayNames = @('日','一','二','三','四','五','六')
    $fmtTime = { param($d) if ($d -is [datetime] -and $d.Year -ge 2000) { $d.ToString('yyyy/MM/dd HH:mm') } else { '' } }
    $fmtSpan = {
        param($iso)
        try { $s = [Xml.XmlConvert]::ToTimeSpan($iso) } catch { return $iso }
        if ($s.TotalDays -ge 1 -and $s.TotalDays -eq [math]::Floor($s.TotalDays)) { return "$([int]$s.TotalDays) 天" }
        if ($s.TotalHours -ge 1 -and $s.TotalHours -eq [math]::Floor($s.TotalHours)) { return "$([int]$s.TotalHours) 小時" }
        if ($s.TotalMinutes -ge 1) { return "$([int]$s.TotalMinutes) 分鐘" }
        return "$([int]$s.TotalSeconds) 秒"
    }
    $fmtTrigger = {
        param($t)
        $hm = ''
        if ($t.StartBoundary) { try { $hm = ([datetime]$t.StartBoundary).ToString('HH:mm') } catch { } }
        $txt = switch ([int]$t.Type) {
            0  { '發生指定事件時' }
            1  {
                $at = ''; if ($t.StartBoundary) { try { $at = ([datetime]$t.StartBoundary).ToString('yyyy/MM/dd HH:mm') } catch { } }
                $rep = ''; try { $rep = [string]$t.Repetition.Interval } catch { }
                if ($rep) { "從 $at 起" } else { "單次 $at" }
            }
            2  { if ($t.DaysInterval -gt 1) { "每 $($t.DaysInterval) 天 $hm" } else { "每天 $hm" } }
            3  {
                $d = @(); for ($i = 0; $i -lt 7; $i++) { if ($t.DaysOfWeek -band (1 -shl $i)) { $d += $dayNames[$i] } }
                $w = if ($t.WeeksInterval -gt 1) { "每 $($t.WeeksInterval) 週" } else { '每週' }
                "$w$($d -join '、') $hm"
            }
            4  { "每月指定日期 $hm" }
            5  { "每月第幾週的星期幾 $hm" }
            6  { '電腦閒置時' }
            7  { '建立或修改排程時' }
            8  { '開機時' }
            9  { if ($t.UserId) { "$($t.UserId) 登入時" } else { '任何使用者登入時' } }
            11 { '工作階段變化時（連線、中斷、鎖定、解鎖）' }
            12 { '系統內部條件觸發' }
            default { "其他（類型 $($t.Type)）" }
        }
        try { if ($t.Repetition.Interval) { $txt += $(if ([int]$t.Type -eq 1) { '' } else { '，' }) + "每 $(& $fmtSpan $t.Repetition.Interval)重複" } } catch { }
        if (-not $t.Enabled) { $txt += '（這個觸發已停用）' }
        $txt.Trim()
    }

    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $rows = New-Object System.Collections.Generic.List[object]
    $folders = New-Object System.Collections.Generic.Queue[object]
    $folders.Enqueue($svc.GetFolder('\'))
    while ($folders.Count -gt 0) {
        $f = $folders.Dequeue()
        try { foreach ($sub in $f.GetFolders(0)) { $folders.Enqueue($sub) } } catch { }
        $tasks = try { @($f.GetTasks(1)) } catch { @() }   # 1 = 連隱藏的排程也列出
        foreach ($t in $tasks) {
            $state = switch ([int]$t.State) { 1 {'已停用'} 2 {'排隊中'} 3 {'已啟用'} 4 {'執行中'} default {'不明'} }
            $code = [int]$t.LastTaskResult
            $hex = '0x{0:X}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($code), 0)
            $lastRun = & $fmtTime $t.LastRunTime
            $result = if (-not $lastRun -and $hex -in @('0x0','0x41303')) { '還沒執行過' }
                      elseif ($resultText.ContainsKey($hex)) { $resultText[$hex] } else { "代碼 $hex" }
            $ok = $hex -in @('0x0','0x41300','0x41301','0x41303','0x41304') -or -not $lastRun
            $triggers = @(); $actions = @(); $runAs = ''; $author = ''; $desc = ''; $highest = $false
            try {
                $def = $t.Definition
                foreach ($tr in $def.Triggers) { $triggers += (& $fmtTrigger $tr) }
                foreach ($a in $def.Actions) {
                    $actions += switch ([int]$a.Type) {
                        0 { ("$($a.Path) $($a.Arguments)").Trim() }
                        5 { "COM 元件 $($a.ClassId)" }
                        6 { '寄送電子郵件（Windows 已淘汰）' }
                        7 { '顯示訊息（Windows 已淘汰）' }
                        default { "其他動作（類型 $($a.Type)）" }
                    }
                }
                $p = $def.Principal
                $runAs = if ($p.UserId) { $p.UserId } elseif ($p.GroupId) { "群組 $($p.GroupId)" } else { '' }
                if ($runAs -in @('S-1-5-18','SYSTEM','NT AUTHORITY\SYSTEM')) { $runAs = 'SYSTEM' }
                elseif ($runAs -in @('S-1-5-19','LOCAL SERVICE')) { $runAs = 'LOCAL SERVICE' }
                elseif ($runAs -in @('S-1-5-20','NETWORK SERVICE')) { $runAs = 'NETWORK SERVICE' }
                $highest = ([int]$p.RunLevel -eq 1)
                $author = [string]$def.RegistrationInfo.Author
                $desc = [string]$def.RegistrationInfo.Description
            } catch { $actions += '（沒有權限讀取內容）' }
            $folder = Split-Path -Parent $t.Path; if (-not $folder) { $folder = '\' }
            $source = if ($t.Path -like '\Microsoft\*') { 'Microsoft' } elseif ($t.Name -like 'OPS-*') { 'OPS-command' } else { '其他' }
            $rows.Add([pscustomobject]@{
                Name=$t.Name; Path=$t.Path; Folder=$folder; Source=$source; State=$state
                Trigger=$(if ($triggers.Count) { (@($triggers | Select-Object -Unique) -join '；') } else { '（沒有排定的觸發）' }); Triggers=$triggers; Action=($actions -join '；'); Actions=$actions
                Next=(& $fmtTime $t.NextRunTime); Last=$lastRun; Result=$result; ResultCode=$hex; ResultOk=$ok
                RunAs=$runAs; Highest=$highest; Author=$author; Description=$desc
            })
        }
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($svc) | Out-Null
    $rows | Sort-Object @{e={ switch ($_.Source) { 'OPS-command' {0} '其他' {1} default {2} } }}, Path
}

function Show-AllTaskDetail($r, $owner) {
    $lines = @(
        "名稱：$($r.Name)"
        "位置：$($r.Path)"
        "來源：$($r.Source)"
        "狀態：$($r.State)"
        "執行身分：$($r.RunAs)$(if ($r.Highest) { '（最高權限）' })"
    )
    if ($r.Author) { $lines += "作者：$($r.Author)" }
    if ($r.Description) { $lines += "說明：$($r.Description)" }
    $lines += ''
    $lines += '觸發時機：'
    if ($r.Triggers.Count) { $lines += @($r.Triggers | ForEach-Object { "  ・$_" }) } else { $lines += '  （沒有排定的觸發：可能由 Windows 自動維護、其他程式呼叫或手動執行）' }
    $lines += ''
    $lines += '執行內容：'
    if ($r.Actions.Count) { $lines += @($r.Actions | ForEach-Object { "  ・$_" }) } else { $lines += '  （沒有動作）' }
    $lines += ''
    $lines += "上次執行：$(if ($r.Last) { $r.Last } else { '（沒有紀錄）' })"
    $lines += "上次結果：$($r.Result)（$($r.ResultCode)）"
    $lines += "下次執行：$(if ($r.Next) { $r.Next } else { '（沒有排定）' })"

    $d = New-Object Windows.Forms.Form
    $d.Text = "排程詳細資料｜$($r.Name)"
    $d.Size = New-Object Drawing.Size(720, 520)
    $d.MinimumSize = New-Object Drawing.Size(480, 320)
    $d.StartPosition = 'CenterParent'
    $d.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10)
    $d.BackColor = [Drawing.Color]::FromArgb(241,245,249)
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false
    $box.Dock = 'Fill'; $box.BackColor = [Drawing.Color]::White
    $box.Text = $lines -join "`r`n"
    $bar = New-Object Windows.Forms.Panel; $bar.Dock = 'Bottom'; $bar.Height = 44
    $close = New-Object Windows.Forms.Button; $close.Text = '關閉'; $close.Size = New-Object Drawing.Size(90, 30)
    $close.Anchor = 'Top,Right'; $close.Location = New-Object Drawing.Point(($bar.Width - 100), 7); $close.DialogResult = 'Cancel'
    $bar.Controls.Add($close)
    $d.Controls.Add($box); $d.Controls.Add($bar)
    $d.CancelButton = $close
    $d.Add_Shown({ $box.SelectionStart = 0; $box.SelectionLength = 0; $close.Focus() }.GetNewClosure())
    [void]$d.ShowDialog($owner)
    $d.Dispose()
}

function New-AllTasksTab {
    $tab = New-Object Windows.Forms.TabPage; $tab.Text = '所有排程（唯讀）'
    $tab.BackColor = [Drawing.Color]::FromArgb(241,245,249)

    $top = New-Object Windows.Forms.FlowLayoutPanel; $top.Dock = 'Top'; $top.Height = 40; $top.FlowDirection = 'LeftToRight'; $top.Padding = New-Object Windows.Forms.Padding(4,6,0,0)
    $searchLabel = New-Object Windows.Forms.Label; $searchLabel.Text = '搜尋'; $searchLabel.AutoSize = $true; $searchLabel.Margin = New-Object Windows.Forms.Padding(3,5,3,0)
    $search = New-Object Windows.Forms.TextBox; $search.Width = 240
    $showMs = New-Object Windows.Forms.CheckBox; $showMs.Text = '顯示 Microsoft 的排程（Windows、Office 等，\Microsoft\ 底下）'; $showMs.AutoSize = $true; $showMs.Margin = New-Object Windows.Forms.Padding(14,4,3,0)
    $count = New-Object Windows.Forms.Label; $count.AutoSize = $true; $count.Margin = New-Object Windows.Forms.Padding(14,5,3,0); $count.ForeColor = [Drawing.Color]::FromArgb(71,85,105)
    $top.Controls.AddRange(@($searchLabel, $search, $showMs, $count))

    $grid = New-Object Windows.Forms.DataGridView; $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.RowHeadersVisible = $false; $grid.BackgroundColor = [Drawing.Color]::White; $grid.EnableHeadersVisualStyles = $false; $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(30,58,138); $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::White; $grid.DefaultCellStyle.Font = New-Object Drawing.Font('Microsoft JhengHei UI',9); $grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(239,246,255); $grid.ShowCellToolTips = $true
    foreach ($c in @(@('Name','名稱',18), @('Source','來源',9), @('State','狀態',7), @('Trigger','執行時機',20), @('Next','下次執行',11), @('Last','上次執行',11), @('Result','上次結果',13), @('Action','執行內容',24))) {
        $i = $grid.Columns.Add($c[0], $c[1]); $grid.Columns[$i].FillWeight = $c[2]
    }
    foreach ($n in @('State','Next','Last')) { $grid.Columns[$n].AutoSizeMode = 'AllCells' }

    $panel = New-Object Windows.Forms.FlowLayoutPanel; $panel.Dock = 'Bottom'; $panel.Height = 48; $panel.FlowDirection = 'LeftToRight'; $panel.WrapContents = $false
    $detail = New-Object Windows.Forms.Button; $detail.Text = '詳細資料'; $detail.Width = 100; $detail.FlatStyle = 'Flat'; $detail.BackColor = [Drawing.Color]::FromArgb(30,64,175); $detail.ForeColor = [Drawing.Color]::White
    $refresh = New-Object Windows.Forms.Button; $refresh.Text = '重新整理'; $refresh.Width = 90; $refresh.FlatStyle = 'Flat'; $refresh.BackColor = [Drawing.Color]::FromArgb(219,234,254); $refresh.ForeColor = [Drawing.Color]::FromArgb(30,64,175)
    $native = New-Object Windows.Forms.Button; $native.Text = '開啟工作排程器'; $native.Width = 130; $native.FlatStyle = 'Flat'; $native.BackColor = [Drawing.Color]::FromArgb(219,234,254); $native.ForeColor = [Drawing.Color]::FromArgb(30,64,175)
    $hint = New-Object Windows.Forms.Label; $hint.AutoSize = $true; $hint.Margin = New-Object Windows.Forms.Padding(10,10,3,0); $hint.ForeColor = [Drawing.Color]::FromArgb(71,85,105)
    $hint.Text = '這頁只能看，要修改請用「工作排程器」。'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { $hint.Text += '（不是系統管理員，部分系統排程看不到）' }
    $panel.Controls.AddRange(@($detail, $refresh, $native, $hint))
    $tab.Controls.Add($grid); $tab.Controls.Add($top); $tab.Controls.Add($panel)

    # 閉包會複製變數，所以把要共用、會變動的資料放在同一個雜湊表裡
    $st = @{ Rows = @(); Loaded = $false }
    $getRows = ${function:Get-AllTaskRows}; $showDetail = ${function:Show-AllTaskDetail}
    $fill = {
        $q = $search.Text.Trim()
        $grid.SuspendLayout(); $grid.Rows.Clear()
        $hidden = 0; $shown = 0
        foreach ($r in $st.Rows) {
            if (-not $showMs.Checked -and $r.Source -eq 'Microsoft') { $hidden++; continue }
            if ($q -and ("$($r.Path) $($r.Action) $($r.Description) $($r.Author) $($r.RunAs)").IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $i = $grid.Rows.Add($r.Name, $r.Source, $r.State, $r.Trigger, $r.Next, $r.Last, $r.Result, $r.Action)
            $row = $grid.Rows[$i]; $row.Tag = $r
            $row.Cells[0].ToolTipText = $r.Path
            if (-not $r.ResultOk) { $row.Cells[6].Style.BackColor = [Drawing.Color]::FromArgb(254,226,226); $row.Cells[6].Style.ForeColor = [Drawing.Color]::FromArgb(153,27,27) }
            if ($r.State -eq '已停用') { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(148,163,184) }
            $shown++
        }
        $grid.ResumeLayout()
        $count.Text = "顯示 $shown 個" + $(if ($hidden) { "（另有 $hidden 個 Microsoft 的排程已隱藏）" } else { '' })
    }.GetNewClosure()
    $load = {
        $tab.Cursor = [Windows.Forms.Cursors]::WaitCursor
        $count.Text = '讀取中…'; $count.Refresh()
        try { $st.Rows = @(& $getRows); $st.Loaded = $true; & $fill }
        catch { $count.Text = '讀取失敗'; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'讀取排程失敗','OK','Error') | Out-Null }
        finally { $tab.Cursor = [Windows.Forms.Cursors]::Default }
    }.GetNewClosure()
    $open = {
        if ($grid.SelectedRows.Count -eq 0) { return }
        & $showDetail $grid.SelectedRows[0].Tag $tab.FindForm()
    }.GetNewClosure()

    # 切到這一頁才讀，打開面板不用等
    $tab.add_VisibleChanged({ if ($tab.Visible -and -not $st.Loaded) { & $load } }.GetNewClosure())
    $search.add_TextChanged($fill)
    $showMs.add_CheckedChanged($fill)
    $refresh.Add_Click($load)
    $detail.Add_Click($open)
    $grid.add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { & $open } }.GetNewClosure())
    $native.Add_Click({ Start-Process "$env:SystemRoot\System32\taskschd.msc" })
    return $tab
}

$form=New-Object Windows.Forms.Form
$form.Text='OPS-command｜自動排程管理'
$form.Size=New-Object Drawing.Size(1000,540)
$form.MinimumSize=New-Object Drawing.Size(760,460)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Microsoft JhengHei UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(241,245,249)
$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'
$tabs.TabPages.Add((New-TaskTab '登入啟動程式' 'Startup'))
$tabs.TabPages.Add((New-TaskTab '定時執行腳本' 'Script'))
$tabs.TabPages.Add((New-TaskTab '關機／重新啟動' 'Shutdown'))
$tabs.TabPages.Add((New-AllTasksTab))
$footer=New-Object Windows.Forms.Panel; $footer.Dock='Bottom'; $footer.Height=42; $footer.BackColor=[Drawing.Color]::FromArgb(219,234,254)
$note=New-Object Windows.Forms.Label; $note.Dock='Fill'; $note.Text='前三頁只管理 OPS-command 建立的排程；「所有排程」可查看這台電腦全部的排程。倒數期間可用 shutdown /a 取消關機／重啟。'; $note.TextAlign='MiddleLeft'; $note.Padding=New-Object Windows.Forms.Padding(8,0,0,0); $footer.Controls.Add($note)
$closePanel=New-Object Windows.Forms.Button; $closePanel.Text='關閉視窗'; $closePanel.Dock='Right'; $closePanel.Width=100; $closePanel.FlatStyle='Flat'; $closePanel.BackColor=[Drawing.Color]::FromArgb(254,226,226); $closePanel.ForeColor=[Drawing.Color]::FromArgb(153,27,27); $closePanel.Add_Click({$form.Close()}.GetNewClosure()); $footer.Controls.Add($closePanel)
$form.Controls.Add($tabs); $form.Controls.Add($footer)
[void]$form.ShowDialog()
