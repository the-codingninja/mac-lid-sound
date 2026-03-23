# Mac Door Hinge Sound — Design Spec

## Overview

Play a gentle old wooden door creak sound when the MacBook lid opens or closes. Each event triggers a slightly randomized variation of the creak so it feels organic — like a real hinge — rather than a repetitive notification.

## Target System

- MacBook Pro M4 Max (Mac16,5), macOS
- Apple Silicon compatible (Homebrew at `/opt/homebrew/`)

## How It Works

### Detection

**SleepWatcher** (Homebrew) monitors macOS sleep/wake events via a launchd service. It executes user-defined scripts on two events:

- **Sleep** (lid close) → runs `~/.sleep` (or a configured script path)
- **Wake** (lid open) → runs `~/.wakeup` (or a configured script path)

### Sound Playback

Each script:

1. Sets up PATH explicitly (`/opt/homebrew/bin`) — SleepWatcher runs scripts in a minimal environment without login shell profiles
2. Checks for mute toggle file (`~/.hinge_mute`) — exits immediately if present
3. Picks a random base sound file from a set of 2-3 variations
4. Applies randomized audio transformations via `sox`:
   - Pitch shift: +/- 100 cents (1 semitone)
   - Speed/tempo: +/- 15%
   - Optional subtle reverb (30% chance, using `$RANDOM % 10 < 3`)
5. Writes processed audio to a unique temp file via `mktemp`
6. Plays the transformed audio via `afplay` (built-in macOS)
7. Cleans up the temp file

**On lid close:** The entire sox+afplay pipeline runs under `caffeinate -i` which prevents idle sleep until the child process exits — no hardcoded timeout.

**On lid open:** No special timing needed — the system is already awake.

**Known limitation:** On lid close, macOS gives very limited time before suspending processes. Close sounds must be short (under 1.5 seconds) to reliably finish. If macOS suspends the script mid-playback, the creak will be cut off. This is acceptable — a partial creak still sounds like a door closing.

### Sound Files

- Source: Free/CC0 sounds from freesound.org
- Style: Gentle wooden door creak (not horror, not metallic)
- Format: WAV (uncompressed, for low-latency playback and sox processing)
- **Duration: 0.5-1.5 seconds** (critical for close sounds to finish before sleep)
- Files:
  - `sounds/close_1.wav`, `close_2.wav`, `close_3.wav` — closing creak variants
  - `sounds/open_1.wav`, `open_2.wav`, `open_3.wav` — opening creak variants
- Opening sounds should have a slightly different character than closing sounds (e.g., reverse creak, different pitch range)

### Randomization Parameters

```
PITCH_RANGE=100        # +/- 100 cents (1 semitone)
SPEED_MIN=0.85
SPEED_MAX=1.15
REVERB_CHANCE=3        # out of 10 → 30% chance (bash: RANDOM % 10 < 3)
REVERB_AMOUNT=20       # subtle, room-size reverb
```

## Dependencies

| Dependency    | Install              | Purpose                         |
|---------------|----------------------|---------------------------------|
| sleepwatcher  | `brew install sleepwatcher` | Detect sleep/wake events  |
| sox           | `brew install sox`         | Audio pitch/speed manipulation |
| afplay        | Built-in macOS             | Audio playback               |
| caffeinate    | Built-in macOS             | Prevent idle sleep during playback |

## File Structure

```
mac-door-hinge-sound/
├── docs/
│   └── design.md
├── sounds/
│   ├── close_1.wav
│   ├── close_2.wav
│   ├── close_3.wav
│   ├── open_1.wav
│   ├── open_2.wav
│   └── open_3.wav
├── scripts/
│   ├── on_sleep.sh
│   └── on_wakeup.sh
├── install.sh
├── uninstall.sh
└── README.md
```

## Scripts

### Environment Setup (both scripts)

```bash
#!/bin/bash
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOUNDS_DIR="$SCRIPT_DIR/../sounds"
LOG_FILE="$HOME/.hinge_sound.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

# Mute check
[ -f "$HOME/.hinge_mute" ] && exit 0

# Verify dependencies
command -v sox >/dev/null || { log "ERROR: sox not found"; exit 1; }
```

### scripts/on_sleep.sh

```
1. Source environment setup above
2. Pick random close_N.wav (verify file exists)
3. Generate random pitch/speed values within range
4. TMPFILE=$(mktemp /tmp/hinge_XXXXXX.wav)
5. caffeinate -i sox input.wav "$TMPFILE" pitch $PITCH speed $SPEED [reverb]
6. afplay "$TMPFILE"
7. rm -f "$TMPFILE"
```

### scripts/on_wakeup.sh

```
1. Source environment setup above
2. Pick random open_N.wav (verify file exists)
3. Generate random pitch/speed values within range
4. TMPFILE=$(mktemp /tmp/hinge_XXXXXX.wav)
5. sox input.wav "$TMPFILE" pitch $PITCH speed $SPEED [reverb]
6. afplay "$TMPFILE"
7. rm -f "$TMPFILE"
```

## install.sh

1. Check for Homebrew, prompt to install if missing
2. `brew install sleepwatcher sox`
3. Resolve absolute path to scripts directory
4. `chmod +x scripts/on_sleep.sh scripts/on_wakeup.sh`
5. Check if `~/.sleep` or `~/.wakeup` already exist — back them up to `~/.sleep.bak` / `~/.wakeup.bak` and warn
6. Create `~/.sleep` and `~/.wakeup` symlinks pointing to scripts
7. Start sleepwatcher service: `brew services start sleepwatcher`
8. Verify service is running

## uninstall.sh

1. `brew services stop sleepwatcher`
2. Remove `~/.sleep` and `~/.wakeup` symlinks
3. Restore `~/.sleep.bak` / `~/.wakeup.bak` if they exist
4. Optionally remove sleepwatcher and sox (`--purge` flag)

## Mute Toggle

- `touch ~/.hinge_mute` → silences all sounds
- `rm ~/.hinge_mute` → re-enables sounds
- Scripts check for this file at the very top and exit immediately if present

## Edge Cases

- **External display / lid closed but not sleeping:** `AppleClamshellCausesSleep = No` means clamshell mode won't trigger sleep → no false creaks
- **Manual sleep (Apple menu → Sleep):** Will trigger the close creak — acceptable, still a "closing" action
- **Rapid open/close:** sox + afplay finish in <1.5s for short creaks, unlikely to overlap
- **No audio output:** If volume is muted, `afplay` silently completes — no error
- **Close sound cut off by sleep:** Partial creak is acceptable — sounds like a door closing quickly
- **Existing ~/.sleep or ~/.wakeup files:** Backed up before overwriting, restored on uninstall

## Testing

- Verify setup: `brew services list | grep sleepwatcher`, `ls -la ~/.sleep ~/.wakeup`
- Script permissions: `test -x scripts/on_sleep.sh && echo "OK"`
- Manual: `bash scripts/on_sleep.sh` and `bash scripts/on_wakeup.sh`
- Variation: Run script 10 times, confirm audible differences
- Integration: Close and open lid, verify sounds play
- Mute: `touch ~/.hinge_mute`, close lid, verify no sound, `rm ~/.hinge_mute`
- Logging: Check `~/.hinge_sound.log` for entries after each trigger
