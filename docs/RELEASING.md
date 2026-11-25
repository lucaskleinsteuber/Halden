# Releasing the server

Releases are tagged `server-v<version>` (semantic versions, test versions like `0.2.0-rc.1`).
The server and the iPhone app have separate version numbers; both started at 0.1.0 on
25.11.2026. New functions raise the middle number, fixes the last one. While the version starts
with `0.`, every release is a **pre-release** on GitHub: servers only install it with test
versions on (`halden update --beta on`), and the Docker image gets no `latest` tag.

1. Make sure `CHANGELOG.md` has the version's entries and the CI is green on `main`.
2. Set the version in `server/Cargo.toml` (and `Cargo.lock`, by building once). The signing key
   is set up (docs/UPDATE_SIGNING.md).
3. Tag and push:

   ```sh
   git tag server-v0.1.0 && git push origin server-v0.1.0
   ```

   The `Release` workflow builds the program for x86_64 and aarch64 Linux (on Ubuntu 22.04, so it
   runs on 22.04 and newer), with the version from the tag, packs
   `halden-<version>-<arch>-linux.tar.gz` (program, `install.sh`, systemd units, licence, README)
   and leaves a **draft** release with the packages and `SHA256SUMS`.
4. On the Mac, sign and publish:

   ```sh
   scripts/publish-release.sh 0.1.0
   ```

   It checks every package against `SHA256SUMS`, signs the list with the owner's key (the
   password comes from the Mac's Keychain, or minisign asks for it), checks the signature against
   the key built into the program, uploads it and publishes the release (as a pre-release for 0.x
   and test versions).
5. Publishing starts the `Docker release` workflow: it checks the signature again, builds the
   image from exactly the signed packages for amd64 and arm64, and pushes
   `ghcr.io/lucaskleinsteuber/halden:<version>` (and `latest` for stable versions).

Servers notice the new version within a day; installing waits for each owner.

A dry run (Actions › Release › Run workflow) builds the packages without publishing anything.
