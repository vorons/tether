-- tether config_auth — credential and per-provider resolution.
--
-- api_key/for_provider/providers_with_keys: stored OAuth/env resolution,
-- per-provider cfg views, keyed-provider listing. Read-only against the
-- outside world except os.getenv; no config-file writes (those live in
-- config_schema). Shared catalog/auth instances resolve through globals
-- with loadfile fallbacks for dev/test runs.
local M = {}

local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

local function auth_module(cfg)
    local auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    return auth_mod
end
M.auth_module = auth_module

-- expand-provider-catalog: per-provider view of a cfg for multi-provider
-- listing. api_key_env/base_url/model resolve user-table → catalog, and
-- compound env merges for the id. Never mutates the input.
local function for_provider(cfg, id)
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
M.for_provider = for_provider

local function env_set(v)
    return v ~= nil and v ~= ""
end

-- expand-provider-catalog: ids holding a usable credential (stored entry or
-- env/ambient source), catalog order, active provider pinned first.
-- Read-only: no refresh, no mint, no network (Bedrock chain is local-only).
local function providers_with_keys(cfg)
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
        if catalog and catalog.env_name then
            env_name = catalog.env_name(env_name)
        end
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
M.providers_with_keys = providers_with_keys

local function api_key(cfg)
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
    -- api_key_env for the active provider. Prefer that resolved name; only
    -- a raw table that never went through load() needs the providers-table
    -- fallback (spec: per-provider env wins).
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
    if penv and (provider == "cloudflare-workers-ai"
        or provider == "cloudflare-ai-gateway") then
        local k = penv.CLOUDFLARE_API_KEY
        if type(k) == "string" and k ~= "" then
            cfg._auth_style = nil
            return k
        end
    end
    cfg._auth_style = nil
    if env_name == "" then return "" end
    -- dynamic-provider-catalog: pipeline entries carry api_key_env lists
    -- ("first set wins"); resolve to one name before getenv.
    if catalog and catalog.env_name then
        env_name = catalog.env_name(env_name)
    end
    if env_name == nil or env_name == "" then return "" end
    return os.getenv(env_name or "OPENAI_API_KEY") or ""
end
M.api_key = api_key

return M
