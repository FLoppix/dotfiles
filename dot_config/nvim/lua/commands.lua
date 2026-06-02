vim.api.nvim_create_user_command("PackAdd", function(opts)
    vim.pack.add(opts.fargs)
end, { nargs = "+", desc = "Add plugins (:PackAdd user/repo1 user/repo2)" })

-- Pack Delete and Update cmds are built-in on Nightly 0.13
vim.api.nvim_create_user_command("PackDel", function(opts)
    vim.pack.del(opts.fargs)
end, { nargs = "+", desc = "Delete plugins (:PackDel plugin1 plugin2)" })

vim.api.nvim_create_user_command("PackUpdate", function(opts)
    -- checks if any argument is passed
    if opts.args:match("%S") then
        -- update specific plugins
        local plugins = vim.split(opts.args, "%s+", { trimempty = true })
        -- update only specified plugins
        vim.pack.update(plugins)
    else
        -- update all
        vim.pack.update()
    end
end, { nargs = "*", desc = "Update all plugins or specific ones" })

-- Buffer limiter: max open buffers, recycle oldest on overflow
local MAX_BUFFERS = 3
local buf_access = {}

local function update_access_time(buf)
    buf_access[buf] = vim.loop.now()
end

vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(args)
        update_access_time(args.buf)
    end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
    callback = function()
        local current = vim.api.nvim_get_current_buf()
        local loaded = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
                table.insert(loaded, buf)
            end
        end

        if #loaded <= MAX_BUFFERS then
            return
        end

        -- find least recently used buffer to recycle
        local lru_buf = nil
        local lru_time = math.huge
        for _, buf in ipairs(loaded) do
            if buf ~= current and not vim.bo[buf].modified then
                local access_time = buf_access[buf] or 0
                if access_time < lru_time then
                    lru_time = access_time
                    lru_buf = buf
                end
            end
        end

        if lru_buf then
            require("mini.bufremove").delete(lru_buf, false)
        end
    end,
})
