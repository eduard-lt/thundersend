#!/bin/sh
# Builds build/ThunderSend.dmg, a drag-to-Applications installer.
set -e
cd "$(dirname "$0")"

./build.sh

VOL=ThunderSend
DMG=build/ThunderSend.dmg
RW=build/ThunderSend-rw.dmg
STAGE=build/dmg
MOUNT="/Volumes/$VOL"

# Finder addresses the disk by name, so an already mounted copy would get in the way.
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet
rm -rf "$STAGE" "$RW" "$DMG"

mkdir -p "$STAGE/.background"
cp -R build/ThunderSend.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

swift Resources/dmg-background.swift build/bg.png 1
swift Resources/dmg-background.swift build/bg@2x.png 2
tiffutil -cathidpicheck build/bg.png build/bg@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null

hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 60m "$RW"
hdiutil attach -quiet -noverify -noautoopen "$RW"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

# Finder saves this layout into the volume. The first run asks to let Terminal control Finder.
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 590}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "ThunderSend.app" of container window to {170, 140}
        set position of item "Applications" of container window to {490, 140}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Added last because the volume icon did not survive the Finder step above.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

sync
hdiutil detach "$MOUNT" -quiet
trap - EXIT
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW" build/bg.png build/bg@2x.png
rm -rf "$STAGE"
echo "Built $DMG"
