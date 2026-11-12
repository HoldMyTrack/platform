#!/usr/bin/env bash
#
# Make the outlines file of every Fog level (docs/DEPLOY.md §6, docs/IMPLEMENTATION.md §4.2.4): cut
# the land-clipped countries, regions, counties and cities out of a pinned Overture Maps release
# with DuckDB, for `seed-admin-boundaries`. Run OFF the server, on a machine with the duckdb CLI
# (brew install duckdb) and 64 GB of memory, which the world's extract peaks at (about 15 minutes
# on 10 cores); it reads several GB of GeoParquet from Overture's public S3 bucket, no account
# needed. Nothing here touches a deployment.
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
#
# The result is <work-dir>/<file>, named after the release; geo.BoundariesKey names the same file,
# so moving to a newer release means changing both. Overture deletes a release a few months after
# the next one, which is why the deployment reads its own copy from the app bucket. The lakes cut
# out of every outline, and the inland water cut from the land between a region's counties, are
# kept in <work-dir> and reused.
#
set -euo pipefail

RELEASE=2026-09-23.0
# Changed with anything that changes the extract's content, since the seed skips a file name it
# has already loaded.
CUT=levels-water

[[ $# -eq 1 ]] || { echo "Usage: $0 <work-dir>" >&2; exit 2; }
command -v duckdb > /dev/null || { echo "duckdb not found: install it (brew install duckdb, or https://duckdb.org/docs/installation)." >&2; exit 1; }

work=$1
mkdir -p "$work"
places=${PLACES:-}
out="$work/overture-$RELEASE-$CUT${places:+-${places//,/-}}-boundaries.csv.gz"
lakes="$work/overture-$RELEASE-lakes.parquet"
water="$work/overture-$RELEASE-water.parquet"
divisions=${OVERTURE_DIVISIONS:-s3://overturemaps-us-west-2/release/$RELEASE/theme=divisions}
here=$(cd "$(dirname "$0")" && pwd)

log() { echo "$(date -u +%FT%TZ) $*"; }

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

log "extracting Overture $RELEASE divisions into $out"
printf "SET VARIABLE divisions = '%s';\nSET VARIABLE lakes = '%s';\nSET VARIABLE water = '%s';\nSET VARIABLE places = '%s';\nSET VARIABLE out = '%s';\n.read %s\n" \
    "$divisions" "$lakes" "$water" "$places" "$out" "$here/boundaries-extract.sql" | duckdb

# What to compare against the last extract before uploading: in 2026-09, 272 countries and
# dependencies, 3,922 regions, 41,179 County-level and 382,538 City-level places.
log "done: $out, $(du -h "$out" | cut -f 1)"
gzip -dc "$out" | cut -d , -f 1,2 | sort | uniq -c
