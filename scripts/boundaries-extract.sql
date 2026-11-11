-- The country and region outlines `seed-admin-boundaries` loads (docs/IMPLEMENTATION.md §4.2.4),
-- cut from one pinned Overture Maps release's divisions theme. Run by
-- scripts/boundaries-extract.sh, which sets getvariable('release') and getvariable('out').
--
-- Overture's divisions are OpenStreetMap's boundaries (plus a few CC BY 4.0 sources) under ODbL,
-- so this file is also the public record of how the derived outlines were made.
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';
SET geometry_always_xy = true;

CREATE TABLE area AS
SELECT division_id,
       subtype,
       country,
       region,
       COALESCE(names.common['en'], names."primary") AS name,
       geometry
FROM read_parquet('s3://overturemaps-us-west-2/release/' || getvariable('release') ||
                  '/theme=divisions/type=division_area/*', hive_partitioning = 1)
-- The land-clipped outline: a coastal country's other outline runs 12 nautical miles out to sea.
WHERE subtype IN ('country', 'dependency', 'region') AND is_land;

-- The largest lakes, which the land-clipped outlines run across to the border in the water, as
-- they run to the coast: Michigan's reached the Canadian border in Lake Huron and Lake Superior,
-- Ontario's the US one in Lake Erie. Taken out like the sea, so a track on the water counts in no
-- place. 1,000 km² keeps Lake Geneva and Lake Tahoe part of the land around them; a smaller lake
-- cut out would be a veiled hole in cleared ground. Intermittent ones are salt pans people cross on
-- foot (Lake Eyre, Etosha Pan). Simplified to about 20 m first: their shorelines at full detail
-- would add 14.5 M points to the outlines.
CREATE TABLE water AS
SELECT id, wikidata, is_intermittent IS TRUE AS intermittent, ST_Area_Spheroid(geometry) AS m2, geometry
FROM read_parquet('s3://overturemaps-us-west-2/release/' || getvariable('release') ||
                  '/theme=base/type=water/*', hive_partitioning = 1)
WHERE subtype IN ('lake', 'reservoir', 'water') AND class NOT IN ('fairway', 'oxbow')
  -- 1,000 km² is at least 0.08 square degrees of bounding box, which skips most rows unread; a
  -- smaller piece counts only as part of a lake named by its Wikidata id.
  AND ((bbox.xmax - bbox.xmin) * (bbox.ymax - bbox.ymin) > 0.08 OR wikidata IS NOT NULL);

-- A lake is judged whole, by the pieces sharing its Wikidata id, and is intermittent if any piece
-- is: OpenStreetMap splits some (the Kuybyshev Reservoir is five, from 2,363 km² down to 23, and
-- Red Lake's two basins are each under 1,000) and draws some twice, tagged unevenly.
CREATE TABLE lake AS
SELECT ST_SimplifyPreserveTopology(ST_MakeValid(geometry), 0.0002) AS geometry
FROM water
WINDOW whole AS (PARTITION BY COALESCE(wikidata, id))
QUALIFY sum(m2) OVER whole >= 1e9 AND NOT bool_or(intermittent) OVER whole;

UPDATE area SET geometry = ST_Difference(area.geometry, cut.geometry)
FROM (
    SELECT a.division_id, ST_Union_Agg(l.geometry) AS geometry
    FROM area a JOIN lake l ON ST_Intersects(a.geometry, l.geometry)
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

-- One row per outline, in the column order seed-admin-boundaries COPYs into its staging table:
-- kind, key (a country's code, a region's Overture division id), country code, region code,
-- name, geometry as hex WKB.
COPY (
    SELECT 'country' AS kind, country AS key, country, NULL AS code, name, ST_AsHEXWKB(geometry) AS geom
    FROM area WHERE subtype IN ('country', 'dependency')
    UNION ALL
    SELECT 'region', division_id, country, region, name, ST_AsHEXWKB(geometry)
    FROM area WHERE subtype = 'region' AND division_id NOT IN (SELECT division_id FROM duplicate)
    ORDER BY 1, 2
) TO (getvariable('out')) (FORMAT csv, HEADER false, COMPRESSION gzip);
