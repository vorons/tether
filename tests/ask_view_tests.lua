-- tests/ask_view_tests.lua — ui_ask_view block view (Phase D, task 4.3).
-- Run: lua tests/ask_view_tests.lua

dofile("tests/helpers.lua")

do
  local av = assert(loadfile("src/tether/ui/ask_view.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local P = {
    copy = copy,
    clip = function(s, w) if #s <= w then return s end return s:sub(1, math.max(w - 3, 0)) .. "..." end,
    wrap = function(s) return { s } end,
    vlen = function(s) return #s end,
    md = function(text) return { text } end,
    hint = function(pairs) local t = {} for _, p in ipairs(pairs) do t[#t + 1] = p.key end return table.concat(t, ",") end,
    caret = function() return "|" end,
    accent = function(s) return "<a>" .. s end,
    cyan = function(s) return "<c>" .. s end,
    dim = function(s) return "<d>" .. s end,
    muted = function(s) return "<m>" .. s end,
    role = function(k, s) return "<" .. k .. ">" .. s end,
    freeform = "Freeform",
  }
  -- empty states render nothing
  assert_eq(#av.render(nil, 80, P), 0, "TAV nil ask renders nothing")
  assert_eq(#av.render({ questions = {} }, 80, P), 0, "TAV no question renders nothing")
  -- single list question: header + options + freeform + hint
  local a = {
    questions = { { question = "Pick?", options = { { label = "one" }, { label = "two" } } } },
    qidx = 1, answers = { { selected = {}, other = "", notes = {} } },
    sel = 1, mode = "list", phase = "questions",
  }
  local rows = av.render(a, 80, P)
  assert_true(#rows >= 5, "TAV single question renders header+options+freeform+hint")
  assert_true(rows[2]:find("Pick?", 1, true) ~= nil, "TAV header names the question")
  assert_eq(rows[3], "", "TAV blank separates the question from the options")
  assert_true(rows[4]:find("1. one", 1, true) ~= nil, "TAV first option numbered")
  assert_true(rows[4]:find("<a>", 1, true) ~= nil, "TAV selected row accented")
  -- confirm phase lists answers per question
  local ac = {
    questions = { { question = "Q1", options = { { label = "x" } } },
                  { question = "Q2", options = { { label = "y" } } } },
    qidx = 1, answers = { { selected = { "x" } }, { selected = {}, other = "y" } },
    sel = 1, mode = "list", phase = "confirm",
  }
  local rc = av.render(ac, 80, P)
  assert_true(rc[2]:find("Confirm", 1, true) ~= nil, "TAV confirm phase shows tabs")
  -- tabs + hint steps
  assert_eq(av.ask_hint({ phase = "confirm" }, {}, copy), copy.ask.hints.confirm, "TAV confirm hints")
  assert_true(type(av.render_tabs(a, 80, P)) == "string", "TAV tabs render a row")
  print("TAV ui_ask_view direct: OK")
end

-- TAV2: ask block spacing (no duplicated question line, air around rows).
do
  local av = assert(loadfile("src/tether/ui/ask_view.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local P = {
    copy = copy,
    clip = function(s, w) if #s <= w then return s end return s:sub(1, math.max(w - 3, 0)) .. "..." end,
    wrap = function(s) return { s } end,
    vlen = function(s) return #s end,
    md = function(text) return { text } end,
    hint = function(pairs) local t = {} for _, p in ipairs(pairs) do t[#t + 1] = p.key end return table.concat(t, ",") end,
    caret = function() return "|" end,
    accent = function(s) return "<a>" .. s end,
    cyan = function(s) return "<c>" .. s end,
    dim = function(s) return "<d>" .. s end,
    muted = function(s) return "<m>" .. s end,
    role = function(k, s) return "<" .. k .. ">" .. s end,
    freeform = "Freeform",
  }
  local two = {
    questions = { { question = "Where to write?", options = { { label = "here" } } },
                  { question = "Where is the key?", options = { { label = "env" } } } },
    qidx = 1, answers = { { selected = {}, other = "", notes = {} } },
    sel = 1, mode = "list", phase = "questions",
  }
  local rows = av.render(two, 80, P)
  for _, r in ipairs(rows) do
    assert_true(r:find("Confirm", 1, true) == nil, "TAV2 no tab strip duplicates the question")
  end
  -- ["", "? Where to write? (1/2)", "", "  1. here", "  Freeform", "", hint]
  assert_eq(rows[1], "", "TAV2 leading blank")
  assert_true(rows[2]:find("Where to write?", 1, true) ~= nil, "TAV2 question row second")
  assert_eq(rows[3], "", "TAV2 blank separates the question from the options")
  assert_true(rows[4]:find("1. here", 1, true) ~= nil, "TAV2 first option follows the blank")
  assert_eq(rows[#rows - 1], "", "TAV2 blank separates the freeform row from the hint")
  assert_true(#rows[#rows] > 0, "TAV2 hint row last")
  print("TAV2 ask block spacing: OK")
end

if failed > 0 then
    os.exit(1)
end
