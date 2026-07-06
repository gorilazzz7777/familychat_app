#!/usr/bin/env bash
# Сборка Flutter Web Family Chat (прод: /familychat/app/).
set -euo pipefail

APP_DIR="${FAMILYCHAT_APP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT_DIR="${FAMILYCHAT_WEB_OUT_DIR:-$APP_DIR/build_web}"

cd "$APP_DIR"

DEFINES_FILE="$(mktemp)"
trap 'rm -f "$DEFINES_FILE"' EXIT
export DEFINES_FILE
export FAMILYCHAT_API_BASE_URL="${FAMILYCHAT_API_BASE_URL:-https://remont-tracker.ru/api/v1/}"
export FAMILYCHAT_WEB_APP_URL="${FAMILYCHAT_WEB_APP_URL:-https://remont-tracker.ru/familychat/app}"
export FAMILYCHAT_INVITE_BASE_URL="${FAMILYCHAT_INVITE_BASE_URL:-https://remont-tracker.ru}"

python3 - <<'PY'
import json
import os

def env(name: str) -> str:
    return os.environ.get(name, "").strip()

defines = {
    "FAMILYCHAT_API_BASE_URL": env("FAMILYCHAT_API_BASE_URL") or "https://remont-tracker.ru/api/v1/",
    "FAMILYCHAT_WEB_APP_URL": env("FAMILYCHAT_WEB_APP_URL") or "https://remont-tracker.ru/familychat/app",
    "FAMILYCHAT_INVITE_BASE_URL": env("FAMILYCHAT_INVITE_BASE_URL") or "https://remont-tracker.ru",
}

with open(os.environ["DEFINES_FILE"], "w", encoding="utf-8") as fh:
    json.dump(defines, fh, ensure_ascii=False)
PY

flutter pub get
flutter build web \
  --release \
  --base-href=/familychat/app/ \
  --no-wasm-dry-run \
  --dart-define-from-file="$DEFINES_FILE"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -a "$APP_DIR/build/web/." "$OUT_DIR/"

echo "Built Family Chat web → $OUT_DIR"
