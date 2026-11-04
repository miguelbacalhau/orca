// orca's hooks module: the run band (./run-band.tsx) and the objective band
// (./objective-band.tsx), drawn above the prompt through their shared slot
// (./bands.tsx), and the verb hook (./relay.ts), which answers the work loop's
// orca.sh verb calls without a model. hooks.json names one module, so this one
// registers all three parts.

import type { Register } from 'claude-code'

import { register as bands } from './bands'
import { register as objectiveBand } from './objective-band'
import { register as relay } from './relay'
import { register as runBand } from './run-band'

export const register: Register = (on, options) => {
  runBand(on, options)
  objectiveBand(on, options)
  bands(on, options)
  relay(on, options)
}
