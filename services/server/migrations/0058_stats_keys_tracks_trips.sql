-- daily_stats: the keys named after activities and stories, and the job kinds 0057 renamed in
-- `jobs.<kind>.<state>`, take the names internal/stats/catalogue.go writes, so each key's history
-- stays one series on the admin page and in `stats <key>`. A day with both names, from a
-- snapshot retaken after 0057, keeps the new one. An old worker running beside this migration can
-- still write that day's snapshot under the old names, which `stats <day>` then lists too; run
-- with 0057's maintenance deploy, no old worker is running.
CREATE TEMP TABLE stat_renames (old text, new text, prefix boolean) ON COMMIT DROP;
INSERT INTO stat_renames VALUES
    ('activity_accounts_by_country.', 'track_accounts_by_country.', true),
    ('activities_by_country.', 'tracks_by_country.', true),
    ('activities_by_source.', 'tracks_by_source.', true),
    ('activities_added_by_source.', 'tracks_added_by_source.', true),
    ('activities_per_account.', 'tracks_per_account.', true),
    ('jobs.edit_track.', 'jobs.edit_route.', true),
    ('jobs.story_copy.', 'jobs.trip_copy.', true),
    ('activities', 'tracks', false),
    ('activities_added', 'tracks_added', false),
    ('stories', 'trips', false),
    ('stories_added', 'trips_added', false),
    ('story_sends', 'trip_sends', false),
    ('accounts_with.stories', 'accounts_with.trips', false);

CREATE TEMP TABLE stat_moves ON COMMIT DROP AS
SELECT s.day, s.key, CASE WHEN r.prefix THEN r.new || substr(s.key, length(r.old) + 1) ELSE r.new END AS new_key
FROM daily_stats s
JOIN stat_renames r ON CASE WHEN r.prefix THEN starts_with(s.key, r.old) ELSE s.key = r.old END;

DELETE FROM daily_stats d USING stat_moves m
WHERE d.day = m.day AND d.key = m.key
  AND EXISTS (SELECT 1 FROM daily_stats n WHERE n.day = m.day AND n.key = m.new_key);

UPDATE daily_stats d SET key = m.new_key FROM stat_moves m
WHERE d.day = m.day AND d.key = m.key;
