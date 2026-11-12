-- The outlines of every Fog level `seed-admin-boundaries` loads (docs/IMPLEMENTATION.md §4.2.4):
-- countries, regions, counties and cities, cut from one pinned Overture Maps release's divisions
-- theme. Run by scripts/boundaries-extract.sh, which sets getvariable('divisions') (the theme, on
-- S3 or a local copy), getvariable('lakes') and getvariable('water') (scripts/boundaries-lakes.sql's
-- and scripts/boundaries-water.sql's files),
-- getvariable('places') (the countries whose counties and cities to take, comma-separated, or
-- empty for all) and getvariable('out').
--
-- Overture's divisions are OpenStreetMap's boundaries (plus a few CC BY 4.0 sources) under ODbL,
-- so this file is also the public record of how the derived outlines were made.
--
-- Each level tiles the land, so a track anywhere clears one place on it: where a level's own
-- places leave land uncovered, the deepest place above with an outline there stands in for them,
-- as a region without counties is its own county. On the City level that is each county's land
-- outside its cities; on the County level, each region's outside its counties.
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';
SET geometry_always_xy = true;

CREATE TABLE division AS
SELECT d.id, d.subtype, d.country, d.local_type['en'] AS local_type,
       d.hierarchies[1] AS chain, p.subtype AS parent_subtype,
       -- The names in the app's languages other than English, which is `name`.
       CASE WHEN d.names.common['ru'] IS NULL THEN '{}' ELSE json_object('ru', d.names.common['ru']) END AS names
FROM read_parquet(getvariable('divisions') || '/type=division/*', hive_partitioning = 1) d
LEFT JOIN read_parquet(getvariable('divisions') || '/type=division/*', hive_partitioning = 1) p
       ON p.id = d.parent_division_id
WHERE d.subtype IN ('country', 'dependency', 'region')
   OR (d.subtype IN ('county', 'locality')
       AND (getvariable('places') = '' OR list_contains(string_split(getvariable('places'), ','), d.country)));

-- The land-clipped outline: a coastal country's other outline runs 12 nautical miles out to sea.
-- A city is an outlined locality whose parent is not a locality: below one are its districts.
CREATE TABLE area AS
SELECT a.division_id, a.subtype, a.country, a.region,
       COALESCE(a.names.common['en'], a.names."primary") AS name,
       d.names, d.local_type,
       list_filter(d.chain, lambda x: x.subtype = 'region')[1].division_id AS region_key,
       list_filter(d.chain, lambda x: x.subtype = 'county')[1].division_id AS county_key,
       a.geometry
FROM read_parquet(getvariable('divisions') || '/type=division_area/*', hive_partitioning = 1) a
JOIN division d ON d.id = a.division_id
WHERE a.is_land
  AND (a.subtype <> 'locality' OR d.parent_subtype IS DISTINCT FROM 'locality');

UPDATE area SET geometry = ST_Difference(area.geometry, cut.geometry)
FROM (
    SELECT a.division_id, ST_Union_Agg(l.geometry) AS geometry
    FROM area a JOIN read_parquet(getvariable('lakes')) l ON ST_Intersects(a.geometry, l.geometry)
    GROUP BY a.division_id
) cut
WHERE area.division_id = cut.division_id;

-- A region with no ISO 3166-2 code that lies mostly inside one that has one is the other side of
-- a dispute drawn twice (Aksai Chin, Western Sahara, South Tibet), not a region of its own.
-- Code-less regions that are, like Puerto Rico's municipalities, stay.
CREATE TABLE duplicate AS
SELECT DISTINCT n.division_id
FROM area n
JOIN area k ON k.subtype = 'region' AND k.region IS NOT NULL AND ST_Intersects(n.geometry, k.geometry)
WHERE n.subtype = 'region' AND n.region IS NULL
  AND ST_Area(ST_Intersection(n.geometry, k.geometry)) > 0.5 * ST_Area(n.geometry);

CREATE TABLE country AS
SELECT country AS key, country, name, names, geometry FROM area WHERE subtype IN ('country', 'dependency');

-- The Region level: every region, and a country without regions as its own region, keyed as
-- seed-admin-boundaries keys it.
CREATE TABLE region AS
SELECT division_id AS key, country, region AS code, local_type, name, names, geometry
FROM area WHERE subtype = 'region' AND division_id NOT IN (SELECT division_id FROM duplicate)
UNION ALL
SELECT 'country:' || c.key, c.country, NULL, NULL, c.name, c.names, c.geometry
FROM country c
WHERE NOT EXISTS (SELECT 1 FROM area r WHERE r.subtype = 'region' AND r.country = c.country);

-- Counties and cities are simplified to about 10 m: at full detail they would be 3.7 GB
-- (FOG_REWORK.md Findings 5).
CREATE TABLE county AS
SELECT a.division_id AS key, a.country, r.key AS region_key, a.local_type, a.name, a.names,
       ST_SimplifyPreserveTopology(a.geometry, 0.0001) AS geometry
FROM area a LEFT JOIN region r ON r.key = COALESCE(a.region_key, 'country:' || a.country)
WHERE a.subtype = 'county';

-- Where two cities overlap (Ohio files Chardon city and Chardon Township both under Geauga
-- County), the smaller is cut out of the larger, so two places never stack the veil; a tie on area
-- goes to the lower id.
CREATE TABLE city_area AS
-- A city's county is the County-level place it lies in: its county, else its region's stand-in.
SELECT a.division_id AS key, a.country, r.key AS region_key, COALESCE(k.key, 'rest:' || r.key) AS county_key,
       a.local_type, a.name, a.names,
       ST_Area_Spheroid(a.geometry) AS m2, ST_SimplifyPreserveTopology(a.geometry, 0.0001) AS geometry
FROM area a
LEFT JOIN region r ON r.key = COALESCE(a.region_key, 'country:' || a.country)
LEFT JOIN county k ON k.key = a.county_key
WHERE a.subtype = 'locality';

-- The join takes ST_Intersects alone: with the size test beside it DuckDB plans a nested loop
-- over every pair of cities instead of its spatial join (France's 35,000 cities took 14 minutes
-- instead of 3 seconds).
CREATE TABLE city_touch AS
SELECT c.key, c.m2, s.key AS smaller_key, s.m2 AS smaller_m2
FROM city_area c JOIN city_area s ON ST_Intersects(c.geometry, s.geometry);

CREATE TABLE city AS
WITH smaller AS (
    SELECT t.key, ST_Union_Agg(s.geometry) AS geometry
    FROM city_touch t JOIN city_area s ON s.key = t.smaller_key
    WHERE t.key <> t.smaller_key AND (t.smaller_m2 < t.m2 OR (t.smaller_m2 = t.m2 AND t.smaller_key < t.key))
    GROUP BY t.key
)
SELECT c.key, c.country, c.region_key, c.county_key, c.local_type, c.name, c.names,
       CASE WHEN s.geometry IS NULL THEN c.geometry ELSE ST_Difference(c.geometry, s.geometry) END AS geometry
FROM city_area c LEFT JOIN smaller s USING (key);

-- What a level's places leave of the place above: its outline minus theirs.
CREATE MACRO rest(above, below) AS
    CASE WHEN below IS NULL THEN above ELSE ST_Difference(above, below) END;

-- The County level's stand-ins: each region's land outside its counties. Only where a place
-- isn't covered, so a place above sits on the level below once.
CREATE TABLE county_rest AS
WITH inside AS (
    SELECT r.key, ST_Union_Agg(k.geometry) AS geometry
    FROM region r JOIN county k ON ST_Intersects(r.geometry, k.geometry)
    GROUP BY r.key
)
SELECT 'rest:' || r.key AS key, r.country, r.key AS region_key,
       CASE WHEN r.key LIKE 'country:%' THEN 'country' ELSE 'region' END AS kind,
       r.local_type, r.name, r.names, rest(r.geometry, i.geometry) AS geometry,
       EXISTS (SELECT 1 FROM county k WHERE k.region_key = r.key) AS partial
FROM region r LEFT JOIN inside i USING (key)
WHERE r.country IN (SELECT DISTINCT country FROM county)
   OR getvariable('places') = '';

-- Where a region has counties, water outside all of them is the region's only as its outline
-- runs to the border in it, as Michigan's runs through the St Marys River where Chippewa County
-- stops at the shore: it is water, so it goes, and a track on it counts on neither level below.
-- A region without counties stands in whole, its rivers its own, as a county's are. Each piece
-- loses its water only where water is a tenth of it or more: GEOS cut Nevada's 76 m-wide,
-- 170 km-long strip, which a river only touches, to a tenth of its area.
CREATE TABLE county_rest_piece AS
SELECT key, UNNEST(ST_Dump(ST_CollectionExtract(ST_MakeValid(geometry), 3)), recursive := true)
FROM county_rest WHERE partial;

CREATE TABLE county_rest_dry AS
WITH wet AS (
    SELECT p.key, p.path, any_value(p.geom) AS geom, ST_Union_Agg(w.geometry) AS water
    FROM county_rest_piece p JOIN read_parquet(getvariable('water')) w ON ST_Intersects(p.geom, w.geometry)
    GROUP BY p.key, p.path
)
SELECT p.key, ST_Union_Agg(
           CASE WHEN w.water IS NOT NULL AND ST_Area(ST_Intersection(p.geom, w.water)) >= 0.1 * ST_Area(p.geom)
                THEN ST_Difference(p.geom, w.water) ELSE p.geom END) AS geometry
FROM county_rest_piece p LEFT JOIN wet w USING (key, path)
GROUP BY p.key;

UPDATE county_rest SET geometry = d.geometry FROM county_rest_dry d WHERE county_rest.key = d.key;

-- The City level's stand-ins: each County-level place's land outside its cities.
CREATE TABLE city_rest AS
WITH above AS (
    SELECT key, country, region_key, key AS county_key, 'county' AS kind, local_type, name, names, geometry FROM county
    UNION ALL
    SELECT key, country, region_key, key, kind, local_type, name, names, geometry FROM county_rest
), inside AS (
    SELECT p.key, ST_Union_Agg(c.geometry) AS geometry
    FROM above p JOIN city c ON ST_Intersects(p.geometry, c.geometry)
    GROUP BY p.key
)
SELECT 'rest:' || p.key AS key, p.country, p.region_key, p.county_key, p.kind,
       p.local_type, p.name, p.names, rest(p.geometry, i.geometry) AS geometry
FROM above p LEFT JOIN inside i USING (key);

-- Cutting leaves slivers where two outlines' shared border doesn't quite match. A stand-in's piece
-- whose mean width (2 × area / perimeter) is under 30 m is one: no track could be said to be in
-- it.
CREATE MACRO kept(g) AS (
    SELECT ST_Union_Agg(geom) FROM (
        SELECT UNNEST(ST_Dump(ST_CollectionExtract(ST_MakeValid(g), 3)), recursive := true)
    ) WHERE 2 * ST_Area_Spheroid(geom) / NULLIF(ST_Perimeter_Spheroid(geom), 0) >= 30
);

-- The County and City levels' rows, each level to be cleaned as one coverage.
CREATE TABLE place AS
SELECT 'county' AS level, 'county' AS kind, key, country, region_key, NULL AS county_key, local_type, name, names, geometry AS g
FROM county
UNION ALL
SELECT 'county', kind, key, country, region_key, NULL, local_type, name, names, g
FROM (SELECT *, kept(geometry) AS g FROM county_rest) WHERE g IS NOT NULL
UNION ALL
SELECT 'city', 'city', key, country, region_key, county_key, local_type, name, names, g
FROM (SELECT *, ST_CollectionExtract(ST_MakeValid(geometry), 3) AS g FROM city) WHERE NOT ST_IsEmpty(g)
UNION ALL
SELECT 'city', kind, key, country, region_key, county_key, local_type, name, names, g
FROM (SELECT *, kept(geometry) AS g FROM city_rest) WHERE g IS NOT NULL;

-- Each county and city simplified to 10 m on its own moves its side of a shared border apart
-- from its neighbour's (1,780 km of Ohio's county borders no longer met), which leaves slivers
-- between them however the seed draws them. Snapping each level's edges within 15 m back
-- together, country by country, makes it a coverage again, so the seed can simplify it as one
-- (internal/geo's drawingSQL). A place it collapses drops out.
CREATE TABLE place_clean AS
WITH l AS (
    SELECT level, country, ST_CoverageClean(list(g ORDER BY key), 0.00015) AS c, list(key ORDER BY key) AS keys
    FROM place GROUP BY level, country
), d AS (
    SELECT level, keys, UNNEST(ST_Dump(c), recursive := true) FROM l
)
SELECT level, keys[path[1]] AS key, ST_Union_Agg(geom) AS g FROM d GROUP BY level, keys[path[1]];

-- One row per outline, in the column order seed-admin-boundaries COPYs into its staging table:
-- level, kind (what the place is: on the County and City levels a stand-in is the region or
-- county it comes from), key (a country's code, else an Overture division id, 'rest:' and the key
-- of the place above for a stand-in), country code, the keys of its region and of the County-level
-- place it lies in, ISO 3166-2 code, Overture's local_type, English name, other languages' names as JSON, geometry as hex WKB.
COPY (
    SELECT 'country' AS level, 'country' AS kind, key, country, NULL AS region_key, NULL AS county_key,
           NULL AS code, NULL AS local_type, name, names, ST_AsHEXWKB(geometry) AS geom
    FROM country
    UNION ALL
    SELECT 'region', 'region', key, country, NULL, NULL, code, local_type, name, names, ST_AsHEXWKB(geometry)
    FROM region WHERE key NOT LIKE 'country:%'
    UNION ALL
    SELECT p.level, p.kind, p.key, p.country, p.region_key, p.county_key, NULL, p.local_type, p.name, p.names, ST_AsHEXWKB(c.g)
    FROM place p JOIN place_clean c USING (level, key)
    ORDER BY 1, 3
) TO (getvariable('out')) (FORMAT csv, HEADER false, COMPRESSION gzip);
