$ErrorActionPreference = 'Stop'
$publicKeyFile = Join-Path $PSScriptRoot '..\cloud\license_api\license-public.key'
if (-not (Test-Path -LiteralPath $publicKeyFile)) {
    throw "Missing public key: $publicKeyFile. Run npm run setup:keys in cloud/license_api first."
}
$publicKey = (Get-Content -LiteralPath $publicKeyFile -Raw).Trim()
if ([Convert]::FromBase64String($publicKey).Length -ne 32) {
    throw 'The local Ed25519 public key must contain 32 bytes.'
}
Push-Location (Join-Path $PSScriptRoot '..')
try {
    flutter run -d windows --dart-define="LICENSE_PUBLIC_KEY_BASE64=$publicKey" --dart-define='LICENSE_API_URL=http://localhost:3000'
} finally {
    Pop-Location
}
