#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TapTap
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/TapTap.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TapTap" "$APP/Contents/MacOS/TapTap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --identifier local.hwz.TapTap "$APP"
printf '已构建：%s\n启动：open "%s"\n' "$APP" "$APP"
