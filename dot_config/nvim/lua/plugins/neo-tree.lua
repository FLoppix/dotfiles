require("neo-tree").setup({
	close_if_last_window = false,
	enable_git_status = true,
	enable_diagnostics = true,
	filesystem = {
		follow_current_file = {
			enabled = true,
			leave_dirs_open = true,
		},
		hijack_netrw_behavior = "open_default",
		use_libuv_file_watcher = true,
		filtered_items = {
			visible = false,
			hide_dotfiles = true,
			hide_gitignored = true,
		},
	},
	window = {
		position = "left",
		width = 40,
	},
	default_component_configs = {
		icon = {
			folder_closed = "",
			folder_open = "",
			folder_empty = "",
		},
		diagnostics = {
			enabled = true,
			symbols = {
				hint = "H",
				info = "I",
				warn = "W",
				error = "E",
			},
			highlights = {
				hint = "DiagnosticHint",
				info = "DiagnosticInfo",
				warn = "DiagnosticWarn",
				error = "DiagnosticError",
			},
		},
	},
})

vim.keymap.set("n", "<leader>e", "<Cmd>Neotree toggle<CR>", { desc = "Toggle file tree" })
vim.keymap.set("n", "<leader>o", "<Cmd>Neotree focus<CR>", { desc = "Focus file tree" })
