-- The inland water scripts/boundaries-extract.sql cuts out of the land a region's counties leave
-- uncovered, from the release's water, for scripts/boundaries-extract.sh, which sets
-- getvariable('release') and getvariable('out') and keeps the file between runs.
--
-- Lakes, reservoirs, rivers and canals whose bounding box is about 5 km² or more, not
-- intermittent, simplified to about 20 m. A smaller piece left in a stand-in is a sliver its own
-- filter drops.
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';
SET geometry_always_xy = true;

-- The geometry is tested once read: DuckDB 2.0 fails when a filter on it reaches the Parquet scan.
CREATE TABLE water AS
SELECT geometry
FROM read_parquet('s3://overturemaps-us-west-2/release/' || getvariable('release') ||
                  '/theme=base/type=water/*', hive_partitioning = 1)
WHERE subtype IN ('lake', 'reservoir', 'river', 'water', 'canal') AND class NOT IN ('fairway', 'oxbow')
  AND is_intermittent IS NOT TRUE
  AND (bbox.xmax - bbox.xmin) * (bbox.ymax - bbox.ymin) > 0.0005;

COPY (
    SELECT ST_SimplifyPreserveTopology(ST_MakeValid(geometry), 0.0002) AS geometry
    FROM water
    WHERE ST_GeometryType(geometry) IN ('POLYGON', 'MULTIPOLYGON')
) TO (getvariable('out')) (FORMAT parquet);
