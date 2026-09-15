-- tether M4: ui — TUI with transcript, tool blocks, confirmation, diff overlay
local M = {}

local transcript = {}
local input_buf = ""
local busy = false
local cfg = nil
local key = ""

local expanded = {}  -- tool_call_id -> true if expanded
local thinking_visible = true
local diff_text = ""
local confirmation_active = false
local confirmation_details = {}

local function out(s) tether.write(s) end

local function draw_banner()
    out("\x1b[2J\x1b[H")
    out("tether\n")
    for _, msg in ipairs(transcript) do
        if msg.role == "user" then
            out("\x1b[36m›\x1b[0m " .. msg.text .. "\n")
        elseif msg.role == "assistant" then
            out("● " .. msg.text .. "\n")
        elseif msg.role == "error" then
            out("\x1b[31m! " .. msg.text .. "\x1b[0m\n")
        elseif msg.role == "tool_result" then
            local tc_id = msg.tool_call_id
            local result = msg.content
            local is_error = result and result.error
            local name = ""
            if result and result.path then name = result.path end
            if is_error then
                out("\x1b[31m✗ " .. name .. ": " .. (result.error or "error") .. "\x1b[0m\n")
            else
                local summary = ""
                if result.bytes then summary = " " .. result.bytes .. "B" end
                if result.content and type(result.content) == "string" then
                    summary = " " .. (#result.content:gsub("[^\n]","")) .. "str"
                end
                if result.line_count then summary = " " .. result.line_count .. "lines" end
                if result.add and result.del then summary = " +" .. result.add .. " -" .. result.del end
                if result.exit_code ~= nil then summary = " exit " .. result.exit_code end
                if result.elapsed_ms then summary = " " .. result.elapsed_ms .. "ms" end
                out("\x1b[33m⚙ " .. name .. summary .. "\x1b[0m\n")
            end
        elseif msg.role == "confirmation" then
            out("\x1b[31m⚠ confirmation pending\n")
        end
    end
    out("› " .. input_buf)
end

local function draw_hint()
    if confirmation_active then
        out("\x1b[37m↑↓ выбрать · Enter подтвердить · y/a/A/d/n горячие · Esc отмена\x1b[0m\n")
    elseif busy then
        out("\x1b[37mCtrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл\x1b[0m\n")
    else
        out("\x1b[37mEnter отправить · Ctrl+J новая строка · Ctrl+C отмена · ? помощь\x1b[0m\n")
    end
end

local function draw_status()
    local model = (cfg and cfg.model) or "unknown"
    local ws = (cfg and cfg.workspace) or tether.getcwd()
    local ws_short = ws:match("^/home/([^/]+)") and "~/" .. ws:match("^/home/([^/]+)/(.+)") or ws
    out("\x1b[7m " .. model .. " · " .. ws_short .. " · Ctrl+Q выход \x1b[0m\n")
end

local function draw_confirmation_menu()
    if not confirmation_active then return end
    out("\x1b[2J\x1b[H")
    out("\x1b[33m⚠ Confirmation required\x1b[0m\n\n")
    for _, detail in ipairs(confirmation_details) do
        local args_str = ""
        if detail.args.path then args_str = detail.args.path end
        if detail.args.command then args_str = detail.args.command end
        out("\x1b[33m⚠ " .. detail.name .. " " .. args_str .. "\x1b[0m\n")
    end
    out("\n")
    out("› [y] once      разрешить один раз\n")
    out("  [a] session   разрешить этот тип до конца сессии\n")
    out("  [A] always    сохранить в auto_approve конфига\n")
    out("  [d] details   показать детали целиком\n")
    out("  [n] deny      отклонить, вернуть отказ агенту\n")
    out("  [Esc] cancel  прервать текущий ход агента\n")
end

local function draw_diff_overlay()
    if diff_text == "" then return end
    out("\x1b[2J\x1b[H")
    out("\x1b[37m┌ diff ────────────────────────────────────────────────┐\x1b[0m\n")
    for _, line in ipairs(diff_text:gmatch("[^\n]*")) do
        if line:match("^%+%+%+") then
            out("\x1b[37m├ " .. line:sub(2) .. "\x1b[0m\n")
        elseif line:match("^%-%-%-") then
            out("\x1b[37m├ " .. line:sub(2) .. "\x1b[0m\n")
        elseif line:match("^@@") then
            out("\x1b[36m├ " .. line .. "\x1b[0m\n")
        elseif line:match("^+") then
            out("\x1b[32m│ " .. line:sub(2) .. "\x1b[0m\n")
        elseif line:match("^-") then
            out("\x1b[31m│ " .. line:sub(2) .. "\x1b[0m\n")
        elseif line:match("^%s") then
            out("│ " .. line .. "\n")
        else
            out("│ " .. line .. "\n")
        end
    end
    out("\x1b[37m├ [/] файл  ↑↓ скролл  PgUp/PgDn страница  g/G начало/конец  Esc ─┘\x1b[0m\n")
end

local function commit_input()
    local text = input_buf
    input_buf = ""
    text = text:match("^%s*(.-)%s*$")
    if text == "" then
        draw_banner()
        out("› ")
        return
    end

    transcript[#transcript + 1] = { role = "user", text = text }
    draw_banner()
    out("… ")

    busy = true
    local ok, err = agent.turn(cfg, key, text, function(ev)
        if ev.type == "text_delta" then
            out(ev.text or "")
        elseif ev.type == "error" then
            out("\n")
            transcript[#transcript + 1] = { role = "error", text = ev.message or "error" }
        elseif ev.type == "confirmation" then
            confirmation_active = true
            confirmation_details = ev.details or {}
            busy = false
            draw_confirmation_menu()
            return
        end
    end)
    busy = false
    out("\n")

    if confirmation_active then
        -- Wait for confirmation; don't draw banner yet
        return
    end

    if not ok then
        draw_banner()
    else
        draw_banner()
    end
    out("› ")
end

local function handle_confirmation_input(c)
    if c == 121 then -- y
        for _, detail in ipairs(confirmation_details) do
            agent.confirm(detail.id, "allow", cfg)
        end
        confirmation_active = false
        return true
    elseif c == 110 then -- n
        for _, detail in ipairs(confirmation_details) do
            agent.confirm(detail.id, "deny", cfg)
        end
        confirmation_active = false
        return true
    elseif c == 13 then -- Enter: same as y
        for _, detail in ipairs(confirmation_details) do
            agent.confirm(detail.id, "allow", cfg)
        end
        confirmation_active = false
        return true
    elseif c == 97 then -- a
        for _, detail in ipairs(confirmation_details) do
            agent.confirm(detail.id, "allow", cfg)
        end
        confirmation_active = false
        return true
    elseif c == 65 then -- A
        for _, detail in ipairs(confirmation_details) do
            agent.confirm(detail.id, "allow", cfg)
        end
        confirmation_active = false
        return true
    elseif c == 100 then -- d
        diff_text = "Full diff content"
        draw_diff_overlay()
        return true
    elseif c == 27 then -- Esc
        confirmation_active = false
        return true
    end
    return false
end

local function handle_diff_input(c)
    if c == 27 then -- Esc
        diff_text = ""
        return true
    end
    return false
end

local function drain_escape()
    local c = tether.read_char()
    if c ~= 91 and c ~= 79 then return end
    c = tether.read_char()
    while c and c >= 65 and c <= 90 do
        c = tether.read_char()
    end
end

function M.run()
    cfg = config.load()
    key = config.api_key(cfg)
    draw_banner()
    out("› ")

    while true do
        local c = tether.read_char()
        if c == 0 or c == -1 then break end
        c = c & 0xFF

        if confirmation_active then
            if handle_confirmation_input(c) then
                draw_banner()
                out("› ")
            end
        elseif diff_text ~= "" then
            if handle_diff_input(c) then
                draw_banner()
                out("› ")
            end
        elseif c == 3 or c == 4 then
            break
        elseif c == 12 then
            draw_banner()
            out("› ")
        elseif c == 27 then
            drain_escape()
        elseif c == 13 or c == 10 then
            if not busy then
                commit_input()
            end
        elseif c == 15 then -- Ctrl+O
            -- toggle expand/collapse
            draw_banner()
            out("› ")
        elseif c == 20 then -- Ctrl+T
            thinking_visible = not thinking_visible
            draw_banner()
            out("› ")
        elseif c == 127 or c == 8 then
            if #input_buf > 0 then
                input_buf = input_buf:sub(1, -2)
                out("\b \b")
            end
        elseif c >= 32 and c <= 126 then
            input_buf = input_buf .. string.char(c)
            out(string.char(c))
        elseif c >= 1 and c <= 26 then
            out(string.format("^%c", c + 64))
        end
    end
    out("\x1b[?25h\n")
end

return M
