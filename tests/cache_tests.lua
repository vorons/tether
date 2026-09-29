-- tests/cache_tests.lua — prompt-cache (change prompt-cache-cleanup).
-- Run: lua tests/cache_tests.lua

dofile("tests/helpers.lua")

local function fresh_cache()
    local cache = assert(loadfile("src/tether/cache.lua"))()
    cache.reset()
    return cache
end

-- TC1 (1.1): deterministic serialization — sorted keys, sorted tools.
do
    local common = assert(loadfile("src/tether/providers/common.lua"))()
    local a = common.json_encode({ name = "x", description = "d",
        input_schema = { b = 1, a = 2 } })
    local b = common.json_encode({ input_schema = { a = 2, b = 1 },
        description = "d", name = "x" })
    assert_eq(a, b, "TC1 json_encode key order canonical")
    assert_eq(a, '{"description":"d","input_schema":{"a":2,"b":1},"name":"x"}',
        "TC1 keys sorted byte order")
    local names = {}
    for _, t in ipairs(common.sorted_tools()) do names[#names + 1] = t.name end
    local sorted = {}
    for _, n in ipairs(names) do sorted[#sorted + 1] = n end
    table.sort(sorted)
    assert_eq(table.concat(names, ","), table.concat(sorted, ","),
        "TC1 tools codepoint-sorted")
    -- filter order must not leak into the payload order
    assert_true(common.set_tools_filter({ "write", "read", "grep" }), "TC1 filter set")
    local kept = {}
    for _, t in ipairs(common.sorted_tools()) do kept[#kept + 1] = t.name end
    assert_eq(table.concat(kept, ","), "grep,read,write", "TC1 filtered payload sorted")
    assert_true(common.set_tools_filter(nil), "TC1 filter reset")
    -- same logical tools -> identical payload bytes across calls
    local openai = assert(loadfile("src/tether/providers/openai.lua"))()
    local msgs = { { role = "user", content = "hi" } }
    local p1 = openai.build_request(msgs, "m")
    local p2 = openai.build_request(msgs, "m")
    assert_eq(p1, p2, "TC1 identical tools payload bytes")
    print("TC1 deterministic serialization: OK")
end

-- TC2 (1.2): no volatile values in the cached prefix — 10 sequential
-- builds are byte-identical.
do
    local openai = assert(loadfile("src/tether/providers/openai.lua"))()
    local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
    local hist = {
        { role = "system", content = "sys" },
        { role = "user", content = "do the thing" },
        { role = "assistant", content = { tool_calls = { { id = "t1",
            type = "function",
            ["function"] = { name = "read", arguments = '{"path":"a"}' } } } } },
        { role = "tool", tool_call_id = "t1", content = "out" },
    }
    local first_o = openai.build_request(hist, "m")
    local first_a = anthropic.build_request(hist, "m", 128)
    for _ = 1, 10 do
        assert_eq(openai.build_request(hist, "m"), first_o, "TC2 openai stable")
        assert_eq(anthropic.build_request(hist, "m", 128), first_a,
            "TC2 anthropic stable")
    end
    print("TC2 prefix byte-stability: OK")
end

-- TC3 (2.1): session key — slug[:64], stable across turns, survives
-- compaction (key derives from the session id, which compaction keeps).
do
    local cache = fresh_cache()
    assert_eq(cache.session_key("Sess_ABC 12"), "sess-abc-12", "TC3 slug")
    assert_eq(cache.session_key(nil), "", "TC3 nil session")
    assert_eq(cache.session_key(""), "", "TC3 empty session")
    assert_eq(#cache.session_key(string.rep("z", 200)), 64, "TC3 64-char cap")
    local cfg = { _session_id = "my-session-7" }
    local msgs = { { role = "system", content = "S" }, { role = "user", content = "a" } }
    local k1 = cache.plan(cfg, msgs).key
    msgs[#msgs + 1] = { role = "assistant", content = "b" }
    local k2 = cache.plan(cfg, msgs).key
    assert_eq(k1, "my-session-7", "TC3 key is the slug")
    assert_eq(k1, k2, "TC3 key stable across turns")
    -- compacted history (new table, same session) keeps the key
    local compacted = { { role = "system", content = "S" },
        { role = "system", content = "SUMMARY\n..." },
        { role = "user", content = "b" } }
    assert_eq(cache.plan(cfg, compacted).key, k1, "TC3 key survives compaction")
    -- disabled cache plans nothing
    assert_true(cache.plan({ cache = { enabled = false }, _session_id = "x" },
        msgs) == nil, "TC3 disabled -> no plan")
    print("TC3 session key: OK")
end

-- TC4 (2.2): subagent inherits the parent key via env; the child reuses it
-- on a matching prompt and derives on a divergent one.
do
    local sub = assert(loadfile("src/tether/subagent.lua"))()
    local _, opts = sub.build_command({ task = "fix", cwd = "/ws", timeout = 5 }, {})
    assert_true(opts.env.TETHER_CACHE_KEY == nil,
        "TC4 no key without a session")
    local _, opts_parent = sub.build_command({ task = "fix", cwd = "/ws", timeout = 5 },
        { cfg = { _session_id = "Parent_S1",
            _system_blocks = { { name = "identity", text = "ID" } } } })
    assert_eq(opts_parent.env.TETHER_CACHE_KEY, "parent-s1",
        "TC4 parent key in child env")
    assert_true(opts_parent.env.TETHER_CACHE_SYS ~= nil
        and opts_parent.env.TETHER_CACHE_SYS:find("^%x+$") ~= nil,
        "TC4 parent sys hash in child env")
    -- child-side decision is pure (no subprocess): matching prompt reuses
    -- the parent key, a divergent prompt derives, no env falls back to
    -- the session slug.
    local cache_c = fresh_cache()
    local sys_hash = cache_c.blocks_hash({ { name = "identity", text = "ID" } })
    assert_eq(cache_c.child_key("parent-s1", sys_hash, sys_hash), "parent-s1",
        "TC4 child reuses parent key")
    local other = cache_c.blocks_hash({ { name = "identity", text = "OTHER" } })
    assert_eq(cache_c.child_key("parent-s1", sys_hash, other), "parent-s1:child",
        "TC4 divergent derives")
    assert_eq(cache_c.derive_key("parent-s1"), "parent-s1:child",
        "TC4 derive fixed suffix")
    assert_eq(cache_c.derive_key(""), "", "TC4 derive empty parent")
    if os.getenv("TETHER_CACHE_KEY") == nil then
        assert_eq(cache_c.resolve_key({ _session_id = "Kid_9" }, nil), "kid-9",
            "TC4 session slug fallback")
    end
    print("TC4 subagent inheritance: OK")
end

-- TC5 (3.1/3.2/3.3): markers — anthropic cache_control trio on first
-- sight, openai prompt_cache_key, legacy bodies untouched when unplanned.
do
    local cache = fresh_cache()
    local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
    local openai = assert(loadfile("src/tether/providers/openai.lua"))()
    local hist = {
        { role = "system", content = "sys" },
        { role = "user", content = "go" },
    }
    local legacy_a = anthropic.build_request(hist, "m", 128)
    assert_true(legacy_a:find('"system":"sys"', 1, true) ~= nil,
        "TC5 legacy system string")
    assert_true(not legacy_a:find("cache_control", 1, true),
        "TC5 legacy no markers")
    local legacy_o = openai.build_request(hist, "m")
    assert_true(not legacy_o:find("prompt_cache_key", 1, true),
        "TC5 legacy no key")
    local plan = cache.plan({ _session_id = "s5" }, hist)
    local marked = anthropic.build_request(hist, "m", 128, nil, plan)
    assert_true(marked:find('"system":[{', 1, true) ~= nil,
        "TC5 system array form")
    local n = 0
    for _ in marked:gmatch("cache_control") do n = n + 1 end
    assert_eq(n, 3, "TC5 three markers (system end, tools, last msg)")
    local keyed = openai.build_request(hist, "m", nil, nil, plan)
    assert_true(keyed:find('"prompt_cache_key":"s5"', 1, true) ~= nil,
        "TC5 openai key present")
    -- long_retention rides as a ttl on the markers
    local cache_h = fresh_cache()
    local plan_h = cache_h.plan({ _session_id = "s5h",
        cache = { long_retention = true } }, hist)
    assert_eq(plan_h.ttl, "1h", "TC5 plan ttl")
    local marked_h = anthropic.build_request(hist, "m", 128, nil, plan_h)
    assert_true(marked_h:find('"ttl":"1h"', 1, true) ~= nil, "TC5 ttl marker")
    print("TC5 markers: OK")
end

-- TC6 (4.1/4.2): block split — a tail change keeps the head entry warm.
do
    local cache = fresh_cache()
    local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
    local cfg = { _session_id = "s6", _system_blocks = {
        { name = "identity", text = "ID" },
        { name = "agents", text = "AG1" },
        { name = "skills", text = "SK" },
    } }
    local msgs = { { role = "system", content = "ID" },
        { role = "user", content = "hi" } }
    local p1 = cache.plan(cfg, msgs)
    assert_true(p1.sys_head == nil, "TC6 first sight: end marker only")
    cfg._system_blocks[2].text = "AG2"
    local p2 = cache.plan(cfg, msgs)
    assert_eq(p2.sys_head, 1, "TC6 head after the unchanged block")
    local body = anthropic.build_request(msgs, "m", 128, nil, p2)
    assert_true(body:find('"text":"ID","cache_control"', 1, true) ~= nil,
        "TC6 head block still cache-marked")
    local n = 0
    for _ in body:gmatch("cache_control") do n = n + 1 end
    assert_true(n <= 4, "TC6 within the 4-slot budget")
    -- volatile first block: no head marker, end marker still stands
    cfg._system_blocks[1].text = "ID2"
    local p3 = cache.plan(cfg, msgs)
    assert_true(p3.sys_head == nil, "TC6 changed head: no head marker")
    print("TC6 block split: OK")
end

-- TC7 (5.1): usage parsing — cache fields reach the canonical event.
do
    local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
    anthropic.reset_stream()
    local got = {}
    local function on(ev) got[#got + 1] = ev end
    anthropic.parse_sse_line(
        'data: {"type":"message_start","message":{"usage":{"input_tokens":100,'
        .. '"cache_creation_input_tokens":90,"cache_read_input_tokens":800}}}', on)
    anthropic.parse_sse_line(
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},'
        .. '"usage":{"output_tokens":5}}', on)
    for _, ev in ipairs(got) do
        if ev.type == "usage" then
            assert_eq(ev.usage.used, 105, "TC7 anthropic used")
            assert_eq(ev.usage.cache_read_tokens, 800, "TC7 anthropic read")
            assert_eq(ev.usage.cache_write_tokens, 90, "TC7 anthropic write")
        end
    end
    local openai = assert(loadfile("src/tether/providers/openai.lua"))()
    openai.reset_stream()
    local oev
    openai.parse_sse_line(
        'data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":10,'
        .. '"prompt_tokens_details":{"cached_tokens":150}}}',
        function(ev) oev = ev end)
    assert_notnil(oev, "TC7 openai usage event")
    assert_eq(oev.usage.cache_read_tokens, 150, "TC7 openai cached")
    assert_eq(oev.usage.used, 210, "TC7 openai used unchanged")
    local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
    gemini.reset_stream()
    local gev
    gemini.parse_sse_line(
        'data: {"candidates":[{"content":{"parts":[{"text":"hi"}],"role":"model"}}],'
        .. '"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":7,'
        .. '"cachedContentTokenCount":4}}',
        function(ev) if ev.type == "usage" then gev = ev end end)
    assert_notnil(gev, "TC7 gemini usage event")
    assert_eq(gev.usage.cache_read_tokens, 4, "TC7 gemini cached")
    assert_eq(gev.usage.used, 12, "TC7 gemini used unchanged")
    print("TC7 usage parsing: OK")
end

-- TC8 (removed): hit-rate diagnostic deleted by the cleanup change.
-- Usage records (TC9) are the remaining observability; providers that
-- report no cache fields simply record zeros.
do
    local cache = fresh_cache()
    assert_true(cache.observe == nil, "TC8 observe stays deleted")
    assert_true(cache.WINDOW == nil and cache.HIT_FLOOR == nil,
        "TC8 window constants stay deleted")
    print("TC8 no-diagnosis regression: OK")
end

-- TC9 (5.1 records): llm_cache_usage record shape + ring.
do
    local cache = fresh_cache()
    local rec = cache.usage_record{
        session_id = "s9", cache_key = "s9", provider = "anthropic",
        model = "claude-x",
        usage = { prompt_tokens = 100, cache_read_tokens = 80,
            cache_write_tokens = 20 },
        blocks = { { name = "identity", hash = "h1" } },
        ttl = "5m", cache_key_present = true, turn_blocks_count = 4,
    }
    assert_eq(rec.event, "llm_cache_usage", "TC9 event name")
    assert_eq(rec.input_tokens, 100, "TC9 input")
    assert_eq(rec.cache_read_tokens, 80, "TC9 read")
    assert_eq(rec.cache_write_tokens, 20, "TC9 write")
    assert_eq(rec.prefix_blocks[1].name, "identity", "TC9 block hashes")
    assert_eq(rec.turn_blocks_count, 4, "TC9 turn size")
    assert_true(cache.last_record() == nil, "TC9 ring starts empty")
    cache.store_record(rec)
    assert_eq(cache.last_record().cache_key, "s9", "TC9 ring stores")
    print("TC9 usage records: OK")
end

-- TC10 (5.2): cache config defaults + merge/fallbacks.
do
    local cs = assert(loadfile("src/tether/config_schema.lua"))()
    local d = cs.default_config()
    assert_eq(d.cache.enabled, true, "TC10 default enabled")
    assert_eq(d.cache.long_retention, false, "TC10 default retention")
    assert_eq(d.cache.debug, false, "TC10 default debug")
    _G.provider_catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
    local config = assert(loadfile("src/tether/config.lua"))()
    local home = "/tmp/tether_cache_tc10"
    os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
    local cfg = config.load(home .. "/no-such-config.lua", home)
    assert_eq(cfg.cache.enabled, true, "TC10 missing table defaults")
    assert_eq(cfg.cache.long_retention, false, "TC10 missing retention defaults")
    local f = assert(io.open(home .. "/.tether/config.lua", "w"))
    f:write('return { cache = { enabled = "yes", long_retention = "maybe",'
        .. ' key_scope = "session_role", retention = "1h",'
        .. ' intermediate_breakpoints = -3 } }\n')
    f:close()
    local cfg2 = config.load(home .. "/.tether/config.lua", home)
    assert_eq(cfg2.cache.enabled, true, "TC10 bad enabled falls back")
    assert_eq(cfg2.cache.long_retention, false, "TC10 bad retention falls back")
    local f2 = assert(io.open(home .. "/.tether/config.lua", "w"))
    f2:write("return { cache = { enabled = false } }\n")
    f2:close()
    local cfg3 = config.load(home .. "/.tether/config.lua", home)
    assert_eq(cfg3.cache.enabled, false, "TC10 explicit false survives")
    os.execute("rm -rf " .. home)
    print("TC10 cache config: OK")
end

-- TC11 (3.1/5.1 end to end): api.stream threads the plan into the wire
-- body and stores one llm_cache_usage record (mocked transport).
do
    local cache = fresh_cache()
    _G.cache = cache
    local api = assert(loadfile("src/tether/api.lua"))()
    local seen_body = nil
    _G.tether = {
        fchmod = function() return true end,
        http_stream = function(_method, _url, _headers, bodyref, feed, _opts)
            local path = tostring(bodyref):match("^@(.+)$")
            local bf = io.open(path, "r")
            seen_body = bf and bf:read("*a") or ""
            if bf then bf:close() end
            feed('data: {"choices":[{"delta":{"content":"hi"}}],'
                .. '"usage":{"prompt_tokens":100,"completion_tokens":5,'
                .. '"prompt_tokens_details":{"cached_tokens":80}}}')
            feed('data: {"choices":[{"finish_reason":"stop"}]}')
            feed('data: [DONE]')
            return true
        end,
    }
    local evs = {}
    local cfg = { provider = "llama-cpp", model = "m",
        base_url = "http://127.0.0.1:9",
        _session_id = "tc11-session", _cache_key = "tc11-key" }
    local ok, failure = api.stream(cfg, "k",
        { { role = "system", content = "S" }, { role = "user", content = "hi" } },
        function(ev) evs[#evs + 1] = ev end)
    assert_true(ok, "TC11 stream ok: " .. tostring(failure and failure.message))
    assert_notnil(seen_body, "TC11 body captured")
    assert_true(seen_body:find('"prompt_cache_key":"tc11-key"', 1, true) ~= nil,
        "TC11 plan threaded into the wire body")
    local rec = cache.last_record()
    assert_notnil(rec, "TC11 usage record stored")
    assert_eq(rec.event, "llm_cache_usage", "TC11 record event")
    assert_eq(rec.input_tokens, 100, "TC11 record input")
    assert_eq(rec.cache_read_tokens, 80, "TC11 record read")
    assert_eq(rec.cache_key, "tc11-key", "TC11 record key")
    assert_eq(rec.session_id, "tc11-session", "TC11 record session")
    _G.cache = nil
    _G.tether = nil
    print("TC11 api threading: OK")
end

if failed > 0 then
    os.exit(1)
end
