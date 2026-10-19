#!/bin/bash
# Builds mac/build/FlowClone.app and seeds the config from the repo's .env on first run.
# Signing: $SIGN_ID, else the first Apple Development / Developer ID identity, else ad-hoc.
# A real identity keeps macOS privacy permissions (Mic, Accessibility) across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FlowClone.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SDK=$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)
swiftc -O -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
  -o "$APP/Contents/MacOS/FlowClone" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"

SIGN_IDENTITY="${SIGN_ID:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application): ' \
    | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/' || true)
fi
if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.flowclone.app "$APP"
else
  echo "Signing with: ad-hoc (-); macOS permissions will reset on each rebuild"
  codesign --force --sign - --identifier com.flowclone.app "$APP"
fi

CFG="$HOME/Library/Application Support/FlowClone/config.env"
if [ ! -f "$CFG" ] && [ -f ../.env ]; then
  mkdir -p "$(dirname "$CFG")"
  (umask 077
   grep '^OPENROUTER_API_KEY=' ../.env > "$CFG"
   printf 'MODEL=google/gemini-3.5-flash-lite\nHOTKEY=fn\nDICTIONARY=\nSEND_CONTEXT=1\n' >> "$CFG")
  echo "Seeded $CFG"
fi
echo "Built $APP"
