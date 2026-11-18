# shellcheck shell=bash
# Sourced by backup.sh and restore-drill.sh, not run on its own: the tables the nightly dump
# leaves the data of out, which the drill checks it left out. Both run from the repository root.
#
# pg_dump's --exclude-table-data matches a name the database doesn't have to nothing and dumps
# the table under its new name in full, so a migration renaming one of these renames it here
# too; missing_backup_tables is how both scripts catch a missed one.

# Written only by `import-spots`, `import-bike-paths`, `seed-admin-boundaries` and
# `seed-timezones`.
REFERENCE_TABLES=(spots bike_paths admin_countries admin_country_parts admin_regions admin_region_parts
  admin_counties admin_county_parts admin_cities admin_city_parts admin_boundaries_source tz_parts
  tz_boundaries_source)
# Left out of every dump: rebuilt on demand (the tile cache) or by `rerender-coverage --masks`.
REBUILT_TABLES=(admin_tile_geoms admin_tiles_built track_tile_mask_data)
# Left out of every dump: the visitor salts and hashes, deleted within 2 days (docs/DPIA.md), which
# a dump kept for weeks would otherwise outlive.
SHORT_LIVED_TABLES=(visitor_salts visitor_days)

# The tables above that the database $1 queries (a function taking one SQL statement, such as
# db_psql) doesn't have, space-separated; nothing when it has them all.
missing_backup_tables() {
  local list
  list=$(IFS=,; echo "${REFERENCE_TABLES[*]},${REBUILT_TABLES[*]},${SHORT_LIVED_TABLES[*]}")
  "$1" "SELECT coalesce(string_agg(t, ' '), '') FROM unnest(string_to_array('$list', ',')) t
        WHERE to_regclass('public.' || t) IS NULL"
}

# Whether the database $1 queries has run this checkout's newest migration. One behind can still
# have a renamed table's old name: a deploy's rollback dump is taken before `migrate`
# (docs/DEPLOY.md §7), and the drill's dump can predate the deploy.
at_newest_migration() {
  local newest
  newest=$(find services/server/migrations -name '*.sql' -exec basename {} \; | sort | tail -n 1)
  [[ "$("$1" 'SELECT max(filename) FROM schema_migrations')" == "$newest" ]]
}