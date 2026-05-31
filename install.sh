#!/usr/bin/env bash
set -e

echo "==> Setting up dotfiles..."

# Install chezmoi if not present
if ! command -v chezmoi &> /dev/null; then
    echo "==> Installing chezmoi..."
    brew install chezmoi
else
    echo "==> chezmoi already installed"
fi

# Initialize and apply dotfiles
echo "==> Applying dotfiles..."
if [ -d "$HOME/code/dotfiles/.git" ]; then
    chezmoi init --source "$HOME/code/dotfiles" --apply
else
    chezmoi init --apply https://github.com/FLoppix/dotfiles.git
fi

# Install tree-sitter CLI (required by nvim-treesitter)
if ! command -v tree-sitter &> /dev/null; then
    echo "==> Installing tree-sitter CLI..."
    brew install tree-sitter
else
    echo "==> tree-sitter CLI already installed"
fi

# Install TPM (Tmux Plugin Manager)
if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    echo "==> Installing Tmux Plugin Manager (TPM)..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
else
    echo "==> TPM already installed"
fi

echo ""
echo "==> Done! Next steps:"
echo "    1. Open tmux and press 'prefix + I' (Ctrl+Space then I) to install tmux plugins"
echo "    2. Open nvim and let plugins install automatically"
echo ""
