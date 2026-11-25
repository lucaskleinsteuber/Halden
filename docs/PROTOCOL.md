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
| `not_found` | 404 | No such route, account, device, upload or asset (or not one you may see). |
| `conflict` | 409 | Username taken, or the change would leave the server without an owner. |
| `unsupported_media_type` | 415 | Halden doesn't store this file type. |
| `too_large` | 413 | The request body is bigger than allowed. |
| `insufficient_storage` | 507 | The library disk is too full for this upload. |
| `upload_busy` | 409 | Another request is sending this upload right now. |
| `offset_mismatch` | 409 | `Upload-Offset` is not where the upload stands; the body's `offset` (and the `Upload-Offset` header) says where to continue. |
| `upload_incomplete` | 409 | `complete` was called before all bytes arrived. |
| `checksum_mismatch` | 422 | The file that arrived doesn't match its SHA-256. The upload is thrown away. |
| `upload_failed` | 410 | The upload ended (checksum mismatch, cancelled, expired). Start a new one. |
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

## Finding the server

In the home network the server announces itself with Bonjour as `_halden._tcp` (instance name
`halden-<first 8 hex digits of the server ID>`). The text record has `id` (server ID), `fp`
(certificate fingerprint, lowercase hex), `api` (API version), `v` (server version) and `name`
(the server's name, to show). The announcement goes out only on home-network interfaces. Finding
a server is not trusting it: the app still pairs or signs in, and when signing in with a password
it shows the fingerprint to compare with `halden status`. Turned off with
`[network] bonjour = false`. In Docker it only works with host networking.

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
{
  "user": { … }, "device": { … }, "unconfirmedDevices": 1,
  "backup": { "mirror": "ok", "onlyOneCopy": false, "filesWaiting": 0,
              "mirrorOnSameDisk": false, "lastDatabaseBackupAt": 1795443720061 },
  "trashDays": 30
}
```

`trashDays` is `[library] trash_days`: how long photos stay in the trash, so the app can show
the days left.

`backup.mirror` is `none` (no second copy), `ok`, `behind` (copies are being made) or
`unreachable` (the mirror disk is missing). While `onlyOneCopy` is true, the app shows a lasting
warning that a broken disk would lose the photos and recommends keeping local copies on the
phone. The status is refreshed hourly in the background.

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

## Uploads

Originals (and the video of a Live Photo, or the RAW of a RAW+HEIC pair) go up with a resumable
protocol in the style of tus. Nothing is lost when the connection breaks, the phone sleeps or the
server is killed: the server keeps every byte that arrived and tells where to continue.

The server makes every file name and path itself; nothing the device sends becomes part of a
path. Originals land in readable folders, by default
`<library>/<username>/<year>/<month>/<date>_<time>.<ext>` in the local time where the photo was
taken (`[storage] path_template`). Two photos from the same second get `_2`, `_3`.

### `POST /uploads`

```json
{
  "assetId": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "role": "original",
  "size": 3145728,
  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "mimeType": "image/heic",
  "metadata": {
    "takenAt": 1795443730000,
    "timeZoneOffsetMinutes": 60,
    "timeZone": "Europe/Berlin",
    "location": { "latitude": 50.5558, "longitude": 9.6808, "altitude": 261.0,
                  "horizontalAccuracy": 4.5, "verticalAccuracy": 3.0,
                  "heading": 271.5, "headingAccuracy": 10.0 },
    "width": 4032, "height": 3024, "durationMs": null,
    "originalFilename": "IMG_0001.HEIC",
    "captureMode": null
  }
}
```

- `assetId`: a UUID the device gives the photo when it is taken. It makes every retry safe.
- `role`: `original` (default), `paired_video` (Live Photo video), `raw` or `stream` (a video's
  small copy, see below). The original has to be there first.
- `mimeType`: `image/heic`, `image/heif`, `image/jpeg`, `image/png`, `image/tiff`, `image/webp`,
  `image/gif`, `image/avif`, `image/x-adobe-dng`, `image/x-canon-cr3`, `image/x-fuji-raf`,
  `video/quicktime`, `video/mp4`, `video/x-matroska`, `video/webm`. Anything else: `415`.
- `captureMode`: for videos `slowmo` (recorded at a high frame rate, played with a slow part) or
  `timelapse`; it becomes the asset's `captureMode`. Other values are kept but not used.
- `metadata` is optional and every field in it too. Unknown fields are kept but not used. When the
  device doesn't say when or where, the server reads it from the file (EXIF, QuickTime); for the
  time the order is device, file, upload time.

Answers:

| Status | Body | Meaning |
|---|---|---|
| `201` | `{"state": "receiving", "uploadId": "…", "assetId": "…", "offset": 0, "size": 3145728, "expiresAt": …}` | Send the bytes. |
| `200` | `{"state": "receiving", …, "offset": 1048576}` | This file was announced before (the app lost the upload id); continue at `offset`. |
| `200` | `{"state": "completed", "asset": {…}}` | Already stored with this hash. |
| `200` | `{"state": "duplicate", "existingAssetId": "…"}` | The same content is stored under another asset id of this account; nothing to send. |
| `409 conflict` | | The asset id is used by another account, or already has a different file in this role. |
| `507 insufficient_storage` | | The file doesn't fit (free space minus space promised to other uploads minus `[storage] min_free_gb`). |

### `PATCH /uploads/{id}`

```
Upload-Offset: 1048576
Content-Type: application/offset+octet-stream

<bytes>
```

Appends the body at `Upload-Offset`, which must be where the upload stands (otherwise
`409 offset_mismatch` with the right offset). Any size works, from one piece to many; 8 to 64
MiB per request suits background uploads on iOS. A request that breaks off keeps what arrived.

Answers `200` with `{"state": "receiving", …, "offset": …}` and an `Upload-Offset` header, or,
when the last byte arrived, `{"state": "completed", "asset": {…}}`: the SHA-256 was checked, the
file flushed to disk and moved into the library, and the database updated. A wrong hash gives
`422 checksum_mismatch` and the upload is thrown away. If another device of the account stored
the same content while this upload was arriving, the answer is
`{"state": "duplicate", "existingAssetId": "…"}` as for the announcement: the photo is kept once,
and this device's photo is that asset.

Unfinished uploads are thrown away after `[storage] upload_expiry_days` (default 7) without
progress.

### `GET /uploads/{id}` and `HEAD /uploads/{id}`

The same body as `PATCH`, with `Upload-Offset` and `Upload-Length` headers. Use it after a
restart of the app or the server to learn where to continue. An upload that was given up,
replaced by a newer announcement of the same asset, or expired answers `410 upload_failed`:
announce it again.

### `POST /uploads/{id}/complete`

For retries: finishes an upload whose bytes all arrived, or returns its result if it is finished.
`409 upload_incomplete` if bytes are missing.

### `DELETE /uploads/{id}`

Gives up on an upload and throws away what arrived. `204`, also when it was given up or
finished before (a finished upload stays stored).

## Assets

### The asset object

```json
{
  "id": "6F9619FF-…", "kind": "photo",
  "takenAt": 1795443730000, "timeZoneOffsetMinutes": 60, "takenAtSource": "client",
  "width": 4032, "height": 3024, "durationMs": null,
  "location": { "latitude": 50.5558, "longitude": 9.6808, "altitude": 261.0,
                "accuracyMeters": 4.5, "heading": 271.5, "source": "client" },
  "camera": { "make": "Apple", "model": "iPhone 15", "lens": "iPhone 15 back camera 6.1mm f/1.6" },
  "files": [
    { "role": "original", "sha256": "…", "size": 3145728, "mimeType": "image/heic",
      "width": 4032, "height": 3024 },
    { "role": "thumbnail", "sha256": "…", "size": 31200, "mimeType": "image/jpeg",
      "width": 512, "height": 384 }
  ],
  "createdAt": …, "updatedAt": …, "seq": 1042, "trashedAt": null, "deletedAt": null
}
```

`takenAtSource` is `client`, `exif` or `upload`; `location.source` is `client` or `exif`. `seq`
changes with every change to the asset. `captureMode` is `slowmo`, `timelapse` or `null`;
`playback` is the slow part of a slow-motion video (see `PATCH`) or `null` to play it as
recorded.

`takenAt`, `timeZoneOffsetMinutes` and `location` are the *effective* values: a correction if
there is one, otherwise the original. `takenAtSource` is then `manual`; `location.source` is
`manual` or `estimated`. `title` and `description` are `null` until set.

### `GET /assets/{id}`

Everything about one asset of the own account (other accounts' assets answer `404`): the asset
object plus

```json
{
  "original": { "takenAt": …, "timeZoneOffsetMinutes": 60, "takenAtSource": "client",
                "location": { … } },
  "exif": { "fNumber": "1.6", "exposureTime": "1/120", "iso": "64", "focalLength": "6.1", … },
  "client": { …what the phone sent with the upload… },
  "edits": [ { "at": …, "field": "location", "deviceId": "…", "old": { … }, "new": { … } } ]
}
```

### `PATCH /assets/{id}`

Corrections. The original values are never changed; every correction is kept in `edits`.

```json
{
  "takenAt": 1795440130000,
  "timeZoneOffsetMinutes": 120,
  "location": { "latitude": 48.137, "longitude": 11.575, "altitude": null, "estimated": false },
  "title": "Munich",
  "description": null,
  "playback": { "slowFromMs": 1000, "slowToMs": 6000, "rate": 0.125 },
  "edit": { "version": 1, "exposure": 0.5, "crop": { "x": 0.1, "y": 0, "width": 0.8, "height": 1 } },
  "restore": []
}
```

Every field is optional. `location: null` removes the place (the original stays stored but is not
shown); `title: null` and `description: null` remove them. `playback` sets the slow part of a
slow-motion video (`0 <= slowFromMs < slowToMs`, `rate` from 0.01 to 1, 0.125 is eight times
slower); `null` plays it as recorded. The file is never changed.

`edit` is an edit as the apps set it (light, colour, turning, straightening, crop, trim), which
they apply whenever they show or export the photo; the server keeps it as it is (a JSON object
with a `version` of 1 or more, at most 16 KB, `422` otherwise) and never changes the file.
`null` goes back to the original. The apps' fields (version 1): `exposure` (stops, -3…3),
`brightness`, `contrast`, `highlights`, `shadows`, `saturation`, `vibrance`, `warmth`, `tint`
(each -1…1), `quarterTurns` (clockwise), `straighten` (degrees), `crop` (`x`, `y`, `width`,
`height`, 0…1 of the turned and straightened picture, from the top left), `trimStartMs`,
`trimEndMs`. The asset object carries it as `edit`. `restore: ["takenAt", "location"]`
drops corrections and shows the originals again. Answers with the asset.

### `POST /assets/location`

One place for many photos (the "Without location" view):
`{"ids": ["…", "…"], "location": {"latitude": …, "longitude": …, "estimated": true}}` →
`{"changed": 2}`. Up to 1000 ids; unknown ids are skipped.

### `GET /assets/without-location?before=<takenAt>&limit=200`

Photos and videos without a place, newest first, each with a suggestion:

```json
{ "assets": [ { …asset…, "suggestion": { "latitude": 50.55, "longitude": 9.68,
                                         "fromAssetId": "…", "minutesApart": 10 } } ] }
```

The suggestion is the place of the nearest photo in time (before or after) that has one, at most
`[library] location_suggest_minutes` (default 120) away; `null` if there is none. Accept it with
`PATCH` or `POST /assets/location` and `"estimated": true`.

### `GET /assets/{id}/location-suggestion`

`{"suggestion": {…} | null}` for one asset.

### `POST /assets/check`

Which of these are backed up? Up to 1000 items per request, answered with two database queries.

```json
{ "items": [ { "assetId": "…", "sha256": "…" } ] }
```

```json
{ "results": [
  { "status": "backedUp", "assetId": "…" },
  { "status": "duplicate", "assetId": "…", "existingAssetId": "…" },
  { "status": "missing", "assetId": "…" },
  { "status": "conflict", "assetId": "…" }
] }
```

`conflict`: this asset id is stored with different content.

### `PUT /assets/{id}/files/thumbnail` and `PUT /assets/{id}/files/preview`

The phone makes the thumbnail (grid, about 512 px) and the preview (full screen, about 2048 px)
and sends each in one request after the original:

```
Content-Type: image/jpeg
Halden-Sha256: <hex>
Halden-Width: 512
Halden-Height: 384

<bytes>
```

JPEG, HEIC, PNG or WebP, at most 8 MiB. Answers with the asset. Sending a new one replaces the
old one.

## Trash

Deleting in the app moves photos to the trash; restoring works on every device. All three
calls take up to 1000 ids, answer `{"changed": n}`, and can be repeated safely (a deletion made
offline is simply sent again later):

- `POST /assets/trash` `{"ids": [...]}`: move to the trash (`trashedAt` is set).
- `POST /assets/restore` `{"ids": [...]}`: take out of the trash.
- `POST /assets/delete` `{"ids": [...]}`: delete for good, **only assets that are in the trash**.
  The original, its conversions and its thumbnails are removed; a tombstone stays for sync.

After `[library] trash_days` (default 30) in the trash, photos are deleted for good
automatically. An asset id that was deleted can't be used again; a phone that still has the photo
gives it a new id to back it up again.

## Settings of the account

### `GET /me/settings` and `PUT /me/settings`

```json
{ "photoFormat": "original", "videoFormat": "mp4" }
```

An extra copy of every photo or video in the preferred format, next to the original in the
library (same name, other extension), as the asset's `converted` file. `photoFormat`:
`original` (no copy), `jpeg`, `heic`, `png`, `tiff`; `videoFormat`: `original`, `mp4`, `mov`,
`mkv`. Videos only change their container (`ffmpeg -c copy`, no quality lost); photos are
converted with libheif or in-process, keeping EXIF and colour profile where the format allows.
RAW files get no copy.

`PUT` takes either field and answers with the settings and `queuedConversions`: after a change,
all existing photos or videos are converted in the background at the lowest priority. Switching
back to `original` removes the copies.

## Albums

An account's own collections of photos. An album only points at photos; a photo can be in many.
Photos in the trash stay in their albums (devices don't show them) and are back when restored;
deleted for good, they leave every album.

```json
{ "id": "…", "name": "Rome", "coverAssetId": "…" | null, "sortOrder": 0,
  "assetIds": ["…newest added first…"], "createdAt": …, "updatedAt": …, "seq": 1043,
  "deletedAt": null }
```

- `GET /albums`: `{"albums": [...]}`, by `sortOrder`, then name.
- `POST /albums` `{"id": "<uuid, optional>", "name": "Rome", "assetIds": [...]}`: `201` with the
  album; `200` with the one already there when the id was used before by the same account (a
  device that didn't hear the answer), `409` when another account has it. Names are trimmed,
  1 to 200 characters (`422`).
- `GET /albums/{id}`, `PATCH /albums/{id}` `{"name", "coverAssetId" (null: the newest photo),
  "sortOrder"}`, `DELETE /albums/{id}` (`204`, also again; the photos stay).
- `POST /albums/{id}/assets` and `DELETE /albums/{id}/assets` `{"assetIds": [...]}` (at most
  5000): put photos in or take them out; photos of other accounts, unknown or deleted ones are
  skipped. Answers with the album.

Other accounts' albums answer `404`.

## Sync

### `GET /sync?since=0&limit=1000`

Everything that changed in the own account after `since`, oldest change first:

```json
{ "assets": [ {…asset…} ], "albums": [ {…album…} ], "nextSince": 1042, "hasMore": false,
  "resetRequired": false }
```

Albums share the counter with assets: a page holds the `limit` lowest numbers of both, and a
deleted album comes once more with `deletedAt` set.

Every change to an asset (new, corrected, new thumbnail, trashed, restored, deleted) gives it the
next number from one counter (`seq`). A device stores `nextSince` and asks with it next time; while
`hasMore` is true it asks again right away. An asset that changed several times comes once, in
its latest state. Deleted assets come once more with `deletedAt` set and no files ("tombstones")
and are kept for `[library] tombstone_days` (default 90). A device that asks with a `since` from
before that gets `resetRequired: true` and must sync again from `since=0`.

`limit` is 1 to 5000 (default 1000). Answers are compressed (gzip or brotli) when the device
accepts it; a page of 1000 assets is a few dozen KB.

## Files

### `GET /files/{sha256}`

Any file of the own account by its content (the `sha256` from an asset's `files`). The answer
never changes, so it carries `Cache-Control: private, max-age=31536000, immutable` and
`ETag: "<sha256>"`: download once, keep forever.

### `GET /assets/{id}/files/{role}`

The current file in a role (`original`, `thumbnail`, `preview`, `converted`, `paired_video`,
`raw`), with `Cache-Control: private, no-cache` (a thumbnail can be replaced) and the same
`ETag`. Originals carry `Content-Disposition` with their name from the library.

Both support:

- `Range: bytes=start-end`, `bytes=start-` and `bytes=-suffix` → `206` with `Content-Range`;
  outside the file → `416`. Several ranges in one request get the whole file.
- `If-None-Match` → `304`, `If-Range` (send the whole file if the ETag changed), `HEAD`.

### `POST /thumbnails`

Up to 500 thumbnails (or previews) in one answer: `{"ids": ["…", …], "role": "thumbnail"}`.
The answer (`Content-Type: application/vnd.halden.files`) is a stream of entries in the order of
`ids`:

```
16 bytes   asset UUID
 4 bytes   length n, big-endian (0: no such file)
 n bytes   the file
```

It is streamed, so the first thumbnails arrive before the last ones are read.

## Thumbnails the server makes

The phone makes thumbnails and previews and sends them. If it hasn't after
`[jobs] thumbnail_delay_minutes` (default 10), the server makes them itself (512 and 2048 px long
edge, JPEG) in the background: JPEG, PNG, TIFF, WebP and GIF directly, HEIC/HEIF/AVIF with
libheif (`heif-dec`), videos with `ffmpeg`. A thumbnail the phone sent is never replaced by one
the server made. The new files show up through `/sync`.

## Small copies of videos

A video bigger than 720p or than about 4.5 Mbit/s gets a small copy to play on the go and in
shared links: role `stream`, H.264 and AAC in MP4, the shorter side `[jobs] stream_height` (720)
at `[jobs] stream_kbps` (3000), ready to play while it loads. The phone sends its own like any
other file (`POST /uploads` with `"role": "stream"`, after the original; only for videos); if it
hasn't after `[jobs] thumbnail_delay_minutes`, the server makes it with ffmpeg at the lowest
priority. A copy that is there is never replaced. `[jobs] stream_versions = false` turns it off.

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

## Looking after the server (owners only)

Everything `halden` can do in the terminal, except restoring a backup (the server must be
stopped for that) and changing folders, port or certificate (a wrong value would lock the apps
out). Changes that open the server up or can delete data need the owner's password again as
`currentPassword`; without it they fail with `403 password_required`.

### `GET /admin/status`

```json
{ "name": "homeserver", "serverId": "…", "version": "0.0.0", "apiVersion": 1,
  "startedAt": 1795443730000, "restarts": 0, "memoryBytes": 52428800,
  "libraryDisk": { "path": "/srv/halden/library", "freeBytes": 812000000000, "totalBytes": 1000000000000 },
  "dataDisk": { … }, "mirrorDisk": null,
  "accounts": [ { "userId": "…", "username": "lucas", "photos": 1200, "videos": 80,
                  "trashed": 3, "libraryBytes": 9400000000 } ],
  "uploadsInProgress": 2, "jobs": { "waiting": 4, "failed": 0 },
  "backup": { …as in GET /me },
  "tools": { "ffmpeg": true, "libheif": true },
  "configProblem": null, "inDocker": false }
```

`memoryBytes` is only known on Linux. `configProblem` is set when the config file was changed
but can't be used; the server then keeps running with its previous settings.

### `GET /admin/config`

```json
{ "settings": [ { "name": "library.trash_days", "kind": "number", "access": "password",
                  "about": "Photos stay in the trash this many days, …",
                  "value": 30, "default": 30 } ],
  "canChange": true, "configProblem": null }
```

`kind`: `text`, `number`, `bool`, `path`, `optionalPath`, `ip`, `networks` (a list of
`"192.0.2.0/24"` strings). `access`: `owner` (no password needed), `password` (needs
`currentPassword`), `terminal` (refused here). `canChange` is false when the server was not
started from a config file it may write.

### `PATCH /admin/config`

```json
{ "changes": { "library.trash_days": 60, "auth.password_login": false, "jobs.workers": null },
  "currentPassword": "…" }
```

`null` puts a setting back to its default. All changes are checked together before anything is
saved; one wrong value (`422 validation_failed`) or one terminal-only setting (`403 forbidden`)
saves nothing. On success the answer is the new settings with `"restarting": true`: the server
starts again with them in under a second, on the same port. Running requests get two seconds to
finish; cut-off uploads continue as usual (`HEAD /uploads/{id}`). Every change is written to the
security log (`settings_changed`).

### `GET /admin/backups` and `POST /admin/backups`

`{"backups": [ { "name": "halden-2026-11-23_03-00-00.db", "size": 4096000, "madeAt": … } ]}`,
newest first. `POST` makes one now (`201` with it) and copies it to the mirror.

### `GET /admin/mirror`, `PUT /admin/mirror`, `DELETE /admin/mirror`

`GET`: `{"path": "/mnt/usb/halden" | null, …the backup status of GET /me}`.
`PUT {"path": "/mnt/usb/halden", "currentPassword": "…"}` makes the folder the mirror: it must
exist and must not be inside the library (`422` otherwise); a marker file is written into it. The
answer says `mirrorOnSameDisk` (a warning: such a mirror protects against nothing) and the server
restarts with it, then copies everything that is missing. `DELETE` with
`{"currentPassword": "…"}` stops mirroring; the copies stay.

### `GET /admin/jobs?state=failed|all`

`{"jobs": [ { "id": 7, "kind": "convert", "assetId": "…", "state": "failed", "attempts": 6,
"lastError": "ffmpeg failed: …", "runAfter": …, "updatedAt": … } ], "counts": {…}}`. Default
`failed`; at most 500, newest first.

### `POST /admin/jobs/retry`

`{"ids": [7, 9]}` or `{}` for every failed job. `{"retried": 2}`.

### `GET /admin/doctor`

What `halden doctor` says: `{"level": "ok" | "warning" | "problem", "checks": [ { "id":
"mirror", "level": "warning", "title": "Mirror", "detail": "none: …", "fix": "connect a second
disk and run: …" } ]}`. `id`s are stable: `config`, `folders`, `settings_file`,
`library_disk`, `data_disk`, `database`, `certificate`, `ffmpeg`, `libheif`, `mirror`, `jobs`,
`backups`, `server`, `clock`, `systemd`, `firewall`, `bonjour`, `network`. Checks that don't
apply are left out.

### `POST /admin/restart`

Starts the server again (`202`). Written to the security log.

### `GET /admin/update`

```json
{ "running": "0.1.0", "state": "available", "installed": "0.1.0", "latest": "0.2.0",
  "prerelease": false, "notesUrl": "https://github.com/…/releases/tag/server-v0.2.0",
  "checkedAt": 1795443730000, "message": null,
  "inDocker": false, "canInstall": true }
```

`state`: `unknown` (not checked yet), `upToDate`, `available`, `installing`, `installed`,
`failed` (nothing was changed; `message` says why), `rolledBack` (the new version didn't start,
the old one and its database are back). The server checks once a day by itself. When
`canInstall` is false, `installHint` says what to do instead (in Docker: pull the new image).

### `POST /admin/update/check`

Looks now; answers like `GET /admin/update`.

### `POST /admin/update/install`

`{"currentPassword": "…"}`. Only when `state` is `available` (else `409 no_update`) and
`canInstall` (else `409 update_unavailable`). Leaves a request for the server's root updater,
which installs the newest signed version: `202` with the status, then `state` goes to
`installing` and on to `installed` (the server restarts) or `failed`/`rolledBack`. Written to
the security log (`update_requested`).
