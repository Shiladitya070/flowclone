#!/bin/bash
# Builds a universal (Apple Silicon + Intel) FlowClone.app and zips it for a GitHub Release:
#   mac/package.sh  →  dist/FlowClone.zip
# The landing page downloads <repo>/releases/latest/download/FlowClone.zip, so upload it with that name.
#
# Release builds are ad-hoc signed on purpose: an Apple Development certificate embeds your
# name/email in the signature. Set SIGN_ID to a "Developer ID Application" identity if you have one.
set -euo pipefail
cd "$(dirname "$0")"

# LOCK_MODEL=0 builds an unlocked release (model picker and "Retry with Flash" enabled).
if [ "${LOCK_MODEL:-1}" = "1" ]; then FLAGS="-D LOCKED_MODEL"; else FLAGS=""; fi
UNIVERSAL=1 SIGN_ID="${SIGN_ID:--}" SWIFT_FLAGS="$FLAGS" ./build.sh

mkdir -p ../dist
rm -f ../dist/FlowClone.zip
ditto -c -k --keepParent build/FlowClone.app ../dist/FlowClone.zip

echo
lipo -info build/FlowClone.app/Contents/MacOS/FlowClone
echo "Packaged dist/FlowClone.zip ($(du -h ../dist/FlowClone.zip | cut -f1))"
echo "Publish:  gh release create v0.1.0 dist/FlowClone.zip --title 'FlowClone 0.1.0' --notes 'First release'"
