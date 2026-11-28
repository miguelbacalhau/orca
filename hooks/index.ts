// orca's hooks module: the run band (./run-band.tsx) and the objective band
// (./objective-band.tsx), drawn above the prompt through their shared slot
// (./bands.tsx), whose session.end hook also releases the ending session's
// objective claims (./claim-release.ts), the verb hook (./relay.ts), which
// answers the work loop's orca.sh verb calls without a model, the pin hook
// (./pin.ts), which starts stage agents in the worktree their task message
// names, and the switch hook (./switch.ts), which approves the session's move
// into the worktree of the objective it has claimed. hooks.json names one
// module, so this one registers all five parts.

import type { Register } from 'claude-code'

import { register as bands } from './bands'
import { register as objectiveBand } from './objective-band'
import { register as pin } from './pin'
import { register as relay } from './relay'
import { register as runBand } from './run-band'
import { register as switchHook } from './switch'

export const register: Register = (on, options) => {
  runBand(on, options)
  objectiveBand(on, options)
  bands(on, options)
  relay(on, options)
  pin(on, options)
  switchHook(on, options)
}
