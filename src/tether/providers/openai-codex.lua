-- tether providers/openai-codex — OpenAI Codex (ChatGPT backend) adapter.
-- Responses-shaped stream: POST {base}/codex/responses with
-- {model, instructions, input, tools, stream:true}; SSE events follow the
-- Responses convention (pi api/openai-codex-responses.ts +
-- openai-responses-shared.ts). Auth: ChatGPT OAuth Bearer, optional
-- chatgpt-account-id from providers.openai-codex config.
local M = {}

M.name = "openai-codex"

local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "openai-codex: cannot load provider_common")
local jesc = common.jesc

local S = { failure = nil, calls = {} }

function M.reset_stream()
    S.failure = nil
    S.calls = {}
end

function M.stream_failure()
    return S.failure
end

local function provider_table(cfg)
    return (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers["openai-codex"]) == "table")
        and cfg.providers["openai-codex"] or {}
end

function M.stream_url(cfg, _model, _api_key)
    local base = ((cfg and cfg.base_url) or ""):gsub("/+$", "")
    if base:sub(-16) == "/codex/responses" then return base end
    return base .. "/codex/responses"
end

function M.header_lines(api_key, ctx)
    local lines = { "Authorization: Bearer " .. (api_key or "") }
    -- pi openai-codex-responses.ts: account header when the id is known
    -- (providers.openai-codex.chatgpt_account_id); the token JWT carries
    -- it otherwise.
    local cfg = (type(ctx) == "table" and ctx.cfg) or nil
    local p = provider_table(cfg)
    if type(p.chatgpt_account_id) == "string" and p.chatgpt_account_id ~= "" then
        lines[#lines + 1] = "chatgpt-account-id: " .. p.chatgpt_account_id
    end
    return lines
end

-- Tether history → Responses input items.
local function convert_input(messages)
    local instructions = {}
    local items = {}
    for _, m in ipairs(messages or {}) do
        local content = m.content
        if m.role == "system" then
            if type(content) == "string" and content ~= "" then
                instructions[#instructions + 1] = content
            end
        elseif type(content) == "table" and content.tool_calls then
            if type(content.text) == "string" and content.text ~= "" then
                items[#items + 1] = { type = "message", role = "assistant",
                    content = { { type = "output_text", text = content.text } } }
            end
            for _, tc in ipairs(content.tool_calls) do
                local fn = tc["function"] or {}
                local args = fn.arguments
                if type(args) ~= "string" then
                    args = common.json_encode(args or {})
                end
                items[#items + 1] = { type = "function_call",
                    call_id = tc.id or "", name = fn.name or "", arguments = args or "" }
            end
        elseif m.role == "tool" then
            items[#items + 1] = { type = "function_call_output",
                call_id = m.tool_call_id or "",
                output = tostring(content or "") }
        else
            local role = (m.role == "assistant") and "assistant" or "user"
            local ctype = (role == "assistant") and "output_text" or "input_text"
            items[#items + 1] = { type = "message", role = role,
                content = { { type = ctype, text = tostring(content or "") } } }
        end
    end
    return table.concat(instructions, "\n\n"), items
end

local function tools_payload()
    local tools = {}
    for _, t in ipairs(common.tools_schema()) do
        tools[#tools + 1] = { type = "function", name = t.name,
            description = t.description, parameters = t.parameters,
            strict = false }
    end
    return tools
end

function M.build_request(messages, model, _max_tokens)
    local instructions, items = convert_input(messages)
    local body = {
        model = model or "",
        instructions = instructions,
        input = items,
        tools = tools_payload(),
        stream = true,
    }
    return common.json_encode(body)
end

function M.parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done", reason = "other" })
        return
    end
    local etype = payload:match('"type"[%s]*:[%s]*"([^"]+)"')
    if not etype then return end
    if etype == "response.output_text.delta" then
        -- empty value yields "" (no event): never a second match without
        -- captures (it would return the whole `"delta":""` fragment as text).
        local delta = payload:match('"delta"[%s]*:[%s]*"(.-[^\\])"') or ""
        if delta and delta ~= "" then
            on_event({ type = "text_delta",
                text = common.json_unescape(delta) })
        end
    elseif etype == "response.output_item.added" then
        local item_type = payload:match('"item"%s*:%s*{[^}]*"type"[%s]*:[%s]*"([^"]+)"')
        if item_type == "function_call" then
            local index = tonumber(payload:match('"output_index"[%s]*:[%s]*(%d+)')) or 0
            local call_id = payload:match('"call_id"[%s]*:[%s]*"([^"]+)"') or ""
            local name = payload:match('"name"[%s]*:[%s]*"([^"]+)"') or ""
            S.calls[index] = { id = call_id, name = name }
            on_event({ type = "tool_call_start", id = call_id, name = name })
        end
    elseif etype == "response.function_call_arguments.delta" then
        local index = tonumber(payload:match('"output_index"[%s]*:[%s]*(%d+)')) or 0
        -- same no-capture rule as above: empty yields "" (no event), so a
        -- blank frame can never corrupt the assembled arguments.
        local delta = payload:match('"delta"[%s]*:[%s]*"(.-[^\\])"') or ""
        local slot = S.calls[index] or {}
        if delta and delta ~= "" then
            on_event({ type = "tool_call_delta", id = slot.id,
                arguments = common.json_unescape(delta) })
        end
    elseif etype == "response.completed" then
        local input = tonumber(payload:match('"input_tokens"[%s]*:[%s]*(%d+)')) or 0
        local output = tonumber(payload:match('"output_tokens"[%s]*:[%s]*(%d+)')) or 0
        on_event({ type = "usage",
            usage = { used = input + output, input = input, output = output } })
        on_event({ type = "done", reason = "stop" })
    elseif etype == "response.incomplete" then
        local reason = payload:match('"reason"[%s]*:[%s]*"([^"]+)"') or ""
        on_event({ type = "done",
            reason = (reason == "max_output_tokens") and "length" or "other" })
    elseif etype == "response.failed" then
        local msg = payload:match('"message"[%s]*:[%s]*"([^"]+)"') or "codex request failed"
        S.failure = { message = "codex: " .. common.json_unescape(msg) }
    end
end

function M.handle_non_sse(_body, _on_event)
    return false
end

function M.models_url(cfg, _api_key)
    return ((cfg and cfg.base_url) or ""):gsub("/+$", "") .. "/codex/models"
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
    return {}
end

M.encode_messages = convert_input
M.tools_schema = common.tools_schema

return M
