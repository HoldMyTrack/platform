-- jobs: no worker handles rewrite_sync_payload, the job 0057 queues per stored sync payload to
-- rename its activity_type. Production finished every one before the kind went; on a database
-- migrating past 0057 later, what it queued would only fail, so it goes, and a payload there that
-- still says activity_type reads as type "unknown" (docs/IMPLEMENTATION.md §4.0.3).
DELETE FROM jobs WHERE kind = 'rewrite_sync_payload' AND state <> 'done';
