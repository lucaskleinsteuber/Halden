#!/bin/bash
# The app's UI tests in the simulator, against a real Halden server started here for the time of
# the tests (the simulator reaches the Mac on 127.0.0.1). Extra arguments go to xcodebuild, e.g.
#   ios/ui-tests.sh -only-testing:HaldenUITests/HaldenUITests/testSigningInWithAPasswordAgainstTheRealServer
set -euo pipefail
cd "$(dirname "$0")"
server=${HALDEN_SERVER:-$PWD/../server/target/debug/halden}
[ -x "$server" ] || { echo "Build the server first: cd server && cargo build" >&2; exit 1; }
work=$(mktemp -d)
password="ui tests password $RANDOM$RANDOM"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
config=(--config "$work/config.toml")
"$server" "${config[@]}" setup --name ui-tests --data-dir "$work/data" --library-dir "$work/library" > /dev/null
"$server" "${config[@]}" config set server.bind 127.0.0.1 > /dev/null
"$server" "${config[@]}" config set server.port "$port" > /dev/null
"$server" "${config[@]}" config set network.bonjour false > /dev/null
printf '%s\n' "$password" | "$server" "${config[@]}" user add lucas --owner > /dev/null
"$server" "${config[@]}" serve > "$work/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2> /dev/null; wait $pid 2> /dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 100); do
  "$server" "${config[@]}" health > /dev/null 2>&1 && break
  sleep 0.1
done
device=${SIMULATOR:-$(xcrun simctl list devices available -j \
  | jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[] | select(.name | test("iPhone"))][0].udid')}
TEST_RUNNER_HALDEN_TEST_SERVER="127.0.0.1:$port" TEST_RUNNER_HALDEN_TEST_PASSWORD="$password" \
  xcodebuild test -project Halden.xcodeproj -scheme Halden -destination "id=$device" \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO "$@"
