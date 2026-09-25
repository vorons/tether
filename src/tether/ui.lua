-- tether / ui.lua — TUI with line-diff redraw.
local M = {}

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

-- M8/R1: glyph → ASCII mapping (single pass, longest-first via explicit scan).
-- The spec promises TERM=dumb renders pure ASCII; the old code only stripped
-- ANSI colors, leaving box-drawing and emoji-width glyphs to break layout.
local GLYPH_MAP = {
    ["●"] = "*", ["•"] = "*", ["⚙"] = "[t]", ["›"] = ">", ["✗"] = "[x]", ["✓"] = "[ok]", ["✻"] = "*",
    ["↻"] = "[r]", ["⏹"] = "[x]", ["⚠"] = "!", ["▸"] = ">", ["▾"] = "v",
    ["┌"] = "+", ["┐"] = "+", ["└"] = "+", ["┘"] = "+", ["─"] = "-",
    ["│"] = "|", ["•"] = "-", ["…"] = "...", ["▓"] = "#", ["░"] = "-", ["━"] = "#",
    ["↑"] = "^", ["↓"] = "v", ["←"] = "<", ["→"] = ">",
    ["·"] = "-",
    -- add-ask-tool: the question block's glyphs (note marker, quoted freeform)
    ["↳"] = "->", ["«"] = '"', ["»"] = '"',
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
        -- 7.1: syntax roles (token kinds); default to 16-color codes so
        -- truecolor/256 render with the same palette. ponytail: no brighter
        -- per-depth variants; add one if a 256-color theme gets complaints.
        comment = "2;38", string = "32", number = "33", keyword = "36;1",
        code = "35", heading = "36;1",
    },
    solarized = {
        accent = "36", warn = "33", error = "31", success = "32",
        dim = "2", italic = "3", reverse = "7", bold = "1",
        comment = "2;38", string = "32", number = "33", keyword = "36",
        code = "35", heading = "36;1",
    },
    mono = {}, -- every role missing ⇒ no SGR emitted
}
local _theme_name = "default"

-- M8/R2: wrap toggle (cfg.ui.wrap); false = truncate to width instead.
local _wrap_enabled = true

-- M8/R2: role-based color — theme table drives the code; missing role in a
-- theme (e.g. mono) returns the raw text with no SGR at all; depth
-- "none" (ASCII/NO_COLOR/dumb) also forces raw text (7.1: never highlight),
-- still mapping the glyphs (to_ascii) so ASCII mode stays pure ASCII.
local function sgr_role(role, s)
    local theme = THEMES[_theme_name] or THEMES.default
    if M.color_depth() == "none" then return to_ascii(s) end
    local code = theme[role]
    if not code then return to_ascii(s) end
    return sgr(code, s)
end

-- Role helpers: every UI color goes through the active theme, so selecting
-- `mono` really drops all color and `solarized` re-tints the whole interface
-- (previously these helpers emitted fixed SGR codes and ignored the theme).
local function cyan(s)   return sgr_role("accent",  s) end
local function yellow(s) return sgr_role("warn",    s) end
local function red(s)    return sgr_role("error",   s) end
local function green(s)  return sgr_role("success", s) end
local function dim(s)    return sgr_role("dim",     s) end
local function italic(s) return sgr_role("italic",  s) end
local function rev(s)    return sgr_role("reverse", s) end

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
-- M8 fix: utf8.sub does NOT exist in the Lua 5.4 stdlib (it worked only
-- inside the embedded binary if it defined one; plain lua crashed).
-- Build char-index slicing on char boundaries instead. T176: step_char-based
-- so a stray byte can never raise "invalid UTF-8 code" (utf8.offset does).
local function usub(s, i, j)
    j = j or -1
    local bounds = {}
    local k = 1
    while k <= #s do
        bounds[#bounds + 1] = k
        k = M._step_char(s, k)
    end
    local n = #bounds
    if i < 0 then i = n + i + 1 end
    if j < 0 then j = n + j + 1 end
    if i < 1 then i = 1 end
    if j > n then j = n end
    if i > j or n == 0 then return "" end
    local start = bounds[i]
    local stop = (j + 1 <= n) and (bounds[j + 1] - 1) or #s
    return s:sub(start, stop)
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
            -- 7.4: cut at a display-width boundary; drop any SGR sequence
            -- dangling past the cut (usub can split one mid-escape, which
            -- would leave \27[3 bytes that are not a full SGR and break
            -- the strip-invariant).
            local cut = usub(para, 1, width - 1)
            cut = cut:gsub("\27%[[0-9;?]*[^a-zA-Z]", ""):gsub("\27$", "")
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
-- tokenize_line(line, lang, state) → ordered {text, kind} tokens, kind in
-- {comment, string, number, keyword, plain}. `state` is an in/out table
-- (one per fence block): state.bc = inside /* */ , state.str = open triple
-- quote (python). Unknown lang → single plain token (7.5).
local function _kwset(list)
    local s = {}
    for _, w in ipairs(list) do s[w] = true end
    return s
end
local HL_LANGS = {
    lua = { lc = "--", kw = _kwset({"local","function","end","return","if","then","else","elseif","for","while","do","in","nil","true","false","repeat","until","not","and","or","break"}) },
    c   = { lc = "//", bo = "/*", bc = "*/", kw = _kwset({"int","char","void","if","else","for","while","do","return","static","const","struct","typedef","sizeof","unsigned","long","float","double","switch","case","break","continue","sizeof"}) },
    sh  = { lc = "#", kw = _kwset({"if","then","else","fi","for","do","done","while","case","esac","function","local","return","echo","export","set","readonly"}) },
    python = { lc = "#", triple = true, kw = _kwset({"def","return","if","else","elif","for","while","import","from","as","class","try","except","finally","with","in","not","and","or","None","True","False","lambda","pass","yield","global","assert","raise","print","len"}) },
    js  = { lc = "//", bo = "/*", bc = "*/", kw = _kwset({"var","let","const","function","return","if","else","for","while","class","new","export","import","from","async","await","true","false","null","undefined","of","in","typeof"}) },
    go  = { lc = "//", bo = "/*", bc = "*/", kw = _kwset({"func","package","return","if","else","for","range","go","defer","chan","map","type","struct","interface","var","const","true","false","nil","error","len","make"}) },
    rust = { lc = "//", bo = "/*", bc = "*/", kw = _kwset({"fn","let","mut","if","else","for","while","match","return","impl","trait","pub","use","mod","struct","enum","const","true","false","loop","async","await","where","crate","self","move","dyn"}) },
    json = { kw = _kwset({"true","false","null"}) },
}
HL_LANGS.h = HL_LANGS.c
HL_LANGS.bash = HL_LANGS.sh
HL_LANGS.ts = HL_LANGS.js
-- common aliases (spec delta): share the canonical tokenizer/table
HL_LANGS.javascript, HL_LANGS.tsx, HL_LANGS.jsx = HL_LANGS.js, HL_LANGS.js, HL_LANGS.js
HL_LANGS.py = HL_LANGS.python
HL_LANGS.shell, HL_LANGS.zsh = HL_LANGS.sh, HL_LANGS.sh
HL_LANGS["c++"], HL_LANGS.cpp, HL_LANGS.cc, HL_LANGS.cxx = HL_LANGS.c, HL_LANGS.c, HL_LANGS.c, HL_LANGS.c
HL_LANGS.rs = HL_LANGS.rust
HL_LANGS.golang = HL_LANGS.go
-- supported languages with no keyword set: string literals and numbers only
HL_LANGS.yaml = { kw = _kwset({}), strq = { "'", '"' } }
HL_LANGS.yml, HL_LANGS.rb = HL_LANGS.yaml, HL_LANGS.yaml
-- string quotes per language family
HL_LANGS.c.strq, HL_LANGS.h.strq = { '"', "'" }, { '"', "'" }
HL_LANGS.go.strq = { '"', "'", '`' }
HL_LANGS.js.strq, HL_LANGS.ts.strq = { "'", '"', "`" }, { "'", '"', "`" }
HL_LANGS.rust.strq = { "'", '"' }
HL_LANGS.lua.strq = { "'", '"' }
HL_LANGS.sh.strq, HL_LANGS.bash.strq = { "'", '"' }, { "'", '"' }
HL_LANGS.python.strq = { "'", '"' }
HL_LANGS.json.strq = { '"' }

function M.tokenize_line(line, lang, state)
    lang = lang and lang:lower()
    local L = lang and HL_LANGS[lang]
    if not L then return {{ text = line, kind = "plain" }} end
    state = state or {}
    local toks, n, i = {}, #line, 1
    local buf = {}
    local function flush()
        if #buf > 0 then toks[#toks + 1] = { text = table.concat(buf), kind = "plain" } end
        buf = {}
    end
    local function add(kind, t) if t ~= "" then toks[#toks + 1] = { text = t, kind = kind } end end
    local strq = L.strq or { "'", '"' }
    while i <= n do
        local c = line:sub(i, i)
        local closed, j, q
        -- open/continue triple-quoted string (python)
        if L.triple and (state.str or line:sub(i, i + 2):match("^[[\"']{3}$")) then
            local tri = state.str or line:sub(i, i + 2)
            local start = state.str and i or i + 3
            local cclose = line:find(tri, start, true)
            if cclose then
                flush()
                add("string", line:sub(i, cclose + 2))
                state.str = nil; i = cclose + 3
            else
                flush()
                add("string", line:sub(i))
                state.str = tri; i = n + 1
            end
        else
            local consumed = false
            -- block comment (c/js/go/rust family)
            if L.bo then
                if state.bc then
                    cclose = line:find(L.bc, i, true)
                    if cclose then
                        add("comment", line:sub(i, cclose + #L.bc - 1)); state.bc = nil; i = cclose + #L.bc
                    else
                        add("comment", line:sub(i)); i = n + 1
                    end
                    consumed = true
                elseif line:sub(i, i + #L.bo - 1) == L.bo then
                    flush()
                    cclose = line:find(L.bc, i + #L.bo, true)
                    if cclose then
                        add("comment", line:sub(i, cclose + #L.bc - 1)); i = cclose + #L.bc
                    else
                        add("comment", line:sub(i)); state.bc = true; i = n + 1
                    end
                    consumed = true
                end
            end
            if not consumed then
                -- line comment
                if L.lc and line:sub(i, i + #L.lc - 1) == L.lc then
                    flush(); add("comment", line:sub(i)); i = n + 1; consumed = true
                elseif c:match("[%\"']") then
                    local qmatch = strq[1]
                    for _, qq in ipairs(strq) do if c == qq then qmatch = qq; break end end
                    if c == qmatch then
                        flush()
                        j = i + 1
                        closed = false
                        while j <= n do
                            local cj = line:sub(j, j)
                            if cj == "\\" then j = j + 2
                            elseif cj == qmatch then closed = true; break
                            else j = j + 1 end
                        end
                        if closed then add("string", line:sub(i, j)); i = j + 1; consumed = true
                        else add("string", line:sub(i)); i = n + 1; consumed = true end
                    end
                end
            end
            if not consumed and c:match("%d") then
                local num
                if c == "0" and line:sub(i + 1, i + 1):lower() == "x" then
                    num = line:match("0[xX][%a%d_]*", i)
                else
                    num = line:match("%d+", i)
                end
                if num and num ~= "." then
                    flush(); add("number", num); i = i + #num; consumed = true
                end
            end
            if not consumed and c:match("[%a_]\z") then
                local w = line:match("^[%a_][%a%d_]*", i)
                if w then
                    if L.kw[w] then flush(); add("keyword", w)
                    else buf[#buf + 1] = w end
                    i = i + #w; consumed = true
                end
            end
            if not consumed then
                buf[#buf + 1] = c; i = i + 1
            end
        end
    end
    flush()
    return toks
end

-- 7.3: render a source line as SGR-colored text (token-scoped SGR wraps, so
-- the existing SGR-aware wrap() can split it at any char boundary later).
-- Plain tokens emit no SGR at all (default foreground).
local HL_ROLE = { comment = "comment", string = "string", number = "number", keyword = "keyword" }
function M.highlight_line(line, lang, state)
    local toks = M.tokenize_line(line, lang, state)
    local out = {}
    for _, t in ipairs(toks) do
        local role = HL_ROLE[t.kind]
        -- 7.4: mono theme ⇒ sgr_role returns the raw token (roles missing),
        -- so the strip-invariant is byte-exact even when roles are requested.
        if role then out[#out + 1] = sgr_role(role, t.text)
        else out[#out + 1] = t.text end
    end
    return table.concat(out)
end

local function md_render(text, width, ansi_fn)
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
            local hl_state = HL_LANGS[lang:lower()] and highlight_enabled() and {} or nil
            i = i + 1
            -- continuation indent needs room; absurdly narrow frames fall
            -- back to plain wrapping with no indent
            local cpre, cw = "  ", inner - 2
            if inner < 4 then cpre, cw = "", inner end
            while i <= #lines and not lines[i]:match("^%s*%`%`%`%s*$") do
                local body_line = lines[i]
                if hl_state then
                    body_line = M.highlight_line(body_line, lang, hl_state)
                end
                for _, seg in ipairs(wrap_words(body_line, inner, cpre, cw)) do
                    out[#out + 1] = dim(box.v) .. " " .. seg
                        .. string.rep(" ", math.max(inner - vlen(seg), 0)) .. " " .. dim(box.v)
                end
                i = i + 1
            end
            out[#out + 1] = dim(box.bl .. string.rep(box.h, inner + 2) .. box.br)
            i = i + 1 -- skip closing fence (or last line)
        elseif line:match("^%s*|") then
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
                    cells[#cells + 1] = md_strip_inline(chunk, ansi_fn)
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
                    if vlen(rule) > width then rule = rule:sub(1, width) end
                    out[#out + 1] = rule
                else
                    local cells = {}
                    for c = 1, ncol do
                        local cell = r[c] or ""
                        cells[#cells + 1] = cell .. string.rep(" ", math.max(colw[c] - vlen(cell), 0))
                    end
                    local row = table.concat(cells, " │ ")
                    if vlen(row) > width then row = row:sub(1, width) end
                    out[#out + 1] = row
                end
            end
        else
            local hashes, rest = line:match("^(#+)%s+(.*)")
            if hashes and rest then
                -- headings: wrap to width, heading role colour, no trailing blank
                local htext = md_strip_inline(rest, ansi_fn)
                htext = sgr_role("heading", htext)
                for _, wl in ipairs(wrap(htext, width)) do
                    out[#out + 1] = wl
                end
                i = i + 1
            elseif line:match("^%s*%d+%.%s+") then
                -- ordered list: numbered prefix + aligned continuation indent
                local num = line:match("^%s*(%d+%.?)%s+")
                local item = line:gsub("^%s*%d+%.%s+", "", 1)
                local body = md_strip_inline(item, ansi_fn)
                local prefix = num .. " "
                local prew = vlen(prefix)
                local wrapped = wrap(body, math.max(width - prew, 1))
                for wi, wl in ipairs(wrapped) do
                    out[#out + 1] = (wi == 1) and (prefix .. wl)
                        or (string.rep(" ", prew) .. wl)
                end
                i = i + 1
            elseif line:match("^%s*[%-%*]%s+") then
                local item = line:gsub("^%s*[%-%*]%s+", "", 1)
                local body = md_strip_inline(item, ansi_fn)
                local prefix = bullet .. " "
                local prew = vlen(prefix)
                local wrapped = wrap(body, math.max(width - prew, 1))
                for wi, wl in ipairs(wrapped) do
                    out[#out + 1] = (wi == 1) and (prefix .. wl)
                        or (string.rep(" ", prew) .. wl)
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
local CONFIRM_DIGITS = { "allow", "session", "always", "deny", "cancel" }
M.CONFIRM_DIGITS = CONFIRM_DIGITS

-- §6.6: spinner frames for the busy status indicator and thinking rows
-- field. ASCII variant for TERM=dumb / NO_COLOR (M8/R1). Declared here (not
-- next to their first use) so both the transcript tail and the status line
-- can reach them as upvalues.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_ASCII = { "|", "/", "-", "\\" }
M.SPINNER_ASCII = SPINNER_ASCII

local SLASH_COMMANDS = {
    -- M9: /help, /status, /log removed per user request
    { label = "/clear",   desc = "clear the transcript",            cmd = "clear" },
    { label = "/compact", desc = "compact context (summarize)",       cmd = "compact" },
    { label = "/model",   desc = "switch model",                      cmd = "model" },
    { label = "/resume",  desc = "resume session for workspace",      cmd = "resume" },
    { label = "/new",     desc = "start a new session",               cmd = "new" },
    { label = "/quit",    desc = "exit",                              cmd = "quit" },
    { label = "/copy",    desc = "copy from the transcript",          cmd = "copy" },
    -- add-provider-login: OAuth/API-key store
    { label = "/login",   desc = "log in with a provider (API key/OAuth)", cmd = "login" },
    { label = "/logout",  desc = "log out from a provider (drop the key)",  cmd = "logout" },
    -- add-reasoning-level: reasoning effort picker
    { label = "/think",   desc = "thinking level",                    cmd = "think" },
    -- unified-slash-palette: /skills removed — skills are entries of this list
}
M.SLASH_COMMANDS = SLASH_COMMANDS

-- 3.1: fuzzy_match / fuzzy_score — subsequence matcher, prefix ranked first,
-- declaration-order ties, empty filter lists all. Exported so tests and the
-- palette_sync rewrite can use the same primitive.
function M.fuzzy_score(filter, label)
    -- prefix gets the best score; subsequence gets a lower score; no match → nil
    local fl = filter:lower()
    local ll = label:lower()
    if fl == "" then return 1000 end
    if ll:find(fl, 1, true) == 1 then return 1000 end
    -- subsequence scan
    local pos = 1
    for c in fl:gmatch("(.)") do
        local found = ll:find(c, pos, true)
        if not found then return nil end
        pos = found + 1
    end
    -- count gap for ranking (smaller gap → better); ties broken by label length
    local gaps = 0
    local p2 = 1
    for c in fl:gmatch("(.)") do
        local f = ll:find(c, p2, true)
        gaps = gaps + (f - p2)
        p2 = f + 1
    end
    return math.max(0, 500 - gaps)
end

function M.fuzzy_rank(filter, labels)
    -- returns indices into labels sorted by score desc, declaration-order ties
    local scored = {}
    for i, lab in ipairs(labels) do
        local s = M.fuzzy_score(filter, lab)
        if s then scored[#scored + 1] = { idx = i, score = s } end
    end
    table.sort(scored, function(a, b)
        if a.score == b.score then return a.idx < b.idx end
        return a.score > b.score
    end)
    local out = {}
    for i, x in ipairs(scored) do out[i] = x.idx end
    return out
end

-- M10: keymap as data (idea from terminal.lua input.keymap) — the single
-- source of truth for keyboard bindings. Consumed by docs/tests; the help
-- screen is gone (M9), so this table is where bindings stay documented.
local KEYMAP = {
    ["enter"]      = "send",
    ["ctrl+j"]     = "newline",
    ["ctrl+c"]     = "abort/quit",
    ["ctrl+q"]     = "quit",
    ["ctrl+r"]     = "resume picker",
    ["ctrl+n"]     = "new session",
    ["ctrl+o"]     = "toggle newest tool result",
    ["ctrl+shift+o"] = "expand/collapse all tool results",
    ["ctrl+t"]     = "toggle thinking",
    ["ctrl+l"]     = "clear screen",
    ["ctrl+a"]     = "line start",
    ["ctrl+e"]     = "line end",
    ["ctrl+u"]     = "kill to start",
    ["ctrl+w"]     = "kill word",
    ["ctrl+k"]     = "kill to end",
    ["ctrl+up"]    = "history prev",
    ["ctrl+down"]  = "history next",
    ["up"]         = "history prev / cursor up (multi-line, Shift+)",
    ["down"]       = "history next / cursor down (multi-line, Shift+)",
    ["pgup"]       = "scroll up",
    ["pgdn"]       = "scroll down",
    ["home"]       = "jump to top (input empty)",
    ["end"]        = "jump to bottom (input empty)",
    ["esc"]        = "cancel/confirmation deny",
    ["1"]          = "confirm allow",
    ["2"]          = "confirm session",
    ["3"]          = "confirm always",
    ["4"]          = "confirm deny",
    ["5"]          = "confirm cancel",
    ["y"]          = "confirm allow",
    ["a"]          = "confirm session",
    ["A"]          = "confirm always",
    ["n"]          = "confirm deny",
}
M.KEYMAP = KEYMAP

-- add-ask-tool: the question block's own bindings, as data. While the block is
-- open it owns the keyboard, so these are its meanings for the shared keys:
-- the arrows move across the option rows and the freeform row, a digit picks
-- that option (toggling it on a `multi` question), Space toggles a `multi`
-- option, Enter submits/accepts, Tab edits the highlighted row (a note on an
-- option, the freeform answer on its row), ← returns to the previous question
-- and Esc cancels the set without stopping the turn.
local ASK_KEYS = {
    ["up"]        = "previous option",
    ["down"]      = "next option",
    ["enter"]     = "submit / accept the question",
    ["1"]         = "pick option 1",
    ["space"]     = "toggle an option of a multi question",
    ["tab"]       = "edit the highlighted option's note / the freeform answer",
    ["left"]      = "previous question",
    ["esc"]       = "cancel the question set",
    ["backspace"] = "edit the open note / freeform editor",
}
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
M._tools = tools
local function tools_mod()
    local g = rawget(_G, "tools")
    if type(g) == "table" then return g end
    return tools
end

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
    pcall(function() debug_log_fh:write(os.date("[%H:%M:%S] ") .. msg .. "\n") end)
end
local function init_debug_log()
    if S and S.debug and debug_log_fh == nil then
        local dir = (os.getenv("HOME") or "/tmp") .. "/.tether/log"
        pcall(function() tether.mkdirp(dir) end)
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
        _in_copy_palette = nil,  -- 5.2: set when the /copy palette is open
        _in_login_palette = nil, -- add-provider-login: bare /login provider picker
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

-- A: spinner frame. TW2 regression: the frame advanced once per paint(), so
-- the glyph changed per event batch — a slideshow whose speed depended on how
-- fast tokens arrived (idle = frozen, burst = blur). Like pi's Loader (80 ms
-- interval), the frame is derived from elapsed wall-clock time since the turn
-- started. Nil-safe like the other seams: callers may run before run() created S.
local SPINNER_INTERVAL_MS = 80
local function spinner_glyph()
    local frames = (M._ascii_mode or M._env_ascii or _ascii) and SPINNER_ASCII or SPINNER
    local ms = 0
    if S and S.busy_started_at_ms then
        local now = (tether.monotonic_ms and tether.monotonic_ms()) or 0
        ms = now - S.busy_started_at_ms
    end
    return frames[(math.floor(ms / SPINNER_INTERVAL_MS) % #frames) + 1]
end
M.spinner_glyph = spinner_glyph
M._spinner_interval_ms = SPINNER_INTERVAL_MS
-- TW2 test seam: glyph for a given elapsed-ms (pure, no S dependency)
M._spinner_glyph_at = function(ms)
    local frames = (M._ascii_mode or M._env_ascii or _ascii) and SPINNER_ASCII or SPINNER
    return frames[(math.floor(ms / SPINNER_INTERVAL_MS) % #frames) + 1]
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

-- unified-slash-palette 2.1: palette window geometry. Pure, so tests can call
-- it directly. Height: at most 8 rows and at most half the terminal height,
-- never below one. Offset: shifts so the selected row stays inside the window.
local function palette_window(h, n, sel)
    if n <= 0 then return 0, 1 end
    local win = math.min(n, 8, math.max(1, math.floor(h / 2)))
    if sel < 1 then sel = 1 end
    if sel > n then sel = n end
    local off = 1
    if win < n then
        off = sel - math.floor(win / 2)
        if off < 1 then off = 1 end
        if off > n - win + 1 then off = n - win + 1 end
    end
    return win, off
end
M._palette_window = palette_window

-- pi-style-input-and-footer: the box's rule glyph and the labels its rules
-- carry for the input rows hidden above/below the window. ASCII twins come from
-- GLYPH_MAP (─ → -, ↑ → ^, ↓ → v) through the dim() role, so no branch is
-- needed here.
local RULE_GLYPH = "─"
local RULE_LABEL_UP = "↑ %d more"
local RULE_LABEL_DOWN = "↓ %d more"

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

-- slim-footer-indicators: transient flags only (the one-shot toast);
-- mouse/keyboard mode icons are gone. Everything lives on the single footer row.
local function static_flags()
    local out = {}
    if S.toast then out[#out + 1] = green(S.toast) end
    return out
end

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
    if S.palette_active and #S.palette_items > 0 then
        -- 2.4: the reserved region follows the window (items + 2); the indicator
        -- row the palette may paint fits inside it (see render_palette)
        local win = palette_window(S.h, #S.palette_items, S.palette_sel)
        want_palette_h = win + 2
    end

    -- slim-footer-indicators: the dock runs, top to bottom — a gap row above
    -- the box, the box's top rule, the input's rows, its bottom rule, the
    -- palette, and the footer's single row. Everything is reserved here so no
    -- region can overlap another; the error banner keeps its row above the box.
    local function reserve(pal_h)
        return 2 + shown_in + pal_h + 1 + 1
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
    local footer_row = rule_bottom_row + palette_h + 1

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

-- ============================================================
-- Palette: derived from input
-- ============================================================
-- unified-slash-palette 1.2: skill rows for the palette. Discovery is injected
-- so tests can stub it (M._skills_stub, mirroring M._tools_stub); a discovery
-- problem degrades to no rows instead of breaking the palette.
local PALETTE_SKILL_HINT = "[skill]"

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
                desc = sk.description or "",
                hint = PALETTE_SKILL_HINT,
                skill = true,
                name = name,
                path = sk.path or "",
            }
        end
    end
    return rows
end

-- 4.2: submit-time lookup over the discovered skills, case-insensitive.
local function palette_skill_named(name)
    for _, row in ipairs(palette_skill_rows()) do
        if (row.name or ""):lower() == name then return row end
    end
    return nil
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
    local order = M.fuzzy_rank(filter, labels)
    local items = {}
    for _, idx in ipairs(order) do
        items[#items + 1] = entries[idx]
    end
    S.palette_items = items
    if S.palette_sel < 1 then S.palette_sel = 1 end
    if S.palette_sel > #items then S.palette_sel = #items end
    if #items == 0 then S.palette_sel = 1 end
end

-- ============================================================
-- Path completion (4.2/4.3/4.4): Tab outside the palette completes the
-- token under the cursor against the workspace, rendered in the palette
-- region. Unique candidate applies in place; several open the palette
-- with the first applied and later Tabs cycle (wrapping); Esc restores
-- the token as typed; any other key keeps the applied text.
-- ============================================================
-- Token = text from the cursor back to the previous whitespace or line
-- start; a leading @ is a mention prefix, kept verbatim in the input.
local function completion_token()
    local lines = input_lines()
    for _, ln in ipairs(lines) do
        if S.cursor >= ln.from and S.cursor <= ln.from + #ln.text then
            local upto = ln.text:sub(1, S.cursor - ln.from)
            local token = upto:match("([^%s]*)$") or ""
            local pos = ln.from + 1 + #upto - #token
            return token, pos
        end
    end
    return nil
end

local function completion_apply(label)
    local comp = S.completion
    if not comp then return end
    local at = comp.original:match("^(@)")
    local replace = at and ("@" .. label) or label
    local head = S.input:sub(1, comp.start - 1)
    S.input = head .. replace .. (comp.tail or "")
    -- comp.start is one-based and S.cursor is a zero-based offset, so the
    -- cursor lands directly after the applied text: before the tail, and never
    -- past the end of the input (spec tui: Path completion)
    S.cursor = comp.start - 1 + #replace
end
-- 4.3: gated on ui.path_completion; Tab inside an open palette keeps its
-- command-completion meaning (handled by the palette branch of handle_key).
-- Resolves the tools module lazily: tests can override M._tools_stub to
-- stub path_complete without touching the real filesystem.
M._tools_stub = nil
-- 6.1: seam for tests to stub skill discovery (mirrors M._tools_stub).
M._skills_stub = nil
local function path_complete_tab()
    if S.palette_active then return end
    if S.cfg and S.cfg.ui and S.cfg.ui.path_completion == false then return end
    -- The host loads every module and exposes it as a global (load_module in
    -- main.c calls lua_setglobal and never package.preload), so the production
    -- lookup has to read the global; require() only resolves in the plain-Lua
    -- harness, which is why it stays as a fallback.
    local tools_mod = M._tools_stub
        or tools_mod()
        or (pcall(require, "tools") and package.loaded.tools)
        or nil
    if tools_mod == nil or tools_mod.path_complete == nil then return end
    local token, token_pos = completion_token()
    if not token or token == "" then return end
    local r = tools_mod.path_complete(token, { workspace = S.workspace })
    local cands = (r and r.candidates) or {}
    if #cands == 0 then return end -- no candidates -> input unchanged, no palette
    if #cands == 1 then
        -- one-shot apply; no cycle state to restore, but the text after the
        -- token still has to survive: a unique candidate completes the token
        -- in place (spec tui: Path completion), so completing `ag` inside
        -- `ag.bak` must not lose `.bak`. The palette branch carries the same tail.
        local one_comp = { start = token_pos, stop = token_pos + #token,
            original = token, tail = S.input:sub(token_pos + #token) }
        S.completion = one_comp
        completion_apply(cands[1])
        S.completion = nil
        return
    end
    local comp = S.completion or {}
    comp.start = comp.start or token_pos
    if not comp.original then
        comp.original = S.input:sub(comp.start, comp.start + #token - 1)
        comp.tail = S.input:sub(comp.start + #token)
    end
    comp.items = cands
    if not S.palette_active then
        S.palette_mode = "path"
        S.palette_active = true
        S.palette_items = {}
        for _, c in ipairs(cands) do
            S.palette_items[#S.palette_items + 1] = { label = c, desc = "" }
        end
        S.palette_sel = 1
    else
        S.palette_sel = (S.palette_sel % #comp.items) + 1
    end
    S.completion = comp
    completion_apply(comp.items[S.palette_sel])
end

-- 4.2: Esc while the completion palette is open restores the token exactly
-- as typed before the first Tab.
local function completion_cancel()
    local comp = S.completion
    if not comp then return end
    S.completion = nil
    S.input = S.input:sub(1, comp.start - 1) .. comp.original .. (comp.tail or "")
    S.cursor = comp.start - 1 + #comp.original
    S.palette_active = false
    S.palette_mode = "command"
    S.palette_items = {}
    S.palette_sel = 1
    palette_sync()
end

-- 4.2: any non-tab/non-esc key during active completion keeps the applied
-- text and clears the cycle state (input is not touched).
local function completion_commit()
    if S.completion then
        S.completion = nil
        S.palette_active = false
        S.palette_mode = "command"
        S.palette_items = {}
        S.palette_sel = 1
        palette_sync()
    end
end

-- ============================================================
-- Input model
-- ============================================================
-- Test seams: drive path_complete_tab / handle_key from a test harness
-- after run() has set up S. Placed here (after all local functions are
-- declared) so the closures capture the locals correctly.
M._path_complete_tab = function() if S then path_complete_tab() end end
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
        and not S._in_resume_palette and not S._in_model_palette
        and not S._in_think_palette then
        palette_sync()
    end
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

-- 4.1: extension -> highlighter language (the highlighter keys are in HL_LANGS).
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
M._entry_expanded = entry_expanded

local function body_line_iter(body)
    return (body .. "\n"):gmatch("([^\n]*)\n")
end

-- 4.2: one tokenizer state spans the body; syntax roles win over the
-- add/remove/context base role, plain tokens take the base role.
local function highlight_diff_line(text, lang, state, base_fn)
    if not lang then return base_fn(text) end
    local toks = M.tokenize_line(text, lang, state)
    local out = {}
    for _, t in ipairs(toks) do
        local role = HL_ROLE[t.kind]
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
                    coloured[#coloured + 1] = num .. "\t" .. M.highlight_line(content, lang, state)
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
                    return pfx .. M.highlight_line(c, l, state_by[l])
                end)
            else
                coloured[#coloured + 1] = line
            end
        end
        return wrap(table.concat(coloured, "\n"), math.max(inner, 1))
    end
    return wrap(body, math.max(inner, 1))
end

-- add-ask-tool: is `label` among this question's selected answers?
local function ask_selected(answer, label)
    for _, l in ipairs((answer and answer.selected) or {}) do
        if l == label then return true end
    end
    return false
end

-- The question block's rows. Rendered from S.ask directly, so the highlight and
-- the rows can never disagree about what is selectable: option rows are 1..n in
-- order, then the always-present freeform row at n+1.
local function render_ask(width)
    local a = S.ask
    if not a then return {} end
    local q = a.questions and a.questions[a.qidx]
    if not q then return {} end
    local answer = a.answers[a.qidx] or {}
    local n = #q.options
    local inner = math.max(width - 2, 1)
    local out = { "" }

    local progress = #a.questions > 1
        and string.format(" (%d/%d)", a.qidx, #a.questions) or ""
    out[#out + 1] = cyan("? ") .. (q.question or "") .. dim(progress)

    if q.description and q.description ~= "" then
        for _, l in ipairs(md_render(q.description, inner, M.md_ansi)) do
            out[#out + 1] = "  " .. l
        end
    end

    for i, opt in ipairs(q.options) do
        local row = {}
        if q.multi then
            row[#row + 1] = ask_selected(answer, opt.label) and "[x] " or "[ ] "
        end
        row[#row + 1] = i .. ". " .. opt.label
        if q.recommended == i then row[#row + 1] = dim("  (recommended)") end
        local text = "  " .. table.concat(row)
        if i == a.sel and a.mode == "list" then text = rev(text) end
        out[#out + 1] = text
        if opt.description and opt.description ~= "" then
            for _, l in ipairs(wrap(opt.description, inner - 4)) do
                out[#out + 1] = "      " .. dim(l)
            end
        end
        if a.mode == "note" and a.note_sel == i then
            out[#out + 1] = "    " .. dim("note> ") .. (a.editor or "") .. caret_glyph()
        else
            local note = answer.notes and answer.notes[opt.label]
            if note and note ~= "" then
                out[#out + 1] = "    " .. dim("↳ " .. note)
            end
        end
    end

    local freeform = ask.FREEFORM_LABEL
    if a.mode == "other" then
        out[#out + 1] = "  " .. freeform .. ": " .. (a.editor or "") .. caret_glyph()
    else
        local text = "  " .. freeform
        if answer.other and answer.other ~= "" then
            text = text .. dim("  («" .. answer.other .. "»)")
        end
        if a.sel == n + 1 and a.mode == "list" then text = rev(text) end
        out[#out + 1] = text
    end
    return out
end

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
        out = render_ask(width)
    elseif e.virt == "placeholder" then
        -- turn-feedback-restyling: no waiting row in the transcript (the
        -- input box carries the Working indicator); kept as a no-op for any
        -- stale tail reference.
        out = {}
    elseif e.virt == "confirm" then
        local c = S.confirmation
        if not c then return {} end
        local co = { "", yellow("⚠ " .. (c.label or "confirmation")) }
        for _, l in ipairs(wrap(c.body or "", width - 2)) do
            co[#co + 1] = "  " .. l
        end
        for i, opt in ipairs(c.options or {}) do
            local t = "  " .. opt
            co[#co + 1] = (i == S.confirmation_sel) and rev(t) or t
        end
        out = co
    else
        local role = e.role or "system"
        if role == "separator" then
            -- tui: Turn separators — dim rule with the local submission time
            local label = "── " .. (e.text or "") .. " "
            local fill = width - vlen(label)
            if fill < 1 then fill = 1 end
            out = { dim(label .. string.rep("─", fill)) }
        elseif role == "user" then
            out = with_prefix(cyan("›") .. " ", 2,
                wrap(e.text or "", math.max(width - 2, 1)))
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
            if not S.thinking_visible then
                return { dim("think ▸ (Ctrl+T)") }
            end
            local secs = os.time() - (e.started_at or os.time())
            if secs < 0 then secs = 0 end
            local to = { dim(italic(string.format("thinking · %.1fs ▾", secs))) }
            -- header only while no reasoning text has arrived: wrap("") yields
            -- one empty line and would paint a stray blank row under the header
            if (e.text or ""):find("%S") then
                for _, l in ipairs(wrap(e.text, math.max(width - 2, 1))) do
                    to[#to + 1] = "  " .. dim(l)
                end
            end
            out = to
        elseif role == "system" then
            out = { dim(e.text or "") }
        elseif role == "tool" then
            -- 3.1: leading status marker; a failed row appends its first error line
            -- (clipped) so the failure is visible without expanding.
            local marker
            if e.status == "pending" then marker = yellow("…")
            elseif e.status == "error" then marker = red("✗")
            else marker = green("✓") end
            local head = marker .. " " .. sgr_role("accent", e.name or "?")
            -- the call's primary argument (which file ran what): without it
            -- `✓ read` / `✓ run` say nothing about what actually happened.
            do
                local label = M._tool_arg_label(e.name, e.args, e.path)
                if label and label ~= "" then
                    label = sanitize_output(label:match("^[^\n]*") or "")
                    local budget = width - vlen(head) - 1
                    if budget >= 4 then head = head .. " " .. clip(label, budget) end
                end
            end
            if e.status == "pending" then
                -- M8/R3: pending tools show live elapsed time
                if e.started_at then
                    local secs = os.time() - e.started_at
                    head = head .. "  " .. dim(string.format(" %.1fs", secs))
                end
            elseif e.status == "error" then
                local raw = (e.body ~= nil and e.body ~= "") and e.body or (e.summary or "")
                raw = sanitize_output(raw):gsub("^✗%s*", "")
                local first = raw:match("^[^\n]*") or ""
                local budget = width - vlen(head) - 1
                if budget >= 1 then head = head .. " " .. red(clip(first, budget)) end
                head = trunc(head, width)
            elseif e.summary and e.summary ~= "" then
                head = head .. "  " .. dim(e.summary)
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
    -- assistant, system) — but not after a separator (the user row it labels
    -- follows directly), not before the first entity, and not before virtual
    -- tails (they emit their own leading blank). Empty entries get no gap.
    local gap_roles = { separator = true, user = true, assistant = true, system = true }
    local is_virt = e.virt == "ask" or e.virt == "placeholder" or e.virt == "confirm"
    local need_gap = (not is_virt) and prev_role ~= nil
        and gap_roles[e.role or "system"] and prev_role ~= "separator"
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

-- Full-render wrapper kept for the rare call sites that index rows directly
-- (mouse hit-testing, Home). The per-frame status indicator uses
-- M.transcript_height instead.
local function display_lines()
    return M._render_all(layout().w)
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

-- M10: hardware scroll-region shift, adapted from terminal.lua's
-- terminal.scroll approach. Returns an escape sequence that sets DECSTBM
-- (top..bottom inclusive, 1-based screen rows), scrolls the region by
-- |shift| lines with SU (up) / SD (down), then resets the region.
-- Guard rails: zero/nil shift, shift >= region size or an invalid region
-- return "" — the caller then falls back to per-row repaint.
function M.scroll_shift_seq(h, top, bottom, shift)
    if not shift or shift == 0 then return "" end
    if not h or not top or not bottom then return "" end
    if top < 1 or bottom > h or top > bottom then return "" end
    local region = bottom - top + 1
    local amount = shift > 0 and shift or -shift
    if amount >= region then return "" end
    local move = (shift > 0)
        and (ESC .. "[" .. amount .. "S")
        or  (ESC .. "[" .. amount .. "T")
    return ESC .. "[" .. top .. ";" .. bottom .. "r" .. move .. ESC .. "[r"
end

local function render_transcript(L)
    local total = ensure_index(L.w)
    S.last_transcript_h = L.transcript_h -- cache bound follows the viewport
    -- viewport pin: while scrolled away from the tail, rows arriving (or
    -- dropped by a retry) below the viewport must not move it — fold the
    -- total drift back into the offset so the same rows stay visible. Only
    -- when the offset itself sat still: a user scroll between paints takes
    -- precedence, so preset offsets are never rewritten.
    if S.user_scrolled and S._last_total ~= nil and total ~= S._last_total
        and S.scroll == (S._last_scroll or S.scroll) then
        S.scroll = S.scroll + (total - S._last_total)
    end
    -- M10: clamp scroll so the viewport can never move past the top of the
    -- transcript. Over-scroll made top negative and the scroll indicator
    -- report nonsense (⏸ +36 on a 4-line transcript).
    local max_scroll = total - 1
    if max_scroll < 0 then max_scroll = 0 end
    if S.scroll > max_scroll then S.scroll = max_scroll end
    if S.scroll < 0 then S.scroll = 0 end
    -- baseline AFTER the clamp: the pin compares against what is actually
    -- painted, never a pre-clamp value.
    S._last_total, S._last_scroll = total, S.scroll
    local bottom = total - S.scroll
    if bottom > total then bottom = total end
    if bottom < 1 then bottom = 1 end
    local top = bottom - L.transcript_h + 1
    if top < 1 then top = 1 end
    -- M9: scrolling shifts every visible row; the row diff must not compare
    -- against rows painted for the PREVIOUS viewport (they had different
    -- content and interleaved SGR open/close), otherwise stale fragments
    -- leak through as stray characters. Invalidate the window when the
    -- scroll offset changes.
    if S.last_transcript_top ~= top then
        -- M10: hardware scroll-region shift (terminal.lua approach).
        -- When the previous viewport is a strict subset/superset of the new
        -- one and the shift is smaller than the region, scroll the region
        -- with SU/SD instead of repainting every row; only the newly
        -- exposed rows are then repainted by the normal diff below.
        if S.last_transcript_top
            and S.last_transcript_w == L.w
            and S.cfg.ui.alt_screen ~= true then
            local old_top = S.last_transcript_top
            local delta = old_top - top -- >0: content moved up (scroll down)
            -- M10 fix: the scroll region operates on SCREEN rows of the
            -- transcript window (transcript_row..transcript_row+h-1), NOT on
            -- transcript line indices. Mixing them (as the first draft did)
            -- produced a tiny/invalid region and SU/SD never fired.
            local seq = M.scroll_shift_seq(L.h, L.transcript_row,
                L.transcript_row + L.transcript_h - 1, delta)
            if seq ~= "" and delta ~= 0 then
                frame_put(seq)
                -- the shift physically moved row contents: forget every
                -- cached row inside the region so the diff repaints the
                -- freshly exposed lines (and only them)
                for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
                    S.screen[r] = nil
                end
            end
        end
        for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
            S.screen[r] = nil
        end
        S.last_transcript_top = top
        S.last_transcript_w = L.w
    end
    -- A: live tail — the caret while deltas are still streaming (the waiting
    -- spinner moved to the input box: the transcript carries no placeholder).
    -- Applied at paint time so the wrapped-line cache stays untouched.
    -- tui spec: the caret must NOT be drawn while the palette, confirmation,
    -- ask block or login secret mode owns the keyboard (the busy pump lets
    -- the palette open mid-turn, so the guard must be explicit here).
    local tail = ""
    if not S.user_scrolled and total > 0 then
        if S.streaming and not S.palette_active
            and not S.confirmation and not S.ask and not S.login_secret then
            tail = caret_glyph()
        end
    end
    local last_painted = math.min(total, bottom)
    local lo = entry_of_row(top, L.w) or 0
    local hi = entry_of_row(last_painted, L.w) or -1
    transcript.set_visible(lo, hi)
    for i = 1, L.transcript_h do
        local idx = top + i - 1
        local text = ""
        if idx >= 1 and idx <= total then
            text = row_text(idx, L.w)
        end
        if idx == total and tail ~= "" then
            text = trunc(text, L.w - 2) .. tail
        end
        set_row(L.transcript_row + i - 1, text)
    end
end

local function render_error_banner(L)
    if not S.error_banner then return end
    set_row(L.error_row, rev(red(" ! ")) .. " " .. red(trunc(S.error_banner, L.w - 4)))
end

-- pi-style-input-and-footer: does the active renderer emit video attributes
-- at all? ASCII/NO_COLOR and the `mono` theme emit none, so the block caret
-- would be invisible there and a bar glyph stands in for it.
local function caret_block()
    local theme = THEMES[_theme_name] or THEMES.default
    return M.color_depth() ~= "none" and theme.reverse ~= nil
end

-- Display-column slicing of a row body: drop `n` columns from the start, and
-- keep at most `width` columns from the start. Both are SGR- and wide-char
-- aware (they walk cells(), not bytes).
local function drop_cols(s, n)
    if not s or s == "" or n <= 0 then return s or "" end
    local out, col = {}, 0
    for _, c in ipairs(cells(s)) do
        col = col + c.w
        if col > n then out[#out + 1] = c.t end
    end
    return table.concat(out)
end

local function take_cols(s, width)
    local out, col = {}, 0
    if width <= 0 then return "", 0 end
    for _, c in ipairs(cells(s)) do
        if col + c.w > width then break end
        out[#out + 1] = c.t
        col = col + c.w
    end
    return table.concat(out), col
end

-- One input row's body: the line windowed to `width` display columns with the
-- caret inside the window, padded out so every input row and both rules share
-- one display width. `caret_off` is the cursor's byte offset inside `text`, or
-- nil on the rows the cursor is not on. A line wider than the row scrolls so
-- the caret stays visible, the way a one-line editor scrolls.
local function input_row_text(text, caret_off, width)
    text = text or ""
    local before, caret, after
    if caret_off then
        before = text:sub(1, caret_off)
        local rest = text:sub(caret_off + 1)
        local ch = rest:match("^" .. utf8.charpattern) or ""
        if caret_block() then
            -- pi's caret: the cell under the cursor painted in reverse video,
            -- or a reverse-video space at the end of the row
            caret = rev(ch ~= "" and ch or " ")
            after = ch ~= "" and rest:sub(#ch + 1) or ""
        else
            caret = "|"
            after = rest
        end
    else
        before, caret, after = text, "", ""
    end
    local caret_col = vlen(before)
    local caret_w = vlen(caret)
    local total_w = caret_col + caret_w + vlen(after)
    local from = 0
    if total_w > width then
        -- scroll right just far enough to bring the caret's own cell inside
        from = math.min(math.max(0, total_w - width),
                        math.max(0, caret_col + caret_w - width))
    end
    local shown = take_cols(drop_cols(before .. caret .. after, from), width)
    local w = vlen(shown)
    if w < width then shown = shown .. string.rep(" ", width - w) end
    return shown
end

-- A rule row: the box's top and bottom rules. It can carry the turn's status at
-- the left (pi's "── status ────") and a centered "N more" label naming the
-- input rows the window hides. Always exactly `width` columns, dim in every
-- theme; the ASCII rules come from GLYPH_MAP through dim().
local function rule_row(width, status, label)
    if width <= 0 then return "" end
    local function fill(n) return string.rep(RULE_GLYPH, math.max(0, n)) end
    local sw = status and vlen(status) or 0
    if status and sw > 0 and sw + 4 <= width then
        local rest = width - 3 - sw - 1
        if label then
            local lw = vlen(label)
            local start = math.floor((width - lw) / 2)
            local left_block = 3 + sw + 1
            -- the label survives only when it clears the status by a column
            if lw + 2 <= width and start - left_block >= 1 then
                return dim(fill(3)) .. status ..
                    dim(" " .. fill(start - left_block) .. label ..
                        fill(width - start - lw))
            end
        end
        return dim(fill(3)) .. status .. dim(" " .. fill(rest))
    end
    if status and sw > 0 then
        -- too narrow for the "── " head: the status alone, truncated to fit
        return trunc(status, width)
    end
    if label then
        local lw = vlen(label)
        if lw + 2 <= width then
            local start = math.floor((width - lw) / 2)
            return dim(fill(start) .. label .. fill(width - start - lw))
        end
    end
    return dim(fill(width))
end

-- The turn's status for the box's top rule: the spinner with Working... while
-- busy. Leading space separates the indicator from the rule's left edge.
local function turn_status()
    if S.busy then
        return " " .. cyan(spinner_glyph()) .. dim(" Working...") .. " "
    end
    return nil
end
M._turn_status = turn_status

local function render_input(L)
    -- palette-only R5: secret mode paints a masked line in the input box —
    -- never the plaintext, never S.input.
    if S.login_secret then
        local pad = box_padding(L.w)
        local content_w = math.max(1, L.w - pad * 2)
        local side = string.rep(" ", pad)
        -- the secret line names what to paste: env var when the provider
        -- takes an API key, device URL for device flows, auth code otherwise.
        local hint = "paste API key"
        if S.cfg and S.cfg.providers and S.cfg.providers[S.login_provider]
            and S.cfg.providers[S.login_provider].api_key_env
            and S.cfg.providers[S.login_provider].api_key_env ~= "" then
            hint = hint .. " (" .. S.cfg.providers[S.login_provider].api_key_env .. ")"
        elseif M._provider_catalog and M._provider_catalog.get then
            local entry = M._provider_catalog.get(S.login_provider or "")
            if entry and entry.api_key_env and entry.api_key_env ~= "" then
                hint = hint .. " (" .. entry.api_key_env .. ")"
            end
        end
        if S.login_flow and S.login_flow.device and S.login_flow.device_code then
            -- full device flow: the TUI polls; the user just authorizes
            hint = "open " .. tostring(S.login_flow.verification_uri
                or S.login_flow.device_url)
                .. " and enter " .. tostring(S.login_flow.user_code or "")
                .. " — waiting (Esc cancels)"
        elseif S.login_flow and S.login_flow.device and S.login_flow.device_url then
            hint = "open " .. S.login_flow.device_url .. ", paste token"
        elseif S.login_flow and S.login_flow.authorize_url then
            hint = hint .. " or auth code"
        end
        local label = "login " .. tostring(S.login_provider or "") .. ": " .. hint
        local mask = string.rep("*", #(S.login_secret.buf or ""))
        local text = label .. ": " .. mask
        set_row(L.rule_top_row, rule_row(L.w, turn_status(), nil))
        set_row(L.input_row, side .. input_row_text(text, #text, content_w) .. side)
        for i = 2, L.input_h do
            set_row(L.input_row + i - 1, side .. string.rep(" ", content_w) .. side)
        end
        set_row(L.rule_bottom_row, rule_row(L.w, nil, nil))
        return
    end
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
    local pad = box_padding(L.w)
    local content_w = math.max(1, L.w - pad * 2)
    local side = string.rep(" ", pad)
    local cursor_li = cursor_line_col()

    -- pi-style-input-and-footer: the box. The top rule carries the turn's
    -- status and, like the bottom rule, names the input rows the window hides.
    local hidden_above = start - 1
    local hidden_below = total - (start + shown - 1)
    set_row(L.rule_top_row, rule_row(L.w, turn_status(),
        hidden_above > 0 and string.format(RULE_LABEL_UP, hidden_above) or nil))

    for i = 1, shown do
        local li = start + i - 1
        local ln = lines[li]
        if not ln then
            set_row(L.input_row + i - 1, side .. string.rep(" ", content_w) .. side)
        else
            local caret_off = (li == cursor_li) and (S.cursor - ln.from) or nil
            set_row(L.input_row + i - 1,
                side .. input_row_text(ln.text, caret_off, content_w) .. side)
        end
    end

    set_row(L.rule_bottom_row, rule_row(L.w, nil,
        hidden_below > 0 and string.format(RULE_LABEL_DOWN, hidden_below) or nil))
end

local function render_palette(L)
    if not S.palette_active or #S.palette_items == 0 then return end
    -- M9: no frame; selected item is accent-colored, not reverse-video
    -- 2.2/2.3: a window over the ranked list, shifted so the selected row is
    -- inside it, plus a dim pos/total row when the list overflows it. The
    -- palette starts below the box's bottom rule and neither rule nor any
    -- footer row is ever painted here. (pi renders its dropdown the same way:
    -- directly under the editor's bottom border.)
    local n = #S.palette_items
    local win, off = palette_window(L.h, n, S.palette_sel)
    local last = L.footer_row - 1
    -- descriptions align: the name column is padded to the widest name+hint
    -- across all listed entries (computed once per paint)
    local label_w = 0
    for _, it in ipairs(S.palette_items) do
        local l = it.label or ""
        if it.hint then l = l .. " " .. it.hint end
        local vw = vlen(l)
        if vw > label_w then label_w = vw end
    end
    for i = 1, win do
        local row = L.palette_row + i
        if row > last then break end
        local it = S.palette_items[off + i - 1]
        if it then
            -- 3.1: the argument hint sits after the name when the entry has one
            local label = it.label or ""
            if it.hint then label = label .. " " .. it.hint end
            local pad = string.rep(" ", math.max(label_w - vlen(label), 0))
            local text = trunc(string.format(" %s%s %s", label, pad, it.desc or ""), L.w - 2)
            set_row(row, (off + i - 1 == S.palette_sel) and sgr_role("accent", text) or dim(text))
        end
    end
    local irow = L.palette_row + win + 1
    if n > win and irow <= last then
        set_row(irow, dim(trunc(string.format(" %d/%d", S.palette_sel, n), L.w - 2)))
    end
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
function M.token_pct(pct, summarize_at)
    summarize_at = summarize_at or 0.7
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    local color = pct >= 0.9 and red or (pct >= summarize_at and yellow or green)
    return color(string.format("%d%%", math.floor(pct * 100)))
end

-- T47: "4.1k/32k (13%)" — used over budget (KiB-style /1024, so the default
-- 32768 budget reads as "32k"), colored by the same thresholds.
function M.token_usage(used, max_tokens, summarize_at)
    if type(used) ~= "number" or used < 0 then used = 0 end
    if type(max_tokens) ~= "number" or max_tokens <= 0 then max_tokens = 1024 end
    local pct = math.min(used / max_tokens, 1)
    local color = pct >= 0.9 and red or (pct >= (summarize_at or 0.7) and yellow or green)
    local k = function(n)
        local s = string.format("%.1fk", n / 1024)
        return (s:gsub("%.0k$", "k"))
    end
    return color(string.format("%s/%s (%d%%)", k(used), k(max_tokens),
        math.floor(pct * 100 + 0.5)))
end

-- pi-style-input-and-footer: compact token counts for the footer, mirrored
-- from pi's footer formatter (plain below 1000, one decimal k, rounded k, M).
function M.format_count(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    n = math.floor(n)
    if n < 1000 then return tostring(n) end
    if n < 10000 then return string.format("%.1fk", n / 1000) end
    if n < 1000000 then return string.format("%dk", math.floor(n / 1000 + 0.5)) end
    if n < 10000000 then return string.format("%.1fM", n / 1000000) end
    return string.format("%dM", math.floor(n / 1000000 + 0.5))
end

-- The tail of `s`, at most `maxw` display columns. The footer keeps the model
-- name readable from its end, where the model id actually lives.
local function tail_cols(s, maxw)
    if maxw <= 0 then return "" end
    if vlen(s) <= maxw then return s end
    local cs = cells(s)
    local out, col = {}, 0
    for i = #cs, 1, -1 do
        local c = cs[i]
        if col + c.w > maxw then break end
        table.insert(out, 1, c.t)
        col = col + c.w
    end
    return table.concat(out)
end

-- The footer row composition: `left` at the start, `right` right-aligned and kept
-- at least two columns away. Both sides may carry SGR; widths are display
-- columns. When they cannot both fit, the right side loses its start (so its
-- tail survives) and is dropped only when nothing of it fits; the left side is
-- truncated only when it alone exceeds the row.
function M.footer_stats(left, right, width)
    if width <= 0 then return "" end
    left, right = left or "", right or ""
    local lw = vlen(left)
    if lw >= width then return to_ascii(trunc(left, width)) end
    local room = width - lw - 2 -- the two columns the model must stay clear of
    local rw = vlen(right)
    if rw == 0 or room <= 0 then
        return left .. string.rep(" ", width - lw)
    end
    local kept = rw <= room and right or tail_cols(right, room)
    local kw = vlen(kept)
    return left .. string.rep(" ", width - lw - kw) .. kept
end

-- slim-footer-indicators: one dim footer row below the box — path ($HOME → ~),
-- session token stats + context cell, transient flags (toast), and the
-- model right-aligned. Truncation when over width (spec tui Footer): path
-- right-truncate first, then toast dropped, then stats
-- right-truncate; model is handled separately by footer_stats. No reverse
-- video, no mode icons.
local function render_footer(L)
    local home = os.getenv("HOME") or ""
    local ws = S.workspace
    if home ~= "" and ws:sub(1, #home) == home then
        ws = "~" .. ws:sub(#home + 1)
    end

    local stats = {}
    if (S.tokens_in or 0) > 0 then
        stats[#stats + 1] = dim("↑" .. M.format_count(S.tokens_in))
    end
    if (S.tokens_out or 0) > 0 then
        stats[#stats + 1] = dim("↓" .. M.format_count(S.tokens_out))
    end
    if S.tokens_max and S.tokens_max > 0 then
        local summarize_at = (S.cfg.context and S.cfg.context.summarize_at) or 0.7
        -- no estimated prefix: the ≈/· marker in front of the context cell
        -- was dropped (the cell itself already reads as an estimate)
        stats[#stats + 1] = M.token_usage(S.tokens_used, S.tokens_max, summarize_at)
    end
    -- blocks joined by `·` separators: path · stats · flags (user request)
    local stats_str = table.concat(stats, dim(" · "))

    local flags = static_flags()
    local flags_str = #flags > 0 and to_ascii(table.concat(flags, " ")) or ""

    local width = L.w
    -- Visual order: path, stats, flags — joined with ` · ` separators.
    -- Truncation order (spec): path first (to_ascii so ASCII mode gets
    -- "..." not "…"), then toast, then stats — each step
    -- re-fits the path into the room that opened up.
    local SEP = dim(" · ")
    local function join(path_s, s_str, f_str)
        local parts = {}
        if path_s ~= "" then parts[#parts + 1] = path_s end
        if s_str ~= "" then parts[#parts + 1] = s_str end
        if f_str ~= "" then parts[#parts + 1] = f_str end
        return table.concat(parts, SEP)
    end

    local function fit_path(f_str, s_str)
        -- separators widen the row by 3 columns per join; reserve room for
        -- them so the truncated path still fits alongside the other blocks
        local rest = 0
        if s_str ~= "" then rest = rest + 3 + vlen(s_str) end
        if f_str ~= "" then rest = rest + 3 + vlen(f_str) end
        local room = width - rest
        if room < 1 then return "" end
        return to_ascii(trunc(dim(ws), room))
    end

    local f_str, s_str = flags_str, stats_str
    local path_s = fit_path(f_str, s_str)
    local left = join(path_s, s_str, f_str)

    if vlen(left) > width then
        -- Drop the toast when over width.
        if S.toast and f_str:find(to_ascii(green(S.toast)), 1, true) then
            f_str = ""
            path_s = fit_path(f_str, s_str)
            left = join(path_s, s_str, f_str)
        end
    end
    if vlen(left) > width and f_str ~= "" then
        f_str = ""
        path_s = fit_path(f_str, s_str)
        left = join(path_s, s_str, f_str)
    end
    if vlen(left) > width then
        local stats_room = width - (path_s ~= "" and vlen(path_s) + 3 or 0)
        if stats_room >= 1 then
            s_str = to_ascii(trunc(s_str, stats_room))
        else
            s_str = ""
        end
        path_s = fit_path(f_str, s_str)
        left = join(path_s, s_str, f_str)
        if vlen(left) > width then
            left = to_ascii(trunc(left, width))
        end
    end

    -- right-aligned cell: provider/model · <level> (provider omitted when
    -- unknown; the level always shows, `off` included — spec tui: Footer)
    local provider = (type(S.cfg) == "table" and S.cfg.provider) or nil
    local level = (type(S.cfg) == "table" and type(S.cfg.reasoning) == "string"
        and S.cfg.reasoning) or "off"
    local model_cell = provider
        and (provider .. "/" .. (S.model_name or "?") .. " · " .. level)
        or ((S.model_name or "?") .. " · " .. level)
    set_row(L.footer_row, M.footer_stats(left, dim(model_cell), width))
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
    if not S or not S.busy then return end
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
-- Event shapes produced here (and the only ones handle_key consumes):
--   { kind = "esc" | "enter" | "newline" | "backspace" | "tab" }
--   { kind = "text",  char = string }
--   { kind = "paste", text = string }
--   { kind = "ctrl",  code = number, shift = bool?, alt = bool? }
--   { kind = "alt",   code = number }
--   { kind = "special", name = string, ctrl = bool?, shift = bool? }
--   { kind = "mouse", name = string, col = number, row = number, button = number }
-- No layout, palette, or mode knowledge lives here — decode is pure
-- bytes → event. Terminal quirks (kitty CSI-u, modifyOtherKeys, X11 copy
-- chords) are normalized into the typed fields above before return.

-- kitty keyboard protocol (spec: "Comprehensive keyboard handling in
-- terminals"). We push flag 1 (disambiguate escape codes) at startup and pop
-- it on exit, so modified keys arrive as `CSI <code>; <mods> u` instead of
-- ambiguous legacy bytes. Modifiers are a bit field plus one:
-- shift 1, alt 2, ctrl 4, super 8 (so the encoded value is mask + 1).
local function decode_mods(mask)
    return {
        shift = mask % 2 == 1,
        alt   = math.floor(mask / 2) % 2 == 1,
        ctrl  = math.floor(mask / 4) % 2 == 1,
    }
end

-- xterm modifyOtherKeys uses its own encoding: 2 shift, 3 alt, 4 shift+alt,
-- 5 ctrl, 6 shift+ctrl, 7 alt+ctrl, 8 shift+alt+ctrl (1 = no modifiers).
local function mods_from_xterm(m)
    local shift = m == 2 or m == 4 or m == 6 or m == 8
    local alt   = m == 3 or m == 4 or m == 7 or m == 8
    local ctrl  = m == 5 or m == 6 or m == 7 or m == 8
    return { shift = shift, alt = alt, ctrl = ctrl }
end

-- One key with explicit modifiers -> the same key table read_key builds for
-- legacy bytes, so the rest of the TUI is encoding-agnostic.
local function decode_modified_key(code, mods)
    if code == 27 then return { kind = "esc" } end
    if code == 13 then
        -- Enter stays legacy when unmodified; any modifier means the terminal
        -- sends it here (Shift/Ctrl/Alt+Enter insert a newline). Alt is kept
        -- on the event so the busy pump can tell Alt+Enter (follow-up) from
        -- Shift/Ctrl+Enter (plain newline).
        if mods.shift or mods.ctrl or mods.alt then
            return { kind = "newline", alt = mods.alt or nil }
        end
        return { kind = "enter" }
    end
    if code == 9 then return { kind = "tab" } end
    if code == 127 or code == 8 then return { kind = "backspace" } end
    if mods.ctrl then
        -- legacy ctrl mapping: a-z -> 1..26, space -> 0, rest masked to 0x1f
        local c = code
        if c >= 97 and c <= 122 then c = c - 96
        elseif c == 32 then c = 0
        else c = c % 32 end
        return { kind = "ctrl", code = c, shift = mods.shift, alt = mods.alt }
    end
    if mods.alt and code >= 32 then return { kind = "alt", code = code } end
    -- No modifiers: only terminals reporting every key (flag 8) send text here
    if code >= 32 and code < 57344 then return { kind = "text", char = utf8.char(code) } end
    return { kind = "special", name = "unknown" }
end

-- kitty CSI-u: `<code>[:shifted[:base]] [;<mods>[:event]] [;<text>] u`
local function decode_csi_u(p)
    local code = p:match("^(%d+)")
    if not code then return nil end
    local rest = p:sub(#code + 1)
    local mods_field = rest:match("^[^;]*;([^;]*)") or ""
    local mods = tonumber(mods_field:match("^(%d+)")) or 1
    return decode_modified_key(tonumber(code), decode_mods(mods - 1))
end

-- xterm modifyOtherKeys (mode 2): `27 ; <xterm mods> ; <code> ~`
local function decode_modify_other_keys(p)
    local m, code = p:match("^27;(%d+);(%d+)$")
    if not m then return nil end
    return decode_modified_key(tonumber(code), mods_from_xterm(tonumber(m)))
end

-- Modifier mask from an arrow/Home/End style CSI parameter list: the standard
-- form is `1;<mods>`, and the odd bare `5;` form old terminals sent.
local function legacy_csi_mods(p)
    local m = p:match("^1;(%d+)$") or p:match("^(%d+);$")
    return m and decode_mods(tonumber(m) - 1) or nil
end

-- T176: non-ASCII keys arrive as multibyte UTF-8, but decode_first_byte
-- only owns one byte — the rest of the keypress is already queued behind it.
-- A lead byte pulls its continuation bytes (non-blocking: they arrive
-- atomically with the keypress) and emits ONE text event. A peeked byte that
-- is not a valid continuation starts the next event and is stashed for the
-- next read; a truncated tail emits what arrived (display code degrades it
-- instead of raising). Previously every byte became its own text event, so
-- S.input filled with invalid UTF-8 fragments and vlen raised
-- "invalid UTF-8 code" on any Russian input.
-- M-fields (not chunk locals): ui.lua already sits at Lua's 200-locals
-- limit for the main chunk.
M._byte_stash = {}
function M._read_nb()
    if #M._byte_stash > 0 then return table.remove(M._byte_stash, 1) end
    return tether.read_char_nb()
end

-- Push bytes back to the FRONT of the stash (order preserved) so a
-- fragmented escape sequence is retried whole on the next tick instead of
-- leaking its tail ("[<65;48;31M") into the input as text.
function M._stash_front(list)
    if not list or #list == 0 then return end
    local old = M._byte_stash
    local n = #list
    for i = #old, 1, -1 do old[i + n] = old[i] end
    for i = 1, n do old[i] = list[i] end
end

function M._read_utf8_char(first)
    local need
    if first >= 0xC2 and first <= 0xDF then need = 1
    elseif first >= 0xE0 and first <= 0xEF then need = 2
    elseif first >= 0xF0 and first <= 0xF4 then need = 3
    else return string.char(first) end
    local parts = { string.char(first) }
    for _ = 1, need do
        local b = tether.read_char_nb()
        if b == nil then break end -- truncated arrival: emit what we have
        b = b & 0xFF
        if b < 0x80 or b > 0xBF then
            M._byte_stash[#M._byte_stash + 1] = b
            break
        end
        parts[#parts + 1] = string.char(b)
    end
    return table.concat(parts)
end

-- Decode one already-read first byte; continuation bytes come from
-- read_char_nb (and the paste body from read_char). Shared by read_key and
-- read_key_nb so blocking and non-blocking paths stay identical.
-- nb (non-blocking caller, the busy pump): an escape sequence split across
-- reads must not decode as a lone esc plus a text tail. When the next byte
-- is not available yet, the consumed prefix goes back to the stash front
-- and decode yields nil — the next tick retries the sequence whole.
local function decode_first_byte(c, nb)
    if c == 27 then
        local consumed = { c }
        local function nb_read()
            local b = M._read_nb()
            if b == nil then
                if nb then M._stash_front(consumed) end
                return nil
            end
            consumed[#consumed + 1] = b & 0xFF
            return b
        end
        local function incomplete()
            if nb then return nil end
            return { kind = "esc" }
        end
        local b2 = nb_read()
        if b2 == nil then return incomplete() end
        local c2 = b2 & 0xFF
        if c2 ~= 91 and c2 ~= 79 then
            return { kind = "alt", code = c2 }
        end
        local params = {}
        while true do
            local b3 = nb_read()
            if b3 == nil then return incomplete() end
            local c3 = b3 & 0xFF
            -- digits, ';', ':', '<', '>': ':' carries kitty alternate-key
            -- sub-fields, so it must not terminate the sequence
            if (c3 >= 48 and c3 <= 57) or c3 == 58 or c3 == 59 or c3 == 60 or c3 == 62 then
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
                            -- paste terminator is ESC [ 2 0 1 ~. Match it
                            -- incrementally: a stray ESC (or split arrival)
                            -- flushes as content and can never eat a real
                            -- terminator that starts later.
                            local target = "[201~"
                            local cand = {}
                            local b0 = M._read_nb()
                            if b0 then cand[#cand + 1] = string.char(b0 & 0xFF) end
                            while #cand > 0
                                and target:sub(1, #cand) == table.concat(cand)
                                and #cand < #target do
                                local b = tether.read_char()
                                if b == nil or b == -1 then break end
                                cand[#cand + 1] = string.char(b & 0xFF)
                            end
                            if table.concat(cand) == target then
                                return { kind = "paste", text = table.concat(buf) }
                            end
                            buf[#buf + 1] = string.char(cc)
                            for _, s in ipairs(cand) do buf[#buf + 1] = s end
                        elseif cc >= 32 or cc == 10 then
                            buf[#buf + 1] = string.char(cc)
                        end
                    end
                    return { kind = "paste", text = table.concat(buf) }
                end
                -- kitty CSI-u (we push flag 1) and xterm modifyOtherKeys
                -- (we enable mode 2): both encode one key with modifiers.
                if c3 == 117 and p ~= "" then
                    local kitty = decode_csi_u(p)
                    if kitty then return kitty end
                    return { kind = "special", name = "unknown" }
                end
                -- T18: some terminals report Ctrl+Shift+C (copy) as a CSI
                -- whose final byte is C with a non-arrow params blob. Normalize
                -- to a typed ctrl event so handle_key never re-parses params.
                if p == "4:53;96" and c3 == 67 then
                    return { kind = "ctrl", code = 3, shift = true }
                end
                local names = {
                    [65] = "up", [66] = "down", [67] = "right", [68] = "left",
                    [72] = "home", [70] = "end",
                }
                if names[c3] then
                    local mods = legacy_csi_mods(p)
                    -- X11 fallback: Shift+Ctrl+C as `CSI 1;2 C` — same chord
                    if c3 == 67 and p == "1;2" then
                        return { kind = "ctrl", code = 3, shift = true }
                    end
                    return { kind = "special", name = names[c3],
                             ctrl = mods and mods.ctrl, shift = mods and mods.shift }
                end
                if c3 == 126 then
                    -- modifyOtherKeys: 27;<xterm mods>;<code>~
                    local mok = decode_modify_other_keys(p)
                    if mok then return mok end
                    -- `~` keys carry modifiers as `<code>;<mods>`
                    local base, mp = p:match("^(%d+);(%d+)$")
                    base = base or p
                    local mods = mp and decode_mods(tonumber(mp) - 1) or nil
                    local m = ({ ["1"]="home", ["2"]="insert", ["3"]="delete",
                                 ["4"]="end", ["5"]="pgup", ["6"]="pgdn",
                                 ["7"]="home", ["8"]="end" })[base]
                    if m then
                        return { kind = "special", name = m,
                                 ctrl = mods and mods.ctrl, shift = mods and mods.shift }
                    end
                end
                -- M8/R6: F3 (CSI 1~ with modifier 1;3~ etc) — terminal sends
                -- ESC[13~ / ESC[14~ for F3/Shift+F3 on xterm; match by params
                if c3 == 126 and p == "13" then return { kind = "special", name = "f3" } end
                if c3 == 126 and p == "14" then return { kind = "special", name = "sf3" } end
                -- T17/TW1: mouse SGR (1006) — final byte M (press) / m
                -- (release). Per xterm the params are code;col;row (button
                -- code first: 0 press, 32 release, 64 wheel up, 65 wheel
                -- down; the '<' SGR prefix lands in p and the pattern skips
                -- it). The old col;row;code read the button code from the
                -- last field: every wheel tick decoded as button 5 = unknown,
                -- so the wheel never scrolled and the terminal's arrow
                -- fallback fed history into the input.
                if c3 == 77 or c3 == 109 then
                    local code, col, row = p:match("(%d+);(%d+);(%d+)")
                    code, col, row = tonumber(code), tonumber(col), tonumber(row)
                    local name
                    if code == 0 then name = "press"
                    elseif code == 32 then name = "release"
                    elseif code == 64 then name = "scroll_up"
                    elseif code == 65 then name = "scroll_down"
                    else name = "unknown" end
                    return { kind = "mouse", name = name,
                             col = col, row = row, button = code }
                end
                return { kind = "special", name = "unknown" }
            end
        end
    elseif c == 13 then return { kind = "enter" }
    elseif c == 10 then return { kind = "newline" }
    elseif c == 127 or c == 8 then return { kind = "backspace" }
    elseif c == 9 then return { kind = "tab" }
    elseif c < 32 then return { kind = "ctrl", code = c }
    elseif c >= 0x80 then
        return { kind = "text", char = M._read_utf8_char(c) }
    else
        return { kind = "text", char = string.char(c) }
    end
end

local function read_key()
    -- Blocking: wait on read_char directly when the stash is empty, so no
    -- poll timeout delays the keypress; a stashed lookahead byte goes first.
    local b
    if #M._byte_stash > 0 then b = table.remove(M._byte_stash, 1)
    else b = tether.read_char() end
    if b == nil or b == -1 then return nil end
    return decode_first_byte(b & 0xFF)
end

-- Non-blocking variant for the busy pump: first byte via read_char_nb so a
-- silent turn never stalls on input. Incomplete escape sequences surface as
-- esc (same as a short blocking read); the pump never blocks.
local function read_key_nb()
    local b = M._read_nb()
    if b == nil or b == -1 then return nil end
    return decode_first_byte(b & 0xFF, true)
end

-- ============================================================
-- Command execution
-- ============================================================
local function start_new_session(banner)
    local sid = commands.new(S.workspace, S.model_name)
    if sid then S.session_id = sid end
    if S.cfg then S.cfg._session_id = S.session_id end
    -- pi-style-input-and-footer: the footer's counters are per session
    S.tokens_in, S.tokens_out = 0, 0
    -- a new session knows nothing of the old transcript — drop it too,
    -- otherwise the screen shows messages the agent never saw
    reset_transcript({ { role = "system", text = banner or "↻ New session" } })
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

local function known_providers()
    if M._provider_catalog and M._provider_catalog.ids then
        return M._provider_catalog.ids()
    end
    return { "openai", "anthropic", "gemini" }
end

local function is_known_provider(name)
    if type(name) ~= "string" then return false end
    if M._provider_catalog and M._provider_catalog.get then
        return M._provider_catalog.get(name:lower()) ~= nil
    end
    return name == "openai" or name == "anthropic" or name == "gemini"
end

local function provider_mod(name)
    local glob = rawget(_G, "provider_" .. name)
    if glob then return glob end
    local chunk = loadfile("src/tether/providers/" .. name .. ".lua")
    return chunk and chunk() or nil
end

local function begin_login(provider)
    if S.cfg and S.cfg.non_interactive then
        S.error_banner = "login is interactive only"
        return false
    end
    local pmod = provider_mod(provider)
    local flow = (pmod and pmod.login_flow and pmod.login_flow(S.cfg)) or nil
    -- expand-provider-catalog: presets without their own adapter module get
    -- the generic catalog flow (config-sourced OAuth/device, else nil →
    -- API-key paste). Endpoints are never invented.
    if not flow and M._provider_catalog and M._provider_catalog.login_flow then
        flow = M._provider_catalog.login_flow(S.cfg, provider)
    end
    S.error_banner = nil
    S.login_provider = provider
    S.login_flow = flow
    -- palette-only R5: secret entry is a masked input mode, never a dialog.
    -- buf is a dedicated buffer — never S.input, never a transcript row.
    S.login_secret = { buf = "" }
    -- Best-effort browser open (never blocks login on failure). URL itself
    S.palette_active = false
    S.palette_mode = "command"
    S.palette_items = {}
    S.palette_sel = 1
    S._in_login_palette = nil
    -- Best-effort browser open (never blocks login on failure). URL itself
    -- stays in the hints / dialog, not the transcript.
    if flow and flow.authorize_url and tether and tether.exec then
        local q = "'" .. flow.authorize_url:gsub("'", "'\\''") .. "'"
        pcall(function()
            local ok = tether.exec("xdg-open " .. q .. " >/dev/null 2>&1")
            if not ok then
                tether.exec("open " .. q .. " >/dev/null 2>&1")
            end
        end)
    end
    -- provider-auth: full device flow — request the device/user code pair up
    -- front. The TUI then polls the token endpoint while the user authorizes;
    -- no paste is needed (a paste still works as a manual fallback for flows
    -- without a token endpoint). Polling state rides the flow table.
    if flow and flow.device and flow.device_token_url then
        local auth_mod = rawget(_G, "auth")
        if not auth_mod then
            local chunk = loadfile("src/tether/auth.lua")
            auth_mod = chunk and chunk() or nil
        end
        if auth_mod and auth_mod.device_request and tether and tether.http_stream then
            local ok, res, err = pcall(auth_mod.device_request,
                flow.device_url, flow.client_id, flow.scope)
            if ok and type(res) == "table" then
                flow.device_code = res.device_code
                flow.user_code = res.user_code
                flow.verification_uri = res.verification_uri or flow.device_url
                flow.poll_interval = tonumber(res.interval) or 5
                flow.poll_deadline = os.time() + (tonumber(res.expires_in) or 900)
                flow.poll_next_at = os.time() + flow.poll_interval
                if tether.exec then
                    local vq = "'" .. flow.verification_uri:gsub("'", "'\\''") .. "'"
                    pcall(function()
                        local okv = tether.exec("xdg-open " .. vq .. " >/dev/null 2>&1")
                        if not okv then tether.exec("open " .. vq .. " >/dev/null 2>&1") end
                    end)
                end
            else
                -- device endpoint unreachable: degrade to the paste path
                flow.device_request_error = tostring(err or "device request failed")
            end
        end
    end
    return true
end

-- One device-flow poll tick, called from the busy pump on each paint while
-- login secret mode with a device flow is active. Paces itself via
-- flow.poll_next_at. Lives on M.* (chunk-local limit: 200 locals); the
-- implementation is assigned right after cancel_login's declaration below
-- (it closes over cancel_login).

local function cancel_login()
    S.login_provider = nil
    S.login_flow = nil
    S.login_secret = nil
    -- leave secret-hint palette: back to command mode
    S.palette_active = false
    S.palette_mode = "command"
    S.palette_items = {}
    S.palette_sel = 1
    S._in_login_palette = nil
end

-- provider-auth: one device-flow poll tick, called from the paint path while
-- login secret mode with a device flow is active. Paces itself via
-- flow.poll_next_at; returns "pending" | "granted" | "failed" | nil.
M._device_poll_tick = function()
    local flow = S and S.login_flow
    if not (flow and flow.device and flow.device_code and flow.device_token_url) then
        return nil
    end
    if os.time() >= (flow.poll_deadline or 0) then
        S.error_banner = "device login expired — run /login again"
        cancel_login()
        return "failed"
    end
    if os.time() < (flow.poll_next_at or 0) then return "pending" end
    flow.poll_next_at = os.time() + (flow.poll_interval or 5)
    local auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end
    if not (auth_mod and auth_mod.device_poll) then return nil end
    local ok, res, perr = pcall(auth_mod.device_poll,
        flow.device_token_url, flow.client_id, flow.device_code)
    if not ok or res == nil then
        -- transport hiccup: keep polling until the deadline
        return "pending"
    end
    if type(res) == "table" and type(res.access_token) == "string"
        and res.access_token ~= "" then
        local entry = auth_mod.device_entry and auth_mod.device_entry(res, S.login_provider)
        if entry and auth_mod.set then
            auth_mod.set(nil, S.login_provider, entry)
        end
        if S.cfg and ((S.cfg.provider or "openai") == S.login_provider) then
            S.api_key = entry.access_token
            S.cfg.api_key = entry.access_token
        end
        transcript.append({
            role = "system",
            text = "→ login " .. tostring(S.login_provider)
                .. ": device flow authorized",
        })
        bump_transcript()
        S.error_banner = nil
        cancel_login()
        return "granted"
    end
    local etype = type(res) == "table" and res.error or nil
    if etype == "authorization_pending" or etype == "slow_down" then
        if etype == "slow_down" then
            flow.poll_interval = (flow.poll_interval or 5) + 5
        end
        return "pending"
    end
    S.error_banner = "device login failed: " .. tostring(etype or perr or "unknown")
    cancel_login()
    return "failed"
end

-- Shared store path for secret-mode Enter: OAuth code/redirect vs bare API key.
local function submit_login_secret(raw)
    local value = (type(raw) == "string" and raw:match("^%s*(.-)%s*$")) or ""
    if value == "" then return false end
    local provider = S.login_provider
    local flow = S.login_flow
    if not provider then return false end
    S.login_provider = nil
    S.login_flow = nil
    S.login_secret = nil
    S.palette_active = false
    S.palette_mode = "command"
    S.palette_items = {}
    S.palette_sel = 1
    S._in_login_palette = nil

    local auth_mod = rawget(_G, "auth")
    if not auth_mod then
        local chunk = loadfile("src/tether/auth.lua")
        auth_mod = chunk and chunk() or nil
    end

    local code = nil
    if flow and not flow.device then
        code = value:match("[?&]code=([^&%s]+)")
        if not code and not value:match("^https?://") then
            local looks_key = value:match("^sk[%-%_]")
                or value:match("^AIza")
                or value:match("^xai")
                or value:match("^gsk_")
            if not looks_key and #value >= 4 and #value <= 512
                and not value:find("%s") then
                code = value
            end
        end
    end

    -- expand-provider-catalog: device flow — the pasted value IS the access
    -- token (authorized out-of-band at flow.device_url); no exchange.
    if flow and flow.device then
        local okd = auth_mod and auth_mod.set and auth_mod.set(nil, provider, {
            kind = "oauth",
            access_token = value,
        })
        if not okd then
            S.error_banner = "login store failed"
            return false
        end
        if S.cfg and ((S.cfg.provider or "openai") == provider) then
            S.api_key = value
            S.cfg.api_key = value
        end
        transcript.append({
            role = "system",
            text = "→ login " .. provider .. ": oauth token stored",
        })
        bump_transcript()
        S.error_banner = nil
        return true
    end

    if code and flow then
        local ccommon = rawget(_G, "provider_common")
        if not ccommon then
            local chunk = loadfile("src/tether/providers/common.lua")
            ccommon = chunk and chunk() or nil
        end
        if ccommon and ccommon.url_decode then
            code = ccommon.url_decode(code)
        end
        local pmod = provider_mod(provider)
        local post = auth_mod and auth_mod._post_json
        -- expand-provider-catalog: presets without their own module share
        -- the generic OAuth exchange.
        local exchange = (pmod and pmod.token_exchange)
            or (ccommon and ccommon.oauth_token_exchange)
        local entry = exchange and exchange(post, flow, code, os.time())
        if not entry then
            S.error_banner = "oauth exchange failed"
            S.login_provider = provider
            S.login_flow = flow
            -- re-enter secret mode (palette-only)
            S.login_secret = { buf = "" }
            return false
        end
        local ok = auth_mod and auth_mod.set and auth_mod.set(nil, provider, entry)
        if not ok then
            S.error_banner = "login store failed"
            return false
        end
        if S.cfg and ((S.cfg.provider or "openai") == provider) then
            S.api_key = entry.access_token
            S.cfg.api_key = entry.access_token
        end
        transcript.append({
            role = "system",
            text = "→ login " .. provider .. ": oauth token stored",
        })
        bump_transcript()
        S.error_banner = nil
        return true
    end

    local ok = auth_mod and auth_mod.set and auth_mod.set(nil, provider, {
        kind = "api_key",
        access_token = value,
    })
    if not ok then
        S.error_banner = "login store failed"
        return false
    end
    if S.cfg and ((S.cfg.provider or "openai") == provider) then
        S.api_key = value
        S.cfg.api_key = value
    end
    transcript.append({
        role = "system",
        text = "→ login " .. provider .. ": credential stored",
    })
    bump_transcript()
    S.error_banner = nil
    return true
end

-- palette-only R2: Enter/mouse actions for picked resume/model rows.
-- One local (file is at the 200-local limit).
local pick = {}
function pick.resume(id)
    if not id then return end
    -- §6.8 /resume: actually load the picked session
    local sid, messages = commands.resume(id)
    if sid then
        S.session_id = sid
        if S.cfg then S.cfg._session_id = sid end
        -- pi-style-input-and-footer: a resumed session starts its
        -- counters over; the old session's totals are not this one's
        S.tokens_in, S.tokens_out = 0, 0
        -- the picked session replaces the visible transcript;
        -- appending would mix two conversations on one screen
        transcript.seed(messages or {})
        transcript.append(
            { role = "system", text = "↻ session " .. tostring(sid):sub(1, 8) .. " resumed" })
        bump_transcript()
    end
end
function pick.model(item, provider)
    local label = (type(item) == "table" and item.label) or item
    if not label then return end
    local model_id = label:match("^model_set:(.*)$") or label
    local prov = provider
    if prov == nil and type(item) == "table" then prov = item.provider end
    if type(prov) == "string" and prov ~= "" and S.cfg
        and S.cfg.provider ~= prov then
        -- picking another provider's model switches provider and
        -- re-resolves everything provider-scoped (endpoint, key env, key),
        -- so the next turn hits the new endpoint at once. Resolving only
        -- the key left base_url baked for the old provider: the turn then
        -- reached the old endpoint with the new model name and failed
        -- until a restart re-baked the URL.
        S.cfg.provider = prov
        S.cfg._auth_style = nil
        local cfgmod = rawget(_G, "config")
        -- endpoint re-resolution must not clobber the active config module:
        -- a test/dev stub may carry api_key without for_provider.
        local for_provider = (type(cfgmod) == "table" and cfgmod.for_provider)
            or nil
        if type(for_provider) ~= "function" then
            local chunk = loadfile("src/tether/config.lua")
            local real = chunk and chunk() or nil
            if type(real) == "table" then for_provider = real.for_provider end
        end
        if type(for_provider) == "function" then
            local ok, c2 = pcall(for_provider, S.cfg, prov)
            if ok and type(c2) == "table" then
                -- model is assigned below from the pick (for_provider would
                -- fall back to the catalog default), never from c2.
                S.cfg.base_url = c2.base_url
                S.cfg.api_key_env = c2.api_key_env
                S.cfg.provider_env = c2.provider_env
            end
        end
        if type(cfgmod) == "table" and cfgmod.api_key then
            local ok, key = pcall(cfgmod.api_key, S.cfg)
            S.api_key = (ok and type(key) == "string" and key) or ""
            S.cfg.api_key = S.api_key
        else
            S.api_key = ""
        end
    end
    S.model_name = model_id
    if S.cfg then S.cfg.model = model_id end
    -- T177: persist the pick to the machine-managed side file so a restart
    -- reloads it via config.load. Best-effort (pcall): the in-memory state
    -- above already applies for this session.
    do
        local cfgmod = rawget(_G, "config")
        if type(cfgmod) ~= "table" or type(cfgmod.persist_keys) ~= "function" then
            local chunk = loadfile("src/tether/config.lua")
            cfgmod = (chunk and chunk()) or nil
        end
        if cfgmod and cfgmod.persist_keys then
            local home = (S.cfg and S.cfg._auth_home) or os.getenv("HOME") or ""
            -- dynamic-provider-catalog: a providerless pick keeps the
            -- current provider — persist skips nil keys, so never bake a
            -- hardcoded fallback into the file (it used to write "openai").
            local prov = (S.cfg and S.cfg.provider) or nil
            pcall(cfgmod.persist_keys, home, { provider = prov, model = model_id })
        end
    end
    local where = (type(prov) == "string" and prov ~= "") and (prov .. "/") or ""
    transcript.append({ role = "system", text = "→ model: " .. where .. model_id })
    bump_transcript()
end
-- add-reasoning-level: apply a level from /think or its picker — in-memory
-- first, then best-effort persistence (a failed write keeps the session on
-- the picked level), then the echo row, exactly like pick.model.
function pick.think(level)
    if S.cfg then S.cfg.reasoning = level end
    do
        local cfgmod = rawget(_G, "config")
        if type(cfgmod) ~= "table" or type(cfgmod.persist_keys) ~= "function" then
            local chunk = loadfile("src/tether/config.lua")
            cfgmod = (chunk and chunk()) or nil
        end
        if cfgmod and cfgmod.persist_keys then
            local home = (S.cfg and S.cfg._auth_home) or os.getenv("HOME") or ""
            pcall(cfgmod.persist_keys, home, { reasoning = level })
        end
    end
    transcript.append({ role = "system", text = "→ thinking: " .. level })
    bump_transcript()
end

-- add-llm-compaction: `rest` is the free text after the command word
-- (e.g. focus instructions for /compact).
local function execute_command(cmd, rest)
    input_clear()
    debug_log("command: " .. tostring(cmd))
    if cmd == "quit" then S.quit = true; return end
    -- M9: /help, /status, /log removed per user request (unknown commands
    -- fall through to the warning below)
    if cmd == "clear" then
        -- §6.8: clears in-memory transcript only; disk session untouched
        reset_transcript({})
        return
    end
    if cmd == "compact" then
        -- force summarization (threshold bypassed); optional focus text
        local focus = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if focus == "" then focus = nil end
        local summary = commands.compact(S.cfg, S.api_key or "", focus)
        if summary ~= nil then
            if type(summary) == "string" and summary ~= "" then
                transcript.append({ role = "system", text = summary })
            else
                transcript.append({ role = "separator", text = "summary" })
            end
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
    if cmd == "copy" then
        -- 5.2: open the copy palette; targets are built from the transcript
        local targets = M.copy_targets(transcript.entries())
        local items = {}
        for _, tg in ipairs(targets) do
            items[#items + 1] = { label = tg.name, desc = tostring(tg.bytes) .. " bytes", copy = tg }
        end
        S.palette_mode = "copy"
        S.palette_active = true
        S.palette_items = items
        S.palette_sel = 1
        S._in_copy_palette = true
        return
    end
    -- unified-slash-palette: /skills removed — skills are entries of the one
    -- palette, so the separate palette mode and the [skill: …] reference are gone
    -- expand-provider-catalog: model items builder, reused when a background
    -- refresh lands while the palette is open (module field: file-local
    -- budget is reserved for state).
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
    if cmd == "model" then
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
        return
    end
    if cmd == "resume" then
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
        return
    end
    -- add-provider-login: interactive credential flow / store clear
    if cmd == "login" then
        local provider = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if S.cfg and S.cfg.non_interactive then
            S.error_banner = "login is interactive only"
            return
        end
        -- Bare /login → shared palette in login mode (same mechanism as
        -- /copy/slash menu); never a silent default to the active provider.
        if provider == "" then
            local active = (S.cfg and S.cfg.provider) or "openai"
            local items = {}
            for _, name in ipairs(known_providers()) do
                items[#items + 1] = {
                    label = name,
                    desc = (name == active) and "active" or "",
                }
            end
            S.error_banner = nil
            S.palette_mode = "login"
            S.palette_active = true
            S.palette_items = items
            S.palette_sel = 1
            S._in_login_palette = true
            return
        end
        if not is_known_provider(provider) then
            S.error_banner = "unknown provider: " .. provider
            return
        end
        provider = provider:lower()
        begin_login(provider)
        return
    end
    if cmd == "logout" then
        local provider = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if provider == "" then provider = S.cfg and S.cfg.provider or "openai" end
        if not is_known_provider(provider) then
            S.error_banner = "unknown provider: " .. provider
            return
        end
        provider = provider:lower()
        S.login_provider = nil
        S.login_flow = nil
        local auth_mod = _G.auth
        if auth_mod and auth_mod.delete then
            auth_mod.delete(nil, provider)
        end
        -- confirmation line: provider name only — never token material
        transcript.append({
            role = "system",
            text = "→ logout " .. provider .. ": stored credential removed",
        })
        bump_transcript()
        return
    end
    -- add-reasoning-level: reasoning level — a level argument applies
    -- directly, no argument opens the level picker in the shared palette.
    if cmd == "think" then
        local level = (type(rest) == "string" and rest:match("^%s*(.-)%s*$")) or ""
        if level == "" then
            local ORDER = { "off", "low", "medium", "high" }
            local cur = (S.cfg and S.cfg.reasoning) or "off"
            local items = {}
            for _, lv in ipairs(ORDER) do
                items[#items + 1] = { label = lv,
                    desc = (lv == cur) and "current" or "" }
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
            S.error_banner = "unknown thinking level: " .. level
            return
        end
        pick.think(level)
        return
    end
end
-- Test seam: drive slash dispatch without going through the byte pump.
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

-- Forward decls: handle_agent_event (above) calls pump_keys; pump_keys calls
-- handle_key. Both are assigned below — must be locals in scope first.
local handle_key
local pump_keys

local function handle_agent_event(ev)
    if not ev or not ev.type then return end
    -- add-steering-input: drain mid-turn keys on every event tick so Enter /
    -- Alt+Enter / Escape work while the agent is busy (no second turn).
    -- Returns whether it handled anything: a scroll drained here must repaint
    -- at once instead of waiting out the delta throttle below.
    local pumped = pump_keys()
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
                    body = body .. "\n⚠ potentially dangerous command"
                end
            elseif args.content and args.path then
                body = "write → " .. args.path .. " (" .. #args.content .. " B)"
            end
            local options = {"[1/y] once     allow once",
                             "[2/a] session  allow until the session ends",
                             "[3/A] always   save to auto_approve",
                             "[4/n] deny     decline",
                             "[5/Esc] cancel abort the agent turn"}
            S.confirmation = {
                label = label,
                body = body,
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
-- Confirmation/ask/secret own the keyboard first — pump is a no-op then.
-- Drains everything available in one tick (not one key per event).
-- Returns whether any key was handled (callers repaint on true).
pump_keys = function()
    if not S or not S.busy then return false end
    if S.confirmation or S.ask or S.login_secret then return false end
    local handled = false
    while true do
        local k = read_key_nb()
        if not k then break end
        handled = true
        handle_key(k)
        if not S or not S.busy then break end
        if S.confirmation or S.ask or S.login_secret then break end
    end
    return handled
end
M._pump_keys = function() if S then return pump_keys() end return false end

-- Shared submit path for Enter / Alt+Enter while busy: user row now, queue
-- FIFO, clear input. Does not start a turn.
local function enqueue_busy(kind)
    local text = S.input
    if text:match("^%s*$") then return end
    local q = kind == "followup" and S.followup_queue or S.steer_queue
    if not queue_push(q, text) then
        S.error_banner = "queue full (" .. QUEUE_CAP .. ")"
        return
    end
    push_history(text)
    transcript.append({ role = "user", text = text })
    bump_transcript()
    input_clear()
    S.error_banner = nil
    S.scroll = 0
    S.user_scrolled = false
end
M._enqueue_busy = function(kind) if S then enqueue_busy(kind) end end

-- Escape while busy with a non-empty queue: steers first, then follow-ups,
-- one per line (submission order across both queues is not tracked — the
-- spec fixes steering-first order). Empty queues: leave the input alone
-- (handle_key's esc branch clears / no-ops as before).
local function restore_queues()
    if not S then return end
    local parts = {}
    for _, t in ipairs(S.steer_queue or {}) do parts[#parts + 1] = t end
    for _, t in ipairs(S.followup_queue or {}) do parts[#parts + 1] = t end
    S.steer_queue = {}
    S.followup_queue = {}
    if #parts == 0 then
        input_clear()
        return
    end
    S.input = table.concat(parts, "\n")
    S.cursor = #S.input
    palette_sync()
end
M._restore_queues = function() if S then restore_queues() end end

-- ! / !! parser: nil = not a bang; "empty" = bang with no command;
-- ("bang"|"double", cmd) = runnable.
local function parse_bang(s)
    if type(s) ~= "string" or s:sub(1, 1) ~= "!" then return nil end
    local double = s:sub(2, 2) == "!"
    local cmd = double and s:sub(3) or s:sub(2)
    cmd = cmd:match("^%s*(.-)%s*$") or ""
    if cmd == "" then return "empty" end
    return double and "double" or "bang", cmd
end
M._parse_bang = parse_bang

-- Run a bang line through the shared run-tool path (workspace, timeout, env).
-- Renders a tool-style row; ! stores a bounded excerpt for the next message;
-- !! never touches history or bang_context.
local function run_bang(s)
    local kind, cmd = parse_bang(s)
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
M._wire_steer_source = wire_steer_source

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
            -- A built-in command runs (so /CLEAR behaves like /clear); a name
            -- that resolves to a discovered skill falls through to the ordinary
            -- submit path below, so the agent receives it as a user message;
            -- anything else keeps the old command path.
            local name = word:lower()
            if command_set()[name] then
                execute_command(name, rest)
                return
            end
            if not palette_skill_named(name) then
                execute_command(word, rest)
                return
            end
        end
    end
    -- add-steering-input: bang runs after slash resolution, never to the model
    local bang = parse_bang(trimmed)
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
        S.scroll = math.max(0, M.transcript_height(layout().w) - 1)
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
M._toggle_all_entries = toggle_all_entries

local function toggle_newest_visible_tool()
    local L = layout()
    local total = ensure_index(L.w)
    local bottom = total - S.scroll
    if bottom > total then bottom = total end
    if bottom < 1 then bottom = 1 end
    local top = bottom - L.transcript_h + 1
    if top < 1 then top = 1 end
    local lo = entry_of_row(top, L.w) or 0
    local hi = entry_of_row(math.min(total, bottom), L.w) or -1
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
M._toggle_newest_visible_tool = toggle_newest_visible_tool

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

-- Drop the last UTF-8 codepoint from an editor buffer.
local function editor_backspace(text)
    if text == nil or text == "" then return "" end
    local i = #text
    while i > 0 do
        local b = text:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return text:sub(1, i - 1)
end

local function ask_question()
    local a = S.ask
    return a and a.questions and a.questions[a.qidx] or nil
end

local function ask_answer()
    local a = S.ask
    if not a then return nil end
    a.answers[a.qidx] = a.answers[a.qidx] or { selected = {}, other = "", notes = {} }
    return a.answers[a.qidx]
end

-- Toggle one option of a multi question, keeping toggle order.
local function ask_toggle(answer, option)
    if not (answer and option) then return end
    local selected = answer.selected or {}
    for i, label in ipairs(selected) do
        if label == option.label then
            table.remove(selected, i)
            answer.selected = selected
            return
        end
    end
    selected[#selected + 1] = option.label
    answer.selected = selected
end

-- Close the block and hand the answer (or the cancellation) to the agent, then
-- resume the turn exactly the way resolve_confirmation does. A cancellation is
-- an answer the model can act on — the turn continues either way.
local function resolve_ask(cancelled)
    local a = S.ask
    if not a then return end
    local questions, answers = a.questions or {}, a.answers or {}
    S.ask = nil
    transcript.append({
        role = "system",
        text = "→ ask: " .. (cancelled and ask.CANCELLED_TEXT or ask.summary(questions, answers)),
    })
    turn.finish(S)
    local ok, err = turn.answer(a.id,
        cancelled and { cancelled = true } or answers, S.cfg, handle_agent_event)
    if not ok and err then S.error_banner = tostring(err) end
    bump_transcript()
    sync_tail()

    local ok2, err2 = turn.continue(S, S.cfg, S.api_key or "", handle_agent_event, function()
        sync_tail()
        paint(true)
    end)
    if not ok2 and err2 then S.error_banner = tostring(err2) end
    bump_transcript()
    sync_tail()
    after_turn_settle()
end

-- The current question is answered: move to the next one, or hand the whole
-- set to the agent once the last one is done.
local function ask_advance()
    local a = S.ask
    if not a then return end
    if a.qidx < #a.questions then
        a.qidx = a.qidx + 1
        a.sel = 1
        a.mode = "list"
        a.note_sel = nil
        a.editor = ""
        sync_tail()
    else
        resolve_ask(false)
    end
end

local function handle_ask_key(k)
    local a = S.ask
    if not a then return end
    local q = ask_question()
    if not q then resolve_ask(true); return end
    local n = #q.options
    local freeform_row = n + 1
    local answer = ask_answer()

    -- --- editors: characters and backspace edit the buffer ----------------
    if a.mode == "other" or a.mode == "note" then
        if k.kind == "esc" then
            -- discard this editor session's edits; the set stays open
            a.mode = "list"
            a.note_sel = nil
            a.editor = ""
            sync_tail()
            return
        end
        if k.kind == "enter" then
            local text = a.editor or ""
            if a.mode == "other" then
                answer.other = text
            else
                local opt = q.options[a.note_sel]
                if opt then
                    if text ~= "" then answer.notes[opt.label] = text
                    else answer.notes[opt.label] = nil end
                end
            end
            a.mode = "list"
            a.note_sel = nil
            a.editor = ""
            sync_tail()
            return
        end
        if k.kind == "backspace" then
            a.editor = editor_backspace(a.editor)
            sync_tail()
            return
        end
        if k.kind == "text" then
            a.editor = (a.editor or "") .. (k.char or "")
            sync_tail()
            return
        end
        if k.kind == "paste" then
            a.editor = (a.editor or "") .. ((k.text or ""):gsub("[%r%n]+", " "))
            sync_tail()
            return
        end
        return
    end

    -- --- list mode -------------------------------------------------------
    if k.kind == "esc" then resolve_ask(true); return end
    if k.kind == "special" then
        if k.name == "up" then
            a.sel = math.max(1, a.sel - 1)
            sync_tail()
        elseif k.name == "down" then
            a.sel = math.min(freeform_row, a.sel + 1)
            sync_tail()
        elseif k.name == "left" and a.qidx > 1 then
            -- back to the previous question, its answer still in place
            a.qidx = a.qidx - 1
            a.sel = 1
            sync_tail()
        end
        return
    end
    if k.kind == "tab" then
        -- Tab edits the highlighted row: a note on an option, the freeform
        -- answer on the freeform row (which Enter submits once it holds text)
        if a.sel <= n then
            local opt = q.options[a.sel]
            a.mode = "note"
            a.note_sel = a.sel
            a.editor = (answer.notes and answer.notes[opt.label]) or ""
            sync_tail()
        elseif a.sel == freeform_row then
            a.mode = "other"
            a.editor = answer.other or ""
            sync_tail()
        end
        return
    end
    if k.kind == "enter" then
        if a.sel == freeform_row then
            if answer.other and answer.other ~= "" then
                ask_advance() -- a committed freeform answer is the answer
            else
                a.mode = "other"
                a.editor = ""
                sync_tail()
            end
            return
        end
        if a.sel <= n then
            if q.multi then
                -- Enter accepts the toggled selection and moves on; Space and
                -- digits are what toggle
                ask_advance()
            else
                answer.selected = { q.options[a.sel].label }
                ask_advance()
            end
        end
        return
    end
    if k.kind == "text" then
        local c = k.char or ""
        if c == " " and q.multi then
            if a.sel <= n then
                ask_toggle(answer, q.options[a.sel])
                sync_tail()
            end
            return
        end
        local digit = tonumber(c)
        if digit and digit >= 1 and digit <= n then
            local opt = q.options[digit]
            if q.multi then
                ask_toggle(answer, opt)
                sync_tail()
            else
                a.sel = digit
                answer.selected = { opt.label }
                ask_advance()
            end
        end
        return
    end
end

local function resolve_confirmation(decision)
    local detail = S.confirmation and S.confirmation.detail
    -- palette-only R3/R6: every decision clears the menu.
    S.confirmation = nil
    S.confirmation_sel = 1
    if detail and agent then
        local needs_resume = true
        local ok, err = turn.confirm(detail.id, decision, S.cfg, handle_agent_event)
        if not ok and err then S.error_banner = tostring(err) end
        transcript.append({
            role = "system",
            text = "→ confirmation: " .. decision .. " (" .. detail.name .. ")",
        })
        if decision == "cancel" then needs_resume = false end
        if needs_resume then
            -- resume the agent loop after confirmation; turn owns begin/finish
            local ok2, err2 = turn.continue(S, S.cfg, S.api_key or "", handle_agent_event, function()
                sync_tail()
                paint(true)
            end)
            if not ok2 and err2 then S.error_banner = tostring(err2) end
        end
        after_turn_settle()
    end
    bump_transcript() -- the decision line appended above
    sync_tail()       -- menu gone, back to the idle input box
end

local function handle_confirmation_key(k)
    if k.kind == "esc" then
        resolve_confirmation("cancel")
        return
    end
    if k.kind == "enter" then
        local sel = S.confirmation_sel
        -- 5 options (palette-only)
        local dec = { [1]="allow", [2]="session", [3]="always", [4]="deny", [5]="cancel" }
        resolve_confirmation(dec[sel] or "deny")
        return
    end
    if k.kind == "text" then
        local c = k.char
        -- palette-only T2: digit shortcuts 1..5 (plus legacy y/a/A/n)
        local digit = tonumber(c)
        if digit and CONFIRM_DIGITS[digit] then
            resolve_confirmation(CONFIRM_DIGITS[digit])
        elseif c == "y" then resolve_confirmation("allow")
        elseif c == "n" then resolve_confirmation("deny")
        elseif c == "a" then resolve_confirmation("session")
        elseif c == "A" then resolve_confirmation("always")
        end
        return
    end
    if k.kind == "special" then
        if k.name == "up" then
            local n = #((S.confirmation and S.confirmation.options) or {})
            if n > 0 then
                S.confirmation_sel = math.max(1, S.confirmation_sel - 1)
                sync_tail() -- selection lives in the menu's rows
            end
        elseif k.name == "down" then
            local n = #((S.confirmation and S.confirmation.options) or {})
            if n > 0 then
                S.confirmation_sel = math.min(n, S.confirmation_sel + 1)
                sync_tail() -- selection lives in the menu's rows
            end
        end
        return
    end
    if k.kind == "mouse" and k.name == "press" then
        -- options are rendered inside the transcript flow; match by column band
        local c = S.confirmation
        if c and c.options and #c.options > 0 then
            local L = layout()
            local total = ensure_index(L.w)
            -- count of transcript rows above the options block
            local above = total - #c.options
            if k.row and k.row >= above + 1 and k.row <= above + #c.options then
                -- account for scroll offset
                local bottom = math.min(total, total - S.scroll)
                local top = bottom - L.transcript_h + 1
                local idx = k.row - top + 1
                local text = (idx >= 1 and idx <= total) and row_text(idx, L.w) or ""
                for i, opt in ipairs(c.options) do
                    if text:find(opt:sub(1, 10), 1, true) then
                        S.confirmation_sel = i
                        local dec = { [1]="allow", [2]="session", [3]="always",
                                      [4]="deny", [5]="cancel" }
                        resolve_confirmation(dec[i] or "deny")
                        break
                    end
                end
            end
        end
    end
end

handle_key = function(k)
    if not k then return end

    -- 5.4: one-shot toast — cleared by any keypress, no timer
    if S.toast then S.toast = nil end

    -- palette-only R5: secret entry owns the keyboard while active
    -- (before confirmation/palette — S.login_secret is the mode flag).
    if S.login_secret then
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

    if S.confirmation then handle_confirmation_key(k); return end
    -- add-ask-tool: the question block owns the keyboard while it is open
    if S.ask then handle_ask_key(k); return end

    -- palette-only R4: Enter/Esc dismiss the one-line error banner.
    -- A later Enter submits normally; full text lives in the debug log.
    if (k.kind == "enter" or k.kind == "esc") and S.error_banner then
        S.error_banner = nil
        return
    end

    -- T17: mouse SGR — scroll transcript, click palette/confirmation items.
    -- S.scroll counts rows hidden ABOVE the viewport: wheel up = older rows =
    -- scroll grows; wheel down returns toward the bottom (follow at 0).
    -- Wheel steps 3 rows (not a screen fraction): finer, calmer scrolling —
    -- terminals have no pixels, so this is the smoothest honest step.
    if k.kind == "mouse" then
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
                -- selects nothing
                local win, off = palette_window(L.h, #S.palette_items, S.palette_sel)
                local last = math.min(L.palette_row + win, L.footer_row - 1)
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
                            begin_login(it.label)
                            bump_transcript()
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
                local total = ensure_index(L.w)
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

    -- global ctrl
    if k.kind == "ctrl" then
        -- Ctrl+Shift+C (kitty CSI-u / modifyOtherKeys) copies the last answer
        if k.code == 3 and k.shift then copy_last_assistant(); return end
        if k.code == 17 then S.quit = true; return end         -- Ctrl+Q
        if k.code == 3 then                                     -- Ctrl+C
            if S.busy then
                -- §6.6: first Ctrl+C aborts the stream, keeps received text;
                -- turn.abort() owns the flag — ui never assigns agent.abort_requested
                turn.abort()
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

    -- Ctrl+Up / Ctrl+Down — history recall. Decoder always sets k.ctrl for
    -- kitty `CSI 1;5A`, modifyOtherKeys, and the bare `5;A` form.
    if k.kind == "special" and (k.name == "up" or k.name == "down") and k.ctrl then
        if k.name == "up" then history_prev() else history_next() end
        return
    end

    -- palette mode
    if S.palette_active then
        if S.palette_mode == "copy" then
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
        elseif S.palette_mode == "resume" then
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
        elseif S.palette_mode == "model" then
            -- palette-only R2: model list — Enter applies, Esc closes;
            -- no fall-through for text (list is modal while active).
            local function close_model_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_model_palette = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                close_model_palette()
                if it and it.label then
                    pick.model(it)
                end
                return
            elseif k.kind == "esc" then
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
            end
            return
        elseif S.palette_mode == "think" then
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
        elseif S.palette_mode == "login" then
            -- add-provider-login: bare /login provider picker — same palette
            -- mechanism as the slash menu / /copy; Enter starts the dialog.
            local function close_login_palette()
                S.palette_active = false
                S.palette_mode = "command"
                S.palette_items = {}
                S.palette_sel = 1
                S._in_login_palette = nil
            end
            if k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                close_login_palette()
                if it and it.label then
                    begin_login(it.label)
                    bump_transcript()
                end
                return
            elseif k.kind == "esc" then
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
            end
            return
        elseif S.palette_mode == "path" then
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
                    completion_apply(S.palette_items[S.palette_sel].label)
                end
                return
            elseif k.kind == "esc" then
                completion_cancel()
                return
            elseif k.kind == "enter" then
                local it = S.palette_items[S.palette_sel]
                if it then
                    S.input = it.label .. " "
                    S.cursor = #S.input
                    completion_commit()
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
            completion_commit()
            palette_sync()
            return
        else
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
            -- fall through for text/backspace so palette_sync runs
        end
    end

    -- 4.2: Tab outside an open palette runs path completion (4.3: gated)
    if k.kind == "tab" and not S.palette_active then
        path_complete_tab()
        return
    end

    -- normal mode
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
    elseif k.kind == "text" then input_insert(k.char)
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
    elseif k.kind == "backspace" then input_backspace()
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

M._handle_key = function(k) if S then handle_key(k) end end
-- Test seam: decode one key from tether.read_char/read_char_nb (no state needed).
M._read_key = function() return read_key() end

-- ============================================================
-- Main
-- ============================================================
-- app_cfg is the already-loaded config from app.run (carries _session_id,
-- CLI overrides and agents-files). Without it (tests/dev) load fresh.
function M.run(app_cfg)
    S = new_state()
    transcript.clear()
    M._byte_stash = {} -- drop any truncated-UTF-8 lookahead from a past run

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
    -- starts empty — seed it so the user sees what the model knows.
    if agent and agent.get_history then
        local okh, hist = pcall(agent.get_history)
        if okh and hist then
            local seeded = transcript.seed(hist)
            if #seeded > 0 then
                transcript.append(
                    { role = "system", text = "↻ session resumed" })
            end
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
                S.palette_items = M._build_model_items(models)
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
            paint(false) -- throttled; picks up bg/resize/mouse changes
        end
        if S.quit then M._loop:stop() end
    end)
    -- A turn started from the stdin dispatch parks the loop inside its own
    -- tick; the synchronous callers (api.stream between steps, the agent's
    -- backoff deadline) find this loop through the module and pump it
    -- nested instead of blocking the OS thread.
    M._reactor.set_active(M._loop)
    M._loop:run()
    M._reactor.set_active(nil)
    M._loop = nil

    if debug_log_fh then pcall(function() debug_log_fh:close() end) end
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
