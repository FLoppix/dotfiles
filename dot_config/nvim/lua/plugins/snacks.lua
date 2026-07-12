-- Minimal snacks.nvim setup: only the dashboard is enabled.
-- See https://github.com/folke/snacks.nvim for the full list of picks.
--
-- Snacks only enables picks that are explicitly listed in `setup(opts)`.
-- Passing `dashboard = {}` enables the dashboard with its built-in defaults
-- (NeoVim ASCII header, default keys, startup section). Every other pick
-- (picker, notifier, statuscolumn, words, indent, bigfile, ...) stays off.

-- Snappier feel: disable built-in animations.
vim.g.snacks_animate = false

require("snacks").setup({
  dashboard = {
    -- Keep snacks' built-in defaults (NeoVim ASCII header, default keys)
    -- but drop the `startup` section: it calls `require("lazy.stats")`, which
    -- only works with lazy.nvim. This config uses `vim.pack.add`, so it errors.
    sections = {
      { section = "header" },
      { section = "keys", gap = 1, padding = 1 },
    },
  },
})
