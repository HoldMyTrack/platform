-- §3.3 activities: editable_times, whether the track's own points (its split piece, clipped
-- against Private locations, before any edit) have timestamps that run forward — what Edit track
-- needs (docs/SPEC.md FR-5.14) and the activity list reports as track_edit `bad_times`. Ingest and
-- every reprocess set it; rows stored before are filled by `backfill-editable-times`, and until
-- then NULL lets the Track tab open and the points request refuse as before. Safe beside the
-- previous release, which never reads it.
ALTER TABLE activities ADD COLUMN editable_times boolean;
