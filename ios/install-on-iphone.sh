#!/bin/bash
# Builds the app and installs it on your iPhone (cable or Wi-Fi). The signing team comes from
# Config/Local.xcconfig. With a free developer account the app runs 7 days, then install again.
#
#   ios/install-on-iphone.sh            the first connected iPhone
#   ios/install-on-iphone.sh <udid>     this one (`xcrun devicectl list devices`)
set -euo pipefail
cd "$(dirname "$0")"
device=${1:-}
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available|connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
fi
[ -n "$device" ] || { echo "No iPhone found. Connect it by cable once and turn on Developer Mode." >&2; exit 1; }
[ -f Config/Local.xcconfig ] || { echo "Put DEVELOPMENT_TEAM = <your team id> into ios/Config/Local.xcconfig first." >&2; exit 1; }
build=$(mktemp -d)
xcodebuild -project Halden.xcodeproj -scheme Halden -configuration Debug -destination "generic/platform=iOS" \
  -derivedDataPath "$build" -allowProvisioningUpdates build -quiet
xcrun devicectl device install app --device "$device" "$build/Build/Products/Debug-iphoneos/Halden.app"
echo "Halden is on the iPhone. Open it there."
