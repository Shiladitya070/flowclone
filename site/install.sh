#!/bin/bash
# FlowClone installer for macOS.
#
#   curl -fsSL https://shiladitya070.github.io/flowclone/install.sh | bash
#   curl -fsSL …/install.sh | bash -s -- sk-or-v1-…     # also sets up an invite key
#
# Downloads the latest release, installs it to /Applications (or ~/Applications), saves the
# OpenRouter key if one is given, and opens the app. Downloading with curl avoids the macOS
# "can't be opened" warning that browser downloads of non-notarized apps get.
set -euo pipefail

REPO="Shiladitya070/flowclone"
ZIP_URL="${FLOWCLONE_ZIP_URL:-https://github.com/$REPO/releases/latest/download/FlowClone.zip}"
CONFIG_DIR="${FLOWCLONE_CONFIG_DIR:-$HOME/Library/Application Support/FlowClone}"
KEY="${1:-}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "FlowClone runs on macOS only."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || fail "FlowClone needs macOS 14 (Sonoma) or newer."
if [ -n "$KEY" ] && [[ "$KEY" != sk-or-* ]]; then
  fail "That doesn't look like an OpenRouter key (it should start with sk-or-)."
fi

# /Applications when writable (admin users), otherwise ~/Applications.
APP_DIR="${FLOWCLONE_APP_DIR:-/Applications}"
if [ ! -w "$APP_DIR" ]; then APP_DIR="$HOME/Applications"; mkdir -p "$APP_DIR"; fi
APP="$APP_DIR/FlowClone.app"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

bold "Downloading FlowClone…"
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/FlowClone.zip" || fail "Download failed: $ZIP_URL"
ditto -x -k "$TMP/FlowClone.zip" "$TMP/unzipped"
[ -d "$TMP/unzipped/FlowClone.app" ] || fail "The download didn't contain FlowClone.app."

# Quit the copy being replaced, if it's running.
pkill -f "$APP/Contents/MacOS/FlowClone" 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
ditto "$TMP/unzipped/FlowClone.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
bold "Installed $APP"

if [ -n "$KEY" ]; then
  mkdir -p "$CONFIG_DIR"
  CFG="$CONFIG_DIR/config.env"
  (
    umask 077
    { [ -f "$CFG" ] && grep -v '^OPENROUTER_API_KEY=' "$CFG" || true; } > "$CFG.tmp"
    echo "OPENROUTER_API_KEY=$KEY" >> "$CFG.tmp"
    mv "$CFG.tmp" "$CFG"
  )
  bold "Invite key saved."
fi

if [ -z "${FLOWCLONE_NO_OPEN:-}" ]; then open "$APP"; fi

cat <<'EOF'

Next:
  1. FlowClone opens a Setup Guide: allow Microphone and Accessibility.
  2. Recommended: System Settings › Keyboard › "Press 🌐 key to" → Do Nothing.
  3. Hold Fn anywhere, speak, release. Double-tap Fn for hands-free, Esc to cancel.

The FlowClone window (click the mic in the menu bar › Open FlowClone…) has your history and settings.
EOF
