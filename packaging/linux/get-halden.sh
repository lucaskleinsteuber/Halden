#!/bin/bash
# Installs the Halden server with one line, or updates it:
#
#   curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Halden/main/packaging/linux/get-halden.sh | sudo bash
#
# It finds the newest stable server release for this computer on GitHub, checks the download
# against the release's SHA256SUMS and its minisign signature, and runs the package's installer
# (install.sh), which asks the setup questions on a new installation.
#
# Everything runs inside main, called on the last line: a download that breaks off midway does
# not parse, so no half of the script runs as root.
main() {
set -euo pipefail

repository=lucaskleinsteuber/Halden
releases="https://api.github.com/repos/$repository/releases?per_page=100"
# The owner's minisign key, the same as in the program (server/src/update/mod.rs). Every release
# must be signed with it. Empty until the first release: then nothing can be installed this way.
signing_public_key=""
# Tests point these at a stand-in for GitHub and sign with their own key.
if [ -n "${HALDEN_RELEASES_URL:-}" ]; then
  releases=$HALDEN_RELEASES_URL
  signing_public_key=${HALDEN_SIGNING_PUBLIC_KEY:-$signing_public_key}
fi

fail() { echo "$*" >&2; exit 1; }

# Succeeds when $2 is a minisign signature of $1 made with signing_public_key, checked with
# openssl so that no further program is needed. Only the prehashed form that minisign writes is
# accepted. $3 is an empty folder for the intermediate files.
signature_valid() {
  local file=$1 signature=$2 scratch=$3
  base64 -d <<<"$signing_public_key" > "$scratch/key.bin" 2>/dev/null || return 1
  sed -n 2p "$signature" | base64 -d > "$scratch/signature.bin" 2>/dev/null || return 1
  [ "$(wc -c < "$scratch/key.bin")" -eq 42 ] && [ "$(wc -c < "$scratch/signature.bin")" -eq 74 ] || return 1
  [ "$(head -c 2 "$scratch/key.bin")" = Ed ] && [ "$(head -c 2 "$scratch/signature.bin")" = ED ] || return 1
  [ "$(head -c 10 "$scratch/key.bin" | tail -c 8 | od -An -tx1)" \
    = "$(head -c 10 "$scratch/signature.bin" | tail -c 8 | od -An -tx1)" ] || return 1
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; tail -c 32 "$scratch/key.bin"; } > "$scratch/key.der"
  tail -c 64 "$scratch/signature.bin" > "$scratch/signature.raw"
  openssl dgst -blake2b512 -binary "$file" > "$scratch/hash" 2>/dev/null || return 1
  openssl pkeyutl -verify -pubin -keyform DER -inkey "$scratch/key.der" -rawin -in "$scratch/hash" \
    -sigfile "$scratch/signature.raw" >/dev/null 2>&1
}
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || fail "Run it with sudo: curl -fsSL https://raw.githubusercontent.com/$repository/main/packaging/linux/get-halden.sh | sudo bash"
command -v systemctl >/dev/null 2>&1 || fail "The Halden server needs Linux with systemd (or Docker, see docs/DOCKER.md)."
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) fail "The Halden server runs on 64-bit Intel, AMD and ARM computers, not on $(uname -m)." ;;
esac
[ -n "$signing_public_key" ] || fail "There is no signed Halden release yet."

missing=()
for tool in curl jq tar sha256sum openssl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  command -v apt-get >/dev/null 2>&1 || fail "Install ${missing[*]} with your package manager first."
  echo "Installing ${missing[*]}..."
  apt-get install -y "${missing[@]/sha256sum/coreutils}" >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null && apt-get install -y "${missing[@]/sha256sum/coreutils}" >/dev/null; } \
    || fail "Could not install ${missing[*]}."
fi

work=$(mktemp -d /var/tmp/halden-get.XXXXXX)
trap 'rm -rf "$work"' EXIT

echo "Looking for the newest Halden server..."
curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$releases" -o "$work/releases.json" \
  || fail "GitHub could not be reached. Check the internet connection and try again."
# The newest stable release (GitHub lists newest first) with a package for this computer, a
# checksum list and its signature.
newest=$(jq -r --arg arch "$arch" '
  [ .[] | select((.draft | not) and (.prerelease | not) and (.tag_name | startswith("server-v")))
    | (.tag_name | ltrimstr("server-v")) as $version
    | select($version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | ("halden-" + $version + "-" + $arch + "-linux.tar.gz") as $name
    | [ $version, $name,
        (first(.assets[] | select(.name == $name) | .browser_download_url) // ""),
        (first(.assets[] | select(.name == "SHA256SUMS") | .browser_download_url) // ""),
        (first(.assets[] | select(.name == "SHA256SUMS.minisig") | .browser_download_url) // "") ]
    | select(.[2] != "" and .[3] != "") ] | first // empty | join("\t")' "$work/releases.json")
[ -n "$newest" ] || fail "No Halden server release for $arch was found on GitHub."
IFS=$'\t' read -r version name url sums_url signature_url <<<"$newest"

echo "Downloading Halden $version..."
curl -fsSL --retry 3 "$url" -o "$work/$name" || fail "The download failed. Try again."
curl -fsSL --retry 3 "$sums_url" -o "$work/SHA256SUMS" || fail "The checksum list could not be downloaded."
unsigned="The release is not signed by the owner of Halden, so it was not installed."
[ -n "$signature_url" ] || fail "$unsigned"
curl -fsSL --retry 3 "$signature_url" -o "$work/SHA256SUMS.minisig" || fail "The signature could not be downloaded."
mkdir "$work/signature"
signature_valid "$work/SHA256SUMS" "$work/SHA256SUMS.minisig" "$work/signature" || fail "$unsigned"
expected=$(awk -v file="$name" '{ sub(/^\*/, "", $2) } $2 == file { print $1 }' "$work/SHA256SUMS")
[ "${#expected}" -eq 64 ] || fail "The release lists no checksum for $name."
[ "$(sha256sum "$work/$name" | cut -d ' ' -f1)" = "$expected" ] \
  || fail "The download does not match its signed checksum, so it was not installed."

# Only the package's own folder is unpacked, owned by root.
folder="halden-$version-$arch-linux"
tar -tzf "$work/$name" > "$work/contents"
awk -v folder="$folder" 'index($0, folder "/") != 1 || /(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad }' "$work/contents" \
  || fail "The download is not a Halden server package, so it was not installed."
mkdir "$work/package"
tar -xzf "$work/$name" --no-same-owner -C "$work/package"
[ -x "$work/package/$folder/halden" ] && [ -f "$work/package/$folder/install.sh" ] \
  || fail "The download is not a Halden server package, so it was not installed."
(cd "$work/package/$folder" && bash ./install.sh)
}

main "$@"
