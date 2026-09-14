# Echo

[![macOS](https://img.shields.io/badge/macOS-26%2B-black)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Minimal macOS loopback: send a specific app’s audio into the iOS Simulator.

Add one or more apps as sources in the Echo window, press Start, then set the Simulator’s microphone to **Echo**.

<!-- Drop a window capture at docs/screenshot.png to show it here.
![Echo](docs/screenshot.png)
-->

Requires macOS 26+.

## Features

- Tap one or more running apps (Core Audio process taps)
- Mix those sources into a virtual **Echo** device (2-channel, 48 kHz)
- First launch installs the bundled HAL driver (administrator password)
- Source list persists; a source becomes Active again when that app is running

## Install

```bash
brew tap alexiscreuzot/echo https://github.com/alexiscreuzot/echo
brew install --cask echo
```

First launch asks for an administrator password to install the Echo audio device.

## Architecture

- **Echo.driver** — Core Audio HAL plugin. Virtual 2-channel 48 kHz device. Audio written to its output is readable on its input.
- **Echo.app** — Windowed SwiftUI app. Taps the apps you add (process taps), mixes them, and plays the result into Echo.

## Build

Open `Echo.xcodeproj` and build the **Echo** scheme. That also builds `Echo.driver` and copies it into `Echo.app/Contents/PlugIns/`.

Select your development team on the Echo app target.

On first launch, Echo copies the bundled driver to `/Library/Audio/Plug-Ins/HAL/` (administrator password) and restarts `coreaudiod`. Later launches skip that if the installed version is current.

## Export

`coreaudiod` only loads HAL plugins signed with a **Developer ID Application** certificate and the hardened runtime. An Apple Development certificate is not enough — a Debug build from Xcode will embed the driver, but Core Audio will not load it.

1. Product → Archive.
2. Distribute App → **Direct Distribution** (Developer ID) and notarize.
3. The exported `Echo.app` includes `Echo.driver`. First launch on a machine without the driver prompts for an administrator password and installs it.

To install a locally built driver without exporting:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/install-driver.sh /path/to/Echo.driver
```

Or, if the driver is already signed in Xcode:

```bash
./scripts/install-driver.sh /path/to/Echo.driver
```

Confirm **Echo** appears in Audio MIDI Setup.

## Use with the Simulator

1. Open Echo and add the host apps you want to tap.
2. Press Start. macOS may ask for System Audio Recording access once per app.
3. In the iOS Simulator: **I/O → Audio Input → Echo**.
4. Play audio in the source app. The Simulator sees it as microphone input.

Source apps keep playing normally. The list persists across launches; a source becomes Active again when that app is running and registered with Core Audio.

## Uninstall the driver

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Echo.driver
sudo killall coreaudiod
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE)
