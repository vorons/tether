-- tether commands — session lifecycle side effects (resume/new/compact/model).
--
-- One owner for the paths app -r and the ui slash commands used to duplicate:
-- rebuild agent history from a journal, start a fresh session, compress the
-- conversation, resolve the model list. UI renders the results and writes
-- cfg._session_id at the call site; this module never touches cfg. Seeding
-- the visible transcript stays with the caller (transcript.seed) so each
-- surface owns its visible state.
local M = {}

-- Resolve a session id (explicit, or latest for the workspace), rebuild the
-- agent history from the journal, and return (session_id, messages).
function M.resume(id, workspace)
    local sid = id
    if not sid and workspace and session and session.latest then
        sid = session.latest(workspace)
    end
    if not sid then return nil end
    local messages = nil
    if session and session.resume then
        messages = session.resume(sid)
    end
    if agent and agent.clear then agent.clear() end
    if messages then
        for _, msg in ipairs(messages) do
            if msg.role == "user" then
                if agent.add_user then agent.add_user(msg.content) end
            elseif msg.role == "assistant" then
                if msg.tool_calls then
                    if agent.add_assistant then
                        agent.add_assistant({ tool_calls = msg.tool_calls,
                            text = msg.content or "" })
                    end
                else
                    if agent.add_assistant then agent.add_assistant(msg.content) end
                end
            elseif msg.role == "tool" then
                if agent.add_tool_result then
                    agent.add_tool_result(msg.tool_call_id, msg.content or "")
                end
            end
        end
    end
    return sid, messages
end

-- Create a fresh session and clear the agent; returns the session id.
function M.new(workspace, model)
    local sid
    if session and session.new_session then
        local ok, id = pcall(session.new_session, workspace, model)
        if ok then sid = id end
    end
    if agent and agent.clear then agent.clear() end
    return sid
end

-- Force-compress the agent history (threshold bypassed). Optional free-text
-- `focus` is passed to the summary request. Returns (summary_text, mode) or
-- nil when compaction is unavailable. mode: "llm" | "truncation" | "noop".
function M.compact(cfg, api_key, focus)
    if agent and agent.compact_history and agent.get_history then
        local h = agent.get_history()
        local compressed, summary, mode =
            agent.compact_history(h, cfg, api_key, focus, true)
        if mode ~= "noop" then
            for i = #h, 1, -1 do table.remove(h) end
            for _, m in ipairs(compressed) do h[#h + 1] = m end
        end
        if mode == "noop" then return "", mode end
        return summary, mode
    end
    if not (agent and agent.compress_history and agent.get_history) then
        return nil
    end
    local h = agent.get_history()
    local compressed = agent.compress_history(h, cfg)
    for i = #h, 1, -1 do table.remove(h) end
    for _, m in ipairs(compressed) do h[#h + 1] = m end
    local summary = ""
    for _, m in ipairs(h) do
        if m.role == "system" and tostring(m.content):find("summary") then
            summary = tostring(m.content)
        end
    end
    return summary, "truncation"
end

-- expand-provider-catalog: model-list cache (pi remote-catalog-provider).
-- pi shows the bundled/persisted catalog instantly and refreshes in the
-- background (4s attempt timeout, 4h interval). This TUI is single-threaded
-- (blocking read_key loop, no async transport), so the closest honest
-- equivalent: serve a fresh cache with zero network, and refresh
-- synchronously with a short timeout only when the cache is stale.
local MODELS_CACHE_TTL = 4 * 3600
local MODELS_REFRESH_TIMEOUT_S = 5

local function json()
    return _G.provider_common
        or (function()
            local chunk = loadfile("src/tether/providers/common.lua")
            return chunk and chunk()
        end)()
end

-- Test seam: cache file path.
function M._models_cache_path(home)
    local h = home
    if type(h) ~= "string" or h == "" then h = os.getenv("HOME") or "." end
    return h .. "/.tether/models_cache.json"
end

-- Pending background-fetch file for one provider (written by the fetch_bg
-- child, consumed by poll_models_refresh). Provider ids are kebab-case.
function M._models_pending_path(home, provider)
    return M._models_cache_path(home) .. "." .. (provider or "openai") .. ".pending"
end

local function read_cache(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local j = json()
    if not j then return {} end
    local ok, tbl = pcall(j.json_decode, data or "")
    if not ok or type(tbl) ~= "table" then return {} end
    return tbl
end

local function write_cache(path, tbl)
    local j = json()
    if not j then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(j.json_encode(tbl))
    f:close()
    return true
end

local function static_list(cfg)
    local models = {}
    if api and api.list_models then
        for _, m in ipairs(api.list_models(cfg)) do
            models[#models + 1] = { id = m, name = m }
        end
    end
    return models
end

local function keyless_err(cfg, provider)
    local env_name = (type(cfg) == "table" and cfg.api_key_env) or ""
    if env_name == "" then
        local p = (type(cfg) == "table" and cfg.providers
            and cfg.providers[provider]) or {}
        env_name = p.api_key_env or ""
    end
    local err = "no models for " .. provider .. ": no API key"
    if env_name ~= "" then
        err = err .. " (/login " .. provider .. " or $" .. env_name .. ")"
    else
        err = err .. " (/login " .. provider .. ")"
    end
    return err
end

-- Live model list with the provider's static fallback.
-- Fresh cache (or no key) returns instantly with no network. Otherwise the
-- stale cache (or static list) is shown immediately and one background
-- fetch is spawned when possible; without fetch_bg (tests/dev) or for
-- ambient-keyless adapters a single sync attempt capped at 5s runs instead.
-- Returns models [, bg_spawned [, err_reason]]. err_reason is set only when
-- the list is empty AND the cause is known (no key, live failure) so the
-- caller can explain the empty palette instead of showing silence.
function M.list_models(cfg, api_key)
    local provider = (type(cfg) == "table" and cfg.provider) or "openai"
    local home = (type(cfg) == "table" and cfg._auth_home) or nil
    local path = M._models_cache_path(home)
    local cache = read_cache(path)
    local entry = cache[provider]
    local now = os.time()
    if type(entry) == "table" and type(entry.models) == "table"
        and #entry.models > 0 and tonumber(entry.checked_at)
        and (now - entry.checked_at) < MODELS_CACHE_TTL then
        return entry.models
    end
    local stale = (type(entry) == "table" and type(entry.models) == "table"
        and entry.models) or nil
    local static = static_list(cfg)
    local display = ((stale and #stale > 0) and stale) or static
    -- Cooldown: a recent attempt (any outcome) serves instantly with no new
    -- network. Fresh models return as-is; a recent failure explains itself
    -- from the cached reason instead of hammering the endpoint.
    local attempted = type(entry) == "table" and tonumber(entry.checked_at)
        and (now - entry.checked_at) < MODELS_CACHE_TTL
    if attempted then
        local e = (type(entry) == "table" and entry.err) or nil
        if e == nil and (not api_key or api_key == "") then
            e = keyless_err(cfg, provider)
        end
        -- Audit: the cooldown applies regardless of what is on display.
        -- Gating on #display == 0 let native providers (non-empty static
        -- list) re-hit the endpoint on every /model open inside the TTL.
        return display, nil, e
    end
    if not api_key or api_key == "" then
        -- ambient-keyless adapters (Bedrock chain) still attempt live.
        local can_ambient = api and api._has_ambient
            and api._has_ambient(cfg) or false
        if not can_ambient then
            if #display == 0 then
                return display, nil, keyless_err(cfg, provider)
            end
            return display
        end
    end
    local spawned = false
    if api and api.refresh_models_bg then
        -- one fetch in flight at most: claim the pending path with an empty
        -- marker first (the child replaces it atomically on finish); an
        -- existing marker means a fetch runs — don't duplicate it.
        local pend = M._models_pending_path(home, provider)
        local pf = io.open(pend, "r")
        if pf then
            pf:close()
            spawned = true
        else
            local mf = io.open(pend, "w")
            if mf then
                mf:close()
                local ok, res = pcall(api.refresh_models_bg, cfg, api_key or "",
                    pend)
                spawned = (ok and res) and true or false
                if not spawned then
                    os.remove(pend)
                else
                    M._bg_pending[provider] = os.time()
                end
            end
        end
    end
    if spawned then return display, true, nil end
    do
        local models = nil
        local reason = nil
        if api and api.list_models_live then
            local ok, res, rerr = pcall(api.list_models_live, cfg, api_key or "",
                MODELS_REFRESH_TIMEOUT_S)
            if ok and type(res) == "table" and #res > 0 then models = res end
            if ok and type(rerr) == "string" and rerr ~= "" then reason = rerr end
        end
        if models then
            cache[provider] = { checked_at = now, models = models }
            write_cache(path, cache)
            return models
        end
        local ferr = nil
        if #display == 0 then
            ferr = reason and (provider .. ": " .. reason)
                or (provider .. ": listing unavailable")
        end
        cache[provider] = { checked_at = now,
            models = ((stale and #stale > 0) and stale) or {},
            err = ferr }
        write_cache(path, cache)
        if #display == 0 then
            return display, nil, ferr
        end
        -- non-empty display (static fallback): the failure reason still
        -- belongs to the cache entry so the cooldown diagnostics can use it.
        return display, nil, ferr
    end
    return display
end

local function config_module()
    local cfgmod = rawget(_G, "config")
    if not cfgmod then
        local chunk = loadfile("src/tether/config.lua")
        cfgmod = chunk and chunk() or nil
    end
    return cfgmod
end

-- Background fetches in flight: provider id → spawn time. list_models_all
-- records every spawn here so poll_models_refresh consumes ALL of them, not
-- just the active provider's file (otherwise non-active results rot).
M._bg_pending = M._bg_pending or {}

-- expand-provider-catalog: models of every provider holding a credential
-- (active first). Items carry .provider — picking one switches provider.
-- No keys anywhere → empty list with a /login hint (never silent).
-- Returns items [, bg_spawned [, err_reason]].
function M.list_models_all(cfg)
    local cfgmod = config_module()
    local ids = {}
    if cfgmod and cfgmod.providers_with_keys then
        local ok, res = pcall(cfgmod.providers_with_keys, cfg)
        if ok and type(res) == "table" then ids = res end
    end
    if #ids == 0 then
        return {}, nil, "no API keys yet — add one via /login"
    end
    local items, errs = {}, {}
    local spawned_any = false
    for _, id in ipairs(ids) do
        local c2 = cfg
        if cfgmod and cfgmod.for_provider then
            local ok, r = pcall(cfgmod.for_provider, cfg, id)
            if ok and type(r) == "table" then c2 = r end
        end
        local key = ""
        if cfgmod and cfgmod.api_key then
            local ok, k = pcall(cfgmod.api_key, c2)
            if ok and type(k) == "string" then key = k end
        end
        local ok, models, bg, er = pcall(M.list_models, c2, key)
        if ok and type(models) == "table" then
            for _, m in ipairs(models) do
                items[#items + 1] = { id = m.id, name = m.name, provider = id }
            end
            if bg then spawned_any = true end
            if type(er) == "string" and er ~= "" then
                errs[#errs + 1] = er
            end
        end
    end
    if #items == 0 then
        if spawned_any then return items, true, nil end
        if #errs == 1 then return items, nil, errs[1] end
        if #errs > 1 then return items, nil, table.concat(errs, "; ") end
        return items, nil, "no models reachable (keys exist but listings failed)"
    end
    return items, spawned_any or nil, nil
end

-- Pick up finished background fetches: the active provider plus every id
-- with a recorded spawn (a non-active provider's file would otherwise rot
-- unconsumed). Returns "updated" (at least one cache refreshed), "waiting"
-- (fetches still running), or "settled" (nothing pending / provider switch
-- / stale state — stop polling). checked_at persists on consume so failures
-- settle too.
function M.poll_models_refresh(cfg, state)
    state = state or {}
    local provider = (type(cfg) == "table" and cfg.provider) or "openai"
    if state.provider and state.provider ~= provider then return "settled" end
    if state.started and (os.time() - state.started) > 120 then
        M._bg_pending = {}
        return "settled"
    end
    local home = (type(cfg) == "table" and cfg._auth_home) or nil
    local candidates = { [provider] = true }
    for id in pairs(M._bg_pending) do candidates[id] = true end
    local updated, waiting = false, false
    for id in pairs(candidates) do
        local res = poll_one(cfg, home, id)
        if res == "updated" then
            updated = true
            M._bg_pending[id] = nil
        elseif res == "waiting" then
            waiting = true
        elseif res == "settled" then
            M._bg_pending[id] = nil
        end
    end
    if updated then return "updated" end
    if waiting then return "waiting" end
    return "settled"
end

poll_one = function(cfg, home, id)
    local pend = M._models_pending_path(home, id)
    local f = io.open(pend, "r")
    if not f then
        -- no file: a recorded spawn with no marker means the spawn failed
        -- after recording (or an external cleanup) — drop it.
        if M._bg_pending[id]
            and (os.time() - M._bg_pending[id]) > 120 then
            return "settled"
        end
        return M._bg_pending[id] and "waiting" or "settled"
    end
    local body = f:read("*a")
    -- empty marker: spawn claimed the path, the child hasn't finished.
    -- A marker older than 120s is a crashed child: drop it and settle.
    if not body or body == "" then
        f:close()
        local settled = false
        if tether and tether.stat then
            local ok, st = pcall(tether.stat, pend)
            if ok and type(st) == "table" and tonumber(st.mtime)
                and (os.time() - st.mtime) > 120 then
                settled = true
            end
        end
        if settled then
            os.remove(pend)
            return "settled"
        end
        return "waiting"
    end
    f:close()
    os.remove(pend)
    local c2 = cfg
    local cfgmod = config_module()
    if cfgmod and cfgmod.for_provider then
        local ok, r = pcall(cfgmod.for_provider, cfg, id)
        if ok and type(r) == "table" then c2 = r end
    end
    local now = os.time()
    local path = M._models_cache_path(home)
    local cache = read_cache(path)
    local models = nil
    local errmsg = nil
    if type(body) == "string" and body:match("^FETCH_FAILED") then
        errmsg = id .. ": "
            .. (body:match("^FETCH_FAILED%s*(.-)%s*$") or "request failed")
    elseif api and api._parse_models then
        local ok, res = pcall(api._parse_models, c2, body or "")
        if ok and res then models = res end
    end
    local old = cache[id]
    local old_models = (type(old) == "table" and type(old.models) == "table")
        and old.models or {}
    local fresh = ((models and #models > 0) and models) or old_models
    cache[id] = { checked_at = now, models = fresh,
        err = (#fresh == 0 and errmsg) or nil }
    write_cache(path, cache)
    return "updated"
end

-- Session journal files for a workspace (resume picker data).
function M.list_sessions(workspace)
    if not (session and session.session_files) then return {} end
    return session.session_files(workspace) or {}
end

return M
