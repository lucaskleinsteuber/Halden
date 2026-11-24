-- Albums: an account's own collections of photos. A photo can be in many albums; an album only
-- points at photos, it never copies them. Every change gives the album the next number from the
-- same counter as assets, so devices get albums with the sync. A deleted album stays as a
-- tombstone (deleted_at) for a while, like assets.
CREATE TABLE albums (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    -- The photo on the album's cover; when it is gone, the newest photo in it.
    cover_asset_id TEXT,
    -- Where the album goes in the list (smaller first), then by name.
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    deleted_at INTEGER
);
CREATE INDEX albums_by_user_seq ON albums (user_id, seq);

CREATE TABLE album_assets (
    album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    added_at INTEGER NOT NULL,
    PRIMARY KEY (album_id, asset_id)
);
CREATE INDEX album_assets_by_asset ON album_assets (asset_id);
