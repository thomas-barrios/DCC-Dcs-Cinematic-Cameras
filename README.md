# DCC-Dcs-Cinematic-Cameras (by Harpia)

DCS World camera automation toolkit, built for recording cinematic multi-camera flythroughs. AutoHotkey v2 scripts drive the [Interception](https://github.com/oblitum/Interception) kernel-mode driver to record and precisely replay multi-leg camera-pan sequences.

## Why a kernel driver?

DCS reads camera/view keys through raw DirectInput device polling, which ignores all normal OS-level synthetic input — `Send`, `SendInput`, and `SendPlay` all silently fail to move the camera. Interception injects input at a kernel-mode filter level indistinguishable from a real hardware keyboard, which is the only input DirectInput will accept. Ordinary AHK hotkeys (menus, Esc/F4) still work fine, since those go through normal window messages instead.

## Requirements

- Windows
- [AutoHotkey v2.0](https://www.autohotkey.com/)
- The Interception driver — install it via the bundled [`install-interception.exe`](install-interception.exe) (this **requires a reboot** afterward, standard for this driver), or get it from the [upstream project](https://github.com/oblitum/Interception)
- DCS World
- Administrator privileges — DCS (via its launcher/anti-cheat) runs elevated, and Windows UIPI silently blocks a non-elevated script's hotkeys from reaching an elevated window's focus. `CameraController.ahk` relaunches itself as Administrator automatically.

Run [`INSTALL.bat`](INSTALL.bat) to automate the above: it checks for AutoHotkey v2 and runs the Interception driver installer.

## Pointing it at your keyboard

`CameraController.ahk` targets one specific keyboard by its USB VID/PID, since Interception addresses devices that way rather than by OS device name. Which keyboard that is varies per machine, so this is detected automatically: on first run (or if the previously detected keyboard isn't plugged in), the script shows a tooltip and waits for you to press any key on the keyboard DCS should read input from, then remembers its VID/PID in `KeyboardConfig.ini` (gitignored, machine-specific) for future launches.

To point it at a different keyboard later, delete `KeyboardConfig.ini` and relaunch. [`Monitor.ahk`](Monitor.ahk) (a small GUI that visualizes live Interception device input) is still there if you ever need to inspect device IDs/VID/PID directly.

## Usage

Run `CameraController.ahk`. It self-elevates, backs up the current `CameraData.ini` into `cameras-backup/`, and starts polling hotkeys.

`CameraData.ini` stores up to 10 camera slots, each an ordered list of legs (`[key, durationMs]` pairs) that are played back by holding the given view key for the given duration.

### Hotkeys

| Keys | Action |
|---|---|
| `Alt+1` .. `Alt+0` | Select and play camera 1–10 (`0` = camera 10) |
| `Ctrl+<digits>` | Select a leg number within the current camera (e.g. `Ctrl+1` then `Ctrl+2` selects leg 12) |
| `Ctrl+Right` / `Ctrl+Left` | Next / previous leg |
| `Ctrl+Up`/`Down` (tap) | Nudge selected leg's duration by 1ms |
| `Ctrl+Up`/`Down` (hold) | Keep nudging, faster, once held past the threshold |
| `Ctrl+Shift+Up`/`Down` | Same, but nudges by a much larger step |
| `Ctrl+Insert` | Insert a new leg after the selected one |
| `Ctrl+Delete` | Delete the selected leg |
| `Ctrl+Shift+Enter` | Dump the current camera's legs as `HoldKey(...)` source lines |
| `Ctrl+Shift+N` | Rename the selected camera |
| `Ctrl+Shift+R` | Start/stop live recording into the selected camera |
| `Alt+Shift+Delete` | Clear the selected camera's legs/name in place |
| `Alt+Shift+Insert` | Jump to the next empty camera slot |
| `Ctrl+Shift+T` | Sweep the selected leg across several durations (calibration) |
| `Ctrl+Shift+B` | Replay the current camera 5x back-to-back |
| `Ctrl+Shift+G` | Same as above, but every leg uses discrete taps instead of holds |
| `Ctrl+Shift+H` | Toggle the full help/shortkey HUD |
| `Ctrl+Shift+A` | Start/stop an automatic random camera tour |

`cameras-backup/` is created automatically and holds timestamped snapshots of `CameraData.ini` taken on every launch, so a bad calibration session can always be rolled back. It's gitignored since it's runtime output, not source.

## Repository layout

```
DCC-Dcs-Cinematic-Cameras/
├── INSTALL.bat          # automates setup (AutoHotkey check, driver install)
├── CameraController.ahk # main recorder/playback script
├── Monitor.ahk          # visualizes live Interception device input (find your keyboard's VID/PID)
├── CameraData.ini       # camera slot/leg definitions, read and written by CameraController.ahk
├── KeyboardConfig.ini   # auto-detected keyboard VID/PID (gitignored, machine-specific)
├── install-interception.exe  # upstream Interception driver installer
├── lib/                 # bundled AutoHotInterception + Interception libraries (see NOTICE.md)
├── _old/                # superseded earlier versions, incl. the original AHK2-Macro-Recorder this was derived from (see NOTICE.md)
├── cameras-backup/      # auto-generated CameraData.ini snapshots (gitignored)
├── assets/              # reaction/overlay footage used in edits (gitignored, kept locally)
└── live-feed-simulation/  # recorded camera passes and stream footage (gitignored, kept locally)
```

## License

This project's own scripts are MIT licensed — see [LICENSE](LICENSE). It bundles third-party components (AutoHotInterception, Interception) under their own licenses — see [NOTICE.md](NOTICE.md).
