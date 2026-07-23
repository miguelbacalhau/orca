#!/usr/bin/env bats
# lib.sh + orca.sh — canonicalizer fixtures, frame round-trips, dispatch.

load helpers

# Run one lib function in a fresh bash: lib canonicalize <path>, etc.
lib() {
  bash -c 'source "$1/lib.sh" && shift && "$@"' _ "$SCRIPTS" "$@"
}

# Reference decoder for one frame key (the production decoder is JS,
# landing with the verb switchover; this pins the emission grammar).
# Between the markers, a line opening a declared key starts that key;
# ANY other line is a continuation of the open key's value — the rule
# that lets a relay-wrapped .b64 line rejoin before decoding. All
# whitespace is stripped from the joined value.
decode_frame_key() { # <key> — frame on stdin, joined value on stdout
  awk -v k="$1" '
    /^@@ORCA@@$/ { inframe = 1; next }
    /^@@ORCA_END@@$/ { inframe = 0; next }
    !inframe { next }
    match($0, /^(rc|verb|action|hash|probe\.b64|message\.b64)=/) {
      cur = substr($0, 1, RLENGTH - 1)
      val[cur] = substr($0, RLENGTH + 1)
      next
    }
    cur != "" { val[cur] = val[cur] $0 }
    END { printf "%s", val[k] }
  ' | tr -d '[:space:]'
}

# ---- canonicalize ------------------------------------------------------

@test "canonicalize resolves a relative link" {
  mkdir -p "$BATS_TEST_TMPDIR/d/sub"
  echo x >"$BATS_TEST_TMPDIR/d/sub/file"
  ln -s sub/file "$BATS_TEST_TMPDIR/d/link"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/d/sub/file" ]
}

@test "canonicalize resolves an absolute link" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  echo x >"$BATS_TEST_TMPDIR/d/file"
  ln -s "$BATS_TEST_TMPDIR/d/file" "$BATS_TEST_TMPDIR/d/link"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/d/file" ]
}

@test "canonicalize resolves a dangling link (existence not required)" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  ln -s "$BATS_TEST_TMPDIR/gone/secret" "$BATS_TEST_TMPDIR/d/link"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/gone/secret" ]
}

@test "canonicalize follows a link chain to the end" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  echo x >"$BATS_TEST_TMPDIR/d/file"
  ln -s file "$BATS_TEST_TMPDIR/d/a"
  ln -s a "$BATS_TEST_TMPDIR/d/b"
  ln -s b "$BATS_TEST_TMPDIR/d/c"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/c"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/d/file" ]
}

@test "canonicalize terminates on a symlink loop" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  ln -s a "$BATS_TEST_TMPDIR/d/b"
  ln -s b "$BATS_TEST_TMPDIR/d/a"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/a"
  [ "$status" -eq 0 ]
  # A loop can never equal a real canonical path — the ownership tests'
  # only requirement; the exact partially-resolved spelling is not pinned.
  [[ "$output" == /* ]]
}

@test "canonicalize resolves a link whose parent is itself a link" {
  mkdir -p "$BATS_TEST_TMPDIR/real"
  echo x >"$BATS_TEST_TMPDIR/real/file"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/alias"
  run lib canonicalize "$BATS_TEST_TMPDIR/alias/file"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/real/file" ]
}

@test "canonicalize normalizes dot and dotdot components" {
  mkdir -p "$BATS_TEST_TMPDIR/d/sub"
  run lib canonicalize "$BATS_TEST_TMPDIR/d/sub/../sub/./deeper"
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/d/sub/deeper" ]
}

# ---- frames ------------------------------------------------------------

@test "frame round-trip: a b64 value decodes back byte-identical" {
  msg='fix: handle "quotes", tabs	and unicode — café'
  run bash -c 'source "$1/lib.sh" && emit_frame rc=0 action=accepted "message.b64=$(b64_encode_str "$2")"' _ "$SCRIPTS" "$msg"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '@@ORCA@@' ]
  has_line 'rc=0'
  has_line 'action=accepted'
  decoded="$(printf '%s\n' "$output" | decode_frame_key message.b64 | base64 --decode)"
  [ "$decoded" = "$msg" ]
}

@test "frame decode failure: garbage under a .b64 key is loud" {
  run bash -c 'source "$1/lib.sh" && emit_frame rc=0 "message.b64=@@not-base64@@"' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  run bash -c 'printf %s "$1" | base64 --decode >/dev/null 2>&1' _ '@@not-base64@@'
  [ "$status" -ne 0 ]
}

@test "a relay-wrapped .b64 value rejoins via the continuation rule" {
  msg='a long commit message that the relay wrapped across several lines while copying the frame'
  b64="$(bash -c 'source "$1/lib.sh" && b64_encode_str "$2"' _ "$SCRIPTS" "$msg")"
  # Simulate the relay inserting newlines mid-value: split the base64
  # into 20-char lines. The continuation lines can end in '=' padding
  # and must still read as continuations, never as key lines.
  wrapped="$(printf '%s' "$b64" | fold -w 20)"
  frame="$(printf '@@ORCA@@\nrc=0\naction=accepted\nmessage.b64=%s\n@@ORCA_END@@\n' "$wrapped")"
  decoded="$(printf '%s\n' "$frame" | decode_frame_key message.b64 | base64 --decode)"
  [ "$decoded" = "$msg" ]
}

# ---- dispatch ----------------------------------------------------------

@test "orca.sh self-test emits a decodable frame" {
  run bash "$SCRIPTS/orca.sh" self-test
  [ "$status" -eq 0 ]
  has_line '@@ORCA@@'
  has_line 'rc=0'
  probe="$(printf '%s\n' "$output" | decode_frame_key probe.b64 | base64 --decode)"
  [ "$probe" = 'orca self-test' ]
}

@test "orca.sh fails typed on an unknown verb" {
  run bash "$SCRIPTS/orca.sh" no-such-verb
  assert_fail_reason UNKNOWN_VERB
}

@test "orca.sh fails typed with no verb at all" {
  run bash "$SCRIPTS/orca.sh"
  assert_fail_reason UNKNOWN_VERB
}

@test "lib.sh double-sourcing is a guarded no-op" {
  run bash -c 'source "$1/lib.sh" && source "$1/lib.sh" && echo OK' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  has_line 'OK'
}

@test "is_banned matches attribution markers case-insensitively, not domain vocabulary" {
  run bash -c 'source "$1/lib.sh" && is_banned "Co-Authored-By: someone"' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1/lib.sh" && is_banned "Generated with a tool"' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1/lib.sh" && is_banned "feat: add AI summarizer user-agent header"' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}
