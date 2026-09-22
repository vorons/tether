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
    return args.path or args.command or args.cwd or ""
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
    local path = args.path or args.command or ""
    if path == "" and tool_name == "run" then path = args.cwd or "" end
    if tool_name == "write" or (tool_name == "patch" and args.path) or (tool_name == "run" and args.cwd) then
        -- target path known: check membership
        return not tools._within(tools._resolve(path, cfg), cfg)
    end
    -- run without cwd: executed in workspace root — allowed there
    return false
end

function M.approve_key(tool_name, args)
    return tool_name .. ":" .. M.path_of(args)
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
