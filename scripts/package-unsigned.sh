#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Increment CURRENT_PROJECT_VERSION in project.yml and project.pbxproj before each delivery.
VERSION=$(/usr/bin/sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' tvbox.xcodeproj/project.pbxproj | head -1)
BUILD=$(/usr/bin/sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' tvbox.xcodeproj/project.pbxproj | head -1)
NAME="TVBox-${VERSION}-build.${BUILD}-unsigned"
ARCHIVE="build/${NAME}.xcarchive"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/tvbox-ipa.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p build
set +e
xcodebuild archive -project tvbox.xcodeproj -scheme tvbox -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO > "build/${NAME}.log" 2>&1
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
  echo "==================== XCODEBUILD FAILED (STATUS: $BUILD_STATUS) ===================="
  echo "=== COMPILATION ERRORS ==="
  grep -n -C 5 -E "error:|fatal error:" "build/${NAME}.log" || true
  echo "=== LAST 40 LINES ==="
  tail -n 40 "build/${NAME}.log"
  echo "================================================================================="
  exit $BUILD_STATUS
fi
set -e
mkdir -p "$STAGING/Payload"
ditto "$ARCHIVE/Products/Applications/TVBox.app" "$STAGING/Payload/TVBox.app"
ditto -c -k --keepParent "$STAGING/Payload" "${NAME}.ipa"
unzip -tq "${NAME}.ipa"
echo "Created ${NAME}.ipa"
