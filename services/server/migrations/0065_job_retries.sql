-- §3.8 jobs.retries: how many times a job failed on something passing and was scheduled again
-- (internal/worker/retry.go). attempts counts every claim, so attempts - retries is how many
-- runs ended with the worker dying; an ingest retries without limit, so attempts alone can't
-- tell a crashing job from one riding out an outage. Every pending job starts with no crashes
-- counted: one nothing is running had each claim so far end in a retry or a release, and one
-- running (the previous worker's, mid-deploy) has only its current claim unaccounted for.
ALTER TABLE jobs ADD COLUMN retries integer NOT NULL DEFAULT 0;

UPDATE jobs SET retries = attempts - (locked_at IS NOT NULL)::int
WHERE state = 'pending' AND attempts > 0;
