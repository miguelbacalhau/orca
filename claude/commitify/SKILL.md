---
name: commitify
description: Create git commits following the Conventional Commits specification. Use when Claude should inspect repository changes, stage appropriate files, generate a Conventional Commit message, commit locally, and confirm the resulting git status.
user-invocable: true
---

# Git Commit

Create a git commit following the Conventional Commits specification.

## Step 1: Inspect

Run these commands in parallel to understand the current state:

```bash
git status
git diff
git diff --staged
git log --oneline -5
```

If there are no changes, including no untracked files and no modifications, stop and inform the user there is nothing to commit.

## Step 2: Stage

Stage files for commit:

- Prefer staging specific files by name, such as `git add <file>...`, over `git add -A` or `git add .`.
- Never stage files that likely contain secrets, such as `.env`, credentials, API keys, or tokens.
- Never stage large binaries unless the user explicitly requests it.
- If all changes are already staged, skip this step.
- Include any plan files that were created during the session, such as files in `.plans/`.
- If unsure which files to include, ask the user.

## Step 3: Analyze

Review the staged diff with `git diff --staged` and determine:

- What changed: new feature, bug fix, refactor, documentation, and so on.
- Why it changed: the purpose, not just a restatement of the diff.
- Scope of the change: the module, component, or area of the codebase.
- Whether the change introduces a breaking change to a public API.

## Step 4: Generate commit message

Build a commit message following Conventional Commits.

Format:

```text
<type>(<optional scope>): <description>

[optional body]

[optional footer(s)]
```

Types:

| Type | When to use |
| --- | --- |
| `feat` | A new feature |
| `fix` | A bug fix |
| `docs` | Documentation only changes |
| `style` | Formatting, whitespace, semicolons, not CSS changes |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | A code change that improves performance |
| `test` | Adding or updating tests |
| `build` | Changes to build system or external dependencies |
| `ci` | Changes to CI configuration files and scripts |
| `chore` | Other changes that do not modify src or test files |
| `revert` | Reverts a previous commit |

Scope is optional. Use a noun describing the affected section of the codebase, such as `feat(auth):`, `fix(api):`, or `docs(readme):`.

Description rules:

- Use imperative, present tense: `add`, not `added` or `adds`.
- Do not capitalize the first letter.
- Do not end with a period.
- Keep it under 70 characters.

Body rules:

- Explain what and why rather than how.
- Wrap at 72 characters.
- Separate the body from the subject with a blank line.
- Use the body when the subject alone does not capture the full context, the change has non-obvious side effects, or important motivation should be recorded.

Footer rules:

- For breaking changes, start with `BREAKING CHANGE: ` followed by what broke and migration steps. Alternatively, append `!` after the type or scope, such as `feat(api)!: remove legacy endpoint`.
- For issue references, use forms like `Closes #123` or `Fixes #456`.

Examples:

```text
feat(auth): add OAuth2 login support
```

```text
fix(parser): handle empty input without crashing

Previously the parser threw a NullPointerException when given an empty
string. Now it returns an empty result set instead.
```

```text
feat(api)!: remove v1 endpoints

BREAKING CHANGE: All /api/v1/* endpoints have been removed.
Consumers must migrate to /api/v2/*.
```

## Step 5: Commit

Execute the commit using a command that preserves formatting, such as:

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <description>

<body>

<footer>
EOF
)"
```

After committing, run `git status` to confirm the commit succeeded.

## Guidelines

- Do not amend existing commits unless the user explicitly asks.
- Do not push to a remote unless the user explicitly asks.
- If a pre-commit hook fails, diagnose the issue, fix it, re-stage, and create a new commit instead of amending.
- When in doubt about what to include or how to describe the change, ask the user.
