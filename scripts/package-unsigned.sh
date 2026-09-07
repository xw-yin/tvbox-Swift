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
xcodebuild archive -project tvbox.xcodeproj -scheme tvbox -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO > "build/${NAME}.log" 2>&1
mkdir -p "$STAGING/Payload"
ditto "$ARCHIVE/Products/Applications/TVBox.app" "$STAGING/Payload/TVBox.app"
ditto -c -k --keepParent "$STAGING/Payload" "${NAME}.ipa"
unzip -tq "${NAME}.ipa"
echo "Created ${NAME}.ipa"
