#!/usr/bin/env bash
# Download TDLib iOS static xcframework (libtdjson.a) for FamilyChat.
# App Store rejects custom dylibs — use static + DynamicLibrary.process() in Dart FFI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ios/tdjson"
URL="https://github.com/up9cloud/ios-libtdjson/releases/download/v1.8.65/libtdjson-static.xcframework.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"
echo "Downloading $URL ..."
curl -L --fail --retry 3 -o "$TMP/tdjson.tar.gz" "$URL"
tar -xzf "$TMP/tdjson.tar.gz" -C "$TMP"

XC="$(find "$TMP" -type d -name 'libtdjson-static.xcframework' | head -n 1)"
if [[ -z "$XC" ]]; then
  echo "libtdjson-static.xcframework not found in archive" >&2
  exit 1
fi

rm -rf "$DEST/libtdjson-static.xcframework"
cp -R "$XC" "$DEST/libtdjson-static.xcframework"
echo "Installed to $DEST/libtdjson-static.xcframework"
echo "Next: cd ios && pod install && cd .."
