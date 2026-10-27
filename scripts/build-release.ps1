param(
    [ValidateSet('windows', 'apk')]
    [string]$Target = 'windows',
    [string]$PublicKeyFile,
    [string]$LicenseApiUrl = '',
    [switch]$IsolatedSmoke,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($PublicKeyFile)) {
    $PublicKeyFile = Join-Path $projectRoot 'cloud\license_api\license-public.key'
}
if (-not (Test-Path -LiteralPath $PublicKeyFile -PathType Leaf)) {
    throw 'The existing License API public key file is required for a release build.'
}
if ((Split-Path -Leaf $PublicKeyFile) -match 'private|secret') {
    throw 'A private key must never be passed to a client release build.'
}
$publicKey = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
try {
    $publicKeyBytes = [Convert]::FromBase64String($publicKey)
} catch {
    throw 'The License API public key must be base64 encoded.'
}
if ($publicKeyBytes.Length -ne 32) {
    throw 'The License API Ed25519 public key must contain exactly 32 bytes.'
}

$licenseApiUrl = $LicenseApiUrl.Trim()
if ($IsolatedSmoke -and $Target -ne 'windows') {
    throw 'The isolated smoke data option is only supported for Windows internal test builds.'
}
if ($licenseApiUrl.Length -gt 0) {
    $apiUri = $null
    if (-not [Uri]::TryCreate($licenseApiUrl, [UriKind]::Absolute, [ref]$apiUri) -or
        $apiUri.Scheme -ne 'https' -or
        [string]::IsNullOrWhiteSpace($apiUri.Host) -or
        $apiUri.UserInfo.Length -gt 0 -or
        $apiUri.Query.Length -gt 0 -or
        $apiUri.Fragment.Length -gt 0 -or
        $apiUri.AbsolutePath -ne '/') {
        throw 'The release License API URL must be an HTTPS origin without credentials, path, query, or fragment.'
    }
    $parsedAddress = $null
    if ($apiUri.Host -eq 'localhost' -or
        [System.Net.IPAddress]::TryParse($apiUri.Host, [ref]$parsedAddress)) {
        throw 'A release License API URL cannot use localhost or an IP address.'
    }
}

if ($ValidateOnly) {
    Write-Output 'Release configuration valid: existing Ed25519 public key; HTTPS API origin supplied or intentionally unset.'
    return
}

$defines = @("--dart-define=LICENSE_PUBLIC_KEY_BASE64=$publicKey")
if ($IsolatedSmoke) {
    $defines += '--dart-define=RC_ISOLATED_DATA=true'
    Write-Output 'Building an INTERNAL SMOKE artifact with isolated data support; do not distribute it.'
}
if ($licenseApiUrl.Length -gt 0) {
    $defines += "--dart-define=LICENSE_API_URL=$licenseApiUrl"
}
Push-Location $projectRoot
try {
    & flutter build $Target --release @defines
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter $Target release build failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
