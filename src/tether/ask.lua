-- add-ask-tool: the structured-question tool's pure core.
--
-- `ask` normalises what the model sent into an answerable question set, encodes
-- the user's answer into the payload the model reads, and renders the one-line
-- transcript summary. Everything here is data in → data out, so the rules in
-- specs/ask/spec.md are testable without a UI, a transport or a parked turn.
--
-- The JSON helpers live once, in providers/common.lua (the C host exposes the
-- module as the `provider_common` global; the loadfile fallback keeps
-- development runs and `lua tests/lua_tests.lua` working).
local M = {}

local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "ask: cannot load provider_common")
local json_encode = common.json_encode

-- Bounds (specs/ask/spec.md "Question set shape and bounds").
M.MAX_QUESTIONS = 8
M.MAX_OPTIONS = 12
M.QUESTION_MAX = 1000
M.DESCRIPTION_MAX = 8000

-- The freeform row is always present; this is the label the UI renders for it.
M.FREEFORM_LABEL = "Other (ввести свой вариант)"

-- The truncation marker the rest of the project uses for oversized bodies.
M.TRUNCATION = "…(truncated)"

-- Model-facing error texts (the UI keeps its own Russian strings).
M.NOTHING_ASKABLE = "ask: no usable question in this request"
M.NO_INTERACTIVE_USER = "ask unavailable: this run has no interactive user, decide with your own judgement"

-- The row the TUI appends when the user cancels a question set.
M.CANCELLED_TEXT = "отменён (Esc)"

local function truncate(s, max)
    if type(s) ~= "string" then return nil end
    if #s <= max then return s end
    return s:sub(1, max) .. M.TRUNCATION
end

-- Usable = a string with at least one non-space character.
local function usable(s)
    return type(s) == "string" and s:match("%S") ~= nil
end

-- An option may be given as a bare string or as {label=..., description=...};
-- anything else has no usable label and is dropped.
local function option_entry(o)
    local label, description
    if type(o) == "string" then
        label = o
    elseif type(o) == "table" then
        label = o.label
        description = o.description
    end
    if not usable(label) then return nil end
    local entry = { label = label }
    if usable(description) then
        entry.description = truncate(description, M.DESCRIPTION_MAX)
    end
    return entry
end

-- Normalise the model's `questions` argument into the answerable set. Never
-- fails: whatever cannot be understood is dropped, and a question that keeps no
-- option is still asked through its freeform row alone (spec: "Malformed
-- question sets degrade instead of hanging").
function M.normalize(args)
    local raw = args
    if type(raw) == "table" and type(raw.questions) == "table" then
        raw = raw.questions
    elseif type(raw) == "table" and type(raw.questions) == "string" then
        -- the model double-encoded the array as a JSON string instead of
        -- sending an array ("questions":"[{...}]"): decode one layer.
        local ok, decoded = pcall(common.json_decode, raw.questions)
        if ok and type(decoded) == "table" then raw = decoded end
    elseif type(raw) == "string" then
        local ok, decoded = pcall(common.json_decode, raw)
        if ok and type(decoded) == "table" then raw = decoded end
    end
    if type(raw) == "table" and type(raw.questions) == "table" then
        raw = raw.questions
    end
    if type(raw) ~= "table" then return {} end

    local questions, seen = {}, {}
    for i = 1, #raw do
        if #questions >= M.MAX_QUESTIONS then break end
        local q = raw[i]
        if type(q) == "table" and usable(q.question) then
            local options = {}
            local opt_source = q.options
            if type(opt_source) == "table" then
                for j = 1, #opt_source do
                    if #options >= M.MAX_OPTIONS then break end
                    local opt = option_entry(opt_source[j])
                    if opt then options[#options + 1] = opt end
                end
            end

            local id = q.id
            if not usable(id) then
                id = "q" .. (#questions + 1)
            end
            if seen[id] then
                local base, n = id, 2
                while seen[base .. "-" .. n] do n = n + 1 end
                id = base .. "-" .. n
            end
            seen[id] = true

            local rec = tonumber(q.recommended)
            if rec and rec ~= math.floor(rec) then rec = nil end
            if not rec or rec < 1 or rec > #options then rec = nil end

            questions[#questions + 1] = {
                id = id,
                question = truncate(q.question, M.QUESTION_MAX),
                description = usable(q.description)
                    and truncate(q.description, M.DESCRIPTION_MAX) or nil,
                options = options,
                multi = q.multi == true,
                -- advisory only: the TUI flags it and never selects it
                recommended = rec,
            }
        end
    end
    return questions
end

-- Notes for one answer, as the payload's array: option order first, then any
-- label that is not in the question's options (sorted, so the payload is
-- stable). A note on an unselected option travels too — a note is intent.
local function notes_for(q, a)
    local out = { _array = true }
    local notes = (type(a) == "table" and type(a.notes) == "table") and a.notes or {}
    local used = {}
    for _, opt in ipairs(q.options or {}) do
        local note = notes[opt.label]
        if usable(note) then
            out[#out + 1] = { option = opt.label, note = note }
            used[opt.label] = true
        end
    end
    local extra = {}
    for label, note in pairs(notes) do
        if not used[label] and usable(label) and usable(note) then
            extra[#extra + 1] = label
        end
    end
    table.sort(extra)
    for _, label in ipairs(extra) do
        out[#out + 1] = { option = label, note = notes[label] }
    end
    return out
end

-- The answer payload the model reads. `answers` is keyed by question index:
--   answers[i] = { selected = {<label>, ...}, other = "<freeform>",
--                  notes = { [<option label>] = "<note>" } }
-- `selected` is always an array (the `_array` marker keeps an empty selection
-- as [] rather than the encoder's {}), `other` and `notes` are omitted when
-- empty, and answers appear in the question order.
function M.encode(questions, answers)
    questions = questions or {}
    answers = answers or {}
    local list = { _array = true }
    for i, q in ipairs(questions) do
        local a = answers[i] or {}
        local item = { id = q.id, question = q.question, selected = { _array = true } }
        if type(a.selected) == "table" then
            for _, label in ipairs(a.selected) do
                if usable(label) then item.selected[#item.selected + 1] = label end
            end
        end
        if usable(a.other) then item.other = a.other end
        local notes = notes_for(q, a)
        if #notes > 0 then item.notes = notes end
        list[#list + 1] = item
    end
    return json_encode({ answers = list })
end

-- The cancellation payload: an empty answer set that names the cancellation.
function M.cancelled_payload()
    return json_encode({
        cancelled = true,
        reason = "cancelled by user",
        answers = { _array = true },
    })
end

-- One-line transcript summary of an answered set:
--   "scope=src; priority=Core + «первая»; scope/Vue: too heavy"
function M.summary(questions, answers)
    questions = questions or {}
    answers = answers or {}
    local parts = {}
    for i, q in ipairs(questions) do
        local a = answers[i] or {}
        local bits = {}
        if type(a.selected) == "table" and #a.selected > 0 then
            bits[#bits + 1] = table.concat(a.selected, ", ")
        end
        if usable(a.other) then bits[#bits + 1] = "«" .. a.other .. "»" end
        parts[#parts + 1] = q.id .. "=" .. (#bits > 0 and table.concat(bits, " + ") or "—")
        for _, n in ipairs(notes_for(q, a)) do
            parts[#parts + 1] = q.id .. "/" .. n.option .. ": " .. n.note
        end
    end
    return table.concat(parts, "; ")
end

return M
