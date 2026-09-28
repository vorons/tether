-- tests/tool_dispatch_tests.lua — tool_dispatch one-call shape (Phase E 5.1).
-- Run: lua tests/tool_dispatch_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- Module direct: stub edge, real shaping rules.
do
  local td = assert(loadfile("src/tether/tool_dispatch.lua"))()
  local history, journaled, events = {}, {}, {}
  local deps = {
    execute = function(name, args)
      if name == "boom" then return nil, "kaput" end
      return { content = "out:" .. (args.path or "?") }
    end,
    summarize = function(name) return "sum:" .. name end,
    body = function(_, res) return res.content end,
    truncate = function(s) return s end,
    add_history = function(id, res) history[#history + 1] = { id = id, res = res } end,
    journal = function(e) journaled[#journaled + 1] = e end,
  }
  local on_event = function(ev) events[#events + 1] = ev end
  -- ok shape: history sees content, journal bounds the body, event carries both
  local res = td.run_tool_call({}, on_event, "t1", "read", { path = "x" }, nil, deps)
  assert_eq(res.content, "out:x", "T5.1 result passes through")
  assert_eq(history[1].res.content, "out:x", "T5.1 history keeps the body")
  assert_eq(journaled[1].tool_call_id, "t1", "T5.1 journal keeps the id")
  assert_eq(events[1].type, "tool_result", "T5.1 event emitted")
  assert_eq(events[1].summary, "sum:read", "T5.1 event carries the summary")
  -- error shape: text everywhere, ✗ marker on the event
  history, journaled, events = {}, {}, {}
  local err = td.run_tool_call({}, on_event, "t2", "boom", {}, nil, deps)
  assert_eq(err.error, "kaput", "T5.1 error passes through")
  assert_eq(history[1].res.error, "kaput", "T5.1 history keeps the error")
  assert_true(events[1].summary:find("kaput", 1, true) ~= nil, "T5.1 event marks the error")
  -- write + projection: diff body, +N −M created meter
  history, journaled, events = {}, {}, {}
  local proj = { diff = "@@ d", add = 3, del = 1, is_new = true }
  td.run_tool_call({}, on_event, "t3", "write", {}, proj, deps)
  assert_eq(events[1].body, "@@ d", "T5.1 write reports the projection diff")
  assert_true(events[1].summary:find("created", 1, true) ~= nil, "T5.1 write meter names creation")
  -- patch + projection: diff body, module summary
  events = {}
  td.run_tool_call({}, on_event, "t4", "patch", {}, { diff = "@@ p" }, deps)
  assert_eq(events[1].body, "@@ p", "T5.1 patch reports the projection diff")
  assert_eq(events[1].summary, "sum:patch", "T5.1 patch keeps the module summary")
  -- silent caller: no event, still reported
  local n = #events
  local r2 = td.run_tool_call({}, nil, "t5", "read", { path = "y" }, nil, deps)
  assert_eq(r2.content, "out:y", "T5.1 nil on_event still returns")
  assert_eq(#events, n, "T5.1 nil on_event emits nothing")
  print("T5.1 tool_dispatch shape: OK")
end

if failed > 0 then
    os.exit(1)
end
