-- tether providers/cloudflare-ai-gateway — Cloudflare AI Gateway adapter.
-- OpenAI-compatible wire through the gateway's OpenAI passthrough base
-- (catalog url_template carries {CLOUDFLARE_ACCOUNT_ID} /
-- {CLOUDFLARE_GATEWAY_ID}, expanded by the transport); the only protocol
-- difference is auth: cf-aig-authorization INSTEAD of Authorization/x-api-key
-- (pi providers/cloudflare-auth.ts — the gateway treats a request-supplied
-- auth header as an upstream credential).
local M = {}

M.name = "cloudflare-ai-gateway"

local openai = (_G.provider_openai)
    or (loadfile("src/tether/providers/openai.lua")
        and loadfile("src/tether/providers/openai.lua")())
assert(openai, "cloudflare-ai-gateway: cannot load provider_openai")

function M.stream_url(cfg, _model, _api_key)
    return ((cfg and cfg.base_url) or "") .. "/chat/completions"
end

function M.header_lines(api_key)
    -- Authorization/x-api-key MUST NOT be sent (gateway semantics).
    return { "cf-aig-authorization: Bearer " .. (api_key or "") }
end

function M.models_url(cfg, _api_key)
    return ((cfg and cfg.base_url) or "") .. "/models"
end

function M.models_headers(api_key)
    return M.header_lines(api_key)
end

-- Shared OpenAI wire: request envelope, SSE mapping, tools, stream state.
M.build_request = openai.build_request
M.parse_sse_line = openai.parse_sse_line
M.encode_messages = openai.encode_messages
M.tools_schema = openai.tools_schema
M.models_parse = openai.models_parse
M.reset_stream = openai.reset_stream
M.stream_failure = openai.stream_failure

function M.handle_non_sse(_body, _on_event)
    return false
end

function M.static_models()
    return {}
end

return M
