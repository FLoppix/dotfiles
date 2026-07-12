-- Minimal snacks.nvim setup.
-- See https://github.com/folke/snacks.nvim for the full list of picks.
-- Calling `setup({})` enables snacks' default picks with their defaults.
-- Add specific picks here only when you want to override a default or enable
-- something that is off by default.

-- Snappier feel: disable built-in animations.
vim.g.snacks_animate = false

require("snacks").setup({
  -- Dashboard, file_picker, notifier, picker, quickfile, statuscolumn,
  -- words, indent, scope, bigfile, lazygit, terminal are all on by default.
  -- Override a pick by listing it here, e.g.:
  -- notifier = { timeout = 3000 },
})
