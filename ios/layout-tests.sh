#!/bin/bash
# Checks the layout of every screen (UITests/LayoutTests.swift: nothing cut off by the edge of the
# screen, no controls on top of each other, buttons big enough) on the smallest and the biggest
# iPhone, each also with big text, and keeps a screenshot of every screen in
# Local/screens/<date>/<device>/ to look at. Needs no server. Extra arguments go to xcodebuild.
set -euo pipefail
cd "$(dirname "$0")"
out=${SCREENS:-$PWD/../Local/screens/$(date +%d.%m.%Y)}
status=0
for type in iPhone-16e iPhone-17-Pro-Max; do
  name="Halden $type"
  device=$(xcrun simctl list devices available -j | jq -r --arg n "$name" '[.devices[][] | select(.name == $n)][0].udid // empty')
  if [ -z "$device" ]; then
    runtime=$(xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | last | .identifier')
    device=$(xcrun simctl create "$name" "com.apple.CoreSimulator.SimDeviceType.$type" "$runtime")
  fi
  xcrun simctl boot "$device" 2> /dev/null || true
  rm -rf "${out:?}/$type"
  TEST_RUNNER_HALDEN_SCREENSHOTS="$out/$type" xcodebuild test -project Halden.xcodeproj -scheme Halden \
    -destination "id=$device" -only-testing:HaldenUITests/LayoutTests -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO "$@" || status=1
done
echo "Screenshots: $out"
exit $status
