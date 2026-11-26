-- Rendered Live Photo effects (Loop/Bounce MP4 or Long Exposure still, role 'live_effect'):
-- extend the role check on asset_files. Nothing references asset_files, so copying it is safe.
CREATE TABLE asset_files_new (
    asset_id   TEXT NOT NULL REFERENCES assets (id) ON DELETE CASCADE,
    role       TEXT NOT NULL CHECK (role IN ('original', 'thumbnail', 'preview', 'converted', 'paired_video', 'raw', 'stream', 'live_effect')),
    user_id    TEXT NOT NULL,
    sha256     BLOB NOT NULL,
    size       INTEGER NOT NULL,
    mime       TEXT NOT NULL,
    storage    TEXT NOT NULL CHECK (storage IN ('library', 'derived')),
    path       TEXT NOT NULL,
    width      INTEGER,
    height     INTEGER,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (asset_id, role)
) STRICT, WITHOUT ROWID;

INSERT INTO asset_files_new SELECT asset_id, role, user_id, sha256, size, mime, storage, path, width,
    height, created_at FROM asset_files;
DROP TABLE asset_files;
ALTER TABLE asset_files_new RENAME TO asset_files;

CREATE INDEX asset_files_by_hash ON asset_files (user_id, sha256);
CREATE UNIQUE INDEX asset_files_library_paths ON asset_files (path) WHERE storage = 'library';
