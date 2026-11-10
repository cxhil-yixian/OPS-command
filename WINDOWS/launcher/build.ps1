# build.ps1 —— 編譯 OPS-command.exe（線上啟動器），可選擇順便簽章
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File WINDOWS\launcher\build.ps1
#
# 用 Windows 內建的 .NET Framework 4.x 編譯器（csc.exe），不需要安裝 Visual Studio 或 .NET SDK。
# 產物：WINDOWS\launcher\dist\OPS-command.exe 與 OPS-command.exe.sha256（dist\ 不進 git，發布放 GitHub Releases）
#
# 簽章（三選一，不帶就不簽）：
#   -PfxPath <檔案>          一般程式碼簽章憑證匯出的 .pfx；密碼放環境變數 OPS_SIGN_PFX_PASSWORD
#   -CertThumbprint <指紋>   已裝進「目前使用者\個人」憑證存放區的憑證（例如 USB 金鑰／雲端 HSM 的憑證）
#   -TrustedSigningMetadata <json>  Azure Trusted Signing 的 metadata.json；同時要給 -DlibPath（Azure.CodeSigning.Dlib.dll）
# 需要 signtool.exe（Windows SDK 內附）；找不到時可用 -SignTool 指定。

param(
    [string]$PfxPath,
    [string]$CertThumbprint,
    [string]$TrustedSigningMetadata,
    [string]$DlibPath,
    [string]$SignTool,
    [string]$TimestampUrl
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $here 'dist'
$exe  = Join-Path $dist 'OPS-command.exe'
New-Item -ItemType Directory -Force $dist | Out-Null

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "找不到 .NET Framework 4.x 的 csc.exe" }

& $csc /nologo /target:exe /platform:anycpu /optimize+ /codepage:65001 `
    "/win32manifest:$(Join-Path $here 'app.manifest')" "/out:$exe" (Join-Path $here 'OpsLauncher.cs')
if ($LASTEXITCODE) { throw "編譯失敗（csc 結束代碼 $LASTEXITCODE）" }
Write-Host "編譯完成：$exe"

$signMode = if ($PfxPath) { 'pfx' } elseif ($CertThumbprint) { 'thumbprint' } elseif ($TrustedSigningMetadata) { 'trusted' } else { '' }
if ($signMode) {
    if (-not $SignTool) {
        $SignTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $SignTool -or -not (Test-Path $SignTool)) { throw "找不到 signtool.exe（Windows SDK），請用 -SignTool 指定" }
    $sa = @('sign', '/v', '/fd', 'SHA256', '/td', 'SHA256', '/d', 'OPS-command')
    switch ($signMode) {
        'pfx' {
            if (-not $env:OPS_SIGN_PFX_PASSWORD) { throw "請先設環境變數 OPS_SIGN_PFX_PASSWORD" }
            $sa += @('/f', $PfxPath, '/p', $env:OPS_SIGN_PFX_PASSWORD, '/tr', $(if ($TimestampUrl) { $TimestampUrl } else { 'http://timestamp.digicert.com' }))
        }
        'thumbprint' {
            $sa += @('/sha1', $CertThumbprint, '/tr', $(if ($TimestampUrl) { $TimestampUrl } else { 'http://timestamp.digicert.com' }))
        }
        'trusted' {
            if (-not $DlibPath) { throw "Azure Trusted Signing 要同時給 -DlibPath（Azure.CodeSigning.Dlib.dll）" }
            $sa += @('/dlib', $DlibPath, '/dmdf', $TrustedSigningMetadata, '/tr', $(if ($TimestampUrl) { $TimestampUrl } else { 'http://timestamp.acs.microsoft.com' }))
        }
    }
    & $SignTool @sa $exe
    if ($LASTEXITCODE) { throw "簽章失敗（signtool 結束代碼 $LASTEXITCODE）" }
    & $SignTool verify /pa /v $exe | Out-Null
    if ($LASTEXITCODE) { throw "簽章驗證沒通過" }
    Write-Host "簽章完成（$signMode）"
} else {
    Write-Host "沒有給簽章參數：這次產出的是未簽章版本。" -ForegroundColor Yellow
}

$hash = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
[IO.File]::WriteAllText("$exe.sha256", "$hash  OPS-command.exe`n")
Write-Host "SHA256：$hash"
