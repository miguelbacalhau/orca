#!/usr/bin/env bats
# orca.sh setup and provision — the safety envelope (closed stdin, the
# process-group watchdog), the fingerprint and its drift verdict, the
# provenance header, and the composite ritual's ordering and frame.

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

# frame_get <key> — the key's value from the frame in $output.
frame_get() {
  printf '%s\n' "$output" | awk -v k="$1" '
    /^@@ORCA@@$/ { f = 1; next }
    /^@@ORCA_END@@$/ { f = 0 }
    f && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

# make_setup_layout <dir> — the bare layout plus a package.json (one probe
# the fingerprint will find) and a secrets tree.
make_setup_layout() {
  make_bare_layout "$1"
  ( cd "$1/main" &&
    printf '{"name":"x"}\n' >package.json &&
    git add package.json && git commit -qm manifest )
  mkdir -p "$1/.orca/secrets"
}

# candidate <path> <body...> — a candidate script at <path>.
candidate() {
  local p="$1"; shift
  printf '%s\n' "$@" >"$p"
}

install_candidate() { # <repo> <candidate> [extra args...]
  local r="$1" c="$2"; shift 2
  ( cd "$r" && bash "$SCRIPTS/orca.sh" setup install "$c" --sources - "$@" )
}

# ---- status ------------------------------------------------------------

@test "status: absent before anything is installed" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tabsent'
}

@test "status: install stamps, and the stamped script reads current" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  run install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" --verified 'rc=0 seconds=1'
  [ "$status" -eq 0 ]
  has_line $'INSTALLED:\t'
  has_line $'SETUP:\tcurrent\t'
  grep -q '^# fingerprint: ' "$BATS_TEST_TMPDIR/r/.orca/setup"
  grep -q '^# inspected: .*package\.json=' "$BATS_TEST_TMPDIR/r/.orca/setup"
  grep -q '^# verified: .*rc=0 seconds=1$' "$BATS_TEST_TMPDIR/r/.orca/setup"
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tcurrent\t'
  has_line $'SETUP_LINES:\t1'
}

@test "status: a hand-written script reads unstamped" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/r/.orca/setup"
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tunstamped'
}

@test "status: a commit touching package.json drifts and names it" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    printf '{"name":"y"}\n' >package.json &&
    git add package.json && git commit -qm bump )
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tdrifted\t'
  has_line $'CHANGED:\tpackage.json'
}

@test "status: a lockfile appearing later trips the drift check" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    printf 'lockfileVersion: 9\n' >pnpm-lock.yaml &&
    git add pnpm-lock.yaml && git commit -qm lockfile )
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tdrifted\t'
  has_line $'CHANGED:\tpnpm-lock.yaml'
}

@test "status: an unrelated commit leaves the fingerprint alone" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    echo more >>seed.txt && git add seed.txt && git commit -qm unrelated )
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tcurrent\t'
  refute_line $'CHANGED:'
}

@test "status: needs-nothing records an empty manifest and still catches a first probe" {
  # The repo holds none of the probed manifests — the "this repo needs no
  # install step" case, whose whole value is noticing when that stops being
  # true.
  make_bare_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  grep -q '^# inspected: -$' "$BATS_TEST_TMPDIR/r/.orca/setup"
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  has_line $'SETUP:\tcurrent\t'
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    printf 'all:\n\t@true\n' >Makefile && git add Makefile && git commit -qm makefile )
  run orca setup status
  has_line $'SETUP:\tdrifted\t'
  has_line $'CHANGED:\tMakefile'
}

@test "install: refuses an empty or syntactically broken candidate" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  : >"$BATS_TEST_TMPDIR/empty"
  run install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/empty"
  assert_fail_reason BAD_SCRIPT
  candidate "$BATS_TEST_TMPDIR/broken" 'if true; then'
  run install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/broken"
  assert_fail_reason BAD_SCRIPT
  [ ! -e "$BATS_TEST_TMPDIR/r/.orca/setup" ]
}

@test "install: a named source joins the fingerprint's probe set" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    mkdir -p tooling && printf 'echo hi\n' >tooling/spawn.sh &&
    git add tooling/spawn.sh && git commit -qm tooling )
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  ( cd "$BATS_TEST_TMPDIR/r" &&
    bash "$SCRIPTS/orca.sh" setup install "$BATS_TEST_TMPDIR/cand" --sources 'tooling/spawn.sh' ) >/dev/null
  grep -q '^# derived-from: tooling/spawn.sh$' "$BATS_TEST_TMPDIR/r/.orca/setup"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    printf 'echo bye\n' >tooling/spawn.sh &&
    git add tooling/spawn.sh && git commit -qm 'tooling moves' )
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup status
  has_line $'SETUP:\tdrifted\t'
  has_line $'CHANGED:\ttooling/spawn.sh'
}

# ---- run ---------------------------------------------------------------

@test "run: absent script is a clean no-op" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  run orca setup run "$BATS_TEST_TMPDIR/r/main" created
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tabsent'
}

@test "run: a succeeding script reports ok and sees its environment" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" \
    'printf "%s\n" "$ORCA_WORKTREE" "$ORCA_REPO_ROOT" "$ORCA_ARRIVAL" "$PWD" >env.txt'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  run orca setup run "$BATS_TEST_TMPDIR/r/main" branch_resumed
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tok\t'
  run cat "$BATS_TEST_TMPDIR/r/main/env.txt"
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/r/main" ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/r" ]
  [ "${lines[2]}" = "branch_resumed" ]
  [ "${lines[3]}" = "$BATS_TEST_TMPDIR/r/main" ]
}

@test "run: a failing script reports rc with a decodable tail" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'echo "installing"' 'echo "boom" >&2' 'exit 9'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  run orca setup run "$BATS_TEST_TMPDIR/r/main" created
  # Advisory: a failed provisioning must never fail the caller.
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tfailed\t9\t'
  has_line $'SETUP_TAIL:\t'
  tail_b64="$(printf '%s\n' "$output" | sed -n 's/^SETUP_TAIL:\t//p')"
  decoded="$(printf '%s' "$tail_b64" | base64 --decode)"
  [[ "$decoded" == *installing* ]]
  [[ "$decoded" == *boom* ]]
}

@test "run: a script that reads stdin returns at once instead of wedging" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'read -r line' 'echo "got:[$line]"'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  run orca setup run "$BATS_TEST_TMPDIR/r/main" created --timeout 30
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tok\t'
}

@test "run: an unstamped script still runs, flagged" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  printf 'echo hand-written >hw.txt\n' >"$BATS_TEST_TMPDIR/r/.orca/setup"
  run orca setup run "$BATS_TEST_TMPDIR/r/main" created
  [ "$status" -eq 0 ]
  has_line $'SETUP:\tunstamped'
  has_line $'SETUP:\tok\t'
  [ -f "$BATS_TEST_TMPDIR/r/main/hw.txt" ]
}

@test "run: rejects an unknown arrival" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  run orca setup run "$BATS_TEST_TMPDIR/r/main" whenever
  assert_fail_reason BAD_ARGS
}

# ---- verify ------------------------------------------------------------

@test "verify: a clean candidate leaves the worktree list unchanged" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  before="$(git -C "$BATS_TEST_TMPDIR/r/main" worktree list | wc -l)"
  candidate "$BATS_TEST_TMPDIR/cand" 'echo built >built.txt'
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup verify "$BATS_TEST_TMPDIR/cand" --check 'test -f built.txt'
  [ "$status" -eq 0 ]
  [ "$(frame_get rc)" = 0 ]
  [ "$(frame_get check_rc)" = 0 ]
  [ "$(frame_get removed)" = yes ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/main" worktree list | wc -l)" -eq "$before" ]
  [ ! -e "$(frame_get worktree)" ]
}

@test "verify: check_rc is reported separately from the candidate's rc" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'exit 0'
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup verify "$BATS_TEST_TMPDIR/cand" --check 'exit 4'
  [ "$status" -eq 0 ]
  [ "$(frame_get rc)" = 0 ]
  [ "$(frame_get check_rc)" = 4 ]
}

@test "verify: a failing candidate skips the check and still removes the worktree" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  before="$(git -C "$BATS_TEST_TMPDIR/r/main" worktree list | wc -l)"
  candidate "$BATS_TEST_TMPDIR/cand" 'echo nope >&2' 'exit 5'
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup verify "$BATS_TEST_TMPDIR/cand" --check 'true'
  [ "$status" -eq 0 ]
  [ "$(frame_get rc)" = 5 ]
  [ "$(frame_get check_rc)" = '-' ]
  [ "$(frame_get removed)" = yes ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/main" worktree list | wc -l)" -eq "$before" ]
  [[ "$(frame_get tail.b64 | base64 --decode)" == *nope* ]]
}

@test "verify: places the secrets into the throwaway worktree" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  candidate "$BATS_TEST_TMPDIR/cand" 'test -f .env || exit 3' 'cat .env'
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup verify "$BATS_TEST_TMPDIR/cand"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ "$(frame_get rc)" = 0 ]
  [[ "$(frame_get tail.b64 | base64 --decode)" == *SECRET=1* ]]
}

@test "verify: a hung grandchild is killed at the cap and reported rc 124" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  marker="$BATS_TEST_TMPDIR/grandchild-survived"
  candidate "$BATS_TEST_TMPDIR/cand" \
    'echo starting' \
    "( sleep 30 ; : >'$marker' ) &" \
    'wait'
  cd "$BATS_TEST_TMPDIR/r"
  run orca setup verify "$BATS_TEST_TMPDIR/cand" --timeout 1
  [ "$status" -eq 0 ]
  [ "$(frame_get rc)" = 124 ]
  [ "$(frame_get check_rc)" = '-' ]
  [ "$(frame_get removed)" = yes ]
  # The process group is what reaches a grandchild: if the sleep survived,
  # the watchdog killed only the script.
  sleep 2
  [ ! -e "$marker" ]
}

# ---- provision ---------------------------------------------------------

@test "provision: places the secrets BEFORE running the setup script" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  candidate "$BATS_TEST_TMPDIR/cand" 'test -f .env || exit 7'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  run orca provision "$BATS_TEST_TMPDIR/r/main" created
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  has_line $'SETUP:\tok\t'
  [ "$(frame_get rc)" = 0 ]
  [ "$(frame_get arrival)" = created ]
  [ "$(frame_get setup)" = ok ]
  [ "$(frame_get setup_stamped)" = yes ]
}

@test "provision: a failed setup rides the frame and never fails the caller" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'echo wrecked >&2' 'exit 3'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  run orca provision "$BATS_TEST_TMPDIR/r/main" integrate
  [ "$status" -eq 0 ]
  [ "$(frame_get rc)" = 0 ]
  [ "$(frame_get setup)" = failed ]
  [ "$(frame_get setup_rc)" = 3 ]
  [[ "$(frame_get setup_tail.b64 | base64 --decode)" == *wrecked* ]]
}

@test "provision: no setup script reports absent with no rc" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  run orca provision "$BATS_TEST_TMPDIR/r/main" reused
  [ "$status" -eq 0 ]
  [ "$(frame_get setup)" = absent ]
  [ "$(frame_get setup_rc)" = '-' ]
  [ "$(frame_get setup_stamped)" = '-' ]
}

@test "provision: an unstamped script runs and is flagged in the frame" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  printf 'exit 0\n' >"$BATS_TEST_TMPDIR/r/.orca/setup"
  run orca provision "$BATS_TEST_TMPDIR/r/main" created
  [ "$status" -eq 0 ]
  [ "$(frame_get setup)" = ok ]
  [ "$(frame_get setup_stamped)" = no ]
}

@test "provision: eight concurrent calls over one repo all succeed" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  candidate "$BATS_TEST_TMPDIR/cand" 'echo "$ORCA_ARRIVAL" >>provisioned.log'
  install_candidate "$BATS_TEST_TMPDIR/r" "$BATS_TEST_TMPDIR/cand" >/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    git -C "$BATS_TEST_TMPDIR/r/main" worktree add -q "$BATS_TEST_TMPDIR/r/w$i" -b "b$i" main
  done
  for i in 1 2 3 4 5 6 7 8; do
    bash "$SCRIPTS/orca.sh" provision "$BATS_TEST_TMPDIR/r/w$i" created >"$BATS_TEST_TMPDIR/out$i" 2>&1 &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do
    grep -q '^setup=ok$' "$BATS_TEST_TMPDIR/out$i"
    [ -f "$BATS_TEST_TMPDIR/r/w$i/provisioned.log" ]
  done
}

@test "provision: rejects an unknown arrival with the setup verb's typed failure" {
  make_setup_layout "$BATS_TEST_TMPDIR/r"
  run orca provision "$BATS_TEST_TMPDIR/r/main" whenever
  assert_fail_reason BAD_ARGS
}
