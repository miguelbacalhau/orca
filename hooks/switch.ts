// The switch hook: approves the main session's move into the worktree of the
// objective it has claimed, so an objective started from a worktree goes on
// without a permission ask at every `EnterWorktree`.
//
// It answers one event, `classic.PermissionRequest`, and allows exactly one
// call: `EnterWorktree({ path })` from the main thread, where
//   - `path` is absolute, has no `.`/`..` segment, and its last segment starts
//     `orca-` (the pin hook's shape check, ./pin.ts);
//   - the session's directory is under the directory that holds `path` — the
//     repository root — but is not the root itself, nor under its `.orca` or
//     `.bare`: a root session never moves, since it would lose `.orca/`;
//   - an objective under `<root>/.orca/objectives` is claimed by this session
//     (its `owner` file names the session id), is neither archived nor being
//     archived, and names `path` on its `objective.md` header's
//     `**Worktree:**` line.
//
// Anything else is passed on with `next(e)`: the hook never denies, so a call
// it does not recognize is the person's to answer, as it would be without it.
// A read that fails is a decline, and the registration's `.catch` passes the
// event on. `ExitWorktree` raises no permission request and needs nothing.

import type { EngineInterface, Register } from 'claude-code'

import { objectiveWorktree, ownerSession } from './derive-objective'
import { normalizePath, parentOf, worktreePath } from './pin'
import { listNames, readCached } from './read-cache'

export const ENTER_TOOL = 'EnterWorktree'

const OBJECTIVE_NAME = /^\d{8}-\d{6}-[a-z0-9]+(-[a-z0-9]+)*$/

function isUnder(path: string, dir: string): boolean {
  return path === dir || path.startsWith(dir === '/' ? '/' : `${dir}/`)
}

// The worktree an `EnterWorktree` input names, by shape alone; null for any
// other input.
export function enterPath(toolInput: unknown): string | null {
  if (typeof toolInput !== 'object' || toolInput === null) return null
  const path = (toolInput as { path?: unknown }).path
  return typeof path === 'string' ? worktreePath(path) : null
}

// Whether a session standing in `cwd` may be moved into `worktree` at all: it
// stands under the worktree's repository root, and not at the root, in its
// `.orca`, or in its `.bare`.
export function standsInAWorktree(cwd: string, worktree: string): boolean {
  if (!cwd.startsWith('/')) return false
  const root = parentOf(worktree)
  const here = normalizePath(cwd)
  if (root === '/' || !isUnder(here, root) || here === root) return false
  return !isUnder(here, `${root}/.orca`) && !isUnder(here, `${root}/.bare`)
}

// Whether an objective of the repository that holds `worktree` is claimed by
// `sessionId`, is not archived, and names `worktree` as its own.
async function claimsWorktree($: EngineInterface, worktree: string, sessionId: string): Promise<boolean> {
  const root = `${parentOf(worktree)}/.orca/objectives`
  for (const entry of await listNames($, root)) {
    if (!OBJECTIVE_NAME.test(entry.name)) continue
    const dir = `${root}/${entry.name}`
    const owner = await readCached($, `${dir}/owner`)
    if (owner.status !== 'ok' || ownerSession(owner.text) !== sessionId) continue
    const names = (await listNames($, dir)).map(f => f.name)
    if (!names.includes('objective.md') || names.includes('archived') || names.includes('archiving')) continue
    const objective = await readCached($, `${dir}/objective.md`)
    if (objective.status !== 'ok') continue
    const named = objectiveWorktree(objective.text)
    if (named !== null && named.startsWith('/') && normalizePath(named) === worktree) return true
  }
  return false
}

export const register: Register = on => {
  // The module's one classic.PermissionRequest hook.
  on('classic.PermissionRequest', async ($, e, next) => {
    if (e.tool_name !== ENTER_TOOL || e.agent_id !== undefined) return next(e)
    const worktree = enterPath(e.tool_input)
    if (worktree === null) return next(e)
    if (typeof e.cwd !== 'string' || !standsInAWorktree(e.cwd, worktree)) return next(e)
    if (typeof e.session_id !== 'string' || e.session_id === '') return next(e)
    if (!(await claimsWorktree($, worktree, e.session_id))) return next(e)
    return { decision: { behavior: 'allow' } }
  }).catch(($, e, next) => next(e))
}
