local lualine = require("lualine")

lualine.setup({
	options = {
		-- lualine ships no `catppuccin` theme, and nvim 0.12's built-in
		-- catppuccin colorscheme does not provide one either. `auto` derives the
		-- statusline colors from the active colorscheme and warns nothing.
		theme = "auto",
	},
	sections = {
		lualine_a = { "mode" },
		lualine_b = { "branch", "diff", "diagnostics" },
		lualine_c = {
			{
				"filename",
				path = 1,
			},
			{
				"buffers",
				show_filename_only = true,
				show_modified_status = true,
				mode = 2,
				max_length = vim.o.columns * 3 / 4,
				symbols = {
					modified = " ●",
					alternate_file = "",
					directory = "",
				},
				buffers_color = {
					active = { fg = "#1e1e2e", bg = "#89b4fa", gui = "bold" },
					inactive = { fg = "#a6adc8", bg = "#313244" },
				},
			},
		},
		lualine_x = { "encoding", "fileformat", "filetype" },
		lualine_y = { "progress" },
		lualine_z = { "location" },
	},
})
