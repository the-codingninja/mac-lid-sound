# mac-door-hinge-sound

Your MacBook lid sounds like an old wooden door.

A lightweight daemon reads the MacBook's built-in **Lid Angle Sensor** at 30 Hz and plays a creak sound in real-time as you open or close the lid. Faster movement = faster creak. Every creak is slightly randomized in pitch so it never sounds repetitive.

https://github.com/user-attachments/assets/placeholder-demo.mp4

## How it works

MacBooks (M4 and 2019 16") have a Hall-effect magnetic angle sensor near the hinge. The daemon reads it through IOKit HID and maps lid movement to audio playback via AVAudioEngine:

```
Lid moves → sensor reports angle → daemon detects velocity/direction
  → picks random creak sound → adjusts rate + pitch → plays through speakers
  → fades out when lid stops moving
```

## Compatibility

| Model | Works |
|-------|-------|
| M4 MacBooks (all) | Yes |
| MacBook Pro 16" 2019 (Intel) | Yes |
| M1 / M2 / M3 MacBooks | No — sensor exists but Apple doesn't expose it |

## Install

### App (recommended)

1. Download **`Door-Hinge.dmg`** from [Releases](https://github.com/the-codingninja/mac-lid-sound/releases)
2. Open the DMG and either:
   - **Double-click "Install Door Hinge"** — installs to /Applications and launches automatically
   - Or drag **Door Hinge** to the **Applications** folder manually

> **Gatekeeper warning:** Since the app isn't notarized with Apple, macOS may block it on first launch. Fix with one of:
> - **Right-click** the app > **Open** > click **Open** in the dialog
> - Or run in Terminal: `xattr -cr /Applications/Door\ Hinge.app`

The app lives in your **menu bar** — no dock icon. From the menu you can:
- See the live lid angle
- Switch between **Door Hinge** and **Garage Door** sounds
- Mute/unmute
- Enable Launch at Login

### From source

```bash
git clone https://github.com/the-codingninja/mac-lid-sound.git
cd mac-lid-sound
./build.sh
open "build/Door Hinge.app"
```

### CLI daemon (alternative)

```bash
./install.sh
```

This compiles a headless daemon and installs a LaunchAgent that starts at login.

## Uninstall

**App:** Quit from menu bar, drag from /Applications to Trash.

**CLI daemon:**
```bash
./uninstall.sh
```

## How the sensor works

The lid angle is read from Apple's Sensor Processing Unit via HID:

- **VendorID:** `0x05AC` (Apple)
- **ProductID:** `0x8104` (Sensor Processing Unit)
- **UsagePage:** `0x0020` (HID Sensor)
- **Usage:** `0x008A` (Orientation)
- **Data:** Feature Report ID 1, byte 1 = angle in degrees (0° closed, ~130° fully open)

Check if your Mac has it:

```bash
hidutil list --matching '{"VendorID":0x5ac,"ProductID":0x8104,"PrimaryUsagePage":32,"PrimaryUsage":138}'
```

## Sound credits

- Door creak sounds from [BigSoundBank.com](https://bigsoundbank.com) — CC0 (public domain)
- Garage door sounds from [SoundEffectsPlus.com](https://www.soundeffectsplus.com) — royalty-free

## License

MIT
