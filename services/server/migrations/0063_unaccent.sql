-- unaccent: Library's search matches a track's name or description ignoring accents
-- (docs/IMPLEMENTATION.md §4.7). It ships with Postgres's contrib modules, in the postgis image.
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;
