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
    ["●"] = "*", ["⚙"] = "[t]", ["›"] = ">", ["✗"] = "[x]", ["✓"] = "[ok]", ["✻"] = "*",
    ["↻"] = "[r]", ["⏹"] = "[x]", ["⚠"] = "!", ["▸"] = ">", ["▾"] = "v",
    ["┌"] = "+", ["┐"] = "+", ["└"] = "+", ["┘"] = "+", ["─"] = "-",
    ["│"] = "|", ["•"] = "-", ["…"] = "...", ["▓"] = "#", ["░"] = "-", ["━"] = "#",
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
        -- 7.1: syntax roles (token kinds); default to 16-color codes so
        -- truecolor/256 render with the same palette. ponytail: no brighter
        -- per-depth variants; add one if a 256-color theme gets complaints.
        comment = "2;38", string = "32", number = "33", keyword = "36;1",
    },
    solarized = {
        accent = "36", warn = "33", error = "31", success = "32",
        dim = "2", italic = "3", reverse = "7", bold = "1",
        comment = "2;38", string = "32", number = "33", keyword = "36",
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

-- Display width of a string: strips ANSI SGR, sums per-codepoint widths.
-- (ulen counted escape bytes and gave CJK 1 column — both produced the
-- stray-character artifacts seen while scrolling.)
local function vlen(s)
    if not s or s == "" then return 0 end
    s = s:gsub("\27%[[0-9;?]*[a-zA-Z]", "")
    local w = 0
    for _, cp in utf8.codes(s) do
        w = w + char_width(cp)
    end
    return w
end
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
        local fence = line:match("^%s*%`%`%`%s*(%w*)%s*$")
        if fence then
            -- code block: framed, soft-wrapped with continuation indent
            local lang = fence ~= "" and (" " .. fence .. " ") or ""
            local inner = math.max(width - 4, 1)
            out[#out + 1] = box.tl .. box.h .. lang
                .. string.rep(box.h, math.max(inner - ulen(lang), 1)) .. box.tr
            -- 7.3: highlight when the fence lang is known (case-insensitive);
            -- unknown/absent langs render plain (7.5). Tokenize each source
            -- line, emit SGR-colored text, then run it through the existing
            -- SGR-aware wrap (zero-width SGR cells, so split boundaries never
            -- land inside a sequence).
            local hl_state = HL_LANGS[fence:lower()] and highlight_enabled() and {} or nil
            i = i + 1
            -- continuation indent needs room; absurdly narrow frames fall
            -- back to plain wrapping with no indent
            local cpre, cw = "  ", inner - 2
            if inner < 4 then cpre, cw = "", inner end
            while i <= #lines and not lines[i]:match("^%s*%`%`%`%s*$") do
                local body_line = lines[i]
                if hl_state then
                    body_line = M.highlight_line(body_line, fence, hl_state)
                end
                for _, seg in ipairs(wrap_words(body_line, inner, cpre, cw)) do
                    out[#out + 1] = box.v .. " " .. seg
                        .. string.rep(" ", math.max(inner - vlen(seg), 0)) .. " " .. box.v
                end
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
    return out
end
M.md_render = md_render

local function trunc(s, maxw)
    if maxw < 1 then return "" end
    if vlen(s) <= maxw then return s end
    local i, width = 1, 0
    while i <= #s do
        local _, finish = s:find("^\27%[[0-9;?]*[a-zA-Z]", i)
        if finish then
            i = finish + 1
        else
            local w = char_width(utf8.codepoint(s, i))
            if width + w > maxw - 1 then break end
            width = width + w
            i = utf8.offset(s, 2, i) or (#s + 1)
        end
    end
    return s:sub(1, i - 1) .. "…" .. ESC .. "[0m"
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
-- M8/R3: digit shortcuts for the confirmation menu (1..6)
local CONFIRM_DIGITS = { "allow", "session", "always", "details", "deny", "cancel" }
M.CONFIRM_DIGITS = CONFIRM_DIGITS

-- §6.6: spinner frames for the "thinking" placeholder and the busy status
-- field. ASCII variant for TERM=dumb / NO_COLOR (M8/R1). Declared here (not
-- next to their first use) so both the transcript tail and the status line
-- can reach them as upvalues.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_ASCII = { "|", "/", "-", "\\" }
M.SPINNER_ASCII = SPINNER_ASCII

local SLASH_COMMANDS = {
    -- M9: /help, /status, /log removed per user request
    { label = "/clear",   desc = "очистить транскрипт",              cmd = "clear" },
    { label = "/compact", desc = "сжать контекст (суммаризация)",    cmd = "compact" },
    { label = "/model",   desc = "сменить модель",                   cmd = "model" },
    { label = "/resume",  desc = "возобновить сессию для workspace", cmd = "resume" },
    { label = "/new",     desc = "начать новую сессию",              cmd = "new" },
    { label = "/quit",    desc = "выход",                            cmd = "quit" },
    { label = "/copy",    desc = "копировать из транскрипта",        cmd = "copy" },
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
-- overlay is gone (M9), so this table is where bindings stay documented.
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
    ["up"]         = "scroll up / cursor up",
    ["down"]       = "scroll down / cursor down",
    ["pgup"]       = "scroll up",
    ["pgdn"]       = "scroll down",
    ["home"]       = "jump to top (input empty)",
    ["end"]        = "jump to bottom (input empty)",
    ["esc"]        = "cancel/confirmation deny",
    ["1"]          = "confirm allow",
    ["2"]          = "confirm session",
    ["3"]          = "confirm always",
    ["4"]          = "confirm details",
    ["5"]          = "confirm deny",
    ["6"]          = "confirm cancel",
    ["y"]          = "confirm allow",
    ["a"]          = "confirm session",
    ["A"]          = "confirm always",
    ["d"]          = "confirm details",
    ["n"]          = "confirm deny",
}
M.KEYMAP = KEYMAP

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
M._set_overlay = function(ov, data) if S then S.overlay = ov; S.overlay_data = data end end
local debug_log_fh = nil
local function debug_log(msg)
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

        transcript = {},
        transcript_ver = 0,
        known_count = 0,     -- entries seen at the last bump (append detection)

        -- Virtualized transcript model: per-entry row caches plus a prefix-sum
        -- height index (see "Transcript model" below).
        index_w = nil,           -- width the index was built for
        index_start = {},        -- index_start[i] = first row of entry i (1-based)
        index_h = {},            -- index_h[i] = entry height in rows
        index_total = 0,         -- total transcript rows
        index_dirty_from = nil,  -- prefix sums must be rebuilt from this entry
        cached_rows = 0,         -- wrapped rows retained across entries
        use_counter = 0,         -- stamp source for the LRU approximation
        visible_lo = 0,          -- entries framing the viewport (eviction guard)
        visible_hi = -1,
        last_transcript_h = nil,

        confirm_entry = nil,     -- synthetic tail entries
        placeholder_entry = nil,

        input = "",
        cursor = 0,  -- byte offset

        busy = false,
        quit = false,

        -- A: turn feedback. waiting = request sent, no token yet (placeholder
        -- row); streaming = deltas arriving (caret on the newest line).
        waiting = false,
        streaming = false,

        error_banner = nil,

        expand_all = false,
        thinking_visible = true, -- M8 follow-up: overridden from cfg.ui.thinking in run()

        palette_active = false,
        palette_mode = "command",
        palette_items = {},
        palette_sel = 1,
        palette_skills = nil,    -- 1.3: skill rows, resolved once per palette open
        _in_copy_palette = nil,  -- 5.2: set when the /copy palette is open

        -- 5.4: one-shot confirmation; cleared on the next keypress in handle_key
        toast = nil,

        -- 4.2/4.3: path completion state. original = token exactly as typed
        -- before the first Tab; items = candidate labels; sel = current index.
        completion = nil,

        confirmation = nil,
        confirmation_sel = 1,

        overlay = nil,
        overlay_data = nil,

        mouse_enabled = nil, -- M8/R8: last emitted tracking state
        last_transcript_top = nil, -- M9/M10: viewport invalidation for scroll repaint
        last_transcript_w = nil,   -- M10: width guard for scroll-region reuse

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

-- Structural change by appending (new turn, new tool entry, system line):
-- existing entries keep their rows and heights, so this costs O(new entries).
local function bump_transcript()
    S.transcript_ver = S.transcript_ver + 1
    local n = #S.transcript
    local from = (S.known_count or 0) + 1
    for i = from, n do
        local e = S.transcript[i]
        e.pos = i
        e.ver = e.ver or 0
    end
    if from <= n and (not S.index_dirty_from or S.index_dirty_from > from) then
        S.index_dirty_from = from
    end
    S.known_count = n
end

-- In-place change that can affect ANY entry (expand-all, thinking toggle, a new
-- width). Every entry is re-derived, so these stay rare on purpose: content
-- edits go through touch_entry instead.
local function invalidate_all()
    local n = #S.transcript
    for i = 1, n do
        local e = S.transcript[i]
        e.pos = i
        e.ver = (e.ver or 0) + 1
    end
    S.index_dirty_from = 1
    S.transcript_ver = S.transcript_ver + 1
    S.known_count = n
end

-- One entry's content changed (a streamed delta, a tool result): only that
-- entry is re-derived, so a long session never re-measures on a delta.
local function touch_entry(e)
    if not e then return end
    e.ver = (e.ver or 0) + 1
    S.transcript_ver = S.transcript_ver + 1
    local pos = e.pos
    if pos then
        if not S.index_dirty_from or S.index_dirty_from > pos then
            S.index_dirty_from = pos
        end
    else
        S.index_dirty_from = 1 -- unknown position: rebuild from the start
    end
end

-- The whole list was replaced (/, /new, /resume, /clear).
local function reset_transcript(list)
    S.transcript = list or {}
    S.known_count = 0
    S.index_dirty_from = 1
    S.visible_lo, S.visible_hi = 0, -1
    bump_transcript()
end
M._touch_entry = touch_entry
M._invalidate_all = invalidate_all

-- A: spinner frame for this repaint (paint() advances S.spinner_frame).
-- Nil-safe like the other seams: callers may run before run() created S.
local function spinner_glyph()
    local frames = (M._ascii_mode or M._env_ascii or _ascii) and SPINNER_ASCII or SPINNER
    local frame = (S and S.spinner_frame) or 0
    return frames[(frame % #frames) + 1]
end
M.spinner_glyph = spinner_glyph

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

local function layout()
    local total = #input_lines()
    local max_in = (S.cfg and S.cfg.ui and S.cfg.ui.input_max_lines) or 8
    local shown_in = math.min(total, max_in)
    if shown_in < 1 then shown_in = 1 end

    local palette_h = 0
    if S.palette_active and #S.palette_items > 0 then
        -- 2.4: the reserved region follows the window (items + 2); the indicator
        -- row the palette may paint fits inside it (see render_palette)
        local win = palette_window(S.h, #S.palette_items, S.palette_sel)
        palette_h = win + 2
    end
    local error_h = S.error_banner and 1 or 0

    -- M9: hint row removed — its line is returned to the transcript
    -- footer: input block, then 1-row dim separator, then status line — the
    -- separator must be reserved here too (F1b), otherwise it lands on the
    -- last input row and paints over the input field.
    local fixed = shown_in + palette_h + error_h + 1 + 1
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
        separator_row = S.h - 1, -- footer: dim rule between input and status
        status_row = S.h,
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
local PALETTE_SKILL_HINT = "[задача]"

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
        or tools
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
    -- 6.1: palette modes set explicitly (copy/skills) survive input_clear;
    -- palette_sync is a no-op for them via the _in_*_palette flags.
    -- 5.2: the copy palette sets its items explicitly; palette_sync is a no-op
    -- for it via the _in_copy_palette flag (the palette is otherwise derived).
    if not S._in_copy_palette then palette_sync() end
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

local function render_entry(e, width)
    -- Synthetic tail entries go through the same path as real entries so the
    -- height index, the scroll indicator and the parity helper stay consistent.
    if e.virt == "placeholder" then
        -- the spinner frame is painted on this row by render_transcript
        return { "", dim("✻ tether думает…") }
    end
    if e.virt == "confirm" then
        local c = S.confirmation
        if not c then return {} end
        local out = { "", yellow("⚠ " .. (c.label or "подтверждение")) }
        for _, l in ipairs(wrap(c.body or "", width - 2)) do
            out[#out + 1] = "  " .. l
        end
        for i, opt in ipairs(c.options or {}) do
            local t = "  " .. opt
            out[#out + 1] = (i == S.confirmation_sel) and rev(t) or t
        end
        return out
    end
    local role = e.role or "system"
    if role == "separator" then
        -- tui: Turn separators — dim rule with the local submission time
        local label = "── " .. (e.text or "") .. " "
        local fill = width - vlen(label)
        if fill < 1 then fill = 1 end
        return { dim(label .. string.rep("─", fill)) }
    elseif role == "user" then
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
    elseif role == "system" then
        return { dim(e.text or "") }
    elseif role == "tool" then
        -- 3.1: leading status marker; a failed row appends its first error line
        -- (clipped) so the failure is visible without expanding.
        local marker
        if e.status == "pending" then marker = yellow("…")
        elseif e.status == "error" then marker = red("✗")
        else marker = green("✓") end
        local head = marker .. " " .. yellow(e.name or "?")
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
        local out = { head }
        -- 3.3: the full body (including a failed call's error text and a
        -- pending write/patch projection) is behind expansion.
        if e.body and e.body ~= "" and entry_expanded(e) then
            local bl = render_tool_body(e.name, e, math.max(width - 2, 1))
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
    end
    return {}
end

-- ============================================================
-- Transcript model (virtualized: per-entry row caches + height index)
-- ============================================================
-- One render path for everything on screen. Entries are rendered on demand and
-- their wrapped rows cached per entry; the transcript height lives in a
-- prefix-sum index so a repaint touches the viewport instead of the session.
-- The confirmation menu and the waiting placeholder are synthetic tail entries
-- (S.confirm_entry / S.placeholder_entry) so heights, the scroll indicator and
-- the parity helper see them exactly like real entries.
local function visible_count()
    local n = #S.transcript
    if S.confirm_entry then n = n + 1 end
    if S.placeholder_entry then n = n + 1 end
    return n
end

local function entry_at(i)
    local n = #S.transcript
    if i <= n then return S.transcript[i] end
    local k = i - n
    if S.confirm_entry then
        if k == 1 then return S.confirm_entry end
        k = k - 1
    end
    if S.placeholder_entry and k == 1 then return S.placeholder_entry end
    return nil
end

-- Called whenever S.confirmation or S.waiting changes: keeps the synthetic tail
-- entries in sync and invalidates the index from the tail (cheap — they sit
-- last). A fresh confirm entry bumps its version so the menu's rows re-render
-- (the selected option is styled in the rows).
local function sync_tail()
    if S.confirmation then
        S.confirm_entry = S.confirm_entry or { virt = "confirm", ver = 0 }
        S.confirm_entry.ver = (S.confirm_entry.ver or 0) + 1
    else
        S.confirm_entry = nil
    end
    if S.waiting then
        S.placeholder_entry = S.placeholder_entry or { virt = "placeholder", ver = 0 }
    else
        S.placeholder_entry = nil
    end
    local n = #S.transcript + 1
    if not S.index_dirty_from or S.index_dirty_from > n then S.index_dirty_from = n end
end
M._sync_tail = sync_tail

-- Rows this entry would occupy when wrapped to `width`; measured without
-- retaining the rows, so an off-screen entry costs a wrap pass once per
-- content/width change and no cached memory.
local function entry_height(e, width)
    if e.height ~= nil and e.h_w == width and e.h_ver == (e.ver or 0) then return e.height end
    if e.rows and e.rows_w == width and e.rows_ver == (e.ver or 0) then
        e.height, e.h_w, e.h_ver = #e.rows, width, (e.ver or 0)
        return e.height
    end
    local rows = render_entry(e, width)
    e.height, e.h_w, e.h_ver = #rows, width, (e.ver or 0)
    return e.height
end

-- Documented bound on retained wrapped rows: max(4 x viewport, 1024) rows total,
-- and no single entry may pin more than half of it (a giant entry is re-rendered
-- per repaint instead of filling the cache).
local function cache_bound()
    local vh = S.last_transcript_h
    if not vh or vh < 1 then vh = (S.h or 24) - 6 end
    if vh < 1 then vh = 1 end
    return math.max(4 * vh, 1024)
end

local function evict_cached_rows()
    local bound = cache_bound()
    while (S.cached_rows or 0) > bound do
        local best, best_use = nil, nil
        for i = 1, visible_count() do
            -- never evict the entries framing the viewport: they are repainted
            -- immediately, which would make eviction pointless thrash
            if i ~= S.visible_lo and i ~= S.visible_hi then
                local e = entry_at(i)
                if e and e.rows then
                    local u = e.used or 0
                    if not best_use or u < best_use then best, best_use = e, u end
                end
            end
        end
        if not best then return end
        S.cached_rows = (S.cached_rows or 0) - #best.rows
        best.rows, best.rows_w, best.rows_ver = nil, nil, nil
    end
end

local function entry_rows(e, width)
    if e.rows and e.rows_w == width and e.rows_ver == (e.ver or 0) then
        S.use_counter = (S.use_counter or 0) + 1
        e.used = S.use_counter
        return e.rows
    end
    local rows = render_entry(e, width)
    if S.cached_rows and #rows > cache_bound() / 2 then
        return rows -- too big to cache; re-rendered on the next repaint
    end
    if e.rows then S.cached_rows = (S.cached_rows or 0) - #e.rows end
    e.rows, e.rows_w, e.rows_ver = rows, width, (e.ver or 0)
    S.use_counter = (S.use_counter or 0) + 1
    e.used = S.use_counter
    S.cached_rows = (S.cached_rows or 0) + #rows
    evict_cached_rows()
    return rows
end
M.cache_rows = function() return S.cached_rows or 0 end

-- Rebuild the prefix-sum height index, from the first dirty entry (O(1) for a
-- plain append) or from the start when the width changed.
local function ensure_index(width)
    if S.index_w == width and not S.index_dirty_from then return S.index_total end
    local n = visible_count()
    local from, rows = 1, 0
    if S.index_w == width and S.index_dirty_from and S.index_dirty_from <= n then
        from = S.index_dirty_from
        rows = (from > 1) and (S.index_start[from - 1] or 0) or 0
    else
        S.index_start, S.index_h = {}, {}
    end
    for i = from, n do
        local e = entry_at(i)
        local h = e and entry_height(e, width) or 0
        S.index_h[i] = h
        rows = rows + h
        S.index_start[i] = rows - h + 1
    end
    for i = n + 1, #S.index_start do
        S.index_start[i], S.index_h[i] = nil, nil
    end
    S.index_w, S.index_total, S.index_dirty_from = width, rows, nil
    return rows
end

function M.transcript_height(width)
    if not S then return 0 end
    return ensure_index(width or S.w)
end

local function entry_of_row(k, width)
    ensure_index(width)
    local lo, hi, best = 1, visible_count(), nil
    while lo <= hi do
        local mid = (lo + hi) // 2
        local s = S.index_start[mid]
        if s and s <= k then best, lo = mid, mid + 1 else hi = mid - 1 end
    end
    return best
end

local function row_text(k, width)
    local i = entry_of_row(k, width)
    if not i then return "" end
    local e = entry_at(i)
    if not e then return "" end
    local rows = entry_rows(e, width)
    return rows[k - (S.index_start[i] or 0) + 1] or ""
end

-- Parity seam: the same rows the viewport path produces, but for the whole
-- transcript. Tests compare the two to prove virtualization changes nothing.
function M._render_all(width)
    if not S then return {} end
    local out = {}
    ensure_index(width or S.w)
    for i = 1, visible_count() do
        local e = entry_at(i)
        if e then
            for _, r in ipairs(entry_rows(e, width or S.w)) do out[#out + 1] = r end
        end
    end
    return out
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
    -- M10: clamp scroll so the viewport can never move past the top of the
    -- transcript. Over-scroll made top negative and the scroll indicator
    -- report nonsense (⏸ +36 on a 4-line transcript).
    local max_scroll = total - 1
    if max_scroll < 0 then max_scroll = 0 end
    if S.scroll > max_scroll then S.scroll = max_scroll end
    if S.scroll < 0 then S.scroll = 0 end
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
    -- A: live tail — the newest line carries the spinner while no token has
    -- arrived yet, and the caret while deltas are still streaming. Applied at
    -- paint time so the wrapped-line cache stays untouched.
    local tail = ""
    if not S.user_scrolled and total > 0 then
        if S.waiting then tail = " " .. spinner_glyph()
        elseif S.streaming then tail = caret_glyph() end
    end
    -- tui: Scroll position indicator — the same count as the status line, painted
    -- on the newest visible row. Only the rows the viewport needs are rendered:
    -- row_text() maps a transcript row to its entry and caches that entry's rows.
    local marker = ""
    if S.user_scrolled and not S.overlay then
        local hidden = scroll_indicator(total, S.scroll, L.transcript_h)
        if hidden and hidden > 0 then
            marker = ((M._ascii_mode or M._env_ascii or _ascii) and "v" or "↓")
                .. " +" .. hidden
        end
    end
    local last_painted = math.min(total, bottom)
    S.visible_lo = entry_of_row(top, L.w) or 0
    S.visible_hi = entry_of_row(last_painted, L.w) or -1
    for i = 1, L.transcript_h do
        local idx = top + i - 1
        local text = ""
        if idx >= 1 and idx <= total then
            text = row_text(idx, L.w)
        end
        if idx == last_painted and marker ~= "" then
            -- reserve room by cutting the row, like ui.wrap=false does; on a row
            -- too narrow for the marker plus a fragment of content, drop it
            local room = L.w - vlen(marker) - 2
            if room >= 8 then
                text = trunc(text, room) .. " " .. marker
            end
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
    -- footer: dim rule between the input block and the status line (F1b);
    -- ASCII twin is "-".
    if L.separator_row then
        local ascii = M.ascii_active(S.cfg and S.cfg.ui and S.cfg.ui.ascii)
        local sep = string.rep(ascii and "-" or "─", L.w)
        set_row(L.separator_row, dim(sep))
    end
end

local function render_palette(L)
    if not S.palette_active or #S.palette_items == 0 then return end
    -- M9: no frame; selected item is accent-colored, not reverse-video
    -- 2.2/2.3: a window over the ranked list, shifted so the selected row is
    -- inside it, plus a dim pos/total row when the list overflows it. Neither
    -- the separator nor the status row is ever painted here.
    local n = #S.palette_items
    local win, off = palette_window(L.h, n, S.palette_sel)
    local last = L.separator_row - 1
    for i = 1, win do
        local row = L.palette_row + i
        if row > last then break end
        local it = S.palette_items[off + i - 1]
        if it then
            -- 3.1: the argument hint sits after the name when the entry has one
            local label = it.label or ""
            if it.hint then label = label .. " " .. it.hint end
            local text = trunc(string.format(" %-10s %s", label, it.desc or ""), L.w - 2)
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

local function render_status(L)
    local home = os.getenv("HOME") or ""
    local ws = S.workspace
    if home ~= "" and ws:sub(1, #home) == home then
        ws = "~" .. ws:sub(#home + 1)
    end
    -- 5b: mandatory parts in fixed order; flags only while relevant
    local parts = { S.model_name or "?", ws }
    -- 5.4: leading confirmation field (one-shot, cleared by next keypress)
    if S.toast then table.insert(parts, 1, S.toast) end
    -- A: while a turn runs, lead the status line with spinner + elapsed time
    -- (the transcript tail shows the same spinner on its placeholder row).
    if S.busy then
        local secs = S.busy_started_at and (os.time() - S.busy_started_at) or 0
        table.insert(parts, 1, spinner_glyph() .. string.format(" %ds", secs))
    end
    if S.tokens_max and S.tokens_max > 0 then
        -- T47: "4.2k/32k (13%)" — value + budget + percent
        local summarize_at = (S.cfg.context and S.cfg.context.summarize_at) or 0.7
        parts[#parts + 1] = (S.tokens_estimated and "≈" or "") ..
            M.token_usage(S.tokens_used, S.tokens_max, summarize_at)
    end
    -- scroll indicator — hidden rows below while the user scrolled up
    if S.user_scrolled then
        -- O(1) after the index is warm: the status line must not rescan the
        -- transcript every frame (tui: viewport-proportional rendering)
        local hidden = scroll_indicator(M.transcript_height(L.w), S.scroll, L.transcript_h)
        if hidden and hidden > 0 then
            parts[#parts + 1] = ((M._ascii_mode or M._env_ascii or _ascii) and "v" or "↓") .. " +" .. hidden
        end
    end
    -- 5b: mouse flag fades out ~3 s after the effective mode changes
    local mm = S.mouse_mode or (S.cfg.ui and S.cfg.ui.mouse) or "auto"
    if S._mouse_flag_until and os.time() < S._mouse_flag_until
        and not (M._ascii_mode or M._env_ascii or _ascii) then
        parts[#parts + 1] = "🖱 " .. mm
    end
    -- 5b: kb flag only when a protocol was actually detected
    if S.kb_protocol == 1 then
        parts[#parts + 1] = "⌨ kitty"
    elseif S.kb_protocol == 2 then
        parts[#parts + 1] = "⌨ xterm"
    end
    local text = table.concat(parts, " · ")
    text = trunc(text, L.w - 2)
    local pad = L.w - vlen(text) -- M9: display width, not raw char count
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
    -- M9: help/status/log overlays removed per user request
    if ov == "diff" then
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
    -- N2: terminal column counts display cells, not bytes — multibyte input
    -- (кириллица) used to drift the caret left of its real position.
    local term_row = L.input_row + row_in - 1
    local term_col = 3 + vlen(ln.text:sub(1, col))  -- "› " = 2 cols
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
        render_status(L)
    end

    place_cursor(L)
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
local last_paint = 0
local skipped = 0
local function paint(force)
    if not S then return end
    skipped = skipped + 1
    local now = os.clock()
    if not force and skipped < PAINT_MIN_DELTAS and (now - last_paint) < PAINT_INTERVAL then
        return
    end
    last_paint = now
    skipped = 0
    S.spinner_frame = (S.spinner_frame or 0) + 1
    redraw()
end
M._paint = paint

-- ============================================================
-- Key reading
-- ============================================================

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
        -- sends it here (Shift/Ctrl/Alt+Enter insert a newline).
        if mods.shift or mods.ctrl or mods.alt then return { kind = "newline" } end
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
                -- kitty CSI-u (we push flag 1) and xterm modifyOtherKeys
                -- (we enable mode 2): both encode one key with modifiers.
                if c3 == 117 and p ~= "" then
                    local kitty = decode_csi_u(p)
                    if kitty then return kitty end
                    return { kind = "special", name = "unknown", params = p }
                end
                local names = {
                    [65] = "up", [66] = "down", [67] = "right", [68] = "left",
                    [72] = "home", [70] = "end",
                }
                if names[c3] then
                    local mods = legacy_csi_mods(p)
                    return { kind = "special", name = names[c3], params = p,
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
                        return { kind = "special", name = m, params = p,
                                 ctrl = mods and mods.ctrl, shift = mods and mods.shift }
                    end
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
    -- a new session knows nothing of the old transcript — drop it too,
    -- otherwise the screen shows messages the agent never saw
    reset_transcript({ { role = "system", text = banner or "↻ Новая сессия" } })
end

-- M9: load_log_overlay removed together with the /log command

local function execute_command(cmd)
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
    if cmd == "copy" then
        -- 5.2: open the copy palette; targets are built from the transcript
        local targets = M.copy_targets(S.transcript)
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
    if cmd == "model" then
        local ok, models = pcall(api.list_models_live, S.cfg, S.api_key or "")
        if not ok then models = nil end
        if not (models and #models > 0) then
            models = {}
            for _, m in ipairs(api.list_models(S.cfg)) do
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

local function handle_agent_event(ev)
    if not ev or not ev.type then return end
    -- A: remember the tail-decoration state so a transition (placeholder ->
    -- caret, or caret -> nothing) repaints at once instead of waiting out the
    -- delta throttle.
    local was_waiting, was_streaming = S.waiting, S.streaming
    if ev.type == "text_delta" then
        local last = S.transcript[#S.transcript]
        if not last or last.role ~= "assistant" then
            S.transcript[#S.transcript + 1] = { role = "assistant", text = "" }
            last = S.transcript[#S.transcript]
        end
        last.text = (last.text or "") .. (ev.text or "")
        S.waiting = false
        S.streaming = true
        touch_entry(last)
        sync_tail()
    elseif ev.type == "reasoning_delta" then
        local last = S.transcript[#S.transcript]
        if not last or last.role ~= "thinking" then
            S.transcript[#S.transcript + 1] = { role = "thinking", text = "" }
            last = S.transcript[#S.transcript]
        end
        last.text = (last.text or "") .. (ev.text or "")
        S.waiting = false
        S.streaming = true
        touch_entry(last)
        sync_tail()
    elseif ev.type == "tool_call_start" then
        -- pretty-transcript-rendering 2.1/4.5: carry the parsed arguments and
        -- the read-only projection; a pending write/patch previews its diff.
        local proj = ev.projection
        S.transcript[#S.transcript + 1] = {
            role = "tool", id = ev.id or tostring(#S.transcript + 1),
            started_at = os.time(), -- M8/R3: for elapsed display
            name = ev.name or "?", status = "pending", summary = "",
            body = (proj and proj.diff) or "",
            args = ev.args,
            path = proj and proj.path or (ev.args and ev.args.path),
            projection = proj,
        }
        S.waiting = false
        S.streaming = false
        bump_transcript()
        sync_tail()
    elseif ev.type == "tool_result" then
        local target
        for i = #S.transcript, 1, -1 do
            local e = S.transcript[i]
            if e.role == "tool" and e.id == ev.id then
                e.status = ev.error and "error" or "ok"
                e.summary = ev.summary or ""
                -- 4.5: a denial/cancellation drops the preview and leaves no
                -- result body; any other outcome replaces the preview.
                local dropped = ev.error == "denied by user" or ev.error == "cancelled by user"
                e.body = dropped and "" or (ev.body or "")
                e.projection = nil
                target = e
                break
            end
        end
        touch_entry(target)
    elseif ev.type == "error" then
        S.error_banner = ev.message or "ошибка"
    elseif ev.type == "aborted" then
        S.waiting = false
        S.streaming = false
        -- 4.5: an aborted call drops its pending projection
        for _, e in ipairs(S.transcript) do
            if e.role == "tool" and e.status == "pending" then
                e.projection = nil
                e.body = ""
            end
        end
        S.transcript[#S.transcript + 1] = { role = "system", text = "⏹ прервано (Ctrl+C)" }
        bump_transcript()
        sync_tail()
    elseif ev.type == "usage" and ev.usage then
        if ev.usage.used then S.tokens_used = ev.usage.used end
        S.tokens_estimated = false
    elseif ev.type == "context_compressed" then
        S.transcript[#S.transcript + 1] = { role = "system", text = "── summary ──" }
        S.tokens_estimated = true
        bump_transcript()
    elseif ev.type == "retry" then
        S.transcript[#S.transcript + 1] = {
            role = "system",
            text = string.format("↻ повтор %d (ждём %.1fs): %s",
                ev.attempt or 1, ev.delay or 0.5, ev.reason or ""),
        }
        bump_transcript()
    end
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
            S.waiting = false
            S.streaming = false
            -- the menu replaces the placeholder: both are synthetic tail entries
            sync_tail()
        end
    end
    if not S.user_scrolled then S.scroll = 0 end
    -- A: repaint now — the main loop only redraws between keypresses, so
    -- without this nothing the model produced would be visible mid-turn.
    -- Deltas are throttled inside paint(); every other event repaints at once.
    local force = ev.type ~= "text_delta" and ev.type ~= "reasoning_delta"
        and ev.type ~= "usage"
    if S.waiting ~= was_waiting or S.streaming ~= was_streaming then force = true end
    paint(force)
end

M._handle_agent_event = handle_agent_event

local function commit_input()
    local text = S.input
    if text:match("^%s*$") then
        input_clear()
        return
    end
    local trimmed = text:match("^%s*(.-)%s*$")
    if trimmed:sub(1, 1) == "/" then
        local word = trimmed:match("^/(%w+)")
        if word then
            -- unified-slash-palette 4.2: names compare without regard to case.
            -- A built-in command runs (so /CLEAR behaves like /clear); a name
            -- that resolves to a discovered skill falls through to the ordinary
            -- submit path below, so the agent receives it as a user message;
            -- anything else keeps the old command path.
            local name = word:lower()
            if command_set()[name] then
                execute_command(name)
                return
            end
            if not palette_skill_named(name) then
                execute_command(word)
                return
            end
        end
    end
    push_history(text)
    -- Turn separators (tui: Turn separators): one dim timestamp row per new turn,
    -- placed before the user row. It is a transcript row — it scrolls and counts
    -- toward the height — but it never reaches the agent.
    if not (S.cfg and S.cfg.ui and S.cfg.ui.turn_separators == false) then
        S.transcript[#S.transcript + 1] = { role = "separator", text = os.date("%H:%M") }
    end
    S.transcript[#S.transcript + 1] = { role = "user", text = text }
    bump_transcript()
    input_clear()
    S.error_banner = nil
    S.scroll = 0
    S.user_scrolled = false

    S.busy = true
    S.busy_started_at = os.time() -- M8/R3: elapsed counter
    -- A: turn feedback — the placeholder repaints immediately after Enter
    S.waiting = true
    S.streaming = false
    sync_tail()
    agent.abort_requested = false
    paint(true)
    local ok, err = pcall(agent.turn, S.cfg, S.api_key or "", text, handle_agent_event)
    S.busy = false
    S.busy_started_at = nil
    S.waiting = false
    S.streaming = false
    sync_tail()
    agent.abort_requested = false
    if not ok and err then
        S.error_banner = tostring(err)
    end
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
        S.mouse_mode = mode -- 5b: effective config mode, shown in the fading flag
        S._mouse_flag_until = os.time() + 3 -- 5b: flag visible for ~3 s after change
        w(M.mouse_tracking_seqs(want))
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
        -- Empty input: scroll the transcript, not history (history is
        -- now Ctrl+Up / Ctrl+Down). Non-empty: move cursor or scroll at edge.
        if S.input == "" then
            S.scroll = S.scroll + 1
            S.user_scrolled = true
        elseif not move_cursor_up() then
            S.scroll = S.scroll + 1
            S.user_scrolled = true
        end
    elseif k.name == "down" then
        if S.input == "" then
            S.scroll = math.max(0, S.scroll - 1)
            if S.scroll == 0 then S.user_scrolled = false end
        elseif not move_cursor_down() then
            S.scroll = math.max(0, S.scroll - 1)
            if S.scroll == 0 then S.user_scrolled = false end
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
    for _, e in ipairs(S.transcript) do e.expand_state = nil end
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
        for i = #S.transcript, 1, -1 do
            if S.transcript[i].role == "tool" then chosen = S.transcript[i]; break end
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
    for i = #S.transcript, 1, -1 do
        if S.transcript[i].role == "assistant" then
            last_text = S.transcript[i].text or ""
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
            add("последний ответ", t[i].text)
            break
        end
    end
    -- last tool output: last tool entry with body
    for i = #t, 1, -1 do
        if t[i].role == "tool" then
            local body = t[i].body or t[i].text or ""
            if body ~= "" then add("последний вывод инструмента", body) end
            break
        end
    end
    -- last fenced block, scanned from the newest entry
    for i = #t, 1, -1 do
        local fb = fenced_block_of(t[i].text)
        if fb ~= "" then add("последний код-блок", fb); break end
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
    add("весь транскрипт", table.concat(parts, "\n"))
    return out
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
            -- A: same turn feedback as commit_input — the continued turn also
            -- streams in from inside this key handler
            S.waiting = true
            S.streaming = false
            sync_tail()
            paint(true)
            local ok2, err2 = pcall(agent.continue, S.cfg, S.api_key or "", handle_agent_event)
            S.busy = false
            S.waiting = false
            S.streaming = false
            if not ok2 and err2 then S.error_banner = tostring(err2) end
        end
    end
    bump_transcript() -- the decision line appended above
    sync_tail()       -- menu gone (or the placeholder is back for the resume)
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
    -- M9: "?" binding removed with the help overlay; plain q inside overlays
    -- is no longer a close key (it was ambiguous while typing "q")
    if k.kind == "text" and k.char == "q" and ov == "diff" then
        S.overlay = nil; S.overlay_data = nil
        bump_transcript()
        return
    end
    -- Error overlay: Esc OR Enter dismisses. commit_input clears
    -- S.error_banner, so after dismissal a new message can be sent.
    if ov == "error" then
        if k.kind == "enter" then
            S.overlay = nil; S.overlay_data = nil
            bump_transcript()
        end
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
                -- the picked session replaces the visible transcript;
                -- appending would mix two conversations on one screen
                reset_transcript({})
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

    -- 5.4: one-shot toast — cleared by any keypress, no timer
    if S.toast then S.toast = nil end

    if S.overlay then handle_overlay_key(k); return end
    if S.confirmation then handle_confirmation_key(k); return end

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
            if S.palette_active and k.row >= L.palette_row + 1 then
                -- 2.5: hit-test through the window offset; the indicator row
                -- selects nothing
                local win, off = palette_window(L.h, #S.palette_items, S.palette_sel)
                local last = math.min(L.palette_row + win, L.separator_row - 1)
                if k.row <= last then
                    local it = S.palette_items[off + (k.row - L.palette_row) - 1]
                    if it then
                        if it.skill then
                            palette_pick_skill(it)
                        elseif it.cmd then
                            execute_command(it.cmd)
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

    -- Ctrl+Up / Ctrl+Down — history recall. read_key decodes the modifiers
    -- (kitty `CSI 1;5A`, modifyOtherKeys, the odd bare `5;A` form); the string
    -- heuristics stay as a fallback for terminals that drop the modifier.
    -- (Ctrl+Shift+C was already caught above.)
    if k.kind == "special" and (k.name == "up" or k.name == "down") then
        local params = k.params or ""
        local is_ctrl = k.ctrl or params:match(";5%a$") or params:match("^1;5%a$")
            or params:match("^%a$")
        if is_ctrl then
            if k.name == "up" then history_prev() else history_next() end
            return
        end
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
                    S.toast = mark .. " скопировано " .. tostring(sz) .. " B"
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

    -- Session is created by app.lua (cfg._session_id); resume path reuses it.
    if S.cfg._session_id then
        S.session_id = S.cfg._session_id
    elseif session and session.new_session then
        local ok, id = pcall(session.new_session, S.workspace, S.model_name)
        S.session_id = ok and id or "?"
        S.cfg._session_id = S.session_id
    end

    -- Resume (-r): app.lua restored the agent history, but the transcript
    -- starts empty — seed it so the user sees what the model knows.
    if agent and agent.get_history then
        local okh, hist = pcall(agent.get_history)
        if okh and hist then
            for _, e in ipairs(transcript_entries(hist)) do
                S.transcript[#S.transcript + 1] = e
            end
            if #S.transcript > 0 then
                S.transcript[#S.transcript + 1] =
                    { role = "system", text = "↻ сессия возобновлена" }
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
