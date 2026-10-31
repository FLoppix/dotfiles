-- Worktree sessions for Rex: one git worktree per session, workmux style.
--
-- Source: ~/code/dotfiles/dot_config/rex/worktrees.lua
-- Target: ~/.config/rex/worktrees.lua
--
-- Each worktree gets a session named <project>/<name> with two windows:
-- "nvim" and one agent window. Switch sessions with C-space + f.
--
-- Run from the CLI:
--   rex do worktree_add name=my-feature
--   rex do worktree_add name=my-feature agent=claude
--   rex do worktree_open name=my-feature agent=pi
--   rex do worktree_remove name=my-feature
--
-- Worktrees live beside the repository in <project>__worktrees/<name>,
-- branches are wm/<name>. An action has 30 seconds to finish, so keep the
-- commands short; long setup work belongs in a window, not in the action.

local context = require("context")

-- Agents offered by the picker. Add your own entry here.
local agents = {
    { name = "pi", command = { "pi" } },
    { name = "claude", command = { "claude" } },
    { name = "codex", command = { "codex" } },
    { name = "opencode", command = { "opencode" } },
    { name = "amp", command = { "amp" } },
}

local editor = { "nvim" }

local STATE_DIR = (os.getenv("HOME") or "") .. "/.local/state/rex"
local LAST_AGENT_FILE = STATE_DIR .. "/worktree-agent"
local LOG_FILE = STATE_DIR .. "/worktree.log"
local SESSION_MAP_FILE = STATE_DIR .. "/worktree-sessions"

local function trim(text)
    return (text:gsub("%s+$", ""))
end

local function run(argv, opts)
    local result, err = rex.exec(argv, opts)
    if result == nil then
        error(err, 0)
    end
    return result
end

-- Run a command and raise with its stderr when it fails.
local function run_ok(argv, opts)
    local result = run(argv, opts)
    if result.ok then
        return result
    end

    local message = trim(result.stderr or "")
    if message == "" then
        message = table.concat(argv, " ") .. " exited with " .. tostring(result.code)
    end
    error(message, 0)
end

-- The main checkout's root, even when the action runs from inside a
-- worktree tab. git worktree list prints the main worktree first.
local function repo_root(cwd)
    local result = rex.exec({ "git", "-C", cwd, "worktree", "list", "--porcelain" }, { timeout = 10 })
    if result == nil or not result.ok then
        return nil
    end
    return result.stdout:match("^worktree (.-)\n")
end

local function worktree_paths(root, name)
    local parent, project = root:match("^(.*)/([^/]+)$")
    local worktree = (parent or ".") .. "/" .. project .. "__worktrees/" .. name
    return worktree, "wm/" .. name
end

local function project_name(root)
    return root:match("([^/]+)$")
end

local function session_label(root, name)
    return project_name(root) .. "/" .. name
end

local function valid_name(name)
    return name ~= nil and name:match("^[%w._-]+$") ~= nil
end

-- Split a command on whitespace; no shell quoting yet.
local function parse_words(text)
    if text == nil or text == "" then
        return nil
    end

    local argv = {}
    for word in text:gmatch("%S+") do
        argv[#argv + 1] = word
    end
    return argv
end

local function agent_command(spec)
    if spec == nil or spec == "" then
        return nil
    end

    for _, agent in ipairs(agents) do
        if agent.name == spec then
            return agent.command
        end
    end
    return parse_words(spec)
end

local function terminal_pane(cwd, label, command)
    local options = { cwd = cwd }
    if command ~= nil then
        options.command = command
    end

    return rex.layout.block {
        flavor = context.shell,
        label = label,
        options = options,
    }
end

local rex_bin

-- Windows in one session, via the CLI so the action does not depend on its own
-- control stream being attached to that session. Each entry carries the window
-- id, because closing by label is ambiguous when a rerun left two setup tabs.
local rex_bin

-- Window entries: { id = "window:...", label = "..." }.
local function window_entries(label)
    local bin = rex_bin()
    local entries = {}
    if bin == nil then
        return entries
    end
    local result = rex.exec({ bin, "window", "ls", "-s", label, "--json" }, { timeout = 10 })
    if result == nil or not result.ok then
        return entries
    end

    local text = result.stdout
    local start = text:find('"windows"%s*:%s*%[')
    if start == nil then
        return entries
    end
    local depth = 0
    local began = nil
    for index = start, #text do
        local char = text:sub(index, index)
        if char == "{" then
            if depth == 0 then
                began = index
            end
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 and began ~= nil then
                local object = text:sub(began, index)
                local id = object:match('"window_id"%s*:%s*"(window:[^"]+)"')
                local window_label = object:match('"label"%s*:%s*"([^"]*)"')
                if id ~= nil and window_label ~= nil then
                    entries[#entries + 1] = { id = id, label = window_label }
                end
                began = nil
            end
        end
    end
    return entries
end

local function window_label_present(entries, wanted)
    for _, entry in ipairs(entries) do
        if entry.label == wanted then
            return true
        end
    end
    return false
end

local function require_root(ctx, action, cwd)
    local first = cwd or context.cwd_of(ctx)
    local tried = {}

    local function attempt(dir)
        if dir == nil or tried[dir] then
            return nil
        end
        tried[dir] = true
        return repo_root(dir)
    end

    local root = attempt(first)
    if root ~= nil then
        return root
    end

    -- A tab can be left open on a directory that is gone, such as a removed
    -- worktree. Try the other panes in the session before giving up.
    local view = rex.session.view {}
    for _, window in ipairs(view.windows or {}) do
        for _, layer in ipairs(window.layers or {}) do
            for _, block in ipairs(layer.blocks or {}) do
                root = attempt(context.block_cwd(block.block_id))
                if root ~= nil then
                    return root
                end
            end
        end
    end

    error(action .. ": no git repository in " .. first, 0)
end

----------------------------------------------------------------------
-- Agents
----------------------------------------------------------------------

-- The server runs with a minimal PATH (/usr/local/bin:/usr/bin:...), so
-- agents are looked up through the user's login shell, like a terminal does.
local function login_shell()
    return os.getenv("SHELL") or "/bin/sh"
end

-- The rex CLI is not on the server's PATH either; resolve it once.
local rex_bin_cache = nil
rex_bin = function()
    if rex_bin_cache ~= nil then
        return rex_bin_cache
    end

    local candidates = {}
    local bin_dir = os.getenv("REX_BIN_DIR")
    if bin_dir ~= nil and bin_dir ~= "" then
        candidates[#candidates + 1] = bin_dir .. "/rex"
    end
    candidates[#candidates + 1] = (os.getenv("HOME") or "")
        .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

    for _, candidate in ipairs(candidates) do
        local probe = rex.exec({ candidate, "version" }, { timeout = 10 })
        if probe ~= nil and probe.ok then
            rex_bin_cache = candidate
            return candidate
        end
    end

    local result = rex.exec({ login_shell(), "-lic", "command -v rex", "find-rex" }, { timeout = 15 })
    if result ~= nil and result.ok then
        local path = trim(result.stdout)
        if path ~= "" then
            rex_bin_cache = path
            return path
        end
    end
    return nil
end

local agent_cache = nil
local agent_cache_at = 0
local AGENT_CACHE_SECONDS = 60

local function read_last_agent()
    local file = io.open(LAST_AGENT_FILE, "r")
    if file == nil then
        return nil
    end
    local name = trim(file:read("*l") or "")
    file:close()
    if name == "" then
        return nil
    end
    return name
end

local function write_last_agent(name)
    rex.exec({ "mkdir", "-p", STATE_DIR }, { timeout = 5 })
    local file = io.open(LAST_AGENT_FILE, "w")
    if file ~= nil then
        file:write(name, "\n")
        file:close()
    end
end

-- Configured agents that are on PATH, in config order. Cached because the
-- login shell takes a couple of seconds to start.
local function installed_agent_names()
    local now = os.time()
    if agent_cache ~= nil and now - agent_cache_at < AGENT_CACHE_SECONDS then
        return agent_cache
    end

    local names = {}
    for _, agent in ipairs(agents) do
        names[#names + 1] = agent.name
    end

    local result = rex.exec({
        login_shell(), "-lic",
        'for a in "$@"; do command -v "$a" >/dev/null 2>&1 && printf "%s\\n" "$a"; done',
        "check-agents", unpack(names),
    }, { timeout = 15 })

    local installed = {}
    if result ~= nil and result.ok then
        for name in result.stdout:gmatch("[^\n]+") do
            installed[#installed + 1] = trim(name)
        end
    end

    agent_cache = installed
    agent_cache_at = now
    return installed
end

-- Installed agents, last used first. The order is computed on every call so a
-- fresh pick is reflected even while the installed list is cached.
local function installed_agents()
    local installed = {}
    for index, name in ipairs(installed_agent_names()) do
        installed[index] = name
    end

    local last = read_last_agent()
    for index, name in ipairs(installed) do
        if name == last then
            table.remove(installed, index)
            table.insert(installed, 1, name)
            break
        end
    end
    return installed
end

local function ensure_agent_available(spec)
    local command = agent_command(spec)
    if command == nil then
        error("worktree: an agent is required", 0)
    end

    for _, name in ipairs(installed_agent_names()) do
        if name == spec then
            return
        end
    end

    -- A configured agent that is missing, or a raw command from the CLI.
    local result = rex.exec({
        login_shell(), "-lic", 'command -v "$1" >/dev/null 2>&1', "check-agent", command[1],
    }, { timeout = 10 })
    if result == nil or not result.ok then
        error("worktree: agent '" .. command[1] .. "' is not on PATH", 0)
    end
end

local function default_agent()
    return read_last_agent() or installed_agents()[1] or agents[1].name
end

----------------------------------------------------------------------
-- Sessions
----------------------------------------------------------------------

local function list_sessions()
    local result, err = rex.call("session.list", {})
    if result == nil then
        error(err, 0)
    end
    return result.sessions or {}
end

local function find_session(label)
    for _, session in ipairs(list_sessions()) do
        if session.label == label then
            return session
        end
    end
    return nil
end

-- Worktree path -> session id, so renaming a session keeps it findable.
local function read_session_map()
    local map = {}
    local file = io.open(SESSION_MAP_FILE, "r")
    if file == nil then
        return map
    end
    for line in file:lines() do
        local path, id = line:match("^(.-)\t(.+)$")
        if path ~= nil and id ~= nil then
            map[path] = id
        end
    end
    file:close()
    return map
end

local function write_session_map(map)
    rex.exec({ "mkdir", "-p", STATE_DIR }, { timeout = 5 })
    local paths = {}
    for path in pairs(map) do
        paths[#paths + 1] = path
    end
    table.sort(paths)

    local file = io.open(SESSION_MAP_FILE, "w")
    if file == nil then
        return
    end
    for _, path in ipairs(paths) do
        file:write(path, "\t", map[path], "\n")
    end
    file:close()
end

local function remember_session(path, session_id)
    local map = read_session_map()
    map[path] = session_id
    write_session_map(map)
end

local function forget_session(path)
    local map = read_session_map()
    if map[path] ~= nil then
        map[path] = nil
        write_session_map(map)
    end
end

-- Find the session for a worktree by its label, falling back to the id it had
-- when it was created (a renamed session no longer matches the label).
local function find_worktree_session(path, label)
    local sessions = list_sessions()

    for _, session in ipairs(sessions) do
        if session.label == label then
            remember_session(path, session.session_id)
            return session
        end
    end

    local mapped = read_session_map()[path]
    if mapped ~= nil then
        for _, session in ipairs(sessions) do
            if session.session_id == mapped then
                return session
            end
        end
        forget_session(path)
    end
    return nil
end

local function known_worktrees(root)
    local result = rex.exec({ "git", "-C", root, "worktree", "list", "--porcelain" }, { timeout = 10 })
    local paths = {}
    if result ~= nil and result.ok then
        for path in result.stdout:gmatch("worktree (.-)\n") do
            paths[path] = true
        end
    end
    return paths
end

-- Workrex config. A repo commits .workrex.lua; .workrex.local.lua overrides it
-- on one machine. The loader runs with a stripped environment, so a repo config
-- cannot reach io, os, or require (Rex runs Lua 5.1, hence loadstring/setfenv).
local CONFIG_KEYS = {
    base = true,
    branch_prefix = true,
    files = true,
    post_create = true,
    setup = true,
    pre_merge = true,
    pre_remove = true,
    env = true,
    port_block = true,
    merge = true,
}

local function string_list(value, name)
    if value == nil then
        return {}
    end
    if type(value) ~= "table" then
        error("workrex: " .. name .. " must be a list of strings", 0)
    end

    local out = {}
    for index, item in ipairs(value) do
        if type(item) ~= "string" then
            error("workrex: " .. name .. " entry " .. index .. " is not a string", 0)
        end
        out[index] = item
    end
    return out
end

local function merge_tables(base, over)
    local out = {}
    for key, value in pairs(base or {}) do
        out[key] = value
    end
    for key, value in pairs(over or {}) do
        if key == "files" or key == "env" then
            out[key] = merge_tables(out[key], value)
        else
            out[key] = value
        end
    end
    return out
end

local function load_config_file(path, sandbox)
    local file = io.open(path, "r")
    if file == nil then
        return nil
    end
    local source = file:read("*a")
    file:close()

    local chunk, err = loadstring(source, "@" .. path)
    if chunk == nil then
        error("workrex: " .. path .. ": " .. tostring(err), 0)
    end
    setfenv(chunk, sandbox)

    local ok, result = pcall(chunk)
    if not ok then
        error("workrex: " .. path .. ": " .. tostring(result), 0)
    end
    if type(result) ~= "table" then
        error("workrex: " .. path .. " must return a table", 0)
    end
    return result
end

local function normalize_config(raw, root)
    for key in pairs(raw) do
        if not CONFIG_KEYS[key] then
            error("workrex: unknown config key '" .. key .. "' in " .. root, 0)
        end
    end

    local files = raw.files or {}
    if type(files) ~= "table" then
        error("workrex: files must be a table", 0)
    end
    if files.copy ~= nil and type(files.copy) ~= "table" then
        error("workrex: files.copy must be a list", 0)
    end
    if files.symlink ~= nil and type(files.symlink) ~= "table" then
        error("workrex: files.symlink must be a list", 0)
    end

    local env = {}
    if raw.env ~= nil then
        if type(raw.env) ~= "table" then
            error("workrex: env must be a table", 0)
        end
        for key, value in pairs(raw.env) do
            if type(key) ~= "string" or type(value) ~= "string" then
                error("workrex: env keys and values must be strings", 0)
            end
            env[key] = value
        end
    end

    local port_block = raw.port_block
    if port_block == nil then
        port_block = 10
    end
    if type(port_block) ~= "number" or port_block < 0 or port_block > 100 then
        error("workrex: port_block must be a number between 0 and 100", 0)
    end

    local strategy = nil
    if raw.merge ~= nil then
        if type(raw.merge) ~= "table" then
            error("workrex: merge must be a table", 0)
        end
        strategy = raw.merge.strategy
        if strategy ~= nil and strategy ~= "merge" and strategy ~= "rebase" and strategy ~= "squash" then
            error("workrex: merge.strategy must be merge, rebase, or squash", 0)
        end
    end

    if raw.base ~= nil and type(raw.base) ~= "string" then
        error("workrex: base must be a string", 0)
    end
    if raw.branch_prefix ~= nil and type(raw.branch_prefix) ~= "string" then
        error("workrex: branch_prefix must be a string", 0)
    end

    return {
        base = raw.base,
        branch_prefix = raw.branch_prefix or "wm/",
        files_given = raw.files ~= nil,
        files = {
            copy = string_list(files.copy, "files.copy"),
            symlink = string_list(files.symlink, "files.symlink"),
        },
        post_create = string_list(raw.post_create, "post_create"),
        setup = string_list(raw.setup, "setup"),
        pre_merge = string_list(raw.pre_merge, "pre_merge"),
        pre_remove = string_list(raw.pre_remove, "pre_remove"),
        env = env,
        port_block = port_block,
        merge_strategy = strategy,
    }
end

local function load_config(root)
    local sandbox = {
        string = string,
        table = table,
        math = math,
        pairs = pairs,
        ipairs = ipairs,
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        error = error,
        assert = assert,
    }

    local project = load_config_file(root .. "/.workrex.lua", sandbox)
    local local_config = load_config_file(root .. "/.workrex.local.lua", sandbox)
    local raw = merge_tables(project or {}, local_config or {})
    return normalize_config(raw, root)
end

local function has_steps(cfg)
    return #cfg.post_create > 0 or #cfg.setup > 0
end

-- Git config helpers. Subsection names may contain dots (valid_name allows
-- them), so quote every subsection. branch."wm/x".workrex-base is the form git
-- reads back with the slash form too.
local function quote_subsection(name)
    return '"' .. name:gsub('"', '\\"') .. '"'
end

local function git_config_get(root, key)
    local result = rex.exec({ "git", "-C", root, "config", "--local", "--get", key }, { timeout = 10 })
    if result == nil or not result.ok then
        return nil
    end
    local value = trim(result.stdout)
    if value == "" then
        return nil
    end
    return value
end

local function git_config_set(root, key, value)
    run_ok({ "git", "-C", root, "config", "--local", key, tostring(value) }, { timeout = 10 })
end

local function meta_key(name, key)
    return "workrex.worktree." .. quote_subsection(name) .. "." .. key
end

local function set_meta(root, name, key, value)
    git_config_set(root, meta_key(name, key), value)
end

local function get_meta(root, name, key)
    return git_config_get(root, meta_key(name, key))
end

local function clear_meta(root, name)
    rex.exec({
        "git", "-C", root, "config", "--local", "--remove-section",
        "workrex.worktree." .. quote_subsection(name),
    }, { timeout = 10 })
end

local function branch_base_key(branch)
    return "branch." .. quote_subsection(branch) .. ".workrex-base"
end

local function set_base(root, branch, base)
    git_config_set(root, branch_base_key(branch), base)
end

local function get_base(root, branch)
    return git_config_get(root, branch_base_key(branch))
end

local function current_branch(root)
    local result = run({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" }, { timeout = 10 })
    if result == nil or not result.ok then
        return nil
    end
    local branch = trim(result.stdout)
    if branch == "" or branch == "HEAD" then
        return nil
    end
    return branch
end

local function shquote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Glob matching for file rules. `*` stays within one segment, `**` crosses
--- segments, and `?` matches one character.
local function glob_to_pattern(glob)
    local out = { "^" }
    local index = 1
    while index <= #glob do
        local char = glob:sub(index, index)
        if char == "*" then
            if glob:sub(index + 1, index + 1) == "*" then
                out[#out + 1] = ".*"
                index = index + 1
                if glob:sub(index + 1, index + 1) == "/" then
                    index = index + 1
                end
            else
                out[#out + 1] = "[^/]*"
            end
        elseif char == "?" then
            out[#out + 1] = "[^/]"
        elseif char:match("[%^%$%(%)%%%.%[%]%+%-]") then
            out[#out + 1] = "%" .. char
        else
            out[#out + 1] = char
        end
        index = index + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

local function list_ignored(root)
    local result = run({
        "git", "-C", root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z",
    }, { timeout = 10 })
    local paths = {}
    if result == nil or not result.ok then
        return paths
    end
    for path in result.stdout:gmatch("([^%z]+)%z") do
        paths[#paths + 1] = path
    end
    return paths
end

local function split_path(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

-- Relative path from one directory to a file or directory inside the repo.
local function relative_path(from_dir, to_path)
    local from = split_path(from_dir)
    local to = split_path(to_path)
    local shared = 0
    while shared + 1 <= #from and shared + 1 <= #to - 1 and from[shared + 1] == to[shared + 1] do
        shared = shared + 1
    end

    local out = {}
    for _ = shared + 1, #from do
        out[#out + 1] = ".."
    end
    for index = shared + 1, #to do
        out[#out + 1] = to[index]
    end
    return table.concat(out, "/")
end

local function copy_rules(cfg)
    if cfg.files_given then
        return cfg.files.copy
    end
    return { ".env*" }
end

local function symlink_rules(cfg)
    return cfg.files.symlink
end

--- Copy and relative-symlink gitignored files from the main checkout into a
--- fresh worktree. Idempotent: an existing destination is left alone.
local function apply_file_rules(root, path, cfg)
    local patterns = {}
    for _, pattern in ipairs(copy_rules(cfg)) do
        if pattern:find("%.%.", 1) or pattern:sub(1, 1) == "/" then
            error("workrex: file pattern escapes the repo: " .. pattern, 0)
        end
        patterns[#patterns + 1] = {
            pattern = glob_to_pattern(pattern),
            literal = pattern:find("[*?]") == nil and pattern or nil,
            mode = "copy",
        }
    end
    for _, pattern in ipairs(symlink_rules(cfg)) do
        if pattern:find("%.%.", 1) or pattern:sub(1, 1) == "/" then
            error("workrex: file pattern escapes the repo: " .. pattern, 0)
        end
        patterns[#patterns + 1] = {
            pattern = glob_to_pattern(pattern),
            literal = pattern:find("[*?]") == nil and pattern or nil,
            mode = "symlink",
        }
    end

    if #patterns == 0 then
        return false
    end

    local lines = {}
    local seen = {}
    local matched = 0
    for _, rel in ipairs(list_ignored(root)) do
        for _, rule in ipairs(patterns) do
            local hit = rel:match(rule.pattern)
            if hit == nil and rule.literal ~= nil and rel:sub(1, #rule.literal + 1) == rule.literal .. "/" then
                hit = rule.literal
            end
            if hit ~= nil and not seen[hit] then
                seen[hit] = true
                matched = matched + 1
                if matched > 200 then
                    return false, "workrex: more than 200 files match the file rules; narrow them"
                end

                local source = root .. "/" .. hit
                local dest = path .. "/" .. hit
                local parent = dest:match("^(.*)/[^/]+$")
                lines[#lines + 1] = "mkdir -p " .. shquote(parent)
                if rule.mode == "copy" then
                    lines[#lines + 1] = "[ -e " .. shquote(dest) .. " ] || cp -pR "
                        .. shquote(source) .. " " .. shquote(dest) .. " || exit 1"
                else
                    local target = relative_path(parent, source)
                    lines[#lines + 1] = "[ -e " .. shquote(dest) .. " ] || [ -L " .. shquote(dest)
                        .. " ] || ln -s " .. shquote(target) .. " " .. shquote(dest) .. " || exit 1"
                end
                break
            end
        end
    end

    -- workmux also links CLAUDE.local.md when the repo ignores it.
    local local_md = root .. "/CLAUDE.local.md"
    local md_file = io.open(local_md, "r")
    if md_file ~= nil then
        md_file:close()
        local ignored = run({ "git", "-C", root, "check-ignore", "-q", "CLAUDE.local.md" }, { timeout = 10 })
        local dest = path .. "/CLAUDE.local.md"
        if ignored ~= nil and ignored.ok then
            lines[#lines + 1] = "[ -e " .. shquote(dest) .. " ] || [ -L " .. shquote(dest)
                .. " ] || ln -s " .. shquote(relative_path(path, local_md)) .. " " .. shquote(dest)
        end
    end

    if #lines == 0 then
        return false
    end

    local script = table.concat(lines, "\n")
    local result = rex.exec({ "bash", "-c", script, "workrex-fileops" }, { timeout = 8 })
    if result == nil then
        return false, "workrex: file rules failed to run"
    end
    if not result.ok then
        return false, "workrex: file rules failed: " .. trim(result.stderr or "")
    end
    return true, matched
end

-- Add a pattern to .git/info/exclude once. Returns true when this call added it.
local function ensure_exclude(root, pattern)
    local info = run({ "git", "-C", root, "rev-parse", "--git-path", "info/exclude" }, { timeout = 10 })
    if info == nil or not info.ok then
        return false
    end
    local path = trim(info.stdout)
    if path:sub(1, 1) ~= "/" then
        path = root .. "/" .. path
    end

    local content = ""
    local file = io.open(path, "r")
    if file ~= nil then
        content = file:read("*a")
        file:close()
    end
    for line in content:gmatch("[^\n]+") do
        if trim(line) == pattern then
            return false
        end
    end

    local out = io.open(path, "a")
    if out == nil then
        return false
    end
    if content ~= "" and content:sub(-1) ~= "\n" then
        out:write("\n")
    end
    out:write(pattern, "\n")
    out:close()
    return true
end

local function remove_exclude(root, pattern)
    local info = run({ "git", "-C", root, "rev-parse", "--git-path", "info/exclude" }, { timeout = 10 })
    if info == nil or not info.ok then
        return
    end
    local path = trim(info.stdout)
    if path:sub(1, 1) ~= "/" then
        path = root .. "/" .. path
    end

    local file = io.open(path, "r")
    if file == nil then
        return
    end
    local kept = {}
    for line in file:lines() do
        if trim(line) ~= pattern then
            kept[#kept + 1] = line
        end
    end
    file:close()

    local out = io.open(path, "w")
    if out == nil then
        return
    end
    for _, line in ipairs(kept) do
        out:write(line, "\n")
    end
    out:close()
end

local function write_env(root, name, path, branch, base, port, cfg)
    local dir = path .. "/.workrex"
    rex.exec({ "mkdir", "-p", dir }, { timeout = 5 })

    local values = {
        WORKREX_WORKSPACE_PATH = path,
        WORKREX_ROOT_PATH = root,
        WORKREX_WORKSPACE_NAME = name,
        WORKREX_BRANCH = branch,
        WORKREX_BASE_BRANCH = base or "",
    }
    if port ~= nil and port > 0 then
        values.WORKREX_PORT = tostring(port)
        values.WORKREX_PORTS = tostring(port) .. ":" .. tostring(port + (cfg.port_block or 10) - 1)
    end
    for key, value in pairs(cfg.env or {}) do
        values[key] = value
    end

    local keys = {}
    for key in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local out = io.open(dir .. "/env", "w")
    if out == nil then
        return
    end
    out:write("# Generated by workrex. Source this file to load the workspace env.\n")
    for _, key in ipairs(keys) do
        out:write("export ", key, "=", shquote(values[key]), "\n")
    end
    out:close()
end

-- First free block of `size` ports at or after the repo counter. The counter
-- only moves forward, so a removed worktree never hands a live dev server's
-- ports to a new tree. A /dev/tcp probe catches processes outside workrex.
local function allocate_ports(root, name, size)
    if size == nil or size <= 0 then
        return nil
    end
    local start = tonumber(git_config_get(root, "workrex.ports.next") or "") or 31000

    local script = table.concat({
        "base=$1; size=$2",
        "for i in $(seq 1 50); do",
        "  free=1; p=$base",
        "  while [ $p -lt $((base+size)) ]; do",
        "    if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then free=0; exec 3>&-; break; fi",
        "    p=$((p+1))",
        "  done",
        "  if [ $free -eq 1 ]; then echo $base; exit 0; fi",
        "  base=$((base+size))",
        "done",
        "exit 1",
    }, "\n")

    local result = run({ "bash", "-c", script, "workrex-ports", tostring(start), tostring(size) }, { timeout = 10 })
    if result == nil or not result.ok then
        return nil
    end
    local port = tonumber(trim(result.stdout))
    if port == nil then
        return nil
    end

    git_config_set(root, "workrex.ports.next", port + size)
    set_meta(root, name, "ports", port)
    return port
end

local function rollback_add(root, name, path, branch, added_exclude, added_local_exclude)
    rex.exec({ "git", "-C", root, "worktree", "remove", "--force", path }, { timeout = 20 })
    rex.exec({ "git", "-C", root, "branch", "-D", branch }, { timeout = 10 })
    clear_meta(root, name)
    rex.exec({ "git", "-C", root, "config", "--local", "--unset", branch_base_key(branch) }, { timeout = 10 })
    if added_exclude then
        remove_exclude(root, ".workrex/")
    end
    if added_local_exclude then
        remove_exclude(root, ".workrex.local.lua")
    end
end


-- Wrap a command so it runs with the workspace env loaded. Terminal blocks have
-- no env option, so the generated wrapper is the only way to export.
local function env_command(path, command)
    local argv = {
        "sh", "-c",
        'set -a; . "$1/.workrex/env" 2>/dev/null; set +a; shift; exec "$@"',
        "workrex-env", path,
    }
    for _, item in ipairs(command) do
        argv[#argv + 1] = item
    end
    return argv
end

local function env_pane(path, label, command)
    return terminal_pane(path, label, env_command(path, command))
end

local function setup_pane(path, script)
    return rex.layout.block {
        flavor = context.shell,
        label = "setup",
        options = {
            cwd = path,
            command = { "sh", "-c", script },
            exit = { on_completion = false },
        },
    }
end

--- The setup window script. Every step prints its command, keeps its output on
--- screen, and marks the worktree failed before the retry prompt. The agent
--- window is created by workrex_setup_done, which the pane calls only after
--- every step succeeded, so a failure can never start an agent.
local function build_setup_script(cfg, root, path, name, spec)
    local key = shquote(meta_key(name, "setup"))
    local lines = {
        "#!/bin/sh",
        "set -u",
        "cd " .. shquote(path) .. " || exit 9",
        ". ./.workrex/env 2>/dev/null || true",
        "say() { printf '\\n[workrex] %s\\n' \"$1\"; }",
        "mark_failed() { git -C " .. shquote(root) .. " config --local " .. key .. " failed 2>/dev/null || true; }",
        "run_steps() {",
    }

    local function add_step(kind, cmd)
        lines[#lines + 1] = "  say " .. shquote(kind .. ": " .. cmd)
        lines[#lines + 1] = "  sh -c " .. shquote(cmd)
            .. " || { printf '\\n[workrex] FAILED: %s (exit %s)\\n' " .. shquote(cmd)
            .. " \"$?\"; mark_failed; return 1; }"
    end

    for _, cmd in ipairs(cfg.post_create) do
        add_step("post-create", cmd)
    end
    for _, cmd in ipairs(cfg.setup) do
        add_step("setup", cmd)
    end

    for _, line in ipairs({
        "}",
        "",
        "ok=0",
        "while :; do",
        "  if run_steps; then ok=1; break; fi",
        "  printf 'fix the problem, press Enter to retry, or Ctrl-D to abandon\\n'",
        "  read -r _ || break",
        "done",
        "if [ \"$ok\" != 1 ]; then exec \"${SHELL:-/bin/sh}\" -l; fi",
        "git -C " .. shquote(root) .. " config --local " .. key .. " running 2>/dev/null || true",
        "rex do -s \"$REX_SESSION\" workrex_setup_done name=" .. shquote(name)
            .. " agent=" .. shquote(spec) .. " cwd=" .. shquote(path),
        "exec \"${SHELL:-/bin/sh}\" -l",
    }) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

local function create_session(root, name, path, spec, cfg, gated)
    local label = session_label(root, name)
    local command = agent_command(spec)

    local windows
    if gated then
        windows = {
            { window_label = "nvim", layout = env_pane(path, "nvim", editor) },
            { window_label = "setup", layout = setup_pane(path, build_setup_script(cfg, root, path, name, spec)) },
        }
    else
        windows = {
            { window_label = "nvim", layout = env_pane(path, "nvim", editor) },
            { window_label = spec, layout = env_pane(path, spec, command) },
        }
    end

    local created, err = rex.call("session.create", {
        label = label,
        initial_windows = windows,
    })
    if created == nil then
        error(err, 0)
    end
    return label, created
end

local function default_branch(root)
    local head = run({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { timeout = 10 })
    if head ~= nil and head.ok then
        local name = trim(head.stdout):gsub("^origin/", "")
        if name ~= "" then
            return name
        end
    end
    for _, candidate in ipairs({ "main", "master" }) do
        local present = run({ "git", "-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" .. candidate }, { timeout = 10 })
        if present ~= nil and present.ok then
            return candidate
        end
    end
    return nil
end

local function worktree_for_branch(root, branch)
    local result = run({ "git", "-C", root, "worktree", "list", "--porcelain" }, { timeout = 10 })
    if result == nil or not result.ok then
        return nil
    end
    local path = nil
    for line in result.stdout:gmatch("[^\n]+") do
        local worktree = line:match("^worktree (.-)$")
        if worktree ~= nil then
            path = worktree
        elseif line == "branch refs/heads/" .. branch and path ~= nil then
            return path
        end
    end
    return nil
end

local function worktree_name(args, cwd)
    if args.name ~= nil then
        return args.name
    end
    local dir = cwd or ""
    local name = dir:match("__worktrees/([^/]+)$")
    if name ~= nil and valid_name(name) then
        return name
    end
    error("workrex: pass name= (not inside a worktree)", 0)
end

local function has_changes(path)
    local result = run({ "git", "-C", path, "status", "--porcelain" }, { timeout = 10 })
    if result == nil or not result.ok then
        return false
    end
    return trim(result.stdout) ~= ""
end

local function has_tracked_changes(path)
    local result = run({ "git", "-C", path, "status", "--porcelain" }, { timeout = 10 })
    if result == nil or not result.ok then
        return false
    end
    for line in result.stdout:gmatch("[^\n]+") do
        if line:sub(1, 2) ~= "??" then
            return true
        end
    end
    return false
end


-- Merge a worktree branch into its base. Guards run in the action; hooks and
-- the merge itself stream in a popup so a slow lint never eats the action.
rex.action {
    name = "worktree_merge",
    title = "Worktree: Merge and clean up",
    description = "Merge a worktree branch into its base, then remove the worktree.",
    category = "Worktrees",
    keywords = "git worktree merge squash rebase cleanup",
    args = {
        name = "string?",
        into = "string?",
        strategy = "string?",
        allow_dirty = "boolean?",
        keep = "boolean?",
        cwd = "string?",
    },
    run = function(ctx, args)
        local root = require_root(ctx, "worktree_merge", args.cwd)
        local name = worktree_name(args, args.cwd or context.cwd_of(ctx))
        local path, branch = worktree_paths(root, name)
        if path == root then
            error("worktree_merge: the main worktree has nothing to merge", 0)
        end
        if not known_worktrees(root)[path] then
            error("worktree_merge: " .. path .. " is not a worktree of " .. root, 0)
        end

        local existing = find_worktree_session(path, session_label(root, name))
        if existing ~= nil and existing.session_id == ctx.session_id then
            error("worktree_merge: this worktree is open in the current session; switch sessions first", 0)
        end

        local cfg = load_config(root)
        local target = args.into or get_base(root, branch) or default_branch(root)
        if target == nil then
            error("worktree_merge: no base branch recorded; pass into=", 0)
        end
        if target == branch then
            error("worktree_merge: cannot merge " .. branch .. " into itself", 0)
        end
        local state = get_meta(root, name, "setup")
        if state == "running" then
            error("worktree_merge: setup is still running for " .. name .. "; finish it first", 0)
        end

        local target_path = worktree_for_branch(root, target) or root
        if has_changes(path) and not args.allow_dirty then
            error("worktree_merge: uncommitted changes in " .. path .. "; commit them or pass allow_dirty=true", 0)
        end
        if has_tracked_changes(target_path) then
            error("worktree_merge: " .. target_path .. " has tracked changes; commit or stash them", 0)
        end

        local strategy = args.strategy or cfg.merge_strategy or "merge"
        if strategy ~= "merge" and strategy ~= "rebase" and strategy ~= "squash" then
            error("worktree_merge: strategy must be merge, rebase, or squash", 0)
        end

        local bin = rex_bin()
        if bin == nil then
            error("worktree_merge: the rex CLI is not on PATH", 0)
        end

        local lines = {
            "#!/bin/bash",
            "set -u",
            "fail() { printf '\\n[workrex] MERGE FAILED: %s\\n' \"$1\"; read -r _; exit 1; }",
            "dirty() { [ -n \"$(git -C \"$1\" status --porcelain)\" ]; }",
            "tracked() { [ -n \"$(git -C \"$1\" status --porcelain | grep -v '^??' || true)\" ]; }",
        }
        local allow = args.allow_dirty and 1 or 0
        lines[#lines + 1] = "[ " .. allow .. " = 1 ] || ! dirty " .. shquote(path)
            .. " || fail 'uncommitted changes in " .. path:gsub("'", "") .. "'"
        lines[#lines + 1] = "! tracked " .. shquote(target_path)
            .. " || fail 'target has tracked changes'"

        for _, hook in ipairs(cfg.pre_merge) do
            lines[#lines + 1] = "( cd " .. shquote(path) .. " && . ./.workrex/env 2>/dev/null; sh -c "
                .. shquote(hook) .. " ) || fail " .. shquote("pre_merge hook failed: " .. hook)
        end

        if strategy == "rebase" then
            lines[#lines + 1] = "git -C " .. shquote(path) .. " rebase " .. shquote(target)
                .. " || { git -C " .. shquote(path) .. " rebase --abort; fail 'rebase conflict; resolve in "
                .. path:gsub("'", "") .. " and rerun'; }"
            lines[#lines + 1] = "git -C " .. shquote(target_path) .. " merge --ff-only " .. shquote(branch)
                .. " || fail 'fast-forward after rebase failed'"
        elseif strategy == "squash" then
            lines[#lines + 1] = "git -C " .. shquote(target_path) .. " merge --squash " .. shquote(branch)
                .. " || { git -C " .. shquote(target_path) .. " reset --hard; fail 'squash conflict'; }"
            lines[#lines + 1] = "git -C " .. shquote(target_path) .. " commit -m "
                .. shquote("Merge branch '" .. branch .. "' (squash)") .. " || fail 'squash commit failed'"
        else
            lines[#lines + 1] = "git -C " .. shquote(target_path) .. " merge --no-edit " .. shquote(branch)
                .. " || { git -C " .. shquote(target_path) .. " merge --abort; fail 'conflicts; resolve in "
                .. path:gsub("'", "") .. " and rerun'; }"
        end

        lines[#lines + 1] = "printf '\\n[workrex] merged %s into %s\\n' "
            .. shquote(branch) .. " " .. shquote(target)
        lines[#lines + 1] = shquote(bin) .. " do worktree_merge_finish name=" .. shquote(name)
            .. " keep=" .. (args.keep and "true" or "false") .. " cwd=" .. shquote(path)
        lines[#lines + 1] = "printf '\\n[workrex] done. Press Enter to close.\\n'"
        lines[#lines + 1] = "read -r _ || true"

        context.popup(ctx, { "bash", "-c", table.concat(lines, "\n") }, "merge " .. name,
            { 0.1, 0.1, 0.8, 0.8 })
        return { name = name, into = target, strategy = strategy, started = true }
    end,
}

-- Teardown after a successful merge. Runs unscoped from the merge popup, so it
-- must never touch the caller's session.
rex.action {
    name = "worktree_merge_finish",
    title = "Worktree: Merge finish",
    description = "Remove a merged worktree, close its session, and delete the branch when merged.",
    category = "Worktrees",
    keywords = "workreex merge finish cleanup",
    args = { name = "string", keep = "boolean?", cwd = "string?" },
    run = function(ctx, args)
        local root = require_root(ctx, "worktree_merge_finish", args.cwd)
        local path, branch = worktree_paths(root, args.name)
        if args.keep then
            return { name = args.name, kept = true }
        end

        local existing = find_worktree_session(path, session_label(root, args.name))
        local session_killed = false
        if existing ~= nil and existing.session_id ~= ctx.session_id then
            local bin = rex_bin()
            if bin ~= nil then
                run_ok({ bin, "kill", existing.session_id }, { timeout = 20 })
                session_killed = true
            end
        end

        local parent, project = root:match("^(.*)/([^/]+)$")
        local trash = (parent or ".") .. "/.workrex-trash-" .. (project or "repo") .. "-" .. args.name
        if io.open(trash, "r") ~= nil then
            trash = trash .. "-" .. tostring(os.time())
        end
        run_ok({ "mv", path, trash }, { timeout = 20 })
        run_ok({ "git", "-C", root, "worktree", "prune" }, { timeout = 20 })
        rex.exec({ "sh", "-c", 'nohup rm -rf "$1" >/dev/null 2>&1 &', "workrex-cleanup", trash }, { timeout = 5 })

        local branch_result = run({ "git", "-C", root, "branch", "-d", branch }, { timeout = 10 })
        forget_session(path)
        clear_meta(root, args.name)

        return {
            name = args.name,
            worktree = path,
            branch = branch,
            session_killed = session_killed,
            branch_deleted = branch_result ~= nil and branch_result.ok,
        }
    end,
}


-- Create a worktree and its session in one go.
rex.action {
    name = "worktree_add",
    title = "Worktree: New Session",
    description = "Create a git worktree and open it as a session with nvim and an agent window.",
    category = "Worktrees",
    keywords = "git worktree workmux session nvim agent parallel",
    args = { name = "string", agent = "string?", base = "string?", cwd = "string?", no_setup = "boolean?" },
    run = function(ctx, args)
        if not valid_name(args.name) then
            error("worktree_add: use only letters, digits, dots, dashes, and underscores", 0)
        end

        local root = require_root(ctx, "worktree_add", args.cwd)
        local cfg = load_config(root)
        local path, branch = worktree_paths(root, args.name)
        local label = session_label(root, args.name)
        if find_worktree_session(path, label) ~= nil then
            error("worktree_add: session " .. label .. " already exists; use worktree_open instead", 0)
        end
        if known_worktrees(root)[path] or io.open(path .. "/.git", "r") ~= nil then
            error("worktree_add: " .. path .. " already exists; use worktree_open instead", 0)
        end

        local spec = args.agent or default_agent()
        ensure_agent_available(spec)

        local base = args.base or cfg.base
        if base == nil then
            base = current_branch(root)
            if base == nil then
                error("worktree_add: detached HEAD; pass base=", 0)
            end
        end

        -- Record the base before the checkout, so a failure mid-add still
        -- leaves the merge target on record.
        set_base(root, branch, base)
        local added_exclude = ensure_exclude(root, ".workrex/")
        local added_local_exclude = ensure_exclude(root, ".workrex.local.lua")

        local ok, add_err = pcall(function()
            run_ok({
                "git", "-C", root, "worktree", "add", "-b", branch, path, base,
            }, { timeout = 20 })
        end)
        if not ok then
            rex.exec({ "git", "-C", root, "config", "--local", "--unset", branch_base_key(branch) }, { timeout = 10 })
            if added_exclude then remove_exclude(root, ".workrex/") end
            if added_local_exclude then remove_exclude(root, ".workrex.local.lua") end
            error(add_err, 0)
        end

        local setup_state = "skipped"
        if has_steps(cfg) and not args.no_setup then
            setup_state = "running"
        end

        set_meta(root, args.name, "base", base)
        set_meta(root, args.name, "created", os.date("!%Y-%m-%dT%H:%M:%SZ"))
        set_meta(root, args.name, "agent", spec)
        set_meta(root, args.name, "setup", setup_state)

        local port = allocate_ports(root, args.name, cfg.port_block)
        write_env(root, args.name, path, branch, base, port, cfg)

        local files_ok, files_err = apply_file_rules(root, path, cfg)
        if not files_ok and files_err ~= nil then
            rollback_add(root, args.name, path, branch, added_exclude, added_local_exclude)
            error(files_err, 0)
        end

        local ok_session, label_or_err, created = pcall(
            create_session, root, args.name, path, spec, cfg, setup_state == "running")
        if not ok_session then
            rollback_add(root, args.name, path, branch, added_exclude, added_local_exclude)
            error(label_or_err, 0)
        end

        write_last_agent(spec)
        remember_session(path, created.session_id)
        set_meta(root, args.name, "session-id", created.session_id)

        return {
            name = args.name,
            worktree = path,
            branch = branch,
            label = label_or_err,
            session_id = created.session_id,
            windows = created.initial_windows,
            base = base,
            port = port or 0,
            setup = setup_state,
        }
    end,
}

-- Open an existing worktree as a session, reusing a live one when present.
rex.action {
    name = "worktree_open",
    title = "Worktree: Open Session",
    description = "Open an existing worktree as a session, or return its live session.",
    category = "Worktrees",
    keywords = "git worktree open session switch existing",
    args = { name = "string", agent = "string?", cwd = "string?" },
    run = function(ctx, args)
        if not valid_name(args.name) then
            error("worktree_open: use only letters, digits, dots, dashes, and underscores", 0)
        end

        local root = require_root(ctx, "worktree_open", args.cwd)
        local path, branch = worktree_paths(root, args.name)
        local label = session_label(root, args.name)

        local existing = find_worktree_session(path, label)
        if existing ~= nil then
            local setup_state = get_meta(root, args.name, "setup") or "skipped"
            local entries = window_entries(label)
            return { name = args.name, worktree = path, branch = branch, label = label,
                session_id = existing.session_id, existing = true,
                setup = setup_state,
                abandoned = setup_state == "running" and not window_label_present(entries, "setup") }
        end

        if not known_worktrees(root)[path] then
            error("worktree_open: " .. path .. " is not a worktree of " .. root, 0)
        end

        local spec = args.agent or default_agent()
        ensure_agent_available(spec)

        local cfg = load_config(root)
        local state = get_meta(root, args.name, "setup") or "skipped"
        local gated = state ~= "ok" and has_steps(cfg)
        if gated then
            set_meta(root, args.name, "setup", "running")
        end
        local _, created = create_session(root, args.name, path, spec, cfg, gated)
        write_last_agent(spec)
        remember_session(path, created.session_id)

        -- Backfill state for worktrees created before workrex existed.
        if get_meta(root, args.name, "agent") == nil then
            set_meta(root, args.name, "agent", spec)
        end
        if get_meta(root, args.name, "setup") == nil then
            set_meta(root, args.name, "setup", "skipped")
        end
        set_meta(root, args.name, "session-id", created.session_id)

        return {
            name = args.name,
            worktree = path,
            branch = branch,
            label = label,
            session_id = created.session_id,
            windows = created.initial_windows,
            existing = false,
            setup = get_meta(root, args.name, "setup") or "skipped",
        }
    end,
}

rex.action {
    name = "worktree_remove",
    title = "Worktree: Remove Session",
    description = "Remove a worktree, close its session, and delete the branch when it is merged.",
    category = "Worktrees",
    keywords = "git worktree remove cleanup session merged kill",
    args = { name = "string", force = "boolean?", cwd = "string?" },
    run = function(ctx, args)
        if not valid_name(args.name) then
            error("worktree_remove: use only letters, digits, dots, dashes, and underscores", 0)
        end

        local root = require_root(ctx, "worktree_remove", args.cwd)
        local path, branch = worktree_paths(root, args.name)
        local label = session_label(root, args.name)
        local cfg = load_config(root)

        local existing = find_worktree_session(path, label)
        if existing ~= nil and existing.session_id == ctx.session_id then
            error("worktree_remove: this worktree is open in the current session; switch sessions first", 0)
        end

        if get_meta(root, args.name, "setup") == "running" and not args.force then
            error("worktree_remove: setup is still running for " .. args.name
                .. "; wait for it or pass force=true", 0)
        end
        if has_changes(path) and not args.force then
            error("worktree_remove: uncommitted changes in " .. path
                .. "; commit them or pass force=true", 0)
        end

        -- pre_remove hooks run in the live worktree before anything is killed.
        for _, hook in ipairs(cfg.pre_remove) do
            local command = "cd " .. shquote(path) .. " && " .. hook
            run_ok({
                "env",
                "WORKREX_WORKSPACE_PATH=" .. path,
                "WORKREX_ROOT_PATH=" .. root,
                "WORKREX_WORKSPACE_NAME=" .. args.name,
                "WORKREX_BRANCH=" .. branch,
                login_shell(), "-lic", command,
            }, { timeout = 25 })
        end

        if existing ~= nil then
            local bin = rex_bin()
            if bin == nil then
                error("worktree_remove: the rex CLI is not on PATH", 0)
            end
            run_ok({ bin, "kill", existing.session_id }, { timeout = 20 })
        end

        -- Quarantine: rename first so a pane still holding the directory cannot
        -- block removal, then let git prune the stale registration. The trash is
        -- deleted in the background because node_modules can exceed the budget.
        local parent, project = root:match("^(.*)/([^/]+)$")
        local trash = (parent or ".") .. "/.workrex-trash-" .. (project or "repo") .. "-" .. args.name
        if io.open(trash, "r") ~= nil then
            trash = trash .. "-" .. tostring(os.time())
        end
        run_ok({ "mv", path, trash }, { timeout = 20 })
        run_ok({ "git", "-C", root, "worktree", "prune" }, { timeout = 20 })
        rex.exec({ "sh", "-c", 'nohup rm -rf "$1" >/dev/null 2>&1 &', "workrex-cleanup", trash }, { timeout = 5 })

        forget_session(path)
        clear_meta(root, args.name)

        -- The branch only goes when it is already merged.
        local branch_result = run({ "git", "-C", root, "branch", "-d", branch }, { timeout = 10 })

        return {
            name = args.name,
            worktree = path,
            branch = branch,
            session_killed = existing ~= nil,
            branch_deleted = branch_result ~= nil and branch_result.ok,
        }
    end,
}

-- Release the agent after the setup window reports success. The marker is
-- written last, so setup == ok implies the agent window exists.
rex.action {
    name = "workrex_setup_done",
    title = "Worktree: Setup done",
    description = "Add the agent window after setup succeeds. Called by the setup pane.",
    category = "Worktrees",
    keywords = "workrex setup done agent gate",
    args = { name = "string", agent = "string?", cwd = "string?" },
    run = function(ctx, args)
        local root = require_root(ctx, "workrex_setup_done", args.cwd)
        local path = worktree_paths(root, args.name)
        local label = session_label(root, args.name)
        if find_worktree_session(path, label) == nil then
            error("workrex_setup_done: no session for " .. label, 0)
        end
        local spec = args.agent or get_meta(root, args.name, "agent") or default_agent()
        local bin = rex_bin()
        if bin == nil then
            error("workrex_setup_done: the rex CLI is not on PATH", 0)
        end

        local entries = window_entries(label)
        if window_label_present(entries, spec) then
            set_meta(root, args.name, "setup", "ok")
            return { already = true, agent = spec }
        end

        local command = agent_command(spec)
        local argv = { bin, "window", "new", "-s", label, spec, "--focus=false", "-c", path, "--" }
        for _, item in ipairs(env_command(path, command)) do
            argv[#argv + 1] = item
        end
        local added = rex.exec(argv, { timeout = 20 })
        if added == nil or not added.ok then
            set_meta(root, args.name, "setup", "failed")
            error("workrex_setup_done: cannot add the agent window: "
                .. trim((added and added.stderr) or "rex window new failed"), 0)
        end

        -- Close the previous agent window only after the new one exists.
        local previous = get_meta(root, args.name, "agent")
        if previous ~= nil and previous ~= spec then
            for _, entry in ipairs(entries) do
                if entry.label == previous then
                    rex.exec({ bin, "window", "close", "-s", label, entry.id }, { timeout = 10 })
                end
            end
        end

        set_meta(root, args.name, "agent", spec)
        set_meta(root, args.name, "setup", "ok")
        return { agent = spec }
    end,
}

-- Rerun setup in a fresh window. Bound to C-space>s.
rex.action {
    name = "workrex_setup",
    title = "Worktree: Rerun setup",
    description = "Open a fresh setup window for the current worktree and rerun its config.",
    category = "Worktrees",
    keywords = "workrex setup rerun retry",
    args = { name = "string?", cwd = "string?" },
    run = function(ctx, args)
        local root = require_root(ctx, "workrex_setup", args.cwd)
        local name = args.name
        if name == nil then
            local cwd = args.cwd or context.cwd_of(ctx)
            name = cwd and cwd:match("__worktrees/([^/]+)$")
        end
        if name == nil or not valid_name(name) then
            error("workrex_setup: run inside a worktree session or pass name=", 0)
        end

        local path, branch = worktree_paths(root, name)
        local cfg = load_config(root)
        if not has_steps(cfg) then
            return { name = name, setup = "skipped" }
        end

        local existing = find_worktree_session(path, session_label(root, name))
        set_meta(root, name, "setup", "running")
        local spec = get_meta(root, name, "agent") or default_agent()
        local script = build_setup_script(cfg, root, path, name, spec)

        if existing ~= nil then
            if ctx.session_id ~= nil and ctx.session_id ~= existing.session_id then
                error("workrex_setup: switch to " .. existing.label
                    .. " first (C-space>f), or run with -s", 0)
            end
            -- Replace the previous setup window so reruns do not leave a trail
            -- of identical tabs. Only close when the label is unambiguous.
            local bin = rex_bin()
            if bin == nil then
                error("workrex_setup: the rex CLI is not on PATH", 0)
            end
            for _, entry in ipairs(window_entries(existing.label)) do
                if entry.label == "setup" then
                    rex.exec({ bin, "window", "close", "-s", existing.label, entry.id }, { timeout = 10 })
                end
            end
            local argv = { bin, "window", "new", "-s", existing.label, "setup", "-c", path, "--" }
            for _, item in ipairs({ "sh", "-c", script }) do
                argv[#argv + 1] = item
            end
            local added = rex.exec(argv, { timeout = 20 })
            if added == nil or not added.ok then
                error("workrex_setup: cannot open the setup window: "
                    .. trim((added and added.stderr) or "rex window new failed"), 0)
            end
            return { name = name, session_id = existing.session_id, setup = "running" }
        end

        local label, created = create_session(root, name, path, spec, cfg, true)
        remember_session(path, created.session_id)
        return { name = name, label = label, session_id = created.session_id, setup = "running" }
    end,
}


----------------------------------------------------------------------
-- One-key triggers: floating pickers
----------------------------------------------------------------------

local function popup_agents()
    return table.concat(installed_agents(), "\n")
end

rex.action {
    name = "worktree_add_prompt",
    title = "Worktree: New Session (ask)…",
    description = "Pick an agent and type a name, then create the worktree session.",
    category = "Worktrees",
    keywords = "git worktree new session agent prompt",
    run = function(ctx)
        require_root(ctx, "worktree_add_prompt")

        local script = table.concat({
            'agent=$(printf "%s\\n" "$1" | fzf --prompt="agent> ") || exit 0',
            '[ -n "$agent" ] || exit 0',
            'printf "worktree name: "',
            'read -r name || exit 1',
            '[ -n "$name" ] || exit 0',
            'mkdir -p "$(dirname "$3")" 2>/dev/null',
            'out=$(rex do -s "$2" worktree_add name="$name" agent="$agent" 2>&1)',
            'code=$?',
            'if [ "$code" -ne 0 ]; then',
            '  printf "[%s] add %s (%s) failed:\\n%s\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$name" "$agent" "$out" >> "$3"',
            '  printf "\\n%s\\n\\nPress Enter to close." "$out"',
            '  read -r _',
            '  exit "$code"',
            'fi',
            'printf "[%s] add %s (%s) ok (setup may still be running)\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$name" "$agent" >> "$3"',
        }, "\n")

        context.popup(
            ctx,
            { "sh", "-c", script, "worktree-add", popup_agents(), ctx.session_id, LOG_FILE },
            "worktree add",
            { 0.3, 0.28, 0.4, 0.3 }
        )
    end,
}

rex.action {
    name = "worktree_open_prompt",
    title = "Worktree: Open Session (pick)…",
    description = "Pick an existing worktree; open it as a session or show its live one.",
    category = "Worktrees",
    keywords = "git worktree open pick session switch",
    run = function(ctx)
        local root = require_root(ctx, "worktree_open_prompt")

        local script = table.concat({
            'cd "$1" || exit 1',
            'labels=$(rex ls --json | jq -r \'.sessions[].label\') || exit 1',
            'entries=""',
            'for p in $(git worktree list --porcelain | awk \'/^worktree /{print $2}\' | grep \'__worktrees/\'); do',
            '  n=$(basename "$p")',
            '  if printf \'%s\\n\' "$labels" | grep -qx "$4/$n"; then',
            '    entries="${entries}${n}    [session]\\n"',
            '  else',
            '    entries="${entries}${n}\\n"',
            '  fi',
            "done",
            'sel=$(printf "%b" "$entries" | fzf --prompt="worktree> ") || exit 0',
            '[ -n "$sel" ] || exit 0',
            'name=${sel%% *}',
            'case "$sel" in',
            '  *"[session]"*)',
            '    printf "\\n%s is already open. Switch with C-space+f.\\nPress Enter to close." "$name"',
            '    read -r _ || true',
            '    exit 0',
            '    ;;',
            "esac",
            'agent=$(printf "%s\\n" "$2" | fzf --prompt="agent for $name> ") || exit 0',
            '[ -n "$agent" ] || exit 0',
            'mkdir -p "$(dirname "$5")" 2>/dev/null',
            'out=$(rex do -s "$3" worktree_open name="$name" agent="$agent" 2>&1)',
            'code=$?',
            'if [ "$code" -ne 0 ]; then',
            '  printf "[%s] open %s (%s) failed:\\n%s\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$name" "$agent" "$out" >> "$5"',
            '  printf "\\n%s\\n\\nPress Enter to close." "$out"',
            '  read -r _',
            '  exit "$code"',
            'fi',
            'printf "[%s] open %s (%s) ok\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$name" "$agent" >> "$5"',
        }, "\n")

        context.popup(
            ctx,
            { "sh", "-c", script, "worktree-open", root, popup_agents(), ctx.session_id, project_name(root), LOG_FILE },
            "worktree open",
            { 0.2, 0.15, 0.6, 0.6 }
        )
    end,
}

rex.action {
    name = "worktree_remove_prompt",
    title = "Worktree: Remove Session (pick)…",
    description = "Pick a worktree, then remove it and close its session.",
    category = "Worktrees",
    keywords = "git worktree remove picker fzf cleanup session",
    run = function(ctx)
        local root = require_root(ctx, "worktree_remove_prompt")

        local script = table.concat({
            'cd "$1" || exit 1',
            'sel=$(git worktree list --porcelain | awk \'/^worktree /{print $2}\' '
                .. "| grep '__worktrees/' | sed 's#.*/##' | sort "
                .. "| fzf --prompt='remove worktree> ') || exit 0",
            '[ -z "$sel" ] && exit 0',
            'mkdir -p "$(dirname "$3")" 2>/dev/null',
            'out=$(rex do -s "$2" worktree_remove name="$sel" 2>&1)',
            'code=$?',
            'if [ "$code" -ne 0 ]; then',
            '  printf "[%s] remove %s failed:\\n%s\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$sel" "$out" >> "$3"',
            '  printf "\\n%s\\n\\nPress Enter to close." "$out"',
            '  read -r _',
            '  exit "$code"',
            'fi',
            'printf "[%s] remove %s ok\\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$sel" >> "$3"',
        }, "\n")

        context.popup(
            ctx,
            { "sh", "-c", script, "worktree-remove", root, ctx.session_id, LOG_FILE },
            "worktree remove",
            { 0.2, 0.15, 0.6, 0.5 }
        )
    end,
}


rex.action {
    name = "worktree_merge_prompt",
    title = "Worktree: Merge (pick)…",
    description = "Pick a worktree and a strategy, then merge and clean up.",
    category = "Worktrees",
    keywords = "git worktree merge picker squash rebase",
    run = function(ctx)
        local root = require_root(ctx, "worktree_merge_prompt")
        local script = table.concat({
            'cd "$1" || exit 1',
            'sel=$(git worktree list --porcelain | awk \'/^worktree /{print $2}\' '
                .. "| grep '__worktrees/' | sed 's#.*/##' | sort "
                .. "| fzf --prompt='merge worktree> ') || exit 0",
            '[ -z "$sel" ] && exit 0',
            'strategy=$(printf "merge\nrebase\nsquash\n" | fzf --prompt="strategy> ") || exit 0',
            '[ -z "$strategy" ] && exit 0',
            'mkdir -p "$(dirname "$3")" 2>/dev/null',
            'out=$(rex do -s "$2" worktree_merge name="$sel" strategy="$strategy" cwd="$1" 2>&1)',
            'code=$?',
            'if [ "$code" -ne 0 ]; then',
            '  printf "[%s] merge %s (%s) failed:\n%s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$sel" "$strategy" "$out" >> "$3"',
            '  printf "\n%s\n\nPress Enter to close." "$out"',
            '  read -r _',
            '  exit "$code"',
            'fi',
            'printf "[%s] merge %s (%s) started\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$sel" "$strategy" >> "$3"',
        }, "\n")

        context.popup(
            ctx,
            { "sh", "-c", script, "worktree-merge", root, ctx.session_id, LOG_FILE },
            "worktree merge",
            { 0.2, 0.15, 0.6, 0.5 }
        )
    end,
}

rex.bind("ctrl+space>m", "worktree_merge_prompt")
rex.bind("ctrl+space>s", "workrex_setup")
rex.bind("ctrl+space>w", "worktree_add_prompt")
rex.bind("ctrl+space>o", "worktree_open_prompt")
rex.bind("ctrl+space>shift+w", "worktree_remove_prompt")


