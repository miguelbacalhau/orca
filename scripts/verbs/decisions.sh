# shellcheck shell=bash disable=SC2154
#
# orca decisions — renders <repo-root>/.orca/decisions.md, the machine-
# local decision log, deterministically from trunk commit history. No
# agent maintains this file: the commit stage writes canonical decision
# bullets (`- chose X over Y: <reason>`) into the one commit that lands
# each work item, and this verb is a pure extraction over `git log`.
#
# Reading trunk only is the correctness property, not a shortcut: a
# decision committed on an unmerged integration branch stays invisible
# to other runs until the human's merge lands it, so decision
# visibility and code visibility ride the same commits and can never
# disagree. Full-history walk, not --first-parent: item commits sit
# behind the landing merge's second parent. This assumes the landing
# merge preserves commit bodies (`git merge --no-ff`, the documented
# landing path) — a squash-landing collapses the bodies and loses the
# bullets with them.
#
# Usage:
#   orca.sh decisions render <repo-root> --trunk <branch>
#
# Output contract — one machine-readable line per fact, TAB-separated:
#   WROTE:<TAB><path>            the rendered decisions.md
#   ENTRIES:<TAB><n>             decision entries extracted from history
#   TIP:<TAB><short-sha>         the trunk tip the render is current to
#   ARCHIVE:<TAB>included|absent whether decisions.archive.md was appended
#   FAIL:<TAB><reason><TAB><detail>  exit 1, nothing written
#     reasons: BAD_ARGS NOT_GIT UNKNOWN_TRUNK WRITE_ERROR
#
# Entry shape (newest first, IDs stable because they ARE the carrying
# commit): `- **D-<short-sha>** (<commit-date>, <subject>): chose X
# over Y: <reason>`; a commit carrying several bullets suffixes the
# later ones `-2`, `-3`, … in body order. A `.orca/decisions.archive.md`
# beside the output — the frozen pre-programmatic log, if the repo has
# one — is appended verbatim under `## Archived` so old `D<n>`-style
# citations keep resolving; this verb never writes the archive file.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh is
# already loaded.

sub="${1:-}"
[ $# -gt 0 ] && shift

[ "$sub" = "render" ] || fail BAD_ARGS "usage: decisions.sh render <repo-root> --trunk <branch>"

root="" trunk=""
while [ $# -gt 0 ]; do
  case "$1" in
    --trunk)
      [ $# -ge 2 ] || fail BAD_ARGS "--trunk needs a branch name"
      trunk="$2"; shift 2 ;;
    -*) fail BAD_ARGS "unknown option '$1' — usage: decisions.sh render <repo-root> --trunk <branch>" ;;
    *)
      [ -z "$root" ] || fail BAD_ARGS "unexpected argument '$1' — repo root already given as '$root'"
      root="$1"; shift ;;
  esac
done
[ -n "$root" ] || fail BAD_ARGS "usage: decisions.sh render <repo-root> --trunk <branch>"
[ -n "$trunk" ] || fail BAD_ARGS "usage: decisions.sh render <repo-root> --trunk <branch>"
[ -d "$root" ] || fail BAD_ARGS "repo root '$root' is not a directory"

git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || fail NOT_GIT "'$root' is not inside a git repository"
tip="$(git -C "$root" rev-parse --short --verify --quiet "$trunk^{commit}" || true)"
[ -n "$tip" ] || fail UNKNOWN_TRUNK "'$trunk' is not a commit in '$root'"

out_dir="$root/.orca"
out_file="$out_dir/decisions.md"
archive_file="$out_dir/decisions.archive.md"

# Extraction: one @@C@@ line per commit (short sha, commit date,
# subject, TAB-separated), then the raw body; only body lines are
# scanned, so a decision-shaped subject can never mint an entry. The
# bullet grammar is the commit stage's contract — `- chose X over Y:
# <reason>` — accepted with or without the leading dash (existing
# history carries both spellings), and a body-wrapped bullet is joined
# back together with paragraph semantics: the bullet absorbs following
# lines (indented or not — real bodies wrap both ways) until a blank
# line, the next bullet, or the commit boundary, so a reason wrapped
# at 72 columns (colon at end-of-line included) survives whole.
entries="$(git -C "$root" log "$trunk" --format='@@C@@%h%x09%cs%x09%s%n%b' | awk '
  function flush() {
    if (open == "") return
    count++
    id = "D-" sha
    if (count > 1) id = id "-" count
    printf "- **%s** (%s, %s): %s\n", id, cdate, subj, open
    open = ""
  }
  /^@@C@@/ {
    flush()
    line = substr($0, 6)
    n = split(line, a, "\t")
    sha = a[1]; cdate = a[2]
    subj = a[3]; for (i = 4; i <= n; i++) subj = subj "\t" a[i]
    count = 0
    next
  }
  {
    s = $0
    stripped = s
    sub(/^[ \t]*-[ \t]*/, "", stripped)
    sub(/[ \t]+$/, "", stripped)
    if (stripped ~ /^chose .+ over .+:/) { flush(); open = stripped; next }
    if (open != "" && s !~ /^[ \t]*$/) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      open = open " " s
      next
    }
    flush()
  }
  END { flush() }
')"

if [ -n "$entries" ]; then
  n_entries="$(printf '%s\n' "$entries" | grep -c '')"
else
  n_entries=0
fi

tmp_file="$out_file.tmp.$$"
mkdir -p "$out_dir" 2>/dev/null || fail WRITE_ERROR "cannot create $out_dir"
# The banner is prose naming a verb, so its backticks are markdown code
# spans and never any expansion — SC2016 reads them as substitutions.
# shellcheck disable=SC2016
{
  printf '# Decision log\n\n'
  printf '<!-- generated by `orca.sh decisions render` from trunk commit history — do not edit; regenerate any time -->\n\n'
  printf '**As of:** %s\n' "$tip"
  if [ "$n_entries" -gt 0 ]; then
    printf '\n%s\n' "$entries"
  fi
  if [ -f "$archive_file" ]; then
    printf '\n## Archived\n\n'
    cat "$archive_file"
  fi
} >"$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; fail WRITE_ERROR "cannot write $out_file"; }
mv -f "$tmp_file" "$out_file" 2>/dev/null || { rm -f "$tmp_file"; fail WRITE_ERROR "cannot write $out_file"; }

# Conventional checkout only (the bare layout's .orca/ sits outside
# every worktree): keep a stray `git add -A` from committing the
# machine-local file, same upkeep the config verb performs.
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common" ] && [ "$(git --git-dir="$common" rev-parse --is-bare-repository 2>/dev/null)" != "true" ]; then
  mkdir -p "$common/info"
  grep -qxF '.orca/' "$common/info/exclude" 2>/dev/null || printf '.orca/\n' >>"$common/info/exclude"
fi

printf 'WROTE:\t%s\n' "$out_file"
printf 'ENTRIES:\t%s\n' "$n_entries"
printf 'TIP:\t%s\n' "$tip"
if [ -f "$archive_file" ]; then
  printf 'ARCHIVE:\tincluded\n'
else
  printf 'ARCHIVE:\tabsent\n'
fi
exit 0
