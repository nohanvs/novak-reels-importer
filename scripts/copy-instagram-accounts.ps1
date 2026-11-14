$ErrorActionPreference = "Stop"

# The source values are Windows-DPAPI encrypted. This copies the encrypted
# account records only; it never decrypts, prints, or transmits a token.
$Root = Split-Path -Parent $PSScriptRoot
$Downloads = Split-Path -Parent $Root
$SourcePath = Join-Path $Downloads "luanz7-reels-importer\.luanz7-local.json"
$TargetPath = Join-Path $Root ".facada-local.json"

if (!(Test-Path -LiteralPath $SourcePath)) {
  throw "Não encontrei a configuração local do Luanz7."
}

try {
  $source = Get-Content -Raw -LiteralPath $SourcePath | ConvertFrom-Json
} catch {
  throw "A configuração local do Luanz7 não pôde ser lida."
}

$accounts = @($source.InstagramAccounts | Where-Object { $_.UserId -and $_.AccessTokenProtected })
if ($accounts.Count -eq 0) {
  throw "Não há contas do Instagram salvas na configuração do Luanz7."
}

if (Test-Path -LiteralPath $TargetPath) {
  try { $target = Get-Content -Raw -LiteralPath $TargetPath | ConvertFrom-Json } catch { $target = [pscustomobject]@{} }
} else {
  $target = [pscustomobject]@{}
}

$target | Add-Member InstagramAccounts $accounts -Force
$target | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TargetPath -Encoding UTF8
Write-Host ("{0} conta(s) do Instagram foram vinculadas ao Facada Reels de forma criptografada." -f $accounts.Count) -ForegroundColor Green
