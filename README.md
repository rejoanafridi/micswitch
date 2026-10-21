# micswitch

macOS menu bar app that keeps a Bluetooth headset in **A2DP (HD stereo)** while the mic is off, and switches to **HFP** only when the mic is on.

| Icon | Mic | Headset sound |
|---|---|---|
| 🎧 | OFF | A2DP, HD stereo |
| 🎙️ | ON (headset mic) | HFP, call mode |

Toggle with **Control + Option + M** or from the menu bar. Apps (Discord, Meet, Zoom...) must use the **Default** input device; keep the app's own mute off and use the hotkey instead.

## Requirements

- macOS 12+
- A non-Bluetooth input for "mic off". Macs without a built-in mic (e.g. Mac mini) need [BlackHole](https://existential.audio/blackhole/):
  `brew install --cask blackhole-2ch`

## Build

```bash
./build.sh
open MicSwitch.app
```

`./MicSwitch.app/Contents/MacOS/MicSwitch --list` prints the detected devices.
