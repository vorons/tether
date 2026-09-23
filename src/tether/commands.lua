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
                        agent.add_assistant({ tool_calls = msg.tool_calls })
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

-- Live model list with the provider's static fallback.
function M.list_models(cfg, api_key)
    local ok, models = false, nil
    if api and api.list_models_live then
        ok, models = pcall(api.list_models_live, cfg, api_key or "")
    end
    if not ok then models = nil end
    if not (models and #models > 0) then
        models = {}
        if api and api.list_models then
            for _, m in ipairs(api.list_models(cfg)) do
                models[#models + 1] = { id = m, name = m }
            end
        end
    end
    return models
end

-- Session journal files for a workspace (resume picker data).
function M.list_sessions(workspace)
    if not (session and session.session_files) then return {} end
    return session.session_files(workspace) or {}
end

return M
