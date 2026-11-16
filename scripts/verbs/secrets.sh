# shellcheck shell=bash
#
# orca secrets — the sole writer of the placement symlinks that carry
# <repo-root>/.orca/secrets/ into worktrees. `git worktree add` materializes
# tracked files only, and secrets are by definition untracked, so every
# worktree orca creates is born without its `.env`s; the loops and skills
# invoke this script directly after every `worktree add`, and never
# hand-roll the symlinks themselves.
#
# The tree is the mapping — no manifest, no config: a file's path inside
# .orca/secrets/ IS its destination path inside the worktree
# (.orca/secrets/apps/api/.env → <worktree>/apps/api/.env). Each placement
# is one RELATIVE symlink, depth computed per destination, so links survive
# the repo root moving — worktrees and .orca/ move together.
#
# An entry is either the file itself or a symlink to a regular file —
# typically the user's real copy in the default worktree
# (.orca/secrets/.env → ../../main/.env), so runs follow the file the user
# actually edits instead of a second copy that drifts. Placement links
# point at the ENTRY, never past it, so a tool replacing the user's file
# (write-then-rename) keeps every worktree current. In the worktree that
# is an entry's own source, placement reports SOURCE and writes nothing.
#
# Usage:
#   orca.sh secrets place <worktree>
#   orca.sh secrets remove <worktree>
#   orca.sh secrets status [<dir>]
#
# remove is place's inverse, for least-privilege staging: the loop strips
# placement links from a worktree before stages that consume adversarial
# content and need no credentials (the independent review), and re-places
# them for stages that do (implement, fix, integrate). Only
# links passing the resolved-target ownership test are touched. Emits one
# UNPLACED:<TAB><relpath> per removed link and a final
# UNPLACED_TOTAL:<TAB><n>; exits 0 even when nothing was removed.
#
# Output contract — one typed TAB-separated line per fact:
#
#   place (idempotent; a re-run over a placed worktree is all OK lines):
#     OK:<TAB>no secrets            no .orca/secrets/ (or nothing in it) — clean no-op
#     LINKED:<TAB><relpath>         new relative symlink created
#     RELINKED:<TAB><relpath>       our symlink was broken or wrong-depth — replaced
#     OK:<TAB><relpath>             already the expected link
#     UNIGNORED:<TAB><relpath>      git would track this path — never placed
#     SKIPPED_EXISTS:<TAB><relpath> a real file (or a foreign symlink) is there — never overwritten
#     SOURCE:<TAB><relpath>         this worktree holds the file the entry links to — nothing to place
#     SKIPPED_IRREGULAR:<TAB><relpath>  an entry that is not a regular file, nor a link to one (socket, link to a directory)
#     SKIPPED_DANGLING:<TAB><relpath>   an entry linking to a file that is gone (or a link loop) — never
#                                   placed, and our link for it in this worktree is removed
#     SKIPPED_GONE:<TAB><relpath>   dangling link whose canonical file is gone — removed
#     SKIPPED_ERROR:<TAB><relpath>  the link could not be written (filesystem error)
#     PLACED:<TAB><n><TAB>SKIPPED:<TAB><m>    summary — n destinations correctly linked, m skipped
#
#   status (read-only; <dir> defaults to the working directory — any path
#   inside the repository, the bare layout's root included). Doctor's view
#   of the store against the default worktree, where the user's real files
#   live; it prescribes, the user links:
#     DEFAULT_WORKTREE:<TAB><path>|-        where the bare HEAD's default branch is checked
#                                           out (a conventional checkout: its root); - when none
#     ENTRY:<TAB><relpath><TAB>FILE         the store holds its own copy
#     ENTRY:<TAB><relpath><TAB>LINK<TAB><target>      a link to a regular file (target as written)
#     ENTRY:<TAB><relpath><TAB>DANGLING<TAB><target>  a link whose file is gone — placement skips it
#     ENTRY:<TAB><relpath><TAB>IRREGULAR    anything else — placement skips it
#     COPY:<TAB><relpath><TAB>SAME|DIFFERS<TAB><link-target>
#                                           a FILE entry the default worktree also holds as a
#                                           real file: two copies, DIFFERS once they have drifted
#     UNLINKED:<TAB><relpath><TAB><link-target>
#                                           an ignored env file (.env, .env.*, .envrc) in the
#                                           default worktree with no store entry
#     ENTRIES:<TAB><n><TAB>COPIES:<TAB><c><TAB>UNLINKED:<TAB><m>   summary
#   <link-target> is what `ln -s <link-target> .orca/secrets/<relpath>`
#   needs to link that entry to the default worktree's file — relative when
#   the worktree sits under the repo root. Ignored directories (node_modules)
#   are not descended into, so an env file inside one is never offered.
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: BAD_ARGS NOT_GIT OLD_GIT OUTSIDE_ROOT
#
# Ownership is by target, never substring: a symlink is ours to manage
# (repair, replace, or sweep) only when it points at this repository's
# .orca/secrets tree at the same relative destination — judged one hop
# (the link's own target, canonical up to its last component, so a
# placement whose entry is itself a link is still ours) or fully resolved
# (a placement reached through some other link). A link into another
# repo's .orca/secrets, a backup.orca/secrets/x path, or any other
# look-alike is state — skipped in the walk, left alone by the sweep.
#
# Per-file problems are typed skips on a zero exit — placement is best
# effort and must never fail the caller's compound command; only misuse
# (bad args, not a worktree) exits 1. The UNIGNORED gate is the safety
# property: a path `git check-ignore` does not report ignored (tracked
# paths included — check-ignore consults the index) is a path a commit
# could pick up, so it never receives a secret.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh (fail()
# and the symlink canonicalizer) is already loaded.

secrets_usage="usage: secrets.sh place|remove <worktree> | status [<dir>]"
mode="${1:-}"
case "$mode" in
  place|remove) [[ $# -eq 2 ]] || fail BAD_ARGS "$secrets_usage" ;;
  status) [[ $# -le 2 ]] || fail BAD_ARGS "$secrets_usage" ;;
  *) fail BAD_ARGS "$secrets_usage" ;;
esac
probe="${2:-.}"
[[ -d "$probe" ]] || fail BAD_ARGS "not a directory: $probe"

if [[ "$mode" == "status" ]]; then
  # status reads the store, not a worktree: any directory in the repo
  # will do, the bare layout's root included.
  worktree=""
else
  # Normalize to the worktree's top level (a subdirectory argument would
  # mis-root every destination) — this also rejects the bare layout's repo
  # root, whose .git pointer resolves to the bare repo, not a working tree.
  worktree="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$worktree" ]] || fail NOT_GIT "$probe is not inside a git working tree"
  probe="$worktree"
fi

# The repo root — the directory that holds .orca/ — is the parent of the
# git common dir in both layouts (bare-with-worktrees and conventional).
common_dir="$(git -C "$probe" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
# An empty result can mean old git, not no-git: --path-format needs
# git >= 2.31, and misreporting that as NOT_GIT sends users chasing the
# wrong problem.
if [[ -z "$common_dir" ]] && git -C "$probe" rev-parse --git-dir >/dev/null 2>&1; then
  fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
fi
[[ -n "$common_dir" ]] || fail NOT_GIT "$probe is not inside a git repository"
repo_root="$(dirname "$common_dir")"
secrets_dir="$repo_root/.orca/secrets"

# Conventional checkout only (the bare layout's .orca/ sits outside every
# worktree): make sure the per-clone ignore file excludes .orca/ before any
# placement, so a checkout that never ran `orca:config set` still cannot
# `git add -A` its .orca/secrets tree. Mirrors the config verb's ensure_exclude —
# the two must stay behaviorally identical. Idempotent, best-effort.
is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
ensure_exclude() {
  [[ "$is_bare" == "true" ]] && return 0
  [[ -e "$repo_root/.orca" ]] || return 0
  local exclude="$common_dir/info/exclude"
  mkdir -p "$common_dir/info" 2>/dev/null || return 0
  grep -qxF '.orca/' "$exclude" 2>/dev/null || printf '.orca/\n' >>"$exclude" 2>/dev/null || true
}
[[ "$mode" == "status" ]] || ensure_exclude

# Canonical target of a symlink, existence NOT required (dangling links
# must still resolve so the sweep can judge them). The lib's pure-bash
# canonicalizer resolves the link path itself — its final component is
# the symlink, so full resolution lands on the canonical target.
resolve_link() { # <link-path> — canonical absolute target on stdout
  canonicalize "$1"
}
# One hop: where the link itself points, canonical up to — not through —
# its last component. A placement whose entry is itself a link resolves
# fully into the default worktree; one hop still lands on the entry.
link_hop() { # <link-path> — canonical absolute one-hop target on stdout
  local t
  t="$(readlink "$1")" || return 1
  case "$t" in
    /*) ;;
    *) t="$(dirname "$1")/$t" ;;
  esac
  printf '%s/%s\n' "$(canonicalize "$(dirname "$t")")" "$(basename "$t")"
}
# The canonical secrets root — the right-hand side of every ownership test.
secrets_canon="$(canonicalize "$secrets_dir")"
owned() { # <link-path> <relpath> — the link is a placement of this entry
  local want="$secrets_canon/$2" got
  got="$(link_hop "$1" 2>/dev/null || true)"
  [[ "$got" == "$want" ]] && return 0
  got="$(resolve_link "$1" 2>/dev/null || true)"
  [[ "$got" == "$want" ]]
}

# Escape glob metacharacters so a repo path containing [ ] * ? \ cannot
# corrupt find -path patterns.
escape_glob() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# Component count of a relative path ("" → 0, "a/b/c" → 3).
depth_of() {
  local p="$1"
  [[ -z "$p" ]] && { echo 0; return; }
  local slashes="${p//[^\/]/}"
  echo $(( ${#slashes} + 1 ))
}

# ---- status: the store against the default worktree (read-only) ----
if [[ "$mode" == "status" ]]; then
  # The default worktree: a conventional checkout is its own; in the bare
  # layout, wherever the bare HEAD's branch is checked out (init-link's
  # resolution). A user who checked out another branch there gets `-`.
  dwt=""
  if [[ "$is_bare" == "true" ]]; then
    dbranch="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
    cur=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) cur="${line#worktree }" ;;
        "branch refs/heads/$dbranch") [[ -n "$dbranch" ]] && dwt="$cur" ;;
      esac
    done < <(git --git-dir="$common_dir" worktree list --porcelain 2>/dev/null)
  else
    dwt="$repo_root"
  fi
  printf 'DEFAULT_WORKTREE:\t%s\n' "${dwt:--}"

  # The ln -s target linking .orca/secrets/<rel> to <dwt>/<rel>: relative
  # when the default worktree sits under the repo root, absolute otherwise.
  root_canon="$(canonicalize "$repo_root")"
  dwt_canon=""
  [[ -n "$dwt" ]] && dwt_canon="$(canonicalize "$dwt")"
  link_target() { # <relpath>
    local rel="$1" ups="" i
    if [[ "$dwt_canon" == "$root_canon" || "$dwt_canon" == "$root_canon"/* ]]; then
      local dwt_rel="${dwt_canon#"$root_canon"}"
      dwt_rel="${dwt_rel#/}"
      for (( i = $(depth_of "$rel") + 1; i > 0; i-- )); do ups+="../"; done
      printf '%s%s\n' "$ups" "${dwt_rel:+$dwt_rel/}$rel"
    else
      printf '%s/%s\n' "$dwt" "$rel"
    fi
  }

  entries=0 copies=0 unlinked=0
  if [[ -d "$secrets_dir" ]]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$secrets_dir"/}"
      entries=$((entries + 1))
      if [[ -L "$src" ]]; then
        if [[ ! -e "$src" ]]; then
          printf 'ENTRY:\t%s\tDANGLING\t%s\n' "$rel" "$(readlink "$src")"
        elif [[ -f "$src" ]]; then
          printf 'ENTRY:\t%s\tLINK\t%s\n' "$rel" "$(readlink "$src")"
        else
          printf 'ENTRY:\t%s\tIRREGULAR\n' "$rel"
        fi
      elif [[ -f "$src" ]]; then
        printf 'ENTRY:\t%s\tFILE\n' "$rel"
        if [[ -n "$dwt" && -f "$dwt/$rel" && ! -L "$dwt/$rel" ]]; then
          if cmp -s "$src" "$dwt/$rel"; then same=SAME; else same=DIFFERS; fi
          printf 'COPY:\t%s\t%s\t%s\n' "$rel" "$same" "$(link_target "$rel")"
          copies=$((copies + 1))
        fi
      else
        printf 'ENTRY:\t%s\tIRREGULAR\n' "$rel"
      fi
    done < <(find "$secrets_dir" -mindepth 1 ! -type d -print0 | LC_ALL=C sort -z)
  fi

  # Candidates: ignored, untracked env files in the default worktree with
  # no entry. --directory lists an ignored directory once instead of
  # descending (node_modules); directory rows end in / and are skipped.
  if [[ -n "$dwt" && -d "$dwt" ]]; then
    while IFS= read -r -d '' rel; do
      case "$rel" in */) continue ;; esac
      base="${rel##*/}"
      case "$base" in
        *.example|*.sample|*.template) continue ;;
        .env|.env.*|.envrc) ;;
        *) continue ;;
      esac
      [[ -f "$dwt/$rel" && ! -L "$dwt/$rel" ]] || continue
      [[ -e "$secrets_dir/$rel" || -L "$secrets_dir/$rel" ]] && continue
      printf 'UNLINKED:\t%s\t%s\n' "$rel" "$(link_target "$rel")"
      unlinked=$((unlinked + 1))
    done < <(git -C "$dwt" ls-files -z --others --ignored --exclude-standard --directory 2>/dev/null | LC_ALL=C sort -z)
  fi
  printf 'ENTRIES:\t%d\tCOPIES:\t%d\tUNLINKED:\t%d\n' "$entries" "$copies" "$unlinked"
  exit 0
fi

# Relative links are computed from the worktree's position under the repo
# root; a worktree elsewhere on disk has no stable relative path to .orca/.
if [[ "$worktree" == "$repo_root" ]]; then
  wt_rel=""
elif [[ "$worktree" == "$repo_root"/* ]]; then
  wt_rel="${worktree#"$repo_root"/}"
else
  fail OUTSIDE_ROOT "$worktree is not under the repo root $repo_root — relative links cannot be computed"
fi
wt_depth="$(depth_of "$wt_rel")"

# ---- remove: strip our placement links (ownership by resolved target) ----
if [[ "$mode" == "remove" ]]; then
  removed=0
  if [[ -d "$secrets_dir" ]]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$secrets_dir"/}"
      dest="$worktree/$rel"
      [[ -L "$dest" ]] || continue
      owned "$dest" "$rel" || continue
      rm -f "$dest" 2>/dev/null || continue
      printf 'UNPLACED:\t%s\n' "$rel"
      removed=$((removed + 1))
    done < <(find "$secrets_dir" -mindepth 1 ! -type d -print0 | LC_ALL=C sort -z)
  fi
  # Owned links whose source was deleted since placement dangle and would
  # escape the walk above — the sweep's ownership test catches them.
  wt_glob="$(escape_glob "$worktree")"
  while IFS= read -r -d '' lnk; do
    [[ -e "$lnk" ]] && continue
    rel="${lnk#"$worktree"/}"
    owned "$lnk" "$rel" || continue
    rm -f "$lnk" 2>/dev/null || continue
    printf 'UNPLACED:\t%s\n' "$rel"
    removed=$((removed + 1))
  done < <(find "$worktree" \( -name .git -o -path "$wt_glob/.orca" \) -prune -o -type l -print0 2>/dev/null | LC_ALL=C sort -z)
  printf 'UNPLACED_TOTAL:\t%d\n' "$removed"
  exit 0
fi

placed=0 skipped=0

# ---- walk the secrets tree: one relative symlink per entry ----
if [[ -d "$secrets_dir" ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#"$secrets_dir"/}"

    # Directories are traversed by find itself (never followed through a
    # link). An entry is a regular file or a link to one; anything else
    # (a socket, a link to a directory) is skipped.
    if [[ -L "$src" && ! -e "$src" ]]; then
      # The file the entry links to is gone, or the link loops (a worktree
      # copy linked back at the store). Never placed — and a placement of
      # it here would dangle, so it goes now rather than in the sweep.
      [[ -L "$worktree/$rel" ]] && owned "$worktree/$rel" "$rel" && rm -f "$worktree/$rel" 2>/dev/null
      printf 'SKIPPED_DANGLING:\t%s\n' "$rel"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ ! -f "$src" ]]; then
      printf 'SKIPPED_IRREGULAR:\t%s\n' "$rel"
      skipped=$((skipped + 1))
      continue
    fi
    # This worktree holds the very file the entry links to (the default
    # worktree, for an entry linking there): the source, not a destination.
    if [[ -L "$src" && "$(canonicalize "$src")" == "$(canonicalize "$(dirname "$worktree/$rel")")/${rel##*/}" ]]; then
      printf 'SOURCE:\t%s\n' "$rel"
      placed=$((placed + 1))
      continue
    fi

    # The gate: a destination git would track must never hold a secret.
    # check-ignore consults the index, so a tracked path fails it too.
    if ! git -C "$worktree" check-ignore -q -- "$rel" 2>/dev/null; then
      printf 'UNIGNORED:\t%s\n' "$rel"
      skipped=$((skipped + 1))
      continue
    fi

    dest="$worktree/$rel"
    ups=""
    for (( i = wt_depth + $(depth_of "$rel") - 1; i > 0; i-- )); do ups+="../"; done
    target="${ups}.orca/secrets/$rel"

    if [[ -L "$dest" ]]; then
      cur="$(readlink "$dest" || true)"
      if owned "$dest" "$rel"; then
        # Ours (points at this repo's secrets entry for this destination):
        # normalize a non-canonical spelling (absolute path, redundant
        # components); an already correct one is the idempotent re-run's OK.
        if [[ "$cur" == "$target" ]]; then
          printf 'OK:\t%s\n' "$rel"
          placed=$((placed + 1))
        elif rm -f "$dest" 2>/dev/null && ln -s "$target" "$dest" 2>/dev/null; then
          printf 'RELINKED:\t%s\n' "$rel"
          placed=$((placed + 1))
        else
          printf 'SKIPPED_ERROR:\t%s\n' "$rel"
          skipped=$((skipped + 1))
        fi
      else
        # A symlink that resolves anywhere else — another repo's secrets, a
        # look-alike path, a wrong destination — is somebody's state,
        # exactly like a real file. Never repaired, never replaced.
        printf 'SKIPPED_EXISTS:\t%s\n' "$rel"
        skipped=$((skipped + 1))
      fi
    elif [[ -e "$dest" ]]; then
      printf 'SKIPPED_EXISTS:\t%s\n' "$rel"
      skipped=$((skipped + 1))
    else
      # A parent holding only ignored files is not tracked, so it may not
      # exist in a fresh worktree.
      if mkdir -p "$(dirname "$dest")" 2>/dev/null && ln -s "$target" "$dest" 2>/dev/null; then
        printf 'LINKED:\t%s\n' "$rel"
        placed=$((placed + 1))
      else
        printf 'SKIPPED_ERROR:\t%s\n' "$rel"
        skipped=$((skipped + 1))
      fi
    fi
  done < <(find "$secrets_dir" -mindepth 1 ! -type d -print0 | LC_ALL=C sort -z)
fi

# ---- sweep: a dangling link whose canonical file is gone is a trap ----
# Runs after the walk, so a broken link whose source still exists was
# already repaired above and resolves here; what remains broken has no
# source to point at — remove it rather than leave a dead .env. Ownership
# is the target test: the dangling link must point at THIS repo's
# secrets tree at its own relative destination, or it is left
# alone (a link into another repo's .orca/secrets, or a backup.orca
# look-alike, is not ours to delete).
wt_glob="$(escape_glob "$worktree")"
while IFS= read -r -d '' lnk; do
  [[ -e "$lnk" ]] && continue
  rel="${lnk#"$worktree"/}"
  owned "$lnk" "$rel" || continue
  rm -f "$lnk" 2>/dev/null || true
  printf 'SKIPPED_GONE:\t%s\n' "$rel"
  skipped=$((skipped + 1))
done < <(find "$worktree" \( -name .git -o -path "$wt_glob/.orca" \) -prune -o -type l -print0 2>/dev/null | LC_ALL=C sort -z)

if (( placed == 0 && skipped == 0 )); then
  printf 'OK:\tno secrets\n'
  exit 0
fi
printf 'PLACED:\t%d\tSKIPPED:\t%d\n' "$placed" "$skipped"
exit 0
