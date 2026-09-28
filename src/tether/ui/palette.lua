-- src/tether/ui/palette.lua — palette view-model: ranking, geometry, rows.
--
-- IN:  all functions take values only (no S, no globals):
--        fuzzy_score(filter, label) -> score or nil (prefix ranks first,
--          subsequence ranks lower, no match is nil; empty filter is 1000)
--        fuzzy_rank(filter, labels) -> indices sorted by score desc,
--          declaration-order ties
--        window(h, n, sel) -> win, off: visible-row count (at most 8 and at
--          most half the terminal height, never below one for n > 0) and the
--          1-based offset, shifted so the selection stays inside
--        indicator(q, n, sel, paint_win, truncated, copy) -> row text or nil:
--          the query/indicator row below the entry window. copy is the
--          ui_copy.palette table (query_prefix, no_matches, sel_total_fmt,
--          count_fmt, cut_marker). nil means "paint no row here".
--        render(slice, L, P) -> ordered rowmap {{row, text}} for the
--          facade's set_row (terminal I/O stays in the facade):
--          slice: { active, items ({label, hint, desc}), sel, mode, query,
--            truncated, hints (PALETTE_HINTS table), copy (ui_copy.palette),
--            content_width, gutter }
--          L: { h, palette_row, palette_h, separator_row }
--          P: { trunc(text, w), vlen(text), dim(text), accent(text),
--            rule(cw) -> text, hint(pairs, cw) -> text }
--          Empty ({} ) when inactive or when no items and no modal query.
-- OUT: module table { fuzzy_score, fuzzy_rank, window, indicator, render }.
--      Pure, no TUI state. The S-mutating interaction (apply_query, pickers,
--      path/@ completion) stays in ui.lua until the S-ownership follow-up.
-- EXAMPLE:
--      indicator("mo", 12, 3, 8, false, copy) --> "> mo (3/12)"
--      indicator("", 0, 1, 8, false, copy)    --> nil
--      render(slice, L, P) --> { {12, " …"}, … }
local M = {}

local function fuzzy_score(filter, label)
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
M.fuzzy_score = fuzzy_score

local function fuzzy_rank(filter, labels)
    -- returns indices into labels sorted by score desc, declaration-order ties
    local scored = {}
    for i, lab in ipairs(labels) do
        local s = fuzzy_score(filter, lab)
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
M.fuzzy_rank = fuzzy_rank

local function window(h, n, sel)
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
M.window = window

local function indicator(q, n, sel, paint_win, truncated, copy)
    if q ~= "" then
        local txt = copy.query_prefix .. q
        if n == 0 then
            txt = txt .. copy.no_matches
        elseif n > paint_win then
            txt = txt .. string.format(copy.sel_total_fmt, sel, n)
        end
        return txt
    elseif n > paint_win or truncated then
        -- a trailing cut marker says the ranked list was cut (the
        -- 200-candidate cap or the walk's own budget), so `1/200` doesn't
        -- read like the whole tree.
        return string.format(copy.count_fmt, sel, n, truncated and copy.cut_marker or "")
    end
    return nil
end
M.indicator = indicator

-- Palette region painting (moved from ui.lua render_palette, Phase A 1.2):
-- slice in, ordered rowmap out. No S, no globals, no terminal I/O.
local function render(slice, L, P)
    slice = slice or {}
    L = L or {}
    P = P or {}
    if not slice.active then return {} end
    -- modal query row: only the model/login palettes ever set a query, so
    -- the command palette's digits-only indicator path is untouched. The
    -- query row paints even with zero matches so the filter stays visible.
    local q = ""
    if slice.mode == "model" or slice.mode == "login"
        or slice.mode == "logout" then
        q = slice.query or ""
    end
    local items = slice.items or {}
    if #items == 0 and q == "" then return {} end
    -- no frame; selected item is accent-colored, not reverse-video. A
    -- window over the ranked list, shifted so the selected row is inside
    -- it, plus a dim pos/total row when the list overflows it.
    local n = #items
    local sel = slice.sel or 1
    local win, off = window(L.h or 24, n, sel)
    -- the blank+hint pair anchors to the region bottom — hint on the last
    -- reserved row, blank one above, footer flush under it. Entries and the
    -- indicator/query row keep the top-flush layout inside the rows above
    -- the blank, so the shrink loop in layout() cuts the entry window
    -- first and the hint is the last content dropped.
    local palette_row = L.palette_row or 1
    local palette_h = L.palette_h or 0
    local hint_row = palette_row + palette_h
    local room = math.max(0, hint_row - 2 - palette_row)
    local paint_win = math.min(win, room - (q ~= "" and 1 or 0))
    if paint_win < 0 then paint_win = 0 end
    local cw = slice.content_width or 80
    local g = slice.gutter or ""
    local trunc = P.trunc or function(s) return s end
    local vlen = P.vlen or function(s) return #s end
    local dim = P.dim or function(s) return s end
    local accent = P.accent or function(s) return s end
    local rows = {}
    -- rows inside the region that end up holding no entry, indicator or
    -- query must stay blank: clear the region up to (not including) the
    -- hint row, so a dock that shifted between frames leaves no stale
    -- content in the reserved blank.
    for r = palette_row + 1, hint_row - 1 do rows[#rows + 1] = { r, g } end
    -- descriptions align: the name column is padded to the widest
    -- name+hint across all listed entries (computed once per paint).
    local label_w = 0
    for _, it in ipairs(items) do
        local l = it.label or ""
        if it.hint then l = l .. " " .. it.hint end
        local vw = vlen(l)
        if vw > label_w then label_w = vw end
    end
    for i = 1, paint_win do
        local it = items[off + i - 1]
        if it then
            local label = it.label or ""
            if it.hint then label = label .. " " .. it.hint end
            local pad = string.rep(" ", math.max(label_w - vlen(label), 0))
            local text = trunc(string.format(" %s%s %s", label, pad, it.desc or ""), cw)
            rows[#rows + 1] = { palette_row + i,
                g .. ((off + i - 1 == sel) and accent(text) or dim(text)) }
        end
    end
    local irow = palette_row + paint_win + 1
    if irow <= palette_row + room then
        local txt = indicator(q, n, sel, paint_win, slice.truncated, slice.copy or {})
        if txt then rows[#rows + 1] = { irow, g .. dim(trunc(" " .. txt, cw)) } end
    end
    if palette_h >= 1 then
        local hints = slice.hints or {}
        local hp = hints[slice.mode] or hints.command
        if hp and P.hint then
            rows[#rows + 1] = { hint_row, g .. P.hint(hp, cw) }
        end
    end
    -- footer-separator: while the palette paints, a full-width rule like
    -- the box's own separates the dock from the footer row.
    if L.separator_row and P.rule then
        rows[#rows + 1] = { L.separator_row, g .. P.rule(cw) }
    end
    return rows
end
M.render = render

return M
