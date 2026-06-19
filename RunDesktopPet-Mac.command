#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build-mac"
MODULE_CACHE="$ROOT/.module-cache"
APP="$BUILD_DIR/DesktopPetMac.app"
BINARY="$APP/Contents/MacOS/DesktopPetMac"
LOG_DIR="$ROOT/logs"
LAUNCH_LOG="$LOG_DIR/desktop-pet-mac-launch.log"

# Secrets are read only from this process environment. The launcher deliberately
# does not source shell profiles or local credential files.
if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  export DEEPSEEK_API_KEY="$ANTHROPIC_AUTH_TOKEN"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE" "$LOG_DIR"
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] launch-script-start"
  echo "root=$ROOT"
} >> "$LAUNCH_LOG"
cp "$ROOT/src-mac/Info.plist" "$APP/Contents/Info.plist"

xcrun swiftc \
  -parse-as-library \
  -suppress-warnings \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/src-mac/DesktopPetMac.swift" \
  -o "$BINARY" 2>> "$LAUNCH_LOG"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] app-start" >> "$LAUNCH_LOG"
"$BINARY" --root "$ROOT" 2>> "$LAUNCH_LOG"
STATUS=$?
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] app-exit status=$STATUS" >> "$LAUNCH_LOG"
exit "$STATUS"
