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
    local ok, result = loadfile(path or os.getenv("HOME") .. "/.tether/config.lua")
    if ok then
        local tbl = result()
        if type(tbl) == "table" then
            deep_merge(cfg, tbl)
        end
    end
    return cfg
end

function M.api_key(cfg)
    return os.getenv(cfg.api_key_env or "OPENAI_API_KEY") or ""
end

return M
