-- users: the client census (docs/IMPLEMENTATION.md §4.32) keeps the day an account last used the
-- iOS app and that app's build, as it does for Android.
ALTER TABLE users ADD COLUMN ios_seen_at timestamptz, ADD COLUMN ios_build integer;
