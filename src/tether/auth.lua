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
        -- ADC-style entries carry the OAuth client (Google requires it).
        client_id = entry.client_id,
        client_secret = entry.client_secret,
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
        -- expand-provider-catalog: no access token yet (e.g. Vertex ADC
        -- import) but a refresh token exists → mint one now.
        if M.refresh_token(entry.provider or "", entry, post_json, now) then
            return entry.access_token
        end
        return nil
    end
    if entry.kind == "api_key" and type(entry.access_token) == "string"
        and entry.access_token ~= "" then
        return entry.access_token
    end
    return nil
end

-- expand-provider-catalog: compound credential pieces (Cloudflare account /
-- gateway ids, Vertex project/location, AWS selectors). Per-field merge —
-- stored entry env wins, ambient process env fills the rest (pi
-- resolveCloudflareEnv). Never fails: missing pieces yield {}.
local COMPOUND_KEYS = {
    ["cloudflare-workers-ai"] = { "CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID" },
    ["cloudflare-ai-gateway"] = { "CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID",
                                  "CLOUDFLARE_GATEWAY_ID" },
    ["google-vertex"] = { "GOOGLE_CLOUD_API_KEY", "GOOGLE_CLOUD_PROJECT",
                          "GCLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
                          "GOOGLE_APPLICATION_CREDENTIALS" },
    ["amazon-bedrock"] = { "AWS_BEARER_TOKEN_BEDROCK", "AWS_PROFILE",
                           "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                           "AWS_SESSION_TOKEN", "AWS_REGION", "AWS_DEFAULT_REGION" },
}

function M.provider_env(provider, home)
    local keys = COMPOUND_KEYS[provider]
    if not keys then return {} end
    local out = {}
    for _, k in ipairs(keys) do
        local v = os.getenv(k)
        if v ~= nil and v ~= "" then out[k] = v end
    end
    local store = M.load(home)
    local e = store and store[provider]
    if type(e) == "table" and type(e.env) == "table" then
        for _, k in ipairs(keys) do
            if e.env[k] ~= nil and e.env[k] ~= "" then out[k] = e.env[k] end
        end
    end
    return out
end

-- Read Google Application Default Credentials (user refresh-token form).
-- Returns { refresh_token, client_id, client_secret } or nil.
function M.read_adc()
    local p = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    if not (p and p ~= "") then
        p = (os.getenv("HOME") or ".") .. "/.config/gcloud/application_default_credentials.json"
    end
    local f = io.open(p, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(common.json_decode, data or "")
    if not ok or type(t) ~= "table" then return nil end
    if t.type ~= "authorized_user" then return nil end
    if type(t.refresh_token) ~= "string" or t.refresh_token == "" then return nil end
    return { refresh_token = t.refresh_token,
             client_id = t.client_id, client_secret = t.client_secret }
end

-- AWS credential chain for Bedrock (pi bedrockAuth resolve order):
-- stored bearer is handled by the caller; here ambient sources only.
-- Returns { mode="bearer", token } | { mode="sigv4", key, secret, session, region } | nil.
local function read_aws_profile(name)
    local p = (os.getenv("HOME") or ".") .. "/.aws/credentials"
    local f = io.open(p, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local section = nil
    local out = {}
    for line in (data or ""):gmatch("[^\r\n]+") do
        local sec = line:match("^%s*%[([^%]]+)%]%s*$")
        if sec then
            section = (sec:gsub("^profile%s+", ""))
        elseif section == name then
            local k, v = line:match("^%s*([A-Za-z_]+)%s*=%s*(.-)%s*$")
            if k and v then out[k:lower()] = v end
        end
    end
    if out.aws_access_key_id and out.aws_access_key_id ~= ""
        and out.aws_secret_access_key and out.aws_secret_access_key ~= "" then
        return { key = out.aws_access_key_id, secret = out.aws_secret_access_key,
                 session = out.aws_session_token }
    end
    return nil
end

local function http_collect(method, url, headers, body)
    if not (tether and tether.http_stream) then return nil end
    local lines = {}
    local ok = tether.http_stream(method, url, headers or {}, body or "",
        function(line)
            lines[#lines + 1] = line
            return true
        end, { timeout_s = 10 })
    if not ok then return nil end
    return table.concat(lines, "\n")
end

function M.aws_creds(no_network)
    local bearer = os.getenv("AWS_BEARER_TOKEN_BEDROCK")
    if bearer and bearer ~= "" then
        return { mode = "bearer", token = bearer }
    end
    local key, secret = os.getenv("AWS_ACCESS_KEY_ID"), os.getenv("AWS_SECRET_ACCESS_KEY")
    if key and key ~= "" and secret and secret ~= "" then
        return { mode = "sigv4", key = key, secret = secret,
                 session = os.getenv("AWS_SESSION_TOKEN") }
    end
    local profile = os.getenv("AWS_PROFILE")
    if profile and profile ~= "" then
        local c = read_aws_profile(profile) or read_aws_profile("default")
        if c then
            return { mode = "sigv4", key = c.key, secret = c.secret, session = c.session }
        end
    elseif os.getenv("AWS_PROFILE") == nil then
        -- no explicit profile: default profile still applies when present
        local c = read_aws_profile("default")
        if c then
            return { mode = "sigv4", key = c.key, secret = c.secret, session = c.session }
        end
    end
    -- no_network: availability probes must stay side-effect free (no HTTP).
    if no_network then return nil end
    -- ECS task role (relative or full URI), best-effort over the transport.
    local rel = os.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    local full = os.getenv("AWS_CONTAINER_CREDENTIALS_FULL_URI")
    local ecs_url = full or (rel and ("http://169.254.170.2" .. rel)) or nil
    if ecs_url then
        local body = http_collect("GET", ecs_url)
        if body then
            local ok, t = pcall(common.json_decode, body)
            if ok and type(t) == "table"
                and type(t.AccessKeyId) == "string" and t.AccessKeyId ~= ""
                and type(t.SecretAccessKey) == "string" then
                return { mode = "sigv4", key = t.AccessKeyId,
                         secret = t.SecretAccessKey, session = t.Token }
            end
        end
    end
    -- IRSA (web identity token file + STS), best-effort.
    local token_file = os.getenv("AWS_WEB_IDENTITY_TOKEN_FILE")
    local role = os.getenv("AWS_ROLE_ARN")
    if token_file and token_file ~= "" and role and role ~= "" then
        local f = io.open(token_file, "r")
        local token = f and f:read("*a")
        if f then f:close() end
        if token and token:match("%S") then
            local region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
                or "us-east-1"
            local body = http_collect("POST",
                "https://sts." .. region .. ".amazonaws.com/",
                { "Content-Type: application/x-www-form-urlencoded" },
                "Action=AssumeRoleWithWebIdentity&Version=2011-06-15"
                    .. "&RoleArn=" .. common.url_encode(role)
                    .. "&RoleSessionName=tether"
                    .. "&WebIdentityToken=" .. common.url_encode(token:match("^%s*(.-)%s*$")))
            if body then
                local ak = body:match("<AccessKeyId>(.-)</AccessKeyId>")
                local sk = body:match("<SecretAccessKey>(.-)</SecretAccessKey>")
                local st = body:match("<SessionToken>(.-)</SessionToken>")
                if ak and ak ~= "" and sk and sk ~= "" then
                    return { mode = "sigv4", key = ak, secret = sk, session = st }
                end
            end
        end
    end
    return nil
end

return M
