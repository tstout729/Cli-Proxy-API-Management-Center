#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Packaging requires macOS and the Swift 6 toolchain." >&2
  exit 1
fi
cd "$ROOT_DIR"
swift build -c release --product AIUsage
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$ROOT_DIR/dist/AI Usage.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/AIUsage" "$APP_DIR/Contents/MacOS/AIUsage"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.simplyvrm.ai-usage</string>
    <key>CFBundleName</key><string>AI Usage</string>
    <key>CFBundleDisplayName</key><string>AI Usage</string>
    <key>CFBundleExecutable</key><string>AIUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "$APP_DIR"
