-- tether approval — persistent [A] always grants.
--
-- Design §6.10: [A] always persists to config with a dated comment.
-- Kept in a machine-managed side file that config.load merges, instead of
-- rewriting the user's hand-written config.lua.
--
-- The file is EXECUTED at startup (config.load_auto_approve uses loadfile +
-- pcall), so writing an entry means writing Lua source with content the model
-- chose — `run:` entries carry the whole shell command. Interpolating an entry
-- between two quote characters let a quote or backslash in the path end the
-- literal early: approving `write` on `a"b.lua` produced a chunk that no
-- longer compiles, so every grant stored before it stopped applying.
-- %q emits a literal that decodes back to exactly `e`, and the read side uses
-- the same decoder the app uses, so what we re-emit is what gets matched.
--
-- `home` is a parameter, not os.getenv("HOME"): callers resolve it (cfg
-- `_auth_home` in the TUI, the real env in --print), so tests can point a
-- grant at a scratch directory instead of the developer's config.
-- Host (tether.mkdirp) and config resolve through globals with loadfile
-- fallbacks for dev/test runs; io/os are standard.
local M = {}

local confirm_policy = _G.confirm_policy
    or (function()
        local chunk = loadfile("src/tether/confirm_policy.lua")
        return chunk and chunk()
    end)()
assert(confirm_policy, "approval: cannot load confirm_policy")

local function persist_approval(tool_name, target, home)
    if type(home) ~= "string" or home == "" then return nil end
    if tether.mkdirp(home .. "/.tether") == nil then return nil end
    local path = home .. "/.tether/auto_approve.lua"
    local pattern = "^" .. tool_name .. ":" ..
        tostring(target):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "$"
    local config = rawget(_G, "config")
    if type(config) ~= "table" or type(config.load_auto_approve) ~= "function" then
        local chunk = loadfile("src/tether/config.lua")
        config = (chunk and chunk()) or nil
    end
    -- Without a decoder we cannot know what is already in the file, and
    -- rewriting it from scratch would drop the user's earlier grants.
    if type(config) ~= "table" or type(config.load_auto_approve) ~= "function" then
        return nil
    end
    local entries = config.load_auto_approve(home)
    for _, e in ipairs(entries) do
        if e == pattern then return pattern end -- already present
    end
    entries[#entries + 1] = pattern
    local w = io.open(path, "w")
    if not w then return nil end
    w:write("-- added by tether ([A] always) on " .. os.date("%Y-%m-%d") .. "\nreturn {\n")
    for _, e in ipairs(entries) do
        w:write("  " .. string.format("%q", e) .. ",\n")
    end
    w:write("}\n")
    w:close()
    return pattern
end
M.persist_approval = persist_approval

local function persist_auto_approve(tool_name, args, cfg)
    local home = (type(cfg) == "table" and cfg._auth_home) or os.getenv("HOME") or ""
    local pattern = persist_approval(tool_name, confirm_policy.path_of(args), home)
    if not pattern or not cfg then return end
    cfg.auto_approve = cfg.auto_approve or {}
    table.insert(cfg.auto_approve, pattern)
end
M.persist_auto_approve = persist_auto_approve

return M
