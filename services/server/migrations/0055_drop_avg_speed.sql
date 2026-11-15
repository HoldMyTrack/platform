-- An activity's average speed: the release before this one stopped writing it, and nothing ever
-- read it.
ALTER TABLE activities DROP COLUMN avg_speed_mps;
