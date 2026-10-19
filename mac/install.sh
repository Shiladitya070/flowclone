#!/bin/bash
# Builds FlowClone, replaces /Applications/FlowClone.app with it, and launches it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

pkill -f "FlowClone.app/Contents/MacOS/FlowClone" 2>/dev/null || true
sleep 0.5

DEST=/Applications/FlowClone.app
rm -rf "$DEST"
ditto build/FlowClone.app "$DEST"
echo "Installed $DEST"

SIG_INFO=$(codesign -dv "$DEST" 2>&1 || true)
if [[ "$SIG_INFO" == *"Signature=adhoc"* ]]; then
  echo "Note: ad-hoc signed. macOS may require re-enabling Accessibility after each install:"
  echo "  tccutil reset Accessibility com.flowclone.app"
  echo "  then grant FlowClone Accessibility again in System Settings."
else
  echo "Signed with a stable identity; Microphone and Accessibility permissions should persist."
fi

open "$DEST"
