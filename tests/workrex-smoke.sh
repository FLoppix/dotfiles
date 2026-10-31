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
  ensure_driver
  rex do -s "$(driver)" "$@" 2>&1
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
  p1) reset; say "p1 lanes not implemented yet" ;;
  p2) reset; say "p2 lanes not implemented yet" ;;
  p3) reset; say "p3 lanes not implemented yet" ;;
  p4) reset; say "p4 lanes not implemented yet" ;;
  p5) reset; say "p5 lanes not implemented yet" ;;
  all)
    reset
    lane_p0
    lane_p0_duplicate
    lane_p0_cleanup
    ;;
  *) say "usage: $0 [reset|p0|p1|p2|p3|p4|p5|all]"; exit 2 ;;
esac

if [ "${WORKREX_SMOKE_FAIL:-0}" = 1 ]; then bad "forced failure" ""; fi
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || { say "failed:$FAILED"; exit 1; }
