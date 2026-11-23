-- §3.8 jobs.retries: how many times a job failed on something passing and was scheduled again
-- (internal/worker/retry.go). attempts counts every claim, so attempts - retries is how many
-- runs ended with the worker dying; an ingest retries without limit, so attempts alone can't
-- tell a crashing job from one riding out an outage. A pending job nothing is running had every
-- claim so far end in a retry or a release, so it starts with no crashes.
ALTER TABLE jobs ADD COLUMN retries integer NOT NULL DEFAULT 0;

UPDATE jobs SET retries = attempts WHERE state = 'pending' AND locked_at IS NULL AND attempts > 0;
