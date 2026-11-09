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

function Get-ManagedTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like 'OPS-Task-*' -and $_.Description -like "$script:Marker*"
    } | ForEach-Object {
        $task = $_
        try { $meta = $task.Description.Substring($script:Marker.Length) | ConvertFrom-Json }
        catch { return }
        [pscustomobject]@{ Task=$task; Meta=$meta; State=[string]$task.State }
    })
}

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
            $switch=if($meta.Action -eq '關機'){'/s'}else{'/r'}
            $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\shutdown.exe" -Argument "$switch /t $($meta.Arguments)"
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
$footer=New-Object Windows.Forms.Panel; $footer.Dock='Bottom'; $footer.Height=42; $footer.BackColor=[Drawing.Color]::FromArgb(219,234,254)
$note=New-Object Windows.Forms.Label; $note.Dock='Fill'; $note.Text='此面板只管理 OPS-command 建立的排程；倒數期間可用 shutdown /a 取消關機／重啟。'; $note.TextAlign='MiddleLeft'; $note.Padding=New-Object Windows.Forms.Padding(8,0,0,0); $footer.Controls.Add($note)
$closePanel=New-Object Windows.Forms.Button; $closePanel.Text='關閉視窗'; $closePanel.Dock='Right'; $closePanel.Width=100; $closePanel.FlatStyle='Flat'; $closePanel.BackColor=[Drawing.Color]::FromArgb(254,226,226); $closePanel.ForeColor=[Drawing.Color]::FromArgb(153,27,27); $closePanel.Add_Click({$form.Close()}.GetNewClosure()); $footer.Controls.Add($closePanel)
$form.Controls.Add($tabs); $form.Controls.Add($footer)
[void]$form.ShowDialog()
