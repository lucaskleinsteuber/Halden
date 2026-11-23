# Halden protocol

How the apps talk to the Halden server. Everything is HTTPS (TLS 1.3 only, HTTP/2 preferred)
under `/api/v1`. Bodies are JSON with `camelCase` keys. Times are Unix milliseconds.

The server uses its own self-signed certificate. Apps don't trust it through a certificate
authority; they **pin** its SHA-256 fingerprint, which they get from the pairing QR code or which
the person compares with `halden status`.

## Errors

Every error has a status code and the same body:

```json
{ "error": "invalid_credentials", "message": "The username or password is wrong." }
```

`error` is stable and meant for code; `message` is an English sentence that may be shown.

| `error` | Status | Meaning |
|---|---|---|
| `unauthorized` | 401 | No token, or the token doesn't work (any more). Sign in again. |
| `invalid_credentials` | 401 / 403 | Wrong username or password, or a wrong, expired or used pairing code (401). A wrong `currentPassword` while signed in (403). |
| `rate_limited` | 429 | Too many attempts. Wait for the `Retry-After` header (seconds). |
| `device_blocked` | 403 | This installation was blocked for this account. |
| `forbidden` | 403 | Not allowed, e.g. a member calling `/admin/*`, or a disabled account. |
| `password_required` | 403 | Send `currentPassword` to confirm this change. |
| `password_login_disabled` | 403 | The server only allows pairing (`[auth] password_login = false`). |
| `validation_failed` | 400 / 415 / 422 | The request is malformed or breaks a rule (name too long, password too short, …). |
| `not_found` | 404 | No such route, account or device (or not one you may see). |
| `conflict` | 409 | Username taken, or the change would leave the server without an owner. |
| `internal_error` | 500 | Something broke on the server; its log has the details. |

## Public routes

### `GET /health`

`{"status": "ok"}`, or 503 when the database doesn't answer.

### `GET /server`

```json
{
  "name": "homeserver",
  "serverId": "d4c45d53-6a54-417c-83b1-9aa070032cdf",
  "version": "0.0.0",
  "apiVersion": 1,
  "fingerprint": "1796ad1f…",
  "passwordLogin": true
}
```

`serverId` never changes; use it to recognise the server at any address.

## Signing in

A device signs in once and gets a **device token**. It sends the token with every request:

```
Authorization: Bearer hd1_VMh9HgxACR27DfTa9HAv6mn6rLUqfPR7lndEJntb3zE
```

A token is `hd1_` plus 43 base64url characters. It is shown only once; store it in the Keychain.
It stays valid until the device is signed out or blocked, the account is disabled, or the device
goes unused for `[auth] device_inactive_days` (default 365).

The `device` object in both sign-in routes:

```json
{ "name": "Lucas' iPhone", "platform": "ios", "installationId": "7F1C…" }
```

- `name`: 1 to 64 characters.
- `platform`: `ios`, `macos` or `cli`.
- `installationId` (optional, recommended): a random id the app creates once per installation
  and keeps (8 to 128 visible ASCII characters). An owner can then block the installation, not
  only sign it out.

Both routes answer with:

```json
{
  "token": "hd1_…",
  "user": { "id": "…", "username": "lucas", "displayName": "Lucas", "role": "owner",
            "disabled": false, "hasPassword": true, "createdAt": 1795443720061 },
  "device": { "id": "…", "userId": "…", "name": "Lucas' iPhone", "platform": "ios",
              "confirmed": true, "createdAt": …, "lastSeenAt": …, "lastSeenIp": "192.168.178.20" }
}
```

### `POST /auth/login`

```json
{ "username": "lucas", "password": "…", "device": { … } }
```

A wrong password and an unknown username get the same answer (`401 invalid_credentials`) and
take the same time. After 5 failures in a row for a username, it waits 30 seconds, doubling with
each further failure up to 15 minutes (`429` with `Retry-After`). Each address may make at most
20 sign-in or pairing attempts per minute.

A device that signs in with the password while the account already has other devices starts
**unconfirmed** (`"confirmed": false`): the other devices (and owners) are asked "New device
signed in: That was me / Block".

### `POST /auth/pair`

```json
{ "code": "7MMV1-M2EA2", "device": { … } }
```

The code comes from the QR code or is typed in. Case, dashes and spaces don't matter; `O`, `I`
and `L` are read as `0`, `1` and `1`. A code works once and for 5 minutes. After 100 wrong codes
in total, all open codes are cancelled.

A paired device is confirmed, unless an owner made the code for somebody else's account and that
account already has devices; then it shows up as new for that account.

### The pairing QR code

```
halden://pair?v=1&id=<serverId>&name=<server name>&addr=192.168.178.72,100.101.102.103&port=47130&fp=<fingerprint>&code=<code>
```

- `addr`: up to four addresses to try, IPv4 first; IPv6 addresses are percent-encoded.
- `fp`: the certificate fingerprint to pin, lowercase hex.
- `code`: the pairing code without the dash.

### `POST /auth/logout`

Signs this device out. `204`.

## The own account

### `GET /me`

```json
{ "user": { … }, "device": { … }, "unconfirmedDevices": 1 }
```

`unconfirmedDevices` counts new devices waiting for confirmation: the account's own, and for
owners those of every account. The asking device is never counted.

### `PUT /me/password`

```json
{ "currentPassword": "…", "newPassword": "…", "signOutOtherDevices": true }
```

`currentPassword` is needed if the account has a password. A new password has at least 8
characters and isn't the username. Answer: `{"signedOutDevices": 2}`.

### `POST /pairing-codes`

Makes a code for adding a device. Body `{}` for the own account. Owners may make one for another
account with `{"userId": "…", "currentPassword": "…"}`. `201`:

```json
{ "code": "7MMV1-M2EA2", "url": "halden://pair?…", "expiresAt": 1795444043364, "userId": "…" }
```

Show `url` as a QR code and `code` for typing.

## Devices

### `GET /devices`

The signed-in devices of the own account; owners get those of every account.

```json
{ "devices": [ { "id": "…", "userId": "…", "username": "lucas", "name": "Lucas' iPhone",
                 "platform": "ios", "confirmed": true, "current": true, … } ] }
```

### `POST /devices/{id}/confirm`

"That was me". `204`. A new device can't confirm itself.

### `POST /devices/{id}/block`

Signs the device out and refuses its installation for this account from now on. `204`.

### `DELETE /devices/{id}`

Signs the device out; it may sign in again. `204`.

Members can only manage their own devices; other devices answer `404`.

## Security log

### `GET /security-log?limit=50&before=<id>`

Newest first, members see their own entries, owners all. `limit` is 1 to 200 (default 50); pass
`nextBefore` from one page as `before` for the next.

```json
{
  "entries": [
    { "id": 42, "at": 1795443743307, "event": "login_succeeded", "userId": "…",
      "username": "lucas", "deviceId": "…", "deviceName": "Lucas' iPhone",
      "ip": "192.168.178.20", "detail": "first device" }
  ],
  "nextBefore": 42
}
```

Events: `login_succeeded`, `login_failed`, `login_throttled`, `pairing_code_created`,
`pair_succeeded`, `pair_failed`, `pairing_codes_cancelled`, `blocked_device_refused`, `logout`,
`device_confirmed`, `device_blocked`, `device_revoked`, `device_expired`, `password_changed`,
`password_reset`, `password_check_failed`, `user_created`, `user_renamed`, `role_changed`,
`user_disabled`, `user_enabled`, `user_deleted`.

## Accounts (owners only)

Changes that hand out access need the owner's own password as `currentPassword`.

### `GET /admin/users`

`{"users": [ { …user, "devices": 2 } ]}`

### `POST /admin/users`

```json
{ "username": "anna", "displayName": "Anna", "role": "member", "password": "…", "currentPassword": "…" }
```

`username`: 2 to 32 letters, digits, dots, dashes or underscores, starting with a letter or
digit; `Anna` and `anna` are the same. Leave out `password` for an account that only pairs.
`role` defaults to `member`. `201` with the user.

### `PATCH /admin/users/{id}`

```json
{ "displayName": "Anna K", "role": "owner", "disabled": false,
  "password": "…", "signOutDevices": true, "currentPassword": "…" }
```

All fields optional. `role` and `password` need `currentPassword`. A disabled account can't sign
in and its tokens stop working until it is enabled again. Answers with the updated user.

### `DELETE /admin/users/{id}`

Body `{"currentPassword": "…"}`. Deletes the account and its devices. `204`.

The server always keeps at least one active owner: demoting, disabling or deleting the last one
is refused with `409 conflict`.
