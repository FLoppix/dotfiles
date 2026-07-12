-- Minimal snacks.nvim setup: dashboard + terminal enabled.
-- See https://github.com/folke/snacks.nvim for the full list of picks.
--
-- Snacks only enables picks that are explicitly listed in `setup(opts)`.
-- Every other pick (picker, notifier, statuscolumn, words, indent, ...)
-- stays off.

-- Snappier feel: disable built-in animations.
vim.g.snacks_animate = false

require('snacks').setup({
    dashboard = {
        -- Keep snacks' built-in defaults (NeoVim ASCII header, default keys)
        -- but drop the `startup` section: it calls `require("lazy.stats")`,
        -- which only works with lazy.nvim. This config uses `vim.pack.add`,
        -- so it errors.
        sections = {
            { section = 'header' },
            { section = 'keys',  gap = 1, padding = 1 },
        },
    },

    -- Toggleable terminal windows. See :h snacks-terminal
    terminal = {},
})

-- Terminal keymaps ---------------------------------------------------------
-- `<leader>t` group is registered in plugins/whichkey.lua.
local term = require('snacks.terminal')

-- Toggle the main shell from normal and terminal mode.
vim.keymap.set({ 'n', 't' }, '<C-t>', function() term.toggle() end, { desc = 'Terminal: toggle' })
vim.keymap.set('n', '<leader>tt', function() term.toggle() end, { desc = 'Terminal: toggle' })
vim.keymap.set('n', '<leader>to', function() term.open() end, { desc = 'Terminal: open' })
vim.keymap.set('n', '<leader>tf', function()
    term.open(nil, { win = { position = 'float' } })
end, { desc = 'Terminal: floating' })
-- Run a one-shot command: `<leader>tk ls -la<cr>` from the cmdline.
vim.keymap.set('n', '<leader>tk', function() term(nil, { auto_close = true }) end, { desc = 'Terminal: run command' })
