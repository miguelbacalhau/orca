// The claim's release on session end: an objective's claim lasts as long as
// the session that took it. When the session ends — exit, /clear, /resume
// into another conversation, logout, a signal — every objective claim that
// names it is dropped, so the objective is free the moment its session is
// gone, and the conversation a /clear starts in the same process does not
// read its own terminal's old claim as another session's.
//
// The hooks module never writes objective files itself: the owner files are
// read here only to see whether there is anything to release, and the
// removal is `orca.sh objective release <repo> --session <id>`, which re-reads
// each under the claim lock and removes it only while it still names the
// ending session. One fixed, narrow verb, so it runs whatever the permission
// mode — unlike the verb hook (./relay.ts), which runs only in
// bypassPermissions sessions. It is run through bands.tsx's session.end hook,
// the module's one hook on that event.
//
// A session that ends without it (a crash, kill -9, the hook not loaded, the
// end's time bound spent) leaves its claim behind; the verbs judge that one
// stale once its process is gone, or once its process goes on under another
// session id.

import { atom, read } from 'claude-code'
import type { EngineInterface } from 'claude-code'

import { ownerSession } from './derive-objective'
import { repoRootOf } from './objective-band'
import { listNames, readCached } from './read-cache'

// The objective band's objective: its repository is looked in too.
const objectiveAtom = atom({ plugin: 'orca', key: 'objective' } as const, null)

const OBJECTIVE_NAME = /^\d{8}-\d{6}-[a-z0-9]+(-[a-z0-9]+)*$/
// The verb's wait on a held claim lock, in 0.2 s checks: inside the end's
// short bound.
const LOCK_TRIES = '4'
// The longest the verb may run where nothing bounds the end (a test).
const MAX_RUN_MS = 10_000

// Whether an objective of <repoRoot> holds an owner file naming <sessionId>.
async function holdsClaim($: EngineInterface, repoRoot: string, sessionId: string): Promise<boolean> {
  const root = `${repoRoot}/.orca/objectives`
  for (const entry of await listNames($, root)) {
    if (!OBJECTIVE_NAME.test(entry.name)) continue
    const owner = await readCached($, `${root}/${entry.name}/owner`)
    if (owner.status === 'ok' && ownerSession(owner.text) === sessionId) return true
  }
  return false
}

export function releaseArgv(pluginRoot: string, repoRoot: string, sessionId: string): string[] {
  return ['bash', `${pluginRoot.replace(/\/+$/, '')}/scripts/orca.sh`, 'objective', 'release', repoRoot, '--session', sessionId]
}

// Releases the ending session's claims in the repository the session's cwd
// is in and the one its objective band follows. <remainingMs> is what is
// left of the end's time bound.
export async function releaseClaims($: EngineInterface, sessionId: string, remainingMs: number) {
  if (!sessionId) return
  const roots = new Set<string>()
  try {
    const followed = await read($, objectiveAtom)
    if (followed?.repoRoot) roots.add(followed.repoRoot)
  } catch { /* the cwd's repository still counts */ }
  try {
    const here = await repoRootOf($)
    if (here) roots.add(here)
  } catch { /* the followed repository still counts */ }
  for (const repoRoot of roots) {
    if (!(await holdsClaim($, repoRoot, sessionId))) continue
    const timeoutMs = Math.max(100, Math.min(MAX_RUN_MS, Math.floor(remainingMs)))
    try {
      await $.process.run(releaseArgv($.plugin.root, repoRoot, sessionId),
        { timeoutMs, env: { ORCA_OBJ_LOCK_TRIES: LOCK_TRIES } })
    } catch { /* the claim stays; the verbs judge it once the session is gone */ }
  }
}
