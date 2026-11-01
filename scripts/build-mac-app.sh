#!/bin/bash
# Build dist/lidrop.app (ad-hoc signed) and dist/lidrop-mac.zip from mac/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/lidrop.app"
cd "$ROOT/mac"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/lidrop"

mkdir -p "$DIST"
rm -rf "$APP" "$DIST/lidrop-mac.zip" "$DIST/icon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/lidrop"
cp "$ROOT/mac/vendor/dumbpipe" "$APP/Contents/MacOS/dumbpipe"

# icon
swiftc "$ROOT/mac/tools/make_icon.swift" -o "$DIST/make_icon"
"$DIST/make_icon" "$DIST/icon.iconset"
iconutil -c icns "$DIST/icon.iconset" -o "$APP/Contents/Resources/lidrop.icns"
rm -rf "$DIST/icon.iconset" "$DIST/make_icon"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>lidrop</string>
  <key>CFBundleDisplayName</key><string>lidrop</string>
  <key>CFBundleIdentifier</key><string>dev.lidrop.mac</string>
  <key>CFBundleExecutable</key><string>lidrop</string>
  <key>CFBundleIconFile</key><string>lidrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>lidrop receives files from your phone over your local network.</string>
  <key>NSBonjourServices</key><array><string>_lidrop._tcp</string></array>
</dict></plist>
PLIST

codesign --force -s - "$APP/Contents/MacOS/dumbpipe"
# ad-hoc, but identified by bundle id: with the default (a hash of this build) every rebuild would be a new app to
# macOS and lose the folder access the user gave it
codesign --force -s - -r='designated => identifier "dev.lidrop.mac"' "$APP"
codesign --verify --verbose "$APP"
(cd "$DIST" && ditto -c -k --keepParent lidrop.app lidrop-mac.zip)
echo "Built $APP and $DIST/lidrop-mac.zip"
