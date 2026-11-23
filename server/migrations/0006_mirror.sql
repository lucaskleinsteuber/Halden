-- Which library files are copied to the mirror (a second disk), checked by their hash.
CREATE TABLE mirror_files (
    asset_id  TEXT NOT NULL REFERENCES assets (id) ON DELETE CASCADE,
    role      TEXT NOT NULL,
    sha256    BLOB NOT NULL,
    path      TEXT NOT NULL,
    copied_at INTEGER NOT NULL,
    PRIMARY KEY (asset_id, role)
) STRICT, WITHOUT ROWID;
