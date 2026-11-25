#!/bin/bash
# Signs and publishes a Halden server release that the release workflow left as a draft. Runs on
# the owner's Mac, with the minisign key that never leaves it (docs/UPDATE_SIGNING.md):
#
#   scripts/publish-release.sh 0.1.0
#
# It downloads the draft's packages and SHA256SUMS, checks every package against the list, signs
# the list, checks the signature against the public key built into the program, uploads the
# signature and publishes the release. Publishing starts the Docker image build.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "$*" >&2; exit 1; }
version=${1:-}
[ -n "$version" ] || fail "Use: scripts/publish-release.sh <version>"
tag="server-v$version"
secret_key=${HALDEN_MINISIGN_SECRET_KEY:-$HOME/.minisign/halden.key}
command -v minisign >/dev/null || fail "Install minisign first: brew install minisign"
command -v gh >/dev/null || fail "Install the GitHub command line first: brew install gh"
[ -f "$secret_key" ] || fail "Missing the signing key $secret_key (docs/UPDATE_SIGNING.md)."
public_key=$(sed -n 's/^pub const RELEASE_KEY: &str = "\(.*\)";$/\1/p' server/src/update/mod.rs)
[ -n "$public_key" ] || fail "server/src/update/mod.rs has no RELEASE_KEY yet (docs/UPDATE_SIGNING.md)."
script_key=$(sed -n 's/^signing_public_key="\(.*\)"$/\1/p' packaging/linux/get-halden.sh)
[ "$script_key" = "$public_key" ] || fail "get-halden.sh and the program carry different keys."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "Downloading the draft $tag..."
gh release download "$tag" --pattern 'SHA256SUMS' --pattern 'halden-*.tar.gz' --dir "$work"
(cd "$work" && shasum -a 256 -c SHA256SUMS) || fail "A package doesn't match SHA256SUMS; nothing was signed."
[ "$(wc -l < "$work/SHA256SUMS")" -ge 2 ] || fail "Expected packages for x86_64 and aarch64."

# The key's password comes from the Mac's Keychain when it is there (docs/UPDATE_SIGNING.md);
# otherwise minisign asks for it.
keychain_item="Halden release signing key"
if security find-generic-password -a halden -s "$keychain_item" >/dev/null 2>&1; then
  echo "Signing (password from the Keychain)..."
  security find-generic-password -a halden -s "$keychain_item" -w \
    | minisign -S -s "$secret_key" -m "$work/SHA256SUMS" -x "$work/SHA256SUMS.minisig" \
      -t "Halden server $version" >/dev/null
else
  echo "Signing (minisign asks for the key's password)..."
  minisign -S -s "$secret_key" -m "$work/SHA256SUMS" -x "$work/SHA256SUMS.minisig" \
    -t "Halden server $version"
fi
minisign -V -P "$public_key" -m "$work/SHA256SUMS" -x "$work/SHA256SUMS.minisig" >/dev/null \
  || fail "The signature doesn't match the program's key; nothing was published."

gh release upload "$tag" "$work/SHA256SUMS.minisig" --clobber
flags=(--draft=false)
# Test versions, and every version while Halden is 0.x, are pre-releases.
case "$version" in 0.*|*-*) flags+=(--prerelease) ;; *) flags+=(--latest) ;; esac
gh release edit "$tag" "${flags[@]}"
echo "Halden $version is published. Servers find it within a day; the Docker image is being built."
