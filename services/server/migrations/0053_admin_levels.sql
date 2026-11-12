-- The County and City levels of Fog (docs/IMPLEMENTATION.md §4.2.4), in the two forms
-- admin_regions keeps: simplified for drawing, and in pieces for matching. Each row is a place on
-- its level, or a place above standing in for that level's land it leaves uncovered (kind). Every
-- outline gets its names in the app's languages other than English, and the kind of place it is
-- in its own country's words (Overture's local_type).
--
-- Every level is drawn at every zoom, so each outline is kept twice for the tiles: `geom` near,
-- under a pixel at zoom 10, and `geom_far` for zoom 6 and out.
--
-- A place above counts the places of each level below that lie in it, stand-ins aside, and a
-- country keeps what most of its regions and counties are (its words), for Fog's tooltip and
-- level control.
ALTER TABLE admin_countries ADD COLUMN geom_far geometry(MultiPolygon, 4326);
ALTER TABLE admin_regions ADD COLUMN geom_far geometry(MultiPolygon, 4326);
ALTER TABLE admin_countries ADD COLUMN names jsonb NOT NULL DEFAULT '{}',
    ADD COLUMN region_word text NOT NULL DEFAULT '', ADD COLUMN county_word text NOT NULL DEFAULT '',
    ADD COLUMN regions_total integer NOT NULL DEFAULT 0, ADD COLUMN counties_total integer NOT NULL DEFAULT 0,
    ADD COLUMN cities_total integer NOT NULL DEFAULT 0;
ALTER TABLE admin_regions ADD COLUMN names jsonb NOT NULL DEFAULT '{}', ADD COLUMN local_type text,
    ADD COLUMN counties_total integer NOT NULL DEFAULT 0, ADD COLUMN cities_total integer NOT NULL DEFAULT 0;

CREATE TABLE admin_counties (
    id serial PRIMARY KEY,
    overture_id text NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('county', 'region', 'country')),
    country_id integer NOT NULL REFERENCES admin_countries (id),
    region_id integer REFERENCES admin_regions (id),
    local_type text,
    name text NOT NULL,
    names jsonb NOT NULL DEFAULT '{}',
    cities_total integer NOT NULL DEFAULT 0,
    geom geometry(MultiPolygon, 4326) NOT NULL,
    geom_far geometry(MultiPolygon, 4326)
);
CREATE INDEX idx_admin_counties_geom ON admin_counties USING gist (geom);
-- The parent ids, for the foreign keys that point at the levels above: without them deleting the
-- old outlines in seed-admin-boundaries checked each region and country against every row.
CREATE INDEX idx_admin_counties_region ON admin_counties (region_id);
CREATE INDEX idx_admin_counties_country ON admin_counties (country_id);

CREATE TABLE admin_county_parts (
    county_id integer NOT NULL REFERENCES admin_counties (id) ON DELETE CASCADE,
    geom geometry(Polygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_county_parts_geom ON admin_county_parts USING gist (geom);
CREATE INDEX idx_admin_county_parts_county ON admin_county_parts (county_id);

CREATE TABLE activity_county (
    activity_id uuid NOT NULL REFERENCES activities (id) ON DELETE CASCADE,
    county_id integer NOT NULL REFERENCES admin_counties (id),
    PRIMARY KEY (activity_id, county_id)
);
CREATE INDEX idx_activity_county_county ON activity_county (county_id);

CREATE TABLE admin_cities (
    id serial PRIMARY KEY,
    overture_id text NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('city', 'county', 'region', 'country')),
    country_id integer NOT NULL REFERENCES admin_countries (id),
    region_id integer REFERENCES admin_regions (id),
    county_id integer REFERENCES admin_counties (id),
    local_type text,
    name text NOT NULL,
    names jsonb NOT NULL DEFAULT '{}',
    geom geometry(MultiPolygon, 4326) NOT NULL,
    geom_far geometry(MultiPolygon, 4326)
);
CREATE INDEX idx_admin_cities_geom ON admin_cities USING gist (geom);
-- The parent ids, as admin_counties': deleting the world's counties scanned 383,000 cities once each.
CREATE INDEX idx_admin_cities_county ON admin_cities (county_id);
CREATE INDEX idx_admin_cities_region ON admin_cities (region_id);
CREATE INDEX idx_admin_cities_country ON admin_cities (country_id);

CREATE TABLE admin_city_parts (
    city_id integer NOT NULL REFERENCES admin_cities (id) ON DELETE CASCADE,
    geom geometry(Polygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_city_parts_geom ON admin_city_parts USING gist (geom);
CREATE INDEX idx_admin_city_parts_city ON admin_city_parts (city_id);

CREATE TABLE activity_city (
    activity_id uuid NOT NULL REFERENCES activities (id) ON DELETE CASCADE,
    city_id integer NOT NULL REFERENCES admin_cities (id),
    PRIMARY KEY (activity_id, city_id)
);
CREATE INDEX idx_activity_city_city ON activity_city (city_id);
