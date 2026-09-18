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

-- Per-stream state: content-block index -> { id, name }, plus the
-- message_start input token count. Streams are sequential (single agent
-- loop), so module-level state is safe; the transport resets it per
-- request via reset_stream().
local S = { index_to_id = {}, input_tokens = nil }

function M.reset_stream()
    S.index_to_id = {}
    S.input_tokens = nil
end

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
local function convert_messages(messages)
    local system_parts = {}
    local out = {}
    for _, m in ipairs(messages) do
        if m.role == "system" then
            system_parts[#system_parts + 1] = tostring(m.content or "")
        elseif m.role == "tool" then
            out[#out + 1] = string.format(
                '{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}',
                jesc(m.tool_call_id or ""), jesc(tostring(m.content or "")))
        else
            local content = m.content
            if type(content) == "table" and content.tool_calls then
                local blocks = {}
                for _, tc in ipairs(content.tool_calls) do
                    local raw = tc["function"] and tc["function"].arguments or ""
                    blocks[#blocks + 1] = string.format(
                        '{"type":"tool_use","id":"%s","name":"%s","input":%s}',
                        jesc(tc.id or ""),
                        jesc(tc["function"] and tc["function"].name or ""),
                        clean_args(raw))
                end
                out[#out + 1] = string.format(
                    '{"role":"assistant","content":[%s]}', table.concat(blocks, ","))
            else
                local role = (m.role == "assistant") and "assistant" or "user"
                out[#out + 1] = string.format(
                    '{"role":"%s","content":"%s"}', role, jesc(tostring(content or "")))
            end
        end
    end
    return table.concat(system_parts, "\n\n"), "[" .. table.concat(out, ",") .. "]"
end

local function tools_payload()
    local out = {}
    for _, t in ipairs(common.tools_schema()) do
        out[#out + 1] = common.json_encode({
            name = t.name, description = t.description,
            input_schema = t.parameters,
        })
    end
    return "[" .. table.concat(out, ",") .. "]"
end

function M.build_request(messages, model, max_tokens)
    local system, msgs = convert_messages(messages)
    local parts = {
        string.format('"model":"%s"', jesc(model or "")),
        string.format('"max_tokens":%d', tonumber(max_tokens) or 4096),
        string.format('"messages":%s', msgs),
        string.format('"tools":%s', tools_payload()),
        '"tool_choice":{"type":"auto"}',
        '"stream":true',
    }
    if system ~= "" then
        parts[#parts + 1] = string.format('"system":"%s"', jesc(system))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.stream_url(cfg, _model, _api_key)
    return (cfg.base_url or "") .. "/v1/messages"
end

function M.header_lines(api_key)
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
        on_event({ type = "done" })
        return
    end

    local etype = payload:match('"type"[%s]*:[%s]*"([^"]+)"')
    if etype == "error" then
        local msg = payload:match('"message"[%s]*:[%s]*"(.-[^\\])"')
        on_event({ type = "error", message = msg and json_unescape(msg) or "anthropic error" })
        return
    end

    if etype == "message_start" then
        S.input_tokens = tonumber(payload:match('"input_tokens"[%s]*:[%s]*(%d+)'))
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
            local text = payload:match('"text"[%s]*:[%s]*"(.-[^\\])"')
                or payload:match('"text"[%s]*:[%s]*""')
            if text and text ~= "" then
                text = json_unescape(text)
                if text ~= "" then
                    on_event({ type = "text_delta", text = text })
                end
            end
            return
        end
        if payload:find('"input_json_delta"', 1, true) then
            -- RAW fragment: unescaping happens once in agent.parse_args (D2b).
            local frag = payload:match('"partial_json"[%s]*:[%s]*"(.-[^\\])"')
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
        local out = tonumber(payload:match('"output_tokens"[%s]*:[%s]*(%d+)'))
        if out or S.input_tokens then
            on_event({ type = "usage", usage = {
                used = (S.input_tokens or 0) + (out or 0),
                prompt_tokens = S.input_tokens, completion_tokens = out,
            } })
        end
        return
    end

    if etype == "message_stop" then
        on_event({ type = "done" })
        return
    end
end

M.parse_sse_line = parse_sse_line
M.convert_messages = convert_messages

return M
