-- Shared helpers for the Rex configuration modules.
--
-- Source: ~/code/dotfiles/dot_config/rex/context.lua
-- Target: ~/.config/rex/context.lua

local M = {}

M.shell = "com.superlogical.terminal.shell"
M.terminal = "com.superlogical.terminal"

-- The working directory of one block, or nil when it can't be read.
function M.block_cwd(block_id)
    local args = { block_id = block_id }

    local result = rex.block.call(M.terminal, "pwd", args)
    if result ~= nil and type(result.pwd) == "string" then
        -- pwd comes back as a file URL: file://host/path
        local path = result.pwd:gsub("^file://[^/]*", "")
        return (path:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end))
    end

    -- A fresh shell may not have reported pwd yet; the process knows.
    local process = rex.block.call(M.terminal, "process", args)
    if process ~= nil then
        local foreground = process.foreground or {}
        local child = process.child or {}
        if foreground.cwd ~= nil then
            return foreground.cwd
        end
        if child.cwd ~= nil then
            return child.cwd
        end
    end

    return nil
end

-- The block an action should act on: its own block, else the focused block
-- of its active window (CLI runs have no block of their own).
function M.focused_block_id(ctx)
    if ctx.block_id ~= nil then
        return ctx.block_id
    end

    local view = rex.session.view {}
    local windows = view and view.windows or {}
    for _, window in ipairs(windows) do
        if window.window_id == view.active_window_id then
            return window.focused_block_id
        end
    end
    if windows[1] ~= nil then
        return windows[1].focused_block_id
    end
    return nil
end

-- The working directory of the terminal an action was run from, or HOME.
function M.cwd_of(ctx)
    local block_id = M.focused_block_id(ctx)
    if block_id ~= nil then
        local cwd = M.block_cwd(block_id)
        if cwd ~= nil then
            return cwd
        end
    end

    return os.getenv("HOME")
end

-- POSIX single-quote one argument so it can be joined into a shell command.
local function sh_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Wrap a command (argv table) so it runs under the user's login + interactive
-- shell. Rex actions run with the server's minimal PATH, but popup commands
-- like lazygit spawn git hooks (e.g. pre-push via vp) that need node and the
-- rest of the terminal environment.
function M.login_cmd(command)
    local parts = {}
    for i, arg in ipairs(command) do
        parts[i] = sh_quote(arg)
    end
    return { "zsh", "-lic", table.concat(parts, " ") }
end

-- A floating pane running a command, in the caller's working directory.
-- Commands run through the login shell so their environment matches a
-- terminal pane (PATH, tool versions, …).
function M.popup(ctx, command, label, bounds)
    local result, err = rex.session.new_layer {
        bounds = bounds,
        focus = true,
        layout = rex.layout.block {
            flavor = M.shell,
            label = label,
            options = {
                command = M.login_cmd(command),
                cwd = M.cwd_of(ctx),
            },
        },
    }
    if result == nil then
        error(err, 0)
    end
    return result
end

return M
