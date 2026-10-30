# AGENTS.md

> Agent-focused context for the dotfiles repository. For human-readable docs, see [README.md](./README.md).

## Project Overview

- **Type**: Personal dotfiles / system configuration
- **Management**: [chezmoi](https://www.chezmoi.io/) — declarative dotfile manager
- **Contents**: Neovim IDE setup, tmux and Rex configuration, install script
- **Remote**: `git@github.com:FLoppix/dotfiles.git`

## Repository Layout

```
.
├── dot_config/
│   ├── nvim/                → ~/.config/nvim (Neovim config)
│   │   ├── init.lua           → Entry point
│   │   ├── lua/keymaps.lua    → Key mappings
│   │   ├── lua/options.lua    → Editor settings
│   │   ├── lua/colorschema.lua → Theme setup
│   │   ├── lua/pack.lua       → Plugin manager (lazy.nvim)
│   │   ├── lua/commands.lua   → Custom commands
│   │   └── lua/plugins/       → Plugin configs
│   │       ├── lsp.lua
│   │       ├── telescope.lua
│   │       ├── neo-tree.lua
│   │       ├── lualine.lua
│   │       ├── treesitter.lua
│   │       ├── diagnostic.lua
│   │       ├── code-actions.lua
│   │       ├── whichkey.lua
│   │       └── mini.lua
│   ├── tmux/
│   │   └── tmux.conf        → ~/.config/tmux/tmux.conf (tmux config)
│   └── rex/
│       ├── init.lua         → ~/.config/rex/init.lua (bindings, popups)
│       ├── context.lua      → Shared cwd/block helpers
│       └── worktrees.lua    → Worktree tab actions
├── install.sh             → Bootstrap script for new machines
└── README.md              → Human docs
```

> **chezmoi naming**: Files prefixed with `dot_` are expanded to `.` in the target state. `dot_config` → `~/.config`.

## Conventions

### Editing Files

- **Prefer editing source files directly** in the repo, then run `chezmoi apply`:

  ```bash
  # Example: edit nvim keymaps
  nvim dot_config/nvim/lua/keymaps.lua
  chezmoi apply
  ```

- **Never edit target files** (e.g. `~/.config/nvim/...`) directly — chezmoi will overwrite them on next `apply`.

- Use `chezmoi edit <target>` if you want chezmoi to handle the source path for you.

### Lua / Neovim

- All Neovim config is Lua. No Vimscript.
- Plugin spec uses `lazy.nvim` (see `lua/pack.lua`).
- Keep plugin configs in `lua/plugins/<name>.lua`, returning a spec table.
- Leader key is `<Space>`.
- Follow the existing style: 2-space indentation, single quotes for strings where possible.

### tmux

- Config is a single file: `dot_config/tmux/tmux.conf`.
- Prefix key: `C-space` (not `C-b`).
- Uses TPM (Tmux Plugin Manager) — plugins declared at the bottom of the file.

### Rex

- Config entry point: `dot_config/rex/init.lua`; extra modules live beside it and are pulled in with `require(...)` (Rex resolves them relative to the config dir).
- `context.lua` holds shared helpers (`cwd_of`, `block_cwd`, `popup`, flavor names).
- `worktrees.lua` defines the workmux-style worktree flow: one git worktree per **session** named `<project>/<name>`, with `nvim` and agent windows. Actions: `worktree_add`, `worktree_open`, `worktree_remove`, plus the `*_prompt` pickers.
- One-key triggers: `ctrl+space>w` (agent picker + name prompt), `ctrl+space>o` (existing worktree picker), `ctrl+space>shift+w` (remove picker); `ctrl+space>]` / `[` cycle sessions. Switch sessions with `ctrl+space>f`.
- Rename keys follow tmux defaults: `ctrl+space>,` → `client.tab.rename`, `ctrl+space>shift+4` (`$`) → `session.rename`, `ctrl+space>l` → `rename_pane_prompt` (a popup in `init.lua` that runs `rex block rename`).
- Worktree → session ids live in `~/.local/state/rex/worktree-sessions`, so `worktree_open`/`worktree_remove` still work after a session is renamed.
- Agents are listed at the top of `worktrees.lua`; the picker shows installed ones, last used first (`~/.local/state/rex/worktree-agent`). The installed list is cached 60s for speed, but the last-used ordering is computed per call.
- Picker scripts log failures to `~/.local/state/rex/worktree.log` and keep the error on screen until Enter, so failures are diagnosable.
- **Server-side PATH gotcha**: `rex.exec` inside actions runs with the server's minimal PATH (`/usr/local/bin:/usr/bin:...`), so agent and `rex` lookup go through the user's **login + interactive shell** (`zsh -lic`). Terminal blocks themselves get the normal login-shell PATH.
- Sessions are created with `rex.call("session.create", { label, initial_windows })` — the `rex.session.*` Lua helper has no `create`/`destroy`. Cross-session teardown cannot use `session.destroy` (409 conflict); `worktree_remove` resolves the `rex` CLI path and runs `rex kill <session_id>`.
- The `*_prompt` actions open a floating layer running a small `sh -c` script that calls `rex do -s "$1" ...`; the pickers need `fzf`, and `worktree_open_prompt` uses `jq`.
- Prefix sequences mirror the tmux config: `ctrl+space>` (`|` split right, `-` split down, arrows resize, `r` reload).
- Floating tool popups are custom actions (`popup_lazygit`, `popup_hunk`, `popup_ghui`, `popup_wt`); they open in the focused pane's working directory.
- Worktree actions are also CLI-invokable: `rex do worktree_add name=foo agent=pi`, `rex do worktree_open name=foo`, `rex do worktree_remove name=foo`.
- After editing: `chezmoi apply ~/.config/rex`, then `rex config check` and `rex config reload`. Rex does not watch the file.
- If `~/.config/rex` doesn't exist yet, `mkdir -p ~/.config/rex` before applying a single target.
- Verify the loaded bindings with `rex keymap` and the actions with `rex actions`.
- Actions have ~30s to finish: keep `rex.exec` calls short; long setup work belongs in a pane.

## Common Tasks

| Task | Command |
|------|---------|
| See what would change | `chezmoi diff` |
| Apply all changes | `chezmoi apply` |
| Apply single file | `chezmoi apply ~/.config/nvim/init.lua` |
| Add new dotfile | `chezmoi add ~/.someconfig` |
| Edit via chezmoi | `chezmoi edit ~/.config/nvim/init.lua` |
| Check Rex config | `rex config check` |
| Reload Rex config | `rex config reload` |
| Show Rex bindings | `rex keymap` |
| Add worktree session | `C-space + w`, or `rex do worktree_add name=foo` |
| Open worktree session | `C-space + o`, or `rex do worktree_open name=foo` |
| Remove worktree session | `C-space + W`, or `rex do worktree_remove name=foo` |
| List sessions | `rex ls` |
| Update from remote | `chezmoi update` |

## Testing Changes

1. Edit the source file in the repo.
2. Run `chezmoi apply` to sync to the target path.
3. Open/Restart Neovim or reload tmux (`C-space + r`) or Rex (`rex config reload`) to verify.
4. Run `chezmoi diff` to confirm no unexpected drift.

## Key Dependencies

- **Neovim** ≥ 0.9 (Lua-native config)
- **chezmoi** (dotfile manager)
- **tmux** + TPM (tmux plugin manager)
- **tree-sitter CLI** (required by nvim-treesitter to compile parsers)
- **Homebrew** (macOS) — used in install script

## Notes for Agents

- This is a **personal** dotfiles repo. Changes affect the user's daily dev environment. Be conservative with breaking changes.
- The `install.sh` script is idempotent-ish but destructive on a fresh machine. Do not run it casually.
- Plugin versions are managed by lazy.nvim and TPM, not pinned in this repo.
- If adding a new plugin, follow the existing pattern: create `lua/plugins/<plugin>.lua` and return a lazy.nvim spec.
- If modifying keymaps, update both the Lua file and the README.md table (keep them in sync).
