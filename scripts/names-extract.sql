-- PROTOTYPE (FOG_REWORK.md "Borders and names"): the outlines' names in the app's languages other
-- than English, from the same Overture release as boundaries-extract.sql and places-extract.sql,
-- keyed as seed-admin-boundaries and seed-admin-places key them: a country by its code, a region
-- or place by its Overture division id. Sets getvariable('base') and getvariable('out').
INSTALL spatial;
LOAD spatial;
INSTALL httpfs;
LOAD httpfs;
SET s3_region = 'us-west-2';

COPY (
    SELECT DISTINCT CASE WHEN subtype IN ('country', 'dependency') THEN country ELSE division_id END AS key,
           'ru' AS lang, names.common['ru'] AS name
    FROM read_parquet(getvariable('base') || '/type=division_area/*', hive_partitioning = 1)
    WHERE is_land AND names.common['ru'] IS NOT NULL
      AND subtype IN ('country', 'dependency', 'region', 'county', 'locality')
) TO (getvariable('out')) (FORMAT csv, HEADER false);
