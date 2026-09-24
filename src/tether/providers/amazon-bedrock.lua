-- tether providers/amazon-bedrock — Amazon Bedrock adapter.
-- Non-streaming Converse API (the ConverseStream eventstream is binary and
-- incompatible with the line-based transport): POST
-- https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse,
-- parsed in handle_non_sse into canonical events (pi bedrock-converse-stream
-- event mapping, single-shot). Auth: bearer token or SigV4 (static keys,
-- profile file, ECS/IRSA via auth.aws_creds).
local M = {}

M.name = "amazon-bedrock"

local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "amazon-bedrock: cannot load provider_common")
local jesc = common.jesc

local auth_mod = nil
local function auth()
    if auth_mod then return auth_mod end
    auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    return auth_mod
end

local S = { failure = nil }

function M.reset_stream()
    S.failure = nil
end

function M.stream_failure()
    return S.failure
end

local function provider_table(cfg)
    return (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers["amazon-bedrock"]) == "table")
        and cfg.providers["amazon-bedrock"] or {}
end

local function region_of(cfg, ctx_env)
    local p = provider_table(cfg)
    if type(p.region) == "string" and p.region ~= "" then return p.region end
    local pe = (type(ctx_env) == "table" and ctx_env)
        or (type(cfg) == "table" and cfg.provider_env) or {}
    for _, k in ipairs({ "AWS_REGION", "AWS_DEFAULT_REGION" }) do
        if pe[k] and pe[k] ~= "" then return pe[k] end
        local v = os.getenv(k)
        if v and v ~= "" then return v end
    end
    return "us-east-1"
end

local function runtime_host(region)
    return "bedrock-runtime." .. region .. ".amazonaws.com"
end

function M.stream_url(cfg, model, _api_key)
    local region = region_of(cfg)
    return "https://" .. runtime_host(region)
        .. "/model/" .. common.url_encode(model or "") .. "/converse"
end

-- SigV4. Pure Lua over common.sha256hex/hmac_sha256_raw; verified against
-- the AWS SigV4 test-suite vectors (see tests). `service` is "bedrock" in
-- prod; the parameter exists so the stock vectors (service "service")
-- can verify the implementation.
-- Returns the Authorization header value + the x-amz-date used.
local function sigv4(key, secret, session, region, service, method, url,
                      body, has_content_type, amzdate_opt)
    local amzdate = amzdate_opt or amzdate_now()
    local datestamp = amzdate:sub(1, 8)
    local host = url:match("^https?://([^/]+)")
    local path = url:match("^https?://[^/]+([^?]*)") or "/"
    local raw_query = url:match("%?(.*)$") or ""
    -- canonical query string: sorted by name
    local qparts = {}
    if raw_query ~= "" then
        for p in (raw_query .. "&"):gmatch("([^&]*)&") do
            qparts[#qparts + 1] = p
        end
        table.sort(qparts)
    end
    local query = table.concat(qparts, "&")
    local payload_hash = common.sha256hex(body or "")
    local cheaders, signed
    if has_content_type then
        cheaders = "content-type:application/json\n"
            .. "host:" .. host .. "\n"
            .. "x-amz-date:" .. amzdate .. "\n"
        signed = "content-type;host;x-amz-date"
    else
        cheaders = "host:" .. host .. "\n" .. "x-amz-date:" .. amzdate .. "\n"
        signed = "host;x-amz-date"
    end
    if session and session ~= "" then
        cheaders = cheaders .. "x-amz-security-token:" .. session .. "\n"
        signed = signed .. ";x-amz-security-token"
    end
    local canonical = method .. "\n" .. path .. "\n" .. query .. "\n"
        .. cheaders .. "\n" .. signed .. "\n" .. payload_hash
    local scope = datestamp .. "/" .. region .. "/" .. service .. "/aws4_request"
    local sts = "AWS4-HMAC-SHA256\n" .. amzdate .. "\n" .. scope .. "\n"
        .. common.sha256hex(canonical)
    local kDate = common.hmac_sha256_raw("AWS4" .. secret, datestamp)
    local kRegion = common.hmac_sha256_raw(kDate, region)
    local kService = common.hmac_sha256_raw(kRegion, service)
    local kSigning = common.hmac_sha256_raw(kService, "aws4_request")
    local sig = common.hmac_sha256hex(kSigning, sts)
    local authz = "AWS4-HMAC-SHA256 Credential=" .. key .. "/" .. scope
        .. ", SignedHeaders=" .. signed .. ", Signature=" .. sig
    return authz, amzdate
end

-- Test seam: deterministic SigV4 for the AWS vectors.
function M._sign(key, secret, session, region, service, method, url, body,
                 has_ct, amzdate)
    return sigv4(key, secret, session, region, service, method, url, body,
        has_ct, amzdate)
end

local function amzdate_now()
    local t = os.date("!*t")
    return string.format("%04d%02d%02dT%02d%02d%02dZ",
        t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function signed_lines(creds, region, method, url, body, has_ct)
    local authz, amzdate = sigv4(creds.key, creds.secret, creds.session,
        region, "bedrock", method, url, body, has_ct)
    local lines = {
        "Authorization: " .. authz,
        "x-amz-date: " .. amzdate,
    }
    if creds.session and creds.session ~= "" then
        lines[#lines + 1] = "x-amz-security-token: " .. creds.session
    end
    return lines
end

function M.header_lines(api_key, ctx)
    if api_key and api_key ~= "" then
        return { "Authorization: Bearer " .. api_key }
    end
    local a = auth()
    local creds = a and a.aws_creds and a.aws_creds()
    if creds and creds.mode == "bearer" then
        return { "Authorization: Bearer " .. creds.token }
    end
    if creds and creds.mode == "sigv4" then
        ctx = (type(ctx) == "table" and ctx) or {}
        local cfg = ctx.cfg
        local region = region_of(cfg, ctx.provider_env)
        local url = ctx.url or ""
        if url == "" then return {} end
        return signed_lines(creds, region, "POST", url, ctx.body or "", true)
    end
    return {}
end

function M.preflight(cfg, api_key, _url, _name)
    if api_key and api_key ~= "" then return nil end
    local a = auth()
    local creds = a and a.aws_creds and a.aws_creds()
    if creds then return nil end
    return "amazon-bedrock: no AWS credentials "
        .. "(AWS_BEARER_TOKEN_BEDROCK, AWS_PROFILE, or access keys)"
end

function M.ambient(_cfg)
    local a = auth()
    return a and a.aws_creds and a.aws_creds() ~= nil
end

-- Converse body from tether history. Consecutive same-role blocks merge
-- (Converse requires strict user/assistant alternation starting with user).
local function convert_messages(messages)
    local system_parts = {}
    local blocks = {}
    local function push(role, content)
        local last = blocks[#blocks]
        if last and last.role == role then
            for _, c in ipairs(content) do last.content[#last.content + 1] = c end
        else
            blocks[#blocks + 1] = { role = role, content = content }
        end
    end
    for _, m in ipairs(messages or {}) do
        local content = m.content
        if m.role == "system" then
            if type(content) == "string" and content ~= "" then
                system_parts[#system_parts + 1] = { text = content }
            end
        elseif type(content) == "table" and content.tool_calls then
            local items = {}
            if type(content.text) == "string" and content.text ~= "" then
                items[#items + 1] = { text = content.text }
            end
            for _, tc in ipairs(content.tool_calls) do
                local fn = tc["function"] or {}
                local args = {}
                if type(fn.arguments) == "string" and fn.arguments ~= "" then
                    local ok, parsed = pcall(common.json_decode, fn.arguments)
                    if ok and type(parsed) == "table" then args = parsed end
                elseif type(fn.arguments) == "table" then
                    args = fn.arguments
                end
                items[#items + 1] = { toolUse = {
                    toolUseId = tc.id or "", name = fn.name or "", input = args } }
            end
            push("assistant", items)
        elseif m.role == "tool" then
            push("user", { { toolResult = {
                toolUseId = m.tool_call_id or "",
                content = { text = tostring(content or "") },
                status = "success" } } })
        else
            local role = (m.role == "assistant") and "assistant" or "user"
            push(role, { { text = tostring(content or "") } })
        end
    end
    if #blocks > 0 and blocks[1].role ~= "user" then
        table.insert(blocks, 1, { role = "user", content = { { text = "<empty>" } } })
    end
    return system_parts, blocks
end

local function tools_payload()
    local tools = {}
    for _, t in ipairs(common.tools_schema()) do
        tools[#tools + 1] = { toolSpec = {
            name = t.name, description = t.description,
            inputSchema = { json = t.parameters } } }
    end
    return tools
end

function M.build_request(messages, model, _max_tokens)
    local system, blocks = convert_messages(messages)
    local body = { messages = blocks, toolConfig = { tools = tools_payload() } }
    if #system > 0 then body.system = system end
    -- the model travels in the URL path; Converse takes no model field.
    return common.json_encode(body)
end

function M.parse_sse_line(_line, _on_event)
    -- Converse (non-streaming) returns one JSON body; lines carry nothing.
    return
end

local STOP_REASONS = {
    end_turn = "stop", stop_sequence = "stop",
    max_tokens = "length", tool_use = "tool_calls",
}

function M.handle_non_sse(body, on_event)
    local ok, parsed = pcall(common.json_decode, body or "")
    if not ok or type(parsed) ~= "table" then
        S.failure = { message = "bedrock: unreadable response" }
        return true
    end
    local out = parsed.output
    if type(out) ~= "table" or type(out.message) ~= "table" then
        local msg = parsed.message or parsed.Message
        S.failure = { message = "bedrock: " .. tostring(msg or "error response") }
        return true
    end
    local content = out.message.content or {}
    for _, block in ipairs(content) do
        if type(block.text) == "string" and block.text ~= "" then
            on_event({ type = "text_delta", text = block.text })
        elseif type(block.toolUse) == "table" then
            local tu = block.toolUse
            on_event({ type = "tool_call_start", id = tu.toolUseId, name = tu.name })
            on_event({ type = "tool_call_delta", id = tu.toolUseId,
                arguments = common.json_encode(tu.input or {}) })
        end
    end
    local usage = parsed.usage or {}
    on_event({ type = "usage",
        usage = { used = (tonumber(usage.inputTokens) or 0)
                        + (tonumber(usage.outputTokens) or 0),
                  input = tonumber(usage.inputTokens) or 0,
                  output = tonumber(usage.outputTokens) or 0 } })
    local reason = STOP_REASONS[out.stopReason] or "other"
    on_event({ type = "done", reason = reason })
    return true
end

function M.models_url(cfg, _api_key)
    local region = region_of(cfg)
    return "https://bedrock." .. region .. ".amazonaws.com/foundation-models"
end

function M.models_headers(api_key, ctx)
    if api_key and api_key ~= "" then
        return { "Authorization: Bearer " .. api_key }
    end
    -- Sign the GET with SigV4 (no content-type in the signature).
    local a = auth()
    local creds = a and a.aws_creds and a.aws_creds()
    if not (creds and creds.mode == "sigv4") then return {} end
    ctx = (type(ctx) == "table" and ctx) or {}
    local cfg = ctx.cfg
    local region = region_of(cfg, ctx.provider_env)
    local url = M.models_url(cfg or {})
    return signed_lines(creds, region, "GET", url, "", false)
end

function M.models_parse(body)
    local result = {}
    for id in body:gmatch('"modelId"[%s]*:[%s]*"([^"]+)"') do
        result[#result + 1] = { id = id, name = id }
    end
    return result
end

function M.static_models()
    return {}
end

function M.encode_messages(messages)
    local _, blocks = convert_messages(messages)
    return common.json_encode(blocks)
end

M.tools_schema = common.tools_schema

return M
