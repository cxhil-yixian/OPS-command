# Update-Sha256Sums.ps1 -- 重新產生 SHA256SUMS（ops-win.ps1 下載後用它核對檔案）
#
# 改了 Win_Admin_Tool.ps1 或 Win_Schedule_Panel.ps1 之後一定要重跑，並把 SHA256SUMS 一起 commit；
# 否則一行指令會因為「對不上」而拒絕執行。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Update-Sha256Sums.ps1          產生
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Update-Sha256Sums.ps1 -Check   只核對，不寫檔
#
# 雜湊算法跟 ops-win.ps1 一致：先把 CRLF 換成 LF 再算 SHA256。
# 原因：.gitattributes 讓 *.ps1 在 Windows 的工作目錄是 CRLF，但 repo 裡（也就是 GitHub raw 給的）是 LF。
# 統一成 LF，在 Windows 或 Linux 的 checkout 上跑結果都一樣，也等於 Linux 上直接
# `sha256sum Win_Admin_Tool.ps1` 對 GitHub raw 下載回來的檔案算出的值。

param(
    # SHA256SUMS 與兩支程式所在的資料夾；預設是這支腳本的上一層
    [string]$Dir = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)
$ErrorActionPreference = 'Stop'

$names = @('Win_Admin_Tool.ps1', 'Win_Schedule_Panel.ps1')
$sumPath = Join-Path $Dir 'SHA256SUMS'

function Get-LfSha256([string]$Path) {
    $latin = [Text.Encoding]::GetEncoding(28591)
    $bytes = $latin.GetBytes($latin.GetString([IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

$lines = foreach ($n in $names) {
    $p = Join-Path $Dir $n
    if (-not (Test-Path $p)) { throw "找不到 $p" }
    '{0}  {1}' -f (Get-LfSha256 $p), $n
}

if ($Check) {
    if (-not (Test-Path $sumPath)) { Write-Host "沒有 $sumPath" -ForegroundColor Red; exit 1 }
    $old = @([IO.File]::ReadAllLines($sumPath) | Where-Object { $_.Trim() })
    $diff = Compare-Object $old $lines
    if ($diff) {
        Write-Host 'SHA256SUMS 跟目前的檔案對不上，請不帶 -Check 重跑一次：' -ForegroundColor Red
        $diff | ForEach-Object { "  {0} {1}" -f $(if ($_.SideIndicator -eq '<=') { '清單' } else { '實際' }), $_.InputObject }
        exit 1
    }
    Write-Host 'SHA256SUMS 與目前的檔案一致。' -ForegroundColor Green
    exit 0
}

# ASCII、LF、無 BOM：跟 sha256sum 的輸出格式相同
[IO.File]::WriteAllText($sumPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "已更新 $sumPath" -ForegroundColor Green
$lines | ForEach-Object { "  $_" }
