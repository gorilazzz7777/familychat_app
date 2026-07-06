#!/usr/bin/env bash
# Сборка Flutter Web Family Chat (прод: /familychat/app/).
set -euo pipefail

_trim_secret() {
  local s
  s="$(printf '%s' "${1:-}" | tr -d '\r\n')"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

for _var in \
  FIREBASE_WEB_API_KEY \
  FIREBASE_WEB_APP_ID \
  FIREBASE_MESSAGING_SENDER_ID \
  FIREBASE_PROJECT_ID \
  FIREBASE_AUTH_DOMAIN \
  FIREBASE_STORAGE_BUCKET \
  FIREBASE_VAPID_KEY; do
  if [[ -n "${!_var:-}" ]]; then
    printf -v "$_var" '%s' "$(_trim_secret "${!_var}")"
  fi
done
unset _var

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
import sys

def env(name: str) -> str:
    return os.environ.get(name, "").strip()

defines = {
    "FAMILYCHAT_API_BASE_URL": env("FAMILYCHAT_API_BASE_URL") or "https://remont-tracker.ru/api/v1/",
    "FAMILYCHAT_WEB_APP_URL": env("FAMILYCHAT_WEB_APP_URL") or "https://remont-tracker.ru/familychat/app",
    "FAMILYCHAT_INVITE_BASE_URL": env("FAMILYCHAT_INVITE_BASE_URL") or "https://remont-tracker.ru",
}

api_key = env("FIREBASE_WEB_API_KEY")
if api_key:
    for key in (
        "FIREBASE_WEB_API_KEY",
        "FIREBASE_WEB_APP_ID",
        "FIREBASE_MESSAGING_SENDER_ID",
        "FIREBASE_PROJECT_ID",
        "FIREBASE_AUTH_DOMAIN",
        "FIREBASE_STORAGE_BUCKET",
    ):
        value = env(key)
        if value:
            defines[key] = value

vapid = env("FIREBASE_VAPID_KEY")
if vapid:
    defines["FIREBASE_VAPID_KEY"] = vapid

for key, value in defines.items():
    if "\n" in value or "\r" in value:
        print(f"ERROR: {key} contains a newline — re-save the GitHub secret as a single line", file=sys.stderr)
        sys.exit(1)

path = os.environ["DEFINES_FILE"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(defines, fh, ensure_ascii=False)
PY

flutter pub get
flutter build web \
  --release \
  --base-href=/familychat/app/ \
  --no-wasm-dry-run \
  --dart-define-from-file="$DEFINES_FILE"

SW_OUT="$APP_DIR/build/web/firebase-messaging-sw.js"
FCM_JS="$APP_DIR/build/web/familychat-fcm.js"
if [[ -n "${FIREBASE_WEB_API_KEY:-}" ]]; then
  for _file in "$SW_OUT" "$FCM_JS"; do
    if [[ -f "$_file" ]]; then
      sed -i "s|REPLACE_FIREBASE_WEB_API_KEY|${FIREBASE_WEB_API_KEY}|g" "$_file"
      sed -i "s|REPLACE_FIREBASE_WEB_APP_ID|${FIREBASE_WEB_APP_ID}|g" "$_file"
      sed -i "s|REPLACE_FIREBASE_MESSAGING_SENDER_ID|${FIREBASE_MESSAGING_SENDER_ID}|g" "$_file"
      sed -i "s|REPLACE_FIREBASE_PROJECT_ID|${FIREBASE_PROJECT_ID}|g" "$_file"
    fi
  done
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -a "$APP_DIR/build/web/." "$OUT_DIR/"

echo "Built Family Chat web → $OUT_DIR"
