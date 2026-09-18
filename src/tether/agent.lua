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

When the user asks you to inspect or edit code, use these tools.
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

local function path_of(args)
    return args.path or args.command or args.cwd or ""
end

-- fix-audit-findings 1.2: patch arguments are the diff text, not a path;
-- the target has to come from the file headers before the containment check.
local function patch_target_path(args)
    local diff = args and args.patch or nil
    if type(diff) ~= "string" then return nil end
    -- same normalization as tools.patch: strip one leading a//b/ component,
    -- skip /dev/null; accept both git-style and prefix-less headers
    local function norm(p)
        if not p or p == "/dev/null" then return nil end
        return p:match("^[ab]/(.+)$") or p
    end
    for line in diff:gmatch("[^\n]*") do
        local plus = line:match("^%+%+%+%s+([^%s]+)")
        if plus then
            local t = norm(plus)
            if t then return t end
        end
        local minus = line:match("^%-%-%-%s+([^%s]+)")
        if minus then
            local t = norm(minus)
            if t then return t end
        end
    end
    return nil
end

local function should_confirm(tool_name, args, cfg)
    if not cfg then return false end
    if cfg.allow_outside_workspace == true then return false end
    if tool_name ~= "write" and tool_name ~= "patch" and tool_name ~= "run" then
        return false
    end
    if tool_name == "patch" then
        local target = patch_target_path(args)
        if not target then return false end
        return not tools._within(tools._resolve(target, cfg), cfg)
    end
    local path = args.path or args.command or ""
    if path == "" and tool_name == "run" then path = args.cwd or "" end
    if tool_name == "write" or (tool_name == "patch" and args.path) or (tool_name == "run" and args.cwd) then
        -- target path known: check membership
        return not tools._within(tools._resolve(path, cfg), cfg)
    end
    -- run without cwd: executed in workspace root — allowed there
    return false
end

local function approve_key(tool_name, args)
    return tool_name .. ":" .. path_of(args)
end

local function check_auto_approve(tool_name, args, cfg)
    if not cfg or not cfg.auto_approve then return false end
    local key = approve_key(tool_name, args)
    for _, pattern in ipairs(cfg.auto_approve) do
        if type(pattern) == "string" and (key:match(pattern) or path_of(args):match(pattern)) then
            return true
        end
    end
    return false
end

local function is_session_approved(tool_name, args)
    return M.session_approved[approve_key(tool_name, args)] == true
end

-- Design §6.10: [A] always persists to config with a dated comment.
-- We keep it in a machine-managed side file that config.load merges,
-- instead of rewriting the user's hand-written config.lua.
local function persist_auto_approve(tool_name, args, cfg)
    local home = os.getenv("HOME") or ""
    local path = home .. "/.tether/auto_approve.lua"
    local dir_ok = os.execute("mkdir -p " .. home .. "/.tether") == 0
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
local function run_tool_call(cfg, on_event, id, name, args)
    local result, err = execute_tool(name, args, cfg)
    local res
    if result then
        res = result
    else
        res = { error = err or "tool failed" }
    end
    -- fix-audit-findings 1.2: the model must see the tool's output body, not
    -- just whatever happened to live under `content` (only `read` had one).
    local history_result
    if res.error then
        history_result = { error = tostring(res.error) }
    else
        history_result = { content = truncate_body(tool_body(name, res)) or "" }
    end
    M.add_tool_result(id, history_result)
    slog(cfg, {
        ts = os.date(), type = "tool_result",
        tool_call_id = id, name = name,
        result = res.error and { error = res.error } or { summary = tool_summary(name, res) },
    })
    if on_event then
        on_event({
            type = "tool_result", id = id, name = name,
            error = res.error or nil,
            summary = res.error and ("✗ " .. tostring(res.error)) or tool_summary(name, res),
            body = res.error and tostring(res.error) or tool_body(name, res),
        })
    end
    return res
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
        elseif not should_confirm(call.name, call.args, cfg)
            or check_auto_approve(call.name, call.args, cfg)
            or is_session_approved(call.name, call.args) then
            run_tool_call(cfg, on_event, call.id, call.name, call.args)
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

local function main_loop(cfg, api_key, on_event)
    local max_iterations = 50
    local iteration = 0

    while iteration < max_iterations do
        iteration = iteration + 1
        if M.abort_requested then
            M.abort_requested = false
            if on_event then on_event({ type = "aborted" }) end
            return false
        end

        if should_summarize(M.history, cfg) then
            M.history = compress_history(M.history)
            if on_event then on_event({ type = "context_compressed" }) end
        end

        local tool_calls = {}
        local ordered = {}

        local text_acc = {}
        local ok = api.stream(cfg, api_key, M.history, function(ev)
            if M.abort_requested and ev.type ~= "usage" then return end
            if ev.type == "text_delta" then
                text_acc[#text_acc + 1] = ev.text
                if on_event then on_event(ev) end
            elseif ev.type == "reasoning_delta" then
                if on_event then on_event(ev) end
            elseif ev.type == "usage" then
                if on_event then on_event(ev) end
            elseif ev.type == "retry" then
                if on_event then on_event(ev) end
            elseif ev.type == "error" then
                if on_event then on_event(ev) end
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

        if not ok then
            return false
        end

        if next(tool_calls) == nil then
            -- No tool calls: keep the streamed assistant text in history
            if #text_acc > 0 then
                local full = table.concat(text_acc)
                M.add_assistant(full)
                log_message(cfg, "assistant", full)
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
        local assistant_text = #text_acc > 0 and table.concat(text_acc) or ""
        M.add_assistant({ tool_calls = tc_list, text = assistant_text })
        slog(cfg, { ts = os.date(), type = "message", role = "assistant",
                    content = assistant_text, tool_calls = tc_list })

        -- Build the queue of calls for this step
        local calls = {}
        for _, id in ipairs(ordered) do
            local tc = tool_calls[id]
            local args = parse_args(tc.arguments)
            calls[#calls + 1] = { id = tc.id, name = tc.name, args = args, arguments_str = tc.arguments }
            if on_event then
                on_event({ type = "tool_call_start", id = tc.id, name = tc.name })
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
                run_tool_call(cfg, on_event, call.id, call.name, call.args)
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
M.compress_history = compress_history
M.should_summarize = should_summarize
M.parse_args = parse_args
M.json_parse = json_parse

return M
