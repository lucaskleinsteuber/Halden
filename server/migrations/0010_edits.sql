-- An edit (light, colour, crop, trim), kept as what was set: a JSON object with a "version"
-- that the apps apply when they show the photo. The original file never changes.
ALTER TABLE assets ADD COLUMN edit_json TEXT;
