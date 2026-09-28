-- tether tool_dispatch — one synchronous tool call: execute, shape the
-- report, write history + journal, emit the UI event.
--
-- IN:  run_tool_call(cfg, on_event, id, name, args, projection, deps):
--        cfg/on_event/id/name/args thread through from the turn loop;
--        projection is the read-only change preview (or nil); deps is the
--        impure edge, built per call by agent:
--          execute(name, args, cfg) -> result, err,
--          summarize(name, res) -> summary text,
--          body(name, res) -> body text or nil,
--          truncate(text) -> bounded text or nil,
--          add_history(id, res) (agent history write),
--          journal(entry) (session journal write).
--      Moved verbatim from agent.lua (Phase E 5.1); agent keeps a thin
--      wrapper so the turn/confirm/answer_ask/continue contract is
--      byte-identical and all existing callers keep working.
-- OUT: the tool result table (or { error }). The result body/summary
--      rules: write/patch report the projection diff when present;
--      errors report their text; everything else uses body/summary.
-- EXAMPLE:
--      tool_dispatch.run_tool_call(cfg, on_event, "t1", "read",
--        { path = "x" }, nil, deps) --> { content = ... }
local M = {}

local function run_tool_call(cfg, on_event, id, name, args, projection, deps)
    deps = deps or {}
    local result, err = deps.execute(name, args, cfg)
    local res
    if result then
        res = result
    else
        res = { error = err or "tool failed" }
    end
    -- pretty-transcript-rendering 2.3/2.4: write and patch report their change
    -- as the applied unified diff (the same text the UI expands), with a
    -- `+N −M` summary; when no projection was available the existing body and
    -- summary are kept so a failure never claims counts it does not have.
    local body, summary
    if res.error then
        body = tostring(res.error)
        summary = nil
    elseif name == "write" and projection then
        body = projection.diff
        local word = projection.is_new and "created" or "overwritten"
        summary = string.format("+%d −%d %s", projection.add, projection.del, word)
    elseif name == "patch" and projection then
        body = projection.diff
        summary = deps.summarize(name, res)
    else
        summary = deps.summarize(name, res)
        body = deps.body(name, res)
    end
    -- fix-audit-findings 1.2: the model must see the tool's output body, not
    -- just whatever happened to live under `content` (only `read` had one).
    local history_result
    if res.error then
        history_result = { error = tostring(res.error) }
    else
        history_result = { content = deps.truncate(body) or "" }
    end
    deps.add_history(id, history_result)
    -- the journal keeps the bounded body too (summary alone lobotomized
    -- resumed turns: the model only saw "17 entries" instead of output).
    deps.journal({
        ts = os.date(), type = "tool_result",
        tool_call_id = id, name = name,
        result = res.error and { error = res.error }
            or { summary = summary, body = deps.truncate(body) or "" },
    })
    if on_event then
        on_event({
            type = "tool_result", id = id, name = name,
            error = res.error or nil,
            summary = res.error and ("✗ " .. tostring(res.error)) or summary,
            body = res.error and tostring(res.error) or body,
        })
    end
    return res
end
M.run_tool_call = run_tool_call

return M
