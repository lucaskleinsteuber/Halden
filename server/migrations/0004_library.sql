-- Corrections on top of the original metadata, their history, and the background job queue.

-- Corrections never overwrite the original columns; they sit next to them. NULL: no correction.
ALTER TABLE assets ADD COLUMN title TEXT;
ALTER TABLE assets ADD COLUMN description TEXT;
ALTER TABLE assets ADD COLUMN edit_taken_at INTEGER;
ALTER TABLE assets ADD COLUMN edit_tz_offset_min INTEGER;
ALTER TABLE assets ADD COLUMN edit_latitude REAL;
ALTER TABLE assets ADD COLUMN edit_longitude REAL;
ALTER TABLE assets ADD COLUMN edit_altitude REAL;
-- 'manual' (set by hand) or 'estimated' (taken from a suggestion).
ALTER TABLE assets ADD COLUMN edit_location_source TEXT;
-- 1: the person removed the location (the original stays stored, but is not shown).
ALTER TABLE assets ADD COLUMN location_hidden INTEGER NOT NULL DEFAULT 0;

-- Every correction, with what it was before. Kept as long as the asset.
CREATE TABLE asset_edits (
    id        INTEGER PRIMARY KEY,
    asset_id  TEXT NOT NULL REFERENCES assets (id) ON DELETE CASCADE,
    device_id TEXT,
    at        INTEGER NOT NULL,
    field     TEXT NOT NULL,
    old_json  TEXT,
    new_json  TEXT
) STRICT;

CREATE INDEX asset_edits_by_asset ON asset_edits (asset_id, id);

-- Work that happens in the background: thumbnails the phone didn't send, conversions, mirroring.
CREATE TABLE jobs (
    id         INTEGER PRIMARY KEY,
    kind       TEXT NOT NULL,
    asset_id   TEXT NOT NULL,
    user_id    TEXT NOT NULL,
    state      TEXT NOT NULL CHECK (state IN ('queued', 'running', 'failed')),
    attempts   INTEGER NOT NULL DEFAULT 0,
    run_after  INTEGER NOT NULL,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

-- One job of a kind per asset at a time.
CREATE UNIQUE INDEX jobs_once ON jobs (kind, asset_id);
CREATE INDEX jobs_due ON jobs (state, run_after);

-- Deleted assets stay as "tombstones" so devices learn about the deletion. When old tombstones
-- are removed, devices that last synced before that point must start over.
INSERT INTO counters (name, value) VALUES ('sync_floor', 0);
