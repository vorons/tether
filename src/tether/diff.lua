-- tether pretty-transcript-rendering: diff.lua — pure-Lua unified-diff engine.
--
-- Three consumers share this module:
--   * agent.lua builds the projection and the write/patch result bodies with
--     unified();
--   * ui.lua renders those bodies with parse() and pair_words();
--   * the write/patch summary meter comes from meter().
-- Nothing here touches the filesystem or the terminal, so every piece is
-- unit-testable from the plain Lua harness.
local M = {}

-- --- text helpers -----------------------------------------------------------

-- Split text into lines without inventing a phantom trailing line for a
-- \n-terminated body (same rule tools.read uses).
local function split_lines(text)
    local lines = {}
    if text == nil or text == "" then return lines end
    local pos, n = 1, #text
    while pos <= n do
        local nl = text:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = text:sub(pos, nl - 1)
            pos = nl + 1
        else
            lines[#lines + 1] = text:sub(pos)
            break
        end
    end
    return lines
end
M.split_lines = split_lines

-- --- unified diff -----------------------------------------------------------

-- LCS DP is O(n*m); trim the common prefix/suffix first (a small edit in a
-- large file collapses to a tiny core) and fall back to a whole-block replace
-- once the core exceeds the budget, so one huge rewrite cannot wedge the turn.
local LCS_BUDGET = 250000

local function lcs_ops(a, b)
    -- returns a list of {kind="context"/"add"/"del", text=...}
    local n, m = #a, #b
    local ops = {}
    -- common prefix
    local p = 0
    while p < n and p < m and a[p + 1] == b[p + 1] do p = p + 1 end
    -- common suffix (not overlapping the prefix)
    local s = 0
    while s < (n - p) and s < (m - p) and a[n - s] == b[m - s] do s = s + 1 end
    local ac, bc = {}, {}
    for i = p + 1, n - s do ac[#ac + 1] = a[i] end
    for i = p + 1, m - s do bc[#bc + 1] = b[i] end
    for i = 1, p do ops[#ops + 1] = { kind = "context", text = a[i] } end

    local anc, bnc = #ac, #bc
    if anc * bnc > LCS_BUDGET then
        for i = 1, anc do ops[#ops + 1] = { kind = "del", text = ac[i] } end
        for i = 1, bnc do ops[#ops + 1] = { kind = "add", text = bc[i] } end
    else
        -- classic DP table + backtrack (only for the bounded core)
        local dp = {}
        for i = 0, anc do dp[i] = { [0] = 0 } end
        for j = 0, bnc do dp[0][j] = 0 end
        for i = 1, anc do
            local row, prev = dp[i], dp[i - 1]
            for j = 1, bnc do
                if ac[i] == bc[j] then
                    row[j] = prev[j - 1] + 1
                else
                    row[j] = (prev[j] >= row[j - 1]) and prev[j] or row[j - 1]
                end
            end
        end
        local i, j = anc, bnc
        local back = {}
        while i > 0 and j > 0 do
            if ac[i] == bc[j] then
                back[#back + 1] = { kind = "context", text = ac[i] }
                i, j = i - 1, j - 1
            elseif dp[i - 1][j] > dp[i][j - 1] then
                back[#back + 1] = { kind = "del", text = ac[i] }
                i = i - 1
            else
                back[#back + 1] = { kind = "add", text = bc[j] }
                j = j - 1
            end
        end
        while i > 0 do back[#back + 1] = { kind = "del", text = ac[i] }; i = i - 1 end
        while j > 0 do back[#back + 1] = { kind = "add", text = bc[j] }; j = j - 1 end
        for k = #back, 1, -1 do ops[#ops + 1] = back[k] end
    end

    for i = n - s + 1, n do ops[#ops + 1] = { kind = "context", text = a[i] } end
    return ops
end

-- Group a full op list into hunks with `ctx` lines of surrounding context.
local function group_hunks(ops, ctx)
    ctx = ctx or 3
    local n = #ops
    -- index every change op
    local changed = {}
    for i = 1, n do
        if ops[i].kind ~= "context" then changed[#changed + 1] = i end
    end
    if #changed == 0 then return {} end
    local hunks = {}
    local hi = 1
    while hi <= #changed do
        local first = changed[hi]
        local last = first
        -- grow while the gap to the next change is within 2*ctx
        while hi < #changed and (changed[hi + 1] - last - 1) <= 2 * ctx do
            hi = hi + 1
            last = changed[hi]
        end
        hi = hi + 1
        local from = math.max(1, first - ctx)
        local to = math.min(n, last + ctx)
        local hunk = { ops = {} }
        for i = from, to do hunk.ops[#hunk.ops + 1] = ops[i] end
        hunks[#hunks + 1] = hunk
    end
    return hunks
end

-- Line starts for a hunk: count old/new lines before the hunk's first op.
local function hunk_starts(ops, from)
    local old_before, new_before = 0, 0
    for i = 1, from - 1 do
        local k = ops[i].kind
        if k == "context" or k == "del" then old_before = old_before + 1 end
        if k == "context" or k == "add" then new_before = new_before + 1 end
    end
    return old_before, new_before
end

local function hunk_header(old_start, old_count, new_start, new_count)
    local function side(start, count)
        if count == 1 then return start end
        return start .. "," .. count
    end
    return string.format("@@ -%s +%s @@", side(old_start, old_count), side(new_start, new_count))
end

-- unified(old_text, new_text [, old_label, new_label])
--   -> diff_text, { add = N, del = M }
-- When labels are given, `--- label` / `+++ label` file headers are prepended.
function M.unified(old_text, new_text, old_label, new_label)
    local a = split_lines(old_text or "")
    local b = split_lines(new_text or "")
    local ops = lcs_ops(a, b)
    local add, del = 0, 0
    for _, op in ipairs(ops) do
        if op.kind == "add" then add = add + 1
        elseif op.kind == "del" then del = del + 1 end
    end
    local out = {}
    if old_label or new_label then
        out[#out + 1] = "--- " .. (old_label or "/dev/null")
        out[#out + 1] = "+++ " .. (new_label or "/dev/null")
    end
    if add == 0 and del == 0 then
        -- identical input: empty diff (headers only, if requested)
        return #out > 0 and table.concat(out, "\n") or "", { add = 0, del = 0 }
    end
    local hunks = group_hunks(ops, 3)
    for _, hunk in ipairs(hunks) do
        local old_count, new_count = 0, 0
        for _, op in ipairs(hunk.ops) do
            if op.kind == "context" then old_count = old_count + 1; new_count = new_count + 1
            elseif op.kind == "del" then old_count = old_count + 1
            elseif op.kind == "add" then new_count = new_count + 1 end
        end
        -- find the first op's index in ops (identity search)
        local first_idx = 1
        for i = 1, #ops do
            if ops[i] == hunk.ops[1] then first_idx = i; break end
        end
        local old_before, new_before = hunk_starts(ops, first_idx)
        local old_start = old_count == 0 and old_before or old_before + 1
        local new_start = new_count == 0 and new_before or new_before + 1
        out[#out + 1] = hunk_header(old_start, old_count, new_start, new_count)
        for _, op in ipairs(hunk.ops) do
            local prefix = (op.kind == "add" and "+") or (op.kind == "del" and "-") or " "
            out[#out + 1] = prefix .. op.text
        end
    end
    return table.concat(out, "\n"), { add = add, del = del }
end

-- --- parse ------------------------------------------------------------------

-- parse(diff_text) -> rows, or nil when the text is not a unified diff.
-- Row: { kind, old, new, text }
--   kind: "file-header" | "hunk-header" | "context" | "add" | "remove" | "no-newline"
--   old/new: line numbers (nil when the side does not advance)
function M.parse(diff_text)
    if type(diff_text) ~= "string" or diff_text == "" then return nil end
    local rows = {}
    local have_hunk = false
    local cur_old, cur_new = nil, nil
    local lines = split_lines(diff_text)
    for _, line in ipairs(lines) do
        local two = line:sub(1, 2)
        if two == "@@" then
            local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            if not os then return nil end
            os, ns = tonumber(os), tonumber(ns)
            oc = (oc == "" or oc == nil) and 1 or tonumber(oc)
            nc = (nc == "" or nc == nil) and 1 or tonumber(nc)
            cur_old, cur_new = os, ns
            have_hunk = true
            rows[#rows + 1] = { kind = "hunk-header", old = os, new = ns,
                                text = line }
        elseif line:sub(1, 3) == "---" then
            rows[#rows + 1] = { kind = "file-header", text = line:sub(5) }
        elseif line:sub(1, 3) == "+++" then
            rows[#rows + 1] = { kind = "file-header", text = line:sub(5) }
        elseif line:sub(1, 1) == "\\" then
            rows[#rows + 1] = { kind = "no-newline", text = line }
        elseif line:sub(1, 1) == "+" then
            if cur_new == nil then return nil end
            rows[#rows + 1] = { kind = "add", new = cur_new, text = line:sub(2) }
            cur_new = cur_new + 1
        elseif line:sub(1, 1) == "-" then
            if cur_old == nil then return nil end
            rows[#rows + 1] = { kind = "remove", old = cur_old, text = line:sub(2) }
            cur_old = cur_old + 1
        else
            if cur_old == nil or cur_new == nil then
                -- text before any hunk is not a diff
                return nil
            end
            rows[#rows + 1] = { kind = "context", old = cur_old, new = cur_new,
                                text = line:sub(2) }
            cur_old = cur_old + 1
            cur_new = cur_new + 1
        end
    end
    if not have_hunk then return nil end
    return rows
end

-- --- word pairing -----------------------------------------------------------

-- Word emphasis is quadratic; lines beyond this width skip the comparison.
local WORD_COLUMN_THRESHOLD = 240
-- Minimum share of common word tokens for a pair to be considered a real edit.
local WORD_SIMILARITY = 0.25

-- Split a string into alternating word / space tokens (kept, in order).
local function word_tokens(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        local ws = c:match("%s")
        local j = i
        if ws then
            while j <= n and s:sub(j, j):match("%s") do j = j + 1 end
        else
            while j <= n and not s:sub(j, j):match("%s") do j = j + 1 end
        end
        out[#out + 1] = { text = s:sub(i, j - 1), space = ws ~= nil }
        i = j
    end
    return out
end

local function row_text(row)
    if type(row) == "table" then return row.text or "" end
    return tostring(row or "")
end

-- pair_words(removed_row, added_row) -> old_segs, new_segs, or nil when the
-- pair is not eligible for emphasis.
-- Segments cover the whole line; `changed` marks the words that actually
-- changed (they keep the add/remove role, carried words render muted).
function M.pair_words(removed_row, added_row)
    local old_text = row_text(removed_row)
    local new_text = row_text(added_row)
    if #old_text > WORD_COLUMN_THRESHOLD or #new_text > WORD_COLUMN_THRESHOLD then
        return nil
    end
    local oa, nb = word_tokens(old_text), word_tokens(new_text)
    -- compare only the word tokens; the sequence lengths must match
    local ow, nw = {}, {}
    for _, t in ipairs(oa) do if not t.space then ow[#ow + 1] = t end end
    for _, t in ipairs(nb) do if not t.space then nw[#nw + 1] = t end end
    if #ow == 0 or #ow ~= #nw then return nil end
    local same = 0
    for i = 1, #ow do
        if ow[i].text == nw[i].text then same = same + 1 end
    end
    if same == #ow then return nil end -- identical lines are not an edit
    if same / #ow < WORD_SIMILARITY then return nil end
    -- mark word tokens by position
    local function mark(tokens, words)
        local wi = 0
        local segs = {}
        for _, t in ipairs(tokens) do
            if t.space then
                segs[#segs + 1] = { text = t.text, changed = false }
            else
                wi = wi + 1
                segs[#segs + 1] = { text = t.text, changed = words[wi] == true }
            end
        end
        return segs
    end
    -- build the per-position changed flags: a word position that differs is
    -- "changed" on both sides
    local old_changed, new_changed = {}, {}
    for i = 1, #ow do
        local diff = ow[i].text ~= nw[i].text
        old_changed[i] = diff
        new_changed[i] = diff
    end
    return mark(oa, old_changed), mark(nb, new_changed)
end

-- --- meter ------------------------------------------------------------------

-- meter(add, del [, total]) -> add_blocks, del_blocks
-- Proportional block counts with at least one block per non-zero side and the
-- N:M ratio kept within one block. A zero side gets no blocks.
function M.meter(add, del, total)
    add, del = tonumber(add) or 0, tonumber(del) or 0
    total = total or 8
    if add <= 0 and del <= 0 then return 0, 0 end
    if add > 0 and del <= 0 then return total, 0 end
    if del > 0 and add <= 0 then return 0, total end
    local sum = add + del
    local a = math.floor(add / sum * total + 0.5)
    if a < 1 then a = 1 end
    local d = total - a
    if d < 1 then
        d = 1
        if a > total - 1 then a = total - 1 end
    end
    if add / sum > 0.5 and a <= d then a = d + 1
    elseif del / sum > 0.5 and d <= a then d = a + 1 end
    if a + d > total then
        if add >= del then a = total - d else d = total - a end
    end
    if a < 0 then a = 0 end
    if d < 0 then d = 0 end
    return a, d
end

M.WORD_COLUMN_THRESHOLD = WORD_COLUMN_THRESHOLD
M.WORD_SIMILARITY = WORD_SIMILARITY

return M
