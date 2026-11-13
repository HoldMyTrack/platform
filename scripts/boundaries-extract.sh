#!/usr/bin/env bash
#
# Make the outlines file of every Fog level (docs/DEPLOY.md §6, docs/IMPLEMENTATION.md §4.2.4): cut
# the countries, regions, counties and cities out of a pinned Overture Maps release, less
# OpenStreetMap's sea, with DuckDB, for `seed-admin-boundaries`. Run OFF the server, on a machine
# with the duckdb CLI (brew install duckdb) and about 30 GB of disk free; it reads several GB of GeoParquet from
# Overture's public S3 bucket, no account needed. Nothing here touches a deployment.
#
# Usage:
#   scripts/boundaries-extract.sh <work-dir>
#
# Environment:
#   OVERTURE_DIVISIONS  a local copy of the release's divisions theme, the directory holding
#                       type=division and type=division_area, instead of reading it from S3.
#   PLACES              countries whose counties and cities to take, comma-separated (US,CA), for
#                       a quicker extract to develop with; every country if unset. Its file name
#                       says so, and the seed loads it only with --partial.
#   MEMORY_LIMIT        DuckDB's memory limit, 60% of the machine's memory if unset. The extract
#                       works in a database file in <work-dir>, deleted when it's done, and spills
#                       to disk past the limit: held in memory, the world's peaked at 64 GB and
#                       swapped beside anything else running. The rest is for GEOS, which DuckDB
#                       doesn't count.
#
# The result is <work-dir>/<file>, named after the release; geo.BoundariesKey names the same file,
# so moving to a newer release means changing both. Overture deletes a release a few months after
# the next one, which is why the deployment reads its own copy from the app bucket. The lakes cut
# out of every outline, the inland water cut from the land between a region's counties, and the
# sea, are kept in <work-dir> and reused. osmdata.openstreetmap.de keeps only its latest sea, so
# osm-ocean.date records which day's this is.
#
set -euo pipefail

RELEASE=2026-09-23.0
# Changed with anything that changes the extract's content, since the seed skips a file name it
# has already loaded.
CUT=levels-sea

[[ $# -eq 1 ]] || { echo "Usage: $0 <work-dir>" >&2; exit 2; }
command -v duckdb > /dev/null || { echo "duckdb not found: install it (brew install duckdb, or https://duckdb.org/docs/installation)." >&2; exit 1; }

work=$1
mkdir -p "$work"
places=${PLACES:-}
out="$work/overture-$RELEASE-$CUT${places:+-${places//,/-}}-boundaries.csv.gz"
lakes="$work/overture-$RELEASE-lakes.parquet"
db="$work/extract.duckdb"
water="$work/overture-$RELEASE-water.parquet"
ocean="$work/osm-ocean.parquet"
divisions=${OVERTURE_DIVISIONS:-s3://overturemaps-us-west-2/release/$RELEASE/theme=divisions}
here=$(cd "$(dirname "$0")" && pwd)

log() { echo "$(date -u +%FT%TZ) $*"; }

if [[ -z ${MEMORY_LIMIT:-} ]]; then
    if [[ $(uname) == Darwin ]]; then bytes=$(sysctl -n hw.memsize)
    else bytes=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024 )); fi
    MEMORY_LIMIT="$(( bytes * 6 / 10 / 1024 / 1024 / 1024 ))GB"
fi

if [[ ! -s $lakes ]]; then
    log "reading the lakes from Overture $RELEASE's water into $lakes (about 20 minutes)"
    printf "SET VARIABLE release = '%s';\nSET VARIABLE out = '%s';\n.read %s\n" \
        "$RELEASE" "$lakes" "$here/boundaries-lakes.sql" | duckdb
fi

if [[ ! -s $water ]]; then
    log "reading the inland water from Overture $RELEASE into $water (about 20 minutes)"
    printf "SET VARIABLE release = '%s';\nSET VARIABLE out = '%s';\n.read %s\n" \
        "$RELEASE" "$water" "$here/boundaries-water.sql" | duckdb
fi

if [[ ! -s $ocean ]]; then
    log "reading OpenStreetMap's coastline water polygons into $ocean (about 10 minutes)"
    rm -rf "$work/water-polygons-split-4326" "$work/water-polygons-split-4326.zip"
    curl -fsS -o "$work/water-polygons-split-4326.zip" https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
    unzip -q -d "$work" "$work/water-polygons-split-4326.zip"
    grep "^Date of the data" "$work/water-polygons-split-4326/README.txt" > "$work/osm-ocean.date"
    printf "SET VARIABLE shapefile = '%s';\nSET VARIABLE out = '%s';\n.read %s\n" \
        "$work/water-polygons-split-4326/water_polygons.shp" "$ocean" "$here/boundaries-ocean.sql" | duckdb
    rm -rf "$work/water-polygons-split-4326" "$work/water-polygons-split-4326.zip"
fi

log "extracting Overture $RELEASE divisions into $out, DuckDB's memory limited to $MEMORY_LIMIT"
rm -f "$db" "$db.wal"
printf "SET memory_limit = '%s';\nSET VARIABLE divisions = '%s';\nSET VARIABLE lakes = '%s';\nSET VARIABLE water = '%s';\nSET VARIABLE ocean = '%s';\nSET VARIABLE places = '%s';\nSET VARIABLE out = '%s';\n.read %s\n" \
    "$MEMORY_LIMIT" "$divisions" "$lakes" "$water" "$ocean" "$places" "$out" "$here/boundaries-extract.sql" | duckdb "$db"
rm -f "$db" "$db.wal"

# What to compare against the last extract before uploading: in 2026-09, 272 countries and
# dependencies, 3,922 regions, 41,049 County-level and 382,573 City-level places.
log "done: $out, $(du -h "$out" | cut -f 1)"
gzip -dc "$out" | cut -d , -f 1,2 | sort | uniq -c
