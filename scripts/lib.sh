# shellcheck shell=bash
#
# orca lib — the shared machinery under the orca CLI (orca.sh and the
# verbs it dispatches to) and any bundled script that sources it. One
# holder for the conventions every verb must agree on: typed failures,
# the framed-output contract, base64 relay encoding, repository
# resolution, the symlink canonicalizer, and the banned-attribution
# regex.
#
# Sourced, never executed. bash has textual inclusion, not modules, so
# the rules are conventions, enforced by review: this file owns its
# function names (fail, emit_frame, b64_encode, b64_decode,
# resolve_repo, canonicalize, is_banned) and verbs never redefine them;
# callers source it via an absolute path ("$PLUGIN_ROOT/scripts/lib.sh"
# — `source` resolves relative paths against the working directory, not
# the sourcing script); and a sourced file's `exit` kills the caller —
# by design for fail() (typed failure then exit is the wanted
# behavior); everything else here returns and lets the verb decide.
#
# Runtime envelope: bash 3.2 + git (>= 2.31) + coreutils. Nothing else.

# Sentinel guard: sourcing twice (dispatcher plus a verb that sources
# defensively) must be a no-op, not a redefinition pass.
[ -n "${ORCA_LIB_LOADED:-}" ] && return
ORCA_LIB_LOADED=1

fail() { # <reason> <detail> — typed failure, exit 1
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

# ---- framed output ----------------------------------------------------
# The relay contract: a verb's machine-readable result is one frame —
# @@ORCA@@, one key=value line per fact, @@ORCA_END@@ — and arbitrary
# content crosses the relay only base64-encoded under a `.b64` key, so
# relay preamble can never contaminate what gets parsed or
# attribution-checked. The decoder's continuation rule (any line between
# the markers not opening a declared key joins the open key's value)
# is what lets a relay-wrapped .b64 line survive; emission's job is
# simply never to emit a value containing a newline outside a .b64 key.

emit_frame() { # key=value ... — one frame on stdout
  printf '@@ORCA@@\n'
  local kv
  for kv in "$@"; do
    printf '%s\n' "$kv"
  done
  printf '@@ORCA_END@@\n'
}

# Encode: `base64 | tr -d '\n'` because GNU base64 wraps at 76 columns
# by default and macOS lacks -w0. Decode: `--decode` is the one spelling
# both userlands accept (GNU -d, older macOS -D).
b64_encode() { # stdin -> one-line base64 on stdout
  base64 | tr -d '\n'
}

b64_encode_str() { # <string> -> one-line base64 on stdout
  printf '%s' "$1" | b64_encode
}

b64_decode() { # stdin (whitespace already stripped) -> raw bytes on stdout
  base64 --decode
}

# ---- repository resolution --------------------------------------------
# Resolve repo state in either layout (bare-with-worktrees or a
# conventional checkout): the parent of the git common dir is the
# directory that holds (or will hold) .orca/. Sets common_dir,
# repo_root, is_bare. Typed OLD_GIT before NOT_GIT: an empty
# --path-format result can mean old git, and misreporting that sends
# users chasing the wrong problem.
resolve_repo() {
  # shellcheck disable=SC2034  # set for the sourcing caller
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$common_dir" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    fail OLD_GIT "git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1) lacks --path-format (orca needs git >= 2.31) — upgrade git"
  fi
  if [ -z "$common_dir" ]; then
    fail NOT_GIT "not inside a git repository"
  fi
  # shellcheck disable=SC2034  # set for the sourcing caller
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  # shellcheck disable=SC2034  # set for the sourcing caller
  repo_root="$(dirname "$common_dir")"
}

# ---- symlink canonicalizer --------------------------------------------
# canonicalize <path> — the canonical absolute path, every symlink
# component resolved, existence NOT required (realpath -m semantics:
# dangling links must still resolve so ownership sweeps can judge
# them). Pure bash because realpath -m is not portable to macOS.
# Symlink hops are bounded at 40 (the kernel's own bound); past it the
# partially resolved path is returned as-is — a loop can never equal a
# real canonical path, which is all the ownership test needs.
canonicalize() { # <path> -> canonical absolute path on stdout
  local target="$1" result="" remaining comp candidate link hops=0
  case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
  esac
  remaining="${target#/}"
  while [ -n "$remaining" ]; do
    comp="${remaining%%/*}"
    if [ "$comp" = "$remaining" ]; then remaining=""; else remaining="${remaining#*/}"; fi
    case "$comp" in
      ''|.) continue ;;
      ..)
        result="${result%/*}"
        continue
        ;;
    esac
    candidate="$result/$comp"
    if [ -L "$candidate" ]; then
      hops=$((hops + 1))
      if [ "$hops" -gt 40 ]; then
        result="$candidate${remaining:+/$remaining}"
        break
      fi
      link="$(readlink "$candidate")"
      case "$link" in
        /*) result=""; remaining="${link#/}${remaining:+/$remaining}" ;;
        *)  remaining="$link${remaining:+/$remaining}" ;;
      esac
    else
      result="$candidate"
    fi
  done
  printf '%s\n' "${result:-/}"
}

# ---- config: vocabulary, parser, canonical writer ---------------------
# The config file is <repo-root>/.orca/config — flat dotted key=value,
# a closed lowercase-token vocabulary:
#
#   reviewer=codex
#   editor=nvim
#   agents.plan.model=sonnet
#   agents.review.effort=high
#
# Grammar: a line is blank, a # comment, or matches
# ^[a-z][a-z.]*=[a-z]+$ — anything else is PARSE_ERROR; a key outside
# the vocabulary is UNKNOWN_KEY; a key seen twice is DUPLICATE_KEY. The
# grammar cannot express an invalid shape: no quoting, no escaping, no
# type confusion, and each line validates independently.
#
# One shared validation vocabulary kept in lockstep across four code
# validators: this file (the config verb's parse and the run skills' launch
# validation via its validate subcommand), work-loop.workflow.js,
# debug-loop.workflow.js, and — MODELS/EFFORTS only — spec.workflow.js.
# The workflow scripts run sandboxed with no filesystem access, so they
# carry their own literal copies; a value accepted here but rejected
# there bricks that verb's launches until the config file is
# hand-edited. CI's lockstep-check.py fails when the lists drift.
ORCA_STAGES="spec plan implement review fix commit merge integrate reproduce hypothesize verify diagnose"
ORCA_MODELS="haiku sonnet opus fable"
ORCA_EFFORTS="low medium high xhigh max"
ORCA_REVIEWERS="codex claude"
ORCA_EDITORS="nvim vscode none"
ORCA_TERMINALS="tmux none"

in_list() { # <value> <space-separated-list>
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

commas() { # <words...> — "a, b, c" for error details
  printf '%s' "$*" | sed 's/ /, /g'
}

# config_allowed_values <key> — the key's allowed-values list on
# stdout; return 1 when the key is not in the vocabulary.
config_allowed_values() {
  local stage
  case "$1" in
    reviewer) printf '%s' "$ORCA_REVIEWERS" ;;
    editor)   printf '%s' "$ORCA_EDITORS" ;;
    terminal) printf '%s' "$ORCA_TERMINALS" ;;
    agents.*.model)
      stage="${1#agents.}"; stage="${stage%.model}"
      case "$stage" in *.*) return 1 ;; esac
      in_list "$stage" "$ORCA_STAGES" || return 1
      printf '%s' "$ORCA_MODELS" ;;
    agents.*.effort)
      stage="${1#agents.}"; stage="${stage%.effort}"
      case "$stage" in *.*) return 1 ;; esac
      in_list "$stage" "$ORCA_STAGES" || return 1
      printf '%s' "$ORCA_EFFORTS" ;;
    *) return 1 ;;
  esac
}

# config_fail_reason <key> — the typed reason a bad VALUE under this
# (known-valid) key fails with.
config_fail_reason() {
  case "$1" in
    reviewer) printf 'UNKNOWN_REVIEWER' ;;
    editor)   printf 'UNKNOWN_EDITOR' ;;
    terminal) printf 'UNKNOWN_TERMINAL' ;;
    *.model)  printf 'UNKNOWN_MODEL' ;;
    *)        printf 'UNKNOWN_EFFORT' ;;
  esac
}

# config_parse <file> — strict parse. On success: the file's key=value
# lines on stdout (file order), exit 0. On any error: one typed
# FAIL:<TAB><reason><TAB><detail> line per problem on stdout — ALL of
# them — and exit 1, valid lines suppressed. A missing file is an empty
# valid config.
config_parse() {
  local file="$1" line key value allowed reason out="" errs="" seen=" "
  if [ ! -f "$file" ]; then return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if ! [[ $line =~ ^[a-z][a-z.]*=[a-z]+$ ]]; then
      errs="$errs$(printf 'FAIL:\t%s\t%s' PARSE_ERROR "invalid line in $file: \"$line\" — a line is blank, a # comment, or lowercase key=value; fix by hand or orca.sh config reset")
"
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    if ! allowed="$(config_allowed_values "$key")"; then
      errs="$errs$(printf 'FAIL:\t%s\t%s' UNKNOWN_KEY "$key in $file — keys are reviewer, editor, terminal, agents.<stage>.<model|effort>; stages are $(commas "$ORCA_STAGES")")
"
      continue
    fi
    if in_list "$key" "$seen"; then
      errs="$errs$(printf 'FAIL:\t%s\t%s' DUPLICATE_KEY "duplicate key \"$key\" in $file — fix by hand or orca.sh config reset")
"
      continue
    fi
    seen="$seen$key "
    if ! in_list "$value" "$allowed"; then
      reason="$(config_fail_reason "$key")"
      errs="$errs$(printf 'FAIL:\t%s\t%s' "$reason" "$key=$value — allowed values: $(commas "$allowed")")
"
      continue
    fi
    out="$out$line
"
  done <"$file"
  if [ -n "$errs" ]; then
    printf '%s' "$errs"
    return 1
  fi
  printf '%s' "$out"
}

# config_lookup <cfg-lines> <key> — the key's value on stdout, empty
# when absent.
config_lookup() {
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { print $2; exit }'
}

# config_write <file> — canonical write of the key=value lines on
# stdin: fixed order (reviewer, editor, terminal, then stages in
# vocabulary order, model before effort), atomic (temp file + rename,
# so a concurrent grep-reader never observes a truncated file), and a
# file that would be empty is deleted instead. Emits WROTE:/DELETED:.
config_write() {
  local file="$1" cfg out="" k s f v dir tmp
  cfg="$(cat)"
  for k in reviewer editor terminal; do
    v="$(config_lookup "$cfg" "$k")"
    [ -n "$v" ] && out="$out$k=$v
"
  done
  for s in $ORCA_STAGES; do
    for f in model effort; do
      v="$(config_lookup "$cfg" "agents.$s.$f")"
      [ -n "$v" ] && out="${out}agents.$s.$f=$v
"
    done
  done
  if [ -z "$out" ]; then
    if [ -e "$file" ]; then
      rm -f "$file"
      printf 'DELETED:\t%s\n' "$file"
    fi
    return 0
  fi
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  if ! tmp="$(mktemp "$dir/.config.XXXXXX" 2>/dev/null)"; then
    fail WRITE_ERROR "could not create a temp file beside $file"
  fi
  if ! printf '%s' "$out" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    fail WRITE_ERROR "could not write $file"
  fi
  printf 'WROTE:\t%s\n' "$file"
}

# ---- banned-attribution check -----------------------------------------
# The one holder of the regex (work-loop's JS copy is deleted in the
# verb switchover): unambiguous attribution markers only — "ai",
# "agent", and "orca" are legitimate domain vocabulary that
# false-positives constantly, and keeping them out of prose is the
# stage agents' own instruction, not something a regex can decide.
ORCA_BANNED_RE='claude|anthropic|co-authored-by|generated (with|by)'

is_banned() { # <text> — exit 0 iff the text trips the attribution regex
  printf '%s' "$1" | grep -iEq "$ORCA_BANNED_RE"
}
