# Taskbar dimmer script for oled displays

AutoHotkey v2 script that draws click-through, semi-transparent black overlays to keep static UI elements from sitting at full brightness — useful for reducing OLED burn-in risk.

What it does:

* Dims the **taskbar area**
* Adds a **top-of-window overlay** on your chosen browser/app windows
* Optional extra **YouTube-only** top overlay (detected via window title)
* Supports **multiple windows on the primary monitor**
* Hides overlays when a **fullscreen app** is detected on the primary monitor

---

## Requirements

* Windows 10/11
* AutoHotkey **v2**

---

## Usage

Run the `.ahk` file.

Hotkey:

* **Ctrl + Alt + F** toggles follow mode

---

## User settings (top of script)

Set the target app:

* `targetBrowserExe` — process name to target (e.g. `msedge.exe`, `chrome.exe`, etc.)

Enable/disable features:

* `enableBrowserTopOverlay` — main top overlay on target windows
* `enableYouTubeOverlay` — extra overlay only when YouTube is detected
* `maxBrowserWindows` — how many windows can be handled at once

Follow mode:

* `followMode` — start enabled or not
* `followHotkey` — hotkey to toggle follow mode
* `followModeBehavior` — `"multi-primary"` (all matching windows on primary) or `"single-anywhere"` (one tracked window)
* `followTopOverlayH` — top overlay height used in follow mode

Overlay sizing:

* `topOverlayHMax` / `topOverlayHSnap` — normal mode top overlay heights
* `ytOverlayH` — YouTube overlay height
* `ytInsetLeft` / `ytInsetRight` — trims YouTube overlay width to avoid borders/scrollbar
* `fallbackTaskbarH` — used if taskbar height can’t be read reliably

Opacity:

* `taskbarAlpha`, `topAlpha`, `ytAlpha` — transparency (0–255, higher = darker)

YouTube detection:

* `youtubeTitleRegex` — regex used to detect YouTube from the window title
