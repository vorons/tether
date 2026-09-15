-- tether M3: api — OpenAI-compatible chat via curl subprocess
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

-- Extract a JSON string value for a given key from possibly-pretty-printed JSON
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
            -- Count preceding backslashes to check if this quote is escaped
            local j = i - 1
            local bs = 0
            while j >= 1 and rest:sub(j, j) == '\\' do
                bs = bs + 1
                j = j - 1
            end
            if bs % 2 == 0 then
                -- Unescaped quote — closing quote
                local val = rest:sub(qstart + 1, i - 1)
                val = val:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t'):gsub('\\\\', '\\')
                return val
            end
        end
        i = i + 1
    end
    return nil
end

local function decode_content(s)
    local has_error = s:find('"error"', 1, true)
    if has_error then
        local msg = json_value(s, "message")
        if msg then
            return nil, "API error: " .. msg
        end
        return nil, "API error (unparsed): " .. s:sub(1, 200)
    end
    local content = json_value(s, "content")
    if content then
        return content
    end
    return nil, "could not parse response: " .. s:sub(1, 200)
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function http_request(cfg, api_key, messages)
    local url = cfg.base_url .. "/chat/completions"
    local req = string.format(
        '{"model":"%s","messages":%s,"stream":false}',
        jesc(cfg.model), encode_messages(messages))

    local body_esc = req:gsub("'", "'\\''")
    local cmd = string.format(
        "curl -s -X POST '%s' -H 'Authorization: Bearer %s' -H 'Content-Type: application/json' -d '%s' -o /tmp/tether_http_out 2>&1; echo $?",
        url, api_key, body_esc)

    tether.exec(cmd .. " > /tmp/tether_http_status")
    local status = read_file("/tmp/tether_http_status") or "1"
    local code = tonumber(status:match("%d+")) or 1
    os.remove("/tmp/tether_http_status")

    if code ~= 0 then
        local err = read_file("/tmp/tether_http_out") or ""
        os.remove("/tmp/tether_http_out")
        return false, string.format("curl exit %d: %s", code, err:sub(1, 200))
    end

    local body = read_file("/tmp/tether_http_out") or ""
    os.remove("/tmp/tether_http_out")
    return true, body
end

function M.chat(cfg, api_key, messages, on_event)
    local ok, body = http_request(cfg, api_key, messages)
    if not ok then
        on_event({ type = "error", message = body })
        return false
    end
    local text, err = decode_content(body)
    if not text then
        on_event({ type = "error", message = err })
        return false
    end
    on_event({ type = "text_delta", text = text })
    on_event({ type = "done" })
    return true
end

return M
