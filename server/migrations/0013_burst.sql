-- Photos taken together in a burst share a `burst_id` chosen by the camera.
ALTER TABLE assets ADD COLUMN burst_id TEXT;
CREATE INDEX assets_by_burst ON assets (user_id, burst_id) WHERE burst_id IS NOT NULL;
