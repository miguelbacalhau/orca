#!/usr/bin/env bash
#
# orca review — the deterministic spine of /orca:review: deliverable
# discovery, editor/terminal resolution, probes, and the launch. The
# skill stays the conversational shell (triage, failure translation,
# the parting message); this script owns the plumbing.
#
# Usage:
#   review.sh discover
#   review.sh open <worktree>
#   review.sh probe <nvim|vscode>
#
# Output contract — one machine-readable line per fact, fields
# TAB-separated (worktree paths may contain spaces):
#
#   discover (read-only):
#     TRUNK:<TAB><trunk>                            informational, emitted once
#     DELIVERABLE:<TAB><branch><TAB><worktree><TAB>ok|missing
#       ok      -> checked out at <worktree> per `git worktree list --porcelain`
#       missing -> branch unmerged but no worktree has it; <worktree> is the
#                  namespace-derived path a re-add would use
#     Exit 0 even with zero DELIVERABLE lines — an empty list is an answer,
#     not an error.
#
#   open (read-only except the launch itself):
#     PROBE_FAILED:<TAB><nvim|vscode><TAB><detail>  informational — a detected
#       (not pinned) tier failed its probe and the next tier was tried
#     OPEN:<TAB>nvim-tmux<TAB><window-id>           exit 0, launched
#     OPEN:<TAB>vscode<TAB><worktree>               exit 0, launched
#     PRINT_ONLY:<TAB><reason><TAB><detail>         exit 2, nothing launched —
#       + COMMAND:<TAB><exact fallback for the user to run themselves>
#       reasons: EDITOR_NONE TERMINAL_NONE NO_TMUX NO_EDITOR
#                TMUX_LAUNCH_FAILED VSCODE_LAUNCH_FAILED
#
#   probe (read-only, machine-level — needs no git repository, so doctor's
#   machine-only mode can call it):
#     PROBE_OK:<TAB><nvim|vscode>                   exit 0, the tier probes clean
#     PROBE_FAILED:<TAB><nvim|vscode><TAB><detail>  exit 1, with the same detail
#       strings the open subcommand emits
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>               exit 1, nothing launched
#       reasons: NOT_GIT NOT_BARE NO_TRUNK BAD_ARGS NO_SUCH_WORKTREE
#                UNKNOWN_VALUE PINNED_PROBE_FAILED PINNED_TERMINAL_UNSET
#
# Config comes from <repo-root>/.orca/config.json — the flat top-level
# `editor` (nvim|vscode|none) and `terminal` (tmux|none) keys, each with
# the three-state contract: absent -> detect, pinned -> loud FAIL when its
# dependency is missing, none -> opt out to PRINT_ONLY. Detection probes
# nvim first, then vscode; the terminal key is consulted only when the
# editor resolved to nvim (the vscode launch is a detached GUI). Nothing
# here writes the config — that is orca:config's job.
#
# Extraction is grep-only by design: orca:config is the sole writer and
# emits compact well-formed JSON in which these can only be top-level keys.

set -uo pipefail

fail() { # <reason> <detail> — typed failure, exit 1, nothing launched
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

print_only() { # <reason> <detail> <command> — clean opt-out, exit 2
  printf 'PRINT_ONLY:\t%s\t%s\n' "$1" "$2"
  printf 'COMMAND:\t%s\n' "$3"
  exit 2
}

# Quote one value for copy-paste into the user's shell — COMMAND: payloads
# must survive paths and refnames containing quotes or metacharacters.
shq() { printf '%q' "$1"; }

# Percent-encode one URI query value. The extension parses the query with
# URLSearchParams, which percent-decodes — a raw path containing & # % + ?
# would arrive truncated or corrupted. Byte-wise (LC_ALL=C) so multibyte
# characters encode as their UTF-8 bytes.
urlencode() {
  local LC_ALL=C
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9./_~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "$(( $(printf '%d' "'$c") & 0xFF ))")" ;;  # mask: bash yields high bytes signed
    esac
  done
  printf '%s' "$out"
}

# Resolve common_dir / repo_root / trunk; typed FAIL outside the bare layout.
resolve_repo() {
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    fail NOT_GIT "not inside a git repository — nothing to review (orca:init sets up the layout)"
  fi
  local is_bare
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" != "true" ]]; then
    fail NOT_BARE "conventional checkout, not bare-with-worktrees (orca:init converts)"
  fi
  repo_root="$(dirname "$common_dir")"
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$trunk" ]]; then
    fail NO_TRUNK "the bare repo's HEAD names no branch — cannot resolve the trunk"
  fi
}

# Extract one flat string key from .orca/config.json. Echoes the value
# (empty = absent). Returns 1 on multiple distinct values — a hand-mangled
# file the caller turns into a loud FAIL, never a guess.
read_config_key() {
  local key="$1" file="$repo_root/.orca/config.json" values count
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  values="$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | grep -o '"[^"]*"$' | tr -d '"' | sort -u || true)"
  count="$(printf '%s' "$values" | grep -c . || true)"
  if [[ "$count" -gt 1 ]]; then
    return 1
  fi
  echo "$values"
}

probe_nvim() {
  if ! command -v nvim >/dev/null 2>&1; then
    probe_detail="nvim not on PATH"
    return 1
  fi
  local out
  out="$(nvim --headless "+lua io.write(pcall(require,'orca') and 'yes' or 'no')" +qa! 2>/dev/null </dev/null || true)"
  if [[ "$out" != *yes* ]]; then
    probe_detail="orca.nvim not loadable (headless require('orca') probe)"
    return 1
  fi
}

probe_vscode() {
  if ! command -v code >/dev/null 2>&1; then
    probe_detail="code CLI not on PATH"
    return 1
  fi
  if ! code --list-extensions 2>/dev/null | grep -qx miguelnjacinto.orca-vscode; then
    probe_detail="orca.vscode extension (miguelnjacinto.orca-vscode) not installed"
    return 1
  fi
}

cmd_discover() {
  resolve_repo
  printf 'TRUNK:\t%s\n' "$trunk"

  # An unborn trunk (bare repo, no commits yet) means no run ever produced
  # a deliverable — an empty list, not an error.
  if ! git --git-dir="$common_dir" rev-parse --verify --quiet "$trunk^{commit}" >/dev/null 2>&1; then
    exit 0
  fi

  # branch<TAB>path pairs from the porcelain — the only sanctioned join;
  # paths are never guessed for a branch that has a worktree.
  local wt_map
  wt_map="$(git --git-dir="$common_dir" worktree list --porcelain | awk '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// { print substr($0, 19) "\t" path }
  ')"

  local branch slug worktree state
  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    # Per-item branches (feature/<slug>-W<n>, kept by blocked items) are
    # not deliverables.
    if [[ "$branch" =~ -W[0-9]+$ ]]; then
      continue
    fi
    worktree="$(printf '%s\n' "$wt_map" | awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }')"
    if [[ -n "$worktree" ]]; then
      state="ok"
    else
      state="missing"
      slug="${branch#*/}"
      case "$branch" in
        fix/*) worktree="$repo_root/orca-fix-$slug" ;;
        *)     worktree="$repo_root/orca-$slug" ;;
      esac
    fi
    printf 'DELIVERABLE:\t%s\t%s\t%s\n' "$branch" "$worktree" "$state"
  done < <(git --git-dir="$common_dir" branch --list 'feature/*' 'fix/*' \
             --no-merged "$trunk" --format='%(refname:short)')
  exit 0
}

cmd_open() {
  local worktree="${1:-}"
  if [[ -z "$worktree" ]]; then
    fail BAD_ARGS "usage: review.sh open <worktree>"
  fi
  resolve_repo
  if [[ ! -d "$worktree" ]]; then
    fail NO_SUCH_WORKTREE "$worktree is not a directory — re-run discover (a missing deliverable needs its worktree re-added first)"
  fi

  local difftool_cmd="cd $(shq "$worktree") && git difftool -d $(shq "$trunk")...HEAD"

  # --- editor: absent -> detect (nvim, then vscode), pinned -> loud fail, none -> opt out ---
  local editor probe_detail=""
  if ! editor="$(read_config_key editor)"; then
    fail UNKNOWN_VALUE "multiple conflicting editor values in .orca/config.json — fix with orca:config"
  fi
  case "$editor" in
    nvim|vscode|none|"") ;;
    *) fail UNKNOWN_VALUE "editor=$editor — allowed values: nvim, vscode, none (orca:config)" ;;
  esac

  if [[ "$editor" == "none" ]]; then
    print_only EDITOR_NONE "editor=none — the user reviews their own way" "$difftool_cmd"
  fi

  local resolved
  if [[ -n "$editor" ]]; then
    resolved="$editor"
    if [[ "$editor" == "nvim" ]]; then
      probe_nvim || fail PINNED_PROBE_FAILED "editor=nvim pinned but $probe_detail — orca:doctor prescribes the fix"
    else
      probe_vscode || fail PINNED_PROBE_FAILED "editor=vscode pinned but $probe_detail — orca:doctor prescribes the fix"
    fi
  elif probe_nvim; then
    resolved="nvim"
  else
    printf 'PROBE_FAILED:\tnvim\t%s\n' "$probe_detail"
    if probe_vscode; then
      resolved="vscode"
    else
      printf 'PROBE_FAILED:\tvscode\t%s\n' "$probe_detail"
      print_only NO_EDITOR "no usable editor detected — orca:doctor prescribes the installs" "$difftool_cmd"
    fi
  fi

  local nvim_cmd="cd $(shq "$worktree") && nvim \"+OrcaReview\""

  if [[ "$resolved" == "nvim" ]]; then
    # --- terminal: consulted only for nvim — the vscode launch is a detached GUI ---
    local terminal
    if ! terminal="$(read_config_key terminal)"; then
      fail UNKNOWN_VALUE "multiple conflicting terminal values in .orca/config.json — fix with orca:config"
    fi
    case "$terminal" in
      tmux|none|"") ;;
      *) fail UNKNOWN_VALUE "terminal=$terminal — allowed values: tmux, none (orca:config)" ;;
    esac
    if [[ "$terminal" == "none" ]]; then
      print_only TERMINAL_NONE "terminal=none — printing the command instead" "$nvim_cmd"
    fi
    if [[ -z "${TMUX:-}" ]]; then
      if [[ "$terminal" == "tmux" ]]; then
        fail PINNED_TERMINAL_UNSET "terminal=tmux pinned but \$TMUX is unset — start claude inside tmux, or unpin terminal via orca:config"
      fi
      print_only NO_TMUX "nvim usable but \$TMUX is unset — no tmux session to open a window in" "$nvim_cmd"
    fi
    # New window in the session $TMUX points at, focused, worktree as cwd;
    # its lifetime is nvim's — :qa destroys it and tmux's MRU stack lands
    # the user back where they invoked the skill. The per-window
    # remain-on-exit off only guards users who set it on globally.
    local win
    if ! win="$(tmux new-window -P -F '#{window_id}' -n review -c "$worktree" 'nvim "+OrcaReview"' 2>/dev/null)"; then
      print_only TMUX_LAUNCH_FAILED "tmux new-window failed" "$nvim_cmd"
    fi
    tmux set-option -w -t "$win" remain-on-exit off 2>/dev/null || true
    printf 'OPEN:\tnvim-tmux\t%s\n' "$win"
    exit 0
  fi

  # vscode — the extension owns window targeting and defaults the range to
  # <trunk>...HEAD; no VS Code running is the same path, --open-url launches it.
  if code --open-url "vscode://miguelnjacinto.orca-vscode/review?worktree=$(urlencode "$worktree")" >/dev/null 2>&1; then
    printf 'OPEN:\tvscode\t%s\n' "$worktree"
    exit 0
  fi
  print_only VSCODE_LAUNCH_FAILED "code --open-url failed — after opening, run \"Orca: Review\" from the palette" "cd $(shq "$worktree") && code ."
}

# Machine-level, deliberately outside resolve_repo: the probes are what
# orca:doctor's install checks run, machine-only mode included.
cmd_probe() {
  local tier="${1:-}" probe_detail=""
  case "$tier" in
    nvim)   probe_nvim   && { printf 'PROBE_OK:\tnvim\n'; exit 0; } ;;
    vscode) probe_vscode && { printf 'PROBE_OK:\tvscode\n'; exit 0; } ;;
    *)      fail BAD_ARGS "usage: review.sh probe <nvim|vscode>" ;;
  esac
  printf 'PROBE_FAILED:\t%s\t%s\n' "$tier" "$probe_detail"
  exit 1
}

case "${1:-}" in
  discover) cmd_discover ;;
  open)     shift; cmd_open "$@" ;;
  probe)    shift; cmd_probe "$@" ;;
  *)        fail BAD_ARGS "usage: review.sh discover | review.sh open <worktree> | review.sh probe <nvim|vscode>" ;;
esac
