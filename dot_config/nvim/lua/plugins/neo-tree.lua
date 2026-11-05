local MiniIcons = require("mini.icons")

-- Files keep nvim-web-devicons, exactly like neo-tree's own default provider.
-- Directories ask mini.icons first, so known names (`.git`, `node_modules`,
-- `src`, `tests`, `docs`, ...) get their own glyph and colour and everything
-- else falls back to the open/closed folder glyphs below.
local function icon_provider(icon, node, state)
	if node.type == "directory" then
		-- The tree's root node has no name; mini.icons requires a string.
		local name = node.name
		if name ~= nil and name ~= "" then
			local ok, glyph, hl, is_fallback = pcall(MiniIcons.get, "directory", name)
			if ok and not is_fallback then
				return { text = glyph, highlight = hl }
			end
		end
		return icon
	end

	local ok, devicons = pcall(require, "nvim-web-devicons")
	if ok then
		local name = node.type == "terminal" and "terminal" or (node.name or "")
		local glyph, hl = devicons.get_icon(name)
		icon.text = glyph or icon.text
		icon.highlight = hl or icon.highlight
	end

	return icon
end

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
			folder_empty = "󰉖",
			folder_empty_open = "󰷏",
			provider = icon_provider,
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
