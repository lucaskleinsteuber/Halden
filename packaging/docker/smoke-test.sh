#!/bin/bash
# Starts the image like a user would (read-only, volumes owned by the container's user), sets up
# an account and talks to it from outside. Used by CI: packaging/docker/smoke-test.sh <image>
set -euo pipefail
image=$1
name=halden-smoke
work=$(mktemp -d)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; sudo rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/config" "$work/data" "$work/library"
sudo chown -R 10001:10001 "$work"

docker run -d --name "$name" -p 47130:47130 -e HALDEN_NAME=smoke --read-only --tmpfs /tmp \
  -v "$work/config:/config" -v "$work/data:/data" -v "$work/library:/library" "$image" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$name" halden health >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$name" halden health
[ "$(docker exec "$name" id -u)" = 10001 ] || { echo "the server must not run as root" >&2; exit 1; }
docker exec "$name" halden doctor || true
echo "smoke test password" | docker exec -i "$name" halden user add smoke --owner >/dev/null

base=https://127.0.0.1:47130/api/v1
curl -fsSk "$base/server" | jq -e '.name == "smoke" and .apiVersion == 1' >/dev/null
token=$(curl -fsSk -H 'content-type: application/json' \
  -d '{"username":"smoke","password":"smoke test password","device":{"name":"CI","platform":"ios","installationId":"ci"}}' \
  "$base/auth/login" | jq -r .token)
curl -fsSk -H "authorization: Bearer $token" "$base/me" | jq -e '.user.username == "smoke"' >/dev/null
curl -fsSk -H "authorization: Bearer $token" "$base/admin/update" | jq -e '.inDocker == true and .canInstall == false' >/dev/null
# ffmpeg and libheif are in the image and work.
docker exec "$name" halden doctor --json | jq -e '[.report.checks[] | select(.id == "ffmpeg" or .id == "libheif") | .level] == ["ok","ok"]' >/dev/null
# Settings changed in the terminal are picked up without a restart.
docker exec "$name" halden config set library.trash_days 45 >/dev/null
sleep 7
curl -fsSk -H "authorization: Bearer $token" "$base/admin/config" \
  | jq -e '.settings[] | select(.name == "library.trash_days") | .value == 45' >/dev/null
echo "Docker smoke test passed."
