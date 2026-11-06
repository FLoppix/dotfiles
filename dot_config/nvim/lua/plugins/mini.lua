---- cmdline completion / pairs / surround (mini.notify removed in favor of snacks.notifier) ----
--- mini cmdline completion ---
require("mini.cmdline").setup({
    autocorrect = { enable = false }
})


--- mini icons (file + directory glyphs, used by neo-tree and snacks) ---
local MiniIcons = require("mini.icons")
MiniIcons.setup()

-- mini.icons ships nine fixed-hue highlight groups. Recolour them with the
-- catppuccin mocha palette (same mapping the catppuccin/nvim "mini"
-- integration uses), so folder icons match the built-in catppuccin
-- colorscheme instead of clashing with it.
local icon_colors = {
	MiniIconsAzure = "#74c7ec", -- sapphire
	MiniIconsBlue = "#89b4fa", -- blue
	MiniIconsCyan = "#94e2d5", -- teal
	MiniIconsGreen = "#a6e3a1", -- green
	MiniIconsGrey = "#cdd6f4", -- text
	MiniIconsOrange = "#fab387", -- peach
	MiniIconsPurple = "#cba6f7", -- mauve
	MiniIconsRed = "#f38ba8", -- red
	MiniIconsYellow = "#f9e2af", -- yellow
}

local function apply_icon_colors()
	for group, fg in pairs(icon_colors) do
		vim.api.nvim_set_hl(0, group, { fg = fg })
	end
end

apply_icon_colors()
-- mini.icons resets its groups on every ColorScheme; run after it does.
vim.api.nvim_create_autocmd("ColorScheme", {
	callback = apply_icon_colors,
	desc = "Keep mini.icons in the catppuccin palette",
})

--- mini pairs (auto-close brackets & quotes) ---
require("mini.pairs").setup()

--- mini surround ---
require("mini.surround").setup()
-- Default Keymaps
-- | `sa` | Add surrounding or Direct with 'saiw' |
-- | `sd` | Delete surrounding |
-- | `sr` | Replace surrounding |
-- | `sf` | Find surrounding (right) |
-- | `sF` | Find surrounding (left) |
-- | `sh` | Highlight surrounding |
-- | `sn` | Update n_lines |
-- | `l` / `n` | as suffix for prev/next |
