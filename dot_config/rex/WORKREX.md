# Workrex

Workmux-style git worktrees inside Rex. Each worktree gets its own session with an editor, an agent, and a per-repo setup step that must finish before the agent starts.

## Requirements

- Rex with the config in this repository applied.
- `git`.
- `fzf` for the pickers.
- `jq` for the picker and window bookkeeping.
- At least one agent CLI on your `PATH`. The shipped list is `pi`, `claude`, `codex`, `opencode`, and `amp`.

## Install

```sh
chezmoi apply ~/.config/rex
rex config check
rex config reload
```

`rex config reload` is required. Rex does not watch the config file.

## Keys

| Key | Action |
|---|---|
| `C-space + w` | New worktree session. Pick an agent, type a name. |
| `C-space + o` | Open an existing worktree. Shows its setup state. |
| `C-space + m` | Merge a worktree and clean up. Pick the worktree, then the strategy. |
| `C-space + s` | Rerun setup in the current worktree. |
| `C-space + W` | Remove a worktree. |
| `C-space + f` | Switch sessions, one session per worktree. |
| `C-space + ]` / `[` | Next or previous session. |

## First run

1. In a repository, press `C-space + w`.
2. Pick an agent with the arrow keys and press Enter.
3. Type a name such as `login-fix` and press Enter.
4. Switch to the new session with `C-space + f` if Rex does not focus it.
5. If the repository has a `.workrex.lua`, the `setup` window streams its steps. The agent window opens only after every step succeeds.

Worktrees live beside the repository in `<project>__worktrees/<name>`. Branches are `wm/<name>`.

## Per-repo config

Commit a `.workrex.lua` at the repository root. Every field is optional. Without the file, a new worktree gets the default `.env*` copy and no setup step.

```lua
return {
  -- Branch to create new worktrees from. Defaults to the current branch.
  base = "origin/main",
  branch_prefix = "wm/",

  -- Copy gitignored files from the main checkout, and link paths back to it.
  -- Relative links keep working when the parent directory moves.
  files = {
    copy = { ".env*", "config/local.json" },
    symlink = { "node_modules" },
  },

  -- Fast hooks, then long steps. Both run in the setup window, with output.
  post_create = { "pnpm run codegen" },
  setup = { "pnpm install" },

  -- Run in the source worktree before merging.
  pre_merge = { "pnpm typecheck" },

  -- Run in the live worktree before removal. Keep it short.
  pre_remove = { "rm -rf ../cache/$WORKREX_WORKSPACE_NAME" },

  -- Extra exports for every window. Secrets belong in .workrex.local.lua.
  env = { APP_ENV = "development" },

  -- WORKREX_PORT .. WORKREX_PORT + 9. Set 0 to disable.
  port_block = 10,

  merge = { strategy = "merge" }, -- merge, rebase, or squash
}
```

Adding any `files` rule replaces the default `.env*` rule. Re-add `.env*` yourself if you still want it.

`setup` and `post_create` run in the `setup` window with a retry prompt. The agent window opens only after every step succeeds. `C-space + s` reruns setup in a fresh window.

For machine-local overrides, create `.workrex.local.lua` next to the committed file. Workrex adds it to `.git/info/exclude` automatically.

### Environment

Every worktree gets a generated `.workrex/env` file, sourced by the editor, setup, and agent windows. Source it yourself in a shell you open later.

| Variable | Value |
|---|---|
| `WORKREX_WORKSPACE_PATH` | Worktree path. |
| `WORKREX_ROOT_PATH` | Main checkout path. |
| `WORKREX_WORKSPACE_NAME` | Worktree name. |
| `WORKREX_BRANCH` | Branch, `wm/<name>`. |
| `WORKREX_BASE_BRANCH` | Branch the worktree was created from. |
| `WORKREX_PORT` | First port of the block. `0` in the file means allocation was disabled. |
| `WORKREX_PORTS` | `START:END` of the block. |

## Command line

Every action works from the CLI. Pass `cwd=` when you run it outside a Rex pane.

```sh
# Create and open
rex do worktree_add name=login-fix agent=claude cwd="$PWD"
rex do worktree_add name=login-fix base=origin/main no_setup=true

# Open, rerun setup, heal
rex do worktree_open name=login-fix cwd="$PWD"
rex do workrex_setup name=login-fix cwd="$PWD"
rex do workrex_fix name=login-fix cwd="$PWD"

# Merge and remove
rex do worktree_merge name=login-fix cwd="$PWD"
rex do worktree_merge name=login-fix strategy=squash keep=true
rex do worktree_remove name=login-fix cwd="$PWD"
rex do worktree_remove name=login-fix force=true
```

## How it works

- One git worktree per session, named `<project>/<name>`.
- Setup state lives in git config, `workrex.worktree."<name>".setup`, and moves `running`, then `ok` or `failed`.
- The base branch is recorded in git config before the checkout, so a merge knows its target even after a restart.
- `worktree_merge` refuses a dirty source, a dirty target, a running setup, and a merge from inside the worktree's own session. It runs hooks and the merge in a popup, then removes the worktree. A merged branch is deleted. An unmerged branch is kept.
- `worktree_remove` refuses uncommitted changes and a running setup unless you pass `force=true`. It renames the directory aside, prunes the git registration, and deletes the directory in the background.
- `workrex_fix` handles the three stuck states. A running setup with no setup window, an `ok` state with no agent window, and a stale session entry.

## Troubleshooting

**The agent window never appeared.** Look at the `setup` window in that session. A failure prints the failing command and stays open with a retry prompt. `C-space + s` starts a fresh run.

**The setup window was closed mid-run.** The state stays `running`. `rex do worktree_open name=<n>` reports `"abandoned":true`. Run `C-space + s` or `workrex_fix` to reopen it.

**Merge refuses with "uncommitted changes".** Commit them, or pass `allow_dirty=true`. Gitignored files such as `.env` do not count.

**Merge refuses with "setup is still running".** Finish or rerun setup first.

**Remove refuses.** Commit or pass `force=true`. A running setup also needs `force=true`.

**Ports collide with another process.** The allocator probes each port before it hands out a block. It never reuses a released block. Start the other process on a port outside `WORKREX_PORT..WORKREX_PORT+9`.

**Something looks inconsistent.** Run `rex do workrex_fix name=<n>`. It prints what it healed.

## Test it

`tests/workrex-smoke.sh` drives the real Rex server against a scratch repository.

```sh
./tests/workrex-smoke.sh reset   # rebuild the scratch repo
./tests/workrex-smoke.sh p3      # one phase
./tests/workrex-smoke.sh all     # every phase
```

The last full run passed 61 checks with 0 failures.

## Limits

- Sandboxed agents, remote hosts, a dashboard, and agent status hooks are not implemented.
- A repository whose `git worktree add` takes longer than 20 seconds reports the git error.
- The setup window is a plain terminal. A closed window leaves the `running` state until you heal it.
