#Requires AutoHotkey v2.0
#SingleInstance Force
DetectHiddenWindows True

; =============================================================================
; USER SETTINGS (safe to edit)
; =============================================================================

; Process name of the browser you want to target.
; Examples: "chrome.exe", "firefox.exe", "brave.exe", "msedge.exe"
targetBrowserExe         := "msedge.exe"

; Main black bar that covers the browser's top chrome / tab strip.
enableBrowserTopOverlay  := true

; Extra black bar below the top bar when the window appears to be a YouTube tab.
enableYouTubeOverlay     := true

; Maximum number of browser windows this script will track at once.
; Increase if you often have many snapped browser windows open.
maxBrowserWindows        := 6

; Used to decide whether a window is "YouTube-like" and should get the extra overlay.
youtubeTitleRegex        := "i)\byoutube\b"

; -----------------------------------------------------------------------------
; FOLLOW MODE
; -----------------------------------------------------------------------------
; followMode = true  -> follow windows more freely
; followMode = false -> normal "snapped / maximized on primary monitor" behavior
followMode               := false

; Hotkey to toggle follow mode on/off.
followHotkey             := "^!f"            ; Ctrl+Alt+F toggles follow mode

; "multi-primary"  = follow all target browser windows on the primary monitor
; "single-anywhere" = follow only one browser window, even if it is not on primary
followModeBehavior       := "multi-primary"

; Fallback height for the top browser overlay in follow mode.
; If dynamic Chromium detection works, that detected height is used instead.
followTopOverlayH        := 81

; -----------------------------------------------------------------------------
; TASKBAR OVERLAY
; -----------------------------------------------------------------------------
; Transparency of the taskbar overlay (0 invisible, 255 opaque).
taskbarAlpha := 179

; Used when Windows reports an odd or unusable taskbar height.
fallbackTaskbarH := 63

; -----------------------------------------------------------------------------
; BROWSER TOP OVERLAY
; -----------------------------------------------------------------------------
; Transparency of the main browser top overlay.
topAlpha := 179

; Fallback height for maximized windows.
topOverlayHMax  := 72

; Fallback height for snapped windows.
topOverlayHSnap := 81

; -----------------------------------------------------------------------------
; YOUTUBE OVERLAY
; -----------------------------------------------------------------------------
; Transparency of the secondary overlay shown below the main top overlay.
ytAlpha := 179

; Height of the YouTube overlay bar.
ytOverlayH := 56

; Slight left/right inset so the YouTube bar does not always go fully edge-to-edge.
ytInsetLeft := 4
ytInsetRight := 4

; -----------------------------------------------------------------------------
; TIMING / DETECTION TUNING
; -----------------------------------------------------------------------------
; Main timer frequency in milliseconds.
; Lower = more responsive, but slightly more CPU usage.
pollMs := 100

; Tolerance used when checking whether another window is effectively fullscreen.
fsTol := 24

; Tolerance used when deciding whether a browser window is snapped/maximized.
snapTol := 48

; Ignore very narrow windows in normal mode. Prevents tiny windows from matching.
; Example: 0.20 means 20% of monitor width.
minSnapWidthRatio := 0.20

; -----------------------------------------------------------------------------
; OPTIONAL OCCLUSION CHECK
; -----------------------------------------------------------------------------
; When enabled, the script samples points inside overlay areas and checks whether
; another window is covering them. This is more expensive, so it is off by default.
enableOcclusionHeuristic := false

; Number of sample points per dimension used by occlusion checking.
; 3 = 3x3 grid = 9 sample points total.
occlusionGrid := 3

; -----------------------------------------------------------------------------
; DYNAMIC CHROMIUM TOP-CHROME DETECTION
; -----------------------------------------------------------------------------
; When true, the script tries to detect the real top chrome height by finding the
; Chromium render area inside the browser window. This improves alignment.
useDynamicChromeHeight := true

; Cache time for that dynamic height detection.
contentTopCacheMs := 250

; =============================================================================
; TELEMETRY SETTINGS
; =============================================================================
; This block is for debugging / diagnosis. Safe to leave disabled.

; Master switch for telemetry.
enableTelemetry        := true

; Write telemetry log to a file.
telemetryToFile        := true

; Send telemetry lines to OutputDebug / DebugView.
telemetryToDebug       := true

; Small on-screen telemetry HUD window.
telemetryHud           := false

; Log file path. This writes to the same folder as the script itself.
telemetryFilePath      := A_ScriptDir "\overlay-telemetry.log"

; Log when GUI windows move.
telemetryVerboseMoves  := true

; Log owner binding / topmost changes.
telemetryVerboseOwner  := true

; Log every timer tick begin/end. Very noisy.
telemetryVerboseTick   := true

; Maximum number of lines shown in the HUD window.
telemetryMaxHudLines   := 12

; =============================================================================
; INTERNAL CONSTANTS
; =============================================================================
; Window style / API constants used by Win32 calls.

WS_EX_TRANSPARENT := 0x00000020   ; Click-through window
WS_EX_TOPMOST     := 0x00000008   ; Topmost extended style

EVENT_SYSTEM_FOREGROUND := 0x0003 ; Foreground window changed
WINEVENT_SKIPOWNPROCESS := 0x0002 ; Ignore events raised by this script itself

SWP_NOSIZE      := 0x0001         ; SetWindowPos: keep current size
SWP_NOMOVE      := 0x0002         ; SetWindowPos: keep current position
SWP_NOACTIVATE  := 0x0010         ; SetWindowPos: do not activate/focus window

HWND_TOPMOST    := -1             ; Insert window into topmost band
GW_OWNER        := 4              ; GetWindow(): retrieve owner window
GWLP_HWNDPARENT := -8             ; SetWindowLongPtr(): change owner for top-level window
GA_ROOT         := 2              ; GetAncestor(): get root window

; =============================================================================
; GLOBALS
; =============================================================================

; Processes / classes that should be ignored by fullscreen and occlusion detection.
global IgnoreProcs := Map(
    "nvidia overlay.exe", true,
    "gamebar.exe", true,
    "xboxgamebar.exe", true,
    "gameoverlayui.exe", true,
    "rtss.exe", true
)
global IgnoreClasses := Map("CEF-OSC-WIDGET", true)

; Set of all overlay HWNDs created by this script.
; Used so we don't accidentally treat our own overlays as real windows.
global OverlayHwndSet := Map()

; Tracks whether a given overlay window is currently shown or hidden.
global OverlayShown := Map()

; For each top overlay slot: which browser hwnd it is currently bound to.
global TopTargets := []

; For each YouTube overlay slot: which top-overlay hwnd it is currently bound to.
global YtTargets  := []

; In single-anywhere follow mode, this stores the browser window being followed.
global TrackedBrowserHwnd := 0

; WinEvent hook handle + callback pointer.
; Used only for telemetry / foreground observation now.
global hWinEventHook := 0
global winEventCb := 0

; Temporary globals used while enumerating Chromium child windows.
global _crBestTop := 0
global _crBestArea := 0

; Reused EnumChildWindows callback for Chromium content-top detection.
global enumChromiumCb := 0

; Cache of detected Chromium content top positions.
; Key = browser hwnd, value = {tick, x, y, w, h, top}
global ChromiumTopCache := Map()

; Per-tick caches so we do not repeatedly query DWM/window state for the same hwnd.
global InTick := false
global TickSerial := 0
global BoundsCache := Map()  ; hwnd => {serial, x, y, w, h}
global CloakCache  := Map()  ; hwnd => {serial, cloaked}

; Last rectangle actually drawn for each overlay.
; Used to avoid unnecessary Move() calls.
global LastTaskRect := ""
global LastTopRects := []
global LastYtRects := []

; Taskbar overlay GUI and hwnd.
global TaskGui := 0
global TaskHwnd := 0

; The real taskbar hwnd the overlay should be owned by.
global TaskTargetHwnd := 0

; Arrays of GUI objects / hwnds for browser overlays.
global TopGuis := []
global TopHwnds := []
global YtGuis  := []
global YtHwnds := []

; -----------------------------------------------------------------------------
; Telemetry globals
; -----------------------------------------------------------------------------
global TelemetrySeq := 0
global TelemetryHudLines := []
global TelemetryGui := 0
global TelemetryText := 0
global TickStartQpc := 0
global PerfFreq := 0
global LastTickDurationMs := 0.0
global FlashWatch := Map()

; =============================================================================
; INIT
; =============================================================================
; Script entry point: build overlays, hooks, timer, hotkeys.
Init()
return

Init() {
    global followHotkey, maxBrowserWindows
    global enumChromiumCb

    ; Create the callback used when enumerating child windows inside Chromium-based browsers.
    enumChromiumCb := CallbackCreate(EnumChromiumChildProc, "Fast")

    ; Create the taskbar overlay and the browser overlay slot arrays.
    RecreateTaskOverlay()
    InitOverlaySets(maxBrowserWindows)

    ; Toggle follow mode.
    Hotkey(followHotkey, ToggleFollowMode)

    ; Debug helpers:
    ; Ctrl+Alt+D = toggle HUD
    ; Ctrl+Alt+L = dump current overlay state to telemetry
    Hotkey("^!d", ToggleTelemetryHud)
    Hotkey("^!l", DumpOverlayState)

    ; Start telemetry system (if enabled).
    InitTelemetry()
    LogEvent("INIT", Map(
        "script", A_ScriptName,
        "browser", targetBrowserExe,
        "pollMs", pollMs,
        "followMode", followMode,
        "followBehavior", followModeBehavior,
        "logFile", telemetryFilePath
    ))

    ; Observe foreground changes for telemetry.
    InitWinEventHook()

    ; Main loop that keeps overlays positioned correctly.
    SetTimer(Tick, pollMs)

    ; Free callbacks / hooks when script exits.
    OnExit(CleanupAll)
}

CleanupAll(*) {
    global hWinEventHook, winEventCb, enumChromiumCb

    LogEvent("EXIT", Map("reason", "cleanup"))

    ; Remove WinEvent hook if it exists.
    if (hWinEventHook) {
        DllCall("User32\UnhookWinEvent", "Ptr", hWinEventHook)
        hWinEventHook := 0
    }

    ; Free foreground hook callback.
    if (winEventCb) {
        CallbackFree(winEventCb)
        winEventCb := 0
    }

    ; Free Chromium enumeration callback.
    if (enumChromiumCb) {
        CallbackFree(enumChromiumCb)
        enumChromiumCb := 0
    }
}

; =============================================================================
; GUI CREATION / RECREATION
; =============================================================================
; Overlay windows can be destroyed if their owner closes. These helpers recreate
; them and reinsert them into the tracking arrays.

InitOverlaySets(n) {
    global TopTargets, YtTargets, LastTopRects, LastYtRects

    Loop n {
        RecreateTopOverlay(A_Index)
        RecreateYtOverlay(A_Index)

        ; No current owner target yet.
        TopTargets.Push(0)
        YtTargets.Push(0)

        ; No cached geometry yet.
        LastTopRects.Push("")
        LastYtRects.Push("")
    }
}

MakeOverlayGui(alpha, alwaysOnTop := false) {
    global OverlayHwndSet, OverlayShown

    ; Creates a borderless, click-through, non-activating black overlay window.
    ; +E0x80000   = layered window (required for transparency)
    ; +E0x20      = transparent to mouse input
    ; +E0x08000000 = no activate
    opts := (alwaysOnTop ? "+AlwaysOnTop " : "") . "-Caption +ToolWindow -DPIScale +E0x80000 +E0x20 +E0x08000000"

    g := Gui(opts)
    g.BackColor := "Black"
    g.Show("NA x0 y0 w1 h1")
    h := g.Hwnd

    ; Apply transparency.
    WinSetTransparent(alpha, "ahk_id " h)

    ; Track this as one of our overlay windows.
    OverlayHwndSet[h] := true
    OverlayShown[h] := true

    ; Start hidden until the main logic decides to show it.
    EnsureShown(h, false)

    return { gui: g, hwnd: h }
}

RecreateTaskOverlay() {
    global TaskGui, TaskHwnd, taskbarAlpha, TaskTargetHwnd, LastTaskRect
    old := TaskHwnd

    ; Create a new taskbar overlay window.
    made := MakeOverlayGui(taskbarAlpha, false)
    TaskGui := made.gui
    TaskHwnd := made.hwnd

    ; Find the primary taskbar window to use as the owner.
    TaskTargetHwnd := WinExist("ahk_class Shell_TrayWnd")

    ; Reset last drawn rectangle cache.
    LastTaskRect := ""

    LogEvent("TASK_RECREATE", Map(
        "old", HwndTag(old),
        "new", HwndTag(TaskHwnd),
        "taskTarget", HwndTag(TaskTargetHwnd)
    ))
}

RecreateTopOverlay(i) {
    global TopGuis, TopHwnds, topAlpha
    old := (TopHwnds.Length >= i) ? TopHwnds[i] : 0

    made := MakeOverlayGui(topAlpha, false)

    if (TopGuis.Length >= i) {
        TopGuis[i] := made.gui
        TopHwnds[i] := made.hwnd
    } else {
        TopGuis.Push(made.gui)
        TopHwnds.Push(made.hwnd)
    }

    LogEvent("TOP_RECREATE", Map(
        "slot", i,
        "old", HwndTag(old),
        "new", HwndTag(TopHwnds[i])
    ))
}

RecreateYtOverlay(i) {
    global YtGuis, YtHwnds, ytAlpha
    old := (YtHwnds.Length >= i) ? YtHwnds[i] : 0

    made := MakeOverlayGui(ytAlpha, false)

    if (YtGuis.Length >= i) {
        YtGuis[i] := made.gui
        YtHwnds[i] := made.hwnd
    } else {
        YtGuis.Push(made.gui)
        YtHwnds.Push(made.hwnd)
    }

    LogEvent("YT_RECREATE", Map(
        "slot", i,
        "old", HwndTag(old),
        "new", HwndTag(YtHwnds[i])
    ))
}

EnsureTaskOverlayAlive() {
    global TaskHwnd

    ; Recreate the task overlay if it was destroyed (for example if owner changed / closed).
    if !IsValidHwnd(TaskHwnd)
        RecreateTaskOverlay()
}

EnsureSlotAlive(i) {
    global TopHwnds, YtHwnds, TopTargets, YtTargets, LastTopRects, LastYtRects

    ; Recreate top overlay if needed.
    if !IsValidHwnd(TopHwnds[i]) {
        RecreateTopOverlay(i)
        TopTargets[i] := 0
        LastTopRects[i] := ""
    }

    ; Recreate YouTube overlay if needed.
    if !IsValidHwnd(YtHwnds[i]) {
        RecreateYtOverlay(i)
        YtTargets[i] := 0
        LastYtRects[i] := ""
    }
}

; =============================================================================
; TELEMETRY
; =============================================================================
; Lightweight optional logging / HUD system used to diagnose flicker, owner
; changes, recreation, move churn, etc.

InitTelemetry() {
    global enableTelemetry, telemetryHud, telemetryToFile, telemetryFilePath
    global TelemetryGui, TelemetryText, PerfFreq

    if (!enableTelemetry)
        return

    ; Performance-counter frequency used for per-tick timing.
    try {
        DllCall("Kernel32\QueryPerformanceFrequency", "Int64P", &PerfFreq)
    } catch {
        PerfFreq := 0
    }

    ; Touch / create the log file if file logging is enabled.
    if (telemetryToFile) {
        try FileAppend("", telemetryFilePath, "UTF-8")
    }

    ; Optional on-screen telemetry window.
    if (telemetryHud) {
        TelemetryGui := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x20 +E0x08000000")
        TelemetryGui.BackColor := "111111"
        TelemetryText := TelemetryGui.AddText("cFFFFFF x8 y6 w760 h220", "telemetry starting...")
        TelemetryGui.Show("NA x20 y20 w780 h235")
    }
}

QpcNow() {
    ; Returns high-resolution performance counter value.
    qpc := 0
    try DllCall("Kernel32\QueryPerformanceCounter", "Int64P", &qpc)
    return qpc
}

QpcElapsedMs(startQpc) {
    global PerfFreq

    ; Converts performance counter delta into milliseconds.
    if (!PerfFreq || !startQpc)
        return 0.0

    now := QpcNow()
    return Round(((now - startQpc) * 1000.0) / PerfFreq, 3)
}

LogEvent(kind, fields := 0) {
    global enableTelemetry, telemetryToFile, telemetryToDebug, telemetryHud, telemetryFilePath
    global TelemetrySeq, TelemetryHudLines, telemetryMaxHudLines

    if (!enableTelemetry)
        return

    ; Format: sequence + timestamp + event kind + key/value pairs
    TelemetrySeq += 1
    line := Format("{1:06d} {2} {3}", TelemetrySeq, FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss"), kind)

    if IsObject(fields) {
        for k, v in fields
            line .= " | " k "=" TelemetryValue(v)
    }

    if (telemetryToFile) {
        try FileAppend(line "`r`n", telemetryFilePath, "UTF-8")
    }

    if (telemetryToDebug) {
        try OutputDebug(line)
    }

    if (telemetryHud) {
        TelemetryHudLines.Push(line)
        while (TelemetryHudLines.Length > telemetryMaxHudLines)
            TelemetryHudLines.RemoveAt(1)
        UpdateTelemetryHud()
    }
}

TelemetryValue(v) {
    ; Clean telemetry value for logging.
    if IsObject(v)
        return "<obj>"

    s := "" v
    s := StrReplace(s, "`r", " ")
    s := StrReplace(s, "`n", " ")
    return s
}

UpdateTelemetryHud() {
    global TelemetryGui, TelemetryText, TelemetryHudLines, LastTickDurationMs
    if (!TelemetryGui || !TelemetryText)
        return

    text := "LastTickMs=" LastTickDurationMs "`n"
    for _, line in TelemetryHudLines
        text .= line "`n"

    try TelemetryText.Text := text
}

HwndTag(hwnd) {
    ; Pretty formatting for hwnd values in logs.
    if (!hwnd)
        return "0x0"
    return "0x" Format("{:X}", hwnd)
}

ProcClassTag(hwnd) {
    ; Helper for logs: "process/class"
    return TryGetProc(hwnd) "/" TryGetClass(hwnd)
}

FlashMark(key, windowMs := 350) {
    global FlashWatch
    now := A_TickCount

    ; Tracks short bursts of repeated events for the same key.
    if (!FlashWatch.Has(key)) {
        FlashWatch[key] := {tick: now, count: 1}
        return 1
    }

    item := FlashWatch[key]
    if (now - item.tick <= windowMs) {
        item.count += 1
        item.tick := now
        FlashWatch[key] := item
        return item.count
    }

    FlashWatch[key] := {tick: now, count: 1}
    return 1
}

SafeGetTitle(hwnd) {
    ; Returns a title without throwing if the window disappears.
    title := ""
    try title := WinGetTitle("ahk_id " hwnd)
    return title
}

ToggleTelemetryHud(*) {
    global telemetryHud, TelemetryGui

    telemetryHud := !telemetryHud
    if (telemetryHud) {
        if (!TelemetryGui)
            InitTelemetry()
        else
            TelemetryGui.Show("NA")
        LogEvent("HUD_ON")
    } else {
        if (TelemetryGui)
            TelemetryGui.Hide()
        LogEvent("HUD_OFF")
    }
}

DumpOverlayState(*) {
    global TaskHwnd, TaskTargetHwnd
    global maxBrowserWindows, TopHwnds, YtHwnds, TopTargets, YtTargets

    ; Dumps current owner / target relationships for all overlays.
    LogEvent("STATE_DUMP", Map(
        "task", HwndTag(TaskHwnd),
        "taskOwner", HwndTag(GetOwnerHwnd(TaskHwnd)),
        "taskTarget", HwndTag(TaskTargetHwnd)
    ))

    Loop maxBrowserWindows {
        i := A_Index
        LogEvent("STATE_SLOT", Map(
            "slot", i,
            "top", HwndTag(TopHwnds[i]),
            "topOwner", HwndTag(GetOwnerHwnd(TopHwnds[i])),
            "topTarget", HwndTag(TopTargets[i]),
            "yt", HwndTag(YtHwnds[i]),
            "ytOwner", HwndTag(GetOwnerHwnd(YtHwnds[i])),
            "ytTarget", HwndTag(YtTargets[i])
        ))
    }
}

; =============================================================================
; WinEvent hook (telemetry only, no Z-order repairs)
; =============================================================================
; We are no longer constantly repairing sibling Z-order. This hook is only used
; to record foreground changes for diagnosis / debugging.

InitWinEventHook() {
    global hWinEventHook, winEventCb
    global EVENT_SYSTEM_FOREGROUND, WINEVENT_SKIPOWNPROCESS

    winEventCb := CallbackCreate(WinEventProc, "Fast")
    hWinEventHook := DllCall("User32\SetWinEventHook"
        , "UInt", EVENT_SYSTEM_FOREGROUND
        , "UInt", EVENT_SYSTEM_FOREGROUND
        , "Ptr", 0
        , "Ptr", winEventCb
        , "UInt", 0
        , "UInt", 0
        , "UInt", WINEVENT_SKIPOWNPROCESS
        , "Ptr")
}

WinEventProc(hHook, event, hwnd, idObject, idChild, idThread, time) {
    global EVENT_SYSTEM_FOREGROUND

    ; Ignore irrelevant event payloads.
    if (event != EVENT_SYSTEM_FOREGROUND || hwnd = 0 || idObject != 0)
        return

    LogEvent("FG_EVENT", Map(
        "hwnd", HwndTag(hwnd),
        "procClass", ProcClassTag(hwnd),
        "title", SafeGetTitle(hwnd)
    ))
}

; =============================================================================
; OWNER BINDING
; =============================================================================
; Instead of repeatedly forcing overlays above sibling windows, the overlays are
; set as "owned" top-level windows. Owned windows naturally stay above their owner,
; which is generally more stable and less flickery than repeated SetWindowPos fixes.

GetOwnerHwnd(hwnd) {
    global GW_OWNER
    if !IsValidHwnd(hwnd)
        return 0
    return DllCall("User32\GetWindow", "Ptr", hwnd, "UInt", GW_OWNER, "Ptr")
}

GetRootWindowHwnd(hwnd) {
    global GA_ROOT
    if !IsValidHwnd(hwnd)
        return 0

    ; Use root window as owner target so we do not bind to child windows.
    root := DllCall("User32\GetAncestor", "Ptr", hwnd, "UInt", GA_ROOT, "Ptr")
    return root ? root : hwnd
}

EnsureOverlayOwner(overlayHwnd, ownerHwnd, kind := "", slot := 0) {
    global telemetryVerboseOwner, GWLP_HWNDPARENT
    global SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE

    if (!IsValidHwnd(overlayHwnd) || !IsValidHwnd(ownerHwnd))
        return false

    ownerHwnd := GetRootWindowHwnd(ownerHwnd)
    current := GetOwnerHwnd(overlayHwnd)

    ; Already owned by the correct window.
    if (current = ownerHwnd)
        return false

    ; Change the overlay owner.
    DllCall("Kernel32\SetLastError", "UInt", 0)
    prev := DllCall("User32\SetWindowLongPtrW"
        , "Ptr", overlayHwnd
        , "Int", GWLP_HWNDPARENT
        , "Ptr", ownerHwnd
        , "Ptr")
    err := DllCall("Kernel32\GetLastError", "UInt")
    ok := !((prev = 0) && (err != 0))

    ; Nudge the window once after rebinding owner.
    flags := SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    DllCall("User32\SetWindowPos"
        , "Ptr", overlayHwnd
        , "Ptr", 0
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", flags)

    if (telemetryVerboseOwner) {
        LogEvent("OWNER_SET", Map(
            "kind", kind,
            "slot", slot,
            "overlay", HwndTag(overlayHwnd),
            "ownerOld", HwndTag(current),
            "ownerNew", HwndTag(ownerHwnd),
            "ok", ok,
            "err", err
        ))
    }
    return true
}

ClearOverlayOwner(overlayHwnd, kind := "", slot := 0) {
    global telemetryVerboseOwner, GWLP_HWNDPARENT

    if !IsValidHwnd(overlayHwnd)
        return false

    current := GetOwnerHwnd(overlayHwnd)
    if (!current)
        return false

    ; Remove current owner relationship.
    DllCall("Kernel32\SetLastError", "UInt", 0)
    prev := DllCall("User32\SetWindowLongPtrW"
        , "Ptr", overlayHwnd
        , "Int", GWLP_HWNDPARENT
        , "Ptr", 0
        , "Ptr")
    err := DllCall("Kernel32\GetLastError", "UInt")
    ok := !((prev = 0) && (err != 0))

    if (telemetryVerboseOwner) {
        LogEvent("OWNER_CLEAR", Map(
            "kind", kind,
            "slot", slot,
            "overlay", HwndTag(overlayHwnd),
            "ownerOld", HwndTag(current),
            "ok", ok,
            "err", err
        ))
    }
    return true
}

PinTopmost(hwnd) {
    global SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, HWND_TOPMOST, telemetryVerboseOwner
    flags := SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE

    ; Fallback path when no taskbar owner was found.
    ok := DllCall("User32\SetWindowPos"
        , "Ptr", hwnd
        , "Ptr", HWND_TOPMOST
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", flags)

    if (telemetryVerboseOwner) {
        LogEvent("PIN_TOPMOST", Map(
            "overlay", HwndTag(hwnd),
            "ok", ok
        ))
    }
}

; =============================================================================
; Main timer tick
; =============================================================================
; This is the heart of the script. Every poll interval it:
; - checks monitor/taskbar geometry
; - hides overlays when fullscreen apps are present
; - updates taskbar overlay
; - updates browser overlays depending on mode

Tick(*) {
    global InTick, TickSerial, TickStartQpc, LastTickDurationMs
    global telemetryVerboseTick

    TickSerial += 1
    TickStartQpc := QpcNow()
    InTick := true

    if (telemetryVerboseTick)
        LogEvent("TICK_BEGIN", Map("tick", TickSerial))

    try {
        TickInner()

        ; Periodically remove dead hwnds from caches.
        if (Mod(TickSerial, 200) = 0)
            PruneCaches()
    } finally {
        LastTickDurationMs := QpcElapsedMs(TickStartQpc)
        if (telemetryVerboseTick)
            LogEvent("TICK_END", Map("tick", TickSerial, "ms", LastTickDurationMs))
        InTick := false
    }
}

TickInner() {
    global TaskGui, TaskHwnd, TaskTargetHwnd, LastTaskRect
    global fallbackTaskbarH, followMode, followModeBehavior

    EnsureTaskOverlayAlive()
    if !WinExist("ahk_id " TaskHwnd)
        return

    ; Primary monitor full bounds and work area.
    primary := MonitorGetPrimary()
    MonitorGet(primary, &mL, &mT, &mR, &mB)
    MonitorGetWorkArea(primary, &waL, &waT, &waR, &waB)

    ; Calculate taskbar area from monitor minus work area.
    taskHReal := mB - waB
    taskH := (taskHReal < 10) ? fallbackTaskbarH : taskHReal
    taskY := (taskHReal < 10) ? (mB - taskH) : waB

    ; Move taskbar overlay only if its rect changed.
    taskWasShown := OverlayShown.Has(TaskHwnd) ? OverlayShown[TaskHwnd] : false
    movedTask := MoveGuiVarIfChanged(TaskGui, &LastTaskRect, mL, taskY, (mR - mL), taskH)

    ; Refresh taskbar hwnd if needed.
    if (!TaskTargetHwnd || !IsValidHwnd(TaskTargetHwnd))
        TaskTargetHwnd := WinExist("ahk_class Shell_TrayWnd")

    ; If something else is fullscreen, hide everything.
    fsHwnd := FindFullscreenOnPrimary(mL, mT, mR, mB)
    if (fsHwnd) {
        LogEvent("FULLSCREEN_DETECTED", Map(
            "hwnd", HwndTag(fsHwnd),
            "procClass", ProcClassTag(fsHwnd),
            "title", SafeGetTitle(fsHwnd)
        ))
        EnsureShown(TaskHwnd, false)
        ClearOverlayOwner(TaskHwnd, "taskbar", 0)
        HideAllBrowserOverlays()
        return
    }

    ; Show taskbar overlay and bind it to the real taskbar when possible.
    EnsureShown(TaskHwnd, true)
    if (TaskTargetHwnd)
        EnsureOverlayOwner(TaskHwnd, TaskTargetHwnd, "taskbar", 0)
    else if (!taskWasShown || movedTask || !IsTopmostHwnd(TaskHwnd))
        PinTopmost(TaskHwnd)

    ; Choose follow mode or normal mode.
    if (followMode) {
        if (followModeBehavior = "single-anywhere")
            RunFollowSingle()
        else
            RunFollowMultiPrimary(primary)
        return
    }

    RunNormalSnapMax(primary, waT, waB)
}

HideAllBrowserOverlays() {
    global maxBrowserWindows
    Loop maxBrowserWindows
        HideOverlaySlot(A_Index)
}

HideOverlaySlot(i) {
    global TopHwnds, YtHwnds, TopTargets, YtTargets
    global LastTopRects, LastYtRects

    ; Hide YT overlay first because it is conceptually attached to the top overlay.
    EnsureShown(YtHwnds[i], false)
    ClearOverlayOwner(YtHwnds[i], "yt", i)
    YtTargets[i] := 0
    LastYtRects[i] := ""

    ; Then hide the top overlay.
    EnsureShown(TopHwnds[i], false)
    ClearOverlayOwner(TopHwnds[i], "top", i)
    TopTargets[i] := 0
    LastTopRects[i] := ""
}

; =============================================================================
; Follow mode
; =============================================================================
; In follow mode the script is less strict about window positioning.
; This is useful when windows are not exactly snapped/maximized.

ToggleFollowMode(*) {
    global followMode, followModeBehavior, TrackedBrowserHwnd, targetBrowserExe

    followMode := !followMode
    LogEvent("FOLLOW_TOGGLE", Map("enabled", followMode, "behavior", followModeBehavior))

    ; If entering single-anywhere mode, try to lock onto the currently active browser.
    if (followMode && (followModeBehavior = "single-anywhere")) {
        hwnd := WinExist("A")
        proc := hwnd ? TryGetProc(hwnd) : ""
        if (proc = StrLower(targetBrowserExe)) {
            TrackedBrowserHwnd := hwnd
        } else if (!IsValidHwnd(TrackedBrowserHwnd)) {
            TrackedBrowserHwnd := FindAnyTargetBrowserWindow()
        }
    }
}

FindAnyTargetBrowserWindow() {
    global targetBrowserExe
    target := StrLower(targetBrowserExe)

    ; Returns the first visible, non-minimized, non-cloaked target browser window found.
    for hwnd in WinGetList() {
        if !IsValidHwnd(hwnd)
            continue
        if (TryGetProc(hwnd) != target)
            continue
        if !TryIsVisible(hwnd)
            continue
        if TryIsMinimized(hwnd)
            continue
        if IsWindowCloaked(hwnd)
            continue
        return hwnd
    }
    return 0
}

RunFollowMultiPrimary(primaryMon) {
    global maxBrowserWindows, enableBrowserTopOverlay, enableYouTubeOverlay
    global TopGuis, TopHwnds, YtGuis, YtHwnds, TopTargets, YtTargets
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global followTopOverlayH, enableOcclusionHeuristic
    global LastTopRects, LastYtRects

    MonitorGet(primaryMon, &monL, &monT, &monR, &monB)

    ; Get all target browser windows on the primary monitor.
    wins := GetBrowserWindowsOnPrimaryAnywhere(primaryMon)
    SortWinsByX(wins)

    Loop maxBrowserWindows {
        i := A_Index
        EnsureSlotAlive(i)

        ; No matching browser for this slot -> hide overlay pair.
        if (!enableBrowserTopOverlay || i > wins.Length) {
            HideOverlaySlot(i)
            continue
        }

        w := wins[i]
        topH := followTopOverlayH
        topY := ClampTopY(w.y, monT)

        ; If possible, detect actual Chromium content top.
        topH := GetDynamicTopH(w.hwnd, topY, topH, w.x, w.y, w.w, w.h)

        ; Optional expensive check: hide if covered by another window.
        if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(w.hwnd, w.x, topY, w.w, topH)) {
            LogEvent("OCCLUDED_TOP", Map("slot", i, "target", HwndTag(w.hwnd)))
            HideOverlaySlot(i)
            continue
        }

        ; Move + bind + show top overlay.
        MoveGuiSlotIfChanged(TopGuis[i], LastTopRects, i, w.x, topY, w.w, topH)
        TopTargets[i] := w.hwnd
        EnsureOverlayOwner(TopHwnds[i], w.hwnd, "top", i)
        EnsureShown(TopHwnds[i], true)

        ; Optional YouTube overlay.
        if (enableYouTubeOverlay && TitleMatches(w.hwnd, youtubeTitleRegex)) {
            ytX := w.x + ytInsetLeft
            ytY := topY + topH
            ytW := w.w - (ytInsetLeft + ytInsetRight)
            if (ytW < 1)
                ytW := 1

            if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(w.hwnd, ytX, ytY, ytW, ytOverlayH)) {
                LogEvent("OCCLUDED_YT", Map("slot", i, "target", HwndTag(w.hwnd)))
                EnsureShown(YtHwnds[i], false)
                ClearOverlayOwner(YtHwnds[i], "yt", i)
                YtTargets[i] := 0
                LastYtRects[i] := ""
            } else {
                MoveGuiSlotIfChanged(YtGuis[i], LastYtRects, i, ytX, ytY, ytW, ytOverlayH)
                YtTargets[i] := TopHwnds[i]
                EnsureOverlayOwner(YtHwnds[i], TopHwnds[i], "yt", i)
                EnsureShown(YtHwnds[i], true)
            }
        } else {
            EnsureShown(YtHwnds[i], false)
            ClearOverlayOwner(YtHwnds[i], "yt", i)
            YtTargets[i] := 0
            LastYtRects[i] := ""
        }
    }
}

RunFollowSingle() {
    global TrackedBrowserHwnd, targetBrowserExe
    global TopGuis, TopHwnds, YtGuis, YtHwnds, maxBrowserWindows
    global TopTargets, YtTargets
    global enableBrowserTopOverlay, enableYouTubeOverlay
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global followTopOverlayH, enableOcclusionHeuristic
    global LastTopRects, LastYtRects

    ; In single follow mode, only slot 1 is used.
    Loop maxBrowserWindows {
        EnsureSlotAlive(A_Index)
        if (A_Index > 1)
            HideOverlaySlot(A_Index)
    }

    ; Refresh tracked browser if it is gone / minimized / wrong process / hidden.
    if (!IsValidHwnd(TrackedBrowserHwnd)
        || TryGetProc(TrackedBrowserHwnd) != StrLower(targetBrowserExe)
        || TryIsMinimized(TrackedBrowserHwnd)
        || !TryIsVisible(TrackedBrowserHwnd)
        || IsWindowCloaked(TrackedBrowserHwnd)) {

        TrackedBrowserHwnd := FindAnyTargetBrowserWindow()
        if (!TrackedBrowserHwnd) {
            HideOverlaySlot(1)
            return
        }
    }

    if (!enableBrowserTopOverlay) {
        HideOverlaySlot(1)
        return
    }

    GetBestBounds(TrackedBrowserHwnd, &x, &y, &w, &h)
    topH := followTopOverlayH

    ; Use monitor top edge for clamp calculation.
    mon := GetMonitorIndexFromPoint(x + w/2, y + h/2)
    monT := y
    if (mon)
        MonitorGet(mon, &monL, &monT, &monR, &monB)

    topY := ClampTopY(y, monT)
    topH := GetDynamicTopH(TrackedBrowserHwnd, topY, topH, x, y, w, h)

    if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(TrackedBrowserHwnd, x, topY, w, topH)) {
        LogEvent("OCCLUDED_SINGLE_TOP", Map("target", HwndTag(TrackedBrowserHwnd)))
        HideOverlaySlot(1)
        return
    }

    MoveGuiSlotIfChanged(TopGuis[1], LastTopRects, 1, x, topY, w, topH)
    TopTargets[1] := TrackedBrowserHwnd
    EnsureOverlayOwner(TopHwnds[1], TrackedBrowserHwnd, "top", 1)
    EnsureShown(TopHwnds[1], true)

    if (enableYouTubeOverlay && TitleMatches(TrackedBrowserHwnd, youtubeTitleRegex)) {
        ytX := x + ytInsetLeft
        ytY := topY + topH
        ytW := w - (ytInsetLeft + ytInsetRight)
        if (ytW < 1)
            ytW := 1

        if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(TrackedBrowserHwnd, ytX, ytY, ytW, ytOverlayH)) {
            LogEvent("OCCLUDED_SINGLE_YT", Map("target", HwndTag(TrackedBrowserHwnd)))
            EnsureShown(YtHwnds[1], false)
            ClearOverlayOwner(YtHwnds[1], "yt", 1)
            YtTargets[1] := 0
            LastYtRects[1] := ""
        } else {
            MoveGuiSlotIfChanged(YtGuis[1], LastYtRects, 1, ytX, ytY, ytW, ytOverlayH)
            YtTargets[1] := TopHwnds[1]
            EnsureOverlayOwner(YtHwnds[1], TopHwnds[1], "yt", 1)
            EnsureShown(YtHwnds[1], true)
        }
    } else {
        EnsureShown(YtHwnds[1], false)
        ClearOverlayOwner(YtHwnds[1], "yt", 1)
        YtTargets[1] := 0
        LastYtRects[1] := ""
    }
}

; =============================================================================
; Normal mode (snap/max on primary workarea)
; =============================================================================
; This mode only overlays browser windows that appear snapped/maximized on the
; primary monitor work area.

RunNormalSnapMax(primaryMon, waT, waB) {
    global maxBrowserWindows, enableBrowserTopOverlay, enableYouTubeOverlay
    global TopGuis, TopHwnds, YtGuis, YtHwnds, TopTargets, YtTargets
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global topOverlayHMax, topOverlayHSnap, snapTol, minSnapWidthRatio, targetBrowserExe
    global enableOcclusionHeuristic
    global LastTopRects, LastYtRects

    MonitorGet(primaryMon, &mL, &mT, &mR, &mB)
    monW := mR - mL
    target := StrLower(targetBrowserExe)

    wins := []

    ; Find matching browser windows that look snapped or maximized on primary.
    for hwnd in WinGetList() {
        if !IsValidHwnd(hwnd)
            continue

        proc := TryGetProc(hwnd)
        if (proc = "" || proc != target)
            continue

        if !TryIsVisible(hwnd)
            continue
        if IsWindowCloaked(hwnd)
            continue
        if TryIsMinimized(hwnd)
            continue

        GetBestBounds(hwnd, &x, &y, &w, &h)
        if (w <= 0 || h <= 0)
            continue

        cx := x + w / 2
        cy := y + h / 2
        if (GetMonitorIndexFromPoint(cx, cy) != primaryMon)
            continue

        ; Require top and bottom edges to roughly align with work area.
        topOK := Abs(y - waT) <= snapTol
        botOK := Abs((y + h) - waB) <= snapTol
        if (!topOK || !botOK)
            continue

        ; Ignore windows that are too narrow.
        if (monW > 0 && w < monW * minSnapWidthRatio)
            continue

        ; Detect maximized vs snapped.
        leftOK  := Abs(x - mL) <= snapTol
        rightOK := Abs((x + w) - mR) <= snapTol
        isMax := leftOK && rightOK && (w >= (monW - 2 * snapTol))
        mode := isMax ? "max" : "snap"

        wins.Push({ hwnd: hwnd, mode: mode, x: x, y: y, w: w, h: h })
    }

    ; Stable left-to-right ordering so slot assignment is consistent.
    SortWinsByX(wins)

    Loop maxBrowserWindows {
        i := A_Index
        EnsureSlotAlive(i)

        if (!enableBrowserTopOverlay || i > wins.Length) {
            HideOverlaySlot(i)
            continue
        }

        w := wins[i]

        ; Choose fallback height based on snapped vs maximized.
        topH := (w.mode = "snap") ? topOverlayHSnap : topOverlayHMax
        topY := ClampTopY(w.y, waT)
        topH := GetDynamicTopH(w.hwnd, topY, topH, w.x, w.y, w.w, w.h)

        if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(w.hwnd, w.x, topY, w.w, topH)) {
            LogEvent("OCCLUDED_NORMAL_TOP", Map("slot", i, "target", HwndTag(w.hwnd)))
            HideOverlaySlot(i)
            continue
        }

        MoveGuiSlotIfChanged(TopGuis[i], LastTopRects, i, w.x, topY, w.w, topH)
        TopTargets[i] := w.hwnd
        EnsureOverlayOwner(TopHwnds[i], w.hwnd, "top", i)
        EnsureShown(TopHwnds[i], true)

        if (enableYouTubeOverlay && TitleMatches(w.hwnd, youtubeTitleRegex)) {
            ytX := w.x + ytInsetLeft
            ytY := topY + topH
            ytW := w.w - (ytInsetLeft + ytInsetRight)
            if (ytW < 1)
                ytW := 1

            if (enableOcclusionHeuristic && IsRectCoveredByOtherWindow(w.hwnd, ytX, ytY, ytW, ytOverlayH)) {
                LogEvent("OCCLUDED_NORMAL_YT", Map("slot", i, "target", HwndTag(w.hwnd)))
                EnsureShown(YtHwnds[i], false)
                ClearOverlayOwner(YtHwnds[i], "yt", i)
                YtTargets[i] := 0
                LastYtRects[i] := ""
            } else {
                MoveGuiSlotIfChanged(YtGuis[i], LastYtRects, i, ytX, ytY, ytW, ytOverlayH)
                YtTargets[i] := TopHwnds[i]
                EnsureOverlayOwner(YtHwnds[i], TopHwnds[i], "yt", i)
                EnsureShown(YtHwnds[i], true)
            }
        } else {
            EnsureShown(YtHwnds[i], false)
            ClearOverlayOwner(YtHwnds[i], "yt", i)
            YtTargets[i] := 0
            LastYtRects[i] := ""
        }
    }
}

GetBrowserWindowsOnPrimaryAnywhere(primaryMon) {
    global targetBrowserExe
    arr := []
    target := StrLower(targetBrowserExe)

    ; Returns all visible target browser windows whose center lies on the primary monitor.
    for hwnd in WinGetList() {
        if !IsValidHwnd(hwnd)
            continue

        proc := TryGetProc(hwnd)
        if (proc = "" || proc != target)
            continue

        if !TryIsVisible(hwnd)
            continue
        if IsWindowCloaked(hwnd)
            continue
        if TryIsMinimized(hwnd)
            continue

        GetBestBounds(hwnd, &x, &y, &w, &h)
        if (w <= 0 || h <= 0)
            continue

        cx := x + w / 2
        cy := y + h / 2
        if (GetMonitorIndexFromPoint(cx, cy) != primaryMon)
            continue

        arr.Push({ hwnd: hwnd, x: x, y: y, w: w, h: h })
    }

    return arr
}

SortWinsByX(arr) {
    ; Simple stable-ish selection sort by X position, then hwnd.
    ; This keeps slot ordering predictable.
    n := arr.Length
    if (n <= 1)
        return

    i := 1
    while (i < n) {
        min := i
        j := i + 1
        while (j <= n) {
            ax := arr[j].x
            bx := arr[min].x
            if (ax < bx || (ax = bx && arr[j].hwnd < arr[min].hwnd))
                min := j
            j += 1
        }
        if (min != i) {
            tmp := arr[i]
            arr[i] := arr[min]
            arr[min] := tmp
        }
        i += 1
    }
}

; =============================================================================
; Chromium content-top cache
; =============================================================================
; Used to estimate the true height of the browser's top chrome by finding the
; largest Chrome_RenderWidgetHostHWND child and using its top edge.

GetDynamicTopH(hwnd, topY, fallback, x, y, w, h) {
    global useDynamicChromeHeight

    if (!useDynamicChromeHeight)
        return fallback

    contentTop := GetChromiumContentTopCached(hwnd, x, y, w, h)
    if (!contentTop)
        return fallback

    dynH := contentTop - topY

    ; Sanity clamp so weird results do not break layout.
    if (dynH >= 40 && dynH <= 220)
        return dynH

    return fallback
}

GetChromiumContentTopCached(hwnd, x, y, w, h) {
    global ChromiumTopCache, contentTopCacheMs
    now := A_TickCount

    ; Reuse cached result if bounds are unchanged and cache is still fresh.
    if (ChromiumTopCache.Has(hwnd)) {
        c := ChromiumTopCache[hwnd]
        if ((now - c.tick) <= contentTopCacheMs && c.x = x && c.y = y && c.w = w && c.h = h)
            return c.top
    }

    top := GetChromiumContentTop(hwnd)
    ChromiumTopCache[hwnd] := { tick: now, x: x, y: y, w: w, h: h, top: top }
    return top
}

GetChromiumContentTop(hwnd) {
    global _crBestTop, _crBestArea, enumChromiumCb

    _crBestTop := 0
    _crBestArea := 0

    ; Enumerate all child windows and let EnumChromiumChildProc choose the best candidate.
    DllCall("User32\EnumChildWindows", "Ptr", hwnd, "Ptr", enumChromiumCb, "Ptr", 0)
    return _crBestTop
}

EnumChromiumChildProc(chwnd, lParam) {
    global _crBestTop, _crBestArea

    ; Only interested in Chromium render widgets.
    cls := TryGetClass(chwnd)
    if (cls != "Chrome_RenderWidgetHostHWND")
        return 1

    if !TryIsVisible(chwnd)
        return 1
    if IsWindowCloaked(chwnd)
        return 1
    if TryIsMinimized(chwnd)
        return 1

    GetBestBounds(chwnd, &x, &y, &w, &h)
    if (w <= 0 || h <= 0)
        return 1

    ; Use largest visible render widget as best match.
    area := w * h
    if (area > _crBestArea) {
        _crBestArea := area
        _crBestTop := y
    }

    return 1
}

; =============================================================================
; Fullscreen detection + optional occlusion heuristics
; =============================================================================
; Fullscreen detection is used to hide overlays when something else is taking over
; the whole screen. Occlusion checks are optional and more expensive.

FindFullscreenOnPrimary(L, T, R, B) {
    global OverlayHwndSet, IgnoreProcs, IgnoreClasses, fsTol
    global WS_EX_TRANSPARENT

    for hwnd in WinGetList() {
        if (OverlayHwndSet.Has(hwnd))
            continue
        if !TryIsVisible(hwnd)
            continue
        if IsWindowCloaked(hwnd)
            continue
        if TryIsMinimized(hwnd)
            continue

        cls := TryGetClass(hwnd)
        if (cls = "")
            continue
        if (cls = "Progman" || cls = "WorkerW" || cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd")
            continue
        if (IgnoreClasses.Has(cls))
            continue

        proc := TryGetProc(hwnd)
        if (proc != "" && IgnoreProcs.Has(proc))
            continue

        ex := TryGetExStyle(hwnd)
        if (ex & WS_EX_TRANSPARENT)
            continue

        GetBestBounds(hwnd, &x, &y, &w, &h)

        ; If a real window nearly covers the whole primary monitor, treat it as fullscreen.
        if (x <= L + fsTol && y <= T + fsTol && (x + w) >= R - fsTol && (y + h) >= B - fsTol)
            return hwnd
    }

    return 0
}

IsRectCoveredByOtherWindow(targetHwnd, rx, ry, rw, rh) {
    global occlusionGrid
    cols := occlusionGrid
    rows := occlusionGrid

    if (rw <= 1 || rh <= 1)
        return true

    ; Sample multiple points inside the rectangle.
    ; If any point is NOT covered, the whole rect is considered not fully covered.
    Loop rows {
        r := A_Index
        py := Integer(ry + (r - 0.5) * (rh / rows))

        Loop cols {
            c := A_Index
            px := Integer(rx + (c - 0.5) * (rw / cols))
            if (!IsPointCoveredByOtherWindow(targetHwnd, px, py))
                return false
        }
    }

    return true
}

IsPointCoveredByOtherWindow(targetHwnd, px, py) {
    global OverlayHwndSet, IgnoreProcs, IgnoreClasses, GA_ROOT

    hwnd := DllCall("User32\GetTopWindow", "Ptr", 0, "Ptr")
    GW_HWNDNEXT := 2
    seen := Map()

    ; Walk top-level Z-order from top to bottom.
    Loop 512 {
        if (!hwnd)
            break

        root := DllCall("User32\GetAncestor", "Ptr", hwnd, "UInt", GA_ROOT, "Ptr")
        if (!root)
            root := hwnd

        if (!seen.Has(root)) {
            seen[root] := true

            if (!OverlayHwndSet.Has(root)) {
                cls := TryGetClass(root)
                if (cls != "" && cls != "Progman" && cls != "WorkerW" && cls != "Shell_TrayWnd" && cls != "Shell_SecondaryTrayWnd") {
                    if (!IgnoreClasses.Has(cls)) {
                        proc := TryGetProc(root)
                        if (!(proc != "" && IgnoreProcs.Has(proc))) {
                            if (TryIsVisible(root) && !IsWindowCloaked(root) && !TryIsMinimized(root)) {
                                GetBestBounds(root, &x, &y, &w, &h)
                                if (w > 0 && h > 0 && px >= x && px < x + w && py >= y && py < y + h) {
                                    ; If the target itself is at this point, it is not covered.
                                    if (root = targetHwnd)
                                        return false
                                    else
                                        return true
                                }
                            }
                        }
                    }
                }
            }
        }

        hwnd := DllCall("User32\GetWindow", "Ptr", hwnd, "UInt", GW_HWNDNEXT, "Ptr")
    }

    return false
}

; =============================================================================
; Utility helpers
; =============================================================================

ClampTopY(y, topY, tol := 8) {
    ; Snaps y to topY if it is already very close, which helps remove tiny gaps.
    return (Abs(y - topY) <= tol) ? topY : y
}

MoveGuiVarIfChanged(gui, &cacheVar, x, y, w, h) {
    global telemetryVerboseMoves
    key := x "|" y "|" w "|" h

    ; Skip Move() if rect is unchanged.
    if (cacheVar = key)
        return false

    oldKey := cacheVar
    gui.Move(x, y, w, h)
    cacheVar := key

    if (telemetryVerboseMoves) {
        burst := FlashMark("move:" gui.Hwnd)
        LogEvent("MOVE_GUI", Map(
            "hwnd", HwndTag(gui.Hwnd),
            "old", oldKey,
            "new", key,
            "burst", burst
        ))
    }
    return true
}

MoveGuiSlotIfChanged(gui, cacheArr, i, x, y, w, h) {
    global telemetryVerboseMoves
    key := x "|" y "|" w "|" h

    ; Same as above but for array-backed per-slot caches.
    if (cacheArr[i] = key)
        return false

    oldKey := cacheArr[i]
    gui.Move(x, y, w, h)
    cacheArr[i] := key

    if (telemetryVerboseMoves) {
        burst := FlashMark("move:" gui.Hwnd)
        LogEvent("MOVE_SLOT", Map(
            "slot", i,
            "hwnd", HwndTag(gui.Hwnd),
            "old", oldKey,
            "new", key,
            "burst", burst
        ))
    }
    return true
}

EnsureShown(hwnd, show) {
    global OverlayShown

    ; Only call WinShow/WinHide if state actually changes.
    cur := OverlayShown.Has(hwnd) ? OverlayShown[hwnd] : false
    if (show = cur)
        return

    burst := FlashMark("showhide:" hwnd)

    if (show) {
        try WinShow("ahk_id " hwnd)
        OverlayShown[hwnd] := true
        LogEvent("SHOW", Map("hwnd", HwndTag(hwnd), "burst", burst))
    } else {
        try WinHide("ahk_id " hwnd)
        OverlayShown[hwnd] := false
        LogEvent("HIDE", Map("hwnd", HwndTag(hwnd), "burst", burst))
    }
}

TryGetProc(hwnd) {
    ; Safe process-name lookup.
    proc := ""
    try {
        proc := StrLower(WinGetProcessName("ahk_id " hwnd))
    } catch {
        proc := ""
    }
    return proc
}

TryGetClass(hwnd) {
    ; Safe class-name lookup.
    cls := ""
    try {
        cls := WinGetClass("ahk_id " hwnd)
    } catch {
        cls := ""
    }
    return cls
}

TryGetExStyle(hwnd) {
    ; Safe extended-style lookup.
    ex := 0
    try {
        ex := WinGetExStyle("ahk_id " hwnd)
    } catch {
        ex := 0
    }
    return ex
}

IsTopmostHwnd(hwnd) {
    ; True if the window currently has the topmost extended style.
    global WS_EX_TOPMOST
    ex := TryGetExStyle(hwnd)
    return (ex & WS_EX_TOPMOST) != 0
}

TryIsVisible(hwnd) {
    ; Safe wrapper around IsWindowVisible().
    try {
        return DllCall("User32\IsWindowVisible", "Ptr", hwnd, "Int") != 0
    } catch {
        return false
    }
}

TryIsMinimized(hwnd) {
    ; Safe minimized-state check.
    try {
        return (WinGetMinMax("ahk_id " hwnd) = -1)
    } catch {
        return true
    }
}

IsValidHwnd(hwnd) {
    ; Basic validity check: nonzero and still exists.
    return hwnd && WinExist("ahk_id " hwnd)
}

TitleMatches(hwnd, rx) {
    ; Safe title lookup + regex match.
    title := ""
    try {
        title := WinGetTitle("ahk_id " hwnd)
    } catch {
        title := ""
    }
    return (title != "" && RegExMatch(title, rx))
}

GetBestBounds(hwnd, &x, &y, &w, &h) {
    global InTick, TickSerial, BoundsCache

    ; Reuse per-tick cached bounds if already queried this tick.
    if (InTick && BoundsCache.Has(hwnd) && BoundsCache[hwnd].serial = TickSerial) {
        c := BoundsCache[hwnd]
        x := c.x
        y := c.y
        w := c.w
        h := c.h
        return
    }

    GetBestBoundsRaw(hwnd, &x, &y, &w, &h)

    if (InTick)
        BoundsCache[hwnd] := { serial: TickSerial, x: x, y: y, w: w, h: h }
}

GetBestBoundsRaw(hwnd, &x, &y, &w, &h) {
    static rect := Buffer(16, 0)
    static wr := Buffer(16, 0)

    ; Prefer DWM extended frame bounds because they usually match the real visible frame better.
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", rect, "UInt", 16) = 0) {
        l := NumGet(rect, 0, "Int")
        t := NumGet(rect, 4, "Int")
        r := NumGet(rect, 8, "Int")
        b := NumGet(rect, 12, "Int")
        ww := r - l
        hh := b - t
        if (ww > 0 && hh > 0) {
            x := l
            y := t
            w := ww
            h := hh
            return
        }
    }

    ; Fallback to standard window rect.
    if (DllCall("User32\GetWindowRect", "Ptr", hwnd, "Ptr", wr) != 0) {
        l := NumGet(wr, 0, "Int")
        t := NumGet(wr, 4, "Int")
        r := NumGet(wr, 8, "Int")
        b := NumGet(wr, 12, "Int")
        x := l
        y := t
        w := r - l
        h := b - t
        return
    }

    ; Last-resort fallback.
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
}

IsWindowCloaked(hwnd) {
    global InTick, TickSerial, CloakCache

    ; Reuse cached cloak state during the same tick.
    if (InTick && CloakCache.Has(hwnd) && CloakCache[hwnd].serial = TickSerial)
        return CloakCache[hwnd].cloaked

    static cloakedBuf := Buffer(4, 0)
    DWMWA_CLOAKED := 14
    hr := -1

    ; "Cloaked" windows are generally hidden / indirect windows that should not count.
    try {
        hr := DllCall("dwmapi\DwmGetWindowAttribute"
            , "Ptr", hwnd
            , "UInt", DWMWA_CLOAKED
            , "Ptr", cloakedBuf
            , "UInt", 4
            , "UInt")
    } catch {
        if (InTick)
            CloakCache[hwnd] := { serial: TickSerial, cloaked: false }
        return false
    }

    cloaked := NumGet(cloakedBuf, 0, "UInt")
    result := (hr = 0) && (cloaked != 0)

    if (InTick)
        CloakCache[hwnd] := { serial: TickSerial, cloaked: result }

    return result
}

GetMonitorIndexFromPoint(px, py) {
    ; Returns the monitor index containing the given point.
    count := 0
    try {
        count := MonitorGetCount()
    } catch {
        return 0
    }

    Loop count {
        i := A_Index
        L := T := R := B := 0
        try {
            MonitorGet(i, &L, &T, &R, &B)
        } catch {
            continue
        }

        if (px >= L && px < R && py >= T && py < B)
            return i
    }

    return 0
}

PruneCaches() {
    global BoundsCache, CloakCache, ChromiumTopCache

    ; Remove stale hwnd entries from bounds cache.
    toDel := []
    for hwnd, _ in BoundsCache {
        if !WinExist("ahk_id " hwnd)
            toDel.Push(hwnd)
    }
    for _, hwnd in toDel
        BoundsCache.Delete(hwnd)

    ; Remove stale hwnd entries from cloak cache.
    toDel := []
    for hwnd, _ in CloakCache {
        if !WinExist("ahk_id " hwnd)
            toDel.Push(hwnd)
    }
    for _, hwnd in toDel
        CloakCache.Delete(hwnd)

    ; Remove stale hwnd entries from Chromium top cache.
    toDel := []
    for hwnd, _ in ChromiumTopCache {
        if !WinExist("ahk_id " hwnd)
            toDel.Push(hwnd)
    }
    for _, hwnd in toDel
        ChromiumTopCache.Delete(hwnd)
}
