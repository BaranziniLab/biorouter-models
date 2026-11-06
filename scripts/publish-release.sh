#!/usr/bin/env bash
# Publishes one staged catalog entry as an immutable GitHub release, then checks it.
#
#   scripts/publish-release.sh <id> <stage dir>
#
# Needs GH_TOKEN and REPO (owner/name) in the environment, and a stage made by
# scripts/stage-release.sh. The steps:
#
#   1. If a published release with the catalog's tag already exists, compare its pinned asset's
#      digest with the pin and stop: reruns are safe. A draft left by an earlier failed run is
#      deleted and made again. A tag with no release stops the run.
#   2. Create the release as a draft, upload the pinned file, read its digest back from GitHub
#      and record it in provenance.json; upload the other assets.
#   3. Publish the draft. With immutable releases on, nothing in it can change from then on.
#   4. Read every asset's digest back and compare it with the local file (and the pinned file
#      with the catalog pin), confirm the release reports immutable, then run
#      `gh release verify` and `gh release verify-asset` on every asset.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: scripts/publish-release.sh <id> <stage dir>"
id=$1
stage=$2
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
cat="catalog/$id.json"
tag=$(jq -r .tag "$cat")
title=$(jq -r .title "$cat")
pin_sha256=$(jq -r .sha256 "$cat")
primary=$(cat "$stage/primary")
assets="$stage/assets"
export TAG="$tag" PRIMARY="$primary"
target=${GITHUB_SHA:-$(git rev-parse HEAD)}

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -lt 6 ] || return 1
    echo "Retrying in $((n * 10)) s: $*"
    sleep $((n * 10))
  done
}

release_row() {
  gh api --paginate "repos/$REPO/releases?per_page=100" \
    --jq '.[] | select(.tag_name == env.TAG) | "\(.id) \(.draft)"'
}

local_digest() { printf 'sha256:%s' "$(sha256sum "$1" | cut -d' ' -f1)"; }

# 1. Skip what is already published.
row=$(release_row)
if [ -n "$row" ]; then
  rid=${row%% *}
  draft=${row##* }
  if [ "$draft" = false ]; then
    got=$(gh api "repos/$REPO/releases/$rid" --jq '.assets[] | select(.name == env.PRIMARY) | .digest')
    [ "$got" = "sha256:$pin_sha256" ] || die "$tag is published, but $primary reports $got, not sha256:$pin_sha256"
    echo "::notice::$tag is already published and $primary matches its pin; nothing to do."
    exit 0
  fi
  echo "Deleting draft release $rid for $tag left by an earlier run."
  gh api -X DELETE "repos/$REPO/releases/$rid"
fi
if gh api "repos/$REPO/git/ref/tags/$tag" >/dev/null 2>&1; then
  die "tag $tag exists but has no release; resolve it by hand before publishing"
fi

# 2. Draft, upload the pinned file, read its digest back.
gh release create "$tag" --repo "$REPO" --draft --title "$title" \
  --notes-file "$stage/notes.md" --target "$target"
rid=$(release_row | cut -d' ' -f1)
[ -n "$rid" ] || die "could not find the draft release for $tag"

gh release upload "$tag" --repo "$REPO" "$assets/$primary"
want="sha256:$pin_sha256"
got=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  got=$(gh api "repos/$REPO/releases/$rid" --jq '.assets[] | select(.name == env.PRIMARY) | .digest // ""')
  [ -n "$got" ] && break
  sleep 3
done
[ "$got" = "$want" ] || die "GitHub reports $primary as '$got' in the draft, expected $want"
echo "Draft digest of $primary: $got"

jq --arg d "$got" '.published.github_digest = $d' "$assets/provenance.json" > "$stage/provenance.tmp"
mv "$stage/provenance.tmp" "$assets/provenance.json"

others=()
for f in "$assets"/*; do
  [ "$(basename "$f")" = "$primary" ] || others+=("$f")
done
gh release upload "$tag" --repo "$REPO" "${others[@]}"

# Every draft asset must match the local file before anything is published.
check_digests() {
  local json name want got
  json=$(gh api "repos/$REPO/releases/$rid")
  for f in "$assets"/*; do
    name=$(basename "$f")
    want=$(local_digest "$f")
    got=$(NAME="$name" jq -r '.assets[] | select(.name == env.NAME) | .digest // ""' <<<"$json")
    [ "$got" = "$want" ] || die "$name: GitHub reports '$got', the local file is $want"
    echo "  $name  $got"
  done
  local count
  count=$(jq '.assets | length' <<<"$json")
  [ "$count" -eq "$(find "$assets" -maxdepth 1 -type f | wc -l)" ] || die "the release holds $count assets, not the staged set"
}
echo "Draft assets:"
check_digests

# 3. Publish.
gh release edit "$tag" --repo "$REPO" --draft=false --latest=false

# 4. Read back and verify.
json=$(gh api "repos/$REPO/releases/tags/$tag")
[ "$(jq -r .draft <<<"$json")" = false ] || die "$tag is still a draft"
[ "$(jq -r .immutable <<<"$json")" = true ] || die "$tag does not report immutable: true"
echo "Published assets:"
check_digests
got=$(jq -r '.assets[] | select(.name == env.PRIMARY) | .digest' <<<"$json")
[ "$got" = "sha256:$pin_sha256" ] || die "$primary reports $got after publishing, expected sha256:$pin_sha256"

retry gh release verify "$tag" --repo "$REPO"
for f in "$assets"/*; do
  retry gh release verify-asset "$tag" "$f" --repo "$REPO"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s\n\n' "$tag"
    printf 'Immutable: %s\n\n| Asset | Digest |\n|---|---|\n' "$(jq -r .immutable <<<"$json")"
    jq -r '.assets[] | "| `\(.name)` | `\(.digest)` |"' <<<"$(gh api "repos/$REPO/releases/tags/$tag")"
    printf '\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "Published and verified $tag."
