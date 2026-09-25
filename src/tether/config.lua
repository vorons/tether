-- tether M2: config — load ~/.tether/config.lua, merge with defaults
local M = {}

-- expand-provider-catalog: per-provider defaults come from the preset
-- catalog (single source with api.lua and the /login picker).
local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

local function catalog_providers()
    if catalog and catalog.entries then
        local t = {}
        for id, e in pairs(catalog.entries) do
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

local function default_config()
    return {
        provider = "openai",
        api_key_env = "OPENAI_API_KEY",
        base_url = "https://api.openai.com/v1",
        model = "gpt-4o-mini",
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
            alt_screen = true, -- T48: fullscreen TUI; "false" keeps native scrollback
            turn_separators = true, -- 2.x: dim dividers between user turns; set false to disable
            block_gap = 1, -- 6.x: blank rows before top-level transcript entities; 0 = compact
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

-- config-file-persist-settings: machine write-through of the three
-- runtime-mutable keys. Targeted text patch (never load→modify→serialize,
-- which would drop comments and break files with logic around the table).
-- Only top-level `provider`/`model`/`reasoning` lines are touched; nested tables
-- (providers.<id>.model), comments and unknown keys survive byte-for-byte.
-- Missing keys append before the top-table close when the structure is
-- recognizable, otherwise fail closed (return false, file untouched).
-- Total function: never raises.
function M._config_path(home)
    local h = home
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/config.lua"
end

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

function M.persist_keys(home, keys)
    return M._persist_keys_to_path(M._config_path(home), keys)
end

function M._persist_keys_to_path(path, keys)
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

-- config-file-persist-settings: bootstrap writer. Serializes
-- default_config() (single source — never a static template that could
-- drift) with a comment per section. Per-provider endpoints and the legacy
-- top-level api_key_env/base_url stay catalog-driven (commented examples
-- only): baking them in would pin stale values and shadow the active
-- provider's catalog entry after a provider switch. Nil defaults are
-- emitted as comments (absent after load = nil).
-- Total function: returns false instead of raising; existing files are
-- never touched (callers check existence first).
local BOOTSTRAP_ORDER = {
    "provider", "api_key_env", "base_url", "model", "reasoning",
    "workspace", "allow_outside_workspace", "auto_approve",
    "context", "retry", "ui", "tools",
    "system_prompt", "skills_dirs", "agents_files", "log_level",
    "providers",
}
local BOOTSTRAP_COMMENTS = {
    provider = "active provider: any catalog id (openai, anthropic, gemini, ...)",
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
    system_prompt = "nil = built-in prompt (inline text or /path/to/file)",
    skills_dirs = "nil = default discovery set",
    agents_files = "explicit agents-instruction files",
    log_level = "info or debug",
    providers = "per-provider overrides (empty = catalog-driven)",
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

function M._write_bootstrap(path)
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
        for _, k in ipairs(BOOTSTRAP_ORDER) do
            local comment = BOOTSTRAP_COMMENTS[k]
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

-- add-llm-compaction: non-numeric / negative values fall back to the default
-- without failing the session (spec: malformed reserve falls back).
local function coerce_nonneg(v, default)
    local n = tonumber(v)
    if not n or n < 0 then return default end
    return math.floor(n)
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
    local cfgpath = path or os.getenv("HOME") .. "/.tether/config.lua"
    local chunk, load_err = loadfile(cfgpath)
    if not chunk and load_err
        and load_err:find("No such file", 1, true) then
        -- config-file-persist-settings: bootstrap a commented file with
        -- defaults so every setting is discoverable; a failed bootstrap
        -- still loads in-memory defaults below.
        if M._write_bootstrap(cfgpath) then
            chunk, load_err = loadfile(cfgpath)
        end
    end
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
    -- config-file-persist-settings: one-time model.lua migration. Applies
    -- only when the user file carries no explicit provider/model: absent
    -- keys count, a hand-written value (even equal to the default) is
    -- explicit and wins over the side file (spec: Hand-written default is
    -- explicit). Writes through to config.lua and removes the side file
    -- after a verified write. The migrated values re-merge below as
    -- explicit values, so provider resolution treats them exactly like
    -- hand-written ones.
    do
        local eu0 = user_tbl or {}
        -- NB: bootstrap writes real `provider`/`model` key lines, but load()
        -- has already deep-merged them into cfg — they are NOT in user_tbl's
        -- own fields. user_tbl reflects only what the user actually wrote.
        -- The bootstrap emits them as literal lines, so its user_tbl carries
        -- them too; distinguish "file came from the bootstrap" by the header
        -- comment rather than the field values.
        local is_bootstrap_file = false
        if user_tbl then
            local fhdr = io.open(cfgpath, "r")
            if fhdr then
                local head = fhdr:read(120) or ""
                fhdr:close()
                is_bootstrap_file = head:find("created with defaults", 1, true) ~= nil
            end
        end
        if is_bootstrap_file or (eu0.provider == nil and eu0.model == nil) then
            local sdir = home or os.getenv("HOME") or "."
            local spath = sdir .. "/.tether/model.lua"
            local schunk = loadfile(spath)
            if schunk then
                local sok, stbl = pcall(schunk)
                if sok and type(stbl) == "table"
                    and type(stbl.model) == "string" and stbl.model ~= "" then
                    local keys = { model = stbl.model }
                    if type(stbl.provider) == "string" and stbl.provider ~= "" then
                        keys.provider = stbl.provider
                    end
                    if M._persist_keys_to_path(cfgpath, keys) then
                        local vchunk = loadfile(cfgpath)
                        if vchunk then
                            local vok, vtbl = pcall(vchunk)
                            if vok and type(vtbl) == "table"
                                and vtbl.model == stbl.model then
                                os.remove(spath)
                                user_tbl = vtbl
                                deep_merge(cfg, vtbl)
                            end
                        end
                    end
                end
            end
        end
    end
    -- providers-table resolution needs the RAW user table (explicit values
    -- win over catalog defaults, including values migrated from the retired
    -- model.lua side file — migration re-merges them as explicit values).
    local eu = user_tbl or {}
    do
        local p = cfg.provider or "openai"
        local up = (eu.providers and eu.providers[p]) or {}
        local def_p = (default_config().providers or {})[p] or {}
        cfg.api_key_env = up.api_key_env or eu.api_key_env
            or def_p.api_key_env or cfg.api_key_env
        cfg.base_url = up.base_url or eu.base_url
            or def_p.base_url or cfg.base_url
        cfg.model = up.model or eu.model
            or def_p.model or cfg.model
    end
    -- expand-provider-catalog: merged compound credential pieces for the
    -- active provider (stored entry env over ambient env; see auth).
    -- Read-only side-file access, same discipline as auto_approve below.
    cfg.provider_env = {}
    do
        local auth_mod = rawget(_G, "auth")
        if not auth_mod then
            local chunk = loadfile("src/tether/auth.lua")
            auth_mod = chunk and chunk() or nil
        end
        if auth_mod and auth_mod.provider_env then
            local ok_env, env = pcall(auth_mod.provider_env,
                cfg.provider or "openai", home)
            if ok_env and type(env) == "table" then cfg.provider_env = env end
        end
    end
    if type(cfg.context) ~= "table" then
        cfg.context = default_config().context
    else
        local def_ctx = default_config().context
        for k, dv in pairs(def_ctx) do
            if cfg.context[k] == nil then cfg.context[k] = dv end
        end
        cfg.context.reserve_tokens = coerce_nonneg(cfg.context.reserve_tokens,
            def_ctx.reserve_tokens)
        cfg.context.keep_recent_messages = coerce_nonneg(
            cfg.context.keep_recent_messages, def_ctx.keep_recent_messages)
        local sat = tonumber(cfg.context.summarize_at)
        if not sat or sat <= 0 or sat >= 1 then cfg.context.summarize_at = def_ctx.summarize_at end
        local mt = tonumber(cfg.context.max_tokens)
        if not mt or mt <= 0 then cfg.context.max_tokens = def_ctx.max_tokens end
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

    -- add-reasoning-level: only the four levels are valid; a missing,
    -- unknown or non-string value behaves as `off` without failing the
    -- session (spec config: Defaults).
    local reasoning_levels = { off = true, low = true, medium = true, high = true }
    if type(cfg.reasoning) ~= "string" or not reasoning_levels[cfg.reasoning] then
        cfg.reasoning = "off"
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
    -- add-provider-login: resolution chain — stored OAuth (unexpired, or
    -- refreshed once when expired) → stored api_key → env → "".
    -- Single resolver shared by TUI and --print (spec: config API key).
    -- Second return: auth style ("bearer" when the token rides
    -- Authorization: Bearer — stored OAuth, ANTHROPIC_AUTH_TOKEN, minted
    -- Vertex tokens). The style is stashed on cfg._auth_style for the
    -- transport header context.
    local auth_mod = rawget(_G, "auth")
    if not auth_mod and type(cfg) == "table" and cfg._auth_home then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    local provider = (cfg and cfg.provider) or "openai"
    local home = (cfg and cfg._auth_home) or nil
    if auth_mod and auth_mod.resolve_entry then
        local store = auth_mod.load(home)
        local entry = store and store[provider]
        if type(entry) == "table" then
            entry.provider = provider
            local post = nil
            if auth_mod._post_json then post = auth_mod._post_json end
            local tok = auth_mod.resolve_entry(entry, post, os.time())
            if type(tok) == "string" and tok ~= "" then
                local style = (entry.kind == "oauth") and "bearer" or nil
                if type(cfg) == "table" then cfg._auth_style = style end
                return tok, style
            end
        end
    end
    if type(cfg) ~= "table" then return "" end
    -- Anthropic token-shaped env vars (pi providers/anthropic.ts).
    if provider == "anthropic" then
        local at = os.getenv("ANTHROPIC_AUTH_TOKEN")
        if at and at ~= "" then
            cfg._auth_style = "bearer"
            return at, "bearer"
        end
        local ot = os.getenv("ANTHROPIC_OAUTH_TOKEN")
        if ot and ot ~= "" then
            cfg._auth_style = nil
            return ot
        end
    end
    -- Vertex ambient ADC: mint an access token when project+location exist.
    -- Both ADC forms (authorized_user refresh-token and service_account JWT)
    -- mint through _post_json; resolve_adc_token covers the service_account
    -- form that used to be discarded (audit).
    if provider == "google-vertex" and auth_mod and auth_mod.read_adc
        and auth_mod._post_json then
        local penv = cfg.provider_env or {}
        local project = penv.GOOGLE_CLOUD_PROJECT or os.getenv("GOOGLE_CLOUD_PROJECT")
            or os.getenv("GCLOUD_PROJECT")
        local location = penv.GOOGLE_CLOUD_LOCATION or os.getenv("GOOGLE_CLOUD_LOCATION")
        if project and project ~= "" and location and location ~= "" then
            local adc = auth_mod.read_adc()
            if adc then
                local tok = nil
                if adc.service_account then
                    tok = auth_mod.resolve_adc_token
                        and auth_mod.resolve_adc_token(adc, auth_mod._post_json, os.time())
                else
                    local entry = { kind = "oauth", provider = provider,
                        refresh_token = adc.refresh_token,
                        client_id = adc.client_id, client_secret = adc.client_secret,
                        refresh_url = "https://oauth2.googleapis.com/token" }
                    tok = auth_mod.resolve_entry(entry, auth_mod._post_json, os.time())
                end
                if type(tok) == "string" and tok ~= "" then
                    cfg._auth_style = "bearer"
                    return tok, "bearer"
                end
            end
        end
    end
    -- load() already folds providers[p].api_key_env into the top-level
    -- api_key_env for the active provider (see M.load lines 123–124). Prefer
    -- that resolved name; only a raw table that never went through load()
    -- needs the providers-table fallback (spec: per-provider env wins).
    -- An explicitly empty name means keyless (OAuth/store only, e.g. codex).
    local env_name = cfg.api_key_env
    if env_name == nil or env_name == "" then
        local p = cfg.provider
        if type(cfg.providers) == "table" and type(cfg.providers[p]) == "table"
            and cfg.providers[p].api_key_env then
            env_name = cfg.providers[p].api_key_env
        end
    end
    -- Compound-credential providers (Cloudflare, Bedrock, Vertex): the key
    -- may come from the stored auth.json `env` object or the process env,
    -- both folded into cfg.provider_env by load()/for_provider. api_key_env
    -- os.getenv below cannot see the stored copy (audit: partial auth header
    -- — cf-aig-authorization: Bearer <empty> with ids filled).
    local penv = (type(cfg) == "table" and type(cfg.provider_env) == "table")
        and cfg.provider_env or nil
    if penv and provider == "cloudflare-workers-ai"
        or provider == "cloudflare-ai-gateway" then
        local k = penv.CLOUDFLARE_API_KEY
        if type(k) == "string" and k ~= "" then
            cfg._auth_style = nil
            return k
        end
    end
    cfg._auth_style = nil
    if env_name == "" then return "" end
    return os.getenv(env_name or "OPENAI_API_KEY") or ""
end

local function auth_module(cfg)
    local auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    return auth_mod
end

-- expand-provider-catalog: per-provider view of a cfg for multi-provider
-- listing. api_key_env/base_url/model resolve user-table → catalog, and
-- compound env merges for the id. Never mutates the input.
function M.for_provider(cfg, id)
    local c2 = {}
    if type(cfg) == "table" then
        for k, v in pairs(cfg) do c2[k] = v end
    end
    c2.provider = id
    local up = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers[id]) == "table") and cfg.providers[id] or {}
    local def = {}
    if catalog and catalog.get then
        local e = catalog.get(id)
        if e then
            def = { api_key_env = e.api_key_env,
                base_url = e.base_url or e.url_template, model = e.model }
        end
    end
    c2.api_key_env = up.api_key_env or def.api_key_env or c2.api_key_env
    c2.base_url = up.base_url or def.base_url or c2.base_url
    c2.model = up.model or def.model or c2.model
    c2._auth_style = nil
    c2.provider_env = {}
    local auth_mod = auth_module(cfg)
    if auth_mod and auth_mod.provider_env then
        local home = (type(cfg) == "table" and cfg._auth_home) or nil
        local ok_env, env = pcall(auth_mod.provider_env, id, home)
        if ok_env and type(env) == "table" then c2.provider_env = env end
    end
    return c2
end

local function env_set(v)
    return v ~= nil and v ~= ""
end

-- expand-provider-catalog: ids holding a usable credential (stored entry or
-- env/ambient source), catalog order, active provider pinned first.
-- Read-only: no refresh, no mint, no network (Bedrock chain is local-only).
function M.providers_with_keys(cfg)
    local home = (type(cfg) == "table" and cfg._auth_home) or nil
    local auth_mod = auth_module(cfg)
    local store = (auth_mod and auth_mod.load) and auth_mod.load(home) or {}
    local function has_stored(id)
        local e = store and store[id]
        if type(e) ~= "table" then return false end
        if e.kind == "api_key" and env_set(e.access_token) then return true end
        if e.kind == "oauth"
            and (env_set(e.access_token) or env_set(e.refresh_token)) then
            return true
        end
        return false
    end
    local function has_env(id)
        if id == "amazon-bedrock" then
            if env_set(os.getenv("AWS_BEARER_TOKEN_BEDROCK")) then return true end
            return auth_mod and auth_mod.aws_creds
                and auth_mod.aws_creds(true) ~= nil or false
        end
        if id == "google-vertex" then
            if env_set(os.getenv("GOOGLE_CLOUD_API_KEY")) then return true end
            local adc = auth_mod and auth_mod.read_adc and auth_mod.read_adc()
            if adc then
                local penv = auth_mod.provider_env
                    and auth_mod.provider_env(id, home) or {}
                local proj = penv.GOOGLE_CLOUD_PROJECT
                    or os.getenv("GOOGLE_CLOUD_PROJECT")
                    or os.getenv("GCLOUD_PROJECT")
                local loc = penv.GOOGLE_CLOUD_LOCATION
                    or os.getenv("GOOGLE_CLOUD_LOCATION")
                if env_set(proj) and env_set(loc) then return true end
            end
            return false
        end
        if id == "cloudflare-workers-ai" or id == "cloudflare-ai-gateway" then
            local penv = auth_mod and auth_mod.provider_env
                and auth_mod.provider_env(id, home) or {}
            if not env_set(penv.CLOUDFLARE_API_KEY) then return false end
            if not env_set(penv.CLOUDFLARE_ACCOUNT_ID) then return false end
            if id == "cloudflare-ai-gateway"
                and not env_set(penv.CLOUDFLARE_GATEWAY_ID) then
                return false
            end
            return true
        end
        if id == "anthropic" then
            if env_set(os.getenv("ANTHROPIC_AUTH_TOKEN")) then return true end
            if env_set(os.getenv("ANTHROPIC_OAUTH_TOKEN")) then return true end
        end
        local entry = catalog and catalog.get(id)
        local env_name = entry and entry.api_key_env or nil
        if env_name == nil or env_name == "" then return false end
        return env_set(os.getenv(env_name))
    end
    local ids = {}
    if catalog and catalog.ids then
        ids = catalog.ids()
    else
        ids = { "openai", "anthropic", "gemini" }
    end
    local out, seen = {}, {}
    for _, id in ipairs(ids) do
        if has_stored(id) or has_env(id) then
            if not seen[id] then seen[id] = true; out[#out + 1] = id end
        end
    end
    -- active provider pinned first when keyed
    local active = (type(cfg) == "table" and cfg.provider) or "openai"
    for i, id in ipairs(out) do
        if id == active and i > 1 then
            table.remove(out, i)
            table.insert(out, 1, id)
            break
        end
    end
    return out
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
