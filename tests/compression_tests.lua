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

-- offline-provider-catalog: per-model limit chain ends at 200000.
do
  local home = os.tmpname()
  os.remove(home)
  assert(os.execute("mkdir -p " .. home .. "/.tether"))
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local function write_shard(models)
    local cache = { metap = { checked_at = os.time(), models = models } }
    local f = assert(io.open(home .. "/.tether/metadata_cache.json", "w"))
    f:write(common.json_encode(cache))
    f:close()
  end
  local orig_catalog, orig_md = _G.provider_catalog, _G.provider_metadata
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    metap = { wire = "openai", base_url = "https://m.example/v1",
      api_key_env = "M", model = "def", _source = "test" },
  }, { generated_at = 0 })
  _G.provider_catalog = catfix
  _G.provider_metadata = assert(loadfile("src/tether/metadata.lua"))()
  local comp = assert(loadfile("src/tether/compression.lua"))()

  -- metadata exact hit.
  write_shard({ { id = "m", context = 9000 }, { id = "def", context = 5000 } })
  assert_eq(comp.catalog_max_tokens({ provider = "metap", model = "m",
    _auth_home = home }), 9000, "TCMP metadata exact hit")
  -- metadata provider-default fallback.
  assert_eq(comp.catalog_max_tokens({ provider = "metap", model = "unknown",
    _auth_home = home }), 5000, "TCMP metadata default fallback")
  -- absent everywhere: 200000, never nil.
  assert_eq(comp.catalog_max_tokens({ provider = "metap", model = "nope",
    _auth_home = home .. "-empty" }), 200000, "TCMP absent is 200k")
  assert_eq(comp.catalog_max_tokens({}), 200000, "TCMP no provider is 200k")
  -- legacy entry.models still serves (old full-form caches).
  catfix.set_overlay({
    metap = { wire = "openai", base_url = "https://m.example/v1",
      api_key_env = "M", model = "def",
      models = { { id = "legacy-m", context = 7000 } }, _source = "test" },
  }, { generated_at = 0 })
  assert_eq(comp.catalog_max_tokens({ provider = "metap",
    model = "legacy-m", _auth_home = home .. "-empty" }), 7000,
    "TCMP legacy entry.models serves")
  -- metadata wins over legacy for the same id.
  assert_eq(comp.catalog_max_tokens({ provider = "metap", model = "m",
    _auth_home = home }), 9000, "TCMP metadata wins over legacy")
  -- explicit user value wins over everything.
  local mt = comp.compaction_thresholds({ provider = "metap", model = "m",
    _auth_home = home, context = { max_tokens = 16384 } })
  assert_eq(mt, 16384, "TCMP user value wins")
  _G.provider_catalog, _G.provider_metadata = orig_catalog, orig_md
  os.execute("rm -rf " .. home)
  print("TCMP metadata chain: OK")
end

if failed > 0 then
    os.exit(1)
end
