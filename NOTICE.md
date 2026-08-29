# Third-party components

This repository bundles the following third-party software under `lib/` and at the repo root. They are separately licensed by their respective authors; the MIT license in [LICENSE](LICENSE) covers only this project's own scripts.

## AutoHotInterception

- Files: `lib/AutoHotInterception.ahk`, `lib/AutoHotInterception.dll`, `lib/CLR.ahk`
- Author: evilC
- Project: https://github.com/evilC/AutoHotInterception

An AutoHotkey v2 wrapper around the Interception driver, used here to send keyboard input that DCS World's DirectInput polling will accept.

## Interception

- Files: `lib/x86/interception.dll`, `lib/x64/interception.dll`, `install-interception.exe`
- Author: Francisco Lopes (oblitum)
- Project: https://github.com/oblitum/Interception

A kernel-mode driver enabling low-level keyboard/mouse input filtering and injection. `install-interception.exe` is the upstream installer for this driver; installing it requires a reboot.

## AHK2-Macro-Recorder

- Files: `_old/Macro Recorder.ahk`, `_old/Macro Recorder - Record2.ahk`
- Author: ArtyMcLabin
- Project: https://github.com/ArtyMcLabin/AHK2-Macro-Recorder

`CameraController.ahk` was originally derived from this generic AutoHotkey v2 macro recorder/player before being rewritten into a DCS-specific, Interception-driven camera controller. The original scripts are kept under `_old/` for reference.
