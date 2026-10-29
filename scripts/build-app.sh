#!/bin/zsh
# Builds Islet.app (release, universal: Apple silicon and Intel, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

# One build per architecture, joined with lipo: SwiftPM's own multi-arch build needs Xcode.
swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0
BIN=.build/arm64-apple-macosx/release/Islet
APP=build/Islet.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BIN" .build/x86_64-apple-macosx/release/Islet -output "$APP/Contents/MacOS/Islet"

# The AirPods Pro 3D model shown when AirPods connect (see HeadphoneArt.swift).
cp -R Resources/AirPodsPro3 "$APP/Contents/Resources/"

# System Now Playing bridge, loaded by /usr/bin/perl at runtime (see NowPlayingHelper.m).
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 -framework Foundation \
    Helpers/NowPlayingHelper.m -o "$APP/Contents/Resources/IsletNowPlaying.dylib"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$BIN" --icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.islet.Islet</string>
    <key>CFBundleName</key><string>Islet</string>
    <key>CFBundleDisplayName</key><string>Islet</string>
    <key>CFBundleExecutable</key><string>Islet</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Islet shows what is playing in Music and Spotify and lets you control it from the notch.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Islet shows when your AirPods and other Bluetooth devices connect, and their battery.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Islet shows your next events and reminds you before they start.</string>
    <key>NSCalendarsUsageDescription</key><string>Islet shows your next events and reminds you before they start.</string>
    <key>NSLocationUsageDescription</key><string>Islet uses your approximate location for the local weather.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Islet uses your approximate location for the local weather.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing. A self-signed certificate was tried to keep permissions across builds:
# macOS accepted it for Calendar but never granted Accessibility or Screen Recording to it,
# even trusted. Ad-hoc gets every permission, at the cost of re-granting them per build.
codesign --force --sign - --identifier app.islet.Islet "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
