// orca's $.state contract: what the hooks module keeps in $.state so it
// survives a hot reload — the run band's run and band (hooks/run-band.tsx),
// and the verb hook's permission gate (hooks/relay.ts).

// One work item as the work-loop launch passed it.
export type OrcaItem = { id: string; title: string; deps: string[] }

// The one orca workflow this session launched and the band follows.
export type OrcaRun = {
  // `spec` for spec.workflow.js, `build` for work-loop.workflow.js.
  kind: 'spec' | 'build'
  runDir: string
  slug: string
  runId: string
  taskId: string
  // <transcriptDir>/journal.jsonl from the launch result; null when the
  // result carried no transcript directory and none could be derived.
  journal: string | null
  // When the launch was seen (ms since the epoch): run files older than
  // this belong to an earlier launch over the same run directory.
  since: number
  items: OrcaItem[]
  // The iterate skill's amendment file, when the spec launch passed one.
  amendPath: string | null
  // The spec workflow's task notification arrived with status completed.
  specEnded: boolean
  // Prompts the person sent since the spec became ready with no launch.
  idlePrompts: number
}

export type OrcaTone = 'done' | 'live' | 'wait' | 'blocked' | 'cut' | 'queued'

export type OrcaRow = { id: string; title: string; mark: string; status: string; tone: OrcaTone }

// What the band draws; null draws nothing.
export type OrcaBand = {
  slug: string
  // `spec`, `build`, `integrate` or `integrate · <stage>`, `wrapping up`.
  phase: string
  // The spec state, or `<merged>/<total> merged`.
  detail: string
  rows: OrcaRow[]
  // Whether item stages came from the workflow journal or from run files alone.
  source: 'journal' | 'files'
}

declare module 'claude-code' {
  interface PluginState {
    orca: {
      run: OrcaRun | null
      band: OrcaBand | null
      // The session's permission mode as the classic hook events last
      // reported it; null until one has. The verb hook runs verbs only while
      // it is bypassPermissions.
      permissionMode: string | null
    }
  }
}
