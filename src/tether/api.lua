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

-- Unknown provider ids fall back to "openai" silently: library code must
-- never write to the terminal mid-TUI (one stray line over the alt-screen
-- persists past diff repaints), and the configured id stays visible in the
-- footer's provider cell for diagnosis.
local function warn_unknown() end

local function wire_spec(wire)
    if WIRE_MODULES[wire] then return WIRE_MODULES[wire] end
    -- Tier-B adapter: module id doubles as the file/global name.
    return {
        global = "provider_" .. wire:gsub("-", "_"),
        path = "src/tether/providers/" .. wire .. ".lua",
    }
end

local function provider_of(cfg)
    -- dynamic-provider-catalog: the default is the local-first bootstrap id;
    -- unknown ids warn and behave as the default (spec: Provider selection).
    local default_id = (catalog and catalog.DEFAULT_ID) or "openai"
    local name = (cfg and cfg.provider) or default_id
    local entry = catalog and catalog.get(name)
    if not entry then
        warn_unknown(name)
        name = default_id
        entry = catalog and catalog.get(default_id)
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

-- provider-catalog spec: static `extra_headers` (catalog + user override at
-- providers.<id>.extra_headers) ride on every request of a preset. A user
-- value replaces the same-named catalog value (that is what override means);
-- emission is name-sorted so duplicate-name ordering is deterministic.
-- Header values are validated: CR/LF in a value would smuggle extra header
-- lines (CRLF injection through the header temp file).
local function extra_header_lines(cfg)
    if type(cfg) ~= "table" then return {} end
    local sources = {}
    local preset = cfg.provider
    if type(cfg.providers) == "table" and type(cfg.providers[preset]) == "table"
        and type(cfg.providers[preset].extra_headers) == "table" then
        sources[#sources + 1] = cfg.providers[preset].extra_headers
    end
    if type(cfg.extra_headers) == "table" then
        sources[#sources + 1] = cfg.extra_headers
    end
    local merged, names = {}, {}
    for _, src in ipairs(sources) do
        for name, value in pairs(src) do
            if type(name) == "string" and type(value) == "string"
                and name ~= "" and not name:find("[\r\n:]")
                and not value:find("[\r\n]") then
                if not merged[name] then names[#names + 1] = name end
                merged[name] = value
            end
        end
    end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = name .. ": " .. merged[name]
    end
    return out
end
M._extra_header_lines = extra_header_lines -- test seam

-- Audit #6: provider credentials must not appear in argv (visible in ps).
-- Header-based auth (OpenAI Bearer, Anthropic x-api-key) goes through a
-- private temp file; the header file and request body file are removed
-- right after the request completes. The body file is written 0600 too.
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

-- dynamic-provider-catalog: loopback test for keyless local listing.
-- Only localhost / 127.0.0.0/8 / ::1 ever qualify; LAN and public hosts
-- always need a key (a dummy value works — runtimes ignore Bearer).
local function is_loopback(url)
    if type(url) ~= "string" then return false end
    local host = url:match("^https?://%[([^%]]+)%]") -- [::1]:port
        or url:match("^https?://([^/:]+)")
    if not host then return false end
    host = host:lower()
    if host == "localhost" then return true end
    if host == "::1" or host == "[::1]" then return true end
    if host:match("^127%.%d+%.%d+%.%d+$") then return true end
    return false
end

M._is_loopback = is_loopback -- test seam (also used by commands)

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
    local hlines = P.models_headers(api_key,
        { provider = pname, cfg = cfg, auth_style = cfg._auth_style,
          session_id = cfg._session_id, messages = nil })
    for _, ln in ipairs(extra_header_lines(cfg)) do hlines[#hlines + 1] = ln end
    local hfile = header_file(hlines)
    if not hfile then return nil end
    -- the C layer reads @file headers before fork and unlinks them.
    local ok = tether.fetch_bg(url, { "@" .. hfile }, outpath, 20)
    if not ok then os.remove(hfile) end
    return ok or nil
end

-- The reactor loop that owns waiting right now (ui.run binds it around its
-- run()); nil in print mode, one-shot callers and tests without a loop.
local function active_loop()
    local r = _G.reactor
    if type(r) == "table" and type(r.active) == "function" then
        return r.active()
    end
    return nil
end

-- The abort seam the agent reads: the UI flag (Ctrl+C while busy) or the
-- host flag (blocking paths). Checked between reactor ticks so an abort ends
-- the transfer instead of streaming on to completion.
local function abort_pending()
    local turn = _G.turn
    if type(turn) == "table" and type(turn.take_abort) == "function" then
        return turn.take_abort()
    end
    local agent = _G.agent
    if agent and agent.abort_requested then return true end
    if type(tether.abort_requested) == "function" and tether.abort_requested() then
        return true
    end
    return false
end

-- One attempt over the step API: the reactor owns the wait (its tick polls
-- stdin, these sockets and the timers together), this loop only advances the
-- transfer between ticks. Complete lines are fed in arrival order, so the
-- event sequence is identical to the blocking http_stream over the same
-- body. An abort (or a stopped loop) ends the transfer as `aborted`, which
-- http_request classifies as interrupted — never as a retryable failure.
local function stepped_stream(loop, url, hfile, bfile, feed)
    local h, herr = tether.http_start("POST", url,
        { "@" .. hfile, "Content-Type: application/json" },
        "@" .. bfile, { timeout_s = 10, idle_timeout_s = 60 })
    if not h then return nil, herr or "cannot start transfer" end
    local finished, step_ok, step_err = false, nil, nil
    local function step()
        if finished then return end
        local st, err = tether.http_step(h, 0)
        local lines = tether.http_lines(h)
        for i = 1, #lines do
            -- http_stream delivers a line error as a failed call too: stop
            -- feeding, keep the message, never retry the parse as transport
            local fed, ferr = pcall(feed, lines[i])
            if not fed then
                finished, step_ok, step_err = true, nil, ferr
                return
            end
        end
        if st ~= "running" then
            finished = true
            if st == "done" then step_ok = true else step_err = err end
        end
    end
    local src = loop:add_source{
        fds = function() return tether.http_fds(h) end,
        ready = function() step() end,
    }
    local ok, terr = pcall(function()
        while not finished do
            if abort_pending() or not loop:tick() then
                tether.http_abort(h)
                step()
                break
            end
        end
    end)
    loop:remove_source(src)
    tether.http_free(h)
    if not ok then error(terr, 0) end
    return step_ok, step_err
end

local function http_request(cfg, api_key, messages, on_event)
    local pname, P = provider_of(cfg)
    local model = cfg.model
    local url = expand_url(P.stream_url(cfg, model, api_key), cfg)
    -- add-reasoning-level: the normalized level rides as the 4th argument;
    -- adapters that predate it ignore the extra arg.
    local req = P.build_request(messages, model, nil, cfg.reasoning)

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
    local hlines = P.header_lines(api_key, hctx)
    for _, ln in ipairs(extra_header_lines(cfg)) do hlines[#hlines + 1] = ln end
    local hfile = header_file(hlines)
    if not hfile then
        return false, retry.failure("permanent", "cannot write auth header file")
    end

    -- request body via stdin to avoid quoting issues entirely; written 0600
    -- (audit: a 0644 draft body is world-readable in /tmp for its lifetime)
    local bfile = hfile .. ".body"
    local bf = io.open(bfile, "w")
    if not bf then
        os.remove(hfile)
        return false, retry.failure("permanent", "cannot write request body file")
    end
    bf:write(req)
    bf:close()
    -- Debug: TETHER_DUMP_BODY=/path keeps a copy of the exact outgoing body
    -- (opt-in only; bodies may carry workspace content).
    pcall(function()
        local dump = os.getenv("TETHER_DUMP_BODY")
        if type(dump) == "string" and dump ~= "" then
            local df = io.open(dump, "w")
            if df then df:write(req); df:close() end
        end
    end)
    if not tether.fchmod or not tether.fchmod(bfile, HEADER_FILE_MODE) then
        os.remove(hfile)
        os.remove(bfile)
        return false, retry.failure("permanent", "cannot lock down request body file")
    end

    if P.reset_stream then P.reset_stream() end

    -- 4.1: in-process transport (vendor'd libcurl + mbedTLS). Passing the auth
    -- and body temp files as "@path" entries keeps both out of any argv.
    local ok = true
    local got_data = false
    local parse_failed = false
    local parse_error = nil
    local buf = {}
    -- Debug: TETHER_DUMP_SSE=/path appends every raw SSE line (opt-in only).
    local sse_dump = os.getenv("TETHER_DUMP_SSE")
    if type(sse_dump) ~= "string" or sse_dump == "" then sse_dump = nil end
    local function feed(line)
        if sse_dump then
            pcall(function()
                local df = io.open(sse_dump, "a")
                if df then df:write(line, "\n"); df:close() end
            end)
        end
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
    end

    -- Transport selection: while a reactor loop owns waiting (ui.run parked
    -- inside its dispatch), stream over the step API so keys, spinner and
    -- timers keep ticking for the whole turn. Everything else — print mode,
    -- one-shot callers, tests without a loop — keeps the blocking contract.
    local stream_ok, serr
    local loop = active_loop()
    if loop then
        stream_ok, serr = stepped_stream(loop, url, hfile, bfile, feed)
    else
        stream_ok, serr = tether.http_stream("POST", url,
            { "@" .. hfile, "Content-Type: application/json" },
            "@" .. bfile, feed, { timeout_s = 10, idle_timeout_s = 60 })
    end

    os.remove(hfile)
    os.remove(bfile)

    -- A transfer the user stopped (Ctrl+C during the stream: the blocking
    -- path reports libcurl's aborted-by-callback text, the stepped path the
    -- `aborted` from http_abort). Distinct from a connection failure so it
    -- can never be retried as one — the turn ends instead.
    if not stream_ok then
        local raw = tostring(serr or "connection error")
        if raw == "aborted" or retry.classify(raw) == "interrupted" then
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
    -- dynamic-provider-catalog: native ids and Tier-B adapters keep their
    -- curated static_models(); every other id falls back to its
    -- pipeline/bundled models[] (ids only), else empty. Live listing stays
    -- authoritative one layer up (commands.list_models tries live first).
    if entry and NATIVE_WIRES[entry.wire] and pname ~= entry.wire then
        local ids = {}
        if type(entry.models) == "table" then
            for _, m in ipairs(entry.models) do
                local id = (type(m) == "table" and m.id) or m
                if type(id) == "string" and id ~= "" then
                    ids[#ids + 1] = id
                end
            end
        end
        return ids
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
        -- dynamic-provider-catalog: local runtimes take no key. Loopback
        -- only — a keyless request to a non-loopback host never happens.
        elseif M._is_loopback(expand_url(cfg.base_url or "", cfg)) then
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
    -- Audit: models requests are "every request of a preset" too — session
    -- id and provider must reach header_lines (x-opencode-session etc.).
    local hlines = P.models_headers(api_key,
        { provider = pname, cfg = cfg, auth_style = cfg._auth_style,
          session_id = cfg._session_id, provider_env = cfg.provider_env })
    for _, ln in ipairs(extra_header_lines(cfg)) do hlines[#hlines + 1] = ln end
    local hfile = header_file(hlines)
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
