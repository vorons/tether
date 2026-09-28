-- tether projection — read-only preview of what a write/patch will change.
--
-- Data in → preview out (or nil): resolved through the tools helpers,
-- inside the workspace, bounded (1 MiB), never written, never journalled.
-- Any failure returns nil so the call itself proceeds unchanged.
-- I/O siblings live here (not in confirm_policy/compression, which are
-- pure): the turn core calls in, files are only read. Shared instances
-- resolve through globals with loadfile fallbacks for dev/test runs.
local M = {}

local diff_mod = _G.diff
    or (function()
        local chunk = loadfile("src/tether/diff.lua")
        return chunk and chunk()
    end)()

local confirm_policy = _G.confirm_policy
    or (function()
        local chunk = loadfile("src/tether/confirm_policy.lua")
        return chunk and chunk()
    end)()
assert(confirm_policy, "projection: cannot load confirm_policy")

local PREVIEW_READ_MAX = 1024 * 1024
M.PREVIEW_READ_MAX = PREVIEW_READ_MAX

-- pretty-transcript-rendering 2.2: a read-only projection of what a write or
-- patch will change. Resolved through the tools helpers, inside the workspace,
-- bounded (1 MiB), never written, never journalled. Any failure returns nil so
-- the call itself proceeds unchanged.
local function projection_for(tool_name, args, cfg)
    local tools = _G.tools
    if not (diff_mod and tools) then return nil end
    args = args or {}
    if tool_name == "write" then
        local target = args.path
        if type(target) ~= "string" or target == "" then return nil end
        local abs = tools._resolve(target, cfg)
        if not tools._within(abs, cfg) then return nil end
        local st = tether.stat and tether.stat(abs) or nil
        if st and st.is_dir then return nil end
        if st and st.size and st.size > PREVIEW_READ_MAX then return nil end
        local rel = tools._to_rel(abs, cfg)
        local prior, is_new = "", false
        if st then
            local f = io.open(abs, "rb")
            if not f then return nil end
            local data = f:read(PREVIEW_READ_MAX + 1) or ""
            f:close()
            if #data > PREVIEW_READ_MAX then return nil end
            prior = data
        else
            is_new = true
        end
        local old_label = is_new and "/dev/null" or ("a/" .. rel)
        local new_label = "b/" .. rel
        local text, counts = diff_mod.unified(prior, args.content or "", old_label, new_label)
        return { path = rel, kind = is_new and "new" or "overwrite",
                 diff = text, add = counts.add, del = counts.del,
                 before = prior, is_new = is_new }
    elseif tool_name == "patch" then
        local diffstr = args.patch
        if type(diffstr) ~= "string" or diffstr == "" then return nil end
        local target = confirm_policy.patch_target_path(args)
        if not target then return nil end
        local abs = tools._resolve(target, cfg)
        if not tools._within(abs, cfg) then return nil end
        local add, del = 0, 0
        for line in diffstr:gmatch("[^\n]*") do
            local p = line:sub(1, 1)
            if p == "+" and line:sub(1, 3) ~= "+++" then add = add + 1
            elseif p == "-" and line:sub(1, 3) ~= "---" then del = del + 1 end
        end
        return { path = tools._to_rel(abs, cfg), kind = "patch",
                 diff = diffstr, add = add, del = del }
    end
    return nil
end
M.projection_for = projection_for

return M
