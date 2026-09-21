# Contributing

Issues and pull requests are welcome.

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

## Architecture

- **Echo.driver** — Core Audio HAL plugin. Virtual 2-channel 48 kHz device. Audio written to its output is readable on its input.
- **Echo.app** — Menu bar SwiftUI app. Taps the apps you add (process taps), mixes them, and plays the result into Echo.

## Screenshots

With Echo built, generate the README image from mock sources:

```bash
./scripts/screenshot.sh
```

## Pull requests

1. Keep the change focused.
2. Match the existing style.
3. Say what you changed and how you checked it (Xcode build, Simulator mic path, Audio MIDI Setup).
