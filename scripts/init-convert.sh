#!/usr/bin/env bash
#
# orca init-convert — the mechanical core of orca:init's conventional-to-bare
# conversion. The skill stays the conversational shell (the before/after
# presentation, every consent gate, failure translation); this script owns
# the one data-loss step in the plugin — moving every untracked file,
# ignored ones included, into the new worktree — NUL-safe throughout, so
# filenames with spaces or newlines survive. The mutating subcommands are
# consent-separated on purpose: the skill confirms before convert and again
# before cleanup, exactly as the prose procedure did; recover exists for
# crashes and takes no new consent (it only completes what convert began).
#
# Usage:
#   init-convert.sh check
#   init-convert.sh convert
#   init-convert.sh cleanup
#   init-convert.sh recover
#
# Output contract — one machine-readable line per fact, TAB-separated:
#
#   check (read-only; run from anywhere inside the main checkout):
#     CLEAN:<TAB>PASS|FAIL<TAB><detail>          no staged/unstaged changes
#                                                (untracked files are fine)
#     NO_WORKTREES:<TAB>PASS|FAIL<TAB><detail>   only the main checkout
#     NO_SUBMODULES:<TAB>PASS|FAIL<TAB><detail>  .gitmodules absent
#     BRANCH:<TAB><name>                         informational
#     UNTRACKED_COUNT:<TAB><n>                   informational — what convert
#                                                will move (.orca/ excluded:
#                                                it stays at the top level in
#                                                the target layout)
#     Exit 1 on any FAIL line.
#
#   convert (mutating): re-verifies the check gates, then runs the
#   conversion — NUL-safe untracked manifest (git ls-files --others -z,
#   ignored included), mv .git .bare, core.bare true, the gitdir pointer
#   file, the default worktree, and the manifest moves preserving relative
#   paths. Persists the manifest at .orca/init-convert-manifest for
#   cleanup's reconciliation. Emits:
#     MOVED:<TAB><n>
#     VERIFY:<TAB><tracked summary><TAB><untracked summary>
#   and stops BEFORE the final top-level deletion. Everything up to here is
#   reversible, in this order (worktree and pointer file first — .git must
#   be gone before .bare can move back): rm -rf ./<branch>, rm -f .git,
#   mv .bare .git, git config core.bare false, git worktree prune.
#
#   cleanup (mutating, destructive): refuses unless the default worktree
#   exists and EVERY manifest file is present in it, then deletes only
#   entries it can prove are conversion leftovers: top-level names of
#   tracked content at HEAD, or top-level parents of manifest entries.
#   Registered worktrees are never deleted. Any other top-level entry is
#   named in a typed FAIL: and nothing is deleted. Emits one
#   REMOVED:<TAB><path> line per deleted entry and a final CLEANED:<TAB><n>,
#   and consumes the manifest.
#
#   recover (mutating): completes a conversion that a crash or signal cut
#   short. convert journals every structural step and every file move
#   (intent before, done after) to .orca/init-convert-journal and traps
#   INT/TERM/HUP; recover reads the journal plus the on-disk state, rolls
#   the conversion forward (bare config, pointer file, worktree, remaining
#   manifest moves — each idempotent), re-verifies, and consumes the
#   journal. Run it from the repository root. If the crash predated any
#   mutation it just removes the journal.
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: NOT_GIT ALREADY_CONVERTED LINKED_WORKTREE NOT_CONVENTIONAL
#                DETACHED_HEAD BRANCH_UNSAFE PRECONDITION CONVERT_FAILED
#                NOT_CONVERTED NO_WORKTREE NO_MANIFEST MANIFEST_MISMATCH
#                INTERRUPTED NO_JOURNAL OLD_GIT BAD_ARGS

set -uo pipefail

fail() { # <reason> <detail> — typed failure, exit 1
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

# Crash journal: NUL-terminated (verb, detail) pairs, appended and fsync'd
# by the shell's O_APPEND semantics. Verbs: begin <branch>, step <name>,
# intent <path>, done <path>, interrupted <signal>. recover replays it.
journal_path() { printf '%s/.orca/init-convert-journal' "$root"; }
journal_append() { printf '%s\0%s\0' "$1" "$2" >>"$(journal_path)"; }

# shellcheck disable=SC2317,SC2329  # invoked indirectly via trap
on_signal() { # <signal-name> — journal the interruption and die typed
  journal_append interrupted "$1"
  printf 'FAIL:\tINTERRUPTED\tconversion interrupted by SIG%s — run init-convert.sh recover from the repository root\n' "$1"
  trap - INT TERM HUP
  exit 1
}
install_traps() {
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
}

# Move every manifest entry not yet at its destination into the worktree,
# journaling intent before and done after each move. Idempotent: entries
# already moved are skipped, so convert and recover share it. Sets
# $moved_count (no subshell — fail must reach the caller's stdout/exit).
move_manifest_entries() { # uses $root $branch $manifest
  local f dest
  moved_count=0
  while IFS= read -r -d '' f; do
    if [[ ! -e "$root/$f" && ! -L "$root/$f" ]]; then
      continue # already moved (or a prior run finished this one)
    fi
    dest="$root/$branch/$f"
    journal_append intent "$f"
    mkdir -p "${dest%/*}" \
      || fail CONVERT_FAILED "mkdir failed for $f — moves incomplete; run init-convert.sh recover"
    mv "$root/$f" "$dest" \
      || fail CONVERT_FAILED "move failed for $f — moves incomplete; run init-convert.sh recover"
    journal_append 'done' "$f"
    moved_count=$((moved_count + 1))
  done <"$manifest"
}

# Emit the VERIFY line: tracked files clean in the worktree, manifest
# entries all arrived. Uses $root $branch $manifest.
verify_conversion() {
  local f tracked_dirty missing=0 total=0
  tracked_dirty="$(git -C "$root/$branch" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  while IFS= read -r -d '' f; do
    total=$((total + 1))
    [[ -e "$root/$branch/$f" || -L "$root/$branch/$f" ]] || missing=$((missing + 1))
  done <"$manifest"
  local tracked_summary untracked_summary
  if [[ "$tracked_dirty" -eq 0 ]]; then tracked_summary="tracked-clean"
  else tracked_summary="$tracked_dirty tracked paths differ"; fi
  if [[ "$missing" -eq 0 ]]; then untracked_summary="all $total untracked arrived"
  else untracked_summary="$missing of $total untracked missing"; fi
  printf 'VERIFY:\t%s\t%s\n' "$tracked_summary" "$untracked_summary"
}

# check/convert run against a conventional main checkout; resolve its root
# and default branch, refusing every layout the recipe does not cover.
resolve_checkout() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  # An empty result can mean old git, not no-git: --path-format needs
  # git >= 2.31, and misreporting that as NOT_GIT sends users chasing the
  # wrong problem.
  if [[ -z "$common_dir" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fi
  if [[ -z "$common_dir" ]]; then
    fail NOT_GIT "not inside a git repository"
  fi
  local is_bare git_dir
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" == "true" ]]; then
    fail ALREADY_CONVERTED "already a bare repository — nothing to convert"
  fi
  git_dir="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  if [[ "$git_dir" != "$common_dir" ]]; then
    fail LINKED_WORKTREE "this is a linked worktree — run from the main checkout"
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$root" || ! -d "$root/.git" || ! "$root/.git" -ef "$common_dir" ]]; then
    fail NOT_CONVENTIONAL "the checkout root's .git is not the repository directory — a layout this recipe does not cover"
  fi
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    fail DETACHED_HEAD "HEAD names no branch — check out the default branch first"
  fi
  # A namespaced branch (feature/foo) would nest the worktree under a
  # top-level directory that cleanup's keep-list does not protect — cleanup
  # would delete the worktree, moved untracked files included. Refuse before
  # any mutation; the target layout wants a single-segment default branch.
  if [[ "$branch" == */* ]]; then
    fail BRANCH_UNSAFE "branch '$branch' contains '/' — the <repo-root>/<branch> worktree layout needs a single path segment; check out (or rename to) a single-segment default branch before converting"
  fi
}

# The untracked manifest, NUL-separated: everything git does not track,
# ignored files included (the .envs and caches a fresh checkout would lose).
# .orca/ is excluded — it stays at the top level in the target layout.
untracked_manifest() {
  git -C "$root" ls-files --others -z | while IFS= read -r -d '' f; do
    [[ "$f" == .orca/* ]] && continue
    printf '%s\0' "$f"
  done
}

# Emit the gate lines; return nonzero when any gate failed.
run_gates() {
  local bad=0 dirty wt_count untracked
  dirty="$(git -C "$root" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  if [[ "$dirty" -eq 0 ]]; then
    printf 'CLEAN:\tPASS\n'
  else
    printf 'CLEAN:\tFAIL\t%s staged or modified paths — commit or stash first\n' "$dirty"
    bad=1
  fi
  wt_count="$(git -C "$root" worktree list --porcelain | grep -c '^worktree ' || true)"
  if [[ "$wt_count" -le 1 ]]; then
    printf 'NO_WORKTREES:\tPASS\n'
  else
    printf 'NO_WORKTREES:\tFAIL\t%s linked worktrees exist — remove them first (git worktree list)\n' "$((wt_count - 1))"
    bad=1
  fi
  if [[ -e "$root/.gitmodules" ]]; then
    printf 'NO_SUBMODULES:\tFAIL\t.gitmodules present — submodules and worktrees interact badly; this repo needs a manual plan\n'
    bad=1
  else
    printf 'NO_SUBMODULES:\tPASS\n'
  fi
  printf 'BRANCH:\t%s\n' "$branch"
  untracked="$(untracked_manifest | tr -dc '\0' | wc -c | tr -d ' ')"
  printf 'UNTRACKED_COUNT:\t%s\n' "$untracked"
  return "$bad"
}

cmd_check() {
  resolve_checkout
  run_gates
  exit "$?"
}

cmd_convert() {
  resolve_checkout
  if ! run_gates; then
    fail PRECONDITION "a gate failed — clear it and re-run (nothing was changed)"
  fi

  # The manifest is captured while .git still exists, into scratch first so
  # it can never list itself.
  local tmp_manifest
  tmp_manifest="$(mktemp)" || fail CONVERT_FAILED "mktemp failed (nothing was changed)"
  untracked_manifest >"$tmp_manifest"

  if [[ -e "$root/.bare" ]]; then
    rm -f "$tmp_manifest"
    fail CONVERT_FAILED ".bare already exists at $root — refusing (nothing was changed)"
  fi
  # The worktree target must not pre-exist (an untracked file or directory
  # named like the branch): worktree add would fail mid-conversion, and the
  # advertised rollback's rm -rf ./<branch> must only ever remove what this
  # run created.
  if [[ -e "$root/$branch" ]]; then
    rm -f "$tmp_manifest"
    fail CONVERT_FAILED "$root/$branch already exists — move it aside first (nothing was changed)"
  fi
  # Manifest and journal both live under .orca (kept at the top level) so
  # they survive any crash from here on. Journal first: begin marks the
  # point of no return, each structural step is journaled before it runs,
  # and the traps turn a signal into a typed FAIL pointing at recover.
  mkdir -p "$root/.orca"
  local manifest="$root/.orca/init-convert-manifest"
  mv "$tmp_manifest" "$manifest" \
    || { rm -f "$tmp_manifest"; fail CONVERT_FAILED "could not persist the manifest (nothing was changed)"; }
  rm -f "$(journal_path)"
  install_traps
  journal_append begin "$branch"

  # One rollback sequence, safe at every failure point after the first mv:
  # the worktree removal and pointer-file rm are no-ops (-rf/-f) where those
  # steps had not happened yet, and .git must be gone before .bare can move
  # back. Runs before the untracked moves, so rm -rf of the fresh worktree
  # deletes only checked-out tracked files.
  local revert
  revert="reversible: cd $(printf '%q' "$root") && rm -rf ./$(printf '%q' "$branch") && rm -f .git && mv .bare .git && git config core.bare false && git worktree prune"
  journal_append step mv-git-bare
  mv "$root/.git" "$root/.bare" \
    || { rm -f "$manifest" "$(journal_path)"; fail CONVERT_FAILED "mv .git .bare failed (nothing was changed)"; }
  journal_append step core-bare
  git --git-dir="$root/.bare" config core.bare true \
    || fail CONVERT_FAILED "core.bare write failed — $revert"
  journal_append step pointer-file
  printf 'gitdir: ./.bare\n' >"$root/.git" \
    || fail CONVERT_FAILED "writing the .git pointer file failed — $revert"
  journal_append step worktree-add
  git -C "$root" worktree add "$root/$branch" "$branch" >/dev/null 2>&1 \
    || fail CONVERT_FAILED "worktree add failed — $revert"

  # The data-loss step, NUL-safe: every untracked file into the worktree,
  # relative paths preserved. Parent dirs via ${dest%/*}, not dirname — a
  # command substitution would strip trailing newlines from a parent path.
  # Each move is journaled intent-then-done so recover knows where a crash
  # landed.
  move_manifest_entries
  printf 'MOVED:\t%s\n' "$moved_count"

  verify_conversion
  trap - INT TERM HUP
  rm -f "$(journal_path)"
  exit 0
}

cmd_recover() {
  # A crash can land anywhere — including between mv .git .bare and the
  # pointer-file write, where git cannot even see a repository — so recover
  # trusts the journal plus the filesystem, not git. Run from the root.
  root="$(pwd -P)"
  if [[ ! -f "$(journal_path)" ]]; then
    fail NO_JOURNAL "no .orca/init-convert-journal here — nothing to recover (run from the repository root)"
  fi
  # branch comes from the journal's begin record — HEAD may be unreadable.
  local verb detail
  branch=""
  while IFS= read -r -d '' verb && IFS= read -r -d '' detail; do
    [[ "$verb" == begin ]] && branch="$detail"
  done <"$(journal_path)"
  if [[ -z "$branch" ]]; then
    fail CONVERT_FAILED "journal has no begin record — refusing to guess; inspect $(journal_path) by hand"
  fi

  if [[ -d "$root/.git" && ! -e "$root/.bare" ]]; then
    # Crashed before the first mv: nothing structural happened.
    rm -f "$(journal_path)"
    printf 'MOVED:\t0\n'
    printf 'VERIFY:\tnothing to recover — conversion had not started\t-\n'
    exit 0
  fi
  if [[ ! -d "$root/.bare" ]]; then
    fail CONVERT_FAILED "neither .git nor .bare is a directory at $root — inspect by hand"
  fi

  install_traps
  # Roll forward, each step idempotent in journal order.
  git --git-dir="$root/.bare" config core.bare true \
    || fail CONVERT_FAILED "core.bare write failed"
  if [[ ! -e "$root/.git" ]]; then
    printf 'gitdir: ./.bare\n' >"$root/.git" \
      || fail CONVERT_FAILED "writing the .git pointer file failed"
  fi
  git -C "$root" worktree prune >/dev/null 2>&1
  if [[ ! -d "$root/$branch" ]]; then
    git -C "$root" worktree add "$root/$branch" "$branch" >/dev/null 2>&1 \
      || fail CONVERT_FAILED "worktree add failed for $root/$branch"
  fi

  local manifest="$root/.orca/init-convert-manifest"
  if [[ ! -f "$manifest" ]]; then
    fail NO_MANIFEST "journal exists but $manifest does not — inspect by hand"
  fi
  move_manifest_entries
  printf 'MOVED:\t%s\n' "$moved_count"

  verify_conversion
  trap - INT TERM HUP
  rm -f "$(journal_path)"
  exit 0
}

cmd_cleanup() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  # Same old-git distinction as resolve_checkout.
  if [[ -z "$common_dir" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fi
  if [[ -z "$common_dir" ]]; then
    fail NOT_GIT "not inside a git repository"
  fi
  local is_bare
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" != "true" || "$(basename "$common_dir")" != ".bare" ]]; then
    fail NOT_CONVERTED "not the converted bare layout — run convert first"
  fi
  root="$(dirname "$common_dir")"
  branch="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    fail NOT_CONVERTED "the bare repo's HEAD names no branch"
  fi
  # The keep-list below matches top-level entry names; a namespaced branch's
  # worktree lives one level down and would be deleted with its parent.
  # convert refuses such branches, so hitting this means a hand-built layout.
  if [[ "$branch" == */* ]]; then
    fail BRANCH_UNSAFE "branch '$branch' contains '/' — cleanup's keep-list cannot protect a nested worktree; clean up by hand"
  fi
  local wt="$root/$branch"
  if [[ ! -d "$wt" ]]; then
    fail NO_WORKTREE "$wt does not exist — refusing to delete anything"
  fi
  local manifest="$root/.orca/init-convert-manifest"
  if [[ ! -f "$manifest" ]]; then
    fail NO_MANIFEST "no $manifest — convert has not run here, or cleanup already finished"
  fi

  # Reconcile before deleting: every moved file must be present in the
  # worktree, or nothing is removed.
  local f missing=0 total=0
  while IFS= read -r -d '' f; do
    total=$((total + 1))
    [[ -e "$wt/$f" || -L "$wt/$f" ]] || missing=$((missing + 1))
  done <"$manifest"
  if [[ "$missing" -gt 0 ]]; then
    fail MANIFEST_MISMATCH "$missing of $total moved files not found in $wt — refusing to delete"
  fi

  # Deletable means provably ours: a top-level name of tracked content at
  # HEAD (the old checkout the worktree now owns) or the top-level parent of
  # a manifest entry (emptied of its moved untracked files). Anything else —
  # an orca-<slug> worktree, a stray file created after convert — is refused
  # by name, and nothing is deleted.
  local f
  declare -A allowed=()
  while IFS= read -r -d '' f; do
    allowed["$f"]=1
  done < <(git --git-dir="$common_dir" ls-tree --name-only -z HEAD)
  while IFS= read -r -d '' f; do
    allowed["${f%%/*}"]=1
  done <"$manifest"

  # Registered worktrees are never deletable, whatever the sets say.
  local wt_line
  declare -A worktrees=()
  while IFS= read -r wt_line; do
    [[ "$wt_line" == worktree\ * ]] || continue
    worktrees["${wt_line#worktree }"]=1
  done < <(git --git-dir="$common_dir" worktree list --porcelain)

  local entry name removed=0 refused=""
  shopt -s dotglob nullglob
  for entry in "$root"/*; do
    name="${entry##*/}"
    case "$name" in .bare | .git | .orca | "$branch") continue ;; esac
    if [[ -n "${worktrees[$entry]:-}" || -z "${allowed[$name]:-}" ]]; then
      refused="${refused:+$refused, }$entry"
    fi
  done
  if [[ -n "$refused" ]]; then
    shopt -u dotglob nullglob
    fail PRECONDITION "unrecognized top-level entries (not manifest-covered, not tracked content, or a registered worktree) — move them aside and re-run; nothing was deleted: $refused"
  fi
  for entry in "$root"/*; do
    name="${entry##*/}"
    case "$name" in .bare | .git | .orca | "$branch") continue ;; esac
    rm -rf "$entry" || fail CONVERT_FAILED "could not remove $entry"
    printf 'REMOVED:\t%s\n' "$entry"
    removed=$((removed + 1))
  done
  shopt -u dotglob nullglob
  rm -f "$manifest"
  printf 'CLEANED:\t%s\n' "$removed"
  exit 0
}

case "${1:-}" in
  check)   cmd_check ;;
  convert) cmd_convert ;;
  cleanup) cmd_cleanup ;;
  recover) cmd_recover ;;
  *)       fail BAD_ARGS "usage: init-convert.sh check | convert | cleanup | recover" ;;
esac
