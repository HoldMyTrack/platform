-- Heatmap's window flag, its scale caps and the count tile each Fog tile's row named: the release
-- before this one stopped reading and writing them.
DROP INDEX idx_activities_in_heatmap_window;
ALTER TABLE activities DROP COLUMN in_heatmap_window;
ALTER TABLE users DROP COLUMN heatmap_cap, DROP COLUMN heat_point_caps;
ALTER TABLE fog_tiles DROP COLUMN heatmap_object_key, DROP COLUMN heatmap_bytes;
