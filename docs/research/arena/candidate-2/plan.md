# Workrex — Candidate 2: Conductor-first implementation spec

Stance: the felt experience is "press `C-space w`, and by the time I switch to the new
session it is actually ready to work." The session appears in **under 1 second** (same as
today), but it already contains a live **Setup tab** streaming the repo's post-create work,
an **agent window gated** on setup completion, **Conductor-style env injection + a
10-port block**, and branch/base metadata recorded for a **one-key merge + archive** flow.
Everything is plain scripts and small state files — no background daemons.

---

## 0. Conductor parity table — what is ported, what is consciously dropped

| Conductor feature | Rex-native translation | Status |
|---|---|---|
| Worktree + branch per task | `<project>/<name>` session (exists today) | keep |
| `.conductor/settings.toml` committed per-repo config | `.workrex.lua` returning a table, sandbox-loaded | **new** |
| Files-to-copy / `.worktreeinclude` (default `.env*`) | `files.copy` / `files.symlink` glob rules, ignored-files only | **new** |
| Setup script runs at creation, shown in Setup tab | generated `.workrex/setup.sh` streamed into a real "setup" window | **new** |
| Chat composer visible while setup runs | agent window exists immediately, running a gate script | **new** |
| Setup failure = first-class visible state | red ❌ banner in setup tab; gated agent drops to shell with rerun hint | **new** |
| Rerun setup | `worktree_setup` action (new setup window, regenerates script) | **new** |
| `CONDUCTOR_*` env vars | `WORKREX_*` env file sourced by every pane | **new** |
| `CONDUCTOR_PORT` 10-port block | sequential port-block allocator in `~/.local/state/rex/workrex-ports` | **new** |
| branch from `origin/<base>`, fetch first | fetch attempt (5 s cap, best-effort) + worktree add from resolved base | **new** |
| `branch.<branch>.workmux-base`-style base recording | **workmux**, not Conductor: `git config branch.<branch>.workrex-base` | **new** |
| branch renamed by the first chat | seed prompt to Claude (only agent with a supported prompt arg) + `worktree_rename` | **partial** |
| merge with strategies, guards, pre-merge hook | popup-streamed merge pipeline (merge/squash/rebase) | **new** |
| archive + history restore | `worktree_archive` (meta file, branch kept) + `worktree_restore` (worktree from branch) | **new** |
| archive hook cleans out-of-tree resources | `cfg.archive` hook run in worktree before cleanup, streamed | **new** |
| restorable **chat** history after archive | **dropped.** Rex has no chat binding; agent transcripts live in the worktree and die with it. The user notices: restoring gives back the *branch and worktree*, never the conversation. |
| Diff viewer / Checks tab / PR flow | **dropped.** Terminal-native `lazygit`/`hunk` popups already cover this (init.lua:127–139). The user notices: no aggregated per-workspace diff/CI view. |
| Checkpoints (revert code + chat together) | **dropped** — no chat state to revert. |
| Multiple chats per workspace | **dropped as a first-class feature**; user can manually split another agent pane (`C-space |`). |
| Run tab / process panel | **dropped.** Dev servers are just started in a shell pane; the env file gives each worktree its port block so parallel servers don't collide. |
| Cloud / sandbox / remote / GUI | **explicitly deferred** per the task constraints. |

Deliberately **not ported** from workmux either: the deferred-cleanup detached worker
(workmux §2.1 case A) — replaced by instant rename-to-trash + lazy GC; the agent
status-hook machinery (workmux-agent-notes §1) — deferred; nerdfont/dashboard/sidebar —
deferred.

---

## 1. Files changed

```
dot_config/rex/
  workrex.lua        NEW   pure helpers: repo config loader, port allocator, env file
                           writer, file-op planner, setup/gate script builders,
                           archive meta store, sh-quoting/glob helpers
  worktrees.lua      EDIT  lifecycle actions extended; new merge/archive/restore/
                           rename/setup/gc actions + pickers + bindings
  init.lua           EDIT  require + new keybindings (3 lines)
dot_config/rex/README.md      EDIT  (docs table — repo convention: keep README in sync)
AGENTS.md                     EDIT  Rex section: new actions/keys/state files
```

No new helper *shell* scripts on disk: all generated shell lives inside the generated
per-worktree `.workrex/setup.sh` and inline `sh -c` strings in the Lua actions (same
pattern as the existing picker scripts, worktrees.lua:594–617).

---

## 2. Per-repo committed config: `.workrex.lua`

Conductor's biggest lesson (conductor-notes §6): *worktree tooling config is project
config, committed to the repo*.

### 2.1 Schema

```lua
-- <repo-root>/.workrex.lua  (committed; team default)
-- Everything optional. Missing file => { files.copy = { ".env*" } }.
return {
  base = "origin/main",     -- branch new worktrees fork from (default: origin/HEAD, else HEAD)

  files = {
    copy    = { ".env*", "config/local.json" },     -- globs vs repo root, ignored files only
    symlink = { ".claude/settings.local.json" },    -- made RELATIVE (worktree -> root), workmux-style
    exclude = { "node_modules/", "dist/", "vendor/" }, -- extra heavy dirs to never touch
  },

  ports = 10,               -- contiguous port block size per worktree

  setup = {                 -- run per fresh worktree, streamed in the setup window
    "pnpm install",
    "pnpm run db:init --name $WORKREX_WORKSPACE_NAME",
  },

  pre_merge = { "make lint" },        -- runs in the worktree before merging; failure aborts
  archive   = { "./script/workspace-archive.sh" },  -- runs at archive/remove; cleans out-of-tree state
}
```

### 2.2 Loader (workrex.lua) — sandboxed, fail-fast

Arbitrary Lua in a repo can't be `dofile`d raw into the action process. Load it with a
stripped environment (Conductor runner shells non-interactively; we go one better by
denying side effects at load time):

```lua
local function load_repo_config(root)
  local path = root .. "/.workrex.lua"
  local f = io.open(path, "r")
  if f == nil then
    return { files = { copy = { ".env*" } } }  -- Conductor default
  end
  local source = f:read("*a"); f:close()

  local env = {}  -- no io, no os, no require, no print inside .workrex.lua
  local chunk
  chunk, err = load(source, "@" .. path, "t", env)   -- Lua 5.2+/LuaJIT
  if chunk == nil then
    -- Fallback for a 5.1-only Lua: compile, then setfenv
    chunk, err = load(source, "@" .. path, "t")
    if chunk ~= nil and setfenv then setfenv(chunk, env) end
  end
  if chunk == nil then error("workrex: .workrex.lua: " .. err, 0) end

  local ok, cfg = pcall(chunk)
  if not ok or type(cfg) ~= "table" then
    error("workrex: .workrex.lua must return a table", 0)
  end

  -- field validation (hard failures, before anything is created)
  local function str_list(v, name)
    if v == nil then return {} end
    if type(v) ~= "table" then error("workrex: ." .. name .. " must be a list of strings", 0) end
    for _, s in ipairs(v) do
      if type(s) ~= "string" or s:match("[%c]") then
        error("workrex: ." .. name .. " entries must be plain single-line strings", 0)
      end
    end
    return v
  end
  cfg.base       = type(cfg.base) == "string" and cfg.base or nil
  cfg.ports      = math.tointeger(cfg.ports) or (type(cfg.ports) == "number" and cfg.ports or 10)
  if cfg.ports < 1 or cfg.ports > 100 then error("workrex: .ports must be 1..100", 0) end
  cfg.setup      = str_list(cfg.setup, "setup")
  cfg.pre_merge  = str_list(cfg.pre_merge, "pre_merge")
  cfg.archive    = str_list(cfg.archive, "archive")
  cfg.files      = type(cfg.files) == "table" and cfg.files or {}
  cfg.files.copy    = str_list(cfg.files.copy, "files.copy")
  cfg.files.symlink = str_list(cfg.files.symlink, "files.symlink")
  cfg.files.exclude = str_list(cfg.files.exclude, "files.exclude")
  return cfg
end
```

Failure paths: unreadable → default config; syntax error or wrong return type → action
aborts **before** any worktree is created (nothing to roll back); a malicious `.workrex.lua`
is inert because its environment has no capabilities.

Per-machine overrides (Conductor `settings.local.toml`) are **not** a second file in
v1 — a repo can define sibling setup entries guarded by `[ -d ... ]` tests. Deferred:
`<repo>/.workrex.local.lua` override, merge order, `"$schema"`-style lint.

### 2.3 Config provenance — the Conductor quick-start prompt

README gains the one-paragraph "ask your agent" recipe from conductor-notes §6: open a
worktree, tell the agent to write `.workrex.lua` from what the project needs, review the
diff. No `workrex init` action in v1.

---

## 3. State layout

```
~/.local/state/rex/
  worktree-agent              (existing, worktrees.lua:32–35)   last used agent
  worktree.log                (existing)                        picker/pipeline failures
  worktree-sessions           (existing, :331–377)              worktree path -> session id
  workrex-ports               NEW   "base<TAB>size<TAB>worktree-path" per line
  workrex-archives/<name>.meta  NEW   "branch<TAB>base<TAB>origPath<TAB>ts<TAB>dirty" per line

<worktree>/.workrex/            NEW, untracked (excluded via the worktree's git info/exclude)
  env                           sourced by every pane/script; exports WORKREX_* vars
  setup.sh                      generated per add/rerun
  status                        single line: setup exit code; deleted before each run
  PROMPT.md                     optional first-task seed prompt
```

**Base branch lives in the repo, not in `~/.local/state`.** Recording
`branch.wm/<name>.workrex-base` via `git config --local` (workmux §6 table) means the
merge target survives a wiped state directory, a machine change, and chezmoi diffs —
verified:`git config "branch.wm/feat-1.workrex-base" main` stores and reads back with the
slash-subsection form. Session/ports/archive state stays in `~/.local/state/rex` because
it is machine-local cache, not team truth.

---

## 4. Env injection + port block allocation

The terminal-block options schema (verified via `rex api` for the `shell` flavor) is
`{args, command, cwd, exit, initial_input, login, path_prepend, shell, size, theme}` —
**there is no per-block `env` option.** Injection therefore happens in the text layer,
which is also more transparent to the user:

| Pane | How it gets `WORKREX_*` |
|---|---|
| setup window | `setup.sh` starts with `. ./.workrex/env` |
| agent window (gated) | gate script sources env before `exec <agent>` |
| nvim window | command wrapped: `sh -c '. ./.workrex/env 2>/dev/null; exec nvim'` (runs through the login shell wrapper, so PATH startup files still apply — per the `command` option's documented behavior) |
| any pane the user opens later | `source .workrex/env` (documented in the env file header) |

### 4.1 env file

`workrex.write_env(root, path, branch, base, port)`:

```sh
# Generated by workrex — source this to get the workspace env:  source .workrex/env
export WORKREX_ROOT_PATH="/abs/root"
export WORKREX_WORKSPACE_PATH="/abs/root__worktrees/name"
export WORKREX_WORKSPACE_NAME="name"
export WORKREX_PROJECT="root-project"
export WORKREX_BRANCH="wm/name"
export WORKREX_BASE_BRANCH="main"
export WORKREX_PORT=3100          # block 3100..3109
export WORKREX_PORTS="3100-3109"
```

Values are substituted in Lua from a table built at creation time; the file is written
with `io.open` (same primitive the existing state-file code uses, worktrees.lua:225–232,
347–363).

### 4.2 Port allocator — algorithm + failure paths

State file `~/.local/state/rex/workrex-ports`, one record per worktree:
`base<TAB>size<TAB>path`.

```
alloc(path, size):
  1. entries = parse file (malformed line -> drop that line; unopenable file -> empty list)
  2. GC pass: entry is dead when io.open(path .. "/.git") fails
     (a linked worktree's .git is a real file; dead == worktree gone)
  3. sort surviving entries by base
  4. base = 3100 PORT_BASE_DEFAULT
     for e in sorted:                       -- walk occupied ranges
       if base + size <= e.base: break      -- free gap fits before e
       if base < e.base + e.size: base = e.base + e.size
  5. append "base<TAB>size<TAB>path"; rewrite the file atomically-enough
     (io.open "w" full rewrite, same idiom as write_session_map, worktrees.lua:347–363)
  6. return base
```

Failure paths:
- corrupt/unreadable file → start at 3100 (worst case two worktrees share a block; dev
  servers fail loudly in their own pane, user edits the file or removes one worktree).
- a *non-Workrex* process squatting on the range is **not detected** (no `lsof` scan —
  slow, flaky). Consciously accepted; documented in the env file header (`# ports may be
  edited; see ~/.local/state/rex/workrex-ports`).
- allocation happens **before** session creation (the env file must exist for setup.sh);
  if the add later rolls back, the entry is reclaimed by the next GC pass — no explicit
  release needed on that path.

Sizes are stored per-entry so an entry with a custom size (e.g. 20) never overlaps its
neighbor of the default size.

---

## 5. Setup pipeline: generated script, streamed output, gated agent

### 5.1 Gating decision

```
gated = (#cfg.setup > 0)
     or (#cfg.files.copy > 0 and cfg.files.copy ~= {".env*"}-only-with-nothing-matching)
```

Implementation detail: copy patterns are resolved at *creation time* (§5.3), so we can
decide statically: `gated = #setup > 0 or #copy_matches > 0 or #symlinks > 0`.
If **not gated** → the session is created exactly as today (2 windows, agent ungated,
zero new behavior). A repo that matches the default `.env*` but has no ignored `.env`
produces a setup.sh with a single informational "nothing to copy" line — it finishes in
<1 s and the gate releases immediately; no special case needed.

### 5.2 `worktree_add` new sequence (action run = max ~25 s)

| step | budget | failure path |
|---|---|---|
| 1. `valid_name` (reuse :87–89) + `require_root` (reuse :130–162) | ~0 | error out |
| 2. `load_repo_config(root)` | ~0 | error out, nothing created |
| 3. `find_worktree_session` duplicate guard (reuse :381–401) | small | error "already exists; use worktree_open" |
| 4. resolve base: `args.base` > `cfg.base` > `git rev-parse --abbrev-ref origin/HEAD` (error→`HEAD`) | <1 s | fall back to current HEAD |
| 5. best-effort fetch: `git -C root fetch --prune origin`, `timeout = 5`, result ignored (logged to worktree.log) | 5 s | proceed with stale refs (Conductor fetches first; we can't afford it inside the action budget — traded for speed, the worktree-add base staleness is the one visible difference) |
| 6. `git worktree add -b <branch> <path> <base>` — reuse the exact call at worktrees.lua:454–456 (`timeout = 20`) | 20 s | error |
| 7. `git -C root config branch.<branch>.workrex-base <base>` | <1 s | non-fatal: warn into result (merge falls back to auto-detect) |
| 8. `mkdir .workrex`; write env (§4.1) after `alloc_ports`; append `.workrex/` to the worktree's exclude: `git -C path rev-parse --git-path info/exclude` | <1 s | continue without exclude (git status will show `.workrex/`; non-fatal) |
| 9. plan file ops (§5.3); if `gated` write `setup.sh`, delete stale `status` | <1 s | error out → roll back worktree (existing lines 458–464 pattern: `worktree remove --force` + `branch -D`) and GC reclaims the port entry |
| 10. snapshot: `pcall(create_session, ...)` (reuse :415–430, parametrized — see §5.4) | ~1 s | same rollback as 9 |
| 11. `write_last_agent(spec)`, `remember_session(path, id)` (reuse :466–467) | ~0 | — |
| 12. return table (existing shape + `gated`, `port`, `base`) | — | — |

Worst case git time ≤ ~26 s; the fetch cap and the worktree-add cap are the two levers
keeping this inside the ~30 s action budget (AGENTS.md hard constraint). If `git worktree
add` itself times out on a huge repo, the user gets the error and can retry —
considered acceptable v1 behavior; the fix (create the worktree in a pane) is listed
under Deferred.

### 5.3 File-op planner (runs in Lua at creation, executes in setup.sh)

```
plan_copy(root, cfg):
  1. ignored = split(git -C root ls-files --others --ignored --exclude-standard -z, \0)
     (timeout 15 s; failure -> empty list, emit "warning: file-list failed" step)
  2. for each candidate: skip if its path contains any heavy dir:
     {"/node_modules/", "/dist/", "/.next/", "/target/", "/.venv/", "/build/"} ∪ cfg.files.exclude
  3. match against cfg.files.copy globs (§5.5); ALSO always try cfg.listing cap:
     - if a pattern like "**" matches > 100 files -> keep first 100, emit warning line in setup.sh
  4. emit lines into setup.sh:
       skip-if-exists: `[ -e "<dst>" ] || { mkdir -p "<dir>"; cp -a "$WORKREX_ROOT_PATH/<f>" "<dst>"; }`
     (idempotent → rerun is safe; destination already tracked in the worktree is preserved
      with a note line, matching Conductor's "never copies tracked files")
plan_symlink(cfg): for each pattern, resolve matches over the same ignored list,
  compute a RELATIVE link target worktree->root via the common-prefix diff (the two are
  siblings: root=a/b/x, wt=a/b/x__worktrees/y → "../x"); emit
  `ln -sfn "<rel>" "<dst>"` guarded by `[ -e $WORKREX_ROOT_PATH/<f> ]`.
```

**Why planner-in-Lua, copy-in-shell:** Lua needs to decide `gated` and needs no `cp`
capability; the copies then stream with timestamps in the visible setup window instead of
being silent background work — Conductor's Setup-tab feel requires output, so nothing
runs invisibly.

### 5.4 Session layout & the gate

`terminal_pane` (worktrees.lua:117–128) gains an `extra` options table. Three windows in
`session.create` order (the worktree-add action reuses the existing `rex.call("session.create",
{label=..., initial_windows=...})` call shape, :419–425):

```lua
-- 1. nvim window, env-aware
terminal_pane(path, "nvim",
  { "sh", "-c", '. ./.workrex/env 2>/dev/null; exec nvim' })
-- 2. setup window: STAYS OPEN after the script exits (visible final state)
terminal_pane(path, "setup",
  { "bash", ".workrex/setup.sh" },
  { exit = { on_completion = false } })
-- 3. agent window, gated
terminal_pane(path, spec, { "bash", "-c", gate_script }, { exit = { on_completion = false } })
```

`gate_script` (the generated `.workrex/setup.sh`'s sibling, built by `workrex.build_gate`):

```bash
cd "$WT"                                   # WT passed as argv
status=.workrex/status
n=0
while [ ! -f "$status" ]; do               # poll; 1 s granularity, cheap
  n=$((n+1))
  [ "$n" -gt 1800 ] && { printf '\n✖ setup never reported (window closed?). rerun: C-space>shift+s\n'; break; }
  sleep 1
done
code=$(cat "$status" 2>/dev/null || echo 99)
if [ "$code" = "0" ]; then
  printf '✔ setup complete — starting %s\n' "<agent>"
  . ./.workrex/env
  exec <sh-quoted agent argv> [<optional prompt arg per §7>]
fi
printf '✖ setup failed (exit %s). Output is in the setup tab.\n' "$code"
printf 'rerun: C-space>shift+s  or  rex do worktree_setup\n'
exec zsh
```

Failure semantics, explicitly:
- **A failing step** writes `status` before exiting and prints its own red ❌ line in the
  setup window; the agent block never starts and instead lands in a shell, with the rerun
  hint on screen. Two visible artifacts — first-class failure state.
- **The user closes the setup window** mid-run → no `status` → gate gives up after
  ~30 min with the same hint. (Longer than Conductor's patience, but there is no watchdog
  to notice; polling forever would be worse.)
- **Session killed during setup** → everything dies together; no orphans, nothing to clean.
- The agent window shows a benign be-quiet loop meanwhile. This is the honest Rex
  translation of Conductor's "chat composer live while Setup streams": the user is never
  blocked from switching to the session; they just can't *use* the agent until setup is
  done — and can watch exactly why in the setup tab.

### 5.5 Generated `setup.sh` shape (workrex.build_setup_script)

```bash
#!/bin/bash
# Generated by workrex from .workrex.lua — commit changes to that file, not here.
cd "$(dirname "$0")/.." || exit 9
set -u
. ./.workrex/env || { printf '✖ env missing\n'; exit 9; }
_wc_step()  { printf '\n\033[2m▸ %s\033[0m\n' "$1"; }
_wc_fail()  { printf '\n\033[31;1m✖ SETUP FAILED: %s\033[0m\n' "$1"; echo "$2" > .workrex/status; exit 1; }
_wc_status(){ echo "$1" > .workrex/status; }
_t0=$SECONDS

_wc_step "copy .env* from main checkout (3 files)"
[ -e .env ]          || cp -a "$WORKREX_ROOT_PATH/.env" .env || _wc_fail "cp .env" 1
[ -e .env.local ]    || cp -a "$WORKREX_ROOT_PATH/.env.local" .env.local || _wc_fail "cp .env.local" 1
...

_wc_step "symlink .claude/settings.local.json (relative)"
[ -e .claude/settings.local.json ] && printf '  skipped (exists)\n' \
  || ln -sfn "../../../proj/.claude/settings.local.json" .claude/settings.local.json || _wc_fail symlink 1

_wc_step "pnpm install"
pnpm install || _wc_fail "pnpm install" 2

_wc_step "pnpm run db:init"
[ = user line runs under sh -c so it may use $WORKREX_* ]
... || _wc_fail '<line>' 3

_wc_status 0
printf '\n\033[32;1m✔ setup complete in %ss\033[0m\n' "$((SECONDS-_t0))"
```

Each user setup line is a separate `%s || _wc_fail` step so the first failure names the
exact line (Conductor parity: "Setup script failed" surfaces the culprit). Symlink
targets are relative (workmux file_ops semantics, workmux-core-notes §1.8).

### 5.6 Rerun: `worktree_setup` (bound `C-space>shift+s`)

```
resolve: name arg, else the action's own session must be a worktree session
         (label prefix <project>/ — parse path from SESSION_MAP by session id).
1. regenerate setup.sh from the CURRENT .workrex.lua (config edits take effect)
2. rm -f .workrex/status
3. rex.call("session.new_window", { session_id = sid, window_label = "setup",
       layout = terminal_pane(path, "setup", {"bash", ".workrex/setup.sh"},
                              { exit = { on_completion = false } }) })
```
- If the gate is still waiting (no agent yet): it picks up the new `status` — the rerun
  *releases* the agent.
- If the agent is already running: only the output is refreshed; the gate doesn't matter.
- Running it twice in a row opens a second "setup" window; the old one is inert output.
  Accepted (matches how the user would open any new tab).

---

## 6. Branch base + conductor's rename trick

- Base recorded at creation (§3, `branch.<branch>.workrex-base`), read with
  `git -C root config branch.<branch>.workrex-base`; invalid/absent → fall back to
  `origin/HEAD` detection.
- **`worktree_rename`** (`name`, `branch`): the one-key manual version of Conductor's
  chat-driven rename:
  1. `git -C <wt> branch -m <new>` (`--force` if the new name pattern repeats).
  2. migrate metadata: read old `branch.<old>.workrex-base`, `git config --add
     branch.<new>.workrex-base <base>` + `git config --unset branch.<old>.workrex-base`.
  3. `rex.call("session.set_label", ...)`? — not required; the session label is
     `<project>/<name>` (dir name), which stays. Branch is visible in git. Documented.
- **Seed prompt** (best effort, Claude only): the `agents` table entries gain
  `prompt_as_arg = true` (only `claude` flagged in v1 — per workmux-agent-notes §3,
  prompt-argument conventions differ per agent and we refuse to guess). If
  `.workrex/PROMPT.md` exists (written by `worktree_add args.prompt`, or the `w` picker's
  optional third question "first task (Enter to skip)"), the gate execs
  `<claude> "$(cat .workrex/PROMPT.md)"` where PROMPT.md opens with:

  > You are working in worktree `<path>` on branch `<wm/name>` (base: `<base>`).
  > First, if the task is clear, rename the branch to match it — either run
  > `rex do worktree_rename branch=<new-name>` (preferred; keeps Rex state in sync) or
  > plain `git branch -m` and tell the user.
  > Then: <user text>

  Dropped honestly: for pi/codex/opencode/amp there is **no auto-rename**, only the
  manual `worktree_rename` key (`C-space>shift+n`). The gate window prints a one-line
  hint at agent start for non-prompt agents.

---

## 7. Merge: guards, strategies, pre-merge hook, then archive

Conductor auto-archives merged workspaces; workmux's merge pipeline (§2 of the notes) is
the algorithmic donor. Both are satisfied by **one streamed popup pipeline** + a thin raw
action:

- **`worktree_merge`** — validations in Lua, then `context.popup` runs the whole pipeline
  as a `sh -c` script (the same floating-layer pattern as the existing pickers,
  worktrees.lua:612–617). Output streams with timestamps; any failure keeps the popup and
  its red lines on screen until Enter (existing pattern :603–607); failures append to
  `worktree.log` (:604 pattern).
- **`worktree_merge_apply`** — the same pipeline minus hooks/confirmations, callable from
  CLI/scripts (`no_verify=1` semantics); used by nobody interactively.

### 7.1 Lua-side validation + arg assembly (fast, <2 s)

```
1. resolve root (require_root), path/branch via worktree_paths (:73–77)
2. self-session guard: if find_worktree_session(...).session_id == ctx.session_id
   -> error "merge/archive from another session" (same guard as worktree_remove, :543–545)
3. target branch = args.into > git config branch.<branch>.workrex-base
                     > git rev-parse --abbrev-ref origin/HEAD
4. target worktree = scan `git worktree list --porcelain` for `branch refs/heads/<target>`;
   absent -> target worktree = root (workmux §2 step 6)
5. strategy = args.strategy > cfg.merge_strategy(none in v1 schema — default "merge")
6. build argv for the pipeline script and open the popup
```

### 7.2 Pipeline script (popup), in order — with failure exits

```sh
# provided as argv: $1 wt  $2 target_wt  $3 branch  $4 target  $5 strategy
#                   $6 keep(0/1)  $7 ignore_dirty  $8 LOG  $9 REX_BIN
die(){ printf '\n\033[31;1m✖ %s\033[0m\n' "$1" >>/dev/tty 2>/dev/null || printf '%s' ""; }

s=$(git -C "$WT" status --porcelain); gutted=$(printf '%s' "$s" | grep -v '^??' || true)
[ -n "$(printf '%s' "$s" | grep '^??')" ] || [ -n "$gutted" ] || ...
#  GUARD 1 (source dirty): unstaged OR untracked present and !ignore_dirty -> FAIL
#     message: "commit or stash; or rerun with ignore_dirty=1"
[ -z "$gutted" ] && [ -n "$(git -C "$WT" diff --cached --name-only)" ] && \
  git -C "$WT" commit -q -m "workrex: stage handoff before merge" || :   # staged-only -> auto-commit (workmux §2.7)
#  GUARD 2 (branch == target) -> FAIL "cannot merge into itself"
#  GUARD 3 (target dirty, tracked): git -C "$TARGET_WT" status --porcelain | grep -v '^??' -> FAIL
#     (untracked allowed; git fails safely on collisions — workmux §2.8)
#  pre_merge hooks (cfg.pre_merge, one per arg, run IN "$WT", env sourced):
#     for cmd: . ./.workrex/env; (cd "$WT" && eval "@/cmd/@")
#       failure -> FAIL "pre_merge hook failed: <cmd>"  (hard abort, workmux §2.10)
#  STRATEGY:
#     rebase: git -C "$WT" rebase "$TGT" || FAIL "conflicts: resolve in $WT, then rerun merge"
#             git -C "$TARGET_WT" merge --ff-only "$BRANCH" || FAIL ff
#     squash: git -C "$TARGET_WT" merge --squash "$BRANCH" \
#               || { git -C "$TARGET_WT" reset --hard; FAIL squash; }
#             git -C "$TARGET_WT" commit -m "Merge $BRANCH (squash)" || FAIL msg
#             (divergence from workmux: no $EDITOR; message is amendable — editor popups
#              inside a streaming script would wedge it)
#     merge:  git -C "$TARGET_WT" merge --no-edit "$BRANCH" \
#               || { git -C "$TARGET_WT" merge --abort 2>/dev/null; FAIL conflicts; }
#  success banner: "✔ merged <branch> into <target>"
```

### 7.3 Archive-tail (same popup unless `keep=1`)

Runs the **archive pipeline** (§8.2) as its final section: archive hook → session kill →
worktree removal → meta + ports GC → done. This gives Conductor's `archive_on_merge`
behavior for free with a single on-screen transcript.

**Explicit difference from workmux:** the merge runs to completion *inside* a window the
user can watch, instead of hooks being synchronous server-side calls that can blow the
30 s action budget on a slow lint. The trade: no machine-readable action result for
merge; the popup + `worktree.log` are the record. Deliberate.

---

## 8. Archive / restore / remove / gc

### 8.1 `worktree_archive` (action, CLI-capable) — synchronous, short

```
1. validations as §7.1 (self-session guard + name).
2. dirty check: uncommitted changes and !force -> STOP: "archive would discard changes;
   commit/stash, or force=1 (moves the tree to .workrex-trash)". Never silently destroys.
3. kill session: resolve rex binary via the existing `rex_bin()` fallback (:176–206),
   `run_ok({bin,"kill",session_id},{timeout=20})` (:552 pattern).
4. run cfg.archive hook, one shell line each, in the worktree, env sourced,
   `run_ok(cmd, { timeout = 20 })` — failure ABORTS archive before any deletion
   (Conductor: "If the script fails, archive may not complete"). Reported path: rerun.
5. remove worktree dir INSTANTLY by rename to
   `<parent>/.workrex-trash/<name>-<os.time()>`; then `git worktree prune`
   (`rm -rf` inside the action would violate the budget; rename is O(1)).
6. attempt `rm -rf` on the trash dir with `timeout {20}`; leftover is fine — GC reaps.
7. delete branch only if `delete_branch=1` (default KEEP; Conductor
   `git.delete_branch_on_archive` opt-in parity).
8. append archive meta file `~/.local/state/rex/workrex-archives/<name>.meta`
   ("branch<TAB>base<TAB>origPath<TAB>ts<TAB>dirty"): the History list.
9. `forget_session(path)` (:371–377) + `rex do worktree_gc`.
```

### 8.2 Popup drivers for interactive use

`worktree_archive_prompt` / `worktree_merge` wrap §8.1-steps 2–9 in the "streamed popup"
script pattern (steps 5–7 stream live; final state stays on screen; Enter → close).
The synchronous action remains the scripted path.

### 8.3 `worktree_restore` (Conductor History pane → one key)

```
1. meta exists? else list archives via a picker (see §10): fzf over
   ~/.local/state/rex/workrex-archives/*.meta (names first, then readable summary).
2. branch must still exist: git show-ref --verify refs/heads/<branch> else
   FAIL "branch was deleted; nothing to restore".
3. path occupied? -> FAIL "dir exists — remove it or pick another name" (rename meta).
4. git worktree add <origPath> <branch>            (no -b; branch already created)
   timeout 20; on failure error out (nothing else touched).
5. write env file (fresh alloc_ports — the old block was freed at archive),
   regenerate setup.sh, remove status.
6. create session with the same 3-window gated layout as tree add (nvim + setup + gate).
   Rationale: after weeks archived, deps are stale — restoring *straight into setup*
   matches Conductor's "unarchive starts the machine again".
7. delete the meta file (workspace is live again). Old sessions map: remember_session.
```

**Honest drops:** no chat history (§0); the original directory identity is not
resurrected — same path when free, otherwise the user must rename.

### 8.4 `worktree_remove` — kept, now thin

Becomes `worktree_archive force=1 delete_branch=1` semantics **plus** pre_remove
behavior: the cfg.archive hook still runs first (workmux `pre_remove` parity), still
fails hard unless `force=1`. Old CLI behavior (`rex do worktree_remove name=...`) is
preserved: guards (:543–545), kill (:548–553), `git worktree remove` (:555–560),
`branch -d` only when merged (:565) — but it now goes through the archive pipeline so
nothing is dropped. `.workrex-trash/` leftovers are swept by GC regardless.

### 8.5 `worktree_gc` — lazy, no daemon

```
1. ports file: drop entries whose worktree/.git is gone (§4.2 step 2).
2. trash dir: find . ..name>-mtime +7 | xargs rm -rf (timeout 20, best effort, ignore)
3. archive metas: drop entries whose branch no longer exists AND ts older than 30 d
   (explicit `branches=1` arg deletes the stale branches instead of the meta — safer default).
```
Bound as `worktree_archive_prompt`'s maint clarifier… no — GC is invoked automatically at
the end of every archive pipeline; it has **no keybinding** (CLI only:
`rex do worktree_gc`). Fewer keys > cleverness.

---

## 9. Action / CLI/ keybinding surface

CLI (all `rex do worktree_* ...`, unchanged invocation style — AGENTS.md table continues
to hold):

| Action | Args | New? |
|---|---|---|
| `worktree_add` | name, agent?, base?, prompt? | edited (gating/env/ports/meta) |
| `worktree_open` | name, agent? | edited only: existing behavior, no gate |
| `worktree_remove` | name, force? | edited (routes through archive pipeline) |
| `worktree_setup` | name? | **NEW** — rerun setup window |
| `worktree_merge` | name, into?, strategy? (merge\|squash\|rebase), keep?, ignore_dirty? | **NEW** — popup pipeline |
| `worktree_merge_apply` | same | **NEW** — scripted, no hooks/popup |
| `worktree_archive` | name, force?, delete_branch? | **NEW** — sync |
| `worktree_archive_prompt` | — | **NEW** — picker + streamed pipeline |
| `worktree_restore` / `worktree_restore_prompt` | name? | **NEW** |
| `worktree_rename` | name, branch | **NEW** |
| `worktree_gc` | branches? | **NEW** — no keybinding |
| `worktree_add_prompt` / `_open_prompt` / `_remove_prompt` | — | edited (prompt question; log lines named) |

Keybindings (init.lua additions):

| Key | Action | Note |
|---|---|---|
| `C-space w` | worktree_add_prompt | existing; gains optional "first task" question |
| `C-space o` | worktree_open_prompt | existing |
| `C-space W` | worktree_remove_prompt | existing |
| `C-space m` | worktree_merge | **NEW** (modal guard inside the same popup: merge → archive unless keep) |
| `C-space shift+x` | worktree_archive_prompt | **NEW** (archive ≈ the remove-cluster's sibling) |
| `C-space shift+o` | worktree_restore_prompt | **NEW** (History pane) |
| `C-space shift+s` | worktree_setup | **NEW** (rerun setup in the current session) |
| `C-space shift+n` | worktree_rename_prompt | **NEW** (branch rename; `shift+4`/`$` stays session rename per tmux muscle memory) |

New keys avoid every taken sequence in init.lua (`|`, `-`, arrows, `c n p ] [ f r z x g
G h t l w o W , $ 1-9`) — verified against the binding list at init.lua:19–63,161–164,198.

The **optimistic loop** for `w`: press → fzf agent → type name → (optionally paste a task)
→ popup closes → `rex do worktree_add` finishes in <~26 s → session exists with nvim +
setup streaming + agent gated. Switch over with `C-space f` at your leisure; the agent is
ready exactly when the gate releases, and if setup failed you see why *before* you open it.

---

## 10. Reuse map (exact reuse of existing helpers — line evidence)

| Existing code | Reused for |
|---|---|
| `run/run_ok` (:41–61) | every git call in add/gc/archive-sync; timeout discipline |
| `repo_root` (:65–71) | unchanged; still the entry root resolver |
| `worktree_paths` (:73–77) | unchanged path/branch derivation (`<project>__worktrees/<name>`, `wm/<name>` given in :73–77 — schema collision-free with our trash/meta names) |
| `require_root` (:130–162) | all new actions' root resolution, incl. the multi-pane fallback |
| `valid_name` (:87–89) | every name arg |
| `parse_words` (`agent_command` :104–115) | gate argv build; unchanged |
| `terminal_pane` (:117–128) | extended with `extra` options (backward-compatible default nil) |
| `create_session` (:415–430) | parametrized to accept a window-plans table; add/restore both call it |
| rollback block (:458–464) | reused verbatim when session creation fails after worktree add |
| `find_worktree_session` (:381–401) | duplicate-merge/archive guards; label/ rename/ sessions map reads |
| `remember/forget_session` (:365–377) | unchanged |
| `rex_bin()` (:176–206) | popup pipelines need `rex kill <sid>`; the resolver keeps working inside generated `sh` because we pass its result as an argv |
| picker script shape (:594–617, :684–700) | template for all new popups: fzf → `rex do -s "$2"` → append to `$LOG` → keep error until Enter |
| `context.popup` (context.lua:74–91) | all streams |
| `context.cwd_of` (context.lua:61–71) | unchanged (used indirectly through require_root) |

---

## 11. Migration from today's worktrees.lua

1. `chezmoi apply ~/.config/rex`; `rex config check`; `rex config reload`.
2. `rex actions | grep worktree` — all 12 old + 9 new actions present.
3. **Behavioral deltas only for new trees:** `worktree_add` without a `.workrex.lua`
   now runs the default `.env*` copy (Conductor's out-of-box default). If nothing is
   ignored, the setup step is an instant informational line; the agent is released<1 s
   later. Existing (pre-migration) worktrees are not touched — `worktree_open` keeps
   creating plain 2-window sessions.
4. Old CLI verbs keep working (`worktree_add/open/remove`); only `worktree_remove`
   gains the archive-hook pre-step, which is empty unless a repo defines `cfg.archive`.
5. No state-file migration needed: `worktree-sessions`, `worktree-agent`, and
   `worktree.log` keep their exact formats; `workrex-ports` and `workrex-archives/`
   start empty.

---

## 12. Verification checklist

Prep: `mkdir -p $TMPD=/private/var/.../opencode/wrtest`; repo with
`.env`+`.env.local` gitignored, one failing-then-passing setup command, `.workrex.lua`
as in §2.1 (with `"pnpm install"` stubbed to `true` for speed in test).

1. `rex config check` clean; `rex keymap` shows all 8 worktree keys.
2. **add happy path:** `rex do worktree_add name=t1 agent=claude` → expect
   `gated=true, port=3100`; session `wrtest/t1` with windows nvim/setup/claude;
   `.workrex/env` has all 7 vars incl. `WORKREX_PORT=3100`; `status` ends as `0`.
   Verify copied `.env`, `git status --porcelain` does **not** list `.workrex/`.
3. **gate:** confirm the agent block stays at "waiting" until `status=0` appears, then
   shows the agent UI (claude recognized via prompt arg & seed prompt in transcript).
4. **failure:** make setup step 1 `exit 3`, rerun add for `t2` → setup tab shows
   `✖ SETUP FAILED: <step>`, agent block drops to a shell with the rerun hint;
   `worktree.log` got a line from the picker script if used.
5. **rerun:** fix `.workrex.lua`, `C-space shift+s` in t2's session (and
   `rex do worktree_setup name=t2` from another session) → new setup window streams;
   gate releases the waiting agent (t3 case).
6. **ports:** create t3 → base 3110; archive t1, run `worktree_gc`, create t4 →
   allocates 3100 if the gap fits, else 3120. Prove the allocator's gap logic by
   creating a size-20 repo (`ports = 20`) between two default ones.
7. **merge:** commit + run `C-space m` in t1's *sibling* session with default strategy →
   streamed transcript shows guards, merge, then the archive tail; session killed;
   worktree gone; meta file exists with `dirty=0`; branch still present.
8. **merge strategies:** `strategy=squash` (single squashed commit on target),
   `strategy=rebase` with a conflicting commit on target → popup says "resolve in
   <wt>…", target tree clean (`git -C target status` empty — abort path verified);
   `ignore_dirty=1` bypasses the dirty guard and warns.
9. **archive/restore:** archive `t2` (dirty guard first: expect the STOP message), then
   `force=1` → trash rename; `C-space shift+o` lists it with branch/base; restore
   recreates the worktree+session and reruns setup.
10. **rename:** `worktree_rename branch=wm/feat-1-renamed` → `git branch` updated;
    `branch.wm/feat-1-renamed.workrex-base` still holds the original base.
11. **regression:** repo without `.workrex.lua` → add behaves like today (plus instant
    env-copy step); `worktree_open` on a pre-migration worktree gives an ungated
    2-window session.
12. `chezmoi diff` shows only intended files.

---

## 13. Explicitly deferred (with reasons)

- **Sandbox / remote / Conductor Cloud, dashboards, agent-status hooks, PR flow,
  checks tab, checkpoints, multi-agent-layouts (`--foreach`/`--count`), nerdfont
  prefixes, tmux-window mode** — task constraint says defer; none affects the
  one-key-ready felt experience.
- **`worktree_open` auto-rerunning setup** — the user asked for deterministic add-time
  setup; auto-running on every open would fight "deps often just need to exist". Manual
  `shift+s` covers it.
- **Machine-local config overlay (`settings.local.toml` analog)** — v1 keeps one file;
  the repo itself can branch entries on `[ -d … ]`.
- **`git worktree add` moving into a pane for huge repos** — revisit only if a real repo
  blows the 20 s cap in practice.
- **Squash-merge `$EDITOR`** — plain `-m` message, amend later.
- **Port-conflict detection via `lsof`** — slow; allocator stays bookkeeping-only.
