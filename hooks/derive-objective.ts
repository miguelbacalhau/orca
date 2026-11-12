// Pure derivation for the objective band: the objective's files in, the band
// out. No `$` here — objective-band.tsx gathers the inputs (and owns every
// engine call), so everything below is testable as plain data.
//
// The files are the ones scripts/verbs/objective.sh writes and reads, and they
// are read here the way it reads them: only `## <id> — <title>` headings and
// `**Key:**` lines, never prose; an entry's first line of each key counts, its
// value the first word (Source: the whole line). The state is derived by the
// same rules as `objective list`, but for `landed`, which needs git: the band
// asks the verb for that (objective-band.tsx).

import type { OrcaBand, OrcaObjective, OrcaRow } from '../types'

// What objective-band.tsx reads from the objective directory on one tick.
export type ObjectiveFiles = {
  dirExists: boolean
  // The owner file's text; null when absent or unreadable.
  owner: string | null
  // The archived file, or an unfinished archive's archiving file, exists.
  archived: boolean
  decisions: string | null
  phases: string | null
  // phases.md's mtime: a plan review written since then is this pass's own.
  phasesMtimeMs: number | null
  // plan/ entries, by name.
  plan: { name: string; mtimeMs: number }[]
  report: string | null
  // phases/<active>/action, the round engine's last frame for the active phase.
  action: string | null
}

export type ObjectiveState = 'active' | 'planning' | 'blocked' | 'discussing' | 'ready' | 'verify' | 'idle'

export type ObjectiveDerived = { finished: boolean; state: ObjectiveState | null; band: OrcaBand | null }

export type Entry = { id: string; title: string; values: Record<string, string> }

// ---------- the files ----------

// One entry per `## <kind><n> — <title>` heading of decisions.md (D) or
// phases.md (P); any other `## ` heading ends the entry before it.
export function parseEntries(text: string | null, kind: 'D' | 'P'): Entry[] {
  const entries: Entry[] = []
  const heading = new RegExp(`^## (${kind}[1-9][0-9]*) — (.*)$`)
  let current: Entry | null = null
  for (const raw of (text ?? '').split('\n')) {
    const line = raw.replace(/[\t\r]/g, ' ')
    const head = heading.exec(line)
    if (head) {
      current = { id: head[1] as string, title: (head[2] as string).trim() || '-', values: {} }
      entries.push(current)
      continue
    }
    if (line.startsWith('## ')) { current = null; continue }
    const key = /^\*\*([A-Za-z ]+):\*\* ?(.*)$/.exec(line)
    if (!current || !key) continue
    const name = key[1] as string
    if (name in current.values) continue
    const value = (key[2] as string).trim()
    current.values[name] = name === 'Source' ? value : firstWord(value)
  }
  return entries
}

function firstWord(value: string): string {
  return value.replace(/^ +/, '').replace(/[ ,;].*$/, '')
}

// A decision whose state is neither decided nor deferred is open; a phase
// whose state is not active, done, or blocked is pending.
export function decisionState(entry: Entry): 'open' | 'decided' | 'deferred' {
  const state = entry.values.State
  return state === 'decided' || state === 'deferred' ? state : 'open'
}

export function phaseState(entry: Entry): 'pending' | 'active' | 'done' | 'blocked' {
  const state = entry.values.State
  return state === 'active' || state === 'done' || state === 'blocked' ? state : 'pending'
}

export function activePhaseId(phases: string | null): string | null {
  return parseEntries(phases, 'P').find(p => phaseState(p) === 'active')?.id ?? null
}

// The F ids listed under report.md's `## Follow-ups` that no decision's
// `**Source:**` cites: a cited follow-up is taken.
export function openFollowups(report: string | null, decisions: Entry[]): number {
  const cited = new Set(decisions.flatMap(d => (d.values.Source ?? '').match(/F[1-9][0-9]*/g) ?? []))
  const listed = new Set<string>()
  let inside = false
  for (const line of (report ?? '').split('\n')) {
    if (line.startsWith('## ')) { inside = /^## Follow-ups *$/.test(line); continue }
    const id = inside ? /^- (F[1-9][0-9]*)( |$)/.exec(line) : null
    if (id) listed.add(id[1] as string)
  }
  return [...listed].filter(id => !cited.has(id)).length
}

// The owner file's `session=` value: the session that claimed the objective.
export function ownerSession(text: string | null): string | null {
  const line = (text ?? '').split('\n').find(l => l.startsWith('session='))
  return line ? line.slice('session='.length).trim() || null : null
}

// Whether report.md's `**Final verification:** <pass|fail> after <P> (…)`
// line covers the last phase: a phase added since makes it stale.
export function finalVerified(report: string | null, phases: Entry[]): boolean {
  const line = (report ?? '').split('\n').find(l => l.startsWith('**Final verification:**'))
  const after = line ? /^\*\*Final verification:\*\* +(?:pass|fail) after (P[1-9][0-9]*)(?: |$)/.exec(line.replace(/[\t\r]/g, ' ')) : null
  const last = phases[phases.length - 1]
  return !!after && !!last && after[1] === last.id
}

// <YYYYMMDD-HHMMSS>-<slug> → <slug>
export function objectiveSlug(dir: string): string {
  const base = dir.replace(/\/+$/, '').split('/').pop() ?? dir
  return base.replace(/^\d{8}-\d{6}-/, '')
}

// Whether `objective list`'s output names this objective landed: one
// `OBJECTIVE:<TAB><dir><TAB><slug><TAB><state><TAB>…` line per objective,
// matched by directory name (the verb prints canonical paths).
export function landedIn(listOutput: string, dir: string): boolean {
  const name = dir.replace(/\/+$/, '').split('/').pop()
  return listOutput.split('\n').some(line => {
    const [tag, path, , state] = line.split('\t')
    return tag === 'OBJECTIVE:' && path?.replace(/\/+$/, '').split('/').pop() === name && state === 'landed'
  })
}

// ---------- the active phase's tail ----------

// The action file is one `rounds next` frame: key=value lines between
// @@ORCA@@ and @@ORCA_END@@. Anything else (missing, torn, a failure) says
// only that the phase is active.
export function actionTail(text: string | null): string {
  const frame = new Map<string, string>()
  for (const line of (text ?? '').split('\n')) {
    const eq = line.indexOf('=')
    if (eq > 0) frame.set(line.slice(0, eq), line.slice(eq + 1).trim())
  }
  const round = frame.get('round') ?? ''
  if (frame.get('rc') !== '0' || !/^\d+$/.test(round)) return 'active'
  const gating = frame.get('gating') ?? '0'
  switch (frame.get('action')) {
    case 'implement': return 'implement'
    case 'review': return `review r${round}`
    case 'fix': return `fix r${round} (${gating} gating)`
    case 'fix-minor': return 'fix minor'
    case 'fix-checks': return 'fix checks'
    case 'ask-disputes': return `waiting on you: dispute r${round}`
    case 'stalled': return `waiting on you: stall r${round}`
    case 'ask-questions': return 'waiting on you: questions'
    case 'infeasible': return 'waiting on you: infeasible'
    case 'drifted': return `revalidate r${round}`
    case 'commit': return 'committing'
    default: return 'active'
  }
}

// ---------- the band ----------

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

type Counts = { open: number; decided: number; active: number; blocked: number; pending: number; done: number; total: number }

function count(decisions: Entry[], phases: Entry[]): Counts {
  const ds = decisions.map(decisionState)
  const ps = phases.map(phaseState)
  return {
    open: ds.filter(s => s === 'open').length,
    decided: ds.filter(s => s === 'decided').length,
    active: ps.filter(s => s === 'active').length,
    blocked: ps.filter(s => s === 'blocked').length,
    pending: ps.filter(s => s === 'pending').length,
    done: ps.filter(s => s === 'done').length,
    total: ps.length,
  }
}

// objective.sh's rules, in its order, the first that holds.
export function objectiveState(c: Counts, proposed: boolean, verified: boolean): ObjectiveState {
  if (c.active > 0) return 'active'
  if (proposed && c.open === 0) return 'planning'
  if (c.blocked > 0) return 'blocked'
  if (c.open > 0 || c.total === 0) return 'discussing'
  if (c.pending > 0) return 'ready'
  if (!verified) return 'verify'
  return 'idle'
}

// A proposal is under review until a plan review is written after phases.md
// last changed: plan-accept installs phases.md after the previous pass's
// review, so an older review belongs to that pass.
function planReviewed(files: ObjectiveFiles): boolean {
  const since = files.phasesMtimeMs ?? 0
  return files.plan.some(f => /^review-[0-9]+\.json$/.test(f.name) && f.mtimeMs >= since)
}

function header(state: ObjectiveState, c: Counts, phases: Entry[], files: ObjectiveFiles): { phase: string; detail: string } {
  switch (state) {
    case 'discussing': return { phase: 'discussing', detail: `${c.decided} decided · ${c.open} open` }
    case 'planning': return { phase: planReviewed(files) ? 'planning' : 'reviewing plan', detail: '' }
    case 'active': return { phase: `${activePhaseId(files.phases) ?? 'P?'}/${c.total}`, detail: '' }
    case 'blocked': {
      const on = phases.find(p => phaseState(p) === 'blocked')?.values['Blocked on']
      return { phase: on && on !== '-' ? `blocked on ${on}` : 'blocked', detail: '' }
    }
    case 'ready': return { phase: 'ready', detail: `${c.pending} pending` }
    case 'verify': return { phase: 'verify', detail: `${plural(c.done, 'phase')} done` }
    case 'idle': return { phase: 'idle', detail: `${plural(c.done, 'phase')} done` }
  }
}

function decisionRows(decisions: Entry[]): OrcaRow[] {
  return decisions.flatMap((d): OrcaRow[] => {
    const state = decisionState(d)
    if (state === 'open') return [{ id: d.id, title: d.title, mark: '○', status: 'open', tone: 'live' }]
    if (state === 'deferred') return [{ id: d.id, title: d.title, mark: '◌', status: 'deferred', tone: 'cut' }]
    return []
  })
}

function phaseRows(phases: Entry[], action: string | null): OrcaRow[] {
  return phases.map(p => {
    const row = (mark: string, status: string, tone: OrcaRow['tone']): OrcaRow => ({ id: p.id, title: p.title, mark, status, tone })
    const commit = p.values.Commit
    const blockedOn = p.values['Blocked on']
    switch (phaseState(p)) {
      case 'done': return row('✓', commit && commit !== '-' ? `done ${commit.slice(0, 7)}` : 'done', 'done')
      case 'active': return row('●', actionTail(action), 'live')
      case 'blocked': return row('✕', blockedOn && blockedOn !== '-' ? `blocked on ${blockedOn}` : 'blocked', 'blocked')
      case 'pending': return row('◌', 'pending', 'queued')
    }
  })
}

export function deriveObjective(objective: OrcaObjective, files: ObjectiveFiles, sessionId: string): ObjectiveDerived {
  // The directory gone, archived, or claimed by another session (a --steal,
  // a release): the band goes with it.
  const gone = !files.dirExists || files.archived || ownerSession(files.owner) !== sessionId
  if (gone) return { finished: true, state: null, band: null }
  const decisions = parseEntries(files.decisions, 'D')
  const phases = parseEntries(files.phases, 'P')
  const c = count(decisions, phases)
  const state = objectiveState(c, files.plan.some(f => f.name === 'proposed.md'), finalVerified(files.report, phases))
  const head = header(state, c, phases, files)
  const followups = openFollowups(files.report, decisions)
  const detail = [head.detail, followups ? plural(followups, 'follow-up') : ''].filter(Boolean).join(' · ')
  const rows = state === 'discussing' ? decisionRows(decisions) : phaseRows(phases, files.action)
  return { finished: false, state, band: { slug: objective.slug, phase: head.phase, detail, rows, source: 'objective' } }
}
