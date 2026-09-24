-- tether providers/azure-openai — Azure OpenAI adapter.
-- Chat-completions path over the shared OpenAI wire (body/SSE identical);
-- this module only owns URL shaping + auth header (pi docs: resource-root
-- normalization, api-key header, deployment path).
local M = {}

M.name = "azure-openai"

local openai = (_G.provider_openai)
    or (loadfile("src/tether/providers/openai.lua")
        and loadfile("src/tether/providers/openai.lua")())
assert(openai, "azure-openai: cannot load provider_openai")
local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "azure-openai: cannot load provider_common")

local API_VERSION_DEFAULT = "2024-10-21"

local function api_version(cfg)
    local p = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers["azure-openai"]) == "table")
        and cfg.providers["azure-openai"] or {}
    if type(p.api_version) == "string" and p.api_version ~= "" then
        return p.api_version
    end
    return API_VERSION_DEFAULT
end

local function base_root(cfg)
    return ((cfg and cfg.base_url) or ""):gsub("/+$", "")
end

-- pi providers.md: resource roots under ai.azure.com,
-- cognitiveservices.azure.com, openai.azure.com normalize to the OpenAI
-- API path (/openai/deployments/...).
local function has_suffix(host, suffix)
    return #host >= #suffix and host:sub(-#suffix) == suffix
end

local function is_resource_root(base)
    local host = base:match("^https?://([^/]+)") or ""
    return has_suffix(host, "ai.azure.com")
        or has_suffix(host, "cognitiveservices.azure.com")
        or has_suffix(host, "openai.azure.com")
end

local function with_api_version(url, ver)
    if url:find("api-version=", 1, true) then return url end
    return url .. (url:find("?", 1, true) and "&" or "?") .. "api-version=" .. ver
end

function M.stream_url(cfg, model, _api_key)
    local base = base_root(cfg)
    local ver = api_version(cfg)
    if base:find("/openai/deployments/", 1, true) then
        return with_api_version(base, ver)
    end
    if is_resource_root(base) then
        return base .. "/openai/deployments/" .. common.url_encode(model or "")
            .. "/chat/completions?api-version=" .. ver
    end
    -- custom proxy speaking plain OpenAI paths
    return base .. "/chat/completions"
end

function M.header_lines(api_key)
    return { "api-key: " .. (api_key or "") }
end

function M.preflight(cfg, _api_key, _url, _name)
    if (cfg and cfg.model) and cfg.model ~= "" then return nil end
    return "azure-openai: set providers.azure-openai.model to your deployment name"
end

function M.models_url(cfg, _api_key)
    local base = base_root(cfg)
    if is_resource_root(base) then
        return base .. "/openai/models?api-version=" .. api_version(cfg)
    end
    return base .. "/models"
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
    -- deployments are per-resource: live listing only.
    return {}
end

return M
