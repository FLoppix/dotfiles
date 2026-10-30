# Dotfiles

Managed with [chezmoi](https://www.chezmoi.io/).

## What's included

- **Neovim** (`~/.config/nvim`) – Full IDE setup with LSP, Telescope, Neo-tree, and more
- **tmux** (`~/.config/tmux/tmux.conf`) – Terminal multiplexer with vim-tmux-navigator
- **Rex** (`~/.config/rex/init.lua`) – Tmux-style prefix, popups, and custom actions for the [Rex](https://www.superlogical.com/rex) terminal multiplexer

## Setup on a new machine

### One-liner (macOS with Homebrew)

```bash
curl -fsSL https://raw.githubusercontent.com/FLoppix/dotfiles/master/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/FLoppix/dotfiles.git ~/code/dotfiles
~/code/dotfiles/install.sh
```

### Manual steps

If you prefer to do it manually:

```bash
# 1. Install chezmoi
brew install chezmoi

# 2. Apply dotfiles
chezmoi init --apply https://github.com/FLoppix/dotfiles.git

# 3. Install tree-sitter CLI (required by nvim-treesitter)
brew install tree-sitter

# 4. Install TPM (Tmux Plugin Manager)
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# 5. Open Neovim to let plugins install automatically
nvim
```

Rex is a separate app install — get it from https://www.superlogical.com/rex. Its
config is applied by chezmoi like the rest; reload it with `rex config reload`.

## Day-to-day workflow

### Edit a config

```bash
# Edit in your editor, applies on save
chezmoi edit ~/.config/nvim/init.lua

# Or edit directly in the source directory
cd ~/code/dotfiles
nvim dot_config/nvim/init.lua
chezmoi apply
```

### See what would change

```bash
chezmoi diff
```

### Apply all changes

```bash
chezmoi apply
```

After changing the Rex config, reload it in the running server:

```bash
rex config check          # validate without applying
rex config reload         # apply to the running server
```

### Update from remote

```bash
chezmoi update
```

### Add a new file to dotfiles

```bash
chezmoi add ~/.someconfig
chezmoi cd
git add .
git commit -m "Add someconfig"
git push
```

## Key Neovim mappings

| Key | Action |
|---|---|
| `<leader>e` | Toggle file tree (Neo-tree) |
| `<leader>ff` | Find files (Telescope) |
| `<leader>fw` | Live grep (Telescope) |
| `<leader>fs` | Find symbols in buffer |
| `<leader>fS` | Find symbols in workspace |
| `<leader>cd` | List diagnostics (buffer) |
| `<leader>cD` | List diagnostics (global) |
| `<leader>ca` | Code actions |
| `<leader>rn` | Rename symbol |
| `gd` | Go to definition |
| `gr` | Find references |
| `K` | Hover docs |
| `<leader>|` | Vertical split |
| `<leader>-` | Horizontal split |
| `<Tab>` / `<S-Tab>` | Cycle buffers |
| `<leader>bb` | Fuzzy switch buffer |
| `<leader>bd` | Delete buffer |
| `<C-s>` | Save buffer |

## Key tmux mappings

| Key | Action |
|---|---|
| `C-space` | Prefix key |
| `C-space + \|` | Split horizontal |
| `C-space + -` | Split vertical |
| `C-h/j/k/l` | Navigate panes (vim-tmux-navigator) |
| `C-space + r` | Reload config |
| `C-space + arrows` | Resize panes |

## Key Rex mappings

Rex keeps its own defaults; the prefix sequences below mirror the tmux workflow.

| Key | Action |
|---|---|
| `C-space` | Prefix for the sequences below |
| `C-space + \|` | Split right |
| `C-space + -` | Split down |
| `C-space + c` | New tab |
| `C-space + n` / `p` | Next / previous tab |
| `C-space + 1`–`9` | Jump to tab N |
| `C-space + ,` | Rename tab (tmux `prefix + ,`) |
| `C-space + $` | Rename session (tmux `prefix + $`) |
| `C-space + l` | Rename pane |
| `C-space + z` | Zoom pane |
| `C-space + x` | Close pane |
| `C-space + arrows` | Resize pane (`Shift` + arrows = bigger step) |
| `C-space + f` | Session switcher (= worktree switcher) |
| `C-space + ]` / `[` | Next / previous session |
| `C-space + g` | lazygit popup |
| `C-space + G` | ghui popup |
| `C-space + h` | hunk diff popup |
| `C-space + t` | worktree switch popup |
| `C-space + w` | New worktree session (agent + name prompt) |
| `C-space + o` | Open worktree session (fzf picker) |
| `C-space + W` | Remove worktree session (fzf picker) |
| `C-space + r` | Reload Rex config |
| `C-space + C-space` | Send a literal `C-space` to the terminal |

> Rex's own defaults (Cmd-based shortcuts) still apply; the config is additive.
> The popups open as floating panes in the focused pane's working directory.

## Worktree sessions (workmux-style)

`dot_config/rex/worktrees.lua` gives Rex a workmux-like flow: **one git
worktree per session**, named `<project>/<name>` (e.g. `dotfiles/stripe-fix`),
with two windows:

- `nvim` — Neovim in the worktree
- `<agent>` — pi / claude / codex / opencode / amp (active window)

Switch between worktrees with the session picker (`C-space + f`) or
`C-space + ]` / `[`. Agents are configured at the top of `worktrees.lua`; the
picker lists the ones installed, most recently used first.

The fastest way in: **`C-space + w`** (pick agent, type name),
**`C-space + o`** (pick an existing worktree), **`C-space + W`** (remove).

From the CLI:

```bash
# Create <repo>__worktrees/<name> on branch wm/<name> and open its session
rex do worktree_add name=my-feature
rex do worktree_add name=my-feature agent=claude

# Open an existing worktree (reuses the live session when present)
rex do worktree_open name=my-feature agent=pi

# Remove the worktree, close its session, delete the branch when merged
rex do worktree_remove name=my-feature
rex do worktree_remove name=my-feature force=true   # discard changes
```

Notes:

- Worktrees live beside the repo in `<project>__worktrees/`; branches are `wm/<name>`.
- Running an action from inside another worktree still targets the main checkout
  (it reads `git worktree list`).
- Removing the worktree you are currently in is refused: switch sessions first.
- `worktree_add` rolls back the worktree and branch if the session can't be created.
- The last used agent is remembered in `~/.local/state/rex/worktree-agent`.
- Picker failures are appended to `~/.local/state/rex/worktree.log`; the popup keeps the error on screen until you press Enter.
- Renaming a worktree session is safe: the worktree → session id mapping is kept in `~/.local/state/rex/worktree-sessions`, so open/remove still find it.
- Actions have ~30s to finish, so keep creation hooks short; long setup work
  belongs in a window.

## License

MIT
