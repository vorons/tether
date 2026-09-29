-- src/tether/ui/ask_view.lua — structured-question block view.
--
-- IN:  render(a, width, P): a is the open question-block state (S.ask shape:
--      questions/qidx/answers/sel/mode/phase/note_sel/editor), width the
--      viewport columns. P is the painter table (facade-built):
--        clip, wrap, vlen (string ops), md(text, inner) -> rows (markdown),
--        hint(pairs, inner) (hint row), caret() (caret glyph),
--        accent/cyan/dim/muted(text) (roles), role(kind, text) (raw role),
--        copy (ui_copy table: ask.hints, ask.confirm_tab),
--        freeform (ask.FREEFORM_LABEL).
--      ask_hint(a, q, copy) and render_tabs(a, width, P) are module-internal
--      steps, also exported for tests.
-- OUT: array of row strings (NOT a rowmap — the caller splices rows into
--      the transcript flow). Pure: no S, no globals, no mutation.
-- EXAMPLE:
--      local rows = ask_view.render(S.ask, 80, P)  -- {} when no open block
local M = {}

local function ask_hint(a, q, copy)
    local H = copy.ask.hints
    if a.phase == "confirm" then
        return H.confirm
    end
    if a.mode == "note" then
        return H.note
    end
    if a.mode == "other" then
        return H.other
    end
    local multi_set = #a.questions > 1
    local hint = H.single
    if q.multi then
        hint = H.multi
    elseif multi_set then
        hint = H.multiset
    end
    -- ask-block-redesign: past the first question the hint names the back
    -- key (← returns with the answer intact); on the first one there is
    -- nothing to go back to. Spliced after the navigation pairs.
    if multi_set and (a.qidx or 1) > 1 and (hint == H.multi or hint == H.multiset) then
        local pairs = {}
        for i, p in ipairs(hint) do
            pairs[#pairs + 1] = p
            if i == 2 then pairs[#pairs + 1] = H.back end
        end
        return pairs
    end
    return hint
end
M.ask_hint = ask_hint

-- ask-block-redesign: the tab strip for multi-question sets. One clipped tab
-- per question plus a trailing Confirm tab; equal width budgets so any set
-- size fits one row (minimum 8 columns per tab). Active phase/tab = accent
-- text; the strip is decoration-only — all routing stays in handle_ask_key.
local function render_tabs(a, width, P)
    local inner = math.max(width - 2, 1)
    local tabs = {}
    for _, qq in ipairs(a.questions or {}) do tabs[#tabs + 1] = qq.question or "" end
    tabs[#tabs + 1] = P.copy.ask.confirm_tab
    local count = #tabs
    local sepw = 3 * (count - 1) -- "   " between tabs
    local budget = math.max(math.floor((inner - sepw) / count), 8)
    local active = (a.phase == "confirm") and count or a.qidx
    local parts = {}
    for i, label in ipairs(tabs) do
        local text = P.clip(label, budget)
        if i == active then
            parts[#parts + 1] = P.role("dim", " ") .. P.role("accent", text)
                .. P.role("dim", " ")
        else
            parts[#parts + 1] = P.muted(text)
        end
    end
    return table.concat(parts, "   ")
end
M.render_tabs = render_tabs

-- add-ask-tool: is `label` among this question's selected answers?
local function ask_selected(answer, label)
    for _, l in ipairs((answer and answer.selected) or {}) do
        if l == label then return true end
    end
    return false
end

-- The question block's rows. Rendered from the passed ask state directly, so
-- the highlight and the rows can never disagree about what is selectable:
-- option rows are 1..n in order, then the always-present freeform row at n+1.
local function render(a, width, P)
    if not a then return {} end
    local q = a.questions and a.questions[a.qidx]
    if not q then return {} end
    local answer = a.answers[a.qidx] or {}
    local n = #q.options
    local inner = math.max(width - 2, 1)
    local out = { "" }

    -- ask-block-redesign: multi-question sets open with a tab strip — one
    -- clipped tab per question plus a trailing Confirm tab. The active tab
    -- is dim-background + accent text; others stay muted. Single-question
    -- sets draw no strip (immediate submit, no confirm phase).
    if a.phase == "confirm" then
        out[#out + 1] = render_tabs(a, width, P)
        for qi, qq in ipairs(a.questions or {}) do
            local ans = a.answers[qi] or {}
            local sel_text = (type(ans.selected) == "table" and #ans.selected > 0)
                and table.concat(ans.selected, ", ") or nil
            local ans_text = (ans.other and ans.other ~= "") and ans.other or sel_text or "—"
            local qpart = P.clip(qq.question or "", math.max(math.floor(inner * 0.6), 8))
            local apart = P.clip(ans_text, math.max(inner - P.vlen(qpart) - 2, 4))
            out[#out + 1] = "  " .. P.dim(qpart .. ": ") .. apart
        end
        out[#out + 1] = P.hint(ask_hint(a, q, P.copy), inner)
        return out
    end
    if #a.questions > 1 then
        out[#out + 1] = render_tabs(a, width, P)
    end
    local progress = #a.questions > 1
        and string.format(" (%d/%d)", a.qidx, #a.questions) or ""
    out[#out + 1] = P.cyan("? ") .. (q.question or "") .. P.dim(progress)
    if q.description and q.description ~= "" then
        for _, l in ipairs(P.md(q.description, inner)) do
            out[#out + 1] = "  " .. l
        end
    end

    for i, opt in ipairs(q.options) do
        local row = {}
        -- multi keeps its square markers so the toggled state stays visible;
        -- single renders a clean numbered list (the accent cursor marks position)
        if q.multi then
            row[#row + 1] = ask_selected(answer, opt.label) and "[x] " or "[ ] "
        end
        row[#row + 1] = i .. ". " .. opt.label
        if q.recommended == i then row[#row + 1] = P.dim("  (recommended)") end
        local active = (i == a.sel and a.mode == "list")
        local text = "  " .. table.concat(row)
        out[#out + 1] = active and P.accent(text) or text
        if opt.description and opt.description ~= "" then
            for _, l in ipairs(P.wrap(opt.description, inner - 4)) do
                out[#out + 1] = "      " .. P.dim(l)
            end
        end
        if a.mode == "note" and a.note_sel == i then
            out[#out + 1] = "    " .. P.dim("note> ") .. (a.editor or "") .. P.caret()
        else
            local note = answer.notes and answer.notes[opt.label]
            if note and note ~= "" then
                out[#out + 1] = "    " .. P.dim("↳ " .. note)
            end
        end
    end

    local freeform = P.freeform
    if a.mode == "other" then
        out[#out + 1] = "  " .. freeform .. ": " .. (a.editor or "") .. P.caret()
    else
        local text = "  " .. freeform
        if answer.other and answer.other ~= "" then
            text = text .. P.dim("  («" .. answer.other .. "»)")
        end
        if a.sel == n + 1 and a.mode == "list" then
            text = P.accent(text)
        end
        out[#out + 1] = text
    end
    -- ask-block-b: one muted hint row under the freeform row, clipped to the
    -- width so it never wraps into extra rows.
    out[#out + 1] = P.hint(ask_hint(a, q, P.copy), inner)
    return out
end
M.render = render

return M
