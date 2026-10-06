// Pure derivation for the run band: run files and the workflow journal in,
// the rows the band draws out. No `$` here — run-band.tsx gathers the inputs
// (and owns every engine call), so everything below is testable as plain data.

import type { OrcaBand, OrcaItem, OrcaRow, OrcaRun } from '../types'

// What run-band.tsx reads from the run directory on one tick.
export type RunFiles = {
  runDirExists: boolean
  // spec.md (or the amendment file on an iterate spec launch): its mtime,
  // and its text when the caller needed it.
  spec: { mtimeMs: number; text: string | null } | null
  // reviews/ entries, by name.
  reviews: { name: string; mtimeMs: number }[]
  // plans/ entry names.
  plans: string[]
  // merged.tsv's text, null when absent.
  merged: string | null
  // report.md's mtime, null when absent.
  reportMtimeMs: number | null
}

export type JournalRead =
  | { status: 'ok'; text: string }
  | { status: 'missing' | 'unreadable' | 'too-large' }

export type Derived = { finished: boolean; band: OrcaBand | null }

// One agent() call the journal recorded.
export type JournalStage = {
  seq: number
  label: string
  running: boolean
  failed: boolean
  result: unknown
}

// ---------- journal ----------

// One JSON object per line: {type:"started",key,agentId,label,phase} and
// later {type:"result"|"failed",key,agentId,...}. A line that does not parse
// (the torn tail of a write in progress, a partial flush) is skipped — the
// next tick reads it whole. A started entry with no label predates labels and
// says nothing the band can use.
export function parseJournal(text: string): JournalStage[] {
  const stages: JournalStage[] = []
  const open = new Map<string, JournalStage[]>()
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let row: unknown
    try { row = JSON.parse(line) } catch { continue }
    if (!isRecord(row)) continue
    const key = typeof row.key === 'string' ? row.key : null
    if (row.type === 'started' && key !== null) {
      const stage: JournalStage = {
        seq: stages.length, label: typeof row.label === 'string' ? row.label : '',
        running: true, failed: false, result: undefined,
      }
      stages.push(stage)
      const list = open.get(key) ?? []
      list.push(stage)
      open.set(key, list)
    } else if ((row.type === 'result' || row.type === 'failed') && key !== null) {
      const list = open.get(key)
      const stage = list?.shift()
      if (!stage) continue
      stage.running = false
      stage.failed = row.type === 'failed'
      stage.result = row.result
    }
  }
  return stages.filter(s => s.label !== '')
}

// What a label in work-loop.workflow.js / spec.workflow.js means for the band.
export type LabelMeaning =
  | { kind: 'item'; ids: string[]; stage: string }
  | { kind: 'escalate'; ids: string[] }
  | { kind: 'salvage'; id: string }
  | { kind: 'integration'; stage: string }
  | { kind: 'spec'; state: 'drafting' | 'in review' }
  | { kind: 'wrap-up' }
  | null

export function classifyLabel(label: string): LabelMeaning {
  // Retries keep their stage: review:W1#0~retry, worktree:W1~frameretry.
  const bare = label.replace(/~(retry|frameretry)$/, '')
  if (bare === 'spec') return { kind: 'spec', state: 'drafting' }
  if (bare === 'spec-review' || bare === 'spec-revise') return { kind: 'spec', state: 'in review' }
  if (bare === 'run-lease-release') return { kind: 'wrap-up' }
  if (bare === 'integration-verify') return { kind: 'integration', stage: 'verify' }
  if (bare === 'integration-review-clean') return { kind: 'integration', stage: 'review' }
  if (bare === 'integration-status') return { kind: 'integration', stage: 'commit' }
  if (bare === 'integration-fix-notes') return { kind: 'integration', stage: 'fix' }
  const colon = bare.indexOf(':')
  if (colon < 0) return null
  // reconcile#2 and reconcile~serial are reconcile; plan:W3#2 is a replan.
  const head = bare.slice(0, colon).replace(/[#~].*$/, '')
  const tail = bare.slice(colon + 1)
  const hash = tail.indexOf('#')
  const subject = hash < 0 ? tail : tail.slice(0, hash)
  const suffix = hash < 0 ? '' : tail.slice(hash + 1)
  const round = /^\d+$/.test(suffix) ? Number(suffix) : null
  const ids = subject.split('+').filter(Boolean)
  if (!ids.length) return null

  let stage: string | null
  switch (head) {
    case 'plan': stage = suffix ? 'replan' : 'plan'; break
    case 'plan-archive':
    case 'review-archive': stage = 'replan'; break
    case 'reconcile': stage = 'reconcile'; break
    case 'escalate': return { kind: 'escalate', ids }
    case 'salvage': return { kind: 'salvage', id: ids[0] ?? subject }
    case 'worktree': stage = 'worktree'; break
    case 'provision': stage = 'provision'; break
    case 'implement': stage = 'implement'; break
    // Rounds are 0-based in labels: review:W3#0 is the first review.
    case 'secrets-remove':
    case 'review': stage = round === null ? 'review' : `review r${round + 1}`; break
    case 'secrets-place':
    case 'fix': stage = round === null ? 'fix' : `fix r${round}`; break
    case 'secrets-restore': stage = 'review'; break
    case 'commit':
    case 'commit-verify': stage = 'commit'; break
    case 'merge-reset':
    case 'merge':
    case 'merge-finalize': stage = 'merge'; break
    default: stage = null // spec-hash, run-lease and other plumbing
  }
  if (stage === null) return null
  if (subject === 'integration') return { kind: 'integration', stage }
  return { kind: 'item', ids, stage }
}

// ---------- spec phase ----------

export type SpecState = 'drafting' | 'in review' | 'ready'

// Files decide by default: no fresh spec is drafting, a fresh spec with no
// fresh review artifact is in review, both is ready (which covers the
// checkpoint wait). "Fresh" is "written since this launch": a checkpoint
// re-spawn or an iterate amend round runs over a directory that already holds
// a spec and a review. A running spec-stage agent in the journal overrides
// the files, and a completed spec workflow is ready.
export function specState(run: OrcaRun, files: RunFiles, stages: JournalStage[] | null): SpecState {
  if (run.specEnded) return 'ready'
  const running = (stages ?? []).filter(s => s.running).map(s => classifyLabel(s.label))
  const live = running.filter((m): m is { kind: 'spec'; state: 'drafting' | 'in review' } => m?.kind === 'spec').pop()
  if (live) return live.state
  if (!files.spec || files.spec.mtimeMs < run.since) return 'drafting'
  const artifact = run.amendPath ? /^spec-amend-[a-z]+\.json$/ : /^spec-[a-z]+\.json$/
  const reviewed = files.reviews.some(r => artifact.test(r.name) && r.mtimeMs >= run.since)
  return reviewed ? 'ready' : 'in review'
}

// ---------- build phase ----------

// The last `**Workflow args:**` line of spec.md: the item list a resume
// replays. Used only when the launch's own args could not be read.
export function itemsFromSpec(text: string | null): OrcaItem[] {
  if (!text) return []
  const lines = text.split('\n').filter(l => l.startsWith('**Workflow args:** '))
  const last = lines[lines.length - 1]
  if (!last) return []
  try { return itemsFromArgs(JSON.parse(last.slice('**Workflow args:** '.length))) } catch { return [] }
}

export function itemsFromArgs(args: unknown): OrcaItem[] {
  let parsed = args
  if (typeof parsed === 'string') { try { parsed = JSON.parse(parsed) } catch { return [] } }
  if (!isRecord(parsed)) return []
  let items = parsed.items
  if (typeof items === 'string') { try { items = JSON.parse(items) } catch { return [] } }
  if (!Array.isArray(items)) return []
  return items.filter(isRecord).filter(i => typeof i.id === 'string').map(i => ({
    id: i.id as string,
    title: typeof i.title === 'string' ? i.title : '',
    deps: Array.isArray(i.deps) ? i.deps.filter((d): d is string => typeof d === 'string') : [],
  }))
}

export function mergedIds(text: string | null): Set<string> {
  const ids = new Set<string>()
  for (const line of (text ?? '').split('\n')) {
    const [id, sha] = line.split('\t')
    if (id && sha && sha.trim()) ids.add(id)
  }
  return ids
}

type ItemTrack = {
  item: OrcaItem
  blocked: string | null
  cut: string | null
  salvaged: boolean
  live: string | null
  last: string | null
}

// Escalation results follow ESCALATE ({replan, cut, blocked, addDeps}) for a
// wave and BUILD_ESCALATE ({action, reason}) for one item mid-build.
function applyEscalation(track: Map<string, ItemTrack>, items: OrcaItem[], ids: string[], result: unknown, merged: Set<string>) {
  let r = result
  if (typeof r === 'string') { try { r = JSON.parse(r) } catch { return } }
  if (!isRecord(r)) return
  if (typeof r.action === 'string') {
    const t = track.get(ids[0] ?? '')
    const reason = typeof r.reason === 'string' ? r.reason : ''
    if (t && r.action === 'block') t.blocked = reason
    if (t && r.action === 'cut') t.cut = reason
    return
  }
  for (const b of Array.isArray(r.blocked) ? r.blocked : []) {
    if (!isRecord(b) || typeof b.id !== 'string' || !ids.includes(b.id)) continue
    const t = track.get(b.id)
    if (t) t.blocked = typeof b.reason === 'string' ? b.reason : ''
  }
  for (const c of Array.isArray(r.cut) ? r.cut : []) {
    if (!isRecord(c) || typeof c.id !== 'string' || !ids.includes(c.id)) continue
    const t = track.get(c.id)
    if (t) t.cut = typeof c.reason === 'string' ? c.reason : ''
  }
  // The scheduler applies addDeps to items not yet building, never as a
  // cycle; an item already merged keeps its deps as they were.
  for (const a of Array.isArray(r.addDeps) ? r.addDeps : []) {
    if (!isRecord(a) || typeof a.id !== 'string' || !Array.isArray(a.dependsOn)) continue
    const it = items.find(i => i.id === a.id)
    if (!it || merged.has(it.id)) continue
    for (const dep of a.dependsOn) {
      if (typeof dep !== 'string' || dep === it.id || it.deps.includes(dep)) continue
      if (!items.some(i => i.id === dep) || reaches(items, dep, it.id)) continue
      it.deps.push(dep)
    }
  }
}

function reaches(items: OrcaItem[], from: string, to: string): boolean {
  const seen = new Set<string>()
  const stack = [from]
  while (stack.length) {
    const cur = stack.pop() as string
    if (cur === to) return true
    if (seen.has(cur)) continue
    seen.add(cur)
    const it = items.find(i => i.id === cur)
    if (it) stack.push(...it.deps)
  }
  return false
}

// A review artifact on disk names the last completed round: <ID>-<reviewer>.json
// is the latest, <ID>-<reviewer>.round<N>.json one per round.
function reviewRound(id: string, reviews: { name: string }[]): number {
  let round = 0
  const esc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const re = new RegExp(`^${esc}-[a-z]+(?:\\.round(\\d+))?\\.json$`)
  for (const r of reviews) {
    const m = re.exec(r.name)
    if (!m) continue
    round = Math.max(round, m[1] === undefined ? 1 : Number(m[1]) + 1)
  }
  return round
}

const isCut = (t: ItemTrack | undefined) => t !== undefined && t.cut !== null
const isBlocked = (t: ItemTrack | undefined) =>
  t !== undefined && !isCut(t) && (t.blocked !== null || t.salvaged)

// Dependencies that have not merged; a cut one counts as satisfied, as it
// does for the scheduler. A blocked one is named as such: the item waits on
// a decision, not on work in progress.
function waitingOn(item: OrcaItem, merged: Set<string>, track: Map<string, ItemTrack>): string[] {
  return item.deps
    .filter(d => !merged.has(d) && !isCut(track.get(d)))
    .map(d => (isBlocked(track.get(d)) ? `${d} (blocked)` : d))
}

export function deriveBuild(run: OrcaRun, files: RunFiles, journal: JournalRead): OrcaBand {
  const items = (run.items.length ? run.items : itemsFromSpec(files.spec?.text ?? null))
    .map(i => ({ ...i, deps: [...i.deps] }))
  const merged = mergedIds(files.merged)
  const track = new Map<string, ItemTrack>(items.map(item =>
    [item.id, { item, blocked: null, cut: null, salvaged: false, live: null, last: null }]))
  const stages = journal.status === 'ok' ? parseJournal(journal.text) : null

  const integration: { live: string | null; seen: boolean } = { live: null, seen: false }
  let wrapping = false
  for (const s of stages ?? []) {
    const m = classifyLabel(s.label)
    if (!m) continue
    if (m.kind === 'item') {
      for (const id of m.ids) {
        const t = track.get(id)
        if (!t) continue
        t.last = m.stage
        if (s.running) t.live = m.stage
      }
    } else if (m.kind === 'escalate') {
      for (const id of m.ids) {
        const t = track.get(id)
        if (!t) continue
        t.last = 'escalate'
        if (s.running) t.live = 'escalate'
      }
      if (!s.running && !s.failed) applyEscalation(track, items, m.ids, s.result, merged)
    } else if (m.kind === 'salvage') {
      const t = track.get(m.id)
      if (t) t.salvaged = true
    } else if (m.kind === 'integration') {
      integration.seen = true
      if (s.running) integration.live = m.stage
    } else if (m.kind === 'wrap-up') {
      wrapping = true
    }
  }

  const rows: OrcaRow[] = items.map(item => {
    const t = track.get(item.id) as ItemTrack
    const row = (mark: string, status: string, tone: OrcaRow['tone']): OrcaRow =>
      ({ id: item.id, title: item.title, mark, status, tone })
    if (merged.has(item.id)) return row('✓', 'done', 'done')
    if (isCut(t)) return row('–', t.cut ? `cut: ${t.cut}` : 'cut', 'cut')
    if (isBlocked(t)) {
      const why = t.blocked || (t.last ? `after ${t.last}` : '')
      return row('✕', why ? `blocked: ${why}` : 'blocked', 'blocked')
    }
    if (t.live) return row('●', t.live, 'live')
    const waits = waitingOn(item, merged, track)
    if (waits.length) return row('◌', `waiting on ${waits.join(', ')}`, 'wait')
    if (stages) return t.last ? row('●', t.last, 'live') : row('○', 'queued', 'queued')
    // File-only fallback: coarse, from what the stages leave on disk.
    const round = reviewRound(item.id, files.reviews)
    if (round > 0) return row('●', `reviewed r${round}`, 'live')
    if (files.plans.includes(`${item.id}.md`)) return row('●', 'planning done', 'live')
    return row('○', 'queued', 'queued')
  })

  const done = items.filter(i => merged.has(i.id)).length
  const phase = wrapping ? 'wrapping up'
    : integration.seen ? (integration.live ? `integrate · ${integration.live}` : 'integrate')
      : 'build'
  return { slug: run.slug, phase, detail: `${done}/${items.length} merged`, rows,
    source: stages ? 'journal' : 'files' }
}

// ---------- the whole band ----------

export function derive(run: OrcaRun, files: RunFiles, journal: JournalRead): Derived {
  // A run directory that went away (archived, removed) takes the band with it.
  if (!files.runDirExists) return { finished: true, band: null }
  // The feature skill writes report.md after the work loop returns: the run
  // is over. Only a report written since this launch counts — a retry or an
  // iterate round relaunches over a directory whose old report was archived.
  if (run.kind === 'build' && files.reportMtimeMs !== null && files.reportMtimeMs >= run.since)
    return { finished: true, band: null }
  if (run.kind === 'spec') {
    const stages = journal.status === 'ok' ? parseJournal(journal.text) : null
    return { finished: false, band: { slug: run.slug, phase: 'spec',
      detail: specState(run, files, stages), rows: [], source: stages ? 'journal' : 'files' } }
  }
  return { finished: false, band: deriveBuild(run, files, journal) }
}

// <task-notification><task-id>…</task-id>…<status>…</status>: the message the
// session receives when a background task (a workflow included) ends. One
// delivery may carry several.
export function parseTaskNotifications(text: string): { taskId: string; status: string }[] {
  const out: { taskId: string; status: string }[] = []
  for (const block of text.split('<task-notification>').slice(1)) {
    const id = /<task-id>([^<]+)<\/task-id>/.exec(block)
    if (!id || !id[1]) continue
    const status = /<status>([^<]+)<\/status>/.exec(block)
    out.push({ taskId: id[1].trim(), status: status?.[1]?.trim() ?? '' })
  }
  return out
}

// .orca/<timestamp>-feat-<slug>/ → <slug>
export function slugOf(runDir: string): string {
  const base = runDir.replace(/\/+$/, '').split('/').pop() ?? runDir
  return base.replace(/^\d{8}-\d{6}-(feat|bug|proto)-/, '')
}

// Claude Code's project folder name for a directory: every character that is
// not a letter or a digit becomes '-'.
export function projectDirName(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-')
}

// ---------- layout ----------

export function truncate(text: string, width: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  if (width <= 0) return ''
  return flat.length <= width ? flat : `${flat.slice(0, Math.max(0, width - 1))}…`
}

// Fits the rows to the band's width: ids padded to one column, titles cut to
// what is left beside the widest status (statuses capped so a long blocked
// reason never squeezes every title away), statuses cut to the remainder.
export function layoutRows(rows: OrcaRow[], columns: number): { lead: string; tail: string; row: OrcaRow }[] {
  const idW = Math.max(0, ...rows.map(r => r.id.length))
  const statusW = Math.min(30, Math.max(0, ...rows.map(r => r.status.length + 2)))
  const lead = 2 + idW + 2
  const titleMax = Math.max(0, ...rows.map(r => r.title.replace(/\s+/g, ' ').trim().length))
  const titleW = Math.min(titleMax, Math.max(8, columns - lead - 2 - statusW))
  return rows.map(row => {
    const title = truncate(row.title, titleW).padEnd(titleW)
    const head = `  ${row.id.padEnd(idW)}  ${title}  `
    const tail = truncate(`${row.mark} ${row.status}`, Math.max(1, columns - head.length))
    return { lead: head, tail, row }
  })
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}
