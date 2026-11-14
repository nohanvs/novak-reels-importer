$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root ".facada-local.json"

if (!(Test-Path -LiteralPath $ConfigPath)) { exit 0 }
try { $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json } catch { throw "Não foi possível ler a configuração local do Facada." }
$property = $config.PSObject.Properties["BlobReadWriteTokenProtected"]
if ($property) { $config.PSObject.Properties.Remove("BlobReadWriteTokenProtected") }
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "O token antigo do Blob foi removido. Na próxima abertura, o executor pedirá o novo token público." -ForegroundColor Green
