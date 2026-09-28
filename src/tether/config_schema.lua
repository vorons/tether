-- tether config_schema — defaults, merge, and config-file writers.
--
-- Schema/defaults source plus the machine writers (persist-keys targeting,
-- bootstrap serializer): pure data assembly over stdlib io/os. The catalog
-- resolves through a global with a loadfile fallback for dev/test runs.
-- M.load (the orchestrator) stays in config.lua and calls in here.
local M = {}

-- expand-provider-catalog: per-provider defaults come from the preset
-- catalog (single source with api.lua and the /login picker).
local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

local function catalog_providers()
    -- dynamic-provider-catalog: merged view (bootstrap + cache + models.lua).
    local all = (catalog and catalog.all and catalog.all())
        or (catalog and catalog.entries)
    if all then
        local t = {}
        for id, e in pairs(all) do
            t[id] = {
                api_key_env = e.api_key_env,
                base_url = e.base_url or e.url_template,
                model = e.model,
            }
        end
        return t
    end
    -- catalog failed to load: legacy triple (matches pre-catalog behavior)
    return {
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
    }
end
M.catalog_providers = catalog_providers

local function default_config()
    return {
        -- dynamic-provider-catalog: local-first default (llama.cpp);
        -- cloud providers arrive via the pipeline cache. NOTE: upstream
        -- `llama` is Meta's cloud API — the local id is `llama-cpp`.
        provider = "llama-cpp",
        api_key_env = "LLAMA_API_KEY",
        base_url = "http://127.0.0.1:8080/v1",
        model = "",
        -- add-reasoning-level: reasoning effort; only these four levels are
        -- valid (M.load normalizes anything else back to "off").
        reasoning = "off",
        providers = catalog_providers(),
        workspace = nil,
        allow_outside_workspace = false,
        auto_approve = {},
        context = {
            max_tokens = 32768,
            summarize_at = 0.7,
            -- add-llm-compaction: reply headroom + keep-window size
            reserve_tokens = 16384,
            keep_recent_messages = 4,
            -- compaction-anchors-preflight-prune: deterministic anchor facts
            -- appended to the summary request (default on), pre-turn
            -- projection for large pastes (default on), lossless pruning of
            -- superseded reads in the outbound view (default off: each first
            -- prune costs one prompt-cache miss).
            anchors = true,
            preflight = true,
            prune_superseded_reads = false,
        },
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
            -- ui-padding: blank gutter left/right of every painted row plus one
            -- blank row above the splash (whole columns, 0..3; 0 = edge-to-edge)
            padding = 1,
            alt_screen = true, -- T48: fullscreen TUI; "false" keeps native scrollback
            turn_separators = true, -- 2.x: dim dividers between user turns; set false to disable
            block_gap = 1, -- 6.x: blank rows before top-level transcript entities; 0 = compact
            path_completion = true, -- 4.3: Tab completes workspace path tokens
        },
        tools = { run_shell = { timeout = 120 } },
        -- subagent: child-run orchestration (max concurrent children,
        -- per-task timeout, fork depth limit).
        subagents = { max_parallel = 4, timeout = 600, max_depth = 1 },
        system_prompt = nil,
        skills_dirs = nil, -- nil = default discovery set (see context.lua)
        agents_files = {}, -- explicit agents-instruction files, merged before CLI --agents-file
        log_level = "info",
    }
end
M.default_config = default_config

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
M.deep_merge = deep_merge

-- config-file-persist-settings: machine write-through of the three
-- runtime-mutable keys. Targeted text patch (never load→modify→serialize,
-- which would drop comments and break files with logic around the table).
-- Only top-level `provider`/`model`/`reasoning` lines are touched; nested tables
-- (providers.<id>.model), comments and unknown keys survive byte-for-byte.
-- Missing keys append before the top-table close when the structure is
-- recognizable, otherwise fail closed (return false, file untouched).
-- Total function: never raises.
local function config_path(home)
    local h = home
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/config.lua"
end
M.config_path = config_path

-- blank string literals (same length) so brace/comment scans ignore them.
local function blank_strings(line)
    local out, in_str, esc = {}, nil, false
    for i = 1, #line do
        local c = line:sub(i, i)
        if in_str then
            out[#out + 1] = " "
            if esc then esc = false
            elseif c == "\\" then esc = true
            elseif c == in_str then in_str = nil end
        elseif c == '"' or c == "'" then
            in_str = c
            out[#out + 1] = " "
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

local PERSIST_KEYS = { "provider", "model", "reasoning" }
M.PERSIST_KEYS = PERSIST_KEYS

local function persist_keys(home, keys)
    return M.persist_keys_to_path(config_path(home), keys)
end
M.persist_keys = persist_keys

local function persist_keys_to_path(path, keys)
    local ok = pcall(function()
        assert(type(keys) == "table")
        local want = {}
        for _, k in ipairs(PERSIST_KEYS) do
            local v = keys[k]
            if v ~= nil then
                assert(type(v) == "string" and v ~= "", "persist_keys: bad " .. k)
                want[k] = v
            end
        end
        if next(want) == nil then return true end
        local f = assert(io.open(path, "r"))
        local data = assert(f:read("*a"))
        f:close()
        local lines, ends_nl = {}, data:sub(-1) == "\n"
        for line in (data .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
        if ends_nl then lines[#lines] = nil end
        -- pass 1: replace top-level key lines, tracking brace depth
        local depth, found, changed = 0, {}, false
        for i, line in ipairs(lines) do
            local blanked = blank_strings(line)
            local cstart = blanked:find("--", 1, true)
            local code = cstart and blanked:sub(1, cstart - 1) or blanked
            if depth == 1 then
                local key = code:match("^%s*(provider)%s*=")
                    or code:match("^%s*(model)%s*=")
                    or code:match("^%s*(reasoning)%s*=")
                if key and want[key] then
                    local indent = line:match("^(%s*)")
                    local trail = ""
                    if cstart then
                        local tc = line:sub(cstart):match("^%-%-%s*(.-)%s*$")
                        if tc and tc ~= "" then trail = " -- " .. tc end
                    end
                    local newline = indent .. key .. " = "
                        .. string.format("%q", want[key]) .. "," .. trail
                    if newline ~= line then lines[i] = newline changed = true end
                    found[key] = true
                end
            end
            for b in code:gmatch("[{}]") do
                if b == "{" then depth = depth + 1 else depth = depth - 1 end
            end
        end
        -- pass 2: append missing keys before the top-table close
        local missing = {}
        for _, k in ipairs(PERSIST_KEYS) do
            if want[k] and not found[k] then missing[#missing + 1] = k end
        end
        if #missing > 0 then
            -- the top-table close: last structural line must be `}`;
            -- comment/blank-only tails tolerated, anything else fails closed.
            local close_at = nil
            for i = #lines, 1, -1 do
                local blanked = blank_strings(lines[i])
                local cstart = blanked:find("--", 1, true)
                local code = cstart and blanked:sub(1, cstart - 1) or blanked
                if code:match("^%s*$") then
                    -- blank or comment-only: skip
                elseif code:match("^%s*}%s*,?%s*$") then
                    close_at = i
                    break
                else
                    break
                end
            end
            if not close_at then error("persist_keys: unrecognizable file") end
            local add = {}
            for _, k in ipairs(missing) do
                add[#add + 1] = "  " .. k .. " = " .. string.format("%q", want[k]) .. ","
            end
            for j = #add, 1, -1 do table.insert(lines, close_at, add[j]) end
            changed = true
        end
        if changed then
            local w = assert(io.open(path, "w"))
            w:write(table.concat(lines, "\n"))
            if ends_nl then w:write("\n") end
            w:close()
        end
        return true
    end)
    return ok == true
end
M.persist_keys_to_path = persist_keys_to_path

-- config-file-persist-settings: bootstrap writer. Serializes
-- default_config() (single source — never a static template that could
-- drift) with a comment per section. Per-provider endpoints and the legacy
-- top-level api_key_env/base_url stay catalog-driven (commented examples
-- only): baking them in would pin stale values and shadow the active
-- provider's catalog entry after a provider switch. Nil defaults are
-- emitted as comments (absent after load = nil).
-- Total function: returns false instead of raising; existing files are
-- never touched (callers check existence first).
M.BOOTSTRAP_ORDER = {
    "provider", "api_key_env", "base_url", "model", "reasoning",
    "workspace", "allow_outside_workspace", "auto_approve",
    "context", "retry", "ui", "tools",
    "system_prompt", "skills_dirs", "agents_files", "log_level",
    "providers", "providers_url",
}
M.BOOTSTRAP_COMMENTS = {
    provider = "active provider: any catalog id (default llama-cpp = local llama.cpp; cloud ids arrive via the providers cache; override the sync source with providers_url)",
    providers_url = "override the providers-cache sync source (default: the data file published by .github/workflows/sync-providers.yml)",
    api_key_env = "legacy top-level key env (per-provider providers.<id>.api_key_env wins)",
    base_url = "legacy top-level endpoint (per-provider providers.<id>.base_url wins)",
    model = "legacy top-level model (per-provider providers.<id>.model wins; /model writes here)",
    reasoning = "reasoning effort: off, low, medium, high (/think writes here)",
    workspace = "nil = process cwd at runtime (also: tether -w DIR)",
    allow_outside_workspace = "tools may touch paths outside the workspace",
    auto_approve = "extra always-approve patterns (the [A] key persists separately)",
    context = "context window budget and compaction thresholds",
    retry = "backoff policy for failed requests",
    ui = "interface: theme, wrap, mouse, keyboard, palette, footer",
    tools = "tool timeouts",
    subagents = "subagent child runs: max_parallel, timeout, max_depth",
    system_prompt = "nil = built-in prompt (inline text or /path/to/file)",
    skills_dirs = "nil = default discovery set",
    agents_files = "explicit agents-instruction files",
    log_level = "info or debug",
    providers = "per-provider overrides (empty = catalog-driven); whole custom providers live in ~/.tether/models.lua",
}

local function write_lua_value(buf, v, indent)
    local t = type(v)
    if t == "string" then
        buf[#buf + 1] = string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        buf[#buf + 1] = tostring(v)
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        if #keys == 0 then buf[#buf + 1] = "{}" return end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        buf[#buf + 1] = "{\n"
        for _, k in ipairs(keys) do
            buf[#buf + 1] = indent .. "  "
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                buf[#buf + 1] = k .. " = "
            else
                buf[#buf + 1] = "[" .. string.format("%q", tostring(k)) .. "] = "
            end
            write_lua_value(buf, v[k], indent .. "  ")
            buf[#buf + 1] = ",\n"
        end
        buf[#buf + 1] = indent .. "}"
    else
        buf[#buf + 1] = "nil"
    end
end

local function write_bootstrap(path)
    local ok = pcall(function()
        local dir = path:match("^(.*)/[^/]*$")
        if dir then
            local mk = tether and tether.mkdirp
            if mk then assert(pcall(mk, dir)) end
        end
        local def = default_config()
        local buf = {
            "-- tether configuration — created with defaults on first run.\n",
            "-- every key is optional (absent = default); /model writes\n",
            "-- provider/model back into this file. Secrets never belong here\n",
            "-- (keys resolve via env or ~/.tether/auth.json).\n",
            "return {\n",
        }
        for _, k in ipairs(M.BOOTSTRAP_ORDER) do
            local comment = M.BOOTSTRAP_COMMENTS[k]
            if comment then
                buf[#buf + 1] = "  -- " .. comment .. "\n"
            end
            local v = def[k]
            if v == nil or k == "api_key_env" or k == "base_url" then
                -- nils and catalog-driven endpoint keys: commented examples
                -- (uncomment to pin); absent after load = default.
                local shown = v == nil and "nil" or string.format("%q", v)
                buf[#buf + 1] = "  -- " .. k .. " = " .. shown .. ",\n"
            elseif k == "providers" then
                buf[#buf + 1] = "  -- e.g. providers = { anthropic ="
                buf[#buf + 1] = ' { model = "claude-sonnet-4-20250514" } },\n'
                buf[#buf + 1] = "  providers = {},\n"
            else
                buf[#buf + 1] = "  " .. k .. " = "
                write_lua_value(buf, v, "  ")
                buf[#buf + 1] = ",\n"
            end
        end
        buf[#buf + 1] = "}\n"
        local w = assert(io.open(path, "w"))
        w:write(table.concat(buf))
        w:close()
    end)
    return ok == true
end
M.write_bootstrap = write_bootstrap

-- add-llm-compaction: non-numeric / negative values fall back to the default
-- without failing the session (spec: malformed reserve falls back).
local function coerce_nonneg(v, default)
    local n = tonumber(v)
    if not n or n < 0 then return default end
    return math.floor(n)
end
M.coerce_nonneg = coerce_nonneg

return M
