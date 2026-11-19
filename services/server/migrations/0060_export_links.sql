-- export_links: a link to one part of a ready export that works without a session, for a
-- phone's download manager, which keeps request headers in a database outside the app
-- (docs/IMPLEMENTATION.md §4.29). The token is kept as a hash; a link lives a day at most and goes
-- with its export.
CREATE TABLE export_links (
    token_hash bytea PRIMARY KEY,
    export_id uuid NOT NULL REFERENCES exports(id) ON DELETE CASCADE,
    part integer NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE INDEX idx_export_links_export ON export_links (export_id);
CREATE INDEX idx_export_links_expiry ON export_links (expires_at);
