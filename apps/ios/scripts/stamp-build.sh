#!/bin/sh
# Xcode's last build phase for the app (apps/ios/docs/ARCHITECTURE.md §1, D9): writes the build number,
# the commit count as Android's versionCode is, and the short commit into the built Info.plist,
# so the User-Agent and /healthz name the same commit. Outside a checkout the build is 1. A Debug
# build also gets plain HTTP to local addresses, for a dev stack; Release never does.
set -eu

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
build=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || echo 1)
commit=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)

buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Set :CFBundleVersion ${build}" "$plist"
"$buddy" -c "Delete :HMTCommit" "$plist" 2>/dev/null || true
"$buddy" -c "Add :HMTCommit string ${commit}" "$plist"

"$buddy" -c "Delete :NSAppTransportSecurity" "$plist" 2>/dev/null || true
if [ "${CONFIGURATION}" = Debug ]; then
  "$buddy" -c "Add :NSAppTransportSecurity dict" "$plist"
  "$buddy" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
fi
