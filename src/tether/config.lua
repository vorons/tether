-- tether M2: config — load ~/.tether/config.lua, merge with defaults
local M = {}

-- expand-provider-catalog: per-provider defaults come from the preset
-- catalog (single source with api.lua and the /login picker).
local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

-- modular-next-phases F: defaults/merge/writers live in config_schema,
-- credential resolution in config_auth — globals in the built binary,
-- loadfile fallbacks for dev/test runs. load/merge orchestration stays here.
local config_schema = _G.config_schema
    or (function()
        local chunk = loadfile("src/tether/config_schema.lua")
        return chunk and chunk()
    end)()
assert(config_schema, "config: cannot load config_schema")

local config_auth = _G.config_auth
    or (function()
        local chunk = loadfile("src/tether/config_auth.lua")
        return chunk and chunk()
    end)()
assert(config_auth, "config: cannot load config_auth")


function M.load(path, home)
    -- dynamic-provider-catalog: merge pipeline cache + models.lua over the
    -- thin bootstrap BEFORE config_schema.default_config() snapshots catalog defaults.
    -- File reads only, no network; a missing cache warns here, the startup
    -- gate (commands.check_providers) decides brick vs bootstrap-local.
    do
        local h = home or os.getenv("HOME")
        if catalog and catalog.ensure then
            local ok, err = catalog.ensure(h)
            if not ok then
                io.stderr:write("tether: providers: " .. tostring(err) .. "\n")
            end
        end
    end
    local cfg = config_schema.default_config()
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
        if config_schema.write_bootstrap(cfgpath) then
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
            config_schema.deep_merge(cfg, tbl)
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
                    if config_schema.persist_keys_to_path(cfgpath, keys) then
                        local vchunk = loadfile(cfgpath)
                        if vchunk then
                            local vok, vtbl = pcall(vchunk)
                            if vok and type(vtbl) == "table"
                                and vtbl.model == stbl.model then
                                os.remove(spath)
                                user_tbl = vtbl
                                config_schema.deep_merge(cfg, vtbl)
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
        local def_p = (config_schema.default_config().providers or {})[p] or {}
        cfg.api_key_env = up.api_key_env or eu.api_key_env
            or def_p.api_key_env or cfg.api_key_env
        cfg.base_url = up.base_url or eu.base_url
            or def_p.base_url or cfg.base_url
        cfg.model = up.model or eu.model
            or def_p.model or cfg.model
    end
    -- dynamic-provider-catalog: a pinned model absent from the merged
    -- catalog still resolves (the request goes out verbatim) but warns
    -- here — pre-TUI startup is the only legal stderr moment. An empty
    -- merged list means "unknown", never "renamed": no warning then.
    do
        local p = cfg.provider
        local e = (catalog and catalog.get and p) and catalog.get(p) or nil
        local ids = (e and type(e.models) == "table") and e.models or nil
        if ids and #ids > 0 and type(cfg.model) == "string" and cfg.model ~= "" then
            local found = false
            for _, m in ipairs(ids) do
                local id = (type(m) == "table" and m.id) or m
                if id == cfg.model then found = true; break end
            end
            if not found then
                io.stderr:write("tether: model '" .. cfg.model
                    .. "' not in the providers catalog for '" .. tostring(p)
                    .. "' (will still try)\n")
            end
        end
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
        cfg.context = config_schema.default_config().context
    else
        local def_ctx = config_schema.default_config().context
        for k, dv in pairs(def_ctx) do
            if cfg.context[k] == nil then cfg.context[k] = dv end
        end
        cfg.context.reserve_tokens = config_schema.coerce_nonneg(cfg.context.reserve_tokens,
            def_ctx.reserve_tokens)
        cfg.context.keep_recent_messages = config_schema.coerce_nonneg(
            cfg.context.keep_recent_messages, def_ctx.keep_recent_messages)
        local sat = tonumber(cfg.context.summarize_at)
        if not sat or sat <= 0 or sat >= 1 then cfg.context.summarize_at = def_ctx.summarize_at end
        local mt = tonumber(cfg.context.max_tokens)
        if not mt or mt <= 0 then cfg.context.max_tokens = def_ctx.max_tokens end
        -- compaction-anchors-preflight-prune: boolean knobs; a missing or
        -- non-boolean value falls back to its default without failing.
        for _, k in ipairs({ "anchors", "preflight", "prune_superseded_reads" }) do
            if type(cfg.context[k]) ~= "boolean" then
                cfg.context[k] = def_ctx[k]
            end
        end
    end

    -- add-retry-and-continuation: a legacy top-level `retries` was the hard
    -- attempt cap. It still is — mapped onto the policy's attempt cap — so an
    -- existing configuration keeps its budget. `retry.max_attempts` wins.
    if type(cfg.retry) ~= "table" then cfg.retry = config_schema.default_config().retry end
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

    -- subagent: max_parallel floors at 1; non-numeric values fall back
    -- without failing the session (spec config: Subagent configuration).
    if type(cfg.subagents) ~= "table" then
        cfg.subagents = config_schema.default_config().subagents
    else
        local def_sub = config_schema.default_config().subagents
        local mp = tonumber(cfg.subagents.max_parallel)
        if mp == nil then
            cfg.subagents.max_parallel = def_sub.max_parallel
        else
            cfg.subagents.max_parallel = math.max(1, math.floor(mp))
        end
        local to = tonumber(cfg.subagents.timeout)
        cfg.subagents.timeout = (to and to >= 1) and to or def_sub.timeout
        local md = tonumber(cfg.subagents.max_depth)
        cfg.subagents.max_depth = (md and math.floor(md) >= 0)
            and math.floor(md) or def_sub.max_depth
    end

    -- prompt-cache v1: cache table with per-key fallbacks; a missing or
    -- malformed value falls back to its default without failing the
    -- session (spec config: Cache configuration table).
    if type(cfg.cache) ~= "table" then
        cfg.cache = config_schema.default_config().cache
    else
        local def_cache = config_schema.default_config().cache
        if type(cfg.cache.enabled) ~= "boolean" then
            cfg.cache.enabled = def_cache.enabled
        end
        if cfg.cache.retention ~= "auto" and cfg.cache.retention ~= "5m"
            and cfg.cache.retention ~= "1h" and cfg.cache.retention ~= "24h" then
            cfg.cache.retention = def_cache.retention
        end
        if cfg.cache.key_scope ~= "session" and cfg.cache.key_scope ~= "session_role" then
            cfg.cache.key_scope = def_cache.key_scope
        end
        local ib = tonumber(cfg.cache.intermediate_breakpoints)
        if ib == nil or ib < 0 then
            cfg.cache.intermediate_breakpoints = def_cache.intermediate_breakpoints
        else
            cfg.cache.intermediate_breakpoints = math.floor(ib)
        end
        if type(cfg.cache.debug) ~= "boolean" then
            cfg.cache.debug = def_cache.debug
        end
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

-- Credential resolution lives in config_auth; the M.* name stays
-- for app.lua and tests.
function M.api_key(cfg)
    return config_auth.api_key(cfg)
end

-- Facade compatibility: implementations live in config_auth/config_schema;
-- in-repo callers (commands list_models_all, ui model/think pickers) keep
-- the M.* names with nil-guarded dynamic dispatch.
function M.for_provider(cfg, id)
    return config_auth.for_provider(cfg, id)
end

function M.providers_with_keys(cfg)
    return config_auth.providers_with_keys(cfg)
end

function M.persist_keys(home, keys)
    return config_schema.persist_keys(home, keys)
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
