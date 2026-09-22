#!/bin/sh
# Smoke build for macOS with Xcode installed.
# Usage: sh ci/smoke.sh   (runs from repo root: musemobile-ios/)
set -e
cd "$(dirname "$0")/.."
xcodebuild -project MuseMobileiOS.xcodeproj \
  -scheme MuseMobileiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
echo "SMOKE BUILD OK (unsigned; sign in Xcode for device install)"
