# Halden security model

What Halden protects, how, and where the limits are. Halden is built for a home server: one
household, a few accounts, a handful of devices each.

## Who may connect

- By default the server only accepts connections from the home network (private and link-local
  addresses) and Tailscale. The check happens before TLS starts, so strangers on the internet get
  nothing, not even a certificate. `[network] allow_public` and `allowed_networks` open it up.
- Every connection is TLS 1.3. Apps pin the server's certificate by its SHA-256 fingerprint, so a
  device on the same Wi-Fi can't pretend to be the server.

## Accounts and roles

- **Owner**: runs the server, manages accounts and devices. **Member**: uses it.
- Each account sees only its own photos. Owners manage accounts and devices but are not given
  other accounts' photos through the app.
- The server always keeps at least one active owner.
- Changes that hand out access (creating accounts, changing roles, resetting someone else's
  password, deleting accounts, making a pairing code for another account) need the owner's own
  password again, so a borrowed phone that is signed in isn't enough.

**Honest limit:** an owner can reset a member's password or pair a device into a member's
account, and whoever has root on the server can read every file on its disks. Privacy between
accounts is an access rule, not encryption. These actions are always written to the security log
of the affected account, and a device an owner pairs into someone else's account shows up there
as a new, unconfirmed device. End-to-end encryption is planned for later.

## Passwords

- Stored as Argon2id hashes (19 MiB memory, 2 passes, 1 lane: the OWASP recommendation), each
  with its own salt. Hashing runs off the request threads and only four hashes run at once.
- At least 8 characters, at most 1024 bytes, not the username.
- A wrong password and an unknown username get the same answer and take the same time.
- Brakes, kept in memory:
  - each address: at most 20 sign-in or pairing attempts per minute;
  - each username: from the 5th failure in a row a wait of 30 seconds, doubling with every
    further failure up to 15 minutes (also for usernames that don't exist).
- `[auth] password_login = false` turns password sign-in off entirely; devices can then only be
  added by pairing.

## Device tokens

- After signing in, a device gets a token: `hd1_` plus 32 random bytes. The prefix lets secret
  scanners recognise a leaked token.
- The server stores only the token's SHA-256. A copy of the database contains no usable tokens.
- A token stops working when the device is signed out or blocked, the account is disabled, or the
  device goes unused for `[auth] device_inactive_days` (default 365, 0 = never).
- "Last seen" is written at most once a minute per device.

## New devices

- **Pairing** (QR code or typed code): a code is 10 characters of Crockford base32 (about 50
  bits), valid for 5 minutes, usable once. Only its hash is stored. After 100 wrong codes in total
  all open codes are cancelled. Since someone with access made the code, the new device is
  trusted, unless an owner made it for somebody else's account.
- **Password**: a new device gets in at once, but if the account already has devices it starts
  unconfirmed. The other devices (and owners) see "New device signed in" with **That was me** or
  **Block**. A device can't confirm itself.
- **Blocking** signs the device out and refuses its installation id for that account, for both
  sign-in and pairing.

**Honest limit:** the installation id comes from the app. Someone who knows the password can
reinstall the app and sign in again. The password stays the real protection, which is why
"change password and sign out all other devices" exists.

## Security log

- Records sign-ins (successful, failed, slowed down), pairing, new, confirmed, blocked and
  signed-out devices, password changes and account changes, with time, account, device and
  address.
- Never records passwords, tokens, pairing codes or file paths.
- Members see their own entries, owners see all (`GET /security-log`, `halden log`).
- Entries are removed after `[security] log_retention_days` (default 90, 0 = keep). Cleaning up
  runs at start and then daily.

## The terminal

`halden user …`, `halden pair`, `halden devices` and `halden log` work directly on the database
and need access to the data folder (usually `sudo`). Whoever can run them already controls the
server. When they run as root, files SQLite creates are handed back to the server's user
afterwards, so the server can still open its database.

