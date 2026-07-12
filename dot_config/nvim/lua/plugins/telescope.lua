local telescope = require("telescope")
local builtin = require("telescope.builtin")

telescope.setup({})

vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fw", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fr", function()
  builtin.oldfiles({ only_cwd = true })
end, { desc = "Recent files (this project)" })

-- Resume the last Telescope picker (global state, not project-scoped).
vim.keymap.set("n", "<leader>fR", builtin.resume, { desc = "Resume last Telescope search" })
vim.keymap.set("n", "<leader>cd", function()
	builtin.diagnostics({ bufnr = 0 })
end, { desc = "List diagnostics in current buffer" })

vim.keymap.set("n", "<leader>cD", function()
	builtin.diagnostics({})
end, { desc = "List all diagnostics (global)" })

vim.keymap.set("n", "<leader>fs", function()
	builtin.lsp_document_symbols({
		symbols = { "Function", "Method", "Class", "Constructor", "Interface", "Struct" },
	})
end, { desc = "Find symbols in current buffer" })
vim.keymap.set("n", "<leader>fS", function()
	builtin.lsp_workspace_symbols({
		symbols = { "Function", "Method", "Class", "Constructor", "Interface", "Struct" },
	})
end, { desc = "Find symbols in workspace" })

vim.keymap.set("n", "<leader>bb", builtin.buffers, { desc = "Fuzzy switch buffer" })
