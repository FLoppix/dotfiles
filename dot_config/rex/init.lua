-- Rex configuration -- managed by chezmoi.
--
-- Source: ~/code/dotfiles/dot_config/rex/init.lua
-- Target: ~/.config/rex/init.lua
-- Reload: rex config reload        (or prefix + r inside Rex)
-- Check:  rex config check
--
-- Rex ships usable defaults; everything here is additive. The prefix
-- bindings mirror the tmux workflow in dot_config/tmux/tmux.conf.

local context = require("context")
local terminal = context.terminal

----------------------------------------------------------------------
-- tmux-style prefix (Ctrl+Space)
----------------------------------------------------------------------

-- Splits, mirroring tmux `|` and `-`.
rex.bind("ctrl+space>shift+\\", "pane.split", { direction = "right" })
rex.bind("ctrl+space>-", "pane.split", { direction = "down" })

-- Tabs.
rex.bind("ctrl+space>c", "client.tab.new")
rex.bind("ctrl+space>n", "client.tab.next")
rex.bind("ctrl+space>p", "client.tab.previous")

-- Sessions (one per worktree).
rex.bind("ctrl+space>]", "session.next")
rex.bind("ctrl+space>[", "session.previous")

-- Jump to tab N with prefix + 1..9.
for i = 1, 9 do
    rex.bind("ctrl+space>" .. i, "client.tab.goto", { index = i })
end

-- Rename, following the tmux defaults: prefix + , / $.
rex.bind("ctrl+space>,", "client.tab.rename")
rex.bind("ctrl+space>shift+4", "session.rename")

-- Pane.
rex.bind("ctrl+space>z", "pane.zoom")
rex.bind("ctrl+space>x", "pane.close")

-- Resize the focused pane with prefix + arrows, like tmux.
rex.bind("ctrl+space>left", "pane.resize", { direction = "left" })
rex.bind("ctrl+space>right", "pane.resize", { direction = "right" })
rex.bind("ctrl+space>up", "pane.resize", { direction = "up" })
rex.bind("ctrl+space>down", "pane.resize", { direction = "down" })

-- Hold shift for a bigger step.
rex.bind("ctrl+space>shift+left", "pane.resize", { direction = "left", amount = 15 })
rex.bind("ctrl+space>shift+right", "pane.resize", { direction = "right", amount = 15 })
rex.bind("ctrl+space>shift+up", "pane.resize", { direction = "up", amount = 15 })
rex.bind("ctrl+space>shift+down", "pane.resize", { direction = "down", amount = 15 })

-- Session switcher (tmux-sessionx muscle memory).
rex.bind("ctrl+space>f", "session.switch")

-- Reload this file without leaving Rex.
rex.bind("ctrl+space>r", "client.config.reload")

-- Send a literal Ctrl+Space to the terminal (e.g. a nested tmux).
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })

----------------------------------------------------------------------
-- Vim-style pane navigation (Ctrl+h/j/k/l)
----------------------------------------------------------------------

-- Programs that keep Ctrl+h/j/k/l for themselves, the same programs
-- vim-tmux-navigator passes keys through to in tmux.
local keeps_nav_keys = {
    vi = true,
    vim = true,
    vimx = true,
    nvim = true,
    gvim = true,
    view = true,
    gview = true,
    vimdiff = true,
    nvimdiff = true,
    gvimdiff = true,
    fzf = true,
}

local function foreground_name(ctx)
    local args = {}
    if ctx.block_id ~= nil then
        args.block_id = ctx.block_id
    end

    local process = rex.block.call(terminal, "process", args)
    if process == nil or process.foreground == nil then
        return nil
    end
    return process.foreground.name
end

local function navigate(direction)
    return function(ctx)
        -- Let vim, nvim, and friends handle the key in their own windows.
        if keeps_nav_keys[foreground_name(ctx) or ""] then
            return false
        end

        local _, err = rex.session.focus_direction { direction = direction }
        if err ~= nil then error(err, 0) end
        return true
    end
end

rex.bind("ctrl+h", navigate("left"))
rex.bind("ctrl+j", navigate("down"))
rex.bind("ctrl+k", navigate("up"))
rex.bind("ctrl+l", navigate("right"))

----------------------------------------------------------------------
-- Floating tools (tmux popup equivalents)
----------------------------------------------------------------------

-- The working directory of the terminal the action was run from.
rex.action {
    name = "popup_lazygit",
    title = "Popup: lazygit",
    category = "Popups",
    keywords = "git lazygit popup",
    run = function(ctx)
        context.popup(ctx, { "lazygit" }, "lazygit", { 0.1, 0.1, 0.8, 0.8 })
    end,
}

rex.action {
    name = "popup_hunk",
    title = "Popup: hunk diff",
    category = "Popups",
    keywords = "git diff hunk review popup",
    run = function(ctx)
        context.popup(ctx, { "hunk", "diff" }, "hunk", { 0.05, 0.05, 0.9, 0.9 })
    end,
}

rex.action {
    name = "popup_ghui",
    title = "Popup: GitHub UI",
    category = "Popups",
    keywords = "github ghui pr popup",
    run = function(ctx)
        context.popup(ctx, { "ghui" }, "ghui", { 0.1, 0.1, 0.8, 0.8 })
    end,
}

rex.action {
    name = "popup_wt",
    title = "Popup: Worktree Switch",
    category = "Popups",
    keywords = "wt worktree switch popup",
    run = function(ctx)
        context.popup(ctx, { "wt", "switch" }, "wt switch", { 0.1, 0.1, 0.8, 0.8 })
    end,
}

rex.bind("ctrl+space>g", "popup_lazygit")
rex.bind("ctrl+space>shift+g", "popup_ghui")
rex.bind("ctrl+space>h", "popup_hunk")
rex.bind("ctrl+space>t", "popup_wt")

----------------------------------------------------------------------
-- Rename a pane (block label)
----------------------------------------------------------------------

rex.action {
    name = "rename_pane_prompt",
    title = "Rename Pane (ask)…",
    description = "Ask for a new name for the focused pane.",
    category = "Pane",
    keywords = "rename pane block label title",
    run = function(ctx)
        local block_id = context.focused_block_id(ctx)
        if block_id == nil then
            error("rename_pane_prompt: no focused pane", 0)
        end

        local script = table.concat({
            'printf "pane name: "',
            'read -r label || exit 1',
            '[ -n "$label" ] || exit 0',
            'exec rex block rename -s "$1" "$2" "$label"',
        }, "\n")

        context.popup(
            ctx,
            { "sh", "-c", script, "rename-pane", ctx.session_id, block_id },
            "rename pane",
            { 0.35, 0.42, 0.3, 0.1 }
        )
    end,
}

rex.bind("ctrl+space>l", "rename_pane_prompt")

----------------------------------------------------------------------
-- Worktree sessions (workmux-style)
----------------------------------------------------------------------

require("worktrees")
