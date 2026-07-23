# shellcheck shell=bash disable=SC2154
#
# orca config — the sole reader/writer of <repo-root>/.orca/config.
# The orca:config skill stays the conversational shell (presentation,
# advice, failure translation); this script owns the parse, the
# validation, the merge/removal semantics, and the canonical write.
# preflight.sh and review.sh read the file with grep, justified by the
# guarantee that lives HERE (via lib.sh): this script is the only
# writer, and it only ever writes the canonical shape below.
#
# The file is flat dotted key=value (see lib.sh's config section for
# the grammar); the legacy .orca/config.json is no longer read by
# anything — preflight.sh emits an informational CONFIG: OBSOLETE line
# while one exists, and orca:config offers to delete it.
#
# Usage:
#   orca.sh config show
#   orca.sh config validate
#   orca.sh config set <field>=<value> [...]     # plan.model=sonnet reviewer=claude
#   orca.sh config clear <field> [...]           # plan.model reviewer
#   orca.sh config reset [stage]
#
# Output contract — one machine-readable line per fact, fields TAB-separated:
#
#   show (read-only; a file that fails validation FAILs — fix via set/clear/reset):
#     REVIEWER:<TAB><codex|claude><TAB>pinned      or  REVIEWER:<TAB>absent
#     EDITOR:<TAB><nvim|vscode|none|absent>
#     TERMINAL:<TAB><tmux|none|absent>
#     OVERRIDE:<TAB><stage><TAB><model|effort><TAB><value>    one per set field
#     DEFAULT:<TAB><stage><TAB><model><TAB><effort>           from the plugin's
#       agents/<stage>.md frontmatter, stages in vocabulary order. The review
#       stage appears twice, as review-codex AND review-claude — the caller
#       renders the row for the effective reviewer, which this script never
#       resolves: detection is preflight.sh's job (its REVIEWER: line), and
#       the caller composes the two outputs.
#
#   validate (read-only):
#     VALID:<TAB><compact-json>    exit 0 — the canonical launch block: the
#       pinned reviewer plus the agents overrides, exactly what the run
#       skills hold for the Workflow args. editor/terminal are validated but
#       excluded — they are orca:review preferences, not launch args. An
#       absent file is a valid state: VALID:<TAB>{}
#       (The one place JSON survives the format migration: the launch
#       skills pass this object straight into Workflow args, and the
#       workflow scripts validate that shape at launch. Emitting JSON for
#       a closed lowercase-token vocabulary is a printf with no escaping
#       concerns; parsing was the hard part, and parsing is flat-file.)
#
#   set / clear / reset (write): the resulting state as show emits it
#   (DEFAULT lines included), plus
#     WROTE:<TAB><path>       or  DELETED:<TAB><path>
#   set assigns field=value; the value `default` clears that field instead.
#   clear removes bare fields (<stage>.<model|effort> or a top-level key).
#   reset <stage> clears one stage; reset with no argument clears everything
#   — file deletion included, and it works even on an unparseable file (the
#   recovery path: a full reset never needs a parse).
#   Writes are reject-all-or-write-nothing: every bad assignment (and any
#   pre-existing bad value the merge would preserve) gets its own FAIL line,
#   and nothing is written on a nonzero exit.
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1, nothing written
#       reasons: NOT_GIT OLD_GIT BAD_ARGS PARSE_ERROR DUPLICATE_KEY
#                UNKNOWN_KEY UNKNOWN_STAGE UNKNOWN_MODEL UNKNOWN_EFFORT
#                UNKNOWN_REVIEWER UNKNOWN_EDITOR UNKNOWN_TERMINAL
#                WRITE_ERROR
#
# Canonical write shape — the contract the grep-readers in preflight.sh and
# review.sh assume (they stay grep-only BECAUSE this script is the sole
# writer): one key=value per line, fixed order (reviewer, editor, terminal,
# then stages in vocabulary order, model before effort), cleared keys
# removed entirely (never "default"), and a file that would be empty is
# deleted instead.
#
# Works in both layouts: the bare-with-worktrees layout orca:init creates
# (.orca/ sits beside the bare repo, outside every worktree) and a
# conventional checkout — where <repo-root> IS a working tree, so when this
# script writes there it also ensures `.orca/` is listed in
# <git-common-dir>/info/exclude (the per-clone ignore file), keeping a stray
# `git add -A` from committing per-machine preferences.
#
# Sourced by orca.sh with the verb arguments in place; lib.sh (fail(),
# the vocabulary tables, and the config parser/writer) is already
# loaded, and $orca_scripts_dir is the dispatcher's own directory.

agents_dir="$orca_scripts_dir/../agents"

# Reject-all-or-write-nothing needs every bad assignment reported, not
# just the first — errors accumulate here and bail together.
errors=""
err() { # <reason> <detail>
  errors="$errors$(printf 'FAIL:\t%s\t%s' "$1" "$2")
"
}
bail_if_errors() {
  [ -z "$errors" ] && return 0
  printf '%s' "$errors"
  exit 1
}

# Resolve repo root in either layout: the parent of the git common dir is
# the directory that holds (or will hold) .orca/. No bare-layout
# requirement — the config is legitimate in a repo orca:init has not
# converted yet.
resolve_config_repo() {
  resolve_repo   # sets common_dir, repo_root, is_bare; NOT_GIT/OLD_GIT typed
  # shellcheck disable=SC2154  # repo_root is resolve_repo's
  config_file="$repo_root/.orca/config"
}

# Stage defaults from the plugin's own agent definitions — read fresh, never
# recited, so a plugin update moves these lines with it.
emit_defaults() {
  local stage file model effort
  for stage in spec plan implement review-codex review-claude fix commit merge integrate reproduce hypothesize verify diagnose; do
    file="$agents_dir/$stage.md"
    [[ -f "$file" ]] || continue
    model="$(awk '/^---$/{n++; next} n==1 && sub(/^model:[ \t]*/,""){print; exit}' "$file")"
    effort="$(awk '/^---$/{n++; next} n==1 && sub(/^effort:[ \t]*/,""){print; exit}' "$file")"
    printf 'DEFAULT:\t%s\t%s\t%s\n' "$stage" "${model:-unset}" "${effort:-unset}"
  done
}

# Conventional checkout only (the bare layout's .orca/ is outside every
# worktree): make sure the per-clone ignore file excludes .orca/. Idempotent,
# and only once .orca/ actually exists.
ensure_exclude() {
  # shellcheck disable=SC2154  # is_bare/common_dir are resolve_repo's
  [[ "$is_bare" == "true" ]] && return 0
  [[ -e "$repo_root/.orca" ]] || return 0
  # shellcheck disable=SC2154  # common_dir is resolve_repo's
  local exclude="$common_dir/info/exclude"
  mkdir -p "$common_dir/info"
  grep -qxF '.orca/' "$exclude" 2>/dev/null || printf '.orca/\n' >>"$exclude"
}

# Load the config file; on any file error print ALL its typed FAILs and
# exit 1. Sets cfg (validated key=value lines).
load_config() {
  if ! cfg="$(config_parse "$config_file")"; then
    printf '%s\n' "$cfg"
    exit 1
  fi
}

# The state lines shared by show and every write: REVIEWER/EDITOR/TERMINAL
# plus one OVERRIDE per set stage field, stages in vocabulary order.
emit_state() { # <cfg-lines>
  local cfg="$1" v s f
  v="$(config_lookup "$cfg" reviewer)"
  if [ -n "$v" ]; then printf 'REVIEWER:\t%s\tpinned\n' "$v"; else printf 'REVIEWER:\tabsent\n'; fi
  printf 'EDITOR:\t%s\n' "$(config_lookup "$cfg" editor | grep . || echo absent)"
  printf 'TERMINAL:\t%s\n' "$(config_lookup "$cfg" terminal | grep . || echo absent)"
  for s in $ORCA_STAGES; do
    for f in model effort; do
      v="$(config_lookup "$cfg" "agents.$s.$f")"
      [ -n "$v" ] && printf 'OVERRIDE:\t%s\t%s\t%s\n' "$s" "$f" "$v"
    done
  done
  return 0
}

# The validate wire format: the canonical launch block as compact JSON —
# byte-compatible with the historical emitter (reviewer first, then the
# agents block, stages in vocabulary order, model before effort).
launch_json() { # <cfg-lines>
  local cfg="$1" out="" agents="" sobj s f v
  v="$(config_lookup "$cfg" reviewer)"
  [ -n "$v" ] && out="\"reviewer\":\"$v\""
  for s in $ORCA_STAGES; do
    sobj=""
    for f in model effort; do
      v="$(config_lookup "$cfg" "agents.$s.$f")"
      [ -n "$v" ] && sobj="$sobj${sobj:+,}\"$f\":\"$v\""
    done
    [ -n "$sobj" ] && agents="$agents${agents:+,}\"$s\":{$sobj}"
  done
  [ -n "$agents" ] && out="$out${out:+,}\"agents\":{$agents}"
  printf '{%s}' "$out"
}

# parse_field <token> — sets ckey to the token's canonical file key
# (reviewer | editor | terminal | agents.<stage>.<model|effort>); on a
# bad field, records the typed error and returns 1. Sets a variable
# rather than printing: run in a command substitution, err()'s
# accumulation would be lost in the subshell. The CLI spelling stays
# <stage>.model — the file's agents. prefix is this mapping's job.
parse_field() {
  local tok="$1" stage field
  ckey=""
  case "$tok" in
    reviewer|editor|terminal) ckey="$tok"; return 0 ;;
    *.*)
      stage="${tok%%.*}"
      field="${tok#*.}"
      if ! in_list "$stage" "$ORCA_STAGES"; then
        err UNKNOWN_STAGE "$tok — stages are $(commas "$ORCA_STAGES")"
        return 1
      fi
      case "$field" in
        model|effort) ckey="agents.$stage.$field"; return 0 ;;
        *) err UNKNOWN_KEY "$tok — a stage takes model or effort"; return 1 ;;
      esac ;;
    *)
      err UNKNOWN_KEY "$tok — settable fields are <stage>.model, <stage>.effort, reviewer, editor, terminal"
      return 1 ;;
  esac
}

# Ops are "set <key> <value>" / "clear <key>" lines accumulated by the
# subcommands and applied in order (a later op on the same key wins).
ops=""
add_op() { # set <key> <value> | clear <key>
  ops="$ops$*
"
}
apply_ops() { # <cfg-lines> — the merged cfg lines on stdout
  local cfg="$1" op verb key value
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    verb="${op%% *}"
    if [ "$verb" = "set" ]; then
      key="$(printf '%s' "$op" | cut -d' ' -f2)"
      value="$(printf '%s' "$op" | cut -d' ' -f3)"
      cfg="$(printf '%s\n' "$cfg" | awk -F= -v k="$key" '$1 != k')
$key=$value"
    else
      key="${op#clear }"
      cfg="$(printf '%s\n' "$cfg" | awk -F= -v k="$key" '$1 != k')"
    fi
  done <<EOF
$ops
EOF
  printf '%s' "$cfg"
}

# The write tail every mutating subcommand shares: apply, canonical
# write, resulting state, exclude upkeep, defaults.
write_and_report() {
  local merged out
  merged="$(apply_ops "$cfg")"
  emit_state "$merged"
  # Captured, not piped through: config_write's typed fail() must exit
  # THIS process, and a pipeline segment's exit cannot.
  if ! out="$(printf '%s\n' "$merged" | config_write "$config_file")"; then
    printf '%s\n' "$out"
    exit 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  ensure_exclude
  emit_defaults
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift

case "$sub" in
  show)
    resolve_config_repo
    load_config
    emit_state "$cfg"
    emit_defaults
    exit 0
    ;;
  validate)
    resolve_config_repo
    load_config
    printf 'VALID:\t%s\n' "$(launch_json "$cfg")"
    exit 0
    ;;
  set)
    [[ $# -ge 1 ]] || fail BAD_ARGS "usage: config.sh set <field>=<value> [...]"
    resolve_config_repo
    for tok in "$@"; do
      case "$tok" in
        *=*) ;;
        *) err BAD_ARGS "$tok — set takes <field>=<value> assignments"; continue ;;
      esac
      field="${tok%%=*}"
      value="${tok#*=}"
      parse_field "$field" || continue
      if [ "$value" = "default" ]; then
        add_op clear "$ckey"
        continue
      fi
      allowed="$(config_allowed_values "$ckey")"
      if ! in_list "$value" "$allowed"; then
        err "$(config_fail_reason "$ckey")" "$tok — allowed values: $(commas "$allowed"), default"
        continue
      fi
      add_op set "$ckey" "$value"
    done
    bail_if_errors
    load_config
    write_and_report
    exit 0
    ;;
  clear)
    [[ $# -ge 1 ]] || fail BAD_ARGS "usage: config.sh clear <field> [...]"
    resolve_config_repo
    for tok in "$@"; do
      case "$tok" in
        *=*) err BAD_ARGS "$tok — clear takes bare fields, no \"=\""; continue ;;
      esac
      parse_field "$tok" || continue
      add_op clear "$ckey"
    done
    bail_if_errors
    load_config
    write_and_report
    exit 0
    ;;
  reset)
    [[ $# -le 1 ]] || fail BAD_ARGS "usage: config.sh reset [stage]"
    resolve_config_repo
    if [[ $# -eq 0 ]]; then
      # Full reset never parses — it is the recovery path for a mangled file.
      emit_state ""
      if [[ -e "$config_file" ]]; then
        rm -f "$config_file"
        printf 'DELETED:\t%s\n' "$config_file"
      fi
      ensure_exclude
      emit_defaults
      exit 0
    fi
    stage="$1"
    if ! in_list "$stage" "$ORCA_STAGES"; then
      err UNKNOWN_STAGE "$stage — stages are $(commas "$ORCA_STAGES")"
    fi
    bail_if_errors
    load_config
    add_op clear "agents.$stage.model"
    add_op clear "agents.$stage.effort"
    write_and_report
    exit 0
    ;;
  *)
    fail BAD_ARGS "usage: config.sh show | validate | set <field>=<value>... | clear <field>... | reset [stage]"
    ;;
esac
