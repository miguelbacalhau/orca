// The run band (hooks/run-band.tsx, hooks/derive.ts): the derivation as plain
// data, then the hooks module end to end against the engine, with the run
// directory and the journal served from memory. Run with
// `claude plugin test <orca checkout>`.

import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { classifyLabel, derive, layoutRows, parseJournal, parseTaskNotifications, specState } from '../hooks/derive'
import type { JournalRead, RunFiles } from '../hooks/derive'
import type { OrcaItem, OrcaRun } from '../types'

const RUN_DIR = '/repo/.orca/20261006-101500-feat-staged-typecheck-overlay'
const JOURNAL = '/home/.claude/projects/-repo/sess/subagents/workflows/wf_1/journal.jsonl'

const ITEMS: OrcaItem[] = [
  { id: 'W1', title: 'Overlay view layers', deps: [] },
  { id: 'W2', title: 'Whiteout collector', deps: [] },
  { id: 'W3', title: 'CLI flag wiring', deps: ['W1'] },
  { id: 'W4', title: 'Cache invalidation', deps: ['W2'] },
  { id: 'W5', title: 'Docs + config', deps: ['W3', 'W4'] },
  { id: 'W6', title: 'Telemetry hook', deps: [] },
  { id: 'W7', title: 'Telemetry docs', deps: ['W6'] },
  { id: 'W8', title: 'Legacy shim', deps: [] },
]

function run(over: Partial<OrcaRun> = {}): OrcaRun {
  return {
    kind: 'build', runDir: RUN_DIR, slug: 'staged-typecheck-overlay', runId: 'wf_1', taskId: 'task1',
    journal: JOURNAL, since: 1000, items: ITEMS, amendPath: null, specEnded: false, idlePrompts: 0,
    ...over,
  }
}

function files(over: Partial<RunFiles> = {}): RunFiles {
  return { runDirExists: true, spec: null, reviews: [], plans: [], merged: null, reportMtimeMs: null, ...over }
}

// A journal the way the workflow writes one: started, then result (or not yet).
function journal(...rows: (readonly [type: 'started' | 'result' | 'failed', key: string, labelOrResult?: unknown])[]): string {
  return rows.map(([type, key, x]) => JSON.stringify(type === 'started'
    ? { type, key, agentId: `a-${key}`, label: x, phase: 'Build' }
    : { type, key, agentId: `a-${key}`, result: x })).join('\n') + '\n'
}
const done = (key: string, label: string, result: unknown = 'ok') =>
  [['started', key, label], ['result', key, result]] as const
const ok = (text: string): JournalRead => ({ status: 'ok', text })

function rowsOf(r: ReturnType<typeof derive>) {
  return Object.fromEntries((r.band?.rows ?? []).map(row => [row.id, `${row.mark} ${row.status}`]))
}

// ---------- derivation ----------

describe('spec phase', () => {
  const spec = (over: Partial<OrcaRun> = {}) => run({ kind: 'spec', items: [], ...over })

  test('brief alone is drafting, a spec is in review, a review artifact is ready', () => {
    expect(specState(spec(), files(), null)).toBe('drafting')
    expect(specState(spec(), files({ spec: { mtimeMs: 1500, text: null } }), null)).toBe('in review')
    expect(specState(spec(), files({
      spec: { mtimeMs: 1500, text: null }, reviews: [{ name: 'spec-codex.json', mtimeMs: 1600 }],
    }), null)).toBe('ready')
  })

  test('a spec and review from before this launch (a checkpoint re-spawn) count as not written yet', () => {
    const old = files({ spec: { mtimeMs: 500, text: null }, reviews: [{ name: 'spec-claude.json', mtimeMs: 600 }] })
    expect(specState(spec(), old, null)).toBe('drafting')
  })

  test('a running spec-stage agent overrides the files', () => {
    const ready = files({ spec: { mtimeMs: 1500, text: null }, reviews: [{ name: 'spec-codex.json', mtimeMs: 1600 }] })
    expect(specState(spec(), ready, parseJournal(journal(...done('k1', 'spec'), ['started', 'k2', 'spec-review']))))
      .toBe('in review')
    expect(specState(spec(), ready, parseJournal(journal(['started', 'k3', 'spec-revise'])))).toBe('in review')
    expect(specState(spec(), files(), parseJournal(journal(['started', 'k1', 'spec'])))).toBe('drafting')
  })

  test('an amend round reads its own artifact, and a finished spec workflow is ready', () => {
    const amend = spec({ amendPath: `${RUN_DIR}/spec.amendment.md` })
    const f = files({ spec: { mtimeMs: 1500, text: null }, reviews: [{ name: 'spec-codex.json', mtimeMs: 1600 }] })
    expect(specState(amend, f, null)).toBe('in review')
    f.reviews.push({ name: 'spec-amend-codex.json', mtimeMs: 1700 })
    expect(specState(amend, f, null)).toBe('ready')
    expect(specState(spec({ specEnded: true }), files(), null)).toBe('ready')
  })

  test('the band is one line', () => {
    const out = derive(spec(), files({ spec: { mtimeMs: 1500, text: null } }), { status: 'missing' })
    expect(out).toEqual({ finished: false, band: {
      slug: 'staged-typecheck-overlay', phase: 'spec', detail: 'in review', rows: [], source: 'files' } })
  })
})

describe('build phase', () => {
  const live = journal(
    ...done('lease', 'run-lease'),
    ...done('p1', 'plan:W1'), ...done('p2', 'plan:W2'), ...done('p6', 'plan:W6'), ...done('p8', 'plan:W8'),
    ...done('r1', 'reconcile:W1+W2+W6+W8', { clean: false, issues: ['W8 contradicts the spec'] }),
    ...done('e1', 'escalate:W1+W2+W6+W8', { replan: [], cut: [{ id: 'W8', reason: 'out of scope' }], blocked: [], addDeps: [] }),
    ...done('m1', 'merge-finalize:W1'), ...done('m2', 'merge-finalize:W2'),
    ...done('p3', 'plan:W3'), ...done('w3', 'worktree:W3'), ...done('i3', 'implement:W3'),
    ...done('v30', 'review:W3#0', { written: true, total: 2, criticalHigh: 1, reason: '' }),
    ...done('f31', 'fix:W3#1'),
    ['started', 'v31', 'review:W3#1'],
    ...done('p4', 'plan:W4'),
    ['started', 'i4', 'implement:W4'],
    ...done('i6', 'implement:W6'),
    ...done('e6', 'escalate:W6', { action: 'block', reason: 'needs a product decision on sampling' }),
    ...done('s6', 'salvage:W6'),
  )
  const merged = 'W1\tabc123\nW2\tdef456\n'

  test('done, live stage, waiting, blocked, waiting on a blocked item, cut', () => {
    const out = derive(run(), files({ merged }), ok(live))
    expect(out.finished).toBe(false)
    expect(out.band).toMatchObject({ slug: 'staged-typecheck-overlay', phase: 'build', detail: '2/8 merged', source: 'journal' })
    expect(rowsOf(out)).toEqual({
      W1: '✓ done',
      W2: '✓ done',
      W3: '● review r2',
      W4: '● implement',
      W5: '◌ waiting on W3, W4',
      W6: '✕ blocked: needs a product decision on sampling',
      W7: '◌ waiting on W6 (blocked)',
      W8: '– cut: out of scope',
    })
  })

  test('a dependency the escalation adds mid-run is waited on; one that would cycle is not applied', () => {
    const items = [{ id: 'W1', title: 'a', deps: [] }, { id: 'W2', title: 'b', deps: [] }, { id: 'W3', title: 'c', deps: ['W2'] }]
    const text = journal(
      ...done('p1', 'plan:W1'), ...done('p2', 'plan:W2'), ...done('p3', 'plan:W3'),
      ...done('r', 'reconcile:W1+W2+W3', { clean: false, issues: ['W2 needs W1'] }),
      ...done('e', 'escalate:W1+W2+W3', { replan: ['W2'], cut: [], blocked: [],
        addDeps: [{ id: 'W2', dependsOn: ['W1'] }, { id: 'W1', dependsOn: ['W3'] }] }),
      ...done('a2', 'plan-archive:W2#deferred'),
      ['started', 'i1', 'implement:W1'],
    )
    expect(rowsOf(derive(run({ items }), files(), ok(text)))).toEqual({
      W1: '● implement',
      W2: '◌ waiting on W1',
      W3: '◌ waiting on W2',
    })
    // The launch's own item list is never mutated.
    expect(items[1]?.deps).toEqual([])
  })

  test('the hook-mode verb calls read as plumbing or their stage', () => {
    expect(classifyLabel('run-lease')).toBe(null)
    expect(classifyLabel('worktree:W1')).toEqual({ kind: 'item', ids: ['W1'], stage: 'worktree' })
  })

  test('a torn last line and a garbled line are skipped, not fatal', () => {
    const text = journal(...done('p1', 'plan:W1'), ['started', 'i1', 'implement:W1']) +
      'not json at all\n' +
      '{"type":"result","key":"i1","agentId":"a-i1","res'
    const out = derive(run({ items: [{ id: 'W1', title: 'a', deps: [] }] }), files(), ok(text))
    expect(rowsOf(out)).toEqual({ W1: '● implement' })
  })

  test('review and fix rounds, worktree, commit and merge stages, integration in the header', () => {
    const one = [{ id: 'W1', title: 'a', deps: [] }]
    const at = (label: string) => rowsOf(derive(run({ items: one }), files(), ok(journal(['started', 'k', label])))).W1
    expect(at('review:W1#0')).toBe('● review r1')
    expect(at('review:W1#2~retry')).toBe('● review r3')
    expect(at('fix:W1#2')).toBe('● fix r2')
    expect(at('commit-verify:W1#1')).toBe('● commit')
    expect(at('merge-reset:W1')).toBe('● merge')
    expect(at('plan:W1#rebuild')).toBe('● replan')
    const integ = derive(run({ items: one }), files({ merged: 'W1\tabc\n' }),
      ok(journal(...done('m', 'merge-finalize:W1'), ...done('v', 'integration-verify'), ['started', 'r', 'review:integration#0'])))
    expect(integ.band?.phase).toBe('integrate · review r1')
    expect(integ.band?.detail).toBe('1/1 merged')
  })

  test('without a readable journal, files give a coarse state', () => {
    const items = [
      { id: 'W1', title: 'a', deps: [] }, { id: 'W2', title: 'b', deps: [] },
      { id: 'W3', title: 'c', deps: [] }, { id: 'W4', title: 'd', deps: ['W3', 'W1'] },
    ]
    const f = files({
      merged: 'W3\tabc\n',
      plans: ['W1.md', 'W2.md'],
      reviews: [{ name: 'W2-codex.round0.json', mtimeMs: 1 }, { name: 'W2-codex.json', mtimeMs: 1 }],
    })
    for (const j of [{ status: 'missing' }, { status: 'unreadable' }, { status: 'too-large' }] as JournalRead[]) {
      const out = derive(run({ items }), f, j)
      expect(out.band?.source).toBe('files')
      expect(rowsOf(out)).toEqual({ W1: '● planning done', W2: '● reviewed r1', W3: '✓ done', W4: '◌ waiting on W1' })
    }
  })

  test('the item list falls back to the last Workflow args line in spec.md', () => {
    const args = { runDir: RUN_DIR, items: [{ id: 'W9', title: 'late', deps: [], files: [] }] }
    const text = `# Spec\n\n**Workflow run:** wf_0\n**Workflow args:** {"items": []}\n**Workflow run:** wf_1\n**Workflow args:** ${JSON.stringify(args)}\n`
    expect(rowsOf(derive(run({ items: [] }), files({ spec: { mtimeMs: 1, text } }), { status: 'missing' })))
      .toEqual({ W9: '○ queued' })
  })
})

describe('finish', () => {
  test('a report written since the launch ends the run; an older one does not', () => {
    expect(derive(run(), files({ reportMtimeMs: 2000 }), { status: 'missing' })).toEqual({ finished: true, band: null })
    expect(derive(run(), files({ reportMtimeMs: 500 }), { status: 'missing' }).finished).toBe(false)
  })

  test('a run directory that is gone ends it', () => {
    expect(derive(run(), files({ runDirExists: false }), { status: 'missing' }).finished).toBe(true)
  })

  test('task notifications are read by id and status', () => {
    const text = '<task-notification>\n<task-id>wb1</task-id>\n<status>completed</status>\n</task-notification>\n' +
      '<task-notification>\n<task-id>wc9</task-id>\n<status>failed</status>\n</task-notification>'
    expect(parseTaskNotifications(text)).toEqual([{ taskId: 'wb1', status: 'completed' }, { taskId: 'wc9', status: 'failed' }])
    expect(parseTaskNotifications('hello')).toEqual([])
  })
})

test('rows fit the width they are given', () => {
  const rows = [
    { id: 'W1', title: 'A very long title that will not fit in a narrow band', mark: '●', status: 'implement', tone: 'live' as const },
    { id: 'W10', title: 'Short', mark: '✕', status: `blocked: ${'x'.repeat(200)}`, tone: 'blocked' as const },
  ]
  for (const columns of [40, 60, 120]) {
    for (const line of layoutRows(rows, columns)) expect((line.lead + line.tail).length).toBeLessThanOrEqual(columns)
  }
  const [first] = layoutRows(rows, 60)
  expect(first?.lead.startsWith('  W1   A very')).toBe(true)
})

// ---------- the hooks module against the engine ----------

const WORK_LOOP = '/plugins/orca/scripts/work-loop.workflow.js'
const SPEC = '/plugins/orca/scripts/spec.workflow.js'
const BAND = {
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 19 }, view: {} },
}

type Node = { text: string; mtimeMs: number }

// The run directory and the journal, served beneath the plugin: each call on
// $.fs answers { value }, or { deny } where the real one would reject.
function serveFiles(on: On, disk: Map<string, Node>) {
  const isDir = (p: string) => [...disk.keys()].some(k => k.startsWith(`${p}/`))
  on('fs.stat', ($, e) => {
    const f = disk.get(e.path)
    if (f) return { value: { kind: 'file' as const, size: f.text.length, mtimeMs: f.mtimeMs, isLink: false } }
    if (isDir(e.path)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false } }
    return { deny: `ENOENT: ${e.path}` }
  })
  on('fs.exists', ($, e) => ({ value: disk.has(e.path) || isDir(e.path) }))
  on('fs.read', ($, e) => {
    const f = disk.get(e.path)
    return f ? { value: f.text } : { deny: `ENOENT: ${e.path}` }
  })
  on('fs.list', ($, e) => {
    if (!isDir(e.path)) return { deny: `ENOENT: ${e.path}` }
    const names = new Map<string, { kind: 'file' | 'dir'; mtimeMs: number; size: number }>()
    for (const [k, f] of disk) {
      if (!k.startsWith(`${e.path}/`)) continue
      const [name, ...more] = k.slice(e.path.length + 1).split('/')
      if (!name) continue
      names.set(name, more.length ? { kind: 'dir', mtimeMs: 0, size: 0 } : { kind: 'file', mtimeMs: f.mtimeMs, size: f.text.length })
    }
    return { value: [...names].map(([name, x]) => ({ name, ...x, isLink: false })) }
  })
}

function launches(on: On, taskId: string, runId: string) {
  on('tool.call', { tool: 'Workflow' }, () => ({
    result: { status: 'async_launched', taskId, taskType: 'local_workflow', runId,
      transcriptDir: JOURNAL.replace(/\/journal\.jsonl$/, '').replace('wf_1', runId) },
  }))
}

function engineBand(on: On) {
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return Text({ children: 'engine band' })
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('session.surfaces', () => ({ value: ['terminal' as const] }))
}

describe('the band in a session', () => {
  test('a work-loop launch draws the items; a fresh report.md takes the band down', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = new Map<string, Node>([
      [`${RUN_DIR}/brief.md`, { text: 'brief', mtimeMs: 1 }],
      [`${RUN_DIR}/spec.md`, { text: 'spec', mtimeMs: 2 }],
      [`${RUN_DIR}/merged.tsv`, { text: 'W1\tabc\n', mtimeMs: 10_100 }],
      [JOURNAL, { text: journal(...done('m1', 'merge-finalize:W1'), ['started', 'i2', 'implement:W2']), mtimeMs: 10_200 }],
    ])
    serveFiles(on, disk)
    launches(on, 'task1', 'wf_1')
    engineBand(on)

    await $.tool.call({ tool: 'Workflow', scriptPath: WORK_LOOP, args: {
      runDir: RUN_DIR, slug: 'staged-typecheck-overlay', integrationBranch: 'feature/staged-typecheck-overlay',
      items: [{ id: 'W1', title: 'Overlay view layers', deps: [], files: [] },
        { id: 'W2', title: 'Whiteout collector', deps: [], files: [] },
        { id: 'W3', title: 'CLI flag wiring', deps: ['W1', 'W2'], files: [] }] } })
    await clock.settle()

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'orca', surface, ...BAND })
      expect(await ui.find({ type: 'Text', text: 'staged-typecheck-overlay · build · 1/3 merged' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '✓ done' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '● implement' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '◌ waiting on W2' })).toBeDefined()
      await ui.unmount()
    }

    // The journal moves on; the next tick redraws.
    disk.set(JOURNAL, { text: journal(...done('m1', 'merge-finalize:W1'), ...done('i2', 'implement:W2'),
      ['started', 'v2', 'review:W2#0']), mtimeMs: 11_000 })
    await clock.advance(1500)
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: '● review r1' })).toBeDefined()

    // The skill writes report.md once the loop returns: the band goes.
    disk.set(`${RUN_DIR}/report.md`, { text: 'report', mtimeMs: 12_000 })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: /orca/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })

  test('the work loop\'s task notification takes the band down', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    serveFiles(on, new Map([[`${RUN_DIR}/spec.md`, { text: 'spec', mtimeMs: 2 }]]))
    launches(on, 'task7', 'wf_7')
    engineBand(on)
    await $.tool.call({ tool: 'Workflow', scriptPath: WORK_LOOP, args: { runDir: RUN_DIR, items: [{ id: 'W1', title: 'a', deps: [], files: [] }] } })
    await clock.settle()
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: '○ queued' })).toBeDefined()

    // Another task's notification changes nothing; this one's ends the run.
    await $.prompt.submit({ text: '<task-notification>\n<task-id>other</task-id>\n<status>completed</status>\n</task-notification>',
      wait: false, origin: { kind: 'task-notification' } })
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: '○ queued' })).toBeDefined()
    await $.prompt.submit({ text: '<task-notification>\n<task-id>task7</task-id>\n<status>completed</status>\n</task-notification>',
      wait: false, origin: { kind: 'task-notification' } })
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })

  test('a spec launch shows one line, stays through the checkpoint, and leaves when abandoned', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    const disk = new Map<string, Node>([[`${RUN_DIR}/brief.md`, { text: 'brief', mtimeMs: 1 }]])
    serveFiles(on, disk)
    launches(on, 'spec1', 'wf_s')
    engineBand(on)
    await $.tool.call({ tool: 'Workflow', scriptPath: SPEC, args: { runDir: RUN_DIR, prompt: 'p', reviewWorktree: '/wt', reviewer: 'codex' } })
    await clock.settle()
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: 'staged-typecheck-overlay · spec · drafting' })).toBeDefined()
    expect(await ui.findAll({ type: 'Text' })).toHaveLength(2)

    disk.set(`${RUN_DIR}/spec.md`, { text: 'spec', mtimeMs: 11_000 })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: /spec · in review/ })).toBeDefined()

    disk.set(`${RUN_DIR}/reviews/spec-codex.json`, { text: '{}', mtimeMs: 11_500 })
    await $.prompt.submit({ text: '<task-notification>\n<task-id>spec1</task-id>\n<status>completed</status>\n</task-notification>',
      wait: false, origin: { kind: 'task-notification' } })
    await clock.advance(1500)
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: /spec · ready/ })).toBeDefined()

    // The checkpoint: the person talks it over, then walks away.
    await $.prompt.submit({ text: 'looks good but why W3?', wait: false, origin: { kind: 'composer' } })
    await $.prompt.submit({ text: 'hm', wait: false, origin: { kind: 'composer' } })
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: /spec · ready/ })).toBeDefined()
    await $.prompt.submit({ text: 'something else entirely', wait: false, origin: { kind: 'composer' } })
    await ui.redraw()
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })

  test('other workflows are not followed', async ($, on) => {
    const clock = mock.clock(on, { now: 10_000 })
    serveFiles(on, new Map([[`${RUN_DIR}/brief.md`, { text: 'brief', mtimeMs: 1 }]]))
    launches(on, 'r1', 'wf_r')
    engineBand(on)
    await $.tool.call({ tool: 'Workflow', scriptPath: '/plugins/orca/scripts/research.workflow.js', args: { runDir: RUN_DIR, prompt: 'p' } })
    await clock.settle()
    const ui = await $.ui.mount({ plugin: 'orca', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  })
})
