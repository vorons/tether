-- tether providers/anthropic — Anthropic Claude Messages API adapter.
-- Reference shape: erikarn/claude-lua (SSE event stream, stateless
-- full-history sends, tool list on every call).
-- Emits the same canonical events as the OpenAI adapter; tool argument
-- fragments stay RAW (still-JSON-escaped) — unescaping happens exactly
-- once in agent.parse_args (M7/D2b).
local M = {}

M.name = "anthropic"

local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "anthropic provider: cannot load provider_common")
local jesc = common.jesc
local json_unescape = common.json_unescape

-- Per-stream state: content-block index -> { id, name }, the message_start
-- input token count, prompt-cache creation/read counts (+ write TTL), the
-- last stop reason (a terminator carries none of its own) and a provider
-- error. Streams are sequential (single agent loop), so module-level state
-- is safe; the transport resets it per request via reset_stream().
local S = { index_to_id = {}, input_tokens = nil, cache_write = nil,
            cache_read = nil, cache_ttl = nil,
            stop_reason = nil, failure = nil }

function M.reset_stream()
    S.index_to_id = {}
    S.input_tokens = nil
    S.cache_write = nil
    S.cache_read = nil
    S.cache_ttl = nil
    S.stop_reason = nil
    S.failure = nil
end

-- Read by the transport after the stream: a non-nil table means the attempt
-- failed with the provider's own message.
function M.stream_failure()
    return S.failure
end

-- Anthropic stop_reason -> canonical stop reason (see the api-client spec).
local STOP_REASONS = {
    end_turn = "stop", stop_sequence = "stop", max_tokens = "length",
    tool_use = "tool_calls", refusal = "other",
}

-- Raw argument fragments are still-JSON-escaped: one unescape restores the
-- JSON object for splicing. Anything that is not an object degrades to {}
-- instead of breaking the request envelope structurally.
local function clean_args(raw)
    if not raw or raw == "" then return "{}" end
    local unesc = json_unescape(raw)
    if unesc:match("^%s*{.*}%s*$") then return unesc end
    return "{}"
end

-- History (OpenAI shape, as stored by agent.lua) -> Anthropic JSON body.
-- arguments in history are RAW (still-JSON-escaped) fragments: exactly one
-- unescape here turns them back into valid JSON, spliced as `input` verbatim.
--
-- plan (prompt-cache, optional): { sys_texts[], sys_head (idx or nil),
-- sys_end, tools, last_msg, ttl }. Without it the legacy string-form body
-- is emitted byte-for-byte as before.
local CC_5M = '{"type":"ephemeral"}'
local CC_1H = '{"type":"ephemeral","ttl":"1h"}'

local function cc_json(ttl)
    if ttl == "1h" then return CC_1H end
    return CC_5M
end

-- System texts -> Anthropic system array value with cache_control on the
-- head block (end of the stable prefix) and on the last block.
local function system_value(texts, head_idx, ttl)
    local cc = cc_json(ttl)
    local parts = {}
    for i, t in ipairs(texts) do
        local block = string.format('{"type":"text","text":"%s"', jesc(t))
        if i == head_idx or i == #texts then
            block = block .. ',"cache_control":' .. cc
        end
        parts[#parts + 1] = block .. "}"
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- One history message in block or string form. cc == nil emits the legacy
-- plain body; a cc string stamps the rolling write-point marker on the
-- final content block.
local function message_value(m, cc)
    if m.role == "tool" then
        if cc then
            return string.format(
                '{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s","cache_control":%s}]}',
                jesc(m.tool_call_id or ""), jesc(tostring(m.content or "")), cc)
        end
        return string.format(
            '{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}',
            jesc(m.tool_call_id or ""), jesc(tostring(m.content or "")))
    end
    local content = m.content
    if type(content) == "table" and content.tool_calls then
        local blocks = {}
        if type(content.text) == "string" and content.text ~= "" then
            blocks[#blocks + 1] = string.format('{"type":"text","text":"%s"}',
                jesc(content.text))
        end
        for _, tc in ipairs(content.tool_calls) do
            local raw = tc["function"] and tc["function"].arguments or ""
            blocks[#blocks + 1] = string.format(
                '{"type":"tool_use","id":"%s","name":"%s","input":%s}',
                jesc(tc.id or ""),
                jesc(tc["function"] and tc["function"].name or ""),
                clean_args(raw))
        end
        if cc then
            if #blocks == 0 then
                blocks[#blocks + 1] = '{"type":"text","text":""}'
            end
            blocks[#blocks] = blocks[#blocks]:sub(1, -2)
                .. ',"cache_control":' .. cc .. "}"
        end
        if cc then
            local role = (m.role == "assistant") and "assistant" or "user"
            return string.format('{"role":"%s","content":[%s]}', role,
                table.concat(blocks, ","))
        end
        return string.format(
            '{"role":"assistant","content":[%s]}', table.concat(blocks, ","))
    end
    local role = (m.role == "assistant") and "assistant" or "user"
    if cc then
        return string.format(
            '{"role":"%s","content":[{"type":"text","text":"%s","cache_control":%s}]}',
            role, jesc(tostring(content or "")), cc)
    end
    return string.format(
        '{"role":"%s","content":"%s"}', role, jesc(tostring(content or "")))
end

local function convert_messages(messages, plan)
    local system_parts = {}
    local nonsys = {}
    for _, m in ipairs(messages) do
        if m.role == "system" then
            system_parts[#system_parts + 1] = tostring(m.content or "")
        else
            nonsys[#nonsys + 1] = m
        end
    end
    local out = {}
    local with_markers = type(plan) == "table"
    for i, m in ipairs(nonsys) do
        if with_markers and plan.last_msg and i == #nonsys then
            out[#out + 1] = message_value(m, cc_json(plan.ttl))
        else
            out[#out + 1] = message_value(m, nil)
        end
    end
    local system = nil
    if with_markers then
        local texts = (type(plan.sys_texts) == "table" and #plan.sys_texts > 0)
            and plan.sys_texts or system_parts
        if #texts > 0 and plan.sys_end then
            system = system_value(texts, plan.sys_head, plan.ttl)
        elseif #system_parts > 0 then
            system = string.format('"%s"', jesc(table.concat(system_parts, "\n\n")))
        end
    elseif #system_parts > 0 then
        system = string.format('"%s"', jesc(table.concat(system_parts, "\n\n")))
    end
    return system, "[" .. table.concat(out, ",") .. "]"
end

local function tools_payload(plan)
    local out = {}
    for _, t in ipairs(common.sorted_tools()) do
        out[#out + 1] = common.json_encode({
            name = t.name, description = t.description,
            input_schema = t.parameters,
        })
    end
    -- prompt-cache: breakpoint at the end of the tools block (last tool).
    if type(plan) == "table" and plan.tools and #out > 0 then
        out[#out] = out[#out]:sub(1, -2)
            .. ',"cache_control":' .. cc_json(plan.ttl) .. "}"
    end
    return "[" .. table.concat(out, ",") .. "]"
end

-- add-reasoning-level: thinking budget per level. Anthropic requires
-- `max_tokens` to stay above the budget with room left for the answer, so
-- enabling a level raises the default 4096 window to budget + 4096.
local THINK_BUDGET = { low = 4096, medium = 16384, high = 65536 }

function M.build_request(messages, model, max_tokens, reasoning, plan)
    local system, msgs = convert_messages(messages, plan)
    local budget = THINK_BUDGET[reasoning]
    local mt = tonumber(max_tokens) or 4096
    if budget and mt < budget + 4096 then mt = budget + 4096 end
    local parts = {
        string.format('"model":"%s"', jesc(model or "")),
        string.format('"max_tokens":%d', mt),
        string.format('"messages":%s', msgs),
        string.format('"tools":%s', tools_payload(plan)),
        '"tool_choice":{"type":"auto"}',
        '"stream":true',
    }
    if budget then
        parts[#parts + 1] = string.format(
            '"thinking":{"type":"enabled","budget_tokens":%d}', budget)
    end
    if system ~= nil then
        parts[#parts + 1] = string.format('"system":%s', system)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.stream_url(cfg, _model, _api_key)
    return (cfg.base_url or "") .. "/v1/messages"
end

function M.header_lines(api_key, ctx)
    -- expand-provider-catalog: ANTHROPIC_AUTH_TOKEN (and stored OAuth) use
    -- Bearer auth (pi providers/anthropic.ts); plain keys use x-api-key.
    -- ctx.auth_style comes from config.api_key via cfg._auth_style.
    if type(ctx) == "table" and ctx.auth_style == "bearer" then
        return { "Authorization: Bearer " .. (api_key or "") }
    end
    return {
        "x-api-key: " .. (api_key or ""),
        "anthropic-version: 2023-06-01",
    }
end

function M.handle_non_sse(_body, _on_event)
    return false
end

function M.models_url(cfg, _api_key)
    return (cfg.base_url or "") .. "/v1/models"
end

function M.models_headers(api_key, ctx)
    return M.header_lines(api_key, ctx)
end

function M.models_parse(body)
    local result = {}
    for id in body:gmatch('"id"[%s]*:[%s]*"([^"]+)"') do
        result[#result + 1] = { id = id, name = id }
    end
    return result
end

function M.static_models()
    return {
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        "claude-haiku-3-5-20241022",
        "claude-3-5-sonnet-20241022",
    }
end

-- Anthropic SSE: "event: ..." lines interleaved with "data: {...}" lines.
-- Event types: message_start / content_block_start / content_block_delta /
-- content_block_stop / message_delta / message_stop / error / ping.
local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done", reason = S.stop_reason or "other" })
        return
    end

    local etype = payload:match('"type"[%s]*:[%s]*"([^"]+)"')
    if etype == "error" then
        -- add-retry-and-continuation: record the failure for the transport
        -- instead of emitting an event; the retry policy classifies it.
        local msg = common.json_string(payload, "message")
        local status = tonumber(payload:match('"status"[%s]*:[%s]*(%d+)'))
            or tonumber(payload:match('"code"[%s]*:[%s]*"?([%d]+)"?'))
        S.failure = { message = msg and json_unescape(msg) or "anthropic error",
                      status = status }
        return
    end

    if etype == "message_start" then
        S.input_tokens = tonumber(payload:match('"input_tokens"[%s]*:[%s]*(%d+)'))
        -- prompt-cache: creation/read counts. The 5m/1h breakdown sums to
       -- the total when present, so prefer it (and learn the write TTL).
        local e5 = tonumber(payload:match('"ephemeral_5m_input_tokens"[%s]*:[%s]*(%d+)'))
        local e1 = tonumber(payload:match('"ephemeral_1h_input_tokens"[%s]*:[%s]*(%d+)'))
        S.cache_read = tonumber(payload:match('"cache_read_input_tokens"[%s]*:[%s]*(%d+)'))
        S.cache_ttl = nil
        if (e5 or 0) > 0 or (e1 or 0) > 0 then
            S.cache_write = (e5 or 0) + (e1 or 0)
            S.cache_ttl = ((e1 or 0) > 0) and "1h" or "5m"
        else
            S.cache_write = tonumber(payload:match('"cache_creation_input_tokens"[%s]*:[%s]*(%d+)'))
        end
        return
    end

    if etype == "content_block_start" then
        if payload:find('"tool_use"', 1, true) then
            local idx = tonumber(payload:match('"index"[%s]*:[%s]*(%d+)'))
            local id = payload:match('"id"[%s]*:[%s]*"([%w_%-]+)"')
            local name = payload:match('"name"[%s]*:[%s]*"([%w_%.%-]+)"')
            if id and name then
                if idx then S.index_to_id[idx] = { id = id, name = name } end
                on_event({ type = "tool_call_start", id = id, name = name })
            end
        end
        return
    end

    if etype == "content_block_delta" then
        local idx = tonumber(payload:match('"index"[%s]*:[%s]*(%d+)'))
        if payload:find('"text_delta"', 1, true) then
            -- Escape-aware read (common.json_string): the old '(.-[^\\])"'
            -- pattern over-matched a value ending in an escaped backslash and
            -- an empty one, leaking the fields after it into the answer.
            local text = common.json_string(payload, "text") or ""
            if text ~= "" then
                text = json_unescape(text)
                if text ~= "" then
                    on_event({ type = "text_delta", text = text })
                end
            end
            return
        end
        if payload:find('"thinking_delta"', 1, true) then
            -- add-reasoning-level: thinking blocks stream as reasoning_delta
            -- (signature_delta below carries no text and emits nothing).
            local th = common.json_string(payload, "thinking") or ""
            if th ~= "" then
                th = json_unescape(th)
                if th ~= "" then
                    on_event({ type = "reasoning_delta", text = th })
                end
            end
            return
        end
        if payload:find('"input_json_delta"', 1, true) then
            -- RAW fragment: unescaping happens once in agent.parse_args (D2b).
            local frag = common.json_string(payload, "partial_json")
            if frag then
                local known = idx and S.index_to_id[idx]
                if known then
                    on_event({ type = "tool_call_delta", id = known.id, arguments = frag })
                else
                    on_event({ type = "tool_call_delta", index = idx, arguments = frag })
                end
            end
            return
        end
        return
    end

    if etype == "message_delta" then
        -- the final delta carries the stop reason; remember it for message_stop
        local reason = payload:match('"stop_reason"[%s]*:[%s]*"([^"]+)"')
        if reason then S.stop_reason = STOP_REASONS[reason] or "other" end
        local out = tonumber(payload:match('"output_tokens"[%s]*:[%s]*(%d+)'))
        if out or S.input_tokens then
            local usage = {
                used = (S.input_tokens or 0) + (out or 0),
                prompt_tokens = S.input_tokens, completion_tokens = out,
            }
            -- prompt-cache: additive cache fields (nil when unreported).
            if S.cache_read ~= nil then usage.cache_read_tokens = S.cache_read end
            if S.cache_write ~= nil then usage.cache_write_tokens = S.cache_write end
            if S.cache_ttl ~= nil then usage.cache_write_ttl = S.cache_ttl end
            on_event({ type = "usage", usage = usage })
        end
        return
    end

    if etype == "message_stop" then
        on_event({ type = "done", reason = S.stop_reason or "other" })
        return
    end
end

M.parse_sse_line = parse_sse_line
M.convert_messages = convert_messages

-- add-provider-login 3.3: terminal OAuth hooks (config-supplied endpoints —
-- no invented Anthropic OAuth URLs; paste path always works).
function M.login_flow(cfg)
    local p = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers.anthropic) == "table")
        and cfg.providers.anthropic or {}
    local cid = p.oauth_client_id
    if type(cid) ~= "string" or cid == "" then return nil end
    if type(p.oauth_token_url) ~= "string" or p.oauth_token_url == "" then
        return nil
    end
    if type(p.oauth_authorize_url) ~= "string" or p.oauth_authorize_url == "" then
        return nil
    end
    local flow = {
        provider = "anthropic",
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
