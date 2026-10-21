<p align="center">
  <img src="icon/icon.png" width="160" alt="MicSwitch icon">
</p>

<h1 align="center">MicSwitch</h1>

<p align="center">
  Keep your Bluetooth headset in <b>HD stereo</b> on macOS, and drop to call mode only while your mic is on.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-12%2B-black?logo=apple" alt="macOS 12+">
  <img src="https://img.shields.io/badge/Swift-native-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## The problem

Bluetooth headsets (neckbands, earbuds, AirPods...) have two modes:

| Mode | When | Sound |
|---|---|---|
| **A2DP** | Listening only | HD stereo |
| **HFP** | Any app opens the headset mic | Low-quality mono |

Join a voice channel in Discord, Meet or Zoom and macOS opens the headset mic, so music and voices turn into muffled phone-call audio. That stays true even while you are muted in the app.

## The fix

MicSwitch sits in the menu bar and decides **which microphone the system uses**:

| Icon | Mic | Headset |
|---|---|---|
| 🎧 | **OFF**: input is a silent non-Bluetooth device | A2DP, HD stereo |
| 🎙️ | **ON**: input is the headset mic | HFP, call mode |

Press **Control + Option + M** (or use the menu) to toggle.

## Features

- Global hotkey **⌃⌥M** with a sound cue on every switch
- Works with any app that uses the system default input (Discord, Meet, Zoom, Teams, Slack...)
- If macOS grabs the headset mic on its own (for example when it reconnects), MicSwitch moves it back while the mic is off
- Prefers the OnePlus Bullets Z3 headset and falls back to any Bluetooth headset
- Native Swift, no dependencies, about 250 lines, no microphone access needed

## Requirements

- macOS 12 or later
- A non-Bluetooth input for "mic off". MacBooks use the built-in mic (muted). **Macs without a mic (Mac mini, Mac Studio, Mac Pro)** need the free [BlackHole](https://existential.audio/blackhole/) driver:

```bash
brew install --cask blackhole-2ch
```

## Install

```bash
git clone https://github.com/rejoanafridi/micswitch.git
cd micswitch
./build.sh
cp -R MicSwitch.app ~/Applications/
open ~/Applications/MicSwitch.app
```

**Start at login:** System Settings → General → Login Items → **+** → `MicSwitch.app`.

## Usage

1. In your call app (Discord: **Settings → Voice & Video**), set
   - **Input Device:** `Default`
   - **Output Device:** your headset
2. Keep the call app itself **unmuted**, and mute/unmute with **⌃⌥M** instead.
3. 🎧 = you hear HD audio and nobody hears you. 🎙️ = you can talk.

Switching takes 1–2 seconds and you may hear a short glitch. That is the headset changing Bluetooth profiles.

## Troubleshooting

```bash
~/Applications/MicSwitch.app/Contents/MacOS/MicSwitch --list
```

This prints every audio device and what MicSwitch picked for the headset and for the "mic off" input.

| Message | Fix |
|---|---|
| `Mic-OFF input: none` | Install BlackHole (see Requirements), then restart audio with `sudo killall coreaudiod` |
| "Bluetooth headset mic not found" | Connect the headset first |
| Still sounds bad with 🎧 | Check that the call app's input is **Default** and not the headset |

## Project layout

```
main.swift            the app
build.sh              builds MicSwitch.app
icon/make_icon.swift  draws the app icon
icon/AppIcon.icns     generated icon
```

## Author

**rejoanafridi** · [rejoanafridi93@gmail.com](mailto:rejoanafridi93@gmail.com) · [GitHub](https://github.com/rejoanafridi)

## License

[MIT](LICENSE) © 2026 rejoanafridi
