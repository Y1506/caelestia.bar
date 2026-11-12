#!/usr/bin/env bash
# Verifies DND toggle stability and checks that NotifService uses direct
# shell IPC and does not oscillate between quiet.json and notifications.json.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIF_QML="$ROOT/services/NotifService.qml"

echo "Checking NotifService.qml implementation..."

# 1. Must use direct omarchy-shell IPC for toggling DND
if grep -q 'omarchy toggle notification silencing' "$NOTIF_QML"; then
  echo "FAIL: NotifService.qml still contains broken 'omarchy toggle notification silencing'" >&2
  exit 1
fi

if ! grep -q 'omarchy-shell.*notifications.*toggleDnd' "$NOTIF_QML"; then
  echo "FAIL: NotifService.qml missing direct 'omarchy-shell -q notifications toggleDnd'" >&2
  exit 1
fi

# 2. Must not have conflicting dndQuietWatcher AND dndWatcher reloading simultaneously
if grep -q 'dndQuietWatcher' "$NOTIF_QML" && grep -q 'dndWatcher' "$NOTIF_QML"; then
  echo "FAIL: Both dndQuietWatcher and dndWatcher are present, risking dual-file oscillation" >&2
  exit 1
fi

echo "NotifService.qml static contract checks passed."
exit 0
