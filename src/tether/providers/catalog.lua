-- tether providers/catalog — provider preset catalog (pi parity).
-- Maps every supported provider id to its wire protocol, default endpoint,
-- credential env var, and default model. Tier-A entries reuse one of the
-- three wire modules (openai/anthropic/gemini) via the api.lua alias
-- registry — no new adapter, no new embed row. Tier-B entries name an
-- adapter module (src/tether/providers/<wire>.lua).
--
-- Sources: pi packages/ai/src/providers/* + env-api-keys.ts.
-- Model ids are defaults only: live /models listing is authoritative
-- (new presets have no static fallback).
local M = {}

-- wire: "openai" | "anthropic" | "gemini" | adapter module id (Tier-B).
-- url_template: {VAR} placeholders expanded from cfg.provider_env/os env.
-- api_key_env "": provider takes no env key (OAuth/store only).
M.entries = {
    openai    = { wire = "openai", base_url = "https://api.openai.com/v1",
                 api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini" },
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
                 api_key_env = "ANTHROPIC_API_KEY", model = "claude-sonnet-4-20250514" },
    gemini    = { wire = "gemini", base_url = "https://generativelanguage.googleapis.com",
                 api_key_env = "GEMINI_API_KEY", model = "gemini-2.5-flash" },

    -- Tier-A: OpenAI-compatible wire
    deepseek  = { wire = "openai", base_url = "https://api.deepseek.com",
                 api_key_env = "DEEPSEEK_API_KEY", model = "deepseek-chat" },
    groq      = { wire = "openai", base_url = "https://api.groq.com/openai/v1",
                 api_key_env = "GROQ_API_KEY", model = "llama-3.3-70b-versatile" },
    cerebras  = { wire = "openai", base_url = "https://api.cerebras.ai/v1",
                 api_key_env = "CEREBRAS_API_KEY", model = "llama-3.3-70b" },
    xai       = { wire = "openai", base_url = "https://api.x.ai/v1",
                 api_key_env = "XAI_API_KEY", model = "grok-4" },
    openrouter = { wire = "openai", base_url = "https://openrouter.ai/api/v1",
                 api_key_env = "OPENROUTER_API_KEY", model = "openai/gpt-4o-mini" },
    fireworks = { wire = "openai", base_url = "https://api.fireworks.ai/inference",
                 api_key_env = "FIREWORKS_API_KEY",
                 model = "accounts/fireworks/models/llama-v3p3-70b-instruct" },
    together  = { wire = "openai", base_url = "https://api.together.ai/v1",
                 api_key_env = "TOGETHER_API_KEY",
                 model = "meta-llama/Llama-3.3-70B-Instruct-Turbo" },
    baseten   = { wire = "openai", base_url = "https://inference.baseten.co/v1",
                 api_key_env = "BASETEN_API_KEY", model = "deepseek-ai/DeepSeek-V3" },
    nvidia    = { wire = "openai", base_url = "https://integrate.api.nvidia.com/v1",
                 api_key_env = "NVIDIA_API_KEY", model = "meta/llama-3.3-70b-instruct" },
    moonshotai = { wire = "openai", base_url = "https://api.moonshot.ai/v1",
                 api_key_env = "MOONSHOT_API_KEY", model = "kimi-k2-0711-preview" },
    ["moonshotai-cn"] = { wire = "openai", base_url = "https://api.moonshot.cn/v1",
                 api_key_env = "MOONSHOT_API_KEY", model = "kimi-k2-0711-preview" },
    huggingface = { wire = "openai", base_url = "https://router.huggingface.co/v1",
                 api_key_env = "HF_TOKEN", model = "meta-llama/Llama-3.3-70B-Instruct" },
    zai       = { wire = "openai", base_url = "https://api.z.ai/api/coding/paas/v4",
                 api_key_env = "ZAI_API_KEY", model = "glm-4.5" },
    ["zai-coding-cn"] = { wire = "openai", base_url = "https://open.bigmodel.cn/api/coding/paas/v4",
                 api_key_env = "ZAI_CODING_CN_API_KEY", model = "glm-4.5" },
    ["qwen-token-plan"] = { wire = "openai",
                 base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
                 api_key_env = "QWEN_TOKEN_PLAN_API_KEY", model = "qwen-max" },
    ["qwen-token-plan-cn"] = { wire = "openai",
                 base_url = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                 api_key_env = "QWEN_TOKEN_PLAN_CN_API_KEY", model = "qwen-max" },
    ["qwen-token-plan-individual"] = { wire = "openai",
                 base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
                 api_key_env = "QWEN_TOKEN_PLAN_API_KEY", model = "qwen-max" },
    xiaomi    = { wire = "openai", base_url = "https://api.xiaomimimo.com/v1",
                 api_key_env = "XIAOMI_API_KEY", model = "mimo-7b" },
    ["xiaomi-token-plan-cn"] = { wire = "openai",
                 base_url = "https://token-plan-cn.xiaomimimo.com/v1",
                 api_key_env = "XIAOMI_TOKEN_PLAN_CN_API_KEY", model = "mimo-7b" },
    ["xiaomi-token-plan-ams"] = { wire = "openai",
                 base_url = "https://token-plan-ams.xiaomimimo.com/v1",
                 api_key_env = "XIAOMI_TOKEN_PLAN_AMS_API_KEY", model = "mimo-7b" },
    ["xiaomi-token-plan-sgp"] = { wire = "openai",
                 base_url = "https://token-plan-sgp.xiaomimimo.com/v1",
                 api_key_env = "XIAOMI_TOKEN_PLAN_SGP_API_KEY", model = "mimo-7b" },
    ["ant-ling"] = { wire = "openai", base_url = "https://api.ant-ling.com/v1",
                 api_key_env = "ANT_LING_API_KEY", model = "Ling-2.6-flash" },
    -- pi-agnes extension (Agnes AI, OpenAI-compatible, Bearer, /v1/models)
    agnes     = { wire = "openai", base_url = "https://apihub.agnes-ai.com/v1",
                 api_key_env = "AGNES_API_KEY", model = "agnes-2.5-flash" },
    ["agnes-cn"] = { wire = "openai", base_url = "https://api.agnes-ai.cn/v1",
                 api_key_env = "AGNES_CN_API_KEY", model = "agnes-2.5-flash" },
    mistral   = { wire = "openai", base_url = "https://api.mistral.ai/v1",
                 api_key_env = "MISTRAL_API_KEY", model = "mistral-large-latest" },
    -- pi serves Meta over openai-responses; chat-completions is best-effort.
    meta      = { wire = "openai", base_url = "https://api.meta.ai/v1",
                 api_key_env = "META_API_KEY", model = "muse" },
    ["github-copilot"] = { wire = "openai",
                 base_url = "https://api.individual.githubcopilot.com",
                 api_key_env = "COPILOT_GITHUB_TOKEN", model = "gpt-4.1" },
    opencode  = { wire = "openai", base_url = "https://opencode.ai/zen/v1",
                 api_key_env = "OPENCODE_API_KEY", model = "kimi-k2.6" },
    ["opencode-go"] = { wire = "openai", base_url = "https://opencode.ai/zen/go/v1",
                 api_key_env = "OPENCODE_API_KEY", model = "kimi-k2.6" },
    llama     = { wire = "openai", base_url = "http://127.0.0.1:8080/v1",
                 api_key_env = "LLAMA_API_KEY", model = "" },
    ["cloudflare-workers-ai"] = { wire = "openai",
                 url_template = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
                 api_key_env = "CLOUDFLARE_API_KEY",
                 model = "@cf/meta/llama-3.3-70b-instruct-fp8-fast" },

    -- Tier-A: Anthropic-compatible wire
    ["kimi-coding"] = { wire = "anthropic", base_url = "https://api.kimi.com/coding",
                 api_key_env = "KIMI_API_KEY", model = "kimi-for-coding" },
    minimax   = { wire = "anthropic", base_url = "https://api.minimax.io/anthropic",
                 api_key_env = "MINIMAX_API_KEY", model = "MiniMax-M2.7" },
    ["minimax-cn"] = { wire = "anthropic", base_url = "https://api.minimaxi.com/anthropic",
                 api_key_env = "MINIMAX_CN_API_KEY", model = "MiniMax-M2.7" },
    ["vercel-ai-gateway"] = { wire = "anthropic", base_url = "https://ai-gateway.vercel.sh",
                 api_key_env = "AI_GATEWAY_API_KEY", model = "anthropic/claude-sonnet-4" },

    -- Tier-B: own adapter modules (src/tether/providers/<wire>.lua)
    ["azure-openai"] = { wire = "azure-openai",
                 base_url = "", api_key_env = "AZURE_OPENAI_API_KEY", model = "gpt-4o" },
    ["amazon-bedrock"] = { wire = "amazon-bedrock",
                 base_url = "", api_key_env = "AWS_BEARER_TOKEN_BEDROCK",
                 model = "us.anthropic.claude-sonnet-4-20250514-v1:0" },
    ["google-vertex"] = { wire = "google-vertex",
                 base_url = "", api_key_env = "GOOGLE_CLOUD_API_KEY", model = "gemini-2.5-flash" },
    ["cloudflare-ai-gateway"] = { wire = "cloudflare-ai-gateway",
                 url_template = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai",
                 api_key_env = "CLOUDFLARE_API_KEY", model = "gpt-4o-mini" },
    radius    = { wire = "radius",
                 base_url = "https://radius.pi.dev",
                 api_key_env = "RADIUS_API_KEY", model = "" },
    ["openai-codex"] = { wire = "openai-codex",
                 base_url = "https://chatgpt.com/backend-api",
                 api_key_env = "", model = "gpt-5.3-codex" },
}

-- Picker order: the big three first, then alphabetical.
local PINNED = { "openai", "anthropic", "gemini" }

function M.get(id)
    if type(id) ~= "string" then return nil end
    return M.entries[id]
end

function M.ids()
    local out = {}
    for _, id in ipairs(PINNED) do
        if M.entries[id] then out[#out + 1] = id end
    end
    local rest = {}
    for id in pairs(M.entries) do
        if id ~= "openai" and id ~= "anthropic" and id ~= "gemini" then
            rest[#rest + 1] = id
        end
    end
    table.sort(rest)
    for _, id in ipairs(rest) do out[#out + 1] = id end
    return out
end

function M.count()
    local n = 0
    for _ in pairs(M.entries) do n = n + 1 end
    return n
end

-- expand-provider-catalog: generic login flow for preset ids without their
-- own adapter module. Endpoints are config-sourced only (never invented):
-- providers.<id>.oauth_device_url + oauth_client_id → device flow;
-- oauth_client_id + oauth_token_url + oauth_authorize_url → code flow.
-- Otherwise nil (the caller falls back to API-key paste).
function M.login_flow(cfg, id)
    if type(id) ~= "string" or not M.entries[id] then return nil end
    local p = (type(cfg) == "table" and type(cfg.providers) == "table"
        and type(cfg.providers[id]) == "table") and cfg.providers[id] or {}
    local cid = p.oauth_client_id
    if type(cid) ~= "string" or cid == "" then return nil end
    if type(p.oauth_device_url) == "string" and p.oauth_device_url ~= "" then
        -- provider-auth: a full device flow needs the token endpoint too
        -- (the TUI polls it while the user authorizes). Without it the flow
        -- degrades to device-URL + paste-token (the pre-device-flow path).
        return {
            provider = id,
            device = true,
            client_id = cid,
            scope = p.oauth_scope,
            authorize_url = p.oauth_device_url,
            device_url = p.oauth_device_url,
            device_token_url = p.oauth_token_url,
        }
    end
    if type(p.oauth_token_url) ~= "string" or p.oauth_token_url == "" then
        return nil
    end
    if type(p.oauth_authorize_url) ~= "string" or p.oauth_authorize_url == "" then
        return nil
    end
    local common = _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
    if not common then return nil end
    local flow = {
        provider = id,
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

return M
