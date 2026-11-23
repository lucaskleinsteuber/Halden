-- Accounts, their devices, pairing codes and the security log. Times are Unix milliseconds.

CREATE TABLE users (
    id            TEXT PRIMARY KEY NOT NULL,
    username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name  TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('owner', 'member')),
    -- Argon2id PHC string. NULL: this account can only add devices by pairing.
    password_hash TEXT,
    disabled      INTEGER NOT NULL DEFAULT 0 CHECK (disabled IN (0, 1)),
    created_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE devices (
    id              TEXT PRIMARY KEY NOT NULL,
    user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    platform        TEXT NOT NULL CHECK (platform IN ('ios', 'macos', 'cli')),
    -- SHA-256 of the device token. The token itself is never stored.
    token_hash      BLOB NOT NULL UNIQUE,
    -- Random id the app creates once per installation; used to block a device for good.
    installation_id TEXT,
    confirmed       INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
    created_at      INTEGER NOT NULL,
    last_seen_at    INTEGER NOT NULL,
    last_seen_ip    TEXT,
    revoked_at      INTEGER
) STRICT;

CREATE INDEX devices_by_user ON devices (user_id);

CREATE TABLE pairing_codes (
    -- SHA-256 of the normalised code.
    code_hash         BLOB PRIMARY KEY NOT NULL,
    user_id           TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- Device that asked for the code. NULL: created in the terminal.
    created_by_device TEXT,
    created_at        INTEGER NOT NULL,
    expires_at        INTEGER NOT NULL,
    used_at           INTEGER,
    -- Device that was added with the code.
    used_by_device    TEXT REFERENCES devices (id) ON DELETE SET NULL
) STRICT;

CREATE TABLE blocked_installations (
    installation_id TEXT NOT NULL,
    user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    blocked_at      INTEGER NOT NULL,
    PRIMARY KEY (installation_id, user_id)
) STRICT;

-- Never holds passwords, tokens, codes or file paths.
CREATE TABLE security_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    at        INTEGER NOT NULL,
    event     TEXT NOT NULL,
    user_id   TEXT,
    device_id TEXT,
    ip        TEXT,
    detail    TEXT
) STRICT;

CREATE INDEX security_log_by_time ON security_log (at);
CREATE INDEX security_log_by_user ON security_log (user_id, id);
