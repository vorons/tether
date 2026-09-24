-- tether providers/radius — Radius gateway adapter (best-effort).
-- The Radius gateway speaks pi's proprietary pi-messages protocol
-- (POST {gateway}/messages with a full pi TranscriptContext). Tether sends
-- an OpenAI-style envelope instead and parses OpenAI-shaped SSE; mismatches
-- surface as provider failures, never silent success. Live catalog comes
-- from GET {gateway}/v1/config (pi radius-config.ts); no static list.
local M = {}

M.name = "radius"

local openai = (_G.provider_openai)
    or (loadfile("src/tether/providers/openai.lua")
        and loadfile("src/tether/providers/openai.lua")())
assert(openai, "radius: cannot load provider_openai")

local function gateway(cfg)
    return (((cfg and cfg.base_url) or ""):gsub("/+$", ""))
end

function M.stream_url(cfg, _model, _api_key)
    return gateway(cfg) .. "/messages"
end

function M.header_lines(api_key)
    return { "Authorization: Bearer " .. (api_key or "") }
end

function M.build_request(messages, model, max_tokens)
    local req = openai.build_request(messages, model, max_tokens)
    -- pi-messages carries the session for routing; Radius ignores unknown
    -- fields, so annotating the model envelope is harmless.
    return req
end

function M.models_url(cfg, _api_key)
    return gateway(cfg) .. "/v1/config"
end

function M.models_headers(api_key)
    return M.header_lines(api_key)
end

function M.models_parse(body)
    -- gateway config: {"baseUrl":..., "models":[{"id":...}]} plus the
    -- OpenAI /models shape as a fallback.
    local result = {}
    local seen = {}
    for id in body:gmatch('"id"[%s]*:[%s]*"([^"]+)"') do
        if not seen[id] then
            seen[id] = true
            result[#result + 1] = { id = id, name = id }
        end
    end
    return result
end

-- Shared OpenAI wire: SSE mapping, tools, stream state.
M.parse_sse_line = openai.parse_sse_line
M.encode_messages = openai.encode_messages
M.tools_schema = openai.tools_schema
M.reset_stream = openai.reset_stream
M.stream_failure = openai.stream_failure

function M.handle_non_sse(_body, _on_event)
    return false
end

function M.static_models()
    return {}
end

return M
