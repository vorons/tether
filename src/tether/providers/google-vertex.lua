-- tether providers/google-vertex — Google Vertex AI adapter.
-- Same Generative AI wire as gemini (body/SSE identical); this module only
-- owns endpoint shaping + auth: ADC/minted tokens ride Authorization:
-- Bearer, an explicit API key rides ?key= (pi google-vertex.ts).
local M = {}

M.name = "google-vertex"

local gemini = (_G.provider_gemini)
    or (loadfile("src/tether/providers/gemini.lua")
        and loadfile("src/tether/providers/gemini.lua")())
assert(gemini, "google-vertex: cannot load provider_gemini")

local function provider_table(cfg)
    return (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers["google-vertex"]) == "table")
        and cfg.providers["google-vertex"] or {}
end

local function lookup(cfg, key, env_names)
    local p = provider_table(cfg)
    if type(p[key]) == "string" and p[key] ~= "" then return p[key] end
    local pe = (type(cfg) == "table" and cfg.provider_env) or {}
    for _, ev in ipairs(env_names) do
        if pe[ev] and pe[ev] ~= "" then return pe[ev] end
        local v = os.getenv(ev)
        if v and v ~= "" then return v end
    end
    return nil
end

local function project_of(cfg)
    return lookup(cfg, "project", { "GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT" })
end

local function location_of(cfg)
    return lookup(cfg, "location", { "GOOGLE_CLOUD_LOCATION" })
end

local function endpoint(cfg)
    local project = project_of(cfg)
    local location = location_of(cfg)
    if not project or not location then return nil end
    return string.format("https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/google/models",
        location, project, location)
end

-- cfg._auth_style (set by config.api_key) tells a minted/stored bearer
-- token apart from a raw GOOGLE_CLOUD_API_KEY (query param).
local function is_bearer(cfg)
    return type(cfg) == "table" and cfg._auth_style == "bearer"
end

function M.stream_url(cfg, model, api_key)
    local ep = endpoint(cfg)
    if not ep then return "" end
    local url = ep .. "/" .. (model or "") .. ":streamGenerateContent"
    if not is_bearer(cfg) and api_key and api_key ~= "" then
        url = url .. "?key=" .. api_key
    end
    return url
end

function M.header_lines(api_key, ctx)
    local cfg = (type(ctx) == "table" and ctx.cfg) or nil
    if (cfg and is_bearer(cfg)) or (type(ctx) == "table" and ctx.auth_style == "bearer") then
        return { "Authorization: Bearer " .. (api_key or "") }
    end
    return {}
end

function M.preflight(cfg, _api_key, _url, _name)
    if not project_of(cfg) or not location_of(cfg) then
        return "google-vertex: set project and location "
            .. "(providers.google-vertex or GOOGLE_CLOUD_PROJECT/GOOGLE_CLOUD_LOCATION)"
    end
    return nil
end

function M.models_url(cfg, api_key)
    local ep = endpoint(cfg)
    if not ep then return "" end
    if not is_bearer(cfg) and api_key and api_key ~= "" then
        return ep .. "?key=" .. api_key
    end
    return ep
end

function M.models_headers(api_key, ctx)
    return M.header_lines(api_key, ctx)
end

function M.models_parse(body)
    local result = {}
    for name in body:gmatch('"name"[%s]*:[%s]*"[^"]*models/([^"]+)"') do
        result[#result + 1] = { id = name, name = name }
    end
    return result
end

-- Shared Gemini wire: request envelope, SSE mapping, tools, stream state.
M.build_request = gemini.build_request
M.parse_sse_line = gemini.parse_sse_line
M.encode_messages = gemini.encode_messages
M.tools_schema = gemini.tools_schema
M.reset_stream = gemini.reset_stream
M.stream_failure = gemini.stream_failure
M.handle_non_sse = gemini.handle_non_sse
if gemini.stream_finished then M.stream_finished = gemini.stream_finished end

function M.static_models()
    return {}
end

return M
