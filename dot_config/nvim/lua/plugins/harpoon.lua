local harpoon = require("harpoon")

-- Setup with default settings
harpoon:setup({
  settings = {
    save_on_toggle = true,
    sync_on_ui_close = true,
  },
})

-- Keymaps
vim.keymap.set("n", "<leader>ha", function() harpoon:list():add() end, { desc = "Harpoon: Add file" })
vim.keymap.set("n", "<C-e>", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon: Toggle menu" })

-- Quick navigation with leader + number
vim.keymap.set("n", "<leader>1", function() harpoon:list():select(1) end, { desc = "Harpoon: File 1" })
vim.keymap.set("n", "<leader>2", function() harpoon:list():select(2) end, { desc = "Harpoon: File 2" })
vim.keymap.set("n", "<leader>3", function() harpoon:list():select(3) end, { desc = "Harpoon: File 3" })
vim.keymap.set("n", "<leader>4", function() harpoon:list():select(4) end, { desc = "Harpoon: File 4" })

-- Remove current file
vim.keymap.set("n", "<leader>hd", function() harpoon:list():remove() end, { desc = "Harpoon: Remove file" })

-- Next/prev navigation
vim.keymap.set("n", "<leader>hn", function() harpoon:list():next() end, { desc = "Harpoon: Next" })
vim.keymap.set("n", "<leader>hp", function() harpoon:list():prev() end, { desc = "Harpoon: Prev" })

-- Optional: integrate with Telescope for fuzzy finding harpooned files
local ok, telescope = pcall(require, "telescope")
if ok then
  vim.keymap.set("n", "<leader>fh", function()
    require("telescope").extensions.harpoon.marks({})
  end, { desc = "Harpoon: Fuzzy find" })
end
