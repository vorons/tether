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

local PROVIDERS = {
    openai    = { global = "provider_openai",    path = "src/tether/providers/openai.lua" },
    anthropic = { global = "provider_anthropic", path = "src/tether/providers/anthropic.lua" },
    gemini    = { global = "provider_gemini",    path = "src/tether/providers/gemini.lua" },
}

local function load_provider(spec)
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

local function provider_of(cfg)
    local name = (cfg and cfg.provider) or "openai"
    if not PROVIDERS[name] then
        if not warned_unknown then
            warned_unknown = true
            io.stderr:write('tether: unknown provider "' .. tostring(name)
                .. '", falling back to "openai"\n')
        end
        name = "openai"
    end
    local mod = load_provider(PROVIDERS[name])
    assert(mod, "tether: cannot load provider " .. name)
    return name, mod
end

-- Test seam: provider name resolution (warns once on unknown, as in prod).
function M._provider_of(cfg)
    local name, _ = provider_of(cfg)
    return name
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

local function http_request(cfg, api_key, messages, on_event)
    local _, P = provider_of(cfg)
    local model = cfg.model
    local url = P.stream_url(cfg, model, api_key)
    local req = P.build_request(messages, model, nil)

    local hfile = header_file(P.header_lines(api_key))
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

function M.list_models(cfg)
    local _, P = provider_of(cfg)
    return P.static_models()
end

function M.list_models_live(cfg, api_key)
    if not cfg or not api_key or api_key == "" then
        return nil, "no api key"
    end
    local _, P = provider_of(cfg)
    local url = P.models_url(cfg, api_key)
    local hfile = header_file(P.models_headers(api_key))
    if not hfile then return nil, "cannot write header file" end
    -- 4.2: in-process GET; the return format (list | nil, reason) is unchanged.
    local body, err = tether.http_get(url, { "@" .. hfile }, 30)
    os.remove(hfile)
    if not body then return nil, err end
    -- minimal JSON: extract model ids via the provider's own parser
    local result = P.models_parse(body)
    return #result > 0 and result or nil, #result > 0 and nil or "empty model list"
end

return M
