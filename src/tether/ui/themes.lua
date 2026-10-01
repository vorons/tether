-- src/tether/ui/themes.lua — all painting: theme tables, role painters,
-- ASCII mapping, hint painters, painter-table builder.
--
-- IN:  build(o) takes one explicit table — no module state, no globals:
--      { theme (name), depth ("truecolor"|"256"|"none"), ascii (bool),
--      light_bg (bool), copy, vlen, clip, trunc, cells, wrap, now_ms,
--      caret, freeform, ascii_none, spinner_interval_ms, md_render }.
--      Moved from ui.lua (ui-themes-cut 1.1); the facade resolves the live
--      values (theme name, depth, ascii/light seams) per call, so tests
--      keep driving ui.set_theme/ui.sgr_role/ui.to_ascii/ui.hint_*.
-- OUT: module table { THEMES, GLYPH_MAP, to_ascii, sgr_wrap, role_code,
--      paint_role, caret_reverse, md_ansi, hint_plain, hint_paint, build }.
--      build(o) returns the exact painter table the regions consume.
-- EXAMPLE:
--      themes.build({ theme = "mono", depth = "256", ascii = false,
--        light_bg = false, copy = {}, vlen = vlen, clip = clip,
--        md_render = md_render }).role("accent", "x") --> "x"
local M = {}

-- M8/R1: glyph → ASCII mapping (single pass, longest-first via explicit scan).
-- The spec promises TERM=dumb renders pure ASCII; the old code only stripped
-- ANSI colors, leaving box-drawing and emoji-width glyphs to break layout.
M.GLYPH_MAP = {
    ["●"] = "*", ["⚙"] = "[t]", ["›"] = ">", ["✗"] = "[x]", ["✓"] = "[ok]", ["✻"] = "*",
    ["↻"] = "[r]", ["⏹"] = "[x]", ["⚠"] = "!", ["▸"] = ">", ["▾"] = "v", ["⇆"] = "tab",
    ["┌"] = "+", ["┐"] = "+", ["└"] = "+", ["┘"] = "+", ["─"] = "-",
    ["│"] = "|",     ["•"] = "*", ["…"] = "...", ["▓"] = "#", ["░"] = "-", ["━"] = "#",
    ["▀"] = "#", ["█"] = "#", ["▄"] = "#",
    ["↑"] = "^", ["↓"] = "v", ["←"] = "<", ["→"] = ">",
    ["·"] = "-",
    -- add-ask-tool: the question block's glyphs (note marker, quoted freeform)
    ["↳"] = "->", ["«"] = '"', ["»"] = '"',
}

-- Pure glyph map (no mode gate — the caller decides when ASCII applies).
local function to_ascii(s)
    local out = {}
    local i = 1
    while i <= #s do
        local matched = false
        for glyph, repl in pairs(M.GLYPH_MAP) do
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

local ESC = "\27"
local function sgr_wrap(code, s)
    return ESC .. "[" .. code .. "m" .. s .. ESC .. "[0m"
end
M.sgr_wrap = sgr_wrap

-- M8/R2: themes — role→SGR-code tables. cfg.ui.theme selects; unknown → default.
-- "mono" = no colors at all (roles resolve to nil ⇒ raw text).
M.THEMES = {
    default = {
        -- green-slate (ported from the Go TUI): accent #69e098, window
        -- background #101214, input surface #22262a. The renderer emits no
        -- background fills, so background/input live here as documented
        -- metadata only; the SGR roles below carry the visible palette.
        -- accent is depth-aware (mint #69e098): truecolor carries the exact
        -- rgb, 256-color falls back to the closest palette index (78).
        -- No bold component by design; headings keep their own bold.
        accent = { truecolor = "38;2;105;224;152", ["256"] = "38;5;78" },
        -- error/warn are fixed semantic hues (soft red #e06c75 / soft
        -- yellow #e5c07b in truecolor terms): bright red/yellow at the
        -- 16-color depth this renderer negotiates, never the accent, so
        -- failures and retries stay legible under every accent choice.
        warn = "33;1", error = "31;1", success = "32",
        -- muted is the derived neutral gray (dark #8d8f92 tier); dim is its
        -- darkened tier. muted_light is the dark-gray tier (#565a5f terms)
        -- for light terminal backgrounds, picked by paint_role via light_bg.
        dim = "2", muted = "90", muted_light = "30",
        italic = "3", reverse = "7", bold = "1",
        -- 7.1: syntax roles (token kinds); default to 16-color codes so
        -- truecolor/256 render with the same palette. ponytail: no brighter
        -- per-depth variants; add one if a 256-color theme gets complaints.
        comment = "2;38", string = "32", number = "33", keyword = "36;1",
        -- inline code is soft lavender (#b48ead), depth-aware like accent: the
        -- 16-color magenta (35) reads near-black on the dark window.
        code = { truecolor = "38;2;180;142;173", ["256"] = "38;5;139" },
        heading = "36;1",
    },
    solarized = {
        accent = "36", warn = "33", error = "31", success = "32",
        dim = "2", muted = "90", italic = "3", reverse = "7", bold = "1",
        comment = "2;38", string = "32", number = "33", keyword = "36",
        code = { truecolor = "38;2;180;142;173", ["256"] = "38;5;139" },
        heading = "36;1",
    },
    mono = {}, -- every role missing ⇒ no SGR emitted
}

-- Resolve a role to its SGR code (or nil ⇒ raw text). Pure.
local function role_code(themes, theme_name, role, depth, light_bg)
    local theme = themes[theme_name] or themes.default
    local code = theme[role]
    -- splash-colors: on a light terminal the muted tier switches to the
    -- dark-gray variant so secondary text stays legible; dim ("2") and the
    -- fixed error/warn hues read on both backgrounds unchanged.
    if role == "muted" and theme.muted_light and light_bg then
        code = theme.muted_light
    end
    if type(code) == "table" then
        code = code[depth] or code["256"] or code.truecolor
    end
    return code
end
M.role_code = role_code

-- M8/R2: role-based color — theme table drives the code; missing role in a
-- theme (e.g. mono) returns the raw text with no SGR at all; depth
-- "none" (ASCII/NO_COLOR/dumb) also forces raw text (7.1: never highlight).
-- The ascii gate mirrors the facade sgr()/to_ascii gates exactly: raw paths
-- map only when it is on, and — like sgr() — painted output degrades to the
-- mapped text (not SGR) when it is on, whatever the depth says.
local function paint_role(themes, theme_name, role, s, depth, light_bg, ascii)
    local function raw(t)
        if ascii then return to_ascii(t) end
        return t
    end
    if depth == "none" then return raw(s) end
    local code = role_code(themes, theme_name, role, depth, light_bg)
    if not code then return raw(s) end
    if ascii then return to_ascii(s) end
    return sgr_wrap(code, s)
end
M.paint_role = paint_role

-- Caret reversal needs a real reverse video role and real colors.
local function caret_reverse(themes, theme_name, depth)
    local theme = themes[theme_name] or themes.default
    return depth ~= "none" and theme.reverse ~= nil
end
M.caret_reverse = caret_reverse

-- Theme-bound markdown annotator: kind straight into the role painter.
local function md_ansi(role_fn, kind, text)
    return role_fn(kind, text)
end
M.md_ansi = md_ansi

-- palette-hints D1: the shared segmented hint painter. A hint is an array of
-- {key, act} pairs; the key token paints in the dim tier, the action word in
-- the muted tier, pairs join with two spaces and no `·` separator.
-- hint_plain is the same text unstyled (the drift guards T228/T267 assert
-- against it); hint_paint clips to `inner` display columns when given,
-- keeping the tiers of whatever survives the clip. ASCII twins arrive through
-- paint_role -> to_ascii (GLYPH_MAP carries ↑ ↓ ⇆), so neither helper needs an
-- ascii flag. P carries the dim/muted/vlen/clip the painter table owns.
local function hint_plain(pairs)
    local t = {}
    for _, p in ipairs(pairs) do t[#t + 1] = p.key .. " " .. p.act end
    return table.concat(t, "  ")
end
M.hint_plain = hint_plain

local function hint_paint(P, pairs, inner)
    local parts, used = {}, 0
    for _, p in ipairs(pairs) do
        if used > 0 then
            if inner and used + 2 > inner then break end
            parts[#parts + 1] = "  "
            used = used + 2
        end
        local seg = p.key .. " " .. p.act
        if inner and used + P.vlen(seg) > inner then
            local kp = P.clip(p.key, math.max(inner - used, 1))
            parts[#parts + 1] = P.dim(kp)
            used = used + P.vlen(kp)
            if inner - used >= 2 then
                parts[#parts + 1] = " " .. P.muted(P.clip(p.act, inner - used - 1))
            end
            break
        end
        parts[#parts + 1] = P.dim(p.key) .. " " .. P.muted(p.act)
        used = used + P.vlen(seg)
    end
    return table.concat(parts)
end
M.hint_paint = hint_paint

-- The exact painter table the regions consume: theme-bound closures over
-- the explicit opts, plain values passed through. No module state.
function M.build(o)
    o = o or {}
    local themes = M.THEMES
    local role = function(kind, text)
        return paint_role(themes, o.theme, kind, text, o.depth, o.light_bg, o.ascii)
    end
    local function dim(s) return role("dim", s) end
    local function muted(s) return role("muted", s) end
    local function red(s) return role("error", s) end
    local function green(s) return role("success", s) end
    local function yellow(s) return role("warn", s) end
    local function cyan(s) return role("accent", s) end
    local function rev(s) return role("reverse", s) end
    local function italic(s) return role("italic", s) end
    -- Pre-declared: a local's scope starts AFTER its declaration statement,
    -- so a self-reference inside the constructor would capture nil —
    -- assign after declaring.
    local P
    P = {
        dim = dim, muted = muted, red = red, green = green, yellow = yellow,
        cyan = cyan, accent = cyan, rev = rev, italic = italic,
        role = role,
        to_ascii = function(s)
            if o.ascii then return to_ascii(s) end
            return s
        end,
        caret_reverse = function()
            return caret_reverse(themes, o.theme, o.depth)
        end,
        md = function(text, inner) return o.md_render(text, inner, role) end,
        -- P is complete by call time: hint reads only dim/muted/vlen/clip.
        hint = function(pairs, inner) return hint_paint(P, pairs, inner) end,
        trunc = o.trunc, vlen = o.vlen, cells = o.cells,
        clip = o.clip, wrap = o.wrap,
        copy = o.copy,
        now_ms = o.now_ms,
        caret = o.caret,
        freeform = o.freeform,
        ascii_none = o.ascii_none,
        spinner_interval_ms = o.spinner_interval_ms,
    }
    return P
end

return M
