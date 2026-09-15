-- tether M3: agent — LLM loop with system prompt
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

function M.add_assistant(text)
    table.insert(M.history, { role = "assistant", content = text })
end

function M.get_history()
    return M.history
end

function M.clear()
    M.history = {}
end

function M.turn(cfg, api_key, user_text, on_event)
    if #M.history == 0 then
        table.insert(M.history, { role = "system", content = system_prompt })
    end
    M.add_user(user_text)

    local last_text = ""
    local ok = api.chat(cfg, api_key, M.history, function(ev)
        if ev.type == "text_delta" then
            last_text = last_text .. ev.text
            on_event(ev)
        elseif ev.type == "error" then
            on_event(ev)
        end
    end)

    if not ok then
        return false
    end

    if last_text ~= "" then
        M.add_assistant(last_text)
    end
    return true
end

return M
