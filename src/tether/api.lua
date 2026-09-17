-- tether M3: api — OpenAI-compatible SSE streaming via curl pipe
local M = {}

local function jesc(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

-- Single-pass JSON string unescape (M7/D2b). Sequential gsub chains corrupt
-- input like `\\n` (escaped backslash + n): the first pass turns it into `\n`,
-- the next pass turns THAT into a newline. A single left-to-right scan with a
-- replacement function never re-processes its own output.
local function json_unescape(s)
    local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                  ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and i < #s then
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code then
                    out[#out + 1] = utf8 and utf8.char and utf8.char(code) or ""
                    i = i + 6
                else
                    out[#out + 1] = n
                    i = i + 2
                end
            else
                out[#out + 1] = map[n] or n
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function encode_messages(messages)
    local items = {}
    for _, m in ipairs(messages) do
        local content = m.content
        if type(content) == "table" and content.tool_calls then
            -- assistant message with tool calls (OpenAI contract)
            local tcs = {}
            for _, tc in ipairs(content.tool_calls) do
                tcs[#tcs + 1] = string.format(
                    '{"id":"%s","type":"function","function":{"name":"%s","arguments":"%s"}}',
                    jesc(tc.id or ""), jesc(tc["function"].name), jesc(tc["function"].arguments or ""))
            end
            items[#items + 1] = string.format(
                '{"role":"assistant","content":null,"tool_calls":[%s]}', table.concat(tcs, ","))
        elseif m.role == "tool" then
            items[#items + 1] = string.format(
                '{"role":"tool","tool_call_id":"%s","content":"%s"}',
                jesc(m.tool_call_id or ""), jesc(tostring(content or "")))
        else
            items[#items + 1] = string.format(
                '{"role":"%s","content":"%s"}',
                jesc(m.role or ""), jesc(tostring(content or "")))
        end
    end
    return "[" .. table.concat(items, ",") .. "]"
end

-- Shallow gmatch-based parser for SSE payloads (per ADR: no load()).
local function parse_json_str(s)
    local obj = {}
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*"([^"]*)"') do
        obj[key] = obj[key] or val
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%d+%.?%d*)') do
        obj[key] = obj[key] or tonumber(val)
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%S+)') do
        val = val:gsub("[,%}%]]$", "")
        if val == "true" then obj[key] = obj[key] or true
        elseif val == "false" then obj[key] = obj[key] or false end
    end
    return next(obj) and obj or nil
end

-- Extract the choices[0].delta / finish_reason from an SSE chunk without a full
-- JSON parser: locate "choices" and scan the first array element heuristically.
-- (Exported as M.parse_sse_line at the bottom of the file for unit tests, M7/T1.)
local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done" })
        return
    end

    local obj = parse_json_str(payload)
    if not obj then return end

    -- content delta: "content":"..." — unescaped once, here (SSE string layer)
    local content = payload:match('"content"[%s]*:[%s]*"(.-[^\\])"')
        or payload:match('"content"[%s]*:[%s]*""')
    if content and content ~= "" then
        content = json_unescape(content)
        if content ~= "" then
            on_event({ type = "text_delta", text = content })
        end
    end

    -- tool calls: "tool_calls":[{"index":0,"id":"...","function":{"name":"...","arguments":"..."}}]
    -- M7/D2a: continuation chunks carry only {"index":N,"function":{"arguments":"..."}}
    -- (no "id"). Match name via a bounded class (OpenAI names are [A-Za-z0-9_-]) so
    -- "arguments" strings never match as a name, and emit raw (still-escaped)
    -- argument fragments — unescaping happens exactly once, in agent.parse_args (D2b).
    -- Note: Lua %w does NOT include "_" — use [%w_] (ids look like "call_1").
    -- Note: value pattern is '(.-[^\\])"' (lazy run ending in a non-backslash char
    -- before the closing quote). The classic '(\\.|[^"\\])*' does NOT work in Lua:
    -- patterns don't backtrack into alternation+star, so escaped quotes fail.
    if payload:find('"tool_calls"', 1, true) then
        for id, name in payload:gmatch('"id"[%s]*:[%s]*"([%w_%-]+)"[^%]]-"function"[%s]*:[%s]*%{[^}]-"name"[%s]*:[%s]*"([%w_.%-]+)"') do
            on_event({ type = "tool_call_start", name = name, id = id })
        end
        -- Arguments are emitted RAW (still JSON-escaped): a chunk boundary can
        -- split an escape sequence (\ at the end of one chunk, " at the start
        -- of the next), so unescaping happens exactly once in agent.parse_args
        -- over the full assembled string.
        for id, args in payload:gmatch('"id"[%s]*:[%s]*"([%w_%-]+)"[^%]]-"function"[%s]*:[%s]*%{.-"arguments"[%s]*:[%s]*"(.-[^\\])"') do
            on_event({ type = "tool_call_delta", id = id, arguments = args })
        end
        for idx, args in payload:gmatch('"index"[%s]*:[%s]*(%d+)[%s]*,[%s]*"function"[%s]*:[%s]*%{[^}]-"arguments"[%s]*:[%s]*"(.-[^\\])"') do
            on_event({ type = "tool_call_delta", index = tonumber(idx), arguments = args })
        end
    end

    -- finish reason
    local finish = payload:match('"finish_reason"[%s]*:[%s]*"([^"]+)"')
    if finish == "stop" then
        on_event({ type = "done" })
    end

    -- usage
    local pt = tonumber(payload:match('"prompt_tokens"[%s]*:[%s]*(%d+)'))
    local ct = tonumber(payload:match('"completion_tokens"[%s]*:[%s]*(%d+)'))
    if pt or ct then
        on_event({ type = "usage", usage = { used = (pt or 0) + (ct or 0), prompt_tokens = pt, completion_tokens = ct } })
    end

    -- error payloads: {"error":{"message":"...","status":429}}
    if obj.error and not content then
        on_event({ type = "error", message = obj.error_message or obj.error or "api error" })
    end
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

-- Audit #6: the API key must not appear in argv (visible in ps). We pass it
-- through a header written to a private temp file, removed right after curl exits.
local function auth_header_file(api_key)
    local path = ("/tmp/tether_h_%d_%d"):format(os.time(), math.random(100000, 999999))
    local f = io.open(path, "w")
    if not f then return nil end
    f:write("Authorization: Bearer " .. (api_key or "") .. "\n")
    f:close()
    os.execute("chmod 600 " .. path)
    return path
end

local function http_request(cfg, api_key, messages, on_event, attempt)
    attempt = attempt or 1
    local max_retries = (cfg.retries and tonumber(cfg.retries)) or 3
    local backoffs = { 0.5, 1.0, 2.0 }
    local url = cfg.base_url .. "/chat/completions"
    local req = string.format(
        '{"model":"%s","messages":%s,"stream":true}',
        jesc(cfg.model), encode_messages(messages))

    local hfile = auth_header_file(api_key)
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
        "curl -s -N -X POST %s -H @%s -H 'Content-Type: application/json' --data-binary @%s 2>/dev/null",
        url, hfile, bfile)

    local handle = tether.open_pipe(cmd)
    local ok = true
    local got_data = false
    local buf = {}
    if handle and handle ~= 0 then
        while true do
            local line = tether.read_line(handle)
            if not line or line == "" then break end
            buf[#buf + 1] = line
            got_data = true
            local ok2, err = pcall(parse_sse_line, line, on_event)
            if not ok2 then
                on_event({ type = "error", message = "SSE parse: " .. tostring(err) })
                ok = false
                break
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
    -- silence. Surface the body (truncated) as an error event.
    if body ~= "" and body:sub(1, 5) ~= "data:" then
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

-- Exports for unit tests (M7)
M.parse_sse_line = parse_sse_line
M.encode_messages = encode_messages

function M.list_models()
    -- M7/N3: static fallback when /models is unavailable. Your provider's
    -- real list may differ — set cfg.model directly (see README).
    return {
        "gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1",
        "gpt-5", "gpt-5-mini", "o3", "o4-mini",
        "deepseek-chat", "deepseek-reasoner", "qwen-max", "qwen-plus",
    }
end

function M.list_models_live(cfg, api_key)
    if not cfg or not api_key or api_key == "" then
        return nil, "no api key"
    end
    local url = cfg.base_url .. "/models"
    local hfile = auth_header_file(api_key)
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
    -- minimal JSON: extract "id" values
    local result = {}
    for id in body:gmatch('"id"[%s]*:[%s]*"([^"]+)"') do
        result[#result + 1] = { id = id, name = id }
    end
    return #result > 0 and result or nil, #result > 0 and nil or "empty model list"
end

return M
