# Workrex — implementation spec (candidate 4: adversarial reviewer turned designer)

Porting workmux's lifecycle machinery (git-config metadata, merge flow, file ops, cleanup
discipline) and Conductor's per-repo committed setup model (setup script, `.env*` takeover,
port block, archive/merge story) into the user's existing Rex worktree sessions
(`dot_config/rex/worktrees.lua`), **after systematically attacking the naive design**.

Every attack that is kept in scope has a named owner for the sentinel, a timeout, and a
user-visible recovery path (`workrex_fix` / `force=1`). Section 3 lists the surviving
wedges honestly; Section 12 lists what got cut because the attack made it expensive.

---

## 0. Verified Rex API facts this design relies on

Re-verified read-only against the live server (`rex api describe block_creator.list`,
`rex --help`, `rex wait --help`, `rex events --help`, `rex actions`):

- **Terminal block options** (`com.superlogical.terminal.shell`): `command` (argv, run
  *through* the shell which reads startup files unless `shell='none'`), `cwd`,
  `login` (default **true** → interactive login shell → per-cwd mise/direnv work),
  `path_prepend`, **`initial_input`** ("Text to type into the terminal once its program
  starts … end the text with one [newline] to run a command"), `exit.on_completion`.
  There is **no `env` option** — env injection must be typed/sourced, see §7.
- **`rex.block.call(terminal_flavor, "write", { block_id = block_id, data = text })`**
  exists (method `terminal.write`) and types into a live terminal. `context.lua` already
  uses the same pattern: `rex.block.call(M.terminal, "pwd", args)` (context.lua:15).
  This is the mechanism for *late-installing / re-kicking the gate* after the shell has
  started — the core anti-wedge primitive.
- **`rex wait <block>` returns the child's exit status**; `--for 10m` bounds it. Not used
  by gating (actions cannot wait), but usable by CLI-side helpers.
- `session.view {}`, `session.create { label, initial_windows }`, `rex.session.new_layer`,
  `rex.do` from popup scripts, `rex kill <session>` — all already exercised by
  `worktrees.lua` and kept unchanged.
- **Action budget ≈ 30 s** (worktrees.lua header, lines 16–17: "An action has 30 seconds
  to finish … long setup work belongs in a window, not in the action"). Nothing long runs
  inside an action in this design.

Line evidence reused from `worktrees.lua` (unchanged behavior):
- `repo_root()` — worktree list porcelain, first entry = main checkout (lines 65–71).
- `worktree_paths()` — sibling convention `<parent>/<project>__worktrees/<name>`,
  branch = `wm/<name>` (lines 73–77). **All relative-symlink math hangs off this invariant.**
- `require_root()` (lines 130–162) with the multi-pane fallback — survives "tab cwd is a
  deleted worktree".
- `find_worktree_session(path, label)` — label match, fallback to remembered session id,
  forget-on-miss (lines 379–401). Renamed-session linkage is already half solved there; we keep it and
  stop adding new per-scope state to the global map (§1).
- `worktree_remove` self-session guard (lines 543–545) — reused by merge teardown.
- `rex_bin()` PATH resolution (lines 174–206) — reused by kill and by popup scripts.
- Popup scripts call `rex do -s "$1" <action>` and log to `$STATE/worktree.log`
  (lines 594–617) — new pickers follow the same template.

---

## 1. Architecture overview — file changes

```
dot_config/rex/
├── init.lua                  # unchanged (works as-is; worktrees.lua still required)
├── context.lua               # unchanged
└── worktrees.lua             # extended in place (stays the single module; ~350 new lines:
                              #   setup/gate/state helpers + workrex_merge/setup/sync/fix
                              #   actions + 1 new binding + worktree_add/open/remove extensions)
~/.config/rex/scripts/        # chezmoi-managed (new dot_config/rex/scripts/, see §9)
├── workrex-setup.sh          # long setup wrapper (runs inside the setup pane)
└── workrex-gate.sh           # agent gate (typed into the agent pane's interactive shell)
<worktree>/.workrex/          # per-worktree state, CANONICAL (gitignored via info/exclude)
├── state                     # key=value: git base, agent, port, created, session id, setup flag
├── journal                   # setup executing log + final sentinel line
├── env                       # generated env file (sourced by gate + panes)
└── setup.log                 # full setup output tail (wrapper tees here too)
<repo>/.git/info/exclude      # + ".workrex/" appended once (workmux's trick, notes §1.3 step 16)
~/.local/state/rex/
├── worktree-sessions         # unchanged: worktree path → session id (rename resilience)
├── worktree-agent            # unchanged: last agent
├── worktree.log              # unchanged: picker failure log
├── workrex.lock/             # mkdir-lock for port allocation + session-map writes
└── workrex-ports             # port lease table (lines "port_base<TAB>project/name")
```

Deliberate split: **worktree-local state is canonical** (dies with the worktree → no
registry drift for everything except the session id, which must outlive renames), and the
global dir keeps only what genuinely needs to outlive the worktree (session id map, last
agent, port leases). This is the single biggest anti-attack decision: registry-vs-reality
drift shrinks to "one mapped session id may be stale", already handled by
`forget_session` (worktrees.lua:398).

---

## 2. Per-repo committed config — `.workrex.lua` (Conductor-style)

A file at **repo root only** (monorepo subdir discovery **cut**, §12), read with
`dofile(root .. "/.workrex.lua")` (Lua-native; a YAML/TOML parser would be a new
dependency in a Lua config — rejected, rationale #8). Absent file → defaults.
The file is committed; per-machine overrides stay out (`.env*` copy covers the common
per-machine need; a `settings.local` layer is deferred).

```lua
-- .workrex.lua (committed; team defaults)
return {
    base     = "main",         -- default --base for worktree_add AND merge target fallback
    agent    = nil,            -- default entry of the agents list (e.g. "claude"); nil = picker default

    setup = {                  -- nil / {} ⇒ no setup, agent window NOT gated (today's behavior)
        commands = {           -- run sequentially in the worktree inside the interactive login shell
            "pnpm install",
        },
        timeout  = 1200,       -- seconds the gate waits before declaring the wait lost
    },

    files = {                  -- rules applied from the MAIN checkout to each new worktree
        -- nil copy ⇒ default: top-level ".env*" that git ignores (Conductor default)
        copy    = nil,         -- e.g. { ".env*", "config/local.json" }; false disables even .env*
        symlink = nil,         -- { "node_modules", "dist" } → relative symlinks, §8
        override = false,      -- true replaces the built-in default rules entirely
    },

    hooks = {
        post_create = nil,     -- { "pnpm run codegen" }; run FIRST INSIDE the setup wrapper
                               -- (not in the 30 s action!) unless setup is disabled, where it
                               -- runs in a throwaway setup pane with no gate
        pre_merge   = nil,     -- { "pnpm test" } run in the SOURCE worktree before merging
        pre_remove  = nil,     -- { "script/teardown-workspace.sh" } before destructive cleanup
    },

    ports = { from = 30000, count = 10 },   -- contiguous block leased per worktree

    merge = { strategy = "merge" },         -- "merge" | "rebase" | "squash"
}
```

Resolution: `dofile` on error → warn and use defaults (a syntactically broken team file
must not brick worktree creation; message logged to `$STATE/worktree.log`).

---

## 3. The attacks, kept in scope, with mitigations

This is the heart of the spec. Each item: attack → design → who writes the sentinel →
what happens on each failure path.

### 3.1 SETUP RACE FAMILY

**Naive design:** write `done` sentinel file after `pnpm install`, agent pane "polled"
by the action — dead on arrival: the action must return in 30 s, nobody is left polling;
or sentinel written but the agent wrapper already gave up.

**Design:** the gate lives *inside the agent pane* as a shell function typed via
`initial_input` into an **interactive** login shell (not a wrapped non-interactive
`command`). The gate is therefore synchronous with the shell that will exec the agent.

Sentinel ownership table:

| Event | Who writes | What is written |
|---|---|---|
| Each setup command starts/ends | `workrex-setup.sh` (in the setup pane) | journal lines `start <i> <cmd>` / `end <i> <code>` |
| Setup finished | `workrex-setup.sh` | journal line `OK` (or `FAIL <code> ─ <last_cmd>`), written atomically: incrementally appended, final line via `printf >> .journal && sync`‑safe pattern (final keyword line is appended last; gate only trusts a line that exactly matches) |
| Setup wrapper started | action | journal line `pid $$` → gate can liveness-probe the wrapper |
| Setup window closed by user | **the gate**, not the action | gate discovers "no block labeled `setup` in my session" → writes `FAIL closed` itself |
| Wrapper crashed without final line | **the gate** (`kill -0 $pid` fails) | gate writes `FAIL dead` |
| Gate timeout | **the gate** | gate gives up — writes `TIMEOUT`, drops to a shell prompt, prints the plan below |
| Gate wedge / impossible state | user via `workrex_fix` | see §5.5 |

Precise gate loop (`workrex-gate.sh`, POSIX sh-compatible but typed into the user shell):

```sh
# args: <worktree_dir> ; all other inputs read from <worktree_dir>/.workrex/
timeout=1200; interval=2; started=$(date +%s)
while :; do
  line=$(tail -n 1 "$W/.workrex/journal" 2>/dev/null || true)
  case "$line" in
    OK)      break ;;                                # ; source env; exec agent
    FAIL*)   break ;;                                # ; print failure, drop to interactive prompt
  esac
  pid=$(grep -m1 '^pid ' "$W/.workrex/journal" 2>/dev/null | cut -d' ' -f2)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    printf 'FAIL\ndead\n' >> "$W/.workrex/journal"; break        # wrapper died, no sentinel
  fi
  if ! has_setup_block; then     # one `rex api call -s "$SID" session.view` behind a function
    printf 'FAIL\nclosed\n' >> "$W/.workrex/journal"; break      # user closed the setup window
  fi
  [ $(( $(date +%s) - started )) -lt "$timeout" ] || { printf 'FAIL\ntimeout\n' >> ...; break; }
  sleep "$interval"
done
```

`has-setup-pane` is one `rex api call -s <sid> session.view` (gate knows its own
session id; the action bakes `session_id=<id>` into `<W>/.workrex/state` before
creating windows; the gate greps for a block whose label is `setup` and whose block_id it
records at creation). `rex` on PATH inside interactive panes — the AGENTS.md PATH gotcha
applies to `rex.exec` inside actions, **not** to interactive shells (they get login PATH);
nevertheless the action resolves `rex_bin()` and bakes the absolute path into `state` too.

Failure-path walkthrough (the four listed attacks):

1. **"Sentinel written but gate already sleeping past it"** — impossible by construction:
   the gate owns the sleep and re-checks after every `sleep 2`; the sentinel is a journal
   *keyword line* only trusted when the last journal line matches exactly, so no torn read.
2. **"Setup fails AND sentinel never written"** — three independent catchers: (a) the
   wrapper always appends `FAIL` in its own `EXIT` trap; (b) if even the trap was bypassed
   (SIGKILL), gate's `kill -0` probe catches it on the next 2 s tick; (c) if the pane died
   entirely, the `has-setup-pane` probe catches it. No path waits forever; the hard
   `timeout` default (config `setup.timeout`, default 20 min) is the backstop for a
   hung-but-alive install (`pnpm install` blocked on a network captive portal).
3. **"User closes the setup window mid-install"** — gate detects missing block → `FAIL
   closed` → agent window prints: *"setup window was closed after step n. Fix things or
   run `rex do workrex_setup name=<name>` (re-runs remaining commands), then start the
   agent with `rex do workrex_open name=<name>`."*
4. **"Setup still running while `workrex_remove` deletes the worktree"** — remove checks
   journal state first: if journal exists and has no final keyword line AND the setup
   block is alive → refuse unless `force=1`: *"setup still running (step n, pid p).
   Use force=1 to kill it (rm -rf of partial node_modules is safe) or wait."* With
   `force=1` remove kills the session (which closes the setup block; wrapper child dies
   with it — process-group termination on block kill is Rex-managed), then proceeds.
   The remove ordering rule: **session kill first, then `git worktree remove`**, matching
   the existing code (worktrees.lua:547–560) — never rm-rf while the wrapper's children
   may still hold files under the worktree.

### 3.2 TEARDOWN FAMILY

- **`workrex_merge` / remove ordering vs. panes with running installs**: merge computes
  teardown *last* (after the merge) and uses the same self-session guard as remove
  (worktrees.lua:543): if the worktree's session is the session the action runs in →
  abort with "switch away, re-run". Killing one's own session from inside is what forced
  workmux into a setsid deferred-cleanup worker with identity fencing — an expensive
  subsystem (workers, dev/inode fencing, quarantine GC) whose only payoff is merging from
  inside; **cut** (§12): the guard costs one line and is already shipped code.
- **Worktree is cwd of multiple panes** across *other* sessions:
  `workrex_remove` enumerates live sessions via `rex ls --json`/`session.list` and lists
  blocks whose `process.child.cwd` (or pwd via `block_cwd`, context.lua:12) is under the
  worktree; those panes' sessions that are NOT the worktree's own session are reported in
  the refusal message (with force override). No silent cd-out of foreign panes.
- **Branch delete vs unmerged work**: unchanged from existing code — `git branch -d`
  (fails on unmerged), result reported (`branch_deleted = ok`), merge command's post-merge
  step additionally *tries* `-d` and falls back to keeping the branch with a message;
  `force` on remove maps to `--force` + `-D` only when explicitly requested by the user,
  never by automation.
- **`rex kill` while the action already returned**: unchanged pattern — action calls
  `run_ok({ bin, "kill", session_id })` synchronously with timeout 20 (worktrees.lua:552)
  before touching the filesystem, because `session.destroy` is unavailable (409).

### 3.3 STATE FAMILY

- **Session renamed**: already solved via `worktree-sessions` map + label fallback
  (§0). No new linkage added — merge/remove/open all resolve through
  `find_worktree_session`.
- **Deleted worktree directory but live session**: canonical state lives in the deleted
  dir → gone. `workrex_open` on a session whose block cwds point into a missing dir still
  works via `require_root` multi-pane fallback. `workrex_fix` detects "session has blocks
  but worktree dir missing" and offers `rex kill <sid>` + map forget (§5.5).
- **Git registry vs state drift**: state can't drift (it IS in the worktree). Base branch
  additionally recorded in git config `branch.<branch>.workrex-base` at creation — this is
  the *fallback* if `.workrex/state` is lost (e.g. user deleted the dir but not the
  branch) and lets `workrex_merge` resurrect base. Drift between the two is harmless:
  git config is authoritative for the base only, and is rewritten by `workrex_sync` /
  on every add.
- **Concurrent `workrex_add`**: workmux takes `.workmux.lock` in the git common dir
  (notes §1.3.10). We need it only where two actions mutate shared files: port table and
  session map. macOS has no `flock` binary the server PATH guarantees → use atomic
  `mkdir` lock `$STATE/workrex.lock` with `os.date`-mtime stale-break (>10 s) and 20×50 ms
  retry, held only across the port-lease + `remember_session` window (a few execs, well
  inside 30 s), created via `rex.exec({ "mkdir", ... })` (mkdir is atomic, like
  workmux's `GitConfigLock` in spirit). Git worktree add itself needs no lock: the second
  racer fails loudly on "already exists / branch already checked out" and the existing
  cleanup path (lines 458–464) undoes half-created branches.

### 3.4 SYMLINK FAMILY (sibling-directory correctness)

Worktrees are siblings: `~/code/proj` and `~/code/proj__worktrees/foo`. A relative
symlink `node_modules → ../../proj/node_modules` is correct from the worktree and from
any nested cwd inside it; absolute paths would break if the user clones/moves the parent
folder, so **links are always relative** (workmux uses `pathdiff`; we generate the path
arithmetically since the layout invariant `worktrees.lua:73–77` guarantees
`<parent>/<project>__worktrees/<name>`):

```lua
-- expected link target for worktree w, entry e:
-- segments relative from w = parent .. "/" .. project__worktrees .. "/" .. name
--> "../../" .. project .. "/" .. e
```

Algorithm per rule `e` (each entry may be a plain name or `src`:`dst`, i.e. `"node_modules:web/node_modules"`):

1. **Skip anything tracked**: `git -C root ls-files --error-unmatch e` succeeds → skip
   (worktrees get tracked files via checkout — stealing them would fight git).
2. Default copy rule and `files.copy` entries are filtered by
   `git -C root check-ignore -q -- <path>` (only gitignored files are taken over —
   Conductor's guarantee, conductor-notes §5.2; prevents pulling real repo content).
3. Idempotency by lstat class:
   - missing → create;
   - existing symlink whose readlink == expected → no-op;
   - existing symlink with different target → replace (unlinked; a symlink is a pointer,
     never user data — logged);
   - existing regular file/dir → **skip with warning** ("remove it manually if you want
     the takeover");
   - dangling symlink → replace and report in `workrex_sync` output.
4. Chain handling: copies go out with `cp -P` (files) / `cp -Rp` (dirs, preserves links
   as links) so a copy *source* that is itself a symlink is never dereferenced into
   the root's real file. Link rules apply **before setup commands** (Conductor order:
   files-to-copy then setup; conductor-notes §2), so `pnpm install` sees whatever the
   rules gave it.
5. `workrex_sync` after the main checkout's target changed — a relative path symlink
   keeps working as long as the target *path* exists. Two real changes need sync:
   the root got a *new* `.env*` variant (copy rules must re-run), or a root target was
   repointed (readlink differs). `workrex_sync` re-runs the exact §8 algorithm for an
   existing worktree and prints a diff of what it fixed — adds/repoints/copy-overwrites
   limited to rule-matching paths — and is idempotent.

### 3.5 PORT FAMILY

- **Lease leak on crash**: leases live in `$STATE/workrex-ports` as
  `from<TAB>project/name<TAB>session_id`. Every allocation first *revalidates*: a lease
  is dead if its session is absent (`session.list`) and/or `find_worktree_session` fails
  AND no worktree dir exists → free it. Single-user machine; lazy GC in the allocator is
  enough; no daemon.
- **Session without `WORKREX_PORT`** (user created the worktree without config/ports
  broken): the agent/node panes just don't get the port vars; dev tools read plain
  defaults; reported at open, not fatal.
- **Two projects racing for the same range**: §3.3's mkdir lock serializes
  allocation; ranges can also *overlap across `.workrex.lua` files of unrelated repos*
  → allocator falls back to scanning the max used port + config `ports.count` beyond all
  leases until 65500, so ranges self-heal instead of arguing. Default range 30000–30009
  (well above macOS ephemeral thresholds); probed once with `nc -z` per candidate port
  (each probe `timeout=2`) before claiming, to survive third-party squatters.

### 3.6 SETUP SHELL FAMILY

- **Login-shell env capture**: rejected — we don't *capture* env in the action at all.
  The setup wrapper runs **inside** the interactive login shell of the setup pane
  (`initial_input` typed line: `exec bash <scripts>/workrex-setup.sh <W>`), with cwd =
  worktree. mise/direnv key off cwd (the exact discovery Conductor wrote down,
  conductor-notes §2 shells section) — being in the real interactive shell is more
  correct than `zsh -lic` capture *and* free of the server PATH problem, because
  interactive panes get login PATH (AGENTS.md PATH gotcha applies to `rex.exec` only).
- **Interactive vs non-interactive drift**: same root fix — every place that needs the
  "dev env" reaches it through either an interactive pane (setup, gate, agent, dev pane)
  or a wrapper `exec`'d from one. The action's own `rex.exec` calls touch only git and
  the registry (PATH-stable).
- **`exit.on_completion`**: used ONLY for the dedicated throwaway pane in
  `post_create-only` configs (§2 hooks comment); default panes never auto-close so errors
  stay readable (terminal default keeps open on quick fails).

---

## 4. State layout (exact bytes)

```
<worktree>/.workrex/state          # plain key=value lines, written by actions only
  base=<branch>                    # recorded BEFORE git worktree add (workmux §1.3.11 order)
  agent=<spec>
  port=<base>                      # optional
  session_id=<id>                  # appended after session.create (§5.1)
  session_label=<project>/<name>
  rex_bin=<abs path>               # pre-resolved to spare the gate the PATH dance
  created=<iso ts>
  setup=<0|1>                      # 1 ⇒ agent window must be gated
<worktree>/.workrex/journal        # workrex-setup.sh appends:
  pid <pid>
  start <i> <cmd...>
  end <i> <code>
  ...                              # final keywords, only gate/setup-wrapper writes:
  OK        |  FAIL <code|closed|dead|timeout>|<message>
<worktree>/.workrex/env            # sourced by gate + dev panes + merge hooks
  WORKREX_WORKSPACE_PATH=<abs worktree>
  WORKREX_ROOT_PATH=<abs main root>
  WORKREX_NAME=<name>
  WORKREX_BRANCH=<wm/name>
  WORKREX_PORT=<base>
  WORKREX_SESSION_LABEL=...
```

Keys are one per line, plain `grep '^key='`-parsed from both Lua (io.lines) and sh — no
JSON needed in the hot path (jq is already a popup dependency in
`worktree_open_prompt`, but the gate runs even without jq).

---

## 5. Actions — precise algorithms

### 5.1 `worktree_add` (extended in place)

```
run(ctx, args { name, agent?, base?, setup? }):
  validate name (existing valid_name)                        [existing]
  root = require_root(ctx)                                   [existing]
  path,branch = worktree_paths(root, name)                   [existing]
  cfg   = load_config(root)                                  [new] dofile .workrex.lua w/ fallback
  base_branch = args.base or cfg.base or auto-detect          [new fallback: origin/HEAD → main]
  refuse if find_worktree_session; ensure_agent_available      [existing]
  session.create is NOT attempted yet.
  lock = mkdir_lock(STATE/workrex.lock)                      [new; 30s total]
    port = ports.allocate(root, name, cfg.ports)  (only if cfg.ports)   [§3.5]
    remember journal/state? not yet — state written AFTER worktree exists
  git worktree add -b branch path base_branch                [existing cmd; timeout 25]
  record ALSO: git config branch.<wm/name>.workrex-base base_branch    [new, tiny]
  append ".workrex/" to <root>/.git/info/exclude if absent   [new; ≤1 exec via grep+printf]
  apply_file_rules(root, path, cfg.files)                    [new; §8; never fatal — report]
  write <path>/.workrex/state (+env)                          [new]
  remember_session(path, ...) after success                  [existing]
  windows layout built by build_windows(...)                 [new] (below)
  session.create { label, initial_windows = windows }        [existing]
  cleanup on failure: undo worktree+branch exactly as today  [existing path lines 458–464]
  release lock
```

`build_windows(root, name, path, spec, cfg, created)`:

- **With setup enabled** (`cfg.setup ~= nil and #cfg.setup.commands > 0`):
  1. window "setup": interactive shell pane (flavor `context.shell`, **no** `command`)
     `initial_input = "exec bash <scripts>/workrex-setup.sh '<path>'\n"`.
     The wrapper (§6) runs `hooks.post_create` (if any) then `cfg.setup.commands`,
     journals everything, ends with OK/FAIL. REX env comes from sourcing `.workrex/env`,
     done by the wrapper.
  2. window `<agent>`: interactive shell pane with
     `initial_input = "source <scripts>/workrex-gate.sh '<path>'\n"` — see §3.1 loop; on
     OK it sources `.workrex/env` (for the pane shell, so the mutation persists for the
     interactive user later too) and execs the agent command with `login_shell -lic`
     semantics preserved by being inside the interactive shell already.
  Order in `initial_windows`: setup first, agent second.
- **No setup**: unchanged behavior — nvim window + agent pane with
  `terminal_pane(path, spec, command)` (existing helper). Plus *if* `cfg.hooks.post_create`
  is set: one extra throwaway window "post-create" running them at once
  (type `initial_input` executing them inline), `exit.on_completion = true`.

Quoting rule for the two typed lines: paths may contain no quotes in practice
(`valid_name` already forbids them in *name*; main-root paths could, so single-quote
escape `'` → `'\''` in a tiny `shquote()` helper).

### 5.2 `worktree_open` (small extension)

- Existing logic unchanged; when recreating windows after a dead session AND
  `<path>/.workrex/state` says `setup=1` AND journal lacks a final keyword → recreate
  BOTH windows as in 5.1 (resume setup with `--continue`, i.e. wrapper skips steps whose
  `end <i> 0` is already journaled) instead of a bare agent pane.
- Returns a `blocked: true` field so the caller (picker) prints "agent starts when setup
  finishes" instead of a confusing silent window.

### 5.3 `worktree_remove` (extension)

```
  guards as today + §3.2 foreign-panes check + §3.1 setup-running check
  hooks.pre_remove run here (timeout 20): run_ok({login_shell,"-lic", joined, "pre-remove", path},...)
    failure → abort remove ("pre_remove failed; run it yourself in '<path>' then retry")
  existing kill-session / remove / forget / branch -d flow unchanged
  best-effort empty-dir remove of <path>__worktrees parent (only if empty via rmdir)
```

### 5.4 `workrex_merge` (new)

```
run(ctx, args { name?|uses cwd's worktree, into?, strategy?, no_verify? (skip pre_merge hooks), keep? (skip teardown), allow_dirty? (skip uncommitted guard) ):
  root = require_root(ctx)
  src  = resolve: args.name → path+branch; else cwd's worktree via
         `git -C cwd rev-parse --show-toplevel` (must match __worktrees/ or explicit name else error)
  refuse if src session == ctx.session_id                        [guard, worktrees.lua:543 pattern]
  base = .workrex/state base || git config branch.<branch>.workrex-base || error
  target = args.into or base
  st = git -C <src> status --porcelain
  if st non-empty and not allow_dirty → error with full status (matches workmux hard error)
  find target worktree: git worktree list porcelain → the worktree whose branch is HEAD target
       (fallback: any worktree containing a branch == target; else main root)
  if target worktree's tracked status dirty (porcelain minus untracked) → error "commit or stash"
  hooks.pre_merge (source worktree, env WORKREX_* + WORKREX_MERGE_TARGET=<target>) —
       unless no_verify; failure → error (workmux parity: hooks fail hard)
  strategy = args.strategy or cfg.merge.strategy ("merge")
    rebase: create temp? NO — rebase in the SOURCE worktree:
       git -C src rebase --onto? plain: git -C src rebase <target>
       conflict → git -C src rebase --abort; error "resolve in <src>, fix, re-run merge"
    squash: git -C tgt merge --squash <branch>; on failure git -C tgt reset --hard (workmux parity);
            commit message = branch subject via `git -C src log --format=%B -n1 <branch>`
            (no interactive editor — cut auto-editor flow, §12; prints message + "amend with git commit --amend")
    merge:  git -C tgt merge <branch>; conflict → git -C tgt merge --abort; error
  branch cleanup: git branch -d <branch> (report if refused — keep branch)
  teardown = same code path as worktree_remove's tail (kill session, worktree remove, forget)
       unless args.keep; self-session and foreign-pane guards naturally apply (same fn)
  return { merged, base, into, branch_deleted, session_killed, worktree }
```

Merge runs `chdir`-free (filenames never depend on process cwd; git -C everywhere).

### 5.5 `workrex_fix` (new — the honest recovery surface)

`rex do workrex_fix name=<n> mode=state|kill|reset`:

- `state` (default): diagnose + heal: prune stale sessions (`session.list` ×
  session-map entries), rewrite gate in the (now interactive) agent block via
  `rex.block.call(terminal, "write", { block_id = ..., data = gate_line.."\n" })` if
  journal says the gate lost its sentinel but non-installer claims it should run —
  in practice: this re-types the gate — the wedge-buster;
  reset journal terminal line to `FAIL manual` so a stuck gate exits on next tick.
- `kill`: rex.kill the mapped session, forget map entry.
- `reset`: `git worktree prune` + rebuild missing `.workrex/` scaffolding (state
  resurrected from git-config base + fresh agent/port).

### 5.6 `workrex_setup` (new) — re-run/observe

`rex do workrex_setup name=<n>` → if session exists: open a NEW setup window running the
wrapper with `--continue` (skips already-OK steps, re-runs failed); if none exists,
creates the session via the same build_windows as add. Separate action so the picker
failure path stays short.

### 5.7 `workrex_sync` (new) — §3.4 file-rule re-application (CLI-only).

### 5.8 Keybindings & prompt pickers

- `ctrl+space>w` unchanged (add picker gains "config file? Y/n" line → passes `setup=`).
- `ctrl+space>shift+m` = `workrex_merge_prompt` (new popup: current-or-pick worktree,
  strategy choice merge/rebase/squash, calls `rex do -s … workrex_merge …`; same sh
  template as existing popups).
- Everything else CLI-only (`rex do …`) to keep the surface minimal; fix/setup/sync are
  referenced in failure messages. Explicitly: NO dashboard, NO archive browser, NO remote
  (deferred, §12).

---

## 6. `workrex-setup.sh` (the setup wrapper, exact semantics)

Chezmoi-target `dot_config/rex/scripts/workrex-setup.sh`. Run inside the setup pane's
interactive login shell (`exec bash …`), so PATH/mise/direnv are already correct when the
wrapper starts:

```sh
#!/bin/zsh -f            # exec'd from the pane's interactive shell: env is already correct
W="$1"; D="$W/.workrex"; J="$D/journal"
printf 'pid %s\n' "$$" >>"$J"             # gate liveness-probes this pid
emit(){ printf '%s\n' "$1" >>"$J"; }      # appends are line-atomic for our sizes
trap 'emit "FAIL 130"' INT; trap 'emit "FAIL 143"' TERM
source "$D/env"                           # WORKREX_* vars for hooks and commands
# 1) post_create hooks (baked into $D/plan as 'hook <n> <cmd...>'); failure => FAIL, stop.
# 2) setup commands (baked as 'step <n> <cmd...>'); resume mode skips steps already 'end 0'.
while read -r kind n rest <"$D/plan"; do
  [ "$kind" = step ] && [ "$n" = skipped-already-done ] && continue
  emit "start $n $rest"
  if eval "$rest" 2>&1 | tee -a "$D/setup.log"; then emit "end $n 0"
  else emit "end $n $?"; emit "FAIL $n: $rest"; exit 1; fi
done
emit OK                                   # the sentinel: last, keyword-only line
```

(The shipped script is written more defensively than this sketch — the action bakes the
plan via io.write with shquoted args and per-step done markers for resume; the sketch
shows the control flow and journal contract.)
Notes: `tee -a` gives live pane output AND durable tail; per-step `end` is the fallback
sentinel granularity the gate can report ("failed at step n: pnpm install").

---

## 7. Env injection — how vars reach each consumer (no env option in block options!)

Verified: the terminal flavor accepts `cwd / command / initial_input / login /
path_prepend` but has **no `env` schema field**. So:

| Consumer | Mechanism |
|---|---|
| Setup wrapper | `source $D/env` inside wrapper (it IS a shell) |
| Gate + agent process | gate sources env into the interactive pane shell before exec agent → the agent inherits pane env; future user keystrokes in that pane keep the env |
| nvim / extra panes | `options.command = { login_shell_path, "-lic", ". '<abs env>'; exec nvim" }` — no shell rc divergence (login shell, same as today) or, simpler for shells: `initial_input = '. env; clear'` for bare interactive panes |
| desktop dev server pane (docs pattern) | user's `.workrex.lua` gets `dev_pane = "pnpm dev --port $((WORKREX_PORT))"`? **cut** — not in scope; agents/dev servers are plain panes by convention; the port lease + env file are the only workrex piece |
| hooks (pre_merge/post_create) | wrapper/export before exec, plus WORKREX_WORKSPACE_PATH, WORKREX_ROOT_PATH, WORKREX_NAME, WORKREX_BRANCH, WORKREX_PORT, $WORKREX_PORT..+9 |

`WORKREX_PORT..+9` documented as contiguous block (`$((WORKREX_PORT+n))`), Conductor
parity (conductor-notes §4).

---

## 8. File rules algorithm (copy + relative symlink)

```
apply_file_rules(root, worktree, cfg.files):
  rules = defaults unless override:
      defaults: copy = { ".env*" }, symlink = { "CLAUDE.local.md" if gitignored }
      (workmux's auto CLAUDE.local.md symlink folded into the same rule engine)
  for each copy rule (glob, top-level only; "." handled as repo root):
    git -C root ls-files --others --ignored --exclude-standard --directory
      filter by fnmatch(rule, basename-or-relpath)
      skip tracked files (ls-files check), skip existing same-content dests (cmp -s → no-op),
      copy: single file cp -P; directory cp -Rp  (node_modules/.next/dist/target explicitly NOT
      default rules — Conductor's stated reason: regenerate cheap, stale copies poison builds)
    dest conflict (file exists, differs): overwrite ONLY IF rule came from user config
      (default .env* never overwrites a differing dest; warns) — low-risk bias
  for each symlink rule → §3.4 (relative "../../<project>/<rel>").
  log every action to worktree.log AND prefix "workrex files:" so add failures are greppable.
```

`fnmatch` in pure Lua: 12-line recursive matcher (RFC style `*`, `?`, `[...]`); no deps.

---

## 9. Where `~/.config/rex/scripts` come from

The two scripts are **chezmoi-managed**: new files
`dot_config/rex/scripts/workrex-setup.sh` and `dot_config/rex/scripts/workrex-gate.sh`
(→ `~/.config/rex/scripts/` in the target state). The actions only check executability
(basic `io.open` + first-line check) and fail with a friendly "run `chezmoi apply` and
`chmod +x`" message otherwise — no hidden self-installing scripts that drift from the
repo copy. `install.sh`/README gain one line each about the new directory.

---

## 10. Migration & back-compat

1. `worktree_add` signature grows only optional args; existing README examples
   (`rex do worktree_add name=my-feature agent=claude`) keep working.
2. Old worktrees (no `.workrex/`): `workrex_setup`/`sync` offer to scaffold
   (write state from git worktree list + git config if branch has a base; else "base
   unknown — pass base=…"). Fix/reset handles this.
3. `worktree-sessions` file: no format change.
4. No breaking rename inside existing config files; `.workrex.lua` is optional everywhere.
5. Docs: README.md's Rex table gains the new one-key bindings (`shift+m` merge picker)
   and CLI rows for `workrex_merge/setup/sync/fix` — per AGENTS.md the Lua file and the
   README table must stay in sync.

---

## 11. Verification checklist

Setup/machinery:
- [ ] `rex do worktree_add name=t1` (repo with `.workrex.lua` holding
  `setup.commands = { "false" }`): setup pane appears, journal shows `pid/start/end`,
  OK; agent pane gates then execs agent.
- [ ] Setup command failing (`["exit 7"]`): FAIL 7 agent pane prints failure and drops to
  a live prompt; `workrex_setup` resume re-runs from step 1.
- [ ] Close setup window mid-install (kill pane): gate writes FAIL closed ≤2 cycles.
- [ ] SIGKILL the wrapper (no trap): gate's `kill -0` catches → FAIL dead.
- [ ] Gate wedge recovery: manually `rm .workrex/journal`, then `workrex_fix name=t1` —
  gate re-typed, journal regenerated to FAIL manual; agent pane returns to prompt.
- [ ] 15-min forced timeout: set `setup.timeout=15` and a slow command → TIMEOUT, prompt.
Merge:
- [ ] Dirty worktree refuses; `allow_dirty=1` proceeds and keeps refs intact.
- [ ] pre_merge failing → no merge applied (`git log` unchanged); no_verify skips.
- [ ] rebase conflict → `rebase --abort` leaves branch as before; rerun works after fix.
- [ ] squash on main → `git log --oneline -1` shows branch subject; amend path clear.
- [ ] merge of worktree in CURRENT session refuses with switch-away message.
- [ ] unmerged branch kept if `git branch -d` refuses; message names branch.
State/locks:
- [ ] Rename session (C-space>$) then `worktree_open`/`workrex_merge` still resolve.
- [ ] `rm -rf` a worktree dir, session still live → `workrex_fix` diagnoses; `remove` works.
- [ ] Two concurrent `worktree_add`s against the same repo with ports — one wins, one
  exits; no torn `worktree-sessions` (diff map before/after).
- [ ] Port lease freed when the owning session is killed (next add reuses the range).
Symlinks/env:
- [ ] `node_modules` symlink resolves from `web/` nested cwd (`../../` math).
- [ ] `workrex_sync` with a new `.env.local` in root copies it; tracked files never copied.
- [ ] `.workrex/` never shows in `git status` (info/exclude took).
Shells:
- [ ] mise-activated tool identical inside the setup/gate pane vs normal pane.
- [ ] `rex do` actions still run untouched (no PATH regressions in existing flows).
Budgets:
- [ ] Every action path (incl. lock-hold) < 30 s measured (`rex do` timing on the test
  repo); long work only ever in panes/shells.

## 12. Explicit cuts (cost/benefit from the attacks or budget)

- **Deferred-detached cleanup worker** (workmux's killer feature): superseded by the
  existing self-session guard + synchronous cleanup; its machinery (setsid, device/inode
  fencing, quarantine GC, retry state) is a subsystem-scale investment for one UX edge.
- **Auto-commit staged changes on merge** (workmux) — interactive editor inside an action
  is a wedge; user must commit; documented behavior.
- **Monorepo subdir `.workrex.lua`** discovery + per-subdir working dirs — costs a config
  resolver, rel-path bugs in symlink math; can be added later without schema break
  (`files.*` already takes `src:dst` pairs that nest fine).
- **Dev-pane config (`scripts.run.*` Conductor platform)** — panes are already
  configurable via session windows; not part of the four required features.
- **Claude.local.md-style special cases beyond the CLAUDE.local.md default symlink**
  and any known-agent magic — the `agents{}` list stays user-edited Lua.
- **Sandbox / remote / dashboard / restored "archived" list** — deferred per scope.
