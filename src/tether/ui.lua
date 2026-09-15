-- tether M4+: ui — TUI with full screen layout, slash palette, help, diff
local M = {}

local transcript = {}      -- array of rendered lines (strings)
local input_lines = {""}   -- multi-line input buffer
local input_line = 1       -- cursor line index in input_lines
local input_col = 0        -- cursor column
local input_offset = 0     -- scroll offset within input
local busy = false
local cfg = nil
local key = ""
local version = "0.1.0"

local expanded = {}        -- tool_call_id -> true if expanded
local expand_all = false
local thinking_visible = true
local diff_text = ""
local confirmation_active = false
local confirmation_details = {}
local confirmation_selected = 1
local palette_active = false
local palette_filter = ""
local palette_items = {}
local palette_selected = 1
local help_active = false
local log_active = false
local status_active = false
local resume_active = false
local resume_items = {}
local resume_selected = 1
local history_items = {}     -- input history
local history_idx = 0        -- current position in history (0 = current input)
local scroll_offset = 0      -- transcript scroll offset
local mouse_enabled = false
local mouse_reporting = false
local keyboard_protocol = "none"
local term_width = 80
local term_height = 24
local session_id = ""
local model_name = ""
local workspace = ""
local tokens_used = 0
local tokens_max = 32768
local last_usage = nil

-- ASCII vs unicode mode
local function is_ascii()
    if cfg and cfg.ui and cfg.ui.ascii then
        if cfg.ui.ascii == true then return true end
        if cfg.ui.ascii == false then return false end
    end
    local term = os.getenv("TERM")
    local no_color = os.getenv("NO_COLOR")
    local lang = os.getenv("LANG") or ""
    if term == "dumb" or no_color == "1" or lang:match("^C") then
        return true
    end
    return false
end

local A = {
    user_gutter = is_ascii() and ">" or "›",
    assistant_gutter = is_ascii() and "*" or "●",
    thinking_gutter = is_ascii() and "t" or "✻",
    separator = is_ascii() and "-" or "─",
    corner_tl = is_ascii() and "+" or "┌",
    corner_tr = is_ascii() and "+" or "┐",
    corner_bl = is_ascii() and "+" or "└",
    corner_br = is_ascii() and "+" or "┘",
    border_v = is_ascii() and "|" or "│",
    border_h = is_ascii() and "-" or "─",
    check = is_ascii() and ">" or "▸",
    expand = is_ascii() and ">" or "▾",
    spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
}

local function out(s) tether.write(s) end

-- terminal size
local function update_size()
    local size = tether.get_terminal_size and tether.get_terminal_size()
    if size and size.width and size.height then
        term_width = size.width
        term_height = size.height
    end
end

local function clear_screen()
    out("\x1b[2J\x1b[H")
end

local function hide_cursor()
    out("\x1b[?25l")
end

local function show_cursor()
    out("\x1b[?25h")
end

local function reverse(s)
    return "\x1b[7m" .. s .. "\x1b[0m"
end

local function dim(s)
    return "\x1b[2m" .. s .. "\x1b[0m"
end

local function cyan(s)
    return "\x1b[36;1m" .. s .. "\x1b[0m"
end

local function yellow(s)
    return "\x1b[33;1m" .. s .. "\x1b[0m"
end

local function red(s)
    return "\x1b[31;1m" .. s .. "\x1b[0m"
end

local function green(s)
    return "\x1b[32m" .. s .. "\x1b[0m"
end

local function wrap_text(text, width)
    local lines = {}
    for line in text:gmatch("[^\n]*") do
        while #line > width do
            table.insert(lines, line:sub(1, width))
            line = line:sub(width + 1)
        end
        if #line > 0 then
            table.insert(lines, line)
        end
    end
    return lines
end

-- Truncate to fit terminal width
local function trunc(s, maxw)
    if #s <= maxw then return s end
    return s:sub(1, maxw - 1)
end

-- Render a single transcript message into display lines
local function render_message(msg, maxw)
    local lines = {}
    if msg.role == "user" then
        local prefix = A.user_gutter .. " "
        for _, l in ipairs(wrap_text(msg.text, maxw - #prefix)) do
            table.insert(lines, prefix .. l)
        end
    elseif msg.role == "assistant" then
        local prefix = A.assistant_gutter .. " "
        for _, l in ipairs(wrap_text(msg.text, maxw - #prefix)) do
            table.insert(lines, prefix .. l)
        end
    elseif msg.role == "tool_result" then
        local result = msg.content
        local name = ""
        if result and result.path then name = result.path end
        if result and result.error then
            table.insert(lines, red(A.assistant_gutter .. " " .. name .. ": " .. result.error))
        else
            local summary = ""
            if result.bytes then summary = " " .. result.bytes .. "B" end
            if result.line_count then summary = " " .. result.line_count .. "lines" end
            if result.add and result.del then summary = " +" .. result.add .. " -" .. result.del end
            if result.exit_code ~= nil then summary = " exit " .. result.exit_code end
            if result.elapsed_ms then summary = " " .. result.elapsed_ms .. "ms" end
            table.insert(lines, yellow(A.assistant_gutter .. " " .. name .. summary))
            if expanded[msg.tool_call_id] then
                if result.content and type(result.content) == "string" then
                    for _, l in ipairs(wrap_text(result.content, maxw)) do
                        table.insert(lines, "  " .. l)
                    end
                end
            end
        end
    elseif msg.role == "thinking" then
        local prefix = A.thinking_gutter .. " "
        if thinking_visible then
            table.insert(lines, dim(prefix .. msg.content))
        else
            table.insert(lines, dim(prefix .. "(Ctrl+T to expand)"))
        end
    elseif msg.role == "confirmation" then
        table.insert(lines, red("⚠ confirmation pending"))
    elseif msg.role == "error" then
        table.insert(lines, red(A.assistant_gutter .. " " .. msg.text))
    end
    return lines
end

local function draw_transcript()
    local maxw = math.max(term_width - 2, 20)
    local maxh = term_height - 8  -- reserve for input, hint, status, palette
    local start = scroll_offset + 1
    local count = 0
    for i = 1, #transcript do
        if i >= start and count < maxh then
            local disp = trunc(transcript[i], maxw)
            out(disp .. "\n")
            count = count + 1
        end
    end
end

local function draw_error_banner()
    if #transcript > 0 and transcript[#transcript].role == "error" then
        local maxw = math.max(term_width - 2, 20)
        local text = trunc(transcript[#transcript].text, maxw)
        out(red("\x1b[7m ! " .. text .. "\x1b[0m\n"))
    end
end

local function draw_input()
    local maxw = math.max(term_width - 2, 20)
    local max_lines = cfg and cfg.ui and cfg.ui.input_max_lines or 8
    local indent = "  "
    local prefix = A.user_gutter .. " "

    -- Draw input lines
    for i = 1, math.min(#input_lines, max_lines) do
        local line = input_lines[i]
        if i == input_line then
            -- cursor line — show cursor
            local disp = prefix .. line
            if #disp > maxw then disp = trunc(disp, maxw) end
            out(disp .. "\x1b[0m" .. utf8.char(0x2588) .. "\x1b[0m\n")
        else
            local disp = prefix .. line
            if #disp > maxw then disp = trunc(disp, maxw) end
            out(disp .. "\n")
        end
    end

    -- Fill remaining lines with empty input
    for i = #input_lines + 1, max_lines do
        out("\n")
    end
end

local function draw_palette()
    if not palette_active then return end
    local maxw = math.max(term_width - 2, 20)
    local maxh = math.min(#palette_items, 10)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    for i = 1, maxh do
        local item = palette_items[i]
        if i == palette_selected then
            out(reverse(" " .. item .. string.rep(" ", math.max(maxw - #item - 1, 0)) .. " "))
        else
            out(" " .. trunc(item, maxw) .. "\n")
        end
    end
    for i = #palette_items + 1, 10 do
        out(string.rep(" ", maxw) .. "\n")
    end
    out(A.corner_bl .. string.rep(A.border_h, maxw) .. A.corner_br .. "\n")
    out("\x1b[37m↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть\x1b[0m\n")
end

local function draw_hint()
    local maxw = math.max(term_width - 2, 20)
    local text = ""
    if palette_active then
        text = "↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть"
    elseif busy then
        text = "Ctrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл"
    elseif confirmation_active then
        text = "↑↓ выбрать · Enter подтвердить · y/a/A/d/n горячие · Esc отмена"
    elseif diff_text ~= "" then
        text = "↑↓ скролл · [/] файл · Esc закрыть"
    else
        text = "Enter отправить · Ctrl+J новая строка · Ctrl+C отмена · / палитра · ? помощь"
    end
    out(dim("  " .. trunc(text, maxw)) .. "\n")
end

local function draw_status()
    local maxw = math.max(term_width - 2, 20)
    local parts = {}
    table.insert(parts, model_name or "unknown")
    local home = os.getenv("HOME") or ""
    local display_ws = workspace
    if home ~= "" and workspace:sub(1, #home) == home then
        display_ws = "~" .. workspace:sub(#home + 1)
    end
    table.insert(parts, display_ws)
    if last_usage then
        table.insert(parts, string.format("%.1fk/%.1fk (%.0f%%)",
            last_usage.used / 1024, last_usage.max / 1024,
            last_usage.used / last_usage.max * 100))
    end
    table.insert(parts, "🖱 on")
    local line = table.concat(parts, " · ")
    if #line > maxw then
        -- truncate from right
        line = line:sub(1, maxw)
    end
    out("\x1b[7m " .. line .. " \x1b[0m\n")
end

local function draw_full()
    clear_screen()
    draw_transcript()
    if diff_text ~= "" and not palette_active then
        draw_diff_overlay()
        return
    end
    if help_active then
        draw_help_overlay()
        return
    end
    if log_active then
        draw_log_overlay()
        return
    end
    if status_active then
        draw_status_overlay()
        return
    end
    if resume_active then
        draw_resume_picker()
        return
    end
    draw_error_banner()
    draw_input()
    draw_palette()
    draw_hint()
    draw_status()
    hide_cursor()
end

-- Diff overlay
local function draw_diff_overlay()
    local maxw = math.max(term_width - 2, 20)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    local lines = {}
    for line in diff_text:gmatch("[^\n]*") do
        table.insert(lines, line)
    end
    for _, line in ipairs(lines) do
        if line:match("^%+%+%+") then
            out(" " .. A.border_v .. " " .. dim(line:sub(2)) .. "\n")
        elseif line:match("^%-%-%-") then
            out(" " .. A.border_v .. " " .. dim(line:sub(2)) .. "\n")
        elseif line:match("^@@") then
            out(" " .. A.border_v .. " " .. line .. "\n")
        elseif line:match("^+") then
            out(" " .. A.border_v .. " " .. green(line) .. "\n")
        elseif line:match("^-") then
            out(" " .. A.border_v .. " " .. red(line) .. "\n")
        elseif line:match("^%s") then
            out(" " .. A.border_v .. " " .. line .. "\n")
        else
            out(" " .. A.border_v .. " " .. line .. "\n")
        end
    end
    out(string.rep(A.border_h, maxw) .. "\n")
    out(dim(" [/] файл · ↑↓ скролл · PgUp/PgDn · g/G · Esc закрыть ") .. "\n")
end

-- Help overlay
local function draw_help_overlay()
    local maxw = math.max(term_width - 2, 20)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    local help_text = {
        "Ввод         Enter отправить · Ctrl+J / Shift+Enter newline",
        "              ↑↓ история · Ctrl+A/E/U/W/K · Ctrl+V вставка",
        "Навигация     PgUp/PgDn · Ctrl+Home/End · мышь-колесо",
        "Транскрипт    Ctrl+O развернуть · Ctrl+T thinking · Ctrl+L очистить",
        "              Ctrl+R возобновить · Ctrl+N новая · Ctrl+Q выход",
        "Палитра       / модель · /help · /clear · /new · /status · /log · /quit",
        "Confirmation  y/A/d/n горячие · ↑↓ при confirmation с потоком",
        "Прочее        ? помощь · F1 ошибки · --debug лог",
    }
    for _, line in ipairs(help_text) do
        out(" " .. trunc(line, maxw - 2) .. "\n")
    end
    out(string.rep(A.border_h, maxw) .. "\n")
    out(dim(" ? закрыть ") .. "\n")
end

-- Log overlay
local function draw_log_overlay()
    local maxw = math.max(term_width - 2, 20)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    out(dim("Последние ошибки из лога:") .. "\n")
    out(dim("Функционал лог-файла доступен при --debug") .. "\n")
    out(string.rep(A.border_h, maxw) .. "\n")
    out(dim(" Esc закрыть ") .. "\n")
end

-- Status overlay
local function draw_status_overlay()
    local maxw = math.max(term_width - 2, 20)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    local lines = {
        "Сессия: " .. session_id,
        "Workspace: " .. workspace,
        "Модель: " .. model_name,
        "Токены: " .. tokens_used .. "/" .. tokens_max,
        "Инструментов выполнено: " .. #transcript,
        "Старт: " .. os.date("%Y-%m-%d %H:%M:%S"),
    }
    for _, line in ipairs(lines) do
        out(" " .. trunc(line, maxw - 2) .. "\n")
    end
    out(string.rep(A.border_h, maxw) .. "\n")
    out(dim(" Esc закрыть ") .. "\n")
end

-- Resume picker
local function draw_resume_picker()
    local maxw = math.max(term_width - 2, 20)
    out("\x1b[2J\x1b[H")
    out(A.corner_tl .. string.rep(A.border_h, maxw) .. A.corner_tr .. "\n")
    out(" ┌ возобновить сессию ───────────────────────────────────┐\n")
    local items = resume_items
    local maxh = math.min(#items, 10)
    for i = 1, maxh do
        local item = items[i]
        if i == resume_selected then
            out(reverse(" " .. item .. string.rep(" ", maxw - #item - 3) .. " "))
        else
            out(" " .. trunc(item, maxw - 2) .. "\n")
        end
    end
    for i = #items + 1, 10 do
        out(string.rep(" ", maxw) .. "\n")
    end
    out(" └───────────────────────────────────────────────────────┘\n")
    out(dim(" ↑↓ выбрать · Enter возобновить · Esc закрыть ") .. "\n")
end

-- Input handling
local function input_text()
    local result = ""
    for _, line in ipairs(input_lines) do
        result = result .. line .. "\n"
    end
    result = result:gsub("\n$", "")
    return result
end

local function clear_input()
    input_lines = {""}
    input_line = 1
    input_col = 0
    input_offset = 0
end

local function add_to_history(text)
    if text and #text > 0 then
        table.insert(history_items, 1, text)
        if #history_items > 5000 then
            table.remove(history_items)
        end
        history_idx = 0
    end
end

local function navigate_history(dir)
    if #history_items == 0 then return end
    history_idx = math.max(0, math.min(#history_items, history_idx + dir))
    if history_idx > 0 then
        input_lines = {history_items[history_idx]}
        input_line = 1
        input_col = #input_lines[1]
    else
        input_lines = {""}
        input_line = 1
        input_col = 0
    end
end

local function commit_input()
    local text = input_text()
    if text:match("^%s*$") then
        clear_input()
        draw_full()
        out(A.user_gutter .. " ")
        return
    end

    -- Check for slash commands
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "/" and not palette_active then
        -- Handle slash command directly if it's a simple one
        local cmd = trimmed:match("^/([^%s]+)")
        local arg = trimmed:match("^/%s*(%S+)")
        handle_slash_command(cmd or trimmed)
        clear_input()
        draw_full()
        out(A.user_gutter .. " ")
        return
    end

    -- Add to transcript
    table.insert(transcript, {role = "user", text = text})
    add_to_history(text)
    clear_input()
    draw_full()
    out("… ")

    -- Run agent
    busy = true
    local ok, err = agent.turn(cfg, key, text, function(ev)
        if ev.type == "text_delta" then
            out(ev.text or "")
        elseif ev.type == "reasoning_delta" then
            if thinking_visible then
                out(ev.text or "")
            end
        elseif ev.type == "error" then
            out("\n")
            table.insert(transcript, {role = "error", text = ev.message or "error"})
        elseif ev.type == "confirmation" then
            confirmation_active = true
            confirmation_selected = 1
            confirmation_details = ev.details or {}
            busy = false
            draw_full()
            out(A.user_gutter .. " ")
            return
        elseif ev.type == "usage" then
            last_usage = ev.usage
        elseif ev.type == "done" then
            busy = false
        end
    end)
    busy = false
    out("\n")

    if confirmation_active then
        return
    end

    if not ok then
        table.insert(transcript, {role = "error", text = err or "unknown error"})
    end

    draw_full()
    out(A.user_gutter .. " ")
end

local function handle_slash_command(cmd)
    if cmd == "help" then
        help_active = true
    elseif cmd == "clear" then
        transcript = {}
        scroll_offset = 0
    elseif cmd == "model" then
        -- Open model palette
        palette_active = true
        palette_filter = ""
        palette_items = {}
        local models = api.list_models and api.list_models() or {}
        for _, m in ipairs(models) do
            table.insert(palette_items, "/model " .. m)
        end
        table.insert(palette_items, "(ввести имя модели вручную)")
        palette_selected = 1
        draw_full()
        out(A.user_gutter .. " /model ")
    elseif cmd == "new" then
        -- Start new session
        table.insert(transcript, {role = "system", text = "── session_end ──"})
        session_id = session.new_session(workspace, cfg.model)
        table.insert(transcript, {role = "system", text = "↻ Новая сессия " .. session_id})
    elseif cmd == "status" then
        status_active = true
    elseif cmd == "log" then
        log_active = true
    elseif cmd == "resume" then
        -- Open resume picker
        resume_active = true
        resume_items = {}
        local files = session.session_files(workspace)
        for _, f in ipairs(files) do
            local time = f.ts and f.ts:sub(1, 5) or "..."
            local id8 = f.id and f.id:sub(1, 8) or ""
            local preview = f.first_line or ""
            table.insert(resume_items, string.format("%s · %s · %s", time, id8, preview:sub(1, 40)))
        end
        resume_selected = 1
        draw_full()
    elseif cmd == "compact" then
        table.insert(transcript, {role = "system", text = "── summary ──"})
    elseif cmd == "quit" then
        table.insert(transcript, {role = "system", text = "── session_end ──"})
        busy = false
        return
    elseif cmd == "model" then
        -- handled above
    else
        -- Unknown command
        table.insert(transcript, {role = "error", text = "Неизвестная команда: /" .. cmd})
    end
end

local function handle_confirmation_input(c)
    if c == 121 then -- y
        for _, detail in ipairs(confirmation_details) do
            if detail.id then agent.confirm(detail.id, "allow", cfg) end
        end
        confirmation_active = false
        return true
    elseif c == 110 then -- n
        for _, detail in ipairs(confirmation_details) do
            if detail.id then agent.confirm(detail.id, "deny", cfg) end
        end
        confirmation_active = false
        return true
    elseif c == 97 then -- a
        for _, detail in ipairs(confirmation_details) do
            if detail.id then agent.confirm(detail.id, "allow", cfg) end
        end
        confirmation_active = false
        return true
    elseif c == 65 then -- A
        for _, detail in ipairs(confirmation_details) do
            if detail.id then agent.confirm(detail.id, "allow", cfg) end
        end
        confirmation_active = false
        return true
    elseif c == 100 then -- d
        diff_text = "Full diff content"
        draw_full()
        return true
    elseif c == 27 then -- Esc
        confirmation_active = false
        return true
    elseif c == 115 or c == 110 then -- s/↓ (scroll down in confirmation)
        confirmation_selected = math.min(#confirmation_details, confirmation_selected + 1)
        draw_full()
        return true
    elseif c == 16 or c == 105 then -- p/↑ (scroll up in confirmation)
        confirmation_selected = math.max(1, confirmation_selected - 1)
        draw_full()
        return true
    end
    return false
end

local function handle_palette_input(c)
    if c == 27 then -- Esc — close palette
        palette_active = false
        return true
    elseif c == 13 then -- Enter — execute
        local item = palette_items[palette_selected]
        if item then
            local cmd = item:match("^/(%w+)")
            if cmd then
                handle_slash_command(cmd)
            end
        end
        palette_active = false
        return true
    elseif c == 9 then -- Tab
        palette_selected = math.min(#palette_items, palette_selected + 1)
        draw_full()
        return true
    elseif c == 115 then -- ↓
        palette_selected = math.min(#palette_items, palette_selected + 1)
        draw_full()
        return true
    elseif c == 112 then -- ↑
        palette_selected = math.max(1, palette_selected - 1)
        draw_full()
        return true
    elseif c >= 32 and c <= 126 then
        palette_filter = palette_filter .. string.char(c)
        palette_selected = 1
        -- Filter items
        local filtered = {}
        for _, item in ipairs(palette_items) do
            if item:lower():find(palette_filter:lower()) then
                table.insert(filtered, item)
            end
        end
        palette_items = filtered
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

local function handle_resize()
    update_size()
    draw_full()
end

function M.run()
    cfg = config.load()
    key = config.api_key(cfg)
    model_name = cfg.model or "unknown"
    workspace = cfg.workspace or tether.getcwd()
    term_width = 80
    term_height = 24
    update_size()

    -- Enable mouse reporting if configured
    if cfg.ui and cfg.ui.mouse and cfg.ui.mouse ~= "off" then
        out("\x1b[?1006h\x1b[?1000h")
        mouse_reporting = true
    end

    -- Detect keyboard protocol
    if cfg.ui and cfg.ui.keyboard_protocol == "kitty" then
        out("\x1b[>1u")
        keyboard_protocol = "kitty"
    elseif cfg.ui and cfg.ui.keyboard_protocol == "modifyOtherKeys" then
        out("\x1b[>4m")
        keyboard_protocol = "modifyOtherKeys"
    end

    clear_screen()
    draw_full()
    out(A.user_gutter .. " ")
    show_cursor()

    while true do
        local c = tether.read_char()
        if c == 0 or c == -1 then break end
        c = c & 0xFF

        if help_active then
            if c == 27 or c == 63 then help_active = false end
            draw_full()
            goto continue
        end

        if log_active then
            if c == 27 then log_active = false end
            draw_full()
            goto continue
        end

        if status_active then
            if c == 27 then status_active = false end
            draw_full()
            goto continue
        end

        if resume_active then
            if c == 27 then resume_active = false; draw_full(); out(A.user_gutter .. " ") end
            if c == 13 then
                if resume_items[resume_selected] then
                    local id = resume_items[resume_selected]:match("%a(%w+)")
                    if id then session.resume(id) end
                    resume_active = false
                    draw_full()
                    out(A.user_gutter .. " ")
                end
            end
            goto continue
        end

        if palette_active then
            if handle_palette_input(c) then goto continue end
        end

        if confirmation_active then
            if handle_confirmation_input(c) then draw_full(); out(A.user_gutter .. " ") end
            goto continue
        end

        if diff_text ~= "" then
            if handle_diff_input(c) then draw_full(); out(A.user_gutter .. " ") end
            goto continue
        end

        if c == 3 or c == 4 then -- Ctrl+C / Ctrl+D
            break
        elseif c == 12 then -- Ctrl+L — clear screen
            clear_screen()
            draw_full()
            out(A.user_gutter .. " ")
        elseif c == 15 then -- Ctrl+O — toggle expand
            expand_all = not expand_all
            draw_full()
            out(A.user_gutter .. " ")
        elseif c == 20 then -- Ctrl+T — toggle thinking
            thinking_visible = not thinking_visible
            draw_full()
            out(A.user_gutter .. " ")
        elseif c == 18 then -- Ctrl+R — resume
            resume_active = true
            local files = session.session_files(workspace)
            resume_items = {}
            for _, f in ipairs(files) do
                local time = f.ts and f.ts:sub(1, 5) or "..."
                local id8 = f.id and f.id:sub(1, 8) or ""
                local preview = f.first_line or ""
                table.insert(resume_items, string.format("%s · %s · %s", time, id8, preview:sub(1, 40)))
            end
            resume_selected = 1
            draw_full()
            goto continue
        elseif c == 14 then -- Ctrl+N — new session
            session_id = session.new_session(workspace, cfg.model)
            table.insert(transcript, {role = "system", text = "↻ Новая сессия"})
            draw_full()
            out(A.user_gutter .. " ")
            goto continue
        elseif c == 17 then -- Ctrl+Q — quit
            break
        elseif c == 63 then -- ? — help
            help_active = true
            draw_full()
            goto continue
        elseif c == 19 then -- Ctrl+S — save (no-op in this version)
            goto continue
        elseif c == 27 then -- ESC — escape sequence
            drain_escape()
        elseif c == 13 or c == 10 then -- Enter
            if not busy then
                if palette_active then
                    handle_palette_input(c)
                else
                    commit_input()
                end
            end
        elseif c == 10 then -- Ctrl+J — newline
            if not busy and #input_lines < (cfg and cfg.ui and cfg.ui.input_max_lines or 8) then
                table.insert(input_lines, input_line + 1, "")
                input_line = input_line + 1
                input_col = 0
            end
        elseif c == 127 or c == 8 then -- Backspace
            if #input_lines[input_line] > 0 then
                input_lines[input_line] = input_lines[input_line]:sub(1, -2)
            elseif #input_lines > 1 then
                table.remove(input_lines, input_line)
                input_line = input_line - 1
                input_col = #input_lines[input_line]
            end
        elseif c == 24 then -- Ctrl+X — kill line
            input_lines[input_line] = ""
            input_col = 0
        elseif c >= 32 and c <= 126 then -- printable
            input_lines[input_line] = input_lines[input_line] .. string.char(c)
            input_col = input_col + 1
        elseif c == 27 then -- ESC sequence starts
            drain_escape()
        elseif c >= 1 and c <= 26 then -- Ctrl+A-Z display
            -- ignore
        end

        ::continue::
    end
    out("\x1b[?25h\n")
    if mouse_reporting then
        out("\x1b[?1006l\x1b[?1000l")
    end
    show_cursor()
end

return M
