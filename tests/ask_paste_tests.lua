-- tests/ask_paste_tests.lua — audit H7: a paste into an ask editor must not
-- mangle the text. `%r`/`%n` are not pattern classes in Lua, so the old
-- sanitizer pattern (`[%r%n]+`) was `[rn]+`: it deleted every `r` and `n` from
-- the paste and left CR/LF/tab/ESC in place. `%c+` flattens control runs only.
-- Run: lua tests/ask_paste_tests.lua

dofile("tests/helpers.lua")

local ask = assert(loadfile("src/tether/ui/ask.lua"))()

-- One question block with an editor open: mode is "other" (freeform answer) or
-- "note" (per-option note). Each call gets a fresh bag, since pastes append.
local function paste(mode, text)
    local bag = { cfg = {}, ask = {
        id = "q1", qidx = 1, sel = 1, phase = "questions",
        mode = mode, note_sel = mode == "note" and 1 or nil, editor = "",
        questions = { { question = "Q?", options = { { label = "opt one" } } } },
        answers = {},
    } }
    local deps = { sync = function() end }
    ask.handle_ask_key(bag, deps, { kind = "paste", text = text })
    return bag.ask.editor, bag, deps
end

-- T328: line breaks and tabs of a multi-line paste collapse to one space each,
-- and every letter of the pasted text survives.
do
    assert_eq(paste("other", "running fast\r\nnext round"), "running fast next round",
        "T328 crlf pastes as one space")
    assert_eq(paste("other", "a\r\n\nb"), "a b", "T328 control run pastes as one space")
    assert_eq(paste("other", "tab\there"), "tab here", "T328 tab pastes as a space")
    assert_eq(paste("other", "plain text"), "plain text", "T328 clean paste is unchanged")
end

-- T328b: non-ASCII is byte-for-byte intact (control bytes are single-byte, so
-- the flattening never cuts a UTF-8 sequence).
do
    assert_eq(paste("other", "привет, café!"), "привет, café!", "T328b cyrillic survives")
    assert_eq(paste("other", "диск\tC:"), "диск C:", "T328b cyrillic around a tab")
end

-- T328c: an escape sequence / bell pasted into the answer leaves no control
-- byte behind — a stray ESC in the committed answer would keep leaking.
do
    local got = paste("other", "a\027[31mb\007c")
    assert_eq(got, "a [31mb c", "T328c ESC and BEL flatten to spaces")
    assert_eq(got:find("%c"), nil, "T328c no control byte left in the buffer")
end

-- T328d: the flattened text is what the agent receives, in both editors.
do
    local _, bag, deps = paste("other", "running fast\r\nnext round")
    ask.handle_ask_key(bag, deps, { kind = "enter" })
    assert_eq(bag.ask.answers[1].other, "running fast next round",
        "T328d freeform answer keeps the text")
    assert_eq(bag.ask.answers[1].notes["opt one"], nil,
        "T328d freeform answer writes no note")

    local _, nbag, ndeps = paste("note", "opt one\r\nsecond line")
    ask.handle_ask_key(nbag, ndeps, { kind = "enter" })
    assert_eq(nbag.ask.answers[1].notes["opt one"], "opt one second line",
        "T328d note answer keeps the text")
end

if failed > 0 then os.exit(1) end
print("ask_paste_tests: OK")
