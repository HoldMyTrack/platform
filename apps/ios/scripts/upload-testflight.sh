#!/bin/sh
# Archives the Release build of the checked-out commit and uploads it to App Store Connect for
# TestFlight (docs/DEPLOY.md §10). Needs Xcode signed in to the team's Apple account and
# Config/Signing.xcconfig; run `make e2e-ios` on the same commit first.
#
# Automatic signing archives with a development profile, which Apple issues only to a team with a
# registered iPhone. So the archive is built unsigned, each bundle is signed ad hoc with
# Config/HoldMyTrack.entitlements so it declares its capabilities, and the export signs it with
# Apple's cloud-managed distribution certificate, which keeps what the ad-hoc signature declared.
# Unsigned, the export drops Sign in with Apple, so the exported app is checked for it before upload.
set -eu
cd "$(dirname "$0")/.."

if ! git diff --quiet HEAD -- . ; then
  echo "error: apps/ios has uncommitted changes; upload a committed build" >&2
  exit 1
fi
team=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Signing.xcconfig)
[ -n "$team" ] || { echo "error: no DEVELOPMENT_TEAM in Config/Signing.xcconfig" >&2; exit 1; }
entitlements=Config/HoldMyTrack.entitlements

work=$(mktemp -d)
archive="$work/HoldMyTrack.xcarchive"
echo "Building in $work"

xcodebuild archive -project HoldMyTrack.xcodeproj -scheme HoldMyTrack -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" CODE_SIGNING_ALLOWED=NO \
  > "$work/archive.log" 2>&1 || { tail -20 "$work/archive.log"; exit 1; }

app="$archive/Products/Applications/HoldMyTrack.app"
for framework in "$app"/Frameworks/*.framework; do
  [ -e "$framework" ] && codesign -f -s - "$framework"
done
for appex in "$app"/PlugIns/*.appex; do
  [ -e "$appex" ] && codesign -f -s - --entitlements "$entitlements" "$appex"
done
codesign -f -s - --entitlements "$entitlements" "$app"

options() {
  cat > "$work/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$1</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/>
</dict></plist>
EOF
}

options export
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/export" \
  -exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates \
  > "$work/export.log" 2>&1 || { tail -20 "$work/export.log"; exit 1; }
mkdir "$work/ipa"
(cd "$work/ipa" && unzip -q ../export/HoldMyTrack.ipa)
signed="$work/ipa/Payload/HoldMyTrack.app"
if ! codesign -d --entitlements - --xml "$signed" 2>/dev/null | grep -q com.apple.developer.applesignin; then
  echo "error: the exported app lost Sign in with Apple; nothing was uploaded" >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$signed/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$signed/Info.plist")
echo "Uploading $version ($build), commit $(git rev-parse --short HEAD)"

options upload
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/upload" \
  -exportOptionsPlist "$work/upload.plist" -allowProvisioningUpdates \
  > "$work/upload.log" 2>&1 || { tail -20 "$work/upload.log"; exit 1; }
grep -E "Upload succeeded|warning:" "$work/upload.log" || true
echo "Uploaded $version ($build); tag it: git tag ios/$build $(git rev-parse --short HEAD) && git push origin ios/$build"
