-- The sea scripts/boundaries-extract.sql cuts out of every outline: OpenStreetMap's coastline
-- water polygons from osmdata.openstreetmap.de, the coastline the basemap draws, in pieces of at
-- most 256 points so a spatial join touches only the shore it needs. Run by
-- scripts/boundaries-extract.sh, which sets getvariable('shapefile') and getvariable('out').
--
-- The sea is simplified to 50 m, the tolerance the seed draws at: at 10 m the countries' outlines
-- were 31 million points, and the seed's drawing of them ran Postgres out of memory. Each of
-- osmdata's polygons is simplified whole and cut into pieces after, so the pieces meet: simplified
-- one by one, the gaps between them were straight lines of land across the Finnish archipelago.
-- Douglas-Peucker can cross a ring over itself, so each is made valid again; keeping topology
-- instead checked each island against every other, and simplifying the pieces as one coverage
-- crashed DuckDB. osmdata splits its sea on a grid itself, and two neighbours simplified apart
-- could each drop the corner where the coast crosses their shared line, leaving a wedge of land
-- up to 50 m wide: within about 200 m of its frame a polygon keeps its full detail, so
-- neighbours meet as osmdata drew them.
INSTALL spatial;
LOAD spatial;

COPY (
    SELECT UNNEST(ST_Dump(ST_Subdivide(sea, 256)), recursive := true)
    FROM (
        SELECT ST_CollectionExtract(ST_MakeValid(ST_Union(
                   ST_CollectionExtract(ST_MakeValid(ST_Simplify(geom, 0.0005)), 3),
                   ST_Intersection(geom, ST_Difference(ST_Envelope(geom), ST_Buffer(ST_Envelope(geom), -0.002))))), 3) AS sea
        FROM ST_Read(getvariable('shapefile'))
    )
) TO (getvariable('out')) (FORMAT parquet);
