-- §3.8 jobs.seen_at: when the account dismissed this failed import in the Upload menu
-- (internal/httpapi/imports.go). One failure at a time, beside users.imports_seen_at, which
-- opening /sync moves past every failure at once.
ALTER TABLE jobs ADD COLUMN seen_at timestamptz;
