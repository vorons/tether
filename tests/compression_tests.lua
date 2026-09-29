-- tests/compression_tests.lua — compression policy (Phase E, task 5.1).
-- Run: lua tests/compression_tests.lua

dofile("tests/helpers.lua")

do
  local comp = assert(loadfile("src/tether/compression.lua"))()
  local big = { { role = "user", content = string.rep("x", 4000) } } -- est 1000
  -- fraction leg: 0.7*1000=700 < 1000 with reserve 0
  assert_true(comp.should_summarize(big, { context = { max_tokens = 1000, reserve_tokens = 0 } }),
    "TCMP fraction leg fires")
  assert_true(not comp.should_summarize({ { role = "user", content = "hi" } },
    { context = { max_tokens = 100000, reserve_tokens = 0 } }),
    "TCMP small history quiet")
  -- reserve leg: est > max - reserve (950 > 1000 - 100)
  assert_true(comp.should_summarize({ { role = "user", content = string.rep("y", 3800) } },
    { context = { max_tokens = 1000, reserve_tokens = 100 } }),
    "TCMP reserve leg fires")
  -- preflight projection adds the prompt cost
  assert_true(comp.should_summarize_projected({}, string.rep("z", 4000),
    { context = { max_tokens = 1000, reserve_tokens = 0 } }),
    "TCMP preflight projects the prompt")
  -- span split keeps system + window, anchors extract the goal
  local hist = { { role = "system", content = "sys" },
    { role = "user", content = "please fix the login bug" },
    { role = "assistant", content = "ok" } }
  local sys, old, keep = comp.split_span(hist, 1)
  assert_eq(sys.content, "sys", "TCMP split keeps system")
  assert_eq(#keep, 1, "TCMP split keeps the window")
  local a = comp.extract_anchors(hist)
  assert_true(a.goal ~= nil and a.goal:find("fix", 1, true) ~= nil, "TCMP anchor goal")
  assert_eq(comp.anchor_block({}, {}), "", "TCMP empty anchors render empty")
  -- truncation-only compression never mutates input (7 msgs, keep 1 → old span exists)
  local h2 = { { role = "system", content = "s" } }
  for i = 1, 6 do h2[#h2 + 1] = { role = "user", content = "m" .. i } end
  local out = comp.compress_history(h2, { context = { keep_recent_messages = 1 } })
  assert_eq(#h2, 7, "TCMP input untouched")
  assert_eq(out[2].role, "system", "TCMP summary row is system")
  assert_true(out[2].content:find(comp.SUMMARY_MARKER, 1, true) ~= nil, "TCMP marker present")
  -- facade parity through agent (same decision, no direct reference needed)
  local agent = assert(loadfile("src/tether/agent.lua"))()
  assert_eq(agent.should_summarize(big, { context = { max_tokens = 1000, reserve_tokens = 0 } }),
    comp.should_summarize(big, { context = { max_tokens = 1000, reserve_tokens = 0 } }),
    "TCMP facade decision parity")
  print("TCMP compression direct: OK")
end

do
  -- anchor-prune-fix 1.1: pinning tests for anchor_trim_prefix.
  -- Verified against the current guard before any edit: identical paths
  -- render their file name (guard is load-bearing, see compression.lua).
  local comp = assert(loadfile("src/tether/compression.lua"))()
  local trim = assert(comp.anchor_trim_prefix, "TCMP trim exposed for pinning")
  local function joined(t) return table.concat(t, ",") end
  assert_eq(joined(trim({ "src/tether/agent.lua", "src/tether/tools.lua" })),
    "agent.lua,tools.lua", "TCMP trim shared prefix")
  assert_eq(joined(trim({ "src/tether/agent.lua", "src/tether/agent.lua" })),
    "agent.lua,agent.lua", "TCMP trim identical keeps filename")
  assert_eq(joined(trim({ "src/a.lua", "docs/b.lua" })),
    "src/a.lua,docs/b.lua", "TCMP trim no common prefix unchanged")
  assert_eq(joined(trim({ "src/only.lua" })),
    "src/only.lua", "TCMP trim single path unchanged")
  assert_eq(joined(trim({ "a/b/c.lua", "a/b/d.lua" })),
    "c.lua,d.lua", "TCMP trim keeps trailing segment")
  print("TCMP anchor_trim_prefix pinning: OK")
end

if failed > 0 then
    os.exit(1)
end
