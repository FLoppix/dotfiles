# Dotfiles

Managed with [chezmoi](https://www.chezmoi.io/).

## What's included

- **Neovim** (`~/.config/nvim`) – Full IDE setup with LSP, Telescope, Neo-tree, and more
- **tmux** (`~/.tmux.conf`) – Terminal multiplexer with vim-tmux-navigator

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

## License

MIT
