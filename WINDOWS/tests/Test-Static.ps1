<#
.SYNOPSIS
    靜態檢查 Windows 圖形介面工具的 .ps1 / .bat（不需要桌面，不會改系統）。

.DESCRIPTION
    逐一檢查資料夾裡的腳本：
      1. 編碼：ops-win.ps1 必須 UTF-8 無 BOM（irm | iex 用），其餘 .ps1 必須 UTF-8 含 BOM；
         全部 CRLF；.bat / .cmd 必須純 ASCII；內容必須是合法的 UTF-8。
      2. 控制字元：除了 Tab / CR / LF 之外不得有控制字元、零寬 BOM、替代字元 U+FFFD。
      3. 語法：每支 .ps1 解析 0 錯誤（含背景執行用的 $Worker* here-string）。
      4. 點不到的函式：從檔案最外層追呼叫關係，沒有任何路徑會呼叫到的函式。
      5. 巢狀閉包：在「不是函式本體」的那一層建立的 .GetNewClosure()，用到建立那層沒有的變數
         （主面板 $sidebar、背景回呼 $append 都是這類 bug）。
      6. 閉包呼叫區域函式：GetNewClosure() 的閉包看不到「定義在函式裡」的函式；
         被函式 dot-source 的檔案（例如 Win_Schedule_Panel.ps1）裡的函式全部算區域函式。
      7. 呼叫到不存在的指令（在本機用 Get-Command 解析，所以要在 Windows PowerShell 5.1 跑才準）；
         背景執行的 $Worker* 程式碼不得呼叫主程式的函式（另一個 runspace 看不到）。
      8. 不得對唯讀／常數自動變數賦值（$HOME、$PID、$Host、$true…，PowerShell 不分大小寫，
         所以 $home 就是 $HOME）；對其他自動變數（$input、$args、$Matches…）賦值列為警告。
      9. 不得使用 PowerShell 7 才有的語法：字元範圍 'a'..'z'、三元運算子、??、?.、&& / ||、
         `u{} 跳脫、-Encoding utf8NoBOM、ForEach-Object -Parallel、$IsWindows 等。

    有任何「失敗」項目時結束碼為 1，否則為 0。

.PARAMETER Path
    要檢查的資料夾，預設是這支腳本的上一層（tests 的上一層，也就是工具本身所在的資料夾）。

.PARAMETER NoBomFiles
    必須是「無 BOM」的檔名，預設只有 ops-win.ps1。

.PARAMETER KnownCommands
    額外視為存在的指令名稱（例如只在 Windows Server 才有的指令）。

.PARAMETER OutFile
    同時把結果寫到這個檔案（UTF-8）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Static.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Static.ps1 -Path C:\OPS-test\old -OutFile C:\OPS-test\static.txt
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string[]]$NoBomFiles = @('ops-win.ps1'),
    [string[]]$KnownCommands = @(),
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

$script:Fails = 0
$script:Warns = 0
$script:Out = New-Object System.Collections.Generic.List[string]

function Write-Line([string]$Text) {
    $script:Out.Add($Text)
    Write-Host $Text
}
function Add-Fail([string]$Text) { $script:Fails++; Write-Line "  [失敗] $Text" }
function Add-Warn([string]$Text) { $script:Warns++; Write-Line "  [警告] $Text" }
$script:QuietOk = $false
function Add-Ok([string]$Text) { if (-not $script:QuietOk) { Write-Line "  [通過] $Text" } }

# ---------------------------------------------------------------- 共用

$Lang = 'System.Management.Automation.Language'

function Get-LineOf([string]$Text, [int]$Index) {
    # 第幾行（1 起算）
    [regex]::Matches($Text.Substring(0, [Math]::Min($Index, $Text.Length)), "`n").Count + 1
}

function Get-Ast([string]$Text, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, $Name, [ref]$tokens, [ref]$errors)
    @{ Ast = $ast; Tokens = $tokens; Errors = $errors }
}

# 往上找最近的一層 scriptblock
function Get-OwnerBlock($Node) {
    $p = $Node.Parent
    while ($p -and $p -isnot [Management.Automation.Language.ScriptBlockAst]) { $p = $p.Parent }
    $p
}

# 去掉 script: / global: / local: / private: 前綴，env: 這類磁碟機變數回傳 $null
function Get-PlainVarName($VarExpr) {
    $vp = $VarExpr.VariablePath
    $name = $vp.UserPath
    if ($name -match '^(?i)(script|global|local|private|using):(.+)$') { return $Matches[2] }
    if ($vp.IsDriveQualified) { return $null }
    $name
}

# ---------------------------------------------------------------- 4. 點不到的函式

function Test-Reachability($Ast) {
    $defs = @{}
    foreach ($f in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defs[$f.Name] = $f }
    $refs = {
        param($node)
        $names = @()
        foreach ($c in $node.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName(); if ($n) { $names += $n }
        }
        # ${function:Xxx} 也算呼叫
        foreach ($v in $node.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if ($v.VariablePath.UserPath -like 'function:*') { $names += $v.VariablePath.UserPath.Substring(9) }
        }
        $names | Where-Object { $defs.ContainsKey($_) } | Sort-Object -Unique
    }
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    $top = @($Ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] })
    if ($Ast.BeginBlock) { $top += $Ast.BeginBlock.Statements }
    foreach ($s in $top) { foreach ($n in (& $refs $s)) { if (-not $seen[$n]) { $seen[$n] = 1; $queue.Enqueue($n) } } }
    while ($queue.Count) {
        $n = $queue.Dequeue()
        foreach ($m in (& $refs $defs[$n].Body)) { if (-not $seen[$m]) { $seen[$m] = 1; $queue.Enqueue($m) } }
    }
    $dead = @($defs.Values | Where-Object { -not $seen[$_.Name] } | Sort-Object { $_.Extent.StartLineNumber })
    if ($dead.Count) {
        foreach ($d in $dead) { Add-Fail ("點不到的函式：{0}（第 {1}-{2} 行）" -f $d.Name, $d.Extent.StartLineNumber, $d.Extent.EndLineNumber) }
    } else { Add-Ok "函式 $($defs.Count) 個，全部可到達" }
}

# ---------------------------------------------------------------- 5. 巢狀閉包少帶變數

$script:AutoVars = @(
    'true', 'false', 'null', '_', 'args', 'this', 'PSItem', 'input', 'PSScriptRoot', 'PSCommandPath', 'LASTEXITCODE',
    'env', 'ErrorActionPreference', 'PID', 'HOME', 'MyInvocation', 'sender', 'e', 'Matches', 'Error', 'Host',
    'PSBoundParameters', 'PSCmdlet', 'ExecutionContext', 'PSVersionTable', 'PWD', 'ShellId', 'PSHOME', 'PSCulture',
    'PSUICulture', 'EventArgs', 'Event', 'EventSubscriber', 'foreach', 'switch', 'StackTrace', 'OFS', '?', '^', '$',
    'ConfirmPreference', 'WarningPreference', 'VerbosePreference', 'ProgressPreference', 'IsAdmin'
)

function Get-AssignedNames($Block, [switch]$ThisLayerOnly) {
    $names = @()
    $inLayer = { param($n) (-not $ThisLayerOnly) -or ((Get-OwnerBlock $n) -eq $Block) }
    foreach ($pb in @($Block.FindAll({ $args[0] -is [Management.Automation.Language.ParamBlockAst] }, $true))) {
        if ($ThisLayerOnly -and $pb.Parent -ne $Block) { continue }
        $names += $pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
    }
    foreach ($a in $Block.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if (-not (& $inLayer $a)) { continue }
        $left = $a.Left
        if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -is [Management.Automation.Language.VariableExpressionAst]) { $names += $left.VariablePath.UserPath }
        if ($left -is [Management.Automation.Language.ArrayLiteralAst]) {
            $names += $left.Elements | Where-Object { $_ -is [Management.Automation.Language.VariableExpressionAst] } | ForEach-Object { $_.VariablePath.UserPath }
        }
    }
    foreach ($f in $Block.FindAll({ $args[0] -is [Management.Automation.Language.ForEachStatementAst] }, $true)) {
        if (& $inLayer $f) { $names += $f.Variable.VariablePath.UserPath }
    }
    # 函式內的巢狀函式參數
    foreach ($fd in $Block.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $ThisLayerOnly -and $fd.Parameters) { $names += $fd.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } }
    }
    $names
}

function Get-ClosureBlocks($Ast) {
    $Ast.FindAll({
            $args[0] -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $args[0].Member.Value -eq 'GetNewClosure' -and
            $args[0].Expression -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true)
}

function Test-NestedClosures($Ast) {
    $n = 0
    foreach ($c in (Get-ClosureBlocks $Ast)) {
        $inner = $c.Expression.ScriptBlock
        $creator = Get-OwnerBlock $c
        if (-not $creator) { continue }
        # 直接在函式本體（或檔案最外層）建立的閉包：那一層就是函式的區域變數，沒問題
        if ($creator.Parent -is [Management.Automation.Language.FunctionDefinitionAst] -or -not $creator.Parent) { continue }
        $local = @(Get-AssignedNames $creator -ThisLayerOnly)
        $innerAssigned = @(Get-AssignedNames $inner)
        $used = $inner.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
            Where-Object { -not $_.VariablePath.IsDriveQualified -and -not $_.VariablePath.IsScript -and -not $_.VariablePath.IsGlobal } |
            ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique
        $missing = @($used | Where-Object { $_ -notin $local -and $_ -notin $innerAssigned -and $_ -notin $script:AutoVars })
        if ($missing.Count) {
            $n++
            Add-Fail ("第 {0} 行：巢狀閉包用到建立那層沒有的變數 → {1}（GetNewClosure 只帶走當下這一層的變數，要先在建立那層寫 `$x=`$x）" -f $c.Extent.StartLineNumber, ($missing -join ', '))
        }
    }
    if (-not $n) { Add-Ok '巢狀閉包變數：沒有可疑項目' }
}

# ---------------------------------------------------------------- 6. 閉包呼叫區域函式

function Test-ClosureLocalFunctions($Ast, [bool]$WholeFileLocal) {
    $local = @{}
    foreach ($f in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $owner = Get-OwnerBlock $f
        $nested = $owner -and $owner.Parent   # 檔案最外層的 scriptblock 沒有 Parent
        if ($nested -or $WholeFileLocal) { $local[$f.Name] = $f }
    }
    $n = 0
    if ($local.Count) {
        foreach ($c in (Get-ClosureBlocks $Ast)) {
            foreach ($cmd in $c.Expression.ScriptBlock.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
                $name = $cmd.GetCommandName()
                if ($name -and $local.ContainsKey($name)) {
                    $n++
                    $why = if ($WholeFileLocal) { '這個檔案是在函式裡 dot-source 的，裡面的函式都是區域函式' } else { '它定義在函式裡' }
                    Add-Fail ("第 {0} 行：GetNewClosure 閉包呼叫 {1}，但閉包看不到它（{2}）。請先存成變數：`$fn=`${{function:{1}}}，閉包裡用 & `$fn" -f $cmd.Extent.StartLineNumber, $name, $why)
                }
            }
        }
    }
    if (-not $n) { Add-Ok '閉包呼叫的函式都看得到' }
}

# ---------------------------------------------------------------- 7. 不存在的指令

$script:CmdCache = @{}
function Test-CommandExists([string]$Name) {
    if ($script:CmdCache.ContainsKey($Name)) { return $script:CmdCache[$Name] }
    $ok = [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    $script:CmdCache[$Name] = $ok
    $ok
}

function Test-Commands($Ast, [hashtable]$Known, [string]$Where) {
    $bad = @{}
    foreach ($c in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($Known.ContainsKey($name)) { continue }
        if ($name -match '[\\/]' -or $name -match '^\.') { continue }   # 路徑
        if (Test-CommandExists $name) { continue }
        if (-not $bad.ContainsKey($name)) { $bad[$name] = $c.Extent.StartLineNumber }
    }
    foreach ($k in ($bad.Keys | Sort-Object)) { Add-Fail ("{0}第 {1} 行：呼叫不存在的指令 {2}" -f $Where, $bad[$k], $k) }
    $bad.Count
}

# 背景執行的程式碼：$Script:WorkerXxx = @' ... '@
function Get-WorkerScripts($Ast) {
    foreach ($a in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = Get-PlainVarName $a.Left
        if ($name -notlike 'Worker*') { continue }
        $s = $a.Right.Find({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
        if ($s -and $s.StringConstantType -match 'HereString') {
            [pscustomobject]@{ Name = $name; Text = $s.Value; Line = $s.Extent.StartLineNumber }
        }
    }
}

# ---------------------------------------------------------------- 8. 唯讀自動變數

$script:ReadOnlyVars = @('HOME', 'PID', 'PSHOME', 'ShellId', 'Host', 'true', 'false', 'null', 'PSVersionTable',
    'ExecutionContext', 'PSCulture', 'PSUICulture', '?', '^', '$')
$script:AutoWritable = @('input', 'args', '_', 'PSItem', 'this', 'Matches', 'MyInvocation', 'PSBoundParameters',
    'PSCmdlet', 'PSScriptRoot', 'PSCommandPath', 'sender', 'EventArgs', 'Event', 'EventSubscriber', 'foreach',
    'switch', 'StackTrace', 'PWD', 'Error')

function Test-AutomaticAssignments($Ast) {
    $n = 0
    $targets = @()
    foreach ($a in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $a.Left
        if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        $vars = @()
        if ($left -is [Management.Automation.Language.VariableExpressionAst]) { $vars = @($left) }
        elseif ($left -is [Management.Automation.Language.ArrayLiteralAst]) { $vars = @($left.Elements | Where-Object { $_ -is [Management.Automation.Language.VariableExpressionAst] }) }
        foreach ($v in $vars) { $targets += [pscustomobject]@{ Var = $v; Kind = '賦值' } }
    }
    foreach ($f in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $targets += [pscustomobject]@{ Var = $f.Variable; Kind = 'foreach 迴圈變數' }
    }
    foreach ($p in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.ParameterAst] }, $true)) {
        $targets += [pscustomobject]@{ Var = $p.Name; Kind = '參數名稱' }
    }
    foreach ($t in $targets) {
        $name = Get-PlainVarName $t.Var
        if (-not $name) { continue }
        if ($name -in $script:ReadOnlyVars) {
            $n++
            Add-Fail ("第 {0} 行：{1} `${2} 是唯讀／常數自動變數（PowerShell 不分大小寫，`$home 就是 `$HOME），執行到這裡會直接出錯" -f $t.Var.Extent.StartLineNumber, $t.Kind, $name)
        } elseif ($name -in $script:AutoWritable -and $t.Kind -ne '參數名稱') {
            Add-Warn ("第 {0} 行：{1} `${2} 是自動變數，可能被 PowerShell 覆寫（或蓋掉 PowerShell 要用的值）" -f $t.Var.Extent.StartLineNumber, $t.Kind, $name)
        }
    }
    if (-not $n) { Add-Ok '沒有對唯讀自動變數賦值' }
}

# ---------------------------------------------------------------- 9. PowerShell 7 專用語法

function Test-Ps7Syntax($Ast, $Tokens) {
    $hits = New-Object System.Collections.Generic.List[string]
    $isNumeric = { param($s) $s -is [Management.Automation.Language.StringConstantExpressionAst] -and $s.Value -match '^\s*-?\d+\s*$' }
    foreach ($b in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        $op = [string]$b.Operator
        if ($op -eq 'DotDot') {
            $str = @($b.Left, $b.Right) | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and -not (& $isNumeric $_) }
            if ($str) { $hits.Add("第 $($b.Extent.StartLineNumber) 行：字元範圍 $($b.Extent.Text)（5.1 不支援，請改用 [char[]](68..90) 之類的寫法）") }
        }
        if ($op -eq 'QuestionQuestion') { $hits.Add("第 $($b.Extent.StartLineNumber) 行：?? 運算子") }
    }
    foreach ($node in $Ast.FindAll({ $true }, $true)) {
        $tn = $node.GetType().Name
        if ($tn -eq 'TernaryExpressionAst') { $hits.Add("第 $($node.Extent.StartLineNumber) 行：三元運算子 ? :") }
        elseif ($tn -eq 'PipelineChainAst') { $hits.Add("第 $($node.Extent.StartLineNumber) 行：&& / || 管線鏈") }
        elseif ($node -is [Management.Automation.Language.MemberExpressionAst] -and $node.PSObject.Properties['NullConditional'] -and $node.NullConditional) {
            $hits.Add("第 $($node.Extent.StartLineNumber) 行：?. / ?[] 運算子")
        }
        elseif ($node -is [Management.Automation.Language.AssignmentStatementAst] -and [string]$node.Operator -eq 'QuestionQuestionEquals') {
            $hits.Add("第 $($node.Extent.StartLineNumber) 行：??= 運算子")
        }
    }
    foreach ($s in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($s.Extent.Text -match '`u\{') { $hits.Add("第 $($s.Extent.StartLineNumber) 行：" + '`u{} 跳脫（5.1 會原樣輸出 u{...}）') }
    }
    foreach ($v in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($v.VariablePath.UserPath -in 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR') {
            $hits.Add("第 $($v.Extent.StartLineNumber) 行：`$$($v.VariablePath.UserPath)（5.1 沒有這個變數，永遠是 `$null）")
        }
    }
    $ps7Cmds = @('Join-String', 'Get-Error', 'Test-Json', 'Get-Uptime', 'Remove-Alias', 'ConvertFrom-Markdown', 'Remove-Service')
    foreach ($c in $Ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        $els = $c.CommandElements
        if ($name -in $ps7Cmds) { $hits.Add("第 $($c.Extent.StartLineNumber) 行：$name 是 PowerShell 6/7 才有的指令") }
        for ($i = 1; $i -lt $els.Count; $i++) {
            if ($els[$i] -isnot [Management.Automation.Language.CommandParameterAst]) { continue }
            $pn = $els[$i].ParameterName
            if ($name -in 'ForEach-Object', '%', 'foreach' -and $pn -in 'Parallel', 'ThrottleLimit') { $hits.Add("第 $($c.Extent.StartLineNumber) 行：ForEach-Object -$pn") }
            if ($name -eq 'ConvertFrom-Json' -and $pn -in 'AsHashtable', 'Depth', 'NoEnumerate') { $hits.Add("第 $($c.Extent.StartLineNumber) 行：ConvertFrom-Json -$pn") }
            if ($pn -eq 'Encoding') {
                $val = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
                if ($val -is [Management.Automation.Language.StringConstantExpressionAst] -and $val.Value -in 'utf8NoBOM', 'utf8BOM', 'ansi') {
                    $hits.Add("第 $($c.Extent.StartLineNumber) 行：-Encoding $($val.Value)（5.1 沒有這個值）")
                }
            }
        }
    }
    foreach ($h in ($hits | Select-Object -Unique)) { Add-Fail "PowerShell 7 專用語法：$h" }
    if (-not $hits.Count) { Add-Ok '沒有 PowerShell 7 專用語法' }
}

# ---------------------------------------------------------------- 主流程

Write-Line "OPS-command 靜態檢查　$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Line "資料夾：$Path"
Write-Line "PowerShell：$($PSVersionTable.PSVersion)（$($PSVersionTable.PSEdition)）"
if ($PSVersionTable.PSVersion.Major -ne 5) {
    $script:Warns++
    Write-Line '  [警告] 不是 Windows PowerShell 5.1：PS7 語法不會造成解析錯誤、指令清單也不同，結果僅供參考。'
}

$files = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.ps1', '.bat', '.cmd' } | Sort-Object Name)
if (-not $files.Count) { Add-Fail "資料夾裡沒有 .ps1 / .bat"; }

$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$parsed = @{}

# 先把所有 .ps1 讀進來、解析，函式清單跨檔共用（排程面板會呼叫主程式的 Write-OpsLog）
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = $null; $decodeError = $null
    try { $text = $utf8Strict.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 })) }
    catch { $decodeError = $_.Exception.Message }
    # Latin1 一個位元組對一個字元，用來數換行與找非 ASCII
    $latin1 = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $entry = @{ File = $f; Bytes = $bytes; Latin1 = $latin1; Bom = $bom; Text = $text; DecodeError = $decodeError }
    if ($f.Extension -eq '.ps1' -and $text -ne $null) {
        $p = Get-Ast $text $f.FullName
        $entry.Ast = $p.Ast; $entry.Tokens = $p.Tokens; $entry.Errors = $p.Errors
    }
    $parsed[$f.Name] = $entry
}

$allFunctions = @{}
foreach ($e in $parsed.Values) {
    if ($e.Ast) { foreach ($fd in $e.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $allFunctions[$fd.Name] = 1 } }
}
foreach ($k in $KnownCommands) { $allFunctions[$k] = 1 }

# 哪些檔案是在函式裡被 dot-source 的（例如 Open-TaskManagerPanel 裡的 . $gui）
$dotSourcedInFunction = @{}
foreach ($e in $parsed.Values) {
    if (-not $e.Ast) { continue }
    foreach ($fd in $e.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $dots = @($fd.Body.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] -and [string]$args[0].InvocationOperator -eq 'Dot' }, $true))
        if (-not $dots.Count) { continue }
        foreach ($s in $fd.Body.FindAll({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($s.Value -match '^[\w\.-]+\.ps1$') { $dotSourcedInFunction[$s.Value] = $fd.Name }
        }
    }
}

foreach ($f in $files) {
    $e = $parsed[$f.Name]
    Write-Line ''
    Write-Line "■ $($f.Name)（$([Math]::Round($f.Length / 1KB, 1)) KB）"

    # ---- 1. 編碼
    $encOk = $true
    if ($e.DecodeError) { $encOk = $false; Add-Fail "不是合法的 UTF-8：$($e.DecodeError)" }
    if ($f.Extension -eq '.ps1') {
        if ($f.Name -in $NoBomFiles) {
            if ($e.Bom) { $encOk = $false; Add-Fail '開頭有 BOM。這支要給 irm | iex 用，BOM 會讓 iex 失敗，必須是 UTF-8 無 BOM' }
        } elseif (-not $e.Bom) {
            $encOk = $false; Add-Fail '沒有 BOM。Windows PowerShell 5.1 會用系統字碼頁（繁中 950）讀檔，中文會把引號吃掉，必須是 UTF-8 含 BOM'
        }
    } else {
        $m = [regex]::Match($e.Latin1, '[^\x00-\x7F]')
        if ($m.Success) {
            $encOk = $false
            Add-Fail "不是純 ASCII（第 $(Get-LineOf $e.Latin1 $m.Index) 行起有非 ASCII 位元組）。cmd.exe 用系統字碼頁讀 .bat，中文會變亂碼"
        }
    }
    $lfOnly = [regex]::Matches($e.Latin1, '(?<!\r)\n')
    $crOnly = [regex]::Matches($e.Latin1, '\r(?!\n)')
    if ($lfOnly.Count -or $crOnly.Count) {
        $first = @(@($lfOnly) + @($crOnly) | ForEach-Object Index | Sort-Object)[0]
        $encOk = $false
        Add-Fail "換行不是全部 CRLF：只有 LF $($lfOnly.Count) 處、只有 CR $($crOnly.Count) 處（第一處在第 $(Get-LineOf $e.Latin1 $first) 行）"
    }
    if ($encOk) { Add-Ok ("編碼：{0}、CRLF" -f $(if ($f.Extension -ne '.ps1') { '純 ASCII' } elseif ($e.Bom) { 'UTF-8 含 BOM' } else { 'UTF-8 無 BOM' })) }

    # ---- 2. 控制字元
    if ($e.Text -ne $null) {
        $ctrl = @()
        $t = $e.Text
        foreach ($m in [regex]::Matches($t, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\uFEFF\uFFFD\u200B-\u200F\u2028\u2029]')) {
            $ctrl += ('第 {0} 行 U+{1:X4}' -f (Get-LineOf $t $m.Index), [int][char]$m.Value)
            if ($ctrl.Count -ge 10) { break }
        }
        if ($ctrl.Count) { Add-Fail "有控制字元／不可見字元：$($ctrl -join '、')" } else { Add-Ok '沒有控制字元' }
    }

    if ($f.Extension -ne '.ps1' -or -not $e.Ast) { continue }

    # ---- 3. 語法
    if ($e.Errors.Count) {
        foreach ($pe in ($e.Errors | Select-Object -First 10)) { Add-Fail ("解析錯誤 第 {0} 行：{1}" -f $pe.Extent.StartLineNumber, $pe.Message) }
        if ($e.Errors.Count -gt 10) { Add-Fail "……共 $($e.Errors.Count) 個解析錯誤" }
        continue
    }
    Add-Ok '解析 0 錯誤'
    $workers = @(Get-WorkerScripts $e.Ast)
    foreach ($w in $workers) {
        $wp = Get-Ast $w.Text "$($f.Name):$($w.Name)"
        if ($wp.Errors.Count) { foreach ($pe in $wp.Errors | Select-Object -First 3) { Add-Fail ("背景程式碼 `${0}（第 {1} 行起）解析錯誤：{2}" -f $w.Name, $w.Line, $pe.Message) } }
        $w | Add-Member -NotePropertyName Ast -NotePropertyValue $wp.Ast
    }
    if ($workers.Count) { Write-Line "  [資訊] 背景執行的程式碼 $($workers.Count) 段：$(($workers | ForEach-Object Name) -join '、')" }

    # ---- 4. 點不到的函式
    Test-Reachability $e.Ast

    # ---- 5. 巢狀閉包
    Test-NestedClosures $e.Ast

    # ---- 6. 閉包呼叫區域函式
    $wholeLocal = $dotSourcedInFunction.ContainsKey($f.Name)
    if ($wholeLocal) { Write-Line "  [資訊] 這個檔案在 $($dotSourcedInFunction[$f.Name]) 裡被 dot-source，函式都算區域函式" }
    Test-ClosureLocalFunctions $e.Ast $wholeLocal

    # ---- 7. 不存在的指令
    $bad = Test-Commands $e.Ast $allFunctions ''
    foreach ($w in $workers) {
        if (-not $w.Ast) { continue }
        $own = @{}
        foreach ($fd in $w.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $own[$fd.Name] = 1 }
        foreach ($k in $KnownCommands) { $own[$k] = 1 }
        foreach ($c in $w.Ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if ($name -and $allFunctions.ContainsKey($name) -and -not $own.ContainsKey($name)) {
                $bad++; Add-Fail ("背景程式碼 `${0} 呼叫主程式的函式 {1}：背景 runspace 看不到它" -f $w.Name, $name)
            }
        }
        $bad += Test-Commands $w.Ast $own "背景程式碼 `$$($w.Name) "
    }
    if (-not $bad) { Add-Ok '呼叫的指令都存在' }

    # ---- 8. 唯讀自動變數
    Test-AutomaticAssignments $e.Ast
    $script:QuietOk = $true
    foreach ($w in $workers) { if ($w.Ast) { Test-AutomaticAssignments $w.Ast } }
    $script:QuietOk = $false

    # ---- 9. PS7 語法
    Test-Ps7Syntax $e.Ast $e.Tokens
    $script:QuietOk = $true
    foreach ($w in $workers) { if ($w.Ast) { Test-Ps7Syntax $w.Ast $null } }
    $script:QuietOk = $false
}

Write-Line ''
Write-Line ("結果：失敗 {0} 項、警告 {1} 項 → {2}" -f $script:Fails, $script:Warns, $(if ($script:Fails) { '不通過' } else { '通過' }))
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllLines($OutFile, $script:Out, (New-Object System.Text.UTF8Encoding($true)))
}
exit $(if ($script:Fails) { 1 } else { 0 })
