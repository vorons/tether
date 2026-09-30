-- tether confirm_policy — pure confirmation policy for tool calls.
--
-- Data in → verdict out: should this call need a user confirmation, what is
-- its approval key, and does an auto-approve pattern or session set cover it.
-- No I/O and no event emission: projection and auto-approve persistence stay
-- in agent.lua (see design.md D5). Path containment resolves through the
-- `tools` global (`_resolve` / `_within`), which the host loads before agent
-- and tests stub before loadfile.
local M = {}

function M.path_of(args)
    -- audit H8: cwd before command, so a run's approval key is the directory the
    -- call works in (matching exception_target) instead of its command text —
    -- otherwise approving one outside-workspace run covers the same command in
    -- any other directory.
    return args.path or args.cwd or args.command or ""
end

-- fix-audit-findings 1.2: patch arguments are the diff text, not a path;
-- the target has to come from the file headers before the containment check.
function M.patch_target_path(args)
    local diff = args and args.patch or nil
    if type(diff) ~= "string" then return nil end
    -- same normalization as tools.patch: strip one leading a//b/ component,
    -- skip /dev/null; accept both git-style and prefix-less headers
    local function norm(p)
        if not p or p == "/dev/null" then return nil end
        return p:match("^[ab]/(.+)$") or p
    end
    for line in diff:gmatch("[^\n]*") do
        local plus = line:match("^%+%+%+%s+([^%s]+)")
        if plus then
            local t = norm(plus)
            if t then return t end
        end
        local minus = line:match("^%-%-%-%s+([^%s]+)")
        if minus then
            local t = norm(minus)
            if t then return t end
        end
    end
    return nil
end

function M.should_confirm(tool_name, args, cfg)
    if not cfg then return false end
    if cfg.allow_outside_workspace == true then return false end
    if tool_name ~= "write" and tool_name ~= "patch" and tool_name ~= "run" then
        return false
    end
    local tools = _G.tools
    if not tools then return false end
    if tool_name == "patch" then
        local target = M.patch_target_path(args)
        if not target then return false end
        return not tools._within(tools._resolve(target, cfg), cfg)
    end
    if tool_name == "run" then
        -- audit H8: run's target is its cwd, never the command string. Resolving
        -- the command text made an outside cwd look inside the workspace, so the
        -- menu never opened for the refusal tools.run then returned.
        local cwd = args.cwd
        if type(cwd) ~= "string" or cwd == "" then return false end
        return not tools._within(tools._resolve(cwd, cfg), cfg)
    end
    local path = args.path
    if type(path) ~= "string" or path == "" then return false end
    return not tools._within(tools._resolve(path, cfg), cfg)
end

function M.approve_key(tool_name, args)
    return tool_name .. ":" .. M.path_of(args)
end

-- Outside-workspace exception: the confirmation menu grants it, the tools
-- layer consumes it. Keyed by resolved absolute target (not by args), so
-- both sides agree even when the tool receives a reshaped payload
-- (tools.patch takes the diff string, not the args table). Single use =
-- one-shot "allow" stays one-shot; the dispatch sites re-grant per run,
-- so session/auto-approve stick without extra state.
function M.exception_target(tool_name, args, cfg)
    local tools = _G.tools
    if not tools or type(cfg) ~= "table" then return nil end
    args = (type(args) == "table" and args) or {}
    local target = nil
    if tool_name == "write" then target = args.path
    elseif tool_name == "patch" then target = args.path or M.patch_target_path(args)
    elseif tool_name == "run" then target = args.cwd
    end
    if type(target) ~= "string" or target == "" then return nil end
    local ok, abs = pcall(tools._resolve, target, cfg)
    if not ok or type(abs) ~= "string" or abs == "" then return nil end
    local ok2, inside = pcall(tools._within, abs, cfg)
    if not ok2 or inside then return nil end
    return abs
end

function M.grant_exception(cfg, abs)
    if type(cfg) ~= "table" or type(abs) ~= "string" or abs == "" then return end
    cfg._approved_paths = cfg._approved_paths or {}
    cfg._approved_paths[abs] = true
end

function M.consume_exception(cfg, abs)
    if type(cfg) ~= "table" or type(cfg._approved_paths) ~= "table" then return false end
    if cfg._approved_paths[abs] ~= true then return false end
    cfg._approved_paths[abs] = nil
    return true
end

function M.check_auto_approve(tool_name, args, cfg)
    if not cfg or not cfg.auto_approve then return false end
    local key = M.approve_key(tool_name, args)
    for _, pattern in ipairs(cfg.auto_approve) do
        if type(pattern) == "string" and (key:match(pattern) or M.path_of(args):match(pattern)) then
            return true
        end
    end
    return false
end

-- session_set is agent.session_approved ("tool:path" → true); passed in so
-- this module stays free of agent state.
function M.is_session_approved(tool_name, args, session_set)
    if not session_set then return false end
    return session_set[M.approve_key(tool_name, args)] == true
end

return M
