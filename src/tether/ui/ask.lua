-- src/tether/ui/ask.lua — the question-block controller: cursor/answer
-- state machine, editors, submit/cancel.
--
-- IN:  ask_question(bag), ask_answer(bag), ask_toggle(answer, option) and
--      editor_backspace(text) take values only (bag is read, the answer
--      table is the unit under edit). ask_advance(bag, deps),
--      handle_ask_key(bag, deps, k) and resolve_ask(bag, deps, cancelled)
--      take (bag, deps, ...) like the busy-pump handlers: bag is the state
--      (S.ask/error_banner/cfg/api_key), deps is the impure edge { askmod
--      (ask rules: CANCELLED_TEXT/summary), turn, on_event, sync, paint,
--      bump, settle, note }.
--      Moved verbatim from ui.lua (Phase D 4.2) with identical function
--      names, so the 4.1 OWN block needs no changes; the facade keeps thin
--      proxies and the 2.2 key table keeps owning the keyboard.
-- OUT: module table { editor_backspace, ask_question, ask_answer,
--      ask_toggle, ask_advance, handle_ask_key, resolve_ask }.
--      No S, no globals, no terminal I/O.
-- EXAMPLE:
--      ask.toggle({ selected = {} }, { label = "x" }) --> selected == { "x" }
--      ask.handle(bag, deps, { kind = "esc" }) --> block cancelled
local M = {}

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
M.editor_backspace = editor_backspace

local function ask_question(bag)
    local a = bag.ask
    return a and a.questions and a.questions[a.qidx] or nil
end
M.ask_question = ask_question

local function ask_answer(bag)
    local a = bag.ask
    if not a then return nil end
    a.answers[a.qidx] = a.answers[a.qidx] or { selected = {}, other = "", notes = {} }
    return a.answers[a.qidx]
end
M.ask_answer = ask_answer

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
M.ask_toggle = ask_toggle

-- Close the block and hand the answer (or the cancellation) to the agent, then
-- resume the turn exactly the way resolve_confirmation does. A cancellation is
-- an answer the model can act on — the turn continues either way.
local function resolve_ask(bag, deps, cancelled)
    deps = deps or {}
    local a = bag.ask
    if not a then return end
    local questions, answers = a.questions or {}, a.answers or {}
    bag.ask = nil
    -- no separate summary note: the answered tool call renders its own row
    -- with the same summary text (record_ask_result), so a note here would
    -- duplicate it line for line.
    deps.turn.finish(bag)
    local ok, err = deps.turn.answer(a.id,
        cancelled and { cancelled = true } or answers, bag.cfg, deps.on_event)
    if not ok and err then bag.error_banner = tostring(err) end
    if deps.bump then deps.bump() end
    if deps.sync then deps.sync() end

    local ok2, err2 = deps.turn.continue(bag, bag.cfg, bag.api_key or "", deps.on_event, function()
        deps.sync()
        deps.paint(true)
    end)
    if not ok2 and err2 then bag.error_banner = tostring(err2) end
    if deps.bump then deps.bump() end
    if deps.sync then deps.sync() end
    if deps.settle then deps.settle() end
end
M.resolve_ask = resolve_ask

-- The current question is answered: move to the next one, or — on the last
-- question of a multi-question set — open the Confirm phase. Single-question
-- sets submit immediately (no confirm phase).
local function ask_advance(bag, deps)
    deps = deps or {}
    local a = bag.ask
    if not a then return end
    if a.qidx < #a.questions then
        a.qidx = a.qidx + 1
        a.sel = 1
        a.mode = "list"
        a.note_sel = nil
        a.editor = ""
        if deps.sync then deps.sync() end
    elseif #a.questions > 1 then
        a.phase = "confirm"
        a.mode = "list"
        a.note_sel = nil
        a.editor = ""
        if deps.sync then deps.sync() end
    else
        resolve_ask(bag, deps, false)
    end
end
M.ask_advance = ask_advance

local function handle_ask_key(bag, deps, k)
    deps = deps or {}
    local sync = deps.sync or function() end
    local a = bag.ask
    if not a then return end
    local q = ask_question(bag)
    if not q then resolve_ask(bag, deps, true); return end
    local n = #q.options
    local freeform_row = n + 1
    local answer = ask_answer(bag)

    -- --- confirm phase: review the whole set, submit or bail -------------
    if a.phase == "confirm" then
        if k.kind == "enter" then
            resolve_ask(bag, deps, false) -- submit the whole committed set
        elseif k.kind == "esc" then
            resolve_ask(bag, deps, true)  -- cancel everything, same as Esc in a question
        elseif (k.kind == "tab")
            or (k.kind == "special" and (k.name == "left" or k.name == "right")) then
            -- back to the questions, answers preserved; ←/→ walk tabs, so →
            -- wraps from Confirm to the first question and ← returns to the last
            a.phase = "questions"
            a.mode = "list"
            a.note_sel = nil
            a.editor = ""
            if k.kind == "special" and k.name == "right" then a.qidx = 1 end
            sync()
        end
        return
    end

    -- question tabs: → on the last question of a multi-question set opens the
    -- Confirm phase; single-question sets have no confirm phase, so their Tab
    -- keeps the note/freeform-editor meaning
    if k.kind == "special" and k.name == "right" and a.qidx >= #a.questions
        and #a.questions > 1 then
        a.phase = "confirm"
        sync()
        return
    end
    if k.kind == "tab" and a.qidx >= #a.questions and #a.questions > 1 then
        a.phase = "confirm"
        sync()
        return
    end

    -- --- editors: characters and backspace edit the buffer ----------------
    if a.mode == "other" or a.mode == "note" then
        if k.kind == "esc" then
            -- discard this editor session's edits; the set stays open
            a.mode = "list"
            a.note_sel = nil
            a.editor = ""
            sync()
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
            sync()
            return
        end
        if k.kind == "backspace" then
            a.editor = editor_backspace(a.editor)
            sync()
            return
        end
        if k.kind == "text" then
            a.editor = (a.editor or "") .. (k.char or "")
            sync()
            return
        end
        if k.kind == "paste" then
            a.editor = (a.editor or "") .. ((k.text or ""):gsub("[%r%n]+", " "))
            sync()
            return
        end
        return
    end

    -- --- list mode -------------------------------------------------------
    if k.kind == "esc" then resolve_ask(bag, deps, true); return end
    if k.kind == "special" then
        if k.name == "up" then
            a.sel = math.max(1, a.sel - 1)
            sync()
        elseif k.name == "down" then
            a.sel = math.min(freeform_row, a.sel + 1)
            sync()
        elseif k.name == "left" and a.qidx > 1 then
            -- back to the previous question, its answer still in place
            a.qidx = a.qidx - 1
            a.sel = 1
            sync()
        elseif k.name == "right" and a.qidx < #a.questions then
            -- on to the next question: an unanswered one keeps its place, an
            -- answered one keeps its answer
            a.qidx = a.qidx + 1
            a.sel = 1
            sync()
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
            sync()
        elseif a.sel == freeform_row then
            a.mode = "other"
            a.editor = answer.other or ""
            sync()
        end
        return
    end
    if k.kind == "enter" then
        if a.sel == freeform_row then
            if answer.other and answer.other ~= "" then
                ask_advance(bag, deps) -- a committed freeform answer is the answer
            else
                a.mode = "other"
                a.editor = ""
                sync()
            end
            return
        end
        if a.sel <= n then
            if q.multi then
                -- Enter accepts the toggled selection and moves on; Space and
                -- digits are what toggle
                ask_advance(bag, deps)
            else
                answer.selected = { q.options[a.sel].label }
                ask_advance(bag, deps)
            end
        end
        return
    end
    if k.kind == "text" then
        local c = k.char or ""
        if c == " " then
            -- Space picks the highlighted option: on a single question it
            -- selects and moves on (like a digit), on a multi question it
            -- toggles without submitting. The freeform row is never picked
            -- by Space -- Enter opens its editor there.
            if a.sel <= n then
                if q.multi then
                    ask_toggle(answer, q.options[a.sel])
                    sync()
                else
                    answer.selected = { q.options[a.sel].label }
                    ask_advance(bag, deps)
                end
            end
            return
        end
        local digit = tonumber(c)
        if digit and digit >= 1 and digit <= n then
            local opt = q.options[digit]
            if q.multi then
                ask_toggle(answer, opt)
                sync()
            else
                a.sel = digit
                answer.selected = { opt.label }
                ask_advance(bag, deps)
            end
        end
        return
    end
end
M.handle_ask_key = handle_ask_key

return M
