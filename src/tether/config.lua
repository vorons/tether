-- tether M2: config — load ~/.tether/config.lua, merge with defaults
local M = {}

local function default_config()
    return {
        provider = "openai",
        api_key_env = "OPENAI_API_KEY",
        base_url = "https://api.openai.com/v1",
        model = "gpt-4o-mini",
        providers = {
            openai = {
                api_key_env = "OPENAI_API_KEY",
                base_url = "https://api.openai.com/v1",
            },
            anthropic = {
                api_key_env = "ANTHROPIC_API_KEY",
                base_url = "https://api.anthropic.com",
                model = "claude-sonnet-4-20250514",
            },
            gemini = {
                api_key_env = "GEMINI_API_KEY",
                base_url = "https://generativelanguage.googleapis.com",
                model = "gemini-2.5-flash",
            },
        },
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
            alt_screen = true, -- T48: fullscreen TUI; "false" keeps native scrollback
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
    -- providers-table resolution needs the RAW user table (not the merged
    -- cfg): provider defaults must not clobber an explicit legacy top-level
    -- value such as a custom OpenAI-compatible base_url.
    local user_tbl = nil
    if chunk then
        local loaded, tbl = pcall(chunk)
        if loaded and type(tbl) == "table" then
            user_tbl = tbl
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
    if user_tbl then
        local p = cfg.provider or "openai"
        local up = (user_tbl.providers and user_tbl.providers[p]) or {}
        local def_p = (default_config().providers or {})[p] or {}
        cfg.api_key_env = up.api_key_env or user_tbl.api_key_env
            or def_p.api_key_env or cfg.api_key_env
        cfg.base_url = up.base_url or user_tbl.base_url
            or def_p.base_url or cfg.base_url
        cfg.model = up.model or user_tbl.model
            or def_p.model or cfg.model
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
