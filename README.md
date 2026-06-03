# Agent Skills

A collection of reusable skills for AI agents.

## Skills

| Skill | Description |
|-------|-------------|
| [git-commit](git-commit/SKILL.md) | Create git commits following the [Conventional Commits](https://www.conventionalcommits.org/) spec |
| [breakdown](breakdown/SKILL.md) | Create a structured plan broken into logical phases for a given objective |

## Install Codex Skills

Install the Codex versions into the user skills directory with symlinks:

```bash
./install-codex-skills.sh
```

By default, this links `codex/*` into `$HOME/.agents/skills`.
Use `--dry-run` to preview, `--target DIR` to install elsewhere, and `--force`
to replace existing targets.

Remove the symlinks with:

```bash
./uninstall-codex-skills.sh
```

## Install Claude Skills

Install the Claude versions into the Claude skills directory with symlinks:

```bash
./install-claude-skills.sh
```

By default, this links `claude/*` into `$HOME/.claude/skills`.
Use `--dry-run` to preview, `--target DIR` to install elsewhere, and `--force`
to replace existing targets.

Remove the symlinks with:

```bash
./uninstall-claude-skills.sh
```
