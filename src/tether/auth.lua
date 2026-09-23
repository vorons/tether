-- tether auth — OAuth/API-key credential store for /login and /logout.
-- Machine-managed side file ~/.tether/auth.json (mode 0600 from creation).
-- Secrets never reach the session journal, transcript, debug log, or argv.
local M = {}

local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "auth: cannot load provider_common")

local AUTH_FILE_MODE = tonumber("600", 8)
M.AUTH_FILE_MODE = AUTH_FILE_MODE

local function home_dir(home)
    if type(home) == "string" and home ~= "" then return home end
    return os.getenv("HOME") or "."
end

function M.path(home)
    return home_dir(home) .. "/.tether/auth.json"
end

-- Tolerant load: missing or corrupt store → empty table (never fails startup).
function M.load(home)
    local f = io.open(M.path(home), "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    if not data or data == "" then return {} end
    local ok, tbl = pcall(common.json_decode, data)
    if not ok or type(tbl) ~= "table" then return {} end
    return tbl
end

-- Create-empty + fchmod 0600 before any secret is written (same discipline
-- as the API header temp file). Returns true when the store is writable.
function M.ensure_private(path)
    path = path or M.path()
    local f = io.open(path, "a")
    if not f then return false end
    f:close()
    if tether and tether.fchmod then
        if not tether.fchmod(path, AUTH_FILE_MODE) then
            os.remove(path)
            return false
        end
    end
    return true
end

function M.save(home, store)
    local path = M.path(home)
    if not M.ensure_private(path) then return false end
    -- rewrite after private creation; atomicity is last-writer-wins (single session)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(common.json_encode(type(store) == "table" and store or {}))
    f:close()
    return true
end

function M.get(home, provider)
    local store = M.load(home)
    local e = store[provider]
    if type(e) ~= "table" then return nil end
    if type(e.access_token) ~= "string" or e.access_token == "" then
        if type(e.kind) == "string" then return e end
        return nil
    end
    return e
end

function M.set(home, provider, entry)
    if type(provider) ~= "string" or provider == "" then return false end
    if type(entry) ~= "table" then return false end
    local store = M.load(home)
    store[provider] = entry
    return M.save(home, store)
end

function M.delete(home, provider)
    local store = M.load(home)
    if store[provider] == nil then return true end
    store[provider] = nil
    return M.save(home, store)
end

-- Redact token material in any logged/error string (banners, journal, slog).
function M.redact(s)
    if type(s) ~= "string" or s == "" then return s end
    local out = s
    out = out:gsub("([Bb]earer%s+)[%w%-%._~%+/=]+", "%1***")
    out = out:gsub("([Aa]ccess[_%-]?[Tt]oken\"?%s*:%s*\")[^\"]+\"", "%1***\"")
    out = out:gsub("([Rr]efresh[_%-]?[Tt]oken\"?%s*:%s*\")[^\"]+\"", "%1***\"")
    out = out:gsub("([Aa]uthorization\"?%s*:%s*\")[^\"]+\"", "%1***\"")
    out = out:gsub("([Aa][Pp][Ii][_%-]?[Kk]ey\"?%s*:%s*\")[^\"]+\"", "%1***\"")
    return out
end

-- add-provider-login 3.3: real form-urlencoded POST via the in-process
-- transport (refresh / authorization-code exchange). Body stays off argv
-- (http_stream takes the payload as a Lua string, not a shell argument).
function M._post_json(url, body)
    if type(url) ~= "string" or url == "" then return nil, "bad url" end
    if type(body) ~= "table" then return nil, "bad body" end
    if not (tether and tether.http_stream) then return nil, "no http" end
    local parts = {}
    for k, v in pairs(body) do
        parts[#parts + 1] = common.url_encode(tostring(k))
            .. "=" .. common.url_encode(tostring(v))
    end
    local form = table.concat(parts, "&")
    local lines = {}
    local ok, err = tether.http_stream("POST", url, {
        "Content-Type: application/x-www-form-urlencoded",
    }, form, function(line)
        lines[#lines + 1] = line
        return true
    end, { timeout_s = 15 })
    if not ok then return nil, err end
    return table.concat(lines, "\n")
end

local function is_expired(entry, now)
    if type(entry) ~= "table" then return false end
    local exp = tonumber(entry.expires_at)
    if not exp then return false end
    return (tonumber(now) or os.time()) >= exp
end
M._is_expired = is_expired

-- OAuth refresh token exchange. `post_json(url, body)` must return
-- (body_string) or (nil, err). Persisting happens only on a well-formed
-- access_token response.
function M.refresh_token(provider, entry, post_json, now)
    if type(entry) ~= "table" then return false end
    local rt = entry.refresh_token
    if type(rt) ~= "string" or rt == "" then return false end
    if type(post_json) ~= "function" then return false end
    -- Provider-specific token endpoints live behind cfg/entry.refresh_url so
    -- the core store stays transport-agnostic (see design.md).
    local url = entry.refresh_url
    if type(url) ~= "string" or url == "" then return false end
    local ok, body = pcall(post_json, url, {
        grant_type = "refresh_token",
        refresh_token = rt,
    })
    if not ok or type(body) ~= "string" or body == "" then return false end
    local parsed_ok, parsed = pcall(common.json_decode, body)
    if not parsed_ok or type(parsed) ~= "table" then return false end
    local access = parsed.access_token
    if type(access) ~= "string" or access == "" then return false end
    entry.access_token = access
    if type(parsed.refresh_token) == "string" and parsed.refresh_token ~= "" then
        entry.refresh_token = parsed.refresh_token
    end
    if parsed.expires_in ~= nil then
        entry.expires_at = (tonumber(now) or os.time()) + (tonumber(parsed.expires_in) or 0)
    end
    entry.kind = "oauth"
    return true
end

-- Eager resolution for one provider entry: valid oauth token → refresh once
-- when expired → stored api_key kind → nil.
function M.resolve_entry(entry, post_json, now)
    if type(entry) ~= "table" then return nil end
    if entry.kind == "oauth" then
        local tok = entry.access_token
        if type(tok) == "string" and tok ~= "" then
            if not is_expired(entry, now) then return tok end
            if M.refresh_token(entry.provider or "", entry, post_json, now) then
                return entry.access_token
            end
            -- expired + unrefreshable → fall through (caller may use env)
            return nil
        end
        return nil
    end
    if entry.kind == "api_key" and type(entry.access_token) == "string"
        and entry.access_token ~= "" then
        return entry.access_token
    end
    return nil
end

return M
