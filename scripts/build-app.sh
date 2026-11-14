#!/usr/bin/env bash
# Builds TokenBar in release mode on macOS and wraps it into build/TokenBar.app
# (LSUIElement menu bar app, generated icon, ad-hoc code signed).
#
# Usage: scripts/build-app.sh [--install] [version]
#   --install   copy the app to /Applications without asking
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

INSTALL=ask
VERSION="0.3.0"
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=yes ;;
    --no-install) INSTALL=no ;;
    *) VERSION="$arg" ;;
  esac
done

cd "$(dirname "$0")/.."
APP="build/TokenBar.app"

swift build -c release --product TokenBar
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TokenBar" "$APP/Contents/MacOS/TokenBar"

# App icon: drawn at build time (no binary assets in the repository).
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
if swift scripts/make-icon.swift "$ICON_TMP/icon.png"; then
  ICONSET="$ICON_TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Warning: icon generation failed, using the default icon." >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TokenBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
echo "Done: $APP"

if [[ "$INSTALL" == ask && -t 0 ]]; then
  read -r -p "Copy to /Applications? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] && INSTALL=yes
fi
if [[ "$INSTALL" == yes ]]; then
  rm -rf /Applications/TokenBar.app
  cp -R "$APP" /Applications/TokenBar.app
  echo "Installed to /Applications/TokenBar.app"
  echo "Run: open /Applications/TokenBar.app"
else
  echo "Run: open $APP"
fi
