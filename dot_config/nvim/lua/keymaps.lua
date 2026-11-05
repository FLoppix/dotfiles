vim.g.mapleader = " "

vim.keymap.set("x", "p", [["_dP]], { desc = "Paste over selection without losing yanked text" })

vim.keymap.set({ "n", "v" }, "<leader>d", [["_d]], { desc = "Delete without yanking" })

vim.keymap.set("i", "<C-c>", "<Esc>")
vim.keymap.set("n", "<C-c>", ":nohl<CR>", { desc = "Clear search highlighting", silent = true })

vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "moves lines down in visual selection" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "moves lines up in visual selection" })

vim.keymap.set("v", "<", "<gv", { desc = "Unindent and keep selection" })
vim.keymap.set("v", ">", ">gv", { desc = "Indent and keep selection" })

vim.keymap.set("n", "J", "mzJ`z", { desc = "Join lines without moving cursor" })

vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "move down in buffer with cursor centered" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "move up in buffer with cursor centered" })

vim.keymap.set("n", "n", "nzzzv", { desc = "Next search result cursor centered" })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Previous search result cursor centered" })

vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]],
    { desc = "Replace word cursor is on globally" })
vim.keymap.set("n", "<leader>X", "<cmd>!chmod +x %<CR>", { silent = true, desc = "makes file executable" })

vim.keymap.set("n", "<leader>re", "<cmd>restart<cr>", { desc = "Restart config :restart)" })

-- Save buffer with Ctrl+S
vim.keymap.set({ "n", "v" }, "<C-s>", ":w<CR>", { desc = "Save buffer", silent = true })
vim.keymap.set("i", "<C-s>", "<C-o>:w<CR>", { desc = "Save buffer", silent = true })

-- Window navigation
--
-- Inside nvim move between windows; at the edge of the layout hand the
-- direction to the multiplexer (Rex, or tmux) so nvim windows and terminal
-- panes behave like one layout, the way vim-tmux-navigator did under tmux.
vim.g.tmux_navigator_no_mappings = 1 -- replaced by the mappings below

local function mux_focus(rex_direction, tmux_flag)
	local session = vim.env.REX_SESSION
	if session ~= nil and session ~= "" then
		local bin_dir = (vim.env.REX_BIN_DIR or ""):gsub("/$", "")
		local bin = bin_dir == "" and "rex" or (bin_dir .. "/rex")
		vim.system({ bin, "focus", rex_direction, "-s", session }, { detach = true })
		return
	end

	if (vim.env.TMUX or "") ~= "" then
		vim.system({ "tmux", "select-pane", tmux_flag }, { detach = true })
	end
end

local function navigate(window_cmd, rex_direction, tmux_flag)
	return function()
		local before = vim.fn.winnr()
		pcall(vim.cmd, "wincmd " .. window_cmd)
		-- Same window number means nvim has nothing that way: leave nvim.
		if vim.fn.winnr() == before then
			mux_focus(rex_direction, tmux_flag)
		end
	end
end

vim.keymap.set("n", "<C-h>", navigate("h", "left", "-L"), { desc = "Focus left nvim window or Rex pane" })
vim.keymap.set("n", "<C-j>", navigate("j", "down", "-D"), { desc = "Focus down nvim window or Rex pane" })
vim.keymap.set("n", "<C-k>", navigate("k", "up", "-U"), { desc = "Focus up nvim window or Rex pane" })
vim.keymap.set("n", "<C-l>", navigate("l", "right", "-R"), { desc = "Focus right nvim window or Rex pane" })
vim.keymap.set("n", "<C-w>p", "<C-w>p", { desc = "Focus previous window" })

-- Splits
vim.keymap.set("n", "<leader>|", "<C-w>v", { desc = "Vertical split" })
vim.keymap.set("n", "<leader>-", "<C-w>s", { desc = "Horizontal split" })
vim.keymap.set("n", "<leader>q", "<C-w>c", { desc = "Close split" })

-- Buffer cycling
vim.keymap.set("n", "<Tab>", ":bnext<CR>", { desc = "Next buffer", silent = true })
vim.keymap.set("n", "<S-Tab>", ":bprev<CR>", { desc = "Previous buffer", silent = true })

-- Buffer management
vim.keymap.set("n", "<leader>bp", "<C-^>", { desc = "Jump to previous buffer" })
vim.keymap.set("n", "<leader>bn", ":enew<CR>", { desc = "New empty buffer", silent = true })
vim.keymap.set("n", "<leader>bd", function()
	require("mini.bufremove").delete(0, false)
end, { desc = "Delete buffer (keep window)" })
vim.keymap.set("n", "<leader>bo", function()
	local current = vim.api.nvim_get_current_buf()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and buf ~= current then
			require("mini.bufremove").delete(buf, false)
		end
	end
end, { desc = "Close all other buffers" })

-- native undotree
vim.keymap.set("n", "<leader>u", function()
    vim.cmd.packadd("nvim.undotree")
    require("undotree").open()
end, { desc = "Toggle Builtin Undotree" })
