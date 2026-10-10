$ErrorActionPreference = "Stop"
$RunnerPath = Join-Path $PSScriptRoot "run-local.ps1"
if (!(Test-Path $RunnerPath)) { throw "Não encontrei scripts\run-local.ps1." }

$content = Get-Content -Raw -LiteralPath $RunnerPath
$pattern = '(?s)function Ensure-BlobCredentials \{.*?\r?\n\}'
$newFunction = @'
function Ensure-BlobCredentials {
  # O executor Windows usa deliberadamente um token estático local.
  # Ignore credenciais de Blob puxadas pelo Vercel CLI e não use OIDC local.
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

$updated = [regex]::Replace($content, $pattern, $newFunction.TrimEnd(), 1)
if ($updated -eq $content) { throw "Não consegui localizar Ensure-BlobCredentials no executor." }
Set-Content -LiteralPath $RunnerPath -Value $updated -Encoding UTF8
Write-Host "Correção do Blob local aplicada." -ForegroundColor Green
