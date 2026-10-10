$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$TempRoot = Join-Path $env:TEMP ("novak-start-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "repo.zip"
$ExtractPath = Join-Path $TempRoot "extract"
$RepoZipUrl = "https://github.com/nohanvs/novak-reels-importer/archive/refs/heads/main.zip"

function Apply-BlobCredentialFix {
  $runner = Join-Path $Root "scripts\run-local.ps1"
  if (!(Test-Path $runner)) { throw "Não encontrei scripts\run-local.ps1." }

  $content = Get-Content -Raw -LiteralPath $runner
  $pattern = '(?s)function Ensure-BlobCredentials \{.*?\r?\n\}'
  $replacement = @'
function Ensure-BlobCredentials {
  # O executor Windows usa deliberadamente um token estático local.
  # Ignore BLOB_READ_WRITE_TOKEN/VERCEL_OIDC_TOKEN puxados pelo Vercel CLI.
  Remove-Item Env:VERCEL_OIDC_TOKEN -ErrorAction SilentlyContinue
  Remove-Item Env:BLOB_READ_WRITE_TOKEN -ErrorAction SilentlyContinue

  $config = $null
  if (Test-Path $LocalConfigPath) {
    try { $config = Get-Content -Raw -LiteralPath $LocalConfigPath | ConvertFrom-Json } catch { $config = $null }
  }

  if ($config -and $config.BlobReadWriteTokenProtected) {
    $secureBlobToken = ConvertTo-SecureString ([string]$config.BlobReadWriteTokenProtected)
    $saved = Convert-SecureToPlainText $secureBlobToken
    if ($saved.Trim().Length -ge 20) {
      $env:BLOB_READ_WRITE_TOKEN = $saved.Trim()
      return
    }
  }

  Write-Host ""
  Write-Host "O executor precisa de um token Read-Write do Vercel Blob para este PC." -ForegroundColor Yellow
  Write-Host "No Vercel -> Storage -> Blob -> seu store -> Quickstart, copie o BLOB_READ_WRITE_TOKEN completo."
  Write-Host "A entrada fica oculta e será criptografada para este usuário do Windows."
  $secureBlobToken = Read-Host "Cole BLOB_READ_WRITE_TOKEN (entrada oculta)" -AsSecureString
  if ($secureBlobToken.Length -lt 20) {
    throw "O token do Blob parece curto demais. Confirme o token completo no painel do Vercel."
  }

  if (!$config) { $config = [pscustomobject]@{} }
  $config | Add-Member -NotePropertyName BlobReadWriteTokenProtected -NotePropertyValue (ConvertFrom-SecureString $secureBlobToken) -Force
  Save-LocalConfig $config
  $env:BLOB_READ_WRITE_TOKEN = Convert-SecureToPlainText $secureBlobToken
}
'@

  $updated = [regex]::Replace($content, $pattern, $replacement.TrimEnd(), 1)
  if ($updated -eq $content) { throw "Não consegui localizar Ensure-BlobCredentials para corrigir." }
  Set-Content -LiteralPath $runner -Value $updated -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
  Write-Host "Verificando atualizações do NovaK Reels..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $RepoZipUrl -OutFile $ZipPath -UseBasicParsing
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractPath -Force
  $DownloadedRoot = Get-ChildItem -LiteralPath $ExtractPath -Directory | Select-Object -First 1
  if (!$DownloadedRoot) { throw "Não consegui encontrar os arquivos atualizados." }

  $exclude = @(".git", ".venv", "node_modules", ".vercel", ".novak-local.json", ".vercel.local.env", "scripts\start-local-fixed.ps1", "INICIAR_LOCAL.bat")
  Write-Host "Aplicando a versão mais recente..." -ForegroundColor Cyan
  Get-ChildItem -LiteralPath $DownloadedRoot.FullName -Force | ForEach-Object {
    if ($exclude -contains $_.Name) { return }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Root $_.Name) -Recurse -Force
  }

  Apply-BlobCredentialFix
  Write-Host "Código atualizado e autenticação local do Blob corrigida." -ForegroundColor Green
  & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\run-local.ps1")
  exit $LASTEXITCODE
}
catch {
  Write-Host "Falha ao atualizar/corrigir automaticamente: $($_.Exception.Message)" -ForegroundColor Yellow
  $runner = Join-Path $Root "scripts\run-local.ps1"
  if (Test-Path $runner) {
    Apply-BlobCredentialFix
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner
    exit $LASTEXITCODE
  }
  exit 1
}
finally {
  if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
