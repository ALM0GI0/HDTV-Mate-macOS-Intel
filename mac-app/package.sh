#!/bin/bash
# Builds a self-contained "HDTV Mate.app" in ./dist for the Mac it runs on
# (Apple Silicon or Intel, macOS 13 or newer). Everything is inside the app: the
# hdtvmate driver, tuner firmware, the Python tools plus a private Python, a small
# ffmpeg with the AC-4 decoder, and the mpv player libraries (taken from IINA's
# prebuilt release). Building needs only Apple's command line tools and internet;
# no Homebrew. Nothing needs to be installed on the Mac that runs the app.
#
#   bash package.sh                     personal build: stock firmware + AC-4 decoder built in
#   PUBLIC=1 bash package.sh            shareable build: generic firmware, AC-4 installed from Settings
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=hdtvmate bash package.sh
#   APP_VERSION=0.2 PUBLIC=1 bash package.sh   stamp a version number (the GitHub release workflow does this)
#                                       signed + notarized (opens normally on any Mac)
#
# To get an Intel version, run this script on the Intel Mac (see make-kit.sh).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"
ROOT="$(cd .. && pwd)"
DRIVER="$ROOT/driver"
ARCH="$(uname -m)"                                   # arm64 or x86_64
PYARCH=$([ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64)
BUILD="$HERE/.build/pkg-$ARCH"
OUT="$HERE/dist"
APP="$OUT/HDTV Mate.app"
PUBLIC="${PUBLIC:-0}"
NCPU="$(sysctl -n hw.ncpu)"
mkdir -p "$BUILD"

say() { echo "$*"; }
fail() { echo; echo "ERROR: $*"; exit 1; }

say "1/8 Checking tools ($ARCH, macOS $(sw_vers -productVersion))"
xcode-select -p >/dev/null 2>&1 || { xcode-select --install || true; fail "Install Apple's command line tools (a window just opened), then run this again."; }
[ -f "$DRIVER/dvb-usb-it9303-01.fw" ] || fail "Missing $DRIVER/dvb-usb-it9303-01.fw"
DEPS="$BUILD/deps"
mkdir -p "$DEPS/include/mpv" "$DEPS/lib" "$DEPS/mpvlibs"

say "2/8 Getting libusb and the mpv player libraries (first time only)"
if [ ! -f "$DEPS/lib/libusb-1.0.a" ]; then
    ( cd "$BUILD" && rm -rf libusb-1.0.27 \
      && curl -fsSL https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 | tar -xj \
      && cd libusb-1.0.27 && ./configure --prefix="$DEPS" --disable-shared --enable-static >/dev/null \
      && make -j"$NCPU" >/dev/null 2>&1 && make install >/dev/null ) || fail "libusb build failed"
fi
for h in client.h render.h render_gl.h; do
    [ -f "$DEPS/include/mpv/$h" ] || curl -fsSL "https://raw.githubusercontent.com/mpv-player/mpv/v0.37.0/libmpv/$h" -o "$DEPS/include/mpv/$h" \
        || fail "couldn't download mpv header $h"
done
if ! ls "$DEPS"/mpvlibs/libmpv*.dylib >/dev/null 2>&1; then
    AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")   # CI: avoid the API rate limit
    DMGURL=$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} https://api.github.com/repos/iina/iina/releases/latest | grep -o 'https://[^"]*\.dmg' | head -1 || true)
    [ -n "$DMGURL" ] || fail "couldn't find IINA's download (it provides the mpv player libraries)"
    say "   downloading $(basename "$DMGURL")…"
    curl -fsSL "$DMGURL" -o "$BUILD/iina.dmg"
    MNT="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$BUILD/iina.dmg" >/dev/null
    IINA="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
    cp "$IINA"/Contents/Frameworks/*.dylib "$DEPS/mpvlibs/" 2>/dev/null || true
    hdiutil detach "$MNT" -quiet || true
    rm -f "$BUILD/iina.dmg"
    ls "$DEPS"/mpvlibs/libmpv*.dylib >/dev/null 2>&1 || fail "IINA's download didn't contain libmpv"
fi
LIBMPV="$(ls "$DEPS"/mpvlibs/libmpv*.dylib | head -1)"
lipo -archs "$LIBMPV" | grep -q "$ARCH" || fail "IINA's libmpv has no $ARCH slice ($(lipo -archs "$LIBMPV"))"
mkdir -p "$DEPS/mpvlink"; ln -sf "$LIBMPV" "$DEPS/mpvlink/libmpv.dylib"

say "3/8 Building the hdtvmate driver and the app"
CFL=(-O2 -std=gnu11 -I"$DRIVER/shim" -I"$DRIVER/vendor" -I"$DEPS/include/libusb-1.0"
     -Wno-switch -Wno-incompatible-pointer-types-discards-qualifiers -Wno-unused-value
     -Wno-sometimes-uninitialized -Wno-parentheses -Wno-enum-compare -Wno-unknown-warning-option)
clang "${CFL[@]}" "$DRIVER/src/hdtvmate.c" "$DRIVER/vendor/cxd2878.c" "$DRIVER/vendor/alp_user.c" \
      -o "$BUILD/hdtvmate" "$DEPS/lib/libusb-1.0.a" -lz -lpthread -lobjc \
      -framework IOKit -framework CoreFoundation -framework Security || fail "hdtvmate build failed"
SFLAGS=(-c release --scratch-path "$HERE/.build/swift-$ARCH"
        -Xcc "-I$DEPS/include" -Xcc -DGL_SILENCE_DEPRECATION
        -Xswiftc -Xcc -Xswiftc "-I$DEPS/include"
        -Xlinker "-L$DEPS/mpvlink" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
swift build "${SFLAGS[@]}" 2>&1 | grep -E "error|warning: unable" || true
SWBIN="$(swift build "${SFLAGS[@]}" --show-bin-path)/HDTVMate"
[ -x "$SWBIN" ] || fail "the app didn't build (run: cd $HERE && swift build ${SFLAGS[*]})"

say "4/8 Building a small ffmpeg$([ "$PUBLIC" = 1 ] || echo " with the AC-4 decoder") (first time takes a few minutes)"
FFSRC="$HERE/.build/src/ffmpeg-ac4"
FFB="$BUILD/ffmpeg-min5-$PUBLIC"          # bump when the configure options change
if [ ! -x "$FFB/ffmpeg" ]; then
    if [ ! -d "$FFSRC/.git" ]; then
        rm -rf "$FFSRC"; mkdir -p "$(dirname "$FFSRC")"
        git clone -q --depth 1 -b ffmpeg-6.0.1 https://github.com/ferrellsl/ffmpeg-ac4 "$FFSRC"
    fi
    chmod +x "$FFSRC/configure"; find "$FFSRC" -name '*.sh' -exec chmod +x {} +
    EXTRA=(); [ "$PUBLIC" = 1 ] || EXTRA+=(--enable-decoder=ac4)
    [ "$ARCH" = x86_64 ] && EXTRA+=(--disable-x86asm)
    rm -rf "$FFB"; mkdir -p "$FFB"
    ( cd "$FFB" && "$FFSRC/configure" --cc=clang --disable-everything --disable-doc --disable-network \
        --disable-autodetect --disable-ffprobe --disable-ffplay \
        --enable-demuxer=mpegts,mov,nut --enable-muxer=mpegts,nut,wav,mp4,mov \
        --enable-parser=mpegvideo,ac3,h264,hevc,aac \
        --enable-decoder=mpeg2video,ac3,eac3,h264,hevc,aac,pcm_s16le --enable-encoder=pcm_s16le,aac,h264_videotoolbox --enable-videotoolbox \
        --enable-filter=aresample,aformat,anull,bwdif,yadif,format,scale --enable-protocol=file,pipe,fd \
        --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null \
      && make -j"$NCPU" ffmpeg >/dev/null 2>&1 ) || fail "ffmpeg build failed (see $FFB/ffbuild/config.log)"
fi

say "5/8 Fetching a private Python (first time only)"
PY="$BUILD/python"
if [ ! -x "$PY/bin/python3" ]; then
    PBS=https://github.com/astral-sh/python-build-standalone/releases
    TAG=$(curl -fsSI "$PBS/latest" | awk -F/ 'tolower($0) ~ /^location:/ {print $NF}' | tr -d '\r' || true)
    [ -n "$TAG" ] || fail "Couldn't find the latest standalone Python release"
    NAME=$(curl -fsSL "$PBS/download/$TAG/SHA256SUMS" | awk '{print $2}' \
           | grep -E "^cpython-3\.13\.[0-9]+\+[0-9]+-$PYARCH-apple-darwin-install_only\.tar\.gz$" | head -1 || true)
    [ -n "$NAME" ] || fail "Couldn't find a Python download for $PYARCH in release $TAG"
    URL="$PBS/download/$TAG/$NAME"
    say "   downloading ${NAME}…"
    rm -rf "$PY"; curl -fsSL "$URL" | tar -xz -C "$BUILD"
    rm -rf "$PY"/lib/python3.*/{test,idlelib,tkinter,turtledemo,ensurepip} "$PY"/include "$PY"/share \
           "$PY"/lib/{tcl,tk,itcl,thread}* "$PY"/lib/python3.*/lib-dynload/_tkinter* 2>/dev/null || true
fi

say "6/8 Assembling the bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
R="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"
cp "$SWBIN" "$APP/Contents/MacOS/HDTVMate"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${APP_VERSION:-}" ]; then                    # e.g. APP_VERSION=0.2 (the release workflow sets it from the tag)
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$APP_VERSION}" "$APP/Contents/Info.plist"
fi
if [ -f AppIcon.png ]; then
    ICONSET="$BUILD/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz * 2)) $((sz * 2)) AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$R/AppIcon.icns" || true
fi
mkdir -p "$R/driver/tools" "$R/bin"
cp "$BUILD/hdtvmate" "$R/driver/hdtvmate"
if [ "$PUBLIC" != 1 ] && [ -f "$DRIVER/dvb-usb-hdtvmate.fw" ] && ! cmp -s "$DRIVER/dvb-usb-hdtvmate.fw" "$DRIVER/dvb-usb-it9303-01.fw"; then
    cp "$DRIVER/dvb-usb-hdtvmate.fw" "$R/driver/dvb-usb-hdtvmate.fw"
    touch "$R/driver/firmware-stock"
    FWNOTE="stock HDTV Mate firmware"
else
    cp "$DRIVER/dvb-usb-it9303-01.fw" "$R/driver/dvb-usb-hdtvmate.fw"
    FWNOTE="generic IT9303 firmware"
fi
cp "$DRIVER"/tools/{atsc3play,tvui,psip,guide,extract_fw}.py "$DRIVER/tools/install_ac4.sh" "$R/driver/tools/"
cp "$FFB/ffmpeg" "$R/bin/ffmpeg"
[ "$PUBLIC" = 1 ] || cp "$FFB/ffmpeg" "$R/bin/ffmpeg-ac4"
cp -R "$PY" "$R/python"
# IINA also ships Swift runtime libraries (libswift*.dylib); macOS 13+ has those built in.
for d in "$DEPS"/mpvlibs/*.dylib; do
    case "$(basename "$d")" in libswift*) ;; *) cp "$d" "$FW/" ;; esac
done
# Every library reference must resolve inside the app: rewrite anything absolute to @rpath.
for f in "$FW"/*.dylib "$APP/Contents/MacOS/HDTVMate"; do
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in /usr/lib/*|/System/*|@*) ;; *) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null || true ;; esac
    done
done

# Nothing may still point at Homebrew, or it won't run on a Mac without it.
LEAKS=$(find "$APP" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    { file -b "$f" | grep -q Mach-O && otool -L "$f" | grep -E '/opt/homebrew|/opt/local|/usr/local/' | sed "s|^|$f: |"; } || true
done)
[ -z "$LEAKS" ] || { echo "$LEAKS"; fail "Some files are still linked to Homebrew (listed above)."; }

MISSING=$(for f in "$FW"/*.dylib "$APP/Contents/MacOS/HDTVMate"; do
    otool -L "$f" | tail -n +2 | awk '{print $1}' | { grep '^@rpath/' || true; } | while read -r dep; do
        [[ "${dep#@rpath/}" == libswift* ]] && continue   # provided by macOS (/usr/lib/swift)
        [ -f "$FW/${dep#@rpath/}" ] || echo "$(basename "$f") needs ${dep#@rpath/}"
    done
done | sort -u)
[ -z "$MISSING" ] || { echo "$MISSING"; fail "Some libraries are missing from the app (listed above)."; }

MINOS=$(find "$APP" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    { file -b "$f" | grep -q Mach-O && otool -l "$f" 2>/dev/null | awk '/minos/{print $2}'; } || true
done | sort -V | tail -1)

say "7/8 Quick self-test"
"$R/bin/ffmpeg" -hide_banner -version >/dev/null || fail "bundled ffmpeg doesn't run"
PROTOS="$("$R/bin/ffmpeg" -hide_banner -protocols 2>/dev/null || true)"
grep -qw fd <<<"$PROTOS" || fail "bundled ffmpeg can't read from a pipe (fd protocol missing)"
if [ "$PUBLIC" != 1 ]; then
    DECS="$("$R/bin/ffmpeg-ac4" -hide_banner -decoders 2>/dev/null || true)"
    grep -q ac4 <<<"$DECS" || fail "AC-4 decoder missing from ffmpeg"
fi
"$R/python/bin/python3" -c "import zlib, json, http.server" || fail "bundled Python doesn't run"
for t in atsc3play tvui psip guide; do      # every tool the app runs is present and parses
    "$R/python/bin/python3" -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$R/driver/tools/$t.py" \
        || fail "driver/tools/$t.py missing or broken in the bundle"
done
USAGE="$("$R/driver/hdtvmate" 2>&1 || true)"
grep -q "Usage" <<<"$USAGE" || fail "bundled hdtvmate doesn't run"

say "8/8 Signing"
sign() {
    if [ -n "${SIGN_ID:-}" ]; then
        codesign --force --timestamp --options runtime --entitlements "$HERE/entitlements.plist" -s "$SIGN_ID" "$1"
    else
        codesign --force -s - "$1"
    fi
}
find "$APP/Contents" -type f | while read -r f; do
    if file -b "$f" | grep -q Mach-O; then sign "$f" >/dev/null 2>&1 || echo "   couldn't sign $f"; fi
done
sign "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

KIND=$([ "$ARCH" = arm64 ] && echo "Apple-Silicon" || echo "Intel")
ZIP="$OUT/HDTV-Mate-$KIND.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    say "   notarizing (a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo
echo "Done: $ZIP  ($(du -sh "$APP" | cut -f1) unzipped)"
echo "For $KIND Macs with macOS ${MINOS:-14} or newer. Includes $FWNOTE$([ "$PUBLIC" = 1 ] && echo "." || echo " and the AC-4 decoder.")"
[ -z "${SIGN_ID:-}" ] && echo "Not notarized: on another Mac, right-click the app and choose Open the first time (or allow it in System Settings > Privacy & Security)."
exit 0
