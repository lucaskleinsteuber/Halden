-- Per-account settings that the server acts on.
CREATE TABLE user_settings (
    user_id      TEXT PRIMARY KEY NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- An extra copy of every photo / video in this format: 'original' (none), 'jpeg', 'heic',
    -- 'png', 'tiff' / 'original', 'mp4', 'mov', 'mkv'.
    photo_format TEXT NOT NULL DEFAULT 'original',
    video_format TEXT NOT NULL DEFAULT 'original',
    updated_at   INTEGER NOT NULL
) STRICT;

CREATE INDEX assets_trashed ON assets (trashed_at) WHERE trashed_at IS NOT NULL AND deleted_at IS NULL;
