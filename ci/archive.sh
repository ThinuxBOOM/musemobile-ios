#!/bin/sh
# Archive + export a signed IPA for sideloading (macOS + Xcode required).
# Usage:
#   TEAM_ID=ABCDE12345 sh ci/archive.sh [development|ad-hoc]
# Output: build/MuseMobileiOS.ipa  → attach to the GitHub release.
set -e
METHOD="${1:-development}"
if [ -z "$TEAM_ID" ]; then
  echo "ERROR: set TEAM_ID first (Apple Developer portal → Membership → Team ID)"
  echo "  TEAM_ID=ABCDE12345 sh ci/archive.sh development"
  exit 1
fi
cd "$(dirname "$0")/.."
sed "s/YOUR_TEAM_ID/$TEAM_ID/" "ci/exportOptions-$METHOD.plist" > build/exportOptions.plist 2>/dev/null || {
  mkdir -p build
  sed "s/YOUR_TEAM_ID/$TEAM_ID/" "ci/exportOptions-$METHOD.plist" > build/exportOptions.plist
}
xcodebuild archive \
  -project MuseMobileiOS.xcodeproj \
  -scheme MuseMobileiOS \
  -configuration Release \
  -archivePath build/MuseMobileiOS.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID"
xcodebuild -exportArchive \
  -archivePath build/MuseMobileiOS.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/exportOptions.plist
echo "IPA: build/export/MuseMobileiOS.ipa"
