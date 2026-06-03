---
name: implementify
description: Execute a plan file phase by phase, writing clean functional code with small focused functions and descriptive intermediate variables. Use when Claude should implement the next incomplete phase from a local plan file, verify it, update the plan, and stop for confirmation before continuing.
args: <plan-file>
user-invocable: true
---

# Implement

Execute a plan file phase by phase, writing clean, well-structured code.

## Input

The user provides a plan file path, usually by invoking `$implementify` with the plan file path.

If no plan file is provided, look for plan files in `.plans/` and ask the user which one to implement. If no plans exist, tell the user to create one first, for example with `$planify`.

## Step 1: Read and understand the plan

Read the plan file and understand:

- The overall objective.
- The phases and their order.
- The tasks within each phase.
- The acceptance criteria for each phase.

Identify the first phase that has incomplete tasks using unchecked checkboxes. Work only on that phase. If all phases are complete, inform the user the plan is fully implemented.

## Step 2: Research before coding

Before writing code for the current phase:

- Read relevant existing files to understand current patterns and conventions.
- Identify where new code should live and what it should integrate with.
- Note any dependencies the phase requires.

## Step 3: Implement the phase

Work through each task in the current phase. Follow these coding principles strictly.

### Prefer functional style

- Favor pure functions over classes and mutable state.
- Use `map`, `filter`, `reduce`, and other higher-order functions when they improve clarity.
- Avoid side effects where possible; isolate them at the edges of the system.
- Prefer immutable data by creating new values instead of mutating existing ones.
- Use function composition to build complex behavior from simple pieces.

### Write small, focused functions

- Make each function do one thing well.
- Split functions longer than about 15-20 lines when they are doing too much.
- Name functions after what they return or what effect they perform, such as `parseConfig`, `buildUserQuery`, or `formatOutput`.
- Prefer extracting a named function over writing inline anonymous logic when the logic is non-trivial.
- Give functions clear inputs and outputs; avoid relying on external mutable state.

### Use descriptive intermediate variables

- Break complex expressions into steps using well-named intermediate variables.
- Make variable names explain the value's purpose without needing a comment.
- Prefer `const activeUsers = users.filter(u => u.isActive)` over inlining the filter inside a larger expression.
- Use intermediate variables to document the "what" at each step of a transformation pipeline.
- Break operation chains when an intermediate result has a meaningful name that aids understanding.

Bad:

```js
return data.filter(x => x.status === 'active' && x.role !== 'admin').map(x => ({ ...x, displayName: `${x.first} ${x.last}` })).sort((a, b) => a.displayName.localeCompare(b.displayName))
```

Good:

```js
const activeNonAdmins = data.filter(x => x.status === 'active' && x.role !== 'admin')
const withDisplayNames = activeNonAdmins.map(x => ({ ...x, displayName: `${x.first} ${x.last}` }))
const sorted = withDisplayNames.sort((a, b) => a.displayName.localeCompare(b.displayName))
return sorted
```

### Frontend components

When working with React, Vue, Svelte, or other component-based frameworks:

- Break components into small, focused units with a single clear responsibility.
- Extract distinct pieces of UI or behavior into their own components.
- Separate logic from presentation using hooks, composables, or equivalent patterns.
- Split components that handle both data fetching and rendering into container and presentational pieces when appropriate.
- Keep components easy to reason about from their name and props.
- Prefer composition over prop drilling by passing children or using slots.

### General code quality

- Follow the existing conventions of the codebase, including naming, file structure, and formatting.
- Avoid unnecessary error handling, comments, or abstractions.
- Write code that is correct and readable without over-engineering.

## Step 4: Verify the phase

After completing all tasks in the phase:

- Run relevant tests, linters, or build steps.
- Check the acceptance criteria for the phase.
- Fix failures before moving on.

## Step 5: Update the plan

Mark completed tasks and update the plan file:

- Check off completed tasks with `- [x]`.
- If the phase is fully done, note it in the plan, such as by changing the phase heading or adding a status note.
- Save the updated plan file.

## Step 6: Report and continue

Tell the user:

- What was implemented in this phase.
- Whether all acceptance criteria were met.
- What the next phase is, if any.

Ask the user if they want to proceed to the next phase. Do not continue automatically; wait for confirmation.

## Guidelines

- Work on one phase at a time. Do not skip ahead or combine phases.
- If a task is ambiguous, ask the user for clarification before implementing.
- If a task turns out to be unnecessary or wrong, flag it to the user instead of silently skipping it.
- Keep commits granular; commit after each phase if the user has not asked you to commit earlier.
- If the plan needs to change based on what you learn during implementation, propose the change to the user before modifying the plan.
