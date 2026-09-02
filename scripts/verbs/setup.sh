# shellcheck shell=bash disable=SC2154
#
# orca setup — the sole owner of <repo-root>/.orca/setup, the script that
# provisions a worktree with what `git worktree add` cannot materialize:
# dependencies, codegen, compiled artifacts. Tracked files come from git,
# untracked credentials come from `secrets place`, and everything else
# comes from here.
#
# The artifact is machine-local like the rest of .orca/ — never committed,
# user-authored or user-approved — and it is a SCRIPT, not a config key:
# .orca/config is a closed lowercase-token vocabulary with a validator and
# a canonical writer, and a free-form command has no allowed-values list.
#
# Usage:
#   orca.sh setup run     <worktree> <arrival> [--timeout <s>]
#   orca.sh setup verify  <candidate> [--check <cmd>] [--timeout <s>] [--trunk <ref>]
#   orca.sh setup status  [--trunk <ref>]
#   orca.sh setup install <candidate> --sources <paths> [--verified <text>] [--trunk <ref>]
#
# ---- the script contract (documented for humans in the README) ----------
#
# `.orca/setup` is run as `bash .orca/setup` — never exec'd, so the exec
# bit is irrelevant (preflight's `test -f` reasoning) — with:
#   cwd            the worktree being provisioned
#   stdin          </dev/null, so a package manager that prompts dies
#                  instead of wedging a workflow stage until the MCP
#                  timeout
#   stdout+stderr  captured to a log; only the tail crosses a relay, and
#                  only base64-encoded
#   ORCA_WORKTREE  absolute path of the worktree (= cwd)
#   ORCA_REPO_ROOT the directory holding .orca/ — for scripts that share a
#                  cache or link build outputs across worktrees
#   ORCA_ARRIVAL   created | branch_resumed | reused | integrate
# and a wall-clock cap (SETUP_TIMEOUT below). Verification always runs
# with ORCA_ARRIVAL=created: a script that behaves differently under
# verification proves nothing.
#
# Requirements on the script, enforced by nothing but stated everywhere:
# idempotent and cheap when warm (`npm install`, not `npm ci`), safe with
# eight copies running at once (package managers take their own locks;
# hand-rolled writes to a shared path do not), and no servers, watchers,
# fixed ports, shared-database migrations, or interactive prompts.
#
# ---- the safety envelope ------------------------------------------------
#
# Stock macOS has no timeout(1), so the watchdog is hand-rolled: `set -m`
# gives the child its own process group, a sleeper TERMs the whole group
# at the cap and KILLs it five seconds later, and a sentinel file — not
# the exit status — is what distinguishes a timeout from a script that
# happens to exit 143. The process group is the only portable way to reach
# grandchildren (a pnpm under a make under the script). rc 124 on timeout,
# GNU timeout's convention.
#
# ---- output contract ----------------------------------------------------
#
# One typed TAB-separated line per fact; verify additionally closes with a
# frame. Advisory by design: a failed provisioning must never kill an item
# before its agent runs — the agent may be what fixes the build — so every
# subcommand exits 0 except on misuse.
#
#   run:
#     SETUP:<TAB>absent                      no .orca/setup — clean no-op
#     SETUP:<TAB>unstamped                   no valid provenance header (hand-
#       written, or written past `install`) — emitted BEFORE the outcome
#       line; the script still runs
#     SETUP:<TAB>ok<TAB><seconds>
#     SETUP:<TAB>failed<TAB><rc><TAB><seconds>
#     SETUP:<TAB>timeout<TAB><cap>
#     SETUP_TAIL:<TAB><b64>                  last 4 KB of the captured log,
#       on failure and timeout only
#
#   verify (creates and removes a throwaway worktree under .orca/doctor/):
#     the chained `secrets place` typed lines, then one frame:
#       rc          the candidate's exit status (124 on timeout)
#       check_rc    the --check command's status, or '-' (never run when
#                   the candidate itself failed)
#       seconds     the candidate's wall clock — what the cap is measured
#                   against; the check's time is deliberately not in it
#       tail.b64    last 4 KB of both logs
#       removed     yes | no
#       worktree    the throwaway path, for a `removed=no` follow-up
#     plus REMOVE_FAILED:<TAB><path> when removal did not converge.
#
#   status (read-only, milliseconds, no worktree):
#     SETUP:<TAB>absent | unstamped
#           | current<TAB><fingerprint>
#           | drifted<TAB><recorded-fingerprint>
#       then, on drifted, one CHANGED:<TAB><path> per probed path whose
#       object id or existence moved.
#     SETUP_LINES:<TAB><n>                   body lines, header excluded
#     SETUP_SOURCES:<TAB><text>              the header's derived-from
#     SETUP_VERIFIED:<TAB><text>             the header's verified record
#
#   install:
#     INSTALLED:<TAB><path>
#     SETUP:<TAB>current<TAB><fingerprint>
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>        exit 1
#       reasons: BAD_ARGS NOT_GIT OLD_GIT NO_COMMIT BAD_SCRIPT WRITE_ERROR
#                WORKTREE_FAILED
#
# ---- the fingerprint ----------------------------------------------------
#
# Drift is "the repo's provisioning inputs moved since this script was
# derived", and it is deterministic and lives HERE, not in the agent's
# judgment: `git ls-tree` at the trunk tip over a fixed probe list of the
# well-known manifests, lockfiles, task runners, toolchain pins, and CI
# paths, plus whatever paths the agent named as its sources. Each probe
# the tree HOLDS renders as `path<TAB><object-id>`, the sorted manifest is
# hashed with `git hash-object --stdin` (stock macOS has perl's shasum,
# not sha256sum), and the per-entry values ride the header's `inspected:`
# line so `status` can name exactly which path moved.
#
# The probe list living in the verb — not in the agent's list of what it
# happened to look at — is what makes a package.json appearing six months
# later trip the check regardless of how thorough the agent's list was.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh (fail,
# emit_frame, b64_encode) is already loaded.

# Wall-clock cap for one provisioning, in seconds. Cold numbers for a large
# monorepo (a pnpm install and a go mod download at low single-digit
# minutes each, a devserver build under one) sum to well under five;
# eight worktrees contending for CPU and disk can plausibly triple that.
# Fifteen minutes keeps headroom over a fat cold install while still
# failing a hung one before a review's ~20-minute MCP_TOOL_TIMEOUT would.
# Not per-repo configurable: the config grammar cannot carry a number, and
# a script that needs longer should be moving cold work into a shared
# cache — the doctor's measured `seconds` is what says a repo is near it.
SETUP_TIMEOUT=900

# The well-known provisioning inputs, in a fixed order. Literal paths only
# — a glob would need `ls-tree -r` and could not render an `absent` entry,
# which is what makes "a lockfile appeared" detectable. Nested manifests
# (backend/go.mod) reach the fingerprint through the agent's --sources.
SETUP_PROBES="
package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml pnpm-workspace.yaml yarn.lock bun.lockb
go.mod go.sum
Cargo.toml Cargo.lock
pyproject.toml poetry.lock uv.lock requirements.txt requirements-dev.txt Pipfile.lock
Gemfile Gemfile.lock
composer.json composer.lock
pom.xml build.gradle build.gradle.kts gradle/libs.versions.toml
mix.exs mix.lock
Makefile makefile GNUmakefile justfile Justfile Taskfile.yml Taskfile.yaml
.tool-versions mise.toml .mise.toml flake.nix flake.lock shell.nix default.nix
.nvmrc .python-version .ruby-version
.devcontainer/devcontainer.json
.github/workflows
"

setup_mode="${1:-}"
[ $# -gt 0 ] && shift

# ---- shared resolution --------------------------------------------------

# setup_resolve <git-context-dir> — sets common_dir, repo_root, setup_file.
# The context is the worktree for `run` (the most robust anchor available
# there) and the working directory for the rest, matching preflight.
setup_resolve() {
  local ctx="$1"
  common_dir="$(git -C "$ctx" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$common_dir" ] && git -C "$ctx" rev-parse --git-dir >/dev/null 2>&1; then
    fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fi
  [ -n "$common_dir" ] || fail NOT_GIT "$ctx is not inside a git repository"
  repo_root="$(dirname "$common_dir")"
  setup_file="$repo_root/.orca/setup"
}

# setup_trunk [<override>] — the rev the fingerprint and the verification
# worktree are taken at: the caller's --trunk when given, else the branch
# the repository's HEAD names (the bare layout's default branch), else
# HEAD itself. Empty when the repository has no commit yet.
setup_trunk() {
  local want="$1" head
  if [ -n "$want" ]; then
    git --git-dir="$common_dir" rev-parse -q --verify "$want^{commit}" >/dev/null 2>&1 \
      || fail BAD_ARGS "--trunk $want does not name a commit in this repository"
    printf '%s' "$want"
    return 0
  fi
  head="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ -n "$head" ] && git --git-dir="$common_dir" rev-parse -q --verify "refs/heads/$head" >/dev/null 2>&1; then
    printf '%s' "$head"
    return 0
  fi
  git --git-dir="$common_dir" rev-parse -q --verify HEAD >/dev/null 2>&1 && printf 'HEAD'
}

# ---- the fingerprint ----------------------------------------------------

# setup_manifest <rev> <extra-paths> — the sorted `path<TAB><object-id>`
# manifest on stdout: one line per probe the tree actually holds, and
# nothing for the ones it does not. An empty rev (a repository with no
# commit) yields an empty manifest.
#
# Recording only what exists is what makes the check both complete and
# upgrade-proof: a lockfile that APPEARS adds a line, one that vanishes
# drops a line, one that changes moves its object id — all three move the
# fingerprint — while a probe a newer plugin adds and the repo does not
# have contributes nothing, so a plugin upgrade never fakes drift.
setup_manifest() {
  local rev="$1" extra="$2" probes
  # Probe paths carry no whitespace by construction (the list above) and
  # --sources rejects it, so the unquoted expansion into ls-tree is safe.
  probes="$(printf '%s\n%s\n' "$SETUP_PROBES" "$extra" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u)"
  [ -n "$rev" ] || return 0
  # One ls-tree over every probe: an absent pathspec is a silent no-op,
  # and a directory probe (.github/workflows) renders as its tree object,
  # so any change under it moves the fingerprint.
  # shellcheck disable=SC2086
  git --git-dir="$common_dir" ls-tree --full-tree "$rev" -- $probes 2>/dev/null \
    | awk -F'\t' '{ split($1, a, " "); print $2 "\t" a[3] }' | LC_ALL=C sort
}

setup_fingerprint() { # stdin: the manifest — the hash on stdout
  git hash-object --stdin
}

# ---- the provenance header ----------------------------------------------

setup_header_field() { # <file> <field> — the value, empty when absent
  sed -n '1,40p' "$1" 2>/dev/null | sed -n "s/^# $2: //p" | head -1
}

setup_body_lines() { # <file> — script lines, the leading comment header excluded
  awk 'b { n++; next }
       /^#!/ { next }
       /^#/ { next }
       /^[[:space:]]*$/ { next }
       { b = 1; n = 1 }
       END { print n + 0 }' "$1" 2>/dev/null
}

setup_is_stamped() { # <file>
  local fp insp
  fp="$(setup_header_field "$1" fingerprint)"
  insp="$(sed -n '1,40p' "$1" 2>/dev/null | grep -c '^# inspected: ' || true)"
  [[ "$fp" =~ ^[0-9a-f]{7,}$ ]] && [ "$insp" -ge 1 ]
}

# ---- the safety envelope ------------------------------------------------

# setup_exec <script> <cwd> <arrival> <cap> <log> — run one script under
# the envelope. Sets setup_rc (124 on timeout) and setup_seconds.
setup_exec() {
  local script="$1" cwd="$2" arrival="$3" cap="$4" log="$5"
  local dir flag start child watcher
  dir="$(dirname "$log")"
  flag="$dir/timedout"
  rm -f "$flag"
  start="$(date +%s)"
  # Job control gives the child its own process group; without it the TERM
  # below could not reach a pnpm under a make under the script.
  set -m
  (
    cd "$cwd" || exit 125
    ORCA_WORKTREE="$cwd" ORCA_REPO_ROOT="$repo_root" ORCA_ARRIVAL="$arrival" \
      exec bash "$script"
  ) >"$log" 2>&1 </dev/null &
  child=$!
  # The sentinel, not the exit status, is the timeout's evidence: a script
  # is free to exit 143 on its own.
  ( sleep "$cap" ; : >"$flag" ; kill -TERM -"$child" 2>/dev/null ; \
    sleep 5 ; kill -KILL -"$child" 2>/dev/null ) &
  watcher=$!
  set +m
  wait "$child" 2>/dev/null
  setup_rc=$?
  kill -TERM -"$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  setup_seconds=$(( $(date +%s) - start ))
  if [ -e "$flag" ]; then setup_rc=124; fi
  rm -f "$flag"
}

setup_scratch() { # a private temp dir, removed by the caller
  mktemp -d "${TMPDIR:-/tmp}/orca-setup.XXXXXX" \
    || fail WRITE_ERROR "could not create a scratch directory for the setup log"
}

setup_tail_b64() { # <log...> — last 4 KB of the concatenated logs, base64
  cat "$@" 2>/dev/null | tail -c 4096 | b64_encode
}

# ---- run ----------------------------------------------------------------

if [ "$setup_mode" = "run" ]; then
  [ $# -ge 2 ] || fail BAD_ARGS "usage: orca.sh setup run <worktree> <arrival> [--timeout <s>]"
  run_wt="$1"; run_arrival="$2"; shift 2
  run_cap="$SETUP_TIMEOUT"
  while [ $# -gt 0 ]; do
    case "$1" in
      # For the doctor and the test suite; the loops never pass it — a
      # per-repo cap would be a number the config grammar cannot carry.
      --timeout) [ $# -ge 2 ] || fail BAD_ARGS "--timeout needs a value"; run_cap="$2"; shift 2 ;;
      *) fail BAD_ARGS "unknown argument to setup run: $1" ;;
    esac
  done
  [[ "$run_cap" =~ ^[0-9]+$ ]] && [ "$run_cap" -gt 0 ] || fail BAD_ARGS "--timeout must be a positive integer: $run_cap"
  case "$run_arrival" in
    created|branch_resumed|reused|integrate) ;;
    *) fail BAD_ARGS "unknown arrival '$run_arrival' — one of created, branch_resumed, reused, integrate" ;;
  esac
  [ -d "$run_wt" ] || fail BAD_ARGS "not a directory: $run_wt"
  setup_resolve "$run_wt"
  run_given="$run_wt"
  # Normalize to the top level: a subdirectory argument would run the
  # script with the wrong cwd and hand it the wrong ORCA_WORKTREE.
  run_wt="$(git -C "$run_wt" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$run_wt" ] || fail NOT_GIT "$run_given is not inside a git working tree"

  if [ ! -f "$setup_file" ]; then
    printf 'SETUP:\tabsent\n'
    exit 0
  fi
  setup_is_stamped "$setup_file" || printf 'SETUP:\tunstamped\n'

  run_dir="$(setup_scratch)"
  setup_exec "$setup_file" "$run_wt" "$run_arrival" "$run_cap" "$run_dir/log"
  if [ "$setup_rc" -eq 124 ]; then
    printf 'SETUP:\ttimeout\t%d\n' "$run_cap"
    printf 'SETUP_TAIL:\t%s\n' "$(setup_tail_b64 "$run_dir/log")"
  elif [ "$setup_rc" -eq 0 ]; then
    printf 'SETUP:\tok\t%d\n' "$setup_seconds"
  else
    printf 'SETUP:\tfailed\t%d\t%d\n' "$setup_rc" "$setup_seconds"
    printf 'SETUP_TAIL:\t%s\n' "$(setup_tail_b64 "$run_dir/log")"
  fi
  rm -rf "$run_dir"
  exit 0
fi

# ---- verify -------------------------------------------------------------

if [ "$setup_mode" = "verify" ]; then
  [ $# -ge 1 ] || fail BAD_ARGS "usage: orca.sh setup verify <candidate> [--check <cmd>] [--timeout <s>] [--trunk <ref>]"
  ver_cand="$1"; shift
  ver_check=""; ver_cap="$SETUP_TIMEOUT"; ver_trunk=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)   [ $# -ge 2 ] || fail BAD_ARGS "--check needs a value";   ver_check="$2"; shift 2 ;;
      --timeout) [ $# -ge 2 ] || fail BAD_ARGS "--timeout needs a value"; ver_cap="$2";   shift 2 ;;
      --trunk)   [ $# -ge 2 ] || fail BAD_ARGS "--trunk needs a value";   ver_trunk="$2"; shift 2 ;;
      *) fail BAD_ARGS "unknown argument to setup verify: $1" ;;
    esac
  done
  [[ "$ver_cap" =~ ^[0-9]+$ ]] && [ "$ver_cap" -gt 0 ] || fail BAD_ARGS "--timeout must be a positive integer: $ver_cap"
  [ -f "$ver_cand" ] || fail BAD_ARGS "candidate is not a file: $ver_cand"
  ver_cand="$(canonicalize "$ver_cand")"
  setup_resolve .
  ver_rev="$(setup_trunk "$ver_trunk")"
  [ -n "$ver_rev" ] || fail NO_COMMIT "the repository has no commit to create a verification worktree at"

  ver_wt="$repo_root/.orca/doctor/verify-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$repo_root/.orca/doctor" 2>/dev/null \
    || fail WRITE_ERROR "could not create $repo_root/.orca/doctor"
  ver_scratch="$(setup_scratch)"
  git --git-dir="$common_dir" -C "$repo_root" worktree add --detach "$ver_wt" "$ver_rev" \
    >"$ver_scratch/add.log" 2>&1 \
    || { ver_detail="$(tr '\n' ' ' <"$ver_scratch/add.log" | tail -c 300)"; rm -rf "$ver_scratch"
         fail WORKTREE_FAILED "could not create the verification worktree: $ver_detail"; }

  # A candidate that needs the .npmrc must see it — the same placement a
  # real arrival gets, and the same typed lines, which are also how the
  # doctor learns which untracked files the install expects.
  bash "$orca_scripts_dir/orca.sh" secrets place "$ver_wt" || true

  setup_exec "$ver_cand" "$ver_wt" created "$ver_cap" "$ver_scratch/candidate.log"
  ver_rc="$setup_rc"; ver_seconds="$setup_seconds"
  ver_logs="$ver_scratch/candidate.log"
  ver_check_rc="-"
  if [ -n "$ver_check" ] && [ "$ver_rc" -eq 0 ]; then
    # The check runs under the same envelope; its clock is deliberately
    # kept out of `seconds`, which is what the cap is measured against.
    printf '%s\n' "$ver_check" >"$ver_scratch/check.sh"
    setup_exec "$ver_scratch/check.sh" "$ver_wt" created "$ver_cap" "$ver_scratch/check.log"
    ver_check_rc="$setup_rc"
    ver_logs="$ver_logs $ver_scratch/check.log"
  fi

  # Removal happens on failure too; a removal failure is a typed line and
  # a frame key, never a lost frame.
  git --git-dir="$common_dir" -C "$repo_root" worktree remove --force "$ver_wt" >/dev/null 2>&1 || true
  if [ -e "$ver_wt" ]; then
    rm -rf "$ver_wt" 2>/dev/null || true
    git --git-dir="$common_dir" -C "$repo_root" worktree prune >/dev/null 2>&1 || true
  fi
  if [ -e "$ver_wt" ]; then
    ver_removed=no
    printf 'REMOVE_FAILED:\t%s\n' "$ver_wt"
  else
    ver_removed=yes
  fi

  # shellcheck disable=SC2086
  ver_tail="$(setup_tail_b64 $ver_logs)"
  rm -rf "$ver_scratch"
  emit_frame "rc=$ver_rc" "check_rc=$ver_check_rc" "seconds=$ver_seconds" \
    "removed=$ver_removed" "worktree=$ver_wt" "tail.b64=$ver_tail"
  exit 0
fi

# ---- status -------------------------------------------------------------

if [ "$setup_mode" = "status" ]; then
  st_trunk=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --trunk) [ $# -ge 2 ] || fail BAD_ARGS "--trunk needs a value"; st_trunk="$2"; shift 2 ;;
      *) fail BAD_ARGS "unknown argument to setup status: $1" ;;
    esac
  done
  setup_resolve .
  if [ ! -f "$setup_file" ]; then
    printf 'SETUP:\tabsent\n'
    exit 0
  fi
  if ! setup_is_stamped "$setup_file"; then
    printf 'SETUP:\tunstamped\n'
    printf 'SETUP_LINES:\t%d\n' "$(setup_body_lines "$setup_file")"
    exit 0
  fi

  st_recorded_fp="$(setup_header_field "$setup_file" fingerprint)"
  st_sources="$(setup_header_field "$setup_file" derived-from)"
  st_verified="$(setup_header_field "$setup_file" verified)"
  st_inspected="$(setup_header_field "$setup_file" inspected)"

  st_dir="$(setup_scratch)"
  # The recorded manifest, recovered from the header's inspected: pairs.
  printf '%s\n' "$st_inspected" | tr ' ' '\n' | grep -v '^$' | grep -v '^-$' \
    | sed 's/=\([^=]*\)$/	\1/' | LC_ALL=C sort >"$st_dir/recorded"

  st_rev="$(setup_trunk "$st_trunk")"
  st_extra="$st_sources"
  [ "$st_extra" = "-" ] && st_extra=""
  setup_manifest "$st_rev" "$st_extra" >"$st_dir/manifest"
  st_fp="$(setup_fingerprint <"$st_dir/manifest")"

  if [ "$st_fp" = "$st_recorded_fp" ]; then
    printf 'SETUP:\tcurrent\t%s\n' "$st_fp"
  else
    printf 'SETUP:\tdrifted\t%s\n' "$st_recorded_fp"
    # The recorded values are 12-character prefixes (the header stays
    # readable); compare like for like.
    awk -F'\t' '{ print $1 "\t" substr($2, 1, 12) }' "$st_dir/manifest" >"$st_dir/now"
    awk -F'\t' 'NR == FNR { a[$1] = $2; seen[$1] = 1; next }
                { if (!seen[$1] || a[$1] != $2) print $1; delete seen[$1] }
                END { for (k in seen) print k }' \
      "$st_dir/recorded" "$st_dir/now" | LC_ALL=C sort -u \
      | while IFS= read -r st_path; do
          [ -n "$st_path" ] && printf 'CHANGED:\t%s\n' "$st_path"
        done
  fi
  printf 'SETUP_LINES:\t%d\n' "$(setup_body_lines "$setup_file")"
  printf 'SETUP_SOURCES:\t%s\n' "${st_sources:--}"
  printf 'SETUP_VERIFIED:\t%s\n' "${st_verified:--}"
  rm -rf "$st_dir"
  exit 0
fi

# ---- install ------------------------------------------------------------

if [ "$setup_mode" = "install" ]; then
  [ $# -ge 1 ] || fail BAD_ARGS "usage: orca.sh setup install <candidate> --sources <paths> [--verified <text>] [--trunk <ref>]"
  in_cand="$1"; shift
  in_sources=""; in_verified=""; in_trunk=""; in_sources_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --sources)  [ $# -ge 2 ] || fail BAD_ARGS "--sources needs a value";  in_sources="$2"; in_sources_set=1; shift 2 ;;
      --verified) [ $# -ge 2 ] || fail BAD_ARGS "--verified needs a value"; in_verified="$2"; shift 2 ;;
      --trunk)    [ $# -ge 2 ] || fail BAD_ARGS "--trunk needs a value";    in_trunk="$2";    shift 2 ;;
      *) fail BAD_ARGS "unknown argument to setup install: $1" ;;
    esac
  done
  [ "$in_sources_set" -eq 1 ] || fail BAD_ARGS "--sources is required — pass '-' when the derivation used no repository file"
  [ -f "$in_cand" ] || fail BAD_ARGS "candidate is not a file: $in_cand"
  [ -s "$in_cand" ] || fail BAD_SCRIPT "candidate is empty: $in_cand"
  bash -n "$in_cand" 2>/dev/null || fail BAD_SCRIPT "candidate is not valid bash: $in_cand"
  case "$in_sources" in
    *'	'*) fail BAD_ARGS "--sources paths may not contain tabs" ;;
  esac
  case "$in_verified" in
    *'
'*) fail BAD_ARGS "--verified must be a single line" ;;
  esac
  setup_resolve .

  in_extra="$in_sources"
  [ "$in_extra" = "-" ] && in_extra=""
  in_rev="$(setup_trunk "$in_trunk")"
  in_dir="$(setup_scratch)"
  setup_manifest "$in_rev" "$in_extra" >"$in_dir/manifest"
  in_fp="$(setup_fingerprint <"$in_dir/manifest")"
  in_inspected="$(awk -F'\t' '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $1, substr($2, 1, 12) }' "$in_dir/manifest")"

  mkdir -p "$repo_root/.orca" 2>/dev/null || fail WRITE_ERROR "could not create $repo_root/.orca"
  # Composed beside the target, not in TMPDIR, so the rename is atomic —
  # config_write's discipline: a concurrent `setup run` must never observe
  # a half-written script.
  in_tmp="$(mktemp "$repo_root/.orca/.setup.XXXXXX" 2>/dev/null)" \
    || { rm -rf "$in_dir"; fail WRITE_ERROR "could not create a temp file beside $setup_file"; }
  # The header is prose about verbs, so it carries backticks and never any
  # expansion — SC2016 reads those as intended substitutions.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf '# orca setup — provisions a fresh worktree; run by `orca.sh provision` on every arrival.\n'
    printf '# Machine-local, never committed. The body is yours to edit; the provenance\n'
    printf '# lines below are read by `orca.sh setup status`, so a change that should\n'
    printf '# re-baseline the drift check goes back through `orca.sh setup install`.\n'
    printf '# derived-from: %s\n' "${in_sources:--}"
    printf '# fingerprint: %s\n' "$in_fp"
    printf '# inspected: %s\n' "${in_inspected:--}"
    printf '# verified: %s %s\n' "$(date +%Y-%m-%d)" "${in_verified:--}"
    printf '\n'
    # A candidate carrying its own shebang would leave a stray interpreter
    # line in the middle of the file.
    sed '1{/^#!/d;}' "$in_cand"
  } >"$in_tmp" 2>/dev/null \
    || { rm -f "$in_tmp"; rm -rf "$in_dir"; fail WRITE_ERROR "could not compose $setup_file"; }
  mv -f "$in_tmp" "$setup_file" 2>/dev/null \
    || { rm -f "$in_tmp"; rm -rf "$in_dir"; fail WRITE_ERROR "could not write $setup_file"; }
  rm -rf "$in_dir"
  printf 'INSTALLED:\t%s\n' "$setup_file"
  printf 'SETUP:\tcurrent\t%s\n' "$in_fp"
  exit 0
fi

fail BAD_ARGS "usage: orca.sh setup run|verify|status|install [args...]"
