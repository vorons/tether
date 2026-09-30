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

-- T321 (audit H5): an implementation that raises degrades into the error
-- shape instead of unwinding through the turn — the call still gets exactly
-- one history result and one tool_result event.
do
  local td = assert(loadfile("src/tether/tool_dispatch.lua"))()
  local history, journaled, events = {}, {}, {}
  local deps = {
    execute = function(name)
      error("attempt to index a " .. type(name) .. " value", 0)
    end,
    summarize = function(name) return "sum:" .. name end,
    body = function(_, res) return res.content end,
    truncate = function(s) return s end,
    add_history = function(id, res) history[#history + 1] = { id = id, res = res } end,
    journal = function(e) journaled[#journaled + 1] = e end,
  }
  local ok, res = pcall(td.run_tool_call, {}, function(ev)
      events[#events + 1] = ev
    end, "t9", "patch", { patch = {} }, nil, deps)
  assert_true(ok, "T321 a raising tool does not escape the dispatch")
  assert_notnil(res, "T321 the dispatch still returns a result")
  assert_true(type(res.error) == "string"
      and res.error:find("tool 'patch' failed:", 1, true) ~= nil,
    "T321 the raise becomes a tool error carrying the message")
  assert_eq(#history, 1, "T321 history gets exactly one result for the call")
  assert_true(history[1].res.error ~= nil, "T321 the history result is the error")
  assert_eq(#events, 1, "T321 exactly one tool_result event")
  assert_eq(events[1].type, "tool_result", "T321 the event is the tool result")
  assert_eq(#journaled, 1, "T321 the journal records the failure")
  print("T321 raising tool degrades: OK")
end

-- Phase E 5.2: prune/bg orchestration stays in agent (the 5.1 split moves
-- only the loader + run_tool_call wrapper). Guard: no diff hunk outside
-- those two regions, and the wrapper routes through the module.
do
  local f = io.open("src/tether/agent.lua", "r")
  local src = f:read("*a")
  f:close()
  local s = src:find("local function run_tool_call", 1, true)
  assert_notnil(s, "T5.2 wrapper present")
  local e = src:find("\nend\n", s)
  local chunk = src:sub(s, e)
  assert_true(chunk:find("tool_dispatch.run_tool_call", 1, true) ~= nil,
    "T5.2 wrapper delegates to the module")
  assert_true(chunk:find("on_event({", 1, true) == nil,
    "T5.2 event shaping lives in the module")
  assert_true(chunk:find('type = "tool_result"', 1, true) == nil,
    "T5.2 journal shaping lives in the module")
  for _, fn in ipairs({ "prune_superseded_reads", "record_bg_result",
    "bg_call_ready", "finish_bg_call" }) do
    assert_true(src:find(fn, 1, true) ~= nil, "T5.2 " .. fn .. " stays in agent")
  end
  print("T5.2 prune/bg untouched: OK")
end

if failed > 0 then
    os.exit(1)
end
