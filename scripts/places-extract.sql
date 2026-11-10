-- PROTOTYPE (FOG_REWORK.md "Next step"): the city tier's outlines, cut from the same Overture
-- release as boundaries-extract.sql, for `seed-admin-places`. Run by scripts/places-extract.sh,
-- which sets getvariable('base') (the release's divisions theme, on S3 or a local copy),
-- getvariable('country') and getvariable('out').
--
-- The places tile the land without overlapping, so a veil over two locked places never stacks:
-- - a city is an outlined locality whose parent is not a locality (FOG_REWORK.md Findings 4);
-- - where two cities overlap (Ohio files Chardon city and Chardon Township both under Geauga
--   County), the smaller is cut out of the larger;
-- - a county keeps only its land outside every city.
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';
SET geometry_always_xy = true;

CREATE TABLE division AS
SELECT id, subtype, parent_division_id AS parent
FROM read_parquet(getvariable('base') || '/type=division/*', hive_partitioning = 1)
WHERE country = getvariable('country');

CREATE TABLE area AS
SELECT a.division_id AS id, a.subtype, a.country, a.region,
       COALESCE(a.names.common['en'], a.names."primary") AS name,
       ST_Area_Spheroid(a.geometry) AS m2,
       a.geometry AS geom
FROM read_parquet(getvariable('base') || '/type=division_area/*', hive_partitioning = 1) a
JOIN division d ON d.id = a.division_id
LEFT JOIN division p ON p.id = d.parent
WHERE a.is_land AND a.country = getvariable('country')
  AND (a.subtype = 'county' OR (a.subtype = 'locality' AND p.subtype IS DISTINCT FROM 'locality'));

-- Each city minus the smaller cities overlapping it; a tie on area goes to the lower id.
CREATE TABLE city AS
WITH smaller AS (
    SELECT c.id, ST_Union_Agg(s.geom) AS geom
    FROM area c JOIN area s ON ST_Intersects(c.geom, s.geom)
    WHERE c.subtype = 'locality' AND s.subtype = 'locality' AND c.id <> s.id
      AND (s.m2 < c.m2 OR (s.m2 = c.m2 AND s.id < c.id))
    GROUP BY c.id
)
SELECT c.id, c.country, c.region, c.name,
       CASE WHEN s.geom IS NULL THEN c.geom ELSE ST_Difference(c.geom, s.geom) END AS geom
FROM area c LEFT JOIN smaller s USING (id)
WHERE c.subtype = 'locality';

CREATE TABLE county AS
WITH inside AS (
    SELECT k.id, ST_Union_Agg(c.geom) AS geom
    FROM area k JOIN area c ON c.subtype = 'locality' AND ST_Intersects(k.geom, c.geom)
    WHERE k.subtype = 'county'
    GROUP BY k.id
)
SELECT k.id, k.country, k.region, k.name,
       CASE WHEN i.geom IS NULL THEN k.geom ELSE ST_Difference(k.geom, i.geom) END AS geom
FROM area k LEFT JOIN inside i USING (id)
WHERE k.subtype = 'county';

-- Cutting leaves slivers where two outlines' shared border doesn't quite match. A piece whose
-- mean width (2 × area / perimeter) is under 30 m is one: no track could be said to be in it.
-- Then simplified to 10 m (FOG_REWORK.md Findings 5).
CREATE TABLE place AS
WITH piece AS (
    SELECT 'city' AS kind, id, country, region, name, UNNEST(ST_Dump(geom), recursive := true) FROM city
    UNION ALL
    SELECT 'county', id, country, region, name, UNNEST(ST_Dump(geom), recursive := true) FROM county
), kept AS (
    SELECT kind, id, country, region, name, geom
    FROM piece
    WHERE ST_GeometryType(geom) = 'POLYGON'
      AND 2 * ST_Area_Spheroid(geom) / NULLIF(ST_Perimeter_Spheroid(geom), 0) >= 30
)
SELECT kind, id, country, region, name,
       ST_SimplifyPreserveTopology(ST_Union_Agg(geom), 0.0001) AS geom
FROM kept
GROUP BY kind, id, country, region, name;

SELECT kind, count(*) AS places, sum(ST_NPoints(geom)) AS points FROM place GROUP BY kind ORDER BY kind;

-- The column order seed-admin-places COPYs: kind, Overture division id, country code, region
-- code, name, geometry as hex WKB.
COPY (
    SELECT kind, id, country, region, name, ST_AsHEXWKB(geom) FROM place ORDER BY 1, 2
) TO (getvariable('out')) (FORMAT csv, HEADER false, COMPRESSION gzip);
