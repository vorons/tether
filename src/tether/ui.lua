-- tether / ui.lua — TUI with line-diff redraw.
local M = {}

-- ============================================================
-- ANSI
-- ============================================================
local ESC = "\27"
local function w(s) tether.write(s) end

-- T20: ASCII mode — NO_COLOR=1 or TERM=dumb → strip all ANSI + non-ASCII glyphs
local _ascii = (os.getenv("NO_COLOR") == "1") or (os.getenv("TERM") == "dumb")
local function sgr(c, s)
    if _ascii then return s end
    return ESC .. "[" .. c .. "m" .. s .. ESC .. "[0m"
end
local function cyan(s)   return sgr("36;1", s) end
local function yellow(s) return sgr("33;1", s) end
local function red(s)    return sgr("31;1", s) end
local function green(s)  return sgr("32",   s) end
local function dim(s)    return sgr("2",    s) end
local function italic(s) return sgr("3",    s) end
local function rev(s)    return sgr("7",    s) end

local function glyph(g)
    if not _ascii then return g end
    local map = {
        ["\226\128\176"] = "[?]",  -- ◻
        ["\226\128\177"] = "[x]",  -- ◻
        ["\255\180\177"] = "->",   -- arrow
        ["\226\142\156"]  = "*",   -- ⚙ gear
        ["\226\128\150"]  = "!",   -- ⚠ warning
        ["\226\128\155"]  = "x",   -- ✗
        ["\226\128\148"]  = "v",   -- ✓
        ["\226\128\156"]  = "!",   -- ❌
        ["\226\128\185"]  = ">>",  -- ➡
        ["\226\128\184"]  = "<<",  -- ⬅
        ["\226\128\154"]  = "o",   -- ⬤
    }
    return map[g] or g
end

-- ============================================================
-- UTF-8 / string helpers
-- ============================================================
local function ulen(s) return utf8.len(s) or #s end
local function usub(s, i, j) return utf8.sub(s, i, j) end

local function wrap(text, width)
    if width < 1 then width = 1 end
    local out = {}
    for para in (text .. "\n"):gmatch("([^\n]*)\n") do
        if para == "" then
            out[#out + 1] = ""
        else
            local line = para
            while true do
                local n = ulen(line)
                if n <= width then out[#out + 1] = line; break end
                out[#out + 1] = usub(line, 1, width)
                line = usub(line, width + 1)
            end
        end
    end
    return out
end

local function trunc(s, maxw)
    if maxw < 1 then return "" end
    if ulen(s) <= maxw then return s end
    return usub(s, 1, maxw - 1) .. "…"
end

-- ============================================================
-- Constants
-- ============================================================
local SLASH_COMMANDS = {
    { label = "/help",    desc = "справка по клавишам",              cmd = "help" },
    { label = "/clear",   desc = "очистить транскрипт",              cmd = "clear" },
    { label = "/compact", desc = "сжать контекст (суммаризация)",    cmd = "compact" },
    { label = "/model",   desc = "сменить модель",                   cmd = "model" },
    { label = "/resume",  desc = "возобновить сессию для workspace", cmd = "resume" },
    { label = "/new",     desc = "начать новую сессию",              cmd = "new" },
    { label = "/status",  desc = "полный статус сессии",             cmd = "status" },
    { label = "/log",     desc = "последние ошибки из лога",         cmd = "log" },
    { label = "/quit",    desc = "выход",                            cmd = "quit" },
}

-- ============================================================
-- State
-- ============================================================
local S
local debug_log_fh = nil
local function debug_log(msg)
    if not debug_log_fh then return end
    pcall(io.write, debug_log_fh, os.date("[%H:%M:%S] ") .. msg .. "\n")
end
local function init_debug_log()
    if S and S.debug and debug_log_fh == nil then
        local ok, fh = pcall(io.open, os.getenv("HOME") and (os.getenv("HOME") .. "/.tether/log/tether.log") or "/dev/null", "a")
        if ok and fh then
            debug_log_fh = fh
            pcall(fh.mkdir)
        end
    end
end

local function new_state()
    return {
        w = 80, h = 24,
        last_w = -1, last_h = -1,
        screen = {},

        cfg = nil,
        model_name = "?",
        workspace = "",
        session_id = "?",
        api_key = nil,

        transcript = {},
        transcript_ver = 0,
        transcript_cache = nil,
        transcript_cache_ver = -1,

        input = "",
        cursor = 0,  -- byte offset

        busy = false,
        quit = false,

        error_banner = nil,

        expanded = {},
        expand_all = false,
        thinking_visible = true,

        palette_active = false,
        palette_items = {},
        palette_sel = 1,

        confirmation = nil,
        confirmation_sel = 1,

        overlay = nil,
        overlay_data = nil,

        history = {},
        history_pos = 0,

        scroll = 0,
        user_scrolled = false,

        tokens_used = 0,
        tokens_max = 32768,
    }
end

local function bump_transcript()
    S.transcript_ver = S.transcript_ver + 1
    S.transcript_cache = nil
end

-- ============================================================
-- Layout
-- ============================================================
local function input_lines()
    local out = {}
    local pos = 1
    while true do
        local nl = S.input:find("\n", pos, true)
        if not nl then
            out[#out + 1] = { text = S.input:sub(pos), from = pos - 1 }
            break
        end
        out[#out + 1] = { text = S.input:sub(pos, nl - 1), from = pos - 1 }
        pos = nl + 1
    end
    return out
end

local function layout()
    local total = #input_lines()
    local max_in = (S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8
    local shown_in = math.min(total, max_in)
    if shown_in < 1 then shown_in = 1 end

    local palette_h = 0
    if S.palette_active and #S.palette_items > 0 then
        palette_h = math.min(#S.palette_items, 8) + 2
    end
    local error_h = S.error_banner and 1 or 0

    local fixed = shown_in + palette_h + error_h + 2
    local th = S.h - fixed
    if th < 1 then th = 1 end

    return {
        w = S.w, h = S.h,
        transcript_row = 1,
        transcript_h = th,
        error_row = 1 + th,
        error_h = error_h,
        input_row = 1 + th + error_h,
        input_h = shown_in,
        input_total = total,
        palette_row = 1 + th + error_h + shown_in,
        palette_h = palette_h,
        hint_row = S.h - 1,
        status_row = S.h,
    }
end

-- ============================================================
-- Screen buffer (row diff)
-- ============================================================
local frame
local function frame_start()
    frame = { ESC .. "[?25l" }
end
local function frame_put(s)
    frame[#frame + 1] = s
end
local function frame_flush()
    if #frame > 0 then w(table.concat(frame)) end
    frame = nil
end
local function set_row(row, content)
    if row < 1 or row > S.h then return end
    if S.screen[row] == content then return end
    frame_put(ESC .. "[" .. row .. ";1H" .. ESC .. "[K" .. content)
    S.screen[row] = content
end

-- ============================================================
-- Palette: derived from input
-- ============================================================
local function palette_sync()
    local first = S.input
    local nl = first:find("\n", 1, true)
    if nl then first = first:sub(1, nl - 1) end

    if first:sub(1, 1) ~= "/" then
        S.palette_active = false
        S.palette_items = {}
        S.palette_sel = 1
        return
    end
    local filter = first:sub(2):lower()
    if filter:find(" ", 1, true) then
        -- user has typed arguments — palette out of scope
        S.palette_active = false
        S.palette_items = {}
        S.palette_sel = 1
        return
    end

    S.palette_active = true
    local items = {}
    for _, c in ipairs(SLASH_COMMANDS) do
        -- strip leading '/': label is "/help", name is "help"
        local name = c.label:sub(2):lower()
        if filter == "" or name:find(filter, 1, true) == 1 then
            items[#items + 1] = c
        end
    end
    S.palette_items = items
    if S.palette_sel < 1 then S.palette_sel = 1 end
    if S.palette_sel > #items then S.palette_sel = #items end
    if #items == 0 then S.palette_sel = 1 end
end

-- ============================================================
-- Input model
-- ============================================================
local function input_insert(s)
    if s:find("\n", 1, true) then
        -- respect line cap
        local total = #input_lines()
        local extra = select(2, s:gsub("\n", ""))
        if total + extra > ((S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8) then
            s = s:gsub("\n", " ")
        end
    end
    S.input = S.input:sub(1, S.cursor) .. s .. S.input:sub(S.cursor + 1)
    S.cursor = S.cursor + #s
    palette_sync()
end

local function input_backspace()
    if S.cursor <= 0 then return end
    S.input = S.input:sub(1, S.cursor - 1) .. S.input:sub(S.cursor + 1)
    S.cursor = S.cursor - 1
    palette_sync()
end

local function input_delete()
    if S.cursor >= #S.input then return end
    S.input = S.input:sub(1, S.cursor) .. S.input:sub(S.cursor + 2)
    palette_sync()
end

local function input_clear()
    S.input = ""
    S.cursor = 0
    palette_sync()
end

local function cursor_line_col()
    local lines = input_lines()
    for i, ln in ipairs(lines) do
        if S.cursor >= ln.from and S.cursor <= ln.from + #ln.text then
            return i, S.cursor - ln.from
        end
    end
    local last = lines[#lines]
    return #lines, #last.text
end

local function set_cursor(li, col)
    local lines = input_lines()
    if li < 1 then li = 1 end
    if li > #lines then li = #lines end
    local ln = lines[li]
    if col < 0 then col = 0 end
    if col > #ln.text then col = #ln.text end
    S.cursor = ln.from + col
end

local function move_cursor_up()
    local li, col = cursor_line_col()
    if li <= 1 then return false end
    set_cursor(li - 1, col)
    return true
end

local function move_cursor_down()
    local li, col = cursor_line_col()
    if li >= #input_lines() then return false end
    set_cursor(li + 1, col)
    return true
end

local function move_line_start()
    local li = cursor_line_col()
    set_cursor(li, 0)
end

local function move_line_end()
    local li = cursor_line_col()
    local lines = input_lines()
    set_cursor(li, #lines[li].text)
end

local function kill_to_start()
    local li, col = cursor_line_col()
    local lines = input_lines()
    local ln = lines[li]
    S.input = S.input:sub(1, ln.from) .. ln.text:sub(col + 1) ..
              S.input:sub(ln.from + #ln.text + 1)
    S.cursor = ln.from
    palette_sync()
end

local function kill_to_end()
    local li, col = cursor_line_col()
    local lines = input_lines()
    local ln = lines[li]
    S.input = S.input:sub(1, ln.from + col)
    S.cursor = ln.from + col
    palette_sync()
end

local function kill_word_before()
    local li, col = cursor_line_col()
    local lines = input_lines()
    local ln = lines[li]
    if col == 0 then return end
    local head = ln.text:sub(1, col)
    local new_head = head:gsub("%s*%S+%s*$", "")
    S.input = S.input:sub(1, ln.from) .. new_head ..
              ln.text:sub(col + 1) .. S.input:sub(ln.from + #ln.text + 1)
    S.cursor = ln.from + #new_head
    palette_sync()
end

-- ============================================================
-- History
-- ============================================================
local function push_history(text)
    if not text or text == "" then return end
    if S.history[1] == text then return end
    table.insert(S.history, 1, text)
    if #S.history > 5000 then table.remove(S.history) end
    S.history_pos = 0
end

local function history_prev()
    if #S.history == 0 then return end
    local p = S.history_pos + 1
    if p > #S.history then p = #S.history end
    S.history_pos = p
    S.input = S.history[p]
    S.cursor = #S.input
    palette_sync()
end

local function history_next()
    if S.history_pos <= 1 then
        S.history_pos = 0
        input_clear()
        return
    end
    S.history_pos = S.history_pos - 1
    S.input = S.history[S.history_pos]
    S.cursor = #S.input
    palette_sync()
end

-- ============================================================
-- Transcript rendering
-- ============================================================
local function with_prefix(prefix, pad_n, body)
    local out = {}
    local pad = string.rep(" ", pad_n)
    for i, l in ipairs(body) do
        out[#out + 1] = (i == 1 and prefix or pad) .. l
    end
    if #out == 0 then out[1] = prefix end
    return out
end

local function render_entry(e, width)
    local role = e.role or "system"
    if role == "user" then
        return with_prefix(cyan("›") .. " ", 2,
            wrap(e.text or "", math.max(width - 2, 1)))
    elseif role == "assistant" then
        if (e.text or "") == "" then return {} end
        return with_prefix("● ", 2, wrap(e.text, math.max(width - 2, 1)))
    elseif role == "thinking" then
        if not S.thinking_visible then
            return { dim("✻ thinking ▸ (Ctrl+T)") }
        end
        local out = { dim(italic("✻ thinking ▾")) }
        for _, l in ipairs(wrap(e.text or "", math.max(width - 2, 1))) do
            out[#out + 1] = "  " .. dim(l)
        end
        return out
    elseif role == "error" then
        return with_prefix(red("✗") .. " ", 2,
            wrap(e.text or "", math.max(width - 2, 1)))
    elseif role == "system" then
        return { dim(e.text or "") }
    elseif role == "tool" then
        local marker = e.status == "error" and "✗" or "⚙"
        local col = e.status == "error" and red or yellow
        local head = col(marker .. " " .. (e.name or "?"))
        if e.summary and e.summary ~= "" then
            head = head .. "  " .. dim(e.summary)
        end
        local out = { head }
        local show = e.body and e.body ~= "" and
                     (e.always_show or S.expanded[e.id] or S.expand_all)
        if show then
            local bl = wrap(e.body, math.max(width - 2, 1))
            local cap = e.collapse_lines or 200
            for i, l in ipairs(bl) do
                if i > cap then
                    out[#out + 1] = "  " .. dim("… (" .. (#bl - i + 1) .. " строк скрыто)")
                    break
                end
                out[#out + 1] = "  " .. l
            end
        end
        return out
    elseif role == "diff" then
        local out = { dim("┌ " .. (e.path or "diff")) }
        for _, l in ipairs(wrap(e.text or "", math.max(width - 4, 1))) do
            local c = l:sub(1, 1)
            if c == "+" then out[#out + 1] = green("│ " .. l)
            elseif c == "-" then out[#out + 1] = red("│ " .. l)
            else out[#out + 1] = dim("│ " .. l) end
        end
        out[#out + 1] = dim("└" .. string.rep("─", math.max(width - 2, 0)))
        return out
    end
    return {}
end

local function display_lines()
    if S.transcript_cache and S.transcript_cache_ver == S.transcript_ver then
        return S.transcript_cache
    end
    local L = layout()
    local lines = {}
    for _, e in ipairs(S.transcript) do
        for _, l in ipairs(render_entry(e, L.w)) do
            lines[#lines + 1] = l
        end
    end
    if S.confirmation then
        local c = S.confirmation
        lines[#lines + 1] = ""
        lines[#lines + 1] = yellow("⚠ " .. (c.label or "подтверждение"))
        for _, l in ipairs(wrap(c.body or "", L.w - 2)) do
            lines[#lines + 1] = "  " .. l
        end
        local opts = c.options or { "[y] once", "[n] deny", "[Esc] cancel" }
        for i, opt in ipairs(opts) do
            local t = "  " .. opt
            lines[#lines + 1] = (i == S.confirmation_sel) and rev(t) or t
        end
    end
    S.transcript_cache = lines
    S.transcript_cache_ver = S.transcript_ver
    return lines
end

-- ============================================================
-- Region renderers
-- ============================================================
local function render_transcript(L)
    local lines = display_lines()
    local total = #lines
    local bottom = total - S.scroll
    if bottom > total then bottom = total end
    if bottom < 1 then bottom = 1 end
    local top = bottom - L.transcript_h + 1
    for i = 1, L.transcript_h do
        local idx = top + i - 1
        local text = (idx >= 1 and idx <= total) and lines[idx] or ""
        set_row(L.transcript_row + i - 1, text)
    end
end

local function render_error_banner(L)
    if not S.error_banner then return end
    set_row(L.error_row, rev(red(" ! ")) .. " " .. red(trunc(S.error_banner, L.w - 4)))
end

local function render_input(L)
    local lines = input_lines()
    local total = #lines
    local shown = L.input_h
    local start = 1
    if total > shown then
        local li = cursor_line_col()
        start = li - math.floor(shown / 2)
        if start < 1 then start = 1 end
        if start > total - shown + 1 then start = total - shown + 1 end
    end
    for i = 1, shown do
        local li = start + i - 1
        local ln = lines[li]
        if not ln then
            set_row(L.input_row + i - 1, "")
        else
            local prefix = (li == 1) and (cyan("›") .. " ") or "  "
            set_row(L.input_row + i - 1, prefix .. ln.text)
        end
    end
end

local function render_palette(L)
    if not S.palette_active or #S.palette_items == 0 then return end
    local shown = math.min(#S.palette_items, L.palette_h - 2)
    set_row(L.palette_row, dim("┌" .. string.rep("─", math.max(L.w - 2, 0)) .. "┐"))
    for i = 1, shown do
        local it = S.palette_items[i]
        local text = string.format(" %-10s %s", it.label or "", it.desc or "")
        text = trunc(text, L.w - 3)
        local row = L.palette_row + i
        set_row(row, (i == S.palette_sel) and rev(text) or text)
    end
    set_row(L.palette_row + shown + 1,
        dim("└" .. string.rep("─", math.max(L.w - 2, 0)) .. "┘"))
end

local function render_hint(L)
    local text
    if S.palette_active then
        text = "↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть"
    elseif S.confirmation then
        text = "↑↓ выбрать · Enter подтвердить · y/a/A/d/n · Esc отмена"
    elseif S.busy then
        text = "Ctrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл"
    elseif S.overlay then
        text = "Esc закрыть"
    else
        text = "Enter отправить · Ctrl+J новая строка · Ctrl+C отмена · ? помощь"
    end
    set_row(L.hint_row, dim(trunc(text, L.w)))
end

local function render_status(L)
    local home = os.getenv("HOME") or ""
    local ws = S.workspace
    if home ~= "" and ws:sub(1, #home) == home then
        ws = "~" .. ws:sub(#home + 1)
    end
    local parts = { S.model_name or "?", ws }
    if S.tokens_max and S.tokens_max > 0 then
        local est = S.tokens_estimated and "≈" or ""
        parts[#parts + 1] = est .. string.format("%.1fk/%.1fk (%.0f%%)",
            S.tokens_used / 1024, S.tokens_max / 1024,
            S.tokens_used / S.tokens_max * 100)
    end
    parts[#parts + 1] = "🖱 on"
    -- T16: keyboard protocol indicator
    if S.kb_protocol == 1 then
        parts[#parts + 1] = "⌨ kitty"
    elseif S.kb_protocol == 2 then
        parts[#parts + 1] = "⌨ xterm"
    end
    local text = table.concat(parts, " · ")
    text = trunc(text, L.w - 2)
    local pad = L.w - ulen(text)
    if pad > 0 then text = text .. string.rep(" ", pad) end
    set_row(L.status_row, rev(text))
end

-- ============================================================
-- Overlays
-- ============================================================
local function overlay_full(title, body, footer)
    local L = layout()
    for r = 1, L.h do set_row(r, "") end
    local inner = math.max(L.w - 2, 1)
    local head = "┌ " .. title .. " "
    local pad = inner - ulen(head) + 1
    if pad < 1 then pad = 1 end
    set_row(1, dim(head .. string.rep("─", pad) .. "┐"))
    local maxi = L.h - 3
    for i = 1, maxi do
        local line = body[i] or ""
        set_row(1 + i, dim("│") .. " " .. trunc(line, inner))
    end
    set_row(L.h - 1, dim("└" .. string.rep("─", inner) .. "┘"))
    set_row(L.h, dim(footer or "Esc закрыть"))
end

local function render_overlay()
    local ov = S.overlay
    if ov == "help" then
        overlay_full("помощь", {
            "Ввод        Enter отправить · Ctrl+J новая строка",
            "             ↑↓ история · Ctrl+A/E/U/W/K",
            "Навигация    PgUp/PgDn · ← → · Home/End",
            "Транскрипт   Ctrl+O развернуть · Ctrl+T thinking",
            "             Ctrl+L очистить экран",
            "Сессия       Ctrl+R возобновить · Ctrl+N новая",
            "             Ctrl+Q выход",
            "Палитра      /help /clear /compact /model /resume",
            "             /new /status /log /quit",
            "Прочее       ? помощь · Esc закрыть",
        }, "? или Esc закрыть")
    elseif ov == "status" then
        overlay_full("статус", {
            "Сессия:   " .. tostring(S.session_id),
            "Workspace:" .. tostring(S.workspace),
            "Модель:   " .. tostring(S.model_name),
            "Токены:   " .. tostring(S.tokens_used) .. "/" .. tostring(S.tokens_max),
            "Старт:    " .. os.date("%Y-%m-%d %H:%M:%S"),
        }, "Esc закрыть")
    elseif ov == "log" then
        local lines = (S.overlay_data and S.overlay_data.lines) or { "(лог пуст)" }
        overlay_full("лог", lines, "Esc закрыть")
    elseif ov == "diff" then
        local src = (S.overlay_data and S.overlay_data.text) or ""
        local lines = {}
        for _, l in ipairs(wrap(src, math.max(S.w - 4, 1))) do
            if l:sub(1, 1) == "+" then lines[#lines + 1] = green(l)
            elseif l:sub(1, 1) == "-" then lines[#lines + 1] = red(l)
            else lines[#lines + 1] = dim(l) end
        end
        overlay_full("diff", lines, "Esc закрыть")
    elseif ov == "resume" then
        local d = S.overlay_data or {}
        local items = d.items or {}
        local lines = {}
        for i, it in ipairs(items) do
            local t = it.label or ""
            lines[#lines + 1] = (i == (d.sel or 1)) and rev(t) or t
        end
        if #lines == 0 then lines[1] = "(сессий нет)" end
        overlay_full("возобновить сессию", lines, "↑↓ выбрать · Enter · Esc")
    elseif ov == "model" then
        local d = S.overlay_data or {}
        local items = d.items or {}
        local lines = {}
        for i, it in ipairs(items) do
            local cur = (it.label == (d.current or S.model_name)) and "● " or "  "
            local t = cur .. (it.label or "")
            lines[#lines + 1] = (i == (d.sel or 1)) and rev(t) or t
        end
        if #lines == 0 then lines[1] = "(модели не найдены)" end
        overlay_full("выбрать модель", lines, "↑↓ выбрать · Enter · Esc")
    end
end

-- ============================================================
-- Cursor & redraw
-- ============================================================
local function place_cursor(L)
    if S.overlay then return end
    local lines = input_lines()
    local li = cursor_line_col()
    local total = #lines
    local shown = L.input_h
    local start = 1
    if total > shown then
        start = li - math.floor(shown / 2)
        if start < 1 then start = 1 end
        if start > total - shown + 1 then start = total - shown + 1 end
    end
    local row_in = li - start + 1
    if row_in < 1 or row_in > L.input_h then return end
    local ln = lines[li]
    local col = S.cursor - ln.from
    local term_row = L.input_row + row_in - 1
    local term_col = 3 + col   -- "› " = 2 cols
    frame_put(ESC .. "[" .. term_row .. ";" .. term_col .. "H")
    frame_put(ESC .. "[?25h")
end

local function redraw()
    local L = layout()
    frame_start()

    if L.w ~= S.last_w or L.h ~= S.last_h then
        S.screen = {}
        frame_put(ESC .. "[2J")
        S.last_w, S.last_h = L.w, L.h
    end

    if S.overlay then
        render_overlay()
    else
        render_transcript(L)
        render_error_banner(L)
        render_input(L)
        render_palette(L)
        render_hint(L)
        render_status(L)
    end

    place_cursor(L)
    frame_flush()
end

-- ============================================================
-- Key reading
-- ============================================================
local paste_buf = nil  -- T13: bracketed paste buffer
local function read_key()
    local b = tether.read_char()
    if b == nil or b == -1 then return nil end
    local c = b & 0xFF

    -- bracketed paste start: ESC[200~ → accumulate until ESC[201~
    if c == 27 then
        local b2 = tether.read_char_nb()
        if b2 == nil then return { kind = "esc" } end
        local c2 = b2 & 0xFF
        if c2 ~= 91 and c2 ~= 79 then
            return { kind = "alt", code = c2 }
        end
        local params = {}
        while true do
            local b3 = tether.read_char_nb()
            if b3 == nil then return { kind = "esc" } end
            local c3 = b3 & 0xFF
            if (c3 >= 48 and c3 <= 57) or c3 == 59 or c3 == 60 or c3 == 62 then
                params[#params + 1] = string.char(c3)
            else
                local p = table.concat(params)
                if p == "200" and c3 == 126 then
                    -- Bracketed paste: read chars until ESC[201~
                    local buf = {}
                    while true do
                        local ch = tether.read_char()
                        if ch == nil or ch == -1 then break end
                        local cc = ch & 0xFF
                        if cc == 27 then
                            -- Possible end marker ESC[201~
                            local b4 = tether.read_char_nb()
                            if b4 and (b4 & 0xFF) == 91 then
                                local b5 = tether.read_char_nb()
                                if b5 and (b5 & 0xFF) == 50 then
                                    local b6 = tether.read_char_nb()
                                    if b6 and (b6 & 0xFF) == 49 then
                                        local b7 = tether.read_char_nb()
                                        if b7 and (b7 & 0xFF) == 126 then
                                            return { kind = "paste", text = table.concat(buf) }
                                        end
                                    end
                                end
                            end
                            buf[#buf + 1] = string.char(cc)
                        elseif cc >= 32 or cc == 10 then
                            buf[#buf + 1] = string.char(cc)
                        end
                    end
                    return { kind = "paste", text = table.concat(buf) }
                end
                local names = {
                    [65] = "up", [66] = "down", [67] = "right", [68] = "left",
                    [72] = "home", [70] = "end",
                }
                if names[c3] then
                    return { kind = "special", name = names[c3], params = p }
                end
                if c3 == 126 then
                    local m = ({ ["1"]="home", ["2"]="insert", ["3"]="delete",
                                 ["4"]="end", ["5"]="pgup", ["6"]="pgdn",
                                 ["7"]="home", ["8"]="end" })[p]
                    if m then return { kind = "special", name = m, params = p } end
                end
                -- T17: mouse SGR (1006) — final byte M (press) / m (release),
                -- params = col;row;code. Scroll code: 64=down, 65=up.
                if c3 == 77 or c3 == 109 then
                    local col, row, code = p:match("(%d+);(%d+);(%d+)")
                    col, row, code = tonumber(col), tonumber(row), tonumber(code)
                    local name
                    if code == 32 then name = "press"
                    elseif code == 33 then name = "release"
                    elseif code == 64 then name = "scroll_up"
                    elseif code == 65 then name = "scroll_down"
                    else name = "unknown" end
                    return { kind = "mouse", name = name,
                             col = col, row = row, button = code }
                end
                return { kind = "special", name = "unknown", final = c3, params = p }
            end
        end
    elseif c == 13 then return { kind = "enter" }
    elseif c == 10 then return { kind = "newline" }
    elseif c == 127 or c == 8 then return { kind = "backspace" }
    elseif c == 9 then return { kind = "tab" }
    elseif c < 32 then return { kind = "ctrl", code = c }
    else
        return { kind = "text", char = string.char(c) }
    end
end

-- ============================================================
-- Command execution
-- ============================================================
local function execute_command(cmd)
    input_clear()
    if cmd == "quit" then S.quit = true; return end
    if cmd == "help" then S.overlay = "help"; return end
    if cmd == "status" then S.overlay = "status"; return end
    if cmd == "clear" then
        S.transcript = {}
        bump_transcript()
        return
    end
    if cmd == "log" then
        S.overlay = "log"
        S.overlay_data = { lines = { "(требуется --debug)" } }
        return
    end
    if cmd == "compact" then
        -- summarize current transcript, reset agent history
        local summary_parts = {}
        for _, e in ipairs(S.transcript) do
            local role = e.role or "?"
            local text = e.text or e.body or ""
            if #text > 200 then text = text:sub(1, 200) .. "…" end
            summary_parts[#summary_parts + 1] = role .. ": " .. text
        end
        local summary = table.concat(summary_parts, "\n")
        S.transcript = { role = "system", text = "── summary ──\n" .. summary }
        if agent then agent.clear() end
        S.tokens_used = math.floor(#summary / 4)
        bump_transcript()
        return
    end
    if cmd == "new" then
        if session and session.new_session then
            S.session_id = session.new_session(S.workspace, S.model_name)
        end
        S.transcript[#S.transcript + 1] = { role = "system", text = "↻ Новая сессия" }
        bump_transcript()
        return
    end
    if cmd == "model" then
        local ok, models = pcall(api.list_models_live, S.cfg, S.api_key or "")
        if not ok then models = nil end
        if not (models and #models > 0) then
            models = {}
            for _, m in ipairs(api.list_models()) do
                models[#models + 1] = { id = m, name = m }
            end
        end
        local items = {}
        for _, m in ipairs(models) do
            items[#items + 1] = {
                label = m.id or m,
                desc = m.name or m.id or "",
            }
        end
        S.overlay = "model"
        S.overlay_data = { items = items, sel = 1, current = S.model_name }
        return
    end
    if cmd == "resume" then
        local items = {}
        if session and session.session_files then
            local files = session.session_files(S.workspace) or {}
            for _, f in ipairs(files) do
                items[#items + 1] = {
                    label = string.format("%s · %s · %s",
                        (f.ts and f.ts:sub(1, 5)) or "…",
                        (f.id and f.id:sub(1, 8)) or "…",
                        (f.first_line or ""):sub(1, 40)),
                    id = f.id,
                }
            end
        end
        S.overlay = "resume"
        S.overlay_data = { items = items, sel = 1 }
        return
    end
end

-- ============================================================
-- Agent integration
-- ============================================================
local function handle_agent_event(ev)
    if not ev or not ev.type then return end
    if ev.type == "text_delta" then
        local last = S.transcript[#S.transcript]
        if not last or last.role ~= "assistant" then
            S.transcript[#S.transcript + 1] = { role = "assistant", text = "" }
            last = S.transcript[#S.transcript]
        end
        last.text = (last.text or "") .. (ev.text or "")
        bump_transcript()
    elseif ev.type == "reasoning_delta" then
        local last = S.transcript[#S.transcript]
        if not last or last.role ~= "thinking" then
            S.transcript[#S.transcript + 1] = { role = "thinking", text = "" }
            last = S.transcript[#S.transcript]
        end
        last.text = (last.text or "") .. (ev.text or "")
        bump_transcript()
    elseif ev.type == "tool_call_start" then
        S.transcript[#S.transcript + 1] = {
            role = "tool", id = ev.id or tostring(#S.transcript + 1),
            name = ev.name or "?", status = "pending", summary = "", body = "",
        }
        bump_transcript()
    elseif ev.type == "tool_result" then
        for i = #S.transcript, 1, -1 do
            local e = S.transcript[i]
            if e.role == "tool" and e.id == ev.id then
                e.status = ev.error and "error" or "ok"
                e.summary = ev.summary or ""
                e.body = ev.body or ""
                break
            end
        end
        bump_transcript()
    elseif ev.type == "error" then
        S.error_banner = ev.message or "ошибка"
    elseif ev.type == "usage" and ev.usage then
        S.tokens_used = ev.usage.used or S.tokens_used
        S.tokens_max  = ev.usage.max  or S.tokens_max
        S.tokens_estimated = false
    elseif ev.type == "context_compressed" then
        S.transcript[#S.transcript + 1] = { role = "system", text = "↘ контекст сжат" }
        S.tokens_estimated = true
    elseif ev.type == "retry" then
        S.transcript[#S.transcript + 1] = {
            role = "system",
            text = string.format("↻ повтор %d (ждём %.1fs): %s",
                ev.attempt or 1, ev.delay or 0.5, ev.reason or ""),
        }
    end
    -- Fallback: estimate tokens when API does not provide usage
    if not ev.usage then
        local total = 0
        for _, e in ipairs(S.transcript) do
            total = total + (#(e.text or "") + #(e.body or "")) / 4
        end
        S.tokens_used = math.max(S.tokens_used, math.floor(total))
        S.tokens_estimated = true
    end
    if ev.type == "confirmation" then
        local detail = ev.details and ev.details[1]
        if detail then
            local label = detail.name .. " " ..
                (detail.args and (detail.args.path or detail.args.command) or "")
            local body = detail.args and detail.args.command or ""
            local options = {"[y] once   разрешить один раз",
                             "[a] session  разрешить до конца сессии",
                             "[d] details  показать diff/аргументы",
                             "[n] deny     отклонить",
                             "[Esc] cancel  прервать ход"}
            S.confirmation = {
                label = label,
                body = body,
                options = options,
                detail = detail,
            }
            S.confirmation_sel = 1
            S.busy = false
        end
    end
    if not S.user_scrolled then S.scroll = 0 end
end

local function commit_input()
    local text = S.input
    if text:match("^%s*$") then
        input_clear()
        return
    end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "/" then
        local cmd = trimmed:match("^/(%w+)")
        if cmd then
            execute_command(cmd)
            return
        end
    end
    push_history(text)
    S.transcript[#S.transcript + 1] = { role = "user", text = text }
    bump_transcript()
    input_clear()
    S.error_banner = nil
    S.scroll = 0
    S.user_scrolled = false

    S.busy = true
    local ok, err = pcall(function()
        agent.turn(S.cfg, S.api_key or "", text, handle_agent_event)
    end)
    S.busy = false
    if not ok and err then
        S.error_banner = tostring(err)
    end
end

-- ============================================================
-- Key dispatch
-- ============================================================
local function handle_special(k)
    if k.name == "left" then
        if S.cursor > 0 then S.cursor = S.cursor - 1 end
    elseif k.name == "right" then
        if S.cursor < #S.input then S.cursor = S.cursor + 1 end
    elseif k.name == "home" then move_line_start()
    elseif k.name == "end" then move_line_end()
    elseif k.name == "delete" then input_delete()
    elseif k.name == "up" then
        if S.input == "" then history_prev()
        else
            if not move_cursor_up() then
                S.scroll = S.scroll + 1
                S.user_scrolled = true
            end
        end
    elseif k.name == "down" then
        if S.input == "" then history_next()
        else
            if not move_cursor_down() then
                S.scroll = math.max(0, S.scroll - 1)
                if S.scroll == 0 then S.user_scrolled = false end
            end
        end
    elseif k.name == "pgup" then
        S.scroll = S.scroll + math.max(1, math.floor(S.h / 2))
        S.user_scrolled = true
    elseif k.name == "pgdn" then
        S.scroll = math.max(0, S.scroll - math.max(1, math.floor(S.h / 2)))
        if S.scroll == 0 then S.user_scrolled = false end
    end
end

local function handle_ctrl(code)
    if code == 1 then move_line_start()
    elseif code == 5 then move_line_end()
    elseif code == 10 then input_insert("\n")   -- Ctrl+J fallback newline
    elseif code == 11 then kill_to_end()
    elseif code == 12 then
        S.screen = {}
        w(ESC .. "[2J")
    elseif code == 14 then
        if session and session.new_session then
            S.session_id = session.new_session(S.workspace, S.model_name)
        end
        S.transcript[#S.transcript + 1] = { role = "system", text = "↻ Новая сессия" }
        bump_transcript()
    elseif code == 15 then
        S.expand_all = not S.expand_all
        bump_transcript()
    elseif code == 20 then
        S.thinking_visible = not S.thinking_visible
        bump_transcript()
    elseif code == 21 then kill_to_start()
    elseif code == 23 then kill_word_before()
    elseif code == 18 then
        -- Ctrl+R: resume picker
        local items = {}
        if session and session.session_files then
            local files = session.session_files(S.workspace) or {}
            for _, f in ipairs(files) do
                items[#items + 1] = {
                    label = string.format("%s · %s · %s",
                        (f.ts and f.ts:sub(1, 5)) or "…",
                        (f.id and f.id:sub(1, 8)) or "…",
                        (f.first_line or ""):sub(1, 40)),
                    id = f.id,
                }
            end
        end
        S.overlay = "resume"
        S.overlay_data = { items = items, sel = 1 }
    end
end

local function b64encode(s)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function c6(v) return chars:sub(v + 1, v + 1) end
    local out2 = {}
    local i = 1
    while i + 2 <= #s do
        local a = string.byte(s:sub(i, i))
        local b = string.byte(s:sub(i+1, i+1))
        local cc = string.byte(s:sub(i+2, i+2))
        local n = a * 65536 + b * 256 + cc
        out2[#out2+1] = c6(math.floor(n / 262144))
        out2[#out2+1] = c6(math.floor(n / 4096) % 64)
        out2[#out2+1] = c6(math.floor(n / 64) % 64)
        out2[#out2+1] = c6(n % 64)
        i = i + 3
    end
    local rem = #s - (i - 1)
    if rem == 1 then
        local a = string.byte(s:sub(i, i))
        out2[#out2+1] = c6(math.floor(a / 4))        -- bits 2-7
        out2[#out2+1] = c6((a % 4) * 16)             -- bits 0-1 → first 2 of second
        out2[#out2+1] = "=="
    elseif rem == 2 then
        local a = string.byte(s:sub(i, i))
        local b = string.byte(s:sub(i+1, i+1))
        local n = a * 256 + b
        out2[#out2+1] = c6(math.floor(n / 1024))     -- bits 10-15
        out2[#out2+1] = c6(math.floor(n / 16) % 64)  -- bits 4-9
        out2[#out2+1] = c6((n % 16) * 4)             -- bits 0-3
        out2[#out2+1] = "="
    end
    return table.concat(out2)
end

local function copy_last_assistant()
    -- T18: copy last assistant response via OSC 52
    local last_text = ""
    for i = #S.transcript, 1, -1 do
        if S.transcript[i].role == "assistant" then
            last_text = S.transcript[i].text or ""
            break
        end
    end
    if last_text == "" then return end
    w(ESC .. "]52;c;" .. b64encode(last_text) .. string.char(7))
end

local function resolve_confirmation(decision)
    local detail = S.confirmation and S.confirmation.detail
    S.confirmation = nil
    S.confirmation_sel = 1
    if detail and agent then
        local ok, err = pcall(agent.confirm, detail.id, decision, S.cfg)
        if not ok and err then S.error_banner = tostring(err) end
        S.transcript[#S.transcript + 1] = {
            role = "system",
            text = "→ подтверждение: " .. decision .. " (" .. detail.name .. ")",
        }
        -- resume the agent loop after confirmation
        S.busy = true
        local ok2, err2 = pcall(agent.continue, S.cfg, S.api_key or "", handle_agent_event)
        S.busy = false
        if not ok2 and err2 then S.error_banner = tostring(err2) end
    end
    bump_transcript()
end

local function handle_confirmation_key(k)
    if k.kind == "esc" then
        resolve_confirmation("cancel")
        return
    end
    if k.kind == "enter" then
        local sel = S.confirmation_sel
        local opts = (S.confirmation and S.confirmation.options) or {}
        local dec = { [1] = "allow", [2] = "session", [3] = "details", [4] = "deny" }
        resolve_confirmation(dec[sel] or "deny")
        return
    end
    if k.kind == "text" then
        local c = k.char
        if c == "y" then resolve_confirmation("allow")
        elseif c == "n" then resolve_confirmation("deny")
        elseif c == "a" then resolve_confirmation("session")
        elseif c == "A" then resolve_confirmation("always")
        elseif c == "d" then
            local conf = S.confirmation
            S.overlay = "diff"
            S.overlay_data = { text = conf and (conf.body or "") or "" }
            S.confirmation = nil
            S.confirmation_sel = 1
            return
        end
        return
    end
    if k.kind == "special" then
        if k.name == "up" then
            local n = #((S.confirmation and S.confirmation.options) or {})
            if n > 0 then
                S.confirmation_sel = math.max(1, S.confirmation_sel - 1)
                bump_transcript()
            end
        elseif k.name == "down" then
            local n = #((S.confirmation and S.confirmation.options) or {})
            if n > 0 then
                S.confirmation_sel = math.min(n, S.confirmation_sel + 1)
                bump_transcript()
            end
        end
    end
    -- T17: click on a confirmation option
    if k.kind == "mouse" and k.name == "press" then
        local c = S.confirmation
        if c and c.options then
            local L = layout()
            local n = #c.options
            local first_opt_row = L.input_row - n  -- options render just above input
            if k.row >= first_opt_row and k.row <= first_opt_row + n - 1 then
                S.confirmation_sel = k.row - first_opt_row + 1
                local dec = { [1] = "allow", [2] = "session", [3] = "details", [4] = "deny" }
                resolve_confirmation(dec[S.confirmation_sel] or "deny")
            end
        end
    end
end

local function handle_overlay_key(k)
    local ov = S.overlay
    if k.kind == "esc" then
        S.overlay = nil; S.overlay_data = nil; return
    end
    if k.kind == "text" and (k.char == "q" or k.char == "?") then
        S.overlay = nil; S.overlay_data = nil; return
    end
    if ov == "resume" then
        local d = S.overlay_data or {}
        if k.kind == "special" then
            if k.name == "up" then
                d.sel = math.max(1, (d.sel or 1) - 1)
            elseif k.name == "down" then
                d.sel = math.min(#(d.items or {}), (d.sel or 1) + 1)
            end
        elseif k.kind == "enter" then
            local it = (d.items or {})[d.sel or 1]
            if it then
                S.overlay = nil; S.overlay_data = nil
                S.transcript[#S.transcript + 1] =
                    { role = "system", text = "↻ возобновить: " .. tostring(it.id) }
                bump_transcript()
            end
        end
    elseif ov == "model" then
        local d = S.overlay_data or {}
        if k.kind == "special" then
            if k.name == "up" then
                d.sel = math.max(1, (d.sel or 1) - 1)
            elseif k.name == "down" then
                local n = #(d.items or {})
                if n > 0 then d.sel = math.min(n, (d.sel or 1) + 1) end
            end
        elseif k.kind == "enter" then
            local it = (d.items or {})[d.sel or 1]
            if it then
                local model_id = it.label:match("^model_set:(.*)$") or it.label
                S.model_name = model_id
                S.cfg.model = model_id
                S.overlay = nil; S.overlay_data = nil
                S.transcript[#S.transcript + 1] =
                    { role = "system", text = "→ модель: " .. model_id }
                bump_transcript()
            end
        end
    end
end

local function handle_key(k)
    if not k then return end

    if S.overlay then handle_overlay_key(k); return end
    if S.confirmation then handle_confirmation_key(k); return end

    -- T17: mouse SGR — scroll transcript, click palette/confirmation items
    if k.kind == "mouse" then
        if k.name == "scroll_up" then
            S.scroll = math.max(0, S.scroll - math.max(1, math.floor(S.h / 4)))
            if S.scroll == 0 then S.user_scrolled = false end
            return
        end
        if k.name == "scroll_down" then
            S.scroll = S.scroll + math.max(1, math.floor(S.h / 4))
            S.user_scrolled = true
            return
        end
        if k.name == "press" then
            local L = layout()
            if S.palette_active and k.row >= L.palette_row + 1
                and k.row <= L.palette_row + math.min(#S.palette_items, L.palette_h - 2) then
                local idx = k.row - L.palette_row
                local it = S.palette_items[idx]
                if it then execute_command(it.cmd) end
                return
            end
        end
        return
    end

    -- global ctrl
    if k.kind == "ctrl" then
        if k.code == 17 then S.quit = true; return end         -- Ctrl+Q
        if k.code == 3 then                                     -- Ctrl+C / Ctrl+Shift+C
            if S.palette_active then input_clear(); return end
            if #S.input > 0 then input_clear()
            elseif os.clock() - (S.last_ctrl_c or 0) < 1.0 then
                S.quit = true                                   -- double Ctrl+C
            else
                S.last_ctrl_c = os.clock()                        -- single: mark, abort stream
            end
            return
        end
    end

    -- T18: kitty keyboard protocol — Ctrl+Shift+C as ESC[4:53;96C
    if k.kind == "special" and k.params == "4:53;96" then
        copy_last_assistant()
        return
    end
    -- T18: X11 fallback — Shift+Ctrl+C as ESC[1;2C
    if k.kind == "special" and k.params and k.params:match("^1;2%a") then
        local key = k.params:match("(%a)$")
        if key == "C" then copy_last_assistant() end
        return
    end

    -- palette mode
    if S.palette_active then
        if k.kind == "enter" then
            local it = S.palette_items[S.palette_sel]
            if it then execute_command(it.cmd) end
            return
        elseif k.kind == "tab" then
            local it = S.palette_items[S.palette_sel]
            if it then
                S.input = it.label .. " "
                S.cursor = #S.input
                palette_sync()
            end
            return
        elseif k.kind == "special" then
            if k.name == "up" then
                S.palette_sel = math.max(1, S.palette_sel - 1)
            elseif k.name == "down" then
                if #S.palette_items > 0 then
                    S.palette_sel = math.min(#S.palette_items, S.palette_sel + 1)
                end
            end
            return
        elseif k.kind == "esc" then
            input_clear()
            return
        end
        -- fall through for text/backspace so palette_sync runs
    end

    -- normal mode
    if k.kind == "paste" then
        local text = k.text or ""
        for i = 1, #text do
            local ch = text:sub(i, i)
            if ch == "\n" then
                S.input = S.input .. "\n"
            else
                input_insert(ch)
            end
        end
        S.cursor = #S.input
    elseif k.kind == "text" then input_insert(k.char)
    elseif k.kind == "enter" then commit_input()
    elseif k.kind == "newline" then input_insert("\n")
    elseif k.kind == "backspace" then input_backspace()
    elseif k.kind == "esc" then input_clear()
    elseif k.kind == "ctrl" then handle_ctrl(k.code)
    elseif k.kind == "special" then handle_special(k)
    end
end

-- ============================================================
-- Main
-- ============================================================
function M.run()
    S = new_state()

    S.cfg = (config and config.load and config.load()) or {}
    S.model_name = S.cfg.model or "gpt-4o-mini"
    S.workspace  = S.cfg.workspace or tether.getcwd()
    if config and config.api_key then
        S.cfg.api_key = config.api_key(S.cfg)
        S.api_key = S.cfg.api_key
    end

    local size = tether.get_terminal_size()
    if size then S.w, S.h = size.width, size.height end

    if session and session.new_session then
        local ok, id = pcall(session.new_session, S.workspace, S.model_name)
        S.session_id = ok and id or "?"
    end

    if S.cfg.ui and S.cfg.ui.mouse and S.cfg.ui.mouse ~= "off" then
        w(ESC .. "[?1006h" .. ESC .. "[?1000h")
    end
    -- T13: enable bracketed paste
    if not _ascii then
        w(ESC .. "[?2004h")
    end
    -- T16: keyboard protocol detection
    local ok, proto = pcall(tether.detect_kb_protocol)
    S.kb_protocol = (ok and type(proto) == "number") and proto or 0
    if S.kb_protocol == 1 then
        w(ESC .. "[?u")
    end

    palette_sync()
    redraw()

    while not S.quit do
        local k = read_key()
        if not k then break end
        handle_key(k)

        if tether.resize_requested() then
            local sz = tether.get_terminal_size()
            if sz then S.w, S.h = sz.width, sz.height end
            S.screen = {}
        end

        redraw()
    end

    w(ESC .. "[?1006l" .. ESC .. "[?1000l" .. ESC .. "[?2004l" .. ESC .. "[?25h" .. "\n")
end

return M
