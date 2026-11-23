-- Photos and videos, their files, and uploads in progress. Times are Unix milliseconds.

-- One counter for the whole server. Every change to an asset takes the next number, so a device
-- that remembers the last number it saw can ask for exactly what changed since.
CREATE TABLE counters (
    name  TEXT PRIMARY KEY NOT NULL,
    value INTEGER NOT NULL
) STRICT;

INSERT INTO counters (name, value) VALUES ('asset_seq', 0);

-- The id comes from the device that took the photo, so a retried upload never creates a second
-- asset. Columns hold the original metadata, as the camera and the device recorded it.
CREATE TABLE assets (
    id                  TEXT PRIMARY KEY NOT NULL,
    user_id             TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind                TEXT NOT NULL CHECK (kind IN ('photo', 'video')),
    -- When it was taken (UTC) and the UTC offset where it was taken.
    taken_at            INTEGER NOT NULL,
    tz_offset_min       INTEGER,
    taken_at_source     TEXT NOT NULL CHECK (taken_at_source IN ('client', 'exif', 'upload')),
    width               INTEGER,
    height              INTEGER,
    duration_ms         INTEGER,
    camera_make         TEXT,
    camera_model        TEXT,
    lens                TEXT,
    latitude            REAL,
    longitude           REAL,
    altitude            REAL,
    location_accuracy_m REAL,
    heading             REAL,
    location_source     TEXT CHECK (location_source IN ('client', 'exif')),
    -- Selected EXIF / QuickTime fields, for the info view.
    exif_json           TEXT,
    -- What the device sent about the photo (time zone name, original file name, ...).
    client_json         TEXT,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    seq                 INTEGER NOT NULL,
    trashed_at          INTEGER,
    deleted_at          INTEGER
) STRICT;

CREATE INDEX assets_by_time ON assets (user_id, taken_at);
CREATE UNIQUE INDEX assets_by_seq ON assets (user_id, seq);
-- Only photos with a location: finds the nearest one in time for a location suggestion.
CREATE INDEX assets_located_by_time ON assets (user_id, taken_at) WHERE latitude IS NOT NULL;

-- The files of an asset: the original, plus thumbnail, preview and later conversions.
CREATE TABLE asset_files (
    asset_id   TEXT NOT NULL REFERENCES assets (id) ON DELETE CASCADE,
    role       TEXT NOT NULL CHECK (role IN ('original', 'thumbnail', 'preview', 'converted', 'paired_video', 'raw')),
    user_id    TEXT NOT NULL,
    sha256     BLOB NOT NULL,
    size       INTEGER NOT NULL,
    mime       TEXT NOT NULL,
    -- 'library': originals and conversions on the big disk, in readable folders.
    -- 'derived': thumbnails and previews on the fast disk, named by their hash.
    storage    TEXT NOT NULL CHECK (storage IN ('library', 'derived')),
    -- Relative to the library or the derived folder. Always made by the server.
    path       TEXT NOT NULL,
    width      INTEGER,
    height     INTEGER,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (asset_id, role)
) STRICT, WITHOUT ROWID;

CREATE INDEX asset_files_by_hash ON asset_files (user_id, sha256);
CREATE UNIQUE INDEX asset_files_library_paths ON asset_files (path) WHERE storage = 'library';

CREATE TABLE uploads (
    id            TEXT PRIMARY KEY NOT NULL,
    user_id       TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id     TEXT,
    asset_id      TEXT NOT NULL,
    role          TEXT NOT NULL,
    kind          TEXT NOT NULL,
    size          INTEGER NOT NULL,
    sha256        BLOB NOT NULL,
    mime          TEXT NOT NULL,
    -- The device's metadata, applied when the upload completes.
    metadata_json TEXT,
    state         TEXT NOT NULL CHECK (state IN ('receiving', 'completed', 'failed')),
    error         TEXT,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    expires_at    INTEGER NOT NULL
) STRICT;

CREATE INDEX uploads_by_asset ON uploads (user_id, asset_id, role);
CREATE INDEX uploads_by_state ON uploads (state, expires_at);
