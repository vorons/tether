-- tether api — provider dispatcher + shared transport.
-- Per-provider request/SSE logic lives in src/tether/providers/*; this
-- module owns what is identical for all providers: the in-process HTTP loop,
-- auth/body temp files, and per-attempt failure surfacing.
-- agent.lua sees only canonical events and never branches on provider.
--
-- add-retry-and-continuation: one call = one attempt. The client does not
-- sleep or repeat a request — it reports `ok, failure` and the agent's turn
-- loop owns the backoff schedule, so no two budgets can interleave.
local M = {}

-- expand-provider-catalog: preset catalog (Tier-A aliases + Tier-B adapter
-- ids). The catalog is data only; wire modules stay the three native ones
-- plus one adapter module per Tier-B id (src/tether/providers/<wire>.lua).
local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

local WIRE_MODULES = {
    openai    = { global = "provider_openai",    path = "src/tether/providers/openai.lua" },
    anthropic = { global = "provider_anthropic", path = "src/tether/providers/anthropic.lua" },
    gemini    = { global = "provider_gemini",    path = "src/tether/providers/gemini.lua" },
}

local function load_module(spec)
    if _G[spec.global] then return _G[spec.global] end
    -- Dev/test fallback: embedded binary has no source files on disk,
    -- but there the C host preloads the globals above.
    local chunk = loadfile(spec.path)
    if chunk then
        local ok, mod = pcall(chunk)
        if ok and mod then return mod end
    end
    return nil
end

local warned_unknown = false

local function warn_unknown(name)
    if not warned_unknown then
        warned_unknown = true
        io.stderr:write('tether: unknown provider "' .. tostring(name)
            .. '", falling back to "openai"\n')
    end
end

local function wire_spec(wire)
    if WIRE_MODULES[wire] then return WIRE_MODULES[wire] end
    -- Tier-B adapter: module id doubles as the file/global name.
    return {
        global = "provider_" .. wire:gsub("-", "_"),
        path = "src/tether/providers/" .. wire .. ".lua",
    }
end

local function provider_of(cfg)
    local name = (cfg and cfg.provider) or "openai"
    local entry = catalog and catalog.get(name)
    if not entry then
        warn_unknown(name)
        name = "openai"
        entry = catalog and catalog.get("openai")
    end
    local wire = (entry and entry.wire) or "openai"
    if not catalog then
        -- catalog failed to load: legacy 1:1 behavior (wire id == provider id)
        if not WIRE_MODULES[name] then
            warn_unknown(name)
            name = "openai"
        end
        wire = name
    end
    local mod = load_module(wire_spec(wire))
    assert(mod, "tether: cannot load provider " .. name)
    -- The catalog id is the provider identity (logs, store keys, warnings);
    -- the wire module is shared and MUST NOT be inferred from the module.
    return name, mod
end

-- Test seam: provider name resolution (warns once on unknown, as in prod).
function M._provider_of(cfg)
    local name, _ = provider_of(cfg)
    return name
end

-- Test seam: the wire module an id resolves to (alias proof).
function M._wire_module(cfg)
    local _, mod = provider_of(cfg)
    return mod
end

-- Test seam: catalog entry for an id (nil when unknown).
function M._catalog_entry(id)
    if not catalog then return nil end
    return catalog.get(id)
end

-- Ambient credentials without a key string (Bedrock AWS chain): live
-- listing may proceed with an empty key, the adapter signs the request.
function M._has_ambient(cfg)
    local _, P = provider_of(cfg)
    if P.ambient then
        local ok, res = pcall(P.ambient, cfg)
        if ok and res then return true end
    end
    return false
end

-- Re-exported for unit tests (M7) and session/resume encoding checks.
function M.parse_sse_line(line, on_event)
    local _, P = provider_of(nil)
    return P.parse_sse_line(line, on_event)
end

function M.encode_messages(messages)
    local _, P = provider_of(nil)
    return P.encode_messages(messages)
end

-- add-retry-and-continuation: classification and the schedule live in
-- src/tether/retry.lua (a global in the built binary, a loadfile fallback for
-- development runs and the plain-lua tests). This module only asks it how a
-- failure should be read.
local retry = _G.retry
    or (function()
        local chunk = loadfile("src/tether/retry.lua")
        return chunk and chunk()
    end)()
assert(retry, "api: cannot load retry")

-- Extract a Retry-After / retry_after value from the body, if present.
local function extract_retry_after(body)
    if not body then return nil end
    local v = body:match('"[Rr]etry[_-]?[Aa]fter"[%s]*:[%s]*([%d%.]+)')
    if v then return tonumber(v) end
    return nil
end

-- 0600 expressed as an integer mode for tether.fchmod (Lua has no octal
-- literals, so the digits are parsed as base 8).
local HEADER_FILE_MODE = tonumber("600", 8)

-- Audit #6: provider credentials must not appear in argv (visible in ps).
-- Header-based auth (OpenAI Bearer, Anthropic x-api-key) goes through a
-- private temp file; the header file and request body file are removed
-- right after the request completes.
local function header_file(lines)
    local path = ("/tmp/tether_h_%d_%d"):format(os.time(), math.random(100000, 999999))
    -- 3.5: create the file, lock it down, then write the key — no window in
    -- which the secret is world-readable, and no key is written if the
    -- permission change fails.
    local f = io.open(path, "w")
    if not f then return nil end
    f:close()
    -- 1.7: in-process fchmod via the C host, not `chmod 600` through the shell.
    if not tether.fchmod(path, HEADER_FILE_MODE) then
        os.remove(path)
        return nil
    end
    f = io.open(path, "w")
    if not f then
        os.remove(path)
        return nil
    end
    for _, ln in ipairs(lines) do
        f:write(ln .. "\n")
    end
    f:close()
    return path
end

-- expand-provider-catalog: {VAR} placeholders in catalog url_template
-- entries (Cloudflare account/gateway ids). Resolved from
-- cfg.provider_env (stored-entry merge, see config) then process env.
-- Unresolved placeholders are left intact so preflight can name them.
local function expand_url(url, cfg)
    if type(url) ~= "string" or not url:find("{", 1, true) then return url end
    return (url:gsub("{([A-Za-z_][A-Za-z0-9_]*)}", function(var)
        local v = nil
        if type(cfg) == "table" and type(cfg.provider_env) == "table" then
            v = cfg.provider_env[var]
        end
        if v == nil or v == "" then v = os.getenv(var) end
        if v == nil or v == "" then return "{" .. var .. "}" end
        return v
    end))
end

-- Test seam: parse a models body through the active adapter.
function M._parse_models(cfg, body)
    local _, P = provider_of(cfg)
    if type(body) ~= "string" or body == "" then return nil end
    if body:match("^FETCH_FAILED") then return nil end
    local ok, res = pcall(P.models_parse, body)
    if not ok or type(res) ~= "table" or #res == 0 then return nil end
    return res
end

-- Fire-and-forget live refresh into outpath (background child, picked up
-- by commands.poll_models_refresh). Returns true when a fetch was spawned.
-- Nil without tether.fetch_bg (plain-lua tests/dev) so the caller can fall
-- back to a short sync attempt instead.
function M.refresh_models_bg(cfg, api_key, outpath)
    if not cfg or not api_key or api_key == "" then return nil end
    if type(outpath) ~= "string" or outpath == "" then return nil end
    if not (tether and tether.fetch_bg) then return nil end
    local pname, P = provider_of(cfg)
    local url = expand_url(P.models_url(cfg, api_key), cfg)
    if P.preflight then
        if P.preflight(cfg, api_key, url, pname) then return nil end
    end
    if url:match("{([A-Za-z_][A-Za-z0-9_]*)}") then return nil end
    local hfile = header_file(P.models_headers(api_key,
        { provider = pname, cfg = cfg, auth_style = cfg._auth_style }))
    if not hfile then return nil end
    -- the C layer reads @file headers before fork and unlinks them.
    local ok = tether.fetch_bg(url, { "@" .. hfile }, outpath, 20)
    if not ok then os.remove(hfile) end
    return ok or nil
end

local function http_request(cfg, api_key, messages, on_event)
    local pname, P = provider_of(cfg)
    local model = cfg.model
    local url = expand_url(P.stream_url(cfg, model, api_key), cfg)
    local req = P.build_request(messages, model, nil)

    -- Optional adapter preflight (missing compound credentials, unexpanded
    -- URL placeholders): fails the attempt before any request is issued.
    if P.preflight then
        local perr = P.preflight(cfg, api_key, url, pname)
        if perr then
            return false, retry.failure("permanent", perr)
        end
    end
    -- A {VAR} left in the URL means a required credential piece is missing
    -- (Cloudflare account/gateway id): never issue the request.
    local missing_var = url:match("{([A-Za-z_][A-Za-z0-9_]*)}")
    if missing_var then
        return false, retry.failure("permanent", "missing " .. missing_var)
    end

    -- expand-provider-catalog: request context for header_lines. Wire
    -- modules that predate it keep working (extra arg ignored).
    local hctx = {
        session_id = cfg._session_id,
        provider = pname,
        messages = messages,
        url = url,
        body = req,
        auth_style = cfg._auth_style,
        provider_env = cfg.provider_env,
        cfg = cfg,
    }
    local hfile = header_file(P.header_lines(api_key, hctx))
    if not hfile then
        return false, retry.failure("permanent", "cannot write auth header file")
    end

    -- request body via stdin to avoid quoting issues entirely
    local bfile = hfile .. ".body"
    local bf = io.open(bfile, "w")
    if not bf then
        os.remove(hfile)
        return false, retry.failure("permanent", "cannot write request body file")
    end
    bf:write(req)
    bf:close()

    if P.reset_stream then P.reset_stream() end

    -- 4.1: in-process transport (vendor'd libcurl + mbedTLS). Passing the auth
    -- and body temp files as "@path" entries keeps both out of any argv.
    local ok = true
    local got_data = false
    local parse_failed = false
    local parse_error = nil
    local buf = {}
    local stream_ok, serr = tether.http_stream("POST", url,
        { "@" .. hfile, "Content-Type: application/json" },
        "@" .. bfile,
        function(line)
            if parse_failed then return true end -- drain, stop parsing
            -- SSE framing: an empty line is an EVENT BOUNDARY, not EOF.
            -- Breaking on "" used to drop everything after the first event
            -- separator (multi-event streams lost deltas).
            if line ~= "" then
                buf[#buf + 1] = line
                got_data = true
                local ok2, err = pcall(P.parse_sse_line, line, on_event)
                if not ok2 then
                    parse_failed = true
                    ok = false
                    parse_error = "SSE parse: " .. tostring(err)
                elseif P.stream_failure and P.stream_failure() then
                    -- a provider error inside the stream fails the attempt;
                    -- the rest of the stream is only drained
                    parse_failed = true
                end
            end
            return true
        end,
        { timeout_s = 10, idle_timeout_s = 60 })

    os.remove(hfile)
    os.remove(bfile)

    -- A transfer the user stopped (Ctrl+C during the stream: libcurl reports
    -- an aborted-by-callback error). Distinct from a connection failure so it
    -- can never be retried as one — the turn ends instead.
    if not stream_ok then
        local raw = tostring(serr or "connection error")
        if retry.classify(raw) == "interrupted" then
            return false, retry.failure("interrupted", retry.reason("interrupted"))
        end
        local text = "request failed: " .. raw
        return false, retry.failure(retry.classify(text), text)
    end

    if parse_error then
        return false, retry.failure(retry.classify(parse_error), parse_error)
    end

    -- A provider error recorded while parsing (Anthropic `error`, an
    -- OpenAI/Gemini `{"error":...}` payload) fails the attempt with the
    -- provider's own text instead of being reported as a successful stream.
    local pf = P.stream_failure and P.stream_failure()
    if pf then
        return false, retry.failure(retry.classify(pf.message, pf.status),
            pf.message, pf.status)
    end

    local body = got_data and table.concat(buf, "\n") or ""

    -- Nothing arrived.
    if body == "" then
        return false, retry.failure("empty", "empty response")
    end

    -- A non-SSE body is either the provider's REST fallback (Gemini
    -- generateContent) or an HTTP error JSON.
    if body:sub(1, 5) ~= "data:" then
        if P.handle_non_sse and P.handle_non_sse(body, on_event) then
            local rf = P.stream_failure and P.stream_failure()
            if rf then
                return false, retry.failure(retry.classify(rf.message, rf.status),
                    rf.message, rf.status)
            end
            return true
        end
        -- M7/D5b: surface the HTTP error instead of returning success silently
        -- (parse_sse_line skips a non-SSE body, so 'ok' stays true).
        local status = tonumber(body:match('"status"[%s]*:[%s]*(%d+)'))
            or tonumber(body:match('"code"[%s]*:[%s]*"?([%d]+)"?'))
        local snippet = body:sub(1, 200):gsub("%s+", " ")
        local text = "http " .. tostring(status or "?") .. ": " .. snippet
        return false, retry.failure(retry.classify(text, status), text, status,
            extract_retry_after(body))
    end

    if ok and P.stream_finished then
        pcall(P.stream_finished, on_event)
    end
    return true
end

function M.stream(cfg, api_key, messages, on_event)
    return http_request(cfg, api_key, messages, on_event)
end

-- add-llm-compaction: one-shot summary request. Reuses the provider adapter
-- and transport, accumulates text_delta, and allows at most one automatic
-- retry for a transient (retryable, non-interrupted) failure. Empty output or
-- a permanent failure returns nil so the caller can fall back to truncation.
function M.summarize(cfg, api_key, messages)
    local function attempt()
        local acc = {}
        local ok, failure = M.stream(cfg, api_key, messages, function(ev)
            if ev.type == "text_delta" and type(ev.text) == "string" then
                acc[#acc + 1] = ev.text
            end
        end)
        local text = table.concat(acc):match("^%s*(.-)%s*$") or ""
        return ok, failure, text
    end
    local ok, failure, text = attempt()
    if ok and text ~= "" then return text end
    if not ok and failure and failure.retryable and failure.kind ~= "interrupted" then
        ok, failure, text = attempt()
        if ok and text ~= "" then return text end
    end
    return nil, failure
end

-- 3.5 test seam: expose the private header-file writer so tests can assert
-- the mode is 600 before the key is written.
M._header_file = header_file

local NATIVE_WIRES = { openai = true, anthropic = true, gemini = true }

function M.list_models(cfg)
    local pname, P = provider_of(cfg)
    local entry = M._catalog_entry(pname)
    -- expand-provider-catalog: alias presets resolve live /models only —
    -- the shared wire module's static list belongs to another provider.
    -- Native ids and Tier-B adapters use their own static_models().
    if entry and NATIVE_WIRES[entry.wire] and pname ~= entry.wire then
        return {}
    end
    return P.static_models()
end

function M.list_models_live(cfg, api_key, timeout_s)
    if not cfg then return nil, "no api key" end
    local pname, P = provider_of(cfg)
    if not api_key or api_key == "" then
        -- expand-provider-catalog: ambient credentials (Bedrock AWS chain)
        -- count as a key; the adapter signs without a bearer token.
        if P.ambient and P.ambient(cfg) then
            api_key = ""
        else
            return nil, "no api key"
        end
    end
    local url = expand_url(P.models_url(cfg, api_key), cfg)
    if P.preflight then
        local perr = P.preflight(cfg, api_key, url, pname)
        if perr then return nil, perr end
    end
    local missing_var = url:match("{([A-Za-z_][A-Za-z0-9_]*)}")
    if missing_var then return nil, "missing " .. missing_var end
    -- ctx carries cfg for adapters that sign the models call (bedrock).
    local hfile = header_file(P.models_headers(api_key,
        { provider = pname, cfg = cfg, auth_style = cfg._auth_style }))
    if not hfile then return nil, "cannot write header file" end
    -- 4.2: in-process GET; the return format (list | nil, reason) is unchanged.
    -- timeout_s caps interactive freeze (pi uses 4s for catalog refresh).
    local body, err = tether.http_get(url, { "@" .. hfile }, timeout_s or 30)
    os.remove(hfile)
    if not body then return nil, err end
    -- minimal JSON: extract model ids via the provider's own parser
    local result = P.models_parse(body)
    return #result > 0 and result or nil, #result > 0 and nil or "empty model list"
end

return M
