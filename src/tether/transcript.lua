-- tether / transcript.lua — the visible conversation model.
--
-- Data-in / rows-out: canonical agent events and session history are reduced
-- to display rows (scroll, attempt tags, confirmation tails). Owns the row
-- cache, prefix-sum height index and stale-attempt drop. Layout, key handling
-- and mode flags stay in ui; render_entry and the cache bound are injected
-- via configure() so this module never reaches into ui state.
local M = {}

-- Display rows (role/text/tool fields) plus synthetic tails.
local entries = {}
local ver = 0
local known_count = 0

-- Virtualized transcript model: per-entry row caches plus a prefix-sum height.
local index_w = nil
local index_start = {}
local index_h = {}
local index_total = 0
local index_dirty_from = nil
local cached_rows = 0
local use_counter = 0
local visible_lo = 0
local visible_hi = -1

-- Synthetic tail entries (confirmation menu, ask block).
local confirm_entry = nil
local ask_entry = nil

-- Injected by ui once render_entry and the viewport height are in scope.
local render_fn = nil
local cache_bound_fn = nil

function M.configure(opts)
    opts = opts or {}
    if opts.render then render_fn = opts.render end
    if opts.cache_bound then cache_bound_fn = opts.cache_bound end
end

function M.entries()
    return entries
end

function M.count()
    return #entries
end

function M.tails()
    return confirm_entry, ask_entry
end

-- Structural change by appending (new turn, new tool entry, system line):
-- existing entries keep their rows and heights, so this costs O(new entries).
function M.bump()
    ver = ver + 1
    local n = #entries
    local from = known_count + 1
    for i = from, n do
        local e = entries[i]
        e.pos = i
        e.ver = e.ver or 0
    end
    if from <= n and (not index_dirty_from or index_dirty_from > from) then
        index_dirty_from = from
    end
    known_count = n
end

-- In-place change that can affect ANY entry (expand-all, thinking toggle, a
-- new width). Every entry is re-derived, so these stay rare on purpose.
function M.invalidate()
    local n = #entries
    for i = 1, n do
        local e = entries[i]
        e.pos = i
        e.ver = (e.ver or 0) + 1
    end
    index_dirty_from = 1
    ver = ver + 1
    known_count = n
end

-- One entry's content changed (a streamed delta, a tool result).
function M.touch(e)
    if not e then return end
    e.ver = (e.ver or 0) + 1
    ver = ver + 1
    local pos = e.pos
    if pos then
        if not index_dirty_from or index_dirty_from > pos then
            index_dirty_from = pos
        end
    else
        index_dirty_from = 1
    end
end

function M.append(e)
    entries[#entries + 1] = e
    return e
end

function M.last()
    return entries[#entries]
end

-- The whole list was replaced (/, /new, /resume, /clear).
function M.reset(list)
    entries = list or {}
    known_count = 0
    index_dirty_from = 1
    visible_lo, visible_hi = 0, -1
    index_w = nil
    index_start, index_h = {}, {}
    index_total = 0
    M.bump()
end

-- Seed from display rows (already {role, text}) or agent-history messages
-- ({role, content}); only user text and assistant text are shown.
function M.seed(messages)
    local out = {}
    for _, m in ipairs(messages or {}) do
        if m.role and m.text ~= nil and m.content == nil then
            out[#out + 1] = m
        elseif m.role == "user" then
            out[#out + 1] = { role = "user", text = tostring(m.content or "") }
        elseif m.role == "assistant" and type(m.content) == "string" then
            out[#out + 1] = { role = "assistant", text = m.content }
        end
    end
    M.reset(out)
    return out
end

function M.clear()
    entries = {}
    ver = 0
    known_count = 0
    index_w = nil
    index_start, index_h = {}, {}
    index_total = 0
    index_dirty_from = nil
    cached_rows = 0
    use_counter = 0
    visible_lo, visible_hi = 0, -1
    confirm_entry, ask_entry = nil, nil
end

-- Keep synthetic tail entries in sync with ui mode flags; invalidates from
-- the tail (cheap — they sit last). A fresh confirm/ask entry bumps its
-- version so the menu/block rows re-render.
function M.sync_tail(has_confirm, has_ask)
    if has_confirm then
        confirm_entry = confirm_entry or { virt = "confirm", ver = 0 }
        confirm_entry.ver = (confirm_entry.ver or 0) + 1
    else
        confirm_entry = nil
    end
    if has_ask then
        ask_entry = ask_entry or { virt = "ask", ver = 0 }
        ask_entry.ver = (ask_entry.ver or 0) + 1
    else
        ask_entry = nil
    end
    local n = #entries + 1
    if not index_dirty_from or index_dirty_from > n then index_dirty_from = n end
end

-- A fresh turn restarts attempt numbering at 1 (agent reset_retry_state),
-- so stale tags from previous turns must go first: otherwise a retry of
-- attempt N drops previous turns' answers tagged N. Same-turn
-- continuations (turn.continue) keep their tags. No version bumps:
-- attempt tags are never rendered, only matched by the retry drop.
function M.new_turn()
    for _, e in ipairs(entries) do e.attempt = nil end
end

-- Row mutations for one canonical agent event. Mode flags, tokens,
-- confirmation/ask construction and paint stay in ui. Returns true when the
-- caller should re-sync the synthetic tails.
function M.handle(ev)
    if not ev or not ev.type then return false end
    local t = ev.type
    if t == "text_delta" then
        -- A delta belongs to the attempt that produced it: a retried attempt's
        -- rows have already been dropped, and a fresh attempt never appends to
        -- the previous attempt's row.
        local last = entries[#entries]
        local stale = ev.attempt and last and last.attempt and last.attempt ~= ev.attempt
        if not last or last.role ~= "assistant" or stale then
            last = M.append({ role = "assistant", text = "" })
        end
        last.text = (last.text or "") .. (ev.text or "")
        last.attempt = ev.attempt or last.attempt
        M.touch(last)
        return true
    elseif t == "reasoning_delta" then
        local last = entries[#entries]
        local stale = ev.attempt and last and last.attempt and last.attempt ~= ev.attempt
        if not last or last.role ~= "thinking" or stale then
            -- started_at once: later deltas must not reset the elapsed clock
            last = M.append({ role = "thinking", text = "", started_at = os.time() })
        end
        last.text = (last.text or "") .. (ev.text or "")
        last.attempt = ev.attempt or last.attempt
        M.touch(last)
        return true
    elseif t == "tool_call_start" then
        local proj = ev.projection
        M.append({
            role = "tool", id = ev.id or tostring(#entries + 1),
            started_at = os.time(),
            name = ev.name or "?", status = "pending", summary = "",
            body = (proj and proj.diff) or "",
            args = ev.args,
            path = proj and proj.path or (ev.args and ev.args.path),
            projection = proj,
        })
        M.bump()
        return true
    elseif t == "tool_result" then
        local target
        for i = #entries, 1, -1 do
            local e = entries[i]
            if e.role == "tool" and e.id == ev.id then
                e.status = ev.error and "error" or "ok"
                e.summary = ev.summary or ""
                local dropped = ev.error == "denied by user" or ev.error == "cancelled by user"
                e.body = dropped and "" or (ev.body or "")
                e.projection = nil
                target = e
                break
            end
        end
        M.touch(target)
        return false
    elseif t == "aborted" then
        for _, e in ipairs(entries) do
            if e.role == "tool" and e.status == "pending" then
                e.projection = nil
                e.body = ""
            end
        end
        M.append({ role = "system", text = "⏹ прервано (Ctrl+C)" })
        M.bump()
        return true
    elseif t == "context_compressed" then
        -- add-llm-compaction: llm mode shows the generated body when present;
        -- truncation / missing mode keeps the stable marker (ASCII-clean).
        local text = "── summary ──"
        if ev.mode == "llm" and type(ev.summary) == "string" and ev.summary ~= "" then
            text = ev.summary
        end
        M.append({ role = "system", text = text })
        M.bump()
        return false
    elseif t == "retry" then
        -- The attempt that failed is dropped before its retry row, so the
        -- transcript never shows output from an attempt the model may answer
        -- differently. Removal invalidates every position after it.
        -- Scope note: attempt tags only live within a turn (ui clears them
        -- on every fresh turn via new_turn), so this never touches previous
        -- turns' answers even though numbering restarts at 1 each turn.
        local failed = ev.attempt
        local removed = false
        if failed then
            for i = #entries, 1, -1 do
                if entries[i].attempt == failed then
                    table.remove(entries, i)
                    removed = true
                end
            end
        end
        if removed then M.invalidate() end
        M.append({
            role = "system",
            text = string.format("↻ повтор %d (ждём %.1fs): %s",
                ev.attempt or 1, ev.delay or 0.5, ev.reason or ""),
        })
        M.bump()
        return false
    elseif t == "continuation" then
        M.append({
            role = "system",
            text = ev.kind == "empty" and "↻ продолжение (пустой ответ)"
                or "↻ продолжение (лимит вывода)",
        })
        M.bump()
        return false
    end
    return false
end

function M.set_visible(lo, hi)
    visible_lo, visible_hi = lo or 0, hi or -1
end

function M.visible_count()
    local n = #entries
    if confirm_entry then n = n + 1 end
    if ask_entry then n = n + 1 end
    return n
end

function M.entry_at(i)
    local n = #entries
    if i <= n then return entries[i] end
    local k = i - n
    if confirm_entry then
        if k == 1 then return confirm_entry end
        k = k - 1
    end
    if ask_entry and k == 1 then return ask_entry end
    return nil
end

-- Rows this entry would occupy when wrapped to `width`; measured without
-- retaining the rows.
local function entry_height(e, width)
    if e.height ~= nil and e.h_w == width and e.h_ver == (e.ver or 0) then
        return e.height
    end
    if e.rows and e.rows_w == width and e.rows_ver == (e.ver or 0) then
        e.height, e.h_w, e.h_ver = #e.rows, width, (e.ver or 0)
        return e.height
    end
    if not render_fn then
        e.height, e.h_w, e.h_ver = 0, width, (e.ver or 0)
        return 0
    end
    local rows = render_fn(e, width)
    e.height, e.h_w, e.h_ver = #rows, width, (e.ver or 0)
    return e.height
end

local function cache_bound()
    if cache_bound_fn then return cache_bound_fn() end
    return 1024
end

local function evict_cached_rows()
    local bound = cache_bound()
    while cached_rows > bound do
        local best, best_use = nil, nil
        for i = 1, M.visible_count() do
            -- never evict the entries framing the viewport
            if i ~= visible_lo and i ~= visible_hi then
                local e = M.entry_at(i)
                if e and e.rows then
                    local u = e.used or 0
                    if not best_use or u < best_use then best, best_use = e, u end
                end
            end
        end
        if not best then return end
        cached_rows = cached_rows - #best.rows
        best.rows, best.rows_w, best.rows_ver = nil, nil, nil
    end
end

local function entry_rows(e, width)
    if e.rows and e.rows_w == width and e.rows_ver == (e.ver or 0) then
        use_counter = use_counter + 1
        e.used = use_counter
        return e.rows
    end
    if not render_fn then return {} end
    local rows = render_fn(e, width)
    if #rows > cache_bound() / 2 then
        return rows -- too big to cache; re-rendered on the next repaint
    end
    if e.rows then cached_rows = cached_rows - #e.rows end
    e.rows, e.rows_w, e.rows_ver = rows, width, (e.ver or 0)
    use_counter = use_counter + 1
    e.used = use_counter
    cached_rows = cached_rows + #rows
    evict_cached_rows()
    return rows
end

function M.cache_rows()
    return cached_rows
end

-- Rebuild the prefix-sum height index, from the first dirty entry (O(1) for a
-- plain append) or from the start when the width changed.
function M.ensure_index(width)
    if index_w == width and not index_dirty_from then return index_total end
    local n = M.visible_count()
    local from, rows = 1, 0
    if index_w == width and index_dirty_from and index_dirty_from <= n then
        from = index_dirty_from
        rows = (from > 1) and (index_start[from - 1] or 0) or 0
    else
        index_start, index_h = {}, {}
    end
    for i = from, n do
        local e = M.entry_at(i)
        local h = e and entry_height(e, width) or 0
        index_h[i] = h
        rows = rows + h
        index_start[i] = rows - h + 1
    end
    for i = n + 1, #index_start do
        index_start[i], index_h[i] = nil, nil
    end
    index_w, index_total, index_dirty_from = width, rows, nil
    return rows
end

function M.height(width)
    return M.ensure_index(width or 80)
end

function M.entry_of_row(k, width)
    M.ensure_index(width)
    local lo, hi, best = 1, M.visible_count(), nil
    while lo <= hi do
        local mid = (lo + hi) // 2
        local s = index_start[mid]
        if s and s <= k then best, lo = mid, mid + 1 else hi = mid - 1 end
    end
    return best
end

function M.row_text(k, width)
    local i = M.entry_of_row(k, width)
    if not i then return "" end
    local e = M.entry_at(i)
    if not e then return "" end
    local rows = entry_rows(e, width)
    return rows[k - (index_start[i] or 0) + 1] or ""
end

-- Parity seam: the same rows the viewport path produces, for the whole
-- transcript. Tests compare the two to prove virtualization changes nothing.
function M.render_all(width)
    local out = {}
    M.ensure_index(width)
    for i = 1, M.visible_count() do
        local e = M.entry_at(i)
        if e then
            for _, r in ipairs(entry_rows(e, width)) do out[#out + 1] = r end
        end
    end
    return out
end

return M
