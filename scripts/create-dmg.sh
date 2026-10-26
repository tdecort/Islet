#!/bin/zsh
# Packs build/Islet.app into build/Islet.dmg: the app, a link to Applications, and a
# short first-launch guide. Run ./scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Islet.app
STAGE=build/dmg
DMG=build/Islet.dmg

if [[ ! -d "$APP" ]]; then
    echo "$APP not found. Run ./scripts/build-app.sh first." >&2
    exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me First.txt" <<'TXT'
Installing Islet

1. Drag Islet onto the Applications folder in this window.
2. Eject this disk, then open Islet from Applications (never from here:
   macOS treats apps run from a disk image as new every time).

The first time only, macOS says it cannot check Islet for malicious software.
Islet is free and open source but not notarized by Apple, so this is expected:

   - Click Done (not Move to Trash).
   - Open System Settings > Privacy & Security, scroll down, and click
     "Open Anyway" next to Islet. Confirm with your password or Touch ID.

macOS remembers this choice. If it ever asks again, run this once in Terminal:

   xattr -dr com.apple.quarantine /Applications/Islet.app

Then open Islet, go to Settings > Permissions and allow each item once.
They stay granted until you install a newer version of Islet.

Source and help: https://github.com/tdecort/Islet
TXT

hdiutil create -volname Islet -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -sh "$DMG" | cut -f1))"
