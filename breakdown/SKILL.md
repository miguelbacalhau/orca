---
name: breakdown
description: Create a structured plan broken into logical phases for a given objective
args: <objective>
user-invocable: true
---

# Breakdown

Create a structured, phase-based plan for a given objective and save it locally.

## Input

The user provides the plan objective as an argument: `/breakdown <objective>`

If no objective is provided, ask the user what they want to plan.

## Step 1 — Understand the objective

Read the objective carefully. If it is ambiguous or too broad, ask one or two clarifying questions before proceeding. Consider:

- What is the desired end state?
- What are the key constraints or requirements?
- What is the scope (is this a single session task, a multi-day effort, a project)?

## Step 2 — Research

Before writing the plan, gather context:

- Explore the codebase if the objective relates to code changes (use Glob, Grep, Read)
- Identify existing patterns, conventions, and architecture
- Note any dependencies, blockers, or risks

Skip this step if the objective is not related to the current codebase.

## Step 3 — Break down into phases

Organize the work into **logical phases**. Each phase should be a coherent unit of work that can be completed and verified independently.

### Phase format

```markdown
## Phase N: <short title>

**Goal:** One sentence describing what this phase achieves.

### Tasks

- [ ] Task description
- [ ] Task description
- [ ] ...

### Acceptance criteria

- Criterion that proves this phase is done
- ...
```

### Guidelines for phases

- Order phases so that each builds on the previous one
- Keep phases small enough to be actionable but large enough to be meaningful
- Early phases should handle setup, research, or foundational work
- Later phases should handle integration, testing, and polish
- Each phase should have clear acceptance criteria so you know when it is done
- Aim for 2–6 phases depending on complexity

## Step 4 — Write the plan file

Save the plan to `.plans/` in the current working directory.

### Filename

Use the format: `YYYYMMDD-HHMMSS-<slug>.md`

- Timestamp comes from the current date and time
- `<slug>` is a short kebab-case description derived from the objective (3–5 words max)
- Example: `20260303-143022-add-auth-flow.md`

### File structure

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

<!-- repeat for each phase -->

## Risks & open questions

- Any known risks, unknowns, or decisions that need to be made along the way
```

### Rules

- Create the `.plans/` directory if it does not exist
- Set the status to `draft`
- Keep the overview concise (2–4 sentences)
- Use checkbox syntax (`- [ ]`) for tasks so progress can be tracked
- Include a final "Risks & open questions" section even if it is short

## Step 5 — Present the plan

After saving the file, display the plan to the user and tell them the file path. Ask if they want to adjust anything before starting execution.

Do **not** begin executing the plan unless the user explicitly asks to proceed.
