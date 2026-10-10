$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$RepoZipUrl = "https://github.com/nohanvs/novak-reels-importer/archive/refs/heads/main.zip"
$TempRoot = Join-Path $env:TEMP ("novak-start-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "repo.zip"
$ExtractPath = Join-Path $TempRoot "extract"
try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  Write-Host "Verificando atualizações do NovaK Reels..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $RepoZipUrl -OutFile $ZipPath -UseBasicParsing
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractPath -Force
  $DownloadedRoot = Get-ChildItem -LiteralPath $ExtractPath -Directory | Select-Object -First 1
  if (!$DownloadedRoot) { throw "Não consegui encontrar os arquivos atualizados." }
  $exclude = @(".git",".venv","node_modules",".vercel",".novak-local.json",".vercel.local.env",".env.local","INICIAR_LOCAL.bat","scripts\start-local.ps1")
  Get-ChildItem -LiteralPath $DownloadedRoot.FullName -Force | ForEach-Object {
    if ($exclude -contains $_.Name) { return }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Root $_.Name) -Recurse -Force
  }
  $BlobFix = Join-Path $Root "scripts\fix-local-blob-auth.ps1"
  if (Test-Path $BlobFix) {
    Write-Host "Aplicando correção do Blob local..." -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $BlobFix
    if ($LASTEXITCODE -ne 0) { throw "Falha ao aplicar a correção do Blob local." }
  }
  Write-Host "Código atualizado. Iniciando o executor..." -ForegroundColor Green
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\run-local.ps1")
  exit $LASTEXITCODE
}
catch {
  Write-Host "Falha ao atualizar: $($_.Exception.Message)" -ForegroundColor Yellow
  $runner = Join-Path $Root "scripts\run-local.ps1"
  if (Test-Path $runner) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner
    exit $LASTEXITCODE
  }
  exit 1
}
finally {
  if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
