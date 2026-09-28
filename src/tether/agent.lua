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

-- modular-next-phases E: pure context-compaction policy — a global in the
-- built binary and a loadfile fallback for development/plain-lua runs.
-- Execution (LLM summarize call, history swap) stays here in compact_history.
local compression = _G.compression
    or (function()
        local chunk = loadfile("src/tether/compression.lua")
        return chunk and chunk()
    end)()
assert(compression, "agent: cannot load compression")

-- modular-next-phases E: read-only change projection + persistent approval
-- store — globals in the built binary, loadfile fallbacks for dev/test runs.
-- Turn control (turn/confirm/answer_ask/continue) stays here.
local projection = _G.projection
    or (function()
        local chunk = loadfile("src/tether/projection.lua")
        return chunk and chunk()
    end)()
assert(projection, "agent: cannot load projection")

local approval = _G.approval
    or (function()
        local chunk = loadfile("src/tether/approval.lua")
        return chunk and chunk()
    end)()
assert(approval, "agent: cannot load approval")

-- deepen-core-modules cut 5: turn facade owns the abort seam; agent keeps
-- M.abort_requested as the flag storage and the four entry points for
-- print mode / non-UI callers.
local turn_mod = _G.turn
    or (function()
        local chunk = loadfile("src/tether/turn.lua")
        return chunk and chunk()
    end)()
assert(turn_mod, "agent: cannot load turn")

-- modular-remainder E: one synchronous tool call (execute + report) —
-- a global in the built binary and a loadfile fallback for dev/test runs.
-- The turn/confirm/answer_ask/continue entries below keep calling the
-- local wrapper, so their contract is unchanged.
local tool_dispatch = _G.tool_dispatch
    or (function()
        local chunk = loadfile("src/tether/tool_dispatch.lua")
        return chunk and chunk()
    end)()
assert(tool_dispatch, "agent: cannot load tool_dispatch")

M.history = {}
M.pending = nil            -- confirmation queue for the current tool-call step
M.bg_calls = nil           -- background subagent calls awaiting pickup: survives
                           -- turns by design (never cleared by M.clear); the
                           -- cancel path owns it
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

function M.add_tool_result(tool_call_id, result, name, summary)
    local r = (type(result) == "table") and result
        or { content = tostring(result or "") }
    -- name/summary ride along so a resumed history re-seeds the transcript
    -- with the tool row it had (the live path carries them via events)
    table.insert(M.history, {
        role = "tool",
        tool_call_id = tool_call_id,
        name = r.name or name,
        summary = r.summary or summary,
        error = r.error,
        content = r.content or r.error or "",
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
    M._skip_first_compact = nil
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
        return (result.line_count or 0) .. " lines"
    elseif name == "list" then
        return (result.count or 0) .. " entries"
    elseif name == "glob" then
        return (result.count or 0) .. " files"
    elseif name == "grep" then
        return (result.count or 0) .. " matches"
    elseif name == "run" then
        return "exit " .. tostring(result.exit_code or "?") .. ", " .. fmt_ms(result.elapsed_ms)
    elseif name == "subagent" then
        return string.format("%d task(s), exit %s, %s", result.tasks or 1,
            tostring(result.exit_code or "?"), fmt_ms(result.elapsed_ms))
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
        -- utf8_prefix, not sub: a byte cut can end mid-glyph, and a body that
        -- is not valid UTF-8 gets the whole request rejected with 400.
        return common.utf8_prefix(body, TOOL_BODY_MAX) .. "\n…(truncated)"
    end
    return body
end

local function tool_body(name, result)
    if not result or result.error then return nil end
    if name == "read" then return result.content end
    if name == "run" then return result.output end
    if name == "subagent" then return result.output end
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

-- subagent depth + allowlist guard (module field, not a file-local: the
-- chunk's local budget is reserved for state). At or above max_depth the
-- `subagent` tool does not exist; outside an allowlist nothing does.
-- Both report the unknown-tool contract so the model sees one rule.
function M._tool_permitted(name, cfg)
    if name == "subagent" then
        local depth = (cfg and tonumber(cfg._subagent_depth)) or 0
        local maxd = (cfg and cfg.subagents and tonumber(cfg.subagents.max_depth)) or 1
        if depth >= maxd then return false end
    end
    local allow = cfg and cfg._tools_allowlist
    if allow == nil then return true end
    for _, n in ipairs(allow) do
        if n == name then return true end
    end
    return false
end

local function execute_tool(name, args, cfg)
    -- 1.3: every tool receives cfg so -w/config.workspace applies uniformly
    if not M._tool_permitted(name, cfg) then
        return nil, "unknown tool: " .. tostring(name)
    end
    if name == "read" then return tools.read(args, cfg)
    elseif name == "write" then return tools.write(args, cfg)
    elseif name == "list" then return tools.list(args, cfg)
    elseif name == "glob" then return tools.glob(args, cfg)
    elseif name == "grep" then return tools.grep(args, cfg)
    elseif name == "run" then return tools.run(args, cfg)
    elseif name == "patch" then return tools.patch(args.patch or args, cfg)
    elseif name == "subagent" then
        local sm = rawget(_G, "subagent")
        if not sm or not sm.run_call then return nil, "unknown tool: subagent" end
        return sm.run_call(args, cfg)
    else return nil, "unknown tool: " .. name
    end
end

-- pretty-transcript-rendering 2.2: read-only change projection + persistent
-- approval live in their own modules now (projection.lua, approval.lua);
-- the turn core below calls in through those tables.

local should_confirm = confirm_policy.should_confirm
local approve_key = confirm_policy.approve_key
local check_auto_approve = confirm_policy.check_auto_approve

local function is_session_approved(tool_name, args)
    return confirm_policy.is_session_approved(tool_name, args, M.session_approved)
end

-- Design §6.10: [A] always persists to config. Canonical implementations
-- live in approval.lua; the M.* names below keep the consumed seams.
function M.persist_approval(tool_name, target, home)
    return approval.persist_approval(tool_name, target, home)
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


-- add-llm-compaction: full compact path. force=true bypasses the threshold
-- (manual /compact). Returns (new_history, summary_text, mode) where mode is
-- "llm" | "truncation" | "noop". Never mutates the input table.
local function compact_history(history, cfg, api_key, focus, force)
    history = history or M.history
    cfg = cfg or {}
    if not force and not compression.should_summarize(history, cfg) then
        return history, "", "noop"
    end
    local N = compression.keep_recent_of(cfg)
    local system, old, keep = compression.split_span(history, N)
    if #old == 0 then return history, "", "noop" end

    local body, mode
    if type(api_key) == "string" and api_key ~= ""
        and api and api.summarize then
        local ok, text = pcall(api.summarize, cfg, api_key,
            compression.build_summary_messages(old, focus, compression.anchor_block(history, cfg)))
        if ok and type(text) == "string" and text ~= "" then
            body, mode = text, "llm"
        end
    end
    if not body then
        body, mode = compression.truncation_body(old), "truncation"
    end
    local summary_msg = compression.SUMMARY_MARKER .. "\n" .. body
    local new_history = { system, { role = "system", content = summary_msg } }
    for _, m in ipairs(keep) do new_history[#new_history + 1] = m end
    return new_history, summary_msg, mode
end

-- Lossless superseded-read pruning (adapted from pifydev/compact): a file read
-- twice keeps both copies in context, but only the later one can still be
-- true. Blank the earlier copies in the OUTBOUND view only — persisted history
-- and the journal are never touched, so resume restores the originals.
-- Cache discipline: the newest tail is never touched, and nothing is rewritten
-- until enough can be reclaimed at once (one rewrite = one cache miss).
-- Returns the same table reference when nothing qualifies.
local PRUNE_PROTECT_CHARS = 160000
local PRUNE_MIN_RECLAIM_CHARS = 20000

local function prune_placeholder(path)
    path = tostring(path)
    return "[superseded: this read of " .. path
        .. " was replaced by the latest read of " .. path
        .. " (kept in context) - pruned from context]"
end

local function normalize_prune_path(p)
    return tostring(p):gsub("\\", "/"):gsub("^%./", "")
end

local function is_plan_file(path)
    local base = tostring(path):match("([^/\\]+)$") or tostring(path)
    return base:lower():find("plan") ~= nil and base:lower():sub(-3) == ".md"
end

local function prune_superseded_reads(view)
    view = view or {}
    -- 1. every read call: tool_call_id -> path, in order.
    local path_of_call = {}
    local call_count = 0
    for _, m in ipairs(view) do
        if m.role == "assistant" then
            for _, tc in ipairs(compression.anchor_tool_calls(m.content)) do
                local name, args = compression.anchor_call_args(tc)
                name = type(name) == "string" and name:lower() or ""
                if compression.ANCHOR_READ_TOOLS[name] and type(tc.id) == "string" then
                    local p = args.path or args.file or args.filename
                    if type(p) == "string" and p:match("%S") then
                        p = normalize_prune_path(
                            p:gsub("^%s+", ""):gsub("%s+$", ""))
                        if p ~= "" then
                            path_of_call[tc.id] = p
                            call_count = call_count + 1
                        end
                    end
                end
            end
        end
    end
    if call_count < 2 then return view end
    -- 2. every read result, grouped by path, in order.
    local by_path = {}
    for i, m in ipairs(view) do
        if m.role == "tool" and type(m.tool_call_id) == "string" then
            local p = path_of_call[m.tool_call_id]
            if p then
                by_path[p] = by_path[p] or {}
                by_path[p][#by_path[p] + 1] = i
            end
        end
    end
    -- 3. chars after each message, to find the protected tail.
    local after = {}
    local acc = 0
    for i = #view, 1, -1 do
        after[i] = acc
        local c = view[i].content
        acc = acc + (type(c) == "string" and #c or 0)
    end
    -- 4. candidates: all but the last result per path, outside the tail.
    local candidates = {}
    local reclaim = 0
    for path, indexes in pairs(by_path) do
        if #indexes >= 2 and not is_plan_file(path) then
            for k = 1, #indexes - 1 do
                local i = indexes[k]
                if after[i] >= PRUNE_PROTECT_CHARS then
                    local m = view[i]
                    local size = type(m.content) == "string" and #m.content or 0
                    local ph = prune_placeholder(path)
                    if size > #ph
                        and not tostring(m.content):sub(1, 13):find("%[superseded:") then
                        candidates[#candidates + 1] = { index = i, path = path }
                        reclaim = reclaim + size
                    end
                end
            end
        end
    end
    if #candidates == 0 or reclaim < PRUNE_MIN_RECLAIM_CHARS then return view end
    -- 5. rewrite the outbound view only.
    local out = {}
    for i, m in ipairs(view) do out[i] = m end
    for _, c in ipairs(candidates) do
        local m = view[c.index]
        local copy = {}
        for k, v in pairs(m) do copy[k] = v end
        copy.content = prune_placeholder(c.path)
        out[c.index] = copy
    end
    return out
end

-- The messages actually sent to the provider: history, or the pruned view
-- when pruning is enabled. Never assigned back to M.history.
local function outbound_view(cfg)
    if not compression.context_flag(cfg, "prune_superseded_reads", false) then
        return M.history
    end
    local ok, view = pcall(prune_superseded_reads, M.history)
    if not ok or type(view) ~= "table" then return M.history end
    return view
end

-- Run one tool call: execute, log, report to UI. Returns result table or {error=...}.
-- `projection` is the read-only change projection computed at call start (nil
-- when none could be computed); it supplies the previous content for the
-- applied diff without a second file read.
local function run_tool_call(cfg, on_event, id, name, args, projection)
    return tool_dispatch.run_tool_call(cfg, on_event, id, name, args, projection, {
        execute = execute_tool,
        summarize = tool_summary,
        body = tool_body,
        truncate = truncate_body,
        add_history = function(call_id, res) M.add_tool_result(call_id, res) end,
        journal = function(entry) slog(cfg, entry) end,
    })
end

-- Background spawn failure (validation): same three writes as a sync tool
-- error — history, journal, UI event — so a rejected call still resolves.
local function record_tool_error(cfg, on_event, id, name, err)
    err = tostring(err or "tool failed")
    M.add_tool_result(id, { error = err })
    slog(cfg, {
        ts = os.date(), type = "tool_result", tool_call_id = id, name = name,
        result = { error = err },
    })
    if on_event then
        on_event({ type = "tool_result", id = id, name = name, error = err,
            summary = "✗ " .. err, body = err })
    end
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
        elseif call.name == "subagent" and not (cfg and cfg.non_interactive)
            and M._tool_permitted("subagent", cfg) then
            -- background delegation (interactive only): spawn now, results
            -- land later via poll_background; the turn parks meanwhile.
            -- Print mode and missing bg support keep the blocking call.
            local sm = rawget(_G, "subagent")
            if sm and sm.run_call_bg then
                local rec, berr = sm.run_call_bg(call.args, cfg)
                if not rec then
                    record_tool_error(cfg, on_event, call.id, call.name, berr)
                    call.done = true
                    p.idx = p.idx + 1
                else
                    M.bg_calls = M.bg_calls or {}
                    local bg = { rec = rec, cfg = cfg, results = {},
                                 batch = rec.batch }
                    for idx, eres in pairs(rec.done or {}) do
                        bg.results[idx] = eres
                    end
                    M.bg_calls[call.id] = bg
                    -- batch: one row per job; the call row stays pending
                    -- until the combined result lands. Single reuses it.
                    if on_event and rec.tasks > 1 then
                        for _, job in ipairs(rec.jobs) do
                            local it = (rec.items or {})[job.idx] or {}
                            on_event({ type = "tool_call_start", id = job.id,
                                name = "subagent",
                                args = { task = it.task, sid = it.sid } })
                        end
                    end
                    call.done = true
                    p.idx = p.idx + 1
                    p.waiting_on_bg = true
                end
            else
                run_tool_call(cfg, on_event, call.id, call.name, call.args, call.projection)
                call.done = true
                p.idx = p.idx + 1
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
        elseif cfg and cfg.non_interactive then
            -- subagent: a run with no interactive user has nobody to
            -- confirm — deny and continue (mirrors the ask degradation)
            -- instead of parking the turn forever.
            record_ask_result(cfg, on_event, call,
                "denied (no interactive user to confirm)",
                "✗ denied (no interactive user to confirm)", true)
            call.done = true
            p.idx = p.idx + 1
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
    local parked_on_bg = p.waiting_on_bg
    M.pending = nil
    -- parked on background children: the turn ends here like a parked
    -- confirmation (ui resumes via continue on pickup), it just waits on
    -- children instead of the user.
    if parked_on_bg then return false end
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
-- call sites working. The test seam is turn.take_abort / turn.ack_abort.
local function take_abort()
    return turn_mod.take_abort(M)
end

local function ack_abort()
    turn_mod.ack_abort(M)
end

-- add-steering-input: pull-based steer source provided by the UI. The agent
-- takes one message only at a segment boundary (after tools / before the next
-- LLM call) — never between retry attempts of the same segment.
local steer_source = nil
function M.set_steer_source(fn)
    steer_source = fn
end

local function take_steer()
    if not steer_source then return nil end
    local ok, text = pcall(steer_source)
    if not ok or type(text) ~= "string" or text == "" then return nil end
    return text
end

-- Inject one steering message as a user turn entry + journal line. Returns
-- true when a message was injected so main_loop can run another segment.
local function inject_steer(cfg)
    local text = take_steer()
    if not text then return false end
    M.add_user(text)
    log_message(cfg, "user", text)
    return true
end

-- The reactor loop that owns waiting right now (ui.run binds it around its
-- run()); nil in print mode and for non-UI callers. Agent never imports ui:
-- the loop is an optional global seam, like the transport.
local function active_loop()
    local r = _G.reactor
    if type(r) == "table" and type(r.active) == "function" then
        return r.active()
    end
    return nil
end

-- Wait out a retry backoff of up to a minute and report whether an abort cut
-- it short. With a reactor loop owning waiting the deadline is a loop timer:
-- keys, spinner and timers keep dispatching through the wait (TW2: a wheel
-- tick scrolls immediately instead of queueing until the turn ends), and the
-- wait ends early on abort or a stopped loop. Without a loop (print mode,
-- one-shot callers) the wait slices on tether.sleep: it returns as soon as
-- input arrives and the host flag is sticky until the turn clears it, so the
-- abort check below usually fires well before the slice elapses.
local function interruptible_sleep(seconds)
    local total = tonumber(seconds) or 0
    if total <= 0 then return false end
    local loop = active_loop()
    if loop then
        local done = false
        local id = loop:after(total * 1000, function() done = true end)
        while not done do
            if take_abort() then
                loop:cancel(id)
                return true
            end
            if not loop:tick() then
                -- closed stdin / quit: stop waiting instead of spinning on a
                -- loop that can no longer dispatch anything
                loop:cancel(id)
                return true
            end
        end
        return false
    end
    local elapsed = 0
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
    -- reasoning rides alongside the text: accumulated per attempt like text
    -- so the caller can journal one thinking message per step (resume needs
    -- what the transcript showed, not just what the model keeps)
    local reasoning_acc = {}
    local stop_reason = "other"
    local ok, failure = api.stream(cfg, api_key, outbound_view(cfg), function(ev)
        if ev.type ~= "usage" and take_abort() then return end
        if ev.type == "text_delta" then
            text_acc[#text_acc + 1] = ev.text
            if on_event then ev.attempt = attempt; on_event(ev) end
        elseif ev.type == "reasoning_delta" then
            reasoning_acc[#reasoning_acc + 1] = ev.text or ""
            if on_event then ev.attempt = attempt; on_event(ev) end
        elseif ev.type == "usage" then
            if on_event then on_event(ev) end
        elseif ev.type == "done" then
            -- the provider's last reported reason for this request
            stop_reason = ev.reason or "other"
        end
        if ev.type == "tool_call_start" then
            -- a repeated start (same id resent by a later chunk) must not
            -- wipe the arguments assembled so far.
            if ev.id and not tool_calls[ev.id] then
                tool_calls[ev.id] = { id = ev.id, name = ev.name, arguments = "" }
                ordered[#ordered + 1] = ev.id
            end
        elseif ev.type == "tool_call_delta" then
            -- gateways split arguments into index-only continuation chunks
            -- (no id): index N is the Nth started call. Without this mapping
            -- the fragments were dropped, the tool still ran on fallback {},
            -- but the echoed arguments went out truncated and strict
            -- providers 400'd every follow-up request ("bad request").
            local id = ev.id
            if not id and ev.index ~= nil then id = ordered[ev.index + 1] end
            if id and tool_calls[id] then
                tool_calls[id].arguments = tool_calls[id].arguments .. (ev.arguments or "")
            end
        end
    end)
    return { text = table.concat(text_acc), tool_calls = tool_calls,
             ordered = ordered, stop_reason = stop_reason,
             reasoning = table.concat(reasoning_acc) }, ok, failure
end

-- Run attempts until this iteration's answer is complete: retry a failed
-- attempt per the policy, continue a truncated answer, nudge an empty one.
-- On success returns true plus { text, tool_calls, ordered, stop_reason,
-- reasoning }. Otherwise returns false plus the failure table or
-- "aborted"/"empty".
local function run_answer_segments(cfg, api_key, on_event, state, max_iterations)
    local p = retry.policy(cfg)
    local merged = {}
    local merged_reasoning = {}
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
            if result.reasoning ~= "" then
                merged_reasoning[#merged_reasoning + 1] = result.reasoning
            end
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
                               stop_reason = result.stop_reason,
                               reasoning = table.concat(merged_reasoning) }
            end
        else
            -- A failed attempt contributes nothing to the conversation.
            -- add-provider-login: one refresh on classified auth failure when
            -- a stored refresh_token exists — runs before permanent stop so
            -- a 401 never dead-ends before the token can be renewed.
            local should_auth_refresh = false
            if failure and failure.kind == "permanent" then
                local auth_mod = rawget(_G, "auth")
                if not auth_mod then
                    local chunk = loadfile("src/tether/auth.lua")
                    auth_mod = chunk and chunk() or nil
                end
                local provider = (cfg and cfg.provider) or "openai"
                local home = cfg and cfg._auth_home
                if auth_mod and auth_mod.load and auth_mod.refresh_token then
                    local store = auth_mod.load(home)
                    local entry = store and store[provider]
                    if type(entry) == "table" and type(entry.refresh_token) == "string"
                        and entry.refresh_token ~= "" then
                        entry.provider = provider
                        local post = auth_mod._post_json
                        if auth_mod.refresh_token(provider, entry, post, os.time()) then
                            auth_mod.save(home, store)
                            should_auth_refresh = true
                            -- new key for the immediate retry of this attempt
                            api_key = entry.access_token
                        else
                            if on_event then
                                on_event({
                                    type = "error",
                                    kind = "permanent",
                                    message = (failure.message or "auth failed")
                                        .. " — run /login to refresh credentials",
                                })
                            end
                            collapse_partial_answer(cfg, pending, merged)
                            return false, failure
                        end
                    end
                end
            end
            local verdict = retry.verdict(p, state, failure)
            if should_auth_refresh then
                -- refresh already renewed the token: retry this attempt once
                -- without consuming a user-visible backoff wait
                state.attempt = state.attempt + 1
                goto continue_attempt
            end
            if verdict.action ~= "retry" then
                collapse_partial_answer(cfg, pending, merged)
                if on_event then
                    on_event({ type = "error", kind = failure and failure.kind,
                               message = retry.terminal_message(failure, state.attempt) })
                end
                return false, failure
            end
            if on_event then
                -- detail carries the provider's own text (a bare "bad
                -- request" never says which field the gateway rejected).
                on_event({ type = "retry", attempt = state.attempt, delay = verdict.delay,
                           reason = verdict.reason or (failure and failure.reason),
                           kind = verdict.kind,
                           detail = failure and failure.message or nil })
            end
            if interruptible_sleep(verdict.delay) then
                collapse_partial_answer(cfg, pending, merged)
                ack_abort()
                if on_event then on_event({ type = "aborted" }) end
                return false, "aborted"
            end
            state.attempt = state.attempt + 1
            ::continue_attempt::
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

        if M._skip_first_compact then
            -- this turn already compacted in preflight; the keep window still
            -- holds the large prompt, so a re-check here would compact again
            -- for no gain (one summary call saved).
            M._skip_first_compact = nil
        elseif compression.should_summarize(outbound_view(cfg), cfg) then
            local compressed, summary, mode =
                compact_history(M.history, cfg, api_key, nil, true)
            if mode ~= "noop" then
                M.history = compressed
                if on_event then
                    on_event({
                        type = "context_compressed",
                        mode = mode,
                        summary = mode == "llm" and summary or nil,
                    })
                end
            end
        end

        local ok, result = run_answer_segments(cfg, api_key, on_event, state, max_iterations)
        if not ok then
            return false
        end

        local tool_calls = result.tool_calls
        local ordered = result.ordered

        -- the step's reasoning is journaled beside its answer: resume
        -- restores the think block from it, the model never sees it
        -- (commands.resume skips non-user/assistant/tool roles for history)
        local reasoning = result.reasoning or ""
        if reasoning ~= "" and reasoning:match("%S") then
            slog(cfg, { ts = os.date(), type = "reasoning", text = reasoning })
        end

        if next(tool_calls) == nil then
            -- No tool calls: keep the assistant text in history
            if result.text ~= "" then
                M.add_assistant(result.text)
                log_message(cfg, "assistant", result.text)
            end
            -- add-steering-input: segment ended with no tools — inject a
            -- pending steer (if any) and run one more LLM segment.
            if inject_steer(cfg) then
                -- fall through to the next main_loop iteration
            else
                return true
            end
        else

        -- Assistant message with tool_calls goes to history BEFORE results (OpenAI contract)
        local tc_list = {}
        for _, id in ipairs(ordered) do
            local tc = tool_calls[id]
            -- the echo must carry the transport-DECODED arguments: fragments
            -- arrive raw (still SSE-escaped, so a split escape survives the
            -- boundary), but echoing them raw adds a whole escape layer and
            -- strict providers 400 every follow-up ("arguments must be valid
            -- JSON"). Execution keeps using the raw form via parse_args below.
            tc_list[#tc_list + 1] = {
                id = tc.id,
                type = "function",
                ['function'] = { name = tc.name,
                                 arguments = sse_unescape(tc.arguments or "") },
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
            local projection = projection.projection_for(tc.name, args, cfg)
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
            -- everything executed; inject a pending steer before the next LLM
            inject_steer(cfg)
            -- loop back to the LLM
        else
            -- waiting for the user; ui resumes us via M.continue
            return true
        end
        end -- tool_calls present
    end
    return true
end

-- The system prompt leads the history. A resumed history is replayed without
-- one (the journal never stores it), so this runs after the replay as well:
-- without it, compaction on a promptless history promotes the first user
-- message into the system role (split_span peels history[1] as the prompt)
-- and the model answers the session's first request instead of the latest.
function M.ensure_prompt(cfg)
    if M.history[1] and M.history[1].role == "system" then return end
    local sp = nil
    -- Composed prompt (context-injection): base + AGENTS.md + agents files
    -- + skills index. Falls back to the legacy config path when the
    -- context module is unavailable (e.g. old embedded build).
    if context and context.compose then
        sp = context.compose(cfg, {
            workspace = cfg and cfg.workspace,
            agents_files = cfg and cfg._cli_agents_files,
        })
    elseif config and config.get_system_prompt then
        sp = config.get_system_prompt(cfg)
    end
    table.insert(M.history, 1, { role = "system", content = sp or M.builtin_prompt })
end

function M.turn(cfg, api_key, user_text, on_event, skip_user)
    M.ensure_prompt(cfg)
    if not skip_user then
        M.add_user(user_text)
        log_message(cfg, "user", user_text)
    end
    -- preflight: a large paste can overflow the very turn it opens, before
    -- the main loop ever sees an over-threshold history. Project and compact
    -- first so the turn goes out against a fitting window.
    if not skip_user and compression.context_flag(cfg, "preflight", true)
        and compression.should_summarize_projected(M.history, user_text, cfg) then
        local compressed, summary, mode =
            compact_history(M.history, cfg, api_key, nil, true)
        if mode ~= "noop" then
            M.history = compressed
            -- the main loop re-checks the threshold on its first iteration;
            -- it would compact again immediately (the large prompt itself is
            -- in the keep window), so tell it this turn already preflighted.
            M._skip_first_compact = true
            if on_event then
                on_event({
                    type = "context_compressed",
                    mode = mode,
                    summary = mode == "llm" and summary or nil,
                })
            end
        end
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
                    approval.persist_auto_approve(call.name, call.args, cfg)
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

-- Final record for a completed background call: the same three writes a
-- sync result performs, with the standard truncation budget on history
-- and journal while the UI event keeps the full body.
local function record_bg_result(cfg, on_event, call_id, combined, is_error, err_text)
    local body = truncate_body(combined.output or "")
    local summary = tool_summary("subagent", combined)
    if is_error then
        err_text = tostring(err_text or "tool failed")
        M.add_tool_result(call_id, { error = err_text })
        slog(cfg, {
            ts = os.date(), type = "tool_result", tool_call_id = call_id,
            name = "subagent", result = { error = err_text },
        })
        if on_event then
            on_event({ type = "tool_result", id = call_id, name = "subagent",
                error = err_text, summary = "✗ " .. err_text, body = err_text })
        end
    else
        M.add_tool_result(call_id, { content = body or "" })
        slog(cfg, {
            ts = os.date(), type = "tool_result", tool_call_id = call_id,
            name = "subagent",
            result = { summary = summary, body = body or "" },
        })
        if on_event then
            on_event({ type = "tool_result", id = call_id, name = "subagent",
                summary = summary, body = combined.output or "" })
        end
    end
end

-- True when every job of the call has a result (ran or immediate).
local function bg_call_ready(bg)
    for i = 1, bg.rec.tasks do
        if bg.results[i] == nil then return false end
    end
    return true
end

-- Record the final result of a ready call and drop its tracking:
-- single resolves to success/error like the blocking path, batch
-- combines in task order. Returns the combined table.
local function finish_bg_call(call_id, bg, on_event)
    local n = bg.rec.tasks
    local combined, is_error, err_text
    if n == 1 then
        local r = bg.results[1]
        combined = { output = r.output, exit_code = r.exit_code,
            elapsed_ms = r.elapsed_ms, model = r.model, tasks = 1 }
        is_error, err_text = (r.status ~= "ok"), r.output
    else
        local sm = rawget(_G, "subagent")
        local ordered = {}
        for i = 1, n do ordered[i] = bg.results[i] end
        combined = sm.combine_batch(ordered, n)
        is_error, err_text = false, nil
    end
    record_bg_result(bg.cfg, on_event, call_id, combined, is_error, err_text)
    M.bg_calls[call_id] = nil
    return combined
end

-- Background subagent pickup: step the registry, collapse job rows with
-- transcript-only events, announce refilled rows, and record final
-- per-call results (history + journal + tool_result event) once all of a
-- call's jobs finish. Single reuses its call row; batch combines in task
-- order like the blocking path. Returns an array of {call_id, combined}
-- for completed calls.
function M.poll_background(cfg, on_event)
    local completed = {}
    local sm = rawget(_G, "subagent")
    if not sm or not sm.poll_running then return completed end
    if not M.bg_calls or next(M.bg_calls) == nil then return completed end
    local step = sm.poll_running()
    for _, s in ipairs(step.spawned or {}) do
        if on_event then
            on_event({ type = "tool_call_start", id = s.id, name = "subagent",
                args = { task = s.item and s.item.task,
                         sid = s.item and s.item.sid } })
        end
    end
    for _, c in ipairs(step.completed or {}) do
        if c.id then
            for call_id, bg in pairs(M.bg_calls) do
                local ours = false
                for _, job in ipairs(bg.rec.jobs) do
                    if job.id == c.id then ours = true break end
                end
                if ours then
                    bg.results[c.idx] = c.result
                    if on_event then
                        local r = c.result
                        if r.status ~= "ok" then
                            on_event({ type = "tool_result", id = c.id,
                                name = "subagent", error = r.output,
                                summary = "✗ " .. tostring(r.output),
                                body = tostring(r.output) })
                        else
                            on_event({ type = "tool_result", id = c.id,
                                name = "subagent",
                                summary = string.format("exit %s, %s",
                                    tostring(r.exit_code), fmt_ms(r.elapsed_ms)),
                                body = r.output or "" })
                        end
                    end
                    break
                end
            end
        elseif c.batch then
            -- immediate refill failure (nothing ever ran): the batch link
            -- disambiguates same-index jobs of concurrent batches.
            for _, bg in pairs(M.bg_calls) do
                if bg.batch == c.batch and bg.results[c.idx] == nil then
                    bg.results[c.idx] = c.result
                    break
                end
            end
        end
    end
    for call_id, bg in pairs(M.bg_calls) do
        if bg_call_ready(bg) then
            local combined = finish_bg_call(call_id, bg, on_event)
            completed[#completed + 1] =
                { call_id = call_id, combined = combined }
        end
    end
    return completed
end

-- Abort/quit owns background children too: kill the registry, collapse
-- rows, record cancellations for tracked calls, drop the tracking.
-- Queued items never had rows; their calls still resolve as cancelled.
function M.cancel_background(cfg, reason, on_event)
    reason = reason or "subagent cancelled"
    local sm = rawget(_G, "subagent")
    local killed = (sm and sm.cancel_all) and sm.cancel_all(reason) or {}
    if on_event then
        for _, k in ipairs(killed) do
            if k.id then
                on_event({ type = "tool_result", id = k.id, name = "subagent",
                    error = reason, summary = "✗ " .. reason, body = reason })
            end
        end
    end
    if M.bg_calls then
        for call_id, bg in pairs(M.bg_calls) do
            local n = bg.rec.tasks
            for i = 1, n do
                if bg.results[i] == nil then
                    local it = (bg.rec.items or {})[i] or {}
                    bg.results[i] = { status = "error", exit_code = 127,
                        output = reason, elapsed_ms = 0, model = it.model }
                end
            end
            finish_bg_call(call_id, bg, on_event)
        end
    end
end

M.estimate_tokens = compression.estimate_tokens
M._should_confirm = should_confirm
M._projection_for = projection.projection_for
M.compress_history = compression.compress_history
M.compact_history = compact_history
M.should_summarize = compression.should_summarize
M.should_summarize_projected = compression.should_summarize_projected
M.extract_anchors = compression.extract_anchors
M.format_anchors = compression.format_anchors
M.prune_superseded_reads = prune_superseded_reads
M.parse_args = parse_args
M.json_parse = json_parse
M.SUMMARY_MARKER = compression.SUMMARY_MARKER
M._inject_steer = inject_steer
M._take_steer = take_steer

return M
