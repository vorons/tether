-- tether turn — control facade over the agent loop.
--
-- Owns the abort seam (take/ack) and the single busy/waiting/streaming
-- begin/finish reset. UI never assigns agent.abort_requested; it calls
-- turn.abort(). External contract (agent.turn/confirm/answer_ask/continue)
-- stays for print mode and non-UI callers.
local M = {}

-- True when the UI or the host asked to stop. Two sources: the UI flag
-- (agent.abort_requested) and the host (tether.abort_requested), which stays
-- set until ack drops it so the same Ctrl+C keeps aborting in-flight work.
function M.take_abort(a)
    local mod = a or agent
    if mod and mod.abort_requested then return true end
    if tether and type(tether.abort_requested) == "function" then
        return tether.abort_requested() and true or false
    end
    return false
end
M._take_abort = M.take_abort

-- The loop has stopped for an interrupt: drop both flags so the next turn
-- is not aborted by the Ctrl+C that ended this one.
function M.ack_abort(a)
    local mod = a or agent
    if mod then mod.abort_requested = false end
    if tether and type(tether.clear_abort) == "function" then
        pcall(tether.clear_abort)
    end
end
M._ack_abort = M.ack_abort

-- UI Ctrl+C while busy: raise the interrupt; the agent loop reads it via
-- take_abort. UI must never assign agent.abort_requested directly.
function M.abort()
    if agent then agent.abort_requested = true end
end

-- Single place that turns the busy indicators on for a blocking agent call.
function M.begin(S)
    if not S then return end
    S.busy = true
    S.busy_started_at = os.time()
    S.waiting = true
    S.streaming = false
end

-- Single place that clears busy/waiting/streaming (and the retry indicator)
-- after a blocking agent call returns.
function M.finish(S)
    if not S then return end
    S.busy = false
    S.busy_started_at = nil
    S.waiting = false
    S.streaming = false
    S.retry_wait = nil
end

-- Thin pcall wrappers over the agent entry points. `before_call` runs after
-- begin (so the UI can paint the placeholder) and before the blocking call.
function M.start(S, cfg, api_key, text, on_event, before_call)
    M.begin(S)
    if before_call then before_call() end
    M.ack_abort()
    local ok, err = pcall(agent.turn, cfg, api_key, text, on_event)
    M.finish(S)
    M.ack_abort()
    return ok, err
end

function M.confirm(id, decision, cfg, on_event)
    return pcall(agent.confirm, id, decision, cfg, on_event)
end

function M.answer(id, payload, cfg, on_event)
    return pcall(agent.answer_ask, id, payload, cfg, on_event)
end

function M.continue(S, cfg, api_key, on_event, before_call)
    M.begin(S)
    if before_call then before_call() end
    local ok, err = pcall(agent.continue, cfg, api_key, on_event)
    M.finish(S)
    return ok, err
end

return M
