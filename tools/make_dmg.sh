#!/bin/bash
# macOS release disk image: build/dist/LAS Recomp-<version>-macOS.dmg holding "LAS Recomp.app" next to an
# Applications shortcut (drag the app onto it to install - how Mac users expect to install). Run after `make app`.
set -e
cd "$(dirname "$0")/.."
APP="build/LAS Recomp.app"
[ -d "$APP" ] || { echo "no $APP - run make app first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT="build/dist/LAS Recomp-$VERSION-macOS.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/LAS Recomp.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p build/dist
rm -f "$OUT"
hdiutil create -volname "LAS Recomp $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov "$OUT" >/dev/null
echo "$OUT ($(du -h "$OUT" | cut -f1))"
