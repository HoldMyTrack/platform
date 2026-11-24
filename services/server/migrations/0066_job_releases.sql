-- §3.8 jobs.releases: how many claims a shutdown handed back unfinished (internal/worker). A
-- claim's attempts is the token its outcome writes name, so a release counts here instead of
-- lowering attempts, which could repeat a token an earlier claim still holds.
-- attempts - retries - releases is how many runs ended with the worker dying.
ALTER TABLE jobs ADD COLUMN releases integer NOT NULL DEFAULT 0;
