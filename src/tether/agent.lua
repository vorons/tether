-- tether M4: agent — LLM loop with system prompt, tool dispatch, and confirmations
local M = {}

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
    slog(cfg, { ts = os.date("*t"), type = "message", role = role, content = content })
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
    return nil
end

local function execute_tool(name, args, cfg)
    if name == "read" then return tools.read(args)
    elseif name == "write" then return tools.write(args, cfg)
    elseif name == "list" then return tools.list(args)
    elseif name == "glob" then return tools.glob(args)
    elseif name == "grep" then return tools.grep(args)
    elseif name == "run" then return tools.run(args, cfg)
    elseif name == "patch" then return tools.patch(args.patch or args, cfg)
    else return nil, "unknown tool: " .. name
    end
end

local function path_of(args)
    return args.path or args.command or args.cwd or ""
end

local function should_confirm(tool_name, args, cfg)
    if not cfg then return false end
    if cfg.allow_outside_workspace == true then return false end
    if tool_name ~= "write" and tool_name ~= "patch" and tool_name ~= "run" then
        return false
    end
    if tool_name == "patch" then
        return not tools._within(args.path and tools._resolve(args.path, cfg) or tools._workspace(cfg), cfg)
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

-- Single-pass SSE-string unescape (M7/D2b): tool_call arguments arrive from
-- api.lua as raw JSON-string content ({\"path\":...}); exactly ONE unescape
-- must happen over the FULL assembled string (a chunk boundary can split an
-- escape sequence), then json_parse sees valid JSON. Single left-to-right scan:
-- sequential gsub chains corrupt \\\\n sequences by re-processing their own output.
local function sse_unescape(s)
    local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                  ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and i < #s then
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code then
                    out[#out + 1] = utf8 and utf8.char and utf8.char(code) or ""
                    i = i + 6
                else
                    out[#out + 1] = n
                    i = i + 2
                end
            else
                out[#out + 1] = map[n] or n
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Minimal JSON parser (recursive descent, no load, no globals)
local function json_parse(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s and s:sub(pos,pos):match("[%s]") do pos = pos + 1 end
    end
    local function parse_value()
        skip_ws()
        local c = s:sub(pos,pos)
        if c == nil then return nil end
        if c == '"' then
            pos = pos + 1
            local buf = {}
            while true do
                -- M7/D6: s:sub returns "" (not nil) past the end — an unterminated
                -- string (truncated tool_call arguments) used to hang the parser.
                if pos > #s then break end
                local ch = s:sub(pos,pos)
                if ch == '"' then pos = pos + 1; return table.concat(buf)
                elseif ch == '\\' then
                    local esc = s:sub(pos+1,pos+1)
                    local m = {["n"]="\n",["t"]="\t",["r"]="\r",["b"]="\b",["f"]="\f",['"']='"',['\\']='\\',["/"]="/"}
                    if esc == "u" then
                        local hex = s:sub(pos+2,pos+5)
                        local code = tonumber(hex) or 0
                        pos = pos + 6
                        buf[#buf+1] = utf8 and utf8.char and utf8.char(code) or ""
                    else
                        buf[#buf+1] = m[esc] or ""
                        pos = pos + 2
                    end
                else
                    buf[#buf+1] = ch
                    pos = pos + 1
                end
            end
            return table.concat(buf)
        elseif c == "{" then
            pos = pos + 1
            local obj = {}
            skip_ws()
            if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
            while true do
                skip_ws()
                local key
                if s:sub(pos,pos) == '"' then
                    key = parse_value()
                else
                    local ks = s:match("[%w_%-]+", pos)
                    if not ks then break end
                    key = ks
                    pos = pos + #key
                end
                skip_ws()
                if s:sub(pos,pos) ~= ":" then break end
                pos = pos + 1
                obj[key] = parse_value()
                skip_ws()
                local nx = s:sub(pos,pos)
                if nx == "," then pos = pos + 1
                elseif nx == "}" then pos = pos + 1; break
                else break end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr+1] = parse_value()
                skip_ws()
                local nx = s:sub(pos,pos)
                if nx == "," then pos = pos + 1
                elseif nx == "]" then pos = pos + 1; break
                else break end
            end
            return arr
        elseif s:sub(pos, pos+3) == "true" then
            pos = pos + 4; return true
        elseif s:sub(pos, pos+4) == "false" then
            pos = pos + 5; return false
        elseif s:sub(pos, pos+3) == "null" then
            pos = pos + 4; return nil
        else
            local st, fin = s:find("%-?%d+%.?%d*[eE][%+%-]?%d+", pos)
            if not st then st, fin = s:find("%-?%d+%.?%d*", pos) end
            if st then
                local num = s:sub(st, fin)
                pos = fin + 1
                return tonumber(num)
            end
            return nil
        end
    end
    return parse_value()
end

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
    M.add_tool_result(id, res.error and { error = res.error } or res)
    slog(cfg, {
        ts = os.date("*t"), type = "tool_result",
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
        M.add_assistant({ tool_calls = tc_list })
        slog(cfg, { ts = os.date("*t"), type = "message", role = "assistant",
                    content = "", tool_calls = tc_list })

        -- Build the queue of calls for this step
        local calls = {}
        for _, id in ipairs(ordered) do
            local tc = tool_calls[id]
            local args = parse_args(tc.arguments)
            calls[#calls + 1] = { id = tc.id, name = tc.name, args = args, arguments_str = tc.arguments }
            if on_event then
                on_event({ type = "tool_call_start", id = tc.id, name = tc.name })
            end
            slog(cfg, { ts = os.date("*t"), type = "tool_call",
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
        local sp = config and config.get_system_prompt and config.get_system_prompt(cfg)
        table.insert(M.history, 1, { role = "system", content = sp or system_prompt })
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
M.compress_history = compress_history
M.should_summarize = should_summarize
M.parse_args = parse_args
M.json_parse = json_parse

return M
