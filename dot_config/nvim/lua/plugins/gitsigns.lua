local gitsigns = require('gitsigns')

gitsigns.setup({
  signs = {
    add = { text = '+' },
    change = { text = '~' },
    delete = { text = '_' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
    untracked = { text = '┆' },
  },
  signs_staged = {
    add = { text = '+' },
    change = { text = '~' },
    delete = { text = '_' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
  },
  current_line_blame = false,
  word_diff = false,
  attach_to_untracked = true,
  update_debounce = 100,
  auto_watch = true,
})

-- Navigation: jump between hunks
vim.keymap.set('n', ']h', function()
  if vim.wo.diff then
    vim.cmd.normal({ ']c', bang = true })
  else
    gitsigns.nav_hunk('next')
  end
end, { desc = 'Gitsigns: Next hunk' })

vim.keymap.set('n', '[h', function()
  if vim.wo.diff then
    vim.cmd.normal({ '[c', bang = true })
  else
    gitsigns.nav_hunk('prev')
  end
end, { desc = 'Gitsigns: Prev hunk' })

-- Hunk actions (leader + g prefix, to avoid clashing with harpoon's leader + h)
vim.keymap.set('n', '<leader>gs', gitsigns.stage_hunk, { desc = 'Gitsigns: Stage hunk' })
vim.keymap.set('n', '<leader>gr', gitsigns.reset_hunk, { desc = 'Gitsigns: Reset hunk' })
vim.keymap.set('v', '<leader>gs', function()
  gitsigns.stage_hunk({ vim.fn.line('.'), vim.fn.line('v') })
end, { desc = 'Gitsigns: Stage hunk' })
vim.keymap.set('v', '<leader>gr', function()
  gitsigns.reset_hunk({ vim.fn.line('.'), vim.fn.line('v') })
end, { desc = 'Gitsigns: Reset hunk' })
vim.keymap.set('n', '<leader>gS', gitsigns.stage_buffer, { desc = 'Gitsigns: Stage buffer' })
vim.keymap.set('n', '<leader>gR', gitsigns.reset_buffer, { desc = 'Gitsigns: Reset buffer' })
vim.keymap.set('n', '<leader>gu', gitsigns.undo_stage_hunk, { desc = 'Gitsigns: Undo stage hunk' })
vim.keymap.set('n', '<leader>gp', gitsigns.preview_hunk, { desc = 'Gitsigns: Preview hunk' })
vim.keymap.set('n', '<leader>gb', function()
  gitsigns.blame_line({ full = true })
end, { desc = 'Gitsigns: Blame line' })
vim.keymap.set('n', '<leader>gd', gitsigns.diffthis, { desc = 'Gitsigns: Diff buffer' })
vim.keymap.set('n', '<leader>gD', function()
  gitsigns.diffthis('~')
end, { desc = 'Gitsigns: Diff buffer (against HEAD)' })

-- Toggles (avoid <leader>g* sub-keys; `gt` is mapped to LSP type definition in lsp.lua
-- and the leader dispatches `gt`, shadowing these bindings)
vim.keymap.set('n', '<leader>tg', gitsigns.toggle_signs, { desc = 'Gitsigns: Toggle signs' })
vim.keymap.set('n', '<leader>lb', gitsigns.toggle_current_line_blame, { desc = 'Gitsigns: Toggle line blame' })

-- Text object: select a hunk
vim.keymap.set({ 'o', 'x' }, 'ih', gitsigns.select_hunk, { desc = 'Gitsigns: Select hunk' })
