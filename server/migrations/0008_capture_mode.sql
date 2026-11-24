-- How a video was taken, as the phone said: 'slowmo' or 'timelapse' (NULL for everything else).
-- And how it plays: the slow part of a slow-motion video as JSON
-- ({"slowFromMs", "slowToMs", "rate"}), a correction kept next to the unchanged original.
ALTER TABLE assets ADD COLUMN capture_mode TEXT;
ALTER TABLE assets ADD COLUMN playback_json TEXT;
