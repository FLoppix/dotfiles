local telescope = require("telescope")
local builtin = require("telescope.builtin")
local conf = require("telescope.config").values

telescope.setup({})

-- find_files shows nothing until the query matches something, instead of
-- dumping the whole file list as soon as the picker opens.
local function find_files_without_empty_results(opts)
  local file_sorter = conf.file_sorter
  conf.file_sorter = function(sorter_opts)
    local sorter = file_sorter(sorter_opts)
    local filter = sorter.filter_function
    sorter.filter_function = function(self, prompt, entry, cb_add, cb_filter)
      if prompt == nil or prompt == "" then
        return -1 -- no query means no results
      end
      if filter then
        return filter(self, prompt, entry, cb_add, cb_filter)
      end
      return 0, prompt -- passing the prompt through keeps the sorter working
    end
    return sorter
  end

  local ok, err = pcall(builtin.find_files, opts)
  conf.file_sorter = file_sorter
  if not ok then
    error(err)
  end
end

vim.keymap.set("n", "<leader>ff", function()
	find_files_without_empty_results({
		-- Show dotfiles as well. `rg` still respects .gitignore, so build
		-- output stays out; only .git itself needs an explicit skip.
		hidden = true,
		file_ignore_patterns = { "^%.git/" },
	})
end, { desc = "Telescope find files (incl. hidden)" })
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
