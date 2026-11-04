#!/usr/bin/env bash
# Reports how many words a change adds to or removes from each project document, so growth is
# seen in review. A signal, never a limit: this always exits 0.
#
# Compares each changed Markdown file under docs/ and the apps' docs/, and AGENTS.md and
# README.md, in the working tree with the merge base with the base ref. Under GitHub Actions
# each line is a notice on the file.
# Usage: scripts/check-doc-growth.sh [base-ref] (default: origin/main).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

base_ref="${1:-origin/main}"
if ! base=$(git merge-base "$base_ref" HEAD 2>/dev/null); then
  echo "check-doc-growth: no merge base with $base_ref; nothing checked" >&2
  exit 0
fi

git diff --name-only --diff-filter=AMR "$base" -- 'docs/*.md' 'apps/*/docs/*.md' AGENTS.md README.md |
  while read -r path; do
    [ -f "$path" ] || continue
    now=$(wc -w < "$path" | tr -d ' ')
    before=$(git show "$base:$path" 2>/dev/null | wc -w | tr -d ' ')
    delta=$((now - before))
    [ "$delta" -eq 0 ] && continue
    message="$now words ($(printf '%+d' "$delta"))"
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::notice file=$path,title=Document growth::$message"
    else
      echo "$path: $message"
    fi
  done
exit 0