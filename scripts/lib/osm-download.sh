# shellcheck shell=bash
# Sourced by the OpenStreetMap extract scripts (spots-extract.sh, bike-paths-extract.sh), not
# run on its own: downloads an OSM file to the current directory as source.osm.pbf and checks
# it. Two scripts run with the same work directory share one download.
#
# The planet's latest-* name is a redirect to a dated file; the checksum beside it names that
# dated file, so download both under fixed names and compare only the hash. Geofabrik serves
# a .md5 beside each extract too. A finished download is reused (and a cut-off one resumed), so
# a failed filter step doesn't mean downloading 85 GB again. source.osm.pbf.want names the
# file a download's bytes belong to: once latest-* has moved on, resuming would append another
# file's tail, so a download of another file stops the run instead, saying how to reuse it.

# shellcheck disable=SC2034 # read by the scripts that source this
PLANET_URL=https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf

log() { echo "$(date -u +%FT%TZ) $*"; }

# osm_download <url>: leaves a checked copy of <url> at ./source.osm.pbf.
osm_download() {
  local url=$1 src=source.osm.pbf want got
  log "fetching the checksum for $url"
  curl -fsSL -o source.md5 "$url.md5"
  want=$(awk '{print $1}' source.md5)

  if [[ -f "$src" && -f "$src.ok" && "$(cat "$src.ok")" == "$want" ]]; then
    log "already downloaded and checked: $src"
    return
  fi
  if [[ -s "$src" && "$(cat "$src.want" 2>/dev/null)" != "$want" ]]; then
    local what="a cut-off download of another file"
    [[ -f "$src.ok" ]] && what="a finished download of another file (md5 $(cat "$src.ok"))"
    echo "$PWD/$src is $what, not of $url (md5 $want)." >&2
    echo "Delete $src to download $url, or pass the URL of the file it is to reuse it:" >&2
    echo "a planet-latest download is planet-<yymmdd>.osm.pbf in the same directory, and its .md5 matches." >&2
    exit 1
  fi
  rm -f "$src.ok"
  echo "$want" > "$src.want"
  log "downloading $url (resumable; re-run to continue after an interruption)"
  curl -fL -C - --retry 5 --retry-delay 30 -o "$src" "$url"
  log "checking md5"
  if command -v md5sum > /dev/null; then got=$(md5sum "$src" | awk '{print $1}'); else got=$(md5 -q "$src"); fi
  if [[ "$got" != "$want" ]]; then
    # A newer file may have been published mid-download, so resuming can't fix this.
    echo "md5 mismatch: got $got, want $want. Delete $PWD/$src and run again." >&2
    exit 1
  fi
  echo "$want" > "$src.ok"
}
