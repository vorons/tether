-- tether providers/openai — OpenAI-compatible adapter.
-- Holds the original api.lua request/SSE logic verbatim; the shared
-- transport (curl pipe, retry, temp files) lives in api.lua and calls
-- this module through the provider interface:
--   build_request(messages, model, max_tokens) -> body string
--   stream_url(cfg, model, api_key) -> url
--   header_lines(api_key) -> array of "Name: value" header lines
--   parse_sse_line(line, on_event)
--   handle_non_sse(body, on_event) -> true when the body was consumed
--   models_url(cfg, api_key) / models_headers(api_key) / models_parse(body)
--   static_models() / tools_schema()
local M = {}

M.name = "openai"

local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "openai provider: cannot load provider_common")
local jesc = common.jesc
local json_unescape = common.json_unescape

-- Per-request state (streams are sequential — single agent loop — and the
-- transport resets this per request). `stop_reason` is remembered because a
-- terminator such as the `[DONE]` sentinel carries no reason of its own;
-- `failure` is a provider error, which fails the attempt instead of being
-- reported as a successful stream.
local S = { stop_reason = nil, failure = nil }

function M.reset_stream()
    S.stop_reason = nil
    S.failure = nil
end

-- Read by the transport after the stream: a non-nil table means the attempt
-- failed with the provider's own message.
function M.stream_failure()
    return S.failure
end

-- Provider finish_reason -> canonical stop reason (see the api-client spec).
local STOP_REASONS = {
    stop = "stop", length = "length",
    tool_calls = "tool_calls", ["function_call"] = "tool_calls",
}

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
            -- 1.2: keep any assistant text emitted alongside the tool calls
            local text = content.text
            local content_json = (type(text) == "string" and text ~= "")
                and ('"' .. jesc(text) .. '"') or "null"
            items[#items + 1] = string.format(
                '{"role":"assistant","content":%s,"tool_calls":[%s]}',
                content_json, table.concat(tcs, ","))
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
local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done", reason = S.stop_reason or "other" })
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

    -- finish reason: any reported reason closes the segment, and the value is
    -- remembered so later terminators repeat it instead of clearing it
    local finish = payload:match('"finish_reason"[%s]*:[%s]*"([^"]+)"')
    if finish then
        S.stop_reason = STOP_REASONS[finish] or "other"
        on_event({ type = "done", reason = S.stop_reason })
    end

    -- usage
    local pt = tonumber(payload:match('"prompt_tokens"[%s]*:[%s]*(%d+)'))
    local ct = tonumber(payload:match('"completion_tokens"[%s]*:[%s]*(%d+)'))
    if pt or ct then
        on_event({ type = "usage", usage = { used = (pt or 0) + (ct or 0), prompt_tokens = pt, completion_tokens = ct } })
    end

    -- error payloads: {"error":{"message":"...","status":429}}
    -- 3.4: detect the error from the payload (parse_json_str does not keep
    -- nested objects, so obj.error was never set) and keep the real text.
    -- add-retry-and-continuation: the attempt fails instead of succeeding, and
    -- the policy classifies the message — the provider never emits `error`.
    if not content and payload:find('"error"', 1, true) then
        local msg = payload:match('"message"[%s]*:[%s]*"([^"]*)"')
        if msg then msg = json_unescape(msg) end
        local status = tonumber(payload:match('"status"[%s]*:[%s]*(%d+)'))
            or tonumber(payload:match('"code"[%s]*:[%s]*"?([%d]+)"?'))
        S.failure = { message = msg or "api error", status = status }
    end
end

local function tools_payload()
    local out = {}
    for _, t in ipairs(common.tools_schema()) do
        out[#out + 1] = {
            type = "function",
            ["function"] = { name = t.name, description = t.description,
                             parameters = t.parameters },
        }
    end
    return out
end

function M.build_request(messages, model, _max_tokens)
    return string.format(
        '{"model":"%s","messages":%s,"tools":%s,"tool_choice":"auto","stream":true}',
        jesc(model or ""), encode_messages(messages),
        common.json_encode(tools_payload()))
end

function M.stream_url(cfg, _model, _api_key)
    return (cfg.base_url or "") .. "/chat/completions"
end

function M.header_lines(api_key)
    return { "Authorization: Bearer " .. (api_key or "") }
end

function M.handle_non_sse(_body, _on_event)
    return false
end

function M.models_url(cfg, _api_key)
    return (cfg.base_url or "") .. "/models"
end

function M.models_headers(api_key)
    return M.header_lines(api_key)
end

function M.models_parse(body)
    local result = {}
    for id in body:gmatch('"id"[%s]*:[%s]*"([^"]+)"') do
        result[#result + 1] = { id = id, name = id }
    end
    return result
end

function M.static_models()
    -- M7/N3: static fallback when /models is unavailable. Your provider's
    -- real list may differ — set cfg.model directly (see README).
    return {
        "gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1",
        "gpt-5", "gpt-5-mini", "o3", "o4-mini",
        "deepseek-chat", "deepseek-reasoner", "qwen-max", "qwen-plus",
    }
end

-- Exports for unit tests (M7) and the api dispatcher
M.parse_sse_line = parse_sse_line
M.encode_messages = encode_messages
M.tools_schema = common.tools_schema

-- add-provider-login 3.3: terminal OAuth hooks. Endpoints are not invented —
-- both authorize and token URLs must come from config (see design.md: paste
-- remains the universal fallback when no OAuth app is registered).
function M.login_flow(cfg)
    local p = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers.openai) == "table") and cfg.providers.openai or {}
    local cid = p.oauth_client_id
    if type(cid) ~= "string" or cid == "" then return nil end
    if type(p.oauth_token_url) ~= "string" or p.oauth_token_url == "" then
        return nil
    end
    if type(p.oauth_authorize_url) ~= "string" or p.oauth_authorize_url == "" then
        return nil
    end
    local flow = {
        provider = "openai",
        client_id = cid,
        client_secret = p.oauth_client_secret,
        redirect_uri = p.oauth_redirect_uri or "http://localhost:7/",
        scope = p.oauth_scope,
        token_url = p.oauth_token_url,
    }
    flow.authorize_url = common.oauth_authorize_url(p.oauth_authorize_url, flow)
    if not flow.authorize_url then return nil end
    return flow
end

function M.token_exchange(post_json, flow, code, now)
    return common.oauth_token_exchange(post_json, flow, code, now)
end

return M
