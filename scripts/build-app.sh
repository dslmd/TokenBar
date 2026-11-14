#!/usr/bin/env bash
# Builds TokenBar in release mode on macOS and wraps it into build/TokenBar.app
# (LSUIElement menu bar app, ad-hoc code signed). Usage: scripts/build-app.sh [version]
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "此脚本只能在 macOS 上运行。" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
APP="build/TokenBar.app"

swift build -c release --product TokenBar
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TokenBar" "$APP/Contents/MacOS/TokenBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>TokenBar</string>
  <key>CFBundleIdentifier</key><string>com.tokenbar.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>TokenBar</string>
  <key>CFBundleDisplayName</key><string>TokenBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no developer account needed). Gatekeeper may still ask on first launch.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "完成：$APP"
echo "运行：open $APP"
