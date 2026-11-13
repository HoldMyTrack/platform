-- The sea scripts/boundaries-extract.sql cuts out of every outline: OpenStreetMap's coastline
-- water polygons from osmdata.openstreetmap.de, the coastline the Protomaps basemap draws, in
-- pieces of at most 256 points so a spatial join touches only the shore it needs. Run by
-- scripts/boundaries-extract.sh, which sets getvariable('shapefile') and getvariable('out').
INSTALL spatial;
LOAD spatial;

COPY (
    SELECT UNNEST(ST_Dump(ST_Subdivide(geom, 256)), recursive := true)
    FROM ST_Read(getvariable('shapefile'))
) TO (getvariable('out')) (FORMAT parquet);