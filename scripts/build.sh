#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
bundle="$PWD/dist/MenuGauge.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/StatusRing "$bundle/Contents/MacOS/StatusRing"
cp Assets/StatusRing.icns THIRD_PARTY_NOTICES.txt "$bundle/Contents/Resources/"
cp -R .build/release/StatusRing_StatusRing.bundle "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dya.StatusRing</string>
<key>CFBundleName</key><string>MenuGauge</string>
<key>CFBundleDisplayName</key><string>MenuGauge</string>
<key>CFBundleExecutable</key><string>StatusRing</string>
<key>CFBundleIconFile</key><string>StatusRing.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>MenuGauge 读取 Mac 日历，以便在菜单栏显示本周和当天的日程。</string>
<key>NSCalendarsUsageDescription</key><string>MenuGauge 读取 Mac 日历，以便在菜单栏显示本周和当天的日程。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
