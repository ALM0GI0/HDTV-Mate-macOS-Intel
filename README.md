# HDTV Mate for macOS

**Watch over-the-air ATSC 1.0 and ATSC 3.0 television on your Mac with the GTMedia HDTV Mate USB tuner.**

HDTV Mate is an independent macOS television application for the GTMedia HDTV Mate. It combines a native SwiftUI interface with a custom USB tuner utility and media-processing tools to scan channels, monitor reception, display program information, and play supported broadcasts.

The project is experimental, especially its ATSC 3.0 playback support. Not every station, service type, audio codec, or broadcast configuration is guaranteed to work.

## Features

### Television
- ATSC 1.0 (8VSB) and experimental ATSC 3.0 reception.
- Automatic channel scanning.
- Channel names, virtual channel numbers, and station information.
- Live television playback.
- Favorite channels and recently selected channel persistence.

### Reception monitoring
- RF signal-strength readings (dBm).
- Signal-to-noise ratio (SNR) readings (dB).
- Tuner status and lock information.
- Live reception statistics.

### Program information
- ATSC 1.0 PSIP channel and program information.
- Electronic program guide data from supported PSIP tables.
- ATSC 3.0 LLS / SLT service discovery.
- Audio-language selection for supported ATSC 3.0 services.

### ATSC 3.0 playback
- Experimental ROUTE/DASH playback.
- LLS and SLT signaling processing.
- SLS and S-TSID processing.
- ROUTE/LCT object reconstruction.
- MPEG-DASH manifest processing.
- Audio and video track handling.
- AC-4 audio decoding when a compatible decoder is installed or bundled.

### Implementation
- Direct USB communication using libusb.
- Custom `hdtvmate` tuner utility.
- GTMedia HDTV Mate firmware handling.
- Bundled Python runtime and supporting scripts in packaged builds.
- FFmpeg-based media processing.
- MPV-based video playback.

## Hardware and system requirements

- GTMedia HDTV Mate USB television tuner.
- Suitable antenna and coax connection for your local broadcasts.
- Mac with a USB port, or a compatible USB adapter/hub.
- macOS 13 Ventura or newer is specified by the app's `Info.plist`.
- An internet connection for the first source build, because the packaging script downloads and builds several dependencies.

The repository is named `HDTV-Mate-macOS-Intel` because the currently distributed build is intended for Intel Macs. The full packaging script selects the architecture of the Mac on which it runs (`x86_64` on Intel, `arm64` on Apple Silicon). The Apple Silicon packaging path is present in the script but should be considered less tested than the Intel build.

## Install a prebuilt release

Check the [GitHub Releases](https://github.com/ALM0GI0/HDTV-Mate-macOS-Intel/releases) page for a packaged download. Each release has `HDTV-Mate-Intel.zip` for Intel Macs and `HDTV-Mate-Apple-Silicon.zip` for M-series Macs.

1. Download the ZIP for your Mac from the release.
2. Double-click the ZIP to extract it.
3. Move `HDTV Mate.app` into your Applications folder.
4. Connect the GTMedia HDTV Mate and an antenna.
5. Open the app and scan for channels.

If no prebuilt ZIP is available, build the app from source using the instructions below.

## Build from source

The recommended way to build the complete application is `mac-app/package.sh`.

This script builds and assembles the tuner utility and Swift application, and bundles the supporting runtime components into `HDTV Mate.app`. It builds libusb, obtains the MPV libraries, builds the configured FFmpeg binary, downloads a private Python runtime, and performs a bundle self-test.

**Homebrew is not required for this full packaging workflow.**

### 1. Install Apple's command-line developer tools

Open Terminal and run:

```bash
xcode-select --install
```

If the Command Line Tools are already installed, macOS will tell you. When installation is complete, verify the tools:

```bash
xcode-select -p
swift --version
clang --version
git --version
```

The Swift package manifest uses Swift tools version 5.9.

### 2. Clone the repository

```bash
git clone https://github.com/ALM0GI0/HDTV-Mate-macOS-Intel.git
cd HDTV-Mate-macOS-Intel
```

### 3. Build the complete application

Change into the app directory:

```bash
cd mac-app
```

For a personal build, run:

```bash
bash package.sh
```

The script automatically detects the current Mac's CPU architecture and builds for that architecture.

For an Intel Mac, `uname -m` should report `x86_64`; the output archive will be:

```text
dist/HDTV-Mate-Intel.zip
```

The completed application will be:

```text
dist/HDTV Mate.app
```

The first build downloads source code and binary dependencies from their upstream projects and compiles several components. Keep an internet connection available until the script finishes.

### 4. Build a shareable package

For a package intended to be shared with other people, use:

```bash
PUBLIC=1 bash package.sh
```

`PUBLIC=1` tells the packaging script to use the generic IT9303 firmware rather than the stock HDTV Mate firmware, and not to bundle the AC-4-enabled FFmpeg binary. The app can offer the AC-4 setup separately.

The default personal build may bundle `driver/dvb-usb-hdtvmate.fw` when that file is present, as well as an AC-4-enabled FFmpeg binary. Check that you have the right to redistribute any vendor firmware or other third-party materials before sharing a package built without `PUBLIC=1`.

### Automatic release builds (GitHub Actions)

`.github/workflows/release.yml` runs the shareable build (`PUBLIC=1`) on GitHub's Intel and Apple Silicon Mac runners. To publish a release, push a version tag:

```bash
git tag v0.2
git push origin v0.2
```

Both builds run (about 15 minutes the first time, less once their dependencies are cached), and a release named after the tag appears on the Releases page with both ZIPs attached. To build without releasing, open the **Actions** tab, choose **Build and release**, and click **Run workflow**; the ZIPs are attached to that run.

### 5. Install the built app

After the build succeeds, install the app in your personal Applications folder:

```bash
mkdir -p "$HOME/Applications"
ditto "dist/HDTV Mate.app" "$HOME/Applications/HDTV Mate.app"
```

You can also drag `dist/HDTV Mate.app` into `/Applications` in Finder.

Connect the GTMedia HDTV Mate and antenna, then open **HDTV Mate**. Use the app's channel-scan control to search for available broadcasts.

### 6. First launch and macOS security

The packaging script applies an ad-hoc code signature. It does not Developer ID sign or notarize the application by default. On another Mac, Gatekeeper may therefore require a manual first launch:

1. In Finder, Control-click (or right-click) **HDTV Mate.app**.
2. Choose **Open**.
3. Confirm **Open** when macOS asks.

If macOS still blocks the app, check **System Settings → Privacy & Security** for the option to allow it.

Only bypass Gatekeeper for a build you trust and have obtained from a trusted source.

## Build only the USB driver

The `driver/` directory also contains a separate command-line tuner utility. This is useful for testing the hardware without launching the GUI.

On macOS, install libusb with Homebrew:

```bash
brew install libusb
```

Then build the driver:

```bash
cd driver
make -f Makefile.in
```

The build produces:

```text
driver/hdtvmate
```

Run the utility from the `driver/` directory:

```bash
./hdtvmate info
./hdtvmate scan
```

Example tuning commands are documented in [`driver/README.md`](driver/README.md).

**Note:** The makefile in this repository is named `Makefile.in`, not `Makefile`, so use `make -f Makefile.in` as shown above.

## Build-script notes

There are two app build scripts in `mac-app/`:

- `package.sh` is the recommended full packaging workflow. It produces the self-contained app bundle used for normal installation and sharing.
- `build.sh` is a smaller Swift app build that expects Homebrew and MPV development files on the build Mac. It does not assemble the full bundled tuner/runtime package. Use it for app-side development rather than creating the complete distributable app.

## Troubleshooting

### `xcode-select` or Swift tools are missing

Install Apple's Command Line Tools:

```bash
xcode-select --install
```

Complete the installation, then run the build again.

### The tuner is not detected

- Confirm the USB tuner is connected securely.
- Try another USB port or a powered USB hub.
- Check that the device is visible to macOS.
- Disconnect and reconnect the tuner, then relaunch the app.

The app monitors the HDTV Mate USB identifier `23e2:2b02`.

### The build fails while downloading dependencies

The packaging script retrieves dependencies from upstream project releases and source repositories. Check the network connection and rerun:

```bash
cd mac-app
bash package.sh
```

The script caches several downloads and intermediate build products under `mac-app/.build/`, so a rerun may reuse work already completed.

### ATSC 3.0 channels are found but do not play

ATSC 3.0 playback is experimental and currently focuses on ROUTE/DASH services. MMTP-based playback is not implemented. DRM-protected services cannot be played. Audio and video support also depends on the codecs and broadcast configuration used by the station.

## ATSC 3.0 compatibility limitations

Current known limitations include:

- Playback focuses on ROUTE/DASH services; MMTP-based playback is not implemented.
- DRM-protected services cannot be played.
- AC-4 audio requires a compatible decoder.
- ATSC 3.0 caption support is not currently implemented in the playback pipeline.
- Not every ATSC 3.0 service or broadcast configuration is guaranteed to work.

## Project goals

Potential future work includes improved ATSC 3.0 compatibility, expanded physical-layer diagnostics, more detailed PLP and signaling inspection, broader audio support, native Apple Silicon validation, and exploration of iPadOS compatibility.

## Contributing and bug reports

Testing, bug reports, and contributions are welcome.

When reporting an issue, include:

- macOS version.
- Mac architecture (`x86_64` or `arm64`).
- Whether the app was built with `package.sh` or `PUBLIC=1 bash package.sh`.
- GTMedia HDTV Mate hardware details.
- Whether the issue concerns ATSC 1.0 or ATSC 3.0.
- Relevant application logs and the affected broadcast channel.

## Disclaimer

HDTV Mate is an independent, experimental project. It is not affiliated with, endorsed by, or officially supported by GTMedia.

Reception and playback depend on the tuner, firmware, antenna, local broadcast conditions, service configuration, and available decoders.

## Licensing

There is currently no top-level `LICENSE` file in this repository. Do not assume that the absence of a license grants permission to reuse, modify, or redistribute the project. The driver documentation identifies its derived driver code as GPL-2.0-only, and bundled firmware and third-party components may have separate terms. Review and document the applicable licenses before redistributing source or application bundles.
