-- tether M3: agent — LLM loop with system prompt and tool dispatch
local M = {}

M.history = {}

local system_prompt = [==[
You are tether, a code assistant running inside a terminal.

Available tools:
- read(path, offset?, limit?) — read file contents
- list(path?) — list directory entries
- glob(pattern, path?) — find files by glob
- grep(pattern, path?, ignore_case?, max_results?) — search text in files
- exec(command) — run a shell command, return exit code

When the user asks you to inspect or edit code, use these tools.
Work in the current directory.
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
end

local function execute_tool(name, args)
    if name == "read" then return tools.read(args)
    elseif name == "list" then return tools.list(args)
    elseif name == "glob" then return tools.glob(args)
    elseif name == "grep" then return tools.grep(args)
    else return nil, "unknown tool: " .. name
    end
end

local function parse_args(args_str)
    if not args_str or args_str == "" then return {} end
    local result = {}
    -- Extract string values: "key": "value"
    for k, v in args_str:gmatch('"(%w+)"%s*:%s*"(.-)"') do
        result[k] = v
    end
    -- Extract numeric values: "key": number
    for k, v in args_str:gmatch('"(%w+)"%s*:%s*(%d+)') do
        result[k] = tonumber(v)
    end
    -- Extract boolean values
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

        -- Build assistant message with tool calls
        if next(tool_calls) then
            local tc_list = {}
            for _, tc in pairs(tool_calls) do
                local args = parse_args(tc.arguments)
                local result, err = execute_tool(tc.name, args)
                if result then
                    M.add_tool_result(tc.id, result)
                else
                    M.add_tool_result(tc.id, { error = err })
                end
                tc_list[#tc_list + 1] = {
                    id = tc.id,
                    type = "function",
                    ['function'] = { name = tc.name, arguments = tc.arguments },
                }
            end
            M.add_assistant({ tool_calls = tc_list })
        else
            -- No tool calls, we're done
            break
        end
    end

    return true
end

return M
