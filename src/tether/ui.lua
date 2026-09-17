-- tether / ui.lua — TUI with line-diff redraw.
local M = {}

-- ============================================================
-- ANSI
-- ============================================================
local ESC = "\27"
local function w(s) tether.write(s) end

-- T20: ASCII mode — NO_COLOR=1 or TERM=dumb → strip all ANSI + non-ASCII glyphs
-- M8/R1 test seam: tests override M._ascii_mode or M._env_ascii; production
-- reads env once. cfg.ui.ascii ("auto"|"on"|"off") overrides via M.ascii_active.
local _ascii = (os.getenv("NO_COLOR") == "1") or (os.getenv("TERM") == "dumb")
M._env_ascii = _ascii

-- cfg.ui.ascii resolution: "on" forces, "off" beats env, else env/auto.
function M.ascii_active(cfg_ascii)
    if cfg_ascii == "on" then return true end
    if cfg_ascii == "off" then return false end
    return M._env_ascii or M._ascii_mode or false
end

-- Effective ascii flag used everywhere at render time.
local function ascii_active()
    local ua = S.cfg and S.cfg.ui and S.cfg.ui.ascii
    return M.ascii_active(ua)
end

-- cfg.ui.thinking resolution: "collapsed" hides thinking on start (Ctrl+T
-- toggles as before). Unknown/nil -> expanded (previous behavior).
function M.initial_thinking_visible(cfg_thinking)
    return cfg_thinking ~= "collapsed"
end

-- cfg.ui.collapse.{read,list,grep} caps the visible body lines per tool type;
-- unknown tool or missing table -> default_cap (200, the previous hardcode).
function M.tool_collapse_cap(tool_name, collapse_tbl, default_cap)
    if type(collapse_tbl) ~= "table" then return default_cap or 200 end
    local v = collapse_tbl[tool_name]
    if type(v) == "number" and v > 0 then return v end
    return default_cap or 200
end

-- cfg.ui.keyboard_protocol override: "auto" (nil) -> C-side detection,
-- "kitty" -> 1, "modifyOtherKeys" -> 2, anything else -> 0 (plain, safe).
function M.kb_protocol_from_config(cfg_kb)
    if cfg_kb == nil or cfg_kb == "auto" then return nil end
    if cfg_kb == "kitty" then return 1 end
    if cfg_kb == "modifyOtherKeys" then return 2 end
    return 0
end

-- M8/R1: glyph → ASCII mapping (single pass, longest-first via explicit scan).
-- The spec promises TERM=dumb renders pure ASCII; the old code only stripped
-- ANSI colors, leaving box-drawing and emoji-width glyphs to break layout.
local GLYPH_MAP = {
    ["●"] = "*", ["⚙"] = "[t]", ["›"] = ">", ["✗"] = "x", ["✻"] = "*",
    ["↻"] = "[r]", ["⏹"] = "[x]", ["⚠"] = "!", ["▸"] = ">", ["▾"] = "v",
    ["┌"] = "+", ["┐"] = "+", ["└"] = "+", ["┘"] = "+", ["─"] = "-",
    ["│"] = "|", ["•"] = "-", ["…"] = "...", ["▓"] = "#", ["░"] = "-",
    ["↑"] = "^", ["↓"] = "v", ["←"] = "<", ["→"] = ">",
}
local function to_ascii(s)
    if not (M._ascii_mode or M._env_ascii or _ascii) then return s end
    local out = {}
    local i = 1
    while i <= #s do
        local matched = false
        for glyph, repl in pairs(GLYPH_MAP) do
            local glen = #glyph
            if i + glen <= #s + 1 and s:sub(i, i + glen - 1) == glyph then
                out[#out + 1] = repl
                i = i + glen
                matched = true
                break
            end
        end
        if not matched then
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end
M.to_ascii = to_ascii

local function sgr(c, s)
    if (M._ascii_mode or M._env_ascii or _ascii) then return to_ascii(s) end
    return ESC .. "[" .. c .. "m" .. s .. ESC .. "[0m"
end

-- M8/R2: themes — role→SGR-code tables. cfg.ui.theme selects; unknown → default.
-- "mono" = no colors at all (roles resolve to nil ⇒ raw text).
local THEMES = {
    default = {
        accent = "36;1", warn = "33;1", error = "31;1", success = "32",
        dim = "2", italic = "3", reverse = "7", bold = "1",
    },
    solarized = {
        accent = "36", warn = "33", error = "31", success = "32",
        dim = "2", italic = "3", reverse = "7", bold = "1",
    },
    mono = {}, -- every role missing ⇒ no SGR emitted
}
local _theme_name = "default"

-- M8/R2: wrap toggle (cfg.ui.wrap); false = truncate to width instead.
local _wrap_enabled = true
local function cyan(s)   return sgr("36;1", s) end
local function yellow(s) return sgr("33;1", s) end
local function red(s)    return sgr("31;1", s) end
local function green(s)  return sgr("32",   s) end
local function dim(s)    return sgr("2",    s) end
local function italic(s) return sgr("3",    s) end
local function rev(s)    return sgr("7",    s) end

-- M8/R2: role-based color — theme table drives the code; missing role in a
-- theme (e.g. mono) returns the raw text with no SGR at all.
local function sgr_role(role, s)
    local theme = THEMES[_theme_name] or THEMES.default
    local code = theme[role]
    if not code then return to_ascii(s) end
    return sgr(code, s)
end

-- Exports for unit tests + runtime config hookup (M8/R2)
M.THEMES = THEMES
M.set_theme = function(name)
    if THEMES[name] then
        _theme_name = name
    else
        _theme_name = "default"
    end
    M._theme_name = _theme_name
end
M.sgr_role = sgr_role
M.set_wrap = function(v) _wrap_enabled = v and true or false end
-- M.wrap_lines assigned after wrap() is defined (see UTF-8 section below)

-- ============================================================
-- UTF-8 / string helpers
-- ============================================================
local function ulen(s) return utf8.len(s) or #s end
-- M8 fix: utf8.sub does NOT exist in the Lua 5.4 stdlib (it worked only
-- inside the embedded binary if it defined one; plain lua crashed).
-- Build char-index slicing on utf8.offset instead.
local function usub(s, i, j)
    j = j or -1
    if i < 0 then i = ulen(s) + i + 1 end
    if j < 0 then j = ulen(s) + j + 1 end
    local start = utf8.offset(s, i)
    if not start then return "" end
    local stop = utf8.offset(s, j + 1)
    if stop then stop = stop - 1 else stop = #s end
    return s:sub(start, stop)
end

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
                if not _wrap_enabled then
                    -- M8/R2: wrap off → truncate with arrow marker
                    out[#out + 1] = (M._ascii_mode or M._env_ascii or _ascii)
                        and usub(line, 1, width - 1) .. ">"
                        or usub(line, 1, width - 1) .. "→"
                    break
                end
                out[#out + 1] = usub(line, 1, width)
                line = usub(line, width + 1)
            end
        end
    end
    return out
end
M.wrap_lines = wrap -- export (M8/R2)

-- ============================================================
-- M8/R4: markdown-lite renderer (pure function, no TUI state)
-- ============================================================
-- Grammar: fenced code blocks ```lang, inline `code`, **bold**, *italic*,
-- #/##/### headings, -/*/1. lists. Escapes: \` and \* are literal.
-- No backtracking patterns (ADR lesson); per-line state machine.
local function md_strip_inline(s, ansi_fn)
    -- ansi_fn(kind, text) applies role colors; nil = strip markers only
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "\\" and i < n and (s:sub(i + 1, i + 1) == "`" or s:sub(i + 1, i + 1) == "*") then
            out[#out + 1] = s:sub(i + 1, i + 1) -- escaped literal
            i = i + 2
        elseif c == "`" then
            local close = s:find("`", i + 1, true)
            if close then
                local code = s:sub(i + 1, close - 1)
                if ansi_fn then
                    out[#out + 1] = ansi_fn("code", code)
                else
                    out[#out + 1] = code
                end
                i = close + 1
            else
                out[#out + 1] = c; i = i + 1
            end
        elseif c == "*" and s:sub(i + 1, i + 1) == "*" then
            local close = s:find("**", i + 2, true)
            if close then
                local bold = s:sub(i + 2, close - 1)
                if ansi_fn then
                    out[#out + 1] = ansi_fn("bold", bold)
                else
                    out[#out + 1] = bold
                end
                i = close + 2
            else
                out[#out + 1] = c; i = i + 1
            end
        elseif c == "*" then
            local close = s:find("*", i + 1, true)
            if close then
                local ital = s:sub(i + 1, close - 1)
                if ansi_fn then
                    out[#out + 1] = ansi_fn("italic", ital)
                else
                    out[#out + 1] = ital
                end
                i = close + 1
            else
                out[#out + 1] = c; i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function md_render(text, width, ansi_fn)
    local ascii = M._ascii_mode or M._env_ascii or _ascii
    local box = ascii and { tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|" }
                            or { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" }
    local bullet = ascii and "-" or "•"
    local cut = ascii and ">" or "→"
    local out = {}
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    local i = 1
    while i <= #lines do
        local line = lines[i]
        local fence = line:match("^%s*%`%`%`%s*(%w*)%s*$")
        if fence then
            -- code block: framed, no wrap, truncate with cut marker
            local lang = fence ~= "" and (" " .. fence .. " ") or ""
            local inner = math.max(width - 4, 1)
            out[#out + 1] = box.tl .. box.h .. lang
                .. string.rep(box.h, math.max(inner - ulen(lang), 1)) .. box.tr
            i = i + 1
            while i <= #lines and not lines[i]:match("^%s*%`%`%`%s*$") do
                local code_line = lines[i]
                if ulen(code_line) > inner then
                    code_line = usub(code_line, 1, inner - 1) .. cut
                end
                out[#out + 1] = box.v .. " " .. code_line
                    .. string.rep(" ", math.max(inner - ulen(code_line), 0)) .. " " .. box.v
                i = i + 1
            end
            out[#out + 1] = box.bl .. string.rep(box.h, inner + 2) .. box.br
            i = i + 1 -- skip closing fence (or last line)
        else
            local heading = line:match("^(#+)%s+(.*)")
            if heading then
                out[#out + 1] = md_strip_inline(select(2, line:match("^(#+)%s+(.*)")), ansi_fn)
                out[#out + 1] = ""
                i = i + 1
            elseif line:match("^%s*[%-%*]%s+") then
                local item = line:gsub("^%s*[%-%*]%s+", "", 1)
                local body = md_strip_inline(item, ansi_fn)
                local prefix = "  " .. bullet .. " "
                local wrapped = wrap(body, math.max(width - #prefix, 1))
                for wi, wl in ipairs(wrapped) do
                    out[#out + 1] = (wi == 1) and (prefix .. wl)
                        or (string.rep(" ", #prefix) .. wl)
                end
                i = i + 1
            else
                local rendered = md_strip_inline(line, ansi_fn)
                for _, wl in ipairs(wrap(rendered, width)) do
                    out[#out + 1] = wl
                end
                i = i + 1
            end
        end
    end
    return out
end
M.md_render = md_render

local function trunc(s, maxw)
    if maxw < 1 then return "" end
    if ulen(s) <= maxw then return s end
    return usub(s, 1, maxw - 1) .. "…"
end

-- ============================================================
-- Constants
-- ============================================================
-- M8/R3: digit shortcuts for the confirmation menu (1..6)
local CONFIRM_DIGITS = { "allow", "session", "always", "details", "deny", "cancel" }
M.CONFIRM_DIGITS = CONFIRM_DIGITS

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
    pcall(function() debug_log_fh:write(os.date("[%H:%M:%S] ") .. msg .. "\n") end)
end
local function init_debug_log()
    if S and S.debug and debug_log_fh == nil then
        local dir = (os.getenv("HOME") or "/tmp") .. "/.tether/log"
        pcall(function() os.execute("mkdir -p " .. dir) end)
        local ok, fh = pcall(io.open, dir .. "/tether.log", "a")
        if ok and fh then debug_log_fh = fh end
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
        debug = false,

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
        thinking_visible = true, -- M8 follow-up: overridden from cfg.ui.thinking in run()

        palette_active = false,
        palette_items = {},
        palette_sel = 1,

        confirmation = nil,
        confirmation_sel = 1,

        overlay = nil,
        overlay_data = nil,

        search = nil, -- M8/R6: { input, active, matches, idx }
        mouse_enabled = nil, -- M8/R8: last emitted tracking state

        history = {},
        history_pos = 0,

        scroll = 0,
        user_scrolled = false,

        tokens_used = 0,
        tokens_max = 32768,
        tokens_estimated = true,

        spinner_frame = 0,
        last_ctrl_c = nil,
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
        S.palette_active = false
        S.palette_items = {}
        S.palette_sel = 1
        return
    end

    S.palette_active = true
    local items = {}
    for _, c in ipairs(SLASH_COMMANDS) do
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
-- History (§6.13: persisted to ~/.tether/history.jsonl, workspace filter)
-- ============================================================
local function load_history()
    local home = os.getenv("HOME") or ""
    local f = io.open(home .. "/.tether/history.jsonl", "r")
    if not f then return end
    local seen_last = nil
    for line in f:lines() do
        local ts = line:match('"ts":"([^"]*)"')
        local wsp = line:match('"workspace":"([^"]*)"')
        local text = line:match('"text":"(.*)"')
        if text then
            text = text:gsub('\\"', '"'):gsub("\\\\", "\\"):gsub("\\n", "\n"):gsub("\\t", "\t")
            -- dedupe consecutive entries globally
            if text ~= seen_last then
                seen_last = text
                -- filter by current workspace
                if not wsp or wsp == S.workspace then
                    S.history[#S.history + 1] = text
                end
            end
        end
    end
    f:close()
    -- keep last 200 for this workspace
    while #S.history > 200 do table.remove(S.history, 1) end
end

local function push_history(text)
    if not text or text == "" then return end
    if S.history[#S.history] == text then return end
    table.insert(S.history, text)
    if #S.history > 200 then table.remove(S.history, 1) end
    S.history_pos = #S.history + 1
    if session and session.add_history then
        pcall(session.add_history, text, S.workspace)
    end
end

local function history_prev()
    if #S.history == 0 then return end
    local p = S.history_pos - 1
    if p < 1 then p = 1 end
    S.history_pos = p
    S.input = S.history[p]
    S.cursor = #S.input
    palette_sync()
end

local function history_next()
    if S.history_pos >= #S.history + 1 then
        input_clear()
        return
    end
    S.history_pos = S.history_pos + 1
    if S.history_pos > #S.history then
        S.history_pos = #S.history + 1
        input_clear()
        return
    end
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
        -- M8/R4: markdown-lite render; md_render handles wrap/width itself
        local body = md_render(e.text, math.max(width - 2, 1))
        return with_prefix("● ", 2, body)
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
        local marker = e.status == "error" and red("✗") or yellow("⚙")
        local head = marker .. " " .. yellow(e.name or "?")
        if e.status == "pending" then
            -- M8/R3: pending tools show live elapsed time
            local elapsed = ""
            if e.started_at then
                local secs = os.time() - e.started_at
                elapsed = string.format(" %s %.1fs", ascii and "." or "…", secs)
            end
            head = head .. "  " .. dim("…" .. elapsed)
        elseif e.summary and e.summary ~= "" then
            head = head .. "  " .. dim(e.summary)
        end
        local out = { head }
        local show = e.body and e.body ~= "" and
                     (e.always_show or e.status == "error" or S.expanded[e.id] or S.expand_all)
        if show then
            local bl = wrap(e.body, math.max(width - 2, 1))
            local cap = e.collapse_lines
                or M.tool_collapse_cap(e.name, S.cfg and S.cfg.ui and S.cfg.ui.collapse, 200)
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
        local opts = c.options or {}
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
-- M8/R3: scroll indicator math. Returns nil when following (bottom-anchored),
-- else the count of lines hidden below the visible window.
local function scroll_indicator(total, scroll, visible_h)
    if scroll <= 0 then return nil end
    local bottom = total - scroll
    if bottom >= total then return nil end
    local hidden_below = total - bottom
    if hidden_below <= 0 then return nil end
    return hidden_below
end
M.scroll_indicator = scroll_indicator

-- M8/R6: search helpers over the live UI state (scans display_lines)
local function search_rescan()
    if not S.search then return end
    S.search.matches = M.search_matches(display_lines(), S.search.input)
    S.search.active = S.search.input ~= nil and S.search.input ~= ""
    if #S.search.matches == 0 then S.search.idx = 0 end
end

-- dir=1 next match, dir=-1 previous; scrolls so the match is visible
local function search_goto(dir)
    if not S.search then return end
    local ms = S.search.matches or {}
    if #ms == 0 then return end
    local idx = (S.search.idx or 0)
    idx = idx + dir
    if idx > #ms then idx = 1 elseif idx < 1 then idx = #ms end
    S.search.idx = idx
    local L = layout()
    S.scroll = M.search_scroll_for(#display_lines(), ms[idx], L.transcript_h)
    S.user_scrolled = true
    bump_transcript()
end

-- M8/R6: transcript search. Case-insensitive substring match over rendered
-- display lines; scroll math puts the match in the lower two-thirds of the
-- viewport. Both helpers are exported for unit tests.
function M.search_matches(lines, query)
    local out = {}
    if not query or query == "" then return out end
    local q = query:lower()
    for i, l in ipairs(lines or {}) do
        if (l:gsub("%c", ""):lower()):find(q, 1, true) then
            out[#out + 1] = i
        end
    end
    return out
end

function M.search_scroll_for(total, match_idx, visible_h)
    if not total or total <= 0 or not match_idx or not visible_h or visible_h <= 0 then
        return 0
    end
    local max_scroll = total - visible_h
    if max_scroll < 0 then max_scroll = 0 end
    -- place the match at the 2/3 line of the viewport (spec: lower third)
    local target_row = math.floor(visible_h * 2 / 3 + 0.5)
    local scroll = match_idx - target_row
    if scroll < 0 then scroll = 0 end
    if scroll > max_scroll then scroll = max_scroll end
    return scroll
end

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
        -- M8/R6: inverse-video the active search match line (simplified per spec)
        if S.search and S.search.active and S.search.matches[S.search.idx] == idx then
            text = rev(text)
        end
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

-- M7/D1+N1: dangerous-command detection, extracted for testability.
-- All patterns are valid Lua patterns (the old %frm%s crashed — %f is a
-- pattern boundary prefix and must be followed by a set).
local function ui_is_dangerous(cmd)
    if cmd:match("rm%s+%-[a-zA-Z]*[rR][a-zA-Z]*[fF]") or cmd:match("rm%s+%-[a-zA-Z]*[fF][a-zA-Z]*[rR]") then
        return true -- rm -rf / -fr / -Rf ... (either flag order, any case)
    end
    if cmd:match("sudo") or cmd:match("curl.-|%s*ba?sh") or cmd:match("curl.-|%s*sh")
        or cmd:match("mkfs") then
        return true
    end
    if cmd:match("^%s*>%s*/") then return true end
    if cmd:match(":%s*%(%)%s*%{") then return true end -- fork bomb :(){ :|:& };:
    if cmd:match("dd%s+if=") or cmd:match("of=/dev/") then return true end
    return false
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" } -- §6.6
-- M8/R1: ASCII spinner for TERM=dumb / NO_COLOR
local SPINNER_ASCII = { "|", "/", "-", "\\" }
M.SPINNER_ASCII = SPINNER_ASCII
local function render_hint(L)
    local text
    if S.palette_active then
        text = "↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть"
    elseif S.confirmation then
        text = "↑↓ выбрать · Enter подтвердить · 1-6 · y/a/A/d/n · Esc отмена"
    elseif S.busy then
        -- M8/R1: ASCII spinner in dumb terminals; M8/R3: elapsed seconds
        local frames = (M._ascii_mode or M._env_ascii or _ascii) and SPINNER_ASCII or SPINNER
        local sp = frames[(S.spinner_frame % #frames) + 1]
        local secs = S.busy_started_at and (os.time() - S.busy_started_at) or 0
        text = string.format("%s tether думает… %ds · Ctrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл",
            sp, secs)
    elseif S.overlay then
        text = "Esc закрыть"
    elseif S.search then
        -- M8/R7 hint: «Esc отмена · n/N следующий/предыдущий»
        text = "поиск: " .. (S.search.input or "") .. " ─ Esc отмена · n/N следующий/предыдущий"
    else
        text = "Enter отправить · Ctrl+J новая строка · Ctrl+C отмена · ? помощь"
    end
    set_row(L.hint_row, dim(trunc(text, L.w)))
end

-- M8/R5: token bar — 10 cells, green <70% (summarize_at), yellow >=70%, red >=90%;
-- ASCII variant renders [###-------] instead of ▓▓░░. Exported for unit tests.
function M.token_bar(pct, summarize_at, ascii)
    summarize_at = summarize_at or 0.7
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    local cells = 10
    local filled = math.floor(pct * cells + 0.5)
    local bar, bar_ascii = "", ""
    for i = 1, cells do
        bar = bar .. (i <= filled and "▓" or "░")
        bar_ascii = bar_ascii .. (i <= filled and "#" or "-")
    end
    local color = pct >= 0.9 and red or (pct >= summarize_at and yellow or green)
    local body = ascii and ("[" .. bar_ascii .. "]") or bar
    return color(string.format("%s %d%%", body, math.floor(pct * 100)))
end

local function render_status(L)
    local home = os.getenv("HOME") or ""
    local ws = S.workspace
    if home ~= "" and ws:sub(1, #home) == home then
        ws = "~" .. ws:sub(#home + 1)
    end
    local parts = { S.model_name or "?", ws }
    if S.tokens_max and S.tokens_max > 0 then
        -- M8/R5: token bar with thresholds from cfg.context.summarize_at
        local pct = S.tokens_used / S.tokens_max
        local summarize_at = (S.cfg.context and S.cfg.context.summarize_at) or 0.7
        parts[#parts + 1] = (S.tokens_estimated and "≈" or "") ..
            M.token_bar(pct, summarize_at, M._ascii_mode or M._env_ascii or _ascii)
    end
    -- M8/R3: scroll indicator — hidden lines below when user scrolled up
    if S.user_scrolled then
        local hidden = scroll_indicator(#display_lines(), S.scroll, L.transcript_h)
        if hidden and hidden > 0 then
            parts[#parts + 1] = "⏸ +" .. hidden
        end
    end
    if not ((S.cfg.ui and S.cfg.ui.mouse == "off") or (M._ascii_mode or M._env_ascii or _ascii)) then
        parts[#parts + 1] = "🖱 " .. (S.mouse_mode or "auto")
    end
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
            "             G/End — в конец (jump-to-bottom)",
            "Поиск        Ctrl+F искать · Enter/n · N · F3/Shift+F3 · Esc",
            "Транскрипт   Ctrl+O развернуть · Ctrl+T thinking",
            "             Ctrl+L очистить экран",
            "Сессия       Ctrl+R возобновить · Ctrl+N новая",
            "             Ctrl+Q выход",
            "Палитра      /help /clear /compact /model /resume",
            "             /new /status /log /quit",
            "Мышь         режим ui.mouse = auto|on|off|selection;",
            "             в auto выделяйте текст как обычно —",
            "             при подтверждении мышь включается сама",
            "             (Shift+drag выделяет даже при вкл. мыши)",
            "Прочее       ? помощь · Esc закрыть",
        }, "? или Esc закрыть")
    elseif ov == "status" then
        local n_tools = 0
        for _, e in ipairs(S.transcript) do
            if e.role == "tool" then n_tools = n_tools + 1 end
        end
        overlay_full("статус", {
            "Сессия:    " .. tostring(S.session_id),
            "Workspace: " .. tostring(S.workspace),
            "Модель:    " .. tostring(S.model_name),
            "Токены:    " .. tostring(S.tokens_used) .. "/" .. tostring(S.tokens_max),
            "Tool calls:" .. tostring(n_tools),
            "Старт:     " .. tostring(S.started_at or os.date("%Y-%m-%d %H:%M:%S")),
            "Лог:       " .. (os.getenv("HOME") or "") .. "/.tether/log/tether.log",
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
    elseif ov == "error" then
        -- M8/R3: full error text; banner shows one truncated line, this the rest
        local src = (S.overlay_data and S.overlay_data.text) or S.error_banner or ""
        local lines = {}
        for _, l in ipairs(wrap(src, math.max(S.w - 4, 1))) do
            lines[#lines + 1] = red(l)
        end
        overlay_full("ошибка", lines, "Esc закрыть")
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
local function read_key()
    local b = tether.read_char()
    if b == nil or b == -1 then return nil end
    local c = b & 0xFF

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
                    local buf = {}
                    while true do
                        local ch = tether.read_char()
                        if ch == nil or ch == -1 then break end
                        local cc = ch & 0xFF
                        if cc == 27 then
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
                -- kitty keyboard protocol: CSI <codes> u (§6.7 Shift+Enter etc.)
                if c3 == 117 and p ~= "" then
                    -- 13;2u / 13;5u → Shift+Enter / Ctrl+Enter → newline
                    return { kind = "newline" }
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
                -- M8/R6: F3 (CSI 1~ with modifier 1;3~ etc) — terminal sends
                -- ESC[13~ / ESC[14~ for F3/Shift+F3 on xterm; match by params
                if c3 == 126 and p == "13" then return { kind = "special", name = "f3" } end
                if c3 == 126 and p == "14" then return { kind = "special", name = "sf3" } end
                -- T17: mouse SGR (1006) — final byte M (press) / m (release),
                -- params = col;row;code (audit: was col/row swapped).
                if c3 == 77 or c3 == 109 then
                    local col, row, code = p:match("(%d+);(%d+);(%d+)")
                    col, row, code = tonumber(col), tonumber(row), tonumber(code)
                    local name
                    if code == 32 then name = "press"
                    elseif code == 33 then name = "release"
                    elseif code == 64 then name = "scroll_down"
                    elseif code == 65 then name = "scroll_up"
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
local function start_new_session(banner)
    if session and session.new_session then
        local ok, id = pcall(session.new_session, S.workspace, S.model_name)
        if ok and id then S.session_id = id end
    end
    if S.cfg then S.cfg._session_id = S.session_id end
    if agent and agent.clear then agent.clear() end
    S.transcript[#S.transcript + 1] = { role = "system", text = banner or "↻ Новая сессия" }
    bump_transcript()
end

local function load_log_overlay()
    local lines = {}
    local path = (os.getenv("HOME") or "") .. "/.tether/log/tether.log"
    local f = io.open(path, "r")
    if not f then
        lines[1] = "(лог пуст — запустите с --debug)"
        return lines
    end
    local all = {}
    for line in f:lines() do all[#all + 1] = line end
    f:close()
    -- last 200 lines (§6.8)
    local start = math.max(1, #all - 199)
    for i = start, #all do lines[#lines + 1] = all[i] end
    if #lines == 0 then lines[1] = "(лог пуст)" end
    return lines
end

local function execute_command(cmd)
    input_clear()
    debug_log("command: " .. tostring(cmd))
    if cmd == "quit" then S.quit = true; return end
    if cmd == "help" then S.overlay = "help"; return end
    if cmd == "status" then S.overlay = "status"; return end
    if cmd == "clear" then
        -- §6.8: clears in-memory transcript only; disk session untouched
        S.transcript = {}
        bump_transcript()
        return
    end
    if cmd == "log" then
        S.overlay = "log"
        S.overlay_data = { lines = load_log_overlay() }
        return
    end
    if cmd == "compact" then
        -- §6.8: force summarization of old messages, report as ── summary ──
        if agent and agent.compress_history then
            local h = agent.get_history()
            local compressed = agent.compress_history(h)
            -- replace history contents in place
            for i = #h, 1, -1 do table.remove(h) end
            for _, m in ipairs(compressed) do h[#h + 1] = m end
            local summary = ""
            for _, m in ipairs(h) do
                if m.role == "system" and tostring(m.content):find("summary") then
                    summary = tostring(m.content)
                end
            end
            S.transcript[#S.transcript + 1] = { role = "system", text = summary ~= "" and summary or "── summary ──" }
        end
        if agent and agent.estimate_tokens then
            S.tokens_used = agent.estimate_tokens(agent.get_history())
        end
        bump_transcript()
        return
    end
    if cmd == "new" then
        start_new_session()
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
            started_at = os.time(), -- M8/R3: for elapsed display
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
    elseif ev.type == "aborted" then
        S.transcript[#S.transcript + 1] = { role = "system", text = "⏹ прервано (Ctrl+C)" }
        bump_transcript()
    elseif ev.type == "usage" and ev.usage then
        if ev.usage.used then S.tokens_used = ev.usage.used end
        S.tokens_estimated = false
    elseif ev.type == "context_compressed" then
        S.transcript[#S.transcript + 1] = { role = "system", text = "── summary ──" }
        S.tokens_estimated = true
    elseif ev.type == "retry" then
        S.transcript[#S.transcript + 1] = {
            role = "system",
            text = string.format("↻ повтор %d (ждём %.1fs): %s",
                ev.attempt or 1, ev.delay or 0.5, ev.reason or ""),
        }
    end
    -- Fallback: estimate tokens from the real agent history (not just UI text)
    if ev.type ~= "usage" and agent and agent.estimate_tokens then
        local est = agent.estimate_tokens(agent.get_history())
        if est > 0 then
            S.tokens_used = est
            S.tokens_estimated = true
        end
    end
    if ev.type == "confirmation" then
        local detail = ev.details and ev.details[1]
        if detail then
            local args = detail.args or {}
            local label = detail.name .. " " .. (args.path or args.command or "")
            local body = ""
            if detail.name == "patch" and args.patch then
                body = args.patch
            elseif detail.name == "run" then
                body = args.command or ""
                if args.cwd then body = body .. "  (cwd=" .. args.cwd .. ")" end
                -- §6.10: warn on dangerous commands
                -- M7/D1+D2: extracted to ui.is_dangerous() (crash: %f is a Lua
                -- pattern boundary prefix, %frm%s was an invalid pattern).
                if ui_is_dangerous(body) then
                    body = body .. "\n⚠ потенциально опасная команда"
                end
            elseif args.content and args.path then
                body = "write → " .. args.path .. " (" .. #args.content .. " B)"
            end
            local options = {"[1/y] once     разрешить один раз",
                             "[2/a] session  разрешить до конца сессии",
                             "[3/A] always   сохранить в auto_approve",
                             "[4/d] details  показать diff/аргументы",
                             "[5/n] deny     отклонить",
                             "[6/Esc] cancel прервать ход агента"}
            S.confirmation = {
                label = label,
                body = body,
                options = options,
                detail = detail,
            }
            S.confirmation_sel = 1
            S.busy = false
            bump_transcript()
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
    S.busy_started_at = os.time() -- M8/R3: elapsed counter
    agent.abort_requested = false
    local ok, err = pcall(agent.turn, S.cfg, S.api_key or "", text, handle_agent_event)
    S.busy = false
    S.busy_started_at = nil
    agent.abort_requested = false
    if not ok and err then
        S.error_banner = tostring(err)
    end
end

-- M8/R8: emit ?1000h/?1006h only on state transitions (not every frame)
local function mouse_update_tracking()
    local mode = (S.cfg.ui and S.cfg.ui.mouse) or "auto"
    local want = M.mouse_wants(mode, { confirmation = S.confirmation ~= nil,
                                       palette_active = S.palette_active })
    if want ~= S.mouse_enabled then
        S.mouse_enabled = want
        w(ESC .. (want and "[?1000h[?1006h" or "[?1000l[?1006l"))
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
    elseif k.name == "end" and S.input == "" then
        -- M8/R3: End jumps to bottom (follow mode) when input is empty
        S.scroll = 0
        S.user_scrolled = false
    elseif k.name == "home" and S.input == "" then
        -- M8/R3: Home jumps to top of transcript
        S.user_scrolled = true
        S.scroll = math.max(0, #display_lines())
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
        start_new_session()
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
        execute_command("resume")
    elseif code == 6 then
        -- M8/R6: Ctrl+F — enter search mode (or re-run to exit)
        if S.search then
            S.search = nil
        else
            S.search = { input = "", active = false, matches = {}, idx = 0 }
        end
        bump_transcript()
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
        out2[#out2+1] = c6(math.floor(a / 4))
        out2[#out2+1] = c6((a % 4) * 16)
        out2[#out2+1] = "=="
    elseif rem == 2 then
        local a = string.byte(s:sub(i, i))
        local b = string.byte(s:sub(i+1, i+1))
        local n = a * 256 + b
        out2[#out2+1] = c6(math.floor(n / 1024))
        out2[#out2+1] = c6(math.floor(n / 16) % 64)
        out2[#out2+1] = c6((n % 16) * 4)
        out2[#out2+1] = "="
    end
    return table.concat(out2)
end

local function copy_last_assistant()
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
    if decision ~= "details" then
        -- M7/D3b: [d] details must keep the menu alive — Esc from the diff
        -- overlay returns to an intact confirmation, not an empty one where
        -- Enter (= allow) executes the tool by surprise.
        S.confirmation = nil
        S.confirmation_sel = 1
    end
    if detail and agent then
        local needs_resume = true
        if decision == "details" then
            -- §6.10 [d]: show the full args/diff; menu stays as-is underneath
            local args = detail.args or {}
            S.overlay = "diff"
            S.overlay_data = { text = args.patch or args.command or
                (args.content and ("write → " .. tostring(args.path) .. "\n" .. args.content) or "") }
            S.busy = false
            return
        end
        local ok, err = pcall(agent.confirm, detail.id, decision, S.cfg, handle_agent_event)
        if not ok and err then S.error_banner = tostring(err) end
        S.transcript[#S.transcript + 1] = {
            role = "system",
            text = "→ подтверждение: " .. decision .. " (" .. detail.name .. ")",
        }
        if decision == "cancel" then needs_resume = false end
        if needs_resume then
            -- resume the agent loop after confirmation
            S.busy = true
            local ok2, err2 = pcall(agent.continue, S.cfg, S.api_key or "", handle_agent_event)
            S.busy = false
            if not ok2 and err2 then S.error_banner = tostring(err2) end
        end
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
        -- 6 options; [d] does not resolve the confirmation
        local dec = { [1]="allow", [2]="session", [3]="always", [4]="details", [5]="deny", [6]="cancel" }
        resolve_confirmation(dec[sel] or "deny")
        return
    end
    if k.kind == "text" then
        local c = k.char
        -- M8/R3: digit shortcuts 1..6 (plus legacy y/a/A/d/n)
        local digit = tonumber(c)
        if digit and CONFIRM_DIGITS[digit] then
            resolve_confirmation(CONFIRM_DIGITS[digit])
        elseif c == "y" then resolve_confirmation("allow")
        elseif c == "n" then resolve_confirmation("deny")
        elseif c == "a" then resolve_confirmation("session")
        elseif c == "A" then resolve_confirmation("always")
        elseif c == "d" then resolve_confirmation("details")
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
        return
    end
    if k.kind == "mouse" and k.name == "press" then
        -- options are rendered inside the transcript flow; match by column band
        local c = S.confirmation
        if c and c.options and #c.options > 0 then
            local total = #display_lines()
            -- count of transcript rows above the options block
            local above = total - #c.options
            if k.row and k.row >= above + 1 and k.row <= above + #c.options then
                -- account for scroll offset
                local lines = display_lines()
                local L = layout()
                local bottom = math.min(total, total - S.scroll)
                local top = bottom - L.transcript_h + 1
                local idx = k.row - top + 1
                local text = lines[idx] or ""
                for i, opt in ipairs(c.options) do
                    if text:find(opt:sub(1, 10), 1, true) then
                        S.confirmation_sel = i
                        if i == 4 then resolve_confirmation("details")
                        else
                            local dec = { [1]="allow", [2]="session", [3]="always", [5]="deny" }
                            resolve_confirmation(dec[i] or "deny")
                        end
                        break
                    end
                end
            end
        end
    end
end

local function handle_overlay_key(k)
    local ov = S.overlay
    if k.kind == "esc" then
        S.overlay = nil; S.overlay_data = nil
        -- M7/D3b: after [d] details, S.confirmation was never cleared —
        -- closing the overlay returns to the intact confirmation menu.
        bump_transcript()
        return
    end
    if k.kind == "text" and (k.char == "q" or k.char == "?") then
        S.overlay = nil; S.overlay_data = nil
        bump_transcript()
        return
    end
    if ov == "resume" then
        local d = S.overlay_data or {}
        if k.kind == "special" then
            if k.name == "up" then
                d.sel = math.max(1, (d.sel or 1) - 1)
                bump_transcript()
            elseif k.name == "down" then
                d.sel = math.min(#(d.items or {}), (d.sel or 1) + 1)
                bump_transcript()
            end
        elseif k.kind == "enter" then
            local it = (d.items or {})[d.sel or 1]
            if it and it.id then
                S.overlay = nil; S.overlay_data = nil
                -- §6.8 /resume: actually load the picked session
                agent.clear()
                local messages = session.resume(it.id)
                if messages then
                    for _, msg in ipairs(messages) do
                        if msg.role == "user" then
                            S.transcript[#S.transcript + 1] = { role = "user", text = msg.content }
                            agent.add_user(msg.content)
                        elseif msg.role == "assistant" then
                            if msg.tool_calls then
                                agent.add_assistant({ tool_calls = msg.tool_calls })
                            else
                                S.transcript[#S.transcript + 1] = { role = "assistant", text = msg.content }
                                agent.add_assistant(msg.content)
                            end
                        elseif msg.role == "tool" then
                            -- M7/D4: restore tool results too; without them
                            -- the API rejects the first turn after resume.
                            agent.add_tool_result(msg.tool_call_id, msg.content or "")
                        end
                    end
                end
                S.session_id = it.id
                if S.cfg then S.cfg._session_id = it.id end
                S.transcript[#S.transcript + 1] =
                    { role = "system", text = "↻ сессия " .. tostring(it.id):sub(1, 8) .. " возобновлена" }
                bump_transcript()
            end
        end
    elseif ov == "model" then
        local d = S.overlay_data or {}
        if k.kind == "special" then
            if k.name == "up" then
                d.sel = math.max(1, (d.sel or 1) - 1)
                bump_transcript()
            elseif k.name == "down" then
                local n = #(d.items or {})
                if n > 0 then d.sel = math.min(n, (d.sel or 1) + 1) end
                bump_transcript()
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

    -- M8/R6: search mode — Ctrl+F entry/exit handled in handle_ctrl;
    -- here we consume typing/n/N while search is active.
    if S.search then
        if k.kind == "text" then
            S.search.input = (S.search.input or "") .. k.char
            search_rescan()
            return
        elseif k.kind == "backspace" then
            S.search.input = (S.search.input or ""):sub(1, -2)
            search_rescan()
            return
        elseif k.kind == "enter" then
            search_rescan()
            search_goto(1) -- like n: first match
            return
        elseif k.kind == "esc" or (k.kind == "ctrl" and k.code == 6) then
            S.search = nil
            bump_transcript()
            return
        elseif k.kind == "special" then
            if k.name == "f3" then search_goto(1)
            elseif k.name == "sf3" then search_goto(-1)
            else search_goto(k.char == "N" and -1 or 1)
            end
            return
        end
        -- anything else: fall through (scroll keys still work)
    end

    -- M8/R3: Enter on an active error banner opens the full error overlay
    if k.kind == "enter" and S.error_banner then
        S.overlay = "error"
        S.overlay_data = { text = S.error_banner }
        return
    end

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
        if k.code == 3 then                                     -- Ctrl+C
            if S.busy then
                -- §6.6: first Ctrl+C aborts the stream, keeps received text
                agent.abort_requested = true
                return
            end
            if S.palette_active then input_clear(); return end
            if #S.input > 0 then input_clear()
            elseif os.clock() - (S.last_ctrl_c or -10) < 1.0 then
                S.quit = true                                   -- double Ctrl+C
            else
                S.last_ctrl_c = os.clock()
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
    S.debug = S.cfg.debug or false
    -- M8/R2: wire config keys to the theme/wrap seams
    if S.cfg.ui and S.cfg.ui.theme then M.set_theme(S.cfg.ui.theme) end
    if S.cfg.ui then M.set_wrap(S.cfg.ui.wrap ~= false) end
    -- M8 follow-up: dead keys now wired — ascii/thinking/collapse/kb_protocol
    if S.cfg.ui and S.cfg.ui.ascii then
        M._env_ascii = M.ascii_active(S.cfg.ui.ascii)
    end
    if S.cfg.ui then
        S.thinking_visible = M.initial_thinking_visible(S.cfg.ui.thinking)
    end
    S.started_at = os.date("%Y-%m-%d %H:%M:%S")
    init_debug_log()

    local size = tether.get_terminal_size()
    if size then S.w, S.h = size.width, size.height end

    -- Session is created by app.lua (cfg._session_id); resume path reuses it.
    if S.cfg._session_id then
        S.session_id = S.cfg._session_id
    elseif session and session.new_session then
        local ok, id = pcall(session.new_session, S.workspace, S.model_name)
        S.session_id = ok and id or "?"
        S.cfg._session_id = S.session_id
    end

    -- M8/R8: mouse tracking is emitted dynamically on state transitions
    -- (mouse_update_tracking in the main loop), not statically at startup.
    -- M8/R9: alt-screen opt-in (cfg.ui.alt_screen, default false — native
    -- scrollback preserved); paired leave on exit below.
    if S.cfg.ui and S.cfg.ui.alt_screen then
        w(ESC .. "[?1049h")
    end
    -- T13: enable bracketed paste
    if not _ascii then
        w(ESC .. "[?2004h")
    end
    -- T16: keyboard protocol detection; cfg.ui.keyboard_protocol overrides
    -- ("auto"/nil -> detect; "kitty"/"modifyOtherKeys"/"plain" -> fixed).
    local cfg_proto = S.cfg.ui and M.kb_protocol_from_config(S.cfg.ui.keyboard_protocol)
    if cfg_proto then
        S.kb_protocol = cfg_proto
    else
        local ok, proto = pcall(tether.detect_kb_protocol)
        S.kb_protocol = (ok and type(proto) == "number") and proto or 0
    end
    if S.kb_protocol == 1 then
        w(ESC .. "[?u")
    end

    load_history()
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

        mouse_update_tracking() -- M8/R8: ?1000h/?1006h on state change only
        redraw()
    end

    if debug_log_fh then pcall(function() debug_log_fh:close() end) end
    -- M8/R9: leave alt-screen first if we entered it, then restore modes
    if S.cfg.ui and S.cfg.ui.alt_screen then
        w(ESC .. "[?1049l")
    end
    w(ESC .. "[?1006l" .. ESC .. "[?1000l" .. ESC .. "[?2004l" .. ESC .. "[?25h" .. "\n")
end

-- Export for unit tests (M7/T2)
M.is_dangerous = ui_is_dangerous

-- M8/R8: mouse mode state machine. Returns whether mouse tracking should be
-- enabled for the given UI state. Exported for unit tests.
--   auto:      mouse only over interactive targets (confirmation/palette)
--   on:        always;  off: never;  selection: never (terminal native)
function M.mouse_wants(mode, state)
    mode = mode or "auto"
    state = state or {}
    if mode == "on" then return true end
    if mode == "off" or mode == "selection" then return false end
    -- auto
    if state.confirmation then return true end
    if state.palette_active then return true end
    return false
end

return M
