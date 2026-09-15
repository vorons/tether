-- tether M2: api — OpenAI-compatible chat via curl subprocess
local M = {}

-- JSON string escape
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

-- tether.exec(cmd) returns (exit_code)
-- stdout captured to /tmp/tether_out; we read it after exec
local OUTFILE = "/tmp/tether_out"

local function curl_request(cfg, api_key, messages)
    local url = cfg.base_url .. "/chat/completions"
    local req = string.format(
        '{"model":"%s","messages":%s,"stream":false}',
        jesc(cfg.model), encode_messages(messages))

    local curl_cmd = string.format(
        'curl -s -X POST %s -H "Authorization: Bearer %s" -H "Content-Type: application/json" -d %q > %s 2>&1; echo $? > %s.status',
        url, api_key, req, OUTFILE, OUTFILE)

    local code = tether.exec(curl_cmd)
    local status = assert(io.open(OUTFILE .. ".status", "r")):read("*a"):match("(%d+)")
    status:close()
    code = tonumber(status) or code

    if code ~= 0 then
        local f = io.open(OUTFILE, "r")
        local err = f and f:read("*a") or ""
        if f then f:close() end
        return false, string.format("curl exit %d: %s", code, err)
    end

    local f = assert(io.open(OUTFILE, "r"))
    local body = f:read("*a")
    f:close()
    return true, body
end

-- Minimal JSON decode (sufficient for OpenAI chat response)
local function decode_simple_json(s)
    -- extract first "content":"..." from choices[0].message
    local content = s:match('"content"%s*:%s*"((?:[^"\\]|\\.)*)"')
    if content then
        content = content:gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\t', '\t')
        return content
    end
    -- fallback: try raw substring
    return nil
end

function M.chat(cfg, api_key, messages, on_event)
    local ok, result = curl_request(cfg, api_key, messages)
    if not ok then
        on_event({ type = "error", message = result })
        return false
    end
    local text = decode_simple_json(result)
    if text then
        on_event({ type = "text_delta", text = text })
    end
    on_event({ type = "done" })
    return true
end

return M
