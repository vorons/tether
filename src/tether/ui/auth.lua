-- src/tether/ui/auth.lua — login/logout flows: provider pickers, secret
-- entry, device polling, credential submit, logout picker + confirm step.
--
-- IN:  every function takes (bag, deps, ...) — values only, no S, no
--      globals, no terminal I/O:
--        bag: the state table (S in the facade). Read/written plain fields:
--          cfg, login_provider, login_flow, login_secret ({buf} or nil),
--          palette_* (active/mode/items/sel/query/_all flags),
--          error_banner, toast, api_key, _logout_confirm, _logout_sel.
--        deps: the impure edge, built per call by the facade:
--          catalog (provider catalog or nil — ids/get/login_flow),
--          load_provider(name) -> module or nil (provider login_flow/token_exchange),
--          auth (credential store module or nil — load/set/delete,
--            device_request/device_poll/device_entry/_post_json),
--          common (provider_common or nil — url_decode/oauth_token_exchange),
--          errors (ui_copy.errors table),
--          host (tether host or nil — exec/http_stream gates),
--          note(text) (transcript system line), bump() (index invalidate),
--          apply_query() (logout-confirm back refilter).
--        Moved verbatim from ui.lua (Phase C 3.2); the facade keeps thin
--        proxies so call sites and M.* seams keep working.
-- OUT: module table { known_providers, is_known_provider, begin, cancel,
--      poll_tick, submit, logout_delete, logout_close, logout_ask_confirm,
--      logout_confirm_accept, logout_confirm_back }.
--      begin/submit return booleans; poll_tick returns
--      "pending" | "granted" | "failed" | nil. Pure S-mutation otherwise.
-- EXAMPLE:
--      auth.begin(S, deps, "openai") --> true (secret mode armed)
--      auth.poll_tick(S, deps)       --> "pending" | "granted" | ...
local M = {}

local function known_providers(catalog)
    if catalog and catalog.ids then
        return catalog.ids()
    end
    return { "openai", "anthropic", "gemini" }
end
M.known_providers = known_providers

local function is_known_provider(catalog, name)
    if type(name) ~= "string" then return false end
    if catalog and catalog.get then
        return catalog.get(name:lower()) ~= nil
    end
    return name == "openai" or name == "anthropic" or name == "gemini"
end
M.is_known_provider = is_known_provider

local function begin(bag, deps, provider)
    deps = deps or {}
    if bag.cfg and bag.cfg.non_interactive then
        bag.error_banner = "login is interactive only"
        return false
    end
    local load_provider = deps.load_provider
    local pmod = load_provider and load_provider(provider) or nil
    local flow = (pmod and pmod.login_flow and pmod.login_flow(bag.cfg)) or nil
    -- expand-provider-catalog: presets without their own adapter module get
    -- the generic catalog flow (config-sourced OAuth/device, else nil →
    -- API-key paste). Endpoints are never invented.
    local catalog = deps.catalog
    if not flow and catalog and catalog.login_flow then
        flow = catalog.login_flow(bag.cfg, provider)
    end
    bag.error_banner = nil
    bag.login_provider = provider
    bag.login_flow = flow
    -- palette-only R5: secret entry is a masked input mode, never a dialog.
    -- buf is a dedicated buffer — never S.input, never a transcript row.
    bag.login_secret = { buf = "" }
    -- Best-effort browser open (never blocks login on failure). URL itself
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
    bag._in_login_palette = nil
    -- Best-effort browser open (never blocks login on failure). URL itself
    -- stays in the hints / dialog, not the transcript.
    local host = deps.host
    if flow and flow.authorize_url and host and host.exec then
        local q = "'" .. flow.authorize_url:gsub("'", "'\\''") .. "'"
        pcall(function()
            local ok = host.exec("xdg-open " .. q .. " >/dev/null 2>&1")
            if not ok then
                host.exec("open " .. q .. " >/dev/null 2>&1")
            end
        end)
    end
    -- provider-auth: full device flow — request the device/user code pair up
    -- front. The TUI then polls the token endpoint while the user authorizes;
    -- no paste is needed (a paste still works as a manual fallback for flows
    -- without a token endpoint). Polling state rides the flow table.
    if flow and flow.device and flow.device_token_url then
        local auth_mod = deps.auth
        if auth_mod and auth_mod.device_request and host and host.http_stream then
            local ok, res, err = pcall(auth_mod.device_request,
                flow.device_url, flow.client_id, flow.scope)
            if ok and type(res) == "table" then
                flow.device_code = res.device_code
                flow.user_code = res.user_code
                flow.verification_uri = res.verification_uri or flow.device_url
                flow.poll_interval = tonumber(res.interval) or 5
                flow.poll_deadline = os.time() + (tonumber(res.expires_in) or 900)
                flow.poll_next_at = os.time() + flow.poll_interval
                if host.exec then
                    local vq = "'" .. flow.verification_uri:gsub("'", "'\\''") .. "'"
                    pcall(function()
                        local okv = host.exec("xdg-open " .. vq .. " >/dev/null 2>&1")
                        if not okv then host.exec("open " .. vq .. " >/dev/null 2>&1") end
                    end)
                end
            else
                -- device endpoint unreachable: degrade to the paste path
                local errors = deps.errors or {}
                flow.device_request_error = tostring(err or errors.device_request_failed)
            end
        end
    end
    return true
end
M.begin = begin

local function cancel(bag)
    bag.login_provider = nil
    bag.login_flow = nil
    bag.login_secret = nil
    -- leave secret-hint palette: back to command mode
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
    bag._in_login_palette = nil
end
M.cancel = cancel

-- provider-auth: one device-flow poll tick, called from the paint path while
-- login secret mode with a device flow is active. Paces itself via
-- flow.poll_next_at; returns "pending" | "granted" | "failed" | nil.
local function poll_tick(bag, deps)
    deps = deps or {}
    local flow = bag and bag.login_flow
    if not (flow and flow.device and flow.device_code and flow.device_token_url) then
        return nil
    end
    local errors = deps.errors or {}
    if os.time() >= (flow.poll_deadline or 0) then
        bag.error_banner = errors.device_expired
        cancel(bag)
        return "failed"
    end
    if os.time() < (flow.poll_next_at or 0) then return "pending" end
    flow.poll_next_at = os.time() + (flow.poll_interval or 5)
    local auth_mod = deps.auth
    if not (auth_mod and auth_mod.device_poll) then return nil end
    local ok, res, perr = pcall(auth_mod.device_poll,
        flow.device_token_url, flow.client_id, flow.device_code)
    if not ok or res == nil then
        -- transport hiccup: keep polling until the deadline
        return "pending"
    end
    if type(res) == "table" and type(res.access_token) == "string"
        and res.access_token ~= "" then
        local entry = auth_mod.device_entry and auth_mod.device_entry(res, bag.login_provider)
        if entry and auth_mod.set then
            auth_mod.set(nil, bag.login_provider, entry)
        end
        if bag.cfg and ((bag.cfg.provider or "openai") == bag.login_provider) then
            bag.api_key = res.access_token
            bag.cfg.api_key = res.access_token
        end
        if deps.note then
            deps.note("→ login " .. tostring(bag.login_provider)
                .. ": device flow authorized")
        end
        if deps.bump then deps.bump() end
        bag.error_banner = nil
        cancel(bag)
        return "granted"
    end
    local etype = type(res) == "table" and res.error or nil
    if etype == "authorization_pending" or etype == "slow_down" then
        if etype == "slow_down" then
            flow.poll_interval = (flow.poll_interval or 5) + 5
        end
        return "pending"
    end
    bag.error_banner = errors.device_failed_prefix .. tostring(etype or perr or "unknown")
    cancel(bag)
    return "failed"
end
M.poll_tick = poll_tick

-- Shared store path for secret-mode Enter: OAuth code/redirect vs bare API key.
local function submit(bag, deps, raw)
    deps = deps or {}
    local errors = deps.errors or {}
    local value = (type(raw) == "string" and raw:match("^%s*(.-)%s*$")) or ""
    if value == "" then return false end
    local provider = bag.login_provider
    local flow = bag.login_flow
    if not provider then return false end
    bag.login_provider = nil
    bag.login_flow = nil
    bag.login_secret = nil
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
    bag._in_login_palette = nil

    local auth_mod = deps.auth

    local code = nil
    if flow and not flow.device then
        code = value:match("[?&]code=([^&%s]+)")
        if not code and not value:match("^https?://") then
            local looks_key = value:match("^sk[%-%_]")
                or value:match("^AIza")
                or value:match("^xai")
                or value:match("^gsk_")
            if not looks_key and #value >= 4 and #value <= 512
                and not value:find("%s") then
                code = value
            end
        end
    end

    -- expand-provider-catalog: device flow — the pasted value IS the access
    -- token (authorized out-of-band at flow.device_url); no exchange.
    if flow and flow.device then
        local okd = auth_mod and auth_mod.set and auth_mod.set(nil, provider, {
            kind = "oauth",
            access_token = value,
        })
        if not okd then
            bag.error_banner = errors.login_store_failed
            return false
        end
        if bag.cfg and ((bag.cfg.provider or "openai") == provider) then
            bag.api_key = value
            bag.cfg.api_key = value
        end
        if deps.note then deps.note("→ login " .. provider .. ": oauth token stored") end
        if deps.bump then deps.bump() end
        bag.error_banner = nil
        return true
    end

    if code and flow then
        local ccommon = deps.common
        if ccommon and ccommon.url_decode then
            code = ccommon.url_decode(code)
        end
        local load_provider = deps.load_provider
        local pmod = load_provider and load_provider(provider) or nil
        local post = auth_mod and auth_mod._post_json
        -- expand-provider-catalog: presets without their own module share
        -- the generic OAuth exchange.
        local exchange = (pmod and pmod.token_exchange)
            or (ccommon and ccommon.oauth_token_exchange)
        local entry = exchange and exchange(post, flow, code, os.time())
        if not entry then
            bag.error_banner = errors.oauth_exchange_failed
            bag.login_provider = provider
            bag.login_flow = flow
            -- re-enter secret mode (palette-only)
            bag.login_secret = { buf = "" }
            return false
        end
        local ok = auth_mod and auth_mod.set and auth_mod.set(nil, provider, entry)
        if not ok then
            bag.error_banner = errors.login_store_failed
            return false
        end
        if bag.cfg and ((bag.cfg.provider or "openai") == provider) then
            bag.api_key = entry.access_token
            bag.cfg.api_key = entry.access_token
        end
        if deps.note then deps.note("→ login " .. provider .. ": oauth token stored") end
        if deps.bump then deps.bump() end
        bag.error_banner = nil
        return true
    end

    local ok = auth_mod and auth_mod.set and auth_mod.set(nil, provider, {
        kind = "api_key",
        access_token = value,
    })
    if not ok then
        bag.error_banner = errors.login_store_failed
        return false
    end
    if bag.cfg and ((bag.cfg.provider or "openai") == provider) then
        bag.api_key = value
        bag.cfg.api_key = value
    end
    if deps.note then deps.note("→ login " .. provider .. ": credential stored") end
    if deps.bump then deps.bump() end
    bag.error_banner = nil
    return true
end
M.submit = submit

-- logout-picker: delete one stored credential and confirm with a
-- transcript/system line (provider name only — never token material).
local function logout_delete(bag, deps, provider)
    deps = deps or {}
    bag.login_provider = nil
    bag.login_flow = nil
    local auth_mod = deps.auth
    if auth_mod and auth_mod.delete then
        auth_mod.delete(nil, provider)
    end
    if deps.note then
        deps.note("→ logout " .. provider .. ": stored credential removed")
    end
    if deps.bump then deps.bump() end
end
M.logout_delete = logout_delete

-- logout-confirm: both steps of the picker are closed from one place, so no
-- exit path can leave the confirmation state behind.
local function logout_close(bag)
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
    bag._in_logout_palette = nil
    bag.palette_query = nil
    bag._palette_all = nil
    bag._logout_confirm = nil
    bag._logout_sel = nil
end
M.logout_close = logout_close

-- logout-confirm D1: picking a provider switches the shared palette to the
-- deletion step instead of deleting. S._palette_all and S.palette_query stay
-- untouched — the step owns no filter buffer (D2), and backing out rebuilds
-- the list from that snapshot rather than re-reading the store (D3).
local function logout_ask_confirm(bag, provider)
    if not provider then return end
    bag._logout_confirm = provider
    bag._logout_sel = bag.palette_sel
    bag.palette_mode = "logout-confirm"
    bag.palette_items = {
        { label = "yes", desc = "delete " .. provider .. "'s stored key", accept = true },
        { label = "no", desc = "keep " .. provider .. " logged in" },
    }
    bag.palette_sel = 1
end
M.logout_ask_confirm = logout_ask_confirm

-- The accepted row: close, then delete through the single writer.
local function logout_confirm_accept(bag, deps)
    deps = deps or {}
    local provider = bag._logout_confirm
    logout_close(bag)
    if provider then logout_delete(bag, deps, provider) end
end
M.logout_confirm_accept = logout_confirm_accept

-- Keep row, `n` or Esc: back to the provider list with the query, the ranked
-- rows and the highlight exactly as the step found them.
local function logout_confirm_back(bag, deps)
    deps = deps or {}
    bag.palette_mode = "logout"
    bag._logout_confirm = nil
    local sel = bag._logout_sel or 1
    bag._logout_sel = nil
    if deps.apply_query then deps.apply_query() end
    if sel < 1 or sel > #bag.palette_items then sel = 1 end
    bag.palette_sel = sel
end
M.logout_confirm_back = logout_confirm_back

return M
