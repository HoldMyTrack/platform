-- §3.3 activities: the Pending check (`GET /v1/activities/pending`, docs/IMPLEMENTATION.md §4.2.5)
-- runs every two seconds while a client watches a reprocess; a partial index keeps it to the few
-- Pending rows instead of the account's whole history.
CREATE INDEX idx_activities_user_pending ON activities (user_id) WHERE edit_pending;
