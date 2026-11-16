#!/bin/bash
# Builds "HDTV Mate.app" next to this script. Needs Xcode command line tools + Homebrew.
set -euo pipefail
cd "$(dirname "$0")"
BREW="$(brew --prefix)"
if [ ! -f "$BREW/include/mpv/client.h" ]; then
    echo "Installing mpv (provides libmpv, the embedded player)..."
    brew install mpv
fi
FLAGS=(-c release
       -Xcc "-I$BREW/include" -Xcc -DGL_SILENCE_DEPRECATION
       -Xswiftc -Xcc -Xswiftc "-I$BREW/include"
       -Xlinker "-L$BREW/lib")
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"
APP="HDTV Mate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HDTVMate" "$APP/Contents/MacOS/HDTVMate"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz * 2)) $((sz * 2)) AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "icon skipped"
fi
codesign --force -s - "$APP" >/dev/null
echo "Built: $PWD/$APP"
echo "Run:   open \"$PWD/$APP\""
