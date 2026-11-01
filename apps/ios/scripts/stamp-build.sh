#!/bin/sh
# Xcode's last build phase for the app (apps/ios/docs/ARCHITECTURE.md §1, D9): writes the build number,
# the commit count as Android's versionCode is, and the short commit into the built Info.plist,
# so the User-Agent and /healthz name the same commit. A Debug build also gets plain HTTP to local
# addresses, for a dev stack; Release never does.
set -eu

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ "${CONFIGURATION}" = Release ]; then
  # A Release build's number orders it on App Store Connect and against the server's
  # MIN_IOS_BUILD, so it can't be guessed: a shallow clone counts too few commits, and one
  # numbered too low would be refused by the server once the minimum passes it.
  if [ "$(git -C "${SRCROOT}" rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
    echo "error: a Release build needs the full git history for its build number (not a shallow clone or a source export)" >&2
    exit 1
  fi
  build=$(git -C "${SRCROOT}" rev-list --count HEAD)
else
  # Outside a checkout a Debug build is 1.
  build=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || echo 1)
fi
commit=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)

buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Set :CFBundleVersion ${build}" "$plist"
"$buddy" -c "Delete :HMTCommit" "$plist" 2>/dev/null || true
"$buddy" -c "Add :HMTCommit string ${commit}" "$plist"

# Only this one key: any other App Transport Security setting in Config/Info.plist (a pinned
# domain, an exception) is the app's and stays in every build.
"$buddy" -c "Delete :NSAppTransportSecurity:NSAllowsLocalNetworking" "$plist" 2>/dev/null || true
if [ "${CONFIGURATION}" = Debug ]; then
  "$buddy" -c "Add :NSAppTransportSecurity dict" "$plist" 2>/dev/null || true
  "$buddy" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
fi