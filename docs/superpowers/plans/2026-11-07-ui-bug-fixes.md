# y1506.bar UI Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three critical UI bugs in `y1506.bar` (Omacale):
1. Resolve the Do Not Disturb toggle oscillation loop where notifications repeatedly cycle between enabled and disabled.
2. Fix show-on-hover for the auto-hiding taskbar and top-edge dashboard by repairing the window input mask and edge hit-testing.
3. Fix workspace overview, wallpaper picker, and theme picker failures caused by null loader references and binding loops.

**Architecture:**
- **DND State:** Target Omarchy 4.5.0's native IPC method (`omarchy-shell -q notifications toggleDnd`) instead of the no-op flag-file command, and read persisted quiet state cleanly from `~/.local/state/omarchy/notifications/quiet.json` without dual-watcher collision.
- **Input Mask & Hover:** Invert `ScreenScope.qml`'s `mask: Region` so the screen borders `[0..Tk.border]` are always included in the window's input mask, while the inner application work area `[win.ax, win.ay, win.aw, win.ah]` is subtracted for window click-through. This allows `MouseArea` to receive edge events for auto-hiding taskbar and top dashboard hover reveal.
- **Pickers & Drawers:** In `ScreenScope.qml`, introduce `launchPendingMode` to buffer picker mode arguments ("wallpapers", "themes") across asynchronous `launchLoader` instantiation, and break the circular binding loop on `overviewLoader.x` and `ofw`.

**Tech Stack:** QML (Qt 6 / Quickshell), JavaScript, Omarchy Shell IPC, Wayland Layer Shell (`wlr-layer-shell`).

**Spec:** User bug report:
1. Show on hover for taskbar and dashboard is not working.
2. Do not disturb is stuck on enabled / cycles repeatedly (ref: uploaded screenshot).
3. Workspace overview, theme picker and wallpaper picker are not working/showing.

---

## Global Constraints

- Never start a second Quickshell process; all shell reloads must go through `omarchy restart shell`.
- Never use `QtQuick.Dialogs` in QML (causes GLib aborts under GTK3 theme).
- Keep all sizes, paddings, and curves bound to `Tk.*` tokens and `Colours.m3*` palette.
- Preserve backward compatibility for older state file formats where reasonable without inducing loops.
- Run `upstream-check` and `test-facade.sh` to ensure contract integrity after edits.

---

## Review Focus

1. **DND Toggle Concurrency:** Toggling DND via quick toggle button or keybind must emit exactly one state notification, never rapid alternating notifications.
2. **Work Area Click-Through:** Modifying the window input mask to include borders must not block pointer events to normal desktop application windows (browsers, terminals).
3. **Multi-Monitor Targeting:** Opening overview, launcher, or pickers via IPC or keyboard must open on the currently focused/active monitor.
4. **Picker Asynchronous Lifecycle:** Opening wallpaper or theme picker when the launcher has never been opened before must cleanly switch to the respective carousel mode on first frame.
5. **Drawer Geometry Stability:** Toggling overview must not trigger `Binding loop detected for property "x"` or leave the panel clipped at zero width.

---

## File Map

| Action | Path | Responsibility |
|:---|:---|:---|
| Modify | [`services/NotifService.qml`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/services/NotifService.qml) | Fix `toggleDnd` IPC call and consolidate DND watcher to `quiet.json` |
| Modify | [`modules/drawers/ScreenScope.qml`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/modules/drawers/ScreenScope.qml) | Fix input mask, edge hover detection, `launchPendingMode`, and `overviewLoader` geometry |
| Modify | [`Bar.qml`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/Bar.qml) | Ensure `openWallpapers()`, `openThemes()`, and `toggle()` pass the active screen reliably |

---

### Task 1: Fix Do Not Disturb Toggle & Watcher Oscillation Loop

**Files:**
- Modify: [`services/NotifService.qml:335-341,480-530`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/services/NotifService.qml#L335-L341)

**Interfaces:**
- Consumes: Omarchy Shell IPC `notifications.toggleDnd`, `~/.local/state/omarchy/notifications/quiet.json`.
- Produces: Stable `root.dnd` property changes emitted only when state actually transitions.

- [ ] **Step 1: Write reproducing verification script**
Create test script `tests/test-dnd-stability.sh` to monitor DND file state and ensure `toggleDnd` directly calls `omarchy-shell -q notifications toggleDnd`.

- [ ] **Step 2: Update `NotifService.qml` `toggleDnd()`**
Change `toggleDnd()` from:
```qml
function toggleDnd() {
  run("omarchy toggle notification silencing || omarchy-shell notifications toggleDnd")
  dndSettle.restart()
}
```
to:
```qml
function toggleDnd() {
  exec(["omarchy-shell", "-q", "notifications", "toggleDnd"])
  dndSettle.restart()
}
```

- [ ] **Step 3: Consolidate DND Watcher in `NotifService.qml`**
Remove `dndQuietWatcher` and `dndWatcher` dual-file oscillation. Use a single primary watcher on `quiet.json` with fallback parsing:
```qml
  property FileView dndWatcher: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readDnd(text())
    onLoadFailed: {
      // Fallback to legacy notifications.json if quiet.json does not exist
      if (path.indexOf("quiet.json") >= 0) {
        path = Quickshell.env("HOME") + "/.local/state/omarchy/notifications.json"
      } else {
        root.dnd = false
      }
    }
  }

  property Timer dndSettle: Timer {
    interval: 250
    repeat: true
    triggeredOnStart: true
    property int left: 0
    onRunningChanged: if (running) left = 4
    onTriggered: {
      root.dndWatcher.reload()
      if (--left <= 0) stop()
    }
  }
```

- [ ] **Step 4: Verify DND toggle via terminal**
Run: `omarchy-shell -q notifications toggleDnd`
Confirm output returns `"on"` or `"off"` without oscillation, and verify `root.dnd` matches disk state.

---

### Task 2: Fix ScreenScope Input Mask & Edge Hover for Taskbar and Dashboard

**Files:**
- Modify: [`modules/drawers/ScreenScope.qml:956-972,1231-1235,1282-1290`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/modules/drawers/ScreenScope.qml#L956-L972)

**Interfaces:**
- Consumes: `scope.cfg.bar.showOnHover`, `scope.cfg.dashboard.showOnHover`, `win.bw`, `win.ax/ay/aw/ah`.
- Produces: Responsive hover triggers for taskbar (`scope.barHover`) and dashboard (`scope.dashboard`) while preserving window pass-through.

- [ ] **Step 1: Invert `ScreenScope.qml` Input Mask**
Update `mask: Region` in `ScreenScope.qml` so that the outer frame bounds `(0, 0, win.width, win.height)` receive mouse input, while the application area `(win.ax, win.ay, win.aw, win.ah)` is subtracted to allow click-through:
```qml
    mask: Region {
      x: 0
      y: 0
      width: win.width
      height: win.height

      // Subtract the central desktop area where applications receive input.
      Region {
        intersection: Intersection.Subtract
        enabled: !win.modal && win.fs < 1
        x: win.ax
        y: win.ay
        width: win.aw
        height: win.ah

        // Re-include open drawers within the work area so they receive input:
        Region { intersection: Intersection.Subtract; enabled: win.dVis; x: win.dx; y: win.ay; width: win.dw; height: Math.max(0, win.dy + win.dh - win.ay) }
        Region { intersection: Intersection.Subtract; enabled: win.lVis; x: win.lx; y: win.ly; width: win.lw; height: Math.max(0, win.ay + win.ah - win.ly) }
        Region { intersection: Intersection.Subtract; enabled: win.cpVis; x: win.cpx; y: win.cpy; width: win.cpw; height: Math.max(0, win.ay + win.ah - win.cpy) }
        Region { intersection: Intersection.Subtract; enabled: win.sVis; x: win.sMaskX; y: win.sy; width: win.sMaskW; height: win.sh }
        Region { intersection: Intersection.Subtract; enabled: win.pVis; x: win.pcx; y: win.pcy; width: win.pcw; height: win.pch }
        Region { intersection: Intersection.Subtract; enabled: win.uVis; x: win.ux; y: win.uMaskY; width: Math.max(0, win.uw); height: win.uMaskH }
        Region { intersection: Intersection.Subtract; enabled: win.sbVis; x: win.sideMaskX(win.sbx); y: win.sby; width: win.sideMaskW(win.sbx, win.sbw); height: win.sbh }
        Region { intersection: Intersection.Subtract; enabled: win.osdVis; x: win.osdMaskX; y: win.osdY; width: win.osdMaskW; height: win.osdH }
        Region { intersection: Intersection.Subtract; enabled: win.th > 0 && !scope.hasFullscreen; x: win.tx; y: win.ty; width: win.tw; height: win.th }
      }
    }
```

- [ ] **Step 2: Adjust `inTopDash` hit threshold**
In `ScreenScope.qml`:
```qml
      function inTopDash(x, y) {
        const visibleH = win.dh * (1 - win.dOff)
        const top = scope.barPos === "top" ? win.ay : 0
        return y >= top && y < Math.max(win.ay + visibleH, top + Math.max(Tk.border, 4)) && x >= win.dx - Tk.borderRounding && x <= win.dx + win.dw + Tk.borderRounding
      }
```

- [ ] **Step 3: Verify Taskbar edge hover sensitivity**
Ensure `depth <= Math.max(Tk.border, 4)` is evaluated properly on edge enter and releases when leaving `depth > Tk.barWidth + Tk.borderRounding`.

---

### Task 3: Fix Wallpaper/Theme Picker Asynchronous Loading and Overview Geometry

**Files:**
- Modify: [`modules/drawers/ScreenScope.qml:288-294,1525-1551,1680-1707`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/modules/drawers/ScreenScope.qml)
- Modify: [`Bar.qml:55-66,563-570`](file:///home/y1506/.config/omarchy/plugins/y1506.bar/Bar.qml)

**Interfaces:**
- Consumes: `openWallpapers()`, `openThemes()`, `toggle("overview")`.
- Produces: Asynchronously buffered carousel mode transitions and stable overview centering without binding loops.

- [ ] **Step 1: Buffer launcher mode across Loader initialization**
In `ScreenScope.qml`, add property `property string launchPendingMode: ""` and update `onToggleRequested`:
```qml
      if (name === "launcher" && scope.cfg.launcher.enabled) {
        const mode = arg === "wallpaper" ? "wallpapers" : arg === "theme" ? "themes" : arg === "menu" ? "menu" : arg === "clipboard" ? "clipboard" : ""
        if (mode && !(scope.launcher && launch && launch.mode === mode)) {
          scope.launchPendingMode = arg
          scope.launcher = true
          if (launch) {
            launch.openMode(arg)
            scope.launchPendingMode = ""
          }
        }
        else scope.launcher = !scope.launcher
      }
```
In `launchLoader`:
```qml
      Loader {
        id: launchLoader
        active: scope.launcher || win.lVis
        focus: scope.launcher
        onLoaded: {
          if (scope.launchPendingMode) {
            item.openMode(scope.launchPendingMode)
            scope.launchPendingMode = ""
          }
        }
        sourceComponent: Launcher {
          ...
        }
      }
```

- [ ] **Step 2: Resolve `overviewLoader.x` binding loop**
In `ScreenScope.qml`, decouple `overviewLoader.x` from the self-referential `win.ox` / `ofw` loop. Centering within `oClip` should be computed based on `oClip.width` and `implicitWidth`:
```qml
        Loader {
          id: overviewLoader
          focus: scope.overview
          x: Math.max(0, Math.round((oClip.width - width) / 2))
          y: Math.max(0, Math.round((oClip.height - height) / 2))
          active: scope.overview || win.oVis
          sourceComponent: Overview {
            width: implicitWidth
            height: implicitHeight
            opacity: win.oOpacity
            transform: Matrix4x4 { matrix: oDeform.matrixAt(width / 2, height / 2) }
            active: scope.overview
            focus: scope.overview
            screen: scope.screen
            onDismissed: scope.overview = false
            onRefocus: win.regrab()
          }
        }
```

- [ ] **Step 3: Ensure `focusedScreen()` handles headless / active monitor fallback**
In `Bar.qml`:
Ensure `focusedScreen()` prefers the monitor containing the pointer cursor if `Hyprland.focusedMonitor` is not currently receiving active pointer events, or fallback cleanly to `Quickshell.screens[0].name`.

---

### Task 4: Integration Verification & Regression Testing

**Files:**
- Test: `tests/test-facade.sh`
- Test: `scripts/upstream-check`

- [ ] **Step 1: Execute static and facade tests**
Run:
```bash
./tests/test-facade.sh
python3 ./scripts/upstream-check
```
Expected: All 34 facade members pass, upstream lock matches.

- [ ] **Step 2: Restart shell cleanly**
Run:
```bash
omarchy restart shell
```
Expected: Shell starts cleanly without QML syntax errors or crashes.

- [ ] **Step 3: Live smoke verification of all three fixes**
1. Test DND: Toggle via `qs -p /usr/share/omarchy/shell ipc call omacale popout utilities` toggle button. Confirm one toast appears.
2. Test Hover: Move cursor to screen edge to verify auto-hide bar reveal and dashboard top hover reveal.
3. Test Pickers & Overview:
   - Run `qs -p /usr/share/omarchy/shell ipc call omacale wallpapers` -> Launcher opens into wallpaper carousel.
   - Run `qs -p /usr/share/omarchy/shell ipc call omacale themes` -> Launcher opens into theme carousel.
   - Run `qs -p /usr/share/omarchy/shell ipc call omacale overview` -> Workspace overview grid displays.

- [ ] **Step 4: Update Knowledge Graph**
Run:
```bash
graphify update .
```
Confirm graph updated without errors.
