# AGENTS.md

> Agent-focused context for the dotfiles repository. For human-readable docs, see [README.md](./README.md).

## Project Overview

- **Type**: Personal dotfiles / system configuration
- **Management**: [chezmoi](https://www.chezmoi.io/) — declarative dotfile manager
- **Contents**: Neovim IDE setup, tmux configuration, install script
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
│   └── tmux/
│       └── tmux.conf        → ~/.config/tmux/tmux.conf (tmux config)
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

## Common Tasks

| Task | Command |
|------|---------|
| See what would change | `chezmoi diff` |
| Apply all changes | `chezmoi apply` |
| Apply single file | `chezmoi apply ~/.config/nvim/init.lua` |
| Add new dotfile | `chezmoi add ~/.someconfig` |
| Edit via chezmoi | `chezmoi edit ~/.config/nvim/init.lua` |
| Update from remote | `chezmoi update` |

## Testing Changes

1. Edit the source file in the repo.
2. Run `chezmoi apply` to sync to the target path.
3. Open/Restart Neovim or reload tmux (`C-space + r`) to verify.
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
