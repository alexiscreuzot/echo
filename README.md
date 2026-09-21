# Echo

<p align="center">
  <img src="docs/screenshot.png" alt="Echo in the menu bar, mixing Safari and Music into the Echo microphone" width="380">
</p>

<p align="center">
  Send sound from apps on your Mac into the iOS Simulator — as if it were the microphone.
</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

Safari, Music, a call, a video — pick what to share, press play, and the Simulator hears it. Those apps keep playing on your Mac as usual.

## Install

macOS 26 or later.

```bash
brew tap alexiscreuzot/echo https://github.com/alexiscreuzot/echo
brew trust alexiscreuzot/echo
brew install --cask echo
```

The first time you open Echo, macOS asks for an administrator password so it can add the Echo microphone.

<details>
<summary>Already using Echo from an older tap?</summary>

```bash
brew tap --custom-remote alexiscreuzot/echo https://github.com/alexiscreuzot/echo
brew update
brew upgrade --cask echo
```

</details>

## Use it

1. Click the waveform icon in the menu bar.
2. Add an app, or an audio file.
3. Press play. macOS may ask once per app for permission to capture its sound.
4. In the Simulator, choose **I/O → Audio Input → Echo**.
5. Play something in the source app. The Simulator hears it as the microphone.

Echo remembers your sources. When that app is open again, it shows as active.

## Remove it

```bash
brew uninstall --cask echo
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Echo.driver
sudo killall coreaudiod
```

The last two lines remove the Echo microphone. After that, it no longer appears in the Simulator or Audio MIDI Setup.

## Developers

Build the **Echo** scheme in `Echo.xcodeproj`. First launch installs the bundled audio driver.

A Debug build from Xcode will not show up as a microphone — Core Audio only loads a driver signed with a Developer ID certificate. Archive, then **Direct Distribution**, and notarize. Details are in [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
./scripts/install-driver.sh /path/to/Echo.driver
```

## License

[MIT](LICENSE). By contributing you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
