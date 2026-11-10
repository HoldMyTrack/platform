-- PROTOTYPE (FOG_REWORK.md "Borders and names"): each outline's name in the app's languages other
-- than English, keyed by language code; `name` stays the English one, and the fallback.
ALTER TABLE admin_countries ADD COLUMN names jsonb NOT NULL DEFAULT '{}';
ALTER TABLE admin_regions ADD COLUMN names jsonb NOT NULL DEFAULT '{}';
ALTER TABLE admin_places ADD COLUMN names jsonb NOT NULL DEFAULT '{}';
