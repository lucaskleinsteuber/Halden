-- Shared links: photos or an album for people without Halden, as a web page. The token is in
-- the link (128 random bits); the link can have a password (Argon2id), an end, and allow the
-- originals or not. A withdrawn link stays, so it answers "ended" instead of "unknown".
CREATE TABLE shares (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token           TEXT NOT NULL UNIQUE,
    title           TEXT,
    album_id        TEXT,
    asset_ids       TEXT,
    expires_at      INTEGER,
    password_hash   TEXT,
    allow_originals INTEGER NOT NULL DEFAULT 0,
    views           INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    revoked_at      INTEGER
);
CREATE INDEX shares_by_user ON shares (user_id, created_at);
