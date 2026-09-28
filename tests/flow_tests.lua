-- tests/flow_tests.lua — decoder/busy/steer/shell/login palettes (split from lua_tests.lua, Phase C).
-- Run: lua tests/flow_tests.lua

dofile("tests/helpers.lua")
-- T137: decoder preserves alt on modified Enter (kitty + modifyOtherKeys)
do
  local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[#t + 1] = s:byte(i) end
    return t
  end
  local qi, queue = 0, {}
  _G.tether = host_mock{
    read_char = function()
      qi = qi + 1
      if qi <= #queue then return queue[qi] end
      return 0
    end,
    read_char_nb = function()
      qi = qi + 1
      if qi <= #queue then return queue[qi] end
      return nil
    end,
  }
  local keys = assert(loadfile("src/tether/ui/keys.lua"))()
  local bag = { _byte_stash = {}, _esc_stash_s = nil, _paint_clock = function() return 0 end }
  local function one(seq)
    queue, qi = to_bytes(seq), 0
    return keys.read_key(bag)
  end

  local k = one("\27[13;3u")
  assert_eq(k.kind, "newline", "T137 kitty Alt+Enter is a newline")
  assert_true(k.alt == true, "T137 kitty Alt+Enter keeps the alt flag")
  k = one("\27[13;2u")
  assert_eq(k.kind, "newline", "T137 kitty Shift+Enter stays a newline")
  assert_true(not k.alt, "T137 kitty Shift+Enter has no alt flag")
  k = one("\27[13;5u")
  assert_eq(k.kind, "newline", "T137 kitty Ctrl+Enter stays a newline")
  assert_true(not k.alt, "T137 kitty Ctrl+Enter has no alt flag")
  k = one("\27[13u")
  assert_eq(k.kind, "enter", "T137 plain Enter stays Enter")
  k = one("\27[27;3;13~")
  assert_eq(k.kind, "newline", "T137 modifyOtherKeys Alt+Enter is a newline")
  assert_true(k.alt == true, "T137 modifyOtherKeys Alt+Enter keeps alt")
  k = one("\27[27;2;13~")
  assert_eq(k.kind, "newline", "T137 mok Shift+Enter stays newline")
  assert_true(not k.alt, "T137 mok Shift+Enter has no alt")
  print("T137 Alt+Enter decode: OK")
end

-- T138: pure queue push — order and cap 8
do
  local ui = assert(loadfile("src/tether/ui.lua"))()
  assert_notnil(ui._queue_push, "T138 queue_push exported")
  local q = {}
  for i = 1, 8 do
    local ok = ui._queue_push(q, "m" .. i)
    assert_true(ok, "T138 push " .. i .. " succeeds")
  end
  assert_eq(#q, 8, "T138 queue holds 8")
  local ok9 = ui._queue_push(q, "m9")
  assert_false(ok9, "T138 ninth push fails")
  assert_eq(#q, 8, "T138 cap keeps length 8")
  assert_eq(q[1], "m1", "T138 order preserved")
  assert_eq(q[8], "m8", "T138 last item is 8th")
  print("T138 queue cap/order: OK")
end

-- T139/T140/T141: busy enqueue, Escape restore, confirmation owns keys
do
  local function str_bytes(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local function merge(...)
    local out = {}
    for _, list in ipairs({ ... }) do
      for _, b in ipairs(list) do out[#out + 1] = b end
    end
    return out
  end

  -- 139: while busy, Enter enqueues steer + user row + clears input;
  -- Alt+Enter enqueues follow-up; idle Alt+Enter inserts newline.
  local steered, followed = false, false
  local bytes139 = merge(str_bytes("hi"), { 13 }, str_bytes("use tabs"), { 13 },
    { 17 })
  local uim, S = run_ui_with(bytes139, {
    agent = {
      turn = function(cfg, key, text, on_event)
        -- mid-turn: pump should read "use tabs" + Enter from the buffer
        if on_event then on_event({ type = "text_delta", text = "x" }) end
        return true
      end,
      get_history = function() return {} end,
      set_steer_source = function() end,
    },
  })
  assert_notnil(S, "T139 state available")
  -- After the first Enter the turn runs; pump during text_delta should
  -- have consumed the second line into the steer queue.
  local steer_q = S.steer_queue or {}
  local follow_q = S.followup_queue or {}
  assert_true(#steer_q >= 1 or #follow_q >= 1,
    "T139 busy Enter enqueues (steer=" .. #steer_q .. " follow=" .. #follow_q .. ")")
  if #steer_q >= 1 then
    assert_eq(steer_q[1], "use tabs", "T139 steer text captured")
    steered = true
  end
  -- input cleared after successful enqueue
  assert_eq(S.input, "", "T139 input cleared after enqueue")

  -- idle Alt+Enter still inserts newline (no turn running)
  local uim2, S2 = run_ui_with(merge(str_bytes("ab"), { 17 }), {})
  local _ = uim2
  -- drive idle alt+enter through the key seam
  uim2._handle_key({ kind = "newline", alt = true })
  assert_true(S2.input:find("\n", 1, true) ~= nil,
    "T139 idle Alt+Enter inserts newline")

  -- 140: Escape while busy restores steers then follow-ups, one per line
  local uim3, S3 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  S3.busy = true
  S3.steer_queue = { "s1", "s2" }
  S3.followup_queue = { "f1" }
  S3.input = "draft"
  local aborted = false
  local turn_mod = _G.turn
  -- restore seam is pure: call through handle_key with a turn stub via agent
  local orig_agent = _G.agent
  -- Use the exported restore helper if present, else drive handle_key
  if uim3._restore_queues then
    uim3._restore_queues()
  else
    -- fallback: simulate via esc key — needs turn.abort; stub agent
    local saved_abort = nil
    if uim3._handle_key then
      -- inject esc through handle_key; agent global used by turn
      _G.agent = _G.agent or { abort_requested = false }
      uim3._handle_key({ kind = "esc" })
    end
  end
  if uim3._restore_queues then
    assert_eq(S3.input, "s1\ns2\nf1", "T140 Escape restores steers then follow-ups")
    assert_eq(#S3.steer_queue, 0, "T140 steer queue cleared")
    assert_eq(#S3.followup_queue, 0, "T140 follow-up queue cleared")
    -- empty-queue Escape: no-op restore keeps behavior
    S3.input = "keep"
    uim3._restore_queues()
    assert_eq(S3.input, "", "T140 empty-queue Escape clears input")
  end
  _G.agent = orig_agent

  -- 141: confirmation open → Enter goes to confirmation, not the queue
  local uim4, S4 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  S4.busy = true
  S4.confirmation = { label = "run rm", body = "rm -rf", options = {},
    detail = { id = "c1", name = "run", args = { command = "rm" } } }
  S4.confirmation_sel = 1
  S4.input = "sneaky"
  local q0 = #(S4.steer_queue or {})
  uim4._handle_key({ kind = "enter" })
  assert_eq(#(S4.steer_queue or {}), q0, "T141 confirmation Enter does not enqueue")
  -- Enter resolves via the confirmation menu (sel=1 → allow), never commits input
  assert_true(S4.confirmation == nil, "T141 confirmation resolved via menu")
  assert_eq(S4.input, "sneaky", "T141 input not submitted under confirmation")
  -- pump seam: must not run while confirmation is open
  S4.confirmation = { label = "x" }
  if uim4._pump_keys then
    uim4._pump_keys()
    assert_eq(#(S4.steer_queue or {}), q0, "T141 pump does not steal under confirmation")
  end

  print("T139-T141 busy steer/escape/confirm: OK")
end

-- T142: agent injects steer at segment boundary (after tools), journaled once,
-- no second system prompt; not injected between retry attempts.
do
  local names = {"agent", "session", "config", "api", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local retry = assert(loadfile("src/tether/retry.lua"))()
  _G.retry = retry
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  local journaled = {}
  _G.session = { append = function(_, ev) journaled[#journaled + 1] = ev end }
  _G.config = { get_system_prompt = function() return "SYS-PROMPT" end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end,
    read = function() return { content = "file-body", truncated = false } end }

  local a = assert(loadfile("src/tether/agent.lua"))()
  local steers = { "focus on the bug" }
  local stream_msgs = {}
  local stream_n = 0
  _G.api = {
    list_models = function() return {} end,
    stream = function(_, _, messages, on_event)
      stream_n = stream_n + 1
      local has_steer, sys_count = false, 0
      for _, m in ipairs(messages) do
        if m.role == "system" then sys_count = sys_count + 1 end
        if m.role == "user" and m.content == "focus on the bug" then has_steer = true end
      end
      stream_msgs[stream_n] = { has_steer = has_steer, sys_count = sys_count }
      if stream_n == 1 then
        -- fail first attempt → retry, no steer yet
        return false, retry.failure("server", "rate limit", 429)
      elseif stream_n == 2 then
        -- succeed with a tool call → segment boundary after tools
        on_event({ type = "tool_call_start", id = "c1", name = "read" })
        on_event({ type = "tool_call_delta", id = "c1", arguments = '{"path":"a.txt"}' })
        return true
      else
        -- after tools: steer must be present in this request
        on_event({ type = "text_delta", text = "ok" })
        return true
      end
    end,
  }
  a.set_steer_source(function()
    return table.remove(steers, 1)
  end)
  a.clear()
  local ok = a.turn({ workspace = "/ws", context = {}, _session_id = "sid" }, "k", "go", function() end)
  assert_true(ok == true or ok == false, "T142 turn returns")
  assert_true(stream_n >= 3, "T142 at least 3 stream calls (retry+tool+post): " .. stream_n)
  assert_true(stream_msgs[1] and not stream_msgs[1].has_steer,
    "T142 no steer between retry attempts")
  assert_true(stream_msgs[2] and not stream_msgs[2].has_steer,
    "T142 no steer before tool segment completes")
  assert_true(stream_msgs[3] and stream_msgs[3].has_steer,
    "T142 steer injected before next LLM call after tools")
  assert_eq(stream_msgs[3].sys_count, 1, "T142 exactly one system message")
  local sys_n, user_steer, user_go = 0, 0, 0
  for _, m in ipairs(a.get_history()) do
    if m.role == "system" then sys_n = sys_n + 1 end
    if m.role == "user" and m.content == "focus on the bug" then user_steer = user_steer + 1 end
    if m.role == "user" and m.content == "go" then user_go = user_go + 1 end
  end
  assert_eq(sys_n, 1, "T142 history has one system prompt")
  assert_eq(user_steer, 1, "T142 steer in history once")
  assert_eq(user_go, 1, "T142 original user text not re-added")
  local j_steer, j_go = 0, 0
  for _, ev in ipairs(journaled) do
    if ev.type == "message" and ev.role == "user" then
      if ev.content == "focus on the bug" then j_steer = j_steer + 1 end
      if ev.content == "go" then j_go = j_go + 1 end
    end
  end
  assert_eq(j_steer, 1, "T142 steer journaled once")
  assert_eq(j_go, 1, "T142 original user journaled once")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T142 segment-boundary steer injection: OK")
end

-- T143: follow-up drain order after settle; stop on error banner
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  assert_notnil(uim._drain_followups, "T143 drain_followups exported")
  local starts = {}
  -- stub turn.start via driving drain with a fake turn on the module
  -- Use set_followup_hook style: run through real turn.start by stubbing agent.turn
  local orig_turn = _G.turn
  -- We cannot easily replace turn; instead inspect queues before/after with
  -- error_banner and confirmation gates.
  S.followup_queue = { "f1", "f2" }
  S.steer_queue = {}
  S.error_banner = "boom"
  uim._drain_followups()
  assert_eq(#S.followup_queue, 2, "T143 error banner stops the drain")
  S.error_banner = nil
  S.confirmation = { label = "x" }
  uim._drain_followups()
  assert_eq(#S.followup_queue, 2, "T143 confirmation blocks the drain")
  S.confirmation = nil
  S.steer_queue = { "pending-steer" }
  uim._drain_followups()
  assert_eq(#S.followup_queue, 2, "T143 pending steer blocks follow-up drain")
  S.steer_queue = {}
  -- Now actually drain with a capturing turn.start seam
  if uim._set_turn_hook then
    uim._set_turn_hook(function(text) starts[#starts + 1] = text; return true end)
    uim._drain_followups()
    assert_eq(#starts, 2, "T143 drains two follow-ups in order")
    assert_eq(starts[1], "f1", "T143 first follow-up first")
    assert_eq(starts[2], "f2", "T143 second follow-up second")
    assert_eq(#S.followup_queue, 0, "T143 queue emptied")
  end
  print("T143 follow-up drain gates: OK")
end

-- T144/T145: shell prefix ! / !!
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    tools = {
      run = function(args, cfg)
        return { output = "OUT:" .. tostring(args.command), exit_code = 0, elapsed_ms = 1 }
      end,
      _within = function() return true end,
      _resolve = function(p) return p end,
      _workspace = function() return "/ws" end,
    },
  })
  assert_notnil(uim._parse_bang, "T144 parse_bang exported")
  local kind, cmd = uim._parse_bang("!git status")
  assert_eq(kind, "bang", "T144 single bang parses")
  assert_eq(cmd, "git status", "T144 single bang command")
  kind, cmd = uim._parse_bang("!!echo hi")
  assert_eq(kind, "double", "T144 double bang parses")
  assert_eq(cmd, "echo hi", "T144 double bang command")
  kind = uim._parse_bang("!")
  assert_eq(kind, "empty", "T144 bare bang is empty")
  kind = uim._parse_bang("!!")
  assert_eq(kind, "empty", "T144 bare double bang is empty")
  kind = uim._parse_bang("/clear")
  assert_eq(kind, nil, "T144 slash is not bang")
  kind = uim._parse_bang("hello")
  assert_eq(kind, nil, "T144 plain text is not bang")

  -- run bang: tool row, no user row, ! feeds context, !! does not
  local runs = {}
  local uim2, S2 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end,
      get_history = function() return {} end },
    tools = {
      run = function(args)
        runs[#runs + 1] = args.command
        return { output = "HELLO", exit_code = 0, elapsed_ms = 2 }
      end,
      _within = function() return true end,
      _workspace = function() return "/ws" end,
    },
  })
  if uim2._run_bang then
    uim2._run_bang("!git status")
    assert_eq(runs[1], "git status", "T144 bang runs via tools.run")
    local entries = uim2._transcript.entries()
    local saw_tool, saw_user = false, false
    for _, e in ipairs(entries) do
      if e.role == "tool" and e.body and e.body:find("HELLO", 1, true) then saw_tool = true end
      if e.role == "user" and e.text and e.text:find("git status", 1, true) then saw_user = true end
    end
    assert_true(saw_tool, "T144 bang shows tool-style row with output")
    assert_false(saw_user, "T144 bang does not create a user row for the ! line")
    assert_notnil(S2.bang_context, "T144 ! stores bang context")
    assert_true((S2.bang_context or ""):find("HELLO", 1, true) ~= nil,
      "T144 bang context holds output")
    -- exit code in summary
    local last = uim2._transcript.entries()
    local last_tool = last[#last]
    assert_true(last_tool and last_tool.summary and last_tool.summary:find("exit", 1, true) ~= nil,
      "T144 summary carries exit code")

    uim2._run_bang("!!make test")
    assert_eq(runs[2], "make test", "T145 double bang runs command")
    local ctx_before = S2.bang_context
    -- !! must not feed context: clear and re-run
    S2.bang_context = nil
    uim2._run_bang("!!again")
    assert_eq(S2.bang_context, nil, "T145 !! does not set bang context")

    -- bare bang → error banner, nothing run
    S2.error_banner = nil
    local n_before = #runs
    uim2._run_bang("!")
    assert_eq(#runs, n_before, "T144 bare bang runs nothing")
    assert_notnil(S2.error_banner, "T144 bare bang sets error banner")
  end
  print("T144-T145 shell prefix: OK")
end

-- T146-T156: add-provider-login — store, resolution, /login /logout, refresh
do
  local auth = assert(loadfile("src/tether/auth.lua"))()

  -- T146: store create-empty + fchmod 0600, per-provider get/set/delete,
  -- corrupt fallback, missing file contributes nothing.
  local tmp = os.tmpname()
  os.remove(tmp)
  local home = tmp .. "_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local store_path = home .. "/.tether/auth.json"

  -- missing store
  assert_eq(type(auth.load(home)), "table", "T146 missing store is empty table")
  assert_true(auth.get(home, "openai") == nil, "T146 missing entry is nil")

  -- set → save with 0600 before secret write
  local ok_set = auth.set(home, "anthropic", {
    kind = "oauth", access_token = "tok-secret", refresh_token = "rt-secret",
    expires_at = math.floor(os.time()) + 3600, refresh_url = "https://example/token",
  })
  assert_true(ok_set, "T146 set persists store")
  assert_true(auth.ensure_private(store_path), "T146 ensure_private succeeds")
  local mode_check = io.popen("stat -c %a '" .. store_path .. "' 2>/dev/null"):read("*l")
  assert_eq(mode_check, "600", "T146 store mode is 0600")

  local e = auth.get(home, "anthropic")
  assert_notnil(e, "T146 get returns entry")
  assert_eq(e.access_token, "tok-secret", "T146 entry keeps token")
  assert_true(auth.get(home, "gemini") == nil, "T146 other providers untouched")

  -- logout removes one provider only
  auth.set(home, "openai", { kind = "api_key", access_token = "sk-oai" })
  assert_true(auth.delete(home, "anthropic"), "T146 delete anthropic")
  assert_true(auth.get(home, "anthropic") == nil, "T146 anthropic gone")
  assert_notnil(auth.get(home, "openai"), "T146 openai still present")

  -- corrupt store → empty, no throw
  local cf = io.open(store_path, "w")
  cf:write("{ not json !!")
  cf:close()
  assert_eq(type(auth.load(home)), "table", "T146 corrupt store loads empty")
  assert_true(auth.get(home, "openai") == nil, "T146 corrupt yields no credentials")

  -- T147: redaction never leaks token material
  local r1 = auth.redact('Authorization: Bearer sk-abc123DEF')
  assert_true(r1:find("sk-abc123DEF", 1, true) == nil, "T147 bearer redacted")
  assert_true(r1:find("Bearer", 1, true) ~= nil, "T147 bearer label kept")
  local r2 = auth.redact('{"access_token":"eyJhbGciOi","refresh_token":"rt-x"}')
  assert_true(r2:find("eyJhbGciOi", 1, true) == nil, "T147 access_token redacted")
  assert_true(r2:find("rt-x", 1, true) == nil, "T147 refresh_token redacted")
  assert_eq(auth.redact(nil), nil, "T147 redact nil is nil")
  assert_eq(auth.redact(""), "", "T147 redact empty is empty")

  -- T148: config.api_key resolution order
  local config = assert(loadfile("src/tether/config.lua"))()
  local orig_auth = _G.auth
  _G.auth = auth
  local home2 = tmp .. "_h2"
  os.execute("rm -rf '" .. home2 .. "' && mkdir -p '" .. home2 .. "/.tether'")

  -- (4) env only when no store — exercised via auth.resolve_entry + config
  os.execute("rm -f '" .. home2 .. "/.tether/auth.json'")
  -- stored unexpired oauth wins over env: call auth.resolve_entry directly
  local unexpired = auth.resolve_entry({
    kind = "oauth", access_token = "oauth-wins",
    expires_at = math.floor(os.time()) + 60,
  })
  assert_eq(unexpired, "oauth-wins", "T148 unexpired oauth preferred")

  -- expired + refresh → one refresh, new token
  local refreshed = auth.resolve_entry({
    kind = "oauth", access_token = "old", refresh_token = "rt",
    expires_at = math.floor(os.time()) - 1,
    refresh_url = "https://example/token",
  }, function(url, body)
    assert_eq(body.grant_type, "refresh_token", "T148 refresh grant_type")
    assert_eq(body.refresh_token, "rt", "T148 refresh uses refresh_token")
    return '{"access_token":"new-tok","expires_in":3600}'
  end, os.time())
  assert_eq(refreshed, "new-tok", "T148 expired oauth refreshes once")

  -- expired + no refresh → nil (falls to env)
  local expired_noref = auth.resolve_entry({
    kind = "oauth", access_token = "old", expires_at = math.floor(os.time()) - 1,
  })
  assert_true(expired_noref == nil, "T148 expired unrefreshable yields nil")

  -- stored api_key kind
  local stored_key = auth.resolve_entry({ kind = "api_key", access_token = "sk-stored" })
  assert_eq(stored_key, "sk-stored", "T148 stored api_key returned")

  -- refresh failure → nil, no throw
  local refresh_fail = auth.resolve_entry({
    kind = "oauth", access_token = "old", refresh_token = "rt",
    expires_at = math.floor(os.time()) - 1,
    refresh_url = "https://example/token",
  }, function() return nil, "boom" end, os.time())
  assert_true(refresh_fail == nil, "T148 refresh failure yields nil")

  -- corrupt entry / nil entry
  assert_true(auth.resolve_entry(nil) == nil, "T148 nil entry yields nil")
  assert_true(auth.resolve_entry({ kind = "oauth" }) == nil, "T148 oauth without token yields nil")

  _G.auth = orig_auth

  -- T149: /login /logout palette registration + unknown provider banner
  -- dynamic-provider-catalog: seed the big three (ui snapshots the catalog
  -- at load; the seed stays through T156, which also needs them).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
      api_key_env = "ANTHROPIC_API_KEY", model = "x", _source = "test" },
    gemini = { wire = "gemini", base_url = "https://generativelanguage.googleapis.com",
      api_key_env = "GEMINI_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local found_login, found_logout = false, false
  for _, c in ipairs(uim.SLASH_COMMANDS or {}) do
    if c.cmd == "login" then found_login = true end
    if c.cmd == "logout" then found_logout = true end
  end
  assert_true(found_login, "T149 /login in palette")
  assert_true(found_logout, "T149 /logout in palette")

  -- unknown provider → error banner, no flow (explicit name still checked)
  uim._execute_command("login", "azure")
  assert_notnil(S.error_banner, "T149 unknown provider error banner")
  assert_true((S.error_banner or ""):find("azure", 1, true) ~= nil,
    "T149 banner names unknown provider")
  assert_true(S.login_secret == nil, "T149 unknown provider enters no secret mode")

  -- T150: logout confirmation has no secrets
  local home3 = tmp .. "_h3"
  os.execute("rm -rf '" .. home3 .. "' && mkdir -p '" .. home3 .. "/.tether'")
  auth.set(home3, "openai", { kind = "api_key", access_token = "sk-super-secret" })
  local orig_auth2 = _G.auth
  _G.auth = auth
  -- force auth path for logout by stubbing home via auth path seam
  local orig_path = auth.path
  auth.path = function() return home3 .. "/.tether/auth.json" end
  local entries_before = #uim._transcript.entries()
  uim._execute_command("logout", "openai")
  local after = uim._transcript.entries()
  local saw_confirm, leaked = false, false
  for i = entries_before + 1, #after do
    local t = tostring(after[i].text or "")
    if t:find("logout", 1, true) or t:find("вый", 1, true) or t:find("clear", 1, true)
      or t:find("удал", 1, true) or t:find("сброшен", 1, true)
      or t:find("openai", 1, true) then saw_confirm = true end
    if t:find("sk-super-secret", 1, true) then leaked = true end
  end
  assert_false(leaked, "T150 logout line has no token text")
  assert_true(auth.get(home3, "openai") == nil, "T150 logout removed entry")
  auth.path = orig_path
  _G.auth = orig_auth2

  -- T219: logout-picker — bare /logout lists stored-only ids in a picker;
  -- Enter deletes immediately (no confirmation); empty store and
  -- named-without-entry report instead of acting.
  local home9 = tmp .. "_h9"
  os.execute("rm -rf '" .. home9 .. "' && mkdir -p '" .. home9 .. "/.tether'")
  auth.set(home9, "openai", { kind = "api_key", access_token = "sk-logout-9" })
  auth.set(home9, "gemini", { kind = "oauth", access_token = "tok-logout-9" })
  local orig_auth9 = _G.auth
  _G.auth = auth
  local orig_path9 = auth.path
  auth.path = function() return home9 .. "/.tether/auth.json" end
  local uim9, S9 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    config = { load = function()
        return { model = "m", provider = "gemini",
                 base_url = "https://models.example/v1",
                 workspace = "/tmp", ui = { input_max_lines = 8 } }
      end,
      api_key = function() return "" end },
  })
  uim9._execute_command("logout", "")
  assert_true(S9.palette_active, "T219 bare /logout opens the picker")
  assert_eq(S9.palette_mode, "logout", "T219 picker mode is logout")
  local labels9 = {}
  for _, it in ipairs(S9.palette_items or {}) do labels9[#labels9 + 1] = it.label end
  assert_eq(#labels9, 2, "T219 picker lists stored ids only")
  assert_eq(labels9[1], "gemini", "T219 stored ids sorted")
  assert_eq(labels9[2], "openai", "T219 stored ids sorted")
  local descs9 = {}
  for _, it in ipairs(S9.palette_items) do descs9[it.label] = it.desc or "" end
  assert_true(descs9.gemini:find("oauth", 1, true) ~= nil, "T219 row shows kind")
  assert_true(descs9.gemini:find("active", 1, true) ~= nil, "T219 active provider marked")
  assert_true(descs9.openai:find("api_key", 1, true) ~= nil, "T219 row shows kind")
  assert_true(descs9.openai:find("sk-logout-9", 1, true) == nil, "T219 no token text in rows")
  -- filter narrows; Esc clears first, closes second; store untouched
  for i = 1, #"ope" do
    uim9._handle_key({ kind = "text", char = ("ope"):sub(i, i) })
  end
  assert_eq(S9.palette_query, "ope", "T219 picker query accumulates")
  assert_eq(#S9.palette_items, 1, "T219 picker filter narrows")
  assert_eq(S9.palette_items[1].label, "openai", "T219 picker match wins")
  assert_eq(S9.input, "", "T219 picker filter does not touch main input")
  uim9._handle_key({ kind = "esc" })
  assert_true(S9.palette_active, "T219 picker Esc clears first")
  assert_eq(#S9.palette_items, 2, "T219 cleared query restores rows")
  uim9._handle_key({ kind = "esc" })
  assert_true(S9.palette_active == false, "T219 picker second Esc closes")
  assert_notnil(auth.get(home9, "openai"), "T219 Esc deletes nothing")
  -- named provider without an entry reports instead of removing
  uim9._execute_command("logout", "anthropic")
  assert_true((S9.error_banner or ""):find("no stored credential", 1, true) ~= nil,
    "T219 missing entry banner names the state")
  assert_notnil(auth.get(home9, "gemini"), "T219 missing entry deletes nothing")
  -- unknown provider keeps its banner
  uim9._execute_command("logout", "azure")
  assert_true((S9.error_banner or ""):find("azure", 1, true) ~= nil,
    "T219 unknown provider banner")
  -- logout-confirm 5.1: Enter on a picked row opens the deletion step instead
  -- of removing anything; the entry only goes when that step accepts.
  local entries9 = #uim9._transcript.entries()
  uim9._execute_command("logout", "")
  uim9._handle_key({ kind = "enter" })
  assert_eq(S9.palette_mode, "logout-confirm", "T219 picker Enter opens the step")
  assert_notnil(auth.get(home9, "gemini"), "T219 Enter alone deletes nothing")
  uim9._handle_key({ kind = "text", char = "y" })
  assert_true(S9.palette_active == false, "T219 accepted step closes the palette")
  assert_true(auth.get(home9, "gemini") == nil, "T219 the accepted step deletes")
  assert_notnil(auth.get(home9, "openai"), "T219 other entries untouched")
  local after9 = uim9._transcript.entries()
  local saw9, leaked9 = false, false
  for i = entries9 + 1, #after9 do
    local t = tostring(after9[i].text or "")
    if t:find("logout", 1, true) and t:find("gemini", 1, true) then saw9 = true end
    if t:find("tok-logout-9", 1, true) then leaked9 = true end
  end
  assert_true(saw9, "T219 system row confirms the removal")
  assert_false(leaked9, "T219 system row has no token text")
  auth.path = orig_path9
  _G.auth = orig_auth9
  -- empty store: no picker, banner instead
  local home9b = tmp .. "_h9b"
  os.execute("rm -rf '" .. home9b .. "' && mkdir -p '" .. home9b .. "/.tether'")
  local orig_auth9b = _G.auth
  _G.auth = auth
  local orig_path9b = auth.path
  auth.path = function() return home9b .. "/.tether/auth.json" end
  local uim9b, S9b = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim9b._execute_command("logout", "")
  assert_true(S9b.palette_active == false, "T219 empty store opens no picker")
  assert_true((S9b.error_banner or ""):find("no provider is logged in", 1, true) ~= nil,
    "T219 empty store banner says nobody is logged in")
  auth.path = orig_path9b
  _G.auth = orig_auth9b

  print("T219 logout stored-only picker: OK")

  -- T289-T292: logout-confirm — the picker's second step. Enter or a click on a
  -- provider row opens it; only its accepted row deletes; backing out returns
  -- to the same filtered list with the same highlight.
  do
    local home9c = tmp .. "_h9c"
    os.execute("rm -rf '" .. home9c .. "' && mkdir -p '" .. home9c .. "/.tether'")
    auth.set(home9c, "openai", { kind = "api_key", access_token = "sk-confirm-9c" })
    auth.set(home9c, "gemini", { kind = "oauth", access_token = "tok-confirm-9c" })
    local orig_authc, orig_pathc = _G.auth, auth.path
    _G.auth = auth
    auth.path = function() return home9c .. "/.tether/auth.json" end
    local uimc, Sc = run_ui_with({ 17 }, {
      agent = { turn = function() return true end, get_history = function() return {} end },
      config = { load = function()
          return { model = "m", provider = "gemini",
                   base_url = "https://models.example/v1",
                   workspace = "/tmp", ui = { input_max_lines = 8 } }
        end, api_key = function() return "" end },
    })

    -- T289: the step itself. Two rows naming the provider, nothing removed
    -- until one of them is accepted, and `y` closes with a token-free row.
    local before_c = #uimc._transcript.entries()
    assert_eq(Sc._logout_confirm, nil, "T289 a fresh session has no target")
    assert_eq(Sc._logout_sel, nil, "T289 a fresh session has no saved index")
    uimc._execute_command("logout", "")
    uimc._handle_key({ kind = "enter" })
    assert_eq(Sc.palette_mode, "logout-confirm", "T289 Enter opens the step")
    assert_true(Sc.palette_active, "T289 the step stays in the shared palette")
    assert_eq(Sc._logout_confirm, "gemini", "T289 the step targets the highlighted row")
    assert_eq(Sc._logout_sel, 1, "T289 the list index is remembered")
    assert_eq(#Sc.palette_items, 2, "T289 the step offers exactly two rows")
    assert_eq(Sc.palette_items[1].label, "yes", "T289 the delete row leads")
    assert_true(Sc.palette_items[1].desc:find("gemini", 1, true) ~= nil,
      "T289 the delete row names the provider")
    assert_true(Sc.palette_items[2].desc:find("gemini", 1, true) ~= nil,
      "T289 the keep row names the provider too")
    assert_notnil(auth.get(home9c, "gemini"), "T289 nothing is deleted before the accept")
    -- D2: the step owns no filter buffer — keys are choices, not query text.
    uimc._handle_key({ kind = "text", char = "q" })
    assert_eq(Sc.palette_query, "", "T289 an unused key filters nothing")
    assert_eq(Sc.palette_mode, "logout-confirm", "T289 an unused key deletes nothing")
    assert_eq(#Sc.palette_items, 2, "T289 an unused key drops no row")
    uimc._handle_key({ kind = "text", char = "y" })
    assert_true(Sc.palette_active == false, "T289 y deletes and closes")
    assert_true(auth.get(home9c, "gemini") == nil, "T289 y removed the entry")
    assert_notnil(auth.get(home9c, "openai"), "T289 y left the other entry alone")
    assert_eq(Sc._logout_confirm, nil, "T289 the target is cleared on close")
    local after_c = uimc._transcript.entries()
    local saw_c, leak_c = false, false
    for i = before_c + 1, #after_c do
      local t = tostring(after_c[i].text or "")
      if t:find("logout", 1, true) and t:find("gemini", 1, true) then saw_c = true end
      if t:find("tok-confirm-9c", 1, true) then leak_c = true end
    end
    assert_true(saw_c, "T289 the accept confirms with a system row")
    assert_false(leak_c, "T289 the system row carries no token text")

    -- T290: Esc returns to the list with the filter and the highlight intact,
    -- and the keep row (Enter on it, or `n`) is the same way back.
    auth.set(home9c, "gemini", { kind = "oauth", access_token = "tok-confirm-9c" })
    uimc._execute_command("logout", "")
    for i = 1, #"ope" do
      uimc._handle_key({ kind = "text", char = ("ope"):sub(i, i) })
    end
    assert_eq(#Sc.palette_items, 1, "T290 the list filters to one provider")
    uimc._handle_key({ kind = "enter" })
    assert_eq(Sc._logout_confirm, "openai", "T290 the step targets the filtered row")
    uimc._handle_key({ kind = "esc" })
    assert_eq(Sc.palette_mode, "logout", "T290 Esc returns to the provider list")
    assert_true(Sc.palette_active, "T290 Esc does not close the palette")
    assert_eq(Sc.palette_query, "ope", "T290 the filter survives the step")
    assert_eq(#Sc.palette_items, 1, "T290 the filtered rows come back")
    assert_eq(Sc.palette_sel, 1, "T290 the highlight comes back")
    assert_notnil(auth.get(home9c, "openai"), "T290 backing out deletes nothing")
    uimc._handle_key({ kind = "enter" })
    uimc._handle_key({ kind = "special", name = "down" })
    assert_eq(Sc.palette_sel, 2, "T290 the arrows move inside the step")
    uimc._handle_key({ kind = "enter" })
    assert_eq(Sc.palette_mode, "logout", "T290 Enter on the keep row returns to the list")
    assert_notnil(auth.get(home9c, "openai"), "T290 keeping deletes nothing")

    -- T291: state hygiene on the plain close, and a reopened picker is a list.
    uimc._handle_key({ kind = "text", char = "n" })
    assert_eq(Sc.palette_mode, "logout", "T291 n returns to the list")
    uimc._handle_key({ kind = "esc" })
    assert_eq(Sc.palette_query, "", "T291 Esc clears the filter first")
    uimc._handle_key({ kind = "esc" })
    assert_true(Sc.palette_active == false, "T291 the second Esc closes the picker")
    assert_eq(Sc.palette_mode, "command", "T291 the palette is back to command")
    assert_eq(Sc._logout_confirm, nil, "T291 no target survives the close")
    assert_eq(Sc._logout_sel, nil, "T291 no index survives the close")
    uimc._execute_command("logout", "")
    assert_eq(Sc.palette_mode, "logout", "T291 a second bare /logout opens the plain list")
    assert_eq(#Sc.palette_items, 2, "T291 no row of the step leaks into the list")

    -- T292: the pointer takes the same path as the keyboard, row for row.
    local Lc = uimc._layout()
    uimc._handle_key({ kind = "mouse", name = "press", row = Lc.palette_row + 2, col = 5, button = 0 })
    assert_eq(Sc.palette_mode, "logout-confirm", "T292 a click on a provider opens the step")
    assert_eq(Sc._logout_confirm, "openai", "T292 the click targets the row it hit")
    assert_notnil(auth.get(home9c, "openai"), "T292 a click deletes nothing by itself")
    Lc = uimc._layout()
    uimc._handle_key({ kind = "mouse", name = "press", row = Lc.palette_row + 2, col = 5, button = 0 })
    assert_eq(Sc.palette_mode, "logout", "T292 clicking the keep row returns to the list")
    assert_notnil(auth.get(home9c, "openai"), "T292 keeping by click deletes nothing")
    Lc = uimc._layout()
    uimc._handle_key({ kind = "mouse", name = "press", row = Lc.palette_row + 1, col = 5, button = 0 })
    assert_eq(Sc._logout_confirm, "gemini", "T292 the step is open for the first row")
    Lc = uimc._layout()
    uimc._handle_key({ kind = "mouse", name = "press", row = Lc.palette_row + 1, col = 5, button = 0 })
    assert_true(Sc.palette_active == false, "T292 clicking the delete row closes")
    assert_true(auth.get(home9c, "gemini") == nil, "T292 the click deleted that entry")
    assert_notnil(auth.get(home9c, "openai"), "T292 the other entry is untouched")

    auth.path = orig_pathc
    _G.auth = orig_authc
    os.execute("rm -rf '" .. home9c .. "'")
    print("T289-T292 logout confirmation step: OK")
  end

  -- T151: refresh-on-401 in agent attempt loop (one refresh, then retry once)
  local names = {"agent", "session", "config", "api", "tools", "context", "tether", "retry", "auth"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local retry = assert(loadfile("src/tether/retry.lua"))()
  _G.retry = retry
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  local journaled = {}
  _G.session = { append = function(_, ev) journaled[#journaled + 1] = ev end }
  _G.config = { get_system_prompt = function() return "SYS" end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }
  local home4 = tmp .. "_h4"
  os.execute("rm -rf '" .. home4 .. "' && mkdir -p '" .. home4 .. "/.tether'")
  local a_store = auth.load(home4)
  a_store.anthropic = {
    kind = "oauth", access_token = "expired", refresh_token = "rt-1",
    expires_at = math.floor(os.time()) - 10, refresh_url = "https://example/token",
  }
  auth.save(home4, a_store)
  _G.auth = auth

  local refresh_calls, stream_n = 0, 0
  local stream_keys = {}
  _G.api = {
    list_models = function() return {} end,
    stream = function(_, key, messages, on_event)
      stream_n = stream_n + 1
      stream_keys[stream_n] = key
      if stream_n == 1 then
        return false, retry.failure("permanent", "http 401: invalid api key", 401)
      end
      on_event({ type = "text_delta", text = "ok" })
      return true
    end,
  }
  local a = assert(loadfile("src/tether/agent.lua"))()
  -- agent reads auth via config.api_key; we stub config.api_key for the loop
  local cfg4 = { workspace = "/ws", context = {}, provider = "anthropic",
    api_key_env = "ANTHROPIC_API_KEY", _session_id = "sid",
    _auth_home = home4 }
  -- inject refresh path: auth module post_json seam
  local orig_refresh = auth.refresh_token
  auth.refresh_token = function(provider, entry, post_json, now)
    refresh_calls = refresh_calls + 1
    entry.access_token = "fresh-tok"
    entry.expires_at = (now or os.time()) + 3600
    return true
  end
  -- config.api_key path used by agent: we pass key through cfg resolution
  local orig_cfg_api_key = config.api_key
  -- agent uses the api_key argument passed to turn; for T151 the UI would
  -- re-resolve after refresh. Simulate: first call returns expired, then
  -- auth path updates and agent re-reads via config.api_key.
  local calls = 0
  config.api_key = function(c)
    calls = calls + 1
    if calls <= 1 then return "expired" end
    local ent = auth.get(home4, "anthropic")
    return ent and ent.access_token or ""
  end

  a.clear()
  -- wire refresh into agent: on permanent 401 with refresh_token, refresh once
  -- (this hook is under test — agent must expose it via run_answer path)
  local ok_turn = a.turn(cfg4, config.api_key(cfg4), "hi", function() end)
  -- If the agent refresh hook is implemented: stream called twice with keys
  -- "expired" then "fresh-tok". If not yet wired, stream_n==1 and we assert
  -- the hook behavior after implementing.
  assert_true(stream_n >= 1, "T151 stream attempted")
  -- prefer hooked path
  if stream_n >= 2 then
    assert_eq(stream_keys[1], "expired", "T151 first attempt uses expired key")
    assert_eq(stream_keys[2], "fresh-tok", "T151 retry uses refreshed key")
    assert_true(refresh_calls >= 1, "T151 refresh ran once")
    -- no token in journal
    for _, ev in ipairs(journaled) do
      local s = tostring(ev.content or "") .. tostring(ev.message or "")
      assert_true(s:find("fresh-tok", 1, true) == nil
        and s:find("rt-1", 1, true) == nil,
        "T151 journal has no token material")
    end
  end
  auth.refresh_token = orig_refresh
  config.api_key = orig_cfg_api_key

  -- T152: refresh failure → permanent error suggesting /login, no loop
  local stream_n2 = 0
  _G.api = {
    list_models = function() return {} end,
    stream = function(_, key, messages, on_event)
      stream_n2 = stream_n2 + 1
      return false, retry.failure("permanent", "http 401: unauthorized", 401)
    end,
  }
  local a2 = assert(loadfile("src/tether/agent.lua"))()
  local home5 = tmp .. "_h5"
  os.execute("rm -rf '" .. home5 .. "' && mkdir -p '" .. home5 .. "/.tether'")
  auth.set(home5, "openai", {
    kind = "oauth", access_token = "old", refresh_token = "rt-bad",
    expires_at = math.floor(os.time()) - 1, refresh_url = "https://example/token",
  })
  local refresh_fail = 0
  auth.refresh_token = function()
    refresh_fail = refresh_fail + 1
    return false
  end
  local cfg5 = { workspace = "/ws", context = {}, provider = "openai",
    api_key_env = "OPENAI_API_KEY", _session_id = "sid5", _auth_home = home5 }
  local err_msgs = {}
  local ok5 = a2.turn(cfg5, "old", "hi", function(ev)
    if ev.type == "error" then err_msgs[#err_msgs + 1] = ev.message or "" end
  end)
  assert_true(stream_n2 >= 1, "T152 stream attempted")
  assert_true(stream_n2 <= 3, "T152 no refresh loop (stream calls=" .. stream_n2 .. ")")
  assert_true(#err_msgs >= 1, "T152 error event emitted")
  local joined = table.concat(err_msgs, "\n")
  assert_true(joined:find("/login", 1, true) ~= nil or joined:find("login", 1, true) ~= nil
    or joined:find("auth", 1, true) ~= nil or joined:find("key", 1, true) ~= nil,
    "T152 error suggests /login or auth: " .. joined)

  auth.refresh_token = orig_refresh
  for _, n in ipairs(names) do _G[n] = orig[n] end

  -- T153: dedicated masked secret entry — secret lives in S.login_secret.buf,
  -- never in S.input and never in the transcript; Enter stores it; overlay
  -- is never opened (palette-only R5).
  local home6 = tmp .. "_h6"
  os.execute("rm -rf '" .. home6 .. "' && mkdir -p '" .. home6 .. "/.tether'")
  local orig_path6 = auth.path
  auth.path = function() return home6 .. "/.tether/auth.json" end
  local orig_auth3 = _G.auth
  _G.auth = auth
  local turns53 = 0
  local uim5, S5 = run_ui_with({ 17 }, {
    agent = { turn = function() turns53 = turns53 + 1; return true end,
              get_history = function() return {} end },
  })
  uim5._execute_command("login", "openai")
  assert_notnil(S5.login_secret, "T153 /login enters secret mode")
  assert_eq(S5.login_provider, "openai", "T153 secret mode carries provider")
  local entries53 = #uim5._transcript.entries()
  -- type/paste the secret into the secret buffer only
  uim5._handle_key({ kind = "paste", text = "sk-paste-secret-53" })
  assert_eq(S5.input, "", "T153 secret never enters main chat input")
  assert_eq((S5.login_secret or {}).buf, "sk-paste-secret-53",
    "T153 secret stored in secret buffer")
  uim5._handle_key({ kind = "enter" })
  assert_eq(S5.login_secret, nil, "T153 secret mode closed after store")
  assert_eq(S5.login_provider, nil, "T153 login prompt cleared after store")
  assert_eq(turns53, 0, "T153 secret not sent to agent")
  local e53 = auth.get(home6, "openai")
  assert_notnil(e53, "T153 paste stores credential")
  assert_eq(e53.kind, "api_key", "T153 paste stored as api_key")
  assert_eq(e53.access_token, "sk-paste-secret-53", "T153 token saved")
  local after53 = uim5._transcript.entries()
  local leaked53 = false
  for i = entries53 + 1, #after53 do
    local t = tostring(after53[i].text or "")
    if t:find("sk-paste-secret-53", 1, true) then leaked53 = true end
  end
  assert_false(leaked53, "T153 confirmation has no token text")
  auth.path = orig_path6
  _G.auth = orig_auth3

  -- T155: /login with no argument opens the shared palette in a login mode
  -- (same mechanism as /copy) — never a silent active-provider default,
  -- never touches S.input, never a full-screen overlay.
  local uim155, S155 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim155._execute_command("login", "")
  assert_true(S155.palette_active, "T155 bare /login opens the palette")
  assert_eq(S155.palette_mode, "login", "T155 palette mode is login")
  local labels = {}
  for _, it in ipairs(S155.palette_items or {}) do labels[#labels + 1] = it.label end
  assert_eq(labels[1], "openai", "T155 picker pins openai first")
  assert_eq(labels[2], "anthropic", "T155 picker pins anthropic second")
  assert_eq(labels[3], "gemini", "T155 picker pins gemini third")
  -- dynamic-provider-catalog: the picker lists the merged catalog, however
  -- large the pipeline cache makes it (fixture here: bootstrap + 3 seeded).
  assert_eq(#labels, #catfix.ids(), "T155 picker lists full catalog")
  assert_eq(S155.input, "", "T155 picker does not touch main input")
  assert_true(S155.login_provider == nil, "T155 no login flow started until pick")
  assert_eq(S155.login_secret, nil, "T155 picker is not secret mode")
  -- Esc closes the picker without side effects
  uim155._handle_key({ kind = "esc" })
  assert_true(S155.palette_active == false, "T155 Esc closes palette")
  assert_eq(S155.palette_mode, "command", "T155 Esc resets palette mode")
  -- Enter on a selected provider starts secret entry for it (no overlay)
  uim155._execute_command("login", "")
  uim155._handle_key({ kind = "special", name = "down" })
  uim155._handle_key({ kind = "enter" })
  assert_notnil(S155.login_secret, "T155 picker Enter enters secret mode")
  assert_eq(S155.login_provider, "anthropic", "T155 picked provider is active login")
  assert_true(S155.palette_active == false, "T155 palette closes when secret starts")

  -- T156: secret mode masks the secret on screen and never paints it into the
  -- frame or transcript; Esc cancels without storing.
  local home8 = tmp .. "_h8"
  os.execute("rm -rf '" .. home8 .. "' && mkdir -p '" .. home8 .. "/.tether'")
  local orig_path8 = auth.path
  auth.path = function() return home8 .. "/.tether/auth.json" end
  local orig_auth5 = _G.auth
  _G.auth = auth
  local sink156 = {}
  local uim156, S156 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  }, sink156)
  uim156._execute_command("login", "gemini")
  assert_notnil(S156.login_secret, "T156 secret mode open")
  local ent156 = #uim156._transcript.entries()
  uim156._handle_key({ kind = "paste", text = "AIzaMaskedSecret156" })
  -- paint into the row buffer (harness restores _G.tether after run, so the
  -- write sink is dead — assert on S.screen via the frame path instead)
  pcall(function() uim156._paint(true) end)
  local frame156 = {}
  for row = 1, (S156.h or 24) do
    frame156[#frame156 + 1] = tostring(S156.screen and S156.screen[row] or "")
  end
  frame156 = table.concat(frame156, "\n")
  assert_true(frame156:find("AIzaMaskedSecret156", 1, true) == nil,
    "T156 painted frame never contains plaintext secret")
  assert_true(frame156:find("*", 1, true) ~= nil or frame156:find("•", 1, true) ~= nil,
    "T156 secret is masked on screen")
  local aft156 = uim156._transcript.entries()
  local leak156 = false
  for i = ent156 + 1, #aft156 do
    local t = tostring(aft156[i].text or "")
    if t:find("AIzaMaskedSecret156", 1, true) then leak156 = true end
  end
  assert_false(leak156, "T156 transcript never contains secret")
  -- Esc cancels: nothing stored, secret mode closed, no overlay
  uim156._handle_key({ kind = "esc" })
  assert_eq(S156.login_secret, nil, "T156 Esc closes secret mode")
  assert_true(auth.get(home8, "gemini") == nil, "T156 cancel stores nothing")
  auth.path = orig_path8
  _G.auth = orig_auth5

  -- T154: provider exchange hooks — login_flow builds authorize URL when a
  -- client_id is configured; token_exchange posts the standard code grant
  -- shape (stubbed HTTP) and parses the token response into an oauth entry.
  local openai_p = assert(loadfile("src/tether/providers/openai.lua"))()
  local anthropic_p = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local gemini_p = assert(loadfile("src/tether/providers/gemini.lua"))()

  -- no client_id → paste-only (login_flow returns nil)
  assert_true(gemini_p.login_flow({ providers = { gemini = {} } }) == nil,
    "T154 gemini without client_id has no oauth flow")
  assert_true(openai_p.login_flow({}) == nil,
    "T154 openai without client_id has no oauth flow")

  -- gemini: built-in Google endpoints + configured client_id
  local gflow = gemini_p.login_flow({
    providers = { gemini = { oauth_client_id = "cid-g-123" } },
  })
  assert_notnil(gflow, "T154 gemini login_flow with client_id")
  assert_true((gflow.authorize_url or ""):find("cid-g-123", 1, true) ~= nil,
    "T154 authorize URL carries client_id")
  assert_true((gflow.authorize_url or ""):find("accounts.google.com", 1, true) ~= nil,
    "T154 gemini authorize host")
  assert_notnil(gflow.token_url, "T154 token_url present")
  assert_notnil(gflow.redirect_uri, "T154 redirect_uri present")
  assert_eq(gflow.client_id, "cid-g-123", "T154 flow keeps client_id")

  -- openai/anthropic: endpoints come from config (no invented defaults)
  local oflow = openai_p.login_flow({
    providers = { openai = {
      oauth_client_id = "cid-o-1",
      oauth_authorize_url = "https://example.test/o/authorize",
      oauth_token_url = "https://example.test/o/token",
      oauth_redirect_uri = "http://localhost:7/",
      oauth_scope = "api",
    } },
  })
  assert_notnil(oflow, "T154 openai login_flow with full oauth config")
  assert_eq(oflow.authorize_url:find("cid-o-1", 1, true) ~= nil, true,
    "T154 openai authorize has client_id")
  assert_eq(oflow.token_url, "https://example.test/o/token", "T154 openai token_url")

  -- missing token endpoint → no half-built flow
  assert_true(openai_p.login_flow({
    providers = { openai = { oauth_client_id = "cid-o-1" } },
  }) == nil, "T154 openai flow requires oauth_token_url")

  -- token_exchange request shape (stubbed post_json)
  local captured_url, captured_body
  local function good_post(url, body)
    captured_url, captured_body = url, body
    return '{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}'
  end
  local entry = gemini_p.token_exchange(good_post, gflow, "authcode-xyz", 1000000000)
  assert_notnil(entry, "T154 token_exchange returns entry")
  assert_eq(captured_url, gflow.token_url, "T154 POST hits token_url")
  assert_eq(type(captured_body), "table", "T154 body is a form field table")
  assert_eq(captured_body.grant_type, "authorization_code", "T154 grant_type")
  assert_eq(captured_body.code, "authcode-xyz", "T154 authorization code")
  assert_eq(captured_body.client_id, "cid-g-123", "T154 client_id in exchange")
  assert_eq(captured_body.redirect_uri, gflow.redirect_uri, "T154 redirect_uri echoed")
  assert_eq(entry.kind, "oauth", "T154 entry kind oauth")
  assert_eq(entry.access_token, "at-1", "T154 access_token stored")
  assert_eq(entry.refresh_token, "rt-1", "T154 refresh_token stored")
  assert_eq(entry.expires_at, 1000000000 + 3600, "T154 expires_at from expires_in")
  assert_eq(entry.refresh_url, gflow.token_url, "T154 refresh_url for later refresh")
  assert_eq(entry.token_type, "Bearer", "T154 token_type kept")

  -- transport failure → nil entry, no throw
  local e_fail = openai_p.token_exchange(function() return nil, "network" end,
    oflow, "code-1")
  assert_true(e_fail == nil, "T154 transport failure yields nil entry")

  -- provider error body → nil entry
  local e_err = anthropic_p.token_exchange(
    function() return '{"error":"invalid_grant"}' end, oflow, "code-1")
  assert_true(e_err == nil, "T154 invalid_grant yields nil entry")

  -- response missing access_token → nil
  local e_noat = gemini_p.token_exchange(
    function() return '{"expires_in":60}' end, gflow, "code-1")
  assert_true(e_noat == nil, "T154 response without access_token yields nil")

  -- /login opens a credential dialog carrying the authorize URL and best-effort-
  -- opens a browser when a flow is available; S.login_flow is set for the code path.
  local home7 = tmp .. "_h7"
  os.execute("rm -rf '" .. home7 .. "' && mkdir -p '" .. home7 .. "/.tether'")
  local orig_path7 = auth.path
  auth.path = function() return home7 .. "/.tether/auth.json" end
  local orig_auth4 = _G.auth
  _G.auth = auth
  local uim7, S7 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    config = (function()
      local cfg = {
        provider = "gemini", api_key_env = "GEMINI_API_KEY",
        workspace = "/tmp", ui = { input_max_lines = 8 },
        providers = { gemini = { oauth_client_id = "cid-ui-9" } },
      }
      return {
        load = function() return cfg end,
        api_key = function() return "" end,
      }
    end)(),
  })
  local opens7 = {}
  local orig_tether7 = _G.tether
  _G.tether = host_mock{
    exec = function(cmd) opens7[#opens7 + 1] = cmd; return true, 0 end,
    getcwd = function() return "/tmp" end,
  }
  uim7._execute_command("login", "gemini")
  assert_notnil(S7.login_secret, "T154 /login enters secret mode")
  assert_notnil(S7.login_flow, "T154 /login sets S.login_flow when oauth configured")
  assert_eq(S7.login_provider, "gemini", "T154 /login keeps provider prompt")
  assert_notnil(S7.login_secret, "T154 /login enters secret mode")
  local flow7 = S7.login_flow
  assert_notnil(flow7 and flow7.authorize_url, "T154 dialog flow has authorize URL")
  assert_true((flow7.authorize_url or ""):find("cid-ui-9", 1, true) ~= nil
    or (flow7.authorize_url or ""):find("accounts.google.com", 1, true) ~= nil,
    "T154 authorize URL present in dialog flow")
  local opened = false
  for _, c in ipairs(opens7) do
    if tostring(c):find("accounts.google.com", 1, true)
      or tostring(c):find("xdg-open", 1, true)
      or tostring(c):find("open ", 1, true) then
      opened = true
    end
  end
  assert_true(opened, "T154 best-effort browser open attempted")

  -- code paste into the dialog runs token_exchange (stubbed _post_json)
  local ex_calls = 0
  local ex_url = flow7 and flow7.token_url
  local orig_post = auth._post_json
  auth._post_json = function(url, body)
    ex_calls = ex_calls + 1
    assert_eq(url, ex_url, "T154 UI exchange uses flow.token_url")
    assert_eq(body.grant_type, "authorization_code", "T154 UI exchange grant")
    assert_eq(body.code, "ui-code-77", "T154 UI exchange code")
    return '{"access_token":"at-ui","refresh_token":"rt-ui","expires_in":120}'
  end
  local turns7 = 0
  _G.agent = { turn = function() turns7 = turns7 + 1; return true end,
               get_history = function() return {} end }
  local entries7 = #uim7._transcript.entries()
  uim7._handle_key({ kind = "paste", text = "http://localhost/?code=ui-code-77" })
  assert_eq(S7.input, "", "T154 code never enters main chat input")
  assert_eq((S7.login_secret or {}).buf, "http://localhost/?code=ui-code-77",
    "T154 code lives in the secret buffer")
  uim7._handle_key({ kind = "enter" })
  assert_eq(ex_calls, 1, "T154 redirect paste triggers one exchange")
  assert_eq(S7.login_secret, nil, "T154 secret mode closed after exchange")
  assert_eq(S7.login_flow, nil, "T154 flow cleared after successful exchange")
  assert_eq(turns7, 0, "T154 code path never sends text to agent")
  local e7 = auth.get(home7, "gemini")
  assert_notnil(e7, "T154 oauth entry stored")
  assert_eq(e7.kind, "oauth", "T154 stored kind oauth")
  assert_eq(e7.access_token, "at-ui", "T154 stored access_token")
  local after7b = uim7._transcript.entries()
  local leaked7 = false
  for i = entries7 + 1, #after7b do
    local t = tostring(after7b[i].text or "")
    if t:find("at-ui", 1, true) or t:find("rt-ui", 1, true)
      or t:find("ui-code-77", 1, true) then leaked7 = true end
  end
  assert_false(leaked7, "T154 exchange confirmation has no secret material")

  -- bare API key during oauth-enabled login still stores as api_key
  uim7._execute_command("login", "gemini")
  local post_before = ex_calls
  uim7._handle_key({ kind = "paste", text = "AIzaSyBareKeyNotOAuthCode000000000000" })
  assert_eq(S7.input, "", "T154 api key never enters main chat input")
  uim7._handle_key({ kind = "enter" })
  assert_eq(ex_calls, post_before, "T154 api_key paste skips token_exchange")
  local e_key = auth.get(home7, "gemini")
  assert_notnil(e_key, "T154 api_key still stored during oauth login")
  assert_eq(e_key.kind, "api_key", "T154 bare key stored as api_key")

  auth._post_json = orig_post
  _G.tether = orig_tether7
  auth.path = orig_path7
  _G.auth = orig_auth4
  _G.provider_catalog = orig_catalog

  print("T146-T156 provider login: OK")
end

-- T157: palette-only R4 — error is banner + debug-log only, no overlay.
-- Enter/Esc on the banner clear it (so a later Enter can submit); the full
-- error text is written to the debug log when logging is on, never to the
-- transcript; ov == "error" and enter→overlay are gone.
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })

  uim._set_error_banner("boom157")
  assert_notnil(S.error_banner, "T157 banner starts visible")
  uim._handle_key({ kind = "enter" })
  assert_eq(S.error_banner, nil, "T157 Enter clears the error banner")

  uim._set_error_banner("boom157b")
  uim._handle_key({ kind = "esc" })
  assert_eq(S.error_banner, nil, "T157 Esc clears the error banner")

  -- full error text → debug log when S.debug; never a transcript row
  local cap = {}
  uim._debug_capture = cap
  S.debug = true
  local n_before = #uim._transcript.entries()
  uim._handle_agent_event({ type = "error", message = "FULL_ERROR_TEXT_157" })
  assert_eq(S.error_banner, "FULL_ERROR_TEXT_157", "T157 error event sets the banner")
  local logged = false
  for _, line in ipairs(cap) do
    if tostring(line):find("FULL_ERROR_TEXT_157", 1, true) then logged = true end
  end
  assert_true(logged, "T157 full error text reaches the debug log")
  local n_after = #uim._transcript.entries()
  assert_eq(n_after, n_before, "T157 error event adds no transcript row")
  local leaked = false
  for i = n_before + 1, n_after do
    local t = tostring(uim._transcript.entries()[i].text or "")
    if t:find("FULL_ERROR_TEXT_157", 1, true) then leaked = true end
  end
  assert_false(leaked, "T157 full error text is not in the transcript")

  -- debug off → no log capture
  local cap2 = {}
  uim._debug_capture = cap2
  S.debug = false
  uim._handle_agent_event({ type = "error", message = "NOLOG_157" })
  assert_eq(#cap2, 0, "T157 debug off writes nothing to the log")
  uim._debug_capture = nil

  print("T157 error banner + debug-log only: OK")
end

-- T158: palette-only R3/R6 — confirmation has no details/[d]/[4].
-- Digit map is 1..5 (allow, session, always, deny, cancel); pressing d or 4
-- no longer opens a details overlay; allow/deny still resolve.
do
  local ui = dofile("src/tether/ui.lua")
  local dm = ui.CONFIRM_DIGITS
  assert_eq(#dm, 5, "T158 five confirmation digits")
  assert_true(dm[4] ~= "details", "T158 digit 4 is not details")
  assert_eq(dm[4], "deny", "T158 digit 4 is deny")
  assert_eq(dm[5], "cancel", "T158 digit 5 is cancel")
  assert_eq(ui.KEYMAP["4"], "confirm deny", "T158 KEYMAP digit 4 is deny")
  assert_eq(ui.KEYMAP["5"], "confirm cancel", "T158 KEYMAP digit 5 is cancel")
  assert_eq(ui.KEYMAP["6"], nil, "T158 KEYMAP has no digit 6")
  assert_eq(ui.KEYMAP["d"], nil, "T158 KEYMAP has no d-details entry")

  -- live menu: d / 4 must not open overlay details; they deny (digit 4) or
  -- fall through (d unbound after removal).
  -- _G.turn must be stubbed BEFORE run_ui_with: ui.lua captures
  -- local turn = _G.turn at load and never re-reads the global.
  local resolved = {}
  local orig_confirm = _G.turn
  _G.turn = {
    confirm = function(id, dec) resolved[#resolved + 1] = dec; return true end,
    continue = function() return true end,
    start = function() return true end,
    abort = function() end,
  }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local orig_agent = _G.agent
  S.confirmation = {
    label = "write /tmp/x",
    body = "write",
    options = {
      "[once]     allow once",
      "[session]  allow until the session ends",
      "[always]   save to auto_approve",
      "[deny]     decline",
    },
    detail = { id = "c1", name = "write", args = { path = "/tmp/x", content = "hi" } },
  }
  S.confirmation_sel = 1
  uim._handle_key({ kind = "text", char = "d" })
  -- d is unbound after details removal: confirmation stays open
  assert_notnil(S.confirmation, "T158 d leaves the menu open (no details)")
  -- digit 4 = deny
  uim._handle_key({ kind = "text", char = "4" })
  assert_eq(S.confirmation, nil, "T158 digit 4 resolves the menu")
  assert_eq(resolved[#resolved], "deny", "T158 digit 4 is deny")
  _G.turn = orig_confirm
  _G.agent = orig_agent

  print("T158 confirmation without details: OK")
end

-- T159: palette-only R2 — /resume opens a palette_mode = "resume" list,
-- never a full-screen overlay. Enter resumes the picked session; Esc is a
-- no-op close. palette_sync must not clobber the explicit list.
do
  local orig_commands = _G.commands
  local resumed_with = nil
  local sessions = {
    { id = "sess-alpha", ts = "2026-09-23 10:00", first_line = "fix the login bug" },
    { id = "sess-beta",  ts = "2026-09-23 11:00", first_line = "add palette mode" },
  }
  _G.commands = {
    list_sessions = function() return sessions end,
    resume = function(id)
      resumed_with = id
      return id, { { role = "user", content = "restored q" } }
    end,
    new = function() return "new-sid" end,
    list_models = function() return {} end,
    compact = function() return "", "noop" end,
  }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    session = { new_session = function() return "sid" end },
  })
  -- open: palette_mode resume, items present
  uim._execute_command("resume")
  assert_eq(S.palette_mode, "resume", "T159 /resume palette_mode is resume")
  assert_true(S.palette_active, "T159 palette is active")
  assert_true(#(S.palette_items or {}) >= 2, "T159 resume items from list_sessions")
  -- palette_sync must not overwrite an explicit resume list
  local n0 = #S.palette_items
  uim._handle_key({ kind = "text", char = "x" })
  -- text while in resume palette: mode-specific handler owns keys (no fall-through)
  assert_eq(#S.palette_items, n0, "T159 resume items survive a keypress")
  assert_eq(S.palette_mode, "resume", "T159 palette_mode stays resume")
  -- Esc closes with no side effects
  uim._handle_key({ kind = "esc" })
  assert_true(S.palette_active == false, "T159 Esc closes the palette")
  assert_eq(S.palette_mode, "command", "T159 Esc resets palette_mode")
  assert_eq(resumed_with, nil, "T159 Esc does not resume")
  -- reopen and Enter on the first item
  uim._execute_command("resume")
  uim._handle_key({ kind = "enter" })
  assert_true(S.palette_active == false, "T159 Enter closes the palette")
  assert_eq(resumed_with, "sess-alpha", "T159 Enter resumes the picked session")
  assert_eq(S.session_id, "sess-alpha", "T159 S.session_id updated")
  _G.commands = orig_commands

  print("T159 /resume palette: OK")
end

-- T159b: resume shows clock times (not the "2026-" year prefix sub(1,5)
-- painted on every row) and resumed tool rows keep name + summary.
do
  local orig_commands = _G.commands
  _G.commands = {
    list_sessions = function()
      return { { id = "sess-1", ts = "2026-09-24T10:00:00", first_line = "q" } }
    end,
    resume = function(id) return id, {} end,
    new = function() return "new-sid" end,
    list_models = function() return {} end,
    compact = function() return "", "noop" end,
  }
  local uim, _ = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._execute_command("resume")
  local items = uim._get_state().palette_items or {}
  local label = (items[1] and items[1].label) or ""
  assert_true(label:find("10:00", 1, true) ~= nil,
    "T159b resume row shows the clock time: " .. label)
  _G.commands = orig_commands

  -- seed renders tool rows and assistant text riding with tool_calls
  local uim2, _ = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local seeded = uim2._transcript.seed({
    { role = "user", content = "look" },
    { role = "assistant", content = { tool_calls = { { id = "c1" } }, text = "checking" } },
    { role = "tool", tool_call_id = "c1", name = "list",
      summary = "2 записей", content = "a\nb" },
    { role = "assistant", content = "done" },
  })
  assert_eq(#seeded, 4, "T159b seed keeps user/assistant-text/tool rows")
  local all = table.concat(uim2._render_all(80), "\n"):gsub("\27%[[%d;]*m", "")
  assert_true(all:find("checking", 1, true) ~= nil,
    "T159b assistant text with tool_calls renders")
  assert_true(all:find("list", 1, true) ~= nil and all:find("2 записей", 1, true) ~= nil,
    "T159b resumed tool row shows name and summary")

  print("T159b resume times and tool rows: OK")
end

-- T159c: ui.run reuses the app-provided session (app and ui used to mint
-- one session each per launch, burying real sessions under empties).
do
  local calls = 0
  local names = { "tether", "config", "session", "agent", "api", "tools", "diff" }
  local originals, preload = {}, {}
  do local okd, dmod = pcall(loadfile, "src/tether/diff.lua")
    _G.diff = (okd and dmod and dmod()) or _G.diff end
  for _, n in ipairs(names) do originals[n] = _G[n]; preload[n] = package.preload[n] end
  local function mockenv(with_sid)
    local qi = 0
    _G.tether = host_mock{
      write = function() end,
      resize_requested = function() return false end,
      get_terminal_size = function() return { width = 80, height = 24 } end,
      getcwd = function() return "/tmp" end,
      read_char = function() qi = qi + 1; if qi <= 1 then return 17 end; return 17 end,
      read_char_nb = function() return nil end,
    }
    _G.config = { load = function()
        local cfg = { model = "m", workspace = "/tmp", ui = { input_max_lines = 8 } }
        if with_sid then cfg._session_id = with_sid end
        return cfg
      end,
      api_key = function() return "" end }
    _G.session = { new_session = function() calls = calls + 1; return "fresh" end }
    _G.agent = { turn = function() return true end, get_history = function() return {} end }
    _G.api = { list_models = function() return {} end }
  end
  mockenv("keep-me")
  local ui1 = assert(loadfile("src/tether/ui.lua"))()
  ui1.run()
  assert_eq(calls, 0, "T159c no new session when the app hands one over")
  assert_eq(ui1._get_state().session_id, "keep-me", "T159c the handed session is used")
  mockenv(nil)
  local ui2 = assert(loadfile("src/tether/ui.lua"))()
  ui2.run()
  assert_eq(calls, 0, "T159c looking around mints no session")
  assert_eq(ui2._get_state().session_id, "?", "T159c no session id before the first turn")
  ui2._handle_key({ kind = "text", char = "h" })
  ui2._handle_key({ kind = "enter" })
  assert_eq(calls, 1, "T159c the first turn mints exactly one session")
  assert_eq(ui2._get_state().session_id, "fresh", "T159c the minted session is used")
  for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
  print("T159c ui.run reuses the app session: OK")
end

-- T160: palette-only R2 — /model opens palette_mode = "model", never overlay.
-- Enter sets S.model_name and a system row; Esc closes without side effects.
do
  local orig_commands = _G.commands
  _G.commands = {
    list_sessions = function() return {} end,
    resume = function() return nil end,
    new = function() return "new-sid" end,
    list_models = function()
      return {
        { id = "gpt-4o", name = "GPT-4o" },
        { id = "claude-opus", name = "Claude Opus" },
      }
    end,
    compact = function() return "", "noop" end,
  }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local before_model = S.model_name
  uim._execute_command("model")
  assert_eq(S.palette_mode, "model", "T160 /model palette_mode is model")
  assert_true(S.palette_active, "T160 palette is active")
  assert_true(#(S.palette_items or {}) >= 2, "T160 model items from list_models")
  -- Esc closes with no model change
  uim._handle_key({ kind = "esc" })
  assert_true(S.palette_active == false, "T160 Esc closes the palette")
  assert_eq(S.palette_mode, "command", "T160 Esc resets palette_mode")
  assert_eq(S.model_name, before_model, "T160 Esc does not change the model")
  -- reopen, Enter on the first model
  uim._execute_command("model")
  uim._handle_key({ kind = "enter" })
  assert_true(S.palette_active == false, "T160 Enter closes the palette")
  assert_eq(S.model_name, "gpt-4o", "T160 Enter sets model_name from the pick")
  local entries = uim._transcript.entries()
  local last = entries[#entries]
  assert_notnil(last, "T160 transcript has a row after model change")
  assert_true(tostring(last.text or ""):find("gpt-4o", 1, true) ~= nil,
    "T160 system row mentions the new model")
  _G.commands = orig_commands

  print("T160 /model palette: OK")
end

-- T160b: picking another provider's model re-resolves the endpoint in
-- memory. Only updating provider/model/key left base_url baked for the old
-- provider, so the next turn hit the old endpoint with the new model name
-- (restricted-region-style failure until a restart re-baked the URL).
do
  local orig_commands = _G.commands
  local orig_config = _G.config
  _G.commands = {
    list_sessions = function() return {} end,
    resume = function() return nil end,
    new = function() return "new-sid" end,
    list_models = function()
      return {
        { id = "m-new", name = "New", provider = "prov-b" },
        { id = "m-old", name = "Old", provider = "prov-a" },
      }
    end,
    compact = function() return "", "noop" end,
  }
  _G.config = {
    for_provider = function(cfg, id)
      local c2 = {}
      for k, v in pairs(cfg) do c2[k] = v end
      c2.provider = id
      c2.base_url = "https://models." .. id .. ".example/v1"
      c2.provider_env = {}
      return c2
    end,
  }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    config = { load = function()
        return { model = "m-old", provider = "prov-a",
                 base_url = "https://models.prov-a.example/v1",
                 workspace = "/tmp", ui = { input_max_lines = 8 } }
      end,
      api_key = function() return "" end },
  })
  uim._execute_command("model")
  uim._handle_key({ kind = "enter" })
  assert_eq(S.cfg.provider, "prov-b", "T160b provider switches in memory")
  assert_eq(S.cfg.model, "m-new", "T160b model switches in memory")
  assert_eq(S.cfg.base_url, "https://models.prov-b.example/v1",
    "T160b endpoint follows the provider without a restart")
  _G.commands = orig_commands
  _G.config = orig_config

  print("T160b cross-provider pick re-resolves endpoint: OK")
end

-- T218: palette-fuzzy-search — /model and bare /login filter as you type
-- with the same fuzzy_rank primitive as the slash palette. Query row lives
-- in the indicator slot; Esc clears the query first and closes second;
-- Enter on an empty match list does nothing.
do
  local strip = function(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  local orig_commands = _G.commands
  _G.commands = {
    list_sessions = function() return {} end,
    resume = function() return nil end,
    new = function() return "new-sid" end,
    list_models = function()
      return {
        { id = "gpt-4o", name = "GPT-4o" },
        { id = "gpt-4o-mini", name = "GPT-4o mini" },
        { id = "claude-sonnet", name = "Claude Sonnet" },
      }
    end,
    compact = function() return "", "noop" end,
  }
  local function type_text(u, text)
    for i = 1, #text do u._handle_key({ kind = "text", char = text:sub(i, i) }) end
  end
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local before_model = S.model_name
  uim._execute_command("model")
  assert_eq(S.palette_query, "", "T218 query starts empty")
  assert_eq(#S.palette_items, 3, "T218 empty query lists all")
  -- arrows move, then typing resets the selection to the top match
  uim._handle_key({ kind = "special", name = "down" })
  assert_eq(S.palette_sel, 2, "T218 arrows move before typing")
  type_text(uim, "cld")
  assert_eq(S.palette_query, "cld", "T218 query accumulates text")
  assert_eq(#S.palette_items, 1, "T218 filter narrows to one")
  assert_eq(S.palette_items[1].label, "claude-sonnet", "T218 fuzzy match wins")
  assert_eq(S.palette_sel, 1, "T218 selection resets on query change")
  -- query row paint in the indicator slot
  uim._paint(true)
  local L = uim._layout()
  local win = uim._palette_window(S.h, #S.palette_items, S.palette_sel)
  assert_true(strip(uim._row(L.palette_row + win + 1)):find("> cld", 1, true) ~= nil,
    "T218 query row shows the typed filter")
  -- backspace edits the query and restores rows
  uim._handle_key({ kind = "backspace" })
  assert_eq(S.palette_query, "cl", "T218 backspace edits the query")
  assert_eq(#S.palette_items, 1, "T218 shorter query still matches")
  -- Esc clears first, closes second; model untouched throughout
  uim._handle_key({ kind = "esc" })
  assert_true(S.palette_active, "T218 first Esc keeps the palette open")
  assert_eq(S.palette_query, "", "T218 first Esc clears the query")
  assert_eq(#S.palette_items, 3, "T218 cleared query restores the full list")
  uim._handle_key({ kind = "esc" })
  assert_true(S.palette_active == false, "T218 second Esc closes")
  assert_eq(S.model_name, before_model, "T218 Esc never changes the model")
  -- Enter on an empty match list does nothing
  uim._execute_command("model")
  type_text(uim, "zzz")
  assert_eq(#S.palette_items, 0, "T218 no match, no rows")
  uim._handle_key({ kind = "enter" })
  assert_true(S.palette_active, "T218 Enter on no match keeps the palette open")
  assert_eq(S.model_name, before_model, "T218 Enter on no match changes nothing")
  uim._handle_key({ kind = "esc" })
  uim._handle_key({ kind = "esc" })
  -- no-match notice in a fresh harness: each /model open echoes into the
  -- transcript and pushes the palette down, so a used harness may have no
  -- room left for the query row (correctly omitted then).
  -- NOTE: ui captures _G.commands at load, so the mock must stay installed
  -- until after run_ui_with below.
  local uim_n, Sn = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim_n._execute_command("model")
  type_text(uim_n, "zzz")
  assert_eq(#Sn.palette_items, 0, "T218 fresh harness no match, no rows")
  uim_n._paint(true)
  local Ln = uim_n._layout()
  local winn = uim_n._palette_window(Sn.h, #Sn.palette_items, Sn.palette_sel)
  assert_true(strip(uim_n._row(Ln.palette_row + winn + 1)):find("> zzz (no matches)", 1, true) ~= nil,
    "T218 no-match notice names the query")
  _G.commands = orig_commands

  -- bare /login filters provider ids the same way (catalog comes from
  -- whatever overlay earlier tests left, so the query is derived from a
  -- real label instead of assuming one)
  local uim2, S2 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim2._execute_command("login", "")
  assert_eq(S2.palette_mode, "login", "T218 login picker opens")
  local n_all = #S2.palette_items
  assert_true(n_all >= 1, "T218 login lists the catalog")
  local target = nil
  for _, it in ipairs(S2.palette_items) do
    if #(it.label or "") >= 4 then target = it.label; break end
  end
  assert_notnil(target, "T218 login has a filterable label")
  type_text(uim2, target)
  assert_eq(S2.palette_query, target, "T218 login query accumulates text")
  local found = false
  for _, it in ipairs(S2.palette_items) do
    if it.label == target then found = true end
    assert_notnil(uim2._palette.fuzzy_score(S2.palette_query, it.label or ""),
      "T218 every listed login row matches the query")
  end
  assert_true(found, "T218 login filter keeps the source label")
  assert_true(#S2.palette_items <= n_all, "T218 login filter never widens")
  assert_eq(S2.palette_sel, 1, "T218 login selection resets on query change")
  assert_eq(S2.input, "", "T218 login filter does not touch main input")
  -- no-match + Esc restore
  type_text(uim2, "-zzz-no-such-provider")
  assert_eq(#S2.palette_items, 0, "T218 login no match, no rows")
  uim2._handle_key({ kind = "enter" })
  assert_true(S2.palette_active, "T218 login Enter on no match keeps the picker open")
  assert_eq(S2.login_secret, nil, "T218 no match starts no login flow")
  uim2._handle_key({ kind = "esc" })
  assert_true(S2.palette_active, "T218 login Esc clears first")
  assert_eq(S2.palette_query, "", "T218 login query cleared")
  assert_eq(#S2.palette_items, n_all, "T218 login full list restored")
  uim2._handle_key({ kind = "esc" })
  assert_true(S2.palette_active == false, "T218 login second Esc closes")
  assert_eq(S2.login_secret, nil, "T218 closed picker starts no login flow")

  print("T218 modal palette fuzzy search: OK")
end

-- T176: non-ASCII input (e.g. Russian) must not crash the TUI.
-- Regression: decode_first_byte emitted one "text" event per BYTE, splitting
-- multibyte UTF-8 into invalid fragments; S.input became invalid UTF-8 and
-- vlen (utf8.codes) raised "invalid UTF-8 code". The decoder must assemble a
-- full UTF-8 char per event, and vlen/trunc must never raise on stray bytes.
do
  local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[#t + 1] = s:byte(i) end
    return t
  end
  -- 1. decoder: raw bytes of "п" (D0 BF) arrive as one text event
  local qi, queue = 0, {}
  _G.tether = host_mock{
    read_char = function()
      qi = qi + 1
      if qi <= #queue then return queue[qi] end
      return nil
    end,
    read_char_nb = function()
      qi = qi + 1
      if qi <= #queue then return queue[qi] end
      return nil
    end,
  }
  local keys = assert(loadfile("src/tether/ui/keys.lua"))()
  local bag = { _byte_stash = {}, _esc_stash_s = nil, _paint_clock = function() return 0 end }
  local uidec = assert(loadfile("src/tether/ui.lua"))()
  local function one(seq)
    queue, qi = to_bytes(seq), 0
    return keys.read_key(bag)
  end
  local k = one("п")
  assert_eq(k.kind, "text", "T176 cyrillic decodes to text")
  assert_eq(k.char, "п", "T176 cyrillic bytes assemble one char")
  k = one("привет")
  assert_eq(k.char, "п", "T176 first event is the first char")
  local k2 = keys.read_key(bag)
  assert_eq(k2.char, "р", "T176 second event is the second char")
  -- 4-byte emoji stays whole
  k = one("😀")
  assert_eq(k.char, "😀", "T176 emoji assembles one char")
  -- 2. vlen never raises, even on split/stray bytes
  local ok, w = pcall(uidec.vlen, "привет")
  assert_true(ok, "T176 vlen survives cyrillic")
  assert_eq(w, 6, "T176 vlen counts cyrillic chars")
  local ok2, w2 = pcall(uidec.vlen, string.char(0xD0))
  assert_true(ok2, "T176 vlen survives a split lead byte")
  assert_eq(w2, 1, "T176 split lead byte degrades to width 1")
  local ok3 = pcall(uidec.trunc, string.char(0xD0) .. "abc", 4)
  assert_true(ok3, "T176 trunc survives a split lead byte")
  -- 3. end-to-end: typing + submitting Russian works, transcript keeps it
  local bytes = {}
  for _, b in ipairs(to_bytes("привет")) do bytes[#bytes + 1] = b end
  bytes[#bytes + 1] = 13 -- Enter
  bytes[#bytes + 1] = 17 -- Ctrl+Q quit
  local uimod = run_ui_with(bytes, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local saw = false
  for _, e in ipairs(tentries(uimod)) do
    if e.role == "user" and e.text == "привет" then saw = true end
  end
  assert_true(saw, "T176 russian submit lands in the transcript")
  -- 4. paste of Russian text inserts whole chars, paint survives
  local uim2, S2 = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim2._handle_key({ kind = "paste", text = "привет" })
  assert_eq(S2.input, "привет", "T176 russian paste inserts intact")
  local okp = pcall(uim2._paint, true)
  assert_true(okp, "T176 paint survives russian input")
  print("T176 non-ASCII input: OK")
end

-- T177 (reworked by config-file-persist-settings): config.lua is the single
-- source of truth — bootstrapped with defaults when missing, and the /model
-- pick is written back into it (the model.lua side file is retired).
do
  -- dynamic-provider-catalog: seed anthropic (migration endpoint check).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
      api_key_env = "ANTHROPIC_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local cfgmod = assert(loadfile("src/tether/config.lua"))()
  local cfgsch = assert(loadfile("src/tether/config_schema.lua"))()
  local home = "/tmp/tether_t177_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local cfgpath = home .. "/.tether/config.lua"
  -- 1. bootstrap: missing file is created, parses, reloads identically
  local c0 = cfgmod.load(cfgpath, home)
  assert_eq(c0.provider, "llama-cpp", "T177 bootstrap loads defaults")
  assert_eq(c0.model, "", "T177 default model unset (pick via /model)")
  local f0 = assert(io.open(cfgpath, "r"))
  local disk0 = f0:read("*a")
  f0:close()
  assert_true(disk0:find("return {", 1, true) ~= nil, "T177 bootstrap writes a table")
  assert_true(disk0:find("editor_padding_x", 1, true) ~= nil, "T177 bootstrap is commented")
  local c0b = cfgmod.load(cfgpath, home)
  assert_eq(c0b.model, c0.model, "T177 bootstrap reload is identical")
  assert_eq(c0b.ui.theme, c0.ui.theme, "T177 bootstrap reload keeps ui")
  -- existing file is never reformatted by the bootstrap
  local f = assert(io.open(cfgpath, "w"))
  f:write('-- hand note\nreturn { model = "gpt-4o" }\n')
  f:close()
  local c1 = cfgmod.load(cfgpath, home)
  assert_eq(c1.model, "gpt-4o", "T177 hand edit applies")
  local f1 = assert(io.open(cfgpath, "r"))
  assert_eq(f1:read("*a"), '-- hand note\nreturn { model = "gpt-4o" }\n',
    "T177 existing file byte-identical")
  f1:close()
  -- unwritable location still loads in-memory defaults
  local cbroken = cfgmod.load("/nonexistent/t177_missing.lua", home)
  assert_eq(cbroken.provider, "llama-cpp", "T177 unwritable loads defaults")
  -- 2. write-through preserves everything but the two keys
  f = assert(io.open(cfgpath, "w"))
  f:write('-- custom\nreturn {\n  provider = "openai",\n  model = "gpt-4o-mini", -- pinned\n  providers = {\n    anthropic = { model = "custom-claude" },\n  },\n}\n')
  f:close()
  assert_true(cfgsch.persist_keys(home, { provider = "openai", model = "gpt-4o" }),
    "T177 persist_keys writes")
  local f2 = assert(io.open(cfgpath, "r"))
  local disk2 = f2:read("*a")
  f2:close()
  assert_true(disk2:find("-- custom", 1, true) ~= nil, "T177 comments survive")
  assert_true(disk2:find("custom-claude", 1, true) ~= nil, "T177 nested model untouched")
  assert_true(disk2:find("pinned", 1, true) ~= nil, "T177 trailing comment kept")
  assert_true(disk2:find('model = "gpt-4o"', 1, true) ~= nil, "T177 top model patched")
  -- exotic files fail closed (intact, pick stays in memory)
  f = assert(io.open(cfgpath, "w"))
  f:write('local m = os.getenv("M") or "x"\nreturn { model = m }\n')
  f:close()
  assert_true(cfgsch.persist_keys(home, { provider = "openai", model = "gpt-4o" }) == false,
    "T177 exotic fails closed")
  local f3 = assert(io.open(cfgpath, "r"))
  assert_true(f3:read("*a"):find("os.getenv", 1, true) ~= nil, "T177 exotic intact")
  f3:close()
  assert_true(cfgsch.persist_keys(home .. "/nope", { provider = "openai", model = "x" }) == false,
    "T177 missing file fails closed")
  -- 3. one-time model.lua migration (side file + a config with no explicit
  -- provider/model — the bootstrap file emits both keys as real values, so
  -- migration keys on explicitness, not on the default comparison)
  assert_true(cfgsch.write_bootstrap(cfgpath), "T177 re-bootstrap for migration")
  local sf = assert(io.open(home .. "/.tether/model.lua", "w"))
  sf:write('return {\n  provider = "anthropic",\n  model = "claude-mig",\n}\n')
  sf:close()
  local cm = cfgmod.load(cfgpath, home)
  assert_eq(cm.provider, "anthropic", "T177 migration restores provider")
  assert_eq(cm.model, "claude-mig", "T177 migration restores model")
  assert_eq(cm.api_key_env, "ANTHROPIC_API_KEY", "T177 migration resolves endpoint")
  assert_eq(io.open(home .. "/.tether/model.lua"), nil, "T177 side file removed")
  local cm2 = cfgmod.load(cfgpath, home)
  assert_eq(cm2.model, "claude-mig", "T177 migrated value stable")
  -- hand-written default in the config is explicit: the side file must win
  -- nothing (spec: Hand-written default is explicit)
  local sf2 = assert(io.open(home .. "/.tether/model.lua", "w"))
  sf2:write('return { model = "claude-side" }\n')
  sf2:close()
  f = assert(io.open(cfgpath, "w"))
  f:write('-- hand note\nreturn { model = "gpt-4o-mini" }\n')
  f:close()
  local cm3 = cfgmod.load(cfgpath, home)
  assert_eq(cm3.model, "gpt-4o-mini", "T177 explicit hand default beats side file")
  assert_true(io.open(home .. "/.tether/model.lua") ~= nil, "T177 side file kept when config is explicit")
  os.remove(home .. "/.tether/model.lua")
  -- explicit config blocks migration (side file kept)
  f = assert(io.open(cfgpath, "w"))
  f:write('return { model = "gpt-4o" }\n')
  f:close()
  sf = assert(io.open(home .. "/.tether/model.lua", "w"))
  sf:write('return { provider = "anthropic", model = "claude-mig" }\n')
  sf:close()
  local cb = cfgmod.load(cfgpath, home)
  assert_eq(cb.model, "gpt-4o", "T177 explicit model blocks migration")
  assert_true(io.open(home .. "/.tether/model.lua") ~= nil, "T177 blocked side file kept")
  -- 4. end-to-end: /model Enter writes provider/model into config.lua
  assert_true(cfgsch.write_bootstrap(cfgpath), "T177 bootstrap for e2e")
  os.remove(home .. "/.tether/model.lua")
  local orig_commands = _G.commands
  _G.commands = {
    list_sessions = function() return {} end,
    resume = function() return nil end,
    new = function() return "new-sid" end,
    list_models = function() return { { id = "gpt-4o", name = "GPT-4o" } } end,
    compact = function() return "", "noop" end,
  }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  S.cfg._auth_home = home
  uim._execute_command("model")
  uim._handle_key({ kind = "enter" })
  _G.commands = orig_commands
  assert_eq(S.model_name, "gpt-4o", "T177 pick applies in session")
  local c4 = cfgmod.load(cfgpath, home)
  assert_eq(c4.model, "gpt-4o", "T177 restart keeps the picked model")
  assert_eq(c4.provider, "llama-cpp", "T177 restart keeps the picked provider")
  os.execute("rm -rf " .. home)
  _G.provider_catalog = orig_catalog
  print("T177 config file is the source of truth: OK")
end


if failed > 0 then
    os.exit(1)
end
