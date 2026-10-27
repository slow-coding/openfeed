#!/bin/bash
# 编出一份 .app 装到 /Applications。构建缓存放机器缓存目录，工程里不留编译产物。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenFeed"
VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 1.0.0)"
CACHE="$HOME/Library/Caches/openfeed-build/swiftpm"
STAGE="$TMPDIR/openfeed-stage"

swift build -c release --scratch-path "$CACHE" 2>&1 | tail -2
BIN_DIR=$(swift build -c release --scratch-path "$CACHE" --show-bin-path)
BIN="$BIN_DIR/OpenFeed"
[ -x "$BIN" ] || { echo "没找到产物: $BIN"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/$APP_NAME.app/Contents/MacOS" "$STAGE/$APP_NAME.app/Contents/Resources"
cp "$BIN" "$STAGE/$APP_NAME.app/Contents/MacOS/OpenFeed"

if [ ! -f assets/AppIcon.icns ]; then
    swift scripts/make-icon.swift >/dev/null
    iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
fi
cp assets/AppIcon.icns "$STAGE/$APP_NAME.app/Contents/Resources/AppIcon.icns"

cat > "$STAGE/$APP_NAME.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenFeed</string>
    <key>CFBundleDisplayName</key><string>OpenFeed</string>
    <key>CFBundleExecutable</key><string>OpenFeed</string>
    <key>CFBundleIdentifier</key><string>app.openfeed.macos</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$STAGE/$APP_NAME.app" >/dev/null 2>&1

pkill -x OpenFeed 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
ditto "$STAGE/$APP_NAME.app" "/Applications/$APP_NAME.app"
rm -rf "$STAGE"
echo "装好了: /Applications/$APP_NAME.app"
