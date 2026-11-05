#!/bin/bash
# Build "OHW Studio.app" (release, ad-hoc signed) into app/build/.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export SDKROOT="${SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/OHWStudio"

APP="$ROOT/build/OHW Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OHWStudio"

ICONWORK="$ROOT/build/icon"
if [ ! -f "$ICONWORK/AppIcon.icns" ]; then
  "$ROOT/../.venv/bin/python" "$ROOT/scripts/make_icon.py" "$ICONWORK"
  iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$ICONWORK/AppIcon.icns"
fi
cp "$ICONWORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OHW Studio</string>
  <key>CFBundleDisplayName</key><string>OHW Studio</string>
  <key>CFBundleIdentifier</key><string>dev.emejulu.ohwstudio</string>
  <key>CFBundleExecutable</key><string>OHWStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>OHW Studio connects to your OHW-11 watch over Bluetooth.</string>
  <key>NSMicrophoneUsageDescription</key><string>OHW Studio listens through your watch's microphone when you talk to the assistant.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>OHW Studio turns what you say to your watch into text so the assistant can answer.</string>
  <key>NSContactsUsageDescription</key><string>OHW Studio puts the people you choose on your watch and keeps them up to date.</string>
  <key>NSAppleEventsUsageDescription</key><string>OHW Studio controls Spotify and Music from your watch and shows the current track on it.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built: $APP"
