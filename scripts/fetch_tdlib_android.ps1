# Download TDLib Android jniLibs (libtdjson.so) for FamilyChat.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root "android\app\src\main\jniLibs"
$url = "https://github.com/up9cloud/android-libtdjson/releases/download/v1.8.65/jniLibs.tar.gz"
$tmp = Join-Path $env:TEMP "tdjson_jniLibs.tar.gz"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Write-Host "Downloading $url ..."
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
$extract = Join-Path $env:TEMP "tdjson_jniLibs_extract"
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
tar -xzf $tmp -C $extract
$inner = Join-Path $extract "jniLibs"
if (Test-Path $inner) {
  Copy-Item -Path (Join-Path $inner "*") -Destination $dest -Recurse -Force
} else {
  Copy-Item -Path (Join-Path $extract "*") -Destination $dest -Recurse -Force
}
Write-Host "Installed to $dest"
Get-ChildItem -Recurse $dest -Filter "*.so" | ForEach-Object { $_.FullName }
