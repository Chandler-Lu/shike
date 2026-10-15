#!/bin/bash
# Compile only. Never archives, exports, installs or uploads an app.
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:-ios}"
case "$platform" in
  ios|ipad) scheme=Shike; destination='generic/platform=iOS Simulator' ;;
  mac) scheme=ShikeMac; destination='platform=macOS,variant=Mac Catalyst' ;;
  watch) scheme=ShikeWatch; destination='generic/platform=watchOS Simulator' ;;
  *) echo 'Usage: scripts/build_debug.sh [ios|ipad|mac|watch]' >&2; exit 2 ;;
esac
xcodebuild -project Shike.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$destination" -derivedDataPath "build/debug-$platform" \
  CODE_SIGNING_ALLOWED=NO build
