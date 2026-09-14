# Contributing

Issues and pull requests are welcome.

## Build

Open `Echo.xcodeproj` and build the **Echo** scheme. That also builds `Echo.driver` and embeds it in the app.

Select your development team on the Echo app target.

`coreaudiod` only loads HAL plugins signed with a **Developer ID Application** certificate and the hardened runtime. A Debug run from Xcode embeds the driver but will not load it as an audio device. See the README Export section.

## Pull requests

1. Keep the change focused.
2. Match the existing style.
3. Say what you changed and how you checked it (Xcode build, Simulator mic path, Audio MIDI Setup).
