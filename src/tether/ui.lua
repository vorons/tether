-- tether M4+: ui — TUI with full screen layout
local M = {}

-- State
local S = {
    key = nil,
    transcript = {},
    input_lines = {""},
    input_line = 1,
    input_col = 0,
    busy = false,
    cfg = nil,
    model_name = "",
    workspace = "",
    session_id = "",
    term_width = 80,
    term_height = 24,
    expanded = {},
    expand_all = false,
    thinking_visible = true,
    diff_text = "",
    confirmation_active = false,
    confirmation_details = {},
    confirmation_selected = 1,
    palette_active = false,
    palette_filter = "",
    palette_items = {},
    palette_selected = 1,
    help_active = false,
    log_active = false,
    status_active = false,
    resume_active = false,
    resume_items = {},
    resume_selected = 1,
    history_items = {},
    history_idx = 0,
    scroll_offset = 0,
    mouse_reporting = false,
    keyboard_protocol = "none",
    last_usage = nil,
    tokens_used = 0,
    tokens_max = 32768,
}

local A = {
    user_gutter = "›",
    assistant_gutter = "●",
    thinking_gutter = "✻",
    separator = "─",
    corner_tl = "┌",
    corner_tr = "┐",
    corner_bl = "└",
    corner_br = "┘",
    border_v = "│",
    border_h = "─",
    expand = "▸",
    check = "▸",
    spinner_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
}

local function out(s) tether.write(s) end
local function is_ascii() return false end

local function update_size()
    if tether.resize_requested() then
        local size = tether.get_terminal_size()
        if size and size.width and size.height then
            S.term_width = size.width
            S.term_height = size.height
        end
        draw_full()
        out(A.user_gutter .. " ")
    else
        local size = tether.get_terminal_size()
        if size and size.width and size.height then
            S.term_width = size.width
            S.term_height = size.height
        end
    end
end

local function esc(s) return "\x1b" .. s end
local function clear() out(esc("[2J") .. esc("[H")) end
local function hide_cursor() out(esc("[?25l")) end
local function show_cursor() out(esc("[?25h")) end
local function reverse(s) return "\x1b[7m" .. s .. "\x1b[0m" end
local function dim(s) return "\x1b[2m" .. s .. "\x1b[0m" end
local function cyan(s) return "\x1b[36;1m" .. s .. "\x1b[0m" end
local function yellow(s) return "\x1b[33;1m" .. s .. "\x1b[0m" end
local function red(s) return "\x1b[31;1m" .. s .. "\x1b[0m" end
local function green(s) return "\x1b[32m" .. s .. "\x1b[0m" end
local function trunc(s, maxw) if utf8.len(s) <= maxw then return s end return utf8.sub(s, 1, maxw - 1) end
local function maxw() return math.max(S.term_width - 2, 20) end

local function wrap_text(text, width)
    local lines = {}
    for line in text:gmatch("[^\n]*") do
        while utf8.len(line) > width do
            table.insert(lines, utf8.sub(line, 1, width))
            line = utf8.sub(line, width + 1)
        end
        if #line > 0 then table.insert(lines, line) end
    end
    return lines
end

local function render_message(msg, mw)
    local lines = {}
    if msg.role == "user" then
        local prefix = A.user_gutter .. " "
        for _, l in ipairs(wrap_text(msg.text, mw - #prefix)) do
            table.insert(lines, prefix .. l)
        end
    elseif msg.role == "assistant" then
        local prefix = A.assistant_gutter .. " "
        for _, l in ipairs(wrap_text(msg.text, mw - #prefix)) do
            table.insert(lines, prefix .. l)
        end
    elseif msg.role == "thinking" then
        local prefix = A.thinking_gutter .. " "
        if S.thinking_visible then
            table.insert(lines, dim(prefix .. msg.content))
        else
            table.insert(lines, dim(prefix .. "(Ctrl+T)"))
        end
    elseif msg.role == "tool_result" then
        local name = msg.content and msg.content.path or ""
        local summary = ""
        if msg.content and msg.content.add then summary = " +" .. msg.content.add end
        if msg.content and msg.content.del then summary = " -" .. msg.content.del end
        if msg.content and msg.content.exit_code ~= nil then summary = " exit " .. msg.content.exit_code end
        if msg.content and msg.content.elapsed_ms then summary = " " .. msg.content.elapsed_ms .. "ms" end
        if msg.content and msg.content.error then
            table.insert(lines, red(A.assistant_gutter .. " " .. name .. ": " .. msg.content.error))
        else
            table.insert(lines, yellow(A.assistant_gutter .. " " .. name .. summary))
        end
        if S.expanded[msg.tool_call_id] or S.expand_all then
            if msg.content and msg.content.content and type(msg.content.content) == "string" then
                for _, l in ipairs(wrap_text(msg.content.content, mw)) do
                    table.insert(lines, "  " .. l)
                end
            end
        end
    elseif msg.role == "error" then
        table.insert(lines, red(A.assistant_gutter .. " " .. msg.text))
    end
    return lines
end

local function draw_transcript()
    local mw = maxw()
    local maxh = S.term_height - 8
    local start = S.scroll_offset + 1
    local count = 0
    for i = 1, #S.transcript do
        if i >= start and count < maxh then
            for _, ml in ipairs(render_message(S.transcript[i], mw)) do
                out(ml .. "\n")
                count = count + 1
                if count >= maxh then break end
            end
        end
        if count >= maxh then break end
    end
end

local function draw_error_banner()
    if #S.transcript > 0 then
        local last = S.transcript[#S.transcript]
        if last.role == "error" then
            out(red("\x1b[7m ! " .. trunc(last.text, maxw()) .. "\x1b[0m\n"))
        end
    end
end

local function draw_input()
    local mw = maxw()
    local max_lines = (S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8
    local prefix = A.user_gutter .. " "
    for i = 1, math.min(#S.input_lines, max_lines) do
        local line = S.input_lines[i]
        local disp = prefix .. line
        if #disp > mw then disp = trunc(disp, mw) end
        if i == S.input_line then
            disp = disp .. "\x1b[7m ▌\x1b[0m"
        end
        out(disp .. "\n")
    end
    for i = #S.input_lines + 1, max_lines do out("\n") end
end

local function draw_palette()
    if not S.palette_active then return end
    local mw = maxw()
    local maxh = math.min(#S.palette_items, 10)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    for i = 1, 10 do
        if i <= #S.palette_items then
            local item = S.palette_items[i]
            if i == S.palette_selected then
                out(reverse(" " .. trunc(item, mw - 2) .. "\n"))
            else
                out(" " .. trunc(item, mw - 2) .. "\n")
            end
        else
            out(string.rep(" ", mw) .. "\n")
        end
    end
    out(A.corner_bl .. string.rep(A.border_h, mw) .. A.corner_br .. "\n")
    out(dim(" ↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть ") .. "\n")
end

local function draw_hint()
    local mw = maxw()
    local text = ""
    if S.palette_active then
        text = "↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть"
    elseif S.busy then
        text = "Ctrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл"
    elseif S.confirmation_active then
        text = "↑↓ выбрать · Enter подтвердить · y/a/A/d/n горячие · Esc отмена"
    elseif S.diff_text ~= "" then
        text = "↑↓ скролл · [/] файл · Esc закрыть"
    elseif S.help_active then
        text = "? закрыть"
    elseif S.log_active then
        text = "Esc закрыть"
    elseif S.status_active then
        text = "Esc закрыть"
    elseif S.resume_active then
        text = "↑↓ выбрать · Enter возобновить · Esc закрыть"
    else
        text = "Enter отправить · Ctrl+J newline · Ctrl+C выход · / палитра · ? помощь"
    end
    out(dim("  " .. trunc(text, mw)) .. "\n")
end

local function draw_status()
    local mw = maxw()
    local home = os.getenv("HOME") or ""
    local display_ws = S.workspace
    if home ~= "" and S.workspace:sub(1, #home) == home then
        display_ws = "~" .. S.workspace:sub(#home + 1)
    end
    local parts = {S.model_name, display_ws}
    if S.last_usage then
        parts[#parts + 1] = string.format("%.1fk/%.1fk (%.0f%%)",
            S.last_usage.used / 1024, S.last_usage.max / 1024,
            S.last_usage.used / S.last_usage.max * 100)
    end
    table.insert(parts, "🖱 on")
    local line = table.concat(parts, " · ")
    if #line > mw then line = line:sub(1, mw) end
    out("\x1b[7m " .. line .. " \x1b[0m\n")
end

local function draw_full()
    clear()
    draw_transcript()
    if S.diff_text ~= "" and not S.palette_active then
        draw_diff_overlay()
        return
    end
    if S.help_active then draw_help_overlay(); return end
    if S.log_active then draw_log_overlay(); return end
    if S.status_active then draw_status_overlay(); return end
    if S.resume_active then draw_resume_picker(); return end
    draw_error_banner()
    draw_input()
    draw_palette()
    draw_hint()
    draw_status()
    hide_cursor()
end

local function draw_diff_overlay()
    local mw = maxw()
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    local lines = {}
    for line in S.diff_text:gmatch("[^\n]*") do table.insert(lines, line) end
    for _, line in ipairs(lines) do
        if line:match("^%s") then
            out(" " .. A.border_v .. " " .. line .. "\n")
        elseif line:match("^+") then
            out(" " .. A.border_v .. " " .. green(line) .. "\n")
        elseif line:match("^-") then
            out(" " .. A.border_v .. " " .. red(line) .. "\n")
        else
            out(" " .. A.border_v .. " " .. dim(line) .. "\n")
        end
    end
    out(string.rep(A.border_h, mw) .. "\n")
    out(dim(" [/] файл · ↑↓ скролл · PgUp/PgDn · Esc закрыть ") .. "\n")
end

local function draw_help_overlay()
    local mw = maxw()
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    local help_text = {
        "Ввод         Enter отправить · Ctrl+J newline",
        "              ↑↓ история · Ctrl+A/E/U/W/K",
        "Навигация     PgUp/PgDn · Ctrl+Home/End",
        "Транскрипт    Ctrl+O развернуть · Ctrl+T thinking",
        "              Ctrl+L очистить экран",
        "Сессия        Ctrl+R возобновить · Ctrl+N новая",
        "              Ctrl+Q выход",
        "Палитра       /model · /help · /clear · /new",
        "              /status · /log · /resume · /compact",
        "Прочее        ? помощь · Esc отмена",
    }
    for _, line in ipairs(help_text) do
        out(" " .. trunc(line, mw - 2) .. "\n")
    end
    out(A.corner_bl .. string.rep(A.border_h, mw) .. A.corner_br .. "\n")
    out(dim(" ? закрыть ") .. "\n")
end

local function draw_log_overlay()
    local mw = maxw()
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    out(dim("Последние ошибки из лога (требуется --debug):") .. "\n")
    out(dim("Функционал лог-файла доступен при --debug") .. "\n")
    out(A.corner_bl .. string.rep(A.border_h, mw) .. A.corner_br .. "\n")
    out(dim(" Esc закрыть ") .. "\n")
end

local function draw_status_overlay()
    local mw = maxw()
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    local lines = {
        "Сессия: " .. S.session_id,
        "Workspace: " .. S.workspace,
        "Модель: " .. S.model_name,
        "Токены: " .. S.tokens_used .. "/" .. S.tokens_max,
        "Инструментов выполнено: " .. #S.transcript,
        "Старт: " .. os.date("%Y-%m-%d %H:%M:%S"),
    }
    for _, line in ipairs(lines) do
        out(" " .. trunc(line, mw - 2) .. "\n")
    end
    out(A.corner_bl .. string.rep(A.border_h, mw) .. A.corner_br .. "\n")
    out(dim(" Esc закрыть ") .. "\n")
end

local function draw_resume_picker()
    local mw = maxw()
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, mw) .. A.corner_tr .. "\n")
    out(" ┌ возобновить сессию ───────────────────────────────┐\n")
    local items = S.resume_items
    local maxh = math.min(#items, 10)
    for i = 1, 10 do
        if i <= #items then
            local item = items[i]
            if i == S.resume_selected then
                out(reverse(" " .. trunc(item, mw - 4) .. "\n"))
            else
                out(" " .. trunc(item, mw - 4) .. "\n")
            end
        else
            out(string.rep(" ", mw) .. "\n")
        end
    end
    out(" └───────────────────────────────────────────────────────┘\n")
    out(dim(" ↑↓ выбрать · Enter возобновить · Esc закрыть ") .. "\n")
end

-- Input handling
local function input_text()
    local result = {}
    for _, line in ipairs(S.input_lines) do
        result[#result + 1] = line
    end
    return table.concat(result, "\n")
end

local function clear_input()
    S.input_lines = {""}
    S.input_line = 1
    S.input_col = 0
    S.input_offset = 0
    draw_full()
    out(A.user_gutter .. " ")
end

local function add_to_history(text)
    if text and #text > 0 then
        table.insert(S.history_items, 1, text)
        if #S.history_items > 5000 then table.remove(S.history_items) end
        S.history_idx = 0
    end
end

local function navigate_history(dir)
    if #S.history_items == 0 then return end
    S.history_idx = math.max(1, math.min(#S.history_items, S.history_idx + dir))
    if S.history_idx > 0 then
        S.input_lines = {S.history_items[S.history_idx]}
        S.input_line = 1
        S.input_col = #S.input_lines[1]
        S.input_offset = 0
    else
        clear_input()
    end
end

local function handle_slash_command(cmd)
    if cmd == "help" then S.help_active = true
    elseif cmd == "clear" then S.transcript = {}; S.scroll_offset = 0
    elseif cmd == "model" then
        S.palette_active = true
        S.palette_filter = ""
        S.palette_items = {}
        local models = (api and api.list_models) and api.list_models() or {}
        for _, m in ipairs(models) do table.insert(S.palette_items, "/model " .. m) end
        table.insert(S.palette_items, "(ввести имя модели вручную)")
        S.palette_selected = 1
    elseif cmd == "new" then
        S.session_id = session.new_session(S.workspace, S.cfg.model)
        table.insert(S.transcript, {role = "system", text = "↻ Новая сессия"})
    elseif cmd == "status" then S.status_active = true
    elseif cmd == "log" then S.log_active = true
    elseif cmd == "resume" then
        S.resume_active = true
        S.resume_items = {}
        local files = session.session_files(S.workspace)
        for _, f in ipairs(files) do
            local t = f.ts and f.ts:sub(1, 5) or "..."
            local id8 = f.id and f.id:sub(1, 8) or ""
            local preview = f.first_line or ""
            table.insert(S.resume_items, string.format("%s · %s · %s", t, id8, preview:sub(1, 40)))
        end
        S.resume_selected = 1
    elseif cmd == "compact" then
        table.insert(S.transcript, {role = "system", text = "── summary ──"})
    elseif cmd == "quit" then
        S.busy = false
        return "quit"
    else
        table.insert(S.transcript, {role = "error", text = "Неизвестная команда: /" .. cmd})
    end
    return nil
end

local function commit_input()
    local text = input_text()
    if text:match("^%s*$") then clear_input(); return end

    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "/" then
        local cmd = trimmed:match("^/(%w+)")
        if cmd then
            local result = handle_slash_command(cmd)
            clear_input()
            if result == "quit" then return "quit" end
            return
        end
    end

    table.insert(S.transcript, {role = "user", text = text})
    add_to_history(text)
    clear_input()
    S.busy = true

    local ok, err = pcall(function() agent.turn(S.cfg, S.key or "", text, function(ev)
        if ev.type == "text_delta" then
            out(ev.text or "")
        elseif ev.type == "error" then
            table.insert(S.transcript, {role = "error", text = ev.message or "error"})
        elseif ev.type == "confirmation" then
            S.confirmation_active = true
            S.confirmation_details = ev.details or {}
            S.confirmation_selected = 1
            S.busy = false
        elseif ev.type == "usage" then
            S.last_usage = ev.usage
            S.tokens_used = ev.usage.used or 0
            S.tokens_max = ev.usage.max or 32768
        end
    end) end)
    S.busy = false
    if not ok then
        table.insert(S.transcript, {role = "error", text = err or "unknown"})
    end
    draw_full()
    out(A.user_gutter .. " ")
    return nil
end

local function handle_palette_key(c)
    if c == 27 then S.palette_active = false; return true end
    if c == 13 then
        local item = S.palette_items[S.palette_selected]
        if item then
            local cmd = item:match("^/(%w+)")
            if cmd then
                handle_slash_command(cmd)
            end
        end
        S.palette_active = false
        return true
    end
    if c == 9 then -- Tab
        S.palette_selected = math.min(#S.palette_items, S.palette_selected + 1)
        return true
    end
    if c >= 32 and c <= 126 then
        S.palette_filter = S.palette_filter .. string.char(c)
        local filtered = {}
        for _, item in ipairs(S.palette_items) do
            if item:lower():find(S.palette_filter:lower()) then
                table.insert(filtered, item)
            end
        end
        S.palette_items = filtered
        S.palette_selected = 1
        return true
    end
    return false
end

local function drain_escape()
    local c = tether.read_char_nb()
    if not c then return nil end
    c = c & 0xFF
    if c ~= 91 and c ~= 79 then return nil end
    local c2 = tether.read_char_nb()
    if not c2 then return nil end
    c2 = c2 & 0xFF
    if c2 >= 49 and c2 <= 57 then
        local c3 = tether.read_char_nb()
        if c3 then c3 = c3 & 0xFF end
    end
    if c2 == 65 then return "up"
    elseif c2 == 66 then return "down"
    elseif c2 == 67 then return "right"
    elseif c2 == 68 then return "left"
    end
    return nil
end

function M.run()
    S.cfg = config.load()
    S.key = config.api_key(S.cfg)
    S.model_name = S.cfg.model or "unknown"
    S.workspace = S.cfg.workspace or tether.getcwd()
    S.session_id = session.new_session(S.workspace, S.cfg.model)
    S.term_width = 80
    S.term_height = 24
    update_size()

    if S.cfg.ui and S.cfg.ui.mouse and S.cfg.ui.mouse ~= "off" then
        out("\x1b[?1006h\x1b[?1000h")
        S.mouse_reporting = true
    end

    clear()
    draw_full()
    show_cursor()

    while true do
        local c = tether.read_char()
        if c == 0 or c == -1 or c == nil then break end
        c = c & 0xFF

        if S.help_active then
            if c == 27 or c == 63 then S.help_active = false end
            draw_full(); goto continue
        end
        if S.log_active then
            if c == 27 then S.log_active = false end
            draw_full(); goto continue
        end
        if S.status_active then
            if c == 27 then S.status_active = false end
            draw_full(); goto continue
        end
        if S.resume_active then
            if c == 27 then S.resume_active = false end
            if c == 13 and S.resume_items[S.resume_selected] then
                S.resume_active = false
            end
            draw_full(); goto continue
        end

        if S.palette_active then
            if handle_palette_key(c) then draw_full() end
            goto continue
        end

        if S.confirmation_active then
            if c == 121 then -- y
                S.confirmation_active = false
            elseif c == 110 then -- n
                S.confirmation_active = false
            elseif c == 97 then -- a
                S.confirmation_active = false
            elseif c == 65 then -- A
                S.confirmation_active = false
            elseif c == 100 then -- d
                S.diff_text = "diff content"; S.confirmation_active = false
            elseif c == 27 then -- Esc
                S.confirmation_active = false
            end
            draw_full(); goto continue
        end

        if S.diff_text ~= "" then
            if c == 27 then S.diff_text = "" end
            draw_full(); goto continue
        end

        if c == 3 or c == 4 then break end -- Ctrl+C / Ctrl+D

        if c == 12 then -- Ctrl+L
            clear()
            draw_full()
        elseif c == 15 then -- Ctrl+O
            S.expand_all = not S.expand_all
            draw_full()
        elseif c == 20 then -- Ctrl+T
            S.thinking_visible = not S.thinking_visible
            draw_full()
        elseif c == 18 then -- Ctrl+R
            S.resume_active = true
            S.resume_items = {}
            local files = session.session_files(S.workspace)
            for _, f in ipairs(files) do
                local t = f.ts and f.ts:sub(1, 5) or "..."
                local id8 = f.id and f.id:sub(1, 8) or ""
                local preview = f.first_line or ""
                table.insert(S.resume_items, string.format("%s · %s · %s", t, id8, preview:sub(1, 40)))
            end
            S.resume_selected = 1
            draw_full()
        elseif c == 14 then -- Ctrl+N
            S.session_id = session.new_session(S.workspace, S.cfg.model)
            table.insert(S.transcript, {role = "system", text = "↻ Новая сессия"})
            draw_full()
        elseif c == 17 then -- Ctrl+Q
            break
        elseif c == 63 then -- ?
            S.help_active = true
            draw_full()
        elseif c == 27 then -- ESC
            local dir = drain_escape()
            if dir == "up" then navigate_history(-1)
            elseif dir == "down" then navigate_history(1)
            end
        elseif c == 13 then -- Enter (send)
            local result = commit_input()
            if result == "quit" then break end
        elseif c == 10 then -- Ctrl+J (newline)
            if #S.input_lines < ((S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8) then
                S.input_line = S.input_line + 1
                table.insert(S.input_lines, S.input_line, "")
            end
            draw_full()
            out(A.user_gutter .. " ")
        elseif c == 127 or c == 8 then -- Backspace
            if #S.input_lines[S.input_line] > 0 then
                S.input_lines[S.input_line] = S.input_lines[S.input_line]:sub(1, -2)
            elseif #S.input_lines > 1 then
                table.remove(S.input_lines, S.input_line)
                S.input_line = S.input_line - 1
            end
            draw_full()
            out(A.user_gutter .. " ")
        elseif c >= 32 and c <= 126 then -- printable
            S.input_lines[S.input_line] = S.input_lines[S.input_line] .. string.char(c)
            S.input_col = S.input_col + 1
            draw_full()
            out(A.user_gutter .. " ")
        elseif c == 9 then -- Tab
            -- ignore during input
        end

        ::continue::
    end

    out("\x1b[?25h\n")
    if S.mouse_reporting then
        out("\x1b[?1006l\x1b[?1000l")
    end
    show_cursor()
end

return M
