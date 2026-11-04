#!/usr/bin/env bats
# scripts/findings.awk — one TSV row per findings entry, over the shared
# JSON tokenizer (scripts/json-tokens.awk), in the POSIX awk envelope.

load helpers

# findings <json> — run the parser on a document given inline.
findings() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/doc.json"
  LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$BATS_TEST_TMPDIR/doc.json"
}

# row <n> — the n-th output row.
row() { printf '%s\n' "$output" | sed -n "${1}p"; }

# title_bytes <n> <file> — decode row n's base64 title into <file>.
title_bytes() { row "$1" | cut -f5 | base64 --decode >"$2"; }

@test "a review's findings array yields one row per entry in column order" {
  run findings '{"findings":[
    {"severity":"High","file":"scripts/a.sh","line":12,"title":"first","body":"b","fix_location":"local code"},
    {"severity":"Low","file":null,"line":null,"title":"second","body":"b","fix_location":"another work item"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(row 1)" = "$(printf 'gating\tlocal code\tscripts/a.sh\t\t%s' "$(printf first | base64)")" ]
  [ "$(row 2)" = "$(printf 'low\tanother work item\t\t\t%s' "$(printf second | base64)")" ]
}

@test "a response's findings array yields outcome and file, with absent severity gating" {
  run findings '{"checks":{"commands":["bats tests/"],"pass":true,"failure":""},
    "findings":[{"title":"fixed one","file":"x.sh","outcome":"fixed","reason":"r"},
                {"title":"declined one","file":null,"outcome":"declined","reason":"r"}],
    "followups":[{"title":"later","file":"y","why":"w"}],"status":"done","questions":[]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(row 1)" = "$(printf 'gating\t\tx.sh\tfixed\t%s' "$(printf 'fixed one' | base64)")" ]
  [ "$(row 2)" = "$(printf 'gating\t\t\tdeclined\t%s' "$(printf 'declined one' | base64)")" ]
}

@test "missing fields are empty columns, never shifted ones" {
  run findings '{"findings":[{}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'gating\t\t\t\t')" ]
}

@test "an empty findings array is no rows and success" {
  run findings '{"findings":[]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "severity: only a recognizable medium or low escapes gating" {
  run findings '{"findings":[
    {"severity":"Critical"},{"severity":"High"},{"severity":"Medium"},{"severity":"Low"},
    {"severity":"MEDIUM"},{"severity":"lOw"},{"severity":"  Medium\t"},
    {"severity":"Lo"},{"severity":"mediums"},{"severity":"minor"},{"severity":""},
    {"severity":null},{"severity":2},{"severity":["low"]},{"severity":{"v":"low"}},
    {"severity":"\u004cow"},{"title":"no severity"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = \
    "gating gating medium low medium low medium gating gating gating gating gating gating gating gating low gating " ]
}

@test "severity: control bytes around or inside medium/low gate; only JSON whitespace trims" {
  run findings '{"findings":[
    {"severity":"low\u0000"},{"severity":"\u0000low"},{"severity":"lo\u0000w"},
    {"severity":"low\u000b"},{"severity":"\fmedium"},{"severity":"medium\b"},
    {"severity":"low\u001f"},{"severity":"\t low\r\n"},{"severity":" \u004d\u0045dium "}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = \
    "gating gating gating gating gating gating gating low medium " ]
}

@test "titles with tabs, newlines, escapes, and unicode survive base64 byte for byte" {
  run findings '{"findings":[
    {"title":"tab\there\nnewline\r\n"},
    {"title":"quote \" backslash \\ slash \/ bf \b\f"},
    {"title":"escaped \u00e9 \u4e2d pair \ud83d\udc33 nul \u0000 end"},
    {"title":"raw café 中 🐋"},
    {"title":"lone \ud800 surrogate"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
  local got="$BATS_TEST_TMPDIR/got" want="$BATS_TEST_TMPDIR/want"
  title_bytes 1 "$got"; printf 'tab\there\nnewline\r\n' >"$want"; cmp "$got" "$want"
  title_bytes 2 "$got"; printf 'quote " backslash \\ slash / bf \b\f' >"$want"; cmp "$got" "$want"
  title_bytes 3 "$got"; printf 'escaped \303\251 \344\270\255 pair \360\237\220\263 nul \000 end' >"$want"; cmp "$got" "$want"
  title_bytes 4 "$got"; printf 'raw café 中 🐋' >"$want"; cmp "$got" "$want"
  title_bytes 5 "$got"; printf 'lone \357\277\275 surrogate' >"$want"; cmp "$got" "$want"
}

@test "base64 titles pad correctly at every length" {
  run findings '{"findings":[{"title":"a"},{"title":"ab"},{"title":"abc"},{"title":"abcd"},{"title":""}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f5 | tr '\n' ' ')" = "YQ== YWI= YWJj YWJjZA==  " ]
}

@test "control bytes in the plain columns become spaces, keeping five columns" {
  run findings '{"findings":[{"severity":"Low","file":"a\tb\nc","fix_location":"local\tcode","outcome":"fix\red","title":"t"}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$output" = "$(printf 'low\tlocal code\ta b c\tfix ed\t%s' "$(printf t | base64)")" ]
}

@test "keys match after unicode-escape decoding, at the root and in entries" {
  run findings '{"\u0066indings":[{"sev\u0065rity":"low","t\u0069tle":"x","fil\u0065":"f"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'low\t\tf\t\t%s' "$(printf x | base64)")" ]
}

@test "non-string and nested values are skipped, never read as a column" {
  run findings '{"meta":{"findings":[{"title":"decoy"}]},"findings":[
    {"severity":"Low","file":{"path":"a"},"title":["t"],"outcome":true,"body":{"title":"inner"},"fix_location":7}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'low\t\t\t\t')" ]
}

@test "a repeated key inside an entry takes the last value" {
  run findings '{"findings":[{"severity":"low","severity":"High"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'gating\t\t\t\t')" ]
}

@test "CRLF and pretty-printed documents parse like compact ones" {
  printf '{\r\n  "findings": [\r\n    {"severity": "Medium", "title": "t"}\r\n  ]\r\n}\r\n' >"$BATS_TEST_TMPDIR/doc.json"
  run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$BATS_TEST_TMPDIR/doc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'medium\t\t\t\t%s' "$(printf t | base64)")" ]
}

@test "a NUL byte anywhere in the file fails with no rows, even after a complete document" {
  local doc="$BATS_TEST_TMPDIR/nul.json" payload
  for payload in '{"findings":[{}]}\0{"findings":[' '{"findings":[{}]}\0' \
    '{"findings":[{"title":"a\0b"}]}' '{"findings":[{}]}\n\0\n' '\0{"findings":[{}]}'; do
    printf "$payload" >"$doc"
    run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$doc"
    if [ "$status" -eq 0 ] || [ -n "$output" ]; then
      echo "accepted: $payload -> status=$status output=$output"
      return 1
    fi
  done
}

@test "malformed UTF-8 anywhere in the file fails with no rows" {
  local doc="$BATS_TEST_TMPDIR/utf8.json" bytes
  # truncated 2/3/4-byte sequences, a stray continuation, overlong forms
  # (C0/C1, E0 80, F0 80), a UTF-8-encoded surrogate, above U+10FFFF
  # (F4 90, F5), and bytes that never start a sequence (FE, FF).
  for bytes in '\303' '\342\202' '\360\237\220' '\200' 'a\277b' \
    '\300\257' '\301\277' '\340\200\257' '\360\200\200\257' '\355\240\200' \
    '\364\220\200\200' '\365\200\200\200' '\376' '\377' '\342\202\342\202\254'; do
    printf '{"findings":[{"severity":"low","title":"x'"$bytes"'y"}]}' >"$doc"
    run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$doc"
    if [ "$status" -eq 0 ] || [ -n "$output" ]; then
      echo "accepted title bytes: $bytes -> status=$status output=$output"
      return 1
    fi
  done
  # Outside a string too: a bad byte in a key that is otherwise skipped.
  printf '{"k\377":1,"findings":[{"severity":"low"}]}' >"$doc"
  run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$doc"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "well-formed UTF-8 at every sequence-length boundary is accepted" {
  local doc="$BATS_TEST_TMPDIR/utf8.json" bytes got="$BATS_TEST_TMPDIR/got" want="$BATS_TEST_TMPDIR/want"
  # U+0080, U+07FF, U+0800, U+D7FF, U+E000, U+FFFF, U+10000, U+10FFFF
  for bytes in '\302\200' '\337\277' '\340\240\200' '\355\237\277' '\356\200\200' \
    '\357\277\277' '\360\220\200\200' '\364\217\277\277'; do
    printf '{"findings":[{"severity":"low","title":"'"$bytes"'"}]}' >"$doc"
    run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$doc"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | cut -f5 | base64 --decode >"$got"
    printf "$bytes" >"$want"
    cmp "$got" "$want"
  done
}

@test "the NUL check re-reads file names with quotes and spaces" {
  local doc="$BATS_TEST_TMPDIR/it's a \$doc.json"
  printf '{"findings":[{"severity":"low"}]}' >"$doc"
  run env LC_ALL=C awk -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$doc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'low\t\t\t\t')" ]
}

@test "stdin is refused: the NUL check needs a file to re-read" {
  run bash -c 'printf "{\"findings\":[{}]}" | LC_ALL=C awk -f "$1/json-tokens.awk" -f "$1/findings.awk"' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "malformed or truncated JSON fails non-zero with no rows" {
  local payload
  while IFS= read -r payload; do
    run findings "$payload"
    if [ "$status" -eq 0 ] || [ -n "$output" ]; then
      echo "accepted: $payload -> status=$status output=$output"
      return 1
    fi
  done <<'PAYLOADS'

prose, not JSON
[]
{}
{"findings":[{"severity":"High","title":"complete"},{"severity":"Low"
{"findings":[{"severity":"High","title":"complete"}]
{"findings":[{"title":"unterminated}]}
{"findings":[{"title":"bad\q"}]}
{"findings":[{"title":"bad\u12"}]}
{"findings":[{"line":01}]}
{"findings":[{"severity" "High"}]}
{"findings":[{"severity":"High" "title":"t"}]}
{"findings":[{"severity":"High",}]}
{"findings":[,]}
{"findings":[{}],}
{"findings":[{}]}{"findings":[]}
{"findings":[{}]} trailing
{"nested":{"findings":[]}}
{"findings":null}
{"findings":{}}
{"findings":[{}],"findings":[{}]}
{"findings":["a string entry"]}
{"findings":[{"title":"t"},3]}
PAYLOADS
}

# ---- opt-in variables (orca.sh rounds) ----------------------------------

# findings_with <vars> <json> — the parser with -v assignments.
findings_with() {
  local vars="$1"
  printf '%s' "$2" >"$BATS_TEST_TMPDIR/doc.json"
  # shellcheck disable=SC2086  # vars is a list of -v assignments
  LC_ALL=C awk $vars -f "$SCRIPTS/json-tokens.awk" -f "$SCRIPTS/findings.awk" "$BATS_TEST_TMPDIR/doc.json"
}

@test "response=1: checks.pass, the base64 failure, and the status print first, ahead of the rows" {
  run findings_with "-v response=1" '{"checks":{"commands":[],"pass":false,"failure":"x\ny"},"findings":[{"title":"t","file":null,"outcome":"fixed","reason":"r"}],"followups":[],"status":"done","questions":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pass\tfalse\t%s\tdone\t\ngating\t\t\tfixed\t%s' "$(printf 'x\ny' | base64)" "$(printf t | base64)")" ]
  run findings_with "-v response=1" '{"questions":["q"],"status":"needs_input","followups":[{"title":"later","file":null,"why":"w","extra":[1]},{"why":"w2","file":"a.sh","title":"t2"}],"findings":[],"extra":1,"checks":{"failure":"","pass":true,"commands":["bats"]}}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pass\ttrue\t\tneeds_input\t')" ]
  run findings_with "-v response=1" '{"checks":{"commands":[],"pass":true,"failure":""},"findings":[],"followups":[],"status":"infeasible","questions":[]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pass\ttrue\t\tinfeasible\t')" ]
  # the tree the response checked, a 40- or 64-digit id, rides as the fifth column
  run findings_with "-v response=1" '{"checks":{"commands":[],"pass":true,"failure":""},"findings":[],"followups":[],"status":"done","questions":[],"tree":"4b825dc642cb6eb9a060e54bf8d69288e0bc4ff1"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pass\ttrue\t\tdone\t4b825dc642cb6eb9a060e54bf8d69288e0bc4ff1')" ]
}

@test "response=1: an incomplete, repeated, or mistyped response — element types included — fails with no output" {
  local ok_checks='"checks":{"commands":[],"pass":true,"failure":""}' rest='"followups":[],"status":"done","questions":[]'
  local ok_entry='"title":"t","file":"a","outcome":"fixed","reason":"r"' payload
  for payload in \
    "{\"findings\":[],$rest}" \
    "{\"checks\":{\"pass\":true},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":\"bats\",\"pass\":true,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":\"true\",\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":null,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"failure\":null},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[],\"pass\":true,\"pass\":true,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":[],\"findings\":[],$rest}" \
    "{$ok_checks,$ok_checks,\"findings\":[],$rest}" \
    "{$ok_checks,$rest}" \
    "{$ok_checks,\"findings\":[],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"done\"}" \
    "{$ok_checks,\"findings\":[],\"followups\":{},\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":1,\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"Done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"pending\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"done\",\"questions\":\"none\"}" \
    "{$ok_checks,\"findings\":[],$rest,\"status\":\"done\"}" \
    "{$ok_checks,\"findings\":[{}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"file\":\"a\",\"outcome\":\"fixed\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"outcome\":\"fixed\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"file\":\"a\",\"outcome\":\"fixed\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"file\":\"a\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"file\":\"a\",\"outcome\":\"Fixed\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"file\":\"a\",\"outcome\":\"done\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":null,\"file\":\"a\",\"outcome\":\"fixed\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{\"title\":\"t\",\"file\":1,\"outcome\":\"fixed\",\"reason\":\"r\"}],$rest}" \
    "{$ok_checks,\"findings\":[{$ok_entry,\"outcome\":\"disputed\"}],$rest}" \
    "{\"checks\":{\"commands\":[42],\"pass\":true,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[\"ok\",null],\"pass\":true,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{\"checks\":{\"commands\":[[\"nested\"]],\"pass\":true,\"failure\":\"\"},\"findings\":[],$rest}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"done\",\"questions\":[42]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[],\"status\":\"done\",\"questions\":[\"q\",{}]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[null],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[\"gap\"],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[{\"title\":\"t\",\"file\":null}],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[{\"title\":\"t\",\"why\":\"w\"}],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[{\"title\":1,\"file\":null,\"why\":\"w\"}],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[{\"title\":\"t\",\"file\":false,\"why\":\"w\"}],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],\"followups\":[{\"title\":\"t\",\"file\":null,\"why\":\"w\",\"why\":\"x\"}],\"status\":\"done\",\"questions\":[]}" \
    "{$ok_checks,\"findings\":[],$rest,\"tree\":null}" \
    "{$ok_checks,\"findings\":[],$rest,\"tree\":\"abc\"}" \
    "{$ok_checks,\"findings\":[],$rest,\"tree\":\"4B825DC642CB6EB9A060E54BF8D69288E0BC4FF1\"}" \
    "{$ok_checks,\"findings\":[],$rest,\"tree\":\"4b825dc642cb6eb9a060e54bf8d69288e0bc4ff1\",\"tree\":\"4b825dc642cb6eb9a060e54bf8d69288e0bc4ff1\"}"; do
    run findings_with "-v response=1" "$payload"
    if [ "$status" -eq 0 ] || [ -n "$output" ]; then
      echo "accepted: $payload -> status=$status output=$output"
      return 1
    fi
  done
  run findings_with "-v response=1" "{$ok_checks,\"findings\":[{$ok_entry}],$rest}"
  [ "$status" -eq 0 ]
}


@test "without response=1 a checks key is skipped like any other" {
  run findings '{"checks":"anything","findings":[]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plain_title=1: the title column is plain text, control bytes as spaces" {
  run findings_with "-v plain_title=1" '{"findings":[{"severity":"low","title":"tab\there\nend é"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'low\t\t\t\ttab here end \303\251')" ]
}

@test "severity_name=1: a sixth column names the severity, anything else unknown" {
  run findings_with "-v severity_name=1" '{"findings":[
    {"severity":"Critical"},{"severity":" HIGH\n"},{"severity":"Medium"},{"severity":"low"},
    {"severity":"Blocker"},{"severity":"hi\u0000gh"},{"severity":null},{}]}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f6 | tr '\n' ' ')" = \
    "critical high medium low unknown unknown unknown unknown " ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = \
    "gating gating medium low gating gating gating gating " ]
}
