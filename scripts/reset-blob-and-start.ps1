$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$configPath = Join-Path $Root ".novak-local.json"
if (Test-Path $configPath) {
  try {
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    if ($config.PSObject.Properties.Name -contains "BlobReadWriteTokenProtected") {
      $config.PSObject.Properties.Remove("BlobReadWriteTokenProtected")
      $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
      Write-Host "Credencial antiga do Blob removida." -ForegroundColor Yellow
    }
  } catch {
    Write-Host "Aviso: não consegui limpar a credencial antiga do Blob." -ForegroundColor Yellow
  }
}

$env:BLOB_READ_WRITE_TOKEN = $null
$env:VERCEL_OIDC_TOKEN = $null

$launcher = Join-Path $PSScriptRoot "start-local-fixed.ps1"
if (!(Test-Path $launcher)) { throw "Não encontrei scripts\start-local-fixed.ps1." }
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher
exit $LASTEXITCODE
