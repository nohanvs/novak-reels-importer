$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$VercelEnvPath = Join-Path $Root ".vercel.local.env"
$LocalConfigPath = Join-Path $Root ".novak-local.json"
$VercelScope = "nohanvsff-3505s-projects"
$ProjectName = "novak-reels-importer"
$ApiBaseUrl = "https://novak-reels-importer.vercel.app"

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Convert-SecureToPlainText([Security.SecureString]$Secret) {
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

function Read-DotEnv([string]$Path) {
  $values = @{}
  if (!(Test-Path $Path)) { return $values }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $key = $matches[1]
      $value = $matches[2].Trim()
      if ($value.Length -ge 2 -and (
          ($value.StartsWith('"') -and $value.EndsWith('"')) -or
          ($value.StartsWith("'") -and $value.EndsWith("'"))
        )) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      $values[$key] = $value
    }
  }
  return $values
}

function Pull-VercelEnvironment {
  $temporaryPath = "$VercelEnvPath.tmp"
  if (Test-Path $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
  Write-Host "Atualizando as variáveis protegidas do Vercel..." -ForegroundColor Cyan
  & vercel env pull $temporaryPath --environment=production
  if ($LASTEXITCODE -ne 0 -or !(Test-Path $temporaryPath)) {
    if (Test-Path $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    return $false
  }

  Move-Item -LiteralPath $temporaryPath -Destination $VercelEnvPath -Force
  $values = Read-DotEnv $VercelEnvPath
  foreach ($key in $values.Keys) {
    [Environment]::SetEnvironmentVariable([string]$key, [string]$values[$key], "Process")
  }
  $env:NOVAK_API_BASE_URL = $ApiBaseUrl
  $env:META_GRAPH_API_VERSION = "v23.0"
  $env:PYTHONUNBUFFERED = "1"
  return $true
}

function Save-LocalConfig($Config) {
  $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LocalConfigPath -Encoding UTF8
}

function Configure-InstagramCredentials {
  $config = $null
  if (Test-Path $LocalConfigPath) {
    try { $config = Get-Content -Raw -LiteralPath $LocalConfigPath | ConvertFrom-Json } catch { $config = $null }
  }
  if (!$config -or !$config.InstagramUserId -or !$config.InstagramAccessTokenProtected) {
    Write-Host ""
    Write-Host "Precisamos configurar a conta profissional do Instagram." -ForegroundColor Yellow
    Write-Host "O token será digitado de forma oculta e guardado criptografado para este usuário do Windows."
    $userId = Read-Host "Cole o INSTAGRAM_USER_ID"
    while ([string]::IsNullOrWhiteSpace($userId)) {
      $userId = Read-Host "O ID é obrigatório. Cole o INSTAGRAM_USER_ID"
    }
    $secureToken = Read-Host "Cole o INSTAGRAM_ACCESS_TOKEN (não será exibido)" -AsSecureString
    if ($secureToken.Length -lt 20) {
      throw "O token do Instagram parece curto demais. Execute novamente e cole o token completo."
    }
    if (!$config) { $config = [pscustomobject]@{} }
    $config | Add-Member -NotePropertyName InstagramUserId -NotePropertyValue $userId.Trim() -Force
    $config | Add-Member -NotePropertyName InstagramAccessTokenProtected -NotePropertyValue (ConvertFrom-SecureString $secureToken) -Force
    Save-LocalConfig $config
  }

  $secureInstagramToken = ConvertTo-SecureString ([string]$config.InstagramAccessTokenProtected)
  $env:INSTAGRAM_USER_ID = [string]$config.InstagramUserId
  $env:INSTAGRAM_ACCESS_TOKEN = Convert-SecureToPlainText $secureInstagramToken
}

function Ensure-BlobCredentials {
  if ($env:BLOB_READ_WRITE_TOKEN -or ($env:VERCEL_OIDC_TOKEN -and $env:BLOB_STORE_ID)) {
    return
  }

  $config = $null
  if (Test-Path $LocalConfigPath) {
    try { $config = Get-Content -Raw -LiteralPath $LocalConfigPath | ConvertFrom-Json } catch { $config = $null }
  }
  if ($config -and $config.BlobReadWriteTokenProtected) {
    $secureBlobToken = ConvertTo-SecureString ([string]$config.BlobReadWriteTokenProtected)
    $env:BLOB_READ_WRITE_TOKEN = Convert-SecureToPlainText $secureBlobToken
    return
  }

  Write-Host ""
  Write-Host "Não encontrei credenciais OIDC ou token do Blob no ambiente do Vercel." -ForegroundColor Yellow
  Write-Host "No painel Vercel -> Storage -> Blob -> seu store, copie um Read-Write Token."
  $secureBlobToken = Read-Host "Cole BLOB_READ_WRITE_TOKEN (entrada oculta)" -AsSecureString
  if ($secureBlobToken.Length -lt 20) {
    throw "O token do Blob parece curto demais. Confirme no painel do Vercel."
  }
  if (!$config) { $config = [pscustomobject]@{} }
  $config | Add-Member -NotePropertyName BlobReadWriteTokenProtected -NotePropertyValue (ConvertFrom-SecureString $secureBlobToken) -Force
  Save-LocalConfig $config
  $env:BLOB_READ_WRITE_TOKEN = Convert-SecureToPlainText $secureBlobToken
}

Write-Host "=== NovaK Reels - executor local para Windows ===" -ForegroundColor Cyan
Write-Host "Esse programa fica consultando a fila e processa os vídeos neste PC."
Write-Host ""

# Try to install missing prerequisites automatically when Windows Package Manager is available.
$missingPackages = @()
if (!(Test-Command "node") -or !(Test-Command "npm")) { $missingPackages += @{ id = "OpenJS.NodeJS.LTS"; name = "Node.js LTS" } }
if (!(Test-Command "python")) { $missingPackages += @{ id = "Python.Python.3.12"; name = "Python 3.12" } }
if (!(Test-Command "ffmpeg")) { $missingPackages += @{ id = "Gyan.FFmpeg.Shared"; name = "FFmpeg" } }

if ($missingPackages.Count -gt 0 -and (Test-Command "winget")) {
  $installedAny = $false
  foreach ($package in $missingPackages) {
    Write-Host ("Instalando " + $package.name + " por meio do winget...") -ForegroundColor Cyan
    & winget install --exact --id $package.id --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) {
      $installedAny = $true
    } else {
      Write-Host ("Não consegui instalar " + $package.name + " automaticamente.") -ForegroundColor Yellow
    }
  }
  if ($installedAny) {
    Write-Host ""
    Write-Host "Feche esta janela e abra INICIAR_LOCAL.bat novamente para o Windows atualizar o PATH." -ForegroundColor Green
    exit 0
  }
  Write-Host "A instalação automática falhou. Instale manualmente os itens que faltam:" -ForegroundColor Red
  Write-Host "Python 3.12: https://www.python.org/downloads/windows/"
  Write-Host "Node.js LTS: https://nodejs.org/en/download"
  Write-Host "FFmpeg: https://www.gyan.dev/ffmpeg/builds/"
  exit 1
}

if (!(Test-Command "node") -or !(Test-Command "npm")) {
  Write-Host "Instale Node.js LTS e abra esta janela novamente:" -ForegroundColor Red
  Write-Host "https://nodejs.org/en/download"
  exit 1
}
if (!(Test-Command "python")) {
  Write-Host "Instale Python 3.12 (marcando 'Add Python to PATH') e abra esta janela novamente:" -ForegroundColor Red
  Write-Host "https://www.python.org/downloads/windows/"
  exit 1
}
if (!(Test-Command "ffmpeg")) {
  Write-Host "Instale o FFmpeg para Windows e adicione a pasta bin ao PATH:" -ForegroundColor Red
  Write-Host "https://www.gyan.dev/ffmpeg/builds/"
  exit 1
}

if (!(Test-Command "vercel")) {
  Write-Host "Instalando Vercel CLI..."
  & npm install --global vercel
  if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar Vercel CLI." }
  $npmGlobal = Join-Path $env:APPDATA "npm"
  if ($env:PATH -notlike "*$npmGlobal*") { $env:PATH = "$env:PATH;$npmGlobal" }
  if (!(Test-Command "vercel")) {
    throw "Vercel CLI foi instalado, mas não apareceu no PATH. Feche esta janela e abra INICIAR_LOCAL.bat novamente."
  }
}

if (!(Test-Path (Join-Path $Root ".vercel\project.json"))) {
  Write-Host "Conectando esta pasta ao projeto Vercel. Se pedir login, entre na sua conta e selecione o projeto $ProjectName." -ForegroundColor Cyan
  & vercel link --project $ProjectName --scope $VercelScope
  if ($LASTEXITCODE -ne 0 -or !(Test-Path (Join-Path $Root ".vercel\project.json"))) {
    throw "Não consegui conectar ao projeto Vercel. Execute novamente e conclua o login/vínculo quando solicitado."
  }
}

if (!(Test-Path (Join-Path $Root ".venv\Scripts\python.exe"))) {
  Write-Host "Criando ambiente Python local..."
  & python -m venv (Join-Path $Root ".venv")
  if ($LASTEXITCODE -ne 0) { throw "Não consegui criar o ambiente Python. Instale Python 3.12 e tente novamente." }
}
$Python = Join-Path $Root ".venv\Scripts\python.exe"

Write-Host "Instalando dependências (isso pode levar alguns minutos)..."
& $Python -m pip install --disable-pip-version-check --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "Falha ao preparar pip." }
& $Python -m pip install --disable-pip-version-check -e .
if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar o importador Python." }
& npm install --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar dependências Node." }

if (!(Pull-VercelEnvironment)) {
  throw "Não consegui baixar as variáveis de produção do Vercel. Verifique o login e o vínculo do projeto e execute novamente."
}
Configure-InstagramCredentials
Ensure-BlobCredentials

if (!$env:NOVAK_IMPORTER_TOKEN -or !$env:UPSTASH_REDIS_REST_URL -or !$env:UPSTASH_REDIS_REST_TOKEN) {
  throw "Faltam NOVAK_IMPORTER_TOKEN ou credenciais do Upstash na configuração Production do Vercel."
}
if (!$env:BLOB_READ_WRITE_TOKEN -and !($env:VERCEL_OIDC_TOKEN -and $env:BLOB_STORE_ID)) {
  throw "Falta autenticação do Vercel Blob."
}

$lastRefresh = Get-Date
Write-Host ""
Write-Host "Executor ativo. Deixe esta janela aberta. Para parar, pressione Ctrl+C." -ForegroundColor Green
Write-Host "A fila será verificada a cada 60 segundos. Não cole senhas ou tokens no chat."
Write-Host ""

while ($true) {
  if (((Get-Date) - $lastRefresh).TotalMinutes -ge 30) {
    if (Pull-VercelEnvironment) {
      try { Ensure-BlobCredentials } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
      $lastRefresh = Get-Date
      Write-Host "Credenciais Vercel atualizadas."
    } else {
      Write-Host "Aviso: não consegui atualizar as credenciais Vercel; vou tentar novamente no próximo ciclo." -ForegroundColor Yellow
    }
    Configure-InstagramCredentials
  }

  Write-Host ("[{0}] Verificando fila de importação..." -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Cyan
  & $Python -m novak_importer
  $importExit = $LASTEXITCODE

  Write-Host ("[{0}] Verificando fila de publicação..." -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Cyan
  & $Python -m novak_publisher
  $publishExit = $LASTEXITCODE

  if ($importExit -ne 0 -or $publishExit -ne 0) {
    Write-Host "Um ciclo terminou com erro. Confira as mensagens acima; tentarei novamente em 60 segundos." -ForegroundColor Yellow
  }
  Start-Sleep -Seconds 60
}
