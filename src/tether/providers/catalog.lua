-- tether providers/catalog — thin bootstrap + merged view.
-- Tier-A provider data arrives via the pipeline cache
-- (~/.tether/providers_cache.json, generated from models.dev; see
-- dynamic-provider-catalog) and an optional user overlay
-- (~/.tether/models.lua). This file bundles only what the pipeline cannot
-- provide: local runtimes, Tier-B adapter entries, and endpoint-less ids.
-- get()/ids() read the merged view; entries stays the bootstrap.
local M = {}

-- wire: "openai" | "anthropic" | "gemini" | adapter module id (Tier-B).
-- url_template: {VAR} placeholders expanded from cfg.provider_env/os env.
-- api_key_env "": provider takes no env key (OAuth/store only).
--
-- dynamic-provider-catalog: M.entries is the thin bootstrap only (local
-- providers + Tier-B adapters + endpoint-less entries). Tier-A arrives via
-- the pipeline cache (~/.tether/providers_cache.json, see ensure()) and an
-- optional user overlay (~/.tether/models.lua). get()/ids() read the merged
-- view; entries stays the bootstrap for reference.
M.entries = {
    -- Local runtimes (loopback; keyless live listing, offline-capable).
    -- NOTE: upstream `llama` is Meta's cloud Llama API, not llama.cpp —
    -- the local default lives under `llama-cpp` and never collides.
    ["llama-cpp"] = { wire = "openai", base_url = "http://127.0.0.1:8080/v1",
                 api_key_env = "LLAMA_API_KEY", model = "" },
    ollama    = { wire = "openai", base_url = "http://localhost:11434/v1",
                 api_key_env = "OLLAMA_API_KEY", model = "" },
    lmstudio  = { wire = "openai", base_url = "http://127.0.0.1:1234/v1",
                 api_key_env = "LMSTUDIO_API_KEY", model = "" },

    -- Tier-B: own adapter modules (src/tether/providers/<wire>.lua)
    ["azure-openai"] = { wire = "azure-openai",
                 base_url = "", api_key_env = "AZURE_OPENAI_API_KEY", model = "gpt-4o" },
    ["amazon-bedrock"] = { wire = "amazon-bedrock",
                 base_url = "", api_key_env = "AWS_BEARER_TOKEN_BEDROCK",
                 model = "us.anthropic.claude-sonnet-4-20250514-v1:0" },
    ["google-vertex"] = { wire = "google-vertex",
                 base_url = "", api_key_env = "GOOGLE_CLOUD_API_KEY", model = "gemini-2.5-flash" },
    ["cloudflare-ai-gateway"] = { wire = "cloudflare-ai-gateway",
                 url_template = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai",
                 api_key_env = "CLOUDFLARE_API_KEY", model = "gpt-4o-mini" },
    radius    = { wire = "radius",
                 base_url = "https://radius.pi.dev",
                 api_key_env = "RADIUS_API_KEY", model = "" },
    ["openai-codex"] = { wire = "openai-codex",
                 base_url = "https://chatgpt.com/backend-api",
                 api_key_env = "", model = "gpt-5.3-codex" },
}

-- Picker order: the big three first, then alphabetical.
local PINNED = { "openai", "anthropic", "gemini" }

-- dynamic-provider-catalog: sync source. The owner/repo default matches the
-- workflow in .github/workflows/sync-providers.yml; override with
-- cfg.providers_url (top-level) when the data lives elsewhere.
M.PROVIDERS_URL =
    "https://raw.githubusercontent.com/vorons/tether/main/data/providers.json"
M.SCHEMA_VERSION = 1
M.CACHE_TTL = 12 * 3600
M.DEFAULT_ID = "llama-cpp"

local function home_dir(home)
    if type(home) == "string" and home ~= "" then return home end
    -- TETHER_HOME overrides HOME (portable installs, test isolation).
    local t = os.getenv("TETHER_HOME")
    if type(t) == "string" and t ~= "" then return t end
    return os.getenv("HOME") or "."
end

function M.cache_path(home)
    return home_dir(home) .. "/.tether/providers_cache.json"
end

function M.pending_path(home)
    return M.cache_path(home) .. ".pending"
end

function M.models_lua_path(home)
    return home_dir(home) .. "/.tether/models.lua"
end

local function common()
    return _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
end

-- Verify a downloaded providers file. Returns the decoded table or
-- nil + reason. Unknown fields are ignored; an unsupported schema major
-- discards the whole file (caller falls back to stale cache).
function M.parse_file(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty providers file"
    end
    if body:match("^FETCH_FAILED") then
        return nil, (body:match("^FETCH_FAILED%s*(.-)%s*$") or "request failed")
    end
    local c = common()
    if not c then return nil, "no json parser" end
    local ok, tbl = pcall(c.json_decode, body)
    if not ok or type(tbl) ~= "table" then
        return nil, "unparseable providers file"
    end
    if tbl.schema ~= M.SCHEMA_VERSION then
        return nil, "unsupported providers schema " .. tostring(tbl.schema)
    end
    if type(tbl.providers) ~= "table" then
        return nil, "providers file has no providers table"
    end
    return tbl
end

-- Read the optional user overlay. Missing file is silent (nil, nil);
-- a broken file warns to stderr and is ignored (nil + reason).
function M.read_models_lua(home)
    local path = M.models_lua_path(home)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local chunk, err = loadfile(path)
    if not chunk then
        io.stderr:write("tether: models error: " .. tostring(err) .. "\n")
        return nil, err
    end
    local ok, tbl = pcall(chunk)
    if not ok or type(tbl) ~= "table" then
        io.stderr:write("tether: models error: file must return a table\n")
        return nil, "file must return a table"
    end
    if tbl.providers ~= nil and type(tbl.providers) ~= "table" then
        io.stderr:write("tether: models error: providers must be a table\n")
        return nil, "providers must be a table"
    end
    return tbl.providers or {}
end

local function copy_entry(e)
    if type(e) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(e) do out[k] = v end
    return out
end

-- Merge layers low -> high: bootstrap < pipeline cache < models.lua
-- (whole entry per id). Pure function over inputs; never mutates them.
-- Returns merged entries + meta {generated_at, sources}.
function M.merge(bootstrap, cache_providers, models_lua_providers, generated_at)
    local merged = {}
    if type(bootstrap) == "table" then
        for id, e in pairs(bootstrap) do
            local c = copy_entry(e)
            if c then c._source = "bootstrap"; merged[id] = c end
        end
    end
    if type(cache_providers) == "table" then
        for id, e in pairs(cache_providers) do
            if type(id) == "string" and type(e) == "table" then
                local c = copy_entry(e)
                c._source = "cache"
                merged[id] = c
            end
        end
    end
    if type(models_lua_providers) == "table" then
        for id, e in pairs(models_lua_providers) do
            if type(id) == "string" and type(e) == "table" then
                local c = copy_entry(e)
                c._source = "models.lua"
                merged[id] = c
            end
        end
    end
    return merged, { generated_at = generated_at,
        bootstrap = type(bootstrap) == "table",
        cache = type(cache_providers) == "table",
        overlay = type(models_lua_providers) == "table" }
end

-- Merged view state. ensure() fills it once per process+home; get()/ids()
-- fall back to the bootstrap when it is empty (tests, dev runs).
M._merged = nil
M._meta = nil
M._home = nil

-- Test seam / poll hook: layer entries over the bootstrap as the merged
-- view (same position as the pipeline cache layer). nil clears the view
-- (poll re-merges from disk right after).
function M.set_overlay(entries, meta)
    if entries == nil then
        M._merged, M._meta, M._home = nil, nil, nil
        return
    end
    local merged, m = M.merge(M.entries, entries, nil, nil)
    M._merged = merged
    M._meta = meta
end

function M.overlay_meta()
    return M._meta
end

-- Load cache + models.lua from home and merge over the bootstrap.
-- Returns "ready" | nil + reason. Missing cache is nil + a naming error
-- (the caller decides: bootstrap-local ids still work offline).
function M.ensure(home)
    -- one home per process in prod; a different home re-merges (tests use
    -- several temp homes in one process — a stale merge would leak).
    if M._merged and M._home == home then return "ready" end
    local cache_providers, generated_at = nil, nil
    local cf = io.open(M.cache_path(home), "r")
    local cache_err = nil
    if cf then
        local body = cf:read("*a")
        cf:close()
        local tbl, err = M.parse_file(body or "")
        if tbl then
            cache_providers, generated_at = tbl.providers, tbl.generated_at
        else
            cache_err = err
        end
    else
        cache_err = "no providers cache at " .. M.cache_path(home)
    end
    local overlay = M.read_models_lua(home)
    if not cache_providers and not overlay then
        return nil, cache_err or "no providers available"
    end
    if cache_err and not cache_providers then
        io.stderr:write("tether: providers cache ignored (" .. cache_err .. ")\n")
    end
    local merged, meta = M.merge(M.entries, cache_providers, overlay,
        generated_at)
    M._merged = merged
    M._meta = meta
    M._home = home
    return "ready"
end

-- Resolve an api_key_env value (string or list) to a single var name.
-- Lists mean "first set wins" (pipeline entries carry every known var);
-- with none set the first name is returned so diagnostics name a var.
function M.env_name(v)
    if type(v) ~= "table" then return v end
    for _, name in ipairs(v) do
        if type(name) == "string" and name ~= "" then
            local val = os.getenv(name)
            if val ~= nil and val ~= "" then return name end
        end
    end
    return type(v[1]) == "string" and v[1] or nil
end

-- Full merged view (bootstrap when no overlay loaded yet).
function M.all()
    return M._merged or M.entries
end

function M.get(id)
    if type(id) ~= "string" then return nil end
    return M.all()[id]
end

function M.ids()
    local all = M.all()
    local out = {}
    for _, id in ipairs(PINNED) do
        if all[id] then out[#out + 1] = id end
    end
    local rest = {}
    for id in pairs(all) do
        if id ~= "openai" and id ~= "anthropic" and id ~= "gemini" then
            rest[#rest + 1] = id
        end
    end
    table.sort(rest)
    for _, id in ipairs(rest) do out[#out + 1] = id end
    return out
end

function M.count()
    local n = 0
    for _ in pairs(M.all()) do n = n + 1 end
    return n
end

-- expand-provider-catalog: generic login flow for preset ids without their
-- own adapter module. Endpoints are config-sourced only (never invented):
-- providers.<id>.oauth_device_url + oauth_client_id → device flow;
-- oauth_client_id + oauth_token_url + oauth_authorize_url → code flow.
-- Otherwise nil (the caller falls back to API-key paste).
function M.login_flow(cfg, id)
    if type(id) ~= "string" or not M.all()[id] then return nil end
    local p = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers[id]) == "table") and cfg.providers[id] or {}
    local cid = p.oauth_client_id
    if type(cid) ~= "string" or cid == "" then return nil end
    if type(p.oauth_device_url) == "string" and p.oauth_device_url ~= "" then
        -- provider-auth: a full device flow needs the token endpoint too
        -- (the TUI polls it while the user authorizes). Without it the flow
        -- degrades to device-URL + paste-token (the pre-device-flow path).
        return {
            provider = id,
            device = true,
            client_id = cid,
            scope = p.oauth_scope,
            authorize_url = p.oauth_device_url,
            device_url = p.oauth_device_url,
            device_token_url = p.oauth_token_url,
        }
    end
    if type(p.oauth_token_url) ~= "string" or p.oauth_token_url == "" then
        return nil
    end
    if type(p.oauth_authorize_url) ~= "string" or p.oauth_authorize_url == "" then
        return nil
    end
    local common = _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
    if not common then return nil end
    local flow = {
        provider = id,
        client_id = cid,
        client_secret = p.oauth_client_secret,
        redirect_uri = p.oauth_redirect_uri or "http://localhost:7/",
        scope = p.oauth_scope,
        token_url = p.oauth_token_url,
    }
    flow.authorize_url = common.oauth_authorize_url(p.oauth_authorize_url, flow)
    if not flow.authorize_url then return nil end
    return flow
end

return M
