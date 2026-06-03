---
name: specify
description: Turn a rough or generic idea into a thorough high-level specification saved as a Markdown file under `.specs/`. Use when Claude should clarify the problem, goals, users, scope, constraints, expected behavior, success criteria, risks, and open questions before planning or implementation; especially before using `planify` and `implementify`. Do not use for low-level implementation plans, file-by-file designs, code architecture, or task execution.
args: <idea>
user-invocable: true
---

# Specify

## Overview

Create a high-level specification from an idea before detailed planning begins. Keep the output focused on the problem and desired product behavior, not implementation mechanics.

## Input

The user provides a rough idea, usually by invoking `$specify` with a short objective.

If no idea is provided, ask what they want specified.

Ask one or two clarifying questions only when the missing answer would materially change the spec. Otherwise, proceed with explicit assumptions and list them in the spec.

## Step 1: Understand the idea

Restate the idea as a problem to solve. Identify:

- The target user or operator.
- The problem, need, or opportunity.
- The desired outcome.
- The boundaries of what is in and out of scope.
- The assumptions needed to make progress.

If the idea relates to an existing codebase, do only light context gathering. Read enough to understand the product area and vocabulary, but do not design implementation details.

## Step 2: Write at the right altitude

The spec should be high-level and thorough.

Include:

- User-facing goals and outcomes.
- Primary use cases or workflows.
- Functional requirements expressed as capabilities.
- Non-functional expectations such as reliability, privacy, accessibility, performance, or operability when relevant.
- Key domain concepts and data at a business level.
- Non-goals and scope exclusions.
- Success criteria that would let `planify` create phases.
- Risks, tradeoffs, and open questions.

Avoid:

- File paths, class names, function names, package choices, database schemas, migration steps, or API signatures unless the user explicitly asked for them.
- Task checkboxes, phase breakdowns, sprint plans, or execution instructions. Those belong in `planify`.
- Implementation commitments that require codebase research to verify.

## Step 3: Save the spec file

Save the spec to `.specs/` in the current working directory.

Use this filename format:

```text
YYYYMMDD-HHMMSS-<slug>.md
```

- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description derived from the idea, 3-5 words max.
- Create the `.specs/` directory if it does not exist.

Use this structure:

```markdown
# Spec: <idea summary>

**Created:** <YYYY-MM-DD HH:MM>
**Status:** draft

## Summary

<One to three paragraphs describing the idea, problem, and desired outcome.>

## Problem

<The problem or opportunity in plain language.>

## Users

- <Primary user or role and their need>

## Goals

- <Outcome the solution should achieve>

## Non-goals

- <Explicitly excluded scope>

## Core Use Cases

### <Use case title>

<High-level narrative of what the user needs to do and why.>

## Requirements

### Functional

- <Capability or behavior, implementation-agnostic>

### Non-functional

- <Quality expectation or constraint>

## Domain Concepts

- **<Concept>:** <Business-level definition>

## Assumptions

- <Assumption made to proceed>

## Success Criteria

- <Observable condition that shows the spec's intent is satisfied>

## Risks & Open Questions

- <Risk, uncertainty, or decision still needed>
```

Omit empty optional sections only when they are clearly irrelevant. Keep `Risks & Open Questions` even if it is short.

## Step 4: Present the spec

After saving the file:

- Tell the user the spec path.
- Summarize the main scope and any important assumptions.
- Recommend the next step: run `$planify <spec-path>` to convert the spec into an execution plan, then `$implementify <plan-path>` when they are ready to implement.

Do not start planning or implementation unless the user explicitly asks.
