#!/usr/bin/env bash
# Fails when the API contract breaks an app release production still lets in: each
# android/<versionCode> tag at or above the min_android_build that /healthz reports, and each
# ios/<build> tag at or above its min_ios_build. Only breaks this change adds count; one already
# on the base ref waits for the deploy that raises MIN_ANDROID_BUILD or MIN_IOS_BUILD
# (docs/DEPLOY.md §10).
#
# --needed-floor <commit> prints, per app, the minimum that deploying <commit> needs: the first
# release tag above the newest one its contract breaks, every break counted, or the current
# minimum when none breaks. A value added to a response enum is listed, not counted. It fails when
# even the newest tagged release breaks, since raising the minimum then leaves nothing to update to.
#
# Usage: scripts/check-contract-release.sh [base-ref] (default: origin/main)
#        scripts/check-contract-release.sh --needed-floor <commit>
# Either takes --app android|ios to check one app. Needs Go, curl, jq and the release tags;
# HEALTHZ_URL overrides https://holdmytrack.com/healthz.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OASDIFF=github.com/oasdiff/oasdiff@v1.33.0
usage="Usage: $0 [base-ref] | --needed-floor <commit>, either with [--app android|ios]"
base_ref=origin/main
target=
apps="android ios"
while (( $# )); do
  case $1 in
    --needed-floor) target=${2:?$usage}; shift 2 ;;
    --app)
      apps=${2:?$usage}
      [[ $apps == android || $apps == ios ]] || { echo "$usage" >&2; exit 2; }
      shift 2 ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) base_ref=$1; shift ;;
  esac
done

# Production down shouldn't fail an unrelated pull request: after three tries the floors are 0,
# which checks every tagged release, stricter, so nothing slips through while it's away.
if healthz=$(curl -fsS --retry 2 --retry-all-errors --max-time 20 "${HEALTHZ_URL:-https://holdmytrack.com/healthz}"); then
  android_floor=$(jq -er '.min_android_build // 0' <<<"$healthz")
  ios_floor=$(jq -er '.min_ios_build // 0' <<<"$healthz")
else
  echo "::warning title=Production unreachable::checking every tagged release, not only those its minimum lets in"
  android_floor=0
  ios_floor=0
fi
floor_of() { if [[ $1 == ios ]]; then echo "$ios_floor"; else echo "$android_floor"; fi; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# contract_at <ref> <name>: the contract at <ref>, in $work/<name>.
contract_at() {
  rm -rf "${work:?}/services" "${work:?}/$2"
  git archive "$1" services/server/api | tar -x -C "$work" && mv "$work/services/server/api" "$work/$2"
}

# breaks <old contract> <new contract>: one line per error-level break, without file positions,
# less those services/server/api/breaking-ignore.txt accepts.
breaks() {
  go run "$OASDIFF" breaking "$1" "$2" --format json --err-ignore services/server/api/breaking-ignore.txt |
    jq -r '.[] | select(.level == 3) | [.operation, .path, .id, .text] | join(" ")' | sort -u
}

if [[ -n $target ]]; then
  sha=$(git rev-parse --short "$target^{commit}")
  contract_at "$sha" target
  # A value added to a response enum breaks only a client that decodes the field as an enum.
  enum_added='^[A-Z]+ [^ ]+ response-[a-z-]*enum-value-added '
  status=0
  for app in $apps; do
    var=MIN_$(tr '[:lower:]' '[:upper:]' <<<"$app")_BUILD
    floor=$(floor_of "$app")
    builds=$(git tag -l "$app/*" | sed "s#^$app/##" | grep -E '^[0-9]+$' | sort -n)
    broken=0
    for build in $builds; do
      if (( build < floor )); then continue; fi
      contract_at "$app/$build" release
      breaks "$work/release/openapi.yaml" "$work/target/openapi.yaml" > "$work/all-$build"
      grep -Ev "$enum_added" "$work/all-$build" > "$work/counted-$build" || true
      grep -E "$enum_added" "$work/all-$build" > "$work/enum-$build" || true
      if [[ -s "$work/counted-$build" ]]; then broken=$build; fi
    done
    needed=$floor
    if (( broken > 0 )); then needed=$(awk -v b="$broken" '$1 > b { print; exit }' <<<"$builds"); fi
    if (( broken == 0 )); then
      echo "$var=$floor (unchanged: $sha breaks no $app release from build $floor on)"
    elif [[ -n "$needed" ]]; then
      echo "$var=$needed (raised from $floor: $sha breaks $app/$broken)"
      sed 's/^/  /' "$work/counted-$broken"
    else
      echo "$var: $sha breaks every $app release up to the newest, $app/$broken; release and tag a build that follows it, then run this again"
      sed 's/^/  /' "$work/counted-$broken"
      status=1
      continue
    fi
    for build in $builds; do
      if (( build < needed )) || [[ ! -s "$work/enum-$build" ]]; then continue; fi
      echo "  Not counted, check that $app/$build reads the new value:"
      sed 's/^/    /' "$work/enum-$build"
    done
  done
  exit "$status"
fi

base=$(git merge-base "$base_ref" HEAD)
contract_at "$base" base
failed=0
for app in $apps; do
  floor=$(floor_of "$app")
  for tag in $(git tag -l "$app/*"); do
    build=${tag#*/}
    # A tag's text reaches arithmetic below, which would run a command substitution in it.
    [[ $build =~ ^[0-9]+$ ]] || continue
    if (( build < floor )); then continue; fi
    contract_at "$tag" release
    added=$(comm -13 <(breaks "$work/release/openapi.yaml" "$work/base/openapi.yaml") \
      <(breaks "$work/release/openapi.yaml" services/server/api/openapi.yaml))
    if [[ -n "$added" ]]; then
      echo "Breaks build $build ($tag):"
      sed 's/^/  /' <<<"$added"
      failed=1
    fi
  done
done
if (( failed == 0 )); then
  echo "check-contract-release: no new break for any Android release from build $android_floor on, or iOS release from build $ios_floor on"
fi
exit "$failed"
