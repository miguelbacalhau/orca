---
name: reviewify
description: Perform a code-review style PR analysis of repository changes. Use when Claude should inspect staged changes first, or all unstaged/untracked changes when nothing is staged, and report bugs, risks, standards issues, best-practice concerns, tests, and project-fit feedback without editing files.
user-invocable: true
---

# Code Review

Review repository changes with a PR-review stance. Prioritize correctness, regressions, maintainability, and fit with the existing project.

## Scope

Determine the review scope before inspecting details:

1. Run `git status --short`.
2. Run `git diff --staged --name-only`.
3. If staged files exist, review only staged changes with `git diff --staged`.
4. If no staged files exist, review all working tree changes:
   - Use `git diff` for tracked files.
   - Use `git ls-files --others --exclude-standard` to find untracked files.
   - Read untracked files directly when they are relevant to the change.

If staged changes exist and there are also unstaged changes, mention that the review is limited to staged changes.

If there are no staged, unstaged, or untracked changes, stop and tell the user there is nothing to review.

## Review Workflow

Gather enough context to judge the diff in the project:

- Inspect the changed files and nearby code, not just isolated diff hunks.
- Identify the feature or fix intent from filenames, tests, commit context, branch name, or surrounding code.
- Check project conventions before calling something a style issue.
- Look for missing or insufficient tests based on the risk of the change.
- Run lightweight verification only when it is directly useful and unlikely to be expensive. If verification is skipped, say so.

Focus on:

- Bugs, runtime errors, incorrect edge-case handling, data loss, security issues, race conditions, and broken contracts.
- Behavioral regressions and compatibility breaks.
- Missing validation, error handling, cleanup, migrations, or rollback paths.
- Test gaps, including missing negative cases and integration coverage.
- Best-practice and standard violations that matter for this codebase.
- Current and future fit: whether the change aligns with existing architecture, naming, boundaries, extensibility, and operational expectations.

Do not rewrite the code or apply fixes unless the user explicitly asks for implementation.

## Output

Lead with findings, ordered by severity.

For each finding, include:

- Severity: `Critical`, `High`, `Medium`, or `Low`.
- File and line reference when possible.
- The concrete problem and why it matters.
- A specific remediation direction.

Use this shape:

```markdown
**Findings**
- `High` [path/to/file.ext](/abs/path/path/to/file.ext:42): The change ...

**Open Questions**
- ...

**PR Fit**
- ...

**Tests**
- ...
```

If there are no findings, say so clearly. Still mention meaningful test gaps or residual risk.

Keep summaries secondary and brief. Avoid praising the change generally; make the review useful and specific.
