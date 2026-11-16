# HDTV Mate for macOS

**Watch over-the-air television on your Mac using the GTMedia HDTV Mate USB tuner.**

HDTV Mate is an independent macOS television application designed to bring ATSC 1.0 and ATSC 3.0 broadcast reception to macOS using the affordable GTMedia HDTV Mate USB tuner.

The project combines native macOS functionality with custom hardware communication and media-processing tools to scan for broadcast channels, monitor reception quality, and watch live over-the-air television.

The goal is to make ATSC television reception more accessible on macOS without requiring expensive dedicated television receivers.

## Features

### 📺 ATSC Television Reception
- ATSC 1.0 (8VSB) support.
- ATSC 3.0 support.
- Automatic channel scanning.
- Channel identification and organization.
- Live television playback.

### 📡 Signal Monitoring
- RF signal strength measurements (dBm).
- Signal-to-noise ratio (SNR) measurements (dB).
- Live tuner status monitoring.
- Reception and tuning information.

### 📋 Channel Information
- ATSC 1.0 PSIP channel information.
- Virtual channel numbers and station names.
- Program guide information from supported PSIP tables.
- ATSC 3.0 LLS / SLT service discovery.
- Audio language selection for supported ATSC 3.0 services.

### 🎬 ATSC 3.0 Playback
- Experimental ROUTE/DASH service playback.
- LLS and SLT service discovery.
- SLS signaling processing.
- ROUTE/LCT object reconstruction.
- MPEG-DASH manifest processing.
- Video and audio track handling.
- Optional AC-4 audio decoding through a compatible FFmpeg build.

### 🔧 Hardware and Software
- Direct USB communication through libusb.
- GTMedia HDTV Mate firmware handling.
- Custom tuner control utility.
- Bundled Python runtime and supporting scripts.
- FFmpeg-based media processing.
- MPV-based playback integration.

## Hardware Requirements

- GTMedia HDTV Mate USB television tuner.
- Compatible television antenna.
- Mac with an Intel processor for the currently provided release.
- macOS 13 Ventura or newer.
- USB connection or compatible USB adapter.

**Note:** The currently packaged application is an Intel x86_64 build. Apple Silicon support is not included in this release.

## Installation

1. Download the latest available macOS release.
2. Extract the downloaded archive.
3. Move `HDTV Mate.app` into your Applications folder.
4. Connect your GTMedia HDTV Mate USB tuner.
5. Connect an appropriate television antenna.
6. Launch HDTV Mate.
7. Scan for available television channels.

Channel reception depends on your antenna, location, broadcast availability, and signal conditions.

## ATSC 3.0 Compatibility Notes

ATSC 3.0 support is experimental and has some limitations.

The current playback implementation focuses on ROUTE/DASH services.

Current limitations include:

- MMTP-based service playback is not yet supported.
- DRM-protected services cannot be played.
- AC-4 audio requires a compatible decoder.
- ATSC 3.0 caption support is not currently implemented in the playback pipeline.

Not every ATSC 3.0 broadcast configuration or service is guaranteed to work.

## Project Goals

This project is an ongoing effort to make affordable USB television hardware more useful on macOS.

Future development may include:

- Improved ATSC 3.0 compatibility.
- Expanded signal diagnostics.
- Additional physical-layer information.
- More detailed PLP and broadcast signaling inspection.
- Improved playback and audio support.
- Native Apple Silicon support.
- Potential iPadOS compatibility.

## Disclaimer

HDTV Mate is an independent, experimental software project.

It is not affiliated with, endorsed by, or officially supported by GTMedia.

ATSC 3.0 reception and playback capabilities depend on the hardware, firmware, broadcast configuration, and available software decoders.

## Contributing

Contributions, testing, bug reports, and suggestions are welcome!

If you encounter an issue, please include:

- macOS version.
- Mac processor architecture.
- GTMedia HDTV Mate hardware information.
- ATSC standard being received.
- Relevant application logs.
- Details about the broadcast channel being tested.

## License

License information will be provided with the source-code distribution.

Third-party components, firmware, and bundled software remain subject to their respective licenses and redistribution requirements.
