-- tests/busy_tests.lua — ui_busy pump and queues (Phase D, task 4.4).
-- Run: lua tests/busy_tests.lua

dofile("tests/helpers.lua")

do
  local busy = assert(loadfile("src/tether/ui/busy.lua"))()
  -- parse_bang is pure
  local k, c = busy.parse_bang("!git status")
  assert_eq(k, "bang", "TBUSY single bang")
  assert_eq(c, "git status", "TBUSY bang command")
  k, c = busy.parse_bang("!!echo hi")
  assert_eq(k, "double", "TBUSY double bang")
  assert_eq(busy.parse_bang("!"), "empty", "TBUSY bare bang")
  assert_eq(busy.parse_bang("/clear"), nil, "TBUSY slash is not bang")
  -- pump drains via callbacks, honors the guards
  local S = { busy = true, input = "" }
  local keys = { { kind = "text", char = "x" }, nil }
  local qi = 0
  local handled = {}
  local ok = busy.pump_keys(S,
    function() qi = qi + 1 return keys[qi] end,
    function(ev) handled[#handled + 1] = ev end)
  assert_true(ok, "TBUSY pump handled a key")
  assert_eq(handled[1].char, "x", "TBUSY pump dispatched to handle_key")
  assert_false(busy.pump_keys({ busy = false },
    function() error("must not read") end,
    function() error("must not dispatch") end), "TBUSY idle pump is a no-op")
  assert_false(busy.pump_keys({ busy = true, confirmation = {} },
    function() error("must not read") end,
    function() end), "TBUSY confirmation owns the keyboard")
  assert_eq(busy.drain_stash({ busy = true }, function() end, function() end), 0,
    "TBUSY drain is a no-op while busy")
  -- enqueue + restore round-trip through explicit callbacks
  local SB = { input = "hello", steer_queue = {}, followup_queue = {} }
  local said = {}
  busy.enqueue_busy(SB, "steer",
    function(q, t) if #q >= 8 then return false end q[#q + 1] = t return true end,
    function() end,
    function(t) said[#said + 1] = t end,
    function() SB.input = "" end, 8)
  assert_eq(SB.steer_queue[1], "hello", "TBUSY enqueue queues the text")
  assert_eq(said[1], "hello", "TBUSY enqueue emits the user row")
  assert_eq(SB.input, "", "TBUSY enqueue clears the field")
  SB.input = "typed"
  busy.restore_queues(SB, function() SB.input = "" end, function() end)
  assert_eq(SB.input, "hello", "TBUSY restore replays the queue")
  assert_eq(#SB.steer_queue, 0, "TBUSY restore drains the queue")
  print("TBUSY ui_busy direct: OK")
end

if failed > 0 then
    os.exit(1)
end
