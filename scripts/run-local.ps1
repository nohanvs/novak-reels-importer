$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$ConfigPath = Join-Path $Root ".luanz7-local.json"
$VercelEnvPath = Join-Path $Root ".vercel.local.env"
$VercelScope = "nohanvsff-3505s-projects"
$ProjectName = "novak-reels-importer"
$ApiBaseUrl = "https://novak-reels-importer.vercel.app"
$PollSeconds = 30
$RateLimitCooldownSeconds = 1800

function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Convert-SecureToPlainText([Security.SecureString]$Secret) {
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function Read-LocalConfig {
  if (!(Test-Path $ConfigPath)) { return [pscustomobject]@{} }
  try { return Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json } catch { return [pscustomobject]@{} }
}
function Save-LocalConfig($Config) { $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
function Read-DotEnv([string]$Path) {
  $values = @{}
  if (!(Test-Path $Path)) { return $values }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $value = $matches[2].Trim(); if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) { $value = $value.Substring(1, $value.Length - 2) }; $values[$matches[1]] = $value
    }
  }; return $values
}
function Pull-VercelEnvironment {
  $temporaryPath = "$VercelEnvPath.tmp"; Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
  Write-Host "Atualizando as variáveis do Vercel..." -ForegroundColor Cyan
  & vercel env pull $temporaryPath --environment=production --scope $VercelScope
  if ($LASTEXITCODE -ne 0 -or !(Test-Path $temporaryPath)) { return $false }
  Move-Item -LiteralPath $temporaryPath -Destination $VercelEnvPath -Force
  foreach ($entry in (Read-DotEnv $VercelEnvPath).GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process") }
  $env:NOVAK_API_BASE_URL = $ApiBaseUrl; $env:META_GRAPH_API_VERSION = "v23.0"; $env:PYTHONUNBUFFERED = "1"; return $true
}
function Ensure-ImporterToken {
  $config = Read-LocalConfig; $current = ([string]$env:NOVAK_IMPORTER_TOKEN).Trim()
  if ($current.Length -ge 32) { $secure = ConvertTo-SecureString $current -AsPlainText -Force; $config | Add-Member ImporterTokenProtected (ConvertFrom-SecureString $secure) -Force; Save-LocalConfig $config; return }
  if ($config.ImporterTokenProtected) { $saved = Convert-SecureToPlainText (ConvertTo-SecureString ([string]$config.ImporterTokenProtected)); if ($saved.Trim().Length -ge 32) { $env:NOVAK_IMPORTER_TOKEN = $saved.Trim(); return } }
  Write-Host "Cole o mesmo NOVAK_IMPORTER_TOKEN salvo no Vercel (a entrada fica oculta)." -ForegroundColor Yellow
  $secure = Read-Host "NOVAK_IMPORTER_TOKEN" -AsSecureString; if ($secure.Length -lt 32) { throw "Token do executor inválido." }
  $config | Add-Member ImporterTokenProtected (ConvertFrom-SecureString $secure) -Force; Save-LocalConfig $config; $env:NOVAK_IMPORTER_TOKEN = Convert-SecureToPlainText $secure
}
function Ensure-BlobToken {
  Remove-Item Env:VERCEL_OIDC_TOKEN -ErrorAction SilentlyContinue; Remove-Item Env:BLOB_READ_WRITE_TOKEN -ErrorAction SilentlyContinue
  $config = Read-LocalConfig
  if ($config.BlobReadWriteTokenProtected) { $saved = Convert-SecureToPlainText (ConvertTo-SecureString ([string]$config.BlobReadWriteTokenProtected)); if ($saved.Trim().Length -ge 20) { $env:BLOB_READ_WRITE_TOKEN = $saved.Trim(); return } }
  Write-Host "Cole o BLOB_READ_WRITE_TOKEN do Vercel Blob (a entrada fica oculta)." -ForegroundColor Yellow
  $secure = Read-Host "BLOB_READ_WRITE_TOKEN" -AsSecureString; if ($secure.Length -lt 20) { throw "Token do Blob inválido." }
  $config | Add-Member BlobReadWriteTokenProtected (ConvertFrom-SecureString $secure) -Force; Save-LocalConfig $config; $env:BLOB_READ_WRITE_TOKEN = Convert-SecureToPlainText $secure
}
function Get-InstagramAccounts {
  $config = Read-LocalConfig; $accounts = @()
  if ($config.InstagramAccounts) { $accounts = @($config.InstagramAccounts | Where-Object { $_.UserId -and $_.AccessTokenProtected }) }
  if ($accounts.Count -eq 0) {
    $count = Read-Host "Quantas contas do Instagram devem publicar? (1 ou 2)"; if ($count -notin @("1", "2")) { $count = "1" }
    for ($index = 1; $index -le [int]$count; $index++) {
      $userId = Read-Host "INSTAGRAM_USER_ID da conta $index"; if ([string]::IsNullOrWhiteSpace($userId)) { throw "O ID da conta $index é obrigatório." }
      $token = Read-Host "INSTAGRAM_ACCESS_TOKEN da conta $index (oculto)" -AsSecureString; if ($token.Length -lt 20) { throw "O token da conta $index parece inválido." }
      $accounts += [pscustomobject]@{ UserId = $userId.Trim(); AccessTokenProtected = ConvertFrom-SecureString $token }
    }
    $config | Add-Member InstagramAccounts $accounts -Force; Save-LocalConfig $config
  }
  $plain = @(); foreach ($account in $accounts) { $plain += @{ userId = [string]$account.UserId; accessToken = Convert-SecureToPlainText (ConvertTo-SecureString ([string]$account.AccessTokenProtected)) } }
  $env:INSTAGRAM_ACCOUNTS_JSON = $plain | ConvertTo-Json -Compress; $env:INSTAGRAM_USER_ID = $plain[0].userId; $env:INSTAGRAM_ACCESS_TOKEN = $plain[0].accessToken
}
function In-Cooldown {
  $config = Read-LocalConfig; if (!$config.PublishCooldownUntil) { return $false }
  try { return ([DateTime]::Parse([string]$config.PublishCooldownUntil) -gt (Get-Date)) } catch { return $false }
}
function Start-Cooldown {
  $config = Read-LocalConfig; $until = (Get-Date).AddSeconds($RateLimitCooldownSeconds); $config | Add-Member PublishCooldownUntil $until.ToString("o") -Force; Save-LocalConfig $config
  Write-Host ("A Meta limitou as requisições. Publicações pausadas até {0}." -f $until.ToString("HH:mm")) -ForegroundColor Yellow
}

Write-Host "=== Luanz7 Reels - executor local para Windows ===" -ForegroundColor Cyan
if (!(Test-Command "node") -or !(Test-Command "npm")) {
  throw "Node.js LTS não está disponível. Instale em https://nodejs.org/ e abra este arquivo novamente."
}
if (!(Test-Command "python")) {
  Write-Host "Python não está instalado neste Windows." -ForegroundColor Yellow
  Write-Host "Baixe o instalador 64-bit em https://www.python.org/downloads/windows/" -ForegroundColor Cyan
  Write-Host "Na primeira tela, marque 'Add Python to PATH'; depois conclua a instalação e abra INICIAR_LOCAL.bat novamente." -ForegroundColor Cyan
  throw "Falta instalar Python 3.11 ou superior."
}
if (!(Test-Command "ffmpeg")) { throw "Instale o FFmpeg e adicione-o ao PATH antes de iniciar." }
if (!(Test-Command "vercel")) { & npm install --global vercel; if ($LASTEXITCODE -ne 0) { throw "Não consegui instalar a Vercel CLI." } }
if (!(Test-Path (Join-Path $Root ".vercel\project.json"))) { & vercel link --project $ProjectName --scope $VercelScope; if ($LASTEXITCODE -ne 0) { throw "Não consegui vincular esta pasta ao Vercel." } }
if (!(Test-Path (Join-Path $Root ".venv\Scripts\python.exe"))) { & python -m venv (Join-Path $Root ".venv") }
$Python = Join-Path $Root ".venv\Scripts\python.exe"
& $Python -m pip install --disable-pip-version-check -e .; if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar o importador." }
& npm install --no-audit --no-fund; if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar as dependências Node." }
if (!(Pull-VercelEnvironment)) { throw "Não consegui baixar as variáveis do Vercel." }; Ensure-ImporterToken; Ensure-BlobToken; Get-InstagramAccounts

Write-Host "Executor ativo. Clips novos da Kick serão adicionados automaticamente; não feche esta janela." -ForegroundColor Green
while ($true) {
  Write-Host ("[{0}] Verificando clips novos da Kick..." -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Cyan; & node scripts/scan-kick.mjs
  Write-Host ("[{0}] Verificando fila de importação..." -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Cyan; & $Python -m novak_importer
  if (In-Cooldown) { Write-Host "Publicação em pausa por limite da Meta." -ForegroundColor Yellow }
  else { Write-Host ("[{0}] Verificando fila de publicação..." -f (Get-Date -Format "HH:mm:ss")); & $Python -m novak_publisher; if ($LASTEXITCODE -eq 4) { Start-Cooldown } }
  Start-Sleep -Seconds $PollSeconds
}
