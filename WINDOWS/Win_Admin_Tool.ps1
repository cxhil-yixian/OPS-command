# Windows 10/11 系統管理工具 (PowerShell 版)

# ===== 檢查目前是否為系統管理員 (不強制提權,先記錄狀態) =====
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 不要用 SilentlyContinue：那會讓每個失敗都無聲無息，然後畫面照樣印「[完成]」。
# 設成 Continue，錯誤訊息會出現，會改到系統的動作再各自讀回來驗證。
$ErrorActionPreference = 'Continue'

# 這個檔案是 UTF-8。主控台若停在 Big5(950)，部分字元會顯示成亂碼或問號。
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Wait-Enter { Write-Host ""; Read-Host "按 Enter 繼續" | Out-Null }

# 以系統管理員身分重新啟動自己
function Restart-AsAdmin {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 修改類功能的權限守門員:不是管理員就詢問是否提權
function Require-Admin {
    if ($IsAdmin) { return $true }
    Write-Host ""
    Write-Host "[需要權限] 這個功能會『修改』系統設定,必須系統管理員權限才能寫入。"
    $c = Read-Host "要以系統管理員身分重新啟動嗎? (Y=重啟提權 / N=返回)"
    if ($c -match '^[Yy]$') { Restart-AsAdmin }
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
$Script:RdpStateDir  = Join-Path $env:ProgramData 'OPS-command'
$Script:RdpStateFile = Join-Path $Script:RdpStateDir 'rdp-port.state'

function Get-RdpPort {
    (Get-ItemProperty -Path $Script:RdpKey -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
}

function Test-RdpWatchdog {
    [bool](Get-ScheduledTask -TaskName $Script:RdpTask -ErrorAction SilentlyContinue)
}

function Get-RdpOldPort {
    if (-not (Test-Path $Script:RdpStateFile)) { return $null }
    $m = Select-String -Path $Script:RdpStateFile -Pattern '^OldPort=(\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
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
function Register-RdpWatchdog {
    param([int]$OldPort, [int]$Minutes)
    if (-not (Test-Path $Script:RdpStateDir)) {
        New-Item -ItemType Directory -Path $Script:RdpStateDir -Force | Out-Null
    }
    $revert = Join-Path $Script:RdpStateDir 'rdp-revert.ps1'
    $body = @"
# 由 Win_Admin_Tool.ps1 自動產生的 RDP 換 port 還原腳本(看門狗)。
# 時限內沒有人來「確認」就會執行這支,把 port 改回去並重啟服務。
Set-ItemProperty -Path '$($Script:RdpKey)' -Name PortNumber -Value $OldPort
netsh advfirewall firewall add rule name="OPS-RDP-$OldPort-TCP" dir=in action=allow protocol=TCP localport=$OldPort | Out-Null
netsh advfirewall firewall add rule name="OPS-RDP-$OldPort-UDP" dir=in action=allow protocol=UDP localport=$OldPort | Out-Null
Restart-Service TermService -Force
Add-Content -Path '$($Script:RdpStateDir)\rdp-port.log' -Value ("{0} 看門狗逾時,已還原為 $OldPort" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Remove-Item '$($Script:RdpStateFile)' -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName '$($Script:RdpTask)' -Confirm:`$false
"@
    Set-Content -Path $revert -Value $body -Encoding UTF8
    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$revert`""
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($Minutes)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $Script:RdpTask -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Host ("[錯誤] 看門狗排程建立失敗: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Unregister-RdpWatchdog {
    if (Test-RdpWatchdog) {
        Unregister-ScheduledTask -TaskName $Script:RdpTask -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Set-RdpPort {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 更換 RDP 連接埠 ==="
    $cur = Get-RdpPort
    if (-not $cur) { Write-Host ""; Write-Host "[錯誤] 讀不到目前的 RDP Port 設定"; Wait-Enter; return }

    if (Test-RdpWatchdog) {
        Write-Host ""
        Write-Host "[注意] 有一次『尚未確認』的換 port 作業進行中,看門狗還在跑。"
        Write-Host "       請先選「確認新 Port 可用」或「立即還原」,再做新的變更。"
        Wait-Enter; return
    }

    Write-Host ""
    Write-Host "目前 RDP Port 為: $cur"
    Write-Host ""
    Write-Host "流程: 改設定 -> 重啟 RDP 服務(本連線會斷) -> 你用新 Port 連回來 -> 回選單確認"
    Write-Host "      時限內沒有確認,看門狗會自動改回 $cur 並重啟服務,不會把你關在外面。"
    Write-Host ""
    $new = Read-Host "請輸入新的 Port 號碼 (1-65535)"
    if ($new -notmatch '^\d+$' -or [int]$new -lt 1 -or [int]$new -gt 65535) {
        Write-Host "[錯誤] 請輸入 1-65535 的有效數字"; Wait-Enter; return
    }
    if ([int]$new -eq [int]$cur) { Write-Host "[提示] 與目前相同,不需變更"; Wait-Enter; return }

    # 新 port 被別的程式佔用的話,TermService 會 bind 失敗,RDP 直接起不來
    $busy = Get-NetTCPConnection -State Listen -LocalPort ([int]$new) -ErrorAction SilentlyContinue
    if ($busy) {
        $procs = ($busy | Select-Object -ExpandProperty OwningProcess -Unique) -join ','
        Write-Host ""
        Write-Host "[錯誤] Port $new 已經有程式在監聽 (PID: $procs),換過去 RDP 會起不來。"
        Wait-Enter; return
    }

    $min = Read-Host "看門狗時限幾分鐘? (Enter = 10)"
    if ($min -notmatch '^\d+$' -or [int]$min -lt 1) { $min = 10 }

    Write-Host ""
    Write-Host "將要執行:"
    Write-Host "  1. 防火牆放行 $new (TCP/UDP);舊 port $cur 的規則保留到你確認為止"
    Write-Host "  2. 登錄檔 PortNumber: $cur -> $new"
    Write-Host "  3. 註冊看門狗排程 ($min 分鐘後自動還原)"
    Write-Host "  4. 重啟 TermService (這條 RDP 連線會斷)"
    Write-Host ""
    Write-Host "[提醒] 雲端主機還要在安全群組/網路 ACL 放行 $new。本機防火牆放行不代表外面通得了,"
    Write-Host "       這是換 port 之後連不上最常見的原因。"
    Write-Host ""
    if ((Read-Host "確定執行嗎? (Y/N)") -notmatch '^[Yy]$') { return }

    Add-RdpFirewallRule -Port ([int]$new)

    if (-not (Register-RdpWatchdog -OldPort ([int]$cur) -Minutes ([int]$min))) {
        Write-Host ""
        Write-Host "[中止] 看門狗建不起來,這次不做變更 —— 沒有自動還原就換 port 太危險。"
        Remove-RdpFirewallRule -Port ([int]$new)
        Wait-Enter; return
    }

    Set-ItemProperty -Path $Script:RdpKey -Name PortNumber -Value ([int]$new)
    $now = Get-RdpPort
    if ([int]$now -ne [int]$new) {
        Write-Host ""
        Write-Host "[錯誤] 寫入後讀回來還是 $now,設定沒有生效(可能被群組原則鎖住)。"
        Write-Host "        已取消看門狗並移除剛加的防火牆規則,系統維持原狀。"
        Unregister-RdpWatchdog
        Remove-RdpFirewallRule -Port ([int]$new)
        Wait-Enter; return
    }

    Set-Content -Path $Script:RdpStateFile -Encoding UTF8 -Value @"
OldPort=$cur
NewPort=$new
Since=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
DeadlineMinutes=$min
"@

    Write-Host ""
    Write-Host "[完成] 登錄檔已改為 $new,看門狗 $min 分鐘。接下來:"
    Write-Host "  1. 重啟 TermService,這條連線會斷"
    Write-Host "  2. 用『另一台電腦』連 IP:$new 確認可以登入"
    Write-Host "  3. 回本選單選「確認新 Port 可用」取消看門狗"
    Write-Host "  * 連不上就什麼都別做,$min 分鐘後會自動還原成 $cur 並重啟服務"
    Write-Host ""
    if ((Read-Host "現在重啟 TermService? (Y=立即重啟 / N=稍後自行重啟或重開機)") -match '^[Yy]$') {
        Restart-Service TermService -Force
        Write-Host "已重啟 TermService。"
    } else {
        Write-Host "尚未重啟,新 port 還沒生效;看門狗仍會在時限到時還原設定。"
    }
    Wait-Enter
}

# ---- 1b. 確認新 RDP Port 可用(取消看門狗) ----
function Confirm-RdpPort {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 確認新 RDP Port 可用 ==="
    if (-not (Test-RdpWatchdog)) {
        Write-Host ""
        Write-Host "目前沒有進行中的換 port 作業(看門狗不存在)。"
        Wait-Enter; return
    }
    $cur = Get-RdpPort
    $old = Get-RdpOldPort
    Write-Host ""
    Write-Host "目前設定的 Port = $cur;變更前是 $old"
    Write-Host ""
    Write-Host "[重要] 請先確認你是『用新 Port 連進來的』,或已另外開一條新連線登入成功。"
    Write-Host "       舊視窗還活著不算數 —— 那條連線是在服務重啟前就建立的。"
    Write-Host ""
    if ((Read-Host "已經確認可以用新 Port $cur 連線了嗎? (Y/N)") -notmatch '^[Yy]$') { return }

    Unregister-RdpWatchdog
    if ($old) {
        Write-Host ""
        if ((Read-Host "要移除舊 Port $old 的防火牆規則嗎? (Y/N)") -match '^[Yy]$') {
            Remove-RdpFirewallRule -Port ([int]$old)
            Write-Host "已移除舊 Port $old 的規則。"
        }
    }
    Remove-Item $Script:RdpStateFile -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "[完成] 看門狗已取消,RDP Port 固定為 $cur。"
    Wait-Enter
}

# ---- 1c. 立即還原 RDP Port ----
function Restore-RdpPort {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 立即還原 RDP Port ==="
    $old = Get-RdpOldPort
    if (-not $old) {
        Write-Host ""
        Write-Host "找不到狀態檔($Script:RdpStateFile),沒有可還原的變更。"
        Write-Host "若確定要手動改回,請用「更換 RDP 連接埠」直接設定。"
        Wait-Enter; return
    }
    $cur = Get-RdpPort
    Write-Host ""
    Write-Host "將把 RDP Port 從 $cur 還原為 $old,並重啟 TermService(這條連線可能會斷)。"
    Write-Host ""
    if ((Read-Host "確定要還原嗎? (Y/N)") -notmatch '^[Yy]$') { return }

    Set-ItemProperty -Path $Script:RdpKey -Name PortNumber -Value ([int]$old)
    Add-RdpFirewallRule -Port ([int]$old)
    Unregister-RdpWatchdog
    $now = Get-RdpPort
    if ([int]$now -eq [int]$old) {
        Remove-Item $Script:RdpStateFile -Force -ErrorAction SilentlyContinue
        Restart-Service TermService -Force
        Write-Host ""
        Write-Host "[完成] 已還原為 $old 並重啟服務。"
    } else {
        Write-Host ""
        Write-Host "[錯誤] 寫入後讀回來是 $now,還原沒有生效。看門狗已取消,請手動檢查登錄檔:"
        Write-Host "        $Script:RdpKey"
    }
    Wait-Enter
}

# ---- 2. 停止 Windows 更新 ----
function Stop-WinUpdate {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 停止 Windows 更新 ==="
    Write-Host ""
    Write-Host "[警告] 停止更新後將無法自動取得安全性修補程式,請自行評估風險。"
    $confirm = Read-Host "確定要停止嗎? (Y/N)"
    if ($confirm -notmatch '^[Yy]$') { return }
    Stop-Service wuauserv -Force
    Set-Service wuauserv -StartupType Disabled
    Stop-Service UsoSvc -Force
    Set-Service UsoSvc -StartupType Disabled
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" -Name Start -Value 4
    $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
    Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1
    Set-ItemProperty -Path $au -Name AUOptions -Value 1
    Write-Host ""
    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    if ($wu -and $wu.StartType -eq 'Disabled') {
        Write-Host "[完成] Windows 更新已停止 (wuauserv 啟動類型 = Disabled)。"
    } else {
        Write-Host ("[未完成] wuauserv 啟動類型現在是 {0},預期 Disabled。" -f $(if ($wu) { $wu.StartType } else { '讀不到' }))
        Write-Host "         可能被群組原則或第三方工具鎖住,請檢查上面的錯誤訊息。"
    }
    Write-Host "        若要恢復請回主選單選「3. 還原 Windows 更新」。"
    Wait-Enter
}

# ---- 3. 還原 Windows 更新 ----
function Start-WinUpdate {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 還原 Windows 更新 (恢復預設) ==="
    Set-Service wuauserv -StartupType Manual
    Start-Service wuauserv
    Set-Service UsoSvc -StartupType Manual
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" -Name Start -Value 3
    $au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Remove-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $au -Name AUOptions -ErrorAction SilentlyContinue
    Write-Host ""
    $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
    if ($wu -and $wu.StartType -ne 'Disabled') {
        Write-Host ("[完成] Windows 更新服務已恢復 (wuauserv 啟動類型 = {0})。" -f $wu.StartType)
    } else {
        Write-Host "[未完成] wuauserv 仍是 Disabled,恢復沒有生效,請檢查上面的錯誤訊息。"
    }
    Wait-Enter
}

# ---- 4. 解除帳號密碼鎖定 ----
function Clear-Lockout {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 解除帳號密碼鎖定 ==="
    Write-Host ""
    Write-Host "[警告] 鎖定閾值設為 0 等於『關閉帳號鎖定保護』,密碼可以被無限次嘗試。"
    Write-Host "       這台若有對外開放 RDP,等於把暴力破解的門檻整個拿掉。"
    Write-Host "       建議只在『自己被鎖住、要先解開』時暫時使用,事後改回 5-10 次。"
    Write-Host ""
    if ((Read-Host "仍要關閉帳號鎖定嗎? (Y/N)") -notmatch '^[Yy]$') { return }
    net accounts /lockoutthreshold:0 | Out-Null
    Write-Host ""
    Write-Host "[完成] 已將帳戶鎖定閾值設為 0 (輸錯密碼不再鎖定帳號)。"
    Write-Host "       要恢復保護: net accounts /lockoutthreshold:5"
    Write-Host ""
    Write-Host "--- 目前帳戶原則 ---"
    net accounts
    Wait-Enter
}

# ---- 5. 解除 RDP 連線數限制 ----
function Clear-RdpLimit {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 解除 RDP 連線數限制 ==="
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fSingleSessionPerUser -Value 0
    $ts = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    if (-not (Test-Path $ts)) { New-Item -Path $ts -Force | Out-Null }
    Set-ItemProperty -Path $ts -Name fSingleSessionPerUser -Value 0
    Set-ItemProperty -Path $ts -Name MaxInstanceCount -Value 999999
    Write-Host ""
    Write-Host "[完成] 已允許同一帳號建立多個工作階段,並解除連線數上限。"
    Write-Host ""
    Write-Host "[備註] 用戶端版 (家用/專業版) 原生限制同時只允許 1 個 RDP 連線,"
    Write-Host "       此限制由 termsrv.dll 控制。上述設定可放寬工作階段規則,"
    Write-Host "       但要真正多人同時連線通常需搭配 RDP Wrapper,且涉及授權條款。"
    Wait-Enter
}

# ---- 6. Ping (ICMP) ----
function Set-Ping {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== Ping (ICMP) 設定 ==="
    Write-Host "  1. 開啟 Ping (允許被 ping)"
    Write-Host "  2. 關閉 Ping (拒絕被 ping)"
    Write-Host "  0. 返回主選單"
    $c = Read-Host "請選擇"
    switch ($c) {
        '1' {
            netsh advfirewall firewall delete rule name="ICMP-Echo-Block" | Out-Null
            netsh advfirewall firewall add rule name="ICMP-Echo-Allow" protocol=icmpv4:8,any dir=in action=allow | Out-Null
            netsh advfirewall firewall add rule name="ICMPv6-Echo-Allow" protocol=icmpv6:128,any dir=in action=allow | Out-Null
            Write-Host ""; Write-Host "[完成] 已開啟 Ping,本機現在可被 ping。"; Wait-Enter
        }
        '2' {
            netsh advfirewall firewall delete rule name="ICMP-Echo-Allow" | Out-Null
            netsh advfirewall firewall delete rule name="ICMPv6-Echo-Allow" | Out-Null
            netsh advfirewall firewall add rule name="ICMP-Echo-Block" protocol=icmpv4:8,any dir=in action=block | Out-Null
            Write-Host ""; Write-Host "[完成] 已關閉 Ping,本機不再回應 ping。"; Wait-Enter
        }
    }
}

# ---- 7. 防火牆 Port 管理 ----
function Manage-Port {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 防火牆 Port 管理 ==="
    Write-Host "  1. 開啟 Port"
    Write-Host "  2. 查詢 Port"
    Write-Host "  3. 關閉 Port"
    Write-Host "  0. 返回主選單"
    $c = Read-Host "請選擇"
    switch ($c) {
        '1' {
            $p = Read-Host "請輸入要開啟的 Port 號碼"
            if ($p -notmatch '^\d+$' -or [int]$p -gt 65535) { Write-Host "[錯誤] 無效的 Port"; Wait-Enter; return }
            $proto = Read-Host "通訊協定? (1=TCP  2=UDP  3=兩者)"
            if ($proto -eq '1' -or $proto -eq '3') { netsh advfirewall firewall add rule name="Open-TCP-$p" dir=in action=allow protocol=TCP localport=$p | Out-Null }
            if ($proto -eq '2' -or $proto -eq '3') { netsh advfirewall firewall add rule name="Open-UDP-$p" dir=in action=allow protocol=UDP localport=$p | Out-Null }
            Write-Host ""; Write-Host "[完成] 已在防火牆開啟 Port $p"; Wait-Enter
        }
        '2' {
            $p = Read-Host "請輸入要查詢的 Port (直接 Enter 列出全部監聽中)"
            Write-Host ""
            if ([string]::IsNullOrWhiteSpace($p)) {
                Write-Host "--- 目前監聽中的 Port ---"
                netstat -ano | Select-String "LISTENING"
            } else {
                Write-Host "--- Port $p 使用狀態 (含佔用的 PID) ---"
                netstat -ano | Select-String (":" + $p + '\b')
            }
            Wait-Enter
        }
        '3' {
            $p = Read-Host "請輸入要關閉的 Port 號碼"
            if ($p -notmatch '^\d+$' -or [int]$p -gt 65535) { Write-Host "[錯誤] 無效的 Port"; Wait-Enter; return }
            netsh advfirewall firewall delete rule name="Open-TCP-$p" | Out-Null
            netsh advfirewall firewall delete rule name="Open-UDP-$p" | Out-Null
            Write-Host ""
            Write-Host "[完成] 已移除『本工具建立的』Port $p 放行規則 (Open-TCP-$p / Open-UDP-$p)。"
            Write-Host "       其他來源建立的規則不會被動到,可用下列指令確認還有哪些:"
            Write-Host "       netsh advfirewall firewall show rule name=all | findstr /C:`"LocalPort:  $p`""
            Wait-Enter
        }
    }
}

# ---- 8. 檢查現況 (唯讀,一般帳號也能用) ----
function Show-Status {
    Clear-Host
    Write-Host "============ 檢查現況 (驗證設定是否生效) ============"
    Write-Host ""

    $port = Get-RdpPort
    Write-Host ("[1] RDP Port          目前 = {0}" -f $port)
    if (Test-RdpWatchdog) {
        $old = Get-RdpOldPort
        Write-Host "                      ** 有未確認的換 port 作業進行中,看門狗會自動還原為 $old"
        Write-Host "                         新 port 測通了請去 A -> 確認;不確定就選 A -> 立即還原"
    }

    $wu = Get-Service wuauserv
    Write-Host ("[2] Windows 更新      wuauserv 狀態 = {0} / 啟動類型 = {1}" -f $wu.Status, $wu.StartType)
    Write-Host "                      (Disabled+Stopped=已停止更新 ; Manual=已還原)"

    Write-Host "[4] 帳號鎖定閾值      (下列 net accounts 中『鎖定閾值』一行,Never/永不=已解除)"
    net accounts | Select-String "鎖定|threshold" | ForEach-Object { Write-Host ("        " + $_.ToString().Trim()) }

    $single = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fSingleSessionPerUser).fSingleSessionPerUser
    Write-Host ("[5] RDP 連線限制      fSingleSessionPerUser = {0}  (0=已放寬)" -f $single)

    $allow = Get-NetFirewallRule -DisplayName "ICMP-Echo-Allow" -ErrorAction SilentlyContinue
    $block = Get-NetFirewallRule -DisplayName "ICMP-Echo-Block" -ErrorAction SilentlyContinue
    if ($allow) { Write-Host "[6] Ping              找到允許規則 => 目前『開啟』" }
    elseif ($block) { Write-Host "[6] Ping              找到封鎖規則 => 目前『關閉』" }
    else { Write-Host "[6] Ping              未找到本工具建立的規則 (維持系統預設)" }

    $ceo = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name AllowEncryptionOracle -ErrorAction SilentlyContinue).AllowEncryptionOracle
    $ceoTxt = switch ($ceo) { 0 {"0 強制更新用戶端"} 1 {"1 已降低影響"} 2 {"2 易受攻擊(已關閉修復)"} default {"尚未設定(預設)"} }
    Write-Host ("[7] CredSSP 加密預示  AllowEncryptionOracle = {0}" -f $ceoTxt)

    Write-Host ""
    Write-Host "[8] 目前監聽中的 Port (前 15 筆) ---"
    netstat -ano | Select-String "LISTENING" | Select-Object -First 15
    Write-Host ""
    Write-Host "提醒:RDP 連線、Ping、Port 是否連得到,必須從『另一台電腦』測才準。"
    Wait-Enter
}

# ---- 9. 磁碟管理 (視覺化) ----
# 畫出單顆磁碟的分割區配置長條
function Show-DiskBar {
    param($DiskNumber, $DiskSize)
    $parts = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Sort-Object Offset
    if (-not $parts) { Write-Host "   (無分割區)"; return }
    $barWidth = 50
    $symbols = @('#','=','+','*','o','~','&')
    $bar = ""
    $legend = @()
    $i = 0
    foreach ($p in $parts) {
        $frac = $p.Size / $DiskSize
        $w = [math]::Max(1, [math]::Round($frac * $barWidth))
        $sym = $symbols[$i % $symbols.Count]
        $bar += ([string]$sym * $w)
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "$($p.Type)" }
        $legend += ("      {0}  {1,-8} {2,7} GB" -f $sym, $letter, [math]::Round($p.Size/1GB,1))
        $i++
    }
    Write-Host ("   [{0}]" -f $bar)
    $legend | ForEach-Object { Write-Host $_ }
}

# 視覺化檢視所有磁碟 (唯讀,一般帳號可用)
function Show-DiskVisual {
    Clear-Host
    Write-Host "================= 磁碟視覺化檢視 ================="
    $disks = Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number
    if (-not $disks) { Write-Host "讀不到磁碟資訊 (可嘗試以管理員身分執行)"; Wait-Enter; return }
    foreach ($d in $disks) {
        $flag = ""
        if ($d.IsBoot -or $d.IsSystem) { $flag = "  <== 系統/開機碟" }
        Write-Host ""
        Write-Host ("磁碟 {0}: {1}{2}" -f $d.Number, $d.FriendlyName, $flag)
        Write-Host ("   容量 {0} GB | 樣式 {1} | 狀態 {2} | 匯流排 {3}" -f `
            [math]::Round($d.Size/1GB,1), $d.PartitionStyle, $d.HealthStatus, $d.BusType)
        if ($d.PartitionStyle -eq 'RAW') { Write-Host "   (尚未初始化的磁碟)" }
        else { Show-DiskBar -DiskNumber $d.Number -DiskSize $d.Size }
    }
    Write-Host ""
    Write-Host "----- 磁碟區使用量 -----"
    Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
        $total = $_.Size
        if ($total -gt 0) {
            $used = $total - $_.SizeRemaining
            $pct = [math]::Round($used / $total * 100)
            $w = 20
            $fill = [math]::Round($pct / 100 * $w)
            $barv = ('#' * $fill) + ('.' * ($w - $fill))
            Write-Host ("   {0}: {1,-12} [{2}] {3,3}%  已用 {4}/{5} GB" -f `
                $_.DriveLetter, $_.FileSystemLabel, $barv, $pct, `
                [math]::Round($used/1GB,1), [math]::Round($total/1GB,1))
        }
    }
    Wait-Enter
}

function Manage-Disk {
    while ($true) {
        Clear-Host
        Write-Host "=== 磁碟管理 (diskpart 視覺化) ==="
        Write-Host "  1. 視覺化檢視所有磁碟 (唯讀)"
        Write-Host "  2. 變更磁碟機代號"
        Write-Host "  3. 格式化磁碟區          [破壞性]"
        Write-Host "  4. 清除整顆磁碟 (clean)  [高破壞性]"
        Write-Host "  0. 返回主選單"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' { Show-DiskVisual }
            '2' {
                if (-not (Require-Admin)) { break }
                Show-DiskVisual
                $dl = (Read-Host "要變更的磁碟機代號 (例如 E)").TrimEnd(':')
                $new = (Read-Host "新的代號 (例如 F)").TrimEnd(':')
                Set-Partition -DriveLetter $dl -NewDriveLetter $new -ErrorAction SilentlyContinue
                Write-Host "[完成] 已將 $dl 變更為 $new (若失敗表示代號被佔用或磁碟機不存在)"
                Wait-Enter
            }
            '3' {
                if (-not (Require-Admin)) { break }
                Show-DiskVisual
                Write-Host ""
                Write-Host "[警告] 格式化會清空該磁碟區的所有資料!"
                $dl = (Read-Host "要格式化的磁碟機代號 (例如 D)").TrimEnd(':')
                if ($dl -match '^[Cc]$') { Write-Host "拒絕:不允許格式化系統碟 C:"; Wait-Enter; break }
                $vol = Get-Volume -DriveLetter $dl -ErrorAction SilentlyContinue
                if (-not $vol) { Write-Host "找不到磁碟機 $dl"; Wait-Enter; break }
                $fs = Read-Host "檔案系統 (NTFS / exFAT / FAT32,直接 Enter 用 NTFS)"
                if ([string]::IsNullOrWhiteSpace($fs)) { $fs = 'NTFS' }
                $label = Read-Host "磁碟區標籤 (可留空)"
                $chk = Read-Host "請『再次輸入』磁碟機代號 $dl 以確認格式化"
                if ($chk.TrimEnd(':') -ne $dl) { Write-Host "確認不符,已取消。"; Wait-Enter; break }
                Format-Volume -DriveLetter $dl -FileSystem $fs -NewFileSystemLabel $label -Confirm:$false -Force
                Write-Host "[完成] 已格式化 $dl 為 $fs"
                Wait-Enter
            }
            '4' {
                if (-not (Require-Admin)) { break }
                Show-DiskVisual
                Write-Host ""
                Write-Host "[高危警告] clean 會抹除『整顆磁碟』上的所有分割區與資料,無法復原!"
                $dn = Read-Host "要清除的磁碟編號 (Disk Number)"
                if ($dn -notmatch '^\d+$') { Write-Host "無效編號"; Wait-Enter; break }
                $disk = Get-Disk -Number $dn -ErrorAction SilentlyContinue
                if (-not $disk) { Write-Host "找不到磁碟 $dn"; Wait-Enter; break }
                if ($disk.IsBoot -or $disk.IsSystem) { Write-Host "拒絕:這是系統/開機碟,清除會導致無法開機。"; Wait-Enter; break }
                Write-Host ("即將清除 -> 磁碟 {0}: {1} ({2} GB)" -f $disk.Number, $disk.FriendlyName, [math]::Round($disk.Size/1GB,1))
                $c1 = Read-Host "請『再次輸入』磁碟編號 $dn 以確認"
                if ($c1 -ne $dn) { Write-Host "確認不符,已取消。"; Wait-Enter; break }
                $c2 = Read-Host "最後確認:輸入大寫 ERASE 才會執行"
                if ($c2 -cne 'ERASE') { Write-Host "未輸入 ERASE,已取消。"; Wait-Enter; break }
                Clear-Disk -Number $dn -RemoveData -RemoveOEM -Confirm:$false
                Write-Host "[完成] 磁碟 $dn 已清除 (未配置狀態,需重新初始化與分割才能使用)"
                Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 10. CredSSP 加密預示修復 (Encryption Oracle Remediation) ----
function Set-CredSSP {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters"
    while ($true) {
        Clear-Host
        Write-Host "=== CredSSP 加密預示修復 (Encryption Oracle Remediation) ==="
        $cur = (Get-ItemProperty -Path $key -Name AllowEncryptionOracle -ErrorAction SilentlyContinue).AllowEncryptionOracle
        switch ($cur) {
            0 { $desc = "0 = Force Updated Clients (強制更新用戶端)" }
            1 { $desc = "1 = Mitigated (已降低影響)" }
            2 { $desc = "2 = Vulnerable (已啟用 / 易受攻擊)" }
            default { $desc = "尚未設定 (系統預設)" }
        }
        Write-Host ("   目前狀態: {0}" -f $desc)
        Write-Host ""
        Write-Host "  1. 設為『已啟用 + 易受攻擊』 (AllowEncryptionOracle = 2)"
        Write-Host "  2. 還原為『尚未設定』 (移除此原則)"
        Write-Host "  0. 返回主選單"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' {
                if (-not (Require-Admin)) { break }
                Write-Host ""
                Write-Host "[提醒] 設為『易受攻擊』可讓你連到尚未修補 CVE-2018-0886 的主機,"
                Write-Host "       但也會讓本機重新暴露於該 CredSSP 弱點。較安全的長期作法是兩端都更新。"
                $ok = Read-Host "仍要繼續嗎? (Y/N)"
                if ($ok -notmatch '^[Yy]$') { break }
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name AllowEncryptionOracle -Type DWord -Value 2
                Write-Host ""
                Write-Host "[完成] 已設定 AllowEncryptionOracle = 2 (已啟用 / 易受攻擊)。"
                Write-Host "        等同 gpedit『加密預示修復 = 已啟用,保護層級 = 易受攻擊』。"
                Write-Host "        請『重新開機』後才會完全生效。"
                Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                Remove-ItemProperty -Path $key -Name AllowEncryptionOracle -ErrorAction SilentlyContinue
                Write-Host ""
                Write-Host "[完成] 已移除此原則,恢復系統預設 (尚未設定)。請重新開機。"
                Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 11. Microsoft Store 應用程式自動更新 (解 wsappx 占用) ----
function Set-StoreAutoUpdate {
    $key = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
    while ($true) {
        Clear-Host
        Write-Host "=== Microsoft Store 應用程式自動更新 ==="
        Write-Host "   (關閉可解決 wsappx 持續占用 CPU / 硬碟寫入)"
        $cur = (Get-ItemProperty -Path $key -Name AutoDownload -ErrorAction SilentlyContinue).AutoDownload
        switch ($cur) {
            2 { $d = "2 = 已關閉自動更新" }
            4 { $d = "4 = 開啟自動更新" }
            default { $d = "尚未設定 (預設會自動更新)" }
        }
        Write-Host ("   目前狀態: {0}" -f $d)
        Write-Host ""
        Write-Host "  1. 關閉自動更新 (建議,降低 wsappx 占用)"
        Write-Host "  2. 開啟自動更新 (恢復預設)"
        Write-Host "  0. 返回主選單"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' {
                if (-not (Require-Admin)) { break }
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name AutoDownload -Type DWord -Value 2
                Write-Host ""
                Write-Host "[完成] 已關閉 Store 應用程式自動更新。"
                Write-Host "        wsappx 占用通常幾分鐘後下降;也可到 Store > 設定再確認一次。"
                Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name AutoDownload -Type DWord -Value 4
                Write-Host ""; Write-Host "[完成] 已開啟 Store 應用程式自動更新。"; Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 12. Hyper-V 切換 / 啟用停用 (與 VMware 共存) ----
function Set-HyperV {
    while ($true) {
        Clear-Host
        Write-Host "=== Hyper-V 切換 / 啟用停用 ==="
        $lt = bcdedit /enum | Select-String "hypervisorlaunchtype" | Select-Object -First 1
        if ($lt) { Write-Host ("   目前 " + ($lt.ToString().Trim())) }
        else { Write-Host "   目前 hypervisorlaunchtype: 未設定 (通常等同 Auto)" }
        Write-Host ""
        Write-Host "  1. 啟用 Hyper-V 功能 (安裝元件,需重開機)"
        Write-Host "  2. 切換為『Hyper-V 優先』   (hypervisorlaunchtype auto)"
        Write-Host "  3. 切換為『VMware 優先/關閉』(hypervisorlaunchtype off)"
        Write-Host "  4. 完全停用 Hyper-V 功能 (移除元件,需重開機)"
        Write-Host "  0. 返回主選單"
        Write-Host ""
        Write-Host "  提示: 已裝 VMware 又想用 Hyper-V -> 選 2 ; 要改用 VMware -> 選 3"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' {
                if (-not (Require-Admin)) { break }
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
                bcdedit /set hypervisorlaunchtype auto | Out-Null
                Write-Host ""; Write-Host "[完成] 已啟用 Hyper-V 元件並設為 auto,請重新開機。"; Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                bcdedit /set hypervisorlaunchtype auto | Out-Null
                Write-Host ""; Write-Host "[完成] hypervisorlaunchtype = auto (Hyper-V 優先),請重新開機。"; Wait-Enter
            }
            '3' {
                if (-not (Require-Admin)) { break }
                bcdedit /set hypervisorlaunchtype off | Out-Null
                Write-Host ""; Write-Host "[完成] hypervisorlaunchtype = off (關閉 Hypervisor,VMware 可用),請重新開機。"; Wait-Enter
            }
            '4' {
                if (-not (Require-Admin)) { break }
                Write-Host "[注意] 這會『移除』Hyper-V 元件。"
                $ok = Read-Host "確定要停用嗎? (Y/N)"
                if ($ok -notmatch '^[Yy]$') { break }
                Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart | Out-Null
                bcdedit /set hypervisorlaunchtype off | Out-Null
                Write-Host ""; Write-Host "[完成] 已停用 Hyper-V 元件,請重新開機。"; Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 13. 時間 / 時區同步 ----
function Sync-Time {
    while ($true) {
        Clear-Host
        Write-Host "=== 時間 / 時區同步 ==="
        Write-Host ("   目前時間: {0}" -f (Get-Date))
        Write-Host ("   目前時區: {0}" -f (tzutil /g))
        Write-Host ""
        Write-Host "  1. 立即同步網路時間 (w32tm /resync)"
        Write-Host "  2. 設定 NTP 伺服器並同步"
        Write-Host "  3. 設定時區為台北 (Taipei Standard Time, UTC+8)"
        Write-Host "  4. 搜尋 / 手動設定其他時區"
        Write-Host "  0. 返回主選單"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' {
                if (-not (Require-Admin)) { break }
                Set-Service w32time -StartupType Manual -ErrorAction SilentlyContinue
                Start-Service w32time -ErrorAction SilentlyContinue
                w32tm /resync /force
                Write-Host ""; Write-Host "[完成] 已嘗試同步時間。"; Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                $ntp = Read-Host "NTP 伺服器 (直接 Enter 用 time.windows.com)"
                if ([string]::IsNullOrWhiteSpace($ntp)) { $ntp = 'time.windows.com' }
                Set-Service w32time -StartupType Manual -ErrorAction SilentlyContinue
                Start-Service w32time -ErrorAction SilentlyContinue
                w32tm /config /manualpeerlist:"$ntp" /syncfromflags:manual /reliable:yes /update | Out-Null
                Restart-Service w32time -ErrorAction SilentlyContinue
                w32tm /resync /force
                Write-Host ""; Write-Host "[完成] 已設定 NTP = $ntp 並同步。"; Wait-Enter
            }
            '3' {
                if (-not (Require-Admin)) { break }
                tzutil /s "Taipei Standard Time"
                Write-Host ""; Write-Host "[完成] 時區已設為 Taipei Standard Time (UTC+8)。"; Wait-Enter
            }
            '4' {
                $kw = Read-Host "輸入關鍵字搜尋時區 (例如 Tokyo / Taipei,直接 Enter 列全部)"
                Write-Host ""
                if ([string]::IsNullOrWhiteSpace($kw)) { tzutil /l }
                else { tzutil /l | Select-String $kw }
                Write-Host ""
                $tz = Read-Host "要設定的時區『完整名稱』(直接 Enter 跳過)"
                if (-not [string]::IsNullOrWhiteSpace($tz)) {
                    if (-not (Require-Admin)) { break }
                    tzutil /s "$tz"
                    Write-Host "[完成] 時區已設為 $tz"
                }
                Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 14. RDP 多開 (多重工作階段) 開啟 / 關閉 ----
function Set-RdpMulti {
    $tsCtrl = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    $tsPol  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    while ($true) {
        Clear-Host
        Write-Host "=== RDP 多開 (多重工作階段) 開啟 / 關閉 ==="
        $single = (Get-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -ErrorAction SilentlyContinue).fSingleSessionPerUser
        $maxc = (Get-ItemProperty -Path $tsPol -Name MaxInstanceCount -ErrorAction SilentlyContinue).MaxInstanceCount
        Write-Host ("   fSingleSessionPerUser = {0}  (0=允許同帳號多工作階段)" -f $single)
        Write-Host ("   MaxInstanceCount      = {0}" -f $maxc)
        Write-Host ""
        Write-Host "  1. 開啟 RDP 多開"
        Write-Host "  2. 關閉 RDP 多開 (還原單一工作階段)"
        Write-Host "  0. 返回主選單"
        $c = Read-Host "請選擇"
        switch ($c) {
            '1' {
                if (-not (Require-Admin)) { break }
                Set-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -Type DWord -Value 0
                if (-not (Test-Path $tsPol)) { New-Item -Path $tsPol -Force | Out-Null }
                Set-ItemProperty -Path $tsPol -Name fSingleSessionPerUser -Type DWord -Value 0
                Set-ItemProperty -Path $tsPol -Name MaxInstanceCount -Type DWord -Value 999999
                Write-Host ""
                Write-Host "[完成] 已開啟多開相關登錄檔設定。"
                Write-Host ""
                Write-Host "[重要] 用戶端版 Windows (家用/專業版) 原生仍限制『同時 1 個連線』,"
                Write-Host "       此限制在系統檔 termsrv.dll,登錄檔改不了。要真正讓多位使用者同時"
                Write-Host "       連線,需用 RDP Wrapper 這類工具處理 termsrv.dll——本工具不會替你"
                Write-Host "       修改該系統檔,且多開可能涉及 Microsoft 授權條款,請自行確認合規性。"
                Write-Host "       (Windows Server 版不受此單一連線限制。)"
                Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                Set-ItemProperty -Path $tsCtrl -Name fSingleSessionPerUser -Type DWord -Value 1
                Set-ItemProperty -Path $tsPol -Name fSingleSessionPerUser -Type DWord -Value 1 -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $tsPol -Name MaxInstanceCount -ErrorAction SilentlyContinue
                Write-Host ""; Write-Host "[完成] 已還原為單一工作階段。"; Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 帳號: 啟用/停用內建 Administrator ----
function Set-AdminAccount {
    # 用 SID -500 找出真正的內建 Administrator (即使被改名也抓得到)
    $admin = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value.EndsWith('-500') }
    while ($true) {
        Clear-Host
        Write-Host "=== 內建 Administrator 帳戶 ==="
        if ($admin) { Write-Host ("   帳號名稱: {0} | 目前狀態: {1}" -f $admin.Name, $(if ($admin.Enabled) { "已啟用" } else { "已停用" })) }
        else { Write-Host "   (讀不到帳號資訊,可嘗試以管理員身分執行)" }
        Write-Host ""
        Write-Host "  1. 啟用 Administrator 帳戶"
        Write-Host "  2. 停用 Administrator 帳戶"
        Write-Host "  0. 返回"
        switch (Read-Host "請選擇") {
            '1' {
                if (-not (Require-Admin)) { break }
                net user $admin.Name /active:yes | Out-Null
                $admin = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value.EndsWith('-500') }
                Write-Host ""; Write-Host "[完成] 已啟用。建議接著到『帳號與安全 > 變更帳號密碼』設定強密碼。"; Wait-Enter
            }
            '2' {
                if (-not (Require-Admin)) { break }
                net user $admin.Name /active:no | Out-Null
                $admin = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value.EndsWith('-500') }
                Write-Host ""; Write-Host "[完成] 已停用 Administrator。"; Wait-Enter
            }
            '0' { return }
        }
    }
}

# ---- 帳號: 變更帳號密碼 ----
function Set-UserPassword {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 變更帳號密碼 ==="
    Write-Host "本機帳號:"
    Get-LocalUser | Select-Object Name, Enabled | Format-Table -AutoSize | Out-String | Write-Host
    $u = Read-Host "要變更密碼的帳號名稱"
    if ([string]::IsNullOrWhiteSpace($u)) { return }
    if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) { Write-Host "找不到帳號 $u"; Wait-Enter; return }
    Write-Host ""
    Write-Host "接下來會要你輸入新密碼兩次 (輸入時畫面不顯示,較安全):"
    net user $u *
    Write-Host ""; Write-Host "[提示] 若上方顯示『命令成功』即代表 $u 的密碼已變更。"; Wait-Enter
}

# ---- 網路: 批量添加 IP ----
function Add-BatchIP {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 批量添加 IP ==="
    Write-Host "使用中的網路介面卡:"
    Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object Name, InterfaceDescription | Format-Table -AutoSize | Out-String | Write-Host
    $if = Read-Host "介面卡名稱 (例如 Ethernet)"
    if ([string]::IsNullOrWhiteSpace($if)) { return }
    $base  = Read-Host "IP 前三段 (例如 192.168.1)"
    $start = Read-Host "起始的第四段 (例如 100)"
    $end   = Read-Host "結束的第四段 (例如 110)"
    $mask  = Read-Host "子網路遮罩長度 (例如 24)"
    if ($base -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Write-Host "[錯誤] IP 前三段格式不對 (應該像 192.168.1)"; Wait-Enter; return
    }
    if ($start -notmatch '^\d+$' -or $end -notmatch '^\d+$' -or $mask -notmatch '^\d+$' -or
        [int]$start -gt [int]$end -or [int]$start -lt 1 -or [int]$end -gt 254 -or
        [int]$mask -lt 1 -or [int]$mask -gt 32) {
        Write-Host "[錯誤] 數值無效 (第四段 1-254、起始不可大於結束、遮罩 1-32)"; Wait-Enter; return
    }
    Write-Host ""
    Write-Host ("即將在 [{0}] 新增 {1}.{2} ~ {1}.{3} / {4}" -f $if, $base, $start, $end, $mask)
    if ((Read-Host "確定? (Y/N)") -notmatch '^[Yy]$') { return }
    $added = 0
    for ($i = [int]$start; $i -le [int]$end; $i++) {
        $ip = "$base.$i"
        try {
            New-NetIPAddress -InterfaceAlias $if -IPAddress $ip -PrefixLength ([int]$mask) -ErrorAction Stop | Out-Null
            Write-Host "  + $ip"; $added++
        } catch {
            Write-Host ("  ! {0} 略過 ({1})" -f $ip, $_.Exception.Message.Split([char]10)[0])
        }
    }
    Write-Host ""; Write-Host "[完成] 共新增 $added 個 IP。(移除可用: Remove-NetIPAddress -IPAddress <IP>)"; Wait-Enter
}

# ---- RDP: 查看遠端登入紀錄 ----
function Show-RdpLogins {
    if (-not (Require-Admin)) { return }
    Clear-Host
    Write-Host "=== 遠端桌面 (RDP) 登入紀錄 ==="
    Write-Host ""
    Write-Host "--- 最近的 RDP 連線 (成功通過驗證, 事件 1149) ---"
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Id=1149} -MaxEvents 25 -ErrorAction Stop
        foreach ($e in $ev) {
            Write-Host ("   {0}  帳號: {1}\{2}  來源: {3}" -f $e.TimeCreated, $e.Properties[1].Value, $e.Properties[0].Value, $e.Properties[2].Value)
        }
    } catch { Write-Host "   (無此紀錄或紀錄為空)" }
    Write-Host ""
    Write-Host "--- 最近的登入失敗 (Security 4625, 可能是被嘗試暴力破解) ---"
    try {
        $f = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 10 -ErrorAction Stop
        foreach ($e in $f) {
            $x = [xml]$e.ToXml()
            $u  = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
            $ip = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
            Write-Host ("   {0}  帳號: {1}  來源IP: {2}" -f $e.TimeCreated, $u, $ip)
        }
    } catch { Write-Host "   (無失敗紀錄, 或無權限讀取 Security 記錄檔)" }
    Wait-Enter
}

# ================= 分類子選單 =================
function Menu-RDP {
    while ($true) {
        Clear-Host
        Write-Host "===== A. 遠端桌面 (RDP) ====="
        if (Test-RdpWatchdog) {
            Write-Host "  ** 有未確認的換 port 作業進行中:測通了選 2 確認,不確定就選 3 還原"
            Write-Host "     (時限到了看門狗會自動還原,不會把你關在外面)"
        }
        Write-Host "  1. 更換 RDP 連接埠 (Port)   新舊埠並存 + 看門狗自動還原"
        Write-Host "  2. 確認新 Port 可用          取消看門狗,收掉舊 Port 規則"
        Write-Host "  3. 立即還原 Port             回到變更前的設定"
        Write-Host "  4. RDP 多開 開啟 / 關閉"
        Write-Host "  5. 關閉 CredSSP 加密預示修復"
        Write-Host "  6. 查看遠端登入紀錄"
        Write-Host "  0. 返回主選單"
        switch (Read-Host "請選擇") {
            '1' { Set-RdpPort }
            '2' { Confirm-RdpPort }
            '3' { Restore-RdpPort }
            '4' { Set-RdpMulti }
            '5' { Set-CredSSP }
            '6' { Show-RdpLogins }
            '0' { return }
        }
    }
}

function Menu-Account {
    while ($true) {
        Clear-Host
        Write-Host "===== B. 帳號與安全 ====="
        Write-Host "  1. 解除帳號密碼鎖定 (試錯次數限制)"
        Write-Host "  2. 啟用 / 停用 Administrator 帳戶"
        Write-Host "  3. 變更帳號密碼"
        Write-Host "  0. 返回主選單"
        switch (Read-Host "請選擇") {
            '1' { Clear-Lockout }
            '2' { Set-AdminAccount }
            '3' { Set-UserPassword }
            '0' { return }
        }
    }
}

function Menu-System {
    while ($true) {
        Clear-Host
        Write-Host "===== C. 系統與更新 ====="
        Write-Host "  1. 停止 Windows 更新"
        Write-Host "  2. 還原 Windows 更新 (恢復預設)"
        Write-Host "  3. Microsoft Store 自動更新 (解 wsappx 占用)"
        Write-Host "  4. 時間 / 時區同步"
        Write-Host "  0. 返回主選單"
        switch (Read-Host "請選擇") {
            '1' { Stop-WinUpdate }
            '2' { Start-WinUpdate }
            '3' { Set-StoreAutoUpdate }
            '4' { Sync-Time }
            '0' { return }
        }
    }
}

function Menu-Network {
    while ($true) {
        Clear-Host
        Write-Host "===== D. 網路與防火牆 ====="
        Write-Host "  1. Ping (ICMP) 開啟 / 關閉"
        Write-Host "  2. 防火牆 Port 管理 (開啟 / 查詢 / 關閉)"
        Write-Host "  3. 批量添加 IP"
        Write-Host "  0. 返回主選單"
        switch (Read-Host "請選擇") {
            '1' { Set-Ping }
            '2' { Manage-Port }
            '3' { Add-BatchIP }
            '0' { return }
        }
    }
}

# ===== 主選單 (分類) =====
while ($true) {
    Clear-Host
    $role = if ($IsAdmin) { "系統管理員" } else { "一般使用者 (修改功能會要求提權)" }
    Write-Host "============================================================"
    Write-Host "        Windows 10 / 11  系統管理工具  (分類選單)"
    Write-Host ("        目前權限: {0}" -f $role)
    Write-Host "============================================================"
    Write-Host "  A. 遠端桌面 (RDP)     - 換 Port / 確認 / 還原 / 多開 / CredSSP / 登入紀錄"
    Write-Host "  B. 帳號與安全         - 鎖定 / Administrator / 改密碼"
    Write-Host "  C. 系統與更新         - Windows 更新 / Store / 時間時區"
    Write-Host "  D. 網路與防火牆       - Ping / Port / 批量加 IP"
    Write-Host "  E. 虛擬化 (Hyper-V)   - 與 VMware 切換 / 啟用停用"
    Write-Host "  F. 磁碟管理           - diskpart 視覺化"
    Write-Host "  S. 檢查現況           - 驗證設定 (免管理員)"
    Write-Host "  0. 離開"
    Write-Host "============================================================"
    if ($IsAdmin -and (Test-RdpWatchdog)) {
        Write-Host "  ** 有未確認的換 RDP Port 作業進行中 —— 進 A 選單確認或還原"
        Write-Host "============================================================"
    }
    if (-not $IsAdmin) {
        Write-Host "  * 目前非管理員。S 檢查現況可直接用;其他修改功能會詢問是否提權。"
    }
    switch (Read-Host "請輸入代號 (A-F / S / 0)") {
        'A' { Menu-RDP }
        'B' { Menu-Account }
        'C' { Menu-System }
        'D' { Menu-Network }
        'E' { Set-HyperV }
        'F' { Manage-Disk }
        'S' { Show-Status }
        '0' { exit }
    }
}
