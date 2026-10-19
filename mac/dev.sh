#!/bin/bash
# Fast dev loop: rebuild, stop any running copy, and run FlowClone in the foreground.
#
# Launched from your terminal, macOS attributes Microphone/Accessibility to the TERMINAL app
# (Terminal, iTerm, Ghostty…), not to FlowClone, so rebuilds no longer reset the permissions.
# Grant your terminal Accessibility + Microphone once. Logs print here; Ctrl+C quits.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -f "FlowClone.app/Contents/MacOS/FlowClone" 2>/dev/null || true
SAVE_AUDIO=1 exec build/FlowClone.app/Contents/MacOS/FlowClone
