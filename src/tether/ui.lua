-- tether / ui.lua — TUI with line-diff redraw.
local M = {}

-- ui_copy: UI strings safe-edit zone (embedded global `ui_copy` in the
-- host, loadfile fallback for tests/dev). Loaded first: the Constants
-- section below reads its tables. M-field (not a chunk local): the main
-- chunk sits at Lua's 200-locals limit.
M._copy = _G.ui_copy
if type(M._copy) ~= "table" then
    local chunk = loadfile("src/tether/ui/copy.lua")
    M._copy = (chunk and chunk()) or {}
end

-- ui_markdown: markdown-lite inline-strip pass (embedded global
-- `ui_markdown`, loadfile fallback for tests/dev). M-fields, not chunk
-- locals: the main chunk sits at Lua's 200-locals limit.
M._markdown = _G.ui_markdown
if type(M._markdown) ~= "table" then
    local chunk = loadfile("src/tether/ui/markdown.lua")
    M._markdown = (chunk and chunk()) or {}
end
-- Callers use M._markdown.strip_inline directly (proxy removed in 2.4).

-- ui_highlight: syntax token scanner + painter (embedded global
-- `ui_highlight`, loadfile fallback for tests/dev). Same M-field pattern.
M._highlight = _G.ui_highlight
if type(M._highlight) ~= "table" then
    local chunk = loadfile("src/tether/ui/highlight.lua")
    M._highlight = (chunk and chunk()) or {}
end

-- ui_keys: key reading, bytes -> typed events (embedded global `ui_keys`,
-- loadfile fallback for tests/dev). Same M-field pattern. The bag is M
-- itself: M._byte_stash / M._esc_stash_s below are the state the module
-- operates on, so tests keep poking the same M.* seams.
M._keys = _G.ui_keys
if type(M._keys) ~= "table" then
    local chunk = loadfile("src/tether/ui/keys.lua")
    M._keys = (chunk and chunk()) or {}
end

-- ui_palette: palette view-model — ranking, window geometry, indicator rows
-- (embedded global `ui_palette`, loadfile fallback for tests/dev). Pure
-- values in, rows out; the S-mutating interaction stays here until the
-- S-ownership follow-up. Same M-field pattern.
M._palette = _G.ui_palette
if type(M._palette) ~= "table" then
    local chunk = loadfile("src/tether/ui/palette.lua")
    M._palette = (chunk and chunk()) or {}
end

-- ui_regions: dock region renderers — input, footer, error banner
-- (embedded global `ui_regions`, loadfile fallback for tests/dev).
-- Slice in, ordered rowmap out; terminal I/O (set_row) stays here.
M._regions = _G.ui_regions
if type(M._regions) ~= "table" then
    local chunk = loadfile("src/tether/ui/regions.lua")
    M._regions = (chunk and chunk()) or {}
end

-- ui_ask_view: structured-question block view (embedded global `ui_ask_view`,
-- loadfile fallback for tests/dev). Ask state in, row strings out; keyboard
-- ownership and S.ask mutation stay here. Same M-field pattern.
M._ask_view = _G.ui_ask_view
if type(M._ask_view) ~= "table" then
    local chunk = loadfile("src/tether/ui/ask_view.lua")
    M._ask_view = (chunk and chunk()) or {}
end

-- ui_busy: busy pump and queue affordances (embedded global `ui_busy`,
-- loadfile fallback for tests/dev). Same M-field pattern; S is the bag.
M._busy = _G.ui_busy
if type(M._busy) ~= "table" then
    local chunk = loadfile("src/tether/ui/busy.lua")
    M._busy = (chunk and chunk()) or {}
end

-- ui_auth: login/logout flows — provider pickers, secret entry, device
-- polling, credential submit, logout picker + confirm (embedded global
-- `ui_auth`, loadfile fallback for tests/dev). Bag in, S-mutation out via
-- the deps table; keyboard ownership and S stay here. Same M-field pattern.
M._auth_flow = _G.ui_auth
if type(M._auth_flow) ~= "table" then
    local chunk = loadfile("src/tether/ui/auth.lua")
    M._auth_flow = (chunk and chunk()) or {}
end

-- ui_confirm: one-shot confirmation menu — rows, key kernel, resolve +
-- keyboard handler (embedded global `ui_confirm`, loadfile fallback for
-- tests/dev). Same M-field pattern; the 2.2 key table keeps the keyboard.
M._confirm = _G.ui_confirm
if type(M._confirm) ~= "table" then
    local chunk = loadfile("src/tether/ui/confirm.lua")
    M._confirm = (chunk and chunk()) or {}
end

-- ui_ask: the question-block controller — cursor/answer state machine,
-- editors, submit/cancel (embedded global `ui_ask`, loadfile fallback for
-- tests/dev). Same M-field pattern; the view stays in ui_ask_view and the
-- keyboard in the 2.2 key table.
M._ask = _G.ui_ask
if type(M._ask) ~= "table" then
    local chunk = loadfile("src/tether/ui/ask.lua")
    M._ask = (chunk and chunk()) or {}
end

-- ui_complete: path completion engine — token/candidates/cycle/restore +
-- @ mention open/refilter/accept/close (embedded global `ui_complete`,
-- loadfile fallback for tests/dev). Same M-field pattern; S-derived deps
-- come from M._complete_deps per call.
M._complete = _G.ui_complete
if type(M._complete) ~= "table" then
    local chunk = loadfile("src/tether/ui/complete.lua")
    M._complete = (chunk and chunk()) or {}
end

-- ui_themes: theme tables, role painters, ASCII mapping, hint painters,
-- painter-table builder (embedded global `ui_themes`, loadfile fallback
-- for tests/dev). Same M-field pattern; live seams (theme name, depth,
-- ascii/light probes) resolve in the facade per call.
M._themes = _G.ui_themes
if type(M._themes) ~= "table" then
    local chunk = loadfile("src/tether/ui/themes.lua")
    M._themes = (chunk and chunk()) or {}
end

-- ============================================================
-- ANSI
-- ============================================================
local ESC = "\27"
local function w(s) if tether and tether.write then tether.write(s) end end

-- T20: ASCII mode — NO_COLOR=1 or TERM=dumb → strip all ANSI + non-ASCII glyphs
-- M8/R1 test seam: tests override M._ascii_mode or M._env_ascii; production
-- reads env once. cfg.ui.ascii ("auto"|"on"|"off") overrides via M.ascii_active.
local _ascii = (os.getenv("NO_COLOR") == "1") or (os.getenv("TERM") == "dumb")
M._env_ascii = _ascii

-- cfg.ui.ascii resolution: "on" (legacy true) forces, "off" (legacy false)
-- beats env, anything else ("auto"/nil/unknown) falls back to env/auto.
function M.ascii_active(cfg_ascii)
    if cfg_ascii == "on" or cfg_ascii == true then return true end
    if cfg_ascii == "off" or cfg_ascii == false then return false end
    return M._env_ascii or M._ascii_mode or false
end

-- Effective ascii flag used everywhere at render time.
local function ascii_active()
    local ua = S.cfg and S.cfg.ui and S.cfg.ui.ascii
    return M.ascii_active(ua)
end

local _colorterm = os.getenv("COLORTERM")
M._color_depth = nil -- test seam
function M.color_depth()
    if M._color_depth then return M._color_depth end
    if M._ascii_mode or M._env_ascii or _ascii then return "none" end
    if _colorterm == "truecolor" or _colorterm == "24bit" then return "truecolor" end
    return "256"
end
M.get_color_depth = M.color_depth

-- 7.3: ui.highlight ("auto" default / "on" / "off") vs depth precedence.
-- S may be nil (md_render is a pure function callable before M.run):
-- cfg absent ⇒ "auto". "off" beats everything; "auto"/"on" = on unless depth
-- is "none" (ASCII/NO_COLOR/dumb); mono theme emits no SGR naturally
-- (roles missing ⇒ raw text), so no special case here.
-- Note: this function is called from md_render which runs after M.run() has
-- created the local S; it reads M._get_state() (nil-safe) instead of the
-- local S upvalue (declared later in the file, so not visible here).
local function highlight_enabled()
    local st = M._get_state()
    local hl = (st and st.cfg and st.cfg.ui and st.cfg.ui.highlight) or "auto"
    if hl == "off" then return false end
    return M.color_depth() ~= "none"
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

-- M8/R1: glyph → ASCII mapping lives in ui_themes (pure); this wrapper
-- keeps the facade mode gate so unit tests and goldens observe identical
-- behavior through ui.to_ascii.
local function to_ascii(s)
    if not (M._ascii_mode or M._env_ascii or _ascii) then return s end
    return M._themes.to_ascii(s)
end
M.to_ascii = to_ascii

-- M8/R2: theme tables live in ui_themes; the active name stays here
-- (set via set_theme from cfg or tests).
local _theme_name = "default"

-- M8/R2: wrap toggle (cfg.ui.wrap); false = truncate to width instead.
local _wrap_enabled = true

-- splash-colors: light-background probe for the default theme's light
-- variant. Test seams: M._light_bg (true/false override, nil = auto),
-- M._colorfgbg (COLORFGBG override). Auto reads COLORFGBG ("fg;bg"):
-- a bg of 7/15 means a light terminal. Anything unparseable or missing
-- falls back to dark, never to light.
M._light_bg = nil
M._colorfgbg = nil
function M.is_light_bg()
    if M._light_bg ~= nil then return M._light_bg end
    local fb = M._colorfgbg or os.getenv("COLORFGBG") or ""
    local bg = fb:match(".*;(.-)%s*$") or fb:match("^(.-)%s*$")
    local n = tonumber(bg)
    return n == 7 or n == 15
end

-- M8/R2: role-based color lives in ui_themes (pure); this wrapper
-- resolves the live theme/depth/light/ascii state per call.
local function sgr_role(role, s)
    return M._themes.paint_role(M._themes.THEMES, _theme_name, role, s,
        M.color_depth(), M.is_light_bg(),
        M._ascii_mode or M._env_ascii or _ascii)
end

-- Role helpers: every UI color goes through the active theme, so selecting
-- `mono` really drops all color and `solarized` re-tints the whole interface
-- (previously these helpers emitted fixed SGR codes and ignored the theme).
local function cyan(s)   return sgr_role("accent",  s) end
local function yellow(s) return sgr_role("warn",    s) end
local function red(s)    return sgr_role("error",   s) end
local function green(s)  return sgr_role("success", s) end
local function dim(s)    return sgr_role("dim",     s) end
local function muted(s)  return sgr_role("muted",   s) end
local function italic(s) return sgr_role("italic",  s) end
local function rev(s)    return sgr_role("reverse", s) end

-- Exports for unit tests + runtime config hookup (M8/R2)
M.THEMES = M._themes.THEMES
M.set_theme = function(name)
    if M._themes.THEMES[name] then
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
-- M10: display-width per codepoint, adapted from terminal.lua's
-- terminal.text.width approach (pure-Lua wcwidth): combining marks and
-- zero-width joiners are 0 columns, East-Asian wide/fullwidth/emoji are 2,
-- everything printable is 1. Control characters are excluded from width
-- math by callers (they never reach the transcript as-is).
local function char_width(cp)
    if not cp or cp < 32 then return 0 end          -- C0 controls
    if cp == 0x7F then return 0 end                 -- DEL
    -- combining marks and zero-width (approximate Unicode ranges)
    if (cp >= 0x0300 and cp <= 0x036F)   -- combining diacritical marks
        or (cp >= 0x0483 and cp <= 0x0489)
        or (cp >= 0x0591 and cp <= 0x05BD)
        or (cp >= 0x0610 and cp <= 0x061A)
        or (cp >= 0x064B and cp <= 0x065F)
        or (cp >= 0x0E31 and cp <= 0x0E3A and cp ~= 0x0E32 and cp ~= 0x0E33)
        or (cp >= 0x200B and cp <= 0x200F)   -- ZWSP..RLM
        or cp == 0x2028 or cp == 0x2029
        or (cp >= 0x2060 and cp <= 0x2064)
        or cp == 0xFEFF                       -- BOM/ZWNBSP
        or (cp >= 0xFE00 and cp <= 0xFE0F)   -- variation selectors
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x20D0 and cp <= 0x20FF) then
        return 0
    end
    -- East-Asian Wide/Fullwidth + emoji
    if (cp >= 0x1100 and cp <= 0x115F)   -- Hangul Jamo
        or (cp >= 0x2E80 and cp <= 0x303E)   -- CJK radicals, Kangxi, CJK symbols
        or (cp >= 0x3041 and cp <= 0x33FF)   -- Hiragana..CJK compat
        or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK ext A
        or (cp >= 0x4E00 and cp <= 0x9FFF)   -- CJK unified
        or (cp >= 0xA000 and cp <= 0xA4CF)   -- Yi
        or (cp >= 0xAC00 and cp <= 0xD7A3)   -- Hangul syllables
        or (cp >= 0xF900 and cp <= 0xFAFF)   -- CJK compat ideographs
        or (cp >= 0xFE10 and cp <= 0xFE19)   -- vertical forms
        or (cp >= 0xFE30 and cp <= 0xFE6F)   -- CJK compat forms
        or (cp >= 0xFF00 and cp <= 0xFF60)   -- fullwidth forms
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x1F300 and cp <= 0x1F64F) -- emoji pictographs
        or (cp >= 0x1F900 and cp <= 0x1F9FF) -- supplemental symbols
        or (cp >= 0x20000 and cp <= 0x3FFFD) then -- CJK ext B+
        return 2
    end
    return 1
end
M.char_width = char_width

-- T176: one UTF-8 step that never raises. Returns the byte index after the
-- char at i and its display width. Structurally valid sequences (checked
-- continuation bytes, no overlongs/surrogates/out-of-range) decode to
-- char_width(cp); stray bytes degrade to a single width-1 step instead of
-- raising like utf8.codes/offset/codepoint do ("invalid UTF-8 code").
-- M-field (not a chunk local): ui.lua already sits at Lua's 200-locals
-- limit for the main chunk.
function M._step_char(s, i)
    local b = s:byte(i)
    local clen = 1
    if b >= 0xF0 and b <= 0xF4 then clen = 4
    elseif b >= 0xE0 then clen = 3
    elseif b >= 0xC2 then clen = 2 end
    if clen > 1 and i + clen - 1 <= #s then
        local c1 = s:byte(i + 1)
        local ok = c1 >= 0x80 and c1 <= 0xBF
        local cp = nil
        if ok and clen == 2 then
            cp = (b - 0xC0) * 64 + (c1 - 0x80)
            if cp < 0x80 then cp = nil end -- overlong
        elseif ok then
            local c2 = s:byte(i + 2)
            ok = c2 >= 0x80 and c2 <= 0xBF
            if ok and clen == 3 then
                cp = (b - 0xE0) * 4096 + (c1 - 0x80) * 64 + (c2 - 0x80)
                if cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF) then cp = nil end
            elseif ok then
                local c3 = s:byte(i + 3)
                if c3 >= 0x80 and c3 <= 0xBF then
                    cp = (b - 0xF0) * 262144 + (c1 - 0x80) * 4096
                        + (c2 - 0x80) * 64 + (c3 - 0x80)
                    if cp < 0x10000 or cp > 0x10FFFF then cp = nil end
                end
            end
        end
        if cp then return i + clen, char_width(cp) end
    end
    return i + 1, char_width(b)
end
-- Display width of a string: strips ANSI SGR, sums per-codepoint widths.
-- (ulen counted escape bytes and gave CJK 1 column — both produced the
-- stray-character artifacts seen while scrolling.)
local function vlen(s)
    if not s or s == "" then return 0 end
    s = s:gsub("\27%[[0-9;?]*[a-zA-Z]", "")
    local w = 0
    local i = 1
    while i <= #s do
        local ni, cw = M._step_char(s, i)
        w = w + cw
        i = ni
    end
    return w
end
-- M11: split s into {t, w, sp} cells: an SGR sequence is one zero-width
-- cell, any other codepoint is one cell of char_width() columns. Invalid
-- UTF-8 bytes degrade to width-1 cells instead of raising.
local function cells(s)
    local out = {}
    local i = 1
    while i <= #s do
        local _, finish = s:find("^\27%[[0-9;?]*[a-zA-Z]", i)
        if finish then
            out[#out + 1] = { t = s:sub(i, finish), w = 0, sp = false }
            i = finish + 1
        else
            local b = s:byte(i)
            local clen = 1
            if b >= 0xF0 then clen = 4 elseif b >= 0xE0 then clen = 3
            elseif b >= 0xC2 then clen = 2 end
            if clen > 1 then
                if i + clen - 1 > #s then clen = 1
                else
                    for k = i + 1, i + clen - 1 do
                        local cb = s:byte(k)
                        if cb < 0x80 or cb > 0xBF then clen = 1; break end
                    end
                end
            end
            local ch = s:sub(i, i + clen - 1)
            local w = (clen == 1) and char_width(b) or 1
            if clen > 1 then
                local cp = utf8.codepoint(ch)
                w = (cp and char_width(cp)) or 1
            end
            out[#out + 1] = { t = ch, w = w, sp = (ch == " ") }
            i = i + clen
        end
    end
    return out
end

-- Cut to `width` DISPLAY columns without splitting a glyph or an SGR sequence.
-- The byte shortcut (`:sub(1, width)`) cut box-drawing/CJK glyphs mid-byte and
-- could drop the closing reset, leaving the terminal with broken UTF-8 and a
-- bleeding colour; the char-index one (usub) counted glyphs, not columns.
local function fit_cols(s, width)
    if vlen(s) <= width then return s end
    local parts, used = {}, 0
    for _, u in ipairs(cells(s)) do
        if used + u.w > width then break end
        parts[#parts + 1] = u.t
        used = used + u.w
    end
    local out = table.concat(parts)
    -- only styled input can lose its closing SGR to the cut
    if s:find("\27", 1, true) then out = out .. ESC .. "[0m" end
    return out
end

-- M11: greedy word wrap of one paragraph (no newlines) to display width.
-- Breaks on spaces; a token longer than the width is cut hard. Optional
-- cont_prefix/cont_width restyle continuation lines (code blocks): lines
-- after the first wrap to cont_width and carry the prefix.
-- ponytail: single O(n) greedy pass, no hyphenation or widow control;
-- upgrade to a real line-breaker only if typography ever matters here.
local function wrap_words(para, width, cont_prefix, cont_width)
    if width < 1 then width = 1 end
    if cont_width and cont_width < 1 then cont_width = 1 end
    local units = cells(para)
    local lines = {}
    local cur, curw, lastsp = {}, 0, nil
    local first, drop_leading = true, false
    local function lim() return (first or not cont_prefix) and width or cont_width end
    local function emit()
        local t = {}
        for _, u in ipairs(cur) do t[#t + 1] = u.t end
        -- trim only trailing spaces; do NOT strip leading spaces (indentation
        -- matters for code blocks) nor spaces immediately before an SGR
        -- sequence (they are code text, not wrap artifacts)
        local s = table.concat(t):gsub(" +$", "")
        if s == "" and #lines > 0 then return end
        if (not first) and cont_prefix then s = cont_prefix .. s end
        lines[#lines + 1] = s
        first = false
    end
    for _, u in ipairs(units) do
        if u.sp and drop_leading and #cur == 0 then
            -- separator consumed by a break; skip
        else
            local consume = false
            if curw + u.w > lim() and #cur > 0 then
                if u.sp then
                    emit() -- line ends before the separator
                    cur, curw, lastsp = {}, 0, nil
                    consume = true
                elseif lastsp and lastsp > 1 then
                    local head, tail, tailw = {}, {}, 0
                    for k = 1, lastsp - 1 do head[#head + 1] = cur[k] end
                    for k = lastsp + 1, #cur do
                        tail[#tail + 1] = cur[k]; tailw = tailw + cur[k].w
                    end
                    cur = head
                    emit()
                    cur, curw, lastsp = tail, tailw, nil
                    for k = 1, #tail do
                        if tail[k].sp then lastsp = k end
                    end
                else
                    emit() -- hard cut inside an overlong token
                    cur, curw, lastsp = {}, 0, nil
                end
                drop_leading = true
            end
            if not consume then
                cur[#cur + 1] = u
                curw = curw + u.w
                if u.sp then lastsp = #cur else drop_leading = false end
            end
        end
    end
    if #cur > 0 or #lines == 0 then emit() end
    return lines
end

local function wrap(text, width)
    if width < 1 then width = 1 end
    local out = {}
    for para in (text .. "\n"):gmatch("([^\n]*)\n") do
        if para == "" then
            out[#out + 1] = ""
        elseif not _wrap_enabled then
            -- M8/R2: wrap off → truncate with arrow marker
            -- 7.4: cut at a display-width boundary (fit_cols keeps every SGR
            -- sequence whole and never splits a multibyte glyph).
            local cut = fit_cols(para, width - 1)
            out[#out + 1] = (M._ascii_mode or M._env_ascii or _ascii)
                and cut .. ">"
                or cut .. "→"
        else
            for _, l in ipairs(wrap_words(para, width)) do
                out[#out + 1] = l
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
-- The inline-strip pass moved to ui_markdown (src/tether/ui/markdown.lua);
-- callers use M._markdown.strip_inline directly. md_render stays here until
-- the regions cut (it needs wrap/trunc/highlight); M.md_ansi stays until the
-- themes cut (it is theme-bound via sgr_role).

-- M11/7.1: code-block syntax highlighting (7.2 tokenizer, 7.3 integration).
-- Depth: COLORTERM=truecolor|24bit -> "truecolor", else "256"; ascii/
-- NO_COLOR/TERM=dumb -> "none". Test seam: M._color_depth set in the ANSI
-- section drives color_depth(); roles resolve via sgr_role (mono theme ⇒ raw text).

function M.md_ansi(kind, text)
    return sgr_role(kind, text)
end

-- ============================================================
-- 7.2: per-line syntax token scanner (stateful for block comments)
-- ============================================================
-- Moved to ui_highlight (src/tether/ui/highlight.lua): langs table,
-- tokenize() and highlight() with identical behavior. Callers use
-- M._highlight.tokenize / M._highlight.highlight directly (proxies removed
-- in 2.4); highlight sites inject the theme-bound sgr_role.

-- `lite` (user text): inline markup and fenced blocks render, block structure
-- does not — heading, list and table markers stay literal so the row remains a
-- faithful echo of what was typed.
local function md_render(text, width, ansi_fn, lite)
    local ascii = M._ascii_mode or M._env_ascii or _ascii
    local box = ascii and { tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|" }
                            or { tl = "┌", tr = "┐", bl = "└", br = "┘", h = "─", v = "│" }
    local bullet = ascii and "-" or "•"
    local out = {}
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    local i = 1
    while i <= #lines do
        local line = lines[i]
        -- fence: ``` optional lang (may carry trailing attributes) optional
        local fence = line:match("^%s*%`%`%`%s*(.*)$")
        if fence then
            -- strip an inline-closing fence (``` alone closes) from the info
            -- string; the first token is the language, the rest are attributes.
            local lang = fence:match("[%w%+%.#%-]+") or ""
            local inner = math.max(width - 4, 1)
            -- top border off-by-one fix: the frame spans exactly `width`
            -- columns (body rows are v + inner + v = inner + 4), so the fill
            -- is what's left after corners and the (readable) label. The
            -- frame is dim; the language label stays in the default fg.
            local prefix = dim(box.tl .. box.h)
            if lang ~= "" then prefix = prefix .. " " .. lang .. " " end
            local fill = math.max(width - vlen(prefix) - 1, 1)
            out[#out + 1] = prefix .. dim(string.rep(box.h, fill) .. box.tr)
            -- 7.3: highlight when the fence lang is known (case-insensitive);
            -- unknown/absent langs render plain (7.5). Tokenize each source
            -- line, emit SGR-colored text, then run it through the existing
            -- SGR-aware wrap (zero-width SGR cells, so split boundaries never
            -- land inside a sequence).
            local hl_state = M._highlight.langs[lang:lower()] and highlight_enabled() and {} or nil
            i = i + 1
            -- continuation indent needs room; absurdly narrow frames fall
            -- back to plain wrapping with no indent
            local cpre, cw = "  ", inner - 2
            if inner < 4 then cpre, cw = "", inner end
            while i <= #lines and not lines[i]:match("^%s*%`%`%`%s*$") do
                local body_line = lines[i]
                if hl_state then
                    body_line = M._highlight.highlight(body_line, lang, hl_state, sgr_role)
                end
                for _, seg in ipairs(wrap_words(body_line, inner, cpre, cw)) do
                    out[#out + 1] = dim(box.v) .. " " .. seg
                        .. string.rep(" ", math.max(inner - vlen(seg), 0)) .. " " .. dim(box.v)
                end
                i = i + 1
            end
            out[#out + 1] = dim(box.bl .. string.rep(box.h, inner + 2) .. box.br)
            i = i + 1 -- skip closing fence (or last line)
        elseif not lite and line:match("^%s*|") then
            -- table: consecutive source lines beginning with |
            local tlines = {}
            while i <= #lines and lines[i]:match("^%s*|") do
                tlines[#tlines + 1] = lines[i]
                i = i + 1
            end
            local rows = {}
            for _, tl in ipairs(tlines) do
                -- strip the enclosing pipes, then split: without this the
                -- trailing pipe yields an empty extra cell and a dangling │
                local inner = tl:match("^%s*%|(.*)%|%s*$") or tl
                local cells = {}
                local pos = 1
                while true do
                    local bar = inner:find("|", pos, true)
                    local chunk = bar and inner:sub(pos, bar - 1) or inner:sub(pos)
                    chunk = chunk:gsub("^%s*(.-)%s*$", "%1")
                    cells[#cells + 1] = M._markdown.strip_inline(chunk, ansi_fn)
                    if not bar then break end
                    pos = bar + 1
                end
                rows[#rows + 1] = cells
            end
            local ncol = 0
            for _, r in ipairs(rows) do ncol = math.max(ncol, #r) end
            local colw = {}
            for c = 1, ncol do
                local mx = 0
                for _, r in ipairs(rows) do
                    if r[c] then mx = math.max(mx, vlen(r[c])) end
                end
                colw[c] = mx
            end
            for _, r in ipairs(rows) do
                local is_sep = #r > 0
                for c = 1, ncol do
                    local cell = r[c] or ""
                    if not cell:match("^:?%-+:?$") then is_sep = false end
                end
                if is_sep then
                    local parts = {}
                    for c = 1, ncol do parts[#parts + 1] = string.rep("─", colw[c]) end
                    local rule = dim(table.concat(parts, "─┼─"))
                    if vlen(rule) > width then rule = fit_cols(rule, width) end
                    out[#out + 1] = rule
                else
                    local cells = {}
                    for c = 1, ncol do
                        local cell = r[c] or ""
                        cells[#cells + 1] = cell .. string.rep(" ", math.max(colw[c] - vlen(cell), 0))
                    end
                    local row = table.concat(cells, " │ ")
                    if vlen(row) > width then row = fit_cols(row, width) end
                    out[#out + 1] = row
                end
            end
        else
            local hashes, rest = line:match("^(#+)%s+(.*)")
            if not lite and hashes and rest then
                -- headings: wrap to width, heading role colour, no trailing blank
                local htext = M._markdown.strip_inline(rest, ansi_fn)
                htext = sgr_role("heading", htext)
                for _, wl in ipairs(wrap(htext, width)) do
                    out[#out + 1] = wl
                end
                i = i + 1
            elseif not lite and line:match("^%s*%d+%.%s+") then
                -- ordered list: numbered prefix + aligned continuation indent
                local num = line:match("^%s*(%d+%.?)%s+")
                local item = line:gsub("^%s*%d+%.%s+", "", 1)
                local body = M._markdown.strip_inline(item, ansi_fn)
                local prefix = num .. " "
                local prew = vlen(prefix)
                local wrapped = wrap(body, math.max(width - prew, 1))
                for wi, wl in ipairs(wrapped) do
                    out[#out + 1] = (wi == 1) and (prefix .. wl)
                        or (string.rep(" ", prew) .. wl)
                end
                i = i + 1
            elseif not lite and line:match("^%s*[%-%*]%s+") then
                local item = line:gsub("^%s*[%-%*]%s+", "", 1)
                local body = M._markdown.strip_inline(item, ansi_fn)
                local prefix = bullet .. " "
                local prew = vlen(prefix)
                local wrapped = wrap(body, math.max(width - prew, 1))
                for wi, wl in ipairs(wrapped) do
                    out[#out + 1] = (wi == 1) and (prefix .. wl)
                        or (string.rep(" ", prew) .. wl)
                end
                i = i + 1
            else
                local rendered = M._markdown.strip_inline(line, ansi_fn)
                for _, wl in ipairs(wrap(rendered, width)) do
                    out[#out + 1] = wl
                end
                i = i + 1
            end
        end
    end
    -- collapse runs of blank rows to one, drop leading/trailing blanks
    local collapsed = {}
    local prev_blank = false
    for _, r in ipairs(out) do
        local blank = r == ""
        if blank then
            if not prev_blank and #collapsed > 0 then collapsed[#collapsed + 1] = r end
            prev_blank = true
        else
            collapsed[#collapsed + 1] = r
            prev_blank = false
        end
    end
    while #collapsed > 0 and collapsed[1] == "" do table.remove(collapsed, 1) end
    while #collapsed > 0 and collapsed[#collapsed] == "" do table.remove(collapsed) end
    return collapsed
end
M.md_render = md_render

local function trunc(s, maxw)
    if maxw < 1 then return "" end
    if vlen(s) <= maxw then return s end
    local ascii = M._ascii_mode or M._env_ascii or _ascii
    local ell = ascii and "..." or "…"
    local ell_w = ascii and 3 or 1
    if maxw < ell_w then
        return ascii and string.rep(".", maxw) or ell
    end
    local i, width = 1, 0
    local budget = maxw - ell_w
    while i <= #s do
        local _, finish = s:find("^\27%[[0-9;?]*[a-zA-Z]", i)
        if finish then
            i = finish + 1
        else
            -- T176: step_char never raises on stray bytes (utf8.codepoint /
            -- utf8.offset do), so truncating a split sequence degrades
            -- instead of crashing the frame.
            local ni, w = M._step_char(s, i)
            if width + w > budget then break end
            width = width + w
            i = ni
        end
    end
    return s:sub(1, i - 1) .. ell .. ESC .. "[0m"
end
M.vlen = vlen   -- export (M9/T39: SGR-aware display width)
-- 7.4: test seam — strip every SGR escape sequence (text-invariant checks).
-- 7.4: test seam — strip every SGR escape sequence (text-invariant checks).
-- Same pattern vlen() uses so a strip round-trips width exactly.
M._strip_sgr = function(s) return ((s or ""):gsub("\27%[[0-9;?]*[a-zA-Z]", "")) end
M.trunc = trunc -- export (M9/T39)

-- ============================================================
-- Constants
-- ============================================================
-- palette-only T2: digit shortcuts for the confirmation menu (1..5)
-- Values live in ui_copy (safe-edit zone); this local keeps call sites unchanged.
local CONFIRM_DIGITS = M._copy.confirm.digits
M.CONFIRM_DIGITS = CONFIRM_DIGITS
-- confirm-menu-redesign D1/D5: per-tool question row and the muted hint.
-- M-fields, not chunk locals (ui.lua sits at Lua's 200-locals limit).
M.CONFIRM_QUESTIONS = M._copy.confirm.questions
M.CONFIRM_QUESTION_FALLBACK = M._copy.confirm.question_fallback
-- palette-hints: hint rows are {key, act} pair tables painted by M.hint_paint
-- (key tokens dim, action words muted, two-space pair separators).
M.CONFIRM_HINT = M._copy.confirm.hint
-- palette-hints D2: per-mode dock hints — only the keys the mode's handler
-- actually consumes (verified against the S.palette_mode branches).
M.PALETTE_HINTS = M._copy.palette_hints

-- §6.6: spinner frames for the busy status indicator and thinking rows
-- field. ASCII variant for TERM=dumb / NO_COLOR (M8/R1). Declared here (not
-- next to their first use) so both the transcript tail and the status line
-- can reach them as upvalues. Glyphs live in ui_copy (safe-edit zone).
local SPINNER = M._copy.spinner.frames
local SPINNER_ASCII = M._copy.spinner.ascii
M.SPINNER_ASCII = SPINNER_ASCII

local SLASH_COMMANDS = M._copy.commands
M.SLASH_COMMANDS = SLASH_COMMANDS

-- 3.1: fuzzy_match / fuzzy_score — subsequence matcher, prefix ranked first,
-- declaration-order ties, empty filter lists all. Moved to ui_palette
-- (src/tether/ui/palette.lua); callers use M._palette.* directly.

-- M10: keymap as data (idea from terminal.lua input.keymap) — the single
-- source of truth for keyboard bindings. Consumed by docs/tests; the help
-- screen is gone (M9), so this table is where bindings stay documented.
-- Values live in ui_copy (safe-edit zone).
local KEYMAP = M._copy.keys.map
M.KEYMAP = KEYMAP

-- add-ask-tool: the question block's own bindings, as data. While the block is
-- open it owns the keyboard, so these are its meanings for the shared keys:
-- the arrows move across the option rows and the freeform row, a digit picks
-- that option (toggling it on a `multi` question), Space picks the highlighted
-- option of a single question (toggling it on a `multi` one), Enter submits/
-- accepts, Tab edits the highlighted row (a note on an option, the freeform
-- answer on its row), ←/→ walk the question set and Esc cancels it without
-- stopping the turn. Values live in ui_copy (safe-edit zone).
local ASK_KEYS = M._copy.keys.ask
M.ASK_KEYS = ASK_KEYS

-- transcript: embedded global (main.c mods[]); loadfile fallback for tests.
local transcript = _G.transcript
if type(transcript) ~= "table" then
    local chunk = loadfile("src/tether/transcript.lua")
    transcript = (chunk and chunk()) or {}
end
M._transcript = transcript

-- commands: embedded global (main.c mods[]); loadfile fallback for tests.
local commands = _G.commands
if type(commands) ~= "table" then
    local chunk = loadfile("src/tether/commands.lua")
    commands = (chunk and chunk()) or {}
end

-- turn: control facade over agent (abort seam + busy begin/finish).
local turn = _G.turn
if type(turn) ~= "table" then
    local chunk = loadfile("src/tether/turn.lua")
    turn = (chunk and chunk()) or {}
end

-- reactor: single-threaded event loop (main.c mods[]); loadfile fallback
-- for tests. Owns the main loop once run() starts: stdin drain, transport
-- sources, timers and the per-tick callback. One line, no chunk locals:
-- the main chunk sits at Lua's 200-locals limit. Published as _G.reactor so
-- the synchronous callers (api.stream, agent backoff) find the very loop
-- this ui runs: the host preloads the global, the loadfile fallback does not.
M._reactor = _G.reactor or ((loadfile("src/tether/reactor.lua")) or function() return {} end)()
_G.reactor = M._reactor

-- tools: same pattern as turn/commands — global in the host, loadfile fallback
-- for tests/dev. Captured as a local so bang path survives global restore in
-- the test harness (run_ui_with snapshots/restores _G after load). Call sites
-- prefer _G.tools when the host (or a test) has installed it after load.
local tools = _G.tools
if type(tools) ~= "table" then
    local chunk = loadfile("src/tether/tools.lua")
    tools = (chunk and chunk()) or {}
end
local function tools_mod()
    local g = rawget(_G, "tools")
    if type(g) == "table" then return g end
    return tools
end

-- Forward declaration (lexical order differs from paint order):
-- ui_regions call sites above invoke painters(); the body lives next to
-- M._painters below, after caret_glyph/md_render are declared.
local painters

-- ============================================================
-- State
-- ============================================================
local S
-- Test seams: exposed AFTER `local S` so the closures bind the state
-- upvalue (defined above it they would capture the global instead).
-- Nil-safe: S is created by new_state() inside run(); before that the
-- guards let callers pcall through instead of crashing module load.
M._get_state = function() return S end
M._set_error_banner = function(v) if S then S.error_banner = v end end

-- add-steering-input: pure FIFO push with a hard cap. Returns false when full
-- (caller raises the one-shot banner); never drops silently.
local QUEUE_CAP = 8
local function queue_push(q, text)
    if #q >= QUEUE_CAP then return false end
    q[#q + 1] = text
    return true
end
M._queue_push = queue_push
local debug_log_fh = nil
M._debug_capture = nil -- test seam: append every logged line when set
local function debug_log(msg)
    if S and S.debug then
        local cap = M._debug_capture
        if cap then cap[#cap + 1] = msg end
    end
    if not debug_log_fh then return end
    -- flush every line: without it the file stays empty until exit (and a
    -- kill/crash loses everything), so tailing tether.log shows nothing.
    pcall(function()
        debug_log_fh:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
        debug_log_fh:flush()
    end)
end
local function init_debug_log()
    if S and S.debug and debug_log_fh == nil then
        local dir = (os.getenv("HOME") or "/tmp") .. "/.tether/log"
        pcall(function() tether.mkdirp(dir) end)
        local ok, fh = pcall(io.open, dir .. "/tether.log", "a")
        if ok and fh then
            debug_log_fh = fh
            debug_log("debug log started")
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
        debug = false,

        -- Transcript rows / index / cache / synthetic tails live in the
        -- transcript module; S keeps only paint-time viewport dimensions.
        last_transcript_h = nil,

        input = "",
        cursor = 0,  -- byte offset

        busy = false,
        quit = false,

        -- A: turn feedback. waiting = request sent, no token yet (Working
        -- indicator shows in the input box); streaming = deltas arriving.
        waiting = false,
        streaming = false,

        error_banner = nil,

        expand_all = false,
        thinking_visible = true, -- M8 follow-up: overridden from cfg.ui.thinking in run()

        -- add-ask-tool: the open question block (or nil) and its synthetic
        -- tail entry — see render_entry's virt == "ask" branch and
        -- handle_ask_key.
        ask = nil,

        palette_active = false,
        palette_mode = "command",
        palette_items = {},
        palette_sel = 1,
        palette_skills = nil,    -- 1.3: skill rows, resolved once per palette open
        palette_query = nil,     -- palette-fuzzy-search: typed filter for model/login palettes
        _palette_all = nil,      -- palette-fuzzy-search: unfiltered rows while a query is active
        _in_copy_palette = nil,  -- 5.2: set when the /copy palette is open
        _in_login_palette = nil, -- add-provider-login: bare /login provider picker
        _in_logout_palette = nil, -- logout-picker: bare /logout stored-credentials picker
        _logout_confirm = nil,   -- logout-confirm: provider the deletion step targets
        _logout_sel = nil,       -- logout-confirm: row index in the list to return to
        _in_resume_palette = nil, -- palette-only: /resume session list
        _in_model_palette = nil,  -- palette-only: /model list
        _in_think_palette = nil,  -- add-reasoning-level: bare /think level list

        -- 5.4: one-shot confirmation; cleared on the next keypress in handle_key
        toast = nil,

        -- 4.2/4.3: path completion state. original = token exactly as typed
        -- before the first Tab; items = candidate labels; sel = current index.
        completion = nil,

        confirmation = nil,
        confirmation_sel = 1,

        mouse_enabled = nil, -- M8/R8: last emitted tracking state
        last_transcript_top = nil, -- M9/M10: viewport invalidation for scroll repaint
        last_transcript_w = nil,   -- M10: width guard for scroll-region reuse

        history = {},
        history_pos = 0,

        -- add-steering-input: FIFO queues for mid-turn submits (max 8 each;
        -- pure push helper is M._queue_push). bang_context carries !cmd output
        -- to the next user/steering message.
        steer_queue = {},
        followup_queue = {},
        bang_context = nil,

        scroll = 0,
        user_scrolled = false,
        -- viewport pin (pi's ScrollView): rows-from-bottom alone lets fresh
        -- rows below drag a scrolled-up viewport toward the tail. Remember
        -- the last painted (total, scroll); when the offset sits still
        -- while the total drifts, the drift folds back into scroll so the
        -- same rows stay put.
        _last_total = nil,
        _last_scroll = nil,

        tokens_used = 0,
        tokens_max = 32768,
        tokens_estimated = true,
        -- pi-style-input-and-footer: session totals for the footer's ↑/↓
        -- counters (the context cell keeps using tokens_used)
        tokens_in = 0,
        tokens_out = 0,

        spinner_frame = 0,
        last_ctrl_c = nil,

        -- add-retry-and-continuation: the pending backoff wait, {attempt, delay}
        retry_wait = nil,
    }
end

-- Structural / in-place / single-entry transcript mutations live in the
-- transcript module; these are thin ui-local aliases for existing call sites.
local function bump_transcript()
    transcript.bump()
end

local function invalidate_all()
    transcript.invalidate()
end

local function touch_entry(e)
    transcript.touch(e)
end

local function reset_transcript(list)
    transcript.reset(list)
end
M._touch_entry = touch_entry
M._invalidate_all = invalidate_all

-- A: spinner frame (TW2: time-based, not paint-count-based). Canonical
-- implementation lives in ui_regions; the seams below delegate with the
-- facade's painters so tests keep the M.* names. Nil-safe like the other
-- seams: callers may run before run() created S.
local SPINNER_INTERVAL_MS = 80
local function spinner_glyph()
    return M._regions.spinner_glyph({ busy_started_at_ms = S and S.busy_started_at_ms }, painters())
end
M.spinner_glyph = spinner_glyph
M._spinner_interval_ms = SPINNER_INTERVAL_MS
-- TW2 test seam: glyph for a given elapsed-ms (pure, no S dependency)
M._spinner_glyph_at = function(ms)
    return M._regions.spinner_glyph_at(ms, painters())
end

-- A: caret marking the tail of text that is still arriving.
local function caret_glyph()
    return (M._ascii_mode or M._env_ascii or _ascii) and "|" or "▌"
end
M.caret_glyph = caret_glyph

-- ============================================================
-- Layout
-- ============================================================
local function input_lines()
    return M._regions.input_lines(S.input)
end

-- unified-slash-palette 2.1: palette window geometry lives in
-- ui_palette.window (pure); tests drive it with S-derived args.
-- (facade-proxy-removal 2.1: M._palette_window alias deleted.)

-- pi-style-input-and-footer: horizontal padding inside the box's rules: whole
-- columns, 0..3 (pi's editorPaddingX), further clamped so the content keeps at
-- least one column. Pure, so tests can call it directly.
function M.editor_padding(width, cfg_value)
    local p = cfg_value
    if type(p) ~= "number" then p = 0 end
    p = math.floor(p)
    if p < 0 then p = 0 elseif p > 3 then p = 3 end
    local maxp = math.max(0, math.floor((math.max(width or 0, 1) - 1) / 2))
    if p > maxp then p = maxp end
    return p
end

local function box_padding(width)
    return M.editor_padding(width, S.cfg and S.cfg.ui and S.cfg.ui.editor_padding_x)
end

-- ui-padding: the blank gutter left/right of every painted row. Whole columns,
-- 0..3, default 1 (nil/non-number keeps the default); clamped so the content
-- keeps at least one column. Pure, so tests can call it directly.
function M.ui_padding(width, cfg_value)
    local p = cfg_value
    if type(p) ~= "number" then p = 1 end
    p = math.floor(p)
    if p < 0 then p = 0 elseif p > 3 then p = 3 end
    local maxp = math.max(0, math.floor((math.max(width or 0, 1) - 1) / 2))
    if p > maxp then p = maxp end
    return p
end

local function ui_pad(width)
    return M.ui_padding(width, S and S.cfg and S.cfg.ui and S.cfg.ui.padding)
end

-- The width every row's content is measured against (wrap/trunc/rules/footer):
-- the terminal width minus both gutters, never below one column.
function M._content_width(width)
    return math.max(1, (width or 1) - 2 * ui_pad(width))
end

-- slim-footer-indicators: transient flags live in ui_regions.static_flags.

-- Scroll position math (count of transcript rows hidden below the
-- viewport, or nil while following). The footer "↓ +N" flag itself was
-- removed per user request; the math stays for tests and potential reuse.

local function layout()
    local total = #input_lines()
    local max_in = (S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8
    local shown_in = math.min(total, max_in)
    if shown_in < 1 then shown_in = 1 end

    local error_h = S.error_banner and 1 or 0
    local want_palette_h = 0
    -- palette-fuzzy-search: an active modal query reserves its row even with
    -- zero matches, so the "> query (no matches)" notice has a place to
    -- paint (same win+3 budget shape, win is 0). Other modes keep the
    -- collapse-when-empty behavior.
    local modal_query = (S.palette_mode == "model" or S.palette_mode == "login"
        or S.palette_mode == "logout")
        and (S.palette_query or "") ~= ""
    if S.palette_active and (#S.palette_items > 0 or modal_query) then
        -- 2.4: the reserved region follows the window; palette-hints: the
        -- indicator/query slot plus the blank+hint rows fit inside win + 3
        -- (the old win + 2 already held one slack row before the footer —
        -- it becomes the blank before the hint)
        local win = M._palette.window(S.h, #S.palette_items, S.palette_sel)
        want_palette_h = win + 3
    end

    -- slim-footer-indicators: the dock runs, top to bottom — a gap row above
    -- the box, the box's top rule, the input's rows, its bottom rule, the
    -- palette, and the footer's single row. Everything is reserved here so no
    -- region can overlap another; the error banner keeps its row above the box.
    -- While the palette region is painted a full-width separator rule runs
    -- between it and the footer (old footer-separator, restored).
    local function reserve(pal_h)
        return 2 + shown_in + pal_h + 1 + 1 + (pal_h > 0 and 1 or 0)
    end
    local function th_for(pal_h)
        local th = S.h - error_h - reserve(pal_h)
        if th < 1 then return nil end
        return th
    end

    -- The error banner sits above the dock, so the transcript gets every row
    -- left after both the banner and the dock are reserved. On a short
    -- terminal the palette is the flexible part: shrink it until the dock
    -- fits with at least one transcript row, so the footer never leaves the
    -- screen.
    local palette_h = want_palette_h
    local th = th_for(palette_h)
    while th == nil and palette_h > 0 do
        palette_h = palette_h - 1
        th = th_for(palette_h)
    end
    if th == nil then
        palette_h = 0
        th = th_for(0) or 1
    end

    local error_row = 1 + th
    local gap_row = error_row + error_h
    local rule_top_row = gap_row + 1
    local rule_bottom_row = rule_top_row + 1 + shown_in
    local separator_row = palette_h > 0 and rule_bottom_row + palette_h + 1 or nil
    local footer_row = rule_bottom_row + palette_h + (separator_row and 1 or 0) + 1

    return {
        w = S.w, h = S.h,
        transcript_row = 1,
        transcript_h = th,
        error_row = error_row,
        error_h = error_h,
        gap_row = gap_row,
        rule_top_row = rule_top_row,
        input_row = rule_top_row + 1,
        input_h = shown_in,
        input_total = total,
        rule_bottom_row = rule_bottom_row,
        palette_row = rule_bottom_row,
        palette_h = palette_h,
        separator_row = separator_row,  -- rule above the footer while the palette paints
        footer_row = footer_row,      -- the single footer row
        stats_row = footer_row,       -- same row (path/stats/model/flags combined)
        flags_row = nil,              -- no separate flag row
    }
end
-- Test seam: the region layout, so frame tests can address palette rows.
M._layout = function() return S and layout() end

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

-- Test seam: last-painted content of a screen row (F1b/5b assertions).
M._row = function(row) return S and S.screen[row] or nil end

-- Apply an ordered rowmap from ui_regions ({row, text} pairs, deterministic
-- order so captured frames stay stable). Terminal I/O stays in the facade.
local function apply_rows(rows)
    for _, r in ipairs(rows) do set_row(r[1], r[2]) end
end

-- ============================================================
-- Palette: derived from input
-- ============================================================
-- unified-slash-palette 1.2: skill rows for the palette. Discovery is injected
-- so tests can stub it (M._skills_stub, mirroring M._tools_stub); a discovery
-- problem degrades to no rows instead of breaking the palette. The skill mark
-- is part of the description ("[s] ...") so the name column stays narrow.

local function discover_palette_skills()
    local ok, res
    if M._skills_stub then
        ok, res = pcall(M._skills_stub)
    else
        ok, res = pcall(function()
            -- modules are exposed as globals by the host (main.c load_module),
            -- the same way agent/session/api are reached here; require() only
            -- works in the plain-Lua test harness
            local ctx = context
            return ctx and ctx.discover_skills(S.cfg, S.workspace)
        end)
    end
    if not ok or type(res) ~= "table" then return {} end
    return res
end

-- Command names own their token: comparison ignores case in the palette and on
-- the submit path alike, so a colliding skill gets neither a row nor a dispatch.
local function command_set()
    local set = {}
    for _, c in ipairs(SLASH_COMMANDS) do set[c.cmd:lower()] = c end
    return set
end

local function palette_skill_rows()
    local commands = command_set()
    local rows = {}
    for _, sk in ipairs(discover_palette_skills()) do
        local name = tostring(sk.name or "")
        if name ~= "" and not commands[name:lower()] then
            rows[#rows + 1] = {
                label = "/" .. name,
                desc = "[s] " .. (sk.description or ""),
                skill = true,
                name = name,
                path = sk.path or "",
            }
        end
    end
    return rows
end

-- forward declaration: palette_pick_skill closes the palette through it
local palette_sync

-- 4.1: a skill row only composes text into the input and closes the palette —
-- nothing is executed and no skill body is read (spec: Palette).
local function palette_pick_skill(it)
    S.input = (it.label or ("/" .. (it.name or ""))) .. " "
    S.cursor = #S.input
    palette_sync() -- the trailing space closes the palette
end

palette_sync = function()
    if S._in_copy_palette then return end -- 5.2: copy palette is set explicitly
    if S._in_login_palette then return end -- add-provider-login: same for picker
    if S._in_logout_palette then return end -- logout-picker: stored-credentials picker
    if S._in_resume_palette then return end -- palette-only: /resume list is explicit
    if S._in_model_palette then return end  -- palette-only: /model list is explicit
    if S._in_think_palette then return end  -- add-reasoning-level: /think picker
    local first = S.input
    local nl = first:find("\n", 1, true)
    if nl then first = first:sub(1, nl - 1) end

    local function palette_hide()
        S.palette_active = false
        S.palette_items = {}
        S.palette_sel = 1
        S.palette_skills = nil
    end

    if first:sub(1, 1) ~= "/" then palette_hide() return end
    local filter = first:sub(2):lower()
    if filter:find(" ", 1, true) then palette_hide() return end

    local was_active = S.palette_active
    S.palette_active = true
    -- 1.3: resolved once per open, not on every keystroke
    if not was_active then S.palette_skills = palette_skill_rows() end

    -- 3.2: fuzzy ranking; declaration-order tie-breaks, empty filter lists all.
    -- unified-slash-palette 1.4: one list — commands in declared order, then the
    -- discovered skills, ranked together so a prefix match wins in either group.
    local entries = {}
    for _, c in ipairs(SLASH_COMMANDS) do entries[#entries + 1] = c end
    for _, r in ipairs(S.palette_skills or {}) do entries[#entries + 1] = r end
    local labels = {}
    for _, e in ipairs(entries) do labels[#labels + 1] = e.label end
    local order = M._palette.fuzzy_rank(filter, labels)
    local items = {}
    for _, idx in ipairs(order) do
        items[#items + 1] = entries[idx]
    end
    S.palette_items = items
    if S.palette_sel < 1 then S.palette_sel = 1 end
    if S.palette_sel > #items then S.palette_sel = #items end
    if #items == 0 then S.palette_sel = 1 end
end

-- palette-fuzzy-search: filter helper for modal list palettes (model/login).
-- The full rows live in S._palette_all; labels are ranked with the same
-- M.fuzzy_rank primitive as the slash palette, S.palette_items becomes the
-- ranked visible rows, and the selection resets to the top. A module field
-- (not a file-local) so the chunk's local budget is untouched; exported as
-- a test seam like _build_model_items.
function M._palette_apply_query()
    local all = S._palette_all or {}
    local labels = {}
    for _, it in ipairs(all) do labels[#labels + 1] = it.label or "" end
    local items = {}
    for _, idx in ipairs(M._palette.fuzzy_rank(S.palette_query or "", labels)) do
        items[#items + 1] = all[idx]
    end
    S.palette_items = items
    S.palette_sel = 1
end

-- Phase C 3.2 proxies: logout flows live in ui_auth (bag/deps); these
-- keep the M.* names callers and tests drive.
-- Module fields (not file-locals) so the chunk's local budget is untouched.
function M._logout_delete(provider)
    return M._auth_flow.logout_delete(S, M._auth_deps(), provider)
end

-- logout-confirm: both steps of the picker are closed from one place, so no
-- exit path can leave the confirmation state behind.
function M._logout_close()
    return M._auth_flow.logout_close(S)
end

-- logout-confirm D1: picking a provider switches the shared palette to the
-- deletion step instead of deleting (D2/D3 notes live in ui_auth).
function M._logout_ask_confirm(provider)
    return M._auth_flow.logout_ask_confirm(S, provider)
end

-- The accepted row: close, then delete through the single writer.
function M._logout_confirm_accept()
    return M._auth_flow.logout_confirm_accept(S, M._auth_deps())
end

-- Keep row, `n` or Esc: back to the provider list as the step found it.
function M._logout_confirm_back()
    return M._auth_flow.logout_confirm_back(S, M._auth_deps())
end

-- ============================================================
-- Path completion (4.2/4.3/4.4): Tab outside the palette completes the
-- token under the cursor against the workspace, rendered in the palette
-- region. Unique candidate applies in place; several open the palette
-- with the first applied and later Tabs cycle (wrapping); Esc restores
-- the token as typed; any other key keeps the applied text.
-- ============================================================
-- Path completion engine (token/candidates/cycle/restore) lives in
-- ui_complete (bag/deps); the M.* seams below forward to it.
-- Resolves the tools module lazily: tests can override M._tools_stub to
-- stub path_complete without touching the real filesystem.
M._tools_stub = nil
-- 6.1: seam for tests to stub skill discovery (mirrors M._tools_stub).
M._skills_stub = nil
-- ============================================================
-- at-file-picker: the `@` trigger (spec tui: Path completion)
-- ============================================================
-- Typing "@" at the start of a token previews the workspace in the palette
-- without touching the input: nothing is applied until Enter, and every later
-- keystroke re-filters the snapshot the first one took. Logic lives in
-- ui_complete; these M.* names stay as the seams the key table and tests
-- drive (ui-facade-thinning 1.1).

function M._at_token_start()
    return M._complete.at_token_start(S)
end

function M._picker_close()
    return M._complete.picker_close(S)
end

function M._mention_refilter()
    return M._complete.mention_refilter(S, M._complete_deps())
end

function M._mention_open()
    return M._complete.mention_open(S, M._complete_deps())
end

function M._mention_accept()
    return M._complete.mention_accept(S, M._complete_deps())
end

-- ============================================================
-- Input model
-- ============================================================
-- Test seams: drive path_complete_tab / handle_key from a test harness
-- after run() has set up S. Placed here (after all local functions are
-- declared) so the closures capture the locals correctly.
M._path_complete_tab = function() if S then M._complete.path_complete_tab(S, M._complete_deps()) end end
local function input_insert(s)
    -- input_max_lines is the viewport window (design §7); the buffer may
    -- grow past it and the rule row scrolls with ↑/↓ labels.
    S.input = S.input:sub(1, S.cursor) .. s .. S.input:sub(S.cursor + 1)
    S.cursor = S.cursor + #s
    palette_sync()
end

-- UTF-8 helpers for the 0-based byte cursor. utf8.offset RAISES when its
-- init lands on a continuation byte (possible after move_cursor_up/down carry
-- the byte column to another line, or after a kill), so every handler either
-- uses pcall or walks bytes explicitly. A leading byte's high bits give the
-- character length directly — no offset() needed.
-- char_len_at(s, pos): length (1..4) of the character at 1-based byte pos.
-- pos is walked to the next leading byte first (skips continuation bytes).
local function char_len_at(s, pos)
    while pos <= #s do
        local b = s:byte(pos)
        if b < 0x80 then return pos, 1
        elseif b >= 0xC0 then return pos, b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        end
        pos = pos + 1 -- continuation byte: not a character start
    end
    return nil, 0
end

local function input_backspace()
    if S.cursor <= 0 then return end
    -- find the start of the character BEFORE the cursor; a mid-char cursor
    -- snaps to the start of the character containing the cursor byte.
    local ok, prev = pcall(utf8.offset, S.input, -1, S.cursor + 1)
    if not ok or not prev then
        -- walk back over continuation bytes to the character's first byte
        local pos = S.cursor
        while pos > 0 and S.input:byte(pos) and S.input:byte(pos) >= 0x80
            and S.input:byte(pos) < 0xC0 do
            pos = pos - 1
        end
        prev = pos
    end
    S.input = S.input:sub(1, prev - 1) .. S.input:sub(S.cursor + 1)
    S.cursor = prev - 1
    palette_sync()
end

local function input_delete()
    if S.cursor >= #S.input then return end
    -- remove the WHOLE character after the caret. The old code used
    -- utf8.offset(s, 1, cursor + 1) as the removal end — but that is the
    -- START of the character at cursor+1, i.e. cursor+1 itself, so the
    -- removed range was empty and Delete was a hard no-op for every input.
    local start, len = char_len_at(S.input, S.cursor + 1)
    if not start then return end
    S.input = S.input:sub(1, S.cursor) .. S.input:sub(start + len)
    palette_sync()
end

local function input_clear()
    S.input = ""
    S.cursor = 0
    -- 6.1: palette modes set explicitly (copy/skills/login) survive input_clear;
    -- palette_sync is a no-op for them via the _in_*_palette flags.
    if not S._in_copy_palette and not S._in_login_palette
        and not S._in_logout_palette
        and not S._in_resume_palette and not S._in_model_palette
        and not S._in_think_palette then
        palette_sync()
    end
end

local function cursor_line_col()
    return M._regions.cursor_line_col(S.input, S.cursor)
end

local function set_cursor(li, col)
    local lines = input_lines()
    if li < 1 then li = 1 end
    if li > #lines then li = #lines end
    local ln = lines[li]
    if col < 0 then col = 0 end
    if col > #ln.text then col = #ln.text end
    -- snap to a character boundary: a byte column carried from another line
    -- (Up/Down keep the column) can land inside a multi-byte char, and every
    -- later cursor op raises on a continuation-byte position.
    local pos = col
    while pos > 0 and ln.text:byte(pos + 1)
        and ln.text:byte(pos + 1) >= 0x80 and ln.text:byte(pos + 1) < 0xC0 do
        pos = pos - 1
    end
    S.cursor = ln.from + pos
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
-- TH1 test seam: tests redirect the history file (env HOME is not
-- rebindable from Lua); production reads the default path.
M._history_file = nil
M._load_history = nil

-- provider_common supplies the shared JSON decoder (same discipline as
-- session.lua); loadfile keeps plain-Lua test runs working.
M._provider_common = _G.provider_common
if type(M._provider_common) ~= "table" then
    local chunk = loadfile("src/tether/providers/common.lua")
    M._provider_common = (chunk and chunk()) or nil
end

local function history_file()
    return M._history_file
        or (os.getenv("HOME") or "") .. "/.tether/history.jsonl"
end

local function load_history()
    local pc = M._provider_common
    if not (pc and pc.json_decode) then return end
    local f = io.open(history_file(), "r")
    if not f then return end
    local seen_last = nil
    for line in f:lines() do
        -- TH1 regression: the previous regex extraction ("text":"(.*)") was a
        -- greedy match to the LAST quote. session.add_history's json_encode
        -- emits fields in arbitrary pairs() order, so with `text` not last the
        -- recall inserted the raw JSON tail instead of the message. Decode the
        -- line as JSON and read typed fields.
        local obj = pc.json_decode(line)
        if type(obj) == "table" and type(obj.text) == "string" and obj.text ~= "" then
            local text = obj.text
            local wsp = obj.workspace
            -- N4: filter by workspace FIRST, then dedupe consecutive entries —
            -- deduping before the filter merged duplicates across workspaces.
            if not wsp or wsp == S.workspace then
                if text ~= seen_last then
                    seen_last = text
                    S.history[#S.history + 1] = text
                end
            end
        end
    end
    f:close()
    -- keep last 200 for this workspace
    while #S.history > 200 do table.remove(S.history, 1) end
end
M._load_history = load_history

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

-- ============================================================
-- pretty-transcript-rendering: sanitization, highlighting, diffs
-- ============================================================
-- The diff engine is a global in the built binary; the loadfile fallback keeps
-- plain-lua development and `lua tests/lua_tests.lua` working.
local diff_mod = _G.diff
    or (function()
        local chunk = loadfile("src/tether/diff.lua")
        return chunk and chunk()
    end)()

-- add-ask-tool: the question block's constants and answer payload rules are a
-- global in the built binary; the loadfile fallback keeps plain-lua runs and
-- `lua tests/lua_tests.lua` working.
local ask = _G.ask
    or (function()
        local chunk = loadfile("src/tether/ask.lua")
        return chunk and chunk()
    end)()

-- 3.2: drop every control sequence except SGR colour. Cursor moves, erase
-- sequences, carriage returns and OSC/DCS escapes must never reach a
-- transcript row; blank-line runs collapse. This is display-only: the stored
-- body and the model's copy stay raw. SGR survives only while colour is on.
local function sanitize_output(text)
    if type(text) ~= "string" then return text end
    local keep_sgr = M.color_depth() ~= "none"
    local out = {}
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == "\27" then
            local nx = text:sub(i + 1, i + 1)
            if nx == "[" then
                local j = i + 2
                while j <= n do
                    local b = text:byte(j)
                    if b and b >= 0x30 and b <= 0x3F then j = j + 1 else break end
                end
                while j <= n do
                    local b = text:byte(j)
                    if b and b >= 0x20 and b <= 0x2F then j = j + 1 else break end
                end
                local final = text:sub(j, j)
                if final == "m" and keep_sgr then out[#out + 1] = text:sub(i, j) end
                i = j + 1
            elseif nx == "]" then
                local j = i + 2
                while j <= n do
                    local bj = text:sub(j, j)
                    if bj == "\7" then j = j + 1; break end
                    if bj == "\27" and text:sub(j + 1, j + 1) == "\\" then j = j + 2; break end
                    j = j + 1
                end
                i = j
            elseif nx == "P" or nx == "X" or nx == "^" or nx == "_" then
                local j = i + 2
                while j <= n do
                    if text:sub(j, j) == "\27" and text:sub(j + 1, j + 1) == "\\" then j = j + 2; break end
                    j = j + 1
                end
                i = j
            else
                i = i + 2
            end
        elseif c == "\r" then
            if text:sub(i + 1, i + 1) == "\n" then out[#out + 1] = "\n"; i = i + 2 else i = i + 1 end
        elseif c == "\n" or c == "\t" then
            out[#out + 1] = c; i = i + 1
        else
            local b = text:byte(i)
            if b and (b < 32 or b == 127) then i = i + 1 else out[#out + 1] = c; i = i + 1 end
        end
    end
    local s = table.concat(out)
    s = s:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
    return s
end
M.sanitize_output = sanitize_output

-- 4.1: extension -> highlighter language (keys live in ui_highlight.langs).
local EXT_LANG = {
    lua = "lua", c = "c", h = "c", sh = "sh", bash = "sh", py = "python",
    js = "js", ts = "ts", go = "go", rs = "rust", json = "json",
}
local function lang_for_path(p)
    if type(p) ~= "string" then return nil end
    local ext = p:match("%.([%w_]+)$")
    return ext and EXT_LANG[ext:lower()] or nil
end
M.lang_for_path = lang_for_path

-- Clip a plain (SGR-free or SGR-aware) string to a display-width budget.
local function clip(s, budget)
    if budget < 1 then return "" end
    if vlen(s) <= budget then return s end
    return trunc(s, budget)
end

-- 3.3/4.5: effective expansion for a tool entry: an explicit per-entry state
-- overrides the inherited all-entries flag, which defaults to collapsed.
local function entry_expanded(e)
    if e.expand_state == "expanded" then return true end
    if e.expand_state == "collapsed" then return false end
    return S and S.expand_all or false
end

local function body_line_iter(body)
    return (body .. "\n"):gmatch("([^\n]*)\n")
end

-- 4.2: one tokenizer state spans the body; syntax roles win over the
-- add/remove/context base role, plain tokens take the base role.
local function highlight_diff_line(text, lang, state, base_fn)
    if not lang then return base_fn(text) end
    local toks = M._highlight.tokenize(text, lang, state)
    local out = {}
    for _, t in ipairs(toks) do
        local role = M._highlight.roles[t.kind]
        if role then out[#out + 1] = sgr_role(role, t.text)
        else out[#out + 1] = base_fn(t.text) end
    end
    return table.concat(out)
end

-- 4.3: changed words keep the add/remove role, carried words are muted.
local function emphasize(segs, role_fn)
    local out = {}
    for _, s in ipairs(segs) do
        if s.changed then out[#out + 1] = role_fn(s.text)
        else out[#out + 1] = dim(s.text) end
    end
    return table.concat(out)
end

local function diff_gutter(old, new)
    return string.format("%4s %4s ", old and tostring(old) or "", new and tostring(new) or "")
end

local function diff_row_string(row, lang, state, emph)
    local kind = row.kind
    if kind == "file-header" or kind == "hunk-header" or kind == "no-newline" then
        return dim(row.text or "")
    end
    local role_fn = function(s) return s end
    if kind == "remove" then role_fn = red
    elseif kind == "add" then role_fn = green end
    local marker = (kind == "add" and "+") or (kind == "remove" and "-") or " "
    local g
    if kind == "context" then g = diff_gutter(row.old, row.new)
    elseif kind == "add" then g = diff_gutter(nil, row.new)
    else g = diff_gutter(row.old, nil) end
    local content
    if emph then content = emphasize(emph, role_fn)
    else content = highlight_diff_line(row.text or "", lang, state, role_fn) end
    return g .. marker .. content
end

-- Render a parsed diff: line-number gutter, add/remove/context roles, syntax
-- colouring by the target path and word emphasis on paired runs.
local function render_diff_rows(rows, path, inner)
    local lang = lang_for_path(path)
    local state = {}
    local out = {}
    local i = 1
    while i <= #rows do
        local r = rows[i]
        if r.kind == "remove" then
            local r0 = i
            while i <= #rows and rows[i].kind == "remove" do i = i + 1 end
            local a0 = i
            while i <= #rows and rows[i].kind == "add" do i = i + 1 end
            local rem, add = {}, {}
            for k = r0, a0 - 1 do rem[#rem + 1] = rows[k] end
            for k = a0, i - 1 do add[#add + 1] = rows[k] end
            local emph_old, emph_new = {}, {}
            local paired = #rem > 0 and #rem == #add
            if paired and diff_mod then
                for k = 1, #rem do
                    emph_old[k], emph_new[k] = diff_mod.pair_words(rem[k], add[k])
                end
            end
            for k = 1, #rem do
                out[#out + 1] = diff_row_string(rem[k], lang, state, paired and emph_old[k] or nil)
            end
            for k = 1, #add do
                out[#out + 1] = diff_row_string(add[k], lang, state, paired and emph_new[k] or nil)
            end
        elseif r.kind == "add" then
            out[#out + 1] = diff_row_string(r, lang, state, nil)
            i = i + 1
        else
            out[#out + 1] = diff_row_string(r, lang, state, nil)
            i = i + 1
        end
    end
    return out
end

-- Expanded tool body -> wrapped rows (no leading indent; the caller adds it).
local function render_tool_body(name, e, inner)
    local body = sanitize_output(e.body or "")
    if body == "" then return {} end
    local hl = highlight_enabled()
    if name == "write" or name == "patch" then
        local rows = diff_mod and diff_mod.parse(body)
        if rows then return render_diff_rows(rows, hl and e.path or nil, inner) end
        return wrap(body, math.max(inner, 1))
    end
    if name == "read" then
        local lang = hl and lang_for_path(e.path) or nil
        if lang then
            local state = {}
            local coloured = {}
            for line in body_line_iter(body) do
                local num, content = line:match("^(%d+)\t(.*)$")
                if num then
                    coloured[#coloured + 1] = num .. "\t" .. M._highlight.highlight(content, lang, state, sgr_role)
                else
                    coloured[#coloured + 1] = line
                end
            end
            return wrap(table.concat(coloured, "\n"), math.max(inner, 1))
        end
    elseif name == "grep" then
        local state_by = {}
        local coloured = {}
        for line in body_line_iter(body) do
            local p = line:match("^(.-):%d+: (.*)$")
            local l = (hl and p) and lang_for_path(p) or nil
            if l then
                state_by[l] = state_by[l] or {}
                coloured[#coloured + 1] = line:gsub("^(.-:%d+: )(.*)$", function(pfx, c)
                    return pfx .. M._highlight.highlight(c, l, state_by[l], sgr_role)
                end)
            else
                coloured[#coloured + 1] = line
            end
        end
        return wrap(table.concat(coloured, "\n"), math.max(inner, 1))
    end
    return wrap(body, math.max(inner, 1))
end

-- splash-colors: startup splash (ported from the Go TUI's splashBlock).
-- Pure data in (version/agents/skills), rows out — no S access, so unit
-- tests drive it directly. Wordmark in the accent role (no bold, per the
-- accent contract), version muted, section headers accent, values muted.
-- Sections with empty lists do not render. No hints, no footer content.
-- Wordmark glyphs live in ui_copy (safe-edit zone).
M.SPLASH_WORDMARK = M._copy.splash.wordmark

function M._tilde_path(p, home)
    home = home or os.getenv("HOME") or ""
    p = tostring(p or "")
    if home ~= "" then
        if p == home then return "~" end
        if p:sub(1, #home + 1) == home .. "/" then
            return "~" .. p:sub(#home + 1)
        end
    end
    return p
end

-- ui-padding: one blank row above the block when the gutter is on (the old
-- Go splash opened with a blank line). nil pad = 0 keeps the block flush for
-- the pure-content tests.
function M._splash_rows(res, width, pad)
    res = res or {}
    width = math.max(width or 80, 1)
    local rows = {}
    if pad and pad > 0 then rows[#rows + 1] = "" end
    local narrow = false
    for _, ln in ipairs(M.SPLASH_WORDMARK) do
        if vlen(ln) > width then narrow = true break end
    end
    if narrow then
        rows[#rows + 1] = cyan(M._copy.splash.narrow_title)
    else
        for _, ln in ipairs(M.SPLASH_WORDMARK) do
            rows[#rows + 1] = cyan(ln)
        end
    end
    local ver = tostring(res.version or ""):match("^%s*(.-)%s*$")
    if ver ~= "" then
        rows[#rows + 1] = ""
        if vlen(ver) <= width then rows[#rows + 1] = muted(" " .. ver)
        else rows[#rows + 1] = muted(" v") end
    end
    local function section(header, items)
        if not items or #items == 0 then return end
        rows[#rows + 1] = ""
        rows[#rows + 1] = cyan(" " .. header)
        -- wrap, never clip: trunc() appends a reset escape even to plain
        -- text, which would leak SGR into mono/ascii rows and break the
        -- byte-width asserts with its multibyte ellipsis.
        local inner = math.max(width - 2, 1)
        for _, l in ipairs(wrap(table.concat(items, ", "), inner)) do
            rows[#rows + 1] = dim("  " .. l)
        end
    end
    section(M._copy.splash.context_header, res.agents)
    section(M._copy.splash.skills_header, res.skills)
    return rows
end

-- Startup resources backing the splash: AGENTS.md candidates (home, then
-- the repo-root→workspace ancestor chain via _agents_chain, then explicit
-- cfg lists — mirroring context.lua discovery and the old projectctx.Load,
-- non-empty files only, tildified) plus user skill names via the context
-- module (embedded global in the host, loadfile fallback in tests).
-- Reads S; stored once at startup and reused by /clear and /new.
function M._collect_splash_resources()
    local st = M._get_state()
    local cfg = (st and st.cfg) or {}
    local ws = (st and st.workspace) or ""
    local agents, seen = {}, {}
    local function add_agent(p)
        if type(p) ~= "string" or p == "" or seen[p] then return end
        local f = io.open(p, "r")
        if f then
            local data = f:read("*a")
            f:close()
            if data and data ~= "" then
                seen[p] = true
                agents[#agents + 1] = M._tilde_path(p)
            end
        end
    end
    local home = os.getenv("HOME") or ""
    if home ~= "" then add_agent(home .. "/.tether/AGENTS.md") end
    if home ~= "" then add_agent(home .. "/.agents/AGENTS.md") end
    for _, dir in ipairs(M._agents_chain(ws)) do
        add_agent(dir .. "/AGENTS.md")
    end
    for _, p in ipairs(cfg.agents_files or {}) do add_agent(p) end
    for _, p in ipairs(cfg._cli_agents_files or {}) do add_agent(p) end
    local skills = {}
    local ctxmod = rawget(_G, "context")
    if type(ctxmod) ~= "table" then
        local chunk = loadfile("src/tether/context.lua")
        ctxmod = (chunk and chunk()) or nil
    end
    if type(ctxmod) == "table" and type(ctxmod.discover_skills) == "function" then
        local ok, list = pcall(ctxmod.discover_skills, cfg, ws)
        if ok and type(list) == "table" then
            local seen_sk = {}
            for _, sk in ipairs(list) do
                local nm = (type(sk) == "table" and sk.name) or tostring(sk)
                if nm and nm ~= "" and not seen_sk[nm] then
                    seen_sk[nm] = true
                    skills[#skills + 1] = nm
                end
            end
        end
    end
    return { agents = agents, skills = skills }
end

-- splash-colors: AGENTS.md ancestor chain, mirroring the old Go
-- projectctx.Load: ~/.tether/AGENTS.md first, then AGENTS.md from the repo
-- root down to ws (outermost first). The walk stops after the first
-- ancestor containing .git, or at ws when there is no repository.
-- Pure path math apart from the .git probes, so tests drive it with temp
-- dirs. (M-field: ui.lua sits at Lua's 200-locals limit.)
function M._agents_chain(ws)
    local out = {}
    if type(ws) ~= "string" or ws == "" then return out end
    local chain = {}
    local dir = ws
    local top = nil -- chain index of the repo root (nearest .git upward)
    while dir and dir ~= "" do
        chain[#chain + 1] = dir
        local probe = io.open(dir .. "/.git", "r")
        if probe then probe:close() top = #chain break end
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == dir then break end
        dir = parent
    end
    -- no repository above ws: only ws itself, like projectctx.Load
    if not top then return { ws } end
    for i = top, 1, -1 do out[#out + 1] = chain[i] end
    return out
end

-- Fresh splash entry from S (version + stored resources). M-field (not a
-- chunk local: ui.lua sits at Lua's 200-locals limit for the main chunk).
function M._splash_entry()
    local st = M._get_state()
    local res = (st and st.splash_resources) or { agents = {}, skills = {} }
    return { role = "splash", version = (st and st.version) or "v0.1.0",
        agents = res.agents or {}, skills = res.skills or {} }
end

-- add-ask-tool: is `label` among this question's selected answers?
-- Canonical implementation lives in ui_ask_view (module-local).

-- palette-hints D1: the shared segmented hint painter lives in ui_themes
-- (pure over the painter table); these M.* names stay as the seams tests
-- and goldens drive.
function M.hint_plain(pairs)
    return M._themes.hint_plain(pairs)
end

function M.hint_paint(pairs, inner)
    return M._themes.hint_paint(M._painters, pairs, inner)
end

-- ask-block-b: the hint row's pairs for the current phase and mode. Short
-- verbs only — the row is clipped to the width (never wrapped), so the full
-- ASK_KEYS phrases would not fit. Every key named here exists in ASK_KEYS
-- (asserted by T228), so the painted hints cannot drift from the handled
-- keys: list modes name navigation + commit + cancel, the confirm phase
-- names submit/dismiss, editors name save/discard instead.
-- (M-field, not chunk local: ui.lua sits at Lua's 200-locals limit.)
-- ask-view hint pairs + tab strip: canonical implementations live in
-- ui_ask_view (ask_hint/render_tabs); the question-block renderer moved
-- there as render(). Keyboard ownership and S.ask mutation stay here.

-- The question block's rows: canonical implementation lives in
-- ui_ask_view.render (ask state in, rows out). Rendered from S.ask via the
-- render_entry call site so the highlight and the rows can never disagree
-- about what is selectable.

-- The call's primary argument for the tool row head: which file ran what.
-- Pure data in (parsed args, fallback path) so tests drive it directly.
-- (M-field, not chunk local: ui.lua sits at Lua's 200-locals limit.)
function M._tool_arg_label(name, args, path)
    args = (type(args) == "table" and args) or {}
    if name == "read" or name == "write" then
        return args.path or path
    elseif name == "list" then
        return args.path or path or "."
    elseif name == "glob" then
        local pat = args.pattern or ""
        if args.path and args.path ~= "" then pat = pat .. " in " .. args.path end
        return pat ~= "" and pat or nil
    elseif name == "grep" then
        local pat = args.pattern or ""
        if args.path and args.path ~= "" then pat = pat .. " in " .. args.path end
        return pat ~= "" and pat or nil
    elseif name == "run" then
        return args.command
    elseif name == "patch" then
        local p = args.patch or args.content or ""
        if type(p) == "string" then
            return p:match("%+%+%+ b/([^\n]+)") or p:match("%+%+%+ ([^%s]+)")
        end
    elseif name == "subagent" then
        local t = args.task or ""
        if t == "" and type(args.tasks) == "table" and args.tasks[1] then
            t = args.tasks[1].task or ""
        end
        if type(t) == "string" and t ~= "" then return t end
    end
    return path
end

local function render_entry(e, width, prev_role)
    -- Synthetic tail entries go through the same path as real entries so the
    -- height index, the scroll indicator and the parity helper stay consistent.
    -- `prev_role` is the role of the preceding entry (or nil) — used to decide
    -- the leading block gap (see transcript-visual-refresh).
    local out
    if e.virt == "ask" then
        out = M._ask_view.render(S.ask, width, painters())    elseif e.virt == "placeholder" then
        -- turn-feedback-restyling: no waiting row in the transcript (the
        -- input box carries the Working indicator); kept as a no-op for any
        -- stale tail reference.
        out = {}
    elseif e.virt == "confirm" then
        -- Phase D 4.2: menu rows live in ui_confirm (rows-out); painters in.
        -- Values come from the ui_themes-built table (2.1); confirm_hint
        -- stays facade-owned.
        local P = painters()
        out = M._confirm.menu_rows(S.confirmation, S.confirmation_sel, width, {
            yellow = P.yellow, rev = P.rev, wrap = P.wrap,
            hint = P.hint,
            confirm_hint = M.CONFIRM_HINT,
        })
    else
        local role = e.role or "system"
        if role == "splash" then
            -- splash-colors: startup splash block (wordmark, version,
            -- Context/Skills sections); rows from the entry's own data.
            out = M._splash_rows({ version = e.version,
                agents = e.agents, skills = e.skills }, width, ui_pad(width))
        elseif role == "separator" then
            -- tui: Turn separators — muted rule with the local submission time
            local label = "── " .. (e.text or "") .. " "
            local fill = width - vlen(label)
            if fill < 1 then fill = 1 end
            out = { muted(label .. string.rep("─", fill)) }
        elseif role == "user" then
            -- the user's own text is markdown-lite: inline code/bold/italic and
            -- fenced blocks render, block markers (#, -, 1., |) stay literal so
            -- the echo matches what was typed.
            out = with_prefix(cyan("›") .. " ", 2,
                md_render(e.text or "", math.max(width - 2, 1), M.md_ansi, true))
        elseif role == "assistant" then
            -- M8/R4: markdown-lite render; md_render handles wrap/width itself
            local body = md_render(e.text or "", math.max(width - 2, 1), M.md_ansi)
            -- No visible content → no row and no block gap: a whitespace- or
            -- control-only text_delta (a lone newline/space right before a
            -- tool call) must not paint a bare marker line — with_prefix
            -- falls back to the prefix alone for an empty body, which is
            -- exactly the stray `•` row this guards against.
            local plain = table.concat(body):gsub("\27%[[0-9;]*m", "")
            if not plain:find("%S") then return {} end
            -- assistant marker: • (ASCII `-`) — was `·`/spec's `●`; user choice
            local marker = M.ascii_active(S.cfg and S.cfg.ui and S.cfg.ui.ascii)
                and "- " or "• "
            out = with_prefix(marker, 2, body)
        elseif role == "thinking" then
            -- the marker color tracks liveness: yellow while reasoning may
            -- still append to this entry, dim once the model moved on (the
            -- answer, a tool call, or the turn ending froze it — see
            -- transcript.handle). A frozen row is finished business, not a
            -- success, so it takes the label's tone instead of green.
            local mark = e.live and yellow("•") or dim("•")
            local secs = os.time() - (e.started_at or os.time())
            if secs < 0 then secs = 0 end
            if not S.thinking_visible then
                out = { mark .. " " .. dim("think · ") .. muted(string.format("%.1fs", secs))
                    .. dim(" · (ctrl+t) ▸") }
            else
                local to = { mark .. " " .. dim(italic("think · "))
                    .. muted(italic(string.format("%.1fs", secs))) .. dim(italic(" ▾")) }
                -- header only while no reasoning text has arrived: wrap("")
                -- yields one empty line and would paint a stray blank row
                -- under the header
                if (e.text or ""):find("%S") then
                    for _, l in ipairs(wrap(e.text, math.max(width - 2, 1))) do
                        to[#to + 1] = "  " .. dim(l)
                    end
                end
                out = to
            end
        elseif role == "system" then
            -- wrapped, not dumped raw: the llm compaction summary is
            -- multi-paragraph text, and one unwrapped row both writes past
            -- the terminal width and shifts the screen at its newlines
            out = {}
            for _, l in ipairs(wrap(e.text or "", math.max(width, 1))) do
                out[#out + 1] = dim(l)
            end
        elseif role == "tool" then
            -- 3.1: leading status marker; a failed row appends its first error line
            -- (clipped) so the failure is visible without expanding.
            local marker
            if e.status == "pending" then marker = yellow("•")
            elseif e.status == "error" then marker = red("✗")
            else marker = green("✓") end
            local head = marker .. " " .. sgr_role("accent", e.name or "?")
            -- The trailing status the head ends with is reserved BEFORE the
            -- label is clipped. Appending it after a full-width label pushes
            -- the row past the terminal: the terminal autowraps the remainder
            -- onto the next screen row and the line-diff cache, which knows
            -- only logical rows, never repaints that spill (a ghost above the
            -- input that survives scrolling).
            local tail = ""
            if e.status == "pending" then
                -- M8/R3: pending tools show live elapsed time
                if e.started_at then
                    local secs = os.time() - e.started_at
                    tail = "  " .. muted(string.format("%.1fs", secs))
                end
            elseif e.status ~= "error" and e.summary and e.summary ~= "" then
                tail = "  " .. muted(e.summary)
            end
            -- the call's primary argument (which file ran what): without it
            -- `✓ read` / `✓ run` say nothing about what actually happened.
            do
                local label = M._tool_arg_label(e.name, e.args, e.path)
                if label and label ~= "" then
                    label = sanitize_output(label:match("^[^\n]*") or "")
                    local budget = width - vlen(head) - 1 - vlen(tail)
                    if budget >= 4 then head = head .. " " .. dim(clip(label, budget)) end
                end
            end
            if e.status == "pending" then
                head = head .. tail
                -- bg subagent tick: newest progress line rides the head row
                -- (no expansion needed); the full tail stays display-only.
                if e.progress and e.progress ~= "" then
                    local last = sanitize_output(e.progress:match("[^\n]*$") or "")
                    local budget = width - vlen(head) - 1
                    if budget >= 4 and last ~= "" then
                        head = head .. "  " .. dim(clip(last, budget))
                    end
                end
            elseif e.status == "error" then
                local raw = (e.body ~= nil and e.body ~= "") and e.body or (e.summary or "")
                raw = sanitize_output(raw):gsub("^✗%s*", "")
                local first = raw:match("^[^\n]*") or ""
                local budget = width - vlen(head) - 1
                if budget >= 1 then head = head .. " " .. red(clip(first, budget)) end
            else
                head = head .. tail
            end
            -- 4.4: the write/patch row carries the +N -M meter.
            if e.status ~= "error" and (e.name == "write" or e.name == "patch") and diff_mod then
                local add, del
                if e.projection then
                    add, del = e.projection.add, e.projection.del
                else
                    local a, d = (e.summary or ""):match("^%+(%d+) −(%d+)")
                    add, del = tonumber(a), tonumber(d)
                end
                if add then
                    local ab, db = diff_mod.meter(add, del or 0)
                    if ab > 0 then head = head .. " " .. green(string.rep("━", ab)) end
                    if db > 0 then head = head .. red(string.rep("━", db)) end
                end
            end
            head = trunc(head, width)
            local to = { head }
            -- 3.3: the full body (including a failed call's error text and a
            -- pending write/patch projection) is behind expansion.
            if e.body and e.body ~= "" and entry_expanded(e) then
                local bl = render_tool_body(e.name, e, math.max(width - 2, 1))
                local cap = e.collapse_lines
                    or M.tool_collapse_cap(e.name, S.cfg and S.cfg.ui and S.cfg.ui.collapse, 200)
                for i, l in ipairs(bl) do
                    if i > cap then
                        to[#to + 1] = "  " .. dim("… (" .. (#bl - i + 1) .. " lines hidden)")
                        break
                    end
                    to[#to + 1] = "  " .. l
                end
            end
            out = to
        else
            out = {}
        end
    end

    -- Block gap: a blank row before top-level entities (separator, user,
    -- assistant, system, thinking) and after a separator (every
    -- `── status ────` marker — turn timestamps, the summary divider —
    -- stands as a block of its own) — but not before the first entity, and
    -- not before virtual tails (they emit their own leading blank). Empty
    -- entries get no gap.
    -- Tool/subagent rows form a GROUP: the first tool after a narrative
    -- block (user/assistant/think/system) opens the group with a gap, tools
    -- inside the group glue together (and to a preceding tool), so a
    -- tool-trail reads as one unit attached to the block it follows.
    local gap_roles = { separator = true, user = true, assistant = true,
        system = true, thinking = true, splash = true }
    local role = e.role or "system"
    local is_virt = e.virt == "ask" or e.virt == "placeholder" or e.virt == "confirm"
    local need_gap = false
    if not is_virt and prev_role ~= nil then
        if role == "tool" then
            need_gap = prev_role ~= "tool"
        else
            need_gap = gap_roles[role] or prev_role == "tool"
        end
    end
    if need_gap and #out > 0 then
        local gap = (S and S.cfg and S.cfg.ui and S.cfg.ui.block_gap)
        if gap == nil then gap = 1 end
        if gap and gap > 0 then
            local merged = {}
            for _ = 1, gap do merged[#merged + 1] = "" end
            for _, r in ipairs(out) do merged[#merged + 1] = r end
            out = merged
        end
    end
    return out
end

-- Wire render_entry + viewport cache bound into the transcript module. Must
-- run after render_entry exists (above) and before any height query.
transcript.configure({
    render = render_entry,
    cut = function(s, n)
        local pc = M._provider_common
        if pc and pc.utf8_prefix then return pc.utf8_prefix(s, n) end
        return s:sub(1, n)
    end,
    cache_bound = function()
        local vh = S and S.last_transcript_h
        if not vh or vh < 1 then vh = (S and S.h or 24) - 6 end
        if vh < 1 then vh = 1 end
        return math.max(4 * vh, 1024)
    end,
})

-- Thin delegates into transcript (kept as ui locals so existing call sites
-- and test seams — M._sync_tail, M.transcript_height, … — stay stable).
local function visible_count()
    return transcript.visible_count()
end

local function entry_at(i)
    return transcript.entry_at(i)
end

-- Called whenever S.confirmation or S.waiting changes: keeps the synthetic
-- tail entries in sync (owned by transcript).
local function sync_tail()
    transcript.sync_tail(S and S.confirmation, S and S.ask)
end
M._sync_tail = sync_tail

local function ensure_index(width)
    return transcript.ensure_index(width)
end

local function entry_of_row(k, width)
    return transcript.entry_of_row(k, width)
end

local function row_text(k, width)
    return transcript.row_text(k, width)
end

function M.transcript_height(width)
    if not S then return 0 end
    return transcript.height(width or S.w)
end
M.cache_rows = function() return transcript.cache_rows() end

-- Parity seam: the same rows the viewport path produces, but for the whole
-- transcript. Tests compare the two to prove virtualization changes nothing.
function M._render_all(width)
    if not S then return {} end
    return transcript.render_all(width or S.w)
end

-- ============================================================
-- Region renderers
-- ============================================================
-- M8/R3: scroll indicator math. Returns nil when following (bottom-anchored),
-- else the count of lines hidden below the visible window.
-- Scroll math + DECSTBM sequences: canonical implementations live in
-- ui_regions (identical signatures); aliases keep the M.* seams tests drive.
M.scroll_indicator = M._regions.scroll_indicator

-- M10: hardware scroll-region shift, adapted from terminal.lua's
-- terminal.scroll approach (see ui_regions header for the contract).
M.scroll_shift_seq = M._regions.scroll_shift_seq

-- Phase A 1.1: viewport render lives in transcript.render_viewport
-- (slice in, ordered rowmap out); this facade builds the slice, applies
-- S.scroll/last_* bookkeeping + terminal I/O, and paints the rowmap.
local function render_transcript(L)
    local cw = M._content_width(L.w)
    local slice = {
        content_width = cw,
        gutter = string.rep(" ", ui_pad(L.w)),
        scroll = S.scroll,
        user_scrolled = S.user_scrolled,
        _last_total = S._last_total,
        _last_scroll = S._last_scroll,
        last_transcript_top = S.last_transcript_top,
        last_transcript_w = S.last_transcript_w,
        streaming = S.streaming,
        palette_active = S.palette_active,
        confirmation = S.confirmation,
        ask = S.ask,
        login_secret = S.login_secret,
        alt_screen = S.cfg and S.cfg.ui and S.cfg.ui.alt_screen,
    }
    local res = transcript.render_viewport(slice, L, {
        trunc = trunc,
        caret = caret_glyph,
        scroll_shift_seq = M.scroll_shift_seq,
    })
    S.last_transcript_h = res.last_transcript_h -- cache bound follows the viewport
    S.scroll = res.scroll
    -- baseline AFTER the clamp: the pin compares against what is actually
    -- painted, never a pre-clamp value.
    S._last_total, S._last_scroll = res.last_total, res.last_scroll
    -- M9: scrolling shifts every visible row; the row diff must not compare
    -- against rows painted for the PREVIOUS viewport — invalidate the
    -- window when the scroll offset changes.
    if res.top_changed then
        if res.shift_seq then
            frame_put(res.shift_seq)
            -- the shift physically moved row contents: forget every
            -- cached row inside the region so the diff repaints the
            -- freshly exposed lines (and only them)
            for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
                S.screen[r] = nil
            end
        end
        for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
            S.screen[r] = nil
        end
        S.last_transcript_top = res.last_top
        S.last_transcript_w = res.last_w
    end
    apply_rows(res.rows)
end

local function render_error_banner(L)
    apply_rows(M._regions.render_error_banner(M._dock_slice(L), L, painters()))
end

-- pi-style-input-and-footer: caret visibility (ASCII/mono themes) lives in
-- M._painters.caret_reverse for ui_regions; column slicing below moved there.

local function render_input(L)
    apply_rows(M._regions.render_input(M._dock_slice(L), L, painters()))
end

-- Phase A 1.2: palette region painting lives in ui_palette.render
-- (slice in, ordered rowmap out); this facade builds the slice, applies it.
local function render_palette(L)
    if not S.palette_active then return end
    local cw = M._content_width(L.w)
    local rows = M._palette.render({
        active = S.palette_active,
        items = S.palette_items,
        sel = S.palette_sel,
        mode = S.palette_mode,
        query = S.palette_query,
        truncated = S.completion and S.completion.truncated,
        hints = M.PALETTE_HINTS,
        copy = M._copy.palette,
        content_width = cw,
        gutter = string.rep(" ", ui_pad(L.w)),
    }, L, {
        trunc = trunc,
        vlen = vlen,
        dim = dim,
        accent = function(t) return sgr_role("accent", t) end,
        rule = function(w) return M._regions.rule_row(w, nil, nil, painters()) end,
        hint = function(pairs, w) return M.hint_paint(pairs, w) end,
    })
    apply_rows(rows)
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

-- §6.6: SPINNER / SPINNER_ASCII live in the Constants section — the
-- transcript tail and the status line both read them.

-- M9: token usage as plain text; colors kept: green <summarize_at, yellow
-- >=summarize_at (default 70%%), red >=90%%. Clamped to 0..100.
-- T47: user-requested format "4.1k/32k (13%)" — used/budget/percent.
-- Token cells + footer composition: canonical implementations live in
-- ui_regions; theme-bound entry points stay here (painters live in ui
-- until the themes cut) so tests and callers keep the M.* names.
function M.token_pct(pct, summarize_at)
    return M._regions.token_pct(pct, summarize_at, M._painters)
end

-- T47: "4.1k/32k (13%)" — see ui_regions.token_usage.
function M.token_usage(used, max_tokens, summarize_at)
    return M._regions.token_usage(used, max_tokens, summarize_at, M._painters)
end

-- pi-style-input-and-footer: compact token counts for the footer, mirrored
-- from pi's footer formatter (see ui_regions.format_count).
function M.format_count(n)
    return M._regions.format_count(n)
end

-- The tail of `s`, at most `maxw` display columns: canonical implementation
-- lives in ui_regions (footer_stats calls it via the module).

-- The footer row composition (see ui_regions.footer_stats).
function M.footer_stats(left, right, width)
    return M._regions.footer_stats(left, right, width, M._painters)
end

-- slim-footer-indicators: one dim footer row below the box — path ($HOME → ~),
-- session token stats + context cell, transient flags (toast), and the
-- model right-aligned. Truncation when over width (spec tui Footer): path
-- right-truncate first, then toast dropped, then stats
-- right-truncate; model is handled separately by footer_stats. No reverse
-- video, no mode icons.
local function render_footer(L)
    apply_rows(M._regions.render_footer(M._dock_slice(L), L, M._painters))
end

-- ============================================================
-- Cursor & redraw
-- ============================================================
-- pi-style-input-and-footer: the caret is painted inside the input box by
-- render_input (pi's block caret), so the hardware terminal cursor stays hidden
-- for the whole session — there is no cursor-positioning pass left. Overlays
-- never showed it either, and the exit sequence turns it back on.

local function redraw()
    local L = layout()
    frame_start()

    if L.w ~= S.last_w or L.h ~= S.last_h then
        S.screen = {}
        frame_put(ESC .. "[2J")
        S.last_w, S.last_h = L.w, L.h
    end

    render_transcript(L)
    render_error_banner(L)
    if L.gap_row then set_row(L.gap_row, "") end
    render_input(L)
    render_palette(L)
    render_footer(L)

    frame_flush()
end

-- A: repaint from inside the turn. agent.turn runs synchronously inside
-- commit_input, so the main loop's redraw() never fires while the model
-- streams — without this the whole answer appeared at once when the turn
-- ended. Throttled so per-token deltas don't repaint per token: a repaint
-- happens after PAINT_MIN_DELTAS skipped deltas or PAINT_INTERVAL of CPU
-- time, and state transitions pass force=true.
local PAINT_INTERVAL = 0.05
local PAINT_MIN_DELTAS = 12
M._paint_skipped = 0
M._paint_count = 0 -- TW2: repaint counter (spinner frame is time-based now)
M._last_paint = 0
-- wall-clock seconds: os.clock() is CPU time and stalls while blocked in
-- C (curl_easy_perform), which froze the throttle during silent waits.
function M._paint_clock()
    local ok, ms = pcall(function()
        return tether.monotonic_ms and tether.monotonic_ms() or nil
    end)
    if ok and type(ms) == "number" then return ms / 1000 end
    return os.clock()
end
local function paint(force)
    if not S then return end
    -- provider-auth: while a device-flow login waits for authorization the
    -- event loop is idle, so the poll ticks from the paint path (paced via
    -- flow.poll_next_at inside the tick).
    if S.login_secret and type(M._device_poll_tick) == "function" then
        M._device_poll_tick()
    end
    M._paint_skipped = M._paint_skipped + 1
    local now = M._paint_clock()
    if not force and M._paint_skipped < PAINT_MIN_DELTAS and (now - M._last_paint) < PAINT_INTERVAL then
        return
    end
    M._last_paint = now
    M._paint_skipped = 0
    M._paint_count = M._paint_count + 1
    redraw()
end
M._paint = paint

-- Per-paint painter table built by ui_themes (2.1): ui_regions,
-- ui_ask_view and ui_confirm consume this instead of the once-built
-- M._painters proxy (which stays until 2.2). Values resolve live per
-- paint from the same seams the proxy closures read, so bytes match
-- exactly within a paint. Chunk local: 1.1 freed a dozen theme locals.
painters = function()
    return M._themes.build({
        theme = _theme_name, depth = M.color_depth(),
        ascii = M._ascii_mode or M._env_ascii or _ascii,
        light_bg = M.is_light_bg(), copy = M._copy,
        vlen = vlen, clip = clip, trunc = trunc, cells = cells, wrap = wrap,
        now_ms = M._paint_clock, caret = caret_glyph,
        freeform = ask.FREEFORM_LABEL,
        ascii_none = function() return M.color_depth() == "none" end,
        spinner_interval_ms = SPINNER_INTERVAL_MS, md_render = md_render,
    })
end

-- Painter/capability table for ui_regions (built once; the module never
-- touches ui locals, S, or globals). Theme-bound painters stay here until
-- the themes cut — the module receives them as values.
M._painters = {
    dim = dim, muted = muted, red = red, green = green, yellow = yellow,
    cyan = cyan, accent = cyan, rev = rev, italic = italic,
    trunc = trunc, vlen = vlen, to_ascii = to_ascii, cells = cells,
    clip = clip, wrap = wrap,
    copy = M._copy,
    now_ms = M._paint_clock,
    role = function(kind, text) return sgr_role(kind, text) end,
    md = function(text, inner) return md_render(text, inner, M.md_ansi) end,
    hint = function(pairs, inner) return M.hint_paint(pairs, inner) end,
    caret = function() return caret_glyph() end,
    freeform = ask.FREEFORM_LABEL,
    ascii_none = function() return M.color_depth() == "none" end,
    caret_reverse = function()
        return M._themes.caret_reverse(M._themes.THEMES, _theme_name, M.color_depth())
    end,
    spinner_interval_ms = SPINNER_INTERVAL_MS,
}

-- State slice for ui_regions, built per paint (geometry + read fields only;
-- screen application stays in apply_rows near set_row above).
function M._dock_slice(L)
    local cw = M._content_width(L.w)
    local pad = box_padding(cw)
    local prov_cfg = S.cfg or {}
    local home = os.getenv("HOME") or ""
    local ws = S.workspace or ""
    if home ~= "" and ws:sub(1, #home) == home then
        ws = "~" .. ws:sub(#home + 1)
    end
    return {
        w = L.w, content_width = cw, gutter = string.rep(" ", ui_pad(L.w)),
        pad = pad, side = string.rep(" ", pad),
        content_w = math.max(1, cw - pad * 2),
        input = S.input, cursor = S.cursor,
        busy = S.busy, busy_started_at_ms = S.busy_started_at_ms,
        error_banner = S.error_banner, toast = S.toast,
        tokens_used = S.tokens_used, tokens_max = S.tokens_max,
        tokens_in = S.tokens_in, tokens_out = S.tokens_out,
        model_name = S.model_name,
        cfg_provider = prov_cfg.provider,
        cfg_reasoning = type(prov_cfg.reasoning) == "string" and prov_cfg.reasoning or nil,
        cfg_summarize_at = prov_cfg.context and prov_cfg.context.summarize_at or nil,
        cfg_providers = prov_cfg.providers,
        ws_tilde = ws, home = home,
        login = S.login_secret and {
            buf = S.login_secret.buf, provider = S.login_provider, flow = S.login_flow,
        } or nil,
        -- read fresh per paint: tests/host can re-point the catalog at runtime.
        catalog = M._provider_catalog,
    }
end

-- Busy-spinner tick: repaints the ` Working...` indicator and drains keys
-- while a turn runs, so a silent stretch (TTFT, backoff, a tool command)
-- never freezes the TUI or queues a wheel tick until the next event. Two
-- drivers cover the two kinds of wait: the reactor's on_tick (the loop owns
-- waiting on the turn path — streamed attempts and backoff deadlines nest
-- into it) and the host hook bound by run() via tether.set_tick_hook (the
-- waits that still block the loop — tether.exec, http_get, the blocking
-- transport/sleep fallbacks — call it back on their quantum).
-- The tick repaints at most once per spinner interval while a turn is busy;
-- overlays own the keyboard first, so it stays a no-op then.
-- (M-fields, not chunk locals: ui.lua sits at Lua's 200-locals limit.)
M._last_spinner_tick_s = nil
function M._spinner_tick()
    if not S or S.quit then return end
    -- a Ctrl+Q that arrived while the turn blocks in the host (a tool
    -- command, a backoff, a transfer): the host raised it because the UI is
    -- not reading stdin here, and this tick is the only Lua entry while the
    -- wait spins
    if tether.quit_requested() then S.quit = true; return end
    if not S.busy then return end
    if S.confirmation or S.ask or S.login_secret then return end
    -- Drain keys here too, not only on agent events: while a turn waits
    -- silently (TTFT/backoff) no event fires, so without this a wheel tick
    -- queued until the next model/tool event and the scroll visibly lagged
    -- one step behind. Pumping first also keeps fragmented ESC sequences
    -- whole: the non-blocking decode yields nil until the tail arrives.
    local had_keys = false
    if type(M._pump_keys) == "function" then had_keys = M._pump_keys() or false end
    local now_s = M._paint_clock()
    if had_keys then
        M._last_spinner_tick_s = now_s
        paint(true)
        return
    end
    if M._last_spinner_tick_s
        and now_s - M._last_spinner_tick_s < SPINNER_INTERVAL_MS / 1000 then
        return
    end
    M._last_spinner_tick_s = now_s
    paint(true)
end

-- ============================================================
-- Key reading — bytes → typed events (narrow contract)
-- ============================================================
-- Moved to ui_keys (src/tether/ui/keys.lua): pure decoders plus
-- decode_first_byte/read_key/read_key_nb operating on the bag (M).
-- M-fields below are the state bag + thin forwarders (tests drive
-- M._stash_front directly).
-- Event shapes are documented in ui/keys.lua header.
M._byte_stash = {}
-- Wall-clock age of a stashed lone ESC prefix (seconds): the pump and the
-- idle retry drive the decoder once per quantum, so a split sequence's tail
-- lands within one; older than this with no tail, the ESC arrived alone.
M._esc_stash_s = nil
function M._read_nb() return M._keys.read_nb(M) end

-- Push bytes back to the FRONT of the stash (order preserved) so a
-- fragmented escape sequence is retried whole on the next tick instead of
-- leaking its tail ("[<65;48;31M") into the input as text.
function M._stash_front(list) return M._keys.stash_front(M, list) end

-- Decode one already-read first byte; continuation bytes come from
-- read_char_nb (and the paste body from read_char). Shared by read_key and
-- read_key_nb so blocking and non-blocking paths stay identical.
-- (Bodies live in ui_keys; the forwarder below keeps call sites unchanged.)
local function read_key_nb() return M._keys.read_key_nb(M) end

-- ============================================================
-- Command execution
-- ============================================================
local function start_new_session()
    local sid = commands.new(S.workspace, S.model_name)
    if sid then S.session_id = sid end
    if S.cfg then S.cfg._session_id = S.session_id end
    -- pi-style-input-and-footer: the footer's counters are per session
    S.tokens_in, S.tokens_out = 0, 0
    -- a new session knows nothing of the old transcript — drop it too,
    -- otherwise the screen shows messages the agent never saw. A fresh
    -- start shows the splash again, not a blank screen.
    reset_transcript({ M._splash_entry() })
end

-- M9: /log command (and its view) removed

-- add-provider-login: interactive credential entry (masked secret mode) and
-- bare-/login provider picker (Pi OAuthSelector). Secrets live only in
-- S.login_secret.buf — never S.input, never a transcript row.
-- expand-provider-catalog: the picker and the /login//logout name checks
-- read the preset catalog (single source with api.lua dispatch) — the big
-- three stay pinned first.
-- provider_catalog on M (200-locals discipline): the module was at the cap,
-- every new top-level local pushes main-chunk compiles over the limit.
M._provider_catalog = _G.provider_catalog
if type(M._provider_catalog) ~= "table" then
    local chunk = loadfile("src/tether/providers/catalog.lua")
    M._provider_catalog = (chunk and chunk()) or nil
end

-- Phase C 3.3: known_providers/is_known_provider proxies deleted with
-- the login/logout command bodies (no callers left; ui_auth owns them).
local function provider_mod(name)
    local glob = rawget(_G, "provider_" .. name)
    if glob then return glob end
    local chunk = loadfile("src/tether/providers/" .. name .. ".lua")
    return chunk and chunk() or nil
end

-- Impure edge for ui_auth, built per call (catalog/store/host handles +
-- transcript callbacks; S itself travels as the bag). M-field, not a chunk
-- local: the main chunk sits at Lua's 200-locals limit. Defined after
-- provider_mod so the loader upvalue resolves.
function M._auth_deps()
    local auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    local ccommon = rawget(_G, "provider_common")
    if not ccommon then
        local chunk = loadfile("src/tether/providers/common.lua")
        ccommon = chunk and chunk() or nil
    end
    return {
        catalog = M._provider_catalog,
        auth = auth_mod,
        load_provider = provider_mod,
        common = ccommon,
        errors = M._copy.errors,
        host = tether,
        note = function(text) transcript.append({ role = "system", text = text }) end,
        bump = bump_transcript,
        apply_query = function() M._palette_apply_query() end,
    }
end

local function begin_login(provider)
    return M._auth_flow.begin(S, M._auth_deps(), provider)
end

-- One device-flow poll tick, called from the busy pump on each paint while
-- login secret mode with a device flow is active. Paces itself via
-- flow.poll_next_at. Lives on M.* (chunk-local limit: 200 locals); the
-- implementation is assigned right after cancel_login's declaration below
-- (it closes over cancel_login).

local function cancel_login()
    return M._auth_flow.cancel(S)
end

-- provider-auth: one device-flow poll tick, called from the paint path while
-- login secret mode with a device flow is active. Paces itself via
-- flow.poll_next_at; returns "pending" | "granted" | "failed" | nil.
M._device_poll_tick = function()
    return M._auth_flow.poll_tick(S, M._auth_deps())
end

-- Shared store path for secret-mode Enter: OAuth code/redirect vs bare API key.
local function submit_login_secret(raw)
    return M._auth_flow.submit(S, M._auth_deps(), raw)
end

-- Impure edge for commands.pick_* appliers, built per call.
-- M-field (200-locals limit).
function M._pick_deps()
    return {
        resume = function(id) return commands.resume(id, nil, S.cfg) end,
        seed = function(msgs) return transcript.seed(msgs) end,
        reset = function(rows) return transcript.reset(rows) end,
        append = function(row) return transcript.append(row) end,
        bump = bump_transcript,
        splash = function() return M._splash_entry() end,
        copy = M._copy,
    }
end

-- palette-only R2: Enter/mouse actions for picked resume/model rows.
-- Appliers live in commands (ui-facade-thinning 2.1); the facade keeps
-- these one-line proxies. One local (file is at the 200-local limit).
local pick = {}
-- Test/dev stubs of the commands global predate pick_* (3.1 pattern):
-- fall back to the file when the captured table has no entry point.
-- Locals live inside the proxies (the chunk sits at the 200-local limit).
function pick.resume(id)
    local cmdmod = commands
    if type(cmdmod.pick_resume) ~= "function" then
        local chunk = loadfile("src/tether/commands.lua")
        cmdmod = (chunk and chunk()) or cmdmod
    end
    return cmdmod.pick_resume(S, M._pick_deps(), id)
end
function pick.model(item, provider)
    local cmdmod = commands
    if type(cmdmod.pick_model) ~= "function" then
        local chunk = loadfile("src/tether/commands.lua")
        cmdmod = (chunk and chunk()) or cmdmod
    end
    return cmdmod.pick_model(S, M._pick_deps(), item, provider)
end
-- add-reasoning-level: apply a level from /think or its picker.
function pick.think(level)
    local cmdmod = commands
    if type(cmdmod.pick_think) ~= "function" then
        local chunk = loadfile("src/tether/commands.lua")
        cmdmod = (chunk and chunk()) or cmdmod
    end
    return cmdmod.pick_think(S, M._pick_deps(), level)
end

-- add-llm-compaction: `rest` is the free text after the command word
-- (e.g. focus instructions for /compact).
-- Phase C 3.1: slash dispatch lives in commands.dispatch (name ->
-- handler, bag/callback shape). One chunk local (the file sits at Lua's
-- 200-locals limit): handlers assign straight into the callback table.
local slash_callbacks = {}

local function execute_command(cmd, rest)
    input_clear()
    debug_log("command: " .. tostring(cmd))
    -- the if-chain is gone: exact-name dispatch, unknown names no-op
    -- as the old fall-through did. Global+fallback: stubs of the
    -- commands global (tests/dev) predate the table — routing shape
    -- then comes from the file while bodies keep the stub's list_*
    -- surface. M-field, not a chunk local (200-locals limit).
    local dispatch = commands.dispatch
    if not dispatch then
        if not M._slash_dispatch then
            local chunk = loadfile("src/tether/commands.lua")
            M._slash_dispatch = (chunk and chunk().dispatch) or nil
        end
        dispatch = M._slash_dispatch
    end
    local h = dispatch and dispatch[cmd]
    if h then h(S, slash_callbacks, cmd, rest) end
end

slash_callbacks.quit = function(bag, cmd, rest)
    S.quit = true
end

slash_callbacks.clear = function(bag, cmd, rest)
        -- §6.8: clears in-memory transcript only; disk session untouched.
        -- The splash returns so /clear reads as a fresh start.
        reset_transcript({ M._splash_entry() })
end

slash_callbacks.compact = function(bag, cmd, rest)
        -- force summarization (threshold bypassed); optional focus text
        local focus = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if focus == "" then focus = nil end
        local summary = commands.compact(S.cfg, S.api_key or "", focus)
        if summary ~= nil then
            if type(summary) == "string" and summary ~= "" then
                transcript.append({ role = "system", text = summary })
            else
                transcript.append({ role = "separator", text = M._copy.session.compact_separator })
            end
        end
        if agent and agent.estimate_tokens then
            S.tokens_used = agent.estimate_tokens(agent.get_history())
        end
        bump_transcript()
end

slash_callbacks.new = function(bag, cmd, rest)
    start_new_session()
end

slash_callbacks.copy = function(bag, cmd, rest)
        -- 5.2: open the copy palette; targets are built from the transcript
        local targets = M.copy_targets(transcript.entries())
        local items = {}
        for _, tg in ipairs(targets) do
            items[#items + 1] = { label = tg.name, desc = tostring(tg.bytes) .. M._copy.session.copy_bytes_suffix, copy = tg }
        end
        S.palette_mode = "copy"
        S.palette_active = true
        S.palette_items = items
        S.palette_sel = 1
        S._in_copy_palette = true
end

-- expand-provider-catalog: model items builder, reused when a background
-- refresh lands while the palette is open (was nested in execute_command;
-- hoisted: redefining it per call was a no-op). M-field: callers and the
-- background path use the M.* name.
function M._build_model_items(models)
    local items = {}
    for _, m in ipairs(models or {}) do
        local desc = m.name or m.id or ""
        if m.provider then desc = m.provider .. " • " .. desc end
        items[#items + 1] = {
            label = m.id or m,
            desc = desc,
            provider = m.provider,
        }
    end
    return items
end

slash_callbacks.model = function(bag, cmd, rest)
        -- all keyed providers (active first); legacy single-provider path
        -- when the commands surface predates list_models_all (tests).
        local models, bg, merr = nil, nil, nil
        if commands.list_models_all then
            local ok, m, b, e = pcall(commands.list_models_all, S.cfg)
            if ok then models, bg, merr = m, b, e end
        end
        if models == nil then
            models, bg, merr = commands.list_models(S.cfg, S.api_key or "")
        end
        if bg then
            S._models_bg = { provider = (S.cfg and S.cfg.provider) or "openai",
                started = os.time() }
        end
        -- palette-only R2: model list is a palette under the input
        S.error_banner = nil
        S.palette_mode = "model"
        S.palette_active = true
        S.palette_items = M._build_model_items(models)
        S._palette_all = S.palette_items
        S.palette_query = ""
        S.palette_sel = 1
        S._in_model_palette = true
        -- an empty palette explains itself (no key, dead endpoint, ...).
        S._models_err = (#S.palette_items == 0) and merr or nil
        if S._models_err then S.error_banner = S._models_err end
        -- dynamic-provider-catalog: a landed providers refresh applies now;
        -- a stale catalog marks its age (one-shot toast + debug log).
        do
            local home = (S.cfg and S.cfg._auth_home) or nil
            if commands.poll_providers then
                pcall(commands.poll_providers, home)
            end
            local age = commands.providers_age
                and commands.providers_age(home) or nil
            if age and age.stale then
                S.toast = "providers catalog " .. age.text .. " old"
                debug_log("providers catalog age: " .. age.text)
            end
        end
end

slash_callbacks.resume = function(bag, cmd, rest)
        local items = {}
        for _, f in ipairs(commands.list_sessions(S.workspace)) do
            -- session ts is ISO ("2026-09-24T10:00:00"): show the clock time,
            -- not the year prefix sub(1,5) used to show ("2026-" on every row).
            local ts = (f.ts and f.ts:match("T(%d%d:%d%d)")) or "…"
            items[#items + 1] = {
                label = string.format("%s · %s · %s",
                    ts,
                    (f.id and f.id:sub(1, 8)) or "…",
                    (f.first_line or ""):sub(1, 40)),
                id = f.id,
            }
        end
        -- palette-only R2: session list is a palette under the input
        S.error_banner = nil
        S.palette_mode = "resume"
        S.palette_active = true
        S.palette_items = items
        S.palette_sel = 1
        S._in_resume_palette = true
end

slash_callbacks.login = function(bag, cmd, rest)
    -- Phase C 3.3: body lives in ui_auth (catalog/auth/store reads).
    return M._auth_flow.login_command(S, M._auth_deps(), rest)
end

slash_callbacks.logout = function(bag, cmd, rest)
    -- Phase C 3.3: body lives in ui_auth (catalog/auth/store reads).
    return M._auth_flow.logout_command(S, M._auth_deps(), rest)
end

slash_callbacks.think = function(bag, cmd, rest)
        -- add-reasoning-level: reasoning level — a level argument applies
        -- directly, no argument opens the level picker in the shared palette.
        local level = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if level == "" then
            local ORDER = { "off", "low", "medium", "high" }
            local cur = (S.cfg and S.cfg.reasoning) or "off"
            local items = {}
            for _, lv in ipairs(ORDER) do
                items[#items + 1] = { label = lv,
                    desc = (lv == cur) and M._copy.session.think_current or "" }
            end
            S.error_banner = nil
            S.palette_mode = "think"
            S.palette_active = true
            S.palette_items = items
            S.palette_sel = 1
            S._in_think_palette = true
            return
        end
        level = level:lower()
        local known = { off = true, low = true, medium = true, high = true }
        if not known[level] then
            S.error_banner = M._copy.errors.unknown_thinking_level_prefix .. level
            return
        end
        pick.think(level)
end

-- (slash_callbacks entries assign directly above; unknown names have
-- no entry and no-op, as the old if-chain's fall-through did.)

-- Test seam (kept per facade-proxy-removal 2.1): drives slash dispatch
-- with the live S without going through the byte pump. commands.dispatch
-- forwards to the facade-owned slash_callbacks bodies above, so there is
-- no module entry point tests could call instead — the proxy stays.
M._execute_command = function(cmd, rest) if S then execute_command(cmd, rest) end end

-- ============================================================
-- Agent integration
-- ============================================================
-- Transcript lifecycle: agent history -> visible entries. Only user text
-- and assistant text are shown; system prompts, tool-call scaffolding
-- and tool results stay in the agent history, not on screen.
local function transcript_entries(messages)
    local out = {}
    for _, m in ipairs(messages or {}) do
        if m.role == "user" then
            out[#out + 1] = { role = "user", text = tostring(m.content or "") }
        elseif m.role == "assistant" and type(m.content) == "string" then
            out[#out + 1] = { role = "assistant", text = m.content }
        end
    end
    return out
end
M.transcript_entries = transcript_entries

-- Forward decls: handle_agent_event (above) calls the busy pump; the pump
-- calls handle_key. handle_key is assigned below — must be local first.
-- pump_keys itself lives in ui_busy (S + callbacks in, handled out).
local handle_key

-- S-MUTATION OWNERSHIP (Phase D 4.1): which handler writes what.
-- Initial values live in new_state (all nil/empty/defaults); below are the
-- post-init writers. Renderers never write (transcript scroll cache aside).
-- Ask edits go through `a`/`answer` aliases of S.ask — no direct S.ask.x
-- writes outside construction. Completion edits go through the `comp`
-- alias of S.completion. T4.1 parses these OWN lines and proves every
-- write site in src is attributed here. Format: OWN: <field> <- owners.
-- OWN: S.ask <- handle_agent_event, resolve_ask
-- OWN: S.ask.* <- handle_agent_event, ask_answer, ask_toggle, ask_advance, handle_ask_key
-- OWN: S.confirmation <- handle_agent_event, resolve_confirmation
-- OWN: S.confirmation_sel <- handle_agent_event, handle_confirmation_key, resolve_confirmation
-- OWN: S.palette_active <- palette_sync, palette_hide, path_complete_tab, completion_cancel, completion_commit, picker_close, mention_refilter, mention_open, on_mouse, on_palette_copy, on_palette_resume, close_resume_palette, on_palette_model, close_model_palette, on_palette_think, close_think_palette, on_palette_login, close_login_palette, on_palette_logout, on_palette_mention, on_slash_copy, on_slash_model, on_slash_resume, on_slash_think, on_slash_login, on_slash_logout, begin, cancel, submit, login_command, logout_command, logout_close, M._poll_models_bg
-- OWN: S.palette_mode <- palette_sync, path_complete_tab, completion_cancel, completion_commit, picker_close, mention_refilter, on_mouse, on_palette_copy, on_palette_resume, close_resume_palette, on_palette_model, close_model_palette, on_palette_think, close_think_palette, on_palette_login, close_login_palette, on_palette_logout, on_slash_copy, on_slash_model, on_slash_resume, on_slash_think, on_slash_login, on_slash_logout, begin, cancel, submit, login_command, logout_command, logout_close, logout_ask_confirm, logout_confirm_back, M._poll_models_bg
-- OWN: S.palette_items <- palette_sync, palette_hide, M._palette_apply_query, path_complete_tab, completion_cancel, completion_commit, picker_close, mention_refilter, on_mouse, on_palette_copy, on_palette_resume, close_resume_palette, on_palette_model, close_model_palette, on_palette_think, close_think_palette, on_palette_login, close_login_palette, on_palette_logout, on_slash_copy, on_slash_model, on_slash_resume, on_slash_think, on_slash_login, on_slash_logout, begin, cancel, submit, login_command, logout_command, logout_close, logout_ask_confirm
-- OWN: S.palette_sel <- palette_sync, palette_hide, M._palette_apply_query, path_complete_tab, completion_cancel, completion_commit, picker_close, mention_refilter, on_mouse, on_palette_copy, on_palette_resume, close_resume_palette, on_palette_model, close_model_palette, on_palette_think, close_think_palette, on_palette_login, close_login_palette, on_palette_logout, on_palette_logout_confirm, on_palette_mention, on_palette_path, on_palette_command, on_slash_copy, on_slash_model, on_slash_resume, on_slash_think, on_slash_login, on_slash_logout, begin, cancel, submit, login_command, logout_command, logout_close, logout_ask_confirm, logout_confirm_back, M._poll_models_bg
-- OWN: S.palette_query <- on_mouse, on_slash_model, on_palette_model, close_model_palette, on_palette_login, close_login_palette, on_palette_logout, login_command, logout_command, logout_close
-- OWN: S.palette_skills <- palette_sync, palette_hide
-- OWN: S._palette_all <- on_mouse, on_slash_model, close_model_palette, close_login_palette, login_command, logout_command, logout_close, M._poll_models_bg
-- OWN: S._in_copy_palette <- on_slash_copy, on_palette_copy
-- OWN: S._in_resume_palette <- on_mouse, on_slash_resume, on_palette_resume, close_resume_palette
-- OWN: S._in_model_palette <- on_mouse, on_slash_model, on_palette_model, close_model_palette, M._poll_models_bg
-- OWN: S._in_think_palette <- on_mouse, on_slash_think, on_palette_think, close_think_palette
-- OWN: S._in_login_palette <- on_mouse, begin, cancel, submit, login_command, close_login_palette, logout_close
-- OWN: S._in_logout_palette <- logout_close, logout_command
-- OWN: S._logout_confirm <- logout_ask_confirm, logout_confirm_back, logout_close
-- OWN: S._logout_sel <- logout_ask_confirm, logout_confirm_back, logout_close
-- OWN: S.completion <- path_complete_tab, completion_cancel, completion_commit, picker_close, mention_refilter, mention_open, on_palette_path
-- OWN: S.completion.* <- path_complete_tab, mention_refilter, on_palette_mention, on_palette_path
-- Out of scope (owned elsewhere): S.login_secret/login_provider/login_flow
-- (ui_auth begin/cancel/submit/poll_tick), S.confirmation.detail (read by
-- resolve_confirmation), S.history (input history), S._models_bg/_models_err
-- (model refresh bookkeeping).

local function handle_agent_event(ev)
    if not ev or not ev.type then return end
    -- add-steering-input: drain mid-turn keys on every event tick so Enter /
    -- Alt+Enter / Escape work while the agent is busy (no second turn).
    -- Returns whether it handled anything: a scroll drained here must repaint
    -- at once instead of waiting out the delta throttle below.
    local pumped = M._busy.pump_keys(S, read_key_nb, handle_key)
    -- A: remember the tail-decoration state so a transition (waiting ->
    -- caret, or caret -> nothing) repaints at once instead of waiting out the
    -- delta throttle.
    local was_waiting, was_streaming = S.waiting, S.streaming

    -- Row mutations belong to the transcript module; ui owns only the mode
    -- flags (waiting/streaming/retry_wait/error/tokens) and confirmation/ask.
    local need_sync = transcript.handle(ev)

    if ev.type == "text_delta" or ev.type == "reasoning_delta" then
        S.retry_wait = nil
        S.waiting = false
        S.streaming = true
    elseif ev.type == "tool_call_start" then
        S.waiting = false
        S.streaming = false
    elseif ev.type == "error" then
        S.error_banner = ev.message or "error"
        -- palette-only R4: full text only to the debug log (when on), never
        -- a modal palette and never a transcript row.
        debug_log("error: " .. tostring(ev.message or "error"))
        S.retry_wait = nil -- a terminal failure ends the backoff wait
    elseif ev.type == "aborted" then
        S.waiting = false
        S.streaming = false
        S.retry_wait = nil
    elseif ev.type == "usage" and ev.usage then
        if ev.usage.used then S.tokens_used = ev.usage.used end
        -- pi-style-input-and-footer: accumulate the session's own traffic —
        -- tokens_used is the context estimate and gets overwritten by it
        S.tokens_in = (S.tokens_in or 0) + (tonumber(ev.usage.prompt_tokens) or 0)
        S.tokens_out = (S.tokens_out or 0) + (tonumber(ev.usage.completion_tokens) or 0)
        S.tokens_estimated = false
    elseif ev.type == "context_compressed" then
        S.tokens_estimated = true
    elseif ev.type == "retry" then
        S.retry_wait = { attempt = ev.attempt or 1, delay = ev.delay or 0,
                         reason = ev.reason }
        S.streaming = false
    elseif ev.type == "continuation" then
        S.retry_wait = nil
        S.streaming = false
    end
    if need_sync then sync_tail() end
    -- Fallback: estimate tokens from the real agent history. Estimate is
    -- O(history) — refresh only on coarse events, not on every streamed delta.
    local significant = ev.type == "tool_call_start" or ev.type == "tool_result"
        or ev.type == "context_compressed" or ev.type == "aborted"
        or ev.type == "confirmation"
    if significant and agent and agent.estimate_tokens then
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
            local name = detail.name
            -- confirm-menu-redesign D3: the header is the single place the
            -- target is shown (no duplicated body row for run/write).
            local label = name .. " " .. (args.path or args.command or args.cwd or "")
            if name == "run" and args.cwd and (args.command or "") ~= "" then
                label = label .. "  (cwd=" .. args.cwd .. ")"
            end
            local body = ""
            if name == "patch" and args.patch then
                body = args.patch
            elseif name == "run" and ui_is_dangerous(args.command or "") then
                -- §6.10: warn on dangerous commands
                -- M7/D1+D2: extracted to ui.is_dangerous() (crash: %f is a Lua
                -- pattern boundary prefix, %frm%s was an invalid pattern).
                body = M._copy.confirm.danger_warning
            end
            -- fresh table per event (values from ui_copy): the menu owns it.
            local options = { table.unpack(M._copy.confirm.options) }
            S.confirmation = {
                label = label,
                body = body,
                question = M.CONFIRM_QUESTIONS[name] or M.CONFIRM_QUESTION_FALLBACK,
                options = options,
                detail = detail,
            }
            S.confirmation_sel = 1
            S.busy = false
            S.waiting = false
            S.streaming = false
            -- the menu replaces the working state: both are synthetic tail entries
            sync_tail()
        end
    end
    if ev.type == "ask" then
        -- add-ask-tool: the question block replaces the working state, exactly as
        -- the confirmation menu does — the turn is waiting on the user.
        S.ask = {
            id = ev.id,
            questions = ev.questions or {},
            qidx = 1,
            sel = 1,
            mode = "list",
            phase = "questions",
            note_sel = nil,
            editor = "",
            answers = {},
        }
        for i = 1, #S.ask.questions do
            S.ask.answers[i] = { selected = {}, other = "", notes = {} }
        end
        S.busy = false
        S.waiting = false
        S.streaming = false
        S.retry_wait = nil
        sync_tail()
    end
    if not S.user_scrolled then S.scroll = 0 end
    -- A: repaint now — the main loop only redraws between keypresses, so
    -- without this nothing the model produced would be visible mid-turn.
    -- Deltas are throttled inside paint(); every other event repaints at once.
    local force = ev.type ~= "text_delta" and ev.type ~= "reasoning_delta"
        and ev.type ~= "usage"
    if pumped then force = true end
    if S.waiting ~= was_waiting or S.streaming ~= was_streaming then force = true end
    paint(force)
end

-- Test seam: mode/paint shell tests drive events through here; row mutations
-- go to transcript.handle. Row-only tests use M._transcript.* directly (D8).
M._handle_agent_event = handle_agent_event

-- ============================================================
-- add-steering-input: busy pump, queues, Escape restore, bang
-- ============================================================

-- Called from handle_agent_event while S.busy: drain non-blocking keys so
-- Enter / Alt+Enter / Escape work mid-turn without a second concurrent turn.
-- Canonical implementation lives in ui_busy (S + read_key_nb/handle_key in).
M._pump_keys = function() if S then return M._busy.pump_keys(S, read_key_nb, handle_key) end return false end

-- Idle retry for a stashed escape prefix: the stdin drain fires only when
-- fresh bytes arrive, so without a tick-driven retry (see run's on_tick) a
-- lone Esc would sit in the stash until the next keypress. Same shape as the
-- drain: decode everything currently readable, dispatch, count handled.
M._drain_stash = function()
    if not S or S.busy then return 0 end
    return M._busy.drain_stash(S, read_key_nb, handle_key)
end

-- Shared submit path for Enter / Alt+Enter while busy: user row now, queue
-- FIFO, clear input. Canonical implementation lives in ui_busy.
local function enqueue_busy(kind)
    if not S then return end
    M._busy.enqueue_busy(S, kind, queue_push, push_history,
        function(text)
            transcript.append({ role = "user", text = text })
            bump_transcript()
        end,
        input_clear, QUEUE_CAP)
end

-- Escape while busy with a non-empty queue: steers first, then follow-ups.
-- Canonical implementation lives in ui_busy.
local function restore_queues()
    if not S then return end
    M._busy.restore_queues(S, input_clear, palette_sync)
end
M._restore_queues = function() if S then restore_queues() end end

-- ! / !! parser: canonical implementation lives in ui_busy (pure).
M._parse_bang = M._busy.parse_bang

-- Run a bang line through the shared run-tool path (workspace, timeout, env).
-- Renders a tool-style row; ! stores a bounded excerpt for the next message;
-- !! never touches history or bang_context.
local function run_bang(s)
    local kind, cmd = M._parse_bang(s)
    if not kind then return false end
    if kind == "empty" then
        S.error_banner = "missing command"
        return true
    end
    local tm = tools_mod()
    if not (tm and tm.run) then
        S.error_banner = "shell unavailable"
        return true
    end
    local res = tm.run({ command = cmd }, S.cfg)
    if not res then
        S.error_banner = "command failed to start"
        return true
    end
    local exit_n = res.exit_code or 0
    local out = res.output or ""
    -- same bound as the run tool's UI body
    if #out > 16 * 1024 then out = out:sub(1, 16 * 1024) .. "\n…(truncated)" end
    local elapsed = res.elapsed_ms
    local summary = "exit " .. tostring(exit_n)
        .. (elapsed and (", " .. (elapsed < 1000 and (elapsed .. " ms")
            or string.format("%.1f s", elapsed / 1000))) or "")
    transcript.append({
        role = "tool",
        id = "bang_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
        started_at = os.time(),
        name = "run",
        status = exit_n == 0 and "ok" or "error",
        summary = summary,
        body = out,
        args = { command = cmd },
        path = nil,
        projection = nil,
    })
    bump_transcript()
    if kind == "bang" then
        S.bang_context = out
    end
    input_clear()
    S.error_banner = nil
    return true
end
M._run_bang = function(s) if S then return run_bang(s) end return false end

-- Fold a pending !cmd excerpt into the next outbound message (turn start,
-- steer injection, follow-up). Cleared on use.
local function take_bang_context()
    local ctx = S and S.bang_context
    if ctx and ctx ~= "" then
        S.bang_context = nil
        return "\n\n[bang]\n" .. ctx
    end
    return ""
end

-- Pull one steering message for the agent (segment boundary). Returns nil
-- when the queue is empty so main_loop can settle.
local function take_steer()
    if not S or not S.steer_queue or #S.steer_queue == 0 then return nil end
    return table.remove(S.steer_queue, 1)
end

-- Wire agent → UI steer source once state exists.
local function wire_steer_source()
    if agent and type(agent.set_steer_source) == "function" then
        agent.set_steer_source(function()
            local t = take_steer()
            if not t then return nil end
            return t .. take_bang_context()
        end)
    end
end

-- After a turn fully settles: drain follow-ups in order as fresh turns.
-- Stops on error banner, parked confirmation/ask, or pending steers.
local turn_hook = nil -- test seam: replaces turn.start during drain
M._set_turn_hook = function(fn) turn_hook = fn end

-- Lazy session: the file appears with the first turn, never at startup.
-- (M-field: ui.lua sits at Lua's 200-locals limit for the main chunk.)
function M._ensure_session()
    if not S then return end
    if S.cfg and S.cfg._session_id then
        S.session_id = S.cfg._session_id
        return
    end
    if commands and commands.new then
        local ok, sid = pcall(commands.new, S.workspace, S.model_name)
        if ok and sid then
            S.session_id = sid
            if S.cfg then S.cfg._session_id = sid end
        end
    end
end

-- Every fresh turn restarts attempt numbering at 1 on the agent side, so
-- stale attempt tags are cleared first: otherwise a retry drops previous
-- turns' answers carrying the same number (transcript.new_turn).
local function start_fresh_turn(payload)
    transcript.new_turn()
    M._ensure_session()
    if turn_hook then return turn_hook(payload) end
    return turn.start(S, S.cfg, S.api_key or "", payload, handle_agent_event, function()
        sync_tail()
        paint(true)
    end)
end

local function drain_followups()
    if not S then return end
    if S.error_banner or S.confirmation or S.ask then return end
    if S.steer_queue and #S.steer_queue > 0 then return end
    while S.followup_queue and #S.followup_queue > 0 do
        if S.error_banner or S.confirmation or S.ask then return end
        if S.steer_queue and #S.steer_queue > 0 then return end
        local msg = table.remove(S.followup_queue, 1)
        local payload = msg .. take_bang_context()
        local ok, err = start_fresh_turn(payload)
        sync_tail()
        if not ok and err then
            S.error_banner = tostring(err)
            return
        end
    end
end
M._drain_followups = function() if S then drain_followups() end end

-- After commit_input / confirmation resume: settle then drain.
local function after_turn_settle()
    drain_followups()
end

-- Impure edge for ui_confirm, built per call. M-field (200-locals limit);
-- defined after after_turn_settle so every upvalue resolves.
function M._confirm_deps()
    return {
        turn = turn,
        agent = rawget(_G, "agent"),
        on_event = handle_agent_event,
        sync = sync_tail,
        paint = paint,
        bump = bump_transcript,
        settle = after_turn_settle,
        note = function(text) transcript.append({ role = "system", text = text }) end,
        layout = layout,
        content_width = M._content_width,
        ensure = ensure_index,
        row_text = row_text,
        digits = CONFIRM_DIGITS,
    }
end

-- Impure edge for ui_ask, built per call. M-field (200-locals limit).
function M._ask_deps()
    return {
        askmod = ask,
        turn = turn,
        on_event = handle_agent_event,
        sync = sync_tail,
        paint = paint,
        bump = bump_transcript,
        settle = after_turn_settle,
        note = function(text) transcript.append({ role = "system", text = text }) end,
    }
end

-- Impure edge for ui_complete, built per call. M-field (200-locals limit).
function M._complete_deps()
    return {
        tools = M._tools_stub or tools_mod()
            or (pcall(require, "tools") and package.loaded.tools)
            or nil,
        sync = palette_sync,
        lines = function() return input_lines() end,
    }
end

local function commit_input()
    local text = S.input
    if text:match("^%s*$") then
        input_clear()
        return
    end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "/" then
        -- add-llm-compaction: capture free text after the command word
        local word, rest = trimmed:match("^/(%w+)%s*(.*)$")
        if word then
            -- unified-slash-palette 4.2: names compare without regard to case.
            -- Routing lives in commands.resolve_slash; a skill name falls
            -- through to the ordinary submit path below. Test/dev stubs of
            -- the commands global predate resolve_slash (3.1 pattern).
            local resolve = commands.resolve_slash
            if type(resolve) ~= "function" then
                local chunk = loadfile("src/tether/commands.lua")
                local real = chunk and chunk() or nil
                resolve = real and real.resolve_slash
            end
            local route = (type(resolve) == "function")
                and resolve(word, command_set(), palette_skill_rows()) or "unknown"
            if route == "command" then
                execute_command(word:lower(), rest)
                return
            elseif route == "unknown" then
                execute_command(word, rest)
                return
            end
        end
    end
    -- add-steering-input: bang runs after slash resolution, never to the model
    local bang = M._parse_bang(trimmed)
    if bang then
        run_bang(trimmed)
        return
    end
    push_history(text)
    -- Turn separators (tui: Turn separators): one dim timestamp row per new turn,
    -- placed before the user row. It is a transcript row — it scrolls and counts
    -- toward the height — but it never reaches the agent.
    if not (S.cfg and S.cfg.ui and S.cfg.ui.turn_separators == false) then
        transcript.append({ role = "separator", text = os.date("%H:%M") })
    end
    transcript.append({ role = "user", text = text })
    bump_transcript()
    input_clear()
    S.error_banner = nil
    S.scroll = 0
    S.user_scrolled = false

    -- turn owns busy/waiting/streaming begin+finish and the abort seam;
    -- before_call paints the Working indicator before the blocking agent call (T54).
    wire_steer_source()
    local send = text .. take_bang_context()
    local ok, err = start_fresh_turn(send)
    sync_tail()
    if not ok and err then
        S.error_banner = tostring(err)
    end
    after_turn_settle()
end

-- M8/R8: emit ?1000h/?1006h only on state transitions (not every frame)
-- T46 regression: each fragment needs its own ESC — "[?1000h[?1006h" emitted
-- a literal "[?1006h" into the input field when the palette opened.
function M.mouse_tracking_seqs(enable)
    if enable then
        return ESC .. "[?1000h" .. ESC .. "[?1006h"
    end
    return ESC .. "[?1000l" .. ESC .. "[?1006l"
end

local function mouse_update_tracking()
    local mode = (S.cfg.ui and S.cfg.ui.mouse) or "auto"
    local want = M.mouse_wants(mode, { confirmation = S.confirmation ~= nil,
                                       palette_active = S.palette_active })
    if want ~= S.mouse_enabled then
        S.mouse_enabled = want
        w(M.mouse_tracking_seqs(want))
    end
end

-- ============================================================
-- Key dispatch
-- ============================================================
local function handle_special(k)
    if k.name == "left" then
        if S.cursor > 0 then
            local ok, prev = pcall(utf8.offset, S.input, -1, S.cursor + 1)
            if not ok or not prev then
                -- mid-char cursor: walk back over continuation bytes
                local pos = S.cursor
                while pos > 0 and S.input:byte(pos) >= 0x80
                    and S.input:byte(pos) < 0xC0 do
                    pos = pos - 1
                end
                prev = pos
            end
            if prev then S.cursor = prev - 1 end
        end
    elseif k.name == "right" then
        -- S.cursor is the number of bytes BEFORE the caret (0..#S.input), so
        -- moving right must place the caret after the NEXT character, never
        -- inside one. utf8.offset(s, 1, i) returns the 1-based byte START of
        -- the character containing byte i; the character's length is the gap
        -- to the next char start, so new cursor = nxt - 1 + chlen. The old
        -- code assigned `nxt` (one byte short on multi-byte chars) or earlier
        -- `nxt - 1` (same position — Right appeared dead). A mid-character
        -- cursor (stale byte offset from a kill/paste) makes offset() raise —
        -- walk to the end of that character instead.
        if S.cursor < #S.input then
            local ok, nxt = pcall(utf8.offset, S.input, 1, S.cursor + 1)
            if ok and nxt then
                -- length of the character starting at nxt, from its leading
                -- byte (0xxxxxxx=1, 110xxxxx=2, 1110xxxx=3, 11110xxx=4).
                -- utf8.offset(nxt+1) cannot be used: it raises on a
                -- continuation byte, i.e. for every multi-byte character.
                local b = S.input:byte(nxt)
                local chlen = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
                S.cursor = nxt - 1 + chlen
            else
                -- cursor+1 sits inside a multi-byte character: skip its tail
                -- bytes (0b10xxxxxx) so the caret lands after that character.
                local pos = S.cursor + 1
                while pos <= #S.input do
                    local b = S.input:byte(pos)
                    if b < 0x80 or b >= 0xC0 then break end
                    pos = pos + 1
                end
                S.cursor = pos
            end
        end
    elseif k.name == "home" and S.input == "" then
        -- M8/R3: Home jumps to top of transcript (input empty);
        -- with text in input, Home moves to line start (branch below)
        S.user_scrolled = true
        S.scroll = math.max(0, M.transcript_height(M._content_width(layout().w)) - 1)
    elseif k.name == "end" and S.input == "" then
        -- M8/R3: End jumps to bottom (follow mode) when input is empty
        S.scroll = 0
        S.user_scrolled = false
    elseif k.name == "home" then move_line_start()
    elseif k.name == "end" then move_line_end()
    elseif k.name == "delete" then input_delete()
    elseif k.name == "up" then
        -- tui spec: Shift+Up/Shift+Down move the cursor between input lines
        -- explicitly (no history recall, no scroll edge). Plain Up recalls
        -- history; when the caret is on a non-first line of a multi-line
        -- input, move the cursor instead, and scroll only at that edge.
        -- PgUp/PgDn are the scroll bindings. Terminals without
        -- kitty/modifyOtherKeys report Shift+Up as plain Up — acceptable:
        -- the recall behaviour stays identical to the pre-spec default.
        if k.shift and S.input ~= "" then
            move_cursor_up()
        elseif S.input ~= "" and move_cursor_up() then
            -- caret moved within the multi-line input
        else
            history_prev()
        end
    elseif k.name == "down" then
        if k.shift and S.input ~= "" then
            move_cursor_down()
        elseif S.input ~= "" and move_cursor_down() then
            -- caret moved within the multi-line input
        else
            history_next()
        end
    elseif k.name == "pgup" then
        S.scroll = S.scroll + math.max(1, math.floor(S.h / 2))
        S.user_scrolled = true
    elseif k.name == "pgdn" then
        S.scroll = math.max(0, S.scroll - math.max(1, math.floor(S.h / 2)))
        if S.scroll == 0 then S.user_scrolled = false end
    end
end

-- 3.3: expand every tool entry (and clear per-entry state), or toggle just the
-- newest tool entry overlapping the viewport (falling back to the newest one).
local function toggle_all_entries()
    S.expand_all = not S.expand_all
    for _, e in ipairs(transcript.entries()) do e.expand_state = nil end
    invalidate_all()
end

local function toggle_newest_visible_tool()
    local L = layout()
    local cw = M._content_width(L.w)
    local total = ensure_index(cw)
    local bottom = total - S.scroll
    if bottom > total then bottom = total end
    if bottom < 1 then bottom = 1 end
    local top = bottom - L.transcript_h + 1
    if top < 1 then top = 1 end
    local lo = entry_of_row(top, cw) or 0
    local hi = entry_of_row(math.min(total, bottom), cw) or -1
    local chosen
    for i = hi, lo, -1 do
        local e = entry_at(i)
        if e and e.role == "tool" then chosen = e; break end
    end
    if not chosen then
        for i = #transcript.entries(), 1, -1 do
            local e = transcript.entries()[i]
            if e.role == "tool" then chosen = e; break end
        end
    end
    if not chosen then return end
    chosen.expand_state = entry_expanded(chosen) and "collapsed" or "expanded"
    touch_entry(chosen)
end

local function handle_ctrl(code, shift)
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
        -- Ctrl+O toggles the newest visible tool entry; Ctrl+Shift+O (or a
        -- terminal that cannot report Shift) keeps the expand-all meaning.
        if shift or (S.kb_protocol or 0) == 0 then
            toggle_all_entries()
        else
            toggle_newest_visible_tool()
        end
    elseif code == 20 then
        S.thinking_visible = not S.thinking_visible
        invalidate_all()
    elseif code == 21 then kill_to_start()
    elseif code == 23 then kill_word_before()
    elseif code == 18 then
        -- Ctrl+R: resume picker
        execute_command("resume")
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

-- 5.3: strip ANSI SGR sequences before copying (same pattern as vlen)
local function strip_sgr(s)
    if not s then return "" end
    return (s:gsub("\27%[[0-9;?]*[a-zA-Z]", ""))
end
M.strip_sgr = strip_sgr

-- Test seam: tests capture the copy payload via M._copy_hook instead of
-- relying on tether.write being alive after run_ui_with restores globals.
M._copy_hook = nil

local function copy_text(text)
    local payload = ESC .. "]52;c;" .. b64encode(strip_sgr(text)) .. string.char(7)
    if M._copy_hook then M._copy_hook(payload) end
    if tether and tether.write then w(payload) end
end

local function copy_last_assistant()
    local last_text = ""
    for i = #transcript.entries(), 1, -1 do
        local e = transcript.entries()[i]
        if e.role == "assistant" then
            last_text = e.text or ""
            break
        end
    end
    if last_text == "" then return end
    copy_text(last_text)
end

-- 5.1: copy targets from the transcript, newest-first; empty sources skipped
local function fenced_block_of(text)
    if not text then return "" end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local start_i
    for i = 1, #lines do
        if lines[i]:match("^%s*%`%`%`%s*([%w%_]*)%s*$") then
            start_i = i
            break
        end
    end
    if not start_i then return "" end
    local body = {}
    for i = start_i + 1, #lines do
        if lines[i]:match("^%s*%`%`%`%s*$") then
            return table.concat(body, "\n")
        end
        body[#body + 1] = lines[i]
    end
    -- unclosed fence at end of text: take what is open
    return table.concat(body, "\n")
end

function M.copy_targets(transcript)
    local t = transcript or {}
    local out = {}
    local function add(name, text)
        if text and text ~= "" then
            out[#out + 1] = { name = name, text = text, bytes = #text }
        end
    end
    -- last answer: last assistant entry
    for i = #t, 1, -1 do
        if t[i].role == "assistant" and (t[i].text or "") ~= "" then
            add("last answer", t[i].text)
            break
        end
    end
    -- last tool output: last tool entry with body
    for i = #t, 1, -1 do
        if t[i].role == "tool" then
            local body = t[i].body or t[i].text or ""
            if body ~= "" then add("last tool output", body) end
            break
        end
    end
    -- last fenced block, scanned from the newest entry
    for i = #t, 1, -1 do
        local fb = fenced_block_of(t[i].text)
        if fb ~= "" then add("last code block", fb); break end
    end
    -- whole transcript: entries in display order (source text, no SGR)
    local parts = {}
    for _, e in ipairs(t) do
        local txt
        if e.role == "tool" then
            txt = e.body or e.text or ""
        else
            txt = e.text or ""
        end
        if txt ~= "" then parts[#parts + 1] = txt end
    end
    add("whole transcript", table.concat(parts, "\n"))
    return out
end

-- ============================================================
-- add-ask-tool: the question block
-- ============================================================
-- The block owns the keyboard while it is open (handle_key dispatches here
-- before the input line), so nothing it does not use reaches the input field,
-- the palette or the transcript scroll. Two single-line editors run inside it —
-- the freeform answer and an option's note — and they only ever commit on
-- Enter; Esc closes the editor without cancelling the question set.

-- Ask/confirm key handling lives in ui_ask / ui_confirm (bag/deps); the
-- 2.2 key table owns the keyboard and calls through on_ask/on_confirmation
-- below. M._confirm_deps/M._ask_deps build the impure edge per call.
-- Phase B 2.2: handle_key routes through ui_keys.route/dispatch. These
-- are the facade callbacks, (bag, k)-shaped like the busy pump handlers;
-- bag is S (the facade's state upvalue does the work). Forward-declared:
-- routing order differs from lexical order (ctrl falls through to
-- palette/normal defined below).
local on_login_secret, on_confirmation, on_ask, on_error_dismiss, on_mouse
local on_ctrl_global, on_history, dispatch_palette, on_normal
local on_palette_copy, on_palette_resume, on_palette_model, on_palette_think
local on_palette_login, on_palette_logout, on_palette_logout_confirm
local on_palette_mention, on_palette_path, on_palette_command
local on_tab_complete, key_callbacks

handle_key = function(k)
    if not k then return end

    -- 5.4: one-shot toast — cleared by any keypress, no timer
    if S.toast then S.toast = nil end
    -- the switch is gone: route (order oracle in ui_keys) picks the key,
    -- the dispatch table picks the facade callback.
    local flags = { login_secret = S.login_secret, confirmation = S.confirmation,
        ask = S.ask, error_banner = S.error_banner,
        palette_active = S.palette_active, palette_mode = S.palette_mode,
        busy = S.busy }
    local key = M._keys.route(k, flags)
    local h = M._keys.dispatch[key]
    if h then h(S, key_callbacks, k) end
end

-- palette-only R5: secret entry owns the keyboard while active
-- (before confirmation/palette — S.login_secret is the mode flag).
on_login_secret = function(bag, k)
    if k.kind == "esc" then
        cancel_login()
        bump_transcript()
        return
    end
    if k.kind == "enter" then
        submit_login_secret(S.login_secret.buf or "")
        bump_transcript()
        return
    end
    if k.kind == "backspace" then
        local s = S.login_secret.buf or ""
        S.login_secret.buf = s:sub(1, math.max(0, #s - 1))
        return
    end
    if k.kind == "text" then
        S.login_secret.buf = (S.login_secret.buf or "") .. (k.char or "")
        return
    end
    if k.kind == "paste" then
        S.login_secret.buf = (S.login_secret.buf or "") .. (k.text or "")
        return
    end
    return -- swallow everything else while secret mode is open
end

on_confirmation = function(bag, k)
    M._confirm.handle_confirmation_key(S, M._confirm_deps(), k)
end

on_ask = function(bag, k)
    M._ask.handle_ask_key(S, M._ask_deps(), k)
end

on_error_dismiss = function(bag, k)
    -- palette-only R4: Enter/Esc dismiss the one-line error banner.
    -- A later Enter submits normally; full text lives in the debug log.
    S.error_banner = nil
end

on_mouse = function(bag, k)
        if k.name == "scroll_up" then
            S.scroll = S.scroll + 3
            S.user_scrolled = true
            return
        end
        if k.name == "scroll_down" then
            S.scroll = math.max(0, S.scroll - 3)
            if S.scroll == 0 then S.user_scrolled = false end
            return
        end
        if k.name == "press" then
            local L = layout()
            if S.palette_active and k.row >= L.palette_row + 1 then
                -- 2.5: hit-test through the window offset; the indicator row
                -- selects nothing; palette-hints: neither the blank nor the
                -- hint row does (they occupy the region's last two rows).
                local win, off = M._palette.window(L.h, #S.palette_items, S.palette_sel)
                local last = math.min(L.palette_row + win,
                    L.palette_row + L.palette_h - 2)
                if k.row <= last then
                    local it = S.palette_items[off + (k.row - L.palette_row) - 1]
                    if it then
                        if it.skill then
                            palette_pick_skill(it)
                        elseif it.cmd then
                            execute_command(it.cmd)
                        elseif S.palette_mode == "login" and it.label then
                            S.palette_active = false
                            S.palette_mode = "command"
                            S.palette_items = {}
                            S.palette_sel = 1
                            S._in_login_palette = nil
                            S.palette_query = nil
                            S._palette_all = nil
                            begin_login(it.label)
                            bump_transcript()
                        elseif S.palette_mode == "logout" and it.label then
                            -- logout-confirm D4: a click takes the same path as
                            -- Enter — it opens the deletion step, never deletes.
                            M._logout_ask_confirm(it.label)
                        elseif S.palette_mode == "logout-confirm" then
                            -- a click acts on the row it hit, like every other mode
                            if it.accept then
                                M._logout_confirm_accept()
                            else
                                M._logout_confirm_back()
                            end
                        elseif S.palette_mode == "resume" and it.id then
                            S.palette_active = false
                            S.palette_mode = "command"
                            S.palette_items = {}
                            S.palette_sel = 1
                            S._in_resume_palette = nil
                            pick.resume(it.id)
                            bump_transcript()
                        elseif S.palette_mode == "model" and it.label then
                            S.palette_active = false
                            S.palette_mode = "command"
                            S.palette_items = {}
                            S.palette_sel = 1
                            S._in_model_palette = nil
                            S.palette_query = nil
                            S._palette_all = nil
                            pick.model(it)
                            bump_transcript()
                        elseif S.palette_mode == "think" and it.label then
                            S.palette_active = false
                            S.palette_mode = "command"
                            S.palette_items = {}
                            S.palette_sel = 1
                            S._in_think_palette = nil
                            pick.think(it.label)
                        end
                    end
                    return
                end
                if k.row == L.palette_row + win + 1 then return end -- indicator row
            end
            -- 3.4: a left click toggles the tool entry under the pointer, but
            -- only where the mouse mode actually delivers transcript clicks.
            local mode = (S.cfg and S.cfg.ui and S.cfg.ui.mouse) or "auto"
            if mode == "on" and k.button == 0
                and k.row >= L.transcript_row
                and k.row <= L.transcript_row + L.transcript_h - 1 then
                local total = ensure_index(M._content_width(L.w))
                local bottom = math.min(total, total - S.scroll)
                if bottom < 1 then bottom = 1 end
                local top = bottom - L.transcript_h + 1
                if top < 1 then top = 1 end
                local idx = top + (k.row - L.transcript_row)
                local e = entry_at(idx)
                if e and e.role == "tool" then
                    e.expand_state = entry_expanded(e) and "collapsed" or "expanded"
                    touch_entry(e)
                end
                return
            end
        end
        return
end

on_ctrl_global = function(bag, k)
        -- Ctrl+Shift+C (kitty CSI-u / modifyOtherKeys) copies the last answer
        if k.code == 3 and k.shift then copy_last_assistant(); return end
        if k.code == 17 then S.quit = true; return end         -- Ctrl+Q
        if k.code == 3 then                                     -- Ctrl+C
            if S.busy then
                -- §6.6: first Ctrl+C aborts the stream, keeps received text;
                -- turn.abort() owns the flag — ui never assigns agent.abort_requested
                turn.abort()
                -- background children belong to the aborted turn too
                M._abort_bg("subagent cancelled")
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
        -- an unmatched ctrl code fell through in the switch: history? no
        -- (kind is ctrl, not special) — palette when open, else the normal
        -- chain lands on handle_ctrl for this same key.
        if S.palette_active then dispatch_palette(bag, k) else on_normal(bag, k) end
end

-- Ctrl+Up / Ctrl+Down — history recall. Decoder always sets k.ctrl for
-- kitty `CSI 1;5A`, modifyOtherKeys, and the bare `5;A` form.
on_history = function(bag, k)
        if k.name == "up" then history_prev() else history_next() end
end

on_palette_copy = function(bag, k)
            -- 5.2/5.3: copy palette — Enter copies via OSC 52 (SGR-stripped),
            -- Esc closes, up/down navigate; no fall-through for text keys.
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if it and it.copy then
                    copy_text(it.copy.text)
                    S.palette_active = false
                    S.palette_mode = "command"
                    S.palette_items = {}
                    S.palette_sel = 1
                    S._in_copy_palette = nil
                    -- spec tui: toast carries the copied size, ASCII twin uses [ok]
                    local sz = it.copy.bytes or #(it.copy.text or "")
                    local mark = M.ascii_active(S.cfg and S.cfg.ui and S.cfg.ui.ascii) and "[ok]" or "✓"
                    S.toast = mark .. " copied " .. tostring(sz) .. " B"
                    paint(true)
                end
                return
            elseif k.kind == "esc" then
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_copy_palette = nil
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            end
            return
end

on_palette_resume = function(bag, k)
            -- palette-only R2: session list — Enter resumes, Esc closes;
            -- no fall-through for text (list is modal while active).
            local function close_resume_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_resume_palette = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                close_resume_palette()
                if it and it.id then
                    pick.resume(it.id)
                end
                return
            elseif k.kind == "esc" then
                close_resume_palette()
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            end
            return
end

on_palette_model = function(bag, k)
            -- palette-only R2: model list — Enter applies, Esc closes;
            -- no fall-through for text (list is modal while active).
            local function close_model_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_model_palette = nil
                S.palette_query = nil
                S._palette_all = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if not it then return end
                close_model_palette()
                if it and it.label then
                    pick.model(it)
                end
                return
            elseif k.kind == "esc" then
                if (S.palette_query or "") ~= "" then
                    S.palette_query = ""
                    M._palette_apply_query()
                    return
                end
                close_model_palette()
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            elseif k.kind == "text" then
                S.palette_query = (S.palette_query or "") .. (k.char or "")
                M._palette_apply_query()
                return
            elseif k.kind == "backspace" then
                S.palette_query = (S.palette_query or ""):sub(1, math.max(0, #(S.palette_query or "") - 1))
                M._palette_apply_query()
                return
            elseif k.kind == "paste" then
                S.palette_query = (S.palette_query or "") .. (k.text or "")
                M._palette_apply_query()
                return
            end
            return
end

on_palette_think = function(bag, k)
            -- add-reasoning-level: level picker — Enter applies, Esc closes;
            -- no fall-through for text (list is modal while active).
            local function close_think_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_think_palette = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                close_think_palette()
                if it and it.label then
                    pick.think(it.label)
                end
                return
            elseif k.kind == "esc" then
                close_think_palette()
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            end
            return
end

on_palette_login = function(bag, k)
            -- add-provider-login: bare /login provider picker — same palette
            -- mechanism as the slash menu / /copy; Enter starts the dialog.
            local function close_login_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_login_palette = nil
                S.palette_query = nil
                S._palette_all = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if not it then return end
                close_login_palette()
                if it and it.label then
                    begin_login(it.label)
                    bump_transcript()
                end
                return
            elseif k.kind == "esc" then
                if (S.palette_query or "") ~= "" then
                    S.palette_query = ""
                    M._palette_apply_query()
                    return
                end
                close_login_palette()
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            elseif k.kind == "text" then
                S.palette_query = (S.palette_query or "") .. (k.char or "")
                M._palette_apply_query()
                return
            elseif k.kind == "backspace" then
                S.palette_query = (S.palette_query or ""):sub(1, math.max(0, #(S.palette_query or "") - 1))
                M._palette_apply_query()
                return
            elseif k.kind == "paste" then
                S.palette_query = (S.palette_query or "") .. (k.text or "")
                M._palette_apply_query()
                return
            end
            return
end

on_palette_logout = function(bag, k)
            -- logout-picker: stored-credentials picker — Enter opens the
            -- confirmation step (nothing is deleted from the list); Esc is
            -- two-stage and Enter dead on no match, like model/login.
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if not it then return end
                M._logout_ask_confirm(it.label)
                return
            elseif k.kind == "esc" then
                if (S.palette_query or "") ~= "" then
                    S.palette_query = ""
                    M._palette_apply_query()
                    return
                end
                M._logout_close()
                return
            elseif k.kind == "special" then
                local n = #S.palette_items
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                return
            elseif k.kind == "text" then
                S.palette_query = (S.palette_query or "") .. (k.char or "")
                M._palette_apply_query()
                return
            elseif k.kind == "backspace" then
                S.palette_query = (S.palette_query or ""):sub(1, math.max(0, #(S.palette_query or "") - 1))
                M._palette_apply_query()
                return
            elseif k.kind == "paste" then
                S.palette_query = (S.palette_query or "") .. (k.text or "")
                M._palette_apply_query()
                return
            end
            return
end

on_palette_logout_confirm = function(bag, k)
            -- logout-confirm D2: the deletion step. No filter buffer, so text
            -- keys are the two choices rather than query characters, and every
            -- key this mode does not use is swallowed instead of leaking into
            -- the input or back into the list's query.
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if not it then return end
                if it.accept then
                    M._logout_confirm_accept()
                else
                    M._logout_confirm_back()
                end
                return
            elseif k.kind == "esc" then
                M._logout_confirm_back()
                return
            elseif k.kind == "text" then
                local c = (k.char or ""):lower()
                if c == "y" then
                    M._logout_confirm_accept()
                elseif c == "n" then
                    M._logout_confirm_back()
                end
                return
            elseif k.kind == "special" then
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" then
                    S.palette_sel = math.min(#S.palette_items, S.palette_sel + 1)
                end
                return
            end
            return
end

on_palette_mention = function(bag, k)
            -- at-file-picker: the "@" preview. Arrows move the highlight, the
            -- input only changes through the user's own keystrokes, and both
            -- Enter and Tab insert the highlighted path.
            if k.kind == "tab" then
                M._mention_accept()
                return
            elseif k.kind == "special"
                and (k.name == "up" or k.name == "down") then
                local n = #S.palette_items
                if n > 0 then
                    if k.name == "up" then
                        S.palette_sel = math.max(1, S.palette_sel - 1)
                    else
                        S.palette_sel = math.min(n, S.palette_sel + 1)
                    end
                    if S.completion then S.completion.sel = S.palette_sel end
                end
                return
            elseif k.kind == "special" then
                -- cursor keys and Delete still edit: the preview lives as long
                -- as the user types, so it must not lock the input.
                if k.name == "left" or k.name == "right" or k.name == "home"
                    or k.name == "end" or k.name == "delete" then
                    handle_special(k)
                    M._mention_refilter()
                end
                return
            elseif k.kind == "enter" then
                M._mention_accept()
                return
            elseif k.kind == "esc" then
                M._picker_close()
                return
            elseif k.kind == "text" then
                input_insert(k.char)
                M._mention_refilter()
                return
            elseif k.kind == "backspace" then
                input_backspace()
                M._mention_refilter()
                return
            elseif k.kind == "paste" then
                input_insert(k.text or "")
                M._mention_refilter()
                return
            end
            return
end

on_palette_path = function(bag, k)
            -- 4.2/4.3: path palette — Tab cycles, Esc restores the token as
            -- typed, Enter commits the selected path; text/backspace keep the
            -- applied text, clear the cycle state, and fall through below.
            if k.kind == "tab" then
                local comp = S.completion or {}
                local n = #S.palette_items
                if n > 0 then
                    S.palette_sel = (S.palette_sel % n) + 1
                    comp.sel = S.palette_sel
                    S.completion = comp
                    M._complete.completion_apply(S, S.palette_items[S.palette_sel].label)
                end
                return
            elseif k.kind == "esc" then
                M._complete.completion_cancel(S, M._complete_deps())
                return
            elseif k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if it then
                    S.input = it.label .. " "
                    S.cursor = #S.input
                    M._complete.completion_commit(S, M._complete_deps())
                end
                return
            elseif k.kind == "special" then
                local n = #(S.completion and S.completion.items or S.palette_items)
                if k.name == "up" then
                    S.palette_sel = math.max(1, S.palette_sel - 1)
                elseif k.name == "down" and n > 0 then
                    S.palette_sel = math.min(n, S.palette_sel + 1)
                end
                if S.completion then S.completion.sel = S.palette_sel end
                return
            end
            -- text/backspace in the path palette: keep the applied text,
            -- clear the cycle state; re-run palette_sync() so the command
            -- palette reopens if the user typed /, otherwise the palette
            -- stays closed. No fall-through (would double-fire input_insert).
            M._complete.completion_commit(S, M._complete_deps())
            palette_sync()
end

on_palette_command = function(bag, k)
            -- command palette (existing behavior, 3.3/3.4/3.5)
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if it then
                    -- 4.1: a skill row composes text; a command row runs
                    if it.skill then palette_pick_skill(it) else execute_command(it.cmd) end
                end
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
            -- fall through for text/backspace so the normal chain runs
            -- (input_insert + mention refilter), as the switch did.
            on_normal(bag, k)
end

-- Mode fan-out for the palette stages (called with palette_active set;
-- unknown modes fall to the command palette, as the switch's else did).
dispatch_palette = function(bag, k)
    local mode = S.palette_mode or "command"
    if mode == "copy" then on_palette_copy(bag, k)
    elseif mode == "resume" then on_palette_resume(bag, k)
    elseif mode == "model" then on_palette_model(bag, k)
    elseif mode == "think" then on_palette_think(bag, k)
    elseif mode == "login" then on_palette_login(bag, k)
    elseif mode == "logout" then on_palette_logout(bag, k)
    elseif mode == "logout-confirm" then on_palette_logout_confirm(bag, k)
    elseif mode == "mention" then on_palette_mention(bag, k)
    elseif mode == "path" then on_palette_path(bag, k)
    else on_palette_command(bag, k) end
end

-- 4.2: Tab outside an open palette runs path completion (4.3: gated)
on_tab_complete = function(bag, k)
    M._complete.path_complete_tab(S, M._complete_deps())
end

on_normal = function(bag, k)
    if k.kind == "paste" then
        local text = k.text or ""
        -- T176: step by UTF-8 chars, not bytes — a byte loop split
        -- multibyte chars into invalid fragments (same crash as typed input).
        local i = 1
        while i <= #text do
            if text:sub(i, i) == "\n" then
                S.input = S.input .. "\n"
                i = i + 1
            else
                local ni = M._step_char(text, i)
                input_insert(text:sub(i, ni - 1))
                i = ni
            end
        end
        S.cursor = #S.input
    elseif k.kind == "text" then
        -- at-file-picker: "@" at a token start opens the file preview; while a
        -- preview session lives, every further character re-filters it.
        local trigger = k.char == "@" and not S.palette_active
            and M._at_token_start()
        input_insert(k.char)
        if trigger then
            M._mention_open()
        elseif S.completion and S.completion.mention then
            M._mention_refilter()
        end
    elseif k.kind == "enter" then
        if S.busy and not S.confirmation and not S.ask then
            enqueue_busy("steer")
        else
            commit_input()
        end
    elseif k.kind == "newline" then
        if S.busy and k.alt and not S.confirmation and not S.ask then
            enqueue_busy("followup")
        else
            input_insert("\n")
        end
    elseif k.kind == "backspace" then
        input_backspace()
        if S.completion and S.completion.mention then M._mention_refilter() end
    elseif k.kind == "esc" then
        if S.busy and ((S.steer_queue and #S.steer_queue > 0)
            or (S.followup_queue and #S.followup_queue > 0)) then
            turn.abort()
            restore_queues()
        else
            input_clear()
        end
    elseif k.kind == "ctrl" then handle_ctrl(k.code, k.shift)
    elseif k.kind == "special" then handle_special(k)
    end
end

-- The callback table ui_keys.dispatch forwards to (bag is S). Normal
-- kinds share on_normal's internal chain; palette modes fan out by name.
key_callbacks = {
    login_secret = on_login_secret,
    confirmation = on_confirmation,
    ask = on_ask,
    error_dismiss = on_error_dismiss,
    mouse = on_mouse,
    ctrl = on_ctrl_global,
    history = on_history,
    tab_complete = on_tab_complete,
    palette = {
        copy = on_palette_copy,
        resume = on_palette_resume,
        model = on_palette_model,
        think = on_palette_think,
        login = on_palette_login,
        logout = on_palette_logout,
        logout_confirm = on_palette_logout_confirm,
        mention = on_palette_mention,
        path = on_palette_path,
        command = on_palette_command,
    },
    normal = {
        paste = on_normal, text = on_normal, enter = on_normal,
        newline = on_normal, backspace = on_normal, esc = on_normal,
        ctrl = on_normal, special = on_normal, tab = on_normal,
        alt = on_normal,
    },
}

M._handle_key = function(k) if S then handle_key(k) end end
-- handle_key routes through ui_keys.route/dispatch (M._keys loader above);
-- tests drive the ui_keys module directly.

-- ============================================================
-- Main
-- ============================================================
-- app_cfg is the already-loaded config from app.run (carries _session_id,
-- CLI overrides and agents-files). Without it (tests/dev) load fresh.
function M.run(app_cfg)
    S = new_state()
    transcript.clear()
    M._byte_stash = {} -- drop any truncated-UTF-8 lookahead from a past run
    M._esc_stash_s = nil

    S.cfg = app_cfg or (config and config.load and config.load()) or {}
    S.model_name = S.cfg.model or "gpt-4o-mini"
    S.workspace  = S.cfg.workspace or tether.getcwd()
    if config and config.api_key then
        S.cfg.api_key = config.api_key(S.cfg)
        S.api_key = S.cfg.api_key
    end
    S.debug = S.cfg.debug or false
    -- F3: token budget percent must follow the configured budget
    S.tokens_max = (S.cfg.context and S.cfg.context.max_tokens) or 32768
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

    -- splash-colors: version and startup resources back the splash block;
    -- /clear and /new re-render it from these, so they stay fixed here.
    S.version = "v0.1.0"
    S.splash_resources = M._collect_splash_resources()

    local size = tether.get_terminal_size()
    if size then S.w, S.h = size.width, size.height end

    -- Session arrives via app_cfg (fresh resume or nil); a brand-new one is
    -- minted lazily by the first turn, never at startup.
    if S.cfg._session_id then
        S.session_id = S.cfg._session_id
    else
        S.session_id = "?"
    end

    -- Resume (-r): app.lua restored the agent history, but the transcript
    -- starts empty — seed it so the user sees what the model knows. The
    -- seed prefers the resume messages over the history: history carries
    -- no thinking blocks and tool rows without args.
    if agent and agent.get_history then
        local src_msgs = S.cfg and S.cfg._resume_messages
        if src_msgs == nil then
            local okh, hist = pcall(agent.get_history)
            if okh and hist then src_msgs = hist end
        end
        if src_msgs then
            local seeded = transcript.seed(src_msgs)
            if #seeded > 0 then
                -- restored history keeps its order; the splash stays first,
                -- like a fresh start that already knows the conversation.
                table.insert(seeded, 1, M._splash_entry())
                transcript.reset(seeded)
                transcript.append(
                    { role = "system", text = "↻ session resumed" })
            else
                reset_transcript({ M._splash_entry() })
            end
        else
            reset_transcript({ M._splash_entry() })
        end
    end

    -- M8/R8: mouse tracking is emitted dynamically on state transitions
    -- (mouse_update_tracking in the main loop), not statically at startup.
    -- T48: alt-screen on by default (fullscreen TUI; shell scrollback no
    -- longer bleeds through on transcript scroll) — cfg.ui.alt_screen=false
    -- opts back out; paired leave on exit below.
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
    -- Enable the protocol we detected, so modified keys arrive in a form the
    -- parser understands: kitty pushes flag 1 (disambiguate escape codes),
    -- xterm-alikes get modifyOtherKeys=2. Both are restored on exit below.
    -- (kitty keeps a separate flag stack per screen, so the push happens after
    -- entering the alternate screen and the pop before leaving it.)
    if S.kb_protocol == 1 then
        w(ESC .. "[>1u")
    elseif S.kb_protocol == 2 then
        w(ESC .. "[>4;2m")
    end

    load_history()
    palette_sync()
    redraw()

    -- The waits that still block the loop (tether.exec while a tool runs,
    -- http_get, the blocking transport/sleep fallbacks) call back into the
    -- TUI on their own quantum; bind the spinner tick for them for as long
    -- as this loop runs. The turn path itself rides the reactor's on_tick.
    if tether.set_tick_hook then tether.set_tick_hook(M._spinner_tick) end

    -- expand-provider-catalog: a background model refresh may have
    -- landed (fetch_bg child wrote the pending file). Rebuild the open
    -- /model palette in place; otherwise the next open picks it up.
    -- M-field (not a run() local): M.run sits at Lua's 200-locals limit.
    function M._poll_models_bg()
        if not (S._models_bg and commands and commands.poll_models_refresh) then
            return
        end
        local st = commands.poll_models_refresh(S.cfg, S._models_bg)
        if st == "updated" then
            if S.palette_mode == "model" and S.palette_active then
                local models, _, merr = nil, nil, nil
                if commands.list_models_all then
                    local ok, m, _, e = pcall(commands.list_models_all, S.cfg)
                    if ok then models, merr = m, e end
                end
                if models == nil then
                    models, _, merr = commands.list_models(S.cfg, S.api_key or "")
                end
                S._palette_all = M._build_model_items(models)
                M._palette_apply_query()
                local n = #S.palette_items
                if (S.palette_sel or 1) > n and n > 0 then
                    S.palette_sel = n
                end
                -- a still-empty palette keeps explaining itself.
                S._models_err = (n == 0) and merr or nil
                if S._models_err then S.error_banner = S._models_err end
            end
            S._models_bg = nil
        elseif st == "settled" then
            S._models_bg = nil
        end
    end

    -- The main loop belongs to the reactor: one poll over stdin, transport
    -- sockets and timers drives the stdin drain, per-tick work and future
    -- transport sources. Nothing here blocks: keys dispatch on the tick
    -- they arrive, whether a turn runs or not.
    -- M-field (not a run() local): M.run sits at Lua's 200-locals limit.
    M._loop = M._reactor.new({
        poll = function(rfds, wfds, timeout)
            return tether.poll(rfds, wfds, timeout)
        end,
        clock = function()
            return (tether.monotonic_ms and tether.monotonic_ms()) or 0
        end,
    })
    M._loop:on_stdin(function()
        local n = 0
        while true do
            local k = read_key_nb()
            if not k then break end
            n = n + 1
            handle_key(k)
            if S.quit then M._loop:stop(); break end
        end
        if n > 0 then paint(true) end
        -- a stashed escape prefix means bytes were consumed for an
        -- incomplete sequence: not EOF, the tail is still coming
        if n == 0 and #M._byte_stash > 0 then n = 1 end
        return n
    end)
    M._loop:on_eof(function()
        S.quit = true
        M._loop:stop()
    end)
    M._loop:on_tick(function()
        M._poll_models_bg()
        M._poll_subagents_bg()
        -- a Ctrl+Q raised by the host while a turn blocked: the turn has
        -- unwound by now, so this is the exit the keystroke asked for
        if tether.quit_requested() then S.quit = true end
        if tether.resize_requested() then
            local sz = tether.get_terminal_size()
            if sz then S.w, S.h = sz.width, sz.height end
            S.screen = {}
        end
        mouse_update_tracking() -- M8/R8: ?1000h/?1006h on state change only
        if S.busy then
            -- the turn nests into this loop (streamed attempts, backoff
            -- deadlines), so the spinner cadence rides the tick itself; the
            -- host hook bound in run() covers the waits that still block it
            M._spinner_tick()
        else
            -- a stashed escape prefix gets its retry here when no turn runs:
            -- the stdin drain fires only on fresh bytes, so without it a
            -- lone Esc would wait for the next keypress
            if #M._byte_stash > 0 and M._drain_stash() > 0 then paint(true) end
            paint(false) -- throttled; picks up bg/resize/mouse changes
        end
        if S.quit then M._loop:stop() end
    end)
    -- A turn started from the stdin dispatch parks the loop inside its own
    -- tick; the synchronous callers (api.stream between steps, the agent's
    -- backoff deadline) find this loop through the module and pump it
    -- nested instead of blocking the OS thread.
    -- Background subagent harvest (async-subagents): progress tails plus
    -- pickup, every tick. Completions only arm the deferred wake drained
    -- after the tick — a turn never starts inside dispatch (see design).
    function M._poll_subagents_bg()
        if not S then return end
        local sm = rawget(_G, "subagent")
        if sm and sm.running_tails then
            for _, t in ipairs(sm.running_tails()) do
                handle_agent_event({ type = "tool_progress",
                    id = t.id, tail = t.tail })
            end
        end
        if agent and agent.poll_background then
            local completed = agent.poll_background(S.cfg, handle_agent_event)
            if #completed > 0 then
                debug_log("bg: picked up " .. #completed .. " child(ren)")
                S._bg_wake_pending = true
            end
        end
    end

    -- Deferred wake past the tick dispatch: completions start the
    -- continuation carrying fresh results when idle; while a turn runs
    -- the wake parks in the queue drained on the next idle tick; on
    -- quit or abort everything is dropped (3.2/3.3 own the abort path).
    function M._drain_bg_wake()
        if not S then return end
        if S.quit then
            S._bg_wake_pending = nil
            S._bg_wake_queued = nil
            return
        end
        if S.busy then
            if S._bg_wake_pending then
                S._bg_wake_queued = true
                S._bg_wake_pending = nil
            end
            return
        end
        if S._bg_wake_pending or S._bg_wake_queued then
            S._bg_wake_pending = nil
            S._bg_wake_queued = nil
            debug_log("bg: waking turn for finished child")
            turn.continue(S, S.cfg, S.api_key or "", handle_agent_event)
        end
    end

    -- Abort owns background children too: kill the registry, collapse rows,
    -- record cancellations, drop pending wakes.
    function M._abort_bg(reason)
        if agent and agent.cancel_background then
            agent.cancel_background(S and S.cfg, reason or "subagent cancelled",
                handle_agent_event)
        end
        if S then
            S._bg_wake_pending = nil
            S._bg_wake_queued = nil
        end
    end

    M._reactor.set_active(M._loop)
    -- Loop errors surface as the error banner, not as a stderr dump that
    -- kills the session: a tick that raises is reported in place and the
    -- next tick keeps the TUI live (the banner clears on the next Enter/Esc).
    while not M._loop:stopped() do
        local ok, err = pcall(M._loop.tick, M._loop)
        if not ok and not M._loop:stopped() then
            S.error_banner = tostring(err or "unknown error")
        end
        -- deferred background wake: completions picked up on the tick start
        -- their continuation here, past dispatch, never nested inside it.
        local wok, werr = pcall(M._drain_bg_wake)
        if not wok and not M._loop:stopped() then
            S.error_banner = tostring(werr or "unknown error")
        end
    end
    M._reactor.set_active(nil)
    M._loop = nil

    -- quitting owns background children too: kill, collapse, record.
    M._abort_bg("subagent cancelled")

    if debug_log_fh then
        pcall(function() debug_log_fh:close() end)
        debug_log_fh = nil
    end
    if tether.set_tick_hook then tether.set_tick_hook(nil) end
    -- Restore the keyboard protocol while the alternate screen (and with it
    -- kitty's own flag stack) is still current, then leave alt-screen.
    if S.kb_protocol == 1 then
        w(ESC .. "[<u")
    elseif S.kb_protocol == 2 then
        w(ESC .. "[>4;0m")
    end
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
-- M8/R8 + TW1: auto keeps mouse tracking always on inside alt-screen. The
-- wheel must scroll the transcript: with tracking off, terminals translate
-- wheel ticks into Up/Down arrows — which recall input history, so a wheel
-- tick pasted history into the field. "selection" keeps native selection
-- (tracking off); in "on"/"auto" hold Shift to select natively.
function M.mouse_wants(mode, state)
    mode = mode or "auto"
    state = state or {}
    if mode == "on" then return true end
    if mode == "off" or mode == "selection" then return false end
    -- auto: wheel capture is the point — always track
    return true
end

return M
