-- daily_stats: the keys named after activities and stories take the tracks and trips names
-- internal/stats/catalogue.go writes, so each key's history stays one series on the admin page
-- and in `stats <key>`. An old worker's snapshot taken during the deploy keeps the old names for
-- that day only; nothing reads them.
UPDATE daily_stats s SET key = m.new || substr(s.key, length(m.old) + 1)
FROM (VALUES
    ('activity_accounts_by_country.', 'track_accounts_by_country.'),
    ('activities_by_country.', 'tracks_by_country.'),
    ('activities_by_source.', 'tracks_by_source.'),
    ('activities_added_by_source.', 'tracks_added_by_source.'),
    ('activities_per_account.', 'tracks_per_account.')
) AS m (old, new)
WHERE starts_with(s.key, m.old);

UPDATE daily_stats s SET key = m.new
FROM (VALUES
    ('activities', 'tracks'),
    ('activities_added', 'tracks_added'),
    ('stories', 'trips'),
    ('stories_added', 'trips_added'),
    ('story_sends', 'trip_sends'),
    ('accounts_with.stories', 'accounts_with.trips')
) AS m (old, new)
WHERE s.key = m.old;
