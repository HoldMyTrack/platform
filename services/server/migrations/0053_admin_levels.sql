-- The County and City levels of Fog (docs/IMPLEMENTATION.md §4.2.4), in the two forms
-- admin_regions keeps: simplified for drawing, and in pieces for matching. Each row is a place on
-- its level, or a place above standing in for that level's land it leaves uncovered (kind). Every
-- outline gets its names in the app's languages other than English, and the kind of place it is
-- in its own country's words (Overture's local_type).
ALTER TABLE admin_countries ADD COLUMN names jsonb NOT NULL DEFAULT '{}';
ALTER TABLE admin_regions ADD COLUMN names jsonb NOT NULL DEFAULT '{}', ADD COLUMN local_type text;

CREATE TABLE admin_counties (
    id serial PRIMARY KEY,
    overture_id text NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('county', 'region', 'country')),
    country_id integer NOT NULL REFERENCES admin_countries (id),
    region_id integer REFERENCES admin_regions (id),
    local_type text,
    name text NOT NULL,
    names jsonb NOT NULL DEFAULT '{}',
    geom geometry(MultiPolygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_counties_geom ON admin_counties USING gist (geom);

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
    geom geometry(MultiPolygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_cities_geom ON admin_cities USING gist (geom);

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
