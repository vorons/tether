-- tether M4: agent — LLM loop with system prompt, tool dispatch, and confirmations
local M = {}

M.history = {}
M.pending_confirmation = nil

local system_prompt = [==[
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
    if path:find("^/") then return true end
    local resolved = tools._resolve(path)
    local rel = tools._to_rel(resolved)
    if rel ~= path then return true end
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

local function parse_args(args_str)
    if not args_str or args_str == "" then return {} end
    local result = {}
    for k, v in args_str:gmatch('"(%w+)"%s*:%s*"(.-)"') do
        result[k] = v
    end
    for k, v in args_str:gmatch('"(%w+)"%s*:%s*(%d+)') do
        result[k] = tonumber(v)
    end
    for k, v in args_str:gmatch('"(%w+)"%s*:%s*(true|false)') do
        result[k] = (v == "true")
    end
    if next(result) then return result end
    return {}
end

function M.turn(cfg, api_key, user_text, on_event)
    if #M.history == 0 then
        table.insert(M.history, { role = "system", content = system_prompt })
    end
    M.add_user(user_text)

    local max_iterations = 50
    local iteration = 0

    while iteration < max_iterations do
        iteration = iteration + 1
        local tool_calls = {}

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
    for _, detail in ipairs(tc.tool_calls) do
        if detail.id == id then
            local result, err
            if decision == "allow" then
                result, err = execute_tool(detail.name, detail.args, cfg)
            else
                result = nil
                err = "denied by user"
            end
            if result then
                M.add_tool_result(id, result)
            else
                M.add_tool_result(id, { error = err })
            end
        end
    end
    M.pending_confirmation = nil
end

return M
