#!/bin/bash
# The whole server on a fresh Linux with systemd, as an owner would run it. For CI (Ubuntu
# runners have root and systemd); needs: curl jq openssl minisign ffmpeg libheif-examples python3.
#
#   packaging/tests/system-test.sh <halden 0.0.1> <halden 0.0.2>
#
# Both programs must be debug builds made with HALDEN_BUILD_VERSION=0.0.1 / 0.0.2: only debug
# builds let the updater be pointed at the stand-in for GitHub this script serves. It:
#
#  1. publishes signed releases on a stand-in for GitHub (a local web server),
#  2. installs 0.0.1 with get-halden.sh, which checks the signature with openssl,
#  3. checks the hardened systemd service, `halden doctor`, and the API from outside,
#  4. uploads a real HEIC photo, an HEVC video and a JPEG; the server makes thumbnails with
#     ffmpeg and libheif inside the systemd sandbox (nice/ionice, syscall filter) and a copy in
#     another format; a mirror under /mnt gets checked copies,
#  5. updates to 0.0.2 from the app (request file, path unit, root updater),
#  6. offers a broken 0.0.3, which doesn't start: the updater goes back to 0.0.2 and its data,
#  7. checks every file with `halden doctor --files`, backs up and restores the database.
set -euo pipefail

v1=$(realpath "$1")
v2=$(realpath "$2")
here=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
site="$work/site"
mkdir -p "$site/files"
port=8765
api=https://127.0.0.1:47130/api/v1
password="system test password"

step() { echo; echo "=== $*"; }
fail() { echo "FAILED: $*" >&2; sudo journalctl -u halden -n 80 --no-pager >&2 || true; exit 1; }

cleanup() {
  [ -n "${web:-}" ] && kill "$web" 2>/dev/null || true
}
trap cleanup EXIT

step "Signing key and a stand-in for GitHub"
minisign -G -W -p "$work/key.pub" -s "$work/key.sec" >/dev/null
key=$(sed -n 2p "$work/key.pub")
echo '[]' > "$site/releases.json"
(cd "$site" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
web=$!
sleep 1

# publish <version> <program> [prerelease]: packs, checksums, signs and lists a release.
publish() {
  local version=$1 program=$2 prerelease=${3:-false} folder="halden-$1-x86_64-linux"
  local staging="$work/staging-$version"
  mkdir -p "$staging/$folder/systemd"
  install -m 755 "$program" "$staging/$folder/halden"
  cp "$here/packaging/linux/install.sh" "$staging/$folder/"
  cp "$here"/packaging/systemd/halden*.service "$here"/packaging/systemd/halden*.path "$staging/$folder/systemd/"
  tar -C "$staging" -czf "$site/files/$folder.tar.gz" --owner=0 --group=0 "$folder"
  (cd "$site/files" && sha256sum "$folder.tar.gz" > "$version-SHA256SUMS")
  minisign -S -s "$work/key.sec" -m "$site/files/$version-SHA256SUMS" -x "$site/files/$version-SHA256SUMS.minisig" >/dev/null
  local base="http://127.0.0.1:$port/files"
  jq --arg v "$version" --arg base "$base" --arg name "$folder.tar.gz" --argjson pre "$prerelease" \
    '[{ tag_name: ("server-v" + $v), draft: false, prerelease: $pre,
        html_url: ("https://example.invalid/" + $v),
        assets: [ { name: $name, browser_download_url: ($base + "/" + $name) },
                  { name: "SHA256SUMS", browser_download_url: ($base + "/" + $v + "-SHA256SUMS") },
                  { name: "SHA256SUMS.minisig", browser_download_url: ($base + "/" + $v + "-SHA256SUMS.minisig") } ] }] + .' \
    "$site/releases.json" > "$site/releases.tmp" && mv "$site/releases.tmp" "$site/releases.json"
}

# As long as Halden is 0.x every release is a test version (a pre-release on GitHub).
publish 0.0.1 "$v1" true

step "Only test versions: get-halden.sh points at --beta"
if sudo HALDEN_RELEASES_URL="http://127.0.0.1:$port/releases.json" HALDEN_SIGNING_PUBLIC_KEY="$key" \
     bash "$here/packaging/linux/get-halden.sh" > "$work/no-beta.log" 2>&1; then
  fail "a test version was installed without --beta"
fi
grep -q "only test versions" "$work/no-beta.log" || fail "unexpected refusal: $(cat "$work/no-beta.log")"

step "A wrongly signed release is refused by get-halden.sh"
other=$(mktemp -d)
minisign -G -W -p "$other/key.pub" -s "$other/key.sec" >/dev/null
if sudo HALDEN_RELEASES_URL="http://127.0.0.1:$port/releases.json" \
     HALDEN_SIGNING_PUBLIC_KEY="$(sed -n 2p "$other/key.pub")" \
     bash "$here/packaging/linux/get-halden.sh" --beta > "$work/wrong-key.log" 2>&1; then
  fail "a release signed with another key was installed"
fi
grep -q "not signed by the owner" "$work/wrong-key.log" || fail "unexpected refusal: $(cat "$work/wrong-key.log")"

step "Install the test version 0.0.1 with the one-line installer"
sudo HALDEN_RELEASES_URL="http://127.0.0.1:$port/releases.json" \
     HALDEN_SIGNING_PUBLIC_KEY="$key" HALDEN_LIBRARY=/srv/halden/library \
     bash "$here/packaging/linux/get-halden.sh" --beta
systemctl is-active --quiet halden || fail "the service is not running"
systemctl is-enabled --quiet halden-update-request.path || fail "the update path unit is not on"
[ "$(stat -c %U /var/lib/halden)" = halden ] || fail "the data folder doesn't belong to halden"
[ "$(stat -c '%U:%G %a' /etc/halden)" = "root:halden 770" ] || fail "/etc/halden: $(stat -c '%U:%G %a' /etc/halden)"
ps -o user= -C halden | grep -qx halden || fail "the server must run as the halden user"
echo "$password" | sudo halden user add ci --owner >/dev/null
sudo systemd-analyze security halden --no-pager | tail -1

step "The updater and the server look at the stand-in for GitHub"
for unit in halden halden-update-request; do
  sudo mkdir -p "/etc/systemd/system/$unit.service.d"
  printf '[Service]\nEnvironment=HALDEN_UPDATE_API=http://127.0.0.1:%s/releases.json\nEnvironment=HALDEN_UPDATE_KEY=%s\n' \
    "$port" "$key" | sudo tee "/etc/systemd/system/$unit.service.d/test.conf" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl restart halden
for _ in $(seq 1 60); do sudo halden health >/dev/null 2>&1 && break; sleep 1; done
sudo halden health

step "Doctor"
sudo halden doctor || fail "doctor found problems"

step "The API from outside"
login() {
  curl -fsSk -H 'content-type: application/json' \
    -d "{\"username\":\"ci\",\"password\":\"$password\",\"device\":{\"name\":\"CI\",\"platform\":\"ios\",\"installationId\":\"system-test-$1\"}}" \
    "$api/auth/login" | jq -r .token
}
token=$(login 1)
[ -n "$token" ] && [ "$token" != null ] || fail "no token"
call() { curl -fsSk -H "authorization: Bearer $token" "$@"; }
call "$api/server" | jq -e '.version == "0.0.1"' >/dev/null || fail "not 0.0.1"

step "Real photos and a video"
media="$work/media"
mkdir -p "$media"
ffmpeg -loglevel error -f lavfi -i testsrc=size=1920x1080 -frames:v 1 "$media/frame.png"
heif-enc -q 80 "$media/frame.png" -o "$media/photo.heic"
ffmpeg -loglevel error -f lavfi -i testsrc=size=1280x720:rate=30 -t 2 -c:v libx265 -tag:v hvc1 "$media/video.mov"
ffmpeg -loglevel error -i "$media/frame.png" "$media/photo.jpg"
# Thumbnails right away, and copies as JPEG: the server picks up the setting by itself.
sudo halden config set jobs.thumbnail_delay_minutes 0 >/dev/null
sleep 7
call -X PUT -H 'content-type: application/json' -d '{"photoFormat":"jpeg"}' "$api/me/settings" >/dev/null

upload() {
  local file=$1 mime=$2 id
  id=$(cat /proc/sys/kernel/random/uuid)
  local size sha
  size=$(stat -c %s "$file")
  sha=$(sha256sum "$file" | cut -d' ' -f1)
  local upload_id
  upload_id=$(call -H 'content-type: application/json' \
    -d "{\"assetId\":\"$id\",\"size\":$size,\"sha256\":\"$sha\",\"mimeType\":\"$mime\"}" \
    "$api/uploads" | jq -r .uploadId)
  call -X PATCH -H 'upload-offset: 0' --data-binary "@$file" "$api/uploads/$upload_id" \
    | jq -e '.state == "completed"' >/dev/null || fail "upload of $file"
  echo "$id"
}
heic=$(upload "$media/photo.heic" image/heic)
video=$(upload "$media/video.mov" video/quicktime)
jpeg=$(upload "$media/photo.jpg" image/jpeg)

has_role() { call "$api/assets/$1" | jq -e --arg role "$2" '[.files[].role] | index($role) != null' >/dev/null; }
for _ in $(seq 1 120); do
  has_role "$heic" thumbnail && has_role "$video" thumbnail && has_role "$jpeg" thumbnail \
    && has_role "$heic" converted && break
  sleep 1
done
has_role "$heic" thumbnail || fail "no thumbnail for the HEIC photo (libheif in the sandbox?)"
has_role "$video" thumbnail || fail "no thumbnail for the video (ffmpeg in the sandbox?)"
has_role "$jpeg" thumbnail || fail "no thumbnail for the JPEG"
has_role "$heic" converted || fail "no JPEG copy of the HEIC photo"
call "$api/admin/jobs" | jq -e '.jobs == []' >/dev/null || fail "failed jobs: $(call "$api/admin/jobs")"

step "A mirror under /mnt"
sudo mkdir -p /mnt/halden-mirror
sudo chown halden:halden /mnt/halden-mirror
sudo halden mirror set /mnt/halden-mirror >/dev/null
for _ in $(seq 1 60); do
  [ "$(call "$api/admin/mirror" | jq -r .filesWaiting)" = 0 ] && [ "$(call "$api/admin/mirror" | jq -r .mirror)" = ok ] && break
  sleep 1
done
call "$api/admin/mirror" | jq -e '.mirror == "ok"' >/dev/null || fail "mirror: $(call "$api/admin/mirror")"
copies=$(sudo find /mnt/halden-mirror -name '*.heic' -o -name '*.mov' -o -name '*.jpg' | wc -l)
[ "$copies" -ge 4 ] || fail "only $copies files on the mirror"

step "Update to 0.0.2 from the app"
publish 0.0.2 "$v2"
call -X POST "$api/admin/update/check" | jq -e '.state == "available" and .latest == "0.0.2" and .canInstall' >/dev/null \
  || fail "update check: $(call "$api/admin/update")"
call -H 'content-type: application/json' -d "{\"currentPassword\":\"$password\"}" "$api/admin/update/install" >/dev/null
for _ in $(seq 1 180); do
  version=$(curl -fsSk "$api/server" 2>/dev/null | jq -r .version 2>/dev/null || true)
  [ "$version" = 0.0.2 ] && break
  sleep 1
done
[ "$version" = 0.0.2 ] || fail "still $version after the update"
token=$(login 2)
# The updater notes "installed" once it has seen the new version answer (it asks every 500 ms).
for _ in $(seq 1 30); do
  call "$api/admin/update" | jq -e '.state == "installed" and .installed == "0.0.2"' >/dev/null && break
  sleep 1
done
call "$api/admin/update" | jq -e '.state == "installed" and .installed == "0.0.2"' >/dev/null \
  || fail "status after the update: $(call "$api/admin/update")"
call "$api/sync" | jq -e '.assets | length == 3' >/dev/null || fail "photos lost in the update"
[ -f /usr/local/bin/halden.previous ] || fail "no previous program kept"

step "A broken 0.0.3 doesn't start: back to 0.0.2"
cat > "$work/broken" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    --version) echo "halden 0.0.3"; exit 0 ;;
    check-upgrade) exit 0 ;;
  esac
done
echo "this version is broken on purpose" >&2
exit 1
EOF
publish 0.0.3 "$work/broken"
call -X POST "$api/admin/update/check" | jq -e '.latest == "0.0.3"' >/dev/null || fail "0.0.3 not found"
call -H 'content-type: application/json' -d "{\"currentPassword\":\"$password\"}" "$api/admin/update/install" >/dev/null
state=""
for _ in $(seq 1 240); do
  state=$(sudo jq -r .state /var/lib/halden/update-status 2>/dev/null || true)
  [ "$state" = rolledBack ] && break
  sleep 1
done
[ "$state" = rolledBack ] || fail "the broken update was not rolled back: $state"
for _ in $(seq 1 60); do sudo halden health >/dev/null 2>&1 && break; sleep 1; done
curl -fsSk "$api/server" | jq -e '.version == "0.0.2"' >/dev/null || fail "0.0.2 is not back"
token=$(login 3)
call "$api/sync" | jq -e '.assets | length == 3' >/dev/null || fail "photos lost in the rollback"

step "Every file intact"
sudo halden doctor --files || fail "doctor --files"

step "Back up, stop, restore, start"
sudo halden backup now >/dev/null
backup=$(sudo halden backup list | awk '/halden-.*\.db/ { print $1; exit }')
sudo systemctl stop halden
sudo halden backup restore "$backup" --yes
sudo systemctl start halden
for _ in $(seq 1 60); do sudo halden health >/dev/null 2>&1 && break; sleep 1; done
token=$(login 4)
call "$api/sync" | jq -e '.assets | length == 3' >/dev/null || fail "photos lost in the restore"

echo
echo "SYSTEM TEST PASSED"
