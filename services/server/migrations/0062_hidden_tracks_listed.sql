-- §3.3 tracks.hidden_by: the Private location a track with no route is listed under, while its
-- circle is in view (docs/IMPLEMENTATION.md §7).
ALTER TABLE tracks ADD COLUMN hidden_by uuid REFERENCES privacy_zones (id) ON DELETE SET NULL;
CREATE INDEX idx_tracks_hidden_by ON tracks (hidden_by) WHERE hidden_by IS NOT NULL;

-- Every track hidden so far is reprocessed to fill hidden_by. An hour on, so the previous
-- release's worker, still running while this migrates, doesn't take the job and leave it unset.
INSERT INTO jobs (kind, user_id, payload, run_after)
SELECT 'reprivacy', user_id, jsonb_build_object('user_id', user_id, 'track_ids', jsonb_agg(id ORDER BY id)), now() + interval '1 hour'
FROM tracks
WHERE trajectory IS NULL AND raw_payload_key IS NOT NULL
GROUP BY user_id;