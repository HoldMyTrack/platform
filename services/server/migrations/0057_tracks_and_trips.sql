-- Deploy: maintenance — rename tables and columns for Tracks and Trips
-- The old release reads activities and stories, so it can't run beside this. Every rename is
-- metadata only; the UPDATEs touch the jobs queue and a handful of Trip copies.

ALTER TABLE activities RENAME TO tracks;
ALTER TABLE tracks RENAME COLUMN activity_type TO track_type;
ALTER TABLE tracks RENAME COLUMN track_edit TO route_edit;

ALTER TABLE stories RENAME TO trips;
ALTER TABLE story_activities RENAME TO trip_tracks;
ALTER TABLE trip_tracks RENAME COLUMN story_id TO trip_id;
ALTER TABLE trip_tracks RENAME COLUMN activity_id TO track_id;
ALTER TABLE story_copies RENAME TO trip_copies;
ALTER TABLE trip_copies RENAME COLUMN source_story_id TO source_trip_id;
ALTER TABLE trip_copies RENAME COLUMN copy_story_id TO copy_trip_id;
ALTER TABLE story_sends RENAME TO trip_sends;
ALTER TABLE trip_sends RENAME COLUMN story_id TO trip_id;

ALTER TABLE activity_photos RENAME TO track_photos;
ALTER TABLE track_photos RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_country RENAME TO track_country;
ALTER TABLE track_country RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_region RENAME TO track_region;
ALTER TABLE track_region RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_county RENAME TO track_county;
ALTER TABLE track_county RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_city RENAME TO track_city;
ALTER TABLE track_city RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_tile_masks RENAME TO track_tile_masks;
ALTER TABLE track_tile_masks RENAME COLUMN activity_id TO track_id;
ALTER TABLE activity_tile_mask_data RENAME TO track_tile_mask_data;
ALTER TABLE track_tile_mask_data RENAME COLUMN activity_id TO track_id;

-- Postgres keeps an index's and a constraint's name through a table rename. Constraints first:
-- renaming a primary key or unique constraint renames its index with it.
CREATE FUNCTION pg_temp.renamed(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(replace(name, 'activities', 'tracks'), 'activity', 'track'), 'stories', 'trips'), 'story', 'trip')
$$;

DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.conrelid::regclass AS tbl, c.conname
        FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'public' AND c.conname ~ '(activit|stor(y|ies))'
    LOOP
        EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I', r.tbl, r.conname, pg_temp.renamed(r.conname));
    END LOOP;
    FOR r IN
        SELECT i.relname
        FROM pg_class i JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE n.nspname = 'public' AND i.relkind = 'i' AND i.relname ~ '(activit|stor(y|ies))'
    LOOP
        EXECUTE format('ALTER INDEX %I RENAME TO %I', r.relname, pg_temp.renamed(r.relname));
    END LOOP;
END $$;

-- A Trip copy's source.
UPDATE tracks SET source = 'trip' WHERE source = 'story';

-- The queue, finished rows included, since the import history reads their payloads.
UPDATE jobs SET kind = 'edit_route' WHERE kind = 'edit_track';
UPDATE jobs SET kind = 'trip_copy' WHERE kind = 'story_copy';
UPDATE jobs SET payload = (payload - 'activity_id') || jsonb_build_object('track_id', payload -> 'activity_id') WHERE payload ? 'activity_id';
UPDATE jobs SET payload = (payload - 'activity_ids') || jsonb_build_object('track_ids', payload -> 'activity_ids') WHERE payload ? 'activity_ids';
UPDATE jobs SET payload = (payload - 'activity_type') || jsonb_build_object('track_type', payload -> 'activity_type') WHERE payload ? 'activity_type';
UPDATE jobs SET payload = (payload - 'story_id') || jsonb_build_object('trip_id', payload -> 'story_id') WHERE payload ? 'story_id';

-- A phone sync's payload names the type activity_type: in jobs.raw while its ingest hasn't
-- stored it, and in object storage after. The first is rewritten here (json.Marshal writes no
-- space after a colon); the second by one rewrite_sync_payload job per object, queued to run
-- before anything the release queues after it.
UPDATE jobs
SET raw = convert_to(replace(convert_from(raw, 'UTF8'), '"activity_type":', '"track_type":'), 'UTF8')
WHERE kind = 'ingest' AND raw IS NOT NULL AND payload ->> 'raw_payload_key' LIKE '%.json';

INSERT INTO jobs (kind, payload, run_after)
SELECT 'rewrite_sync_payload', jsonb_build_object('key', raw_payload_key), now() - interval '1 minute'
FROM (SELECT DISTINCT raw_payload_key FROM tracks WHERE raw_payload_key LIKE '%.json') keys;
