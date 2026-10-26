#!/bin/zsh
# Builds Islet.app (release, ad-hoc signed) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release/Islet
APP=build/Islet.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Islet"

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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Islet affiche le morceau en cours dans Musique et Spotify et vous laisse le contrôler depuis l’encoche.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Islet affiche la connexion et la batterie de vos AirPods et autres appareils Bluetooth.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Islet affiche vos prochains événements et vous prévient avant qu’ils commencent.</string>
    <key>NSCalendarsUsageDescription</key><string>Islet affiche vos prochains événements et vous prévient avant qu’ils commencent.</string>
    <key>NSLocationUsageDescription</key><string>Islet utilise votre position approximative pour la météo locale.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Islet utilise votre position approximative pour la météo locale.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing. A self-signed certificate was tried to keep permissions across builds:
# macOS accepted it for Calendar but never granted Accessibility or Screen Recording to it,
# even trusted. Ad-hoc gets every permission, at the cost of re-granting them per build.
codesign --force --sign - --identifier app.islet.Islet "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
