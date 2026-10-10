#!/bin/bash
# make app: build/LAS Recomp.app - the executable, hactool and the seed generator helper (when built) in
# Contents/MacOS, the Homebrew dylibs it loads (SDL3, FFmpeg and everything non-system they pull in) in
# Contents/Frameworks (load paths rewritten to @rpath), the icon in Contents/Resources, ad-hoc signed.
# No game files, keys or fonts: the app keeps those in ~/Library/Application Support/<bundle id> (runtime/paths.h).
# SEEDGEN=<path>: the generator helper to include (default build/lasrecomp-seedgen, skipped if missing).
set -euo pipefail
cd "$(dirname "$0")/.."
EXE=build/lasrecomp
APP="build/LAS Recomp.app"
BUNDLE_ID=$(sed -n 's/^#define RT_BUNDLE_ID "\(.*\)"/\1/p' runtime/paths.h)
VERSION=$(sed -n 's/^#define LARECOMP_VERSION "\(.*\)"/\1/p' runtime/ui/launcher.mm)
SEEDGEN=${SEEDGEN:-build/lasrecomp-seedgen}
[ -x "$EXE" ] || { echo "no $EXE (make first)"; exit 1; }
[ -x tools/hactool/hactool ] || { echo "no tools/hactool/hactool (make hactool)"; exit 1; }

rm -rf "$APP"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
cp "$EXE" "$C/MacOS/lasrecomp"
cp tools/hactool/hactool "$C/MacOS/hactool"
if [ -e "$SEEDGEN" ]; then cp -R "$SEEDGEN" "$C/MacOS/"; else echo "note: no seed generator helper ($SEEDGEN)"; fi
cp docs/icon/icon.icns "$C/Resources/icon.icns"
cp docs/icon/icon_1024.png "$C/Resources/icon.png"  # (window / Dock icon at run time)

# ---- dylibs: copy every non-system dependency, recursively; point all references at @rpath/<name>
is_system() { case "$1" in /usr/lib/*|/System/*) return 0;; esac; return 1; }
find_dep() {  # dep as referenced by $2 -> a real file
    case "$1" in
    @rpath/*|@loader_path/*)
        local n=${1#*/}
        for d in "$(dirname "$2")" /opt/homebrew/lib; do [ -e "$d/$n" ] && { echo "$d/$n"; return; }; done
        echo "cannot resolve $1 (from $2)" >&2; exit 1;;
    *) echo "$1";;
    esac
}
deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -v "^$(otool -D "$1" | tail -n +2 | head -1)\$" || true; }
origin() { local s; s="$(dirname "$1")/.$(basename "$1").src"; if [ -f "$s" ]; then cat "$s"; else echo "$1"; fi; }
queue="$C/MacOS/lasrecomp"
copied=" "
while [ -n "$queue" ]; do
    f=${queue%%|*}; [ "$queue" = "$f" ] && queue= || queue=${queue#*|}
    for dep in $(deps_of "$f"); do
        is_system "$dep" && continue
        name=$(basename "$dep")
        if [[ "$copied" != *" $name "* ]]; then
            real=$(find_dep "$dep" "$(origin "$f")")
            cp -L "$real" "$C/Frameworks/$name"
            chmod u+w "$C/Frameworks/$name"
            install_name_tool -id "@rpath/$name" "$C/Frameworks/$name" 2>/dev/null
            echo "$real" > "$C/Frameworks/.$name.src"
            copied+="$name "
            queue=${queue:+$queue|}$C/Frameworks/$name
        fi
        [ "$dep" != "@rpath/$name" ] && install_name_tool -change "$dep" "@rpath/$name" "$f" 2>/dev/null
    done
done
rm -f "$C/Frameworks"/.*.src
for r in $(otool -l "$C/MacOS/lasrecomp" | awk '/LC_RPATH/ {getline; getline; print $2}'); do
    install_name_tool -delete_rpath "$r" "$C/MacOS/lasrecomp"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/lasrecomp"
for f in "$C/Frameworks"/*.dylib; do  # (their own Homebrew rpaths, if any: point them at the bundle too)
    for r in $(otool -l "$f" | awk '/LC_RPATH/ {getline; getline; print $2}'); do install_name_tool -delete_rpath "$r" "$f"; done
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
done

# ---- Info.plist: LSMinimumSystemVersion = the newest minimum any shipped binary was built for (Homebrew bottles
# target the macOS they were built on; build SDL3 / FFmpeg with MACOSX_DEPLOYMENT_TARGET for older systems)
MIN=11.0
for f in "$C/MacOS"/* "$C/Frameworks"/*; do
    [ -f "$f" ] || continue
    m=$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/ {b=1} b && /minos/ {print $2; exit}')
    [ -n "$m" ] && [ "$(printf '%s\n%s\n' "$MIN" "$m" | sort -V | tail -1)" = "$m" ] && MIN=$m
done
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>lasrecomp</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>LAS Recomp</string>
    <key>CFBundleDisplayName</key><string>LAS Recomp</string>
    <key>CFBundleIconFile</key><string>icon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>$MIN</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF
printf 'APPL????' > "$C/PkgInfo"

# ---- ad-hoc signature (Apple Silicon refuses to run unsigned code; the rewrites above invalidated the originals)
for f in "$C/Frameworks"/*.dylib "$C/MacOS"/*; do [ -f "$f" ] && codesign -f -s - "$f" 2>/dev/null; done
codesign -f -s - "$APP"
codesign --verify --strict "$APP"
echo "$APP: $(du -sh "$APP" | cut -f1), $(ls "$C/Frameworks" | wc -l | tr -d ' ') dylibs, macOS $MIN+"
