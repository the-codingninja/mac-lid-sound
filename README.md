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

**From source:**

```bash
git clone https://github.com/user/mac-door-hinge-sound.git
cd mac-door-hinge-sound
./install.sh
```

This compiles the Swift daemon and installs a LaunchAgent that starts at login.

**Pre-built binary:**

Download `hinge-daemon` from [Releases](https://github.com/user/mac-door-hinge-sound/releases), then:

```bash
# Place it somewhere permanent
mkdir -p ~/.local/bin
cp hinge-daemon ~/.local/bin/
cp -r sounds ~/.local/share/hinge-sounds/

# Run it
~/.local/bin/hinge-daemon ~/.local/share/hinge-sounds/
```

Or use `install.sh` which handles everything.

## Uninstall

```bash
./uninstall.sh
```

## Usage

```bash
touch ~/.hinge_mute      # mute
rm ~/.hinge_mute          # unmute
cat ~/.hinge_sound.log    # view log
```

**Manual control:**

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.hinge-sound.daemon.plist

# Start
launchctl load ~/Library/LaunchAgents/com.hinge-sound.daemon.plist
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

Door creak sounds from [BigSoundBank.com](https://bigsoundbank.com) — CC0 (public domain).

## License

MIT
