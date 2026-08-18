// Run a *.workflow.js script the way the Workflow host does — exports
// hoisted out, body wrapped in an async function — with the sandbox globals
// stubbed, so bats can assert on arg validation and return shapes.
//
// usage: node run-workflow.js <script> <args-json> <responses-json>
//
// <responses-json> is an array consumed in order, one entry per agent()
// call; {"die": true} makes that call return null (a skipped/dead agent).
// Prints one JSON line: {ok, result?, error?, calls: [{prompt, opts}]} —
// ok:false carries a launch-validation or runtime throw in `error`.
'use strict'
const { readFileSync } = require('node:fs')
const vm = require('node:vm')

const [, , file, argsJson, responsesJson] = process.argv
const src = readFileSync(file, 'utf8').replace(/^export /gm, '')
const responses = JSON.parse(responsesJson)
const calls = []

const sandbox = {
  args: JSON.parse(argsJson),
  log: () => {},
  phase: () => {},
  agent: async (prompt, opts) => {
    calls.push({ prompt, opts })
    const r = responses.shift()
    if (r === undefined) throw new Error(`agent() call #${calls.length} has no scripted response`)
    return r && r.die ? null : r
  },
  parallel: async (thunks) => Promise.all(thunks.map(t => t().catch(() => null))),
  pipeline: async () => { throw new Error('pipeline() is not stubbed in this harness') },
  workflow: async () => { throw new Error('workflow() is not stubbed in this harness') },
  budget: { total: null, spent: () => 0, remaining: () => Infinity },
}
vm.createContext(sandbox)

Promise.resolve()
  .then(() => new vm.Script(`(async () => {\n${src}\n})()`, { filename: file }).runInContext(sandbox))
  .then(
    result => process.stdout.write(JSON.stringify({ ok: true, result, calls }) + '\n'),
    err => process.stdout.write(JSON.stringify({ ok: false, error: String((err && err.message) || err), calls }) + '\n'),
  )
