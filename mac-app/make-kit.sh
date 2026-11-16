#!/bin/bash
# Zips everything needed to build HDTV Mate on another Mac (for example an Intel Mac)
# into ~/Desktop/HDTV-Mate-kit.zip. On the other Mac (only Apple's command line tools needed):
#   unzip -oq ~/Desktop/HDTV-Mate-kit.zip -d ~ && bash ~/hdtvmate/mac-app/package.sh
#   (the finished app is in ~/hdtvmate/mac-app/dist)
set -euo pipefail
cd "$(dirname "$0")/../.."
D="hdtvmate"
OUT="$HOME/Desktop/HDTV-Mate-kit.zip"
rm -f "$OUT"
zip -qr "$OUT" \
    $D/driver/src $D/driver/vendor $D/driver/shim $D/driver/tools $D/driver/Makefile.in $D/driver/README.md \
    $D/driver/dvb-usb-it9303-01.fw $( [ -f $D/driver/dvb-usb-hdtvmate.fw ] && echo $D/driver/dvb-usb-hdtvmate.fw ) \
    $D/mac-app/Sources $D/mac-app/Package.swift $D/mac-app/Info.plist $D/mac-app/build.sh $D/mac-app/package.sh \
    $D/mac-app/make-kit.sh $D/mac-app/entitlements.plist $D/mac-app/AppIcon.png \
    -x '*/__pycache__/*' '*.pyc'
echo "Created $OUT ($(du -h "$OUT" | cut -f1))."
echo "On the other Mac:  unzip -oq ~/Desktop/HDTV-Mate-kit.zip -d ~ && bash ~/hdtvmate/mac-app/package.sh"
