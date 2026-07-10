# Generate upload_certificate.pem and pepk_out.zip for RuStore (Family Chat).
# Run from familychat_app root:
#   powershell -ExecutionPolicy Bypass -File android/signing/generate-rustore-signing.ps1

$ErrorActionPreference = 'Stop'

$SigningDir = $PSScriptRoot
$AndroidDir = Split-Path $SigningDir -Parent

$SecretsFile = Join-Path $SigningDir 'secrets.local.ps1'
if (-not (Test-Path $SecretsFile)) {
    Write-Host 'Create android/signing/secrets.local.ps1 from secrets.example.ps1' -ForegroundColor Red
    exit 1
}
. $SecretsFile

$JavaHome = $env:JAVA_HOME
if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome 'bin\keytool.exe'))) {
    $JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
}
$Keytool = Join-Path $JavaHome 'bin\keytool.exe'
$Java = Join-Path $JavaHome 'bin\java.exe'

if (-not (Test-Path $Keytool)) {
    Write-Host 'keytool not found. Install JDK or Android Studio.' -ForegroundColor Red
    exit 1
}

$KeystorePath = Join-Path $AndroidDir 'familychat-release.keystore'
$PemPath = Join-Path $SigningDir 'upload_certificate.pem'
$PepkJar = Join-Path $SigningDir 'pepk.jar'
$PepkOut = Join-Path $SigningDir 'pepk_out.zip'
$KeyPropsPath = Join-Path $AndroidDir 'key.properties'
$SaveCloudPath = Join-Path $SigningDir 'SAVE_TO_CLOUD.txt'

if (-not (Test-Path $PepkJar)) {
    $DownloadCandidates = @(
        (Join-Path $env:USERPROFILE 'Downloads\pepk (4).jar'),
        (Join-Path $env:USERPROFILE 'Downloads\pepk (3).jar'),
        (Join-Path $env:USERPROFILE 'Downloads\pepk (2).jar'),
        (Join-Path $env:USERPROFILE 'Downloads\pepk (1).jar'),
        (Join-Path $env:USERPROFILE 'Downloads\pepk.jar')
    )
    $found = $false
    foreach ($candidate in $DownloadCandidates) {
        if (Test-Path $candidate) {
            Copy-Item $candidate $PepkJar
            Write-Host "Copied PEPK: $PepkJar"
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Host "Put pepk.jar in $SigningDir (download from RuStore console)." -ForegroundColor Red
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($RuStoreEncryptionKey) -or $RuStoreEncryptionKey -like '*RUSTORE*' -or $RuStoreEncryptionKey -like '*ENCRYPTION_KEY*') {
    Write-Host 'Set RuStoreEncryptionKey in secrets.local.ps1 (from RuStore console).' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $KeystorePath)) {
    Write-Host "Creating keystore: $KeystorePath"
    & $Keytool -genkeypair -v `
        -keystore $KeystorePath `
        -alias $KeyAlias `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000 `
        -storepass $StorePassword `
        -keypass $KeyPassword `
        -dname $Dn
} else {
    Write-Host "Keystore exists: $KeystorePath"
}

Write-Host 'Export upload_certificate.pem'
& $Keytool -exportcert -rfc `
    -alias $KeyAlias `
    -keystore $KeystorePath `
    -storepass $StorePassword `
    -file $PemPath

Write-Host 'PEPK -> pepk_out.zip'
$pepkArgs = @(
    '-jar', $PepkJar,
    "--keystore=$KeystorePath",
    "--alias=$KeyAlias",
    "--output=$PepkOut",
    "--encryptionkey=$RuStoreEncryptionKey",
    '--include-cert',
    "--keystore-pass=$StorePassword",
    "--key-pass=$KeyPassword"
)
& $Java @pepkArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host 'PEPK failed. Check alias, passwords and encryption key.' -ForegroundColor Red
    exit $LASTEXITCODE
}

$keyProps = @"
storePassword=$StorePassword
keyPassword=$KeyPassword
keyAlias=$KeyAlias
storeFile=../familychat-release.keystore
"@
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($KeyPropsPath, $keyProps, $utf8NoBom)
Write-Host "Created $KeyPropsPath"

$saveText = @"
SAVE TO CLOUD (1Password / Drive) - required for future updates!

1) android/familychat-release.keystore - MAIN FILE
2) Passwords below

storePassword / keyPassword: $StorePassword
keyAlias for AAB (upload): $KeyAlias

RuStore console (Signing section) - upload:
- android/signing/pepk_out.zip
- android/signing/upload_certificate.pem

Release build:
  flutter build appbundle --release
"@
Set-Content -Path $SaveCloudPath -Value $saveText -Encoding UTF8
Write-Host 'Done.' -ForegroundColor Green
Write-Host "  $PemPath"
Write-Host "  $PepkOut"
Write-Host "  $KeyPropsPath"
