# Workrex — workmux-faithful implementation spec (candidate 1)

Port the setup/lifecycle machinery of [workmux] and [Conductor] into Rex's worktree
sessions, extending `dot_config/rex/worktrees.lua`. Design stance: mirror workmux
semantics wherever Rex allows; where Rex cannot do a workmux thing, name the closest
honest replacement and verify it against the real CLI.

**Deferred explicitly**: sandboxing, remote hosts, dashboard/sidebar TUI, agent
status-hook integration (workmux `agent_setup/*`), conversation fork/continue,
`--foreach`/multi-worktree templating, PR checkout, layouts/pane-splitting.

---

## 0. Grounded facts (verified against the live Rex CLI on 2026-10-31)

These facts drive every design decision below. Each was verified, not assumed.

| # | Fact | Evidence |
|---|------|----------|
| F1 | **A window can be added to an *existing* session**: `rex window new -s SESSION [LABEL] [--focus=false] [-c DIR] [-- COMMAND...]` | `rex window new --help`; API `session.new_window` (`rex api describe`) → `{ session_id (required), window_label, layout, focus }` |
| F2 | `session.create` accepts `initial_windows: null/[]` — an **empty session can be created**, then windows added later | `rex api describe session.create`: `"initial_windows": {"type": ["null","array"], …} "If any of them fails, the server creates no session."` |
| F3 | Terminal block options have **no `env` field** (`additionalProperties: false`) — env injection must go through the command wrapper | `rex api call block_creator.list`, flavor `com.superlogical.terminal.shell` options schema: `shell, command, args(deprecated), login, cwd, path_prepend, size, theme, initial_input, exit` |
| F4 | Terminal blocks support `exit { on_completion, quick_exit_threshold_ms }`: close-on-exit by default, **stays open when the program fails quickly** (250 ms default) | same schema |
| F5 | Terminal blocks have `initial_input` (typed text) but no env; `path_prepend` prepends PATH | same schema |
| F6 | **Terminal blocks get the normal login-shell PATH** (block option `command` runs "through the shell [that] reads its startup files first, so the program is found on the PATH they set"); only `rex.exec` from an action has the minimal server PATH | `rex api describe session.new_block` + creator schema; matches AGENTS.md "Server-side PATH gotcha" |
| F7 | `rex wait TARGET` returns a terminal child's exit status (works with `--keep-open` blocks); bounded with `--for` | `rex wait --help` |
| F8 | `rex do` scripts can register **`rex.on` handlers and keep running as event subscribers** (`--all`, `rex.session.attach/detach`, `rex.stop`); but live `rex events -s <session> --json` streams *nothing* without session activity (a 3 s live capture saw a single `client_connected` event), and event names are not documented in CLI help | `rex do --help`; `rex events --help`; live capture test |
| F9 | `rex window ls -s SESSION [--json -q]` lists a session's windows (for duplicate/gate checks); `rex ls --json | jq -r '.sessions[].label'` already in use | `rex window ls --help`; worktrees.lua:633 |
| F10 | macOS has no standalone `flock` binary in the default install; `sh -c` is bash-3.2 (no `globstar`); `nohup` exists | platform knowledge, relevant to §3 lock and §5 file matching |
| F11 | Existing helpers to reuse verbatim: `run`/`run_ok` (worktrees.lua:41‑61), `repo_root` (:65‑71), `worktree_paths` (:73‑77), `valid_name` (:87‑89), `rex_bin` (:176‑206), `find_worktree_session` (:381‑401), `remember_session`/`forget_session` (:365‑377), `terminal_pane` (:117‑128), `context.popup` (context.lua:74‑91), `context.shell` (context.lua:8) | read of worktrees.lua / context.lua |

**Answering the stance question directly.** The prompt asks whether gating *forces* a
sentinel hack or whether Rex allows the workmux ordering "provision first, agent
window later". Verified verdict: **session-creation-time gating is not needed and
sentinels are not needed either.** Rex has both halves of workmux's ordering:

- `session.create` can start a session with `[nvim, setup]` only (F2 — even an empty
  session is possible), so provisioning starts before any agent pane exists;
- `rex window new -s <sid> --focus=false -- <agent>` (F1) adds the agent window
  **after** setup — and the cleanest watchdog is the setup process itself: the last
  line of the setup script creates the agent window when (and only when) setup
  succeeded. No polling, no daemon, no `rex.on` subscription (F8 shows the event
  surface is too sparse to trust for the primary path).

---

## 1. Files changed / added

```
dot_config/rex/
  init.lua                    # + require("workrex")  (one line added after require("worktrees"))
  context.lua                 # unchanged
  worktrees.lua               # EXTENDED in place (add/open/remove flows go through workrex, see §7)
  workrex.lua                 # NEW: config schema + loader + lifecycle helpers (pure Lua)
  workrex/
    setup.sh                  # NEW: the setup-window runtime script (hooks + setup + agent gate)
    fileops.sh                # NEW: copy/symlink executor (called per matched path by the action)
README.md                     # repo-root README: keymap table + Rex section updated
```

Rex pulls in modules with `require` relative to the config dir (AGENTS.md "extra
modules live beside it and are pulled in with `require(...)`"), so `worktrees.lua`
will `require("workrex")` at the top — no `init.lua` ordering issues; init.lua only
needs one added line (`require("worktrees")` stays as-is and worktrees.lua now also
loads workrex; safest is adding `require("workrex")` explicitly to init.lua after
line 204 so the module owns its actions even if worktrees.lua is reorganized).

Rationale for the two shell helpers: Lua has no glob, no copy-dir, no symlink
reasoning primitives worth hand-rolling; these run either inside the ≤30 s action
(`fileops.sh`, must finish fast) or inside a long-lived terminal block
(`setup.sh`, may take minutes, output visible — replaces Conductor's Setup tab).

---

## 2. Config schema (Conductor-style, committed per repo)

Config lives as **Lua**, matching the user's config idiom. Lua config also means the
repo config can contain small functions later without a format change.

### 2.1 Files & precedence (Conductor §2, workmux §3.1 analog)

1. Built-in defaults (`workrex.lua` `default_config` table).
2. **Global** user config, machine-level: `~/.config/rex/workrex.lua` (chezmoi-managed
   as `dot_config/rex/workrex.lua`; contains the user's personal defaults, e.g. custom
   agents are out of scope here). Searched, optional.
3. **Project** committed config: `<repo>/.workrex.lua` — the Conductor
   `.conductor/settings.toml` / workmux `.workmux.yaml` equivalent. Committed, runs
   for the whole team once merged.
4. **Local override** (never committed, gitignored by default on first create):
   `<repo>/.workrex.local.lua` (Conductor `settings.local.toml` analog).

`load_config(root)` merges in that order; later layers win per scalar; list fields
like workmux's `"<global>"` splice: a literal string entry `"<global>"` inside a
project list splices the global list at that position (string compare, then
flattening). Unknown keys are rejected with a precise error at load time
(`next(t)`-walk against a whitelist) so typos fail fast, Conductor-style.

### 2.2 Schema

```lua
-- .workrex.lua — committed per-repo Workrex config. Return one table.
return {
  -- creation ---------------------------------------------------------------
  base_branch      = nil,        -- nil = current branch at creation; or "origin/main"
  branch_prefix    = "wm/",      -- branch = prefix .. name   (existing behavior, worktrees.lua:76)
  worktree_dir     = nil,        -- nil keeps "<project>__worktrees/<name>" beside the repo
                                 -- (worktrees.lua:73-77). A v1 string value is interpreted as a plain
                                 -- directory name relative to the repo's parent (deviation from workmux's
                                 -- "<project>" template; noted as deferred in §11).

  -- files (Conductor "Files to copy" / workmux files:) -----------------------
  files = {
    copy    = {},               -- globs relative to repo root, copied into the worktree.
                                -- ONLY gitignored files are copied (Conductor semantics).
    symlink = {},               -- globs; copied as RELATIVE symlinks (only gitignored targets).
                                -- If both empty → default: symlink = { ".env*" } (task's default
                                -- gitignored .env* takeover). Adding any value disables the default
                                -- (same rule as Conductor's file_include_globs).
  },

  -- hooks --------------------------------------------------------------
  post_create = {},             -- workmux parity. FAST hooks; run at the top of the setup
                                -- window, with cwd = worktree dir. Fail hard → agent gated off.
  setup       = {},             -- Conductor setup. LONG commands (pnpm install, build …);
                                -- run after post_create in the same window.
  pre_merge   = {},             -- workmux pre_merge; extra env WORKREX_TARGET_BRANCH
  pre_remove  = {},             -- workmux pre_remove / Conductor scripts.archive (merged roles, see §6)

  -- env -----------------------------------------------------------------
  env            = {},          -- extra exports into every workrex window (strings; see §5.3)
  port_block     = 10,          -- workrex gives each worktree WORKREX_PORT..WORKREX_PORT+9
                                -- (Conductor CONDUCTOR_PORT). 0 disables allocation.

  -- merge / remove ------------------------------------------------------
  merge = { strategy = nil, keep = nil },  -- nil → CLI default wins ("merge", keep worktree).
                                           -- strategy: "merge"|"rebase"|"squash" (workmux merge_strategy)
  confirm_unmerged_removal = true,         -- workmux confirm_unmerged_removal (§6.2)

  -- server-side PATH workaround for hooks run FROM ACTIONS (not windows) -----
  hook_shell = nil,             -- nil = { os zsh -lic }, i.e. login interactive (workmux hook_shell analog)
}
```

Values interpolation: hook/setup/env strings may contain `{name}`, `{branch}`,
`{root}`, `{path}`, `{port}` — expanded by `expand(text, vars)` just before use
(workmux's `{project}` convention, reduced to the placeholders workrex has).

### 2.3 Loader notes (no hand-waving)

```lua
local function load_config(root)
  local cfg = deep_copy(default_config)                    -- workrex.lua
  for _, layer in ipairs({ global_path(), root .. "/.workrex.lua", root .. "/.workrex.local.lua" }) do
    local t = load_layer(layer)                            -- loadfile + setfenv sandbox + assert(table)
    if t then cfg = merge_config(cfg, t) end               -- scalars overwrite, lists splice "<global>"
  end
  validate(cfg)                                            -- unknown keys, bad strategy, non-string env values
  return cfg
end
```

- `load_layer` uses Lua 5.1 `loadfile(path, "t", env)` — actually `load` with a
  reader so we can set a custom `_ENV` table containing nothing: config files have
  no globals at all (`os`, `io`, `require`, even `_G` absent). They must end in
  `return { … }`; anything else errors. Loading is done inside `load_config` and
  hard-fails the action.
**A repo config cannot execute host code** (protects against hostile repos — the
same reason workmux makes `auto_name.command` global-only, workmux notes §3.3).
If the file errors: action aborts with `workrex: <path>: <error>` — hard failure,
like workmux (config errors abort, no silent default).
- Hygiene note: `.workrex.local.lua` is registered in `.git/info/exclude`
  (hosted in the repo, not the user's `.gitignore`) the first time it is loaded or
  created — the same way workmux registers `.workmux/` (workmux notes §1.3 step 16),
  so machine-local config never pollutes tracked files.

---

## 3. Lifecycle state — git config, workmux-style

`git config --local` against the repo's common dir (on a worktree checkout `git
config` writes the shared config — same storage workmux uses, its §6 cheat sheet
"state in `$XDG_STATE_HOME/workmux`" | "same git-config storage").
All lifecycle writes go through two helpers in `workrex.lua`:

```lua
set_meta(root, name, key, value)      -- git -C root config --local  workrex.worktree.<name>.<key> <value>
get_meta(root, name, key)             -- git -C root config --local --get …  (nodes: ↓)
clear_meta(root, name)                -- git -C root config --local --remove-section workrex.worktree.<name>
set_base (root, branch, base)         -- git -C root config --local branch.<branch>.workrex-base <base>
get_base (root, branch)               -- ↓ validated: must also be a local branch (`git show-ref --verify`)
```

Keys written (workmux parity, notes §4):

| key | when | meaning |
|-----|------|---------|
| `branch.<branch>.workrex-base` | **before** `git worktree add` (workmux §1.3 step 11) | merge-target default |
| `workrex.worktree.<name>.base` | same moment | base actually checked out (may differ, e.g. commit base) |
| `workrex.worktree.<name>.session-id` | after session.create | survives session rename (replaces the flat `worktree-sessions` file as primary; file kept as read-fallback — see §7 migration) |
| `workrex.worktree.<name>.setup` | `provisioning` → `running` → `ok` \| `failed` | agent-gating state |
| `workrex.worktree.<name>.agent` | on create/rerun | last agent spec (worktree_open preselect) |
| `workrex.worktree.<name>.ports` | after allocation | `"31472"` (first port; last = +port_block-1) |
| `workrex.worktree.<name>.created` | creation | ISO 8601 date string |

Locking: workmux serializes config writes with `GitConfigLock` (lock file
`<common>/.workmux.lock`, notes §1.3 step 10). Verified F10: macOS ships no
`flock` binary. **Closest honest replacement**: per-key `git config` writes are the
atomicity unit; workrex accepts the narrow single-writer race (two concurrent
`worktree_add` for the same *name* are already excluded by the session-exists
check, worktrees.lua:448) and documents it. No invented lock file.

---

## 4. Creation flow (`worktree_add`, ≤30 s action + long-lived setup window)

### 4.1 Algorithm with failure paths

```lua
rex.action { name = "worktree_add", …, args = { name = "string", agent = "string?",
                                                 base = "string?",   no_setup = "boolean?" } }
run = function(ctx, args)
  -- 1. validate name (valid_name, worktrees.lua:87) · require_root (:130)
  local cfg = load_config(root)
  -- 2. existing-session check  (as today, worktrees.lua:448-452)
  -- 3. resolve base: args.base > cfg.base_branch > current branch of ctx cwd
  -- 4. WRITE-BEFORE-CHECKOUT: set_base(root, branch, base)        -- workmux §1.3 step 11
  -- 5. git worktree add -b branch path base                       (run_ok, worktrees.lua:454 ff.)
  -- 6. set_meta(name, "base", base); set_meta(name, "created", os.date("!%Y-%m-%dT%H:%M:%SZ"))
  -- 7. FILE OPS  — one `git ls-files --others --ignored --exclude-standard` call +
  --    Lua-side glob match (§8.2), then fileops.sh invoked once per concrete path.
  --    fail → step 11* (rollback).
  -- 8. PORTS    — allocate_port_block(root, name, cfg.port_block) (§5.4) fail → continue with 0
  -- 9. ENV FILE — write <path>/.workrex/env  (§5.3) + `echo ".workrex/" >> <common>/info/exclude` (idempotent)
  -- 10. SESSION: create_session(root, name, path, spec) — but with initial_windows =
  --      { nvim window,  setup window }  (NO agent window)           -- replaces worktrees.lua:419-425
  --      setup window block options = { cwd = path,
  --          command = { "sh", "-c", 'exec sh "$@"', "workrex-setup",
  --                       setup_sh_path, name, branch, base, root, path,
  --                       session_id, cfg_file, agentname, agentcmd_argv… } }
  --      (plain `sh` is fine in blocks per F6: blocks run with the login PATH. The session_id is
  --       passed so the script can call `rex window new -s <sid>` itself at gate time.)
  --      setup window is the ACTIVE window; nvim is created but not focused.
  --      git config: set_meta(name, "setup", "running"), set_meta(name, "agent", spec)
  --      Rollback if session.create fails → step 11* plus remember_session(explicit NOT written)
  -- 11. (*) rollback: worktree remove --force, branch -D (as today :459-464) PLUS clear_meta + unset base
  -- 12. write_last_agent(spec); remember_session(path, created.session_id) +
  --      set_meta(name, "session-id", created.session_id)
  -- 13. return { name, worktree, branch, label, session_id, setup = "running" }
end
```

The action returns *before* setup finishes — that is the whole point. The action's
own runtime stays comfortably inside 30 s: the long command runs in a terminal
block that outlives the action (AGENTS.md: "long setup work belongs in a window,
not in the action").

### 4.2 `workrex/setup.sh` (the gate runtime; runs in the setup window block)

Receives argv: `name branch base root path session_id cfgfile agentname agentcmd`
(`cfgfile` is a shell-sourceable file written by the action via `serialize_cfg` —
hook lists, `pre_merge`/`pre_remove` inclusion flags, env file path, mode flags;
§8.1. `agentname`/`agentcmd` are the resolved agent label and argv).

```sh
#!/bin/sh
# workrex setup runtime — workmux provision_environment + Conductor setup, in one window.
set -u
name=$1 branch=$2 base=$3 root=$4 path=$5 sid=$6 cfgfile=$7 agentname=$8 agentcmd=$9
mark()  { git -C "$root" config --local "workrex.worktree.$name.setup" "$1"; }
say()   { printf '\033[36m[workrex]\033[0m %s\n' "$1"; }

# source the serialized, validated config (POSIX-sh arrays, no re-execution of repo strings)
# and the generated env file (§5.3; non-fatal if missing)
. "$cfgfile"
[ -r "$path/.workrex/env" ] && . "$path/.workrex/env"

fail() {  # VISIBLE failure: mark state, report, keep the window open (F4 protects quick
          # failures; the explicit `read -r` also holds the window for slow failures)
  mark failed
  printf '\033[31m[workrex] %s FAILED (see above)\033[0m\n' "$phase"
  printf 'Rerun with  C-space>e   or   rex do worktree_setup name=%s\n' "$name"
  read -r _ || true          # stay open; plain exit would close the window otherwise
  exit 1
}

#"post-create hooks" (fast, cwd = worktree dir, WORKREX_* env exported already)
phase="post-create hook"
cfg_run workrex_post || fail

# setup" (long, same window — the Conductor Setup tab)
phase="setup command"
cfg_run workrex_setup || fail

mark ok
say "provisioning agent window"
# THE GATE — workmux ordering in one call (verified F1: `rex window new -s` exists):
if rex window ls -s "$sid" --json | grep -q "\"$agentname\""; then
  say "agent window already present"
else
  rex window new -s "$sid" "$agentname" --focus=false -c "$path" -- \
    sh -c 'set -a; . "$1/.workrex/env" 2>/dev/null; set +a; shift; exec "$@"' \
    sh "$path" $agentcmd || fail       # agent cmd is the pre-resolved argv from Lua
fi
say "setup ok — agent gated in"
exit 0
```

(The `cfg_run` helper is spelled out in §8.1. Everything passed into setup.sh is
either generated by workrex itself or was validated at config load; the hook and
setup strings are the only repo-authored shell, executed exactly once and in the
visible window — the same trust model workmux applies to `post_create`. Workrex
restricts config entries to the line-oriented `sh -c` idiom used by worktrees.lua's
existing popups; no exotic quoting is transported.)

Failure-path properties:
- **Failure visible**: the block stays open (F4 quick-exit protection + explicit
  `read -r` hold), errors print in place. This is Conductor's Setup tab behavior.
- **Agent never starts on failure**: the window-new call sits below `fail` exits.
- **Setup state machine in git config**: `running → ok | failed`, consumed by
  `worktree_setup`/`worktree_merge`/`worktree_remove` (a merge refuses `running`).
- **Rerunnable**: `worktree_setup` (§4.3) closes the old setup window, reopens a new
  block with identical argv, sets `setup=running`.
- Block options include `exit = { on_completion = false }` so the output remains
  reviewable after success (compare workmux pane semantics: "pane stays open with
  a shell after the command completes", workmux notes §1.9). Closing is manual
  (C-space>x) — cheap and predictable.

### 4.3 `worktree_setup` (new action — rerun / resume)

```
args = { name = "string?" }   -- default: current worktree, resolved like worktree_open
- resolve root/path/branch/session via find_worktree_session (:381) + session exists check
- state = get_meta(setup); nothing to do if state == "ok" AND agent window present (F9 check) → return
- if a setup window exists in that session (label query) → close it (`rex window close -s … setup`? 
  verified CLI: `rex window close` exists — `rex window --help` line "close Close windows")
- open a NEW setup block (same argv as §4.1 step 10), session.new_window via
  rex.call("session.new_window", { session_id, window_label = "setup", focus = true, layout })
- set_meta(setup, "running"); return
```

`worktree_open` (existing) is extended: after `create_session`, if
`get_meta(setup) == "ok"` it adds the agent window immediately **with env wrapper**
(§5.2), otherwise creates the setup window and returns `setup = <state>` so the
user reruns with C-space>e. This keeps reopening a finished worktree instant
(workmux `open` re-runs nothing, notes §1.10).

---

## 5. Env injection & file ops (F3 constraint: no env field → wrappers)

### 5.1 `.workrex/` layout inside each worktree

```
<path>/.workrex/env        # export lines (generated, gitignored via .git/info/exclude exclude)
<path>/.workrex/           # workmux writes .workmux/ the same way (notes §1.3 step 16)
```

### 5.2 Window command wrapper (the only way to set env, verified F3)

Every workrex-created window that needs env (agent, setup, future dev panes) gets:

```
sh -c 'set -a; . "$1"; set +a; shift; exec "$@"' sh <env-file> <program-args…>
```

The Lua helper `env_block(path, label, program)` in workrex.lua emits the
`rex.layout.block` layout (mirroring `terminal_pane` at worktrees.lua:117‑128, but
wrapping command). Because blocks run under the login shell (F6), `path_prepend`
is unnecessary; `login` default true suffices.

### 5.3 Env file content (task requirement #4)

```
export WORKREX_WORKSPACE_PATH="$5"      # worktree path       (Conductor WORKSPACE_PATH)
export WORKREX_ROOT_PATH="$4"           # main checkout root  (Conductor ROOT_PATH/.env cp target)
export WORKREX_WORKSPACE_NAME="$1"      # handle              (Conductor WORKSPACE_NAME)
export WORKREX_BRANCH="$2"
export WORKREX_BASE_BRANCH="$3"
export WORKREX_PORT="31472"             # first of port_block  (Conductor CONDUCTOR_PORT)
export WORKREX_PORTS="31472:31481"      # convenient range for shell loops
export WORKREX_PORT_NEXT=0              # $((WORKREX_PORT + WORKREX_PORT_NEXT + 1)) idiom
# …plus cfg.env entries (values interpolated via expand(), §2.2)
```

Setup hooks, setup commands, agent windows, and future Run-actions all source
this, so hook scripts stay dumb.

### 5.4 Port allocation (no state file — deterministic-first-free)

Algorithm (all inside the action, ≤5 s):

| step | detail |
|------|--------|
| 1 | read `workrex.ports.next` from git config (store a *global* counter once per repo, default 31000) |
| 2 | candidate = next; test each of `port_block` ports with a single `sh -c` blocking probe loop using `/dev/tcp` (`exec 3<>/dev/tcp/127.0.0.1/$p` — no `nc`/`lsof` dependency); if ANY busy → candidate += port_block and retry (max 50 tries) |
| 3 | `git config --local workrex.ports.next` updated past the claimed block; `set_meta(name,"ports",candidate)` |
| 4 | ALSO tags the actual listeners: each setup command's env sees unique port so apps pick it; workrex never binds ports itself |

Cost: one shell spawn, <1 s. Release: on remove, the `ports` meta key is cleared;
the counter simply advances (no reclamation — deliberate, avoids reuse of a port a
lingering dev server still listens on). Collision-free within a repo by
construction; across repos, the /dev/tcp probe resolves conflicts.

**Honest gap vs workmux**: no cross-repo uniqueness guarantee for names. Two repos
on the same machine can both choose name `fix`; worktrees are repo-local so paths
disambiguate (…`projectA__worktrees/fix` vs `projectB__worktrees/fix`); sessions
labels are `<project>/<name>` so they are unique too (worktrees.lua:83‑85). No
change needed.

---

## 6. Merge / remove / archive

### 6.1 `worktree_merge` (new action; workmux §1.9, notes §2)

`args = { name = "string?", into = "string?", strategy = "string?", allow_dirty = "boolean?", keep = "boolean?", squash_message = "string?" }`

```
1. resolve: name → worktree path via `git -C root worktree list --porcelain` walk
   (no registry needed — same smart resolution order workmux uses: handle then branch);
   refuse if path == main root (workmux §2 step 3).
2. target branch:  args.into > get_base(branch) (validated local branch)
                   > detected default branch (`git symbolic-ref refs/remotes/origin/HEAD`
                     trimmed, else master|main heuristic — workmux §3.3 "detected default branch").
   (Fallback auto-backfill: if branch.<b>.workrex-base is MISSING — a pre-Workrex worktree —
    merge still works via the fallbacks; this *is* the migration story, §7.)
3. guards (workmux §2 steps 7-8, all in the source worktree):
   dirty unstaged/untracked → error mentioning `allow_dirty` flag
   (workmux's --ignore-uncommitted) unless allow_dirty
   staged changes → auto-commit `git commit -m "workrex: stage before merge of <name>"`
     (workmux opens GIT_EDITOR — impossible from an action (no TTY); closest honest
      replacement is an auto-commit with a clear message, noted in rationale; users who want
      review pass keep=false first)
   target worktree has tracked changes → error (untracked allowed)
   branch == target → error
4. setup state check: `get_meta(setup)` must be "ok"/"failed"; `running`→error "wait for setup or rerun".
5. pre_merge hooks: run in worktree dir, via cfg hook_shell (login shell, since ACTION context —
   worktrees.lua's `run_ok` passes through rex.exec's minimal-PATH; so hooks are launched
   with argv `{ login_shell(), "-lic", cmd }` — the same pattern as installed_agent_names
   at worktrees.lua:247‑251). env: WORKREX_* + `WORKREX_TARGET_BRANCH=<target>`.
   any hook failing → abort merge, error includes the hook output (run_ok raises it).
6. strategy dispatch in the TARGET worktree for merge/squash; IN SOURCE for rebase:
   a. merge (default): `git -C target merge branch`
      conflict → `git -C target merge --abort` → error "Conflict. Resolve in <path>, rerun."
        (workmux MergeConflict; retry = same action for the merge step).
   b. rebase: `git -C src rebase target` — conflicts left IN PROGRESS (workmux leaves the
      user in the resolution state, notes §2.11) → error "Resolve in <path>, rerun merge".
      on success → `git -C target merge branch` (expected fast-forward, workmux §2.11).
      after rebase ALSO refresh base: set_base(root, branch, target) (workmux `set-base` command).
   c. squash: `git -C target merge --squash branch`; on conflict → `git -C target reset --hard`
        + error. Then EITHER (args.squash_message given) commit with it in the action, OR
        open a context.popup floating layer (context.lua:74) running an interactive
        `git commit` — the popup's tail script, after the commit exits, executes the
        cleanup chain (§6.4) itself, then calls `rex do worktree_merge_finish name=… `, then
        closes everything, so the user is not watching a dead popup. This keeps workmux's
        "editor for the squash message" behavior alive in Rex.
7. cleanup (shared `wrex_cleanup`, §6.4): kill source session (:547-553 `rex kill`),
   quarantine+prune+branch-delete chain (§6.2.5), clear meta. Wrap the cleanup in
   `pcall` and return `cleanup_error` separately — workmux §2 invariant: "merge
   SUCCEEDS even when cleanup fails". Return `{ merged = true, target = …, cleanup_error = … }`.
```

### 6.2 `worktree_remove` (rewrite / archive) — args `{ name = "string?", force = "boolean?", delete_branch = "boolean?" }`

```
1. refuse if session is current (`existing.session_id == ctx.session_id`, :543) — unchanged.
2. pre_remove hooks: launched from ACTION → login shell (as §6.1.5). Default injection
   (workmux): if cfg.pre_remove empty AND a Node lockfile found in the worktree
   (pnpm-lock.yaml|package-lock.json|yarn.lock) → run cleanup_node_modules first:
   `mv <node_modules> "$(mktemp -d)/node_modules" && nohup rm -rf "$TMP/node_modules" &`
   — the same trick as workmux's NODE_MODULES_CLEANUP_SCRIPT (notes §1.8): the mv keeps the
   action inside its budget, the background rm usually survives the action's end (F10's
   nohup). If the background rm dies, a stale temp dir remains — acceptable, documented.
3. session kill via `rex_bin()` kill (:547-553) — but DEFERRED when the kill would take out
   a session a picker popup currently lives in (fatal conflict 409; AGENTS.md notes
   cross-session teardown restrictions). Replacement for workmux's deferred-cleanup worker:
   spawn `nohup sh -c 'sleep 2; exec <bin> kill <sid>' >/dev/null 2>&1 &` from within the
   action, returning immediately. Concretely only triggered from worktree_remove_prompt;
   the direct action keeps today's refuse behavior (:543-545).
4. tear down hooks run BEFORE (§6.2.2), since the worktree directory still has to exist
   for the pre_remove cwd (workmux: "pre_remove runs in the live worktree dir before
   deletion").
5. session id cleanly detached from the mapping: forget_session(path) (:371-377) +
   clear_meta(name, "session-id").
6. QUARANTINE (workmux §2.8.2): `mv <path> "<parent>/.workrex-trash-<pid>-<name>"` then
   `git worktree prune` — then `rm -rf trash` UNLESS branch-delete was refused:
   only when args.delete_branch, `git branch -d branch` (merged-only, same as today :565).
   If `-d` refuses (unmerged commits) and cfg.confirm_unmerged_removal → KEEP the trash
   dir at its sibling path, error naming it as the rescue location; otherwise rm -rf trash.
   (Why quarantine: `git worktree remove --force` fails when a process holds cwd inside
   the worktree; the rename sidesteps EBUSY and keeps those processes alive in a renamed
   dir — workmux's rationale, notes §2.8.2.)
7. clear_meta — remove the workrex.worktree.<name> section (+ workrex-base line stays,
   it is branch history and a merge-restart target).
```

Note the divergence from today's design (worktrees.lua:555‑560 uses plain
`git worktree remove`): quarantine is strictly more robust and satisfies the
task's "safe cleanup" and documentable as one paragraph in the code comment.

### 6.3 `worktree_archive`? — NO separate action. Conductor's archive script ("clean up
resources outlawed outside the worktree that setup created") is pre_remove. Keeping
one hook avoids a second entrypoint with the same body; the only archived-only
Conductor feature (History restore) would require a transcript store — deferred.

### 6.4 `worktree_merge_finish` (hidden-ish helper for the squash popup chain)

args `{ name = "string?" }`: performs steps 7-end of §6.1 (kill, quarantine etc.)
Identical core callable from popup scripts and from direct action use; extracted
into a shared function `wrex_cleanup(root, name, opts)` in workrex.lua used by all
three actions — no duplication.

---

## 7. Migration from current worktrees.lua

| today | becomes |
|---|---|
| `create_session` builds `nvim` + agent windows (:415‑430) | `create_session` builds `nvim` + `setup` (agent comes later: §4.1) |
| state = `~/.local/state/rex/worktree-sessions` flat file | git-config primary; file kept as *read* fallback inside `find_worktree_session` (existing :381 logic + one `get_meta` dereference); every write path updates BOTH |
| base branch = `args.base or HEAD` (:455) | args.base > cfg.base_branch > cwd branch; recorded BEFORE worktree add via `workrex-base` key |
| no setup/hook concept | §4 flow |
| `worktree_add name=foo agent=pi` CLI still works | yes, args identical; arg `no_setup=true` skips creating the setup window entirely — the escape hatch for repos whose config is empty |
| writing error log to `~/.local/state/rex/worktree.log` from pickers | unchanged |

Backfill: existing worktrees have no git-config keys. All reads use fallbacks
(base detection chain §6.1.2; session via flat file), and any successful add/open
on them writes the git-config keys. So migration is "lazy" and destructive migrations
are not needed. `worktrees.lua` file header comment updated to document it
(README table too, per AGENTS.md "If modifying keymaps, update both … README").

`chezmoi apply ~/.config/rex` + `rex config reload` picks up everything (Rex does
not watch files; AGENTS.md).

---

## 8. Concrete code (the two non-obvious pieces, for reviewers)

### 8.1 workrex.lua `serialize_cfg` ↔ setup.sh `cfg_run` protocol

Lua side (action, before block creation):

```lua
local function shq(s)  -- POSIX quote
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function serialize_cfg(cfg, log_file)
    local out = { 'workrex_post=()', 'workrex_setup=()' }
    local function push_list(key, list)
        out[#out+1] = key .. "=()"
        for _, cmd in ipairs(list) do out[#out+1] = shq(cmd) end
        out[#out+1] = ")"
    end
    push_list('workrex_post', cfg.post_create)
    push_list('workrex_setup', cfg.setup)
    out[#out+1] = 'workrex_log=' .. shq(log_file)
    return table.concat(out, "\n")
end
```

setup.sh executes each:

```sh
cfg_run() { # $1=arrname
  eval "set -- \${$1[@]}" || return 1   # ${arr[@]} in POSIX sh (bash-3.2 sh mode OK)
  local i=1 rc
  for cmd in "$@"; do
      rc=0; sh -c "$cmd" || rc=$?
      [ $rc -eq 0 ] || return $rc
      i=$((i+1))
  done
}
# usage:  cfg_run workrex_post || fail "post_create hook failed"
```

(The arrays are pre-populated by `eval "$(cat "$8")"` where `$8 = script path to the
serialized config` — written to `<state>/workrex-cfg-<name>` to avoid ARGV length
limits; this is how the shell receives the *safe, validated* config from Lua.)

### 8.2 fileops.sh (fast — target ≤5 s total, runs inside the action)

The action enumerates candidates in Lua (one `git ls-files` call + `match_glob`),
then calls fileops.sh once per matched path:

```sh
#!/bin/sh
# workrex fileops — copy or symlink one concrete path <src> into <dst>.
# usage: fileops.sh copy    <src> <dst>
#        fileops.sh symlink <src> <dst> <rel_target>   # rel_target precomputed in Lua
# No shell globbing here (macOS bash-3.2 sh lacks it, F10) — every path is concrete.
mode=$1 src=$2 dst=$3 rel_target=$4
case "$mode" in
  copy)
    mkdir -p "$(dirname "$dst")"
    [ -e "$dst" ] && exit 0        # idempotent, never overwrite
    cp -pR "$src" "$dst"           # directories recurse, like workmux copy_dir_recursive
    ;;
  symlink)
    [ -e "$src" ] || exit 0
    [ -e "$dst" ] && exit 0        # idempotent, never overwrite
    ln -s "$rel_target" "$dst"     # RELATIVE link (workmux: pathdiff::diff_paths)
    ;;
esac
```

`relpath` (Lua-computed and passed in as `$5`, keeping sh dumb) — Lua-side
`relative(from, to)` util: tokenization on `/`, drop common prefix count of `..`
segments; workmux does exactly this with `pathdiff::diff_paths` (notes §1.8).

Gitignore filtering lives on the Lua side, one `rex.exec`:

```lua
-- candidates = ALL gitignored non-tracked files (Conductor: "only for files git already ignores; never copies tracked files")
local out = run_ok({ "git", "-C", root, "ls-files", "--others", "--ignored",
                     "--exclude-standard" }, { timeout = 15 })
-- pot-line cap: 40 000; warn+abort beyond (documented: a heavy repo should list explicit globs)
for line in out.stdout:gmatch("[^\n]+") do
    if match_glob(line, pattern) then emit_copy_or_link(line) end
end
```

`match_glob` in Lua: translate `*`→`[^/]*`, `**`→`.*`, `?`→`.`, escape regex
metachars, anchored — deterministic, no shell glob dependency (F10).

---

## 9. Action / CLI / keymap surface

| Surface | args | key | purpose |
|---|---|---|---|
| `worktree_add` (modified) | name, agent?, base?, no_setup? | `ctrl+space>w` (via existing prompt) | §4 |
| `worktree_setup` (new)  | name? | `ctrl+space>e` + picker `worktree_setup_prompt` | rerun/first-launch the setup window (pick across known worktrees with a setup state per worktree, appended to the picker's label from git config) |
| `worktree_merge` (new)  | name?, into?, strategy?, allow_dirty?, keep?, squash_message? | `ctrl+space>m` + pickers `worktree_merge_prompt` (fzf over `git worktree list` worktrees + branch into that list), no squash editor step needed — popup handles it inline if strategy == squash |
| `worktree_remove` (modified) | name, force?, delete_branch? | `ctrl+space>W` (existing prompt) | §6.2 |
| `worktree_merge_finish` | name? | (no key; popups + result JSON) | §6.4 / squash-chain |

Consistent with existing picker style (fzf + `rex do -s "$session"`; worktrees.lua
:594‑617 pattern; failures append to LOG_FILE and stay on screen until Enter).

New keybindings live in workrex.lua itself (it is a full config module, same pattern
as worktrees.lua's tail binds at :711‑713):

```lua
rex.bind("ctrl+space>m", "worktree_merge_prompt")
rex.bind("ctrl+space>e", "worktree_setup_prompt")
```

`m` and `e` are free in the current prefix map (checked init.lua:19‑164: splits/tabs/
sessions/pane/popup/rename/reload all taken; `m`, `e`, `s` free). `e` was chosen over
`s` for the setup mnemonic; no default tmux muscle-memory conflicts.

---

## 10. Verification checklist (one session each, in order)

1. `chezmoi apply ~/.config/rex && rex config check && rex config reload`
   → no errors, `rex keymap` shows `ctrl+space>m`, `ctrl+space>e`, `w/o/W` unchanged.
2. `rex actions | grep worktree` → `worktree_add`, `worktree_setup`, `worktree_merge`,
   `worktree_merge_finish`, `worktree_remove` (all listed).
3. Read-only pins: `rex api call block_creator.list | grep path_prepend`,
   `rex api describe session.new_window | grep focus` — schema assumptions still hold
   (defends against Rex updates changing the option shape).
4. Setup gating E2E in a scratch repo:
   - `cd ~/code/playground-scratch && rex do worktree_add name=test-setup --json`
   - `git -C . config --local branch.wm/test-setup.workrex-base` → prints the base branch.
   - watch the setup window: `running` → `ok`; then `rex window ls -s <sid>` shows the
     agent window; inside that block, `echo $WORKREX_PORT` (typed by the user) prints the
     allocated port.
   - failure path: scratch repo with `setup = { "false" }` in `.workrex.lua` →
     setup window prints `[workrex] setup command FAILED`, stays open,
     `git config --local workrex.worktree.test-fail.setup` → `failed`,
     `rex window ls -s <sid>` shows NO agent window.
   - rerun: `rex do worktree_setup name=test-fail` → fresh setup block; agent window
     appears only if the rerun succeeds.
5. File ops: scratch repo with a gitignored `.env` and `.env.local`, empty `files` rules
   → after add, `ls -la <worktree>` shows `.env` and `.env.local` as symlinks whose
   `readlink` output is a relative path pointing back into the main checkout.
6. Merge:
   - happy path: commit on branch, `rex do worktree_merge name=test-setup --json` →
     `merged = true`, session killed, quarantine dir cleaned up, worktree removed
     (branch kept unless `delete_branch=true`; the base key stays for history).
   - conflict path: create a conflicting commit on the base first → target reported as
     `merge --abort`ed with a resolve-and-rerun message; worktree and branch survive.
   - squash path with `squash_message` set: commit happens inline in the action; with the
     flag unset: popup opens an interactive `git commit`, and after the editor closes the
     same chain cleans up WITHOUT further user action.
   - rebase path: conflict → error names the worktree and the rerun command; after
     `git rebase --continue`, a second rerun succeeds and `workrex-base` is refreshed.
7. Ports: `worktree_add name=port-a` then `name=port-b` in the same repo →
   `workrex.worktree.port-a.ports=` (first block), `port-b.ports=` = first+10 (or next free block).
   Confirm with `nc -z 127.0.0.1 31472` while dev server listens on `$WORKREX_PORT+2`.
8. Remove: `rex do worktree_remove name=port-a --json` → quarantined + pruned, ports key
   cleared, flat-file entry gone, branch still exists (delete_branch default false).
9. `chezmoi diff` → only intended new/changed files; no drift.
10. README.md updated (worktree keymap rows: `C-space w/e/o/m/W` and the config pointer to
    `.workrex.lua`) and kept in sync with the Lua sources per AGENTS.md.

---

## 11. Explicitly deferred (surfaced per task instructions)

| workmux / Conductor feature | verdict |
|---|---|
| Sandbox (Docker/Lima), remote hosts (`workmux remote/*`, Conductor Cloud) | out of scope |
| Dashboard / sidebar TUIs, nerdfont status bar | out of scope (Rex needs a pane; revisit later) |
| Agent status hooks (`agent_setup/*`, `set-window-status`, AgentState store) | out of scope — Rex's OSC 7501 `program_status` (visible in `rex api list`) is the natural future hook, not designed here |
| `--fork`/`--continue` conversation forking, prompt templates, `--foreach` multi-spec | out of scope |
| PR checkout (`--pr`), gh/glab wiring | out of scope |
| Repo config templates/serialisation of layout (`panes`/`windows`/`layouts`) | workrex v1 keeps the fixed nvim+setup windows; a `windows =` key is reserved but unimplemented |
| `sync-files` re-apply action | v2 (fileops.sh is built to be re-invokable, so it is trivial to add) |
| Deferred cleanup *worker process* (setsid) | partially replaced by the nohup'd kill (§6.2.3); full worker not needed |

---

## 12. Effort / risk summary

- Biggest risks: (a) `session.create` with an initial setup window racing ahead of its
  own config writes — mitigated because `set_meta(setup, "running")` is written by the
  action before session.create, and setup.sh re-marks on every phase; (b) POSIX-sh
  array eval in bash-3.2 — handled in §8.1 with `eval "set -- \${arr[@]}"` (works in
  bash 3.2 and dash); (c) gated agent needs the login PATH — blocks have it (F6), the
  agent cmd resolution happens in the ACTION (worktrees.lua's `agent_command`, :104‑115),
  so nothing depends on setup.sh resolving PATH.
