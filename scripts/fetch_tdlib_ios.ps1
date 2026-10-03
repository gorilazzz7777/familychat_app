# Download TDLib iOS static xcframework (libtdjson.a) for FamilyChat.
# App Store rejects custom dylibs — use static + DynamicLibrary.process() in Dart FFI.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root "ios\tdjson"
$url = "https://github.com/up9cloud/ios-libtdjson/releases/download/v1.8.65/libtdjson-static.xcframework.tar.gz"
$tmp = Join-Path $env:TEMP "tdjson_ios_static.tar.gz"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Write-Host "Downloading $url ..."
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
$extract = Join-Path $env:TEMP "tdjson_ios_static_extract"
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
tar -xzf $tmp -C $extract

$xc = Get-ChildItem -Path $extract -Filter "libtdjson-static.xcframework" -Recurse -Directory |
  Select-Object -First 1
if (-not $xc) {
  throw "libtdjson-static.xcframework not found in archive"
}
$targetXc = Join-Path $dest "libtdjson-static.xcframework"
if (Test-Path $targetXc) { Remove-Item $targetXc -Recurse -Force }
Copy-Item -Path $xc.FullName -Destination $targetXc -Recurse -Force

Write-Host "Installed to $targetXc"
Get-ChildItem -Recurse $dest -Filter "libtdjson.a" | ForEach-Object { $_.FullName }
Write-Host "Next (on macOS): cd ios; pod install"
