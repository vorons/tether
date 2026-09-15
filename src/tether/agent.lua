-- tether M2: agent — LLM loop
local M = {}

M.history = {}

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

function M.turn(cfg, api_key, on_event)
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
