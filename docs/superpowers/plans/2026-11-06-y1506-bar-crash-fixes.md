# Plan: y1506.bar crash fixes after Omarchy 4.5.0-3

**Goal:** Fix the two classes of crash in `y1506.bar` (a fork of `omacale.bar`) introduced by the `omarchy 4.5.0-2 → 4.5.0-3` update on 2026-11-05.

**Architecture:** Quickshell QML bar plugin loaded from `~/.config/omarchy/plugins/y1506.bar`. Entry point `Bar.qml`. Handover scripts (`notif-popups`, `osd-handover`, `lock-screen`) manage clones of Omarchy built-in services. `PluginBarFacade.qml` wraps `PluginBarApi.qml` (the host-bar contract) and is handed to every hosted third-party widget.

**Tech stack:** QML / Quickshell, Python 3 (handover scripts), Omarchy IPC, shell scripts.

**Spec reference:** `CLAUDE.md` rules; Omarchy upstream at `/usr/share/omarchy/`; barContract recorded in `tests/upstream.lock` (baseline: `omarchy-dev 4.0.0.r2186`).

**Global constraints:**
- Never start a second Quickshell process. Always `omarchy restart shell` to reload.
- Never use `QtQuick.Dialogs`. Never copy `omarchy-plugin-clone` logic; call the tool.
- Every new QML type must be in `qmldir`.
- Verify with live log reading (`qs log` or `journalctl --user`), not "it looks fine".
- No code outside `y1506.bar/` changes (except the managed clones that the handover scripts own).
- `upstream.lock` is **not** updated until all fixes are confirmed (Task 6).

**Review focus:**
- Are all removed `PluginBarApi` members still referenced anywhere in `Bar.qml` or `PluginBarFacade.qml`?
- Does `notif-popups sync` now exit with `patch: applied`?
- Does `lock-screen status` show `stale: no`?
- Do QML WARNs for the bar disappear from the shell log after restart?

---

## Diagnosis summary

`upstream-check` and manual hash comparison show that **every tracked upstream file changed** since the lock was recorded against `omarchy-dev 4.0.0.r2186`. The critical breakages for the two reported crash classes:

### Crash class 1 — Bar instability / plugin reload storm

The shell log shows `y1506omacale.bar` and `y1506.bar` both triggering repeated "Local plugin changed, reloading" storms — the QML engine keeps rejecting the bar and retrying. This happens because `PluginBarApi.qml` added several new properties/functions in 4.5.0-3 that `PluginBarFacade.qml` does not yet wire:

| New in upstream `PluginBarApi` | In `PluginBarFacade.qml`? |
|---|---|
| `traySectionDragActive` (bool) | ❌ missing |
| `traySectionPopoutOpen` (bool) | ❌ missing |
| `notePopoutCard(card)` function | ❌ missing |
| `popoutCardFor(owner)` function | ❌ missing |
| `_notePopoutCard` / `_popoutCardFor` callbacks | ❌ missing |
| `_setCenterHoverRevealSuppressed` callback | ✅ already stub-safe |
| `_run` callback / `run(command)` function | ✅ already implemented |
| `registerClickTarget` / `unregisterClickTarget` | ✅ already implemented |

The host-side `Bar.qml` also needs `notePluginPopoutCard` and `pluginPopoutCardFor` to match.

### Crash class 2 — Notification service broken (confirmed by script output)

```
notif-popups status:
  patch:    refused
  reason:   Omarchy's notification daemon no longer has the popup UI section this patch replaces
  stale:    yes  (stale-files: Service.qml)
  daemon:   stock (draws its own toasts)

notif-popups health:
  health:   fail
  reason:   the notification daemon is not Omacale's clone (no `omacalePopups`)
```

**Root cause:** Omarchy 4.5.0-3 rewrote `shell/plugins/notifications/Service.qml` (1664 lines, changed hash) and decomposed `NotificationLogic.js` into seven separate files (`Delivery.js`, `Detect.js`, `Icons.js`, `Layout.js`, `Markup.js`, `Security.js`, `Store.js`). The patch inside `notif-popups` that carves out the popup-window block no longer applies to the new file shape. **The safety net is working correctly** — the clone was left as-is; toasts draw via Omarchy's stock window (non-crashing but Omacale popup UI is inactive).

### Other changed upstreams (re-verification needed, not crash-critical)

| File | Status | Risk |
|---|---|---|
| `shell/plugins/lock/Service.qml` | CHANGED | `lock-screen install` re-copies verbatim |
| `shell/plugins/lock/LockView.qml` | CHANGED | Wrapper properties may need update |
| `shell/plugins/lock/LockFeedSurface.qml` | **MISSING** | ⚠️ If wrapper imports it, crash |
| `shell/Ui/KeyboardPanel.qml` | CHANGED | `notePopoutCard`/`popoutCardFor` consumer |
| `shell/Commons/Style.qml` | CHANGED | Token names; watch for WARN |
| `shell/plugins/osd/Osd.qml` + `OsdModel.js` | CHANGED | `osd-handover sync` needed |
| `shell/plugins/menu/MenuModel.js` | CHANGED | `MenuService.qml` already handles gracefully |
| `bin/omarchy-plugin-clone` | CHANGED | Handover scripts call it |
| Others (AppLibrary, BrightnessKeys, clipboard, media) | CHANGED | Scan log in Task 5 |

---

## Task list

### Task 0 — Pre-flight: capture shell log baseline

**Goal:** Know what errors exist now, so post-fix verification has a diff.

**Files:** None (read-only diagnostic)

**Steps:**
1. Capture current log:
   ```bash
   journalctl --user -b 0 -n 200 | grep -iE "y1506|omacale|ERROR|WARN.*bar|WARN.*notification|WARN.*osd" | tail -60
   ```
2. Test bar IPC:
   ```bash
   qs ipc call omacale barFocus 2>&1 || true
   ```
3. Record shell PID: `pgrep -u "$USER" quickshell`

**Verification:** Baseline captured. No code changes.

---

### Task 1 — Fix `PluginBarFacade.qml`: wire missing API members

**Goal:** Implement `notePopoutCard`, `popoutCardFor`, `traySectionDragActive`, `traySectionPopoutOpen` so hosted widgets calling the new API don't get `undefined`.

**Files:**
- `modules/bar/PluginBarFacade.qml` (edit)
- `Bar.qml` (edit — add `notePluginPopoutCard` and `pluginPopoutCardFor`)

**Interfaces:**
- `PluginBarFacade.notePopoutCard(card)` → calls `host.notePluginPopoutCard(facade, card)`
- `PluginBarFacade.popoutCardFor(owner)` → calls `host.pluginPopoutCardFor(facade, owner)` → returns `null` if unset
- `PluginBarFacade.traySectionDragActive` → `readonly property bool` stub, always `false`
- `PluginBarFacade.traySectionPopoutOpen` → `readonly property bool` stub, always `false`

**TDD steps:**
1. Add to `PluginBarFacade.qml` (after `centerSectionRevealHeld`):
   ```qml
   readonly property bool traySectionDragActive: false
   readonly property bool traySectionPopoutOpen: false
   ```
2. Add functions (after `setCenterHoverRevealSuppressed`):
   ```qml
   function notePopoutCard(card) { _call("notePluginPopoutCard", [facade, card]) }
   function popoutCardFor(owner) { return _call("pluginPopoutCardFor", [facade, owner], null) }
   ```
3. In `Bar.qml`, add near `pluginPopoutOwners`:
   ```qml
   property var pluginPopoutCards: ({})
   function notePluginPopoutCard(facade, card) {
     pluginPopoutCards[facade.moduleName] = card
   }
   function pluginPopoutCardFor(facade, owner) {
     return pluginPopoutCards[facade.moduleName] || null
   }
   ```
4. `omarchy restart shell`.
5. Check: `journalctl --user -b 0 -n 50 | grep -iE "ERROR|WARN.*popout|y1506"`.

**Verification:**
```bash
qs ipc call omacale barFocus
journalctl --user -b 0 -n 50 | grep -iE "y1506|omacale" | grep -v "changed, reloading"
```
Expect: `barFocus` succeeds, no new WARNs.

**Commit:** `fix: wire notePopoutCard/popoutCardFor and tray stubs in PluginBarFacade`

---

### Task 2 — Fix notification handover: update `notif-popups` patch

**Goal:** Make `notif-popups sync` exit with `patch: applied` against the new 1664-line `Service.qml`.

**Files:**
- `scripts/notif-popups` (edit — update embedded patch + bump `MARKER` to `v3`)
- `scripts/notifs.py` (review — may reference `NotificationLogic.js` which is gone)

**Interfaces:**
- `notif-popups status` → `patch: applied`, `stale: no`
- `notif-popups health` exits `0`
- Clone still exposes `omacalePopups` IPC target
- `NotifHandover.qml` / `NotifService.qml` unaffected (they read state files, not the clone)

**TDD steps:**
1. Inspect the popup block in new `Service.qml`:
   ```bash
   grep -n "PanelWindow\|LayerSurface\|WlrLayerSurface\|toasts\|ListModel\|overlay\|claim" /usr/share/omarchy/shell/plugins/notifications/Service.qml | head -40
   ```
2. Find the exact line range the patch must gate (the popup draw window controlled by `deckDisplayName`/`showsOn`).
3. Rewrite the patch heredoc in `scripts/notif-popups` to match the new context lines (keeping the claim-check and lifetime-manager additions from the original patch intent).
4. Bump `MARKER = "omacale:headless-popups v3"`.
5. Run `python3 scripts/notif-popups sync` — exits `0`.
6. Run `python3 scripts/notif-popups status` — verify `patch: applied`, `stale: no`.
7. Run `omarchy restart shell`.
8. Run `python3 scripts/notif-popups health` — exits `0`.
9. Check `notifs.py` for any `NotificationLogic` import — if found, replace with the appropriate new module (`Markup.py` → `Markup.js`, etc.) or remove if Omarchy now handles it internally.

**Verification:**
```bash
python3 scripts/notif-popups status
# patch: applied  stale: no
python3 scripts/notif-popups health; echo "exit:$?"
# health: ok  exit:0
notify-send "Smoke test" "Omacale notif fix"
# Toast appears in Omacale's popup style
```

**Commit:** `fix: update notif-popups patch for new notifications/Service.qml shape`

---

### Task 3 — Re-sync OSD handover

**Goal:** Rebuild OSD clone against new `Osd.qml` and `OsdModel.js`.

**Files:**
- `scripts/osd-handover` (patch update if refused; sync if stale)
- Clone at `~/.config/omarchy/plugins/y1506.osd` (managed by script)

**TDD steps:**
1. `python3 scripts/osd-handover status` — note `patch:` field.
2. If `patch: refused`: diff new `Osd.qml`, update heredoc + bump `MARKER`.
3. If `patch: applied` + `stale: yes`: `python3 scripts/osd-handover sync`.
4. `omarchy restart shell`.
5. Press a volume key — OSD appears in Omacale style.

**Verification:**
```bash
python3 scripts/osd-handover status | grep "patch:\|stale:"
# patch: applied  stale: no
```

**Commit:** `fix: sync osd-handover patch for new Osd.qml/OsdModel.js`

---

### Task 4 — Re-sync lock-screen handover

**Goal:** Re-copy new `Service.qml` into lock clone; audit `LockView.qml` changes and `LockFeedSurface.qml` disappearance.

**Files:**
- `scripts/lock-screen` (read; may need MARKER bump if wrapper changed)
- `assets/lock/LockView.qml` (edit — `stockOptional` audit + `LockFeedSurface` fallback)
- Clone at `~/.config/omarchy/plugins/y1506.lock` (managed by script)

**TDD steps:**
1. Check `LockFeedSurface.qml` existence:
   ```bash
   find /usr/share/omarchy -name "LockFeedSurface*"
   grep -rn "LockFeedSurface" assets/lock/
   ```
   If the asset still imports it and it's gone: add a `Loader`-based fallback or remove the import.
2. `bash scripts/lock-screen status` — note `stale:`, `view:`, `expects:` fields.
3. Diff new vs old `LockView.qml`: identify any new required properties, add to `stockOptional` if optional.
4. If `view: stale`: `bash scripts/lock-screen install` (re-copies `Service.qml` verbatim).
5. If wrapper content changed: bump `MARKER` in `scripts/lock-screen` and line 1 marker in `assets/lock/LockView.qml` together.
6. `bash scripts/lock-screen health` — exits `0`.
7. `omarchy system lock` — verify lock screen appears and unlocks.

**Verification:**
```bash
bash scripts/lock-screen status
# stale: no   view: matches expects
bash scripts/lock-screen health; echo "exit:$?"
# exit:0
```

**Commit:** `fix: re-sync lock-screen for 4.5.0-3 LockView changes`

---

### Task 5 — Shell log audit: remaining WARNs from other changed upstreams

**Goal:** After Tasks 1–4 and a fresh shell restart, eliminate any remaining y1506.bar WARNs from other changed upstream files (`Style.qml`, `KeyboardPanel.qml`, `AppLibrary.qml`, etc.).

**Steps:**
1. `omarchy restart shell` (fresh boot of changes).
2. Wait 15 seconds:
   ```bash
   journalctl --user -b 0 -n 300 | grep -iE "y1506|omacale|ERROR|WARN" \
     | grep -v "lock-explorer\|quick-reference\|ggregoro\|jetbrains\|Dictation"
   ```
3. For each WARN in a y1506.bar file: open file, fix usage.
4. Common patterns:
   - `Unable to assign [undefined]` → renamed/removed property
   - `ReferenceError: X is not defined` → JS function gone from updated Omarchy module
   - `Indicator loader error Dictation` → known benign Omarchy WARN, skip

**Verification:**
```bash
journalctl --user -b 0 -n 200 | grep -iE "y1506|omacale" | grep -v "changed, reloading\|Dictation"
# Empty or DEBUG/INFO lines only
```

**Commit:** (per-fix, e.g. `fix: update AppLibrary usage for 4.5.0-3`)

---

### Task 6 — Update `tests/upstream.lock` baseline

> [!IMPORTANT]
> Only after all tasks above are verified clean. Updating earlier silences the signal.

**Goal:** Re-record all upstream hashes against `omarchy 4.5.0-3`.

**Files:** `tests/upstream.lock`

**Steps:**
```bash
cd /home/y1506/.config/omarchy/plugins/y1506.bar
python3 - <<'EOF'
import json, hashlib, os
lock = json.load(open('tests/upstream.lock'))
base = '/usr/share/omarchy'
for rel in lock['files']:
    p = os.path.join(base, rel)
    if os.path.exists(p):
        h = hashlib.sha256(open(p,'rb').read()).hexdigest()
        lock['files'][rel] = h
    else:
        print(f'MISSING (remove or update path): {rel}')
lock['omarchy'] = 'omarchy 4.5.0-3'
lock['recorded'] = '2026-11-06'
print(json.dumps(lock, indent=2))
EOF
```
Review output, remove MISSING entries that are genuinely gone (e.g. `LockFeedSurface.qml`), update `barContract` list to match current `PluginBarApi.qml`, write to file.

**Verification:**
```bash
bash scripts/upstream-check
# All OK lines, no CHANGED
```

**Commit:** `chore: update upstream.lock to omarchy 4.5.0-3`

---

### Task 7 — Version bump + CHANGELOG

**Goal:** Bump `manifest.json`, `scripts/omacale`, `Bar.qml`. Add `CHANGELOG.md` entry.

**Version:** `0.54.1` → `0.54.2`

**CHANGELOG entry:**
```md
## 0.54.2 - 2026-11-06

### Fixed
- **bar**: Wire `notePopoutCard`/`popoutCardFor` and tray stubs in `PluginBarFacade` for Omarchy 4.5.0-3
- **notifications**: Update `notif-popups` patch for restructured `Service.qml` / new JS helper split
- **osd**: Re-sync OSD handover patch for new `Osd.qml`/`OsdModel.js`
- **lock**: Re-sync lock-screen handover for new `LockView.qml`; handle `LockFeedSurface` removal
```

**Final smoke test (must all pass):**
```bash
qs ipc call omacale barFocus
python3 scripts/notif-popups health; echo "exit:$?"
python3 scripts/osd-handover status | grep "patch:"
bash scripts/lock-screen health; echo "exit:$?"
journalctl --user -b 0 -n 300 | grep -iE "y1506|omacale" | grep -v "changed, reloading\|Dictation"
notify-send "Smoke test" "y1506.bar 0.54.2"
```

**Commit:** `bump: 0.54.2 — fix crashes after omarchy 4.5.0-3`

---

## Self-review checklist

- [x] Goal is clear and scoped to two crash classes from one update
- [x] Root causes are evidence-based (hash diffs, `notif-popups status` output, log inspection)
- [x] Tasks are ordered correctly (fix → audit → lock update → version bump)
- [x] CLAUDE.md constraints respected throughout (no `QtQuick.Dialogs`, `Service.qml` copied not patched, `omarchy restart shell` only)
- [x] Safety net behaviour preserved — notif patch fail leaves clone intact
- [x] `LockFeedSurface.qml` MISSING flagged for investigation before writing any lock code
- [x] `upstream.lock` update is last (Task 6), after all fixes verified
- [x] Version bump is last (Task 7), matches CLAUDE.md requirement
- [x] All verification commands are specific and runnable
