-- tether extensions — single-file Lua extensions from ~/.tether/extensions/.
--
-- Layout: ~/.tether/extensions/<name>/<name>.lua returning a table:
--   { name = "<name>", api_version = 1,
--     tools = { { name, description?, schema?, fn } },
--     commands = { { name, description?, fn } },
--     prompt = { text = "..." },
--     hooks = { on_before_tool?, on_after_tool?, on_session_start? } }
-- Unknown fields are ignored (forward compatibility).
--
-- Trust model: only ~/.tether/extensions/ is scanned (never the workspace),
-- so everything loaded was placed there by the machine owner. Extension code
-- runs with a restricted env (no io, no tether host table, no loaders, no
-- os.execute/remove/rename) and reaches the outside world only through ctx
-- ({ workspace, config, log, read, run }), where read/run call the same
-- tools.* implementations the model's calls land in. That path keeps tools-level
-- containment (an outside-workspace cwd or write target is refused) but is
-- never confirmed by the user and writes no history/journal — so ctx grants
-- less than a model-issued `run`, never more.
--
-- IN:  load(home, cfg) once at startup; get() for the registry anywhere.
-- OUT: registry { exts, tools, tool_order, commands, command_order,
--      prompt_parts, before, after, start }.
-- EXAMPLE:
--      local reg = extensions.load(os.getenv("HOME"), cfg)
--      local fn = extensions.tool_fn("jira_get")

local M = {}

M.API_VERSION = 1
M.PROMPT_PART_MAX = 4 * 1024
M.PROMPT_TOTAL_MAX = 16 * 1024
M.HOOK_BUDGET_MS = 100

-- Built-in tool names win over extension tools unconditionally.
local BUILTIN_TOOLS = {
    read = true, list = true, glob = true, grep = true,
    write = true, patch = true, run = true, ask = true, subagent = true,
}

local function warn(ext, msg)
    io.stderr:write("tether: extension " .. tostring(ext) .. ": " .. tostring(msg) .. "\n")
end

function M.empty_registry()
    return {
        exts = {}, tools = {}, tool_order = {},
        commands = {}, command_order = {},
        prompt_parts = {}, before = {}, after = {}, start = {},
    }
end

M.registry = nil

function M.get()
    return M.registry or M.empty_registry()
end

function M.extensions_dir(home)
    local h = home
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/extensions"
end

local function list_dirs(dir)
    local th = rawget(_G, "tether")
    if not (th and th.readdir) then return {} end
    local ok, names = pcall(th.readdir, dir)
    if not ok or type(names) ~= "table" then return {} end
    local out = {}
    for _, n in ipairs(names) do
        if type(n) == "string" and n ~= "" and not n:find("/", 1, true)
            and n ~= "." and n ~= ".." then
            out[#out + 1] = n
        end
    end
    table.sort(out)
    return out
end

local function now_ms()
    local th = rawget(_G, "tether")
    if th and th.monotonic_ms then
        local ok, v = pcall(th.monotonic_ms)
        if ok and type(v) == "number" then return math.floor(v) end
    end
    return nil
end

-- Restricted chunk env: everything except the denylist falls through to _G.
-- os arrives as a safe subset (no execute/remove/rename); io, loaders and
-- the tether host table are unreachable, so ctx is the only outside path.
local function sandbox_env()
    local safe_os = {}
    for _, k in ipairs({ "clock", "date", "difftime", "time", "getenv", "tmpname" }) do
        safe_os[k] = os[k]
    end
    local env = { os = safe_os, print = print }
    setmetatable(env, { __index = function(_, k)
        if k == "io" or k == "dofile" or k == "load" or k == "loadfile"
            or k == "require" or k == "tether" then
            return nil
        end
        return _G[k]
    end })
    return env
end

local function valid_tool_name(n)
    return type(n) == "string" and n:match("^[%w_][%w_%.%-]*$") ~= nil
end

local function valid_command_name(n)
    -- commit_input routes ^/(%w+), so anything outside %w is unreachable.
    return type(n) == "string" and n:match("^%w+$") ~= nil
end

local function register_tools(reg, ename, list)
    if list == nil then return end
    if type(list) ~= "table" then warn(ename, "tools is not a table, ignored") return end
    for i, t in ipairs(list) do
        local where = ename .. ".tools[" .. tostring(i) .. "]"
        if type(t) ~= "table" then warn(ename, "tool entry is not a table, skipped")
        elseif not valid_tool_name(t.name) then warn(ename, "bad tool name, skipped")
        elseif type(t.fn) ~= "function" then warn(ename, "tool '" .. tostring(t.name) .. "' has no fn, skipped")
        elseif BUILTIN_TOOLS[t.name] then warn(ename, "tool '" .. t.name .. "' collides with a built-in, skipped")
        elseif reg.tools[t.name] then
            warn(ename, "tool '" .. t.name .. "' already registered by '"
                .. tostring(reg.tools[t.name].ext) .. "', skipped")
        else
            if type(t.description) ~= "string" then t.description = "" end
            if type(t.schema) ~= "table" then t.schema = { type = "object" } end
            reg.tools[t.name] = { ext = ename, def = t }
            reg.tool_order[#reg.tool_order + 1] = t.name
        end
    end
end

local function register_commands(reg, ename, list)
    if list == nil then return end
    if type(list) ~= "table" then warn(ename, "commands is not a table, ignored") return end
    for i, c in ipairs(list) do
        if type(c) ~= "table" then warn(ename, "command entry is not a table, skipped")
        elseif not valid_command_name(c.name) then warn(ename, "bad command name, skipped")
        elseif type(c.fn) ~= "function" then warn(ename, "command '" .. tostring(c.name) .. "' has no fn, skipped")
        else
            local key = c.name:lower()
            if reg.commands[key] then
                warn(ename, "command '" .. c.name .. "' already registered by '"
                    .. tostring(reg.commands[key].ext) .. "', skipped")
            else
                if type(c.description) ~= "string" then c.description = "" end
                reg.commands[key] = { ext = ename, def = c }
                reg.command_order[#reg.command_order + 1] = key
            end
        end
    end
end

local function register_prompt(reg, ename, prompt)
    if prompt == nil then return end
    if type(prompt) ~= "table" or type(prompt.text) ~= "string" or prompt.text == "" then
        warn(ename, "prompt.text is not a non-empty string, ignored")
        return
    end
    reg.prompt_parts[#reg.prompt_parts + 1] = { ext = ename, text = prompt.text }
end

local function register_hooks(reg, ename, hooks)
    if hooks == nil then return end
    if type(hooks) ~= "table" then warn(ename, "hooks is not a table, ignored") return end
    for _, key in ipairs({ "on_before_tool", "on_after_tool", "on_session_start" }) do
        local fn = hooks[key]
        if fn ~= nil then
            if type(fn) ~= "function" then
                warn(ename, key .. " is not a function, ignored")
            else
                local bucket = key == "on_before_tool" and reg.before
                    or key == "on_after_tool" and reg.after or reg.start
                bucket[#bucket + 1] = { ext = ename, fn = fn }
            end
        end
    end
end

local function load_one(path, ename)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open" end
    local text = f:read("*a")
    f:close()
    if type(text) ~= "string" then return nil, "cannot read" end
    -- load (not loadfile) so the chunk runs in the restricted env.
    local chunk, lerr = load(text, "@" .. path, "t", sandbox_env())
    if not chunk then return nil, lerr or "load failed" end
    local ok, tbl = pcall(chunk)
    if not ok then return nil, tostring(tbl) end
    if type(tbl) ~= "table" then return nil, "must return a table" end
    if tbl.name ~= ename then return nil, "name must equal the directory name" end
    if tbl.api_version ~= M.API_VERSION then
        return nil, "unsupported api_version " .. tostring(tbl.api_version)
    end
    return tbl
end

-- Load every extension under home/.tether/extensions/. A missing directory
-- means no extensions (silent). Each failure is fail-closed per extension.
function M.load(home, cfg)
    local reg = M.empty_registry()
    local disabled = {}
    if type(cfg) == "table" and type(cfg.extensions) == "table"
        and type(cfg.extensions.disabled) == "table" then
        for _, n in ipairs(cfg.extensions.disabled) do
            if type(n) == "string" and n ~= "" then disabled[n] = true end
        end
    end
    local dir = M.extensions_dir(home)
    for _, ename in ipairs(list_dirs(dir)) do
        if not disabled[ename] then
            local path = dir .. "/" .. ename .. "/" .. ename .. ".lua"
            local probe = io.open(path, "r")
            if probe then
                probe:close()
                local tbl, err = load_one(path, ename)
                if not tbl then
                    warn(ename, err)
                else
                    reg.exts[#reg.exts + 1] = { name = ename, def = tbl }
                    register_tools(reg, ename, tbl.tools)
                    register_commands(reg, ename, tbl.commands)
                    register_prompt(reg, ename, tbl.prompt)
                    register_hooks(reg, ename, tbl.hooks)
                end
            end
        end
    end
    M.registry = reg
    return reg
end

-- Tool fn for the agent dispatch (nil when no extension provides it).
function M.tool_fn(name)
    local t = M.get().tools[name]
    if not t then return nil end
    return t.def.fn, t.ext
end

function M.has_tool(name)
    return M.get().tools[name] ~= nil
end

-- Sorted { name, description, parameters } entries for the provider schema.
function M.schema_entries()
    local reg = M.get()
    local out = {}
    for _, name in ipairs(reg.tool_order) do
        local t = reg.tools[name]
        out[#out + 1] = {
            name = name,
            description = t.def.description ~= "" and t.def.description
                or ("Extension tool '" .. name .. "' (from '" .. t.ext .. "')"),
            parameters = t.def.schema,
        }
    end
    return out
end

-- The outside path handed to tool fns and hooks. read/run call tools.* with
-- the live cfg: workspace containment applies (an outside target is refused),
-- but nothing is confirmed by the user and nothing is journaled.
function M.ctx_for(cfg)
    local tools = _G.tools
    if not tools then
        local chunk = loadfile("src/tether/tools.lua")
        tools = chunk and chunk() or nil
    end
    local ws = nil
    if tools and tools._workspace then
        local ok, w = pcall(tools._workspace, cfg)
        if ok then ws = w end
    end
    local ctx = { workspace = ws, config = cfg }
    function ctx.log(msg)
        io.stderr:write("tether: extension: " .. tostring(msg) .. "\n")
    end
    function ctx.read(path)
        if not tools then return nil, "tools unavailable" end
        return tools.read({ path = path }, cfg)
    end
    function ctx.run(command, opts)
        if not tools then return nil, "tools unavailable" end
        opts = opts or {}
        return tools.run({ command = command, cwd = opts.cwd, timeout = opts.timeout }, cfg)
    end
    return ctx
end

-- Before-tool chain (name order): nil = allow, { deny = reason } vetoes,
-- { args = new } rewrites. Deny short-circuits; rewrites flow down the
-- chain in a single pass. Errors and budget overruns degrade to allow.
-- Returns kind, payload: ("allow", final_args) | ("deny", reason).

-- Declared JSON types mapped to the Lua value that carries them.
local ARG_TYPES = { string = "string", number = "number", integer = "number",
    boolean = "boolean", array = "table", object = "table" }

-- A rewrite must still fit the tool's schema, or it reaches confirm and the
-- tool as garbage (design Risks). The check is deliberately shallow: key
-- names, the JSON type of each value, and the required list. Values stay the
-- tool's own problem. Nil schema (an extension tool that declared no
-- properties) means nothing to check.
function M.validate_args(schema, args)
    if type(args) ~= "table" then return "arguments must be a table" end
    if type(schema) ~= "table" or type(schema.properties) ~= "table" then return nil end
    local props = schema.properties
    for k, v in pairs(args) do
        local spec = type(k) == "string" and props[k] or nil
        if type(spec) ~= "table" then
            return "unknown argument '" .. tostring(k) .. "'"
        end
        local want = ARG_TYPES[spec.type]
        if want and type(v) ~= want then
            return "argument '" .. tostring(k) .. "' must be " .. tostring(spec.type)
        end
    end
    if type(schema.required) == "table" then
        for _, k in ipairs(schema.required) do
            if type(k) == "string" and args[k] == nil then
                return "missing required argument '" .. k .. "'"
            end
        end
    end
    return nil
end

local function tool_schema(name)
    local t = M.get().tools[name]
    if t then return t.def.schema end
    local common = _G.provider_common
    if not (common and common.tools_schema) then
        local chunk = loadfile("src/tether/providers/common.lua")
        common = chunk and chunk() or nil
    end
    if not (common and common.tools_schema) then return nil end
    local ok, list = pcall(common.tools_schema)
    if not ok or type(list) ~= "table" then return nil end
    for _, e in ipairs(list) do
        if type(e) == "table" and e.name == name and type(e.parameters) == "table" then
            return e.parameters
        end
    end
    return nil
end

function M.run_before(tool, args, cfg)
    local reg = M.get()
    if #reg.before == 0 then return "allow", args end
    local ctx = M.ctx_for(cfg)
    local current, rewritten = args, false
    for _, h in ipairs(reg.before) do
        local t0 = now_ms()
        local ok, verdict = pcall(h.fn, tool, current, ctx)
        local t1 = now_ms()
        if not ok then
            warn(h.ext, "on_before_tool failed: " .. tostring(verdict))
        elseif t0 and t1 and (t1 - t0) > M.HOOK_BUDGET_MS then
            warn(h.ext, "on_before_tool exceeded the time budget, ignored")
        elseif verdict == nil then
            -- allow, keep going
        elseif type(verdict) ~= "table" then
            warn(h.ext, "on_before_tool must return nil or a table, ignored")
        elseif type(verdict.deny) == "string" and verdict.deny ~= "" then
            return "deny", verdict.deny
        elseif verdict.args ~= nil then
            local bad = M.validate_args(tool_schema(tool), verdict.args)
            if bad then
                return "deny", "extension '" .. h.ext .. "': " .. bad
            end
            current, rewritten = verdict.args, true
        else
            warn(h.ext, "on_before_tool returned an empty verdict, ignored")
        end
    end
    if rewritten then return "allow_rewrite", current end
    return "allow", current
end

-- After-tool chain (name order): each handler sees prior edits. It receives
-- the shaped view ({ content = body text, details?, is_error }) — the exact
-- payload history/journal/event will carry — and returns a patch with the
-- same fields, or nil to leave it. Omitted patch fields stay; errors and
-- budget overruns degrade to no-op. Returns the composed view table.
function M.run_after(tool, args, result, cfg)
    local reg = M.get()
    if #reg.after == 0 then return result end
    local ctx = M.ctx_for(cfg)
    for _, h in ipairs(reg.after) do
        local t0 = now_ms()
        local ok, patch = pcall(h.fn, tool, args, result, ctx)
        local t1 = now_ms()
        if not ok then
            warn(h.ext, "on_after_tool failed: " .. tostring(patch))
        elseif t0 and t1 and (t1 - t0) > M.HOOK_BUDGET_MS then
            warn(h.ext, "on_after_tool exceeded the time budget, ignored")
        elseif patch ~= nil then
            if type(patch) ~= "table" then
                warn(h.ext, "on_after_tool must return nil or a table, ignored")
            else
                if patch.content ~= nil then result.content = patch.content end
                if patch.details ~= nil then result.details = patch.details end
                if patch.is_error ~= nil then result.is_error = patch.is_error and true or false end
            end
        end
    end
    return result
end

-- Session-start fan-out (new + resume), once per process: the TUI can reach
-- this from both the resume point and the lazy first-turn mint. Errors
-- degrade to warn; the session always proceeds.
function M.fire_start(cfg, workspace)
    local reg = M.get()
    if reg.start_fired then return end
    reg.start_fired = true
    if #reg.start == 0 then return end
    local ctx = M.ctx_for(cfg)
    if workspace ~= nil then ctx.workspace = workspace end
    for _, h in ipairs(reg.start) do
        local ok, err = pcall(h.fn, ctx)
        if not ok then warn(h.ext, "on_session_start failed: " .. tostring(err)) end
    end
end

-- Prompt block for context.blocks (tools listing + prompt texts), capped
-- per part and in total. Nil when no extension contributes anything.
function M.prompt_block()
    local reg = M.get()
    local parts = {}
    if #reg.tool_order > 0 then
        local lines = { "## Extension tools" }
        for _, name in ipairs(reg.tool_order) do
            local t = reg.tools[name]
            local desc = t.def.description ~= "" and t.def.description
                or ("from '" .. t.ext .. "'")
            lines[#lines + 1] = "- " .. name .. ": " .. desc
        end
        parts[#parts + 1] = table.concat(lines, "\n")
    end
    for _, p in ipairs(reg.prompt_parts) do
        local text = p.text
        if #text > M.PROMPT_PART_MAX then
            local common = _G.provider_common
            if not common then
                local chunk = loadfile("src/tether/providers/common.lua")
                common = chunk and chunk() or nil
            end
            if common and common.utf8_prefix then
                text = common.utf8_prefix(text, M.PROMPT_PART_MAX) .. "…(truncated)"
            else
                text = text:sub(1, M.PROMPT_PART_MAX) .. "…(truncated)"
            end
        end
        parts[#parts + 1] = "## Extension note (" .. p.ext .. ")\n" .. text
    end
    if #parts == 0 then return nil end
    local text = table.concat(parts, "\n\n")
    if #text > M.PROMPT_TOTAL_MAX then
        text = text:sub(1, M.PROMPT_TOTAL_MAX) .. "\n…(truncated)"
    end
    return text
end

-- ============================================================
-- Management: install / list / remove (task group 4)
-- ============================================================

function M.list_names(home)
    local dir = M.extensions_dir(home)
    local out = {}
    for _, ename in ipairs(list_dirs(dir)) do
        local probe = io.open(dir .. "/" .. ename .. "/" .. ename .. ".lua", "r")
        if probe then
            probe:close()
            out[#out + 1] = ename
        end
    end
    return out
end

local function sq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Shell seam: tether.exec in the binary, os.execute fallback. Tests stub it.
function M._exec(cmd)
    local th = rawget(_G, "tether")
    if th and th.exec then
        local ok, code = th.exec(cmd)
        return ok, code
    end
    local ok = os.execute(cmd)
    if ok == true or ok == 0 then return true, 0 end
    return false, 1
end

local function mkdirp(path)
    local th = rawget(_G, "tether")
    if th and th.mkdirp then
        local ok = pcall(th.mkdirp, path)
        if ok then return true end
    end
    local ok = os.execute("mkdir -p " .. sq(path))
    if ok == true or ok == 0 then return true end
    return nil, "cannot create directory " .. path
end

local function copy_file(src, dst)
    local f = io.open(src, "rb")
    if not f then return nil, "cannot open " .. src end
    local data = f:read("*a")
    f:close()
    if type(data) ~= "string" then return nil, "cannot read " .. src end
    local w = io.open(dst, "wb")
    if not w then return nil, "cannot write " .. dst end
    w:write(data)
    w:close()
    return true
end

local function looks_like_git_url(s)
    return s:match("^[%w+]+://") ~= nil or s:match("^git@") ~= nil
        or s:match("%.git$") ~= nil
end

local function base_name(s)
    s = s:gsub("/+$", "")
    local b = s:match("([^/]+)$") or s
    b = b:gsub("%.git$", "")
    return b
end

-- Install from a local directory (must hold <name>/<name>.lua) or a git
-- URL (shallow-cloned to a temp dir first). Never leaves a half-written
-- extension directory behind.
function M.install(source, home)
    if type(source) ~= "string" or source == "" then
        return nil, "tether install needs a source path or URL"
    end
    local dir = M.extensions_dir(home)
    if looks_like_git_url(source) then
        local tmp = os.tmpname()
        os.remove(tmp)
        local ok, mkdir_err = mkdirp(tmp)
        if not ok then return nil, mkdir_err end
        local cok, code = M._exec("git clone --depth 1 " .. sq(source) .. " " .. sq(tmp) .. " >/dev/null 2>&1")
        if not cok or code ~= 0 then
            M._exec("rm -rf " .. sq(tmp))
            return nil, "git clone failed for " .. source
        end
        local name = base_name(source)
        local res, err = M.install(tmp .. "/" .. name, home)
        M._exec("rm -rf " .. sq(tmp))
        return res, err
    end
    -- local path: <path> itself or <path>/<name>/<name>.lua
    local name = base_name(source)
    local src_file = source .. "/" .. name .. ".lua"
    local probe = io.open(src_file, "r")
    if not probe then
        -- maybe source already points at the file
        probe = io.open(source, "r")
        if probe then
            probe:close()
            src_file = source
            name = base_name(source:gsub("%.lua$", ""))
            if name == "" then return nil, "cannot derive an extension name from " .. source end
        else
            return nil, "no extension file at " .. src_file
        end
    else
        probe:close()
    end
    local dest_dir = dir .. "/" .. name
    local ok, mkdir_err = mkdirp(dest_dir)
    if not ok then return nil, mkdir_err end
    local dest = dest_dir .. "/" .. name .. ".lua"
    local cok, cerr = copy_file(src_file, dest)
    if not cok then
        M._exec("rm -rf " .. sq(dest_dir))
        return nil, cerr
    end
    return name
end

-- Remove one extension directory. Only that directory is touched.
function M.remove(name, home)
    if type(name) ~= "string" or name == "" or name:find("/", 1, true) then
        return nil, "bad extension name"
    end
    local dir = M.extensions_dir(home) .. "/" .. name
    local probe = io.open(dir .. "/" .. name .. ".lua", "r")
    if not probe then return nil, "no such extension: " .. name end
    probe:close()
    M._exec("rm -rf " .. sq(dir))
    local stale = io.open(dir .. "/" .. name .. ".lua", "r")
    if stale then
        stale:close()
        return nil, "cannot remove " .. name
    end
    return true
end

return M
