$ErrorActionPreference = "Stop"
$RunnerPath = Join-Path $PSScriptRoot "run-local.ps1"
if (!(Test-Path $RunnerPath)) { throw "Não encontrei scripts\\run-local.ps1." }
$content = Get-Content -Raw -LiteralPath $RunnerPath
$start = $content.IndexOf("function Ensure-BlobCredentials {")
if ($start -lt 0) { throw "Não encontrei a função Ensure-BlobCredentials no executor." }
$endMarker = "`n}`n`nWrite-Host \"=== NovaK Reels - executor local para Windows ===\""
$end = $content.IndexOf($endMarker, $start)
if ($end -lt 0) { throw "Não consegui localizar o fim da função Ensure-BlobCredentials." }
$end += 3
$newFunction = @'
function Ensure-BlobCredentials {
  $config = Get-LocalConfig

  # O executor Windows usa deliberadamente um token estático local.
  # Não reutilize um token puxado pelo Vercel, pois o Blob novo usa OIDC por padrão
  # e um token antigo/stale pode retornar Access denied.
  if ($config -and $config.BlobReadWriteTokenProtected) {
    $secureBlobToken = ConvertTo-SecureString ([string]$config.BlobReadWriteTokenProtected)
    $saved = Convert-SecureToPlainText $secureBlobToken
    if ($saved.Trim().Length -ge 20) {
      $env:BLOB_READ_WRITE_TOKEN = $saved.Trim()
      Remove-Item Env:VERCEL_OIDC_TOKEN -ErrorAction SilentlyContinue
      return
    }
  }

  Write-Host ""
  Write-Host "O executor precisa de um token Read-Write do Vercel Blob para este PC." -ForegroundColor Yellow
  Write-Host "No Vercel: Storage -> Blob -> seu store -> Quickstart, copie o BLOB_READ_WRITE_TOKEN completo."
  Write-Host "A entrada fica oculta e será criptografada para este usuário do Windows."
  $secureBlobToken = Read-Host "Cole BLOB_READ_WRITE_TOKEN (entrada oculta)" -AsSecureString
  if ($secureBlobToken.Length -lt 20) { throw "O token do Blob parece curto demais. Confirme o token completo no painel do Vercel." }
  if (!$config) { $config = [pscustomobject]@{} }
  $config | Add-Member -NotePropertyName BlobReadWriteTokenProtected -NotePropertyValue (ConvertFrom-SecureString $secureBlobToken) -Force
  Save-LocalConfig $config
  $env:BLOB_READ_WRITE_TOKEN = Convert-SecureToPlainText $secureBlobToken
  Remove-Item Env:VERCEL_OIDC_TOKEN -ErrorAction SilentlyContinue
}
'@
$content = $content.Substring(0, $start) + $newFunction.TrimEnd() + $content.Substring($end)
Set-Content -LiteralPath $RunnerPath -Value $content -Encoding UTF8
Write-Host "Correção do Blob local aplicada." -ForegroundColor Green
