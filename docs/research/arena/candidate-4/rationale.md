# Why this design — candidate 4 (adversarial reviewer turned designer)

I attacked the naive port before writing it. The naive design — "a Lua action writes a
sentinel file, an agent-window wrapper polls it" — dies on contact with Rex's 30 s action
budget: whatever the action "waits" on has to keep existing after the action returns.
Below: the alternatives I examined, what each attack exposed, and why I chose
what I chose.

## Alternatives considered and rejected

**1. Sentinel file polled from inside the action / background Lua watcher process.**
Rejected. An action cannot wait; spawning a detached `rex do watcher.lua` from the action
adds a second unmanaged process (`rex.exec` inside the action blocks until the child
exits, so the "spawn and return" needs ugly gymnastics on the server's PATH-stripped
environment), two writers to the gate state (watcher + user reruns), and no liveness
knowledge beyond the file. Chosen instead: **the gate lives in the agent pane's
interactive shell via `initial_input`** (verified terminal option: "text to type into the
terminal once its program starts … end with newline to run a command"). The gate is then
synchronous with the shell that execs the agent, written by the shell itself when it
detects closure/death of the setup step, and it keeps checking after every 2 s sleep —
"sentinel written but the waiter already passed" races and torn reads are structurally
impossible, timeouts and `kill -0` liveness probes cover the "no sentinel, no pane"
branches. `workrex_fix` re-types
the gate into a live pane through the verified `terminal.write` method — the wedge-buster.

**2. Setup commands executed with a wrapped non-interactive `command` on the pane**
(`{ "zsh", "-f", setup_script }`). Rejected: loses the interactive Ctrl-C/recovery path
(a wedged script leaves a dead pane from which you can't rerun), and breaks the
mise/direnv-by-cwd environment Conductor writes about (their 5 s shell-config capture is
exactly the interactive-vs-non-interactive drift attack — being in the interactive login
shell in the worktree cwd sidesteps capture entirely). The action never runs setup
commands; it only types one line. This also solves the server-PATH gotcha, which applies
to `rex.exec` not interactive panes.

**3. workmux-style git-config canonical metadata** (all state in
`branch.<b>.workrex-*` / `workmux.worktree.<handle>.*`). Partially rejected. Store-in-repo
feels stateless but: port leases and agent identity are per-machine; deleted-dir
registries drift silently (the attack list's "registry vs reality"); and the session map
already has a proven home in `~/.local/state/rex/worktree-sessions`. Chosen: **the
worktree's own `.workrex/` dir is canonical** (dies with the worktree, travels with
checkouts, gitignored via `.git/info/exclude` like workmux's prompt files), the global map
keeps only session-id linkage (rename resilience, already shipped), and git config keeps
exactly one key (`branch.<branch>.workrex-base`) as a resurrection fallback if someone
deletes the worktree dir without removing the branch. Drift shrinks to "one id may be
stale", already handled by `forget_session` in the existing code.

**4. workmux's deferred detached cleanup worker (setsid + device/inode fencing +
quarantine GC) to allow `merge`/`remove` from inside the owning session.** Rejected. The
attack (killing your own pane mid-action) is real, but the machinery needed to do it
safely is a subsystem-scale artifact of supporting multi-backend tmux/zellij/kitty and
long-lived daemons; here a one-line guard — refuse when
`existing.session_id == ctx.session_id`, **already implemented at worktrees.lua:543** —
achieves safety with zero new moving parts. Honest trade: you must switch sessions before
merging/removing a worktree. That is a price I pay deliberately.

**5. Auto-committing staged changes during merge (workmux behavior).** Rejected: it needs
git's interactive editor inside a 30 s action, i.e. another wedge. The guard is the
honest answer: dirty worktree → refuse with the exact status, override via
`allow_dirty=1`.

**6. Copy-type takeover of everything** (Conductor's "Files to copy" for all ignored
files, or excluding nothing from takeover). Rejected after attacking: stale copies and
absolute-path breakage produce exactly the symlink-chain/wrong-target drift the attack
list worries about; the relative-symlink path is safe **only** because
`worktree_paths()` (worktrees.lua:73–77) makes every worktree a sibling of the root, so
all links are arithmetically `../../<project>/<rel>` rather than realpath-derived.
Conductor's docs agree: never copy `node_modules`/`.next`/`dist`/`target`. The default
takeover list is therefore precisely { gitignored top-level `.env*`, gitignored
`CLAUDE.local.md` (symlink) } — cheap, safe, covers 90 % of the "workspace ready" itch.

**7. Port allocator with lsof / port-scan reservation daemon.** Rejected. `lsof` isn't
guaranteed on the server's PATH, and a daemon is unkillable-wedge territory. The leak
attack is fully served by: lease file + `mkdir`-based lock (`flock` isn't on stock macOS)
+ lazy validation against `session.list`, plus a one-shot `nc -z` probe inside the
lease window. The self-healing range bump (beyond the max used lease) keeps two projects
from arguing when they filed overlapping `.workrex.lua` ranges.

**8. `.workrex.yaml`/TOML config format instead of Lua.** Rejected: a parser dependency
in a Lua config, no JSON-stdlib in shell land, and the repo already speaks Lua
(`worktrees.lua`/`context.lua`). `dofile` also failed-soft: a syntactically broken team
file degrades to a warning, not a brick.

**9. Fine-grained copy semantics for `.env*`** (e.g. copy only when missing, copy-tree-then-swap, "copy if destination empty").
Over-engineered: sync rules use `cmp -s`-idempotency, tracked
files skipped via `git ls-files --error-unmatch`, differing user-configured destinations
overwritten only by explicit user rules, default rules never clobber. Simple, auditable,
no copy "cache/format versions".

## Kept-in-scope wedges + standing recovery surface (oppose-to-deletion)

Honest answers: **gate wedge** still possible if `initial_input` fails to be typed (Rex
taps text once at program start; on a slow login shell this should always land, but the
wedge exists in the corner of 500 ms login shells plus human weirdness) and **port leak**
when a session dies without being killed via Rex. Both have user-visible recovery:
`workrex_fix name=<n> reset|kill` re-types the gate through `terminal.write` and
releases leases; the gate's hard timeout (config `setup.timeout`, default 20 min) means a
forever-wait is never the *only* state. What remains is a user-recoverable one-command
reset, ergonomically equivalent to an error message rather than a mystery.

## What got cut because the attack made it expensive

Deferred-cleanup worker, auto-commit stage, monorepo subdir config files, Conductor's
`scripts.run` run-button model, agent-status tracking (dashboard/sidebar) beyond the
existing setup pane showing live output, sandboxed/remote anything. Each cut named in
plan §12 with its price.
