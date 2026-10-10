$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$RepoZipUrl = "https://github.com/nohanvs/novak-reels-importer/archive/refs/heads/main.zip"
$TempRoot = Join-Path $env:TEMP ("novak-update-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "repo.zip"
$ExtractPath = Join-Path $TempRoot "extract"

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

  Write-Host "Verificando atualizações do NovaK Reels..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $RepoZipUrl -OutFile $ZipPath -UseBasicParsing
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractPath -Force

  $DownloadedRoot = Get-ChildItem -LiteralPath $ExtractPath -Directory | Select-Object -First 1
  if (!$DownloadedRoot) { throw "Não consegui encontrar os arquivos atualizados." }

  # Preserve all machine-specific data and credentials.
  $exclude = @(
    ".git",
    ".venv",
    "node_modules",
    ".vercel",
    ".novak-local.json",
    ".vercel.local.env",
    ".env.local",
    "scripts\auto-update-local.ps1",
    "INICIAR_LOCAL.bat"
  )

  Write-Host "Aplicando a versão mais recente..." -ForegroundColor Cyan
  Get-ChildItem -LiteralPath $DownloadedRoot.FullName -Force | ForEach-Object {
    $relative = $_.Name
    if ($exclude -contains $relative) { return }
    $destination = Join-Path $Root $relative
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
  }

  Write-Host "Código atualizado. Iniciando o executor..." -ForegroundColor Green
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\run-local.ps1")
  exit $LASTEXITCODE
}
catch {
  Write-Host "Falha ao atualizar automaticamente: $($_.Exception.Message)" -ForegroundColor Yellow
  Write-Host "Vou tentar iniciar o executor que já está instalado." -ForegroundColor Yellow
  $localRunner = Join-Path $Root "scripts\run-local.ps1"
  if (Test-Path $localRunner) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $localRunner
    exit $LASTEXITCODE
  }
  exit 1
}
finally {
  if (Test-Path $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
