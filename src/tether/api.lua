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

local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done" })
        return
    end
    local obj = json_decode(payload)
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

local function http_request(cfg, api_key, messages, on_event)
    local url = cfg.base_url .. "/chat/completions"
    local req = string.format(
        '{"model":"%s","messages":%s,"stream":true}',
        jesc(cfg.model), encode_messages(messages))

    local body_esc = req:gsub("'", "'\\''")
    local cmd = string.format(
        "curl -s -N -X POST '%s' -H 'Authorization: Bearer %s' -H 'Content-Type: application/json' -d '%s'",
        url, api_key, body_esc)

    local handle = tether.open_pipe(cmd)
    if not handle or handle == 0 then
        on_event({ type = "error", message = "curl failed to start" })
        return false
    end

    local ok = true
    while true do
        local line = tether.read_line(handle)
        if not line or line == "" then break end
        local ok2, err = pcall(parse_sse_line, line, on_event)
        if not ok2 then
            on_event({ type = "error", message = "SSE parse: " .. tostring(err) })
            ok = false
            break
        end
        if tether.pipe_eof() == 1 then break end
    end

    tether.close_pipe(handle)
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

return M
