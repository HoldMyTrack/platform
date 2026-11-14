-- The lakes scripts/boundaries-extract.sql cuts out of every outline, from the release's water, for
-- scripts/boundaries-extract.sh, which sets getvariable('release') and getvariable('out') and keeps
-- the file between runs: reading the water from Overture is most of an extract's time.
--
-- The largest lakes, which the outlines run across to the border in the water, as they run
-- out to sea: Michigan's reached the Canadian border in Lake Huron and Lake Superior,
-- Ontario's the US one in Lake Erie. Taken out like the sea, so a track on the water counts in no
-- place. 1,000 km² keeps Lake Geneva and Lake Tahoe part of the land around them; a smaller lake
-- cut out would be a veiled hole in cleared ground. Intermittent ones are salt pans people cross on
-- foot (Lake Eyre, Etosha Pan). Simplified to about 20 m first: their shorelines at full detail
-- would add 14.5 M points to the outlines.
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';
SET geometry_always_xy = true;

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
COPY (
    SELECT ST_SimplifyPreserveTopology(ST_MakeValid(geometry), 0.0002) AS geometry
    FROM water
    WINDOW whole AS (PARTITION BY COALESCE(wikidata, id))
    QUALIFY sum(m2) OVER whole >= 1e9 AND NOT bool_or(intermittent) OVER whole
) TO (getvariable('out')) (FORMAT parquet);
