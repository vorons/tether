-- tether M4: agent — LLM loop with system prompt, tool dispatch, and confirmations
local M = {}

M.history = {}
M.pending_confirmation = nil

local system_prompt = (config and config.get_system_prompt and config.get_system_prompt()) or [==[
You are tether, a code assistant running inside a terminal.

Available tools:
- read(path, offset?, limit?) — read file contents
- write(path, content) — create/overwrite file
- list(path?) — list directory entries
- glob(pattern, path?) — find files by glob
- grep(pattern, path?, ignore_case?, max_results?) — search text in files
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
        role = "tool_result",
        tool_call_id = tool_call_id,
        content = result,
    })
end

function M.get_history()
    return M.history
end

function M.clear()
    M.history = {}
    M.pending_confirmation = nil
end

local function execute_tool(name, args, cfg)
    if name == "read" then return tools.read(args)
    elseif name == "write" then return tools.write(args, cfg)
    elseif name == "list" then return tools.list(args)
    elseif name == "glob" then return tools.glob(args)
    elseif name == "grep" then return tools.grep(args)
    elseif name == "run" then return tools.run(args, cfg)
    elseif name == "patch" then return tools.patch(args, cfg)
    else return nil, "unknown tool: " .. name
    end
end

local function should_confirm(tool_name, args, cfg)
    if not cfg then return false end
    if cfg.allow_outside_workspace then return false end
    local path = args.path or args.command
    if not path then return false end
    -- absolute paths always need confirmation
    if path:sub(1, 1) == "/" then return true end
    local ws = tools._workspace()
    local resolved = ws .. "/" .. path
    if not resolved:match(ws .. "$") and not resolved:match(ws .. "/") then
        return true
    end
    return false
end

local function check_auto_approve(tool_name, args, cfg)
    if not cfg or not cfg.auto_approve then return false end
    local path = args.path or args.command
    if not path then return false end
    for _, pattern in ipairs(cfg.auto_approve) do
        if path:match(pattern) then return true end
    end
    return false
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
                local ch = s:sub(pos,pos)
                if ch == nil then break end
                if ch == '"' then pos = pos + 1; return table.concat(buf)
                elseif ch == '\\' then
                    local esc = s:sub(pos+1,pos+1)
                    local m = {["n"]="\n",["t"]="\t",["r"]="\r",["b"]="\b",["f"]="\f",['"']='"',['\\']='\\'}
                    buf[#buf+1] = m[esc] or ""
                    pos = pos + 2
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
            local st, fin = s:find("%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
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
    local ok, result = pcall(json_parse, args_str)
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

function M.turn(cfg, api_key, user_text, on_event, skip_user)
    if #M.history == 0 then
        table.insert(M.history, { role = "system", content = system_prompt })
    end
    if not skip_user then
        M.add_user(user_text)
    end

    local max_iterations = 50
    local iteration = 0

    while iteration < max_iterations do
        iteration = iteration + 1
        local tool_calls = {}

        -- Auto-compress if context is getting full
        if should_summarize(M.history, cfg) then
            M.history = compress_history(M.history)
            on_event({ type = "context_compressed" })
        end

        local ok = api.stream(cfg, api_key, M.history, function(ev)
            if ev.type == "text_delta" then
                on_event(ev)
            elseif ev.type == "tool_call_start" then
                tool_calls[ev.id] = { id = ev.id, name = ev.name, arguments = "" }
            elseif ev.type == "tool_call_delta" then
                if tool_calls[ev.id] then
                    tool_calls[ev.id].arguments = tool_calls[ev.id].arguments .. (ev.arguments or "")
                end
            elseif ev.type == "done" then
                -- stream finished
            elseif ev.type == "error" then
                on_event(ev)
            end
        end)

        if not ok then
            return false
        end

        -- Build assistant message with tool calls, execute tools
        if next(tool_calls) then
            local tc_list = {}
            local needs_confirm = false
            local confirm_details = {}

            for _, tc in pairs(tool_calls) do
                local args = parse_args(tc.arguments)
                local tool_name = tc.name

                -- Check if confirmation needed
                if should_confirm(tool_name, args, cfg) then
                    local auto = check_auto_approve(tool_name, args, cfg)
                    if not auto then
                        needs_confirm = true
                        confirm_details[#confirm_details + 1] = {
                            id = tc.id,
                            name = tool_name,
                            args = args,
                        }
                    end
                end

                -- Execute if no confirmation needed, or auto-approved
                local result, err
                if needs_confirm then
                    result = nil
                    err = "pending confirmation"
                else
                    result, err = execute_tool(tool_name, args, cfg)
                end

                if result then
                    M.add_tool_result(tc.id, result)
                else
                    M.add_tool_result(tc.id, { error = err })
                end

                tc_list[#tc_list + 1] = {
                    id = tc.id,
                    type = "function",
                    ['function'] = { name = tool_name, arguments = tc.arguments },
                }
            end

            -- Emit confirmation event if needed
            if needs_confirm then
                M.pending_confirmation = {
                    tool_calls = confirm_details,
                    tc_list = tc_list,
                }
                on_event({ type = "confirmation", details = confirm_details })
                return true
            end

            M.add_assistant({ tool_calls = tc_list })
        else
            -- No tool calls, we're done
            break
        end
    end

    return true
end

function M.confirm(id, decision, cfg)
    if not M.pending_confirmation then return end
    local tc = M.pending_confirmation
    local handled = false
    for _, detail in ipairs(tc.tool_calls) do
        if detail.id == id then
            local result, err
            if decision == "allow" or decision == "session" or decision == "always" then
                result, err = execute_tool(detail.name, detail.args, cfg)
                handled = true
            else
                result = nil
                err = "denied by user"
                handled = true
            end
            if result then
                M.add_tool_result(id, result)
            else
                M.add_tool_result(id, { error = err })
            end
        end
    end
    if handled then
        M.pending_confirmation = nil
    end
    return handled
end

-- Continue the agent loop after a confirmation was resolved,
-- without adding a new user message.
M.estimate_tokens = estimate_tokens
M.compress_history = compress_history
M.should_summarize = should_summarize

function M.continue(cfg, api_key, on_event)
    local ok = M.turn(cfg, api_key, "", on_event, true)
    return ok
end

M.system_prompt = nil

function M.set_system_prompt(p)
    M.system_prompt = p
end

function M.get_system_prompt()
    if not M.system_prompt or M.system_prompt == "" then return nil end
    return M.system_prompt
end

return M
