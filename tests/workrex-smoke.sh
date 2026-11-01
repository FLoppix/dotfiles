#!/bin/sh
# Workrex smoke test. Rebuilds a scratch repo, drives the real Rex server, and
# asserts the visible result. Usage:
#   tests/workrex-smoke.sh reset     rebuild the scratch repo
#   tests/workrex-smoke.sh p0|p1|p2|p3|p4|p5
#   tests/workrex-smoke.sh all       run every lane that exists
#   WORKREX_SMOKE_FAIL=1 ...        force one failing assertion
set -u

DIR=${WORKREX_SMOKE_DIR:-/private/var/folders/wb/xrqy4t111gs50qzgzxd_0by80000gn/T/opencode/workrex-proto}
REPO=$DIR/repo
PROJECT=$(basename "$REPO")
PASS=0
FAIL=0
FAILED=""

say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED $1"; say "FAIL $1 ${2:-}"; }
skip() { say "SKIP $1 not implemented yet"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_file() { # name path
  if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi
}
assert_no_file() { # name path
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "exists $2"; fi
}
wait_for() { # command
  i=0
  while [ $i -lt 60 ]; do
    if eval "$1"; then return 0; fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

assert_config() { # name key expected
  actual=$(git -C "$REPO" config --local --get "$2" 2>/dev/null || true)
  assert_eq "$1" "$3" "$actual"
}

reset() {
  rm -rf "$DIR"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf '.env*\nnode_modules\nCLAUDE.local.md\n' >"$REPO/.gitignore"
  printf 'SECRET=1\n' >"$REPO/.env"
  printf 'LOCAL=2\n' >"$REPO/.env.local"
  mkdir -p "$REPO/node_modules/dep"
  printf 'dep\n' >"$REPO/node_modules/dep/index.js"
  printf 'keep\n' >"$REPO/tracked.txt"
  git -C "$REPO" add .gitignore tracked.txt
  git -C "$REPO" -c user.email=smoke@example.com -c user.name=smoke commit -qm init
  say "reset $REPO"
}

name_for() { printf '%s-%s' "$1" "$$"; }

label_for() { printf '%s/%s' "$PROJECT" "$1"; }

driver() { printf '%s/driver' "$PROJECT"; }

ensure_driver() {
  if ! rex ls 2>/dev/null | grep -q "$(driver)"; then
    rex new "$(driver)" -c "$REPO" >/dev/null 2>&1 || true
    sleep 1
  fi
}

run_action() { # action args...
  rex do "$@" cwd="$REPO" 2>&1
}

add_wt() { # name agent
  run_action worktree_add name="$1" agent="${2:-sh}" >/dev/null 2>&1
}

open_wt() { # name agent
  run_action worktree_open name="$1" agent="${2:-sh}" >/dev/null 2>&1
}

remove_wt() { # name
  run_action worktree_remove name="$1" force=true >/dev/null 2>&1
}

cleanup_wt() { # name
  rex kill "$(label_for "$1")" >/dev/null 2>&1 || true
  git -C "$REPO" worktree remove --force "$REPO"__worktrees/"$1" >/dev/null 2>&1 || true
  git -C "$REPO" branch -D "wm/$1" >/dev/null 2>&1 || true
}

lane_p0() {
  n=$(name_for p0)
  rm -rf "$REPO"__worktrees
  if add_wt "$n"; then ok "p0 add"; else bad "p0 add" "worktree_add failed"; return; fi
  assert_file "p0 worktree dir" "$REPO"__worktrees/"$n"
  if open_wt "$n"; then ok "p0 open"; else bad "p0 open" "worktree_open failed"; fi
  if remove_wt "$n"; then ok "p0 remove"; else bad "p0 remove" "worktree_remove failed"; fi
  assert_no_file "p0 worktree gone" "$REPO"__worktrees/"$n"
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/wm/$n"; then
    bad "p0 merged branch deleted" "branch still exists"
  else
    ok "p0 merged branch deleted"
  fi
  cleanup_wt "$n"
}

lane_p0_duplicate() {
  n=$(name_for dup)
  add_wt "$n"
  out=$(run_action worktree_add name="$n" agent=sh)
  case "$out" in
    *"already exists"*) ok "p0 duplicate rejected" ;;
    *) bad "p0 duplicate rejected" "$out" ;;
  esac
  remove_wt "$n"
  cleanup_wt "$n"
}

write_config() { # body
  printf '%s\n' "$1" >"$REPO/.workrex.lua"
}

lane_p1() {
  n=$(name_for p1)
  write_config 'return { setup = {}, port_block = 10 }'
  add_wt "$n" || { bad "p1 add" "worktree_add failed"; return; }
  wt=$REPO"__worktrees/$n"
  assert_file "p1 env file" "$wt/.workrex/env"
  assert_eq "p1 base key" "main" "$(git -C "$REPO" config --local --get "branch.\"wm/$n\".workrex-base")"
  assert_config "p1 setup state" "workrex.worktree.\"$n\".setup" "skipped"
  envport=$(sed -n "s/^export WORKREX_PORT='\([0-9]*\)'$/\1/p" "$wt/.workrex/env")
  metaport=$(git -C "$REPO" config --local --get "workrex.worktree.\"$n\".ports")
  assert_eq "p1 env port matches meta" "$metaport" "$envport"

  n2=$(name_for p1b)
  add_wt "$n2"
  port2=$(git -C "$REPO" config --local --get "workrex.worktree.\"$n2\".ports")
  if [ -n "$envport" ] && [ "$envport" != "$port2" ]; then ok "p1 ports differ"; else bad "p1 ports differ" "$envport vs $port2"; fi

  # config errors abort before any side effect
  write_config 'return { nope = true }'
  n3=$(name_for p1c)
  out=$(run_action worktree_add name="$n3" agent=sh)
  case "$out" in
    *"unknown config key"*) ok "p1 unknown key rejected" ;;
    *) bad "p1 unknown key rejected" "$out" ;;
  esac
  assert_no_file "p1 no dir after config error" "$REPO"__worktrees/"$n3"

  write_config 'return { setup = { '
  out=$(run_action worktree_add name="$n3" agent=sh)
  case "$out" in
    *"workrex:"*) ok "p1 syntax error rejected" ;;
    *) bad "p1 syntax error rejected" "$out" ;;
  esac

  write_config 'return { setup = {}, port_block = 10 }'
  lines=$(grep -c '^\.workrex/$' "$REPO/.git/info/exclude" 2>/dev/null || true)
  assert_eq "p1 exclude once" "1" "$lines"

  # old worktree backfill: drop meta keys, reopen
  git -C "$REPO" config --local --remove-section "workrex.worktree.\"$n2\"" 2>/dev/null || true
  rex kill "$(label_for "$n2")" >/dev/null 2>&1 || true
  open_wt "$n2"
  assert_config "p1 backfilled setup" "workrex.worktree.\"$n2\".setup" "skipped"

  # rollback when the session label is taken
  n4=$(name_for p1d)
  rex new "$(label_for "$n4")" -c "$REPO" >/dev/null 2>&1
  sleep 1
  out=$(run_action worktree_add name="$n4" agent=sh)
  case "$out" in
    *"already exists"*|*"conflict"*|*"failed"*|*"label"*) ok "p1 rollback reports conflict" ;;
    *) bad "p1 rollback reports conflict" "$out" ;;
  esac
  assert_no_file "p1 rollback removed worktree" "$REPO"__worktrees/"$n4"
  rex kill "$(label_for "$n4")" >/dev/null 2>&1 || true

  remove_wt "$n"
  remove_wt "$n2"
  cleanup_wt "$n"; cleanup_wt "$n2"; cleanup_wt "$n4"
  rm -f "$REPO/.workrex.lua"
}

lane_p2() {
  n=$(name_for p2)
  write_config 'return { files = { copy = { ".env*" }, symlink = { "node_modules" } } }'
  add_wt "$n" || { bad "p2 add" "worktree_add failed"; return; }
  wt=$REPO"__worktrees/$n"
  if [ -f "$wt/.env" ] && cmp -s "$wt/.env" "$REPO/.env"; then ok "p2 copy .env"; else bad "p2 copy .env" "missing or different"; fi
  assert_file "p2 copy .env.local" "$wt/.env.local"
  if [ -L "$wt/node_modules" ]; then ok "p2 symlink node_modules"; else bad "p2 symlink node_modules" "not a symlink"; fi
  target=$(readlink "$wt/node_modules" 2>/dev/null || true)
  case "$target" in
    ../../*) ok "p2 symlink is relative" ;;
    *) bad "p2 symlink is relative" "$target" ;;
  esac
  if (cd "$wt" && node -e "require.resolve('./node_modules/dep/index.js')" 2>/dev/null) || [ -f "$wt/node_modules/dep/index.js" ]; then
    ok "p2 symlink resolves"
  else
    bad "p2 symlink resolves" "target missing"
  fi
  if [ "$(cat "$wt/tracked.txt")" = "keep" ]; then ok "p2 tracked file from checkout"; else bad "p2 tracked file from checkout" ""; fi

  printf 'local instructions\n' >"$REPO/CLAUDE.local.md"
  n2=$(name_for p2b)
  add_wt "$n2"
  if [ -L "$REPO"__worktrees/"$n2"/CLAUDE.local.md ]; then ok "p2 CLAUDE.local.md link"; else bad "p2 CLAUDE.local.md link" "missing"; fi

  write_config 'return { files = { copy = { "../escape" } } }'
  n3=$(name_for p2c)
  out=$(run_action worktree_add name="$n3" agent=sh)
  case "$out" in
    *"escapes the repo"*) ok "p2 escape rejected" ;;
    *) bad "p2 escape rejected" "$out" ;;
  esac

  remove_wt "$n"; remove_wt "$n2"
  cleanup_wt "$n"; cleanup_wt "$n2"; cleanup_wt "$n3"
  rm -f "$REPO/.workrex.lua" "$REPO/CLAUDE.local.md"
}

labels_of() { # name
  rex window ls -s "$(label_for "$1")" --json 2>/dev/null | jq -r '.windows[].label' 2>/dev/null
}

has_label() { # name label
  labels_of "$1" | grep -qx "$2"
}

state_of() { # name
  git -C "$REPO" config --local --get "workrex.worktree.\"$1\".setup" 2>/dev/null || true
}

lane_p3() {
  n=$(name_for p3)
  write_config 'return { setup = { "echo HELLO; sleep 1" } }'
  add_wt "$n" || { bad "p3 add" "worktree_add failed"; return; }
  sleep 3
  if has_label "$n" "setup"; then ok "p3 setup window"; else bad "p3 setup window" "missing"; fi
  if has_label "$n" "sh"; then ok "p3 agent window"; else bad "p3 agent window" "missing"; fi
  assert_eq "p3 state ok" "ok" "$(state_of "$n")"

  n2=$(name_for p3f)
  write_config 'return { setup = { "false" } }'
  add_wt "$n2"
  sleep 2
  assert_eq "p3 failed state" "failed" "$(state_of "$n2")"
  if labels_of "$n2" | grep -qx "sh"; then bad "p3 no agent on failure" "agent present"; else ok "p3 no agent on failure"; fi

  # rerun after fixing the config
  write_config 'return { setup = { "echo FIXED" } }'
  run_action -s "$(label_for "$n2")" workrex_setup name="$n2" >/dev/null 2>&1
  sleep 3
  assert_eq "p3 rerun ok" "ok" "$(state_of "$n2")"
  if labels_of "$n2" | grep -qx "sh"; then ok "p3 rerun agent"; else bad "p3 rerun agent" "missing"; fi
  setups=$(labels_of "$n2" | grep -c '^setup$' || true)
  assert_eq "p3 single setup window" "1" "$setups"

  # double report is idempotent
  run_action workrex_setup_done name="$n2" agent=sh >/dev/null 2>&1
  if [ "$(labels_of "$n2" | grep -c '^sh$')" = "1" ]; then ok "p3 double report"; else bad "p3 double report" "duplicate agent"; fi

  # agent change closes the old window
  printf 'return { setup = {} }\n' >"$REPO/.workrex.lua"
  run_action workrex_setup_done name="$n2" agent=bash >/dev/null 2>&1
  if labels_of "$n2" | grep -qx "bash" && ! labels_of "$n2" | grep -qx "sh"; then
    ok "p3 agent change"
  else
    bad "p3 agent change" "$(labels_of "$n2" | tr '\n' ' ')"
  fi

  # closed setup window is reported as abandoned
  n3=$(name_for p3c)
  write_config 'return { setup = { "sleep 20" } }'
  add_wt "$n3"
  sleep 1
  rex window close -s "$(label_for "$n3")" setup >/dev/null 2>&1
  out=$(run_action worktree_open name="$n3" agent=sh)
  case "$out" in
    *'"abandoned":true'*) ok "p3 abandoned detected" ;;
    *) bad "p3 abandoned detected" "$out" ;;
  esac

  # no_setup escape hatch
  n4=$(name_for p3n)
  write_config 'return { setup = { "sleep 20" } }'
  if run_action worktree_add name="$n4" agent=sh no_setup=true >/dev/null 2>&1; then ok "p3 no_setup add"; else bad "p3 no_setup add" ""; fi
  if labels_of "$n4" | grep -qx "sh"; then ok "p3 no_setup agent"; else bad "p3 no_setup agent" "missing"; fi
  if labels_of "$n4" | grep -qx "setup"; then bad "p3 no_setup window" "setup window exists"; else ok "p3 no_setup window"; fi

  for x in "$n" "$n2" "$n3" "$n4"; do
    rex kill "$(label_for "$x")" >/dev/null 2>&1 || true
    remove_wt "$x"
    cleanup_wt "$x"
  done
  rm -f "$REPO/.workrex.lua"
}

commit_in() { # dir message file
  printf '%s\n' "$2" >"$1/$3"
  git -C "$1" add "$3"
  git -C "$1" -c user.email=smoke@example.com -c user.name=smoke commit -qm "$2"
}

lane_p4() {
  # happy path
  n=$(name_for p4)
  add_wt "$n"
  commit_in "$REPO"__worktrees/"$n" feature feat.txt
  run_action worktree_merge name="$n" strategy=merge >/dev/null 2>&1
  wait_for "[ ! -e \"$REPO\"__worktrees/\"$n\" ]" || true
  if git -C "$REPO" log --oneline -5 | grep -q feature; then ok "p4 merge landed"; else bad "p4 merge landed" ""; fi
  assert_no_file "p4 merge removed worktree" "$REPO"__worktrees/"$n"
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/wm/$n"; then bad "p4 merge deleted branch" "branch exists"; else ok "p4 merge deleted branch"; fi
  cleanup_wt "$n"

  # conflict keeps the worktree and cleans the target
  n2=$(name_for p4c)
  add_wt "$n2"
  commit_in "$REPO"__worktrees/"$n2" branch-side conflict.txt
  commit_in "$REPO" main-side conflict.txt
  run_action worktree_merge name="$n2" >/dev/null 2>&1
  wait_for "[ -z \"\$(git -C \"$REPO\" status --porcelain)\" ]" || true
  assert_file "p4 conflict keeps worktree" "$REPO"__worktrees/"$n2"
  if [ -z "$(git -C "$REPO" status --porcelain)" ]; then ok "p4 conflict target clean"; else bad "p4 conflict target clean" "$(git -C "$REPO" status --porcelain)"; fi
  cleanup_wt "$n2"

  # dirty guard
  n3=$(name_for p4d)
  add_wt "$n3"
  printf 'dirty\n' >>"$REPO"__worktrees/"$n3/tracked.txt"
  out=$(run_action worktree_merge name="$n3")
  case "$out" in
    *"uncommitted changes"*) ok "p4 dirty merge refused" ;;
    *) bad "p4 dirty merge refused" "$out" ;;
  esac
  out=$(run_action worktree_remove name="$n3")
  case "$out" in
    *"uncommitted changes"*) ok "p4 dirty remove refused" ;;
    *) bad "p4 dirty remove refused" "$out" ;;
  esac
  run_action worktree_remove name="$n3" force=true >/dev/null 2>&1
  assert_no_file "p4 force remove" "$REPO"__worktrees/"$n3"
  cleanup_wt "$n3"

  # self-session guard
  n4=$(name_for p4s)
  add_wt "$n4"
  out=$(run_action -s "$(label_for "$n4")" worktree_merge name="$n4")
  case "$out" in
    *"current session"*) ok "p4 self-session refused" ;;
    *) bad "p4 self-session refused" "$out" ;;
  esac

  # setup running guard
  write_config 'return { setup = { "sleep 30" } }'
  n5=$(name_for p4r)
  add_wt "$n5"
  out=$(run_action worktree_merge name="$n5")
  case "$out" in
    *"setup is still running"*) ok "p4 running setup refused" ;;
    *) bad "p4 running setup refused" "$out" ;;
  esac
  write_config 'return { setup = {} }'

  # pre_merge hook failure blocks the merge
  n6=$(name_for p4h)
  write_config 'return { pre_merge = { "false" } }'
  add_wt "$n6"
  commit_in "$REPO"__worktrees/"$n6" hook feature2.txt
  run_action worktree_merge name="$n6" >/dev/null 2>&1
  sleep 4
  assert_file "p4 hook failure keeps worktree" "$REPO"__worktrees/"$n6"
  if git -C "$REPO" log --oneline -3 | grep -q hook; then bad "p4 hook failure blocked" "merge landed"; else ok "p4 hook failure blocked"; fi

  for x in "$n2" "$n4" "$n5" "$n6"; do
    rex kill "$(label_for "$x")" >/dev/null 2>&1 || true
    remove_wt "$x"
    cleanup_wt "$x"
  done
  rm -f "$REPO/.workrex.lua"
}

window_id_of() { # name label
  rex window ls -s "$(label_for "$1")" --json 2>/dev/null     | jq -r --arg l "$2" '.windows[] | select(.label == $l) | .window_id' 2>/dev/null | head -1
}

lane_p5() {
  # failed setup is healed by rerunning it
  n=$(name_for p5)
  write_config 'return { setup = { "false" } }'
  add_wt "$n"
  sleep 2
  assert_eq "p5 failed state" "failed" "$(state_of "$n")"
  write_config 'return { setup = { "echo FIXED" } }'
  run_action workrex_fix name="$n" >/dev/null 2>&1
  sleep 3
  assert_eq "p5 fix reruns setup" "ok" "$(state_of "$n")"
  if labels_of "$n" | grep -qx "sh"; then ok "p5 fix agent"; else bad "p5 fix agent" "missing"; fi

  # ok state with a missing agent window is healed without rerunning setup
  wid=$(window_id_of "$n" sh)
  rex window close -s "$(label_for "$n")" "$wid" >/dev/null 2>&1
  if labels_of "$n" | grep -qx "sh"; then bad "p5 agent closed" "still present"; else ok "p5 agent closed"; fi
  run_action workrex_fix name="$n" >/dev/null 2>&1
  sleep 1
  if labels_of "$n" | grep -qx "sh"; then ok "p5 fix agent window"; else bad "p5 fix agent window" "missing"; fi

  # idempotent when nothing is wrong
  out=$(run_action workrex_fix name="$n" 2>&1)
  case "$out" in
    *'"healed":"none"'*) ok "p5 fix idempotent" ;;
    *) bad "p5 fix idempotent" "$out" ;;
  esac

  # running state with no setup window is healed
  n2=$(name_for p5r)
  write_config 'return { setup = { "sleep 30" } }'
  add_wt "$n2"
  sleep 1
  sid=$(window_id_of "$n2" setup)
  rex window close -s "$(label_for "$n2")" "$sid" >/dev/null 2>&1
  run_action workrex_fix name="$n2" >/dev/null 2>&1
  sleep 1
  if labels_of "$n2" | grep -qx "setup"; then ok "p5 fix setup window"; else bad "p5 fix setup window" "missing"; fi

  for x in "$n" "$n2"; do
    rex kill "$(label_for "$x")" >/dev/null 2>&1 || true
    remove_wt "$x"
    cleanup_wt "$x"
  done
  rm -f "$REPO/.workrex.lua"
}

lane_p0_cleanup() {
  if rex ls 2>/dev/null | grep -q "proto/"; then
    bad "p0 no proto sessions" "found proto session"
  else
    ok "p0 no proto sessions"
  fi
}

case "${1:-all}" in
  reset) reset ;;
  p0) reset; lane_p0; lane_p0_duplicate; lane_p0_cleanup ;;
  p1) reset; lane_p1 ;;
  p2) reset; lane_p2 ;;
  p3) reset; lane_p3 ;;
  p4) reset; lane_p4 ;;
  p5) reset; lane_p5 ;;
  all)
    reset
    lane_p0
    lane_p0_duplicate
    lane_p1
    lane_p2
    lane_p3
    lane_p4
    lane_p5
    lane_p0_cleanup
    ;;
  *) say "usage: $0 [reset|p0|p1|p2|p3|p4|p5|all]"; exit 2 ;;
esac

if [ "${WORKREX_SMOKE_FAIL:-0}" = 1 ]; then bad "forced failure" ""; fi
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || { say "failed:$FAILED"; exit 1; }
