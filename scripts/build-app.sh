#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$ROOT/build}"
BUILD="${PORTLIGHT_BUILD_DIR:-$ROOT/.build}"
mkdir -p "$BUILD" "$DESTINATION"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$BUILD/ModuleCache"
OPTIONS=(--package-path "$ROOT" --scratch-path "$BUILD" --cache-path "$BUILD/cache" --config-path "$BUILD/config" --security-path "$BUILD/security" --disable-sandbox --arch arm64 -c release)
swift build "${OPTIONS[@]}"
BIN="$(swift build "${OPTIONS[@]}" --show-bin-path)"
APP="$DESTINATION/Portlight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Portlight" "$APP/Contents/MacOS/Portlight"
# SwiftPM release binaries retain linker debug paths; omit them from public app bundles.
/usr/bin/strip -S "$APP/Contents/MacOS/Portlight"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    swift "$ROOT/scripts/draw-icon.swift" "$BUILD/AppIcon.iconset"
    iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Ready: %s\n' "$APP"
