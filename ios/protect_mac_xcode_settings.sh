#!/usr/bin/env bash
# Защита локальных настроек Xcode от перезаписи при git pull (запускать один раз на Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(
  ios/Runner.xcodeproj/project.pbxproj
  ios/Runner/Runner.entitlements
  ios/ShareExtension/ShareExtension.entitlements
  ios/Runner/GoogleService-Info.plist
)

for path in "${paths[@]}"; do
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    git update-index --skip-worktree "$path"
    echo "skip-worktree: $path"
  elif [[ -f "$path" ]]; then
    echo "local only (ignored): $path"
  else
    echo "missing: $path"
  fi
done

echo "Done. Git pull больше не перезапишет эти файлы на этом Mac."
