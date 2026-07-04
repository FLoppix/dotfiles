local mason = require("mason")
local registry = require("mason-registry")

mason.setup()

local ensure_installed = {
	"lua-language-server",
	"marksman",
	"gopls",
	"rust-analyzer",
	"typescript-language-server",
	"pyright",
}

local function install_missing_servers()
	for _, name in ipairs(ensure_installed) do
		local ok, package = pcall(registry.get_package, name)
		if ok and not package:is_installed() then
			package:install()
		end
	end
end

registry.refresh(install_missing_servers)

vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })
vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { desc = "Go to declaration" })
vim.keymap.set("n", "gi", vim.lsp.buf.implementation, { desc = "Go to implementation" })
vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, { desc = "Go to type definition" })
vim.keymap.set("n", "gr", vim.lsp.buf.references, { desc = "Find references" })
vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Hover documentation" })
vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename symbol" })
local function format_buffer()
	local has_oxfmt = #vim.lsp.get_clients({ bufnr = 0, name = "oxfmt" }) > 0
	vim.lsp.buf.format({
		timeout_ms = 2000,
		filter = has_oxfmt and function(c)
			return c.name == "oxfmt"
		end or nil,
	})
end

vim.keymap.set("n", "<leader>f", format_buffer, { desc = "Format buffer (oxfmt if available)" })
vim.keymap.set("n", "df", vim.diagnostic.open_float, { desc = "Show line diagnostics" })
vim.keymap.set("i", "<C-k>", vim.lsp.buf.signature_help, { desc = "Signature help" })

vim.diagnostic.config({ virtual_text = true })

local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities = vim.tbl_deep_extend("force", capabilities, require("blink.cmp").get_lsp_capabilities())

vim.lsp.config("*", { capabilities = capabilities })

-- Resolve the project-local vite-plus binary. vite-plus bundles oxfmt/oxlint
-- and reads the fmt/lint blocks from vite.config.ts, which standalone
-- oxfmt/oxlint binaries cannot parse (they expect .oxfmtrc.json/.oxlintrc.json).
local function resolve_vp(root_dir)
	if not root_dir then
		return "vp"
	end
	local local_vp = vim.fs.joinpath(root_dir, "node_modules", ".bin", "vp")
	if vim.fn.executable(local_vp) == 1 then
		return local_vp
	end
	return "vp"
end

-- oxfmt LSP via vite-plus: formatting that respects vite.config.ts fmt block.
vim.lsp.config("oxfmt", {
	cmd = function(dispatchers, config)
		local cmd = resolve_vp(config.root_dir)
		return vim.lsp.rpc.start({ cmd, "fmt", "--lsp" }, dispatchers)
	end,
	filetypes = {
		"javascript",
		"javascriptreact",
		"typescript",
		"typescriptreact",
		"vue",
		"json",
		"jsonc",
		"css",
		"html",
		"markdown",
	},
	workspace_required = true,
	root_dir = function(bufnr, on_dir)
		local fname = vim.api.nvim_buf_get_name(bufnr)
		local util = require("lspconfig.util")
		local root_markers = util.insert_package_json(
			{ ".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts" },
			{ "oxfmt", "vite%-plus" },
			fname
		)
		root_markers = util.root_markers_with_field(
			root_markers,
			{ "vite.config.ts" },
			{ "vite%-plus", "fmt:" },
			fname,
			"all"
		)
		on_dir(vim.fs.dirname(vim.fs.find(root_markers, { path = fname, upward = true })[1]))
	end,
})

-- oxlint LSP via vite-plus: diagnostics that respect vite.config.ts lint block.
vim.lsp.config("oxlint", {
	cmd = function(dispatchers, config)
		local cmd = resolve_vp(config.root_dir)
		return vim.lsp.rpc.start({ cmd, "lint", "--lsp" }, dispatchers)
	end,
	filetypes = {
		"javascript",
		"javascriptreact",
		"typescript",
		"typescriptreact",
		"vue",
	},
	workspace_required = true,
	root_dir = function(bufnr, on_dir)
		local fname = vim.api.nvim_buf_get_name(bufnr)
		local util = require("lspconfig.util")
		local root_markers = util.insert_package_json(
			{ ".oxlintrc.json", ".oxlintrc.jsonc", "oxlint.config.ts" },
			{ "oxlint", "vite%-plus" },
			fname
		)
		root_markers = util.root_markers_with_field(
			root_markers,
			{ "vite.config.ts" },
			{ "vite%-plus", "lint:" },
			fname,
			"all"
		)
		on_dir(vim.fs.dirname(vim.fs.find(root_markers, { path = fname, upward = true })[1]))
	end,
	on_attach = function(client, bufnr)
		vim.api.nvim_buf_create_user_command(bufnr, "LspOxlintFixAll", function()
			client:exec_cmd({
				title = "Apply Oxlint automatic fixes",
				command = "oxc.fixAll",
				arguments = { { uri = vim.uri_from_bufnr(bufnr) } },
			})
		end, {
			desc = "Apply Oxlint automatic fixes",
		})
	end,
})

vim.lsp.config("lua_ls", {
	settings = {
		Lua = {
			diagnostics = { globals = { "vim" } },
		},
	},
})

vim.lsp.enable({
	"lua_ls",
	"marksman",
	"gopls",
	"rust_analyzer",
	"ts_ls",
	"pyright",
	"oxfmt",
	"oxlint",
})

vim.api.nvim_create_autocmd("BufWritePre", {
	callback = format_buffer,
})
