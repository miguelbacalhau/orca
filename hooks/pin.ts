// The pin hook: starts orca's stage agents in the worktree their task message
// names, whatever directory the session itself was started in.
//
// It acts on spawns of the agent types in PINNED and nothing else. Each type
// is pinned by its own label, read from the task message's leading block of
// `Label: value` lines:
//
//   Worktree:              implement, fix, commit, review-*, and the
//                          objective's implementer, verifier, planner,
//                          provisioner, reviewers, and the address agent
//   Integration worktree:  merge, integrate, plan
//   Review worktree:       spec-review-*
//
// The three labels are frozen: the work loop, the spec workflow, and the
// skills compose them, and a rename would silently unpin (tests/work-loop.bats
// greps the composers for them). The path on the line is data, not trust: it
// is pinned only when it is absolute, has no `.`/`..` segment, its last
// segment starts `orca-`, and the directory beside it holds `.orca`.
//
// How an agent is pinned depends on what starts it:
//   - an Agent-tool spawn runs in the worktree: the spawn's `cwd` is rewritten;
//   - a workflow agent's `cwd` does not apply, so it is bound by the id
//     `next(e)` answers, and its Bash commands start with a `cd` into the
//     worktree, its Glob and Grep search there by default;
//   - either kind may not edit a file under the repository root that is
//     outside its worktree and outside `.orca/`.
//
// A workflow agent restarted after a stall gets a new id that `agent.spawn`
// never raises, so nothing names its worktree. One is recognized when a loop
// of a pinned workflow type starts (`tool.offer`, `classic.SubagentStart`)
// under an id no spawn answered, and it is blocked: its writing tools and its
// StructuredOutput are denied, so the script's `agent()` call fails as an
// agent error.
//
// The hook fails open. Every registration's `.catch` passes the event on, a
// line that fails the check leaves the agent unpinned, and no spawn is ever
// denied here. A session without this hook runs agents as before: their own
// instructions and `git -C <worktree>` calls keep them in place.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { OrcaPin } from '../types'

export const WORKTREE = 'Worktree'
export const INTEGRATION_WORKTREE = 'Integration worktree'
export const REVIEW_WORKTREE = 'Review worktree'

// The exit status of a command whose `cd` into the worktree failed.
export const CD_FAILED_EXIT = 97

export type PinRule = {
  // The label of the task-message line that names the worktree.
  label: string
  // Started by a workflow script's agent() (bound by id), not the Agent tool.
  workflow: boolean
}

const workflowAgent = (label: string): PinRule => ({ label, workflow: true })
const toolAgent = (label: string): PinRule => ({ label, workflow: false })

// Every agent type the hook pins. A type that is not here is never pinned:
// orca:spec, orca:research, orca:council*, orca:audit, orca:doctor and
// orca:objective-open work across directories, and some of their prompts
// quote the user's own text.
export const PINNED: Readonly<Record<string, PinRule>> = {
  'orca:implement': workflowAgent(WORKTREE),
  'orca:fix': workflowAgent(WORKTREE),
  'orca:commit': workflowAgent(WORKTREE),
  'orca:review-codex': workflowAgent(WORKTREE),
  'orca:review-claude': workflowAgent(WORKTREE),
  'orca:merge': workflowAgent(INTEGRATION_WORKTREE),
  'orca:integrate': workflowAgent(INTEGRATION_WORKTREE),
  'orca:plan': workflowAgent(INTEGRATION_WORKTREE),
  'orca:spec-review-codex': workflowAgent(REVIEW_WORKTREE),
  'orca:spec-review-claude': workflowAgent(REVIEW_WORKTREE),
  'orca:objective-implement': toolAgent(WORKTREE),
  'orca:objective-verify': toolAgent(WORKTREE),
  'orca:phases': toolAgent(WORKTREE),
  'orca:provision': toolAgent(WORKTREE),
  'orca:objective-review-codex': toolAgent(WORKTREE),
  'orca:objective-review-claude': toolAgent(WORKTREE),
  'orca:phases-review-codex': toolAgent(WORKTREE),
  'orca:phases-review-claude': toolAgent(WORKTREE),
  'orca:address': toolAgent(WORKTREE),
}

// What a blocked agent may not call: the tools that write, and the tool that
// returns a schema'd result.
export const BLOCKED_TOOLS: readonly string[] = ['Bash', 'Edit', 'Write', 'NotebookEdit', 'StructuredOutput']

export const UNBOUND_DENIAL =
  'orca could not bind this agent to its worktree: it was started again after a stall, and nothing names the worktree it belongs to. It must not change files or report a result. Stop here; the stage fails and is handled as an agent error.'

function ruleFor(subagentType: string): PinRule | undefined {
  return Object.prototype.hasOwnProperty.call(PINNED, subagentType) ? PINNED[subagentType] : undefined
}

// ---------- the line ----------

// A header line may carry no value (`Owned files: ` for an item that owns none).
const HEADER_LINE = /^([A-Z][A-Za-z -]{0,40}):(?: (.*))?$/

// The path on the type's own line, when that line stands in the task message's
// leading block of `Label: value` lines. The block ends at the first line of
// any other shape, so a label quoted further down (a user's idea, a finding's
// text) is never read. null when the type is not pinned or has no such line.
export function worktreeLine(subagentType: string, prompt: string): string | null {
  const rule = ruleFor(subagentType)
  if (!rule) return null
  const lines = prompt.split('\n')
  let i = 0
  while (i < lines.length && (lines[i] as string).trim() === '') i++
  for (; i < lines.length; i++) {
    const match = HEADER_LINE.exec((lines[i] as string).replace(/\s+$/, ''))
    if (!match) return null
    if (match[1] === rule.label) return (match[2] ?? '').trim()
  }
  return null
}

// The path a line may pin, by shape alone: absolute, no empty, `.` or `..`
// segment, and a last segment that starts `orca-`. Returns it without a
// trailing slash, or null.
export function worktreePath(value: string): string | null {
  const path = value.length > 1 ? value.replace(/\/+$/, '') : value
  if (!path.startsWith('/')) return null
  const segments = path.slice(1).split('/')
  if (segments.some(s => s === '' || s === '.' || s === '..')) return null
  if (!(segments[segments.length - 1] as string).startsWith('orca-')) return null
  if (segments.length < 2) return null
  return path
}

export function parentOf(path: string): string {
  const cut = path.lastIndexOf('/')
  return cut <= 0 ? '/' : path.slice(0, cut)
}

// The worktree a line's value names, checked: the shape above, and a `.orca`
// in the directory that holds it. null when it fails either, and when the
// lookup itself fails: the agent is then left unpinned, never unknown.
async function checkedWorktree($: EngineInterface, value: string): Promise<string | null> {
  const path = worktreePath(value)
  if (path === null) return null
  try { return (await $.fs.exists(`${parentOf(path)}/.orca`)) ? path : null }
  catch { return null }
}

// ---------- paths and commands ----------

// An absolute path with `.`, `..` and empty segments folded away. Symbolic
// links are not followed.
export function normalizePath(path: string): string {
  const out: string[] = []
  for (const segment of path.split('/')) {
    if (segment === '' || segment === '.') continue
    if (segment === '..') out.pop()
    else out.push(segment)
  }
  return `/${out.join('/')}`
}

// A tool's path argument as the absolute path it means for an agent in
// `worktree`.
export function resolveIn(worktree: string, path: string): string {
  return normalizePath(path.startsWith('/') ? path : `${worktree}/${path}`)
}

function isUnder(path: string, dir: string): boolean {
  return path === dir || path.startsWith(dir === '/' ? '/' : `${dir}/`)
}

// Why an agent bound to `worktree` may not edit `path`, or null when it may:
// its own worktree, the repository's `.orca/`, and anything outside the
// repository are allowed; everything else under the repository root is not.
export function editDenial(worktree: string, path: string): string | null {
  const root = parentOf(worktree)
  const target = resolveIn(worktree, path)
  if (!isUnder(target, root)) return null
  if (isUnder(target, worktree) || isUnder(target, `${root}/.orca`)) return null
  return `orca: this agent works in ${worktree}, and ${target} is outside it. Edit the file at its path under ${worktree}; other checkouts under ${root} are not this agent's to change.`
}

export function shellQuote(text: string): string {
  return `'${text.replace(/'/g, `'\\''`)}'`
}

// `||`, not `&&`: in `cd … && a || b`, `b` would run where the cd failed.
export function pinnedCommand(worktree: string, command: string): string {
  return `cd ${shellQuote(worktree)} || exit ${CD_FAILED_EXIT}\n${command}`
}

export function shellNote(worktree: string): string {
  return `orca starts this agent's shell commands in ${worktree}`
}

// ---------- the bindings ----------

// agent id → its pin. Set here synchronously the moment a spawn answers (the
// agent's first tool call can follow at once) and mirrored to $.state, which
// is what a reloaded module starts from.
const pins = new Map<string, OrcaPin>()
let isLoaded = false
// Agents already told where their shell commands start.
const told = new Set<string>()
// Worktree lines already reported as unusable.
const noted = new Set<string>()

const pinsAtom = atom({ plugin: 'orca', key: 'pins' } as const, {})

// What a reload does to this module's own variables; $.state is untouched.
export function forgetPins() {
  pins.clear()
  told.clear()
  noted.clear()
  isLoaded = false
}

async function loadPins($: EngineInterface) {
  if (isLoaded) return
  const stored = await read($, pinsAtom)
  isLoaded = true
  for (const [agentId, pin] of Object.entries(stored ?? {}))
    if (!pins.has(agentId)) pins.set(agentId, pin)
}

async function storePins($: EngineInterface) {
  try { await update($, pinsAtom, () => Object.fromEntries(pins)) }
  catch { /* the module's own map still holds it */ }
}

async function bind($: EngineInterface, agentId: string, pin: OrcaPin) {
  pins.set(agentId, pin)
  await storePins($)
}

// A loop of a known type started. One of a pinned workflow type under an id
// no spawn answered is a restarted agent: blocked.
async function noteLoop($: EngineInterface, agentId: string, subagentType: string) {
  if (!ruleFor(subagentType)?.workflow) return
  await loadPins($)
  if (pins.has(agentId)) return
  await bind($, agentId, { worktree: null, workflow: true, blocked: true })
  try { await $.ui.log(`orca: a restarted ${subagentType} agent (${agentId}) has no worktree binding; its writes and its result are refused`, { to: 'debug' }) }
  catch { /* the block stands without the line */ }
}

// A subagent stopped. A workflow agent is never resumed, so its binding goes;
// an Agent-tool agent's stays for the session, since the objective's
// implementer is continued by message across a whole phase. Called from the
// module's one classic.SubagentStop hook (./relay.ts).
export async function releasePin($: EngineInterface, agentId: string) {
  await loadPins($)
  if (!pins.get(agentId)?.workflow) return
  pins.delete(agentId)
  told.delete(agentId)
  await storePins($)
}

async function noteUnusable($: EngineInterface, subagentType: string, value: string) {
  if (noted.has(value)) return
  noted.add(value)
  try { await $.ui.log(`orca: ${subagentType} is not pinned: ${JSON.stringify(value)} is not an orca worktree under a repository root`, { to: 'debug' }) }
  catch { /* nothing depends on the line */ }
}

// ---------- the hooks ----------

export const register: Register = on => {
  on('agent.spawn', async ($, e, next) => {
    const rule = ruleFor(e.subagentType)
    if (!rule || e.fork) return next(e)
    await loadPins($)

    // A resume already runs where its first spawn was put, and can only be
    // refused here. A binding a reload lost is taken back from its cwd.
    if (e.resume) {
      if (!pins.has(e.resume.agentId) && e.cwd !== undefined) {
        const worktree = await checkedWorktree($, e.cwd)
        if (worktree !== null) await bind($, e.resume.agentId, { worktree, workflow: false })
      }
      return next(e)
    }

    const value = worktreeLine(e.subagentType, e.prompt)
    const worktree = value === null ? null : await checkedWorktree($, value)
    if (value !== null && worktree === null) await noteUnusable($, e.subagentType, value)

    if (e.workflow) {
      const started = await next(e)
      // Nothing may wait between the answer and the binding. An agent whose
      // line could not be used is recorded too, so it is not taken for a restart.
      if (started.agentId !== undefined) await bind($, started.agentId, { worktree, workflow: true })
      return started
    }

    if (worktree === null) return next(e)
    const started = await next({ ...e, cwd: worktree })
    if (started.agentId !== undefined) await bind($, started.agentId, { worktree, workflow: false })
    return started
  }).catch(async ($, e, next) => {
    // Whatever failed above, the spawn goes on. A workflow agent of a pinned
    // type is still recorded as a known first attempt, unpinned, so the loop
    // that follows is not taken for a restart and blocked.
    const started = await next(e)
    if (e.workflow && !e.resume && !e.fork && ruleFor(e.subagentType) && started.agentId !== undefined && !pins.has(started.agentId))
      pins.set(started.agentId, { worktree: null, workflow: true })
    return started
  })

  on('tool.offer', { for: 'list' }, async ($, e, next) => {
    if (e.agentId !== undefined && e.subagentType !== undefined) await noteLoop($, e.agentId, e.subagentType)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('classic.SubagentStart', async ($, e, next) => {
    await noteLoop($, e.agent_id, e.agent_type)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const agentId = e.agentId
    if (agentId === undefined) return next(e)
    await loadPins($)
    const pin = pins.get(agentId)
    if (!pin) return next(e)
    const tool: string = e.tool

    if (pin.blocked) return BLOCKED_TOOLS.includes(tool) ? { deny: UNBOUND_DENIAL } : next(e)
    const worktree = pin.worktree
    if (worktree === null) return next(e)

    if (tool === 'Edit' || tool === 'Write' || tool === 'NotebookEdit') {
      const args = e as { file_path?: unknown; notebook_path?: unknown }
      const path = tool === 'NotebookEdit' ? args.notebook_path : args.file_path
      const denial = typeof path === 'string' && path !== '' ? editDenial(worktree, path) : null
      return denial === null ? next(e) : { deny: denial }
    }

    // An Agent-tool agent's directory is the worktree already.
    if (!pin.workflow) return next(e)

    if (e.tool === 'Bash') {
      const result = await next({ ...e, command: pinnedCommand(worktree, e.command) })
      if (told.has(agentId) || result.deny !== undefined) return result
      told.add(agentId)
      return { ...result, context: [...(result.context ?? []), shellNote(worktree)] }
    }

    // Not every build has these two as tools of their own, so they are read
    // by name and their `path` as data.
    if (tool === 'Glob' || tool === 'Grep') {
      const path = (e as { path?: unknown }).path
      if (path === undefined || path === null || path === '') return next({ ...e, path: worktree } as typeof e)
      if (typeof path !== 'string' || path.startsWith('/') || path.startsWith('~')) return next(e)
      return next({ ...e, path: resolveIn(worktree, path) } as typeof e)
    }

    return next(e)
  }).catch(($, e, next) => next(e))
}
