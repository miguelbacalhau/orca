#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install-claude-skills.sh [options]

Symlink all skills from ./claude into the Claude skills directory.

Options:
  --target DIR   Install links into DIR instead of $HOME/.claude/skills
  --force        Replace existing targets that are not the desired symlink
  --dry-run      Print actions without changing the filesystem
  -h, --help     Show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$script_dir/claude" ]]; then
  repo_root="$script_dir"
elif [[ -d "$script_dir/../claude" ]]; then
  repo_root="$(cd "$script_dir/.." && pwd)"
else
  repo_root="$script_dir"
fi

source_dir="$repo_root/claude"
target_dir="$HOME/.claude/skills"
force=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      if [[ $# -lt 2 ]]; then
        echo "error: --target requires a directory" >&2
        exit 2
      fi
      target_dir="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run() {
  if [[ "$dry_run" == true ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

same_link_target() {
  local link_path="$1"
  local expected_target="$2"

  [[ -L "$link_path" ]] || return 1
  [[ "$(readlink "$link_path")" == "$expected_target" ]]
}

if [[ ! -d "$source_dir" ]]; then
  echo "error: source directory not found: $source_dir" >&2
  echo "hint: run this script from the skills repo, or keep it next to the claude/ directory" >&2
  exit 1
fi

shopt -s nullglob
skill_dirs=("$source_dir"/*)

if [[ ${#skill_dirs[@]} -eq 0 ]]; then
  echo "error: no skills found in $source_dir" >&2
  exit 1
fi

run mkdir -p "$target_dir"

for skill_dir in "${skill_dirs[@]}"; do
  [[ -d "$skill_dir" ]] || continue

  skill_name="$(basename "$skill_dir")"
  link_path="$target_dir/$skill_name"

  if same_link_target "$link_path" "$skill_dir"; then
    echo "ok: $skill_name already linked"
    continue
  fi

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ "$force" != true ]]; then
      echo "skip: $link_path already exists; rerun with --force to replace it" >&2
      continue
    fi

    run rm -rf "$link_path"
  fi

  run ln -s "$skill_dir" "$link_path"
  if [[ "$dry_run" == true ]]; then
    echo "would link: $link_path -> $skill_dir"
  else
    echo "linked: $link_path -> $skill_dir"
  fi
done
