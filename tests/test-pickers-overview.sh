#!/usr/bin/env bash
# Verifies that ScreenScope and Bar handle async launcher modes and overview centering cleanly.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREEN_SCOPE="$ROOT/modules/drawers/ScreenScope.qml"

echo "Checking ScreenScope.qml launcher async mode buffering and overview geometry..."

# 1. ScreenScope must have launchPendingMode buffering
if ! grep -q "launchPendingMode" "$SCREEN_SCOPE"; then
  echo "FAIL: ScreenScope.qml lacks launchPendingMode to buffer async launcher modes" >&2
  exit 1
fi

# 2. launchLoader must apply launchPendingMode when loaded
if ! grep -A 10 "id: launchLoader" "$SCREEN_SCOPE" | grep -q "launchPendingMode"; then
  echo "FAIL: launchLoader missing onLoaded handling for launchPendingMode" >&2
  exit 1
fi

# 3. overviewLoader must not use the circular binding that caused 'Binding loop detected for property "x"'
if grep -A 6 "id: overviewLoader" "$SCREEN_SCOPE" | grep -q "x: Math.round(win.ox + (win.ow - width) / 2) - oClip.x"; then
  echo "FAIL: overviewLoader still uses circular reference to win.ox and oClip.x" >&2
  exit 1
fi

echo "Pickers and overview contract checks passed."
exit 0
