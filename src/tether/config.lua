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
        -- add-retry-and-continuation: the retry policy reads this table.
        -- There is deliberately no default attempt cap: the budget is the
        -- cutoff in retry.max_failures_at_max_delay (see src/tether/retry.lua),
        -- and a legacy top-level `retries` still caps the attempts.
        retry = {
            base_delay_ms = 2000,
            max_delay_ms = 60000,
            multiplier = 2,
            max_failures_at_max_delay = 3,
        },
        ui = {
            theme = "default",
            header = false,
            keyboard_protocol = "auto",
            mouse = "auto",
            thinking = "collapsed",
            ascii = "auto",
            highlight = "auto", -- 7.x: syntax highlight in fenced code blocks ("auto"/"on"/"off")
            wrap = true,
            collapse = { read = 20, list = 30, grep = 15 },
            input_max_lines = 8,
            -- pi-style-input-and-footer: horizontal padding inside the input
            -- box's rules (whole columns, 0..3, pi's editorPaddingX)
            editor_padding_x = 0,
            alt_screen = true, -- T48: fullscreen TUI; "false" keeps native scrollback
            turn_separators = true, -- 2.x: dim dividers between user turns; set false to disable
            path_completion = true, -- 4.3: Tab completes workspace path tokens
        },
        tools = { run_shell = { timeout = 120 } },
        system_prompt = nil,
        skills_dirs = nil, -- nil = default discovery set (see context.lua)
        agents_files = {}, -- explicit agents-instruction files, merged before CLI --agents-file
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

function M.load(path, home)
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
    -- add-retry-and-continuation: a legacy top-level `retries` was the hard
    -- attempt cap. It still is — mapped onto the policy's attempt cap — so an
    -- existing configuration keeps its budget. `retry.max_attempts` wins.
    if type(cfg.retry) ~= "table" then cfg.retry = default_config().retry end
    if cfg.retry.max_attempts == nil then
        local legacy = tonumber(cfg.retries)
        if legacy then cfg.retry.max_attempts = legacy end
    end

    -- fix-audit-findings 2.1: merge the persisted [A] always patterns so a
    -- permanent approval survives a restart (written by agent.persist_auto_approve).
    local persisted = M.load_auto_approve(home or os.getenv("HOME"))
    if type(cfg.auto_approve) ~= "table" then cfg.auto_approve = {} end
    for _, pat in ipairs(persisted) do
        local dup = false
        for _, e in ipairs(cfg.auto_approve) do
            if e == pat then dup = true break end
        end
        if not dup then cfg.auto_approve[#cfg.auto_approve + 1] = pat end
    end
    return cfg
end

-- Read ~/.tether/auto_approve.lua (machine-managed side file). A missing or
-- invalid file contributes no patterns and never fails the session.
function M.load_auto_approve(home)
    if not home or home == "" then return {} end
    local chunk = loadfile(home .. "/.tether/auto_approve.lua")
    if not chunk then return {} end
    local ok, tbl = pcall(chunk)
    if not ok or type(tbl) ~= "table" then return {} end
    local out = {}
    for _, p in ipairs(tbl) do
        if type(p) == "string" and p ~= "" then out[#out + 1] = p end
    end
    return out
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
