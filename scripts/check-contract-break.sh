#!/usr/bin/env bash
# Fails when the API contract in services/server/api changes in a way an installed client can't
# follow: a response field removed or made optional, a request field made required, an operation
# removed. Additive changes pass. The contract is compared with its copy at the merge base with the
# base ref, by oasdiff's breaking-change rules at error level.
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

go run "$OASDIFF" breaking "$work/services/server/api/openapi.yaml" services/server/api/openapi.yaml --fail-on ERR