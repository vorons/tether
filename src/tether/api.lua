-- tether M3: api — OpenAI-compatible SSE streaming via curl pipe
local M = {}

local function jesc(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return s
end

local function encode_messages(messages)
    local items = {}
    for _, m in ipairs(messages) do
        items[#items+1] = string.format('{"role":"%s","content":"%s"}',
            jesc(m.role or ""), jesc(m.content or ""))
    end
    return "[" .. table.concat(items, ",") .. "]"
end

local function json_value(s, key)
    local pos = s:find(string.format('"%s"', key), 1, true)
    if not pos then return nil end
    local rest = s:sub(pos + #key + 2)
    local qstart = rest:find('"', 1, true)
    if not qstart then return nil end
    local i = qstart + 1
    while i <= #rest do
        local ch = rest:sub(i, i)
        if ch == '"' then
            local j = i - 1
            local bs = 0
            while j >= 1 and rest:sub(j, j) == '\\' do
                bs = bs + 1
                j = j - 1
            end
            if bs % 2 == 0 then
                local val = rest:sub(qstart + 1, i - 1)
                val = val:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\\\', '\\')
                return val
            end
        end
        i = i + 1
    end
    return nil
end

local function json_decode(s)
    local ok, result = pcall(function()
        return load("return " .. s)()
    end)
    if ok and result then
        return result
    end
    return nil
end

local function parse_json_str(s)
    local obj = {}
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*"([^"]*)"') do
        obj[key] = val
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%d+%.?%d*)') do
        obj[key] = tonumber(val)
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%S+)') do
        val = val:gsub("[,%}]]$", "")
        if val == "true" then obj[key] = true elseif val == "false" then obj[key] = false end
    end
    return next(obj) and obj or nil
end

local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done" })
        return
    end
    local obj = parse_json_str(payload)
    if not obj then return end

    local choice = obj.choices and obj.choices[1]
    if not choice then return end

    local delta = choice.delta
    if not delta then return end

    if delta.content and delta.content ~= "" then
        on_event({ type = "text_delta", text = delta.content })
    end

    if delta.tool_calls then
        for _, tc in ipairs(delta.tool_calls) do
            if tc.id then
                on_event({ type = "tool_call_start", name = tc['function'].name, id = tc.id })
            end
            if tc['function'] and tc['function'].arguments then
                on_event({ type = "tool_call_delta", id = tc.id, arguments = tc['function'].arguments })
            end
            if tc.id and choice.finish_reason == "tool_calls" then
                on_event({ type = "tool_call_end", id = tc.id })
            end
        end
    end

    if choice.finish_reason and choice.finish_reason ~= "null" then
        if choice.finish_reason == "stop" then
            on_event({ type = "done" })
        end
    end

    if obj.usage then
        on_event({ type = "usage", usage = obj.usage })
    end
end

-- T15: detect whether an HTTP response body is a retryable error (429 / 5xx).
-- curl-piped streams can't report the status code directly, so we infer it
-- from the body: OpenAI-compatible APIs return a plain JSON error body on
-- 4xx/5xx (not an SSE stream). Rate-limit responses include "rate_limit" or
-- a 429 status. Retry on empty bodies and retryable error JSON.
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
    local lowered = body:lower()
    if lowered:find("rate.?limit") or lowered:find("rate_limit")
        or lowered:find("too many requests") or lowered:find("overloaded")
        or lowered:find("internal server error") or lowered:find("bad gateway")
        or lowered:find("service unavailable") then
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

local function http_request(cfg, api_key, messages, on_event, attempt)
    attempt = attempt or 1
    local max_retries = (cfg.retries and tonumber(cfg.retries)) or 3
    local backoffs = { 0.5, 1.0, 2.0 }
    local url = cfg.base_url .. "/chat/completions"
    local req = string.format(
        '{"model":"%s","messages":%s,"stream":true}',
        jesc(cfg.model), encode_messages(messages))

    local body_esc = req:gsub("'", "'\\''")
    local cmd = string.format(
        "curl -s -N -X POST '%s' -H 'Authorization: Bearer %s' -H 'Content-Type: application/json' -d '%s' 2>/dev/null",
        url, api_key, body_esc)

    local handle = tether.open_pipe(cmd)
    if not handle or handle == 0 then
        if attempt < max_retries then
            pcall(tether.sleep, backoffs[attempt])
            return http_request(cfg, api_key, messages, on_event, attempt + 1)
        end
        on_event({ type = "error", message = "curl failed to start" })
        return false
    end

    local ok = true
    local got_data = false
    local buf = {}
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
        if tether.pipe_eof() == 1 then break end
    end

    tether.close_pipe(handle)

    -- Decide whether to retry based on the body content.
    local body = table.concat(buf, "\n")
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

    return ok
end

function M.stream(cfg, api_key, messages, on_event)
    return http_request(cfg, api_key, messages, on_event)
end

function M.chat(cfg, api_key, messages, on_event)
    return http_request(cfg, api_key, messages, on_event)
end

function M.list_models()
    return {"gpt-4o-mini", "gpt-4o", "gpt-4-turbo"}
end

function M.list_models_live(cfg, api_key)
    if not cfg or not api_key or api_key == "" then
        return nil, "no api key"
    end
    local url = cfg.base_url .. "/models"
    local cmd = string.format(
        "curl -s -X GET '%s' -H 'Authorization: Bearer %s'",
        url, api_key)
    local handle = tether.open_pipe(cmd)
    if not handle or handle == 0 then return nil, "curl failed" end
    local buf = {}
    while true do
        local line = tether.read_line(handle)
        if not line or line == "" then break end
        buf[#buf + 1] = line
    end
    tether.close_pipe(handle)
    local body = table.concat(buf)
    -- minimal JSON: extract "id" values
    local result = {}
    for id in body:gmatch('"id"[%s]*:[%s]*"([^"]+)"') do
        result[#result + 1] = { id = id, name = id }
    end
    return #result > 0 and result or nil, #result > 0 and nil or "empty model list"
end

return M
