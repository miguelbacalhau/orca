// The objective band: a live view of the objective this session owns, drawn
// above the prompt where the run band draws. A read-only observer — it finds
// the objective whose `owner` file names this session (the claim `objective
// open` writes, from inside orca:worktree), then reads that objective's files
// on a short tick. It writes nothing anywhere but its own $.state.
//
// Ownership is looked up on session.start, on every prompt.submit, and when
// an orca:worktree agent stops — never on the tick — and the match is kept in
// $.state. A run the session launches takes the band over while it is live.
// The band goes on session end, when the objective's directory or this
// session's claim on it disappears, when it is archived, and when it sat idle
// through three of the person's prompts or landed (which needs git, so it is
// asked of the read-only `objective list`).
//
// The derivation itself is pure and lives in ./derive-objective.ts; the
// drawing, and the events both bands hear, are shared with the run band
// (./bands.tsx).

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { OrcaBand, OrcaObjective } from '../types'
import { activePhaseId, deriveObjective, landedIn, objectiveSlug, ownerSession } from './derive-objective'
import type { ObjectiveDerived, ObjectiveFiles } from './derive-objective'
import { listNames, readCached } from './read-cache'

const objectiveAtom = atom({ plugin: 'orca', key: 'objective' } as const, null)
const bandAtom = atom({ plugin: 'orca', key: 'objectiveBand' } as const, null)
const droppedAtom = atom({ plugin: 'orca', key: 'objectiveDropped' } as const, null)
// The run band's run: while one is tracked, the run has the band.
const runAtom = atom({ plugin: 'orca', key: 'run' } as const, null)

const TICK_MS = 1500
// An idle objective (every phase done) that sat through this many of the
// person's own prompts is put down, as the run band does an abandoned spec.
const IDLE_PROMPTS = 3
// How many directories up from the session's cwd .orca/objectives is looked for.
const WALK_DEPTH = 8
const WORKTREE_AGENT = 'orca:worktree'
const LANDED_TIMEOUT_MS = 20_000
const OBJECTIVE_NAME = /^\d{8}-\d{6}-[a-z0-9]+(-[a-z0-9]+)*$/

// Module variables start over on a hot reload; the objective is in $.state.
let ticker: Timer | null = null
let ticking = false
let rootCache: { cwd: string; root: string } | null = null

// The nearest directory at or above the session's cwd that holds
// .orca/objectives: the repository root. Only a find is cached — an
// objective created later is still found.
async function repoRootOf($: EngineInterface): Promise<string | null> {
  const cwd = (await $.session.cwd()).replace(/\/+$/, '') || '/'
  if (rootCache?.cwd === cwd) return rootCache.root
  let dir = cwd
  for (let depth = 0; depth < WALK_DEPTH; depth++) {
    const base = dir === '/' ? '' : dir
    if (await $.fs.exists(`${base}/.orca/objectives`).catch(() => false)) {
      rootCache = { cwd, root: dir }
      return dir
    }
    if (dir === '/') break
    dir = dir.replace(/\/[^/]*$/, '') || '/'
  }
  return null
}

// The objective whose owner names this session, archived ones skipped; the
// most recently claimed should several.
async function findOwned($: EngineInterface, repoRoot: string, sessionId: string): Promise<string | null> {
  const root = `${repoRoot}/.orca/objectives`
  let best: { dir: string; mtimeMs: number } | null = null
  for (const entry of await listNames($, root)) {
    if (!OBJECTIVE_NAME.test(entry.name)) continue
    const dir = `${root}/${entry.name}`
    const owner = await readCached($, `${dir}/owner`)
    if (owner.status !== 'ok' || ownerSession(owner.text) !== sessionId) continue
    if (await $.fs.exists(`${dir}/archived`).catch(() => true)) continue
    if (await $.fs.exists(`${dir}/archiving`).catch(() => true)) continue
    const claimed = (await $.fs.stat(`${dir}/owner`).catch(() => null))?.mtimeMs ?? 0
    if (!best || claimed >= best.mtimeMs) best = { dir, mtimeMs: claimed }
  }
  return best?.dir ?? null
}

// One tick's files; null when the directory is there but could not be
// listed, so a passing hiccup never takes the band down.
async function readObjectiveFiles($: EngineInterface, objective: OrcaObjective): Promise<ObjectiveFiles | null> {
  const { dir } = objective
  const files: ObjectiveFiles = {
    dirExists: true, owner: null, archived: false, decisions: null, phases: null,
    phasesMtimeMs: null, plan: [], report: null, action: null,
  }
  let entries
  try { entries = await $.fs.list(dir) } catch {
    if (await $.fs.exists(dir).catch(() => true)) return null
    files.dirExists = false
    return files
  }
  const named = new Map(entries.map(f => [f.name, f]))
  const text = async (path: string, present: boolean) => {
    if (!present) return null
    const got = await readCached($, `${dir}/${path}`)
    return got.status === 'ok' ? got.text : null
  }
  files.owner = await text('owner', named.has('owner'))
  files.archived = named.has('archived') || named.has('archiving')
  files.decisions = await text('decisions.md', named.has('decisions.md'))
  files.phases = await text('phases.md', named.has('phases.md'))
  files.phasesMtimeMs = named.get('phases.md')?.mtimeMs ?? null
  if (named.has('plan')) files.plan = await listNames($, `${dir}/plan`)
  files.report = await text('report.md', named.has('report.md'))
  const active = activePhaseId(files.phases)
  if (active) files.action = await text(`phases/${active}/action`, named.has('phases'))
  return files
}

async function observe($: EngineInterface, objective: OrcaObjective, sessionId: string): Promise<ObjectiveDerived | null> {
  const files = await readObjectiveFiles($, objective)
  return files ? deriveObjective(objective, files, sessionId) : null
}

// `landed` needs git, so the verb answers it: `objective list` is read-only.
async function isLanded($: EngineInterface, objective: OrcaObjective): Promise<boolean> {
  try {
    const orca = `${$.plugin.root.replace(/\/+$/, '')}/scripts/orca.sh`
    const ran = await $.process.run(['bash', orca, 'objective', 'list', objective.repoRoot], { timeoutMs: LANDED_TIMEOUT_MS })
    return ran.exitCode === 0 && landedIn(ran.stdout, objective.dir)
  } catch { return false }
}

// Writes only a change: every write redraws the band.
async function setBand($: EngineInterface, band: OrcaBand | null) {
  if (JSON.stringify(await read($, bandAtom)) === JSON.stringify(band)) return
  await update($, bandAtom, () => band)
}

async function forget($: EngineInterface) {
  if (ticker) ticker.cancel()
  ticker = null
  await update($, objectiveAtom, () => null)
  await setBand($, null)
}

// Put down while still owned: kept with the band it showed, so a rescan
// takes it up again only once the files say something new.
async function drop($: EngineInterface, dir: string, band: OrcaBand) {
  await forget($)
  await update($, droppedAtom, () => ({ dir, band: JSON.stringify(band) }))
}

async function tick($: EngineInterface) {
  if (ticking) return
  ticking = true
  try {
    const objective = await read($, objectiveAtom)
    if (!objective) {
      if (ticker) ticker.cancel()
      ticker = null
      await setBand($, null)
      return
    }
    // A live run has the band; nothing draws it here: read nothing.
    if ((await read($, runAtom)) || !(await draws($))) return
    const out = await observe($, objective, await $.session.id())
    // A rescan may have moved or dropped the objective while this tick read.
    if (!out || (await read($, objectiveAtom))?.dir !== objective.dir) return
    if (out.finished) await forget($)
    else await setBand($, out.band)
  } catch {
    // Never crash the session over a status line; the next tick tries again.
  } finally {
    ticking = false
  }
}

function follow($: EngineInterface) {
  if (!ticker) ticker = $.clock.every(TICK_MS, () => { void tick($) })
  void tick($)
}

// Nothing draws the band but the terminal and desktop (`claude -p`, VS Code).
async function draws($: EngineInterface): Promise<boolean> {
  return (await $.session.surfaces()).some(s => s === 'terminal' || s === 'desktop')
}

async function rescan($: EngineInterface) {
  if (!(await draws($))) return
  const sessionId = await $.session.id()
  const repoRoot = await repoRootOf($)
  const dir = repoRoot ? await findOwned($, repoRoot, sessionId) : null
  const current = await read($, objectiveAtom)
  if (!repoRoot || !dir) {
    if (current) await forget($)
    return
  }
  const objective: OrcaObjective = current?.dir === dir ? current
    : { dir, slug: objectiveSlug(dir), repoRoot, idlePrompts: 0 }
  const out = await observe($, objective, sessionId)
  if (!out) return
  if (out.finished || !out.band) {
    if (current) await forget($)
    return
  }
  const dropped = await read($, droppedAtom)
  if (dropped?.dir === dir && dropped.band === JSON.stringify(out.band)) return
  if (out.state === 'idle' && await isLanded($, objective)) {
    await drop($, dir, out.band)
    return
  }
  if (dropped) await update($, droppedAtom, () => null)
  if (current?.dir !== dir) await update($, objectiveAtom, () => objective)
  await setBand($, out.band)
  follow($)
}

// The band's share of the events both bands hear, registered in ./bands.tsx.
export async function objectiveStart($: EngineInterface) {
  // A hot reload drops the timer; the tracked objective is still in $.state.
  if (await read($, objectiveAtom)) follow($)
  await rescan($)
}

// The person's own prompts count toward the idle drop; every prompt rescans.
export async function objectivePrompt($: EngineInterface, origin: string) {
  const objective = await read($, objectiveAtom)
  const band = await read($, bandAtom)
  if (objective && band && (origin === 'composer' || origin === 'bridge')) {
    if (band.phase === 'idle' && objective.idlePrompts + 1 >= IDLE_PROMPTS) {
      await drop($, objective.dir, band)
      return
    }
    const idlePrompts = band.phase === 'idle' ? objective.idlePrompts + 1 : 0
    if (idlePrompts !== objective.idlePrompts) await update($, objectiveAtom, o => (o ? { ...o, idlePrompts } : o))
  }
  await rescan($)
}

export async function objectiveEnd($: EngineInterface) {
  await forget($)
}

// The band to draw now; null while a live run has the slot.
export async function objectiveBand($: EngineInterface): Promise<OrcaBand | null> {
  if (await read($, runAtom)) return null
  const band = await read($, bandAtom)
  return band && (await read($, objectiveAtom)) ? band : null
}

export const register: Register = on => {
  // orca:worktree runs `objective open`, which writes the claim.
  on('classic.SubagentStop', { agent_type: WORKTREE_AGENT }, async ($, e, next) => {
    try { await rescan($) } catch { /* observe only */ }
    return next(e)
  }).catch(($, e, next) => next(e)) // an observer never stands in a call's way
}
