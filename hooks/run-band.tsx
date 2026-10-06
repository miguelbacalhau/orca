// The run band: a live view of the orca run this session launched, drawn
// above the prompt. A read-only observer — it watches this session's own
// Workflow launches of spec.workflow.js / work-loop.workflow.js, then reads
// the run directory and the workflow's journal on a short tick while that run
// is tracked. It writes nothing anywhere but its own $.state, and draws
// nothing where the AbovePrompt band is not raised (VS Code, `claude -p`).
//
// The derivation itself is pure and lives in ./derive.ts.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { OrcaBand, OrcaRun, OrcaTone } from '../types'
import { derive, itemsFromArgs, layoutRows, parseTaskNotifications, projectDirName, slugOf, truncate } from './derive'
import type { JournalRead, RunFiles } from './derive'

const runAtom = atom({ plugin: 'orca', key: 'run' } as const, null)
const bandAtom = atom({ plugin: 'orca', key: 'band' } as const, null)

const TICK_MS = 1500
// $.fs.read refuses anything larger.
const MAX_READ = 4 * 1024 * 1024
// A spec that finished and then sat through this many of the person's own
// prompts with no work-loop launch was abandoned at the checkpoint.
const SPEC_IDLE_PROMPTS = 3

// Module variables start over on a hot reload; the run itself is in $.state.
// A timer keeps the `$` of the hook that started it, which stays usable after
// that dispatch ends (checked under `claude -p` on 2.1.290).
let ticker: Timer | null = null
let ticking = false
const textCache = new Map<string, { size: number; mtimeMs: number; text: string }>()

function kindOf(scriptPath: unknown): OrcaRun['kind'] | null {
  if (typeof scriptPath !== 'string') return null
  if (/(^|\/)spec\.workflow\.js$/.test(scriptPath)) return 'spec'
  if (/(^|\/)work-loop\.workflow\.js$/.test(scriptPath)) return 'build'
  return null
}

function record(v: unknown): Record<string, unknown> | null {
  if (typeof v === 'string') { try { v = JSON.parse(v) } catch { return null } }
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

// Reads a file through a size+mtime cache: an unchanged journal is not read
// again every tick. 'too-large' past what $.fs.read takes.
async function readCached($: EngineInterface, path: string): Promise<JournalRead> {
  let stat
  try { stat = await $.fs.stat(path) } catch { return { status: 'missing' } }
  if (stat.size > MAX_READ) return { status: 'too-large' }
  const hit = textCache.get(path)
  if (hit && hit.size === stat.size && hit.mtimeMs === stat.mtimeMs) return { status: 'ok', text: hit.text }
  try {
    const text = await $.fs.read(path)
    textCache.set(path, { size: stat.size, mtimeMs: stat.mtimeMs, text })
    return { status: 'ok', text }
  } catch { return { status: 'unreadable' } }
}

async function listNames($: EngineInterface, dir: string): Promise<{ name: string; mtimeMs: number }[]> {
  try { return (await $.fs.list(dir)).map(f => ({ name: f.name, mtimeMs: f.mtimeMs })) } catch { return [] }
}

async function readRunFiles($: EngineInterface, run: OrcaRun): Promise<RunFiles> {
  const files: RunFiles = { runDirExists: true, spec: null, reviews: [], plans: [], merged: null, reportMtimeMs: null }
  let entries
  try { entries = await $.fs.list(run.runDir) } catch {
    files.runDirExists = await $.fs.exists(run.runDir).catch(() => true)
    return files
  }
  const named = new Map(entries.map(f => [f.name, f]))
  const report = named.get('report.md')
  files.reportMtimeMs = report ? report.mtimeMs : null
  if (run.amendPath) {
    const st = await $.fs.stat(run.amendPath).catch(() => null)
    files.spec = st ? { mtimeMs: st.mtimeMs, text: null } : null
  } else {
    const spec = named.get('spec.md')
    // spec.md's text is needed only when the launch's own item list was unreadable.
    const needText = run.kind === 'build' && run.items.length === 0
    const text = spec && needText ? await readCached($, `${run.runDir}/spec.md`) : null
    files.spec = spec ? { mtimeMs: spec.mtimeMs, text: text && text.status === 'ok' ? text.text : null } : null
  }
  if (named.has('reviews')) files.reviews = await listNames($, `${run.runDir}/reviews`)
  if (named.has('plans')) files.plans = (await listNames($, `${run.runDir}/plans`)).map(f => f.name)
  if (run.kind === 'build' && named.has('merged.tsv')) {
    const merged = await readCached($, `${run.runDir}/merged.tsv`)
    files.merged = merged.status === 'ok' ? merged.text : null
  }
  return files
}

// Writes only a change: every write redraws the band.
async function setBand($: EngineInterface, band: OrcaBand | null) {
  if (JSON.stringify(await read($, bandAtom)) === JSON.stringify(band)) return
  await update($, bandAtom, () => band)
}

async function forget($: EngineInterface) {
  if (ticker) ticker.cancel()
  ticker = null
  await update($, runAtom, () => null)
  await setBand($, null)
}

async function tick($: EngineInterface) {
  if (ticking) return
  ticking = true
  try {
    const run = await read($, runAtom)
    if (!run) {
      if (ticker) ticker.cancel()
      ticker = null
      await setBand($, null)
      return
    }
    // Nothing draws the band here (a `claude -p` run, VS Code): read nothing.
    const surfaces = await $.session.surfaces()
    if (!surfaces.some(s => s === 'terminal' || s === 'desktop')) return
    const files = await readRunFiles($, run)
    const journal: JournalRead = run.journal ? await readCached($, run.journal) : { status: 'missing' }
    const out = derive(run, files, journal)
    // The run may have ended (a notification) or been replaced (a new launch)
    // while this tick read files; a stale answer must not redraw the band.
    if ((await read($, runAtom))?.runId !== run.runId) return
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

// The launch result names the workflow's transcript directory, which holds
// journal.jsonl. Without it, the same path is rebuilt from the session.
async function journalPath($: EngineInterface, transcriptDir: unknown, runId: string): Promise<string | null> {
  if (typeof transcriptDir === 'string' && transcriptDir) return `${transcriptDir.replace(/\/+$/, '')}/journal.jsonl`
  const config = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`
  if (!config.startsWith('/')) return null
  const cwd = await $.session.cwd()
  const session = await $.session.id()
  return `${config}/projects/${projectDirName(cwd)}/${session}/subagents/workflows/${runId}/journal.jsonl`
}

async function track($: EngineInterface, kind: OrcaRun['kind'], input: Record<string, unknown>, launched: unknown, since: number) {
  const result = record(launched)
  if (!result || result.status !== 'async_launched') return
  const runId = result.runId
  const taskId = result.taskId
  if (typeof runId !== 'string' || typeof taskId !== 'string') return
  const args = record(input.args)
  const runDir = args && typeof args.runDir === 'string' ? args.runDir.replace(/\/+$/, '') : null
  if (!args || !runDir) return
  const run: OrcaRun = {
    kind,
    runDir,
    slug: typeof args.slug === 'string' && args.slug ? args.slug : slugOf(runDir),
    runId,
    taskId,
    journal: await journalPath($, result.transcriptDir, runId),
    since,
    items: kind === 'build' ? itemsFromArgs(args) : [],
    amendPath: kind === 'spec' && typeof args.amendPath === 'string' ? args.amendPath : null,
    specEnded: false,
    idlePrompts: 0,
  }
  await update($, runAtom, () => run)
  follow($)
}

async function onPrompt($: EngineInterface, origin: string, text: string) {
  const run = await read($, runAtom)
  if (!run) return
  if (origin === 'task-notification') {
    const ended = parseTaskNotifications(text).find(n => n.taskId === run.taskId)
    if (!ended) return
    // The work loop ending ends the run's live phase. A spec that completed
    // stays on screen as ready (the checkpoint, or the launch about to come);
    // one that failed or was stopped does not.
    if (run.kind === 'build' || ended.status !== 'completed') await forget($)
    else await update($, runAtom, r => (r ? { ...r, specEnded: true } : r))
    return
  }
  if ((origin === 'composer' || origin === 'bridge') && run.kind === 'spec') {
    const band = await read($, bandAtom)
    if (!run.specEnded && band?.detail !== 'ready') return
    if (run.idlePrompts + 1 >= SPEC_IDLE_PROMPTS) await forget($)
    else await update($, runAtom, r => (r ? { ...r, idlePrompts: r.idlePrompts + 1 } : r))
  }
}

const TONE: Record<OrcaTone, { color?: string; dimColor?: boolean }> = {
  done: { color: 'success' },
  live: { color: 'suggestion' },
  wait: { dimColor: true },
  queued: { dimColor: true },
  blocked: { color: 'error' },
  cut: { dimColor: true },
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // A hot reload drops the timer; the tracked run is still in $.state.
    if (await read($, runAtom)) follow($)
    return next(e)
  })

  on('tool.call', { tool: 'Workflow' }, async ($, e, next) => {
    // Only the main conversation's own launches: the skills launch from there.
    if (e.tool !== 'Workflow' || e.agentId !== undefined) return next(e)
    const kind = kindOf(e.scriptPath)
    if (!kind) return next(e)
    const since = await $.clock.now()
    const ran = await next(e)
    if (!ran.isError && 'result' in ran) {
      try { await track($, kind, { args: e.args }, ran.result, since) } catch { /* observe only */ }
    }
    return ran
  }).catch(($, e, next) => next(e)) // an observer never stands in a call's way

  on('prompt.submit', async ($, e, next) => {
    try { await onPrompt($, e.origin.kind, e.text) } catch { /* observe only */ }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    try { await forget($) } catch { /* observe only */ }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const band = await read($, bandAtom)
    if (!band || !(await read($, runAtom))) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const columns = Math.max(24, e.props.bodyColumns || 80)
    const facts = [band.slug, band.phase, band.detail]
    if (band.source === 'files' && band.phase !== 'spec') facts.push('no journal')
    const header = truncate(` · ${facts.join(' · ')}`, columns - 4)

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>orca</Text>
          <Text dimColor wrap="truncate-end">{header}</Text>
        </Box>
        {layoutRows(band.rows, columns).map(line => (
          <Box>
            <Text>{line.lead}</Text>
            <Text {...TONE[line.row.tone]} wrap="truncate-end">{line.tail}</Text>
          </Box>
        ))}
      </Box>
    )
  })
}
