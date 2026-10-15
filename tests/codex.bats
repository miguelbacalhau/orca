#!/usr/bin/env bats
# orca.sh codex — the cross-model reviewer's transport, against a stubbed
# codex CLI. The verb's whole job is that a review either lands verbatim or
# lands nowhere, so every case here checks BOTH the frame and the disk.

load helpers

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/child.pid" ]; then
    kill -KILL "$(cat "$BATS_TEST_TMPDIR/child.pid")" 2>/dev/null || true
  fi
}

# A fake codex whose `exec` behavior one argument selects. It parses
# --output-last-message the way the real CLI does, so the verb's contract
# with that flag is exercised, not assumed.
#   ok        — writes a conforming findings payload
#   empty     — exits 0 writing nothing
#   prose     — writes a refusal instead of JSON
#   halfjson  — writes a JSON object with no findings key
#   crash     — exits 3 with a message on stderr
#   hang      — sleeps past any sane cap
#   fixture   — copies PAYLOAD_FIXTURE verbatim
#   claims    — writes a conforming council claims payload
# It records the --model it was given (empty when none) and the schema
# file's basename beside the stub, for the council cases to assert on.
make_codex_exec_stub() { # <bindir> <behavior>
  mkdir -p "$1"
  cat >"$1/codex" <<EOF
#!/usr/bin/env bash
[ "\$1" = exec ] || { echo "stub: expected the exec subcommand, got \$1" >&2; exit 64; }
shift
out="" schema="" sandbox="" cd_to="" model=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --model)               model="\$2"; shift 2 ;;
    --output-last-message) out="\$2"; shift 2 ;;
    --output-schema)       schema="\$2"; shift 2 ;;
    --sandbox)             sandbox="\$2"; shift 2 ;;
    --cd)                  cd_to="\$2"; shift 2 ;;
    -)  shift ;;
    *)  echo "stub: unexpected argument \$1" >&2; exit 64 ;;
  esac
done
# The transport's safety and schema guarantees are asserted HERE, at the
# process boundary, so dropping any of them from the verb turns the whole
# suite red instead of passing quietly.
[ -n "\$out" ]              || { echo "stub: no --output-last-message" >&2; exit 64; }
[ "\$sandbox" = read-only ] || { echo "stub: sandbox was '\$sandbox', not read-only" >&2; exit 64; }
[ -d "\$cd_to" ]            || { echo "stub: --cd '\$cd_to' is not a directory" >&2; exit 64; }
[ "\$cd_to" = "\$PWD" ]     || { echo "stub: ran in \$PWD, not the --cd target \$cd_to" >&2; exit 64; }
[ -s "\$schema" ]           || { echo "stub: --output-schema '\$schema' is not a file" >&2; exit 64; }
grep -qE '"(findings|claims)"' "\$schema" || { echo "stub: schema describes neither findings nor claims" >&2; exit 64; }
printf '%s' "\$model" >"$1/seen-model"
basename "\$schema" >"$1/seen-schema"
case "$2" in
  ok)       printf '{"findings":[{"severity":"High","file":"a.txt","line":1,"title":"t","body":"b","fix_location":"local code"}]}' >"\$out" ;;
  empty)    : ;;
  prose)    printf 'I cannot review this.' >"\$out" ;;
  halfjson) printf '{"error":"no"}' >"\$out" ;;
  crash)    echo "codex: stream error" >&2; exit 3 ;;
  hang)     sleep 30 ;;
  fixture)  cp "\$PAYLOAD_FIXTURE" "\$out" ;;
  claims)   printf '{"summary":"s","claims":[{"claim":"c","evidence":["a.txt:1"],"confidence":"high"}],"open_questions":[]}' >"\$out" ;;
esac
EOF
  chmod +x "$1/codex"
}

# run_codex <behavior> [extra args...] — prompt, cwd, and out are fixed;
# OUT/ARCHIVE are the paths every test asserts against.
run_codex() {
  local behavior="$1"; shift
  make_codex_exec_stub "$BATS_TEST_TMPDIR/stub" "$behavior"
  mkdir -p "$BATS_TEST_TMPDIR/wt"
  printf 'review this\n' >"$BATS_TEST_TMPDIR/prompt.md"
  OUT="$BATS_TEST_TMPDIR/reviews/W-01-codex.json"
  ARCHIVE="$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$OUT" "$@"
}

@test "a clean review lands byte-identical at both paths" {
  run_codex ok --archive "$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  [ "$status" -eq 0 ]
  has_line 'rc=0'
  has_line 'status=ok'
  [ -f "$OUT" ]
  cmp -s "$OUT" "$ARCHIVE"
  # Verbatim, and the parent directory was created for it.
  [ "$(cat "$OUT")" = '{"findings":[{"severity":"High","file":"a.txt","line":1,"title":"t","body":"b","fix_location":"local code"}]}' ]
}

@test "the archive is optional and reported absent when not asked for" {
  run_codex ok
  [ "$status" -eq 0 ]
  has_line 'status=ok'
  has_line 'archive=-'
  [ ! -f "$ARCHIVE" ]
}

@test "a codex that writes nothing is no_output, and writes nothing" {
  run_codex empty --archive "$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  [ "$status" -eq 0 ]
  has_line 'rc=1'
  has_line 'status=no_output'
  [ ! -e "$OUT" ]
  [ ! -e "$ARCHIVE" ]
}

@test "prose instead of JSON is bad_payload, never an artifact" {
  run_codex prose
  has_line 'rc=1'
  has_line 'status=bad_payload'
  [ ! -e "$OUT" ]
}

@test "a JSON object without findings is bad_payload" {
  run_codex halfjson
  has_line 'rc=1'
  has_line 'status=bad_payload'
  [ ! -e "$OUT" ]
}

@test "a nonzero codex is exec_failed and carries its output in the tail" {
  run_codex crash
  has_line 'rc=1'
  has_line 'status=exec_failed'
  [ ! -e "$OUT" ]
  # The tail is the only channel that reaches a human mid-run, so it must
  # actually carry codex's own words.
  tail_b64="$(printf '%s\n' "$output" | sed -n 's/^tail\.b64=//p')"
  printf '%s' "$tail_b64" | base64 --decode | grep -q 'stream error'
}

@test "a wedged codex is killed at the cap and reported as a timeout" {
  run_codex hang --timeout 1
  has_line 'rc=1'
  has_line 'status=timeout'
  [ ! -e "$OUT" ]
}

@test "timeout finishes killing children after the codex parent exits on TERM" {
  mkdir -p "$BATS_TEST_TMPDIR/stub" "$BATS_TEST_TMPDIR/wt"
  cat >"$BATS_TEST_TMPDIR/stub/codex" <<'STUB'
#!/usr/bin/env bash
bash -c '
  trap "" TERM
  echo $$ >"$WATCHDOG_DIR/child.pid"
  for ((i=0; i<300; i++)); do
    printf x >>"$WATCHDOG_DIR/heartbeat"
    sleep 0.1
  done
' &
wait
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub/codex"
  printf 'review\n' >"$BATS_TEST_TMPDIR/prompt.md"
  WATCHDOG_DIR="$BATS_TEST_TMPDIR" PATH="$BATS_TEST_TMPDIR/stub:$PATH" \
    run bash "$SCRIPTS/orca.sh" codex "$BATS_TEST_TMPDIR/prompt.md" \
    --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/out.json" --timeout 1
  has_line 'status=timeout'
  [ ! -e "$BATS_TEST_TMPDIR/out.json" ]
  # A heartbeat tests actual execution, including on systems where a dead
  # orphan remains a zombie briefly and kill -0 would still succeed.
  [ -s "$BATS_TEST_TMPDIR/heartbeat" ]
  cp "$BATS_TEST_TMPDIR/heartbeat" "$BATS_TEST_TMPDIR/stopped"
  sleep 0.3
  cmp -s "$BATS_TEST_TMPDIR/stopped" "$BATS_TEST_TMPDIR/heartbeat"
}

# The "lands verbatim or lands nowhere" contract is only interesting when
# something is already there — a re-review round's destination usually is.
@test "a failed review leaves an existing artifact untouched" {
  run_codex ok --archive "$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  [ "$status" -eq 0 ]
  round1="$(cat "$OUT")"
  run_codex prose
  has_line 'status=bad_payload'
  [ "$(cat "$OUT")" = "$round1" ]
}

@test "a truncated payload is bad_payload, not a half-written artifact" {
  mkdir -p "$BATS_TEST_TMPDIR/stub" "$BATS_TEST_TMPDIR/wt"
  cat >"$BATS_TEST_TMPDIR/stub/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac
done
printf '{"findings":[{"severity":"High"' >"$out"
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub/codex"
  printf 'p\n' >"$BATS_TEST_TMPDIR/prompt.md"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/o.json"
  has_line 'status=bad_payload'
  [ ! -e "$BATS_TEST_TMPDIR/o.json" ]
}

@test "malformed JSON never replaces an existing artifact or archive" {
  run_codex ok --archive "$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  has_line 'status=ok'
  cp "$OUT" "$BATS_TEST_TMPDIR/original.json"
  export PAYLOAD_FIXTURE="$BATS_TEST_TMPDIR/payload.json"
  local payload
  while IFS= read -r payload; do
    printf '%s' "$payload" >"$PAYLOAD_FIXTURE"
    run_codex fixture --archive "$ARCHIVE"
    has_line 'status=bad_payload'
    cmp -s "$OUT" "$BATS_TEST_TMPDIR/original.json"
    cmp -s "$ARCHIVE" "$BATS_TEST_TMPDIR/original.json"
  done <<'PAYLOADS'
{"findings":[{"severity":"High","file":"a","line":1,"title":"t","body":"b","fix_location":"local code"}
{"findings":[{"body":"unterminated }]}
{"findings":[{"body":"bad\q"}]}
{"findings":[{"body":"bad\u123"}]}
{"findings":[{"line":01}]}
{"findings":[{"line":1.}]}
{"findings":[{"severity" "High"}]}
{"findings":[{"severity":"High" "body":"b"}]}
{"findings":[{"severity":"High",}]}
{"findings":[,]}
{"findings":[],}
{"findings":[]}{"findings":[]}
{"findings":[]} trailing
{"nested":{"findings":[]}}
{"findings":null}
{"findings":[],"findings":null}
PAYLOADS
}

@test "complete JSON with escaped strings and CRLF lands verbatim" {
  export PAYLOAD_FIXTURE="$BATS_TEST_TMPDIR/payload.json"
  cat >"$PAYLOAD_FIXTURE" <<'PAYLOAD'
{
  "\u0066indings": [{
    "severity": "High", "file": null, "line": 123,
    "title": "Quotes: \" and backslashes: \\",
    "body": "Literal delimiters: } ] { [ ; escapes: \n\t\r\b\f\/\u00e9 ; UTF-8: café 🐋",
    "fix_location": "local code"
  }]
}
PAYLOAD
  # Valid trailing whitespace is not limited to the last 200 bytes.
  printf '%300s\r\n' '' >>"$PAYLOAD_FIXTURE"
  awk '{ printf "%s\r\n", $0 }' "$PAYLOAD_FIXTURE" >"$BATS_TEST_TMPDIR/crlf.json"
  PAYLOAD_FIXTURE="$BATS_TEST_TMPDIR/crlf.json"
  run_codex fixture --archive "$BATS_TEST_TMPDIR/reviews/W-01-codex.round1.json"
  has_line 'status=ok'
  cmp -s "$OUT" "$PAYLOAD_FIXTURE"
  cmp -s "$ARCHIVE" "$PAYLOAD_FIXTURE"
}

# A relative prompt path is opened by the child AFTER it has changed into
# the worktree, so without canonicalization it resolves somewhere else.
@test "relative paths are resolved against the caller, not the worktree" {
  make_codex_exec_stub "$BATS_TEST_TMPDIR/stub" ok
  mkdir -p "$BATS_TEST_TMPDIR/here" "$BATS_TEST_TMPDIR/wt"
  printf 'review this\n' >"$BATS_TEST_TMPDIR/here/prompt.md"
  cd "$BATS_TEST_TMPDIR/here"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    prompt.md --cwd ../wt --out out.json
  [ "$status" -eq 0 ]
  has_line 'status=ok'
  [ -f "$BATS_TEST_TMPDIR/here/out.json" ]
}

@test "a path that would inject a frame key is refused up front" {
  make_codex_exec_stub "$BATS_TEST_TMPDIR/stub" ok
  mkdir -p "$BATS_TEST_TMPDIR/wt"
  printf 'p\n' >"$BATS_TEST_TMPDIR/prompt.md"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" \
    --out "$(printf '%s\nstatus=timeout' "$BATS_TEST_TMPDIR/o.json")"
  [ "$status" -eq 1 ]
  has_line $'FAIL:\tBAD_ARGS\tpaths may not contain newlines'
}

@test "misuse fails typed, never as a frame" {
  make_codex_exec_stub "$BATS_TEST_TMPDIR/stub" ok
  mkdir -p "$BATS_TEST_TMPDIR/wt"
  printf 'p\n' >"$BATS_TEST_TMPDIR/prompt.md"

  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS'

  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/nope.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\tprompt file not found'

  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--out is required'

  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/gone" --out "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--cwd is not a directory'

  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/o.json" --timeout nope
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--timeout must be a positive integer'
}

@test "no codex on PATH fails typed NO_CODEX, naming the claude escape hatch" {
  mkdir -p "$BATS_TEST_TMPDIR/wt" "$BATS_TEST_TMPDIR/empty-bin"
  printf 'p\n' >"$BATS_TEST_TMPDIR/prompt.md"
  PATH="$BATS_TEST_TMPDIR/empty-bin:/usr/bin:/bin" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 1 ]
  has_line $'FAIL:\tNO_CODEX'
  [[ "$output" == *"reviewer=claude"* ]]
}

@test "the prompt reaches codex on stdin, unmangled" {
  mkdir -p "$BATS_TEST_TMPDIR/stub" "$BATS_TEST_TMPDIR/wt"
  # This stub echoes back what it was fed, so a quoting bug in the verb
  # shows up as a diff rather than as a mysteriously bad review.
  # STDIN_COPY, not a path derived from --output-last-message: the verb
  # writes that one inside a scratch dir it removes on the way out.
  cat >"$BATS_TEST_TMPDIR/stub/codex" <<'STUB'
#!/usr/bin/env bash
[ "$1" = exec ] || exit 64
shift
out=""
while [ $# -gt 0 ]; do
  case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac
done
cat >"$STDIN_COPY"
printf '{"findings":[]}' >"$out"
STUB
  chmod +x "$BATS_TEST_TMPDIR/stub/codex"
  printf 'line one: "quoted", `backticked`, $dollared\nline two: %% and \\ and $(nope)\n' \
    >"$BATS_TEST_TMPDIR/prompt.md"
  STDIN_COPY="$BATS_TEST_TMPDIR/seen-on-stdin" \
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash "$SCRIPTS/orca.sh" codex \
    "$BATS_TEST_TMPDIR/prompt.md" --cwd "$BATS_TEST_TMPDIR/wt" --out "$BATS_TEST_TMPDIR/o.json"
  [ "$status" -eq 0 ]
  has_line 'status=ok'
  # What codex read on stdin is the prompt file, byte for byte.
  cmp -s "$BATS_TEST_TMPDIR/prompt.md" "$BATS_TEST_TMPDIR/seen-on-stdin"
  # The payload is on disk, and an empty findings array is a clean pass.
  [ "$(cat "$BATS_TEST_TMPDIR/o.json")" = '{"findings":[]}' ]
}

# ---- the council's astra seat: --model and --schema ---------------------

@test "a review passes no model and the findings schema, as before" {
  run_codex ok
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stub/seen-model")" = "" ]
  [ "$(cat "$BATS_TEST_TMPDIR/stub/seen-schema")" = codex-findings.schema.json ]
}

@test "--model reaches codex exec and --schema council selects the claims schema" {
  run_codex claims --model gpt-6-astra --schema council
  [ "$status" -eq 0 ]
  has_line 'status=ok'
  [ "$(cat "$BATS_TEST_TMPDIR/stub/seen-model")" = gpt-6-astra ]
  [ "$(cat "$BATS_TEST_TMPDIR/stub/seen-schema")" = council-claims.schema.json ]
  [ "$(cat "$OUT")" = '{"summary":"s","claims":[{"claim":"c","evidence":["a.txt:1"],"confidence":"high"}],"open_questions":[]}' ]
}

@test "the payload guard follows the schema: findings under council is bad_payload" {
  run_codex ok --schema council
  has_line 'rc=1'
  has_line 'status=bad_payload'
  [ ! -f "$OUT" ]
}

@test "the payload guard follows the schema: claims under review is bad_payload" {
  run_codex claims
  has_line 'rc=1'
  has_line 'status=bad_payload'
  [ ! -f "$OUT" ]
}

@test "a bad --model or --schema fails typed before codex runs" {
  run_codex claims --model 'gpt 6; rm -rf /' --schema council
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--model must be a model id'
  [ ! -f "$BATS_TEST_TMPDIR/stub/seen-model" ]
  run_codex claims --schema verdicts
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--schema must be review or council'
  run_codex claims --model
  [ "$status" -eq 1 ]; has_line $'FAIL:\tBAD_ARGS\t--model needs a value'
}

@test "the bundled council schema matches the workflow's literal copy" {
  command -v node >/dev/null || skip "node not available"
  run node -e '
    const fs = require("fs")
    const file = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const src = fs.readFileSync(process.argv[2], "utf8")
    const m = src.match(/const CLAIMS = (\{[\s\S]*?\} \} \})\n/)
    if (!m) { console.log("no CLAIMS literal"); process.exit(1) }
    const lit = Function(`return (${m[1]})`)()
    const norm = o => Array.isArray(o) ? o.map(norm)
      : o && typeof o === "object" ? Object.keys(o).sort().reduce((a, k) => (a[k] = norm(o[k]), a), {}) : o
    const same = JSON.stringify(norm(file)) === JSON.stringify(norm(lit))
    console.log(same ? "SAME" : "DRIFT")
    process.exit(same ? 0 : 1)
  ' "$SCRIPTS/council-claims.schema.json" "$SCRIPTS/council.workflow.js"
  [ "$status" -eq 0 ]
  [ "$output" = SAME ]
}
