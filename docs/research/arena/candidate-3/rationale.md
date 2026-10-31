# Why this design — candidate 3 (Rex-native minimalist, incumbent challenger)

Design stance: **extend `worktrees.lua`, verify every addition against the live rex CLI,
reject anything the incumbent code doesn't already prove works.** The four mandated features
(config, long setup, merge/cleanup, env injection) were each shaped by first asking a
simpler-possible-alternative question and only keeping the complex option when the simple
one was *verified impossible* — not merely assumed.

Output: the spec is in `plan.md`; this file records the alternatives and why they lost.

---

## 1. The central bet: no sentinel polling — VERIFIED, not guessed

The most consequential decision is that **the agent window is not created at session
start and polled into usefulness; it is created after setup reports done.** This rests on
one probe:

```
$ rex api describe session.new_window
  "session_id":  { "type": "string",  "description": "The session to act on." }   ← required
  "layout":      { "type": ["null","object"], "description": "The blocks to create ... Required." }
```

`session_id` is a first-class input parameter, so a server-side action can open a window in
*any* named session — including the new worktree session — without being the session's owner.
`rex.call("session.create", …)` and `rex.call("session.list", {})` are already proven raw
call sites in the incumbent (worktrees.lua:419, 314), so `rex.call("session.new_window", …)`
is the same transport, not a new mechanism. `session.view` exposes per-window `label`
(verified in the describe output), which is exactly enough for idempotence checks.

Alternatives considered for the gating problem and what set them aside:

1. **Sentinel polling from the action** (spawn agent window immediately; poll
   `.workrex/setup.done` or an OSC-7501 status in a loop for up to 28 s inside the action).
   — Rejected: burns the entire 30 s budget just holding open, yields unreachable states
   (install finishes at t+31 s), and companies the "output visible" requirement — you'd end
   up re-reading pane output to fake progress. Worse than the event-report for zero benefit.
2. **Poll from a later action** (e.g. re-check on `worktree_open` / keypress and graft the
   agent window whenever the marker exists, keeping no in-flight gating at all).
   — Rejected as the *primary* design: leaves the session in a state where the agent never
   appears automatically, so every setup requires a manual follow-up keypress; the
   completion callback does the same job with no user in the loop. (Its good half —
   "on open, a worktree without an ok-marker reopens as setup-pending" — **was kept** as
   slice 5.4's decision point.)
3. **Pre-create all windows and let the agent race the setup.** — Rejected: the task says
   the agent window must be *gated*; everything else (agent launching against a
   half-installed tree) is the exact Conductor bug that gated setups fix
   (conductor-notes.md §2: failures are surfaced before chats start). Also would rely on
   unverified `keep_open`/command-dispatch semantics from the block API.
4. **`rex.events`/`rex.on`-based listener waiting for a completion event.**
   — Rejected: `rex do --help` shows any such listener must be a *running* script state
   per session, which adds a live process where none exists today; whereas the
   self-report line `rex do -s "$6" workrex_setup_done …` is one line in one pane script
   and needs nothing watching. Event *scoping* is what `rex do -s` already does.

So the event-report callback + `session.new_window` release is the minimal feasible design,
and the RCA-depth criterion — *is the simpler thing actually impossible?* — is satisfied by
showing the simple thing is `session.new_window` itself, which we then use.

## 2. Long setup: run in a pane, report via self-sourced keypress

`pnpm install` blows way past 30 s; the incumbent already says so ("long setup work belongs
in a window, not in the action", worktrees.lua:16–17). So the design rule became: *the only
code that runs inside the 30 s action is the code that provably finishes in ms — everything
long becomes pane script.* That yielded:

- **File ops (copy + relative symlinks) belong in the action**, not the pane: they're ms-sharp
  (cp of a handful of gitignored dotfiles), and moving them to the pane would mean the pane
  script needs to know the rules AND handle their failure, both of which the action already
  handles (§5.1's step 8 with its worktrees.lua:458–464 rollback). No new mechanism needed.
- **Setup is a pane script generated in Lua** using the same shape as the pickers' existing
  `sh -c` scripts (worktrees.lua:594–610, 630–664). No install step, no `PATH` trap (terminal
  blocks get the login PATH per AGENTS.md), and success/failure is *the pane itself* —
  visible by construction. Workmux NR§1.9's observation that "pane stays open with a shell
  after the command exits" matched our `exec "$SHELL" -l` closing figure exactly.
- **Self-report only.** The marker `.workrex/setup.done` is written by the *action* (which
  is the only trusted writer), and only on success. A `setup.failed` bookkeeping file was
  rejected: the visible pane + the "no marker ⇒ reopening is setup-pending" rule carries all
  the state recovery needs without a third file.

## 3. Merge: reuse the incumbent's cleanup story rather than workmux's wholeCleanup machine

workmux's merge flow (workmux-core-notes §2) is a merge + a cleanup state machine with a
deferred worker, quarantine renames, identity fencing, and window-token bookkeeping. That
complexity exists because workmux merges from *inside the tmux window it then kills*. In
Rex, the incumbent already answers that situation with a guard (worktrees.lua:543–545:
"this worktree is open in the current session; switch sessions first", i.e. don't kill what
the user is sitting in). So candidate 3's design:

- `worktree_merge` runs the merge in the action and, at teardown time, reuses the exact
  teardown path that `worktree_remove` already runs from a stable session (kill via resolved
  `rex_bin()` + `rex kill` (worktrees.lua:547–553), then `git worktree remove` (555–560),
  then `forget_session`).
- If the user *is* inside the session being merged, we do NOT kill — we tell them the merge
  succeeded and the teardown is a manual `rex kill` away. A deferred-cleanup worker was
  rejected as unmarkable: *whether* a process spawned from a session being killed survives
  that kill is unmeasurable with the tools we're allowed to use, and candidate 3 doesn't
  ship mechanisms it cannot test. Deferred with a trigger in plan.md §12 if the friction is
  real in practice.
- Same guard philosophy extended to `worktree_remove`: two additive guards (pre_remove hook
  failure, pre-flight dirty-worktree check) fire *before* the kill, so every failure path
  leaves an intact worktree. The incumbent's order (kill → remove → branch) is respected;
  the point is only to never enter it with a pending failure.

Also rejected on merge: workmux's `$GIT_EDITOR` squash message (Actions can't open editors),
auto-commit of *staged* changes (same reason — both are documented deviations in §7 step 5
rather than silently wrong), and a separate `worktree rebase` verb (rebase is a merge
strategy here, matching workmux's `merge --rebase`; fewer actions for the same power).

## 4. Config: per-repo Lua, not TOML/JSON — and typed-sandboxed, not raw `dofile`

Conductor's structural move from `conductor.json` to committed `.conductor/settings.toml`
(conductor-notes.md §6: "worktree tooling config is project config") is the part we copy;
the file format battle is where Rex-native wins:

- **Lua chosen**: zero new parser deps, matches Rex's own config language so the user edits
  one dialect, and the schema stays data-only (lists of strings + one optional `base`
  string). Loaded with `load(text, "@.workrex.lua", "t", {…})` — restricted globals, no
  `io`/`os`/`load` in scope — so a malicious/typo'd config can't touch the host beyond
  reading nothing (we only `io.open` from *our* trusted side of the wall, never in the
  cfg's environment).
- **TOML/JSON rejected**: needs a parser, invites a schema doc nobody will keep in sync, and
  forces a second editing dialect on a Lua-native tool. Also rejected: global
  `~/.config/rex/workrex-defaults.lua` — deferred until a second repo wants it (§12), same
  reason workmux's complicated `"<global>"` splice exists (workmux-core-notes §1.8) and
  we don't yet need it.
- **Conductor's one sharp edge copied precisely**: adding any `files` table removes the
  `.env*` default (conductor-notes.md:167), and `files = {}` disables copying —
  documented in plan.md §2 so intent is never ambiguous.

## 5. State: reuse everything, store the one new thing where git already stores things

Three existing state files (`worktree-sessions`, `worktree-agent`, `worktree.log`) are cited
and kept untouched. New state was deliberately pushed to where it dies naturally:

- **Base branch → `git config branch.<branch>.workrex-base`**, mirroring workmux exactly
  (workmux-core-notes §4's table, `branch.<name>.workmux-base`). Reasoning: it's per-repo,
  survives session rename *and* reboots, is deleted with the repo, and needs no new file
  format. A `worktree-bases` state file beside `worktree-sessions` was the alternative and
  lost: it would duplicate what git config offers without any of the lifecycle wins.
- **Setup marker → `<worktree>/.workrex/setup.done`**: dies with `git worktree remove`, so
  no GC path is needed. The `.git/info/exclude` line mirrors workmux's own `.workmux/`
  exclusion trick (workmux-core-notes §1.3 step 16) — the marker naming avoids being an
  untracked-interview burden for users' `git status`.
- **Ports → nothing**: pure fnv-hash of the worktree path, no allocation file. A
  `worktree-ports` ledger was rejected explicitly because crash-orphaned reservations leak
  forever, while a deterministic hash is *self-healing on restart*. Trigger for an allocator
  is recorded (§12) if real collides occur.

## 6. Minimal surface, audited plainly

Final ledger (plan.md §13): **1 new file** (`workconfig.lua`, ~150 lines), **0 new shell
scripts**, **0 new state files**, **1 new API call** (`session.new_window`), **2 new
keybindings**, **3 user-typeable actions** (`worktree_merge`, `worktree_merge_prompt`,
`workrex_setup_retry`), plus the internal `workrex_setup_done` the pane calls. Everything
else is edited lines inside files that already exist.

Deliberate deferrals, each with an explicit trigger (§12): archive/restore, monorepo config
discovery, global defaults config, port allocator, `workrex sync-files`, deferred teardown
worker, agent-driven branch naming. Sandbox/remote/dashboard are named non-goals (§11) —
personally out of scope for a personal dotfiles repo, and workmux's own porting priority
list puts them after status tracking, which is itself a different work stream.

## 7. Deviations from workmux/Conductor, stated rather than hidden

1. Squash merges use a fixed commit message; workmux opens `$GIT_EDITOR`. The action cannot
   hold an editor TTY; documented in §7 step 5.
2. Staged changes block merge; workmux auto-commits them. Same FDI limitation; the guard
   error says so (§7 step 3).
3. Merge from inside the merged session is a two-step (merge auto-runs, teardown is manual).
   workmux hides this with a deferred worker; we refuse to ship one untested. §7 step 7.
4. `pnpm install` output lives in the setup pane, not a Setup-tab-style UI. A pane *is* the
   terminal equivalent of that tab (Conductor "bottom panel Setup tab") — and the pane has
   full scrollback, which the app model lacks.
5. Sub-port-level collision theory: sustained FNV hashing isn't an arbitration mechanism; if
   two trees collide in the 40000–48990 window, port override wins (the number is just a
   suggested default, not a reservation).
