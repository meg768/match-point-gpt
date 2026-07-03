#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
INSTALL="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT="MatchPointGPT"
APP_NAME="Match Point GPT"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"

if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release
  BINARY="$ROOT/.build/release/$PRODUCT"
else
  swift build
  BINARY="$ROOT/.build/debug/$PRODUCT"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BINARY" "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>se.egelberg.match-point-gpt</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

if [[ "$INSTALL" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" "$HOME/Applications/$APP_NAME.app"
  echo "Installed $HOME/Applications/$APP_NAME.app"
fi

echo "Built $APP_DIR"
