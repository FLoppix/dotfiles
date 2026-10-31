# Workrex — Implementation Spec (candidate 3: Rex-native minimalist, incumbent challenger)

Author stance: **extend `worktrees.lua`, invent almost nothing.** Every mechanism below is
either (a) already proven by a line-quoted fragment of the incumbent code, or (b) verified
against the live `rex` CLI with the probe quoted verbatim. One new small Lua module (config
loader + script builders); **zero new shell helper files**. Two features explicitly deferred.

---

## 0. The load-bearing verification (done first, drives the whole design)

The mandate's central question was: *is sentinel polling needed to gate the agent window, or
can the session be created with a setup window first and the agent window added after setup
completes?*

**Answer: post-hoc window creation exists. Sentinel polling is rejected.**

Probe evidence (real `rex` CLI, run read-only during design):

```
$ rex api describe session.new_window
Create a window and the blocks in its layout. It becomes the active window by default.
Input schema:
  "session_id":  { "type": "string",  "description": "The session to act on." }   ← required
  "window_label": { "type": "string", ... }
  "layout":      { "type": ["null","object"], "description": "The blocks to create in the
                  window and how to arrange them. Required. ..." }
  "focus":       { "type": ["null","boolean"], "description": "Whether to make the new
                  window the active window. Defaults to true. ..." }
```

`session_id` is an explicit parameter — so a **server-side action can create a window in any
session it can name**, including the new worktree session. The incumbent already does raw
`rex.call("session.create", ...)` (worktrees.lua:419) and raw `rex.call("session.list", {})`
(worktrees.lua:314), so `rex.call("session.new_window", { session_id = sid, ... })` uses the
same proven transport. No helper gaps: `session.new_window` is a first-class API method, and
`session.view` returns window `label` per window (verified in the schema output), which gives
a cheap dedup check.

Secondary probes that shape the design:

- `rex run --help` / `rex window new --help`: **no env-injection flag exists** for terminal
  blocks (`--split --ratio --block --session --window --cwd --keep-open --shell --label
  --focus --json --wait`). → env injection is done by wrapping the command in
  `sh -c 'export …; exec …'` (see §5.)
- `rex window new -s SESSION [LABEL] [-- COMMAND...]` exists as CLI fallback, but the API
  call avoids the `rex_bin()` CLI resolution path, so it's the primary.
- `rex.events` / `rex.wait` exist but are **not needed**: the completion signal is a
  self-report from the setup pane (`rex do … workrex_setup_done ...`), not an event
  subscription. Terminal blocks get the user's login-shell PATH (AGENTS.md "Server-side PATH
  gotcha" line), so `rex` resolves inside the pane.

### The 30-second cliff, mapped exactly

Where clamping actually bites, per step of the flow:

| Step | In action (≤30 s)? | Why |
|---|---|---|
| worktree create (`git worktree add`) | yes — incumbent already budgets `{ timeout = 25 }` (worktrees.lua:456) | proven |
| file copy / `.env*` takeover / relative symlinks | **yes** — cp/ln over a handful of files is ms-scale; one `sh -c` fragment | no new machinery |
| base-branch git-config write | yes — single `git config` ms-scale | |
| **`pnpm install` etc.** | **no — runs in the setup pane**, never in the action | this is the cliff the incumbent warned about at worktrees.lua:16–17 ("long setup work belongs in a window, not in the action") |
| agent window creation (`session.new_window`) | yes — one API call | |
| merge itself (`git merge`) | yes — needs ≤25 s timeout; a pathological huge merge can exceed it but so could any action; documented | |
| pre_merge / pre_remove hooks | yes but *capped in practice*: run through login shell with `timeout = 25` | hooks must be short; long checks don't belong here (documented) |
| teardown (`rex kill`, worktree remove) | yes — proven by worktree_remove today (worktrees.lua:547–560) | |

No setup path needs a *second* pane: the setup pane is created with the session itself, so
it needs no creation machinery at all.

---

## 1. File changes (exactly two source files + two doc files)

```
dot_config/rex/workconfig.lua   NEW   ~150 lines: .workrex.lua loading + shell-script builders
dot_config/rex/worktrees.lua    EDIT  extended in place (actions + 2 new actions + 1 new binding)
init.lua                        EDIT  1 line: no change needed unless we split modules (we don't)
AGENTS.md                       EDIT  Rex section: new actions, keys, config, state
README.md                       EDIT  keymap table sync (repo convention)
```

`workconfig.lua` is a *library*, loaded with `require("workconfig")` at the top of
`worktrees.lua` (same pattern as `require("context")` at worktrees.lua:19). Nothing changes in
`init.lua` — it already `require("worktrees")` (init.lua:204).

Deliberate choice: **no new `.sh` files.** The incumbent already generates inline `sh -c`
scripts as Lua string tables (worktrees.lua:594–610, 630–664, 684–700) and passes arguments as
positional `$1…$n` (`context.popup` at context.lua:74–91). File-ops and setup scripts are built
the same way — as Lua string constants emitted at call time. Nothing to install, nothing to
resolve on the server's minimal PATH.

---

## 2. Per-repo committed config: `.workrex.lua` (Conductor-style)

Loaded from the **main checkout root only** (no monorepo subdir discovery, no global config —
both deferred, see §12).

### Schema (Lua, smallest that covers the task)

```lua
-- <repo>/.workrex.lua  — committed, reviewable like code (Conductor's "config is project config")
return {
  base = nil,                 -- default base branch for worktree_add, e.g. "origin/main"; nil = HEAD
  files = nil,                -- nil  → default { copy = { ".env*" } }   (Conductor's default pattern, conductor-notes §5)
                              -- table → CONDUCTOR SEMANTICS: overrides the default entirely
                              --        (add ".env*" yourself if you still want it)
  files = {                   -- (illustrative)
    copy    = { ".env*", "certs/dev.pem" },   -- top-level glob patterns, relative to repo root
    symlink = { ".claude" },                  -- symlinked RELATIVELY (workmux/conductor behavior)
  },
  setup = nil,                -- nil or {} → no setup; session opens directly with nvim+agent (incumbent behavior)
  setup = {                   -- list of commands run sequentially in the worktree, &&-chained,
    "pnpm install",           -- first failure = setup failure
  },
  pre_merge  = { "pnpm typecheck" },  -- nil → none. Runs in the SOURCE worktree before the merge.
  pre_remove = { "./script/workspace-archive.sh" },  -- nil → none. Runs in the worktree before removal.
}
```

Semantics pinned down:

- **`files` present ⇒ default `.env*` is OFF** (exact Conductor rule: "If you add your own
  patterns you must re-add `.env*` yourself" — conductor-notes.md:167). `files = {}` disables
  copying. `files` key absent → `{ copy = { ".env*" } }`.
- Copy rule condition: source exists AND `git check-ignore -q -- <src>` succeeds at the main
  root AND target does not already exist. → This is the "default gitignored `.env*` takeover"
  (Conductor: only gitignored files, never tracked files — conductor-notes.md:165–168).
- Symlink rule: `ln -sfn <relative-path> <worktree>/<name>`; relative path computed in pure
  Lua (no dependency on macOS `realpath --relative-to`, which is not guaranteed on all
  macOS versions).
- Copy pattern constraint: **top-level patterns only** (no `/` in pattern). A pattern with
  `/` produces a config-load error (fail loudly rather than silently ignoring).
- Config file is executed as Lua with a **typed, sandboxed environment** — it's a data
  module, the user commits and reviews it (same trust model as any repo dotfile). If it
  throws, the error is surfaced with file context; creation aborts before any side effect.

### Loader (`workconfig.lua`)

```lua
local function load_config(root)
    local handle = io.open(root .. "/.workrex.lua", "r")
    if handle == nil then return nil end            -- no file → incumbent behavior everywhere
    local text = handle:read("*a")
    handle:close()

    local chunk = load(text, "@.workrex.lua", "t", {
        string = string, table = table, math = math,
        pairs = pairs, ipairs = ipairs, tostring = tostring, tonumber = tonumber,
    })
    if chunk == nil then
        error("workrex: .workrex.lua does not parse", 0)
    end
    local ok, cfg = pcall(chunk)
    if not ok then error("workrex: .workrex.lua error: " .. tostring(cfg), 0) end
    if type(cfg) ~= "table" then error("workrex: .workrex.lua must return a table", 0) end

    -- validation (exact, fail-closed)
    if cfg.files ~= nil then
        assert(type(cfg.files) == "table")
        for _, key in ipairs({ "copy", "symlink" }) do
            for _, pattern in ipairs(cfg.files[key] or {}) do
                assert(type(pattern) == "string")
                assert(not pattern:find("/", 1, true),
                    "workrex: files." .. key .. " pattern has '/': only top-level patterns are supported")
            end
        end
    end
    for _, key in ipairs({ "setup", "pre_merge", "pre_remove" }) do
        if cfg[key] ~= nil then
            assert(type(cfg[key]) == "table")
            for _, cmd in ipairs(cfg[key]) do
                assert(type(cmd) == "string", "workrex: " .. key .. " entries must be strings")
            end
        end
    end
    if cfg.base ~= nil and type(cfg.base) ~= "string" then
        error("workrex: base must be a string", 0)
    end
    return cfg
end

-- Effective helpers:
local function copy_rules(cfg)      -- returns the rules to apply
    if cfg == nil or cfg.files == nil then return { ".env*" } end    -- Conductor default
    return cfg.files.copy or {}
end
local function symlink_rules(cfg)
    if cfg == nil or cfg.files == nil then return {} end
    return cfg.files.symlink or {}
end
local function has_setup(cfg) return cfg ~= nil and cfg.setup ~= nil and #cfg.setup > 0 end
```

---

## 3. State layout — reuse, don't invent

Justification for every location kept or moved:

| Item | Location | Verdict | Why |
|---|---|---|---|
| worktree → session id | `~/.local/state/rex/worktree-sessions` (worktrees.lua:35, 331–401) | **KEEP as-is** | already survives session rename; every action resolves through `find_worktree_session` |
| last agent | `~/.local/state/rex/worktree-agent` (worktrees.lua:33) | **KEEP as-is** | picker ordering only |
| action/picker failure log | `~/.local/state/rex/worktree.log` (worktrees.lua:34) | **KEEP** | pickers keep errors on screen until Enter (AGENTS.md) |
| ✚ base branch | **`git config --local branch.<branch>.workrex-base`** | **git config, NOT a state file** | workmux precedent ("Store review base BEFORE checkout … `branch.<branch>.workmux-base`", workmux-core-notes §1.3/§4); lives and dies with the repo; survives session rename; readable from any process. Written at creation, consulted by merge. Deleted by the same rollback that deletes the branch. |
| ✚ setup gate marker | **`<worktree>/.workrex/setup.done`** (file exists ⇒ setup reported ok) | **state inside the worktree** | the worktree is the natural scope; `git worktree remove` deletes it for free (no GC). Worktrees ignore `.workrex/` via one line appended to `.git/info/exclude` (workmux does exactly this for `.workmux/` — workmux-core-notes §1.3 step 16). No new JSON, no schema. |
| ✚ ports | **none — deterministic hash** | pure function of the worktree path | allocation state leaks on crash and needs GC; hash collides only in the same 2000-bucket space and self-heals by user override. See §6. |

Rejected state ideas: a port-allocation ledger (`worktree-ports`, crash-leaky), a bases file
(`worktree-bases`, redundant next to `worktree-sessions` and per-repo git config is strictly
better), per-worktree JSON (`setup.json`, over-spec'd for one boolean).

One-shot exclude append at creation (idempotence via grep):

```lua
local function ensure_gitignore_marker(root)
    local probe = rex.exec({ "git", "-C", root, "check-ignore", "-q", ".workrex/x" })
    -- (skip when already excluded)
    -- else: append ".workrex/" to root/.git/info/exclude via sh fragment
end
```

---

## 4. Actions: final surface

Existing (kept byte-compatible for the no-config repo): `worktree_add`, `worktree_open`,
`worktree_remove`, `worktree_{add,open,remove}_prompt`.

New / changed:

| Action | Args | Purpose |
|---|---|---|
| `worktree_add` (changed) | `name, agent?, base?` | unchanged CLI; internally: config load → base record → file ops → session-create **with setup window only when setup exists** |
| `worktree_open` (changed) | `name, agent?` | unchanged CLI; if setup was configured and no ok-marker → opens **setup-pending session** instead of nvim+agent |
| `worktree_remove` (changed) | `name, force?` | unchanged CLI; inserts pre_remove hooks + pre-flight uncommitted check before the kill |
| **`workrex_setup_done`** (new, internal) | `name, path, ok, agent` | the completion callback; adds agent (+nvim) windows to the running worktree session |
| **`workrex_setup_retry`** (new) | `name` | opens a fresh setup window in the 当前 worktree session (also re-opens a lost agent window when setup already ok) |
| **`worktree_merge`** (new) | `name, into?, strategy?, ignore_uncommitted?, keep?` | merge + guards + hooks + optional teardown |
| **`worktree_merge_prompt`** (new) | — | fzf picker for merge (worktree → strategy) |

Actions the user never types: `workrex_setup_done` (invoked by the setup pane's script).

Keybinding plan (mirrors existing `ctrl+space>w / o / shift+w` pattern at worktrees.lua:711–713):

```
ctrl+space>m   → worktree_merge_prompt
ctrl+space>s   → workrex_setup_retry        (only meaningful inside a worktree session)
```

---

## 5. The setup pipeline (the core change)

### 5.1 `worktree_add` — new algorithm with failure paths

The incumbent rollback fragment is reused verbatim (worktrees.lua:458–464):

```lua
        local ok, label_or_err, created = pcall(create_session, root, args.name, path, spec)
        if not ok then
            -- Undo the fresh worktree so a failed session leaves nothing behind.
            rex.exec({ "git", "-C", root, "worktree", "remove", "--force", path }, { timeout = 20 })
            rex.exec({ "git", "-C", root, "branch", "-D", branch }, { timeout = 10 })
            error(label_or_err, 0)
        end
```

Steps with rollout on each:

1. `valid_name`, `require_root`, `worktree_paths`, `session_label` — unchanged (worktrees.lua:88, 130–162, 73–85).
2. `local cfg = load_config(root)` — if it throws: abort **before any side effect** (nothing to roll back).
3. `ensure_agent_available(spec)` — unchanged (worktrees.lua:284–303).
4. Duplicate check via `find_worktree_session` — unchanged (worktrees.lua:448–450).
5. **Base branch record** (workmux §1.3 step 11 semantics):
   ```lua
   local base = args.base or (cfg and cfg.base) or "HEAD"
   local resolved = base == "HEAD" and "HEAD" or base   -- keep the ref as typed; resolve HEAD later
   run_ok({ "git", "-C", root, "config", "--local", "branch." .. branch .. ".workrex-base", base })
   ```
   HEAD is stored as the literal branch name: if base is nil/"HEAD", first run
   `git -C root rev-parse --abbrev-ref HEAD` (≤10 ms) and store *that*, so `worktree_merge`
   gets an unambiguous local branch even if HEAD moved on.
6. `git worktree add` — unchanged (worktrees.lua:454–456).
7. `ensure_gitignore_marker(root)` (§3) — best-effort, non-fatal.
8. **File ops** — one `sh -c` fragment, in-action (ms-scale), values passed as positionals:
   ```sh
   cd "$2" || exit 1                                   # $2 = main root
   mkdir -p "$3" || exit 1                              # $3 = worktree path
   copy: for each pattern P (Lua-unrolled, sh-quoted):
     for f in P; do                                     # unquoted expansion does the globbing, sh builds the loop
       [ -f "$f" ] || [ -d "$f" ] || continue
       git check-ignore -q -- "$f" || continue          # Conductor: only gitignored files
       cp -R -- "$f" "$3/$f"                            # directory copies recurse
     done
   symlink: same loop, then Lua-computed relative target:
     ln -sfn "<rel>" "$3/$f"                            # relative, workmux-style (difference-of-paths)
   ```
   Any cp/ln failure ⇒ script exits nonzero ⇒ **rollback** (step 11's fragment) + error.
   Pattern-mismatch (no matches) is **not** an error (glob expands to the literal pattern;
   the `-f` guard skips it silently).
9. **Session creation, gated shape:**
   ```lua
   if has_setup(cfg) then
       -- ONE window only: the setup pane. The agent and nvim windows arrive via workrex_setup_done.
       created = rex.call("session.create", { label = label, initial_windows = {
           { window_label = "setup", layout = setup_pane(path, root, args.name, branch, port, sid?, spec) },
       }})
   else
       created = create_session(root, args.name, path, spec)   -- incumbent, byte-identical path
   end
   ```
   `session.create` failure ⇒ rollback (existing fragment) **plus**
   `git config --local --unset-all branch.<branch>.workrex-base` (the piece workmux's
   headless rollback also undoes).
10. `write_last_agent(spec)` + `remember_session(path, created.session_id)` — unchanged.
11. Return result table — unchanged shape, plus `setup = has_setup(cfg)` for callers/CLI.

### 5.2 The setup pane script (single generated fragment, no helper file)

Built in `workconfig.lua` as `build_setup_script(cfg, ...)`. The pane is created by
`rex.layout.block { flavor = context.shell, label = "setup", options = { cwd = path,
command = { "sh", "-c", script, "workrex-setup", "<path>", "<root>", "<name>", "<branch>",
"<spec>", "<sid>" } } }` — the same invocation shape the pickers already use
(worktrees.lua:614). Positions:

```sh
cd "$1" || exit 1
export WORKREX_WORKTREE_PATH="$1" WORKREX_PROJECT_ROOT="$2" WORKREX_NAME="$3" \
       WORKREX_BRANCH="$4" WORKREX_PORT="<N>"
printf '\nworkrex: setting up %s (%s)\n' "$3" "$4"
while true; do
  if sh -c '<command 1> && <command 2> && ...'; then                 -- &&-chained, first failure fails setup
    printf '\nworkrex: setup ok\n'
    rex do -s "$6" workrex_setup_done name="$3" path="$1" ok=true agent="$5"
    exec "$SHELL" -l                                                -- pane always ends as a live shell
  fi
  printf '\nworkrex: setup FAILED (see above).\nPress Enter to retry, Ctrl-D to abandon: '
  read -r _ || exit 1                                               -- Ctrl-D kills the pane; nothing was half-open
done
```

Properties (each is a hard requirement from the task):

- **Outlives the 30 s action budget** — it is *in a pane*, the incumbent's own guidance
  (worktrees.lua:16–17). pnpm/Gemini de-AGENTS-style long installs just run there.
- **Output visible** — it *is* the pane; the user can switch to the session at any point
  (`ctrl+space>]`) and watch. No hidden logs.
- **Failure surfaced** — the pane holds the failure with a prompt, and `worktree_open` on a
  later pass treats a worktree without `setup.done` as setup-pending, so it can be retried.
- **Rerunnable** — in-pane loop retry (Enter), or `ctrl+space>s` for a fresh pane later.
- Self-report runs `rex do` from *within the new worktree session's* pane, so even the plain
  `-s $6` scoping targets the same session — but `workrex_setup_done` receives `path` as an
  argument and resolves session id from `find_worktree_session` (worktrees.lua:381–401), so
  the callback does not depend on shell-scoping subtleties.
- Each command printed with a `+ <cmd>` line so delay vs. failure is distinguishable.
- `WORKREX_PORT` is exported for both the setup commands AND the final interactive shell.

### 5.3 `workrex_setup_done` (the gate-release action)

Runs inside the worktree session (invoked from the pane with `-s <sid>`). Algorithm:

1. Resolve `root = repo_root(args.path)` and `path, branch = worktree_paths(root, args.name)`.
2. Guard: `find_worktree_session(path, label)` must exist and match the CLI session (pass
   `session_id` explicitly) — if stale, error "session vanished; re-run worktree_open".
3. Guard idempotency: if `session.view { session_id = sid }` already has a window labeled
   with the agent spec name (verified `session.view` exposes window `label`) → return
   `{ already = true }` (e.g. after a double-report).
4. Build the agent command — `agent_command(args.agent)` reuses the incumbent agent
   machinery (worktrees.lua:104–115). Inject env via the sh wrapper (no env flag exists in
   block creation — verified):
   ```lua
   local shq = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
   local exports = "export WORKREX_WORKTREE_PATH=" .. shq(path) ..
       " WORKREX_PROJECT_ROOT=" .. shq(root) ..
       " WORKREX_NAME=" .. shq(args.name) ..
       " WORKREX_BRANCH=" .. shq(branch) ..
       " WORKREX_PORT=" .. tostring(port)
   local command = { "sh", "-c", exports .. "; exec " .. table.concat(map(shq, command), " "),
                     "workrex-agent", path }
   -- (worktrees.lua's terminal_pane at line 117–128 does the block wrapping)
   ```
5. Two windows, in order that leaves the agent **not** stealing focus from the editor:
   - `rex.call("session.new_window", { session_id = sid, window_label = "nvim",
     focus = false, layout = terminal_pane(path, "nvim", editor) })` — `editor = { "nvim" }`
     from worktrees.lua:30.
   - `rex.call("session.new_window", { session_id = sid, window_label = spec, focus = true,
     layout = terminal_pane(path, spec, command) })`.
6. Write the ok-marker: `io.open(path .. "/.workrex/setup.done", "w")` (content "ok"). **Last
   step**, so an action failure never leaves a marker claiming a setup that didn't finish.
7. Return `{ agent_window = spec, nvim_window = "nvim", port = port }`.

Failure semantics: if step 5 errors, no marker is written, so `worktree_open` would later
open a setup-pending session again — and the user can re-key `ctrl+space>s` right in the pane.

### 5.4 `worktree_open` — only change is a decision before `create_session`

```lua
local cfg = load_config(root)
local setup_pending = has_setup(cfg)
    and io.open(path .. "/.workrex/setup.done", "r") == nil     -- no ok-marker
if setup_pending then
    -- open Session with ONLY the setup window (init re-runs idempotently if partially done)
    created = rex.call("session.create", { label = label, initial_windows = {
        { window_label = "setup", layout = setup_pane(...) } } })
else
    created = create_session(root, args.name, path, spec)   -- incumbent, untouched
end
```

`ensure_agent_available(spec)` is hoisted above both branches (already the first thing
`worktree_open` does — worktrees.lua:507–508).

### 5.5 `workrex_setup_retry` (normalized key: `workrex_setup_retry`)

Only meaningful when invoked from inside the worktree session:

1. `root = require_root(ctx, ...)` (this is exactly the fallback the incumbent already handles
   for "a tab can be left open on a directory that is gone", worktrees.lua:147–158 — same idea).
2. `path, branch = worktree_paths(root, current name from ctx cwd basename)`.
3. If agent config has changed since add, re-`agent_command` from ctx's requested agent name
   or the last-agent state (`read_last_agent`, worktrees.lua:212–223).
   Also: if `path .. "/.workrex/setup.done"` already exists and the agent window is missing
   from the view, skip the setup pane entirely and go straight to the window-adding part of
   §5.3 (open agent + nvim windows directly) — this doubles as agent-window recovery.
   Additionally, remove any stale agent window before re-creating one (only two known labels
   to close: "nvim" and the agent-spec label), and re-create the setup pane with a fresh
   `session.new_window` on `ctx.session_id`. Because the new setup window replaces the old
   one rather than re-entering it, the action's `ctx` never couples to a pane about to die;
   any prior pane exits when its in-pane Ctrl-D is exercised or can be closed by hand.
4. Removes any stale agent window for the worktree session (only two known labels to close:
   "nvim", agent-spec label) and re-creates the setup pane via `session.new_window` on
   `ctx.session_id`.
5. If reached from within the worktree's own setup pane: because we re-create a new setup
   window rather than re-entering the old one, there's no coupling between the action's
   `ctx` and the original pane; the old pane either exits when re-tagged as "old" or is
   closed automatically if the session view shows exactly one setup-pending pane.

---

## 6. Env injection + port block

Five variables, matching Conductor's env-var skyline (conductor-notes.md:148–152) minus the
cloud-only ones:

```
WORKREX_WORKTREE_PATH   absolute worktree path
WORKREX_PROJECT_ROOT    main checked-out root
WORKREX_NAME            session label (injected as $WORKREX_NAME, not the raw path)
WORKREX_BRANCH          wm/<name>
WORKREX_PORT            base of a 10-port block; scripts use $((WORKREX_PORT + n))
```

Since terminal blocks accept no env option (verified), all five are exported by the
`sh -c 'export …; exec …'` wrapper (§5.3) or by plain script-text exports (§5.2).

Port computation — deterministic, stateless, collision-safe-enough:

```lua
local function fnv1a(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = (hash * 16777619 + text:byte(i)) % 4294967296
    end
    return hash
end
local function worktree_port(path)
    return 40000 + (fnv1a(path) % 900) * 10      -- 40000 … 48990, blocks of 10
end
```

Rejected: an allocation-count file. Reason: crash-orphaned reservations leak, and an FNV
hash over a path is stable, spread well (900 buckets), and lands under 49152 so it never
collides with macOS's ephemeral port range. Deferred: any collision-sensing allocator (§12).

---

## 7. `worktree_merge` — full algorithm with failure paths

`strategy` ∈ `{"merge","squash","rebase"}`, default `merge` (same default as workmux —
workmux-core-notes §2 step 11).

Steps:

1. `valid_name`, `require_root`, `worktree_paths` — incumbent helpers.
2. **Target resolution** (mirrors workmux §2 step 5, precedence arg > recorded base > fail):
   ```lua
   local target = args.into
       or git_get(root, "branch." .. branch .. ".workrex-base")          -- §3's recorded base
   if target == nil then error("worktree_merge: pass into=X (no recorded base for " .. branch .. ")") end
   if target == "HEAD" then error("worktree_merge: base was recorded as HEAD, pass into=X") end
   -- normalize origin/foo → foo when foo exists locally
   local short = target:match("^origin/(.+)$")
   if short and run_ok({ "git","-C",root,"rev-parse","--verify","--quiet","refs/heads/"..short }).ok
           ~= false then target = short end
   ```
3. **Guards (all explicit errors, nothing destructive has happened yet):**
   - `path ~= root` — "cannot merge the main worktree into itself" (workmux §2 step 3).
   - `branch ~= target` — "cannot merge a branch into itself".
   - `git -C root rev-parse --verify --quiet refs/heads/<target>` — target must exist.
   - **Source uncommitted guard:** `git -C <path> status --porcelain` non-empty → error
     "commit or stash first (or ignore_uncommitted=true)". (Deviation from workmux: staged
     changes are *not* auto-committed because committing needs `$GIT_EDITOR`; noted in §12.)
   - skip the two above when `args.ignore_uncommitted`.
   - **Target-worktree guard:** if `target` is checked out somewhere other than `root`, the
     *other* worktree's dirtiness errors the merge unless `ignore_uncommitted` — same
     `status --porcelain` probe at the target worktree.
   - **Where to merge:** `git -C root rev-parse --abbrev-ref HEAD == target` → merge at
     `root`; else, if `git worktree list` shows some path with `branch <target>` → merge
     there; else error "target branch is not checked out anywhere; open a session for it
     (`worktree_open` on the main worktree) and try again".
4. **pre_merge hooks** (skip entirely if `args.no_verify`): `for _, hook in ipairs(cfg.pre_merge or {}) do
   run_ok({ login_shell(), "-lic", hook, "workrex-hook" }, { timeout = 25 })` — cwd is the
   **source** worktree (workmux parity: "pre_merge hooks run in the SOURCE worktree dir" —
   workmux-core-notes §2 step 10), env injected via `env(1)` argv prefix (no shell quoting
   hazards): `{ "env", "WORKREX_WORKTREE_PATH="..path, "WORKREX_PROJECT_ROOT="..root,
   "WORKREX_NAME="..name, "WORKREX_BRANCH="..branch, "WORKREX_PORT="..tostring(port),
   unpack(login_shell()) , "-lic", hook }`.
   Hook failure → hard error, nothing was merged.
5. **Strategy** (all with `{ timeout = 25 }`, all conflict paths use explicit abort + error):
   - `merge`:
     ```lua
     local ok = pcall(run_ok, { "git", "-C", tgt_wt, "merge", "--no-edit", branch })
     if not ok then
         run_ok({ "git", "-C", tgt_wt, "merge", "--abort" })   -- matches workmux §2 step 11
         error("worktree_merge: conflicts; resolve them in " .. tgt_wt .. " with 'git -C "
             .. tgt_wt .. " merge " .. branch .. "', or re-run worktree_merge", 0)
     end
     ```
   - `squash`:
     ```lua
     if not pcall(run_ok, ..., "merge", "--squash", branch) then
         run_ok({ "git", "-C", tgt_wt, "reset", "--hard" })   -- workmux §2 step 11 (squash arm)
         error("worktree_merge: squash conflict; aborting")   -- --abort doesn't suffice; reset --hard does
     end
     run_ok({ "git", "-C", tgt_wt, "commit", "-m", "Merge branch '" .. branch .. "' (squash)" })
     -- deviation from workmux: workmux opens $GIT_EDITOR here; actions can't, so the message
     -- is fixed; users who care run the squash by hand. (documented, not hidden)
     ```
   - `rebase`: in the **source worktree** (workmux §2 step 11 rebase arm):
     ```lua
     if not pcall(run_ok, { "git", "-C", path, "rebase", target }) then
         run_ok({ "git", "-C", path, "rebase", "--abort" })
         error("worktree_merge: rebase conflict; rebase manually in " .. path .. " and retry", 0)
     end
     run_ok({ "git", "-C", tgt_wt, "merge", "--no-edit", branch })   -- ff expected after rebase
     ```
6. **Branch delete** — incumbent pattern, reused verbatim (worktrees.lua:565):
   ```lua
   local branch_result = run({ "git", "-C", root, "branch", "-d", branch }, { timeout = 10 })
   ```
   After `squash`, git doesn't consider the branch merged, so fall back to `-D` only if
   `strategy == "squash"` (workmux uses force deletion too since it's provably merged).
7. **Teardown** unless `args.keep` — reuses the exact incumbent teardown machinery:
   ```lua
   -- worktree_remove's lines 547–553 and 555–560 refactored into a shared
   -- local function teardown(root, path, branch, name, ctx, opts) used by both actions:
   --   a) self-kill guard: existing.session_id == ctx.session_id → do NOT kill; skip teardown
   --      and return { teardown_skipped = "you are inside the merged session — close it with "
   --      .. "rex kill or the worktree_remove picker after switching" }
   --   b) pre_remove hooks run BEFORE kill (so they can serve files that still exist)
   --   c) run_ok({ rex_bin(), "kill", existing.session_id })         ← proven path
   --   d) run_ok({ "git","-C",root,"worktree","remove", ...(force?), path })   ← proven pattern
   --   e) forget_session(path)
   --   f) branch already deleted in step 6, so pass delete_branch=false here
   ```
8. Return `{ branch_merged = target, strategy = ..., teardown = ... or "skipped" }`.

### Self-kill edge, and why it's answered with the *incumbent's* answer

The incumbent already has this exact situation and answers it with a guard, not a deferred
worker (worktrees.lua:543–545):

```lua
        local existing = find_worktree_session(path, label)
        if existing ~= nil and existing.session_id == ctx.session_id then
            error("worktree_remove: this worktree is open in the current session; switch sessions first", 0)
        end
```

Candidate-3's choice: `worktree_merge` never kills the session the user is sitting in
(it skips teardown and says so). Rationale: spawning a detached `rex kill` child from inside
the dying session is *unverified* — we don't know whether the server reaps children of a
killed session's terminal, and workmux's whole reason for building `_deferred-cleanup` +
`setsid` + identity fencing (workmux-core-notes §2.1 step 6) is that this race is real and
nasty. The guard route is deterministic, needs zero new machinery, and matches the UX users
already have for remove. **Trigger to revisit**: if "merge from within the worktree session"
turns out to be the common pattern, add a `workrex DeferredCleanup` later — explicitly
deferred (§12).

`worktree_remove` gains two additive guards before its kill path (its own order — kill then
remove — is preserved):

```lua
-- pre_remove hooks (abort on failure, like workmux)
for _, hook in ipairs((load_config(root) or {}).pre_remove or {}) do
    run_ok(env_wrapped_hook(hook, ...), { timeout = 25 })   -- runs with cwd = worktree path
end
-- pre-flight uncommitted check so we never kill a session over a failing git remove
if not args.force and nonempty(execute-rex.exec git -C path status --porcelain) then
    error("worktree_remove: uncommitted changes in " .. path .. " (use force=true)", 0)
end
```

Hook failure → the whole remove aborts *before* any irreversible step, so there's nothing to
roll back.

---

## 8. The pickers (smallest additions)

`worktree_merge_prompt` — mirrors the structure of `worktree_remove_prompt` exactly:
`(worktrees.lua:684–700)`. Worktree → strategy (fzf pick) → optional
`into=` (free prompt only when no base recorded).

`worktree_add_prompt` / `worktree_open_prompt`: no change.

### CLI surface additions

```
rex do worktree_add name=X agent=pi [base=origin/main]
rex do worktree_open name=X [agent=pi]
rex do worktree_remove name=X [force=true]
rex do worktree_merge name=X [into=Y] [strategy=squash|rebase|merge] [ignore_uncommitted=true] [keep=true]
rex do workrex_setup_done name=X path=P ok=true agent=pi      (internal; setup pane calls this)
rex do workrex_setup_retry                                    (in-session)
```

`workrex_setup_done` is deliberately named with the module prefix (no underscore) so it's
listable and callable but visually distinct from user-facing `worktree_*` actions.

---

## 9. Migration from the current `worktrees.lua`

Mechanics ordered:

1. `cd ~/code/dotfiles && $EDITOR dot_config/rex/workconfig.lua` (new), then edit
   `dot_config/rex/worktrees.lua` minimally:
   - top: `local workconfig = require("workconfig")`
   - `worktree_add`: insert steps 2/5/7/8 and the gated `session.create` shape (§5.1);
     `create_session` stays untouched as the "no setup" branch.
   - `worktree_open`: insert step 5.4's decision above line 510's existing `create_session`.
   - `worktree_remove`: insert §7's two guards between the `find_worktree_session` block
     (line 542) and the kill (line 547).
   - new actions `workrex_setup_done`, `workrex_setup_retry`, `worktree_merge`,
     `worktree_merge_prompt` appended before the existing `rex.bind` lines.
   - new binds (`m`, `s`) appended next to the existing three.
2. `chezmoi apply ~/.config/rex` (AGENTS.md rules).
3. `rex config check` then `rex config reload` (Rex does not watch files — AGENTS.md).
4. `rex actions | grep work` shows the 10 worktree/workrex actions; `rex keymap | grep space` shows 5 bindings (711–713 + `m` + `s`).

Zero state migration: `worktree-sessions`, `worktree-agent`, `worktree.log` keep their exact
format. Existing sessions keep running; a pre-existing worktree opened after the upgrade and
found to have no `.workrex.lua` behaves exactly as today (§5.4's `has_setup(cfg)` is false).
The only "new" file the old code ever left behind is also the new marker's parent dir already
existing (`.workrex/` is created lazily by `ensure_gitignore_marker` and the setup script's
first `mkdir -p`).

---

## 10. Verification checklist (each item maps to a concrete run)

Setup / infra:
- [ ] `rex config check` clean after both edits.
- [ ] `rex actions | grep work` lists `worktree_add/open/remove`, all three prompts, `workrex_setup_done`, `workrex_setup_retry`, `worktree_merge`, `worktree_merge_prompt`.
- [ ] `rex keymap` shows `ctrl+space>m` → `worktree_merge_prompt` and `ctrl+space>s` → `workrex_setup_retry`; old `w / o / shift+w` unchanged.

Per-repo config:
- [ ] Repo without `.workrex.lua`: `rex do worktree_add name=t1 agent=pi` behaves byte-identically to today; `.env` (if gitignored) lands in the worktree; session opens with `nvim` + `pi` immediately.
- [ ] `.workrex.lua` with `setup = { "true" }`: session opens with a single `setup` window; completes in <1 s and the agent + nvim windows appear; `cat <path>/.workrex/setup.done` says ok.
- [ ] `.workrex.lua` with `setup = { "false" }`: pane shows the failure; Enter re-runs; Ctrl-D closes the pane; `rex do worktree_open name=…` from another session re-enters setup (marker absent).
- [ ] `.workrex.lua` with `files.copy = { "does-not-exist*" }`: no error (glob misses silently).
- [ ] `.workrex.lua` with `files.symlink = { "node_modules" }` where `node_modules` exists in root: relative symlink appears in the worktree; `readlink` resolves.
- [ ] `.workrex.lua` with a `files.copy` pattern containing `/`: **worktree_add errors** (fail-closed), nothing created.

Setup life-cycle:
- [ ] `pnpm install`-scale setup (minute-scale): action returns in <5 s even while the pane is still installing; the session has only the `setup` window during that time; after `setup done`, agent + nvim windows appear, agent focused.
- [ ] During setup, `rex do worktree_open name=<same>` returns the live session (guard at worktrees.lua:497–501 still works — idempotent).
- [ ] `workrex_setup_done` double-invocation returns `{ already = true }` (no third window).
- [ ] Killing the setup pane (Ctrl-D) leaves the worktree/session consistent; `workrex_setup_retry` from the (shell) pane re-opens setup.

Merge:
- [ ] `rex do worktree_merge name=t1` with a recorded base merges, deletes the branch, tears down the session (from a different session).
- [ ] Same action run **from inside** t1's own session: merges fine, prints "teardown skipped — you're inside this session" and returns; `rex kill` from another session then finishes the job manually (documented two-step).
- [ ] `strategy=squash` produces a single squashed commit; `strategy=rebase` rebases t1's branch then ff-merges.
- [ ] Uncommitted guard: dirty worktree blocks merge; `ignore_uncommitted=true` bypasses.
- [ ] `pre_merge = { "false" }` blocks merge, nothing merged.
- [ ] `keep=true` merges and keeps the worktree + session.
- [ ] `git config --local branch.wm/t1.workrex-base` exists after add; *unchanged* after merge; deleted after remove (rollback fragment).

Remove:
- [ ] `pre_remove` hook failure leaves the worktree, branch, session all intact (guard fires before the kill).
- [ ] Dirty worktree without `force=true` blocks remove (new guard).

Ports:
- [ ] Two concurrent trees get distinct `WORKREX_PORT` (different hashes); `subshell` in the agent pane sees `$WORKREX_PORT`.

No-op regressions:
- [ ] The three old prompt pickers still write to `~/.local/state/rex/worktree.log` on failure and keep the error on screen.
- [ ] `worktree_open` on a worktree created before the upgrade (no marker) still opens normally.

---

## 11. Explicit non-goals of the incumbent that this spec deliberately does NOT copy

| workmux / Conductor feature | Verdict |
|---|---|
| `$GIT_EDITOR` squash message / auto-commit of staged changes | rejected — impossible from a short server-side action without a PTY; guarded instead |
| Monorepo subdir config discovery (`backend/.workmux.yaml`) | deferred (§12) — warranted only when the user actually has a monorepo |
| `"<global>"` list splice + global config file | deferred (§12) — one repo at a time today |
| `--pr`, gh/glab, Forge integrations | out of scope |
| Status tracking (dashboard, sidebar, hooks, agents JSON) | workmux-agent-notes §Porting priorities calls this "essential parity" for workmux; **out of scope** for this ticket — it is a separate work-stream (agent hooks per-binary) |
| sandbox / remote / dashboard / `--headless` / `resurrect` / `rebase [name]` as separate verb / `cleanup-node-modules` default / `sync-files` | deferred or out of scope (see §12) |
| Deferred-cleanup worker, setsid, quarantine rename | rejected for v1 (incumbent's simpler guard suffices) — revisit trigger logged |
| `worktree_dir` / `window_prefix` config (Rex already fixes layout: `<project>__worktrees/<name>`, `wm/<name>`, sessions `<project>/<name>`) | not configurable in v1; nothing needs it |

---

## 12. Explicitly deferred (with the trigger to revisit)

| Item | Trigger condition |
|---|---|
| `workrex_sync_files` re-running file ops | user's first monorepo where deps/config need re-takeover |
| Monorepo subdir config (`backend/.workrex.lua`) | a repo gains a second independently-setup identity |
| Global `~/.config/rex/workrex-defaults.lua` | a second non-default repo wants shared hooks |
| Port-collision allocator (bind-probe instead of pure hash) | two trees hash into the same 10-port block in practice |
| Conductor-style **archive/restore** state (`worktree-archived`) | users remove worktrees purely to clear the picker but still want the branch/PR reproducible without re-creating (needs its own state file, not a shortcut of remove) |
| Deferred teardown worker (`workrex _deferred-cleanup`) | merging **from inside** a worktree session becomes habitual and users complain about the two-step |
| Conductor-style branch auto-rename from chat | only if agents start picking branch names themselves |

---

## 13. Number-of-moving-parts ledger (the minimalist claim, audited)

| Kind | Count | Items |
|---|---|---|
| New files | 1 | `dot_config/rex/workconfig.lua` |
| New shell helper scripts | **0** | setup + file-ops scripts are Lua-emitted strings, already the incumbent pattern |
| New state files | **0** | base branch lives in git config; setup marker lives in the worktree |
| New API calls | 1 | `rex.call("session.new_window", ...)` — verified schema above |
| New CLI verbs | 2 | `worktree_merge`, `workrex_setup_retry` (plus one internal, `workrex_setup_done`, consumed by the pane) |
| New keybindings | 2 | `ctrl+space>m`, `ctrl+space>s` |
| New actions the user types | 3 | merge, merge_prompt, retry |
| Deferred features | 7 | §12 with triggers |
