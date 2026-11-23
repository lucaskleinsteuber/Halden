# Signing updates

`halden update` runs as root and replaces the program. A checksum list published next to the
packages only proves that a download arrived intact: whoever could change the GitHub release (a
stolen token, a compromised workflow) could replace a package and its checksum together. So
Halden installs an update only when the release's `SHA256SUMS` carries a
[minisign](https://jedisct1.github.io/minisign/) signature made with the owner's secret key. That
key never goes to GitHub; it stays on the owner's Mac.

The same key is checked by:

- the program (`RELEASE_KEY` in `server/src/update/mod.rs`, with the pure-Rust `minisign-verify`),
- `packaging/linux/get-halden.sh` (with openssl, before anything of Halden runs),
- the Docker release workflow (with openssl, before the image is built).

A test makes sure the program and `get-halden.sh` carry the same key.

## One-time setup (before the first release)

1. Install minisign: `brew install minisign`.
2. Create the key pair, protected by a password:

   ```sh
   mkdir -p ~/.minisign
   minisign -G -p ~/.minisign/halden.pub -s ~/.minisign/halden.key
   ```

3. Back up `~/.minisign/halden.key` and its password somewhere safe and offline. Without it no
   further update can be installed automatically; a new key needs a version installed by hand.
4. Copy the second line of `~/.minisign/halden.pub` (it starts with `RW`) into `RELEASE_KEY` in
   `server/src/update/mod.rs` and into `signing_public_key` in
   `packaging/linux/get-halden.sh`, and commit both.

While the key is empty, a build installs no update at all and says so, and `get-halden.sh`
refuses to install.

## What is checked, in order

1. The release is a `server-v<version>` release, not a draft, newer than the installed version
   (never older), and a test version only with `halden update --beta on`.
2. `SHA256SUMS.minisig` is a valid signature of `SHA256SUMS` by the built-in key (only the
   prehashed form minisign makes today; the legacy form is refused).
3. The package matches its line in `SHA256SUMS`.
4. The package holds only its own folder (`halden-<version>-<arch>-linux/`), nothing with `..`.
5. The new program says the expected version and brings a copy of the database up to date
   (`halden check-upgrade`) without damage.
6. The database is backed up, the program swapped (the old one stays as `halden.previous`), the
   server restarted. If it doesn't answer with the new version within a minute, the old program
   and the backed-up database come back.

Debug builds (tests) may be pointed at a stand-in for GitHub with `HALDEN_UPDATE_API` and a test
key with `HALDEN_UPDATE_KEY`; release builds ignore both.
