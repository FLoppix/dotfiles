# workmux Core Workflow — Implementation Notes for Reimplementation in Rex

Source analyzed: `/private/var/folders/wb/xrqy4t111gs50qzgzxd_0by80000gn/T/opencode/workmux`
(workmux by raine — "Parallel development in tmux with git worktrees").

Registry of all exact identifiers below. Key files:

| File (relative to repo root) | Role |
|---|---|
| `src/main.rs` / `src/cli.rs` | Entry point + clap CLI dispatch (`Commands::Add`, `Commands::Merge`, …) |
| `src/command/add.rs` (1588 lines) | `workmux add` orchestration (specs, prompts, auto-name, multi) |
| `src/workflow/create.rs` | `create()`, `create_headless()`, `create_with_changes()` — git worktree creation + metadata |
| `src/workflow/setup.rs` | `provision_environment()`, `setup_environment()`, `write_prompt_file()`, `resolve_pane_configuration()` |
| `src/workflow/file_ops.rs` | `handle_file_operations` (copy/symlink from `files` config) |
| `src/workflow/context.rs` | `WorkflowContext` |
| `src/workflow/merge.rs` / `src/command/merge.rs` | `workmux merge` flow |
| `src/workflow/cleanup.rs` (1109 lines) | `cleanup()`, quarantine, deferred cleanup worker |
| `src/workflow/open.rs`, `remove.rs`, `rename.rs` | open existing worktree / remove / rename |
| `src/config.rs` (7806 lines) | `Config` struct (schema), discovery, merge, defaults |
| `src/naming.rs` | `derive_handle()` |
| `src/state/{mod,store,types}.rs` | Agent status state store (`$XDG_STATE_HOME/workmux/`) |
| `src/frozen_config.rs` | Config snapshot for sandboxed child processes |
| `src/template.rs` | minijinja worktree spec generation (foreach/count/agents) |
| `src/creation_time.rs` | Filesystem birth time for worktree age (`list`) |
| `src/xdg.rs` | XDG path helpers |
| `src/git/worktree.rs`, `src/git/branch.rs` | git-config-backed metadata storage |

---

## 1. `workmux add` — full flow

### 1.1 CLI surface (from `src/cli.rs`, `Commands::Add { … }`)

Flags: `branch_name` (positional), `--pr`, `--forge (github|gitlab)`, `--auto-name`,
`--base`, `--name`, `--target-name`, `--parent-session`, `--prompt/-p`, `--prompt-file/-P`,
`--prompt-editor/-e`, prompt-file-only mode (`prompt_file_only`), `SetupFlags`
(`--no-hooks`, `--no-file-ops`, `--no-pane-cmds`, `--background`, `--open-if-exists`,
`--sandbox`), `RescueArgs` (`--with-changes/-w`, `--patch`, `--include-untracked`),
`--agent/-a`, `--count`, `--foreach`, `--max-concurrent`, `--branch-template`, `--layout/-l`,
`--continue/-c`, `--fork[=session-id]`, `--wait`, `--mode (window|session)`, `--session`,
`--dry-run`, `--headless`, `--json`, `--config <path>`, `--remote [name]`, `--local`.

### 1.2 Entry sequencing (function `run()` in `src/main.rs` + `command/add.rs::run`)

1. `logger::init()`, then `cli::run()`.
2. Dispatch `_deferred-cleanup` hidden command before anything else if present.
3. Early config load (`Config::load_with_override(None, config_override)`) — used only by
   "side effects": nerdfont wizard, agent-status-tracking wizard, `update::check_and_notify`.
4. `command::add::run(...)` for `Commands::Add`.

Inside `command::add::run`:

1. **Remote/sandbox routing**: if inside sandbox guest or remote node session → `run_add_via_rpc`.
   If `--remote` resolved (`command::add::check_placement`) → most local options are refused.
2. **`--headless`** → `run_headless()` (no mux state; provision only; prints
   `HeadlessReceipt { schema_version: 1, handle, branch, worktree_path, working_directory,
   base_branch, post_create_hooks_run }`).
3. `check_preconditions()` — requires git repo AND running mux (tmux/zellij/kitty/wezterm).
4. Config loaded via `Config::load_with_location(agent, config_override)`; `--layout`
   replaces `config.panes` with `config.layouts[name].panes` (`resolve_layout`, sets
   `config.windows = None`).
5. Build `SetupOptions::new(run_hooks = !no_hooks, run_file_ops = !no_file_ops,
   run_pane_commands = !no_pane_cmds)` then extras:
   `focus_window = !background`, `open_if_exists`, `mode` (from `--mode`/`--session`/
   `Config.mode`, default `MuxMode::Window`), `resume_mode` (Continue when `--continue`).
6. Stdin lines read via `read_stdin_lines()` (poll + 10MB cap); JSON lines become template vars.
7. **Auto-name**: prompt is loaded first (`-p/-P/-e` or $EDITOR); for single worktree the branch
   name is generated NOW via `llm::generate_branch_name()` (spinner feedback, respects
   `config.auto_name.{command,model,system_prompt}`); for multi worktree it is deferred and
   generated inside the per-spec loop from the rendered prompt.
8. `--pr` resolves via `workflow::pr::PrReference::resolve()` to `(checkout_ref, base_branch,
   local_branch, remote_branch)`; that ref is fetched (`git::fetch_refspec_in`) with fallback to
   fetching the raw head branch.
9. Remote-branch detection (`workflow::pr::detect_remote_branch`) turns `origin/foo` into
   `{ remote_branch: "origin/foo", template_base_name: "foo" }`.
10. `determine_foreach_matrix()` — priority: CLI `--foreach` > stdin > prompt frontmatter
    `foreach`. Conflicts error out.
11. **Worktree specs**: `template::generate_worktree_specs(base_name, &multi.agent,
    multi.count, foreach_rows, &env, branch_template)` — minijinja env with `slugify` filter,
    context `{ base_name, agent, num, index, foreach_vars, input, … }`, reserved keys
    `["base_name","agent","num","index","foreach_vars"]`. For every spec:
    `render_prompt_body(doc.body, env, spec.template_context)` when templating is enabled and
    `validate_template_variables()` BEFORE creating anything.
12. Loop over specs (with `--max-concurrent` polling at 250ms against live windows/sessions):
    a. `Config::load_with_location(spec.agent, override)` per spec (agent-specific config).
    b. `crate::naming::derive_handle(branch, explicit_name, config)`.
    c. `workflow::create(&ctx, CreateArgs { … })`.
    d. Announce `HookPhase::PostCreate` hooks unless quiet.

### 1.3 `workflow::create()` (`src/workflow/create.rs::create_impl`) — exact order

1. If `panes` and `windows` both set in config → error (they're mutually exclusive).
2. `windows` requires `MuxMode::Session` (validate via `validate_windows_config`).
3. `ensure_mux_running()`; **session mode is tmux-only**.
4. Window-mode placement resolved once: `setup::resolve_window_placement_target(mux,
   config)` → dispatches to `mux.resolve_window_placement_target(config.window_placement())`
   (`WindowPlacement::AfterCurrent` default / `Rightmost`).
5. Target existence checks:
   - `target = MuxHandle::new(mux, mode, prefix, primary_target_name)`; `primary_mux_target_name`
     comes from `options.target_window_name`/`target_session_name`, else the handle.
   - If target exists and NO worktree exists and no explicit `--name`: **auto-suffix** via
     `suffix_taken_handle()` → `project_suffixed_handle()` = `format!("{handle}-{project_slug}")`
     (slug of the main worktree dir name); prints warning to stderr.
   - `--open-if-exists` → delegates to `workflow::open::open()` with hooks/file-ops disabled.
   - Target exists otherwise → error suggesting `--name/--target-name`.
6. `git::worktree_exists_in(branch)` → error if the branch already has a worktree (suggests
   `workmux open`).
7. Branch auto-detection: `create_new = !branch_exists`. If creating new and no `--base`
   and no `config.base_branch` → base = current branch of execution dir (`--base` may also be a
   commit/tag; errors on detached HEAD without base).
8. Remote branches: fetched before checkout (`track_upstream = true` when remote branch).
9. `base_dir = context.worktree_base_dir()`; `worktree_path = base_dir.join(current_handle)`.
   Path collision handling:
   - Registered worktree at path → error.
   - Path contains `.git` but unregistered → error ("corrupted metadata … data loss").
   - Otherwise **orphan dir**: `fs::remove_dir_all(worktree_path)` (leftover from rename-based
     cleanup; recreated by watchers with stale `$PWD`).
10. **Exclusive lock** `git::GitConfigLock::acquire(&context.git_common_dir)` — serializes
    `.git/config` writes across concurrent `workmux add` processes (lock file `.workmux.lock`
    inside the common git dir).
11. **Store review base BEFORE checkout**: `git::set_branch_base_in(branch, base)` writes
    `git config --local branch.<branch>.workmux-base <base>` (see §6).
12. `git::create_worktree_in(worktree_path, branch_name, create_new, base_branch_for_creation,
    track_upstream, Some(execution_dir))` — `git worktree add … [-b <branch>] [--track]`.
13. Metadata written (still under lock) via `git::set_worktree_meta_in(handle, key, value)`:
    - non-headless: `workmux.worktree.<handle>.mode` = `"window"|"session"`;
      `.attachment` = `"multiplexer"`;
      `.target-window` when `--target-name` (window mode);
      `.target-session` when `--target-name` (session mode);
      `.window-session` when `--parent-session`;
      window-mode + backend with `supports_window_ownership()` →
      `workmux.worktree.<handle>.window-token` = random 16-byte hex token
      (`ensure_worktree_window_token_in`) plus `primary_window = true`.
    - headless: `.attachment` = `"headless"` only.
14. Drop config lock.
15. `--fork`: fork agent conversation AFTER worktree exists, BEFORE setup; sets
    `options.resume_mode = ResumeMode::ForkSession(session_id)`.
16. Write prompt file: `setup::write_prompt_file(Some(worktree_path), branch, prompt)`
    → `<worktree>/.workmux/PROMPT-<branch-slug>.md` (slashes/colons → dashes), plus appending
    `.workmux/` to `.git/info/exclude` (resolves worktree gitdir correctly).
    `prompt_file_only` → file written but NOT passed to setup.
17. `working_dir`: if nested config (`config_rel_dir` non-empty, e.g. `backend/`) →
    `worktree_path.join(rel_dir)` if it exists, else worktree root.
18. Delegates to `setup::setup_environment(...)` for file ops, hooks, and the mux target.
19. Result struct `CreateResult { worktree_path, branch_name, post_create_hooks_run,
    base_branch (comparison_base = PR target for review checkouts), did_switch,
    resolved_handle, mux_target_full_name, mode }`.

**Error handling / rollback**: any failure in headless mode or setup runs
`cleanup::cleanup_headless()` with `force=true, keep_branch=!create_new, no_hooks=true` and
repackages the error, surfacing rollback failure separately.

### 1.4 `create_with_changes()` (`--with-changes` rescue flow)

1. Changes captured from CWD worktree; error if nothing to move.
2. `git::stash_push("workmux: moving changes to <branch>", include_untracked, patch)`.
3. `create()` — on failure pops the stash back into the original worktree.
4. `git::stash_pop(new_worktree)` — success → `git::reset_hard(original)` (clean original);
   failure → `cleanup::cleanup(force, keep_branch=false)` of the new worktree +
   `navigate_to_target_and_close(...)`, error message says changes remain in `stash@{0}`.

### 1.5 `setup::provision_environment()` (shared by attached and headless creation)

Order inside:
1. `effective_working_dir = options.working_dir.unwrap_or(worktree_path)`.
2. `file_ops_source = options.config_root.unwrap_or(project_root)`.
3. **File operations FIRST** (only if `options.run_file_ops`):
   `handle_file_operations(file_ops_source, effective_working_dir, &config.files)` +
   `symlink_claude_local_md(file_ops_source, effective_working_dir)`.
4. **`post_create` hooks SECOND** (before any mux window is created!) via
   `cmd::shell_command_with_env_mode(config.hook_shell, command, effective_working_dir, hook_env,
   hook_output)` executed sequentially; hook env vars:
   ```text
   WORKMUX_HANDLE=<handle>
   WM_HANDLE=<handle>
   WM_WORKTREE_PATH=<canonical worktree path>
   WM_PROJECT_ROOT=<canonical main worktree root>
   WM_CONFIG_DIR=<canonical working dir (config subdir in worktree)>
   ```
   `hook_shell` is an argv vector; the hook command is appended as the final argument.
   Default `["bash", "-c"]`.
Returns `ProvisionedEnvironment { working_directory, post_create_hooks_run }`.

### 1.6 `setup::setup_environment()` — window/pane creation

1. `prefix = config.window_prefix()` (default `"wm-"`, or a nerdfont glyph).
2. Call `provision_environment()` (per §1.5).
3. `window_plans: Vec<WindowConfig>` — from `config.windows` (session mode only) or wrap
   `config.panes` in one unnamed window.
4. `resolve_pane_configuration(panes, config, agent)`: with an agent selected, injects
   `<agent>` into a pane that has NO explicit command (preferring the `focus: true` pane; else
   the first commandless pane; else creates one pane); explicit commands (nvim, dev servers,
   known agent commands like `claude --flags`) are never overwritten.
5. If a prompt file is provided: `validate_prompt_consumption(panes, agent, config, options)`
   — errors if pane commands are disabled or no pane runs the configured agent
   (`pane_runs_agent`: `<agent>`, `<agent:...>`, known agents, or matching command string).
6. `pre_boot_lima_vm()` when sandbox=lima and any pane needs sandboxing — boots VM before the
   window so boot progress is visible; returns the VM name for pane wrappers.
7. Mux target:
   - `mux_target_full_name = prefixed(prefix, target_window_name|handle)` for window mode,
     `prefixed(prefix, target_session_name|handle)` for session mode.
   - Window mode: `mux.create_window(CreateWindowParams { prefix, name, cwd, after_window })`
     — `after_window` is either CLI placement (beside current/rightmost) or
     `resolve_window_placement_target()`. If `--parent-session` given →
     `create_window_in_parent_session(...)` instead.
     Then `mux.set_window_ownership(pane_id, window_token, primary_window)` if a token exists.
   - Session mode (tmux only): first window `mux.create_session(CreateSessionParams { prefix,
     name, cwd, initial_window_name })`, subsequent `mux.create_window_in_session
     (CreateWindowInSessionParams { session_name, name, cwd })`.
   - Per window: `mux.setup_panes(initial_pane_id, panes, cwd, PaneSetupOptions {
     run_commands: options.run_pane_commands, prompt_file_path, worktree_root, lima_vm_name,
     resume_mode, … }, config, agent)` — splits panes per `split`/`size`/`percentage`/`target`,
     returns `PaneSetupResult { focus_pane_id, zoom_pane_id }`.
8. Focus: `options.focus_window` → window mode: `mux.select_pane(focus)` +
   `mux.select_window(prefix, name)` (skipped when created inside a parent session); session
   mode: `mux.switch_to_pane(focus_pane_id, None)`.
9. `mux.zoom_pane(zoom_id)` when a pane had `zoom: true`.

### 1.7 State tracking for `add`

- Git config keys (see §6) written at creation: `mode`, `attachment`,
  `target-window`/`target-session`, `window-session`, `window-token`, plus
  `branch.<name>.workmux-base`.
- Prompt file on disk + `.git/info/exclude` entry.
- `--wait`: CLI blocks until windows/sessions close
  (`mux.wait_until_windows_closed(&targets)` / `wait_until_session_closed`).
- No database for add — everything is git config + the mux server's own state.

### 1.8 Config schema (from `src/config.rs::Config`, all setup-relevant fields)

```yaml
# basic
main_branch: Option<String>        # merge target; auto-detected if unset
base_branch: Option<String>        # also accepts "auto"
worktree_dir: Option<String>       # relative or absolute; supports ~ and {project}
window_prefix: Option<String>      # default "wm-"; supports {project}
mode: Option<window|session>       # MuxMode
default_session: Option<String>    # return target when a managed session closes
window_placement: Option<after_current|rightmost>
agent: Option<String>              # e.g. "claude"; default resolved to "claude"
agents: BTreeMap<String, AgentEntry>  # { command?, type?, args: [..], env: {KEY: val|from_env: KEY} }
placement: Option<String>          # "local" or a remote name

# naming
worktree_naming: full|basename     # WorktreeNaming (full default)
worktree_prefix: Option<String>

# layout
panes: Option<Vec<PaneConfig>>
windows: Option<Vec<WindowConfig { name, panes }>>   # session mode only
layouts: Option<HashMap<String, LayoutConfig { panes }>>

# --- lifecycle/setup fields ---
hook_shell: Option<Vec<String>>          # argv; default ["bash","-c"]; hook cmd appended as last arg
post_create: Option<Vec<String>>         # after worktree created, BEFORE window opens
pre_merge: Option<Vec<String>>           # before merging; extra env WM_BRANCH_NAME, WM_TARGET_BRANCH
pre_remove: Option<Vec<String>>          # before removing worktree
files: FileConfig { copy: Option<Vec<String>>, symlink: Option<Vec<String>> }   # glob patterns
remote_files: FileConfig                 # same shape, for remote workspaces
merge_strategy: Option<merge|rebase|squash>
merge_keep: Option<bool>
confirm_unmerged_removal: Option<bool>   # default true
auto_name: { command, model, system_prompt, background: Option<bool> }
prompt_file_only: Option<bool>
status_format/status_icons/nerdfont/theme/dashboard/sidebar/sandbox/remotes …  # UI-only
```

Semantics worth copying:
- `post_create` runs with `cwd = working dir in the new worktree` (nested config dir honored),
  BEFORE any mux window exists. `pre_merge` also runs in the source worktree dir; `pre_remove`
  runs in the live worktree dir before deletion.
- Hooks fail hard (abort the operation) unless `--no-hooks`/`--no-verify` (merge).
- `files.copy` / `files.symlink` are glob patterns relative to the **config source dir**
  (main worktree root or nested config dir); traversal beyond repo root (`..`) is rejected
  (`validate_path_within_repo`). Symlinks are made RELATIVE (`pathdiff::diff_paths`) — this is
  how `node_modules` symlink patterns work. Directories are copied recursively
  (`copy_dir_recursive`: preserves symlinks as links, skips sockets/FIFOs, merges dirs).
- Extra auto behavior: `symlink_claude_local_md()` — symlinks the main worktree's
  `CLAUDE.local.md` into the worktree only when the file is gitignored
  (`git::is_path_ignored`) and the destination doesn't exist.
- Default `pre_remove` for Node repos: if `config.pre_remove` is None and the repo (or any
  depth-1 subdir) has `pnpm-lock.yaml`/`package-lock.json`/`yarn.lock` (`has_node_lockfile`,
  `NODE_LOCKFILES`), workmux injects `NODE_MODULES_CLEANUP_SCRIPT` (bundled
  `src/scripts/cleanup_node_modules.sh`: moves every `node_modules` into a `mktemp -d` trash,
  `nohup rm -rf` on it in the background). Project-defined `pre_remove` REPLACES it; the
  literal placeholder `"<cleanup-node-modules>"` (`CLEANUP_NODE_MODULES_PLACEHOLDER`)
  re-expands to the script.
- List-merge with `"<global>"`: project lists (`post_create`, `pre_merge`, `pre_remove`,
  `files.copy`, `files.symlink`) may contain the literal `"<global>"` to splice global config
  items at that position.
- Default panes when none configured:
  `[{ command: <agent if CLAUDE.md exists or agent configured>, focus: true },
    { command: "clear", split: horizontal }]` (`default_panes` / `agent_default_panes`).

### 1.9 Dev server handling

There is **no dedicated dev-server field**. A dev server is just a pane:

```yaml
panes:
  - command: nvim
    focus: true
  - command: pnpm install && pnpm run dev
    split: vertical
    size: 15
```

- The pane stays open with a shell after the command exits (`PaneConfig.command` semantics:
  "The pane will remain open with an interactive shell after the command completes").
- Each worktree gets its OWN dev server instance in its own window; nothing is shared or
  reattached between worktrees. Reopening (`workmux open <handle>`) switches to the EXISTING
  window (`open()` early-returns `target.select()` when the target exists and
  `!new_window`), so the pane and its process are left intact.
- `workmux sync-files [--all]` re-runs `handle_file_operations` for an existing worktree
  (source always the MAIN worktree, monorepo subdir honored).

### 1.10 `workmux open` (reattachment, `src/workflow/open.rs`)

- `workflow::open::open(name, context, options, new_window, mode_override, prompt_file_only,
  agent)`; name resolves via `git::find_worktree_in` (handle first, then branch name).
- Mode precedence: CLI `--mode` > stored `workmux.worktree.<handle>.mode` >
  `options.mode` (config default).
- Mode conversion (window↔session) kills the prior window/session first (token-aware via
  `resolve_owned_window_targets` or by name regex `^{prefix}{handle}(-\d+)?$`).
- If the target exists and not `--new`: backfill missing metadata, focus, return early
  (no hooks/files re-run).
- `--new` in window mode only; picks suffix `-2`, `-3`, … via `resolve_unique_handle()`
  (session mode rejects `--new`).
- On creating a new target: writes prompt file if `prompt_file_only`, then the same
  `setup::setup_environment()`, then `set_worktree_attachment_in(handle, Multiplexer)`.
- Metadata backfilled/persisted on open: `mode`, `target-window`, `target-session`,
  `window-session`, `window-token` (all inside git config).

---

## 2. `workmux merge` — full flow

CLI (`src/command/merge.rs`): `workmux merge [name] [--into <branch>] [--rebase] [--squash]
[--ignore-uncommitted] [--keep] [--cleanup] [--no-verify] [--no-hooks] [--notify]`.
- `--keep` and `--cleanup` are mutually exclusive.
- `effective_keep = if cleanup { false } else { keep || config.merge_keep }`.
- Default strategy: CLI flags win; otherwise `config.merge_strategy`
  (`MergeStrategy::Merge|Rebase|Squash`) is applied.
- `command::resolve_name(name)` — argument or the CURRENT cwd's worktree.
- Announces `HookPhase::PreMerge` and `HookPhase::PreRemove` before running.

`workflow::merge()` (`src/workflow/merge.rs`) sequence:

1. `context.chdir_to_main_worktree()` FIRST
   (the deleting path may be the process CWD — avoids EBUSY on getcwd).
2. `(worktree_path, branch_to_merge) = git::find_worktree(name)` — smart
   resolution: worktree handle, then branch name (fails with "use workmux list").
3. Abort if source worktree IS the main worktree
   ("Create a linked worktree first").
4. `handle = worktree_path.file_name()` (mux operations use this).
   Capture mode + attachment BEFORE cleanup:
   - `get_worktree_mode(handle)` (from git config),
   - `get_worktree_attachment_in(handle)` — cleanup only touches mux if
     `attachment.manages_mux()`.
5. **Target branch resolution** (in priority order):
   1. `--into <branch>` if given, else
   2. stored base branch: `git::get_branch_base(branch_to_merge)` reads
      `branch.<name>.workmux-base`; falls back silently if invalid/not a LOCAL branch,
   3. `context.main_branch` (config `main_branch`, or detected default branch).
6. **Find target worktree**: `git::get_worktree_path(target_branch)`.
   - Target checked out anywhere → merge there (supports the case where `main` is itself a
     linked worktree — issue #29). Window name = branch name if in the main root, else the
     worktree dir handle.
   - Not checked out anywhere → use `main_worktree_root`.
7. **Conflict checks on the source worktree** (skipped under `--keep` since data survives):
   - unstaged changes & untracked files → hard error unless `--ignore-uncommitted`.
   - **Staged changes**: committed automatically with `git::commit_with_editor(worktree)`
     (opens GIT's editor) unless `--ignore-uncommitted`.
   - `branch_to_merge == target_branch` → cannot merge into itself.
8. **Conflict check on the target worktree**: `git::has_tracked_changes(target)` → hard error
   ("Please commit or stash"). Untracked is allowed (git will fail safely on collisions).
9. Explicitly checkout the target branch in the target worktree:
   `git::switch_branch_in_worktree(target_worktree_path, target_branch)`.
10. **`pre_merge` hooks** run in the SOURCE worktree dir after all validations and before
    the merge, with env `WORKMUX_HANDLE, WM_HANDLE, WM_BRANCH_NAME, WM_TARGET_BRANCH,
    WM_WORKTREE_PATH, WM_PROJECT_ROOT`; skipped with `--no-verify`/`--no-hooks`.
11. **Merge strategies** (three, default is a plain merge commit, NOT squash):
    - `--rebase`: `git::rebase_branch_onto_base(source, target)` IN THE SOURCE WORKTREE —
      conflicts abort with a `MergeConflict` error object telling the user to resolve there
      and re-run. After a successful rebase, the target merge is expected to be a
      **fast-forward**: `git::merge_in_worktree(target, branch)`.
    - `--squash`: `git::merge_squash_in_worktree(target, branch)` (stages only) — on failure
      `git::reset_hard(target)`; then `git::commit_with_editor(target)` for the squashed
      commit message.
    - default (merge commit): `git::merge_in_worktree(target, branch)`; failure →
      `git::abort_merge_in_worktree(target)` and `MergeConflict`.
    - `MergeConflict(String)` is downcast by callers (e.g. sidebar/dashboard code) to
      distinguish "user must resolve" from other errors; message suggests
      `workmux merge <branch>` retry command.
12. Desktop notification `show_notification("Merged '<src>' into '<tgt>'")` before cleanup
    (cleanup may kill the window this process lives in).
13. `--keep` → return early with `cleanup_scheduled = false`.
14. Cleanup: `cleanup::cleanup(context, branch, handle, worktree_path, CleanupOptions {
    force: true, keep_branch: false, no_hooks, show_hook_output: true })`, then
    `navigate_to_target_and_close(mux, prefix, target_window_name, handle, result, mode,
    default_session)` ONLY if `attachment.manages_mux()`.

`CleanupResult { tmux_window_killed, source_target_is_active, source_target_to_close,
deferred_cleanup }`; `MergeResult { branch_merged, main_branch, had_staged_changes,
cleanup_scheduled, cleanup_error }` — merge SUCCEEDS even when cleanup fails (returns
cleanup_error which the CLI prints as partial failure).

### 2.1 Cleanup order inside `cleanup::cleanup_impl` (shared with remove)

1. Refuse if the worktree IS the main worktree.
2. `capture_worktree_identity()` — record `(device, inode)` of the directory plus
   `git::RepositoryIdentity { worktree, admin_dir, common_dir, dot_git }`, verifying
   `common_dir` matches the context's. (TOCTOU protection: cleanup must never act on a
   path that got rebound to a different directory/repo.)
3. Headless/non-mux-attached worktrees: cd to main worktree, run `pre_remove` hooks +
   `cleanup_prompt_files()`, then destructive cleanup, done (no mux interaction).
4. Otherwise: resolve per-handle `mode`, `target_name`
   (`target-session`/`target-window` metadata, default handle), `parent_session`
   (`window-session`), `window_token`; `chdir_to_main_worktree()`.
5. Check `is_inside_matching_target(...)` (does THIS process run inside the target window /
   session or one of its duplicates `{prefix}{handle}-{N}`?).
6. **Case A: running inside the target**
   - kill all OTHER matching duplicate windows (not the current one) — duplicates exist only
     in window mode;
   - record the source target in `source_target_to_close`;
   - hooks + prompt-file cleanup (`prepare_destructive_cleanup`);
   - schedule `DeferredCleanup { worktree_path, branch_name, handle, keep_branch, force,
     expected_identity }` and spawn a detached worker process
     (`workmux _deferred-cleanup --worktree-path … --branch-name … --handle … --device ...
     --inode ... --expected-worktree --admin-dir --common-dir --dot-git --source-mode
     (window|session) --source-name [--source-id] [--keep-branch] [--force]` with `setsid`
     so it survives the terminal dying). Worker: polls up to
     `DEFERRED_TARGET_CLOSE_TIMEOUT` (5s) for the source target to actually close, then runs
     `perform_destructive_cleanup`. Failures recorded by
     `logger::record_deferred_cleanup_failure` (under `$XDG_STATE_HOME/workmux`).
   - Reason: killing the pane whose shell is THIS process would kill the cleanup itself.
7. **Case B: not inside the target**
   - kill first: session mode kills the session (`poll_bounded` waits up to 20×50ms);
     window mode kills every matching window.
   - THEN `prepare_destructive_cleanup()` (pre_remove hooks run AFTER the window is gone so
     hook processes can't keep the target alive), then `perform_fs_git_cleanup()`.
8. `perform_destructive_cleanup(path, quarantine_identity, branch, handle, keep_branch, force,
   git_common_dir)`:
   1. (linked worktree) remove `locked` file from the worktree's admin dir if present.
   2. **Quarantine rename**: `mv <worktree_path> ../.workmux_trash_<dir>_<pid>_<nonce>`
      (identity re-validated immediately before renaming: same dev/inode + same repository
      identity). Renaming frees the path while processes with that CWD keep working in the
      quarantined dir.
   3. `git::prune_worktrees_in(git_common_dir)` — git prunes the now-stale registration.
   4. If `!keep_branch`: `git::delete_branch_in(branch, force, common_dir)` — the CLI offers
      an "unmerged commits" confirmation first when `confirm_unmerged_removal` (default true).
   5. `git::remove_worktree_meta_at(handle, common_dir)` — removes the whole
      `workmux.worktree.<handle>` config section.
   9. `pending.remove()` — deletes the quarantined directory if identity still matches
      (`cleanup_retry::PendingCleanup`).
9. `navigate_to_target_and_close`: if the user was inside the killed target, move focus to the
   target branch's window/session (or `default_session`) and close the source target
   (`schedule_window_close` with `WINDOW_CLOSE_DELAY_MS = 300`, a tmux deferred script).

---

## 3. Config file discovery (`src/config.rs`)

### 3.1 Files & precedence

- **Global**: `xdg::config_dir()/config.yaml` or `config.yml`, i.e.
  `$XDG_CONFIG_HOME/workmux/config.yaml` (default `~/.config/workmux/config.yaml`);
  legacy fallback for reading if XDG_CONFIG_HOME is custom (per `global_config_path()`).
- **Project**: `.workmux.yaml` / `.workmux.yml`.
- **`--config <path>` override** (add/open only): must be a file; `rel_dir` intentionally
  empty so panes open at worktree root.
- **Frozen**: env `WORKMUX_FROZEN_CONFIG` (`frozen_config::FROZEN_CONFIG_ENV`) points at a
  serialized `{ version, config, selected_agent, agent_type, location }` JSON snapshot
  (created for sandbox guest children, file mode 0600, must be regular file/no-symlink,
  `version` field enforced); mutually exclusive with `--config`.

### 3.2 Project discovery (`discover_project_config` / `find_project_config`)

- Walks up from CWD to the worktree root (stops at repo root), checking both names in
  each dir — nearest-first (monorepo nesting).
- If inside a LINKED worktree and nothing is found there, falls back to the MAIN worktree
  root's config files.
- Returns `ConfigLocation { config_path, config_dir, rel_dir }` where `rel_dir` is relative
  from repo root ("backend" for `backend/.workmux.yaml`).
- `rel_dir` / `config_dir` feed `WorkflowContext.config_rel_dir` / `config_source_dir`;
  from them: pane `working_dir` (worktree_path + rel_dir if it exists), file-op source dir,
  `WM_CONFIG_DIR` hook env var.

### 3.3 Merge & defaults (`merge_and_apply_defaults`)

1. Load global (`load_global()`), then project (or defaults).
2. Merge: project wins for scalar fields; maps (`layouts`, `agents`) merge per-key (project
   extends); list fields support the `"<global>"` splice; `auto_name.command` is
   GLOBAL-ONLY (security: a project config may not choose the command generating branch
   names); `remotes`/`agents` are global-only; sandbox `env_passthrough`/`excluded_files`
   from project config are rejected/ignored with warnings.
3. Agent resolution: `cli -a/--agent` > project `agent` > global `agent` > `"claude"`;
   name looked up in the merged `agents` map (`AgentEntry { command, type, args, env }`),
   producing `config.agent` (full command) + `config.agent_type` (profile type).
4. Defaults applied against `defaults_root` (config dir if under repo root, else repo root):
   - `panes` unset → agent default (CLAUDE.md present or explicit agent) or plain default +
     `clear` split pane.
   - `pre_remove` unset and Node lockfile found → node_modules cleanup script.
   - `hook_shell` unset → `["bash", "-c"]`.
   - `window_prefix` containing `{project}` is expanded against the main worktree so every
     worktree of the repo resolves the same prefix.
5. Validation: `validate_panes_config` (first pane has no split/size; every later pane has a
   split; size XOR percentage; one zoom max; `target` < index), `validate_windows_config`,
   `validate_hook_shell`, `validate_sidebar_views`, sandbox network/container validation.
6. `Config::init()` (command `workmux init`) writes a starter project `.workmux.yaml`.
7. Template rendering of config: config files are NOT templated; only `{project}` in
   `window_prefix`/`worktree_dir` (`util::expand_worktree_dir`) gets substitution.

---

## 4. State management (`src/state/`)

**Who uses it:** the agent status tracking system (dashboard, sidebar, reap, last-done) —
NOT the add/merge lifecycle. Worktree lifecycle state is stored in git config (below).

- `StateStore::new()` → base `get_state_dir()` = `$XDG_STATE_HOME/workmux/`
  (default `~/.local/state/workmux/`, via `xdg::state_dir()`), with subdirs:
  - `agents/` — one JSON file per agent pane:
    filename `{backend}__{instance}__{pane_id}.json` (`PaneKey::to_filename`; instance/pane
    percent-encoded; `PaneKey { backend, instance, pane_id }`).
  - `settings.json` — `GlobalSettings { sort_mode, hide_stale, preview_size, last_pane_id,
    dashboard_scope, worktree_sort_mode, last_done_cycle { target, head_ts }, sidebar_layout,
    sidebar_width, sidebar_height, sidebar_filter, sidebar_group_by, sidebar_hint_* }`.
  - `runtime/{backend}__{instance}.json` — `RuntimeState { interrupted_pane_ids,
    updated_ts }`, produced by the sidebar daemon for the dashboard process.
- Record `AgentState { pane_key, workdir, status (working|waiting|done), status_ts,
  activity_ts, pane_title, pane_pid (tmux shell PID, used to detect pane reuse), command,
  updated_ts, window_name, session_name, boot_id (tmux server start time),
  agent_kind (classified once), agent_session_id (hook-bound), prompt (single line),
  remote: Option<RemoteRef> }`.
- Writes are merge-with-existing best-effort (`persist_agent_update` etc.), under a lock file
  (`store.with_agent_lock`); a reaping process deletes stale entries
  (`command::reap_agents` with `stale_after_secs` / default 1 hour).
- Why filesystem: works across backends (tmux, zellij, kitty, wezterm) where pane queries are
  weak; enables cross-process dashboard/daemon sharing.

**Worktree lifecycle state in git config** (`git config --local`, i.e. `<common_dir>/config`):

| Key | Meaning |
|---|---|
| `branch.<branch>.workmux-base` | base branch/commit the branch was created from (also the merge-target default); recorded before worktree creation |
| `workmux.worktree.<handle>.mode` | `window` \| `session` |
| `workmux.worktree.<handle>.attachment` | `multiplexer` \| `headless` |
| `workmux.worktree.<handle>.target-window` | explicit tmux window name (`--target-name`) |
| `workmux.worktree.<handle>.target-session` | explicit session name |
| `workmux.worktree.<handle>.window-session` | parent session for window mode (`--parent-session`) |
| `workmux.worktree.<handle>.window-token` | 32-hex random token binding window identity (lookup by token instead of fuzzy name match) |

Helpers: `set_worktree_meta_in`, `get_worktree_meta_in`, `get_worktree_mode_opt_in`,
`get_all_worktree_modes_in` (batch `config --local --get-regexp r"^workmux\.worktree\..*\.mode$"`),
`remove_worktree_meta_at` (removes the whole section). Rename migrates keys
(`workmux.worktree.<old>.*` → `<new>.*`). `GitConfigLock` = lock file
`<git_common_dir>/.workmux.lock`.

---

## 5. Worktree directory naming and placement

- Default directory: `<projects_parent>/<project_name>__worktrees/<handle>` where
  `project_name` = basename of the main worktree root
  (`context::worktree_base_dir()`).
  Overridable by `worktree_dir` (relative or absolute; `~` and `{project}` expanded via
  `util::expand_worktree_dir`). The worktree directory name is the **handle**, not the branch.
- **Handle** (`src/naming.rs::derive_handle`):
  1. explicit `--name` wins (slugified, bypasses everything),
  2. otherwise `config.worktree_naming` (`full` = branch with `/`→`-`; `basename` = last
     `/` segment) then optional `config.worktree_prefix`, then `slugify()`.
  - Validated: non-empty, no `..`, no leading `/`, no whitespace.
- Mux target name = handle by default; overridden by `--target-name` (persisted as
  `target-window`/`target-session`); full target is `{window_prefix}{target_name}`
  (`util::prefixed`). Collision handling: `project_suffixed_handle()` →
  `{handle}-{project_slug}`, or duplicate numbering `-2`, `-3` in `open --new`.
- **Branch name** = the text the user passed to `add` (or an auto-generated kebab-case slug
  from the prompt via `llm::generate_branch_name`, prompt piped to `llm` or a custom
  `auto_name.command`); `--branch-template` templating for multi-worktree specs
  (`generate_worktree_specs`).

---

## 6. Misc interesting pieces

- **`frozen_config.rs`**: serialization of a resolved `Config` (including agent env/secrets)
  into a 0600 tempfile for children that cannot rediscover config (sandbox guests / RPC host
  commands). Env var `FROZEN_CONFIG_ENV = "WORKMUX_FROZEN_CONFIG"`.
- **`creation_time.rs`**: `filesystem_birth_time(path)` — Linux `statx(BTIME)` via rustix,
  otherwise `metadata().created()`; used by `workflow/list.rs` for the age column only.
- **`template.rs`**: minijinja env (`AutoEscape::None`, trailing newline kept, `slugify`
  filter); reserved foreach keys; single-spec branch names pass through unchanged (templating
  only kicks in for multi-worktree).
- **Deferred cleanup worker**: `workmux _deferred-cleanup` hidden command; setsid-detached
  child; 5s timeout; the only path that survives "I deleted my own window".
- **Quarantine naming**: `.workmux_trash_<dir>_<pid>_<nonce>` sibling of the worktree.

### Rex mapping cheat sheet

| workmux concept | likely Rex analogue |
|---|---|
| tmux window per handle, `wm-<handle>` | Rex session per worktree (`<project>/<name>`) |
| `workmux.worktree.<handle>.*` git-config keys | Rex `~/.local/state/rex/worktree-sessions` file, or same git-config storage |
| `wm-` window prefix / `{project}` placeholder | Rex session label prefix |
| `post_create`/`pre_remove`/`pre_merge` hooks + `WM_*` env | same with `REX_*`-style env if desired |
| `files.copy`/`files.symlink` relative symlinks | same |
| node_modules `pre_remove` default + `"<cleanup-node-modules>"` | same script idea |
| `worktree_dir` default `<project>__worktrees` sibling | Rex worktrees inside the repo (different convention — see `dot_config/rex/worktrees.lua`) |
| open-if-exists / duplicate numbering `-2` | `worktree_open` picker |
| deferred cleanup worker (setsid) | cleanup after agent window closes |
| state in `$XDG_STATE_HOME/workmux/` | Rex `~/.local/state/rex/` |
