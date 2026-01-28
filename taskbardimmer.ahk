#Requires AutoHotkey v2.0
#SingleInstance Force
DetectHiddenWindows True

; ===================== USER SETTINGS =====================
targetBrowserExe         := "msedge.exe"     ; "chrome.exe", "firefox.exe", "brave.exe", etc.

enableBrowserTopOverlay  := true
enableYouTubeOverlay     := true

maxBrowserWindows        := 6
youtubeTitleRegex        := "i)\byoutube\b"

; FOLLOW MODE
followMode               := false			 ; Start in follow mode
followHotkey             := "^!f"            ; Ctrl+Alt+F toggles follow mode
followModeBehavior       := "multi-primary"  ; "multi-primary" or "single-anywhere"

; follow mode top overlay height (always)
followTopOverlayH        := 81

; Taskbar overlay
taskbarAlpha := 179
fallbackTaskbarH := 63

; Browser top overlay heights (normal mode)
topAlpha := 179
topOverlayHMax  := 72
topOverlayHSnap := 81

; YouTube overlay
ytAlpha := 179
ytOverlayH := 56
ytInsetLeft := 4
ytInsetRight := 19

pollMs := 100
fsTol := 24
snapTol := 48
minSnapWidthRatio := 0.20

pinThrottleMs := 10
; ==========================================================

global IgnoreProcs := Map(
    "nvidia overlay.exe", true,
    "gamebar.exe", true,
    "xboxgamebar.exe", true,
    "gameoverlayui.exe", true,
    "rtss.exe", true
)
global IgnoreClasses := Map("CEF-OSC-WIDGET", true)

enableLog := true
logFile := A_ScriptDir "\taskbardimmer_debug.log"

global OverlayHwndSet := Map()
global OverlayShown := Map()

global TrackedBrowserHwnd := 0

global hWinEventHook := 0
global winEventCb := 0
global lastPinTick := 0

; ---------- Taskbar overlay ----------
global TaskGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
TaskGui.BackColor := "Black"
TaskGui.Show("NA x0 y0 w1 h1")
global TaskHwnd := TaskGui.Hwnd
WinSetTransparent(taskbarAlpha, "ahk_id " TaskHwnd)
OverlayHwndSet[TaskHwnd] := true
OverlayShown[TaskHwnd] := true

; ---------- Per-window overlays ----------
global TopGuis := [], TopHwnds := []
global YtGuis  := [], YtHwnds  := []
InitOverlaySets(maxBrowserWindows)

if (enableLog) {
    try FileDelete(logFile)
    Log("START | AHK " A_AhkVersion " | followMode=" followMode " | behavior=" followModeBehavior)
}

Hotkey(followHotkey, ToggleFollowMode)

InitWinEventHook()
SetTimer(Tick, pollMs)
return

; ======================= ANTI-FLICKER =======================
InitWinEventHook() {
    global hWinEventHook, winEventCb
    EVENT_SYSTEM_FOREGROUND := 0x0003
    WINEVENT_SKIPOWNPROCESS := 0x0002

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

    OnExit(CleanupWinEventHook)
}

CleanupWinEventHook(*) {
    global hWinEventHook, winEventCb
    if (hWinEventHook) {
        DllCall("User32\UnhookWinEvent", "Ptr", hWinEventHook)
        hWinEventHook := 0
    }
    if (winEventCb) {
        CallbackFree(winEventCb)
        winEventCb := 0
    }
}

WinEventProc(hHook, event, hwnd, idObject, idChild, idThread, time) {
    if (event != 0x0003 || hwnd = 0 || idObject != 0)
        return
    PinAllShownOverlays()
}

PinAllShownOverlays() {
    global OverlayShown, lastPinTick, pinThrottleMs
    now := A_TickCount
    if (now - lastPinTick < pinThrottleMs)
        return
    lastPinTick := now

    for ohwnd, shown in OverlayShown {
        if (shown)
            PinTop(ohwnd)
    }
}

PinTop(hwnd) {
    SWP_NOSIZE := 0x0001
    SWP_NOMOVE := 0x0002
    SWP_NOACTIVATE := 0x0010
    SWP_SHOWWINDOW := 0x0040
    flags := SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW

    DllCall("User32\SetWindowPos"
        , "Ptr", hwnd
        , "Ptr", -1
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0
        , "UInt", flags)
}
; ============================================================

ToggleFollowMode(*) {
    global followMode, followModeBehavior, TrackedBrowserHwnd, targetBrowserExe
    followMode := !followMode

    if (followMode) {
        if (followModeBehavior = "single-anywhere") {
            hwnd := WinExist("A")
            proc := hwnd ? TryGetProc(hwnd) : ""
            if (proc = StrLower(targetBrowserExe)) {
                TrackedBrowserHwnd := hwnd
            } else if (!IsValidHwnd(TrackedBrowserHwnd)) {
                TrackedBrowserHwnd := FindAnyTargetBrowserWindow()
            }
            Log("FOLLOW ON (single) | tracked=" HwndHex(TrackedBrowserHwnd))
        } else {
            Log("FOLLOW ON (multi-primary)")
        }
    } else {
        Log("FOLLOW OFF")
    }
}

FindAnyTargetBrowserWindow() {
    global targetBrowserExe
    target := StrLower(targetBrowserExe)
    for hwnd in WinGetList() {
        if !IsValidHwnd(hwnd)
            continue
        if (TryGetProc(hwnd) = target && TryIsVisible(hwnd) && !TryIsMinimized(hwnd))
            return hwnd
    }
    return 0
}

InitOverlaySets(n) {
    global TopGuis, TopHwnds, YtGuis, YtHwnds
    global OverlayHwndSet, OverlayShown, topAlpha, ytAlpha

    Loop n {
        gTop := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
        gTop.BackColor := "Black"
        gTop.Show("NA x0 y0 w1 h1")
        hTop := gTop.Hwnd
        WinSetTransparent(topAlpha, "ahk_id " hTop)
        OverlayHwndSet[hTop] := true
        OverlayShown[hTop] := true
        EnsureShown(hTop, false)

        gYt := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
        gYt.BackColor := "Black"
        gYt.Show("NA x0 y0 w1 h1")
        hYt := gYt.Hwnd
        WinSetTransparent(ytAlpha, "ahk_id " hYt)
        OverlayHwndSet[hYt] := true
        OverlayShown[hYt] := true
        EnsureShown(hYt, false)

        TopGuis.Push(gTop), TopHwnds.Push(hTop)
        YtGuis.Push(gYt),   YtHwnds.Push(hYt)
    }
}

Tick() {
    global TaskGui, TaskHwnd
    global TopHwnds, YtHwnds
    global fallbackTaskbarH, maxBrowserWindows
    global followMode, followModeBehavior

    if !WinExist("ahk_id " TaskHwnd)
        return

    primary := MonitorGetPrimary()
    MonitorGet(primary, &mL, &mT, &mR, &mB)
    MonitorGetWorkArea(primary, &waL, &waT, &waR, &waB)

    taskHReal := mB - waB
    taskH := (taskHReal < 10) ? fallbackTaskbarH : taskHReal
    taskY := (taskHReal < 10) ? (mB - taskH) : waB
    TaskGui.Move(mL, taskY, (mR - mL), taskH)

    fsHwnd := FindFullscreenOnPrimary(mL, mT, mR, mB)
    if (fsHwnd) {
        EnsureShown(TaskHwnd, false)
        Loop maxBrowserWindows {
            i := A_Index
            EnsureShown(TopHwnds[i], false)
            EnsureShown(YtHwnds[i], false)
        }
        return
    }

    EnsureShown(TaskHwnd, true)
    PinTop(TaskHwnd)

    if (followMode) {
        if (followModeBehavior = "single-anywhere")
            RunFollowSingle()
        else
            RunFollowMultiPrimary(primary)
        return
    }

    RunNormalSnapMax(primary, waT, waB)
}

; ---------- follow multi on PRIMARY, anywhere ----------
RunFollowMultiPrimary(primaryMon) {
    global maxBrowserWindows, enableBrowserTopOverlay, enableYouTubeOverlay
    global TopGuis, TopHwnds, YtGuis, YtHwnds
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global followTopOverlayH

    wins := GetBrowserWindowsOnPrimaryAnywhere(primaryMon)
    SortWinsByX(wins)

    Loop maxBrowserWindows {
        i := A_Index
        if (!enableBrowserTopOverlay || i > wins.Length) {
            EnsureShown(TopHwnds[i], false)
            EnsureShown(YtHwnds[i], false)
            continue
        }

        w := wins[i]
        topH := followTopOverlayH  ; <-- ALWAYS 81 in follow mode

        TopGuis[i].Move(w.x, w.y, w.w, topH)
        EnsureShown(TopHwnds[i], true)
        PinTop(TopHwnds[i])

        if (enableYouTubeOverlay && TitleMatches(w.hwnd, youtubeTitleRegex)) {
            ytX := w.x + ytInsetLeft
            ytY := w.y + topH
            ytW := w.w - (ytInsetLeft + ytInsetRight)
            if (ytW < 1)
                ytW := 1
            YtGuis[i].Move(ytX, ytY, ytW, ytOverlayH)
            EnsureShown(YtHwnds[i], true)
            PinTop(YtHwnds[i])
        } else {
            EnsureShown(YtHwnds[i], false)
        }
    }
}

GetBrowserWindowsOnPrimaryAnywhere(primaryMon) {
    global targetBrowserExe
    arr := []
    target := StrLower(targetBrowserExe)

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

        cx := x + w/2, cy := y + h/2
        if (GetMonitorIndexFromPoint(cx, cy) != primaryMon)
            continue

        arr.Push({ hwnd: hwnd, x: x, y: y, w: w, h: h })
    }
    return arr
}

; ---------- follow single anywhere ----------
RunFollowSingle() {
    global TrackedBrowserHwnd, targetBrowserExe
    global TopGuis, TopHwnds, YtGuis, YtHwnds, maxBrowserWindows
    global enableBrowserTopOverlay, enableYouTubeOverlay
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global followTopOverlayH

    Loop maxBrowserWindows {
        if (A_Index > 1) {
            EnsureShown(TopHwnds[A_Index], false)
            EnsureShown(YtHwnds[A_Index], false)
        }
    }

    if (!IsValidHwnd(TrackedBrowserHwnd)
        || TryGetProc(TrackedBrowserHwnd) != StrLower(targetBrowserExe)
        || TryIsMinimized(TrackedBrowserHwnd)
        || !TryIsVisible(TrackedBrowserHwnd)) {

        TrackedBrowserHwnd := FindAnyTargetBrowserWindow()
        if (!TrackedBrowserHwnd) {
            EnsureShown(TopHwnds[1], false)
            EnsureShown(YtHwnds[1], false)
            return
        }
    }

    if (!enableBrowserTopOverlay) {
        EnsureShown(TopHwnds[1], false)
        EnsureShown(YtHwnds[1], false)
        return
    }

    GetBestBounds(TrackedBrowserHwnd, &x, &y, &w, &h)

    topH := followTopOverlayH  ; <-- ALWAYS 81 in follow mode

    TopGuis[1].Move(x, y, w, topH)
    EnsureShown(TopHwnds[1], true)
    PinTop(TopHwnds[1])

    if (enableYouTubeOverlay && TitleMatches(TrackedBrowserHwnd, youtubeTitleRegex)) {
        ytX := x + ytInsetLeft
        ytY := y + topH
        ytW := w - (ytInsetLeft + ytInsetRight)
        if (ytW < 1)
            ytW := 1
        YtGuis[1].Move(ytX, ytY, ytW, ytOverlayH)
        EnsureShown(YtHwnds[1], true)
        PinTop(YtHwnds[1])
    } else {
        EnsureShown(YtHwnds[1], false)
    }
}

; ---------- Normal mode (snap/max on primary workarea) ----------
RunNormalSnapMax(primaryMon, waT, waB) {
    global maxBrowserWindows, enableBrowserTopOverlay, enableYouTubeOverlay
    global TopGuis, TopHwnds, YtGuis, YtHwnds
    global ytOverlayH, ytInsetLeft, ytInsetRight, youtubeTitleRegex
    global topOverlayHMax, topOverlayHSnap, snapTol, minSnapWidthRatio, targetBrowserExe

    MonitorGet(primaryMon, &mL, &mT, &mR, &mB)
    monW := mR - mL
    target := StrLower(targetBrowserExe)

    wins := []
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

        cx := x + w/2, cy := y + h/2
        if (GetMonitorIndexFromPoint(cx, cy) != primaryMon)
            continue

        topOK := Abs(y - waT) <= snapTol
        botOK := Abs((y + h) - waB) <= snapTol
        if (!topOK || !botOK)
            continue

        if (monW > 0 && w < monW * minSnapWidthRatio)
            continue

        leftOK  := Abs(x - mL) <= snapTol
        rightOK := Abs((x + w) - mR) <= snapTol
        isMax := leftOK && rightOK && (w >= (monW - 2*snapTol))
        mode := isMax ? "max" : "snap"
        wins.Push({ hwnd: hwnd, mode: mode, x: x, y: y, w: w, h: h })
    }

    SortWinsByX(wins)

    Loop maxBrowserWindows {
        i := A_Index
        if (!enableBrowserTopOverlay || i > wins.Length) {
            EnsureShown(TopHwnds[i], false)
            EnsureShown(YtHwnds[i], false)
            continue
        }

        w := wins[i]
        topH := (w.mode = "snap") ? topOverlayHSnap : topOverlayHMax

        TopGuis[i].Move(w.x, w.y, w.w, topH)
        EnsureShown(TopHwnds[i], true)
        PinTop(TopHwnds[i])

        if (enableYouTubeOverlay && TitleMatches(w.hwnd, youtubeTitleRegex)) {
            ytX := w.x + ytInsetLeft
            ytY := w.y + topH
            ytW := w.w - (ytInsetLeft + ytInsetRight)
            if (ytW < 1)
                ytW := 1
            YtGuis[i].Move(ytX, ytY, ytW, ytOverlayH)
            EnsureShown(YtHwnds[i], true)
            PinTop(YtHwnds[i])
        } else {
            EnsureShown(YtHwnds[i], false)
        }
    }
}

SortWinsByX(arr) {
    n := arr.Length
    if (n <= 1)
        return
    i := 1
    while (i < n) {
        min := i
        j := i + 1
        while (j <= n) {
            ax := arr[j].x, bx := arr[min].x
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

FindFullscreenOnPrimary(L, T, R, B) {
    global OverlayHwndSet, IgnoreProcs, IgnoreClasses, fsTol

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
        WS_EX_TRANSPARENT := 0x20
        if (ex & WS_EX_TRANSPARENT)
            continue

        GetBestBounds(hwnd, &x, &y, &w, &h)
        if (x <= L + fsTol && y <= T + fsTol && (x + w) >= R - fsTol && (y + h) >= B - fsTol)
            return hwnd
    }
    return 0
}

EnsureShown(hwnd, show) {
    global OverlayShown
    cur := OverlayShown.Has(hwnd) ? OverlayShown[hwnd] : false
    if (show = cur)
        return
    if (show) {
        try WinShow("ahk_id " hwnd)
        OverlayShown[hwnd] := true
    } else {
        try WinHide("ahk_id " hwnd)
        OverlayShown[hwnd] := false
    }
}

TryGetProc(hwnd) {
    proc := ""
    try {
        proc := StrLower(WinGetProcessName("ahk_id " hwnd))
    } catch {
        proc := ""
    }
    return proc
}

TryGetClass(hwnd) {
    cls := ""
    try {
        cls := WinGetClass("ahk_id " hwnd)
    } catch {
        cls := ""
    }
    return cls
}

TryGetExStyle(hwnd) {
    ex := 0
    try {
        ex := WinGetExStyle("ahk_id " hwnd)
    } catch {
        ex := 0
    }
    return ex
}

TryIsVisible(hwnd) {
    try {
        return DllCall("User32\IsWindowVisible", "ptr", hwnd, "int") != 0
    } catch {
        return false
    }
}

TryIsMinimized(hwnd) {
    try {
        return (WinGetMinMax("ahk_id " hwnd) = -1)
    } catch {
        return true
    }
}

IsValidHwnd(hwnd) => hwnd && WinExist("ahk_id " hwnd)

TitleMatches(hwnd, rx) {
    title := ""
    try {
        title := WinGetTitle("ahk_id " hwnd)
    } catch {
        title := ""
    }
    return (title != "" && RegExMatch(title, rx))
}

HwndHex(hwnd) => hwnd ? ("0x" Format("{:X}", hwnd)) : "0x0"

GetBestBounds(hwnd, &x, &y, &w, &h) {
    rect := Buffer(16, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "int", 9, "ptr", rect, "int", 16) = 0) {
        l := NumGet(rect, 0, "int"), t := NumGet(rect, 4, "int")
        r := NumGet(rect, 8, "int"), b := NumGet(rect, 12, "int")
        ww := r - l, hh := b - t
        if (ww > 0 && hh > 0) {
            x := l, y := t, w := ww, h := hh
            return
        }
    }
    wr := Buffer(16, 0)
    if (DllCall("User32\GetWindowRect", "ptr", hwnd, "ptr", wr) != 0) {
        l := NumGet(wr, 0, "int"), t := NumGet(wr, 4, "int")
        r := NumGet(wr, 8, "int"), b := NumGet(wr, 12, "int")
        x := l, y := t, w := r - l, h := b - t
        return
    }
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
}

IsWindowCloaked(hwnd) {
    cloaked := 0
    DWMWA_CLOAKED := 14
    hr := 0
    try {
        hr := DllCall("dwmapi\DwmGetWindowAttribute"
            , "Ptr", hwnd
            , "UInt", DWMWA_CLOAKED
            , "UIntP", &cloaked
            , "UInt", 4
            , "UInt")
    } catch {
        return false
    }
    return (hr = 0) && (cloaked != 0)
}

GetMonitorIndexFromPoint(px, py) {
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

Log(msg) {
    global enableLog, logFile
    if !enableLog
        return
    ts := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    try FileAppend(ts " | " msg "`r`n", logFile, "UTF-8")
}
