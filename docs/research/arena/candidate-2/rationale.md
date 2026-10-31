# Rationale — Candidate 2 (Conductor-first)

Why this design, and what was rejected on purpose.

## North star

The felt experience: one keypress, then a ready-to-work session — and "ready" means
deps installed, env present, ports reserved, branch recorded, failure state impossible
to miss. That drove three stance-defining choices:

1. **Everything setup-related is a real, streaming terminal window**, not background
   work. Conductor's Setup/Run/Terminal bottom panel is its best UX idea; a real
   multiplexer should beat a GUI at it, not approximate it with a spinner.
2. **The user is never blocked and never surprised.** The session appears instantly
   (unchanged from today's <1 s `session.create`); the agent exists immediately but is
   gated; setup failure is a first-class *visible* state with a built-in rerun path.
3. **Fewer moving parts beats clever daemons.** Everything is generated shell scripts +
   two small state files. No event-bus subscribers, no long-running `rex do` watchers,
   no idle battery drain.

## Alternatives considered and rejected

### Gating mechanism

- **`rex wait` on the setup block + server event subscription** (`rex.on`, `data.connect`)
  to spawn the agent window post-hoc. *Rejected:* needs a long-lived `rex do` process per
  creation (a daemon-shaped moving part), races a client that may close, and the agent
  window would pop in seconds later — jarring, and broken if the listener dies. It also
  couples setup completion to Rex event schemas I'd then have to grep per release.
- **Agent-gated poll loop on a `status` file** — *chosen.* One obvious script, trivially
  debuggable (`cat .workrex/status`), survives client disconnects, does the right thing
  if the user closes the setup window (timeout + hint). 1 s polling is the only cost, and
  it's a sleeping `sleep 1` loop, not a CPU spinner.

### Where setup runs

- **workmux-style synchronously inside the add action before the session exists**
  (post_create hooks first, then windows). *Rejected:* directly violates the ~30 s
  action budget for the flagship case (`pnpm install`), and it zeroes out the optimistic
  feel — the user stares at a paused prompt for a minute. Partially kept, inverted: the
  *file-op planner* runs in Lua at creation because the gating decision needs its
  results, but the copies themselves execute inside the streamed script.
- **A detached cleanup-style worker for setup** (workmux `_deferred-cleanup` analogy).
  *Rejected:* setup needs *visible* output and a gate handshake; a service that also
  streams to a pane becomes a mini job scheduler. One script per worktree is the same
  job with no scheduler.

### Env injection

- **Wrapped `env VAR=… argv` per block.** *Rejected:* the block list at session-create
  time can't be guaranteed to cover panes the user adds later, and a giant argv for 7
  vars × ~6 vars is unreadable in `rex session inspect`. A sourced file is live-readable.
- **direnv (generate a `.envrc`)** — first-alternative I seriously considered because it
  is the ecosystem default. *Rejected:* adds a dependency the repo may not have, changes
  behavior of shells beyond panes I control, and writes a file into the user's worktree
  that teams didn't ask for. The `WORKREX_*` file is inert unless sourced.
- **Per-block `env` option** — doesn't exist (verified live via the options schema:
  `args, command, cwd, exit, initial_input, login, path_prepend, shell, size, theme`).
- **`initial_input`-typed `source …` for the shell pane** — kept for nvim in wrapper
  form; rejected as the general mechanism because typing into a pane pollutes scrollback
  and races slow shells. `path_prepend` is fine but solves PATH, not our 7 vars.

### Config file format

- **`jq`-driven `.workrex.json`** (the user already requires jq for `worktree_open_prompt`).
  *Rejected:* two-process dance per read (`rex.exec` → Lua string → re-parse), no
  numbers/booleans safety net without hand-rolling a JSON validator, and
  `"$schema"`-style tooling doesn't exist here.
- **Raw `dofile`** — arbitrary code in the action's Lua env. Unacceptable; rejected
  immediately.
- **`load` with an empty environment** — *chosen:* validates structure with zero
  dependencies, denies I/O at load time, and reads like config, matching the repo's
  "config is Lua tables" idiom.
- **TOML to be Conductor-literal** — no TOML parser available in the environment;
  rejected on availability, not on aesthetics.

### Ports

- **`lsof`/`ss` scanning for the next free port** — *rejected:* slow (hundreds of ms on
  macOS `lsof -i`), breaks when a server briefly listens on a port the next add wants,
  and can't express a *block* need. Conductor's insight is that a **block of 10** makes
  `pnpm --port` and friends trivially parallel; a scanner gives single ports, not blocks.
- **Hashing the worktree name to a port range** (deterministic, no state file) — cute,
  but collision-prone across repos and unfixable when two names hash to the same slot.
- **Sequential allocator + GC-on-read** — *chosen:* ~15 lines, survives a wiped state
  file (corruption → default 3100, worst case a shared block loudly fails in the dev
  server pane). Honest failure mode documented in the env file itself.
- **Rex action per-allocation (`rex do workrex_alloc`)** — pointless IPC round-trip;
  the allocation happens inside the same action that writes the env file.

### State placement

- **All state in git config** (workmux §6) for everything. *Rejected for ports/archive
  meta:* it is machine-local cache; committing it to a shared `.git/config` diff while
  `chezmoi diff` runs is noise. *Kept in git config for exactly one thing the team might
  need:* `branch.<branch>.workrex-base` (verified working with a slash-subsection), since
  the merge target outlives ~/.local and belongs to the repo.
- **Rex server API as the store** (tag sessions, etc.) — no such primitive for durable
  key/value; rejected.

### Merge / archive shape

- **Pure-Lua action doing all merge steps with `run_ok` + timeouts.** *Rejected:* hard
  ceiling at 30 s for pre_merge hooks (`make lint`) and the archive hook that may `rm -rf`
  node_modules; failure mid-chain leaves the user staring at a truncated action result
  rather than a terminal. Partially kept: the *guards and arg assembly* still run in Lua
  (cheap, deterministic error messaging), the pipeline runs in a streamed popup window.
- **Calling `worktree_merge_apply` from the popup** (nested `rex do` for the git work).
  *Rejected* as duplication: the popup is already a `sh` pipeline; making it call back
  into an action for steps it can do directly doubles the failure surface. `merge_apply`
  exists only as a headless/scripted entry (no hooks), mirroring workmux's `--headless`.
- **Quarantine via workmux's deferred-cleanup detached worker** (identity-fenced
  `setsid` process). *Rejected:* the exact problem it solves — killing the pane that
  hosts the cleanup process — can't happen here, because cleanup runs in a popup in the
  *caller's* session while the victim is another session (`rex kill`, the pattern
  worktrees.lua:548–553 already uses). Instead: instant `mv` to `.workrex-trash/` + lazy
  GC; pathological leftovers visible and sweepable, no daemon keeping the trash alive.

### Conductor features consciously not ported (and what the user notices)

- **Restorable chat history.** Conductor restores archived workspaces *including
  transcripts*, stored app-side. Rex has no chat abstraction: agent sessions are files
  inside the worktree (`~/.claude/projects/<encoded-cwd>/…`, per the workspace-cwd
  binding in conductor-notes §4). Running/symlinking agent transcript stores per
  worktree would mean daemons that chase each agent's storage layout — a treadmill
  against five agent vendors' config schemas. Dropped. The user notices: `shift+o`
  restores the *branch and a fresh worktree*, never the conversation.
- **Diff viewer / Checks tab / PR flow.** The terminal already has lazygit/hunk/ghui
  popups routed at the same cwd (init.lua:161–164); duplicating them as a parallel
  "workrex UI" adds keys without new power. The user notices: nothing, if they already
  lived in those popups; something, if they wanted Conductor's aggregated per-workspace
  checklist.
- **Branch rename delegated to an LLM.** Conductor auto-names via `llm generate` +
  instructs the first chat to rename. Porting auto-name needs an `llm` binary + a
  request-budget; porting *only* the rename instruction is trivial (seed prompt) but
  per-agent prompt-passing differs wildly (workmux-agent-notes §3 `prompt_argument()`).
  V1: seed prompt for Claude only, manual `worktree_rename` for everyone. Honest, and
  the branch still ends up named by the chat.
- **`archive_on_merge` via a post-merge hook on the forge.** Only the merge command
  archives (in the same streamed transcript). Detecting a merged PR requires `gh`
  polling we explicitly declined.

### Keybinding decisions

- Merge on bare `m` (new, high-frequency), archive on `shift+x` (clustered with the
  destructive `shift+w` remove), restore on `shift+o` (echoes `o` = open), rename on
  `shift+n`, setup on `shift+s`. All verified non-conflicting against init.lua's
  existing bind list. GC deliberately unbound: an untriggerable-mistake maintenance verb
  does not deserve a prefix slot.

## What I'd argue is the divisive call

Running the merge (and archive hook + worktree removal) inside a streamed popup instead
of a synchronous action is the biggest bet. It diverges from workmux's synchronous-pure
style and from the "actions should be cheap scripts" law here. Justification: the *only*
things that blow the 30 s budget in the whole lifecycle are hooks and `rm -rf`, and
Conductor's whole point is that those are visible artifacts, not silent success codes.
Locking the merge pipeline into a popup costs machine-readability of `worktree_merge`
results; `worktree_merge_apply` exists for anyone who needs scripting. If in practice
repos define only trivial pre_merge/archive hooks, the popup is a minor detour; if they
do define real ones, the popup is the difference between "watch it work" and "watch a
spinner and trust it".

## Summary of deltas vs the other three candidates' likely shapes

- Conductor-first means the **setup window + gate is the headline**, not the merge
  machinery: more of the design's budget lands in the streaming/gating/env/port system,
  merge is deliberately lean and judged as a byproduct ("merge = guards + git + archive").
- No background anything: gates, not watchers; checkpoints, not daemons; GC, not
  reapers. Every failure path is a file you can `cat`.
- Everything new is additive to `worktrees.lua`'s existing verbs and state formats, with
  a name-level audit per helper in the reuse map (§10 of plan.md).
