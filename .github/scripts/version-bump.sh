#!/usr/bin/env bash
# Guard against shipped plugin changes landing on main without a version bump:
# the plugin updater keys its install cache on .claude-plugin/plugin.json's
# version, so a main tip that changes shipped files but not the version makes
# later updates silently serve the old code.
#
# The check is stateless and self-healing: find the commit that introduced the
# current version, and if any shipped paths changed since it, bump and push a
# commit. A missed or failed run is repaired by the next one. The bump size
# follows Conventional Commits across the uncovered range: a breaking marker
# (`!` after the type, or a BREAKING CHANGE footer) bumps major, `feat` bumps
# minor, anything else bumps patch. A manual bump of any size covers the
# changes that landed with it, so the run becomes a no-op.
#
# Run from the repository root on the main branch with full history.
set -euo pipefail

MANIFEST=".claude-plugin/plugin.json"
SHIPPED=(skills agents scripts .claude-plugin)

version_at() {
  git show "$1:$MANIFEST" 2>/dev/null | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p'
}

current=$(version_at HEAD)
[[ -n "$current" ]] || {
  echo "version-bump: cannot read a version from $MANIFEST at HEAD" >&2
  exit 1
}

# base = the commit that introduced the current version: walk the
# manifest-touching commits from newest to oldest while they still carry the
# current version. Shipped changes after base are covered by no bump.
base=HEAD
while read -r commit; do
  [[ "$(version_at "$commit")" == "$current" ]] || break
  base=$commit
done < <(git log --format=%H -- "$MANIFEST")

changed=$(git diff --name-only "$base" HEAD -- "${SHIPPED[@]}")
if [[ -z "$changed" ]]; then
  echo "version-bump: no shipped changes since $current was introduced — nothing to do"
  exit 0
fi

[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
  echo "version-bump: version '$current' in $MANIFEST is not semver — fix it manually" >&2
  exit 1
}
major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"

breaking_re='^[a-z]+(\([^)]*\))?!: ' feat_re='^feat(\([^)]*\))?: ' footer_re='^BREAKING[- ]CHANGE: '
bump="patch"
# Size from SHIPPED-touching commits only: a feat that changes nothing
# shipped must not size the bump a chore's shipped change triggers.
while IFS= read -r subject; do
  if [[ "$subject" =~ $breaking_re ]]; then bump=major; break; fi
  if [[ "$subject" =~ $feat_re ]]; then bump=minor; fi
done < <(git log --format=%s "$base..HEAD" -- "${SHIPPED[@]}")
if [[ "$bump" != major ]]; then
  # BREAKING CHANGE must be a footer token: only each body's final
  # paragraph is scanned, so prose or a quoted mention mid-body never
  # majors a release.
  # %x01 as the record separator, not NUL: BSD awk (macOS, where the test
  # suite also runs this) does not honor a NUL RS.
  while IFS= read -r line; do
    if [[ "$line" =~ $footer_re ]]; then bump=major; break; fi
  done < <(git log --format='%b%x01' "$base..HEAD" -- "${SHIPPED[@]}" | awk '
    BEGIN { RS = "\001" }
    {
      n = split($0, L, "\n")
      end = 0
      for (i = n; i >= 1; i--) if (L[i] !~ /^[[:space:]]*$/) { end = i; break }
      if (!end) next
      begin = 1
      for (i = end; i >= 1; i--) if (L[i] ~ /^[[:space:]]*$/) { begin = i + 1; break }
      for (i = begin; i <= end; i++) print L[i]
    }')
fi

case "$bump" in
  major) bumped="$((major + 1)).0.0" ;;
  minor) bumped="$major.$((minor + 1)).0" ;;
  *)     bumped="$major.$minor.$((patch + 1))" ;;
esac

# Portable in-place edit: BSD sed's -i takes a mandatory suffix argument,
# so GNU-style `sed -i "s/…/"` breaks on macOS (where the test suite runs
# this too). Temp file + mv works everywhere.
sed "s/\"version\": *\"$current\"/\"version\": \"$bumped\"/" "$MANIFEST" >"$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
git add "$MANIFEST"
git commit --quiet -m "chore: bump plugin version to $bumped"
# A push that lands mid-run rejects ours; rebase once and retry — if that also
# fails, exit nonzero and let the racing push's own run repair the gap.
git push origin HEAD:main || { git pull --rebase --quiet origin main && git push origin HEAD:main; }
echo "version-bump: shipped files changed since $current — bumped to $bumped ($bump)"
