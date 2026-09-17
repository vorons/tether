-- tether M2: config — load ~/.tether/config.lua, merge with defaults
local M = {}

local function default_config()
    return {
        provider = "openai",
        api_key_env = "OPENAI_API_KEY",
        base_url = "https://api.openai.com/v1",
        model = "gpt-4o-mini",
        workspace = nil,
        allow_outside_workspace = false,
        auto_approve = {},
        context = { max_tokens = 32768, summarize_at = 0.7 },
        retries = 3,
        ui = {
            theme = "default",
            header = false,
            keyboard_protocol = "auto",
            mouse = "auto",
            thinking = "collapsed",
            ascii = "auto",
            wrap = true,
            collapse = { read = 20, list = 30, grep = 15 },
            input_max_lines = 8,
            mouse_selection = false,
            alt_screen = false, -- M8/R9: false keeps native scrollback
        },
        tools = { run_shell = { timeout = 120 } },
        system_prompt = nil,
        log_level = "info",
    }
end

local function deep_merge(a, b)
    for k, v in pairs(b) do
        if type(v) == "table" and type(a[k]) == "table" then
            deep_merge(a[k], v)
        else
            a[k] = v
        end
    end
    return a
end

function M.load(path)
    local cfg = default_config()
    -- M7/N4: loadfile returns nil+err when the file is missing — the old code
    -- called the result unconditionally and crashed (nil call) on a fresh
    -- install where ~/.tether/config.lua does not exist.
    -- M8 fix: loadfile returns (chunk) on SUCCESS — a function, not (ok, chunk).
    -- The old `local ok, chunk = loadfile(...)` bound ok=function, chunk=nil,
    -- so `if ok and chunk` was never true and user configs were silently
    -- ignored (theme/alt_screen/mouse had no effect).
    local chunk, load_err = loadfile(path or os.getenv("HOME") .. "/.tether/config.lua")
    if chunk then
        local loaded, tbl = pcall(chunk)
        if loaded and type(tbl) == "table" then
            deep_merge(cfg, tbl)
        elseif not loaded then
            io.stderr:write("tether: config error: " .. tostring(tbl) .. "\n")
        end
    elseif load_err then
        -- missing file is fine (fresh install); a real error is reported
        if not load_err:find("No such file", 1, true) then
            io.stderr:write("tether: config load: " .. tostring(load_err) .. "\n")
        end
    end
    return cfg
end

function M.api_key(cfg)
    return os.getenv(cfg.api_key_env or "OPENAI_API_KEY") or ""
end

-- Design §5: system prompt can be overridden by config.system_prompt
-- (either an inline string or a path to a file).
function M.get_system_prompt(cfg)
    cfg = cfg or M.load()
    local sp = cfg.system_prompt
    if type(sp) ~= "string" or sp == "" then return nil end
    if sp:find("\n", 1, true) then return sp end -- multi-line: inline text
    if sp:find("^/") then
        local f = io.open(sp, "r")
        if f then
            local data = f:read("*a")
            f:close()
            if data and data ~= "" then return data end
        end
        return nil
    end
    return sp
end

return M
