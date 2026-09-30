-- tether metadata — lazy per-provider model metadata.
--
-- Model lists with context limits live in pipeline shards
-- (data/providers/<id>.json), fetched only for the active provider and
-- only on need (model selection, compaction-limit miss). Routing never
-- waits on this module: absent metadata is silent (see provider-metadata).
-- Discipline mirrors commands.list_models: fresh cache serves with zero
-- network, stale serves immediately with one background refresh, failures
-- cool down for one TTL.
local M = {}

M.METADATA_TTL = 24 * 3600
M.SYNC_TIMEOUT_S = 10

local function catalog()
    return _G.provider_catalog
        or (function()
            local chunk = loadfile("src/tether/providers/catalog.lua")
            return chunk and chunk()
        end)()
end

local function json()
    return _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
end

function M.cache_path(home)
    local h = home
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/metadata_cache.json"
end

function M.pending_path(home, provider)
    return M.cache_path(home) .. "." .. (provider or "openai") .. ".pending"
end

-- Shard URL for one provider id. Derived from the endpoints URL by
-- convention (its directory + /providers/<id>.json) so a custom
-- providers_url mirror carries its shards alongside. The id is restricted
-- to kebab-case so it can never escape into a path.
function M.shard_url(provider, url)
    if type(provider) ~= "string"
        or not provider:match("^[a-z0-9%-]+$") then
        return nil, "bad provider id"
    end
    local base = url
    if type(base) ~= "string" or base == "" then
        local cat = catalog()
        base = (cat and cat.PROVIDERS_URL) or nil
    end
    if type(base) ~= "string" or base == "" then
        return nil, "no providers url"
    end
    base = base:gsub("/+$", "")
    local dir = base:match("^(.*)/[^/]*$") or base
    return dir .. "/providers/" .. provider .. ".json"
end

-- Verify a shard body. Returns the normalized models list [{id, context}]
-- or nil + reason. Unknown fields are ignored; an unsupported schema or a
-- mismatched id discards the whole shard (caller falls back to stale).
function M.parse_shard(body, provider)
    if type(body) ~= "string" or body == "" then
        return nil, "empty metadata shard"
    end
    if body:match("^FETCH_FAILED") then
        return nil, (body:match("^FETCH_FAILED%s*(.-)%s*$") or "request failed")
    end
    local c = json()
    if not c then return nil, "no json parser" end
    local ok, tbl = pcall(c.json_decode, body)
    if not ok or type(tbl) ~= "table" then
        return nil, "unparseable metadata shard"
    end
    local cat = catalog()
    local schema = (cat and cat.SCHEMA_VERSION) or 1
    if tbl.schema ~= schema then
        return nil, "unsupported metadata schema " .. tostring(tbl.schema)
    end
    if tbl.id ~= nil and tbl.id ~= provider then
        return nil, "shard id mismatch"
    end
    if type(tbl.models) ~= "table" then
        return nil, "shard has no models table"
    end
    local out = {}
    for _, m in ipairs(tbl.models) do
        local id = (type(m) == "table" and m.id) or m
        if type(id) == "string" and id ~= "" then
            local ctx = (type(m) == "table" and m.context) or nil
            out[#out + 1] = { id = id,
                context = (type(ctx) == "number" and ctx > 0) and ctx or nil }
        end
    end
    return out
end

local function read_cache(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local j = json()
    if not j then return {} end
    local ok, tbl = pcall(j.json_decode, data or "")
    if not ok or type(tbl) ~= "table" then return {} end
    return tbl
end

local function write_cache(path, tbl)
    local j = json()
    if not j then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(j.json_encode(tbl))
    f:close()
    return true
end

-- Cached shard models for one provider, or nil. Never touches the network;
-- the silent-absent path for startup warnings and compaction budgets.
function M.cached(provider, home)
    if type(provider) ~= "string" or provider == "" then return nil end
    local cache = read_cache(M.cache_path(home))
    local entry = cache[provider]
    if type(entry) == "table" and type(entry.models) == "table" then
        return entry.models
    end
    return nil
end

-- Fetch-on-need shard models for one provider. Returns models + status +
-- optional reason; status is "fresh" | "background" | "ok" | "stale" |
-- "missing". Fresh cache serves with zero network; stale serves immediately
-- with one background refresh; a miss blocks on one sync attempt (at most
-- M.SYNC_TIMEOUT_S) so the first /model open can show limits. With
-- opts.refresh == false no HTTP is issued at all (the metadata_refresh
-- opt-out): disk serves, absence stays silent.
function M.models(provider, home, url, opts)
    if type(provider) ~= "string" or provider == "" then
        return nil, "missing", "bad provider id"
    end
    local path = M.cache_path(home)
    local cache = read_cache(path)
    local entry = cache[provider]
    local now = os.time()
    local checked = type(entry) == "table" and tonumber(entry.checked_at)
    if checked and (now - checked) < M.METADATA_TTL
        and type(entry.models) == "table" then
        return entry.models, "fresh"
    end
    local stale = (type(entry) == "table" and type(entry.models) == "table"
        and entry.models) or nil
    if type(opts) == "table" and opts.refresh == false then
        if stale then return stale, "stale", "metadata refresh disabled" end
        return nil, "missing", "metadata refresh disabled"
    end
    local u, uerr = M.shard_url(provider, url)
    if not u then
        if stale then return stale, "stale", uerr end
        return nil, "missing", uerr
    end
    local th = rawget(_G, "tether")
    -- Background refresh only when stale data can serve meanwhile.
    if th and th.fetch_bg and stale then
        local pend = M.pending_path(home, provider)
        local pf = io.open(pend, "r")
        if pf then
            pf:close()
            return stale, "background"
        end
        local mf = io.open(pend, "w")
        if mf then
            mf:close()
            local ok, res = pcall(th.fetch_bg, u, {}, pend, 20)
            if ok and res then return stale, "background" end
            os.remove(pend)
        end
    end
    if th and th.http_get then
        local ok, body, herr = pcall(th.http_get, u, {},
            M.SYNC_TIMEOUT_S)
        if ok and type(body) == "string" and body ~= "" then
            local models, perr = M.parse_shard(body, provider)
            if models then
                cache[provider] = { checked_at = now, models = models }
                write_cache(path, cache)
                return models, "ok"
            end
            if stale then return stale, "stale", perr end
            return nil, "missing", perr
        end
        if stale then return stale, "stale", herr or "request failed" end
        return nil, "missing", herr or "request failed"
    end
    if stale then return stale, "stale", "no http client" end
    return nil, "missing", "no http client"
end

-- Consume a finished background shard fetch. Returns "updated" | "waiting" |
-- "settled" (same contract as the providers/model-list poll hooks).
function M.poll(home, provider)
    local pend = M.pending_path(home, provider)
    local f = io.open(pend, "r")
    if not f then return "settled" end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then
        -- empty marker: child hasn't finished; a marker older than 120s is
        -- a crashed child — drop it and settle.
        local th = rawget(_G, "tether")
        if th and th.stat then
            local ok, st = pcall(th.stat, pend)
            if ok and type(st) == "table" and tonumber(st.mtime)
                and (os.time() - st.mtime) > 120 then
                os.remove(pend)
                return "settled"
            end
        end
        return "waiting"
    end
    os.remove(pend)
    local models, perr = M.parse_shard(body, provider)
    local now = os.time()
    local path = M.cache_path(home)
    if not models then
        -- failure cools down like a models miss: checked_at persists so a
        -- dead source blocks at most once per TTL, not per open.
        local old = read_cache(path)
        local entry = old[provider]
        if type(entry) ~= "table" then entry = {} end
        entry.checked_at = now
        old[provider] = entry
        write_cache(path, old)
        return "settled"
    end
    local cache = read_cache(path)
    cache[provider] = { checked_at = now, models = models }
    write_cache(path, cache)
    return "updated"
end

-- Pure context-limit lookup over a models list: exact hit, else the
-- provider-default entry, else nil (the caller applies its own fallback).
function M.limit(models, want, fallback)
    if type(models) ~= "table" then return nil end
    local fb = nil
    for _, m in ipairs(models) do
        local id = (type(m) == "table" and m.id) or m
        local cx = (type(m) == "table" and m.context) or nil
        if type(cx) == "number" and cx > 0 then
            if id == want then return cx end
            if id == fallback then fb = cx end
        end
    end
    return fb
end

return M
