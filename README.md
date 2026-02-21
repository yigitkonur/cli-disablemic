# 🙅🏻‍♂️ no airpods mic

> every time i connect my AirPods, macOS silently switches my mic input to them. my voice goes from studio-quality 48kHz to walkie-talkie 16kHz mono. i got tired of manually switching it back. so i made this.

https://github.com/user-attachments/assets/6e24f816-4b3c-4b60-929d-e47be2871238

one command. installs itself. runs forever. no app, no menu bar icon, no GUI. just your MacBook's built-in mic, always.

## install

```bash
npx fix-my-mic
```

that's it. picks a mode, compiles from source on your machine (no code signing, no quarantine, no gatekeeper drama), and starts a background daemon. no sudo needed.

**want to change settings or uninstall? run the same command again.**

don't have node? use curl:

```bash
curl -fsSL https://yigitkonur.com/disable-airpods-mic.sh | bash
```

or clone it:

```bash
git clone https://github.com/yigitkonur/cli-disablemic.git && cd cli-disablemic && ./install.sh
```

### requirements

- macOS 12 (Monterey) or later
- Xcode Command Line Tools (the installer will prompt you if missing)

## how it works

it's a ~600-line Swift daemon that talks directly to CoreAudio. no dependencies, no third-party libraries, no electron, no python, no node. just Apple frameworks.

1. **event-driven, not polling.** registers CoreAudio listeners on the default input device and the device list. the instant something changes, it gets a callback. between events, it's fully idle at 0.0% CPU.

2. **finds the built-in mic by transport type**, not by name. works on MacBook Pro, MacBook Air, iMac, Mac Mini, Mac Studio — any Mac with a built-in microphone.

3. **blocks Bluetooth input** (classic and LE) and unknown wireless transports like iPhone Continuity mic. USB mics and aggregate devices are left alone.

4. **defeats AirPods HFP flip-backs.** AirPods sometimes re-negotiate the input 1-3 seconds after connecting. mic-guard re-asserts the built-in mic every 0.5s for 5 seconds after a change, then goes fully idle again.

5. **uses Apple Unified Logging** (`os_log`), not log files. the system handles rotation automatically.

## two modes

the installer asks you to pick:

### 1) always block (default)

your built-in mic is always the default. AirPods and Bluetooth mics are never used as input. install and forget.

### 2) respect manual override

same as above, but if you switch back to AirPods within 10 seconds of mic-guard reverting it, mic-guard goes "ok, you clearly want this" and pauses itself for 1 hour. after the hour, it resumes automatically.

perfect for when you actually need your AirPods mic for a call.

## resource usage

| metric | value |
|--------|-------|
| CPU (idle) | 0.0% |
| CPU (during 5s stabilization) | ~0.0% (a few microsecond ticks) |
| memory | ~12 MB RSS |
| disk | ~65 KB binary |
| network | none |

## commands

```bash
# need your AirPods mic for a sec?
mic-guard pause           # pause indefinitely
mic-guard pause 30        # pause for 30 min, auto-resumes
mic-guard resume          # back to blocking
mic-guard status          # what's going on?

# nerdy stuff
log stream --predicate 'subsystem == "com.local.mic-guard"' --style compact
launchctl kickstart -k gui/$(id -u)/com.local.mic-guard   # restart
launchctl bootout gui/$(id -u)/com.local.mic-guard         # stop until next login
```

## uninstall

run the install command again and pick "uninstall":

```bash
npx fix-my-mic
```

or nuke it manually:

```bash
launchctl bootout gui/$(id -u)/com.local.mic-guard
rm ~/.local/bin/mic-guard
rm ~/Library/LaunchAgents/com.local.mic-guard.plist
rm -rf ~/.config/mic-guard
```

## why not just use an app?

there are GUI apps that do this — [SoundAnchor](https://apps.kopiro.me/soundanchor/), [AirPods Sound Quality Fixer](https://github.com/milgra/airpodssoundqualityfixer), [audio-device-blocker](https://github.com/jbgosselin/audio-device-blocker). they work, but:

- need code signing/notarization or `xattr -cr` to bypass Gatekeeper
- run a menu bar icon you don't need
- may not survive macOS updates
- require manual download and drag-to-Applications

this compiles from source on your machine (born trusted, no signing needed), runs as a headless `launchd` agent (no GUI), and is a single Swift file you can read in 5 minutes.

## the nerdy details

single file: `main.swift`. only uses Apple frameworks (`CoreAudio`, `Foundation`, `os.log`). compiles with `swiftc` — no Xcode project, no Package.swift, no CocoaPods, no SPM.

key CoreAudio APIs:
- `AudioObjectAddPropertyListener` — event callbacks
- `AudioObjectGetPropertyData` / `SetPropertyData` — read/write device properties
- `kAudioHardwarePropertyDefaultInputDevice` — the system default input
- `kAudioDevicePropertyTransportType` — distinguish built-in from Bluetooth

## license

MIT — do whatever you want with it.
