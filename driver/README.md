# hdtvmate — native macOS driver for the GTMEDIA / Zenview HDTV Mate

ATSC 1.0 + 3.0 on macOS with no kext and no VM. It talks to the stick over libusb.

| Layer | Source |
|---|---|
| ITE IT930x USB bridge (fw load, GPIO, I2C relay, TS endpoint) | ported from koreapyj/cxd28xx `it930x.c` |
| Sony CXD2878 demod + Ascot3 tuner | `cxd2878.c` from cxd28xx compiled **unmodified** against `shim/kshim.h` |
| ATSC 3.0 ALP-div-TS → ALP → IPv4 | cxd28xx ALP parser (net_device swapped for a callback) |
| LLS / SLT decode, pcap writer | `src/hdtvmate.c` |

License: GPL-2.0-only (derived from cxd28xx).

## Build

```sh
brew install libusb
make
```

## Firmware

The stick boots cold and needs the IT930x bridge firmware each time it's powered up.

```sh
# Best option: extract it from the vendor Android app (pass the APK, or liba3_phy_sony.so from arm64-v8a)
python3 tools/extract_fw.py HDTVMate.apk          # -> dvb-usb-hdtvmate.fw

# Fallback: the generic linux-firmware blob (slightly worse ATSC 3.0 performance)
curl -LO https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/dvb-usb-it9303-01.fw
cp dvb-usb-it9303-01.fw dvb-usb-hdtvmate.fw
```

## Use

```sh
./hdtvmate info                              # firmware + demod chip detect
./hdtvmate scan                              # find ATSC 3.0 / 1.0 stations on RF 2-36
./hdtvmate tune 27 -1                        # ATSC 1.0, RF 27, live RF/SNR/BER
./hdtvmate tune 27 -1 -o - | ffplay -        # watch ATSC 1.0
./hdtvmate tune 30 -o a3.ts -w a3.pcap -t 30 # ATSC 3.0: service list, IP flows, pcap
```

Status flags: S=signal C=carrier V=viterbi Y=sync L=lock.
`-v` dumps the driver's debug output and the full SLT XML.
