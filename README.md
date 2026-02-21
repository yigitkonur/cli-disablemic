macOS silently switches your mic to AirPods every time they connect. your voice goes from studio-quality 48kHz to walkie-talkie 16kHz mono. this fixes that.

```bash
npx fix-my-mic
```

compiles from source on your machine, installs a background daemon, no sudo needed. run the same command again to change settings or uninstall.

[![macOS](https://img.shields.io/badge/macOS-12+-93450a.svg?style=flat-square)](https://support.apple.com/macos)
[![swift](https://img.shields.io/badge/swift-single_file-93450a.svg?style=flat-square)](https://www.swift.org/)
[![license](https://img.shields.io/badge/license-MIT-grey.svg?style=flat-square)](https://opensource.org/licenses/MIT)

---

## demo

https://github.com/user-attachments/assets/6e24f816-4b3c-4b60-929d-e47be2871238

---

## what it does

~600-line Swift daemon that talks directly to CoreAudio. no dependencies, no electron, no python, no node. just Apple frameworks.

- **event-driven, not polling** — registers CoreAudio listeners, fully idle at 0.0% CPU between events
- **finds built-in mic by transport type** — works on MacBook Pro, Air, iMac, Mac Mini, Mac Studio
- **blocks Bluetooth input** — classic, LE, and iPhone Continuity mic. USB mics left alone
- **defeats AirPods HFP flip-backs** — re-asserts built-in mic every 0.5s for 5 seconds after a change, then goes idle
- **Apple Unified Logging** — uses `os_log`, system handles rotation

## install

```bash
npx fix-my-mic
```

don't have node? use curl:

```bash
curl -fsSL https://yigitkonur.com/disable-airpods-mic.sh | bash
```

or clone it:

```bash
git clone https://github.com/yigitkonur/cli-disablemic.git && cd cli-disablemic && ./install.sh
```

requires macOS 12+ and Xcode Command Line Tools (installer prompts if missing).

## two modes

the installer asks you to pick:

### always block (default)

built-in mic is always the default. AirPods and Bluetooth mics never used as input. install and forget.

### respect manual override

same as above, but if you switch back to AirPods within 10 seconds of mic-guard reverting it, it pauses for 1 hour then resumes. for when you actually need your AirPods mic on a call.

## usage

```bash
mic-guard pause           # pause indefinitely
mic-guard pause 30        # pause for 30 min, auto-resumes
mic-guard resume          # back to blocking
mic-guard status          # what's going on?
```

```bash
# logs
log stream --predicate 'subsystem == "com.local.mic-guard"' --style compact

# restart
launchctl kickstart -k gui/$(id -u)/com.local.mic-guard

# stop until next login
launchctl bootout gui/$(id -u)/com.local.mic-guard
```

## resource usage

| metric | value |
|:---|:---|
| CPU (idle) | 0.0% |
| CPU (stabilization) | ~0.0% (microsecond ticks) |
| memory | ~12 MB RSS |
| disk | ~65 KB binary |
| network | none |

## uninstall

run the install command again and pick "uninstall":

```bash
npx fix-my-mic
```

or manually:

```bash
launchctl bootout gui/$(id -u)/com.local.mic-guard
rm ~/.local/bin/mic-guard
rm ~/Library/LaunchAgents/com.local.mic-guard.plist
rm -rf ~/.config/mic-guard
```

## why not a GUI app?

there are apps that do this — SoundAnchor, AirPods Sound Quality Fixer, audio-device-blocker. they work, but need code signing or `xattr -cr` to bypass Gatekeeper, run a menu bar icon, and require manual download.

this compiles from source on your machine (born trusted), runs as a headless `launchd` agent, and is a single Swift file you can read in 5 minutes.

## internals

single file: `main.swift`. only Apple frameworks (`CoreAudio`, `Foundation`, `os.log`). compiles with `swiftc` — no Xcode project, no Package.swift, no SPM.

key CoreAudio APIs:

- `AudioObjectAddPropertyListener` — event callbacks
- `AudioObjectGetPropertyData` / `SetPropertyData` — read/write device properties
- `kAudioHardwarePropertyDefaultInputDevice` — system default input
- `kAudioDevicePropertyTransportType` — distinguish built-in from Bluetooth

## license

MIT
