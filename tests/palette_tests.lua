-- tests/palette_tests.lua — ui_palette view-model (split from lua_tests.lua, Phase C).
-- Run: lua tests/palette_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- TPAL: ui_palette owns the view-model directly (ui-modular-split 6.2).
do
  local pal = assert(loadfile("src/tether/ui/palette.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))().palette
  assert_eq(pal.fuzzy_score("", "anything"), 1000, "TPAL empty filter")
  assert_eq(pal.fuzzy_score("mo", "model"), 1000, "TPAL prefix")
  assert_eq(pal.fuzzy_score("md", "model"), 499, "TPAL subsequence")
  assert_eq(pal.fuzzy_score("zz", "model"), nil, "TPAL no match")
  local order = pal.fuzzy_rank("md", { "command", "model", "resume" })
  assert_eq(order[1], 2, "TPAL rank prefix first")
  local win, off = pal.window(24, 20, 15)
  assert_eq(win, 8, "TPAL window capped at 8")
  assert_true(off <= 15 and 15 < off + win, "TPAL selection inside window")
  win, off = pal.window(24, 0, 1)
  assert_eq(win, 0, "TPAL empty list")
  assert_eq(pal.indicator("mo", 12, 3, 8, false, copy), "> mo (3/12)", "TPAL query over window")
  assert_eq(pal.indicator("mo", 2, 1, 8, false, copy), "> mo", "TPAL query fits")
  assert_eq(pal.indicator("zz", 0, 1, 8, false, copy), "> zz (no matches)", "TPAL no matches")
  assert_eq(pal.indicator("", 200, 3, 8, true, copy), " 3/200+", "TPAL cut marker")
  assert_eq(pal.indicator("", 3, 1, 8, false, copy), nil, "TPAL no row when fits")
  -- module owns the behavior; the ui facade keeps M.* names until 2.4.
  assert_eq(pal.fuzzy_rank("md", { "command", "model" })[1], 2, "TPAL prefix ranks first via module")
  local w2, o2 = pal.window(24, 20, 15)
  assert_eq(w2, 8, "TPAL window capped via module")
  assert_true(o2 >= 1, "TPAL window offset via module")
  print("TPAL ui_palette direct: OK")
end

-- Phase A 1.2: ui_palette.render owns the region painting (slice in,
-- ordered rowmap out). Two layers: module direct + facade proxy shape.
do
  local pal = assert(loadfile("src/tether/ui/palette.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local P = { trunc = function(s) return s end, vlen = function(s) return #s end,
    dim = function(s) return "D" .. s end, accent = function(s) return "A" .. s end,
    rule = function() return "RULE" end, hint = function() return "HINT" end }
  local items = { { label = "/model", desc = "pick" }, { label = "/new", desc = "fresh" } }
  local L = { h = 24, palette_row = 20, palette_h = 5, separator_row = 26 }
  local slice = { active = true, items = items, sel = 1, mode = "command",
    query = nil, truncated = false, hints = copy.palette_hints,
    copy = copy.palette, content_width = 78, gutter = " " }
  local rows = pal.render(slice, L, P)
  assert_true(#rows > 0, "T1.2 region rowmap non-empty")
  assert_eq(rows[1][1], 21, "T1.2 blank clear starts below the rule")
  local found_acc, found_hint, found_sep = false, false, false
  for _, r in ipairs(rows) do
    if r[2]:find("A /model", 1, true) then found_acc = true end
    if r[1] == 25 and r[2]:find("HINT", 1, true) then found_hint = true end
    if r[1] == 26 then found_sep = true end
  end
  assert_true(found_acc, "T1.2 selected entry accent-painted")
  assert_true(found_hint, "T1.2 hint anchors to the region bottom")
  assert_true(found_sep, "T1.2 separator rule paints while open")
  -- inactive / empty stays silent
  assert_eq(#pal.render({ active = false, items = items }, L, P), 0, "T1.2 inactive paints nothing")
  assert_eq(#pal.render({ active = true, items = {} }, L, P), 0, "T1.2 empty paints nothing")
  print("T1.2 ui_palette.render module: OK")
end

-- T358 (audit L10): the click hit-test uses the painted (clamped) window,
-- not the raw one — paint_window is the single clamp both sides share, so
-- a shrunk region or a query row cannot misroute a click. Entry rows the
-- painter emits exactly fill it.
do
  local pal = assert(loadfile("src/tether/ui/palette.lua"))()
  local P = { trunc = function(s) return s end, vlen = function(s) return #s end,
    dim = function(s) return s end, accent = function(s) return s end,
    rule = function() return "RULE" end, hint = function() return "HINT" end }
  local function entry_rows(slice, L)
    local n = 0
    for _, r in ipairs(pal.render(slice, L, P)) do
      if r[1] > (L.palette_row or 1) and r[2]:find("file", 1, true) then n = n + 1 end
    end
    return n
  end
  local items = {}
  for i = 1, 20 do items[#items + 1] = { label = "file" .. i .. ".txt", desc = "" } end
  -- roomy region: full window of 8
  local pw, off = pal.paint_window(24, 20, 1, 24, false)
  assert_eq(pw, 8, "T358 roomy region paints the full window")
  -- shrunk region: clamped to room
  local pw2 = pal.paint_window(24, 20, 1, 6, false)
  assert_eq(pw2, 4, "T358 shrunk region clamps the window")
  -- query row takes one more when the region is tight
  local pw3 = pal.paint_window(24, 20, 1, 10, true)
  assert_eq(pw3, 7, "T358 query row shrinks the window by one")
  -- the painter fills exactly paint_window entry rows
  local L = { h = 24, palette_row = 10, palette_h = 6, separator_row = 17 }
  local slice = { active = true, items = items, sel = 1, mode = "path",
    query = nil, truncated = false, hints = {}, copy = {},
    content_width = 78, gutter = " " }
  assert_eq(entry_rows(slice, L), pw2, "T358 painted entries fill the clamp")
  -- click mapping: row palette_row+i hits items[off+i-1]
  local pw4, off4 = pal.paint_window(24, 20, 1, 24, false)
  assert_eq(off4, 1, "T358 first window starts at item 1")
  local hit = off4 + 3 - 1
  assert_eq(items[hit].label, "file3.txt", "T358 third painted row is the third item")
  print("T358 completion hit-test uses the painted window: OK")
end

if failed > 0 then
    os.exit(1)
end
