$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$ConfigPath = Join-Path $Root ".facada-local.json"
$Scope = "nohanvsff-3505s-projects"

# Generate a high-entropy executor secret without writing it to the console.
$bytes = [byte[]]::new(48)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

& npx vercel env add NOVAK_IMPORTER_TOKEN "production,preview" --value $token --sensitive --yes --scope $Scope
if ($LASTEXITCODE -ne 0) { throw "Não consegui salvar o token interno no Vercel." }

if (Test-Path -LiteralPath $ConfigPath) {
  try { $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json } catch { $config = [pscustomobject]@{} }
} else {
  $config = [pscustomobject]@{}
}
$secure = ConvertTo-SecureString $token -AsPlainText -Force
$config | Add-Member ImporterTokenProtected (ConvertFrom-SecureString $secure) -Force
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host "Token interno criado e salvo de forma criptografada. Ele não será exibido." -ForegroundColor Green
