-- src/tether/ui/markdown.lua — markdown-lite inline-strip pass.
--
-- IN:  strip_inline(s, ansi_fn): s is source text; ansi_fn(kind, text) is an
--      optional role painter (nil = strip markers, keep text). No globals.
-- OUT: module table { strip_inline }. Pure function, no TUI state.
-- EXAMPLE:
--      strip_inline("**b** and `c`", function(kind, text) return "<" .. kind .. ">" .. text end)
--      --> "<bold>b</bold> and <code>c</code>"
--
-- Grammar: inline `code`, **bold**, *italic*. Escapes: \` and \* are
-- literal. No backtracking patterns (ADR lesson); per-line state machine.
-- Block structure (fences, headings, lists) lives in ui.lua's md_render
-- until the regions cut; the theme-bound M.md_ansi painter stays in ui.lua
-- until the themes cut.
local M = {}

local function strip_inline(s, ansi_fn)
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
M.strip_inline = strip_inline

return M
