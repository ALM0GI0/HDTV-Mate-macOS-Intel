#!/bin/bash
# Builds the open-source AC-4 audio decoder (ffmpeg fork) into <dest>/ffmpeg-ac4/ffmpeg.
# Used by HDTV Mate's Settings > "Install AC-4 decoder". Runs on the user's own Mac.
set -euo pipefail
DEST="${1:?usage: install_ac4.sh <destination folder>}"
SRC="$DEST/ffmpeg-ac4-src"
OUT="$DEST/ffmpeg-ac4"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "STEP: Installing Apple's command line tools first. Finish that installer, then click Install again."
    xcode-select --install || true
    exit 1
fi

if [ ! -d "$SRC/.git" ]; then
    echo "STEP: Downloading the AC-4 decoder source…"
    rm -rf "$SRC"
    git clone --depth 1 -b ffmpeg-6.0.1 https://github.com/ferrellsl/ffmpeg-ac4 "$SRC"
fi
cd "$SRC"
chmod +x configure
find . -name '*.sh' -exec chmod +x {} +

echo "STEP: Configuring…"
./configure --cc=clang --disable-everything --disable-doc --disable-network --disable-autodetect \
    --disable-ffprobe --disable-ffplay \
    --enable-decoder=ac4 --enable-demuxer=mov --enable-muxer=nut --enable-muxer=wav \
    --enable-encoder=pcm_s16le --enable-protocol=file --enable-protocol=pipe \
    --enable-filter=aresample --enable-filter=aformat --enable-filter=anull >/dev/null

echo "STEP: Compiling (a few minutes)…"
make -j"$(sysctl -n hw.ncpu)" ffmpeg >/dev/null 2>&1 || make ffmpeg

mkdir -p "$OUT"
cp ffmpeg "$OUT/ffmpeg"
"$OUT/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -q ac4
echo "STEP: Done."
