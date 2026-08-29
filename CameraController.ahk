#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "lib\AutoHotInterception.ahk"

; DCS (via launcher/anti-cheat) usually runs elevated. If this script runs
; non-elevated, Windows UIPI silently blocks its hotkeys from firing while
; an elevated window has focus - no error, they just never trigger. Force
; a relaunch as admin so this script's hook matches DCS's integrity level.
if !A_IsAdmin {
    try {
        Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    }
    ExitApp()
}

; Snapshots CameraData.ini into .\cameras-backup\ before anything else touches
; it, so a bad calibration/recording session can always be rolled back. The
; filename is timestamp-prefixed (e.g. "2026-02-01-12-12-45-CameraData.ini")
; so repeated runs never overwrite an earlier backup. No-op on a fresh
; machine where CameraData.ini doesn't exist yet.
BackupCameraData() {
    file := CameraDataFile()
    if !FileExist(file)
        return
    backupDir := A_ScriptDir "\cameras-backup"
    DirExist(backupDir) || DirCreate(backupDir)
    stamp := FormatTime(, "yyyy-MM-dd-HH-mm-ss")
    FileCopy(file, backupDir "\" stamp "-CameraData.ini")
}
BackupCameraData()

; Precision fix A: the default Windows scheduler tick is ~15.6ms, so Sleep()
; in HoldKey() can wake up to that far late (worse under load, e.g. OBS
; encoding while streaming) - this is jitter on every single leg. Raising
; the timer resolution to 1ms and bumping this process's priority so OS
; scheduling contention delays it less both target that jitter directly.
DllCall("winmm\timeBeginPeriod", "UInt", 1)
ProcessSetPriority("High")
OnExit((*) => DllCall("winmm\timeEndPeriod", "UInt", 1))

SetKeyDelay(30)
; DCS's DirectInput keyboard reading doesn't reliably pick up Event-mode
; (keybd_event) synthetic input - the known-working DCS automation script
; never overrides SendMode and relies on the default Input (SendInput) mode.
SendMode("Input")
SetTitleMatchMode(2)
CoordMode("Mouse", "Screen")

; DCS reads camera/view keys (a/w/e below) through DirectInput device
; polling, which ignores ALL OS-level synthetic input - confirmed by testing
; that neither Send, SendInput, nor SendPlay ever registered, while menu
; keys (Esc/F4, plain Send) work fine because those go through normal
; window messages instead. The Interception driver + AutoHotInterception
; inject through a kernel-mode filter that's indistinguishable from a real
; hardware keyboard, which is the only thing DirectInput will accept.
global AHI := AutoHotInterception()
global DcsKeyboardId := ResolveDcsKeyboard(AHI)

; Which physical keyboard drives DCS varies per machine, so instead of a
; hardcoded VID/PID this remembers whatever was detected last time in
; KeyboardConfig.ini (gitignored - machine-specific). If that device isn't
; currently plugged in (fresh machine, or a swapped keyboard), it falls back
; to a one-time interactive detection instead of failing outright.
ResolveDcsKeyboard(AHI) {
    configFile := A_ScriptDir "\KeyboardConfig.ini"
    vid := IniRead(configFile, "Keyboard", "VID", "")
    pid := IniRead(configFile, "Keyboard", "PID", "")
    if (vid != "" && pid != "") {
        for id, dev in AHI.GetDeviceList() {
            if (!dev.IsMouse && dev.VID = Integer(vid) && dev.PID = Integer(pid))
                return id
        }
    }

    dev := DetectDcsKeyboard(AHI)
    IniWrite(dev.VID, configFile, "Keyboard", "VID")
    IniWrite(dev.PID, configFile, "Keyboard", "PID")
    return dev.ID
}

; Subscribes to every keyboard Interception can see and waits for a keypress,
; so first-time setup is "press a key" instead of running Monitor.ahk to read
; VID/PID out of a GUI and hand-editing this script.
DetectDcsKeyboard(AHI) {
    list := AHI.GetDeviceList()
    ToolTip("DCS Camera Controller - first-time setup`nPress any key on the keyboard DCS should read input from...")
    detected := {id: 0}
    for id, dev in list {
        if !dev.IsMouse
            AHI.SubscribeKeyboard(id, false, OnDetectKey.Bind(id, detected))
    }
    while !detected.id
        Sleep(20)
    for id, dev in list {
        if !dev.IsMouse
            AHI.UnsubscribeKeyboard(id)
    }
    ToolTip()
    return list[detected.id]
}

OnDetectKey(id, detected, code, state) {
    detected.id := id
}

; ##### HUD windows (status / transient / help) #####
; The status/leg/help displays used to be native ToolTip() slots 1-3, which
; forced a DllCall("gdi32\CreateFont"...)+WM_SETFONT hack (see git history)
; just to get a fixed-width font so the column padding below lines up - and
; still offered no control over colors/borders, or any way to move them off
; wherever the code happened to place them. Real Gui windows give that
; control directly via SetFont/BackColor, so each HUD below is a small
; borderless always-on-top window instead, and can be dragged out of the way
; (see HudDragStart below).
;
; -Caption +ToolWindow keeps them off the taskbar/Alt+Tab; +AlwaysOnTop keeps
; them above DCS. HUD_EXSTYLE adds WS_EX_NOACTIVATE (0x08000000) so
; showing/clicking one never steals keyboard focus from DCS. Unlike the
; original tooltip HUD, these are NOT click-through (WS_EX_TRANSPARENT) -
; that's what let it be dragged, but it also means a HUD sitting over DCS
; will catch mouse clicks meant for the game underneath. Trade-off accepted
; in exchange for being movable; reposition a HUD out of the way once
; (position is remembered - see `moved` below) rather than leaving it
; centered over the view.
global HUD_EXSTYLE := "+E0x08000000"

; Builds one HUD window: a Gui containing a single Text control that
; ShowHud() resizes/repositions on every update (see below). `moved` starts
; false (HUD still auto-positioned by its caller); it flips true the first
; time the user drags the HUD (see HudDragStart), after which ShowHud() stops
; overriding its position and just leaves it wherever it was dropped.
NewHud() {
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border " HUD_EXSTYLE)
    g.BackColor := "1E1E1E"
    g.SetFont("s10 cWhite", "Consolas")
    ctrl := g.Add("Text", "w1 h1", "")
    return { gui: g, ctrl: ctrl, moved: false }
}

; Maps both a HUD's own Gui Hwnd and its Text control's Hwnd back to the HUD
; object, so HudDragStart can find the right one from whichever of the two a
; click actually landed on (see comment there).
global HUD_BY_HWND := Map()
RegisterHud(hud) {
    global HUD_BY_HWND
    HUD_BY_HWND[hud.gui.Hwnd] := hud
    HUD_BY_HWND[hud.ctrl.Hwnd] := hud
}

global StatusHud := NewHud() ; always-on status box
RegisterHud(StatusHud)
global LegHud := NewHud()    ; transient leg-buffer/error messages
RegisterHud(LegHud)
global HelpHud := NewHud()   ; toggled help/shortkey screen
RegisterHud(HelpHud)

; Makes every HUD draggable by clicking anywhere on it, even though it has no
; titlebar (-Caption): a real titlebar drag works by the OS getting
; WM_NCLBUTTONDOWN with HTCAPTION, so a left-click anywhere in the HUD (its
; background OR its Text control - both are registered in HUD_BY_HWND) is
; forwarded as exactly that message to the HUD's own top-level window, which
; hands the drag off to the OS's standard move loop, identical to grabbing a
; real titlebar. Marks the HUD `moved` immediately so ShowHud() never yanks
; it back to its computed position again.
OnMessage(0x201, HudDragStart) ; WM_LBUTTONDOWN
HudDragStart(wParam, lParam, msg, hwnd) {
    global HUD_BY_HWND
    if !HUD_BY_HWND.Has(hwnd)
        return
    hud := HUD_BY_HWND[hwnd]
    hud.moved := true
    PostMessage(0xA1, 2, 0, , "ahk_id " hud.gui.Hwnd) ; WM_NCLBUTTONDOWN, HTCAPTION
}

; Resizes `hud`'s text control and window to fit `text` (20px/line, matching
; the line spacing tuned for the old tooltip font) and shows it without
; activating it, so DCS keeps keyboard focus. Uses (x, y) as the position
; only until the user has dragged this HUD (see `moved`/HudDragStart above) -
; after that, its current on-screen position is kept instead, so a redraw
; (e.g. on every keypress while calibrating) doesn't undo the user's drag.
; Returns the shown window's {w, h} so callers can position another HUD
; relative to it (e.g. the leg/help HUDs sitting just below/right of the
; status HUD's variable-height box).
ShowHud(hud, text, x, y) {
    th := StrSplit(text, "`n").Length * 20
    tw := HudLineWidth(text)
    hud.ctrl.Move(8, 6, tw, th)
    hud.ctrl.Text := text
    w := tw + 16, h := th + 12
    if hud.moved
        hud.gui.GetPos(&x, &y)
    hud.gui.Show("x" x " y" y " w" w " h" h " NoActivate")
    return { w: w, h: h }
}

HideHud(hud) {
    hud.gui.Hide()
}

; ##### Recorded playback sequences #####
; Each camera is an ordered list of legs (a [key, durationMs] pair). Alt+1..
; Alt+0 select/play cameras 1-10; within the selected camera, Ctrl+<digits>
; picks a leg to tune. See "Calibration mode" below for the tuning hotkeys.

; Sends `key` `count` times via the Interception-driver keyboard, with a
; real down/up press and a delay between repeats so DCS registers each one
; as a distinct press instead of a single held key.
SendRepeat(key, count, delayMs := 10, pressMs := 20) {
    global AHI, DcsKeyboardId
    sc := GetKeySC(key)
    Loop count {
        AHI.SendKeyEvent(DcsKeyboardId, sc, 1)
        Sleep(pressMs)
        AHI.SendKeyEvent(DcsKeyboardId, sc, 0)
        Sleep(delayMs)
    }
}

; Holds `key` down for exactly `durationMs`, then releases it. DCS's camera
; keys pan continuously while held, so movement distance is a function of
; total held time - one down/up pair with a single Sleep() gives one timing
; interval to jitter instead of the many that SendRepeat's discrete presses
; accumulate, so the camera lands in the same spot every run.
; `key` may be a single key name or several joined with "+" (e.g.
; "RShift+NumpadLeft") - all are pressed down together, held for
; `durationMs`, then released in reverse order.
HoldKey(key, durationMs) {
    global AHI, DcsKeyboardId
    keys := StrSplit(key, "+")
    scs := []
    for k in keys
        scs.Push(GetKeySC(k))
    for sc in scs
        AHI.SendKeyEvent(DcsKeyboardId, sc, 1)
    Sleep(durationMs)
    Loop scs.Length
        AHI.SendKeyEvent(DcsKeyboardId, scs[scs.Length - A_Index + 1], 0)
}

; Precision fix B: sends `key` as repeated short taps instead of one
; continuous hold, covering the same span of view-key presses as SendRepeat
; but timed to approximate `durationMs` of pan. Each tap is short enough
; that DCS can't build up whatever makes the accel-test sweeps land so
; unevenly (see AccelTest results), and a single tap's timing jitter only
; perturbs that one small increment instead of the whole leg - opt-in via
; PlayCamera's useTapped param so it doesn't change default playback.
HoldKeyTapped(key, durationMs, pressMs := 20, delayMs := 10) {
    global AHI, DcsKeyboardId
    keys := StrSplit(key, "+")
    scs := []
    for k in keys
        scs.Push(GetKeySC(k))
    tapCount := Max(1, Round(durationMs / (pressMs + delayMs)))
    Loop tapCount {
        for sc in scs
            AHI.SendKeyEvent(DcsKeyboardId, sc, 1)
        Sleep(pressMs)
        Loop scs.Length
            AHI.SendKeyEvent(DcsKeyboardId, scs[scs.Length - A_Index + 1], 0)
        Sleep(delayMs)
    }
}

; Focuses DCS so subsequent keys go to the game instead of the editor/desktop.
; WinWaitActive blocks until DCS truly has keyboard focus (not just visually
; on top) - a flat Sleep isn't enough if activation is slow across the
; elevation boundary, and Sends fired before real focus lands go nowhere.
; Returns true once DCS is active, false if it's not running or won't focus.
FocusDCS() {
    if (WinExist("ahk_exe DCS.exe")) {
        WinActivate "ahk_exe DCS.exe"
        if !WinWaitActive("ahk_exe DCS.exe", , 3)
            return false
        return true
    }
    return false
}

; Camera 1 is the original Record2 sequence. Add more slots (2-10) the same
; way as they get calibrated; an undefined slot just has no legs yet.
global Cameras := Map()
Cameras[1] := [["a", 800], ["w", 600], ["e", 50], ["RShift+NumpadLeft", 1420]] ;180 degrees of rotation

; Optional display name per camera slot, set via Ctrl+Shift+N. Slots with no
; entry here just show as "Camera-0N" with no quoted name in the status HUD.
global CameraNames := Map()

; Fixed number of camera slots shown in the status HUD and reachable via
; Shift+Left/Right and Alt+"Number" (single digit, "0" = 10).
global MAX_CAMERAS := 10

; ##### Camera data persistence #####
; Cameras/CameraNames live in an .ini file next to the script instead of only
; in this source file, so calibrated positions can be copied to another
; machine (or backed up) by copying one file - no code edit/reload needed.
; LoadCameraData() runs once at startup (below, after the hardcoded default
; Cameras[1] is defined) and overwrites that default if the file exists;
; SaveCameraData() is called wherever a camera's data changes (see PlayCamera,
; ToggleRecording, RenameCamera) so the file never falls behind memory.
CameraDataFile() {
    return A_ScriptDir "\CameraData.ini"
}

SaveCameraData() {
    global Cameras, CameraNames
    file := CameraDataFile()
    if FileExist(file)
        FileDelete(file)
    for camNum, legs in Cameras {
        section := "Camera" camNum
        if CameraNames.Has(camNum)
            IniWrite(CameraNames[camNum], file, section, "Name")
        IniWrite(legs.Length, file, section, "LegCount")
        for i, leg in legs {
            IniWrite(leg[1], file, section, "Leg" i "Key")
            IniWrite(leg[2], file, section, "Leg" i "Ms")
        }
    }
}

; Returns true and replaces Cameras/CameraNames if CameraDataFile() exists;
; returns false (leaving the hardcoded defaults alone) if it doesn't yet.
LoadCameraData() {
    global Cameras, CameraNames
    file := CameraDataFile()
    if !FileExist(file)
        return false
    loaded := Map()
    loadedNames := Map()
    for section in StrSplit(IniRead(file), "`n") {
        if !RegExMatch(section, "^Camera(\d+)$", &m)
            continue
        camNum := Integer(m[1])
        name := IniRead(file, section, "Name", "")
        if (name != "")
            loadedNames[camNum] := name
        legCount := Integer(IniRead(file, section, "LegCount", "0"))
        legs := []
        Loop legCount {
            key := IniRead(file, section, "Leg" A_Index "Key", "")
            ms := Integer(IniRead(file, section, "Leg" A_Index "Ms", "0"))
            legs.Push([key, ms])
        }
        loaded[camNum] := legs
    }
    Cameras := loaded
    CameraNames := loadedNames
    return true
}

; Load persisted camera data now, overwriting the hardcoded Camera[1] default
; above if CameraDataFile() exists; if this is a fresh machine with no file
; yet, keep the hardcoded default and write it out immediately so the file
; exists from the start and can be copied elsewhere right away.
if !LoadCameraData()
    SaveCameraData()

; Plays every leg of `camNum` in order. No-op if that camera has no legs yet.
; useTapped swaps in HoldKeyTapped (precision fix B) for every leg's pan -
; the Numpad5 reset always uses a plain HoldKey since it's a snap keypress,
; not a pan, so there's nothing for tapping to help with there. Defaults to
; false: a first RepeatTest round made tapped look more consistent, but two
; more rounds (RepeatTest\<timestamp>_hold vs _tapped) showed tapped landing
; on 3 wildly different framings across 5 runs while hold stayed on the same
; framing in 4/5 - tapped's ~47 independent down/up cycles per leg (for the
; 1420ms rotation) are ~47 separate chances for DCS's per-frame DirectInput
; poll to drop/mistime a tap, which outweighs HoldKey's single Sleep()
; jitter. Kept available via PlayCamera(cam, true) / Ctrl+Shift+G for
; reference, but hold is the default again.
PlayCamera(camNum, useTapped := false) {
    global Cameras
    if !Cameras.Has(camNum) || Cameras[camNum].Length = 0
        return
    ; Every camera run re-saves CameraData.ini, so the file on disk never
    ; drifts from whatever's actually been calibrated in memory.
    SaveCameraData()
    if !FocusDCS()
        return
    ; F4 needs noticeably longer than the other waits before the view is
    ; actually selected/active - a/w/e/z sent too soon after this land
    ; nowhere, even though the keys themselves are bound and working fine.
    Sleep(50)
    ; Numpad5 resets the F4 camera back to its default position/angle before
    ; any leg moves it, so every camera starts its pan from the same spot
    ; instead of wherever the previous camera left off. Sent twice with a
    ; short gap - DCS's DirectInput poll occasionally misses a single short
    ; press (same failure mode noted for HoldKeyTapped above), which used to
    ; leave the camera wherever the previous camera left off instead of at
    ; the reset position; two presses need both to be missed to still fail.
    HoldKey("Numpad5", 80)
    Sleep(60)
    HoldKey("Numpad5", 80)
    Sleep(60)
    for leg in Cameras[camNum]
        useTapped ? HoldKeyTapped(leg[1], leg[2]) : HoldKey(leg[1], leg[2])
}

; ##### Calibration mode #####
; Tunes one leg's duration at a time without editing/reloading the script.
;   Alt+1..Alt+0         select camera 1-10 (0 = camera 10) and play it in full
;   Shift+Left/Right     select previous/next camera (1..MAX_CAMERAS), no play
;   Ctrl+<digits>        select a leg number within the current camera
;                        (e.g. Ctrl+1 then Ctrl+2 selects leg 12)
;   Ctrl+Right           select next leg within the current camera
;   Ctrl+Left            select previous leg within the current camera
;   Ctrl+Up/Down tap     nudge the selected leg's duration by 1ms (precise) -
;                        fires once immediately on key-down
;   Ctrl+Up/Down hold    once held past HOLD_THRESHOLD_MS, keeps nudging by
;                        REPEAT_STEP_MS every REPEAT_INTERVAL_MS until released
;   Ctrl+Shift+Up/Down   same as Ctrl+Up/Down but nudges by the much larger
;                        SUPER_STEP_MS/SUPER_REPEAT_STEP_MS, for coarse edits
;   Ctrl+Insert          insert a new leg right after the selected one,
;                        select it, and capture the next key(s) you actually
;                        press in DCS as its key+duration (see "Leg key
;                        capture" below) instead of leaving it a hardcoded
;                        blank "w", 0ms to hand-edit
;   Ctrl+Delete          delete the selected leg
;   Ctrl+Shift+Enter     dump the current camera's legs as HoldKey(...) lines
;                        to paste back into its Cameras[...] entry
;   Ctrl+Shift+N         type/change the selected camera's display name
;   Ctrl+Shift+R         start/stop live recording into the selected camera -
;                        replaces its legs with whatever you actually pan in
;                        DCS (see "Live recording" below)
;   Alt+Shift+Delete     clear the selected camera's legs/name in place (no
;                        other camera slots are renumbered)
;   Alt+Shift+Insert     jump to the next empty camera slot so a new camera
;                        can be recorded into it (no other slots are moved)
;   Ctrl+Shift+T         sweep the selected leg across 5 durations (25/50/75/
;                        100/125% of its current value), screenshotting after
;                        each, to check whether pan distance is linear in
;                        hold duration - saved as .bmp under AccelTest\<timestamp>\
;   Ctrl+Shift+B         replay the whole current camera 5x back-to-back
;                        (continuous holds), screenshotting after each run,
;                        to check run-to-run positioning consistency - saved
;                        under RepeatTest\<timestamp>_hold\
;   Ctrl+Shift+G         same as Ctrl+Shift+B but every leg uses discrete taps
;                        (HoldKeyTapped) instead of one continuous hold -
;                        saved under RepeatTest\<timestamp>_tapped\
;   Ctrl+Shift+H         toggle the full help/shortkey HUD
;   Ctrl+Shift+A         start/stop automatic random camera tour - plays
;                        every camera with legs, one at a time, in a freshly
;                        shuffled order, pausing 2s after each finishes
;                        positioning, looping until Ctrl+Shift+A is pressed
;                        again
;
; All camera data (legs + names) is persisted to CameraData.ini next to this
; script - see "Camera data persistence" above. It's re-saved on every camera
; run, recording stop, and rename, so copying that one file to another
; machine carries every calibrated camera with it.
global CurrentCamera := 1
global CurrentLeg := 1
global LegBuffer := ""
; Tracks the bottom edge of the last CalShowState() box so the leg-buffer/
; error HUD (LegHud) can sit just below it instead of overlapping.
global StateBoxBottomY := 220
; Tracks the right edge of the last CalShowState() box so the help HUD
; (HelpHud) can sit just to its right instead of overlapping it.
global StateBoxRightX := 220

; ##### Live recording #####
; Captures real panning as legs instead of hand-typing/tuning them.
;
; Originally this watched every down/up on the DCS keypad device via
; AHI.SubscribeKeyboard's callback. That turned out to be a dead end: the
; camera keys are DCS-facing, but the callback itself runs on
; AutoHotInterception's own thread (either its raw driver-read thread with
; concurrent=true, or - apparently non-functional in this AHI build -
; marshalled back via COM with concurrent=false, which never delivered a
; single event in testing). Calling AHK code (even just pushing onto an
; array) from that foreign thread reliably crashed the whole script within
; seconds, and there was no safe subset of work small enough to avoid it.
;
; Recording instead piggybacks on the same polling this script already uses
; for every other hotkey (see "Hotkey polling" below): the camera keys are
; real physical keypresses, so they always update Windows' normal keyboard
; state table regardless of DCS's DirectInput-only reading of *synthetic*
; input - GetKeyState(..., "P") sees them exactly like it sees the Ctrl/Alt/
; digit combos already polled elsewhere in this script. ProcessRecordingPoll
; below runs on the main thread from PollHotkeys' existing 20ms timer, so
; there's no foreign-thread call in this path at all.
;
; A "cluster" is whatever keys are held down with overlapping intervals -
; supports chords like the camera 1 "RShift+NumpadLeft" leg even when the two
; keys' down-presses don't land on the exact same 20ms poll tick, as long as
; one is still held when the other goes down. It opens on the first key-down
; after the held set was empty, absorbs any other key that goes down while
; it's still open, and closes into one [key(s), durationMs] leg - the same
; shape PlayCamera already expects - either when the held set empties out, or
; when a key that's *already part of this cluster* gets pressed again (a
; repeat tap), which still forces a boundary even while another key (e.g. a
; held modifier) bridges across it. That repeat-tap rule is what keeps "hold
; RShift, tap NumpadLeft three times with gaps" as three separate
; "RShift+NumpadLeft" legs instead of merging the whole gesture (taps and
; gaps together) into one leg - an even earlier version only closed a leg
; once every held key had come back up, so a still-held modifier meant the
; held-count never returned to 0 between taps and the whole multi-tap gesture
; got recorded as one continuous hold, playing back as one long over-rotation
; instead of three short nudges. See ClusterFeed/ClusterFinalize below.
; Numpad5 is excluded since PlayCamera always sends its own reset before the
; first leg.
global IsRecording := false

; Candidate keys polled while recording - DCS's F4 free-camera keys (pan/
; zoom/tilt) plus the modifiers/numpad keys needed for chorded legs like
; camera 1's "RShift+NumpadLeft". Deliberately excludes Ctrl/Alt/digits/
; arrows, since those are this script's own hotkeys and would otherwise get
; captured as (bogus) legs the moment you press Ctrl+Shift+R itself.
global RECORD_KEYS := ["a", "w", "e", "q", "s", "d", "LShift", "RShift",
    "NumpadLeft", "NumpadRight", "NumpadUp", "NumpadDown",
    "Numpad4", "Numpad6", "Numpad8", "Numpad2"]

; The subset of RECORD_KEYS that actually pan/tilt the camera when held, as
; opposed to a pure chord modifier (LShift/RShift). Used by the cluster
; engine below (see IsAxisActive) to only accrue a leg's recorded duration
; while one of these is genuinely held, so an idle gap between taps - with
; only a modifier still down - doesn't get counted as pan time.
global MOTION_KEYS := ["a", "w", "e", "q", "s", "d",
    "NumpadLeft", "NumpadRight", "NumpadUp", "NumpadDown",
    "Numpad4", "Numpad6", "Numpad8", "Numpad2"]

; True if `val` is already present in `arr` (AHK v2 arrays have no built-in
; membership test).
HasVal(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}

; True if `k` is one of MOTION_KEYS.
IsMotionKey(k) {
    global MOTION_KEYS
    return HasVal(MOTION_KEYS, k)
}

; True if any key in `active` is a motion key.
IsAxisActive(active) {
    for k in active
        if IsMotionKey(k)
            return true
    return false
}

; Fresh empty cluster-tracking state (see cluster comment above) - shared by
; both live recording (ProcessRecordingPoll, pushes every finalized cluster
; as a new leg) and single-leg key capture (ProcessLegCapturePoll, writes the
; first finalized cluster into one leg slot and stops).
;   members  - every key that's been part of the currently-open cluster, in
;              first-appeared order (becomes the leg's "+"-joined key string)
;   active   - the subset of `members` still physically held right now
;   accumMs  - total ms so far where a motion key (see MOTION_KEYS) has
;              actually been held during this cluster, not counting gaps
;              where only a bridging modifier (e.g. RShift) was down
;   runSince - A_TickCount when the current motion-key-held span began, or 0
;              if no motion key is currently held (accrual paused)
NewClusterState() {
    return Map("members", [], "active", [], "accumMs", 0, "runSince", 0)
}

; Builds a [keyStr, durationMs] leg from `members`/`durationMs`, or "" if
; there's nothing to build (no keys, or no actual held time).
BuildLeg(members, durationMs) {
    if (members.Length = 0 || durationMs <= 0)
        return ""
    keyStr := ""
    for i, k in members
        keyStr .= (i = 1 ? "" : "+") k
    return [keyStr, durationMs]
}

; Closes `state`'s current cluster into a [keyStr, durationMs] leg - using
; only its accrued motion-key-held time (accumMs, plus whatever span is
; still running) - and resets `state`, optionally seeding the replacement
; with `carryForward` (keys still physically held, e.g. a bridging modifier
; on a repeat-tap boundary) instead of leaving it empty. Returns "" if
; nothing was open, or if the accrued time was zero.
ClusterFinalize(state, now, carryForward := "") {
    if (carryForward = "")
        carryForward := []
    if (state["runSince"] != 0)
        state["accumMs"] += now - state["runSince"]
    leg := BuildLeg(state["members"], state["accumMs"])
    state["members"] := carryForward.Clone()
    state["active"] := carryForward.Clone()
    state["accumMs"] := 0
    state["runSince"] := IsAxisActive(carryForward) ? now : 0
    return leg
}

; Feeds one key transition (`down` = keyName's new physical state) into
; `state`. Returns the finalized [keyStr, durationMs] leg if this transition
; closed a cluster (held set emptied, or a repeat tap forced a boundary), or
; "" if the cluster is still open / nothing changed.
;
; Duration accrual (`accumMs`/`runSince`) only runs while a MOTION_KEYS key
; is actually held - a bridging modifier alone (e.g. RShift held between two
; NumpadLeft taps) pauses it instead of counting the gap as held time. An
; earlier version measured a cluster's duration as wall-clock time from
; cluster-open to close, which - since a still-held bridging modifier keeps
; the cluster open across a tap's release - silently folded the idle gap
; before the next tap into the leg's recorded duration. A slow multi-tap
; "RShift+NumpadLeft" nudge (hold RShift, tap NumpadLeft a few times with
; pauses in between while eyeballing the framing) then recorded several
; extra seconds of phantom held time, which replayed back as one long
; HoldKey and spun the camera through multiple full rotations instead of
; the small nudge that was actually performed.
ClusterFeed(state, keyName, down, now) {
    active := state["active"], members := state["members"]
    if (down) {
        if (active.Length = 0 && members.Length = 0) {
            ; Brand new cluster.
            state["members"] := [keyName]
            state["active"] := [keyName]
            state["accumMs"] := 0
            state["runSince"] := IsMotionKey(keyName) ? now : 0
            return ""
        }
        if HasVal(members, keyName) {
            ; Repeat tap of a key already seen in this cluster - close it now
            ; (using only accrued motion-key-held time), then immediately
            ; reopen a new one carrying forward whatever's still physically
            ; held (e.g. a bridging modifier) plus this key.
            leg := ClusterFinalize(state, now, active)
            newActive := state["active"]
            newActive.Push(keyName)
            state["active"] := newActive
            state["members"].Push(keyName)
            if (IsMotionKey(keyName) && state["runSince"] = 0)
                state["runSince"] := now
            return leg
        }
        ; New key joining the still-open cluster - this is the overlap merge.
        members.Push(keyName)
        active.Push(keyName)
        if (IsMotionKey(keyName) && state["runSince"] = 0)
            state["runSince"] := now
        return ""
    } else {
        newActive := []
        for k in active
            if (k != keyName)
                newActive.Push(k)
        state["active"] := newActive
        if (!IsAxisActive(newActive) && state["runSince"] != 0) {
            state["accumMs"] += now - state["runSince"]
            state["runSince"] := 0
        }
        if (newActive.Length = 0)
            return ClusterFinalize(state, now)
        return ""
    }
}

; Polls RECORD_KEYS for down/up transitions and feeds them into `clusterState`
; (see cluster comment above), pushing every finalized cluster as a new leg.
; `prevState` is owned by the caller (PollHotkeys) so it persists across
; calls without needing another global.
ProcessRecordingPoll(prevState, clusterState) {
    global IsRecording, RECORD_KEYS
    if !IsRecording
        return
    for keyName in RECORD_KEYS {
        down := GetKeyState(keyName, "P")
        prev := prevState.Has(keyName) ? prevState[keyName] : false
        if (down = prev) {
            continue
        }
        prevState[keyName] := down
        leg := ClusterFeed(clusterState, keyName, down, A_TickCount)
        if (leg != "") {
            CurrentCameraLegs().Push(leg)
            CalShowState()
        }
    }
}

; ##### Leg key capture #####
; Ctrl+Insert (see InsertLeg below) creates a blank leg, then waits for the
; very next physical key gesture in DCS to determine that leg's key+duration
; instead of leaving a hardcoded "w", 0ms to hand-edit. Reuses the same
; RECORD_KEYS cluster engine as live recording (see cluster comment above
; IsRecording) so a chorded gesture like "RShift+NumpadLeft" is captured as
; one leg here too - but unlike ProcessRecordingPoll this only ever captures
; a single cluster, then turns itself off.
global CapturingLeg := false
global CaptureLegIndex := 0
global LegCaptureKeyState := Map()
global LegCaptureClusterState := NewClusterState()

; Feeds RECORD_KEYS transitions into `clusterState` while CapturingLeg is
; true, writing the first finalized cluster directly into
; Cameras[CurrentCamera][CaptureLegIndex] and turning capture off.
ProcessLegCapturePoll(prevState, clusterState) {
    global CapturingLeg, CaptureLegIndex, RECORD_KEYS
    if !CapturingLeg
        return
    for keyName in RECORD_KEYS {
        down := GetKeyState(keyName, "P")
        prev := prevState.Has(keyName) ? prevState[keyName] : false
        if (down = prev) {
            continue
        }
        prevState[keyName] := down
        leg := ClusterFeed(clusterState, keyName, down, A_TickCount)
        if (leg != "") {
            CurrentCameraLegs()[CaptureLegIndex] := leg
            CapturingLeg := false
            SaveCameraData()
            CalShowState()
            return
        }
    }
}

; Opposite-direction key pairs recognized for vectorization (see
; VectorizeLegs below), keyed by AHK key name -> {axis, sign}. Two legs only
; ever get folded together if they share both `axis` (this map) AND the same
; set of non-axis modifier keys - e.g. a bare "a"/"d" run never merges with
; a "LShift+a"/"LShift+d" run, since holding Shift is assumed to be a
; deliberately different pan speed, not noise on the same motion.
global AXIS_KEYS := Map(
    "a", { axis: "leftright", sign: -1 }, "d", { axis: "leftright", sign: 1 },
    "w", { axis: "fwdback", sign: 1 }, "s", { axis: "fwdback", sign: -1 },
    "e", { axis: "updown", sign: 1 }, "q", { axis: "updown", sign: -1 },
    "NumpadLeft", { axis: "numlr", sign: -1 }, "NumpadRight", { axis: "numlr", sign: 1 },
    "Numpad4", { axis: "numlr", sign: -1 }, "Numpad6", { axis: "numlr", sign: 1 },
    "Numpad8", { axis: "numud", sign: 1 }, "Numpad2", { axis: "numud", sign: -1 }
)

; Returns {axis, sign, axisKey, mods} describing `keyStr` (e.g.
; "NumpadLeft+RShift") if it contains exactly one key recognized in
; AXIS_KEYS, or "" if it doesn't (a modifier-only chord, or a key this
; script has no opposite for - those still get merged by VectorizeLegs when
; their modifiers are compatible, see ModsCompatible). `mods` is every other
; component as an array of tokens (not joined), so two legs' modifier sets
; can be compared with ModsCompatible/UnionMods instead of requiring an exact
; string match. A chord with more than one axis key (e.g. a diagonal "a+w")
; just keeps whichever key StrSplit visits last - not expected from DCS's
; single-axis camera keys, so not worth handling.
AxisInfoOf(keyStr) {
    global AXIS_KEYS
    axisKey := "", mods := []
    for c in StrSplit(keyStr, "+") {
        if AXIS_KEYS.Has(c)
            axisKey := c
        else
            mods.Push(c)
    }
    if (axisKey = "")
        return ""
    return { axis: AXIS_KEYS[axisKey].axis, sign: AXIS_KEYS[axisKey].sign, axisKey: axisKey, mods: mods }
}

; True if every token in `x` also appears in `y`, i.e. `x` is a subset of `y`.
IsSubset(x, y) {
    for t in x
        if !HasVal(y, t)
            return false
    return true
}

; True if `a` and `b` (modifier-token arrays) are compatible: one is a subset
; of the other. Treats e.g. [] and ["RShift"] as compatible - an established
; modifier just hasn't shown up on this particular leg - and ["RShift"] and
; ["RShift"] as compatible, but ["RShift"] and ["LShift"] as NOT compatible,
; since a different modifier is a deliberate different combo rather than
; polling noise on the same held key.
ModsCompatible(a, b) {
    return IsSubset(a, b) || IsSubset(b, a)
}

; Union of two modifier-token arrays, no duplicates - grows a run's known
; modifier set as more of it is observed across legs.
UnionMods(a, b) {
    result := []
    for t in a
        result.Push(t)
    for t in b
        if !HasVal(result, t)
            result.Push(t)
    return result
}

; Joins modifier tokens back into a "+"-separated string ("" if none).
JoinMods(tokens) {
    s := ""
    for i, t in tokens
        s .= (i = 1 ? "" : "+") t
    return s
}

; Collapses a raw recorded leg list down to net motion per contiguous run of
; same-axis legs, so hand-flown trial-and-error (nudge left, overshoot,
; correct right, nudge left again, ...) plays back as the single net leg it
; actually amounts to instead of every individual correction - e.g. 3
; separate "a" presses followed by 2 "d" presses collapse into one net "a"
; leg (sum of the a's minus the d's), and a run that cancels out exactly is
; dropped entirely. Legs with no recognized axis key (AxisInfoOf returns "")
; aren't vectorized against an axis, but consecutive identical ones still get
; summed into one, same as before.
;
; A run also absorbs any interleaved modifier-only legs (e.g. bare "RShift")
; and tolerates the axis legs' own modifier set changing leg-to-leg (e.g.
; "NumpadLeft" then "RShift+NumpadLeft"), as long as each new leg's modifiers
; are compatible with what's been seen so far in the run (see
; ModsCompatible). This is needed because polling a physically-held modifier
; alongside a repeatedly-tapped axis key is noisy: RShift held throughout a
; burst of NumpadLeft taps reads back as RShift/NumpadLeft/RShift+NumpadLeft
; alternating almost at random even though the user never released RShift -
; without this, one continuous "hold RShift, tap NumpadLeft" gesture
; fragmented into dozens of tiny legs instead of the single
; "RShift+NumpadLeft" leg it actually is (see Camera-03's recorded data
; before this fix). A genuinely different modifier (e.g. bare "LShift"
; showing up mid-run) is NOT compatible with an established "RShift" set, so
; it still correctly breaks the run instead of getting absorbed - a run
; still never crosses a deliberate change of axis or modifier.
VectorizeLegs(legs) {
    result := []
    i := 1
    n := legs.Length
    while (i <= n) {
        info := AxisInfoOf(legs[i][1])
        if (info = "") {
            sumMs := legs[i][2]
            j := i + 1
            while (j <= n && legs[j][1] = legs[i][1]) {
                sumMs += legs[j][2]
                j += 1
            }
            result.Push([legs[i][1], sumMs])
            i := j
            continue
        }
        net := info.sign * legs[i][2]
        mods := info.mods
        posKey := info.sign > 0 ? info.axisKey : "", posMods := info.sign > 0 ? info.mods : []
        negKey := info.sign < 0 ? info.axisKey : "", negMods := info.sign < 0 ? info.mods : []
        j := i + 1
        while (j <= n) {
            jInfo := AxisInfoOf(legs[j][1])
            if (jInfo != "") {
                if (jInfo.axis != info.axis || !ModsCompatible(jInfo.mods, mods))
                    break
                mods := UnionMods(mods, jInfo.mods)
                net += jInfo.sign * legs[j][2]
                if (jInfo.sign > 0)
                    posKey := jInfo.axisKey, posMods := jInfo.mods
                else
                    negKey := jInfo.axisKey, negMods := jInfo.mods
                j += 1
                continue
            }
            ; Pure modifier-only leg (no axis key) - absorb it as noise if its
            ; modifiers are compatible with what this run has seen so far.
            ; Holding a bare modifier alone doesn't pan the camera, so its
            ; time contributes no net motion, but absorbing it keeps the run
            ; open instead of splitting it into a separate leg.
            legMods := StrSplit(legs[j][1], "+")
            if !ModsCompatible(legMods, mods)
                break
            mods := UnionMods(mods, legMods)
            j += 1
        }
        if (net != 0) {
            legMods := net > 0 ? posMods : negMods
            baseKey := net > 0 ? posKey : negKey
            modStr := JoinMods(legMods)
            result.Push([modStr != "" ? modStr "+" baseKey : baseKey, Abs(net)])
        }
        i := j
    }
    return result
}

; Starts recording into the current camera (wiping its existing legs first)
; or, if already recording, stops and collapses the raw legs down to net
; motion (see VectorizeLegs) - use Ctrl+Shift+Enter afterward to see the
; result as code.
; `prevState` is PollHotkeys' RECORD_KEYS state map and `clusterState` is its
; cluster-tracking state (see NewClusterState) - seeding prevState here with
; whatever's physically held right now means a modifier already down when
; recording starts (nothing here needs one today, but future legs might)
; doesn't get misread as a fresh key-down on the next poll.
ToggleRecording(prevState, clusterState) {
    global IsRecording, Cameras, CurrentCamera, CurrentLeg, RECORD_KEYS
    if (IsRecording) {
        ; A camera key still held when recording stops would otherwise lose
        ; whatever's been accumulated on it since its last transition -
        ; close it out as a final leg first, same as any other boundary.
        leg := ClusterFinalize(clusterState, A_TickCount)
        if (leg != "")
            CurrentCameraLegs().Push(leg)
        IsRecording := false
        Cameras[CurrentCamera] := VectorizeLegs(Cameras[CurrentCamera])
        SaveCameraData()
        CalShowState()
    } else {
        Cameras[CurrentCamera] := []
        CurrentLeg := 1
        clusterState["members"] := [], clusterState["active"] := [], clusterState["accumMs"] := 0, clusterState["runSince"] := 0
        prevState.Clear()
        for keyName in RECORD_KEYS
            prevState[keyName] := GetKeyState(keyName, "P")
        IsRecording := true
        CalShowState()
    }
}

; Right-pads `str` with spaces to `len` characters (never truncates).
Pad(str, len) {
    str := String(str)
    n := len - StrLen(str)
    return n > 0 ? str SubStr("                                                  ", 1, n) : str
}

; Estimates `text`'s widest line in pixels (rough - char-count based, tuned
; for Consolas 10pt) and returns the x that centers a HUD that wide
; horizontally on the primary monitor.
CenterHudX(text) {
    return Max(0, (A_ScreenWidth - HudLineWidth(text)) // 2)
}

; Rough pixel-width estimate for `text`'s widest line, matching the estimate
; CenterHudX uses, so callers can position a second HUD relative to one
; already placed with CenterHudX.
HudLineWidth(text) {
    widest := 0
    for line in StrSplit(text, "`n")
        widest := Max(widest, StrLen(line))
    return widest * 7 + 24
}

; Returns the current camera's leg list, creating an empty one if the
; camera slot hasn't been defined yet.
CurrentCameraLegs() {
    global Cameras, CurrentCamera
    if !Cameras.Has(CurrentCamera)
        Cameras[CurrentCamera] := []
    return Cameras[CurrentCamera]
}

; Status HUD (StatusHud) - stays on screen permanently, pinned top-center,
; and is only ever replaced by the next CalShowState() call, never
; auto-cleared. Leg-buffer digit entry uses LegHud so it doesn't fight with
; this one, and the full help screen uses HelpHud; StateBoxBottomY tracks
; where LegHud should sit so it doesn't overlap this (variable-height) box.
;
; Two-column layout: the left column always lists all MAX_CAMERAS camera
; slots (">" marks the selected one); the right column lists the SELECTED
; camera's legs, row-for-row from the top (">" marks the selected leg) -
; rows beyond that camera's leg count are left blank on the right. The two
; columns are otherwise unrelated; they just share row space to stay compact.
CalShowState() {
    global CurrentCamera, CurrentLeg, StateBoxBottomY, StateBoxRightX, IsRecording, CameraNames, MAX_CAMERAS
    global CapturingLeg, CaptureLegIndex, StatusHud, TourActive
    legs := CurrentCameraLegs()
    sep := ""
    Loop 68
        sep .= "-"

    camLabel := "Camera-" Format("{:02}", CurrentCamera)
    name := CameraNames.Has(CurrentCamera) ? CameraNames[CurrentCamera] : ""
    nameStr := name != "" ? ' "' name '"' : ""
    recStr := IsRecording ? "  [RECORDING - Ctrl+Shift+R to stop]" : ""
    tourStr := TourActive ? "  [TOUR - Ctrl+Shift+A to stop]" : ""
    totalStr := "Total " MAX_CAMERAS " Cameras"
    header := Pad(camLabel nameStr recStr tourStr, 60) totalStr

    body := ""
    rows := Max(MAX_CAMERAS, legs.Length)
    Loop rows {
        i := A_Index
        camCell := ""
        if (i <= MAX_CAMERAS) {
            camMarker := (i = CurrentCamera) ? "> " : "  "
            camCell := camMarker "Camera-" Format("{:02}", i)
        }
        legCell := ""
        if (i <= legs.Length) {
            leg := legs[i]
            legMarker := (i = CurrentLeg) ? "> " : "  "
            if (CapturingLeg && i = CaptureLegIndex)
                legCell := legMarker Pad("Leg-" Format("{:02}", i), 8) "(press a key in DCS...)"
            else
                legCell := legMarker Pad("Leg-" Format("{:02}", i), 8) Pad(leg[2] "ms", 8) leg[1]
        }
        body .= Pad(camCell, 12) "| " legCell "`n"
    }

    text := header "`n" sep "`n" body sep "`n" "Ctrl + Shift + H --> Help"
    boxX := CenterHudX(text)
    dims := ShowHud(StatusHud, text, boxX, 10)
    StateBoxBottomY := 10 + dims.h
    StateBoxRightX := boxX + dims.w
}

; Switching cameras disarms an in-progress leg key capture - the placeholder
; leg it was armed for belongs to the camera being switched away from.
SelectCamera(camNum) {
    global CurrentCamera, CurrentLeg, CapturingLeg
    CurrentCamera := camNum
    CurrentLeg := 1
    CapturingLeg := false
    CalShowState()
}

SelectAndPlayCamera(camNum) {
    SelectCamera(camNum)
    PlayCamera(camNum)
}

; Shift+Left/Right - moves the selection to the previous/next camera slot
; (clamped to 1..MAX_CAMERAS) without playing it, so you can browse cameras
; while tuning without triggering DCS playback each time.
AdjustCamera(delta) {
    global CurrentCamera, MAX_CAMERAS
    newCam := CurrentCamera + delta
    if (newCam < 1 || newCam > MAX_CAMERAS)
        return
    SelectCamera(newCam)
}

; Ctrl+Left/Right - moves the selected leg within the current camera
; (clamped to 1..legs.Length; no-op if the camera has no legs yet).
AdjustLeg(delta) {
    global CurrentLeg
    legs := CurrentCameraLegs()
    if (legs.Length = 0)
        return
    newLeg := CurrentLeg + delta
    if (newLeg < 1 || newLeg > legs.Length)
        return
    CurrentLeg := newLeg
    CalShowState()
}

CalAdjustDuration(delta) {
    global CurrentLeg
    legs := CurrentCameraLegs()
    if (legs.Length = 0)
        return
    leg := legs[CurrentLeg]
    leg[2] := Max(0, leg[2] + delta)
    CalShowState()
}

; Ctrl+Insert - inserts a new blank leg (default key "w", 0ms, same fallback
; as before) right after the selected leg, selects it, and arms leg key
; capture (see "Leg key capture" above) so the very next physical key gesture
; pressed in DCS overwrites that leg's key+duration. The "w", 0ms default is
; kept (rather than an empty key) so an aborted/uncaptured leg - e.g. camera
; switched away mid-capture - still plays back as a harmless no-op instead of
; a blank key string crashing HoldKey. Inserting at the start (CurrentLeg =
; 0, i.e. an empty camera) is handled the same way since InsertAt(1, ...) on
; an empty array just appends. No-ops the arming (but still inserts) while a
; live recording is in progress, since RECORD_KEYS polling is already
; feeding that recording's cluster instead.
InsertLeg() {
    global CurrentLeg, IsRecording, CapturingLeg, CaptureLegIndex
    global LegCaptureKeyState, LegCaptureClusterState, RECORD_KEYS
    legs := CurrentCameraLegs()
    insertAt := legs.Length = 0 ? 1 : CurrentLeg + 1
    legs.InsertAt(insertAt, ["w", 0])
    CurrentLeg := insertAt
    if !IsRecording {
        CaptureLegIndex := insertAt
        LegCaptureKeyState := Map()
        for keyName in RECORD_KEYS
            LegCaptureKeyState[keyName] := GetKeyState(keyName, "P")
        LegCaptureClusterState := NewClusterState()
        CapturingLeg := true
    }
    SaveCameraData()
    CalShowState()
}

; Ctrl+Delete - removes the selected leg. No-op if the camera has no legs.
; CurrentLeg is clamped back into range afterward (e.g. deleting the last
; leg selects the new last leg instead of pointing past the end). Cancels an
; in-progress leg key capture unconditionally - RemoveAt can shift
; CaptureLegIndex out from under an armed capture even when the deleted leg
; isn't the one being captured, so it's simplest to just disarm.
DeleteLeg() {
    global CurrentLeg, CapturingLeg
    legs := CurrentCameraLegs()
    if (legs.Length = 0)
        return
    legs.RemoveAt(CurrentLeg)
    CurrentLeg := Max(1, Min(CurrentLeg, legs.Length))
    CapturingLeg := false
    SaveCameraData()
    CalShowState()
}

; Ctrl+Shift+N - prompts for a display name for the selected camera. An
; empty/cancelled entry clears any existing name rather than leaving stale
; text in CameraNames.
RenameCamera() {
    global CurrentCamera, CameraNames
    current := CameraNames.Has(CurrentCamera) ? CameraNames[CurrentCamera] : ""
    result := InputBox("Enter a display name for Camera-" Format("{:02}", CurrentCamera), "Rename Camera", "w300 h120", current)
    if (result.Result = "OK") {
        name := Trim(result.Value)
        if (name = "")
            CameraNames.Delete(CurrentCamera)
        else
            CameraNames[CurrentCamera] := name
        SaveCameraData()
    }
    CalShowState()
}

; Alt+Shift+Delete - clears the selected camera's legs and name in place.
; No other camera slots are renumbered/shifted; the cleared slot just goes
; back to being an empty camera at the same position.
DeleteCamera() {
    global CurrentCamera, CurrentLeg, Cameras, CameraNames, CapturingLeg, StateBoxBottomY, LegHud
    Cameras[CurrentCamera] := []
    if CameraNames.Has(CurrentCamera)
        CameraNames.Delete(CurrentCamera)
    CurrentLeg := 1
    CapturingLeg := false
    SaveCameraData()
    text := "Camera-" Format("{:02}", CurrentCamera) " cleared"
    ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
    SetTimer(() => HideHud(LegHud), -1500)
    CalShowState()
}

; Alt+Shift+Insert - jumps selection to the next empty camera slot (no
; legs recorded yet) so a new camera can be recorded/tuned into it, without
; renumbering or shifting any other camera. Searches forward from just after
; the current slot, wrapping around, so repeated presses cycle through every
; empty slot in order.
InsertCamera() {
    global CurrentCamera, MAX_CAMERAS, Cameras, StateBoxBottomY, LegHud
    Loop MAX_CAMERAS {
        camNum := Mod(CurrentCamera + A_Index - 1, MAX_CAMERAS) + 1
        if !Cameras.Has(camNum) || Cameras[camNum].Length = 0 {
            SelectCamera(camNum)
            text := "New camera in Camera-" Format("{:02}", camNum)
            ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
            SetTimer(() => HideHud(LegHud), -1500)
            return
        }
    }
    text := "No empty camera slots"
    ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
    SetTimer(() => HideHud(LegHud), -1500)
}

CalShowSummary() {
    global CurrentCamera
    legs := CurrentCameraLegs()
    lines := "Camera " CurrentCamera ":`n"
    for leg in legs
        lines .= 'HoldKey("' leg[1] '", ' leg[2] ')`n'
    MsgBox(lines, "Calibrated durations", "T10")
}

; Appends one typed digit to the pending leg-number buffer, committing once
; two digits have been entered (leg numbers only ever need two digits here).
AppendLegDigit(d) {
    global LegBuffer, StateBoxBottomY, LegHud
    LegBuffer .= d
    text := "Leg select: " LegBuffer
    ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
    SetTimer(() => HideHud(LegHud), -1500)
    if StrLen(LegBuffer) >= 2
        CommitLegBuffer()
}

; Commits the pending leg-number buffer (called on 2nd digit, or on Ctrl
; release so a single-digit selection like Ctrl+3 still takes effect).
CommitLegBuffer() {
    global LegBuffer, CurrentLeg, StateBoxBottomY, LegHud
    if (LegBuffer = "")
        return
    n := Integer(LegBuffer)
    LegBuffer := ""
    legs := CurrentCameraLegs()
    if (n >= 1 && n <= legs.Length) {
        CurrentLeg := n
        CalShowState()
    } else {
        text := "No leg " n " (camera has " legs.Length ")"
        ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
        SetTimer(() => HideHud(LegHud), -1500)
    }
}

; Captures the full virtual screen to a BMP via plain GDI (BitBlt + GetDIBits
; + a hand-written file header) - deliberately avoids GDI+, whose
; Startup/Shutdown token pairing was crashing with an access violation here.
CaptureScreenshot(filePath) {
    x := SysGet(76)  ; SM_XVIRTUALSCREEN
    y := SysGet(77)  ; SM_YVIRTUALSCREEN
    w := SysGet(78)  ; SM_CXVIRTUALSCREEN
    h := SysGet(79)  ; SM_CYVIRTUALSCREEN

    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hBitmap := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")
    DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h,
        "Ptr", hdcScreen, "Int", x, "Int", y, "UInt", 0x00CC0020) ; SRCCOPY
    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld)

    ; BITMAPINFOHEADER, 32bpp BI_RGB, negative height = top-down DIB (so rows
    ; come out in normal top-to-bottom order without a manual flip).
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)

    imgSize := w * 4 * h
    pixels := Buffer(imgSize, 0)
    DllCall("GetDIBits", "Ptr", hdcMem, "Ptr", hBitmap, "UInt", 0, "UInt", h,
        "Ptr", pixels, "Ptr", bi, "UInt", 0) ; DIB_RGB_COLORS

    fh := Buffer(14, 0)
    NumPut("UShort", 0x4D42, fh, 0) ; "BM"
    NumPut("UInt", 14 + 40 + imgSize, fh, 2)
    NumPut("UInt", 14 + 40, fh, 10) ; pixel data offset

    f := FileOpen(filePath, "w")
    f.RawWrite(fh, 14)
    f.RawWrite(bi, 40)
    f.RawWrite(pixels, imgSize)
    f.Close()

    DllCall("DeleteObject", "Ptr", hBitmap)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
}

; Sweeps the currently selected leg across 5 durations (25/50/75/100/125% of
; its current calibrated value), replaying every prior leg from a fresh
; Numpad5 reset each time so each shot starts from the same origin, and
; screenshots after each so distance-per-ms can be eyeballed across the
; sequence to check for acceleration/frame-time-dependent panning. Uses
; HoldKey throughout, matching PlayCamera's default (continuous hold), so
; leg durations get tuned against the same mechanism that actually plays
; them back.
RunAccelTest() {
    global CurrentCamera, CurrentLeg, StatusHud, LegHud
    legs := CurrentCameraLegs()
    if (legs.Length = 0) {
        ShowHud(LegHud, "No legs to test", 20, 50)
        SetTimer(() => HideHud(LegHud), -1500)
        return
    }
    if !FocusDCS()
        return
    leg := legs[CurrentLeg]
    key := leg[1]
    baseDur := leg[2]
    fractions := [0.25, 0.5, 0.75, 1.0, 1.25]
    outDir := A_ScriptDir "\AccelTest\" FormatTime(, "yyyyMMdd_HHmmss")
    DirExist(outDir) || DirCreate(outDir)
    for i, f in fractions {
        testDur := Max(20, Round(baseDur * f))
        ShowHud(StatusHud, "Accel test " i "/" fractions.Length ": leg " CurrentLeg " (" key ") @ " testDur "ms", 20, 20)
        Sleep(50)
        HoldKey("Numpad5", 50)
        loop CurrentLeg - 1
            HoldKey(legs[A_Index][1], legs[A_Index][2])
        HoldKey(key, testDur)
        Sleep(300) ; let the view settle before capturing
        file := outDir "\" String(i) "_" testDur "ms.bmp"
        CaptureScreenshot(file)
    }
    ShowHud(StatusHud, "Accel test done - " fractions.Length " screenshots in " outDir, 20, 20)
    SetTimer(() => CalShowState(), -3000)
}

; Runs the current camera 5 times back-to-back (with precision fix A already
; applied process-wide) and screenshots after each run, to directly test
; run-to-run consistency rather than the within-leg duration curve the
; accel test covers. useTapped switches every leg to HoldKeyTapped
; (precision fix B) so the two modes' folders can be eyeballed side by side.
RunRepeatTest(useTapped) {
    global CurrentCamera, Cameras, StatusHud, LegHud
    if !Cameras.Has(CurrentCamera) || Cameras[CurrentCamera].Length = 0 {
        ShowHud(LegHud, "No legs to test", 20, 50)
        SetTimer(() => HideHud(LegHud), -1500)
        return
    }
    runs := 5
    label := useTapped ? "tapped" : "hold"
    outDir := A_ScriptDir "\RepeatTest\" FormatTime(, "yyyyMMdd_HHmmss") "_" label
    DirExist(outDir) || DirCreate(outDir)
    Loop runs {
        ShowHud(StatusHud, "Repeat test (" label ") " A_Index "/" runs, 20, 20)
        PlayCamera(CurrentCamera, useTapped)
        Sleep(300) ; let the view settle before capturing
        CaptureScreenshot(outDir "\" A_Index ".bmp")
    }
    ShowHud(StatusHud, "Repeat test done - " runs " screenshots in " outDir, 20, 20)
    SetTimer(() => CalShowState(), -3000)
}

; ##### Help screen #####
; Ctrl+Shift+H toggles a full shortkey reference in the help HUD (separate
; from the always-on status box), so it can be pulled up and dismissed on
; demand without disturbing the status display underneath it.
global HelpVisible := false

ToggleHelp() {
    global HelpVisible, HelpHud
    HelpVisible := !HelpVisible
    if (HelpVisible)
        ShowHelp()
    else
        HideHud(HelpHud)
}

ShowHelp() {
    global StateBoxRightX, HelpHud
    text := "
    (
Help / Shortkeys / Commands
--------------------------------------------------------------------
Wolf Cinematics allows for recording, tuning, and editing the DCS F4
view into multiple pre-set camera positions.
--------------------------------------------------------------------
Positioning (moving the camera)
 w                     --> camera moves forward
 s                     --> camera moves back
 a                     --> camera moves left
 d                     --> camera moves right
 e                     --> camera moves up
 q                     --> camera moves down
 NumPad5               --> resets camera
 Ctrl + <key>          --> move slower (ex: Ctrl+w = forward slow)

Recording
 Ctrl + Shift + R      --> start/stop recording into selected camera

Camera
 Alt + "Number"        --> plays and selects Camera-"Number"
 Shift + Left/Right    --> select previous/next camera (no play)
 Ctrl + Shift + N      --> type camera name / rename camera
 Alt + Shift + Insert  --> jump to next empty camera slot
 Alt + Shift + Delete  --> clear selected camera's legs/name in place
 Ctrl + Shift + A      --> start/stop random camera tour (loops until
                            pressed again)

Editing
 Ctrl + "Number"          --> select Leg-"Number" (ex: Ctrl+3 = Leg-03)
 Ctrl + Right             --> select next Leg
 Ctrl + Left              --> select previous Leg
 Ctrl + Up/Down (tap)     --> +/-1ms  (precision step)
 Ctrl + Up/Down (hold)    --> fast +/-ms while held
 Ctrl + Shift + Up/Down   --> increases/decreases super fast
 Ctrl + Insert            --> insert new leg, capture next key you press
 Ctrl + Delete            --> delete selected leg
 Ctrl + Shift + Enter     --> dump camera's legs as code
 Ctrl + Shift + T         --> accel test (sweep leg across durations)
 Ctrl + Shift + B         --> repeat test, continuous holds x5
 Ctrl + Shift + G         --> repeat test, discrete taps x5
--------------------------------------------------------------------
 Ctrl + Shift + H      --> close Help
    )"
    ShowHud(HelpHud, text, StateBoxRightX + 20, 10)
}

; ##### Camera tour (automatic random playback loop) #####
; Ctrl+Shift+A starts/stops a loop that plays every camera slot with at
; least one leg, one at a time, in a freshly-shuffled random order each lap -
; the same effect as an operator randomly pressing Alt+1..Alt+0 - pausing
; TOUR_PAUSE_MS after each camera finishes positioning before moving to the
; next, and repeats indefinitely until Ctrl+Shift+A is pressed again.
;
; Runs on its own SetTimer (TourTick) rather than inside PollHotkeys: the
; PlayCamera() call it drives blocks on Sleep() for the duration of the
; camera's positioning, and AHK's Sleep() yields to *other* timers while it
; waits - keeping the tour's blocking playback in a separate timer callback
; from PollHotkeys is what lets Ctrl+Shift+A still get polled (and TourActive
; flipped off) while a camera is mid-move, instead of one long PollHotkeys
; call starving its own hotkey polling for the whole tour.
global TourActive := false
global TourOrder := []
global TourIndex := 0
global TourNextTime := 0
global TOUR_PAUSE_MS := 2000

; Camera numbers (in Cameras' iteration order) that have at least one leg -
; slots with no legs yet are skipped, same as PlayCamera's own no-op guard.
CamerasWithLegs() {
    global Cameras
    out := []
    for camNum, legs in Cameras
        if (legs.Length > 0)
            out.Push(camNum)
    return out
}

; Fisher-Yates shuffle - returns a new shuffled copy of `arr`, leaving `arr`
; itself untouched.
ShuffleArray(arr) {
    out := arr.Clone()
    Loop out.Length - 1 {
        i := out.Length - A_Index + 1
        j := Random(1, i)
        if (i != j) {
            tmp := out[i]
            out[i] := out[j]
            out[j] := tmp
        }
    }
    return out
}

ToggleCameraTour() {
    global TourActive, TourOrder, TourIndex, LegHud, StateBoxBottomY
    if (TourActive) {
        StopCameraTour()
        return
    }
    avail := CamerasWithLegs()
    if (avail.Length = 0) {
        text := "No cameras with legs to tour"
        ShowHud(LegHud, text, CenterHudX(text), StateBoxBottomY)
        SetTimer(() => HideHud(LegHud), -1500)
        return
    }
    TourOrder := ShuffleArray(avail)
    TourIndex := 1
    TourActive := true
    PlayTourCamera()
}

StopCameraTour() {
    global TourActive
    TourActive := false
    CalShowState()
}

; Selects+plays the tour's current camera (updating CurrentCamera/the status
; HUD like a manual Alt+digit press would) and, if the tour is still active
; once PlayCamera returns (it may have been stopped mid-positioning), arms
; TourNextTime for TourTick to advance after TOUR_PAUSE_MS.
PlayTourCamera() {
    global TourActive, TourOrder, TourIndex, TourNextTime, TOUR_PAUSE_MS
    SelectCamera(TourOrder[TourIndex])
    PlayCamera(TourOrder[TourIndex])
    if (!TourActive)
        return
    TourNextTime := A_TickCount + TOUR_PAUSE_MS
}

; Polled separately from PollHotkeys (see comment above) so a camera's
; blocking positioning move never delays hotkey polling. Advances to the
; next camera in TourOrder once TOUR_PAUSE_MS has elapsed since the last one
; finished positioning; reshuffles a fresh order once a full lap completes.
TourTick() {
    global TourActive, TourOrder, TourIndex, TourNextTime
    if (!TourActive || A_TickCount < TourNextTime)
        return
    TourIndex += 1
    if (TourIndex > TourOrder.Length) {
        avail := CamerasWithLegs()
        if (avail.Length = 0) {
            StopCameraTour()
            return
        }
        TourOrder := ShuffleArray(avail)
        TourIndex := 1
    }
    PlayTourCamera()
}
SetTimer(TourTick, 200)

; ##### Hotkey polling #####
; Confirmed by testing: Hotkey()-registered combos (RegisterHotKey / the
; keyboard hook) only fired while DCS was NOT the focused window. DCS
; captures the keyboard exclusively while it has focus, which blocks
; Windows from delivering hotkey messages to any other process - no error,
; they just silently never arrive. Polling GetKeyState(..., "P") instead
; reads the physical key-state table the driver maintains directly, which
; isn't gated by DCS's message routing, so it keeps working while focused.
PollHotkeys() {
    static digitKeys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static prevAltDigit := Map(), prevCtrlDigit := Map()
    static prevCtrl := false, prevExit := false
    static prevUp := false, prevDown := false
    static prevSuperUp := false, prevSuperDown := false
    static prevLegLeft := false, prevLegRight := false
    static prevCamLeft := false, prevCamRight := false
    static prevSummary := false
    static prevAccelTest := false
    static prevRepeatHold := false, prevRepeatTap := false
    static prevRecord := false, prevRename := false, prevHelp := false, prevTour := false
    static prevInsertLeg := false, prevDeleteLeg := false
    static prevInsertCamera := false, prevDeleteCamera := false
    static recordClusterState := NewClusterState()
    global LegCaptureKeyState, LegCaptureClusterState

    ; Ctrl+Up/Down duration-nudge timing: a tap (single press) always fires
    ; one ±1ms precision step immediately. If the key is still held past
    ; HOLD_THRESHOLD_MS, it switches to firing ±REPEAT_STEP_MS every
    ; REPEAT_INTERVAL_MS until released - the "hold to go fast" behavior.
    static HOLD_THRESHOLD_MS := 350, REPEAT_INTERVAL_MS := 30, REPEAT_STEP_MS := 5
    static upHeldSince := 0, upRepeating := false, upLastRepeat := 0
    static dnHeldSince := 0, dnRepeating := false, dnLastRepeat := 0
    ; Ctrl+Shift+Up/Down: same tap/hold shape as Ctrl+Up/Down above, but with
    ; a much bigger step and shorter interval for coarse "super fast" edits.
    static SUPER_STEP_MS := 25, SUPER_REPEAT_INTERVAL_MS := 20, SUPER_REPEAT_STEP_MS := 25
    static supUpHeldSince := 0, supUpRepeating := false, supUpLastRepeat := 0
    static supDnHeldSince := 0, supDnRepeating := false, supDnLastRepeat := 0
    static recordKeyState := Map()

    ProcessRecordingPoll(recordKeyState, recordClusterState)
    ProcessLegCapturePoll(LegCaptureKeyState, LegCaptureClusterState)

    alt := GetKeyState("Alt", "P")
    ctrl := GetKeyState("Ctrl", "P")
    shift := GetKeyState("Shift", "P")

    ; Alt+1..Alt+0 -> select camera (index 1-10, "0" is camera 10) and play it
    for i, dk in digitKeys {
        down := alt && !ctrl && GetKeyState(dk, "P")
        prev := prevAltDigit.Has(dk) ? prevAltDigit[dk] : false
        if (down && !prev)
            SelectAndPlayCamera(i)
        prevAltDigit[dk] := down
    }

    ; Ctrl+<digit> -> feed the leg-number buffer (two digits, e.g. 1 then 2 = leg 12)
    for i, dk in digitKeys {
        down := ctrl && !alt && GetKeyState(dk, "P")
        prev := prevCtrlDigit.Has(dk) ? prevCtrlDigit[dk] : false
        if (down && !prev)
            AppendLegDigit(dk)
        prevCtrlDigit[dk] := down
    }
    if (!ctrl && prevCtrl)
        CommitLegBuffer()
    prevCtrl := ctrl

    ; Ctrl+Up (tap = ±1ms, hold = fast ±REPEAT_STEP_MS every REPEAT_INTERVAL_MS)
    upKey := ctrl && !shift && !alt && GetKeyState("Up", "P")
    if (upKey && !prevUp) {
        CalAdjustDuration(1)
        upHeldSince := A_TickCount
        upRepeating := false
    } else if (upKey && prevUp) {
        if (!upRepeating && A_TickCount - upHeldSince >= HOLD_THRESHOLD_MS) {
            upRepeating := true
            upLastRepeat := A_TickCount
        }
        if (upRepeating && A_TickCount - upLastRepeat >= REPEAT_INTERVAL_MS) {
            CalAdjustDuration(REPEAT_STEP_MS)
            upLastRepeat := A_TickCount
        }
    } else if (!upKey) {
        upRepeating := false
    }
    prevUp := upKey

    ; Ctrl+Down (tap = -1ms, hold = fast -REPEAT_STEP_MS every REPEAT_INTERVAL_MS)
    downKey := ctrl && !shift && !alt && GetKeyState("Down", "P")
    if (downKey && !prevDown) {
        CalAdjustDuration(-1)
        dnHeldSince := A_TickCount
        dnRepeating := false
    } else if (downKey && prevDown) {
        if (!dnRepeating && A_TickCount - dnHeldSince >= HOLD_THRESHOLD_MS) {
            dnRepeating := true
            dnLastRepeat := A_TickCount
        }
        if (dnRepeating && A_TickCount - dnLastRepeat >= REPEAT_INTERVAL_MS) {
            CalAdjustDuration(-REPEAT_STEP_MS)
            dnLastRepeat := A_TickCount
        }
    } else if (!downKey) {
        dnRepeating := false
    }
    prevDown := downKey

    ; Ctrl+Shift+Up (tap = +SUPER_STEP_MS, hold = fast +SUPER_REPEAT_STEP_MS
    ; every SUPER_REPEAT_INTERVAL_MS) - same shape as Ctrl+Up but coarse.
    superUpKey := ctrl && shift && !alt && GetKeyState("Up", "P")
    if (superUpKey && !prevSuperUp) {
        CalAdjustDuration(SUPER_STEP_MS)
        supUpHeldSince := A_TickCount
        supUpRepeating := false
    } else if (superUpKey && prevSuperUp) {
        if (!supUpRepeating && A_TickCount - supUpHeldSince >= HOLD_THRESHOLD_MS) {
            supUpRepeating := true
            supUpLastRepeat := A_TickCount
        }
        if (supUpRepeating && A_TickCount - supUpLastRepeat >= SUPER_REPEAT_INTERVAL_MS) {
            CalAdjustDuration(SUPER_REPEAT_STEP_MS)
            supUpLastRepeat := A_TickCount
        }
    } else if (!superUpKey) {
        supUpRepeating := false
    }
    prevSuperUp := superUpKey

    ; Ctrl+Shift+Down - same shape as above, decreasing.
    superDownKey := ctrl && shift && !alt && GetKeyState("Down", "P")
    if (superDownKey && !prevSuperDown) {
        CalAdjustDuration(-SUPER_STEP_MS)
        supDnHeldSince := A_TickCount
        supDnRepeating := false
    } else if (superDownKey && prevSuperDown) {
        if (!supDnRepeating && A_TickCount - supDnHeldSince >= HOLD_THRESHOLD_MS) {
            supDnRepeating := true
            supDnLastRepeat := A_TickCount
        }
        if (supDnRepeating && A_TickCount - supDnLastRepeat >= SUPER_REPEAT_INTERVAL_MS) {
            CalAdjustDuration(-SUPER_REPEAT_STEP_MS)
            supDnLastRepeat := A_TickCount
        }
    } else if (!superDownKey) {
        supDnRepeating := false
    }
    prevSuperDown := superDownKey

    ; Ctrl+Left/Right -> select previous/next leg within the current camera
    legLeft := ctrl && !alt && !shift && GetKeyState("Left", "P")
    if (legLeft && !prevLegLeft)
        AdjustLeg(-1)
    prevLegLeft := legLeft

    legRight := ctrl && !alt && !shift && GetKeyState("Right", "P")
    if (legRight && !prevLegRight)
        AdjustLeg(1)
    prevLegRight := legRight

    ; Ctrl+Insert -> insert a new blank leg after the selected one
    insertLegDown := ctrl && !alt && GetKeyState("Insert", "P")
    if (insertLegDown && !prevInsertLeg)
        InsertLeg()
    prevInsertLeg := insertLegDown

    ; Ctrl+Delete -> delete the selected leg
    deleteLegDown := ctrl && !alt && GetKeyState("Delete", "P")
    if (deleteLegDown && !prevDeleteLeg)
        DeleteLeg()
    prevDeleteLeg := deleteLegDown

    ; Alt+Shift+Insert -> jump to the next empty camera slot
    insertCameraDown := alt && shift && !ctrl && GetKeyState("Insert", "P")
    if (insertCameraDown && !prevInsertCamera)
        InsertCamera()
    prevInsertCamera := insertCameraDown

    ; Alt+Shift+Delete -> clear the selected camera's legs/name in place
    deleteCameraDown := alt && shift && !ctrl && GetKeyState("Delete", "P")
    if (deleteCameraDown && !prevDeleteCamera)
        DeleteCamera()
    prevDeleteCamera := deleteCameraDown

    ; Shift+Left/Right -> select previous/next camera (no auto-play)
    camLeft := shift && !ctrl && !alt && GetKeyState("Left", "P")
    if (camLeft && !prevCamLeft)
        AdjustCamera(-1)
    prevCamLeft := camLeft

    camRight := shift && !ctrl && !alt && GetKeyState("Right", "P")
    if (camRight && !prevCamRight)
        AdjustCamera(1)
    prevCamRight := camRight

    ; Ctrl+Shift+Enter -> dump the current camera's durations
    summaryDown := ctrl && shift && GetKeyState("Enter", "P")
    if (summaryDown && !prevSummary)
        CalShowSummary()
    prevSummary := summaryDown

    ; Ctrl+Shift+N -> type/change the selected camera's display name
    renameDown := ctrl && shift && !alt && GetKeyState("n", "P")
    if (renameDown && !prevRename)
        RenameCamera()
    prevRename := renameDown

    ; Ctrl+Shift+R -> start/stop live recording into the selected camera
    recordDown := ctrl && shift && !alt && GetKeyState("r", "P")
    if (recordDown && !prevRecord)
        ToggleRecording(recordKeyState, recordClusterState)
    prevRecord := recordDown

    ; Ctrl+Shift+T -> sweep the selected leg across 5 durations, screenshotting each
    accelTestDown := ctrl && shift && !alt && GetKeyState("t", "P")
    if (accelTestDown && !prevAccelTest)
        RunAccelTest()
    prevAccelTest := accelTestDown

    ; Ctrl+Shift+B -> repeat the current camera 5x with continuous holds, screenshotting each
    repeatHoldDown := ctrl && shift && !alt && GetKeyState("b", "P")
    if (repeatHoldDown && !prevRepeatHold)
        RunRepeatTest(false)
    prevRepeatHold := repeatHoldDown

    ; Ctrl+Shift+G -> same, but with discrete-tap legs instead of continuous holds
    repeatTapDown := ctrl && shift && !alt && GetKeyState("g", "P")
    if (repeatTapDown && !prevRepeatTap)
        RunRepeatTest(true)
    prevRepeatTap := repeatTapDown

    ; Ctrl+Shift+H -> toggle the full help/shortkey HUD
    helpDown := ctrl && shift && !alt && GetKeyState("h", "P")
    if (helpDown && !prevHelp)
        ToggleHelp()
    prevHelp := helpDown

    ; Ctrl+Shift+A -> start/stop the automatic random camera tour
    tourDown := ctrl && shift && !alt && GetKeyState("a", "P")
    if (tourDown && !prevTour)
        ToggleCameraTour()
    prevTour := tourDown

    ; Ctrl+Alt+F12 -> exit the script (F1-F4 are DCS view keys, avoid those)
    exitDown := ctrl && alt && GetKeyState("F12", "P")
    if (exitDown && !prevExit)
        ExitApp()
    prevExit := exitDown
}
SetTimer(PollHotkeys, 20)
CalShowState()

; Future cameras: add Cameras[2] := [["key", ms], ...], etc. - no new hotkey
; wiring needed, Alt+2 and the Ctrl+ leg-tuning combos already cover any slot.
