// orca's hooks module: the run band (./run-band.tsx), drawn above the prompt,
// and the verb hook (./relay.ts), which answers the work loop's orca.sh verb
// calls without a model. hooks.json names one module, so this one registers both.

import type { Register } from 'claude-code'

import { register as relay } from './relay'
import { register as runBand } from './run-band'

export const register: Register = (on, options) => {
  runBand(on, options)
  relay(on, options)
}
