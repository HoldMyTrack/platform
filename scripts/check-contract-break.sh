#!/usr/bin/env bash
# Fails when an API contract in services/server/api changes in a way an installed client can't
# follow: a response field removed or made optional, a request field made required, an operation
# removed. Additive changes pass. Each contract, /v1's openapi.yaml and /v2's v2/openapi.yaml, is
# compared with its copy at the merge base with the base ref, by oasdiff's breaking-change rules at
# error level, less the entries its directory's breaking-ignore.txt accepts, each with why no
# client is affected. A contract the merge base doesn't have yet is new, with nothing to compare.
# Usage: scripts/check-contract-break.sh [base-ref] (default: origin/main). Needs Go.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

OASDIFF=github.com/oasdiff/oasdiff@v1.33.0
base_ref="${1:-origin/main}"
base=$(git merge-base "$base_ref" HEAD)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! git archive "$base" services/server/api | tar -x -C "$work" 2>/dev/null; then
  echo "check-contract-break: no contract at $base; nothing to compare"
  exit 0
fi

status=0
for dir in services/server/api services/server/api/v2; do
  if [[ ! -f "$work/$dir/openapi.yaml" ]]; then
    echo "check-contract-break: no $dir/openapi.yaml at $base; nothing to compare"
    continue
  fi
  go run "$OASDIFF" breaking "$work/$dir/openapi.yaml" "$dir/openapi.yaml" --fail-on ERR \
    --err-ignore "$dir/breaking-ignore.txt" || status=1
done
exit "$status"
