---- cmdline completion / pairs / surround (mini.notify removed in favor of snacks.notifier) ----
--- mini cmdline completion ---
require("mini.cmdline").setup({
    autocorrect = { enable = false }
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
