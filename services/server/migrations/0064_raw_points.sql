-- §3.3 tracks.raw_points: how many points the original parses to, which a GPX download is
-- bounded by before it parses any (docs/IMPLEMENTATION.md §4.35). Ingest sets it; every track
-- kept before is counted by a count_points job per account. An hour on, so the previous
-- release's worker, still running while this migrates, doesn't take a kind it can't run.
ALTER TABLE tracks ADD COLUMN raw_points integer;

INSERT INTO jobs (kind, user_id, payload, run_after)
SELECT 'count_points', user_id, jsonb_build_object('user_id', user_id), now() + interval '1 hour'
FROM tracks
WHERE raw_payload_key IS NOT NULL
GROUP BY user_id;
