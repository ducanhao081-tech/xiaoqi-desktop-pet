#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build-mac"
MODULE_CACHE="$ROOT/.module-cache"
APP="$BUILD_DIR/DesktopPetMac.app"
BINARY="$APP/Contents/MacOS/DesktopPetMac"
LOG_DIR="$ROOT/logs"
LAUNCH_LOG="$LOG_DIR/desktop-pet-mac-launch.log"

# Secrets are read only from this process environment. The self-test never
# sources shell profiles or local credential files.

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE" "$LOG_DIR"
cp "$ROOT/src-mac/Info.plist" "$APP/Contents/Info.plist"

xcrun swiftc \
  -parse-as-library \
  -suppress-warnings \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/src-mac/DesktopPetMac.swift" \
  -o "$BINARY" 2>> "$LAUNCH_LOG"

"$BINARY" --root "$ROOT" --self-test
