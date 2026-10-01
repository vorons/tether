-- tests/agent_tests.lua — agent/api/retry/config/reasoning (split from lua_tests.lua, Phase C).
-- Run: lua tests/agent_tests.lua

dofile("tests/helpers.lua")
-- T178: a retry in turn N must not drop previous turns' answers.
-- Regression: attempt numbering restarts at 1 every turn
-- (agent reset_retry_state), but transcript's retry-drop removed
-- same-attempt entries across the WHOLE transcript — turn 1's completed
-- answer (tagged 1) vanished when turn 2 retried attempt 1.
do
  local orig_agent = _G.agent
  local orig_tether = _G.tether
  -- post-run driving reads the host via _G.tether (clock + stash drain);
  -- pin a deterministic mock instead of inheriting leakage from other files.
  _G.tether = host_mock{ monotonic_ms = function() return 0 end,
    read_char = function() return nil end, read_char_nb = function() return nil end }
  local turn_no = 0
  _G.agent = {
    -- like the real agent: attempt numbers restart at 1 every turn
    turn = function(_, _, _, on_event)
      turn_no = turn_no + 1
      if turn_no == 1 then
        on_event({ type = "text_delta", attempt = 1, text = "answer one" })
      else
        on_event({ type = "text_delta", attempt = 1, text = "doomed partial" })
        on_event({ type = "retry", attempt = 1, delay = 0, reason = "boom" })
        on_event({ type = "text_delta", attempt = 2, text = "answer two" })
      end
      return true
    end,
    get_history = function() return {} end,
  }
  local uim = run_ui_with({ 17 }, { agent = _G.agent })
  local function type_text(s)
    for i = 1, #s do uim._handle_key({ kind = "text", char = s:sub(i, i) }) end
  end
  type_text("one")
  uim._handle_key({ kind = "enter" })
  type_text("two")
  uim._handle_key({ kind = "enter" })
  _G.agent = orig_agent
  _G.tether = orig_tether
  local saw_one, saw_two, saw_doomed = false, false, false
  for _, e in ipairs(tentries(uim)) do
    if e.role == "assistant" and e.text == "answer one" then saw_one = true end
    if e.role == "assistant" and e.text == "answer two" then saw_two = true end
    if e.role == "assistant" and (e.text or ""):find("doomed", 1, true) then
      saw_doomed = true
    end
  end
  assert_true(saw_one, "T178 turn 1 answer survives turn 2 retry")
  assert_true(saw_two, "T178 turn 2 answer lands after retry")
  assert_true(not saw_doomed, "T178 failed attempt partial is dropped")
  print("T178 retry keeps previous answers: OK")
end

-- T179: empty string deltas emit nothing (no `"content":""` garbage).
-- Regression: the `or match('"..."')` empty-value fallbacks had no capture
-- group, so string.match returned the whole key fragment and it was emitted
-- as a text/argument delta (every turn starts with an empty-content frame).
do
  local openai_p = assert(loadfile("src/tether/providers/openai.lua"))()
  local anthropic_p = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local codex_p = assert(loadfile("src/tether/providers/openai-codex.lua"))()
  local function collect(mod, line)
    local evs = {}
    mod.parse_sse_line(line, function(ev) evs[#evs + 1] = ev end)
    return evs
  end
  -- empty frames: zero events (they used to emit `"content":""` etc.)
  assert_eq(#collect(openai_p,
    'data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}'),
    0, "T179 openai empty content silent")
  assert_eq(#collect(anthropic_p,
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}'),
    0, "T179 anthropic empty text silent")
  assert_eq(#collect(codex_p,
    'data: {"type":"response.output_text.delta","output_index":0,"delta":""}'),
    0, "T179 codex empty delta silent")
  assert_eq(#collect(codex_p,
    'data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":""}'),
    0, "T179 codex empty args silent")
  -- non-empty values still flow, unescaped once
  local oevs = collect(openai_p, 'data: {"choices":[{"index":0,"delta":{"content":"Hi!"}}]}')
  assert_eq(#oevs, 1, "T179 openai text flows")
  assert_eq(oevs[1].text, "Hi!", "T179 openai text intact")
  local aevs = collect(anthropic_p,
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hey"}}')
  assert_eq(#aevs, 1, "T179 anthropic text flows")
  assert_eq(aevs[1].text, "Hey", "T179 anthropic text intact")
  local cevs = collect(codex_p,
    'data: {"type":"response.output_text.delta","output_index":0,"delta":"Yo"}')
  assert_eq(#cevs, 1, "T179 codex text flows")
  assert_eq(cevs[1].text, "Yo", "T179 codex text intact")
  print("T179 empty deltas are silent: OK")
end

-- T330 (audit M7): the space after `data:` is optional. Each wire used to
-- filter with sub(1, 6) ~= "data: ", so a provider emitting `data:{...}`
-- delivered a stream that parsed into nothing at all.
do
  local openai_p = assert(loadfile("src/tether/providers/openai.lua"))()
  local anthropic_p = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local gemini_p = assert(loadfile("src/tether/providers/gemini.lua"))()
  local codex_p = assert(loadfile("src/tether/providers/openai-codex.lua"))()
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local function collect(mod, line)
    local evs = {}
    mod.parse_sse_line(line, function(ev) evs[#evs + 1] = ev end)
    return evs
  end
  local function kinds(mod, line)
    local out = {}
    for _, ev in ipairs(collect(mod, line)) do
      out[#out + 1] = (ev.type or "?") .. "/" .. tostring(ev.text or "")
    end
    return table.concat(out, ",")
  end

  assert_eq(common.sse_payload('data:{"a":1}'), '{"a":1}', "T330 no-space payload")
  assert_eq(common.sse_payload('data: {"a":1}'), '{"a":1}', "T330 spaced payload")
  assert_eq(common.sse_payload('data:{"a":1}   '), '{"a":1}', "T330 trailing blanks trimmed")
  assert_eq(common.sse_payload("event: message_start"), nil, "T330 event field is no payload")
  assert_eq(common.sse_payload(": keepalive"), nil, "T330 comment is no payload")
  assert_eq(common.sse_payload("id: 7"), nil, "T330 id field is no payload")
  assert_eq(common.sse_payload("data"), nil, "T330 bare field name is no payload")
  assert_eq(common.sse_payload(nil), nil, "T330 nil line is no payload")

  local frames = {
    { openai_p, '{"choices":[{"index":0,"delta":{"content":"Hi!"}}]}', "text_delta/Hi!" },
    { anthropic_p,
      '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hey"}}',
      "text_delta/Hey" },
    { gemini_p,
      '{"candidates":[{"content":{"parts":[{"text":"Hola"}],"role":"model"}}]}',
      "text_delta/Hola" },
    { codex_p, '{"type":"response.output_text.delta","output_index":0,"delta":"Yo"}',
      "text_delta/Yo" },
  }
  for _, f in ipairs(frames) do
    assert_eq(kinds(f[1], "data:" .. f[2]), f[3], "T330 frame without the space flows")
    assert_eq(kinds(f[1], "data: " .. f[2]), f[3], "T330 same frame spaced is identical")
    assert_eq(#collect(f[1], "event: ping"), 0, "T330 an event field yields nothing")
    assert_eq(#collect(f[1], "data:   " .. f[2]), 1, "T330 extra blanks stay one event")
    local done = collect(f[1], "data:[DONE]")
    assert_eq(#done, 1, "T330 unspaced sentinel ends the stream")
    assert_eq(done[1].type, "done", "T330 unspaced sentinel is a done event")
  end
  print("T330 SSE frames parse without the space: OK")
end

-- T331 (audit M4): the provider error body turns into ONE bounded,
-- control-free, redacted string at api.lua; the banner, transcript, journal
-- and debug log all read that string.
do
  local orig_tether = _G.tether
  local api_mod = assert(loadfile("src/tether/api.lua"))()
  local function failure_message(body)
    _G.tether = host_mock{
      http_stream = function(_, _, _, _, on_line)
        on_line(body)
        return true
      end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    local ok, failure = api_mod.stream({ provider = "openai", base_url = "http://x",
      model = "m" }, "key", { { role = "user", content = "hi" } }, function() end)
    _G.tether = orig_tether
    assert_true(not ok, "T331 the body fails the attempt")
    return failure.message
  end

  -- an escape sequence and a NUL in the body never reach the terminal
  local ctrl = failure_message('{"error":{"message":"\27[31m boom\0 done","status":400}}')
  assert_eq(ctrl:find("%c"), nil, "T331 no control byte survives the snippet")
  assert_true(ctrl:find("http 400:", 1, true) == 1, "T331 the status still leads")

  -- credential material is redacted before the snippet escapes this layer
  local key = failure_message('{"error":{"message":"bad","status":401,'
      .. '"api_key":"sk-secret-leak-123"}}')
  assert_true(key:find("sk-secret-leak-123", 1, true) == nil, "T331 an api_key is redacted")
  assert_true(key:find('"api_key":"***"', 1, true) ~= nil, "T331 the field still reads redacted")
  local bearer = failure_message('{"error":{"message":"Bearer sk-another-secret",'
      .. '"status":403}}')
  assert_true(bearer:find("sk-another-secret", 1, true) == nil, "T331 a bearer token is redacted")

  -- the 2000-byte budget stays, but the cut lands on a glyph boundary
  local boundary = string.rep("a", 1999) .. "П" .. "tail"
  local cut = failure_message(boundary)
  assert_notnil(utf8.len(cut), "T331 the cut keeps valid UTF-8")
  assert_true(#cut >= 2000, "T331 the generous budget is kept")
  assert_true(cut:find("tail", 1, true) == nil, "T331 the body is still bounded")
  assert_true(failure_message(string.rep("b", 400)):find("http ?:", 1, true) == 1,
      "T331 a statusless body still reads http ?:")
  print("T331 error snippet is bounded, control-free, redacted: OK")
end

-- T346 (audit M14): the request body file is private before its content —
-- fchmod lands ahead of the first write, and a refused mode fails the
-- request instead of sending a world-readable body.
do
  local api_mod = assert(loadfile("src/tether/api.lua"))()
  local order = {}
  local real_open = io.open
  local function watch_open(path, mode)
    local f = real_open(path, mode)
    if f and type(path) == "string" and path:sub(-5) == ".body" then
      order[#order + 1] = "open:" .. tostring(mode)
      local wrapped = {}
      setmetatable(wrapped, { __index = function(_, k)
        if k == "write" then
          return function(_, ...)
            order[#order + 1] = "write"
            return f:write(...)
          end
        elseif k == "close" then
          return function() return f:close() end
        end
        return f[k]
      end })
      return wrapped
    end
    return f
  end
  local orig_tether = _G.tether
  local function run_stream(fchmod_body)
    order = {}
    _G.tether = host_mock{
      fchmod = function(path, _mode)
        if type(path) == "string" and path:sub(-5) == ".body" then
          order[#order + 1] = "fchmod"
          return fchmod_body
        end
        return true
      end,
      http_stream = function(_, _, _, _, on_line)
        on_line('data: {"choices":[{"delta":{"content":"hi"}}]}')
        return true
      end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    io.open = watch_open
    local ok, failure = api_mod.stream({ provider = "openai", base_url = "http://x",
      model = "m" }, "key", { { role = "user", content = "hi" } }, function() end)
    _G.tether = orig_tether
    io.open = real_open
    return ok, failure
  end
  assert_true(run_stream(true), "T346 the request succeeds")
  local fi, wi
  for i, e in ipairs(order) do
    if e == "fchmod" then fi = fi or i end
    if e == "write" then wi = wi or i end
  end
  assert_notnil(fi, "T346 fchmod ran on the body path")
  assert_notnil(wi, "T346 the body was written")
  assert_true(fi < wi, "T346 the mode lands before the first byte")
  local ok2, failure2 = run_stream(false)
  assert_true(not ok2, "T346 a refused mode fails the request")
  assert_true(tostring(failure2 and failure2.message or failure2):find(
    "lock down", 1, true) ~= nil, "T346 the failure names the lockdown")
  for _, e in ipairs(order) do
    assert_true(e ~= "write", "T346 nothing is written when the mode fails")
  end
  print("T346 body file is private before its content: OK")
end

-- T347 (audit M15): auth refresh respects the retry verdict. A rejecting
-- refresh token costs one backed-off retry and a single error — not a
-- hammer loop — and a renewed token still saves the turn.
do
  local retry = assert(loadfile("src/tether/retry.lua"))()
  local ws = os.tmpname()
  os.remove(ws)
  assert(host_fs.mkdirp(ws))
  local orig_tether, orig_tools = _G.tether, _G.tools
  local orig_session, orig_config = _G.session, _G.config
  local orig_api, orig_auth = _G.api, _G.auth
  local sleeps, streams, refreshes = {}, {}, {}
  local fail401 = retry.failure("permanent", "http 401: unauthorized", 401)
  _G.tether = host_mock({
    getcwd = function() return ws end,
    realpath = function(p) return p end,
    exec = function() return true, 0 end,
    monotonic_ms = function() return 0 end,
    sleep = function(s) sleeps[#sleeps + 1] = s end,
  })
  _G.tools = assert(loadfile("src/tether/tools.lua"))()
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.extensions = nil
  local mode = "reject"
  _G.api = {
    stream = function(_, _, _, on_event)
      streams[#streams + 1] = true
      if mode == "renew" and #streams == 2 then
        on_event({ type = "text_delta", text = "back" })
        on_event({ type = "done", reason = "stop" })
        return true, nil
      end
      return false, fail401
    end,
  }
  _G.auth = {
    load = function() return { openai = {
      kind = "oauth", access_token = "old", refresh_token = "rt-dead",
      refresh_url = "https://example/token" } } end,
    save = function() return true end,
    _post_json = function() return nil, "rejected" end,
    refresh_token = function()
      refreshes[#refreshes + 1] = true
      return mode == "renew"
    end,
  }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local function run_turn()
    agent.clear()
    agent.reset_retry_state()
    sleeps, streams, refreshes = {}, {}, {}
    local evs = {}
    local ok = agent.turn({ workspace = ws, provider = "openai",
      retry = { base_delay_ms = 10, max_delay_ms = 100 } },
      "", "hi", function(ev) evs[#evs + 1] = ev end)
    return ok, evs
  end
  -- rejecting refresh: backoff ran, one refresh, one error, then stop
  mode = "reject"
  local ok, evs = run_turn()
  assert_true(not ok, "T347 dead refresh ends the turn failed")
  assert_eq(#streams, 2, "T347 the failed refresh costs one retry")
  assert_eq(#refreshes, 1, "T347 at most one refresh request")
  assert_true(#sleeps >= 1 and (sleeps[1] or 0) > 0, "T347 the backoff ran")
  local errors = {}
  for _, ev in ipairs(evs) do
    if ev.type == "error" then errors[#errors + 1] = ev end
  end
  assert_eq(#errors, 1, "T347 the turn ends with one error")
  assert_true(errors[1].message:find("/login", 1, true) ~= nil,
    "T347 the error suggests /login")
  -- renewing refresh: the backed-off retry uses the new token, no error
  mode = "renew"
  local ok2, evs2 = run_turn()
  assert_true(ok2, "T347 a renewed token saves the turn")
  assert_eq(#refreshes, 1, "T347 success still refreshes once")
  assert_true(#sleeps >= 1 and (sleeps[1] or 0) > 0,
    "T347 the refreshed retry waits too")
  for _, ev in ipairs(evs2) do
    assert_true(ev.type ~= "error", "T347 no error event on rescue")
  end
  _G.tether, _G.tools = orig_tether, orig_tools
  _G.session, _G.config = orig_session, orig_config
  _G.api, _G.auth = orig_api, orig_auth
  os.execute("rm -rf '" .. ws .. "'")
  print("T347 refresh respects the retry verdict: OK")
end

-- T336 (audit M2): stored tool-call arguments encode exactly once. History
-- holds DECODED arguments (agent.lua unescapes at echo time), so the
-- Anthropic encoder must splice them verbatim: a second unescape turns
-- {"command":"echo \"hi\""} into {"command":"echo "hi""} and the provider
-- answers "arguments must be valid JSON".
do
  local anthropic_p = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local function assistant_msg(args)
    return { role = "assistant", content = { tool_calls = {
      { id = "call_1", type = "function",
        ["function"] = { name = "run", arguments = args } },
    }, text = "" } }
  end
  local decoded = '{"command":"echo \\"hi\\""}'
  local _, msgs = anthropic_p.convert_messages(
    { { role = "user", content = "run it" }, assistant_msg(decoded) })
  assert_true(msgs:find('"input":{"command":"echo \\"hi\\""}', 1, true) ~= nil,
    "T336 quoted arguments survive the encode verbatim")
  local parsed = common.json_decode(msgs)
  assert_notnil(parsed, "T336 the emitted messages parse as JSON")
  local input = parsed[2].content[1].input
  assert_eq(input.command, 'echo "hi"', "T336 the round-tripped command is intact")

  local _, empty_msgs = anthropic_p.convert_messages(
    { assistant_msg("") })
  assert_true(empty_msgs:find('"input":{}', 1, true) ~= nil,
    "T336 empty arguments encode as {}")
  local _, absent_msgs = anthropic_p.convert_messages(
    { assistant_msg(nil) })
  assert_true(absent_msgs:find('"input":{}', 1, true) ~= nil,
    "T336 absent arguments encode as {}")
  print("T336 stored tool-call arguments encode exactly once: OK")
end

-- T180: audit fixes — extra_headers mechanism (catalog + user override, CRLF guard)
do
  local api = assert(loadfile("src/tether/api.lua"))()
  -- catalog entry: providers.deepseek.extra_headers; user override: extra_headers
  local cfg = {
    provider = "deepseek", base_url = "http://x", model = "m",
    providers = { deepseek = { extra_headers = { ["X-Catalog"] = "cat",
                                                 ["X-Both"] = "from-catalog" } } },
    extra_headers = { ["X-Both"] = "from-user", ["X-User"] = "usr" },
  }
  local lines = api._extra_header_lines(cfg)
  local function find(name)
    for _, ln in ipairs(lines) do
      if ln:find(name .. ": ", 1, true) == 1 then return ln end
    end
    return nil
  end
  assert_eq(find("X-Catalog"), "X-Catalog: cat", "T180 catalog header present")
  assert_eq(find("X-User"), "X-User: usr", "T180 user header present")
  assert_eq(find("X-Both"), "X-Both: from-user", "T180 user override wins")
  -- CRLF / header-splitting values and names are dropped, not smuggled
  local bad = { provider = "deepseek",
    extra_headers = { ["X-Evil"] = "x\r\nEvil: 1", ["X-Col:on"] = "v",
                      ["X-Ok"] = "fine", ["X-NL"] = "a\nb" } }
  local bad_lines = api._extra_header_lines(bad)
  local found_ok = false
  for _, ln in ipairs(bad_lines) do
    assert_true(ln == "X-Ok: fine", "T180 CRLF names/values dropped: " .. ln)
    if ln == "X-Ok: fine" then found_ok = true end
  end
  assert_true(found_ok, "T180 safe header kept")
  -- no extra_headers anywhere → empty
  assert_eq(#api._extra_header_lines({ provider = "openai" }), 0,
    "T180 empty when unconfigured")
  print("T180 extra_headers: OK")
end

-- T181: models requests carry session id + extra headers (every request of
-- a preset — models-hctx used to omit session_id, breaking x-opencode-session)
do
  local orig_api_g = _G.api
  local orig_tether = _G.tether
  local seen_headers = nil
  -- api.lua reads the catalog through _G.provider_catalog (plain-lua tests
  -- must provide it or every provider falls back to the openai wire).
  -- dynamic-provider-catalog: seed opencode (thin bootstrap lacks Tier-A).
  local catalog = dofile("src/tether/providers/catalog.lua")
  catalog.set_overlay({
    opencode = { wire = "openai", base_url = "https://opencode.ai/zen/v1",
      api_key_env = "OPENCODE_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  _G.provider_catalog = catalog
  local api = assert(loadfile("src/tether/api.lua"))()
  _G.api = api
  _G.tether = host_mock{
    http_get = function(url, headers)
      -- headers arrive as { "@file" }; read the referenced temp file
      for _, entry in ipairs(headers or {}) do
        if entry:sub(1, 1) == "@" then
          local f = io.open(entry:sub(2), "r")
          seen_headers = f and f:read("*a") or ""
          if f then f:close() end
          os.remove(entry:sub(2))
        end
      end
      return '{"data":[{"id":"m1"}]}'
    end,
    fchmod = function() return true end,
    sleep = function() end,
  }
  local cfg = { provider = "opencode", base_url = "http://x", model = "m",
    _session_id = "sess-42",
    extra_headers = { ["X-Trace"] = "t1" } }
  local models, err = api.list_models_live(cfg, "key", 3)
  assert_eq(models and models[1] and models[1].id, "m1", "T181 models parsed")
  assert_true(seen_headers ~= nil and seen_headers ~= "", "T181 headers captured")
  -- plain find (true): the needles are literals, no %-escapes needed
  local got_session = seen_headers:find("x-opencode-session: sess-42", 1, true)
  local got_trace = seen_headers:find("X-Trace: t1", 1, true)
  assert_true(got_session ~= nil, "T181 x-opencode-session on models call")
  assert_true(got_trace ~= nil, "T181 extra header on models call")
  _G.api = orig_api_g
  _G.tether = orig_tether
  _G.provider_catalog = nil
  print("T181 models-hctx: OK")
end

-- T182: Cloudflare key resolves from provider_env (stored auth.json env) —
-- partial auth header (Bearer "") must be impossible with ids filled
do
  local cfgm = dofile("src/tether/config_auth.lua")
  local real_getenv = os.getenv
  os.getenv = function(k) return nil end -- bare env: only stored entry can help
  local home = "/tmp/tether_t182_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local auth = assert(loadfile("src/tether/auth.lua"))()
  auth.set(home, "cloudflare-ai-gateway", { kind = "api_key", access_token = "",
    env = { CLOUDFLARE_API_KEY = "cf-secret", CLOUDFLARE_ACCOUNT_ID = "acc",
            CLOUDFLARE_GATEWAY_ID = "gw" } })
  local cfg = cfgm.for_provider({ provider = "cloudflare-ai-gateway",
    _auth_home = home }, "cloudflare-ai-gateway")
  local key, style = cfgm.api_key(cfg)
  assert_eq(key, "cf-secret", "T182 cf key from stored env")
  assert_eq(style, nil, "T182 cf style is header-default")
  os.getenv = real_getenv
  print("T182 cloudflare stored key: OK")
end

-- T183: /model cooldown covers native providers (non-empty static list) —
-- a recent failure must not re-hit the endpoint on every open (audit:
-- cooldown was gated on #display == 0)
do
  local home = "/tmp/tether_t183_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local orig_api_g = _G.api
  local orig_tether = _G.tether
  local orig_catalog = _G.provider_catalog
  local calls = { n = 0 }
  -- dynamic-provider-catalog: seed openai (curated static for cooldown).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  _G.provider_catalog = catfix
  local api = assert(loadfile("src/tether/api.lua"))()
  _G.api = api
  _G.tether = host_mock{
    http_get = function()
      calls.n = calls.n + 1
      return nil, "connection refused"
    end,
    fchmod = function() return true end,
  }
  -- openai has a non-empty static list: display is never empty. The failure
  -- reason is not surfaced on a non-empty display (the palette explains
  -- nothing when the user has a usable list) — only the cooldown matters.
  local cfg = { provider = "openai", base_url = "http://x", model = "m",
    _auth_home = home, api_key_env = "OPENAI_API_KEY" }
  local m1, _, e1 = commands.list_models(cfg, "key")
  assert_true(#m1 > 0, "T183 static served on miss")
  assert_eq(calls.n, 1, "T183 one live attempt")
  -- second open right after failure: cooldown, no new request
  local m2 = commands.list_models(cfg, "key")
  assert_true(#m2 > 0, "T183 static still served")
  assert_eq(calls.n, 1, "T183 dead endpoint not hammered on native")
  _G.api = orig_api_g
  _G.tether = orig_tether
  _G.provider_catalog = orig_catalog
  print("T183 native provider cooldown: OK")
end

-- T184: Bedrock stored-profile choice — AWS_PROFILE from the auth.json env
-- object selects the credentials file (stored profile used to be dead)
do
  local auth = assert(loadfile("src/tether/auth.lua"))()
  local real_getenv = os.getenv
  os.getenv = function(k)
    if k == "HOME" then return "/tmp/tether_t184_home" end
    return nil -- bare process env: only the stored AWS_PROFILE can help
  end
  os.execute("rm -rf /tmp/tether_t184_home && mkdir -p /tmp/tether_t184_home/.aws")
  local wf = io.open("/tmp/tether_t184_home/.aws/credentials", "w")
  wf:write("[stored-proj]\naws_access_key_id = AKID-STORED\n"
    .. "aws_secret_access_key = SECRET-STORED\n")
  wf:close()
  local creds = auth.aws_creds(true, { AWS_PROFILE = "stored-proj" })
  assert_true(creds ~= nil, "T184 stored profile resolves")
  assert_eq(creds.mode, "sigv4", "T184 sigv4 mode")
  assert_eq(creds.key, "AKID-STORED", "T184 key from profile file")
  assert_eq(creds.secret, "SECRET-STORED", "T184 secret from profile file")
  os.getenv = real_getenv
  print("T184 bedrock stored profile: OK")
end

-- T185: caret guard — streaming caret suppressed while palette/confirmation/
-- ask/login-secret own the keyboard (tui spec)
do
  local uimod = dofile("src/tether/ui.lua")
  -- the guard lives in the transcript tail painter; exercise via paint state
  local S_ok = { user_scrolled = false, streaming = true, palette_active = false,
    confirmation = nil, ask = nil, login_secret = nil }
  local S_palette = { user_scrolled = false, streaming = true,
    palette_active = true, confirmation = nil, ask = nil, login_secret = nil }
  local S_secret = { user_scrolled = false, streaming = true,
    palette_active = false, confirmation = nil, ask = nil,
    login_secret = { buf = "x" } }
  -- uimod exposes the painter only through paint(); assert the guard fields
  -- are read (no crash) and the module loads with the guard expression
  assert_true(uimod ~= nil, "T185 ui loads")
  -- Phase A 1.1: the caret guard lives in transcript.render_viewport
  -- (slice in, rows out); the ui facade only forwards S fields.
  local tsrc = io.open("src/tether/transcript.lua", "r"):read("*a")
  io.open("src/tether/transcript.lua", "r"):close()
  local usrc = io.open("src/tether/ui.lua", "r"):read("*a")
  io.open("src/tether/ui.lua", "r"):close()
  assert_true(tsrc:find("not slice.palette_active", 1, true) ~= nil,
    "T185 palette guard present")
  assert_true(tsrc:find("not slice.login_secret", 1, true) ~= nil,
    "T185 login-secret guard present")
  assert_true(tsrc:find("not slice.confirmation", 1, true) ~= nil,
    "T185 confirmation guard present")
  assert_true(tsrc:find("not slice.ask", 1, true) ~= nil, "T185 ask guard present")
  assert_true(usrc:find("palette_active = S.palette_active", 1, true) ~= nil,
    "T185 facade forwards palette guard")
  assert_true(usrc:find("login_secret = S.login_secret", 1, true) ~= nil,
    "T185 facade forwards login-secret guard")
  assert_true(type(S_ok) == "table" and type(S_palette) == "table"
    and type(S_secret) == "table", "T185 guard states constructible")
  print("T185 caret guard: OK")
end

-- T186: footer restyle — ` · ` block separators, no estimate marker before the
-- context cell, provider/model right-aligned cell
do
  local function strip(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  local uimod = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end },
      size = { width = 130, height = 24 } })
  local S = uimod._get_state()
  S.cfg.provider = "deepseek"
  S.model_name = "deepseek-chat"
  S.tokens_in, S.tokens_out = 3000, 1000
  S.tokens_max, S.tokens_used = 32000, 4100
  uimod._paint(true)
  local L = uimod._layout()
  local row = strip(uimod._row(L.footer_row) or "")
  -- provider/model right-aligned
  assert_true(row:find("deepseek/deepseek-chat", 1, true) ~= nil,
    "T186 footer model cell is provider/model: " .. row)
  -- no ≈ (or any estimate marker) before the context cell
  assert_eq(row:find("≈", 1, true), nil, "T186 no estimate marker")
  -- blocks joined by ` · `: path · stats
  assert_true(row:find(" · ", 1, true) ~= nil,
    "T186 footer blocks joined by · separator: " .. row)
  -- context cell intact
  assert_true(row:find("4k/31.2k (13%)", 1, true) ~= nil,
    "T186 context cell rendered: " .. row)
  -- unknown provider falls back to the bare model name
  S.cfg.provider = nil
  uimod._paint(true)
  row = strip(uimod._row(L.footer_row) or "")
  assert_true(row:find("/deepseek-chat", 1, true) == nil,
    "T186 unknown provider keeps bare model name: " .. row)
  print("T186 footer restyle: OK")
end

-- T187: full device flow — device_request shows URL+code, the poll tick
-- exchanges the device code for a token and stores it (spec: Copilot device flow)
do
  local function strip(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  local auth = assert(loadfile("src/tether/auth.lua"))()
  local home = "/tmp/tether_t187_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local orig_auth = _G.auth
  _G.auth = auth
  -- 1. device_request: form POST carries client_id + device grant
  local requests = {}
  local responses = {}
  _G.tether = host_mock{
    http_stream = function(method, url, headers, body)
      requests[#requests + 1] = { url = url, body = body }
      local res = table.remove(responses, 1)
      if res == nil then return false, "no stubbed response" end
      if res == "__LINE__" then return false, "connection reset" end
      return true
    end,
  }
  -- capture the decoded body via a stubbed json line: http_stream delivers
  -- response lines through the callback, but auth._post_json builds them
  -- internally — emulate by making the callback-style stream return the body
  -- in one line. The real _post_json passes an on_line callback; re-check.
  -- Simplest faithful stub: wrap _post_json's transport by re-stubbing after
  -- reading what it sends.
  responses = { '{"device_code":"DC123","user_code":"ABCD-1234",'
    .. '"verification_uri":"https://example.com/activate","interval":5,"expires_in":900}' }
  _G.tether = host_mock{
    http_stream = function(method, url, headers, body, on_line, opts)
      requests[#requests + 1] = { url = url, body = body }
      local res = responses and table.remove(responses, 1)
      if res == nil then return false, "no stubbed response" end
      on_line(res)
      return true
    end,
  }
  local dev, derr = auth.device_request("https://example.com/device", "cid", "repo")
  assert_true(dev ~= nil, "T187 device_request returns the grant: " .. tostring(derr))
  assert_eq(dev.device_code, "DC123", "T187 device_code")
  assert_eq(dev.user_code, "ABCD-1234", "T187 user_code")
  assert_eq(dev.verification_uri, "https://example.com/activate", "T187 verification uri")
  assert_eq(#requests, 1, "T187 one device request")
  assert_true(requests[1].body:find("client_id=cid", 1, true) ~= nil,
    "T187 request carries client_id")
  assert_true(requests[1].body:find("grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant%-type%%3Adevice_code", 1, false) ~= nil,
    "T187 request carries the device grant type")

  -- 2. poll: pending then granted
  responses = {
    '{"error":"authorization_pending"}',
    '{"access_token":"ghu-final","token_type":"bearer","expires_in":1600}',
  }
  local p1 = auth.device_poll("https://example.com/token", "cid", "DC123")
  assert_eq(p1 and p1.error, "authorization_pending", "T187 pending poll")
  local p2 = auth.device_poll("https://example.com/token", "cid", "DC123")
  assert_eq(p2 and p2.access_token, "ghu-final", "T187 granted poll")
  local entry = auth.device_entry(p2, "github-copilot")
  assert_eq(entry and entry.access_token, "ghu-final", "T187 entry built")
  assert_eq(entry and entry.kind, "oauth", "T187 entry kind oauth")
  auth.set(home, "github-copilot", entry)
  local stored = auth.get(home, "github-copilot")
  assert_eq(stored and stored.access_token, "ghu-final", "T187 token stored")

  -- 3. UI: begin_login with a device flow requests the code and polls to grant
  local catalog = dofile("src/tether/providers/catalog.lua")
  _G.provider_catalog = catalog
  -- route the store into the temp home (same seam as T165/T153/T156): the
  -- UI grants call auth.set(nil, ...) which would otherwise write the stubbed
  -- token into the real ~/.tether/auth.json
  local orig_path187 = auth.path
  auth.path = function() return home .. "/.tether/auth.json" end
  responses = {
    '{"device_code":"DC-UI","user_code":"USER-CODE","verification_uri":"https://example.com/activate","interval":0,"expires_in":900}',
    '{"error":"authorization_pending"}',
    '{"error":"authorization_pending"}',
    '{"access_token":"ghu-ui","token_type":"bearer"}',
  }
  -- dynamic-provider-catalog: seed github-copilot (ui snapshots the catalog).
  do
    local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
    catfix.set_overlay({
      ["github-copilot"] = { wire = "openai", base_url = "https://x",
        api_key_env = "COPILOT_GITHUB_TOKEN", model = "x", _source = "test" },
    }, { generated_at = 0 })
    _G.provider_catalog = catfix
  end
  local uimod, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    config = { load = function()
        return { model = "test", workspace = "/tmp", provider = "github-copilot",
          providers = { ["github-copilot"] = {
            oauth_client_id = "cid", oauth_device_url = "https://example.com/device",
            oauth_token_url = "https://example.com/token" } },
          ui = { input_max_lines = 8 } }
      end,
      api_key = function() return "" end },
  })
  -- run_ui_with restored the harness tether; re-stub the transport for the
  -- login flow (begin_login reads _G.auth/_G.tether at call time)
  _G.tether = host_mock{
    http_stream = function(method, url, headers, body, on_line)
      requests[#requests + 1] = { url = url, body = body }
      local res = table.remove(responses, 1)
      if res == nil then return false, "stub exhausted" end
      on_line(res)
      return true
    end,
    exec = function() return true, 0 end,
  }
  uimod._execute_command("login", "github-copilot")
  assert_true(S.login_secret ~= nil, "T187 device login enters secret mode")
  assert_eq(S.login_flow.device_code, "DC-UI", "T187 UI requested the device code")
  assert_eq(S.login_flow.user_code, "USER-CODE", "T187 UI carries the user code")
  -- hint shows the activation URL and user code, no "paste token"
  -- the paint path runs one device poll tick before rendering (interval 0 →
  -- immediate), so the first pending response is consumed here while the
  -- secret mode — and therefore the hint — stays up
  uimod._paint(true)
  local L187 = uimod._layout()
  local hint_row = strip(uimod._row(L187.input_row) or "")
  assert_true(S.login_secret ~= nil, "T187 paint keeps waiting on a pending poll")
  assert_true(hint_row:find("USER%-CODE", 1, false) ~= nil,
    "T187 hint shows the user code: " .. hint_row)
  -- poll tick: first pending, then granted
  assert_eq(uimod._device_poll_tick(), "pending", "T187 first tick pends")
  local tick = uimod._device_poll_tick()
  assert_eq(tick, "granted", "T187 second tick grants")
  local stored2 = auth.get(home, "github-copilot")
  assert_eq(stored2 and stored2.access_token, "ghu-ui", "T187 UI stored the granted token")
  assert_true(S.login_secret == nil, "T187 secret mode exits on grant")
  auth.path = orig_path187
  _G.auth = orig_auth
  _G.provider_catalog = nil
  print("T187 device flow: OK")
end

-- T-reactor: the event loop dispatches input > transport > timers in order,
-- timers fire past their deadline, cancel drops them, EOF disarms stdin, and
-- a scripted run is repeatable with no wall-clock involved.
do
  local reactor = assert(loadfile("src/tether/reactor.lua"))()
  local function scripted_run()
    local now = 0
    local script = {
      { read = { 0 }, write = {} }, -- tick 1: stdin ready
      { read = { 7 }, write = {} }, -- tick 2: transport fd ready
      { read = {}, write = {} },    -- tick 3: pure timeout, timer due
    }
    local si = 0
    local order = {}
    local r = reactor.new({
      poll = function()
        si = si + 1
        return script[si] or { read = {}, write = {} }
      end,
      clock = function() return now end,
      stdin_fd = 0,
      quantum_ms = 80,
    })
    r:on_stdin(function()
      order[#order + 1] = "stdin"
      return 1
    end)
    local src = r:add_source({
      fds = function() return { read = { 7 }, write = {} } end,
      ready = function(kinds)
        order[#order + 1] = "transport"
        assert_eq(kinds.read, true, "T-reactor transport kind is read")
      end,
    })
    r:after(160, function() order[#order + 1] = "timer" end)
    local cancelled = r:after(1000, function() order[#order + 1] = "late" end)
    assert_true(r:cancel(cancelled), "T-reactor cancel drops the timer")
    r:tick()
    r:tick()
    assert_true(r:remove_source(src), "T-reactor remove_source drops the fd")
    now = 200
    r:tick()
    r:tick() -- drained script: nothing ready, nothing due
    return table.concat(order, ",")
  end
  assert_eq(scripted_run(), "stdin,transport,timer",
    "T-reactor dispatch order is input, transport, timers")
  assert_eq(scripted_run(), "stdin,transport,timer",
    "T-reactor scripted run is repeatable")

  -- EOF: readable stdin with zero bytes drained disarms stdin and fires on_eof
  do
    local now = 0
    local calls, eofs = 0, 0
    local r = reactor.new({
      poll = function() return { read = { 0 }, write = {} } end,
      clock = function() return now end,
    })
    r:on_stdin(function() calls = calls + 1; return 0 end)
    r:on_eof(function() eofs = eofs + 1 end)
    r:tick()
    r:tick()
    assert_eq(calls, 1, "T-reactor stdin disarmed after EOF")
    assert_eq(eofs, 1, "T-reactor on_eof fires once")
  end

  -- run() returns when a timer stops the loop (no infinite spin)
  do
    local now = 0
    local r = reactor.new({
      poll = function() now = now + 80; return { read = {}, write = {} } end,
      clock = function() return now end,
    })
    r:after(0, function() r:stop() end)
    r:run()
    assert_true(r:stopped(), "T-reactor run returns after stop")
  end

  -- T204: the poll timeout is always integral. The host clock is fractional
  -- (tether.monotonic_ms carries sub-ms precision) and the C poll() takes an
  -- integer ms, so a leftover fraction made luaL_optinteger throw and killed
  -- the whole loop ("number has no integer representation").
  do
    local now = 1000.456789
    local seen
    local r = reactor.new({
      poll = function(_, _, timeout) seen = timeout end,
      clock = function() return now end,
    })
    r:after(50, function() end)
    now = 1000.457001 -- under 1 ms elapsed: the wait is fractional
    r:tick()
    assert_true(seen ~= nil, "T204 poll received a timeout")
    assert_eq(seen, math.floor(seen), "T204 clock-fraction poll timeout integral")
  end
  do
    -- the other fraction source: a fractional timer delay (agent backoff:
    -- loop:after(total * 1000) with sub-ms seconds)
    local seen
    local r = reactor.new({
      poll = function(_, _, timeout) seen = timeout end,
      clock = function() return 100 end,
    })
    r:after(33.5, function() end)
    r:tick()
    assert_eq(seen, math.floor(seen), "T204 delay-fraction poll timeout integral")
  end
  print("T-reactor determinism: OK")
end

-- T3.1: api.stream is incremental behind its signature. The same recorded
-- SSE body through the blocking http_stream and through the step API
-- (http_start/http_step/http_lines, pumped by the reactor loop) yields the
-- identical event sequence; the stepped attempt never touches the blocking
-- transport, keeps timers ticking while it runs, and maps a mid-stream abort
-- to a non-retryable interrupted failure instead of a retry.
do
  local api_mod = assert(loadfile("src/tether/api.lua"))()
  local reactor = assert(loadfile("src/tether/reactor.lua"))()
  local cfg = { base_url = "http://x", model = "m" }
  local msgs = { { role = "user", content = "hi" } }
  local recorded = {
    'data: {"choices":[{"delta":{"content":"Hel"}}]}',
    "",
    'data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}',
  }
  local function dump(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return tostring(v) end
    if depth > 4 then return "..." end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local function collect(stream)
    local events = {}
    local ok, failure = api_mod.stream(cfg, "key", msgs,
      function(ev) events[#events + 1] = ev end)
    return ok, failure, events, stream
  end

  local orig = { tether = _G.tether, reactor = _G.reactor,
                 agent = _G.agent, turn = _G.turn }

  -- (a) blocking transport: the contract print mode and tests without a
  -- loop keep using. No loop is bound (app print mode never runs one), so
  -- the transfer and the models GET must stay on the blocking primitives.
  _G.reactor, _G.agent, _G.turn = reactor, nil, nil
  reactor.set_active(nil)
  local stream_a, starts_a, steps_a, gets_a = 0, 0, 0, 0
  _G.tether = host_mock{
    http_stream = function(_, _, _, _, on_line)
      stream_a = stream_a + 1
      for _, line in ipairs(recorded) do on_line(line) end
      return true
    end,
    http_start = function() starts_a = starts_a + 1; return {} end,
    http_step = function() steps_a = steps_a + 1; return "done" end,
    http_get = function()
      gets_a = gets_a + 1
      return '{"data":[{"id":"m"}]}'
    end,
    sleep = function() end,
  }
  local ok_b, fail_b, ev_b = collect()
  assert_eq(stream_a, 1, "T3.1 no loop: the stream blocks in http_stream")
  assert_eq(starts_a, 0, "T3.1 no loop: no stepped transfer is started")
  assert_eq(steps_a, 0, "T3.1 no loop: no step ever runs")
  local models_b = api_mod.list_models_live(cfg, "key")
  assert_eq(gets_a, 1, "T3.1 no loop: models live uses one blocking http_get")
  assert_eq(starts_a, 0, "T3.1 no loop: models live never starts a transfer")
  assert_true(models_b ~= nil and models_b[1] and models_b[1].id == "m",
    "T3.1 no loop: the blocking GET result parses")

  -- (b) stepped transport under an active reactor loop
  local function run_stepped(on_step)
    local now, polls, starts, steps, frees, aborts, stream_calls = 0, 0, 0, 0, 0, 0, 0
    local step_i, aborted, timer_fired = 0, false, false
    local pending = {}
    local chunks = { { recorded[1], recorded[2] }, { recorded[3] } }
    local r = reactor.new{
      poll = function(_, _, timeout)
        polls = polls + 1
        now = now + math.max(timeout or 0, 1)
        return { read = {}, write = {} }
      end,
      clock = function() return now end,
    }
    reactor.set_active(r)
    r:after(1, function() timer_fired = true end)
    _G.tether = host_mock{
      http_stream = function() stream_calls = stream_calls + 1; return true end,
      http_start = function() starts = starts + 1; return {} end,
      http_step = function()
        steps = steps + 1
        if on_step then on_step(steps) end
        if aborted then pending = {}; return "failed", "aborted" end
        if step_i < #chunks then
          step_i = step_i + 1
          pending = chunks[step_i]
          return "running"
        end
        pending = {}
        return "done"
      end,
      -- a step queues lines; draining hands them over exactly once, the way
      -- http_lines empties the transfer's queue
      http_lines = function()
        local lines = pending
        pending = {}
        return lines
      end,
      http_fds = function() return { read = {}, write = {}, timeout = -1 } end,
      http_abort = function() aborted = true; aborts = aborts + 1; return true end,
      http_free = function() frees = frees + 1; return true end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    local ok, failure, events = collect()
    reactor.set_active(nil)
    return ok, failure, events, {
      polls = polls, starts = starts, steps = steps, frees = frees,
      aborts = aborts, stream_calls = stream_calls, timer_fired = timer_fired,
    }
  end

  _G.reactor = reactor
  _G.agent, _G.turn = nil, nil
  local ok_s, fail_s, ev_s, n = run_stepped()

  assert_true(ok_b, "T3.1 blocking transport succeeds on the recorded body")
  assert_true(ok_s, "T3.1 stepped transport succeeds on the recorded body")
  assert_eq(dump(ev_s), dump(ev_b),
    "T3.1 stepped events are identical to the blocking sequence")
  assert_eq(n.stream_calls, 0, "T3.1 the blocking transport is never called")
  assert_eq(n.starts, 1, "T3.1 one http_start per attempt")
  assert_eq(n.frees, 1, "T3.1 the transfer is freed after the attempt")
  assert_eq(n.aborts, 0, "T3.1 no abort on a clean stream")
  assert_true(n.timer_fired, "T3.1 timers dispatch while the stream runs")
  assert_true(n.polls > 0 and n.steps > 0, "T3.1 the loop pumped the transfer")

  -- (c) abort mid-stream: `aborted` from http_abort is never retryable
  local ok_a, fail_a, _, na = run_stepped(function(n2)
    if n2 == 1 then _G.agent = { abort_requested = true } end
  end)
  assert_false(ok_a, "T3.1 an aborted stream fails the attempt")
  assert_true(fail_a ~= nil, "T3.1 the abort reports a failure")
  assert_eq(fail_a and fail_a.kind, "interrupted", "T3.1 abort classifies interrupted")
  assert_false(fail_a and fail_a.retryable, "T3.1 interrupted is not retryable")
  assert_eq(na.aborts, 1, "T3.1 the transfer is aborted through http_abort")

  _G.tether, _G.reactor = orig.tether, orig.reactor
  _G.agent, _G.turn = orig.agent, orig.turn
  print("T3.1 incremental stream: OK")
end

-- T316/T317 (audit H1): what makes a body a stream is what the adapter
-- produced, not the first five bytes of the accumulated body. Anthropic frames
-- every payload with an `event:` line, so the `data:` sniff judged a fully
-- delivered answer as a retryable failure (`handle_non_sse` → false) right after
-- the text had reached the UI. A framed stream that produced no event at all
-- stays a success — an empty answer is the agent's case, not a transport error.
do
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    anthropic = { wire = "anthropic", base_url = "http://x",
      api_key_env = "ANTHROPIC_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  _G.provider_catalog = catfix
  local api_mod = assert(loadfile("src/tether/api.lua"))()
  local reactor = assert(loadfile("src/tether/reactor.lua"))()
  local orig = { tether = _G.tether, reactor = _G.reactor,
                 agent = _G.agent, turn = _G.turn, catalog = _G.provider_catalog }
  _G.reactor, _G.agent, _G.turn = reactor, nil, nil
  reactor.set_active(nil)

  local function play(lines, provider)
    local events = {}
    _G.tether = host_mock{
      http_stream = function(_, _, _, _, on_line)
        for _, line in ipairs(lines) do on_line(line) end
        return true
      end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    local ok, failure = api_mod.stream(
      { provider = provider, base_url = "http://x", model = "m" }, "key",
      { { role = "user", content = "hi" } },
      function(ev) events[#events + 1] = ev end)
    return ok, failure, events
  end

  -- (a) Anthropic wire: an `event:` line above every `data:` payload
  local ok, failure, evs = play({
    "event: message_start",
    'data: {"type":"message_start","message":{"id":"1","role":"assistant","content":[]}}',
    "",
    "event: content_block_start",
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    "",
    "event: content_block_delta",
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
    "",
    "event: message_stop",
    'data: {"type":"message_stop"}',
    "",
  }, "anthropic")
  local text = ""
  for _, ev in ipairs(evs) do
    if ev.type == "text_delta" then text = text .. (ev.text or "") end
  end
  assert_true(ok, "T316 an event-framed stream succeeds")
  assert_eq(failure, nil, "T316 a delivered answer reports no failure")
  assert_eq(text, "Hello", "T316 the deltas reached the caller")

  -- (b) framed with nothing parseable in it: still a stream, not a failure
  local ok2, failure2, evs2 = play({ ": keep-alive", "" }, "openai")
  assert_true(ok2, "T317 a framed stream with no event succeeds")
  assert_eq(#evs2, 0, "T317 no events were produced")
  assert_eq(failure2, nil, "T317 no failure record for it")
  local ok2b, failure2b, evs2b = play({ "data: [DONE]", "" }, "openai")
  assert_true(ok2b, "T317 a lone completion marker succeeds")
  assert_eq(failure2b, nil, "T317 no failure record for it")
  local saw_text = false
  for _, ev in ipairs(evs2b) do
    if ev.type == "text_delta" then saw_text = true end
  end
  assert_false(saw_text, "T317 no text arrived, so the empty answer stays the agent's case")

  -- (c) a JSON error body (no framing, no events) still fails the attempt
  local ok3, failure3 = play({ '{"error":{"message":"nope","status":401}}' }, "anthropic")
  assert_false(ok3, "T316 a JSON error body still fails")
  assert_true(failure3 ~= nil
    and tostring(failure3.message):find("^http 401:") ~= nil,
    "T316 the failure names http 401")

  _G.tether, _G.reactor = orig.tether, orig.reactor
  _G.agent, _G.turn, _G.provider_catalog = orig.agent, orig.turn, orig.catalog
  print("T316-T317 stream or error body: OK")
end

-- T188: an assistant entry with no visible content — a whitespace-only
-- text_delta (a lone newline/space is common right before a tool call) —
-- renders no row at all: no lone `•` marker line and no block-gap blank
-- in front of it. Thinking keeps its own header row and never degrades
-- into a bare bullet.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function rows_for(txt)
    local uimod = run_ui_with({}, { agent = agent_stub })
    local T = uimod._transcript
    T.reset({})
    T.append({ role = "tool", id = "t1", name = "list", status = "ok", summary = "17 записей" })
    T.handle({ type = "text_delta", text = txt, attempt = 1 })
    T.append({ role = "tool", id = "t2", name = "read", status = "ok", summary = "449 стр." })
    local rows = {}
    for _, r in ipairs(uimod._render_all(80)) do
      rows[#rows + 1] = r:gsub("\27%[[0-9;]*m", "")
    end
    return rows
  end
  local function has_bullet(rows)
    for _, r in ipairs(rows) do
      local bare = r:match("^%s*[•-]%s*$")
      if bare then return true end
    end
    return false
  end
  for _, txt in ipairs({ "\n", " ", "\t", " \n", "\n\n", "\13", "\27[31m" }) do
    local q = string.format("%q", txt)
    local rows = rows_for(txt)
    assert_eq(#rows, 2, "T188 whitespace-only delta adds no row (" .. q .. ")")
    assert_false(has_bullet(rows), "T188 no lone bullet row (" .. q .. ")")
  end
  -- visible text still renders with the assistant marker
  local ok = rows_for("hello")
  local bullet_row
  for _, r in ipairs(ok) do if r:find("• hello", 1, true) then bullet_row = r end end
  assert_notnil(bullet_row, "T188 visible text keeps its bullet row")

  -- thinking never degrades into a bare bullet: it carries its own header
  local uimod = run_ui_with({}, { agent = agent_stub })
  uimod._transcript.reset({})
  uimod._transcript.append({ role = "thinking", text = "", started_at = os.time() })
  local th = {}
  for _, r in ipairs(uimod._render_all(80)) do th[#th + 1] = r:gsub("\27%[[0-9;]*m", "") end
  assert_eq(#th, 1, "T188 empty thinking renders its header")
  assert_true(th[1]:find("think ·", 1, true) ~= nil,
    "T188 thinking row starts with its header: " .. tostring(th[1]))
  print("T188 blank assistant row suppressed: OK")
end

-- T188b: the incremental height index must resume from the row AFTER the last
-- clean entry, not from that entry's START row. Regression for the floating
-- "user row vanishes when think ends" bug: tool_call_start's bump() raised
-- index_dirty_from while the index was already clean (the think block had been
-- frozen by the preceding text_delta, so no touch pulled dirty_from back to
-- 1). The rebuild then re-anchored every following entry index_h[from-1]-1
-- rows too high: the think block's leading gap swallowed the user row (it
-- vanished from the chat) and later rows overlapped. The next full rebuild
-- repaired it, which is why the row "came back" on the following tool call.
do
  local function str_bytes(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local function merge(a, b) for _, x in ipairs(b) do a[#a + 1] = x end return a end
  -- viewport path (row_text, height-indexed) must equal the full render, row
  -- for row — that parity is what keeps the painted screen on the truth
  local function parity(uimod, width)
    local tr = uimod._transcript
    local total = tr.height(width)
    local full = tr.render_all(width)
    if total ~= #full then
      return false, string.format("height %d vs render_all %d", total, #full)
    end
    for k = 1, #full do
      local got = tr.row_text(k, width)
      if got ~= full[k] then
        return false, string.format("row %d: viewport %q vs render %q", k, got, full[k])
      end
    end
    return true
  end

  local bytes = merge(merge(str_bytes("hello there"), { 13 }), { 17 })
  local uimod, S = run_ui_with(bytes,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  -- the transcript holds the startup splash + this turn's separator + user row
  assert_eq(#tentries(uimod), 3, "T188b submit leaves splash + separator + user")

  -- think streams, then ends on an assistant text delta (freezes the think
  -- block, appends an assistant row), then the tool call bumps the index
  uimod._handle_agent_event({ type = "reasoning_delta", text = "planning the work" })
  uimod._paint(true)
  local ok, why = parity(uimod, 80)
  assert_true(ok, "T188b parity while think streams: " .. tostring(why))

  uimod._handle_agent_event({ type = "text_delta", text = "let me read the file" })
  uimod._paint(true)
  ok, why = parity(uimod, 80)
  assert_true(ok, "T188b parity after think freezes: " .. tostring(why))

  uimod._handle_agent_event({ type = "tool_call_start", id = "t1", name = "read",
    args = { path = "/tmp/foo.txt" } })
  uimod._paint(true)
  ok, why = parity(uimod, 80)
  assert_true(ok, "T188b parity after the tool call: " .. tostring(why))

  -- the user row specifically must still map to its own content
  local full = uimod._render_all(80)
  local user_row
  for k, r in ipairs(full) do
    if (r:gsub("\27%[[%d;]*m", "")):find("› hello there", 1, true) then user_row = k end
  end
  assert_notnil(user_row, "T188b the user row is rendered")
  local mapped = user_row and uimod._transcript.row_text(user_row, 80) or ""
  assert_true((mapped:gsub("\27%[[%d;]*m", "")):find("hello there", 1, true) ~= nil,
    "T188b the user row maps to itself under the height index")
  print("T188b incremental index resumes after the last clean entry: OK")
end

-- T189: add-reasoning-level — the config key defaults to `off`, normalizes
-- at load (unknown/missing/non-string never fails the session), and the
-- bootstrap file carries it.
do
  local cfgmod = assert(loadfile("src/tether/config.lua"))()
  local home = "/tmp/tether_t189_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local cfgpath = home .. "/.tether/config.lua"
  local c0 = cfgmod.load(cfgpath, home)
  assert_eq(c0.reasoning, "off", "T189 fresh config defaults to off")
  local f0 = assert(io.open(cfgpath, "r"))
  local disk0 = f0:read("*a")
  f0:close()
  assert_true(disk0:find("reasoning", 1, true) ~= nil,
    "T189 bootstrap carries the reasoning key")
  local function write(s)
    local f = assert(io.open(cfgpath, "w"))
    f:write(s)
    f:close()
  end
  write('return { reasoning = "medium" }\n')
  assert_eq(cfgmod.load(cfgpath, home).reasoning, "medium", "T189 valid level loads")
  write('return { reasoning = "turbo" }\n')
  assert_eq(cfgmod.load(cfgpath, home).reasoning, "off",
    "T189 unknown level falls back to off")
  write('return { reasoning = 42 }\n')
  assert_eq(cfgmod.load(cfgpath, home).reasoning, "off",
    "T189 non-string level falls back to off")
  write('return { }\n')
  assert_eq(cfgmod.load(cfgpath, home).reasoning, "off",
    "T189 missing level defaults to off")
  print("T189 config reasoning default and normalization: OK")
end

-- T190: persist_keys writes the reasoning level through the same
-- byte-preserving rewriter: only that line changes, comments/unknown keys
-- survive, and a config without the key gets it appended before the close.
do
  local cfgmod = assert(loadfile("src/tether/config.lua"))()
  local cfgsch = assert(loadfile("src/tether/config_schema.lua"))()
  local home = "/tmp/tether_t190_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local cfgpath = home .. "/.tether/config.lua"
  local function write(s)
    local f = assert(io.open(cfgpath, "w"))
    f:write(s)
    f:close()
  end
  local function read()
    local f = assert(io.open(cfgpath, "r"))
    local d = f:read("*a")
    f:close()
    return d
  end
  write('-- keep me\nreturn {\n  provider = "openai",\n  model = "gpt-4o", -- pinned\n'
    .. '  reasoning = "off",\n  providers = {\n    anthropic = { model = "custom-claude" },\n  },\n}\n')
  assert_true(cfgsch.persist_keys(home, { reasoning = "medium" }),
    "T190 persist_keys writes reasoning")
  local d1 = read()
  assert_true(d1:find('reasoning = "medium"', 1, true) ~= nil, "T190 reasoning line patched")
  assert_true(d1:find("-- keep me", 1, true) ~= nil, "T190 comment survives")
  assert_true(d1:find('model = "gpt-4o"', 1, true) ~= nil, "T190 model untouched")
  assert_true(d1:find("pinned", 1, true) ~= nil, "T190 trailing comment kept")
  assert_true(d1:find("custom-claude", 1, true) ~= nil, "T190 nested table untouched")
  -- config without the key: appended before the top-table close
  write('-- only model\nreturn {\n  model = "gpt-4o",\n}\n')
  assert_true(cfgmod.persist_keys(home, { reasoning = "high" }),
    "T190 persist_keys appends the missing key")
  local d2 = read()
  assert_true(d2:find('reasoning = "high"', 1, true) ~= nil, "T190 key appended")
  assert_true(d2:find("-- only model", 1, true) ~= nil, "T190 comment survives the append")
  assert_true(d2:find('model = "gpt-4o"', 1, true) ~= nil, "T190 existing keys survive the append")
  print("T190 persist reasoning: OK")
end

-- T191: the level reaches the request body of the wires that support it and
-- touches nothing else (checked through the real api.stream transport seam).
do
  -- dynamic-provider-catalog: seed the wires under test.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    agnes = { wire = "openai", base_url = "http://x",
      api_key_env = "AGNES_API_KEY", model = "x", _source = "test" },
    gemini = { wire = "gemini", base_url = "http://x",
      api_key_env = "GEMINI_API_KEY", model = "x", _source = "test" },
    anthropic = { wire = "anthropic", base_url = "http://x",
      api_key_env = "ANTHROPIC_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local api = assert(loadfile("src/tether/api.lua"))()
  local orig_tether, orig_reactor = _G.tether, _G.reactor
  local function body_of(cfg)
    local captured
    _G.reactor = nil
    _G.tether = host_mock{
      http_stream = function(_, _, _, body, on_line)
        local path = tostring(body):match("^@(.+)$")
        if path then
          local f = io.open(path, "r")
          if f then captured = f:read("*a"); f:close() end
        end
        on_line('data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}')
        return true
      end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    local ok = api.stream(cfg, "key", { { role = "user", content = "hi" } },
      function() end)
    _G.tether, _G.reactor = orig_tether, orig_reactor
    assert_true(ok, "T191 stream succeeds for " .. tostring(cfg.provider))
    return captured or ""
  end
  local base = { base_url = "http://x", model = "m" }
  local function with(t)
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    for k, v in pairs(t) do c[k] = v end
    return c
  end
  -- openai wire: reasoning_effort, absent for off/unknown
  local hi = body_of(with{ provider = "agnes", reasoning = "high" })
  assert_true(hi:find('"reasoning_effort":"high"', 1, true) ~= nil,
    "T191 openai body carries reasoning_effort")
  assert_true(hi:find('"model":"m"', 1, true) ~= nil, "T191 request still carries the model")
  local lo = body_of(with{ provider = "agnes", reasoning = "low" })
  assert_true(lo:find('"reasoning_effort":"low"', 1, true) ~= nil, "T191 effort low")
  local md = body_of(with{ provider = "agnes", reasoning = "medium" })
  assert_true(md:find('"reasoning_effort":"medium"', 1, true) ~= nil, "T191 effort medium")
  local off = body_of(with{ provider = "agnes", reasoning = "off" })
  assert_eq(off:find("reasoning_effort", 1, true), nil, "T191 off omits the parameter")
  local unk = body_of(with{ provider = "agnes", reasoning = "turbo" })
  assert_eq(unk:find("reasoning_effort", 1, true), nil, "T191 unknown level omits it")
  local nilv = body_of(with{ provider = "agnes" })
  assert_eq(nilv:find("reasoning_effort", 1, true), nil, "T191 unset level omits it")
  -- unsupported wire keeps the request it sends today
  local gem = body_of(with{ provider = "gemini", reasoning = "high" })
  assert_eq(gem:find("reasoning_effort", 1, true), nil, "T191 gemini sends no effort")
  assert_eq(gem:find('"thinking"', 1, true), nil, "T191 gemini sends no thinking")
  -- anthropic wire: thinking budget + max_tokens at least budget+4096
  local aoff = body_of(with{ provider = "anthropic", reasoning = "off" })
  assert_eq(aoff:find('"thinking"', 1, true), nil, "T191 anthropic off omits thinking")
  assert_true(aoff:find('"max_tokens":4096', 1, true) ~= nil,
    "T191 anthropic default max_tokens unchanged")
  local expect = { low = { 4096, 8192 }, medium = { 16384, 20480 },
                   high = { 65536, 69632 } }
  for _, level in ipairs({ "low", "medium", "high" }) do
    local b = body_of(with{ provider = "anthropic", reasoning = level })
    local budget, mt = expect[level][1], expect[level][2]
    assert_true(b:find('{"type":"enabled","budget_tokens":' .. budget .. "}", 1, true)
      ~= nil, "T191 anthropic budget for " .. level)
    assert_true(tonumber(b:match('"max_tokens"[%s]*:%s*(%d+)')) == mt,
      "T191 anthropic max_tokens >= budget+4096 for " .. level)
  end
  _G.provider_catalog = orig_catalog
  print("T191 reasoning reaches the request body: OK")
end

-- T192: reasoning chunks become reasoning_delta, never text_delta, and a
-- signature chunk emits nothing.
do
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local function collect(mod, lines)
    mod.reset_stream()
    local evs = {}
    for _, l in ipairs(lines) do
      mod.parse_sse_line(l, function(ev) evs[#evs + 1] = ev end)
    end
    return evs
  end
  local evs = collect(openai, {
    'data: {"choices":[{"delta":{"reasoning_content":"let us plan"}}]}',
    'data: {"choices":[{"delta":{"reasoning":"second step"}}]}',
    'data: {"choices":[{"delta":{"content":"Hello"}}]}',
  })
  local rtext, ttext, nr, nt = {}, {}, 0, 0
  for _, ev in ipairs(evs) do
    if ev.type == "reasoning_delta" then nr = nr + 1; rtext[#rtext + 1] = ev.text end
    if ev.type == "text_delta" then nt = nt + 1; ttext[#ttext + 1] = ev.text end
  end
  assert_eq(nr, 2, "T192 openai emits two reasoning_delta")
  assert_eq(nt, 1, "T192 openai text stays text_delta")
  assert_eq(table.concat(rtext, "|"), "let us plan|second step",
    "T192 reasoning text is unescaped exactly once")
  assert_eq(table.concat(ttext), "Hello", "T192 answer text carries no reasoning")

  local aevs = collect(anthropic, {
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
  })
  local seen, texts = {}, {}
  for _, ev in ipairs(aevs) do
    seen[ev.type] = (seen[ev.type] or 0) + 1
    texts[#texts + 1] = ev.type .. ":" .. tostring(ev.text or "")
  end
  assert_eq(seen.reasoning_delta, 1, "T192 thinking_delta -> one reasoning_delta")
  assert_eq(seen.text_delta, 1, "T192 text_delta unaffected")
  assert_eq(table.concat(texts, "|"), "reasoning_delta:hmm|text_delta:Hello",
    "T192 signature_delta emits nothing: " .. table.concat(texts, "|"))
  print("T192 reasoning stream mapping: OK")
end

-- T193: /think — direct apply, unknown level, the picker, and the footer
-- right cell carrying `provider/model · <level>` always.
do
  local persisted = {}
  local cfg_stub = {
    load = function()
      return { model = "test", workspace = "/tmp", provider = "openai",
        ui = { input_max_lines = 8 }, _auth_home = "/tmp/tether_t193_home" }
    end,
    api_key = function() return "" end,
    persist_keys = function(home, keys)
      persisted[#persisted + 1] = { home = home, keys = keys }
      return true
    end,
  }
  local uimod, S = run_ui_with({ 17 }, {
    config = cfg_stub,
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  -- run_ui_with restores _G.config after ui.run returns, while pick.think
  -- resolves the module through the global at call time — stub it here too.
  local orig_config = _G.config
  _G.config = cfg_stub
  local listed = false
  for _, c in ipairs(uimod.SLASH_COMMANDS) do
    if c.cmd == "think" and c.label == "/think" then listed = true end
  end
  assert_true(listed, "T193 /think is a listed built-in")

  uimod._execute_command("think", "high")
  assert_eq(S.cfg.reasoning, "high", "T193 /think high applies")
  assert_eq(#persisted, 1, "T193 the level is persisted")
  assert_eq(persisted[1] and persisted[1].keys.reasoning, "high",
    "T193 persist_keys carries reasoning")
  local ents = uimod._transcript.entries()
  assert_true((ents[#ents].text or ""):find("→ thinking: high", 1, true) ~= nil,
    "T193 system row echoes the level")

  uimod._execute_command("think", "turbo")
  assert_eq(S.cfg.reasoning, "high", "T193 unknown level changes nothing")
  assert_notnil(S.error_banner, "T193 unknown level raises a banner")
  assert_true((S.error_banner or ""):find("turbo", 1, true) ~= nil,
    "T193 banner names the bad level")
  assert_eq(#persisted, 1, "T193 unknown level persists nothing")

  S.error_banner = nil
  uimod._execute_command("think")
  assert_true(S.palette_active, "T193 bare /think opens the picker")
  assert_eq(S.palette_mode, "think", "T193 palette mode is think")
  local labels = {}
  for _, it in ipairs(S.palette_items or {}) do labels[#labels + 1] = it.label end
  assert_eq(table.concat(labels, ","), "off,low,medium,high",
    "T193 the four levels are listed in order")
  local marked = false
  for _, it in ipairs(S.palette_items) do
    if it.label == "high" and (it.desc or ""):find("current", 1, true) then
      marked = true
    end
  end
  assert_true(marked, "T193 the current level is marked in its description")

  uimod._handle_key({ kind = "special", name = "down" })
  uimod._handle_key({ kind = "special", name = "down" })
  assert_eq(S.palette_sel, 3, "T193 selection moves to medium")
  uimod._handle_key({ kind = "enter" })
  assert_false(S.palette_active, "T193 Enter closes the picker")
  assert_eq(S.cfg.reasoning, "medium", "T193 the pick applies")
  ents = uimod._transcript.entries()
  assert_true((ents[#ents].text or ""):find("→ thinking: medium", 1, true) ~= nil,
    "T193 the pick appends its row")

  uimod._execute_command("think")
  uimod._handle_key({ kind = "esc" })
  assert_false(S.palette_active, "T193 Esc closes the picker")
  assert_eq(S.cfg.reasoning, "medium", "T193 Esc changes nothing")

  -- footer: provider/model · <level>, always, whole cell ends the row
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local function footer()
    uimod._paint(true)
    return strip(uimod._row(uimod._layout().footer_row))
  end
  S.cfg.reasoning = "medium"
  local f1 = footer()
  assert_true(f1:find("openai/test · medium", 1, true) ~= nil,
    "T193 footer carries provider/model · level: " .. f1)
  assert_eq(f1:sub(-#"· medium"), "· medium", "T193 level ends the footer row")
  S.cfg.reasoning = "off"
  local f2 = footer()
  assert_eq(f2:sub(-#"· off"), "· off", "T193 level shown even when off: " .. f2)
  S.cfg.reasoning = nil
  local f3 = footer()
  assert_eq(f3:sub(-#"· off"), "· off", "T193 unset level renders off: " .. f3)
  _G.config = orig_config
  print("T193 /think command, picker and footer: OK")
end

-- T194: reasoning_delta events build one thinking entry, the assistant row
-- carries the answer only, and ui.thinking governs the body visibility.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "step one " })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "step two" })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "!" })
  uimod._handle_agent_event({ type = "text_delta", text = "the answer" })
  local th, th_n, asst = "", 0, nil
  for _, e in ipairs(uimod._transcript.entries()) do
    if e.role == "thinking" then th_n = th_n + 1; th = e.text end
    if e.role == "assistant" then asst = e.text end
  end
  assert_eq(th_n, 1, "T194 reasoning accumulates into one thinking entry")
  assert_eq(th, "step one step two!", "T194 the joined reasoning body")
  assert_eq(asst, "the answer", "T194 the assistant row excludes the reasoning")
  local function rows()
    local out = {}
    for _, r in ipairs(uimod._render_all(80)) do
      out[#out + 1] = r:gsub("\27%[[0-9;]*m", "")
    end
    return out
  end
  local joined = table.concat(rows(), "\n")
  assert_true(joined:find("think · ", 1, true) ~= nil, "T194 thinking header painted")
  assert_true(joined:find("step one step two!", 1, true) ~= nil, "T194 reasoning body painted")
  assert_true(joined:find("• the answer", 1, true) ~= nil, "T194 assistant row painted")

  S.thinking_visible = false
  uimod._invalidate_all()
  local collapsed = table.concat(rows(), "\n")
  assert_true(collapsed:find("think · %d+%.%ds · %(ctrl%+t%) ▸") ~= nil,
    "T194 collapsed shows the timed placeholder")
  assert_eq(collapsed:find("Ctrl+T", 1, true), nil,
    "T194 collapsed hint is lowercase")
  assert_eq(collapsed:find("step one step two!", 1, true), nil,
    "T194 collapsed hides the reasoning body")
  uimod._handle_key({ kind = "ctrl", code = 20 })
  assert_true(S.thinking_visible, "T194 Ctrl+T expands the thinking")
  local expanded = table.concat(rows(), "\n")
  assert_true(expanded:find("step one step two!", 1, true) ~= nil,
    "T194 expanded shows the reasoning body again")
  print("T194 reasoning reaches the transcript: OK")
end

-- T195: providers file verify + merge priority + env list resolution
do
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  local body = '{"schema":1,"generated_at":123,"providers":'
    .. '{"a":{"wire":"openai","base_url":"https://x","api_key_env":["X"],'
    .. '"model":"m","models":[{"id":"m","context":100}]}}}'
  local tbl, err = catalog.parse_file(body)
  assert_true(tbl ~= nil, "T195 valid file parses")
  assert_eq(tbl.providers.a.wire, "openai", "T195 wire kept")
  assert_eq(tbl.providers.a.models[1].context, 100, "T195 context kept")
  local t2, e2 = catalog.parse_file('{"schema":2,"providers":{}}')
  assert_true(t2 == nil and e2:find("unsupported", 1, true) ~= nil,
    "T195 schema major rejected")
  local t3 = catalog.parse_file("FETCH_FAILED timeout\n")
  assert_true(t3 == nil, "T195 fetch marker rejected")
  assert_true(catalog.parse_file("") == nil, "T195 empty rejected")
  assert_true(catalog.parse_file("not json{{") == nil, "T195 garbage rejected")

  local boot = { a = { wire = "openai", model = "b" } }
  local cache = { a = { wire = "openai", model = "c" }, b = { wire = "openai" } }
  local over = { b = { wire = "openai", model = "o" } }
  local merged, meta = catalog.merge(boot, cache, over, 123)
  assert_eq(merged.a.model, "c", "T195 cache wins over bootstrap")
  assert_eq(merged.a._source, "cache", "T195 source stamped")
  assert_eq(merged.b.model, "o", "T195 models.lua wins over cache")
  assert_eq(merged.b._source, "models.lua", "T195 overlay source stamped")
  assert_eq(boot.a.model, "b", "T195 inputs unmutated")
  assert_eq(meta.generated_at, 123, "T195 meta carries generated_at")

  assert_eq(catalog.env_name("PLAIN"), "PLAIN", "T195 string passthrough")
  assert_eq(catalog.env_name({ "TETHER_DEF_UNSET_1", "HOME" }), "HOME",
    "T195 first set wins")
  assert_eq(catalog.env_name({ "TETHER_DEF_UNSET_1", "TETHER_DEF_UNSET_2" }),
    "TETHER_DEF_UNSET_1", "T195 none set falls back to first")
  print("T195 providers verify/merge/env: OK")
end

-- T196: sync_providers TTL + branches (fresh/bg/ok/stale/missing)
do
  local home = "/tmp/tether_t196_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  local payload = '{"schema":1,"generated_at":456,"providers":'
    .. '{"hub":{"wire":"openai","base_url":"https://h","api_key_env":["H"],'
    .. '"model":"m","models":[]}}}'
  local calls = { n = 0, bg = 0 }
  local live_body = payload
  local orig_tether = _G.tether
  -- phase 1: sync path only (no fetch_bg) to exercise ok/stale/missing
  _G.tether = host_mock{
    http_get = function(url)
      calls.n = calls.n + 1
      assert_true(url:find("providers.json", 1, true) ~= nil, "T196 hits data URL")
      if live_body then return live_body end
      return nil, "boom"
    end,
  }

  -- miss + live success -> ok, slim cache written with checked_at
  assert_eq(commands.sync_providers(home), "ok", "T196 ok on miss")
  assert_eq(calls.n, 1, "T196 one sync attempt")
  local cp = catalog.cache_path(home)
  local f = io.open(cp, "r")
  local raw = f:read("*a")
  f:close()
  assert_true(raw:find('"checked_at"', 1, true) ~= nil, "T196 checked_at stored")
  assert_true(raw:find('"generated_at":456', 1, true) ~= nil, "T196 payload stored")
  assert_true(raw:find('"models"', 1, true) == nil, "T196 cache stored slim")

  -- fresh -> instant, zero network (stub would explode the count only)
  assert_eq(commands.sync_providers(home), "fresh", "T196 fresh instant")
  assert_eq(calls.n, 1, "T196 no network on fresh")

  -- stale + live failure -> stale served with reason (sync path: no fetch_bg)
  -- 8d back: past the weekly endpoints TTL.
  local old_raw = raw:gsub('"checked_at":(%d+)',
    function(ts) return '"checked_at":' .. (tonumber(ts) - 8 * 86400) end)
  local wf = io.open(cp, "w")
  wf:write(old_raw)
  wf:close()
  live_body = nil
  _G.tether = host_mock{
    http_get = function()
      calls.n = calls.n + 1
      return nil, "boom"
    end,
  }
  local st, serr = commands.sync_providers(home)
  assert_eq(st, "stale", "T196 stale on failure")
  assert_true(serr ~= nil, "T196 stale carries reason")

  -- no cache + failure -> missing naming the cause
  os.execute("rm -f '" .. cp .. "'")
  local ms, merr = commands.sync_providers(home)
  assert_eq(ms, "missing", "T196 missing without cache")
  assert_true(merr ~= nil, "T196 missing carries reason")

  -- schema mismatch body -> missing with schema reason
  live_body = '{"schema":99,"providers":{}}'
  _G.tether = host_mock{
    http_get = function() return live_body end,
  }
  local sm, smerr = commands.sync_providers(home)
  assert_eq(sm, "missing", "T196 schema mismatch not stored")
  assert_true(smerr:find("unsupported", 1, true) ~= nil, "T196 schema reason")

  -- background spawn path: stale cache serves while one spawn refreshes;
  -- no duplicate while the marker lives. (No cache at all takes the sync
  -- path instead so a first run can bootstrap: see commands.sync_providers.)
  local stale_wrap = '{"checked_at":' .. (os.time() - 8 * 86400)
    .. ',"schema":1,"generated_at":' .. (os.time() - 8 * 86400)
    .. ',"providers":{}}'
  local swf = io.open(cp, "w")
  swf:write(stale_wrap)
  swf:close()
  os.execute("rm -f '" .. cp .. ".pending'")
  _G.tether = host_mock{
    http_get = function() error("T196 sync must not run with fetch_bg") end,
    fetch_bg = function(url, headers, outpath, timeout)
      calls.bg = calls.bg + 1
      assert_eq(timeout, 20, "T196 bg timeout 20s")
      local mf = io.open(outpath, "w")
      if mf then mf:close() end
      return true
    end,
  }
  assert_eq(commands.sync_providers(home), "background", "T196 bg spawn")
  assert_eq(commands.sync_providers(home), "background", "T196 bg no duplicate")
  assert_eq(calls.bg, 1, "T196 exactly one spawn")

  _G.tether = orig_tether
  print("T196 sync_providers branches: OK")
end

-- T197: poll_providers consume (waiting/updated/settled + re-merge)
do
  local home = "/tmp/tether_t197_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  local pend = catalog.pending_path(home)

  -- empty marker -> waiting
  local mf = io.open(pend, "w")
  mf:close()
  assert_eq(commands.poll_providers(home), "waiting", "T197 waiting on marker")

  -- landed file -> updated, cache stored, re-merged into the view
  local wf = io.open(pend, "w")
  wf:write('{"schema":1,"generated_at":789,"providers":'
    .. '{"polled":{"wire":"openai","base_url":"https://p",'
    .. '"api_key_env":["P"],"model":"m","models":[]}}}')
  wf:close()
  assert_eq(commands.poll_providers(home), "updated", "T197 updated on land")
  local cat2 = assert(loadfile("src/tether/providers/catalog.lua"))()
  assert_eq(cat2.ensure(home), "ready", "T197 cache readable")
  assert_true(cat2.get("polled") ~= nil, "T197 landed id in merged view")
  assert_eq(cat2.overlay_meta().generated_at, 789, "T197 meta generated_at")

  -- failure marker -> settled, old providers preserved, cooldown armed
  local ff = io.open(pend, "w")
  ff:write("FETCH_FAILED timeout\n")
  ff:close()
  assert_eq(commands.poll_providers(home), "settled", "T197 failure settles")
  local cat3 = assert(loadfile("src/tether/providers/catalog.lua"))()
  assert_eq(cat3.ensure(home), "ready", "T197 old cache survives")
  assert_true(cat3.get("polled") ~= nil, "T197 old entry preserved")
  assert_eq(commands.sync_providers(home), "fresh", "T197 cooldown armed")

  -- nothing pending -> settled
  assert_eq(commands.poll_providers(home), "settled", "T197 quiet settles")
  print("T197 poll_providers: OK")
end

-- T198: models.lua overlay + startup gate
do
  local home = "/tmp/tether_t198_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()

  -- overlay defines a custom id and overrides a cached one wholesale
  local mf = io.open(home .. "/.tether/models.lua", "w")
  mf:write('return { providers = { ["my-proxy"] = { wire = "openai",'
    .. ' base_url = "https://corp.example/v1", api_key_env = "CORP_KEY",'
    .. ' model = "corp-model", models = {} } } }')
  mf:close()
  assert_eq(catalog.ensure(home), "ready", "T198 overlay loads")
  local e = catalog.get("my-proxy")
  assert_true(e ~= nil, "T198 custom id resolves")
  assert_eq(e.base_url, "https://corp.example/v1", "T198 custom endpoint")
  assert_eq(e._source, "models.lua", "T198 custom source stamped")
  local found = false
  for _, id in ipairs(catalog.ids()) do
    if id == "my-proxy" then found = true end
  end
  assert_true(found, "T198 custom id in picker ids")

  -- bootstrap-local id passes the gate with no cache at all
  local cat2 = assert(loadfile("src/tether/providers/catalog.lua"))()
  _G.provider_catalog = cat2
  -- NOTE: pre-4.4 bootstrap still carries the full Tier-A list; "llama" is
  -- the current local id (4.4 trims to llama-cpp + Tier-B).
  assert_true(commands.check_providers(home, "llama") == true,
    "T198 bootstrap-local passes offline")
  -- unknown id with no cache anywhere -> gate passes on the snapshot;
  -- the unknown id falls through to the alias-fallback path downstream
  -- (offline fresh install serves every snapshot id).
  local bare = "/tmp/tether_t198_bare"
  os.execute("rm -rf '" .. bare .. "' && mkdir -p '" .. bare .. "/.tether'")
  local ok, err = commands.check_providers(bare, "definitely-not-a-provider")
  assert_true(ok == true, "T198 unknown id passes on snapshot ("
    .. tostring(err) .. ")")

  -- malformed models.lua warns and is ignored: the pipeline catalog still
  -- serves (t197 home holds a cache; garbage overlay must not break it)
  local badhome = "/tmp/tether_t197_home"
  local bf = io.open(badhome .. "/.tether/models.lua", "w")
  bf:write("return { providers = { broken = = = } }\n")
  bf:close()
  local cat4 = assert(loadfile("src/tether/providers/catalog.lua"))()
  assert_eq(cat4.ensure(badhome), "ready", "T198 broken overlay ignored")
  assert_true(cat4.get("polled") ~= nil, "T198 cache serves past broken overlay")
  os.remove(badhome .. "/.tether/models.lua")
  _G.provider_catalog = nil
  print("T198 models.lua overlay + gate: OK")
end

-- T200: pipeline models[] in the listing fallback chain (4.1)
do
  local home = "/tmp/tether_t200_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local f = io.open(home .. "/.tether/providers_cache.json", "w")
  f:write('{"checked_at":' .. os.time() .. ',"schema":1,"generated_at":'
    .. os.time() .. ',"providers":{"groq":{"wire":"openai",'
    .. '"base_url":"https://api.groq.com/openai/v1",'
    .. '"api_key_env":["GROQ_API_KEY"],"model":"llama-3.3-70b-versatile",'
    .. '"models":[{"id":"m-a","context":100},{"id":"m-b","context":null}]},'
    .. '"openai":{"wire":"openai","base_url":"https://api.openai.com/v1",'
    .. '"api_key_env":["OPENAI_API_KEY"],"model":"gpt-4o-mini","models":[]}}}')
  f:close()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  assert_eq(catalog.ensure(home), "ready", "T200 cache loads")
  _G.provider_catalog = catalog
  local api = assert(loadfile("src/tether/api.lua"))()
  local groq = api.list_models({ provider = "groq" })
  assert_eq(#groq, 2, "T200 pipeline list served")
  assert_eq(groq[1], "m-a", "T200 pipeline id")
  -- curated native statics untouched
  local oai = api.list_models({ provider = "openai" })
  local has_mini = false
  for _, m in ipairs(oai) do
    if m == "gpt-4o-mini" then has_mini = true end
  end
  assert_true(has_mini, "T200 openai static kept")
  -- renamed upstream pin: resolves verbatim, warns naming the id
  local rpf = io.open(home .. "/.tether/renamed-cfg.lua", "w")
  rpf:write('return { provider = "groq", model = "renamed-away" }\n')
  rpf:close()
  local errf = io.open(home .. "/.tether/stderr.txt", "w")
  local old_err = io.stderr
  io.stderr = errf
  local cfgm2 = assert(loadfile("src/tether/config.lua"))()
  local rc = cfgm2.load(home .. "/.tether/renamed-cfg.lua", home)
  io.stderr = old_err
  errf:close()
  assert_eq(rc.model, "renamed-away", "T200 pin resolves verbatim")
  local ef = io.open(home .. "/.tether/stderr.txt", "r")
  local captured = ef:read("*a")
  ef:close()
  assert_true(captured:find("renamed-away", 1, true) ~= nil,
    "T200 pin warning names id")
  _G.provider_catalog = nil
  print("T200 pipeline listing fallback: OK")
end

-- T201: per-model max_tokens chain for compaction (4.2)
do
  local home = "/tmp/tether_t201_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local f = io.open(home .. "/.tether/providers_cache.json", "w")
  f:write('{"checked_at":' .. os.time() .. ',"schema":1,"generated_at":'
    .. os.time() .. ',"providers":{"testp":{"wire":"openai",'
    .. '"base_url":"https://t","api_key_env":["T"],"model":"base-m",'
    .. '"models":[{"id":"base-m","context":400},'
    .. '{"id":"other-m","context":100}]}}}')
  f:close()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  assert_eq(catalog.ensure(home), "ready", "T201 cache loads")
  _G.provider_catalog = catalog
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local hist = { { role = "user", content = string.rep("x", 320) } } -- est 80
  -- reserve 0 isolates the fraction leg (default 16384 would fire first
  -- on these tiny test budgets and mask the max_tokens under test).
  local ctx0 = { reserve_tokens = 0 }

  -- per-model limit applies: 0.7*100=70 < 80 (32768 would say false)
  assert_true(agent.should_summarize(hist,
    { provider = "testp", model = "other-m", context = ctx0 }),
    "T201 per-model limit applies")
  -- unknown model falls back to provider default: 0.7*400=280 > 80
  assert_true(not agent.should_summarize(hist,
    { provider = "testp", model = "nope", context = ctx0 }),
    "T201 unknown model falls back")
  -- user value wins over pipeline: 0.7*4000=2800 > 80
  assert_true(not agent.should_summarize(hist,
    { provider = "testp", model = "other-m",
      context = { max_tokens = 4000, reserve_tokens = 0 } }),
    "T201 user max_tokens wins")
  -- no provider context at all: historic default path intact
  assert_true(not agent.should_summarize(hist, { context = ctx0 }),
    "T201 default path intact")
  _G.provider_catalog = nil
  print("T201 max_tokens chain: OK")
end

-- T202: keyless loopback listing, never remote (4.3)
do
  -- dynamic-provider-catalog: seed openai (remote-static assertions).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local api = assert(loadfile("src/tether/api.lua"))()
  assert_true(api._is_loopback("http://127.0.0.1:8080/v1"), "T202 127 loopback")
  assert_true(api._is_loopback("http://localhost:11434/v1"), "T202 localhost")
  assert_true(api._is_loopback("http://[::1]:8080/v1"), "T202 v6 loopback")
  assert_true(not api._is_loopback("https://api.openai.com/v1"), "T202 public no")
  assert_true(not api._is_loopback("http://192.168.1.5:11434/v1"), "T202 lan no")
  assert_true(not api._is_loopback(nil), "T202 nil no")
  assert_true(not api._is_loopback("not a url"), "T202 garbage no")

  local calls = { n = 0 }
  local orig_tether = _G.tether
  _G.tether = host_mock{
    fchmod = function() return true end,
    http_get = function(url)
      calls.n = calls.n + 1
      assert_true(url:find("127.0.0.1", 1, true) ~= nil, "T202 loopback URL")
      return '{"data":[{"id":"local-m"}]}'
    end,
  }
  -- loopback without key attempts live
  local res, rerr = api.list_models_live(
    { provider = "llama", base_url = "http://127.0.0.1:8080/v1", model = "m" },
    "", 5)
  assert_true(res ~= nil and res[1].id == "local-m", "T202 loopback live")
  assert_eq(calls.n, 1, "T202 loopback attempted")
  -- public without key is refused before any network
  local res2, rerr2 = api.list_models_live(
    { provider = "openai", base_url = "https://api.openai.com/v1", model = "m" },
    "", 5)
  assert_true(res2 == nil and rerr2 == "no api key", "T202 public refused")
  assert_eq(calls.n, 1, "T202 public never attempted")
  -- LAN without key is refused too
  local res3 = api.list_models_live(
    { provider = "x", base_url = "http://192.168.1.5:11434/v1", model = "m" },
    "", 5)
  assert_true(res3 == nil, "T202 lan refused")

  -- commands level: loopback proceeds keyless, remote explains itself
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local orig_api = _G.api
  _G.api = api
  local home = "/tmp/tether_t202_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local m1 = commands.list_models(
    { provider = "llama", base_url = "http://127.0.0.1:8080/v1", model = "m",
      _auth_home = home }, "")
  assert_eq(#m1, 1, "T202 commands loopback live")
  assert_eq(m1[1].id, "local-m", "T202 commands loopback id")
  local m2 = commands.list_models(
    { provider = "openai", base_url = "https://api.openai.com/v1",
      model = "m", _auth_home = home }, "")
  assert_true(#m2 >= 10, "T202 commands remote static without key")
  assert_eq(calls.n, 2, "T202 commands remote no network")
  -- preset without static and without key explains itself (key hint)
  local m2b, _, e2b = commands.list_models(
    { provider = "groq", _auth_home = home }, "")
  assert_eq(#m2b, 0, "T202 commands preset empty")
  assert_true(e2b:find("no API key", 1, true) ~= nil, "T202 commands key hint")
  -- runtime message when the loopback host is down (fresh home: no
  -- models cache to mask the failure, like a first-ever open)
  local down_home = "/tmp/tether_t202_down"
  os.execute("rm -rf '" .. down_home .. "' && mkdir -p '" .. down_home .. "/.tether'")
  _G.tether = host_mock{
    fchmod = function() return true end,
    http_get = function() return nil, "connection refused" end,
  }
  local m4, _, e4 = commands.list_models(
    { provider = "llama", base_url = "http://127.0.0.1:8080/v1", model = "m",
      _auth_home = down_home }, "")
  assert_true(e4:find("local runtime", 1, true) ~= nil, "T202 runtime hint")
  _G.api = orig_api
  _G.tether = orig_tether
  _G.provider_catalog = orig_catalog
  print("T202 keyless loopback: OK")
end

-- T199: catalog age marks (providers_age branches + /model stale toast)
do
  local home = "/tmp/tether_t199_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()

  -- missing cache -> vendored snapshot age (offline installs mark build age)
  local no_cache = commands.providers_age(home)
  assert_true(no_cache ~= nil and no_cache.source == "snapshot",
    "T199 no cache serves snapshot age")
  assert_true(no_cache.text ~= nil, "T199 snapshot age has text")

  -- fresh cache -> age present, not stale
  local now = os.time()
  local f = io.open(catalog.cache_path(home), "w")
  f:write('{"checked_at":' .. now .. ',"schema":1,"generated_at":' .. now
    .. ',"providers":{}}')
  f:close()
  local young = commands.providers_age(home)
  assert_true(young ~= nil and young.stale == false, "T199 fresh not stale")
  assert_eq(young.source, "cache", "T199 fresh age source is cache")

  -- old data -> stale with human text (8d back: past the weekly TTL)
  local of = io.open(catalog.cache_path(home), "w")
  of:write('{"checked_at":' .. (now - 8 * 86400) .. ',"schema":1,'
    .. '"generated_at":' .. (now - 8 * 86400) .. ',"providers":{}}')
  of:close()
  local old = commands.providers_age(home)
  assert_true(old ~= nil and old.stale == true, "T199 old is stale")
  assert_eq(old.text, "8d", "T199 age text days")
  assert_eq(old.source, "cache", "T199 old age source is cache")

  -- /model open on a stale catalog sets the age toast (T78 pattern:
  -- drive _handle_key directly, read state back)
  local cfg_stub = {
    load = function()
      return { model = "test", workspace = "/tmp", _auth_home = home,
        provider = "openai", ui = { input_max_lines = 8 } }
    end,
    api_key = function() return "" end,
  }
  local uimod = run_ui_with({ 17 }, { config = cfg_stub,
    api = { list_models = function() return {} end } })
  for i = 1, #"/model" do
    uimod._handle_key({ kind = "text", char = ("/model"):sub(i, i) })
  end
  uimod._handle_key({ kind = "enter" })
  local S = uimod._get_state()
  assert_true(S.palette_mode == "model", "T199 model palette open")
  assert_true(S.toast ~= nil
    and S.toast:find("providers catalog 8d old", 1, true) ~= nil,
    "T199 stale age toast set")

  -- /model with no cache toasts the vendored snapshot age when stale.
  local bare_home = "/tmp/tether_t199_bare"
  os.execute("rm -rf '" .. bare_home .. "' && mkdir -p '" .. bare_home .. "/.tether'")
  local cfg_bare = {
    load = function()
      return { model = "test", workspace = "/tmp", _auth_home = bare_home,
        provider = "openai", ui = { input_max_lines = 8 } }
    end,
    api_key = function() return "" end,
  }
  local uimod2 = run_ui_with({ 17 }, { config = cfg_bare,
    api = { list_models = function() return {} end } })
  for i = 1, #"/model" do
    uimod2._handle_key({ kind = "text", char = ("/model"):sub(i, i) })
  end
  uimod2._handle_key({ kind = "enter" })
  local S2 = uimod2._get_state()
  local bare_age = commands.providers_age(bare_home)
  assert_true(bare_age ~= nil and bare_age.source == "snapshot",
    "T199 bare home serves snapshot age")
  if bare_age.stale then
    assert_true(S2.toast ~= nil
      and S2.toast:find("(vendored)", 1, true) ~= nil,
      "T199 vendored age toast set")
  else
    assert_true(S2.toast == nil, "T199 fresh snapshot sets no toast")
  end
  os.execute("rm -rf '" .. bare_home .. "'")
  print("T199 catalog age marks: OK")
end

-- T203: login secret-mode hint resolves api_key_env lists — dynamic-catalog
-- entries (e.g. `opencode`) carry a list of vars, not a string; painting the
-- hint concatenated the table raw and crashed the whole render.
do
  local function strip(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    opencode = { wire = "openai", base_url = "https://opencode.ai/zen/v1",
      api_key_env = { "OPENCODE_API_KEY" }, model = "kimi-k2.6",
      _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._execute_command("login", "opencode")
  assert_notnil(S.login_secret, "T203 secret mode open")
  local L = uim._layout()
  -- catalog branch: the hint names the var instead of crashing on the list
  uim._paint(true)
  assert_true(strip(uim._row(L.input_row) or ""):find("OPENCODE_API_KEY", 1, true) ~= nil,
    "T203 catalog-list hint names the env var")
  -- cfg.providers branch: config.catalog_providers copies cache entries
  -- verbatim, so a loaded cfg carries the same list
  S.cfg.providers = { opencode = { api_key_env = { "OPENCODE_API_KEY" } } }
  uim._paint(true)
  assert_true(strip(uim._row(L.input_row) or ""):find("OPENCODE_API_KEY", 1, true) ~= nil,
    "T203 cfg-list hint names the env var")
  -- a keyless preset (empty list) paints without a var and without crashing
  S.cfg.providers = { opencode = { api_key_env = {} } }
  uim._paint(true)
  assert_true(strip(uim._row(L.input_row) or ""):find("paste API key", 1, true) ~= nil,
    "T203 keyless hint has no var suffix")
  _G.provider_catalog = orig_catalog
  print("T203 login hint env list: OK")
end

-- T205: a loop error becomes the error banner, never a stderr dump that
-- kills the session — the failing tick is reported in place and the loop
-- stays live (the banner clears on the next Enter/Esc).
do
  local function strip(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  local polls = 0
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    tether = {
      poll = function(rfds, wfds, timeout)
        polls = polls + 1
        if polls == 1 then error("synthetic loop error") end
        return { read = { 0 }, write = {} }
      end,
    },
  })
  assert_true(polls >= 2, "T205 the loop survived the failing tick")
  assert_notnil(S.error_banner, "T205 loop error reached the banner")
  assert_true((S.error_banner or ""):find("synthetic loop error", 1, true) ~= nil,
    "T205 banner carries the error text: " .. tostring(S.error_banner))
  local L = uim._layout()
  assert_true(strip(uim._row(L.error_row) or ""):find("synthetic loop error", 1, true) ~= nil,
    "T205 banner painted, not thrown to the terminal")
  print("T205 loop error to banner: OK")
end

-- T206: a lone Esc during a busy turn (a tool command, a silent TTFT, a
-- backoff) must decode as esc — the pump retries a stashed escape prefix
-- every quantum, and one no tail follows within that window arrived alone
-- instead of being re-stashed forever.
do
  local clock_ms = 1000
  local fired
  local orig_tether = _G.tether
  _G.tether = setmetatable({
      monotonic_ms = function() return clock_ms end,
      read_char_nb = function() if not fired then fired = true; return 27 end return nil end,
      read_char = function() if not fired then fired = true; return 27 end return nil end,
    }, { __index = function() return function() return nil end end })
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  -- the module resolves `tether` at call time, so the post-run probes see
  -- the mock above (the harness shadowed it only while the loop ran)
  S.busy = true
  S.input = "typed"
  fired = false
  assert_false(uim._pump_keys(), "T206 the lone Esc stashes, no key decoded yet")
  assert_eq(#uim._byte_stash, 1, "T206 the Esc prefix waits for its tail")
  clock_ms = 1000 + 200 -- past the retry window: the tail is not coming
  assert_true(uim._pump_keys(), "T206 the aged-out Esc decodes as a key")
  assert_eq(#uim._byte_stash, 0, "T206 the stash is drained")
  _G.tether = orig_tether
  print("T206 lone Esc decodes while busy: OK")
end

-- T207: the same lone Esc with no turn running: the stdin drain fires only on
-- fresh bytes, so the stash gets a tick-driven retry (the same age window)
-- instead of waiting for the next keypress.
do
  local clock_ms = 5000
  local fired
  local orig_tether = _G.tether
  _G.tether = setmetatable({
      monotonic_ms = function() return clock_ms end,
      read_char_nb = function() if not fired then fired = true; return 27 end return nil end,
      read_char = function() if not fired then fired = true; return 27 end return nil end,
    }, { __index = function() return function() return nil end end })
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  S.busy = false
  S.error_banner = "stale banner"
  fired = false
  if type(uim._drain_stash) ~= "function" then
    assert_true(false, "T207 the idle stash retry seam exists")
  else
    assert_eq(uim._drain_stash(), 0, "T207 the lone Esc stashes, banner intact")
    assert_eq(S.error_banner, "stale banner", "T207 nothing decoded before the window")
    clock_ms = 5000 + 200
    assert_eq(uim._drain_stash(), 1, "T207 the aged-out Esc decodes on the tick retry")
    assert_eq(S.error_banner, nil, "T207 the Esc key cleared the banner")
  end
  _G.tether = orig_tether
   print("T207 lone Esc decodes while idle: OK")
end

-- T207b: _stash_front must not duplicate stash entries when called
-- repeatedly with the same content (e.g. a lone ESC that is drained
-- and re-stashed each idle tick). The stash must stay at size 1.
do
   local uim, S = run_ui_with({ 17 },
     { agent = { turn = function() return true end, get_history = function() return {} end } })
   -- In the normal flow M._read_nb() removes bytes before _stash_front,
   -- so the stash is always empty when _stash_front runs. Verify the
   -- stash stays at size 1 after repeated stash_front calls (no growth).
   uim._byte_stash = {}
   uim._stash_front({ 27 })
   assert_eq(#uim._byte_stash, 1, "T207b stash stays size 1 after stash_front")
   assert_eq(uim._byte_stash[1], 27, "T207b stash first byte is ESC")
   uim._stash_front({ 27 })
   assert_eq(#uim._byte_stash, 1, "T207b stash stays size 1 after second stash_front")
   assert_eq(uim._byte_stash[1], 27, "T207b stash first byte is still ESC")
   print("T207b stash no duplication: OK")
end

-- T208: the host raises a quit flag while a turn blocks (a Ctrl+Q during an
-- exec/sleep/transfer — the UI is not reading stdin then, so the host watches
-- it itself); the tick honors it and the app exits instead of sitting on the
-- turn the keystroke just aborted.
do
  local polls, quit_calls = 0, 0
  run_ui_with({}, {
    tether = {
      -- no scripted bytes: the loop lives on ticks alone, and after the quit
      -- window stdin drains to EOF so a missing fix still unwinds (a red
      -- test must hang nowhere)
      poll = function()
        polls = polls + 1
        if polls > 6 then return { read = { 0 }, write = {} } end
        return { read = {}, write = {} }
      end,
      read_char = function() return nil end,
      read_char_nb = function() return nil end,
      quit_requested = function()
        quit_calls = quit_calls + 1
        return quit_calls > 2
      end,
    },
  })
  assert_true(quit_calls >= 3, "T208 the tick polled the host quit flag")
  print("T208 host quit flag honored: OK")
end

-- T-empty-args: a tool call streamed with no argument fragments must echo
-- arguments "{}" (valid JSON), not "" — strict gateways 400 every
-- follow-up request replaying arguments:"" ("must be valid JSON"), while
-- local execution keeps its {} fallback.
do
  local ws = os.tmpname()
  os.remove(ws)
  assert(host_fs.mkdirp(ws))
  _G.tether = host_mock({
    getcwd = function() return ws end,
    realpath = function(p) return p end,
    exec = function() return true, 0 end,
    monotonic_ms = function() return 0 end,
  })
  _G.tools = assert(loadfile("src/tether/tools.lua"))()
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.extensions = nil
  local ncalls = 0
  _G.api = {
    stream = function(_, _, _, on_event)
      ncalls = ncalls + 1
      if ncalls == 1 then
        on_event({ type = "tool_call_start", id = "c1", name = "run", arguments = "" })
        -- no tool_call_delta chunks: the model sent no arguments
      end
      on_event({ type = "text_delta", text = "done" })
      on_event({ type = "done", reason = "stop" })
      return true, nil
    end,
  }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  agent.clear()
  local ok = agent.turn({ workspace = ws }, "", "do it", function() end)
  assert_true(ok, "T-empty-args turn completes")
  local args_out = nil
  for _, m in ipairs(agent.get_history()) do
    local tcalls = (m.role == "assistant" and type(m.content) == "table")
        and m.content.tool_calls or nil
    for _, tc in ipairs(tcalls or {}) do
      if tc.id == "c1" and tc["function"] then
        args_out = tc["function"].arguments
      end
    end
  end
  assert_eq(args_out, "{}", "T-empty-args echo carries valid JSON")
  os.execute("rm -rf '" .. ws .. "'")
  print("T-empty-args empty arguments echo as {}: OK")
end


-- T321 (audit H5, turn level): a tool call the built-in cannot accept must
-- close the conversation. Before the fix `patch` reached tools.patch as a table
-- and raised, so the dispatch never wrote the tool result: the assistant
-- message with tool_calls stayed unmatched and every later request of the
-- session was rejected for an unclosed conversation.
do
  local ws = os.tmpname()
  os.remove(ws)
  assert(host_fs.mkdirp(ws))
  _G.tether = host_mock({
    getcwd = function() return ws end,
    realpath = function(p) return p end,
    exec = function() return true, 0 end,
    monotonic_ms = function() return 0 end,
  })
  _G.tools = assert(loadfile("src/tether/tools.lua"))()
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.extensions = nil
  local ncalls = 0
  _G.api = {
    stream = function(_, _, _, on_event)
      ncalls = ncalls + 1
      if ncalls == 1 then
        on_event({ type = "tool_call_start", id = "p1", name = "patch", arguments = "" })
        -- arguments that do not decode into a diff: the shape that used to raise
        on_event({ type = "tool_call_delta", index = 0, id = "p1",
                   arguments = '{"files":{"a.lua":1}}' })
      else
        on_event({ type = "text_delta", text = "recovered" })
      end
      on_event({ type = "done", reason = "stop" })
      return true, nil
    end,
  }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  agent.clear()
  local events = {}
  local ok = agent.turn({ workspace = ws }, "", "patch it",
    function(ev) events[#events + 1] = ev end)
  assert_true(ok, "T321 the turn survives a tool it cannot run")
  assert_true(ncalls >= 2, "T321 the turn went on to the next request")
  local results, answered = 0, nil
  for _, m in ipairs(agent.get_history()) do
    if m.role == "tool" and m.tool_call_id == "p1" then
      results = results + 1
      answered = m
    end
  end
  assert_eq(results, 1, "T321 exactly one tool result for the call")
  local body = answered and (type(answered.content) == "table"
      and tostring(answered.content.error) or tostring(answered.content)) or ""
  assert_true(body:find("patch", 1, true) ~= nil,
    "T321 the result tells the model what failed (" .. body .. ")")
  local tool_events = 0
  for _, ev in ipairs(events) do
    if ev.type == "tool_result" then tool_events = tool_events + 1 end
  end
  assert_eq(tool_events, 1, "T321 exactly one tool_result event")
  os.execute("rm -rf '" .. ws .. "'")
  print("T321 raising tool keeps history closed: OK")
end


if failed > 0 then
    os.exit(1)
end
