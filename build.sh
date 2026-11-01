#!/bin/sh
# Builds ThunderSend.app (Apple Silicon and Intel) into the build folder.
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"

swift build -c release --arch arm64 --arch x86_64

APP=build/ThunderSend.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ThunderSend" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ThunderSend</string>
    <key>CFBundleExecutable</key><string>ThunderSend</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>app.thundersend</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>ThunderSend finds the other Mac over the Thunderbolt cable.</string>
    <key>NSBonjourServices</key><array><string>_thundersend._tcp</string></array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
