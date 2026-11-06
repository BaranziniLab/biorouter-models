#!/usr/bin/env bash
# Stages one catalog entry for release, without touching GitHub.
#
#   scripts/stage-release.sh <id> <stage dir>
#
# <id> names catalog/<id>.json. For a model it downloads the file from the pinned upstream
# revision and checks its size, SHA-256, SHA-1 and the legacy ggml magic. For an evaluation set
# it runs the builder named in the catalog and checks the archive's size and SHA-256. Then it
# writes provenance.json, SHA256SUMS, the release notes and (for a model) NOTICE.md.
#
# Output: <stage dir>/assets/ holds every release asset; <stage dir>/notes.md the release body;
# <stage dir>/primary the name of the asset whose digest is pinned in the catalog.
#
# Set ALLOW_UNPINNED=1 to build an evaluation set whose catalog has no pin yet; the script then
# prints the values to pin and stops before writing release files.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: scripts/stage-release.sh <id> <stage dir>"
id=$1
stage=$2
[[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad id: $id"
cat="catalog/$id.json"
[ -f "$cat" ] || die "no catalog entry: $cat"

j() { jq -r "$1" "$cat"; }

kind=$(j .kind)
tag=$(j .tag)
file=$(j .file)
pin_bytes=$(j '.bytes // empty')
pin_sha256=$(j '.sha256 // empty')

case "$kind" in
  model)
    [[ "$tag" =~ ^stt-${id//./\\.}-r[1-9][0-9]*$ ]] || die "tag $tag does not match stt-$id-r<n>"
    ;;
  eval)
    [[ "$id" =~ ^eval- ]] || die "an evaluation entry's id starts with eval-: $id"
    [[ "$tag" =~ ^${id//./\\.}-r[1-9][0-9]*$ ]] || die "tag $tag does not match $id-r<n>"
    ;;
  *) die "unknown kind: $kind" ;;
esac

rm -rf "$stage"
mkdir -p "$stage/assets" "$stage/work"
assets="$stage/assets"
acquired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
run_url=""
if [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

if [ "$kind" = model ]; then
  url=$(j .source.url)
  revision=$(j .source.revision)
  pin_sha1=$(j '.sha1 // empty')
  [[ "$url" == https://huggingface.co/* ]] || die "source url is not on huggingface.co: $url"
  [[ "$url" == */resolve/"$revision"/"$file" ]] || die "source url does not name revision $revision and file $file"
  [ -n "$pin_sha256" ] && [ -n "$pin_bytes" ] || die "a model entry needs bytes and sha256"

  echo "Downloading $url"
  curl -fL --proto '=https' --retry 5 --retry-all-errors --connect-timeout 30 \
    -o "$assets/$file" "$url"

  got_bytes=$(stat -c %s "$assets/$file")
  got_sha256=$(sha256sum "$assets/$file" | cut -d' ' -f1)
  got_sha1=$(sha1sum "$assets/$file" | cut -d' ' -f1)
  [ "$got_bytes" = "$pin_bytes" ] || die "$file is $got_bytes bytes, expected $pin_bytes"
  [ "$got_sha256" = "$pin_sha256" ] || die "$file SHA-256 is $got_sha256, expected $pin_sha256"
  if [ -n "$pin_sha1" ]; then
    [ "$got_sha1" = "$pin_sha1" ] || die "$file SHA-1 is $got_sha1, expected $pin_sha1"
  fi
  if [ "$(j '.check_ggml_magic')" = true ]; then
    magic=$(head -c 4 "$assets/$file" | od -An -tx1 | tr -d ' \n')
    # 0x67676d6c stored little endian: the bytes "lmgg".
    [ "$magic" = 6c6d6767 ] || die "$file does not start with the legacy ggml magic (got $magic)"
  fi
  echo "Checked $file: $got_bytes bytes, sha256 $got_sha256, sha1 $got_sha1"

  printf '%s  %s\n' "$got_sha256" "$file" > "$assets/SHA256SUMS"

  jq -n \
    --argjson c "$(cat "$cat")" \
    --arg sha1 "$got_sha1" \
    --arg acquired_at "$acquired_at" \
    --arg repo "${GITHUB_REPOSITORY:-BaranziniLab/biorouter-models}" \
    --arg commit "$commit" \
    --arg run_url "$run_url" \
    '{
      id: $c.id,
      file: $c.file,
      bytes: $c.bytes,
      sha256: $c.sha256,
      sha1: $sha1,
      format: $c.format,
      acquired_from: {
        url: $c.source.url,
        revision: $c.source.revision,
        hf_lfs_sha256: $c.source.hf_lfs_sha256,
        upstream_published_sha1: $c.source.upstream_published_sha1,
        acquired_at: $acquired_at
      },
      derived_from: $c.derived_from,
      license: $c.license,
      published: {
        repo: $repo,
        tag: $c.tag,
        github_digest: null,
        catalog_commit: $commit,
        workflow_run: (if $run_url == "" then null else $run_url end)
      }
    }' > "$assets/provenance.json"

  {
    printf '# Notice for %s\n\n' "$file"
    printf 'Release `%s` of BaranziniLab/biorouter-models.\n\n' "$tag"
    printf '## Who made the weights\n\n%s\n\n' "$(j .notice.weights)"
    printf '## Who converted them\n\n%s\n\n' "$(j .notice.conversion)"
    printf '## Who hosts them\n\n%s\n\n' "$(j .notice.hosting)"
    printf 'This copy was downloaded from %s and checked against the Hugging Face LFS SHA-256' "$url"
    if [ "$(j '.source.upstream_published_sha1 // empty')" != "" ]; then
      printf ' and the SHA-1 that upstream publishes'
    fi
    printf '.\n\nSHA-256: `%s`\n' "$got_sha256"
  } > "$assets/NOTICE.md"

  {
    printf '%s\n\n' "$(j .title)"
    printf '| | |\n|---|---|\n'
    printf '| File | `%s` |\n' "$file"
    printf '| Size | %s bytes |\n' "$got_bytes"
    printf '| SHA-256 | `%s` |\n' "$got_sha256"
    printf '| SHA-1 | `%s` |\n' "$got_sha1"
    printf '| Format | %s |\n' "$(j .format)"
    printf '| Languages | %s |\n' "$(j .languages)"
    printf '| License | %s (%s) |\n' "$(j .license.spdx)" "$(j '.license.holders | join(", ")')"
    printf '| Source | %s |\n\n' "$url"
    printf 'The file is byte identical to the upstream file at the pinned revision. '
    printf 'Biorouter downloads it only by this release'"'"'s exact URL and refuses it unless its SHA-256 matches the value compiled into the app.\n\n'
    printf 'Published by the publish-model workflow from catalog commit `%s`.' "$commit"
    if [ -n "$run_url" ]; then printf ' Run: %s' "$run_url"; fi
    printf '\n'
  } > "$stage/notes.md"
else
  script=$(j .build.script)
  selection=$(j .build.selection)
  [ -f "$script" ] && [ -f "$selection" ] || die "builder or selection missing for $id"
  license_file="licenses/$(j '.license.files[0]')"
  python3 -I "$script" --selection "$selection" --license "$license_file" --out "$stage/work"

  [ -f "$stage/work/$file" ] || die "the builder did not write $file"
  got_bytes=$(stat -c %s "$stage/work/$file")
  got_sha256=$(sha256sum "$stage/work/$file" | cut -d' ' -f1)
  echo "Built $file: $got_bytes bytes, sha256 $got_sha256"
  if [ -z "$pin_sha256" ] || [ -z "$pin_bytes" ]; then
    if [ "${ALLOW_UNPINNED:-}" = 1 ]; then
      echo "Unpinned build: pin \"bytes\": $got_bytes and \"sha256\": \"$got_sha256\" in $cat"
      exit 0
    fi
    die "$cat has no bytes and sha256 pin for $file"
  fi
  [ "$got_bytes" = "$pin_bytes" ] || die "$file is $got_bytes bytes, expected $pin_bytes; the build did not reproduce"
  [ "$got_sha256" = "$pin_sha256" ] || die "$file SHA-256 is $got_sha256, expected $pin_sha256; the build did not reproduce"

  mv "$stage/work/$file" "$assets/$file"
  cp "$stage/work/ATTRIBUTION.md" "$assets/ATTRIBUTION.md"
  (cd "$assets" && sha256sum "$file" ATTRIBUTION.md) > "$assets/SHA256SUMS"

  jq -n \
    --argjson c "$(cat "$cat")" \
    --argjson b "$(cat "$stage/work/build-info.json")" \
    --arg acquired_at "$acquired_at" \
    --arg repo "${GITHUB_REPOSITORY:-BaranziniLab/biorouter-models}" \
    --arg commit "$commit" \
    --arg run_url "$run_url" \
    '{
      id: $c.id,
      file: $c.file,
      bytes: $c.bytes,
      sha256: $c.sha256,
      format: $c.format,
      acquired_from: {
        url: ($c.source.repository + "/tree/" + $c.source.commit),
        commit: $c.source.commit,
        acquired_at: $acquired_at
      },
      derived_from: {
        original: $c.derived_from.original,
        conversion: $c.derived_from.conversion,
        builder: $c.build.script,
        selection: $c.build.selection,
        flac: $b.flac_version
      },
      contents: $b.counts,
      license: $c.license,
      published: {
        repo: $repo,
        tag: $c.tag,
        github_digest: null,
        catalog_commit: $commit,
        workflow_run: (if $run_url == "" then null else $run_url end)
      }
    }' > "$assets/provenance.json"

  {
    printf '%s\n\n' "$(j .title)"
    j .description
    printf '\n| | |\n|---|---|\n'
    printf '| File | `%s` |\n' "$file"
    printf '| Size | %s bytes |\n' "$got_bytes"
    printf '| SHA-256 | `%s` |\n' "$got_sha256"
    printf '| Source | %s at `%s` |\n' "$(j .source.repository)" "$(j .source.commit)"
    printf '| License | %s; see ATTRIBUTION.md |\n\n' "$(j .license.spdx)"
    printf '## Selection\n\n'
    j '.selection_notes[]' | sed 's/^/- /'
    printf '\nBiorouter never downloads this release at run time; only its accuracy tests read it.\n\n'
    printf 'Published by the publish-model workflow from catalog commit `%s`.' "$commit"
    if [ -n "$run_url" ]; then printf ' Run: %s' "$run_url"; fi
    printf '\n'
  } > "$stage/notes.md"
fi

jq -r '.license.files[]' "$cat" | while read -r lf; do
  [ -f "licenses/$lf" ] || die "license text missing: licenses/$lf"
  cp "licenses/$lf" "$assets/$lf"
done

printf '%s\n' "$file" > "$stage/primary"
echo "Staged $tag:"
(cd "$assets" && ls -l)
