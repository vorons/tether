-- tether api — provider dispatcher + shared transport.
-- Per-provider request/SSE logic lives in src/tether/providers/*; this
-- module owns what is identical for all providers: the curl pipe loop,
-- auth/body temp files, retry/backoff policy, and error surfacing.
-- agent.lua sees only canonical events and never branches on provider.
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

-- T15: detect whether an HTTP response body is a retryable error (429 / 5xx).
-- curl-piped streams can't report the status code directly, so we infer it
-- from the body: OpenAI-compatible APIs return a plain JSON error body on
-- 4xx/5xx (not an SSE stream). Retry on empty bodies and retryable error JSON.
local function is_retryable_body(body)
    if body == nil or body == "" then return true, "empty response" end
    local first = body:match("^[%s]*(%S)")
    -- SSE streams start with "data:" — a non-SSE body on a streaming request
    -- is an HTTP error JSON.
    if first == "d" then return false, nil end
    local status = tonumber(body:match('"status"[%s]*:[%s]*(%d+)'))
        or tonumber(body:match('"code"[%s]*:[%s]*"?([%d]+)"?'))
    if status and (status == 429 or status >= 500) then
        return true, tostring(status)
    end
    if status and status >= 400 then
        return false, "http " .. status
    end
    local lowered = body:lower()
    if lowered:find("rate.?limit") or lowered:find("too many requests")
        or lowered:find("overloaded") or lowered:find("internal server error")
        or lowered:find("bad gateway") or lowered:find("service unavailable") then
        return true, "rate limit / server error body"
    end
    return false, nil
end

-- Extract a Retry-After / retry_after value from the body, if present.
local function extract_retry_after(body)
    if not body then return nil end
    local v = body:match('"[Rr]etry[_-]?[Aa]fter"[%s]*:[%s]*([%d%.]+)')
    if v then return tonumber(v) end
    return nil
end

-- Audit #6: provider credentials must not appear in argv (visible in ps).
-- Header-based auth (OpenAI Bearer, Anthropic x-api-key) goes through a
-- private temp file; the header file and request body file are removed
-- right after curl exits.
local function header_file(lines)
    local path = ("/tmp/tether_h_%d_%d"):format(os.time(), math.random(100000, 999999))
    -- 3.5: create the file, lock it down, then write the key — no window in
    -- which the secret is world-readable, and no key is written if chmod fails.
    local f = io.open(path, "w")
    if not f then return nil end
    f:close()
    local ok = os.execute("chmod 600 " .. path)
    if ok ~= true and ok ~= 0 then
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

local function http_request(cfg, api_key, messages, on_event, attempt)
    attempt = attempt or 1
    local _, P = provider_of(cfg)
    local max_retries = (cfg.retries and tonumber(cfg.retries)) or 3
    local backoffs = { 0.5, 1.0, 2.0 }
    local model = cfg.model
    local url = P.stream_url(cfg, model, api_key)
    local req = P.build_request(messages, model, nil)

    local hfile = header_file(P.header_lines(api_key))
    if not hfile then
        on_event({ type = "error", message = "cannot write auth header file" })
        return false
    end

    -- request body via stdin to avoid quoting issues entirely
    local bfile = hfile .. ".body"
    local bf = io.open(bfile, "w")
    if not bf then
        os.remove(hfile)
        on_event({ type = "error", message = "cannot write request body file" })
        return false
    end
    bf:write(req)
    bf:close()

    local cmd = string.format(
        "curl -s -N -X POST '%s' -H @%s -H 'Content-Type: application/json' --data-binary @%s 2>/dev/null",
        url, hfile, bfile)

    if P.reset_stream then P.reset_stream() end
    local handle = tether.open_pipe(cmd)
    local ok = true
    local got_data = false
    local buf = {}
    if handle and handle ~= 0 then
        while true do
            local line = tether.read_line(handle)
            if not line then break end
            -- SSE framing: an empty line is an EVENT BOUNDARY, not EOF.
            -- Breaking on "" used to drop everything after the first event
            -- separator (multi-event streams lost deltas).
            if line ~= "" then
                buf[#buf + 1] = line
                got_data = true
                local ok2, err = pcall(P.parse_sse_line, line, on_event)
                if not ok2 then
                    on_event({ type = "error", message = "SSE parse: " .. tostring(err) })
                    ok = false
                    break
                end
            end
            if tether.pipe_eof(handle) == 1 or tether.pipe_eof() == 1 then break end
        end
        tether.close_pipe(handle)
    else
        ok = false
    end

    os.remove(hfile)
    os.remove(bfile)

    if not handle or handle == 0 then
        if attempt < max_retries then
            pcall(tether.sleep, backoffs[attempt])
            return http_request(cfg, api_key, messages, on_event, attempt + 1)
        end
        on_event({ type = "error", message = "curl failed to start" })
        return false
    end

    if ok and P.stream_finished then
        pcall(P.stream_finished, on_event)
    end

    -- Decide whether to retry based on the body content.
    local body = table.concat(buf, "\n")
    if not got_data then body = "" end
    local retryable, reason = is_retryable_body(body)
    if retryable and attempt < max_retries then
        local delay = backoffs[math.min(attempt, #backoffs)]
        local retry_after = extract_retry_after(body)
        if retry_after then delay = retry_after end
        pcall(tether.sleep, delay)
        on_event({ type = "retry", attempt = attempt, delay = delay, reason = reason })
        return http_request(cfg, api_key, messages, on_event, attempt + 1)
    end

    if retryable and attempt >= max_retries then
        on_event({ type = "error", message = "API failed after " .. max_retries
            .. " attempts: " .. tostring(reason or "empty response") })
        return false
    end

    -- M7/D5b: a non-SSE, non-retryable body is an HTTP error (e.g. 401 JSON).
    -- parse_sse_line silently skips it and 'ok' stays true -> the user sees
    -- silence. Providers with a REST fallback (Gemini generateContent) may
    -- consume the body into events first; otherwise surface it truncated.
    if body ~= "" and body:sub(1, 5) ~= "data:" then
        if P.handle_non_sse and P.handle_non_sse(body, on_event) then
            return ok
        end
        local status = tonumber(body:match('"status"[%s]*:[%s]*(%d+)'))
            or tonumber(body:match('"code"[%s]*:[%s]*"?([%d]+)"?'))
        local snippet = body:sub(1, 200):gsub("%s+", " ")
        on_event({ type = "error",
                   message = "http " .. tostring(status or "?") .. ": " .. snippet })
        return false
    end

    return ok
end

function M.stream(cfg, api_key, messages, on_event)
    return http_request(cfg, api_key, messages, on_event)
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
    local cmd = string.format("curl -s -X GET '%s' -H @%s", url, hfile)
    local handle = tether.open_pipe(cmd)
    if not handle or handle == 0 then
        os.remove(hfile)
        return nil, "curl failed"
    end
    local buf = {}
    while true do
        local line = tether.read_line(handle)
        if not line or line == "" then break end
        buf[#buf + 1] = line
        if tether.pipe_eof() == 1 then break end
    end
    tether.close_pipe(handle)
    os.remove(hfile)
    local body = table.concat(buf)
    -- minimal JSON: extract model ids via the provider's own parser
    local result = P.models_parse(body)
    return #result > 0 and result or nil, #result > 0 and nil or "empty model list"
end

return M
