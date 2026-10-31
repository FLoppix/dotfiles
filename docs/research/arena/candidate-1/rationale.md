# Rationale — Workrex candidate 1 (workmux-faithful port)

Companion to `plan.md`. What follows is the decision log: each fork in the road in
this design space, the alternatives I considered, and precisely why the chosen
branch won or the others were rejected.

## 1. The gating architecture — the question the arena harness posed

The task states the hard question verbatim: Rex actions have a ~30 s budget, but
Conductor-style setup (pnpm install) runs for minutes. Does that force a
"sentinel-gate" hack, or is there a better Rex-native ordering?

I verified against the live CLI rather than guessing:

- `rex api describe session.create` → `initial_windows` is nullable (`"type":
  ["null","array"]`), so a session can exist with no windows at creation.
- `rex window new --help` → `rex window new -s SESSION [LABEL] [--focus=false]
  [-c DIR] [-- COMMAND...]`: **windows can be created in an existing session from
  the command line**, and the API mirror `session.new_window` exists with the same
  knobs. This kills the premise of the sentinel question entirely.
- `rex do --help` → scripts with `rex.on` handlers can stay resident and react to
  server events ("event actions"). This is a possible daemon-based gate.

Alternatives considered:

1. **Sentinel/polling gate** (a background loop in the action or a state file a
   poller watches, waiting on `git config workrex...setup=ok`). Rejected: with
   `session.new_window` existing, polling adds a moving part to solve a problem the
   server solved. It also wastes the action budget and its failure modes (lost
   poller, stale sentinel) are nastier than the problem.
2. **Event-daemon gate** — a long-lived `rex do gate.lua --all` with a `rex.on`
   handler that adds the agent window when the setup block exits. Rejected as the
   *primary* mechanism: it is a second long-running process to keep alive across
   server restarts, its lifecycle (who starts it? after reboot?) is unspecified in
   the CLI, and my live capture showed the event stream idling with effectively
   undocumented event names — I could not verify a `block_exit` event exists.
   Building the critical path on an unverifiable event vocabulary violates the
   task's "verify against the actual rex CLI" instruction. It remains a nice
   future *addition* (e.g. status icons) once the vocabulary is mapped.
3. **Self-provisioning gate (chosen)** — the setup script's last step runs
   `rex window new -s $sid "$agentname" --focus=false -c "$path" -- <agent>`.
   Chosen because: (a) the gate is colocated with the thing it gates, so there is no
   external state to drift; (b) it exactly reproduces workmux's ordering
   (provision_environment → then the mux target, workmux core notes §1.5/§1.6) with
   the setup window standing in for the not-yet-created agent pane; (c) failure
   handling is linear code in the same shell — `fail` exits *before* the window-new
   call, so "failure → no agent" is structurally guaranteed rather than negotiated
   between two processes; (d) reruns are trivial (a fresh block re-executes the
   same script); (e) blocks run with the login PATH (verified in the
   `com.superlogical.terminal.shell` options schema + AGENTS.md), so the script can
   call `rex` directly, no `rex_bin()` gymnastics from inside the block.

Trade-off honestly acknowledged: if the user closes the setup window mid-run or
the server dies, the gate dies with it — `worktree_setup` (rerun action) recovers,
and the setup state machine in git config (`running → ok|failed`) makes any
stuck session diagnosable with one `git config --get`. The daemon alternative
would have survived that edge better; linear correctness won.

## 2. "Provision BEFORE any pane" — literally, or honestly?

Workmux runs `post_create` hooks *before any mux window exists* (core notes §1.5
step 2, explicitly "before any mux window is created"). Two faithful options in Rex:

1. **Fully literal**: `session.create(initial_windows = null)` (verified possible) →
   run file ops + hooks from the action itself *before* any window → then create
   nvim/setup/agent windows. Rejected, with a concrete reason: hooks would have to
   finish inside the ~30 s action (they would, per workmux's design philosophy,
   still be a black box) — and the task's requirement #2 explicitly wants long setup
   to be **visible** with output and rerunnability. Running hooks invisibly inside
   a 30 s budget is the one workmux property that conflicts head-on with the
   product requirements; delivering a compromise there is not optional.
2. **Chosen**: file ops run inside the action (they are pure filesystem work,
   bounded ≤5 s), then the session is created with `[nvim, setup]` and hooks + setup
   run in the *visible setup window*, which doubles as Conductor's Setup tab
   (conductor notes §1: "bottom panel with tabs (Setup / Run / Terminal)"). The
   agent — the pane the gating is about — still does not exist until provisioning
   ends, which is the invariant workmux actually cares about (its `resolve_pane
   _configuration` injects the agent into a pane only after hooks and file ops ran).

So the stance is workmux-faithful where Rex permits and Conductor-faithful where the
requirements demand visibility; no sentinel was necessary either way because of the
§1 verification.

## 3. Env injection — the F3 discovery

`block_creator.list` proves the terminal block options schema has
`additionalProperties: false` and lists exactly: `shell, command, login, cwd,
path_prepend, size, theme, initial_input, exit`. There is no env map. The task
plainly requires env injection (workspace path/root/name/branch + port block).
Options:

1. Write env into `initial_input` (typed exports). Rejected: typed input races the
   shell's readiness, cannot be trusted for the agent window ordering, and is
   unrecoverable.
2. Inline `export` in a generated wrapper at window-creation time. Chosen-adjacent
   but insufficient alone: values computed once get stale when the user edits
   `.workrex/env` or a rerun changes ports.
3. **Chosen**: a generated gitignored `<worktree>/.workrex/env` file + the wrapper
   `sh -c 'set -a; . "$1"; set +a; shift; exec "$@"' sh <envfile> <args…>` for every
   workrex-created window, plus sourcing the same file at the top of setup.sh and
   hooks. This mirrors Conductor's model where env is a property of the workspace,
   not of one pane, and makes hook scripts and future Run-actions read identical
   env. `export WORKREX_PORT…=…` matches the `CONDUCTOR_PORT` block design
   (conductor notes §4, 10 contiguous ports).

Port allocation deliberately reuses no external allocator: a per-repo
`workrex.ports.next` counter in git config + a `/dev/tcp` busy-probe (no `nc/
lsof` dependency, verified bash-3.2 sh supports `/dev/tcp`). Alternative like "lsof -
i" rejected: I cannot rely on lsof path or speed inside a 30 s action; the probe
spawned once in a single sh process is both faster and dependency-free.

## 4. Config: format and honesty of "committed per-repo"

Task requirement: per-repo committed config, Conductor-style. Options:

1. YAML/TOML + a Lua-side parser. Rejected: I would hand-roll a YAML or TOML parser
   in Lua 5.1 inside a dotfiles repo — exactly the kind of hidden dependency the
   task wants avoided; both formats' quoting/indent rules are a security surface
   too (config → shell string formation later).
2. JSON. Rejected: no comments; a config is documentation; Conductor shipped with
   comments in the docs' snippets (`"$schema"`, inline comments in `.toml`).
3. **Lua config files** (`<repo>/.workrex.lua` returning one table). Chosen: it is
   the user's config idiom (the whole repo is Lua), the format is trivially parsed
   by the runtime we run in (`load` with a custom `_ENV`), comments are free, and —
   as a bonus — the file can grow small functions later without a migration.
   Rejected alternative inside this: `dofile`/`require` of the project config
   without a sandbox — rejected because that hands a remote repo the keys of the
   local machine. The loader therefore sandboxes project config (empty `_ENV`,
   must `return` a table), while the *global* user config
   (`~/.config/rex/workrex.lua`) is trusted (it is already installed locally).
   This mirrors workmux's suspicion of project config (`auto_name.command`
   global-only for the same reason, core notes §3.3).
4. `.workrex.local.lua` (machine-local, registered in `.git/info/exclude` rather
   than the user's `.gitignore`): rejected the alternative "just don't commit it" —
   registering in info/exclude is the workmux-proven mechanism (its notes §1.3
   step 16 does the same for `.workmux/`) and doesn't mutate tracked files.

The `"<global>"` list-splice convention was copied from workmux unchanged — it is
the one piece of config semantics that makes committed team lists and personal
additions compose without a merge algorithm.

## 5. State in git config

Workmux stores lifecycle state in git config keys (`branch.<name>.workmux-base`,
`workmux.worktree.<handle>.*`; core notes §4, §1.3 step 11 "Store review base
BEFORE checkout"). Options:

1. Keep the flat `~/.local/state/rex/worktree-sessions` file alone, extend it with
   setup/ports. Rejected: machine-local state for data that *is* branch metadata;
   it is invisible to anything that looks at the repo (scripts, teammates, future
   dashboards), gets no rename key-migration story, and dies if the state dir is
   cleaned. The base-branch fact belongs to the branch, not to my `$HOME`.
2. **Chosen**: git config as primary (`branch.<b>.workrex-base` +
   `workrex.worktree.<name>.*`), with the existing flat file kept as a read
   fallback during migration (lazy backfill). Keys written *before* `worktree add`
   exactly like workmux step 11 (create-then-lose-base-info is the failure mode
   that this ordering exists to prevent: if the action dies mid-`worktree add`,
   the base is still on record to clean up with).
3. Locking honesty: workmux uses `GitConfigLock` (`.workmux.lock` in the common
   dir). macOS has no `flock` binary (verified platform reality), so workrex relies
   on git config's per-key atomicity + the pre-existing name collision check
   (worktrees.lua:448) and says so in the plan instead of pretending a lock exists.

## 6. Merge semantics

Workmux's merge pipeline is precise (core notes §2): chdir main, resolve target (CLI
`--into` > recorded base > detected default), dirty guards, hooks, 3 strategies,
cleanup ordered so cleanup *can fail without failing the merge*, and a deferred
worker only when cleanup must kill the process's own session.

- Strategy set: `merge | rebase | squash` copied as-is rather than simplified to
  just squash — cheap now, and it is the piece most likely to be daily-useful.
- Dirty guards copied exactly (`allow_dirty` mirrors `--ignore-uncommitted`,
  staged changes auto-committed). Deviation, honest and documented: workmux opens
  GIT's editor for staged changes and for the squash commit message; from an
  action there is no TTY, so workrex auto-commits with an explicit message, and for
  squash w/o `squash_message` it opens a `context.popup` REPL — i.e. workmux's
  interactive behavior is preserved via the mechanism Rex already has for
  interactive affordances (the popup layer, context.lua:74-91), not dropped.
- Cleanup invariants copied: cleanup errors never propagate as merge failure
  (`pcall` + `cleanup_error` in the result), matching workmux §2's partial-failure
  semantics.
- Deferred worker: workmux spawns a `setsid` detached cleanup worker for the
  "I killed my own window" case. Rex has no setsid binary (verified); the practical
  Rex equivalent is a `nohup` 2 s delayed `rex kill` from inside the picker action,
  used only in the popup path where the action's own session would otherwise be
  killed out from under the popup (Rex's 409 cross-session-teardown conflict, per
  AGENTS.md). Documented as *partially* replacing workmux's worker in §11.
- Quarantine-before-prune cleanup copied from workmux §2.8.2. Alternative kept
  from today's code (`git worktree remove --force` + `branch -d`): rejected because
  the worktree that a process is cwd'ed in produces EBUSY-style failures
  cryptically; the rename-side-then-prune approach is strictly more robust and
  is the reviewed workmux solution to the exact error window.
- Conductor's archive: merged into `pre_remove` rather than a separate hook +
  separate action. Conductor's archive script exists to clean resources setup
  created outside the worktree — in workrex that is precisely what pre_remove does;
  a second `archive` hook would be documentation noise. Conductor's History/restore
  was explicitly out of scope (needs a transcript store).

## 7. Reused vs rewritten — line evidence

Nothing with a working past was reimplemented: reuse `run/run_ok`
(worktrees.lua:41-61) for all subprocesses, `repo_root` (:65-71) and
`require_root` (:130-162) for root resolution, `worktree_paths` (:73-77) and
`project_name` (:79-85) for path/label conventions — meaning workmux's
`<project>__worktrees/<handle>` layout already matches workrex's
(<parent>/<project>__worktrees/<name>, worktrees.lua:73-77) and the design keeps
it — `find_worktree_session` (:381-401) for session recovery, `rex_bin()` (:176-206)
for cross-session kills (worktree_remove's existing pattern, :547-553),
`agent_command`/installed-agents (:104-115, :236-282) unchanged, `context.popup`
(context.lua:74-91) for the squash editor and the pickers. New code is limited to
the four mechanisms the task asks for: config loader, file/env layer, the
setup-window gate, and the merge flow — everything else is glue.

## 8. Deliberate non-goals (per the task's "keep the surface minimal")

Deferred: sandbox/remote/dashboard (mandated), plus three things I could have
included and didn't: (a) workmux's window/"pane" template system — Rex sessions are
already two-window sessions and a layout DSL would triple config surface for
marginal value; (b) agent status hooks — Rex exposes OSC 7501 `program_status`
(seen in the API list) which is the future hook, but wiring per-agent plugins is its
own project; (c) a `sync-files` action — fileops.sh is written to be re-invokable
and the action is 10 lines, but it is not in the required list. Each is logged in
plan §11 so the next iteration can pick them up without redesign.
