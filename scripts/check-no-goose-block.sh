#!/usr/bin/env bash
# R-31, copied from BaranziniLab/biorouter's scripts/ of the same name and adapted to
# BaranziniLab/biorouter-models: fail when the tracked tree names the project Biorouter no
# longer mentions, or that project's publisher.
#
# Biorouter's owner ruled that those names are purged from every tracked file and every
# tracked file NAME. Biorouter keeps one exception, its NOTICE file; this repository has no
# file that needs the names, so it has no exception at all. This guard is the tripwire. It
# reads the TRACKED tree through git, so scratch files, release assets and downloaded models
# never trip it, and it runs in .github/workflows/guard.yml on every push and pull request.
#
# Allowed, and nothing else:
#   scripts/check-no-goose-block.sh   this file, which has to spell the words
#   the token "mongoose"              an unrelated database library, removed before matching
#   the token "check-no-goose-block"  this script's own name, so a workflow that runs it passes
#
# The ordinary word "block" (code block, blocking, a block's height) is never the target
# and is never matched on its own; only the publisher's name, its possessive, its logo files
# and its repository URLs are.
#
# Binary files are skipped (git grep -I). Text a release builds from upstream data (an
# evaluation set's transcripts) is not tracked, so screen it before committing any of it.
set -euo pipefail
cd "$(dirname "$0")/.."

self='scripts/check-no-goose-block.sh'

# Matched ignoring case. Written without backslashes so awk and grep read it the same way.
ci='goose|geese|gosling|honk|gaggle|block[-_]?lockup|block[.]github[.]io|github[.]com/block([^[:alnum:]_-]|$)|githubusercontent[.]com/block/|repos/block/|://block/'

# Matched exactly as written: "Block" the company, as opposed to the word "block".
cs="Block, Inc|Block Inc([^[:lower:]]|\$)|(^|[^[:alnum:]_])Block's|Square, Inc"

# Reads "path:line:text" on stdin and prints only the lines whose TEXT still matches
# after the allowed tokens are removed. $1 is the regex; $2 is "i" to fold case.
surviving() {
  awk -v re="$1" -v fold="${2:-}" '
    {
      s = $0
      sub(/^[^:]*:[0-9]+:/, "", s)
      if (fold == "i") s = tolower(s)
      gsub(/mongoose/, "", s)
      gsub(/check-no-goose-block/, "", s)
      if (s ~ re) print substr($0, 1, 200)
    }'
}

hits=$(
  {
    git grep -n -I -i -E "$ci" -- . ":(exclude)$self" 2>/dev/null | surviving "$ci" i || true
    git grep -n -I -E "$cs" -- . ":(exclude)$self" 2>/dev/null | surviving "$cs" || true
  } | sort -u
)

# File and directory names are part of the tree too.
names=$(
  git ls-files | awk -v re="$ci" -v self="$self" '
    $0 == self { next }
    {
      s = tolower($0)
      gsub(/mongoose/, "", s)
      gsub(/check-no-goose-block/, "", s)
      if (s ~ re) print $0
    }'
)

fail=0
if [ -n "$hits" ]; then
  printf '::error::tracked text names a removed upstream or its publisher:\n' >&2
  printf '%s\n' "$hits" >&2
  fail=1
fi
if [ -n "$names" ]; then
  printf '::error::tracked file names carry a removed upstream or its publisher:\n' >&2
  printf '%s\n' "$names" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  printf '\nRemove the mention. Do not widen the allowlist in %s.\n' "$self" >&2
  exit 1
fi
echo "check-no-goose-block: the tracked tree is clean."
