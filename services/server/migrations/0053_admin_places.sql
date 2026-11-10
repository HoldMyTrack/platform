-- PROTOTYPE (FOG_REWORK.md): the city tier's places, cities and the county land outside them,
-- in the two forms admin_regions keeps (docs/IMPLEMENTATION.md §3.13), and each activity's
-- matches to them.
CREATE TABLE admin_places (
    id serial PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('city', 'county')),
    overture_id text NOT NULL UNIQUE,
    country text NOT NULL,
    region text,
    name text NOT NULL,
    geom geometry(MultiPolygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_places_geom ON admin_places USING gist (geom);

CREATE TABLE admin_place_parts (
    place_id integer NOT NULL REFERENCES admin_places (id) ON DELETE CASCADE,
    geom geometry(Polygon, 4326) NOT NULL
);
CREATE INDEX idx_admin_place_parts_geom ON admin_place_parts USING gist (geom);
CREATE INDEX idx_admin_place_parts_place ON admin_place_parts (place_id);

CREATE TABLE activity_place (
    activity_id uuid NOT NULL REFERENCES activities (id) ON DELETE CASCADE,
    place_id integer NOT NULL REFERENCES admin_places (id),
    PRIMARY KEY (activity_id, place_id)
);
CREATE INDEX idx_activity_place_place ON activity_place (place_id);
