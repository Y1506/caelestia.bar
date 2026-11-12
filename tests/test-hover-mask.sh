#!/usr/bin/env bash
# Verifies that ScreenScope.qml has proper input mask geometry to allow
# border hover detection for auto-hiding taskbar and dashboard.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREEN_SCOPE="$ROOT/modules/drawers/ScreenScope.qml"

echo "Checking ScreenScope.qml mask and hover geometry..."

# 1. Mask must not start at win.ax/win.ay which clips out borders [0..Tk.border]
if grep -A 5 "mask: Region {" "$SCREEN_SCOPE" | grep -q "x: win.fs >= 1 || win.modal ? 0 : win.ax"; then
  echo "FAIL: mask: Region still starts at win.ax/win.ay, blocking mouse events on screen borders" >&2
  exit 1
fi

# 2. Mask must have outer bounds covering full screen
if ! grep -A 5 "mask: Region {" "$SCREEN_SCOPE" | grep -q "width: win.width"; then
  echo "FAIL: mask: Region missing full width covering screen borders" >&2
  exit 1
fi

# 3. inTopDash must use responsive border threshold, not rigid top + 2
if grep -A 5 "function inTopDash" "$SCREEN_SCOPE" | grep -q "top + 2"; then
  echo "FAIL: inTopDash still uses rigid 'top + 2' px threshold" >&2
  exit 1
fi

echo "ScreenScope.qml hover mask checks passed."
exit 0
