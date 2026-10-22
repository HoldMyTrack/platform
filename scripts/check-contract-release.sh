#!/usr/bin/env bash
# Fails when the API contract breaks an Android release production still lets in: each
# android/<versionCode> tag at or above the min_android_build that /healthz reports. Only breaks
# this change adds count; one already on the base ref waits for the deploy that raises
# MIN_ANDROID_BUILD (docs/DEPLOY.md §10).
# Usage: scripts/check-contract-release.sh [base-ref] (default: origin/main). Needs Go, curl, jq
# and the release tags; HEALTHZ_URL overrides https://holdmytrack.com/healthz.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OASDIFF=github.com/oasdiff/oasdiff@v1.33.0
base_ref="${1:-origin/main}"
base=$(git merge-base "$base_ref" HEAD)
floor=$(curl -fsS --max-time 20 "${HEALTHZ_URL:-https://holdmytrack.com/healthz}" | jq -er '.min_android_build // 0')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive "$base" services/server/api | tar -x -C "$work" && mv "$work/services/server/api" "$work/base"

# breaks <old contract> <new contract>: one line per error-level break, without file positions.
breaks() {
  go run "$OASDIFF" breaking "$1" "$2" --format json |
    jq -r '.[] | select(.level == 3) | [.operation, .path, .id, .text] | join(" ")' | sort -u
}

failed=0
for tag in $(git tag -l 'android/*'); do
  build=${tag#android/}
  if (( build < floor )); then continue; fi
  rm -rf "$work/services" "$work/release"
  git archive "$tag" services/server/api | tar -x -C "$work" && mv "$work/services/server/api" "$work/release"
  added=$(comm -13 <(breaks "$work/release/openapi.yaml" "$work/base/openapi.yaml") \
    <(breaks "$work/release/openapi.yaml" services/server/api/openapi.yaml))
  if [[ -n "$added" ]]; then
    echo "Breaks build $build ($tag):"
    sed 's/^/  /' <<<"$added"
    failed=1
  fi
done
if (( failed == 0 )); then
  echo "check-contract-release: no new break for any release from build $floor on"
fi
exit "$failed"
