#!/usr/bin/env bash
# Fails on the AGENTS.md writing rules a pattern can catch without ever flagging good text:
# intensifiers, meta-narration, "selected" for an activity, its route, track or row, and
# source-code paths in a SPEC.
# The rules a pattern can't judge ("now" as history or as a time, a reason restated beside its
# pointer) stay with the reviewer.
#
# Checks the project's Markdown documents: docs/, the apps' docs/, README.md. AGENTS.md, which
# quotes the words, and the ADRs are left out.
# Usage: scripts/check-doc-style.sh [file...] (default: every such tracked document).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ "$#" -eq 0 ]; then
  # shellcheck disable=SC2046 # one argument per tracked file
  set -- $(git ls-files 'docs/*.md' 'apps/*/docs/*.md' README.md | grep -v '^docs/adr/')
fi

python3 - "$@" <<'PY'
import os, re, sys

RULES = [
    # (applies to, pattern, message)
    (lambda p: True, re.compile(r"\b(deliberately|genuinely|actually|simply|really)\b", re.I),
     "an intensifier (AGENTS.md, Write tight): cut it"),
    (lambda p: True, re.compile(r"(^|[.:]\s+|^[-*]\s+)(This section|As noted above|As mentioned|It is worth noting|Note that)\b"),
     "meta-narration (AGENTS.md, Write tight): state the fact"),
    (lambda p: True, re.compile(r"\bselected\s+(activit|routes?\b|tracks?\b|rows?\b|ones?\b)|\b(activit\w*|routes?|tracks?|rows?)\s+((is|are)\s+)?selected\b", re.I),
     'an activity is Focused or Checked, never "selected" (SPEC.md FR-5.15)'),
    (lambda p: os.path.basename(p) == "SPEC.md", re.compile(r"`[^`\s]+\.(go|ts|tsx|kt|swift|html|sql|mjs|sh|css)`"),
     "a source file in a SPEC (AGENTS.md, One fact, one home): name the behavior, not the file"),
]

failures = 0
github = os.environ.get("GITHUB_ACTIONS") == "true"
for path in sys.argv[1:]:
    if not path.endswith(".md") or not os.path.exists(path):
        continue
    fence = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.startswith("```"):
            fence = not fence
        if fence:
            continue
        # Quoted text and code are what they are.
        prose = re.sub(r"`[^`]*`|\"[^\"]*\"", lambda m: m.group(0) if m.group(0).startswith("`") else "", line)
        for applies, pattern, message in RULES:
            if not applies(path):
                continue
            target = prose if "source file" in message else re.sub(r"`[^`]*`", "", prose)
            m = pattern.search(target)
            if m:
                failures += 1
                if github:
                    print(f"::error file={path},line={n},title=Document style::{message}")
                else:
                    print(f"{path}:{n}: {message}: {m.group(0).strip()!r}")
if failures:
    print(f"check-doc-style: {failures} problem(s)", file=sys.stderr)
    sys.exit(1)
PY