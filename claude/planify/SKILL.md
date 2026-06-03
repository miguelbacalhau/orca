---
name: planify
description: Create a structured, phase-based plan for a given objective or high-level spec file and save it locally. Use when Claude needs to break a goal, `.specs/` Markdown spec, or requirements summary into logical phases, tasks, acceptance criteria, risks, and open questions before execution.
args: <objective-or-spec-file>
user-invocable: true
---

# Breakdown

Create a structured, phase-based plan for a given objective or high-level spec and save it locally.

## Input

The user provides a plan objective or a spec file path, usually by invoking `$planify` with the objective or a `.specs/` Markdown file created by `$specify`.

If no objective is provided, ask the user what they want to plan.

If the input is a file path, read the file first and use it as the source objective. Treat high-level spec sections such as goals, non-goals, requirements, assumptions, success criteria, risks, and open questions as planning constraints.

## Step 1: Understand the objective

Read the objective or spec carefully. If it is ambiguous or too broad, ask one or two clarifying questions before proceeding. Consider:

- What is the desired end state?
- What are the key constraints or requirements?
- What is the scope: single session task, multi-day effort, or larger project?

## Step 2: Research

Before writing the plan, gather context:

- Explore the codebase if the objective relates to code changes.
- Identify existing patterns, conventions, and architecture.
- Note dependencies, blockers, or risks.

Skip this step if the objective is not related to the current codebase.

## Step 3: Break down into phases

Organize the work into logical phases. Each phase should be a coherent unit of work that can be completed and verified independently.

Use this phase format:

```markdown
## Phase N: <short title>

**Goal:** One sentence describing what this phase achieves.

### Tasks

- [ ] Task description
- [ ] Task description

### Acceptance criteria

- Criterion that proves this phase is done
```

Guidelines for phases:

- Order phases so each builds on the previous one.
- Keep phases small enough to be actionable and large enough to be meaningful.
- Put setup, research, or foundational work early.
- Put integration, testing, and polish later.
- Give each phase clear acceptance criteria.
- Aim for 2-6 phases depending on complexity.

## Step 4: Write the plan file

Save the plan to `.plans/` in the current working directory.

Use this filename format:

```text
YYYYMMDD-HHMMSS-<slug>.md
```

- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description derived from the objective, 3-5 words max.
- Example: `20260303-143022-add-auth-flow.md`.

Use this file structure:

```markdown
# Plan: <objective summary>

**Created:** <YYYY-MM-DD HH:MM>
**Status:** draft

## Overview

<Brief description of what this plan aims to accomplish and why.>

## Phase 1: <title>

**Goal:** ...

### Tasks

- [ ] ...

### Acceptance criteria

- ...

## Phase 2: <title>

...

## Risks & open questions

- Any known risks, unknowns, or decisions that need to be made along the way
```

Rules:

- Create the `.plans/` directory if it does not exist.
- Set the status to `draft`.
- Keep the overview concise, 2-4 sentences.
- Use checkbox syntax (`- [ ]`) for tasks so progress can be tracked.
- Include a final `Risks & open questions` section even if it is short.

## Step 5: Present the plan

After saving the file, display the plan to the user and tell them the file path. Ask if they want to adjust anything before starting execution.

Do not begin executing the plan unless the user explicitly asks to proceed.
