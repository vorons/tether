-- tether M4: agent — LLM loop with system prompt, tool dispatch, and confirmations
local M = {}

-- fix-audit-findings 3.9: the hand-rolled JSON helpers now live once, in
-- providers/common.lua. The C host exposes it as the `provider_common` global
-- (loaded before every core module); the loadfile fallback keeps development
-- runs and `lua tests/lua_tests.lua` working.
local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "agent: cannot load provider_common")
local sse_unescape = common.json_unescape
local json_parse = common.json_decode

-- pretty-transcript-rendering: the diff engine is a global in the built
-- binary and a loadfile fallback for development/plain-lua test runs.
local diff_mod = _G.diff
    or (function()
        local chunk = loadfile("src/tether/diff.lua")
        return chunk and chunk()
    end)()

-- add-retry-and-continuation: the retry policy is a pure module — a global in
-- the built binary and a loadfile fallback for development/plain-lua runs.
local retry = _G.retry
    or (function()
        local chunk = loadfile("src/tether/retry.lua")
        return chunk and chunk()
    end)()
assert(retry, "agent: cannot load retry")

-- add-ask-tool: the structured-question rules (normalisation, answer payload,
-- transcript summary) live in a pure module — a global in the built binary and
-- a loadfile fallback for development/plain-lua runs.
local ask = _G.ask
    or (function()
        local chunk = loadfile("src/tether/ask.lua")
        return chunk and chunk()
    end)()
assert(ask, "agent: cannot load ask")

-- deepen-core-modules cut 3: pure confirmation policy — a global in the built
-- binary and a loadfile fallback for development/plain-lua runs.
local confirm_policy = _G.confirm_policy
    or (function()
        local chunk = loadfile("src/tether/confirm_policy.lua")
        return chunk and chunk()
    end)()
assert(confirm_policy, "agent: cannot load confirm_policy")

-- deepen-core-modules cut 5: turn facade owns the abort seam; agent keeps
-- M.abort_requested as the flag storage and the four entry points for
-- print mode / non-UI callers.
local turn_mod = _G.turn
    or (function()
        local chunk = loadfile("src/tether/turn.lua")
        return chunk and chunk()
    end)()
assert(turn_mod, "agent: cannot load turn")

-- Bound on a projection's read of the previous content (same bound `read` uses).
local PREVIEW_READ_MAX = 1024 * 1024

M.history = {}
M.pending = nil            -- confirmation queue for the current tool-call step
M.session_approved = {}    -- "tool:path" approved for the rest of the session
M.abort_requested = false  -- §6.6: Ctrl+C during stream

local system_prompt = [==[
You are tether, a code assistant running inside a terminal.

Available tools:
- read(path, offset?, limit?) — read file contents
- write(path, content) — create/overwrite file
- list(path?) — list directory entries
- glob(pattern, path?) — find files by glob
- grep(pattern, path?, glob?, ignore_case?, max_results?) — search text in files
- run(command, cwd?, timeout?) — run shell command via /bin/sh -c
- patch(patch) — apply unified diff, strictly
- ask(questions) — ask the user to choose: [{question, options:[{label, description?}], id?, description?, multi?, recommended?}]

When a decision belongs to the user (which option, which scope, which
constraint), ask instead of guessing. When the user asks you to inspect or edit
code, use these tools.
Work in the current directory.
Outside workspace, write/patch/run require user confirmation.
]==]

-- Exposed so context.lua can reuse the exact built-in base prompt (single source).
M.builtin_prompt = system_prompt

function M.add_user(text)
    table.insert(M.history, { role = "user", content = text })
end

function M.add_assistant(content)
    table.insert(M.history, { role = "assistant", content = content })
end

function M.add_tool_result(tool_call_id, result)
    table.insert(M.history, {
        role = "tool",
        tool_call_id = tool_call_id,
        content = type(result) == "table" and (result.content or result.error or "") or tostring(result or ""),
    })
end

function M.get_history()
    return M.history
end

function M.clear()
    M.history = {}
    M.pending = nil
    M.session_approved = {}
    M.retry_state = nil
end

-- --- session journal (design §10) -------------------------------------------
local function slog(cfg, event)
    if not (cfg and cfg._session_id and session and session.append) then return end
    pcall(session.append, cfg._session_id, event)
end

local function log_message(cfg, role, content)
    slog(cfg, { ts = os.date(), type = "message", role = role, content = content })
end

-- --- tool summaries (design §6.5) -------------------------------------------
local function fmt_ms(ms)
    if ms ~= nil then
        if ms < 1000 then return ms .. " ms" end
        return string.format("%.1f s", ms / 1000)
    end
    return ""
end

local function tool_summary(name, result)
    if not result then return "" end
    if name == "read" then
        return (result.line_count or 0) .. " стр."
    elseif name == "list" then
        return (result.count or 0) .. " записей"
    elseif name == "glob" then
        return (result.count or 0) .. " файлов"
    elseif name == "grep" then
        return (result.count or 0) .. " совп."
    elseif name == "run" then
        return "exit " .. tostring(result.exit_code or "?") .. ", " .. fmt_ms(result.elapsed_ms)
    elseif name == "write" then
        return "+" .. tostring(result.bytes or 0) .. " B"
    elseif name == "patch" then
        return "+" .. tostring(result.add or 0) .. " −" .. tostring(result.del or 0)
    end
    return ""
end

local TOOL_BODY_MAX = 16 * 1024

-- 3.5: bound the body forwarded to the model so one large result cannot blow
-- the context budget; the marker mirrors the AGENTS.md truncation style.
local function truncate_body(body)
    if type(body) ~= "string" then return nil end
    if #body > TOOL_BODY_MAX then
        return body:sub(1, TOOL_BODY_MAX) .. "\n…(truncated)"
    end
    return body
end

local function tool_body(name, result)
    if not result or result.error then return nil end
    if name == "read" then return result.content end
    if name == "run" then return result.output end
    if name == "list" then
        local parts = {}
        for _, e in ipairs(result.entries or {}) do parts[#parts + 1] = e end
        return table.concat(parts, "\n")
    end
    if name == "glob" then
        local parts = {}
        for _, f in ipairs(result.files or {}) do parts[#parts + 1] = f end
        return table.concat(parts, "\n")
    end
    if name == "grep" then
        local parts = {}
        for _, m in ipairs(result.matches or {}) do
            parts[#parts + 1] = string.format("%s:%d: %s", m.path, m.line or 0, m.text or "")
        end
        return table.concat(parts, "\n")
    end
    if name == "write" then return result.path end
    if name == "patch" then
        -- fix-audit-findings 1.2: patch has no single body; report what applied
        local parts = {}
        for _, a in ipairs(result.applied or {}) do
            parts[#parts + 1] = string.format("%s  +%d −%d", a.file or "?", a.add or 0, a.del or 0)
        end
        if result.files then
            parts[#parts + 1] = string.format("%d file(s), +%d −%d",
                result.files, result.add or 0, result.del or 0)
        end
        return #parts > 0 and table.concat(parts, "\n") or nil
    end
    return nil
end

local function execute_tool(name, args, cfg)
    -- 1.3: every tool receives cfg so -w/config.workspace applies uniformly
    if name == "read" then return tools.read(args, cfg)
    elseif name == "write" then return tools.write(args, cfg)
    elseif name == "list" then return tools.list(args, cfg)
    elseif name == "glob" then return tools.glob(args, cfg)
    elseif name == "grep" then return tools.grep(args, cfg)
    elseif name == "run" then return tools.run(args, cfg)
    elseif name == "patch" then return tools.patch(args.patch or args, cfg)
    else return nil, "unknown tool: " .. name
    end
end

local path_of = confirm_policy.path_of
local patch_target_path = confirm_policy.patch_target_path

-- pretty-transcript-rendering 2.2: a read-only projection of what a write or
-- patch will change. Resolved through the tools helpers, inside the workspace,
-- bounded (1 MiB), never written, never journalled. Any failure returns nil so
-- the call itself proceeds unchanged.
local function projection_for(tool_name, args, cfg)
    if not (diff_mod and tools) then return nil end
    args = args or {}
    if tool_name == "write" then
        local target = args.path
        if type(target) ~= "string" or target == "" then return nil end
        local abs = tools._resolve(target, cfg)
        if not tools._within(abs, cfg) then return nil end
        local st = tether.stat and tether.stat(abs) or nil
        if st and st.is_dir then return nil end
        if st and st.size and st.size > PREVIEW_READ_MAX then return nil end
        local rel = tools._to_rel(abs, cfg)
        local prior, is_new = "", false
        if st then
            local f = io.open(abs, "rb")
            if not f then return nil end
            local data = f:read(PREVIEW_READ_MAX + 1) or ""
            f:close()
            if #data > PREVIEW_READ_MAX then return nil end
            prior = data
        else
            is_new = true
        end
        local old_label = is_new and "/dev/null" or ("a/" .. rel)
        local new_label = "b/" .. rel
        local text, counts = diff_mod.unified(prior, args.content or "", old_label, new_label)
        return { path = rel, kind = is_new and "new" or "overwrite",
                 diff = text, add = counts.add, del = counts.del,
                 before = prior, is_new = is_new }
    elseif tool_name == "patch" then
        local diffstr = args.patch
        if type(diffstr) ~= "string" or diffstr == "" then return nil end
        local target = patch_target_path(args)
        if not target then return nil end
        local abs = tools._resolve(target, cfg)
        if not tools._within(abs, cfg) then return nil end
        local add, del = 0, 0
        for line in diffstr:gmatch("[^\n]*") do
            local p = line:sub(1, 1)
            if p == "+" and line:sub(1, 3) ~= "+++" then add = add + 1
            elseif p == "-" and line:sub(1, 3) ~= "---" then del = del + 1 end
        end
        return { path = tools._to_rel(abs, cfg), kind = "patch",
                 diff = diffstr, add = add, del = del }
    end
    return nil
end

local should_confirm = confirm_policy.should_confirm
local approve_key = confirm_policy.approve_key
local check_auto_approve = confirm_policy.check_auto_approve

local function is_session_approved(tool_name, args)
    return confirm_policy.is_session_approved(tool_name, args, M.session_approved)
end

-- Design §6.10: [A] always persists to config with a dated comment.
-- We keep it in a machine-managed side file that config.load merges,
-- instead of rewriting the user's hand-written config.lua.
local function persist_auto_approve(tool_name, args, cfg)
    local home = os.getenv("HOME") or ""
    local path = home .. "/.tether/auto_approve.lua"
    local dir_ok = tether.mkdirp(home .. "/.tether") ~= nil
    if not dir_ok then return end
    local pattern = "^" .. tool_name .. ":" .. path_of(args):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "$"
    local f = io.open(path, "r")
    local entries = {}
    if f then
        local data = f:read("*a")
        f:close()
        for e in data:gmatch('"([^"]+)"') do
            entries[#entries + 1] = e
        end
    end
    for _, e in ipairs(entries) do
        if e == pattern then return end -- already present
    end
    entries[#entries + 1] = pattern
    local w = io.open(path, "w")
    if not w then return end
    w:write("-- added by tether ([A] always) on " .. os.date("%Y-%m-%d") .. "\nreturn {\n")
    for _, e in ipairs(entries) do
        w:write('  "' .. e .. '",\n')
    end
    w:write("}\n")
    w:close()
    if cfg then
        cfg.auto_approve = cfg.auto_approve or {}
        table.insert(cfg.auto_approve, pattern)
    end
end

-- Tool-call arguments arrive raw (still JSON-escaped). Exactly one unescape
-- runs over the FULL assembled string (a chunk boundary can split an escape
-- sequence), then the shared JSON decoder sees valid JSON. Both helpers live
-- in providers/common.lua (fix-audit-findings 3.9).
local function parse_args(args_str)
    if not args_str or args_str == "" then return {} end
    -- exactly one SSE-layer unescape over the full assembled string (M7/D2b)
    local ok, result = pcall(json_parse, sse_unescape(args_str))
    if ok and type(result) == "table" then return result end
    return {}
end

local function estimate_tokens(history)
    local total = 0
    for _, m in ipairs(history) do
        local c = m.content
        if type(c) == "string" then total = total + #c / 4
        elseif type(c) == "table" then
            for _, tc in ipairs(c) do
                total = total + #(tc["function"] and (tc["function"].arguments or "") or "") / 4
            end
        end
    end
    return math.ceil(total)
end

local function should_summarize(history, cfg)
    local max_tokens = (cfg.context and cfg.context.max_tokens) or 32768
    local threshold  = (cfg.context and cfg.context.summarize_at) or 0.7
    return estimate_tokens(history) > threshold * max_tokens
end

-- Compress old history: keep system + last N messages, summarize the rest
local function compress_history(history)
    local N = 4
    if #history <= N + 1 then return history end
    local system = history[1]
    local keep_from = math.max(2, #history - N + 1)
    while keep_from > 2 and history[keep_from].role == "tool" do
        keep_from = keep_from - 1
    end
    local old = {}
    for i = 2, keep_from - 1 do old[#old + 1] = history[i] end
    local keep = {}
    for i = keep_from, #history do keep[#keep + 1] = history[i] end
    local parts = {}
    for _, m in ipairs(old) do
        local c = m.content
        if type(c) == "string" then
            parts[#parts + 1] = m.role .. ": " .. (c:sub(1, 200) .. (c:len() > 200 and "…" or ""))
        end
    end
    local summary = table.concat(parts, "\n")
    local new_history = { system }
    new_history[#new_history + 1] = { role = "system", content = "── summary ──\n" .. summary }
    for _, m in ipairs(keep) do new_history[#new_history + 1] = m end
    return new_history
end

-- Run one tool call: execute, log, report to UI. Returns result table or {error=...}.
-- `projection` is the read-only change projection computed at call start (nil
-- when none could be computed); it supplies the previous content for the
-- applied diff without a second file read.
local function run_tool_call(cfg, on_event, id, name, args, projection)
    local result, err = execute_tool(name, args, cfg)
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
        local word = projection.is_new and "создан" or "перезаписан"
        summary = string.format("+%d −%d %s", projection.add, projection.del, word)
    elseif name == "patch" and projection then
        body = projection.diff
        summary = tool_summary(name, res)
    else
        body = tool_body(name, res)
        summary = tool_summary(name, res)
    end
    -- fix-audit-findings 1.2: the model must see the tool's output body, not
    -- just whatever happened to live under `content` (only `read` had one).
    local history_result
    if res.error then
        history_result = { error = tostring(res.error) }
    else
        history_result = { content = truncate_body(body) or "" }
    end
    M.add_tool_result(id, history_result)
    slog(cfg, {
        ts = os.date(), type = "tool_result",
        tool_call_id = id, name = name,
        result = res.error and { error = res.error } or { summary = summary },
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

-- add-ask-tool: report a tool result for a call the pending queue resolved
-- itself — a non-interactive or malformed `ask`, or one the UI answered. The
-- same three writes run_tool_call performs: history, journal, UI event.
local function record_ask_result(cfg, on_event, call, payload, summary, is_error)
    if is_error then
        M.add_tool_result(call.id, { error = payload })
    else
        M.add_tool_result(call.id, { content = payload })
    end
    slog(cfg, {
        ts = os.date(), type = "tool_result", tool_call_id = call.id, name = call.name,
        result = is_error and { error = payload } or { summary = summary, body = payload },
    })
    if on_event then
        on_event({
            type = "tool_result", id = call.id, name = call.name,
            error = is_error and payload or nil,
            summary = is_error and ("✗ " .. payload) or summary,
            body = payload,
        })
    end
end

-- Advance the pending confirmation queue: emit the next needed confirmation,
-- execute everything that doesn't need one. Returns true when queue is empty.
-- M7/D3: emission is idempotent — a call's confirmation is emitted at most
-- once (call.confirm_emitted), so repeated drive_pending (ui calls continue
-- freely) never re-shows the same menu.
local function drive_pending(cfg, on_event)
    local p = M.pending
    if not p then return true end
    while p.idx <= #p.calls do
        local call = p.calls[p.idx]
        if call.done then
            p.idx = p.idx + 1
        elseif call.name == "ask" then
            -- add-ask-tool: the question tool never executes locally. It parks
            -- the turn for the user's answer, or degrades to an error result
            -- when there is nobody to ask or nothing answerable.
            local questions = call.questions
            if not questions then
                questions = ask.normalize(call.args)
                call.questions = questions
            end
            if cfg and cfg.non_interactive then
                record_ask_result(cfg, on_event, call, ask.NO_INTERACTIVE_USER, nil, true)
                call.done = true
                p.idx = p.idx + 1
            elseif #questions == 0 then
                record_ask_result(cfg, on_event, call, ask.NOTHING_ASKABLE, nil, true)
                call.done = true
                p.idx = p.idx + 1
            elseif call.ask_emitted then
                -- already waiting on the user for this call; stay parked
                return false
            else
                call.ask_emitted = true
                if on_event then
                    on_event({ type = "ask", id = call.id, questions = questions })
                end
                return false
            end
        elseif not should_confirm(call.name, call.args, cfg)
            or check_auto_approve(call.name, call.args, cfg)
            or is_session_approved(call.name, call.args) then
            run_tool_call(cfg, on_event, call.id, call.name, call.args, call.projection)
            call.done = true
            p.idx = p.idx + 1
        elseif call.confirm_emitted then
            -- already waiting on the user for this call; stay parked
            return false
        else
            -- needs user confirmation
            call.confirm_emitted = true
            on_event({
                type = "confirmation",
                details = { { id = call.id, name = call.name, args = call.args } },
            })
            return false
        end
    end
    M.pending = nil
    return true
end

-- --- retry, continuation and per-turn state (add-retry-and-continuation) ---
-- The turn owns the backoff schedule: api.stream makes one attempt and
-- reports a classified failure, and everything below decides what that
-- means. See src/tether/retry.lua for the policy itself.

-- Per-turn retry state. Created by M.turn and kept across M.continue so the
-- budget and the continuation flags belong to one user turn.
function M.reset_retry_state()
    M.retry_state = retry.new_state()
    M.retry_state.iterations = 0
    return M.retry_state
end

-- True when the user asked to stop the turn. Two sources: the UI sets
-- M.abort_requested when its key handler reads Ctrl+C, and the host reports one
-- that arrived while the turn was blocked — during a turn the UI is not reading
-- stdin at all, so the host watches it itself and hands the interrupt over
-- through tether.abort_requested(). The host call also drains bytes typed
-- during the turn, so nothing is lost.
--
-- The host flag stays set until ack_abort() clears it: the same Ctrl+C also
-- aborts an in-flight transfer (the libcurl progress callback reads it), and
-- only the turn knows when the abort has actually been handled.
--
-- Implementation lives in turn.lua (cut 5); these locals keep agent's internal
-- call sites and the M._take_abort / M._ack_abort test seams working.
local function take_abort()
    return turn_mod.take_abort(M)
end
M._take_abort = take_abort

local function ack_abort()
    turn_mod.ack_abort(M)
end
M._ack_abort = ack_abort

-- Sleep in slices so Ctrl+C is honored during a wait of up to a minute.
-- Returns true when the wait was interrupted by an abort. tether.sleep itself
-- returns as soon as input arrives, so the check below usually fires well
-- before the slice elapses.
local function interruptible_sleep(seconds)
    local elapsed = 0
    local total = tonumber(seconds) or 0
    while elapsed < total do
        local step = total - elapsed
        if step > 0.25 then step = 0.25 end
        pcall(tether.sleep, step)
        elapsed = elapsed + step
        if take_abort() then return true end
    end
    return false
end

-- Undo a continuation chain's hidden history edits: the folded nudge goes back
-- to the user's original text, and the hidden assistant/continuation turns
-- disappear so the answer can be stored as one assistant message.
local function collapse_segments(pending)
    if not pending then return end
    if pending.restore then
        local m = M.history[pending.restore.index]
        if m then m.content = pending.restore.content end
    end
    for i = #M.history, pending.start + 1, -1 do
        table.remove(M.history, i)
    end
end

-- An answer interrupted mid-continuation: collapse it and journal the part
-- that was produced, so a resume keeps it.
local function collapse_partial_answer(cfg, pending, merged)
    local text = table.concat(merged)
    if not pending or text == "" then return end
    collapse_segments(pending)
    table.insert(M.history, { role = "assistant", content = text })
    log_message(cfg, "assistant", text)
end

-- One provider attempt: stream, collect deltas and tool calls, remember why the
-- model stopped. Deltas carry the attempt index so a renderer can drop exactly
-- the rows of an attempt that gets retried.
local function run_attempt(cfg, api_key, attempt, on_event)
    local tool_calls, ordered, text_acc = {}, {}, {}
    local stop_reason = "other"
    local ok, failure = api.stream(cfg, api_key, M.history, function(ev)
        if ev.type ~= "usage" and take_abort() then return end
        if ev.type == "text_delta" then
            text_acc[#text_acc + 1] = ev.text
            if on_event then ev.attempt = attempt; on_event(ev) end
        elseif ev.type == "reasoning_delta" then
            if on_event then ev.attempt = attempt; on_event(ev) end
        elseif ev.type == "usage" then
            if on_event then on_event(ev) end
        elseif ev.type == "done" then
            -- the provider's last reported reason for this request
            stop_reason = ev.reason or "other"
        end
        if ev.type == "tool_call_start" then
            tool_calls[ev.id] = { id = ev.id, name = ev.name, arguments = "" }
            ordered[#ordered + 1] = ev.id
        elseif ev.type == "tool_call_delta" then
            if tool_calls[ev.id] then
                tool_calls[ev.id].arguments = tool_calls[ev.id].arguments .. (ev.arguments or "")
            end
        end
    end)
    return { text = table.concat(text_acc), tool_calls = tool_calls,
             ordered = ordered, stop_reason = stop_reason }, ok, failure
end

-- Run attempts until this iteration's answer is complete: retry a failed
-- attempt per the policy, continue a truncated answer, nudge an empty one.
-- On success returns true plus { text, tool_calls, ordered, stop_reason }.
-- Otherwise returns false plus the failure table or "aborted"/"empty".
local function run_answer_segments(cfg, api_key, on_event, state, max_iterations)
    local p = retry.policy(cfg)
    local merged = {}
    local pending = nil

    while true do
        if take_abort() then
            ack_abort()
            if on_event then on_event({ type = "aborted" }) end
            return false, "aborted"
        end

        local result, ok, failure = run_attempt(cfg, api_key, state.attempt, on_event)

        -- An abort during the transfer arrives as a failed attempt; stop here so
        -- it is never mistaken for something worth retrying.
        if not ok and take_abort() then
            collapse_partial_answer(cfg, pending, merged)
            ack_abort()
            if on_event then on_event({ type = "aborted" }) end
            return false, "aborted"
        end

        if ok then
            if result.text ~= "" then merged[#merged + 1] = result.text end
            local action = retry.continuation_action(state, result.stop_reason,
                result.text ~= "", #result.ordered > 0)
            -- a continuation costs one iteration, like a tool round
            if action and state.iterations >= max_iterations then action = nil end
            if action == "length" or action == "empty" then
                if on_event then on_event({ type = "continuation", kind = action }) end
                if not pending then pending = { start = #M.history } end
                if action == "length" then
                    -- the model needs its own partial answer to resume from
                    if result.text ~= "" then
                        table.insert(M.history,
                            { role = "assistant", content = result.text })
                    end
                    table.insert(M.history,
                        { role = "user", content = retry.continuation_text("length") })
                else
                    -- An empty answer left no assistant turn to follow, so the
                    -- nudge is folded into the pending user message: providers
                    -- reject two consecutive user-role turns (Anthropic).
                    local prev = M.history[#M.history]
                    if prev and prev.role == "user" and type(prev.content) == "string" then
                        pending.restore = { index = #M.history, content = prev.content }
                        prev.content = prev.content .. "\n\n" .. retry.continuation_text("empty")
                    else
                        table.insert(M.history,
                            { role = "user", content = retry.continuation_text("empty") })
                    end
                end
                state.iterations = state.iterations + 1
                state.attempt = state.attempt + 1
            elseif action == "empty_giveup" then
                collapse_segments(pending)
                if on_event then
                    on_event({ type = "error", kind = "empty",
                               message = retry.EMPTY_GIVEUP_MESSAGE })
                end
                return false, "empty"
            else
                -- the answer is complete: keep the hidden edits out of history
                -- and let the caller store the single merged entry
                collapse_segments(pending)
                return true, { text = table.concat(merged),
                               tool_calls = result.tool_calls,
                               ordered = result.ordered,
                               stop_reason = result.stop_reason }
            end
        else
            -- A failed attempt contributes nothing to the conversation.
            local verdict = retry.verdict(p, state, failure)
            if verdict.action ~= "retry" then
                collapse_partial_answer(cfg, pending, merged)
                if on_event then
                    on_event({ type = "error", kind = failure and failure.kind,
                               message = retry.terminal_message(failure, state.attempt) })
                end
                return false, failure
            end
            if on_event then
                on_event({ type = "retry", attempt = state.attempt, delay = verdict.delay,
                           reason = verdict.reason or (failure and failure.reason),
                           kind = verdict.kind })
            end
            if interruptible_sleep(verdict.delay) then
                collapse_partial_answer(cfg, pending, merged)
                ack_abort()
                if on_event then on_event({ type = "aborted" }) end
                return false, "aborted"
            end
            state.attempt = state.attempt + 1
        end
    end
end

local function main_loop(cfg, api_key, on_event)
    local max_iterations = 50
    local state = M.retry_state or M.reset_retry_state()

    while state.iterations < max_iterations do
        state.iterations = state.iterations + 1
        if take_abort() then
            ack_abort()
            if on_event then on_event({ type = "aborted" }) end
            return false
        end

        if should_summarize(M.history, cfg) then
            M.history = compress_history(M.history)
            if on_event then on_event({ type = "context_compressed" }) end
        end

        local ok, result = run_answer_segments(cfg, api_key, on_event, state, max_iterations)
        if not ok then
            return false
        end

        local tool_calls = result.tool_calls
        local ordered = result.ordered

        if next(tool_calls) == nil then
            -- No tool calls: keep the assistant text in history
            if result.text ~= "" then
                M.add_assistant(result.text)
                log_message(cfg, "assistant", result.text)
            end
            return true
        end

        -- Assistant message with tool_calls goes to history BEFORE results (OpenAI contract)
        local tc_list = {}
        for _, id in ipairs(ordered) do
            local tc = tool_calls[id]
            tc_list[#tc_list + 1] = {
                id = tc.id,
                type = "function",
                ['function'] = { name = tc.name, arguments = tc.arguments },
            }
        end
        -- 1.2: keep any text the model emitted alongside its tool calls
        local assistant_text = result.text or ""
        M.add_assistant({ tool_calls = tc_list, text = assistant_text })
        slog(cfg, { ts = os.date(), type = "message", role = "assistant",
                    content = assistant_text, tool_calls = tc_list })

        -- Build the queue of calls for this step
        local calls = {}
        for _, id in ipairs(ordered) do
            local tc = tool_calls[id]
            local args = parse_args(tc.arguments)
            -- 2.1/2.2: carry the parsed args on the event and, for write/patch,
            -- a read-only projection of the change the call is about to make.
            local projection = projection_for(tc.name, args, cfg)
            calls[#calls + 1] = { id = tc.id, name = tc.name, args = args,
                                  arguments_str = tc.arguments, projection = projection }
            if on_event then
                on_event({ type = "tool_call_start", id = tc.id, name = tc.name,
                           args = args, projection = projection })
            end
            slog(cfg, { ts = os.date(), type = "tool_call",
                        tool_call_id = tc.id, name = tc.name, args = args })
        end

        M.pending = { calls = calls, idx = 1 }
        local all_done = drive_pending(cfg, on_event)
        if all_done then
            -- everything executed; loop back to the LLM
        else
            -- waiting for the user; ui resumes us via M.continue
            return true
        end
    end
    return true
end

function M.turn(cfg, api_key, user_text, on_event, skip_user)
    if not (M.history[1] and M.history[1].role == "system") then
        local sp = nil
        -- Composed prompt (context-injection): base + AGENTS.md + agents files
        -- + skills index. Falls back to the legacy config path when the
        -- context module is unavailable (e.g. old embedded build).
        if context and context.compose then
            sp = context.compose(cfg, {
                workspace = cfg.workspace,
                agents_files = cfg._cli_agents_files,
            })
        elseif config and config.get_system_prompt then
            sp = config.get_system_prompt(cfg)
        end
        table.insert(M.history, 1, { role = "system", content = sp or M.builtin_prompt })
    end
    if not skip_user then
        M.add_user(user_text)
        log_message(cfg, "user", user_text)
    end
    -- a new user turn gets a fresh retry budget, continuation state and nudge
    M.reset_retry_state()
    -- and no leftover interrupt: a Ctrl+C delivered just as the turn started must
    -- not abort this turn
    ack_abort()
    return main_loop(cfg, api_key, on_event)
end

-- Resolve a confirmation: "allow" | "session" | "always" | "deny" | "cancel"
function M.confirm(id, decision, cfg, on_event)
    local p = M.pending
    if not p then return false end
    for _, call in ipairs(p.calls) do
        if call.id == id and not call.done then
            if decision == "allow" or decision == "session" or decision == "always" then
                if decision ~= "allow" then
                    M.session_approved[approve_key(call.name, call.args)] = true
                end
                if decision == "always" then
                    persist_auto_approve(call.name, call.args, cfg)
                end
                run_tool_call(cfg, on_event, call.id, call.name, call.args, call.projection)
            elseif decision == "cancel" then
                -- deny this call; the remaining ones are denied in the loop below
                M.add_tool_result(call.id, { error = "cancelled by user" })
            else
                M.add_tool_result(call.id, { error = "denied by user" })
                if on_event then
                    on_event({ type = "tool_result", id = call.id, name = call.name,
                               error = "denied by user",
                               summary = "✗ denied by user", body = "denied by user" })
                end
            end
            call.done = true
        end
    end
    -- cancel denies everything still queued
    if decision == "cancel" then
        for _, call in ipairs(p.calls) do
            if not call.done then
                M.add_tool_result(call.id, { error = "cancelled by user" })
                call.done = true
                if on_event then
                    on_event({ type = "tool_result", id = call.id, name = call.name,
                               error = "cancelled by user",
                               summary = "✗ cancelled by user", body = "cancelled by user" })
                end
            end
        end
        M.pending = nil
        return true
    end
    return drive_pending(cfg, on_event) == false -- false => another confirmation pending
end

-- add-ask-tool: resolve a parked `ask` call with the user's answer. `answer`
-- is the UI's answer table — { [question index] = { selected = {<label>, ...},
-- other = "<freeform>", notes = { [<option label>] = "<note>" } } } — or
-- { cancelled = true } to cancel the whole batch. Records the call's tool
-- result, drives the queue, and returns true when the queue drained (the UI
-- then resumes with M.continue), false when another interaction is parked.
function M.answer_ask(id, answer, cfg, on_event)
    local p = M.pending
    if not p then return false end
    local cancelled = type(answer) == "table" and answer.cancelled == true
    if cancelled then
        -- Esc means "stop asking": every queued question of this step is
        -- resolved, so the model cannot re-prompt with the next one.
        local payload = ask.cancelled_payload()
        for _, call in ipairs(p.calls) do
            if call.name == "ask" and not call.done then
                record_ask_result(cfg, on_event, call, payload, ask.CANCELLED_TEXT, false)
                call.done = true
            end
        end
    else
        for _, call in ipairs(p.calls) do
            if call.name == "ask" and call.id == id and not call.done then
                local questions = call.questions or ask.normalize(call.args)
                local payload = ask.encode(questions, answer)
                record_ask_result(cfg, on_event, call, payload,
                    ask.summary(questions, answer), false)
                call.done = true
                break
            end
        end
    end
    return drive_pending(cfg, on_event) == false
end

-- Continue the agent loop after confirmations are resolved,
-- without adding a new user message.
function M.continue(cfg, api_key, on_event)
    if M.pending then
        if not drive_pending(cfg, on_event) then return true end
    end
    return main_loop(cfg, api_key, on_event)
end

M.estimate_tokens = estimate_tokens
M._should_confirm = should_confirm
M._patch_target_path = patch_target_path
M._projection_for = projection_for
M.compress_history = compress_history
M.should_summarize = should_summarize
M.parse_args = parse_args
M.json_parse = json_parse

return M
