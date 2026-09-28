-- tests/rows_tests.lua — tool rows/think/footer/debug/confirm/hints/picker/polish (split from lua_tests.lua, Phase C).
-- Run: lua tests/rows_tests.lua

dofile("tests/helpers.lua")
-- T209: a running tool row carries the • marker (not …), yellow while it
-- runs; the done marker stays ✓ green and the error one ✗ red.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local function head_row()
    for _, r in ipairs(uimod._render_all(80)) do
      if r:find("run", 1, true) then return r end
    end
    return nil
  end
  uimod._handle_agent_event({ type = "tool_call_start", id = "t1",
    name = "run", args = { command = "sleep 1" } })
  local head = head_row()
  assert_notnil(head, "T209 the pending run row is painted")
  assert_true(head:find("•", 1, true) ~= nil, "T209 the pending marker is •")
  assert_eq(head:find("…", 1, true), nil, "T209 the pending marker is no longer …")
  assert_true(head:find("33;1", 1, true) ~= nil, "T209 the pending marker stays yellow")
  uimod._handle_agent_event({ type = "tool_result", id = "t1",
    summary = "done", body = "" })
  head = head_row()
  assert_notnil(head, "T209 the finished run row is painted")
  assert_true(head:find("✓", 1, true) ~= nil, "T209 the done marker is still ✓")
  assert_true(head:find("32m", 1, true) ~= nil, "T209 the done marker is green")
  print("T209 run tool marker: OK")
end

-- T210: the think block carries a • marker — yellow while the model is still
-- reasoning, dim like its label once it moved on — and the expanded header
-- reads "think", never "thinking".
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local function think_row()
    for _, r in ipairs(uimod._render_all(80)) do
      if r:find("think", 1, true) then return r end
    end
    return nil
  end
  uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
  local head = think_row()
  assert_notnil(head, "T210 the think row is painted")
  assert_true(head:find("•", 1, true) ~= nil, "T210 the think row has the • marker")
  assert_true(head:find("33;1", 1, true) ~= nil, "T210 the marker is yellow while thinking")
  local joined = table.concat(uimod._render_all(80), "\n"):gsub("\27%[[0-9;]*m", "")
  assert_true(joined:find("think ·", 1, true) ~= nil, "T210 the header reads think")
  assert_eq(joined:find("thinking", 1, true), nil, "T210 no 'thinking' header anywhere")
  -- the model moved on to the answer: the marker takes the label's dim tone
  uimod._handle_agent_event({ type = "text_delta", text = "the answer" })
  head = think_row()
  assert_notnil(head, "T210 the think row survives the answer")
  assert_true(head:find("\27[2m", 1, true) ~= nil, "T210 the marker is dim once done")
  assert_eq(head:find("\27[32m", 1, true), nil, "T210 a frozen think row is never green")
  -- collapsed keeps the marker and the label
  S.thinking_visible = false
  uimod._invalidate_all()
  head = think_row()
  assert_notnil(head, "T210 the collapsed think row is painted")
  assert_true(head:find("•", 1, true) ~= nil, "T210 the collapsed row keeps the marker")
  local cplain = head:gsub("\27%[[0-9;]*m", "")
  assert_true(cplain:find("think · %d+%.%ds · %(ctrl%+t%) ▸") ~= nil,
    "T210 the collapsed header carries time and the hint")
  print("T210 think block marker and label: OK")
end

-- T211: the think block gets a blank row above and below (block gap)
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._handle_agent_event({ type = "text_delta", text = "preface" })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
  uimod._handle_agent_event({ type = "text_delta", text = "the answer" })
  local rows = uimod._render_all(80)
  local thi = nil
  for i, r in ipairs(rows) do
    if r:find("think ·", 1, true) then thi = i break end
  end
  assert_notnil(thi, "T211 the think row is painted")
  assert_eq(rows[thi - 1], "", "T211 a blank row sits above the think block")
  local thi_end = thi
  while thi_end < #rows and rows[thi_end + 1] ~= "" do thi_end = thi_end + 1 end
  assert_eq(rows[thi_end + 1], "", "T211 a blank row sits below the think block")
  print("T211 think block padding: OK")
end

-- T212: a compaction summary is wrapped like any other row. The llm body is
-- multi-paragraph text; a single unwrapped row writes past the terminal width
-- and its embedded newlines shift the screen, which is what broke the TUI.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local para = string.rep("word ", 40)
  uimod._handle_agent_event({ type = "context_compressed", mode = "llm",
    summary = "[summary]\n" .. para .. "\n\n" .. para })
  local rows = uimod._render_all(40)
  assert_true(#rows > 1, "T212 the multi-paragraph summary spans several rows")
  for _, r in ipairs(rows) do
    assert_true(uimod.vlen(r) <= 40, "T212 every summary row fits the width")
    assert_eq(r:find("\n", 1, true), nil, "T212 no row carries a raw newline")
  end
  print("T212 compaction summary wraps: OK")
end

-- T213: resume restores the tool rows the journal carries — the name and the
-- one-line summary, not a `?` marker leaking the body's first line — and a
-- resumed history that hits the compaction threshold still hands the model
-- the latest request, not the first one.
with_modules(base_env, function(mods)
  local agent, session, ui = mods.agent, mods.session, mods.ui
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local tmpdir = "/tmp/tether_t213_sessions"
  os.execute("rm -rf " .. tmpdir)
  session._session_dir = tmpdir
  local id = session.new_session("/tmp/ws", "m")
  local function msg(role, content)
    session.append(id, { ts = os.date(), type = "message", role = role, content = content })
  end
  msg("user", "first request")
  msg("assistant", "first answer")
  msg("user", "second request")
  session.append(id, { ts = os.date(), type = "tool_call", tool_call_id = "tc1",
    name = "grep", args = { pattern = "opencode" } })
  session.append(id, { ts = os.date(), type = "tool_result", tool_call_id = "tc1",
    name = "grep",
    result = { summary = "3 matches",
      body = "src/tether/providers/openai.lua:330: if provider == \"opencode\"\n"
        .. "src/tether/api.lua:150: local function extra_header_lines" } })
  msg("assistant", "second answer")
  msg("user", "latest request")
  for i = 1, 30 do
    msg("assistant", "padding answer number " .. i .. " with enough text to cross the threshold")
    msg("user", "padding request number " .. i)
  end
  msg("user", "the real latest request")

  local sid, messages = commands.resume(id)
  assert_notnil(sid, "T213 the session resumed")

  -- bug 3: the tool's name and summary survive the rebuild
  local tool_entry = nil
  for _, m in ipairs(agent.get_history()) do
    if m.role == "tool" then tool_entry = m end
  end
  assert_notnil(tool_entry, "T213 the tool result is in history")
  assert_eq(tool_entry.name, "grep", "T213 the tool name is restored")
  assert_eq(tool_entry.summary, "3 matches", "T213 the tool summary is restored")

  -- and the transcript renders the row, not a `?` leak: the -r startup seeds
  -- from the rebuilt history, so the render sees what resume put there
  local uimod, S = run_ui_with({}, {
    agent = { get_history = function() return agent.get_history() end,
      turn = function() return true end },
  })
  local plain = table.concat(uimod._render_all(80), "\n"):gsub("\27%[[0-9;]*m", "")
  assert_true(plain:find("✓ grep", 1, true) ~= nil, "T213 the row leads with the tool name")
  assert_eq(plain:find("✓ ?", 1, true), nil, "T213 no `?` marker on resume")
  assert_true(plain:find("3 matches", 1, true) ~= nil, "T213 the summary is shown")
  assert_eq(plain:find("extra_header_lines", 1, true), nil,
    "T213 the body's first line is not the summary")

  -- bug 1: a compaction run on the freshly resumed history — before the first
  -- turn re-inserts the system prompt — must not promote the first user
  -- message into the system role; that promotion is what made the model
  -- answer the session's first request instead of the latest one.
  local compacted, _, cmode = agent.compact_history(agent.get_history(),
    { workspace = "/tmp/ws", context = { keep_recent_messages = 2 } }, "k", nil, true)
  assert_true(cmode == "llm" or cmode == "truncation", "T213 compaction ran")
  assert_eq(compacted[1].role, "system", "T213 the compacted history leads with a system role")
  assert_true(type(compacted[1].content) == "string"
    and compacted[1].content:find("You are tether", 1, true) ~= nil,
    "T213 the real system prompt leads the compacted history")
  assert_eq((compacted[1].content or ""):find("the real latest request", 1, true), nil,
    "T213 a user message did not become the prompt")

  -- bug 1 (live path): compaction on the resumed history keeps the latest
  -- request last
  local seen = nil
  mods.api.stream = function(c, key, messages, on_event)
    seen = messages
    on_event({ type = "text_delta", text = "ok" })
    on_event({ type = "done", reason = "stop" })
    return true
  end
  mods.api.summarize = function() return "compacted summary" end
  agent.turn({ workspace = "/tmp/ws", _session_id = id,
      context = { max_tokens = 400, keep_recent_messages = 2 } },
    "k", "new request", function() end)
  assert_notnil(seen, "T213 the turn reached the provider")
  local has_summary = false
  for _, m in ipairs(seen) do
    if m.role == "system" and type(m.content) == "string"
      and m.content:find("summary", 1, true) then has_summary = true end
  end
  assert_true(has_summary, "T213 compaction fired on the resumed history")
  local last_user = nil
  for _, m in ipairs(seen) do
    if m.role == "user" then last_user = m.content end
  end
  assert_eq(last_user, "new request",
    "T213 the model sees the latest request, not the first")
  local first = seen[1] and seen[1].content
  assert_true(type(first) == "string" and #first > 0,
    "T213 the system prompt leads the compacted history")
  os.execute("rm -rf " .. tmpdir)
  print("T213 resume restores tools and the latest request: OK")
end)

-- T214: the think header format — collapsed `• think · Ns · (ctrl+t) ▸`,
-- expanded `• think · Ns ▾` — with a controlled clock.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
  uimod._handle_agent_event({ type = "text_delta", text = "the answer" })
  local th = nil
  for _, e in ipairs(uimod._transcript.entries()) do
    if e.role == "thinking" then th = e end
  end
  assert_notnil(th, "T214 the thinking entry exists")
  th.started_at = os.time() - 1003
  local function head()
    for _, r in ipairs(uimod._render_all(80)) do
      if r:find("think", 1, true) then return (r:gsub("\27%[[0-9;]*m", "")) end
    end
    return nil
  end
  S.thinking_visible = false
  uimod._invalidate_all()
  local c = head()
  assert_notnil(c, "T214 the collapsed header is painted")
  local csecs = c:match("think · (%d+)%.%ds · %(ctrl%+t%) ▸")
  assert_notnil(csecs, "T214 collapsed shape 'think · Ns · (ctrl+t) ▸': " .. c)
  assert_true(tonumber(csecs) >= 1003 and tonumber(csecs) <= 1004,
    "T214 collapsed shows the elapsed seconds")
  assert_eq(c:find("Ctrl+T", 1, true), nil, "T214 collapsed hint is lowercase")
  S.thinking_visible = true
  uimod._invalidate_all()
  local x = head()
  assert_notnil(x, "T214 the expanded header is painted")
  local xsecs = x:match("think · (%d+)%.%ds ▾")
  assert_notnil(xsecs, "T214 expanded shape 'think · Ns ▾': " .. x)
  assert_true(tonumber(xsecs) >= 1003 and tonumber(xsecs) <= 1004,
    "T214 expanded shows the elapsed seconds")
   print("T214 think header format: OK")
end

-- T214b: streaming caret ▌ must not be appended to a thinking row
-- (the think header already ends with ▸; appending ▌ produced ▸▌).
do
   local uimod, S = run_ui_with({ 17 },
     { agent = { turn = function() return true end, get_history = function() return {} end } })
   uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
   uimod._handle_agent_event({ type = "text_delta", text = "the answer" })
   local th = nil
   for _, e in ipairs(uimod._transcript.entries()) do
     if e.role == "thinking" then th = e end
   end
   assert_notnil(th, "T214b the thinking entry exists")
   th.started_at = os.time() - 1003
   S.thinking_visible = false
   S.streaming = true
   uimod._invalidate_all()
   uimod._paint(true)
   local think_row = nil
   for _, r in ipairs(uimod._render_all(80)) do
     local plain = r:gsub("\27%[[0-9;]*m", "")
     if plain:find("think", 1, true) then think_row = plain; break end
   end
   assert_notnil(think_row, "T214b the think row is rendered")
   assert_true(think_row:find("▌", 1, true) == nil,
     "T214b streaming caret not appended to a thinking row: " .. think_row)
   assert_true(think_row:find("▸", 1, true) ~= nil,
     "T214b think header ▸ still present: " .. think_row)
   print("T214b streaming caret not on think row: OK")
end

-- T215: every `── status ────` marker stands as its own block — the turn
-- timestamp gets a blank row below it as well as above.
do
  local bytes = { string.byte("q"), string.byte("1"), 13,
                  string.byte("q"), string.byte("2"), 13, 17 }
  local uimod, S = run_ui_with(bytes,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local rows = {}
  for _, r in ipairs(uimod._render_all(80)) do
    rows[#rows + 1] = r:gsub("\27%[[0-9;]*m", "")
  end
  local seps = {}
  for i, r in ipairs(rows) do
    if r:find("──", 1, true) then seps[#seps + 1] = i end
  end
  assert_eq(#seps, 2, "T215 two turns → two timestamp rows")
  local si = seps[2]
  assert_eq(rows[si - 1], "", "T215 a blank row sits above the timestamp")
  assert_eq(rows[si + 1], "", "T215 a blank row sits below the timestamp")
  assert_true(rows[si + 2]:find("q2", 1, true) ~= nil,
    "T215 the user row follows the bottom gap")
  print("T215 turn timestamp block gap: OK")
end

-- T216: the muted role (darker than dim) carries tool times, think times and
-- tool result counts; tool arguments stay dim.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
  uimod._handle_agent_event({ type = "tool_call_start", id = "t1", name = "read",
    args = { path = "src/x.lua" } })
  local rows = uimod._render_all(80)
  local think, pend = nil, nil
  for _, r in ipairs(rows) do
    if r:find("think ·", 1, true) then think = r end
    if r:find("read", 1, true) then pend = r end
  end
  assert_notnil(think, "T216 the think header is painted")
  assert_true(think:find("%[90m\27%[3m%d+%.%ds", 1) ~= nil,
    "T216 the think time is muted")
  assert_notnil(pend, "T216 the pending tool row is painted")
  assert_true(pend:find("%[90m%d+%.%ds", 1) ~= nil,
    "T216 the pending tool time is muted")
  assert_true(pend:find("[2msrc/x.lua", 1, true) ~= nil,
    "T216 the tool argument is dim")
  uimod._handle_agent_event({ type = "tool_result", id = "t1",
    summary = "25 matches", body = "" })
  rows = uimod._render_all(80)
  local done = nil
  for _, r in ipairs(rows) do
    if r:find("read", 1, true) then done = r end
  end
  assert_notnil(done, "T216 the done tool row is painted")
  assert_true(done:find("[90m25 matches", 1, true) ~= nil,
    "T216 the result count is muted")
  print("T216 muted times, counts and dim args: OK")
end

-- T217: resume restores think blocks and tool args — the full chain:
-- agent.turn journals them, session.resume rebuilds them, seed renders them.
with_modules(base_env, function(mods)
  local agent, session = mods.agent, mods.session
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local tmpdir = "/tmp/tether_t217_sessions"
  os.execute("rm -rf " .. tmpdir)
  session._session_dir = tmpdir
  mods.api.stream = function(c, key, messages, on_event)
    on_event({ type = "reasoning_delta", text = "planning" })
    on_event({ type = "tool_call_start", id = "c1", name = "grep" })
    on_event({ type = "tool_call_delta", id = "c1",
      arguments = '{"pattern":"opencode","path":"src"}' })
    on_event({ type = "done", reason = "tool_calls" })
    return true
  end
  mods.tools.grep = function() return { matches = {}, count = 0 } end
  agent.clear()
  local sid = session.new_session("/tmp/ws", "m")
  agent.turn({ workspace = "/tmp/ws", _session_id = sid, auto_approve = {} },
    "k", "do it", function() end)
  local rsid, messages = commands.resume(sid, "/tmp/ws", { workspace = "/tmp/ws" })
  assert_eq(rsid, sid, "T217 resume finds the session")
  local think, tool = nil, nil
  for _, m in ipairs(messages) do
    if m.role == "thinking" then think = m end
    if m.role == "tool" then tool = m end
  end
  assert_notnil(think, "T217 resume carries the reasoning")
  assert_true(think.content:find("planning", 1, true) ~= nil,
    "T217 the reasoning text survives")
  assert_notnil(tool, "T217 resume carries the tool result")
  assert_true(type(tool.args) == "table" and tool.args.pattern == "opencode",
    "T217 the tool args survive")
  -- and no thinking leaks into the model history
  for _, m in ipairs(agent.get_history()) do
    assert_true(m.role ~= "thinking", "T217 thinking stays out of history")
  end
  -- and the transcript seeds them into visible rows
  local uimod = run_ui_with({}, {
    agent = { turn = function() return true end,
      get_history = function() return {} end },
  })
  uimod._transcript.seed(messages)
  local plain = table.concat(uimod._render_all(80), "\n"):gsub("\27%[[0-9;]*m", "")
  assert_true(plain:find("think ·", 1, true) ~= nil,
    "T217 the think block is rendered")
  assert_true(plain:find("planning", 1, true) ~= nil,
    "T217 the reasoning body is rendered")
  assert_true(plain:find("opencode", 1, true) ~= nil,
    "T217 the tool arg label is rendered")
  os.execute("rm -rf " .. tmpdir)
  print("T217 resume restores think blocks and tool args: OK")
end)

-- T229: --debug log reaches the disk DURING the run, not only at exit.
-- A buffered-only handle leaves ~/.tether/log/tether.log empty mid-run, so
-- tailing it shows nothing and a kill/crash loses everything.
do
  local logpath = (os.getenv("HOME") or "/tmp") .. "/.tether/log/tether.log"
  os.remove(logpath)
  local midrun = {}
  local function sniff()
    local f = io.open(logpath, "r")
    if f then
      midrun[#midrun + 1] = f:read("*a") or ""
      f:close()
    else
      midrun[#midrun + 1] = ""
    end
  end
  -- NOTE: the stdin drain consumes all scripted bytes in one tick, so poll
  -- and write hooks also observe post-close exit writes; sniffing
  -- read_char_nb instead sees strictly pre-close disk state (the Ctrl-Q
  -- byte and the terminating nil are read after Enter was processed).
  local bytes = { 47, 99, 108, 101, 97, 114, 13, 17 } -- "/clear" Enter Ctrl-Q
  local qi = 0
  run_ui_with(bytes, {
    config = { load = function()
        return { model = "test", workspace = "/tmp", debug = true,
          ui = { input_max_lines = 8 } }
      end,
      api_key = function() return "" end },
    agent = { turn = function() return true end,
      get_history = function() return {} end },
    tether = { read_char_nb = function()
        sniff()
        qi = qi + 1
        if qi <= #bytes then return bytes[qi] end
        return nil
      end },
  })
  local seen_startup, seen_command = false, false
  for _, data in ipairs(midrun) do
    if data:find("debug log started", 1, true) then seen_startup = true end
    if data:find("command: clear", 1, true) then seen_command = true end
  end
  assert_true(seen_startup, "T229 startup line is on disk mid-run")
  assert_true(seen_command, "T229 command line is on disk mid-run")
  print("T229 debug log flushed mid-run: OK")
end

-- T251 (full-project review 2026-09-28, high): wrap-off must cut on DISPLAY
-- columns and never split an SGR sequence or a multibyte glyph. The old cut was
-- usub (character index) plus a gsub that mangled `\27[36m` into a stray `m`.
do
  local ui = assert(loadfile("src/tether/ui.lua"))()
  ui.set_wrap(false)
  local styled = "\27[36m" .. string.rep("中", 30) .. "\27[0m"
  local lines = ui.wrap_lines(styled, 10)
  assert_eq(#lines, 1, "T251 wrap=false still one line")
  local row = lines[1]
  assert_true(ui.vlen(row) <= 10, "T251 cut measured in columns, not glyphs")
  assert_true(row:find("\27[36m", 1, true) ~= nil, "T251 opening SGR stays whole")
  assert_eq(ui._strip_sgr(row):find("\27", 1, true), nil, "T251 no partial escape left")
  assert_notnil(utf8.len(ui._strip_sgr(row)), "T251 no glyph split mid-byte")
  ui.set_wrap(true)
  print("T251 wrap-off cut is width- and SGR-safe: OK")
end

-- T252: the blocking batch path combined results through a bare `combine_batch`
-- (a nil global) instead of M.combine_batch — two tasks crashed the tool call.
do
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  sub.run_batch = function(items, _ctx)
    local r = {}
    for i = 1, #items do
      r[i] = { status = "ok", exit_code = 0, output = "out" .. i,
               elapsed_ms = 1, model = "m", session_id = "s" .. i }
    end
    return r
  end
  local res, err = sub.run_call(
    { tasks = { { task = "a" }, { task = "b" } } },
    { workspace = "/ws", model = "m" })
  assert_notnil(res, "T252 batch run_call returns a result (" .. tostring(err) .. ")")
  assert_eq(res.tasks, 2, "T252 both tasks reported")
  assert_true(res.output:find("out1", 1, true) ~= nil
      and res.output:find("out2", 1, true) ~= nil, "T252 outputs in task order")
  print("T252 subagent batch path combines results: OK")
end

-- T253: `penv and A or B` read as `(penv and A) or B`, so a cloudflare-ai-gateway
-- cfg without provider_env reached `penv.CLOUDFLARE_API_KEY` on nil.
do
  local cfgm = assert(loadfile("src/tether/config.lua"))()
  local ok, key = pcall(cfgm.api_key, { provider = "cloudflare-ai-gateway" })
  assert_true(ok, "T253 api_key does not raise when provider_env is missing")
  assert_eq(key, "", "T253 keyless cloudflare-ai-gateway resolves empty")
  print("T253 cloudflare credential branch guards penv: OK")
end

-- T254 (H1): the SSE string readers are escape-aware. The old
-- '"key":"(.-[^\\])"' pattern cannot find the end of a value that finishes with
-- an escaped backslash, or of an empty value, so it ran past the real closing
-- quote and printed the JSON fields behind it as answer text.
do
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  local function texts(payload)
    local out = {}
    openai.reset_stream()
    openai.parse_sse_line('data: ' .. payload, function(ev)
      if ev.type == "text_delta" then out[#out + 1] = ev.text end
    end)
    return out
  end
  local t = texts('{"id":"1","choices":[{"index":0,"delta":{"content":"a\92\92"}}]}')
  assert_eq(#t, 1, "T254 exactly one text delta")
  assert_eq(t[1], "a\92", "T254 a value ending in an escaped backslash stays in the value")
  assert_eq(#texts('{"id":"1","choices":[{"index":0,"delta":{"content":"","role":"assistant"}}]}'),
    0, "T254 an empty value emits nothing instead of the fields behind it")
  assert_eq(texts('{"id":"1","choices":[{"index":0,"delta":{"content":"C:\92\92tmp"}}]}')[1],
    "C:\92tmp", "T254 an embedded escaped backslash decodes once")
  assert_eq(texts('{"id":"1","choices":[{"index":0,"delta":{"content":"say \92"hi\92""}}]}')[1],
    'say "hi"', "T254 escaped quotes round trip")
  print("T254 openai SSE strings are escape-aware: OK")
end

-- T255 (H1): the same escape-aware read on the other streamed adapters.
do
  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
  local codex = assert(loadfile("src/tether/providers/openai-codex.lua"))()

  local function collect(mod, line)
    local out = {}
    mod.reset_stream()
    mod.parse_sse_line(line, function(ev)
      if ev.type == "text_delta" then out[#out + 1] = ev.text end
    end)
    return out
  end

  assert_eq(collect(anthropic,
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a\92\92"}}')[1],
    "a\92", "T255 anthropic trailing escaped backslash")
  assert_eq(#collect(anthropic,
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"","x":1}}'),
    0, "T255 anthropic empty text emits nothing")
  local g = collect(gemini,
    'data: {"candidates":[{"content":{"parts":[{"text":"a\92\92"},{"text":"b\92"c\92""}],"role":"model"}}]}')
  assert_eq(#g, 2, "T255 gemini keeps both text parts")
  assert_eq(g[1], "a\92", "T255 gemini part 1 ends at its own quote")
  assert_eq(g[2], 'b"c"', "T255 gemini part 2")
  assert_eq(collect(codex,
      'data: {"type":"response.output_text.delta","delta":"end\92\92","ob":"x"}')[1],
    "end\92", "T255 codex trailing escaped backslash")
  assert_eq(#collect(codex,
      'data: {"type":"response.output_text.delta","delta":"","ob":"x"}'),
    0, "T255 codex blank frame emits nothing")
  print("T255 anthropic/gemini/codex SSE strings are escape-aware: OK")
end

-- T256 (H2): ~/.tether/auto_approve.lua is EXECUTED at startup, so storing an
-- approval is generating Lua source out of a model-chosen path. The old emitter
-- wrapped the pattern with "'"..e..'"', so a quote in the path ended the literal
-- early and the whole file stopped compiling — every grant stored before it
-- silently stopped applying.
with_modules(base_env, function(mods)
  local home = "/tmp/tether_t256_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home)
  _G.tether = host_mock{ getcwd = function() return home .. "/ws" end,
                         realpath = function(p) return p end }
  local agent, config = mods.agent, mods.config
  local p1 = agent.persist_approval("write", 'a"b.lua', home)
  assert_eq(p1, '^write:a"b%.lua$', "T256 a quote in the target stays inside one literal")
  local p2 = agent.persist_approval("write", 'dir\92name.lua', home)
  assert_eq(p2, '^write:dir\92name%.lua$', "T256 a backslash in the target survives")
  local p3 = agent.persist_approval("run", 'sh -c "echo hi"', home)
  assert_eq(p3, '^run:sh %-c "echo hi"$', "T256 a quoted command survives")
  local chunk, lerr = loadfile(home .. "/.tether/auto_approve.lua")
  assert_notnil(chunk, "T256 the generated file still compiles: " .. tostring(lerr))
  local entries = config.load_auto_approve(home)
  assert_eq(#entries, 3, "T256 all three grants load back")
  assert_eq(entries[1], p1, "T256 grant 1 keeps its content and order")
  assert_eq(entries[2], p2, "T256 grant 2 keeps its content and order")
  assert_eq(entries[3], p3, "T256 grant 3 keeps its content and order")
  assert_eq(agent.persist_approval("write", 'a"b.lua', home), p1,
    "T256 re-approving the same target returns the same pattern")
  assert_eq(#config.load_auto_approve(home), 3, "T256 re-approving does not duplicate")
  assert_eq(agent.persist_approval("write", "x.lua", nil), nil,
    "T256 no home means no write, not a crash")
  assert_eq(agent.persist_approval("write", "x.lua", ""), nil,
    "T256 an empty home is rejected")
  os.execute("rm -rf " .. home)
  print("T256 auto_approve grants round trip through the executed file: OK")
end)

-- T257 (H3): write used to report success for a path it never wrote. The bytes
-- now go through a sibling temp file and every step is checked, so targeting a
-- directory is an error — and no temp file is left behind.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t257_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws .. "/adirectory")
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return (p:gsub("/+$", "")) end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local r, err = tools.write({ path = "adirectory", content = "hello" }, { workspace = ws })
  assert_eq(r, nil, "T257 writing onto a directory fails")
  assert_true(type(err) == "string" and err:find("cannot write adirectory", 1, true) ~= nil,
    "T257 the failure names the path: " .. tostring(err))
  local leftovers = 0
  for _, name in ipairs(tether.readdir(ws) or {}) do
    if name:match("^adirectory%.tmp%.") then leftovers = leftovers + 1 end
  end
  assert_eq(leftovers, 0, "T257 the temp file is cleaned up")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T257 write reports a failed rename: OK")
end

-- T258 (H3): patch counted a file as applied when the rewritten buffer never
-- reached the disk, so the model believed the edit had landed.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t258_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws .. "/adir")
  local f = assert(io.open(ws .. "/a.txt", "w")); f:write("one\n"); f:close()
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return (p:gsub("/+$", "")) end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local r, err = tools.patch("--- a/adir\n+++ b/adir\n@@ -0,0 +1 @@\n+new\n", { workspace = ws })
  assert_eq(r, nil, "T258 a patch that cannot be written fails")
  assert_true(type(err) == "string" and err:find("cannot write adir", 1, true) ~= nil,
    "T258 patch reports the write error: " .. tostring(err))
  local r2, err2 = tools.patch("--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n one\n+two\n",
    { workspace = ws })
  assert_true(r2 ~= nil, "T258 a valid patch still applies (" .. tostring(err2) .. ")")
  assert_eq(r2.files, 1, "T258 one file applied")
  local h = assert(io.open(ws .. "/a.txt"))
  local body = h:read("*a")
  h:close()
  assert_eq(body, "one\ntwo\n", "T258 the file holds the patched bytes")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T258 patch reports a failed write: OK")
end

-- T259 (H3): run reported elapsed_ms from os.clock(), which is CPU time and
-- stalls while the host is blocked in curl or waitpid — a 30s command reported
-- 0ms. It now comes from the host's monotonic clock.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t259_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local ticks = { 1000, 3500 }
  local n = 0
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return (p:gsub("/+$", "")) end,
                         monotonic_ms = function()
                           n = n + 1
                           return ticks[n] or 3500
                         end,
                         exec = function() return true, 0 end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local r = tools.run({ command = "true", timeout = 1 }, { workspace = ws })
  assert_eq(n, 2, "T259 the clock is read before and after the command")
  assert_eq(r.elapsed_ms, 2500, "T259 elapsed_ms is wall-clock, not CPU time")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T259 run measures elapsed wall-clock: OK")
end

-- T260 (H4/M3): the truncation helpers cut on a byte budget but must never cut
-- a UTF-8 glyph in half — a body that is not valid UTF-8 is a 400 from the
-- provider, which turns a long answer into a failed request.
do
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local s = "abc" .. string.rep("\228\184\173", 4)
  assert_eq(#s, 15, "T260 the sample is 15 bytes")
  for budget = 0, #s + 3 do
    local cut = common.utf8_prefix(s, budget)
    assert_true(#cut <= budget, "T260 budget " .. budget .. " is respected")
    assert_true(utf8.len(cut) ~= nil, "T260 budget " .. budget .. " yields valid UTF-8")
    assert_true(s:sub(1, #cut) == cut, "T260 budget " .. budget .. " is a prefix")
  end
  assert_eq(common.utf8_prefix(s, 15), s, "T260 no cut when the budget fits")
  assert_eq(common.utf8_prefix("abc", 10), "abc", "T260 short input untouched")
  assert_eq(common.utf8_prefix("", 5), "", "T260 empty input")
  local bin = "\255\254\253\252\0\1"
  assert_true(#common.utf8_prefix(bin, 3) <= 3,
    "T260 non-UTF-8 input still fits the budget")
  print("T260 utf8_prefix never splits a glyph: OK")
end

-- T261 (M1): a journal line is re-parsed on resume, so it has to be valid JSON.
-- The encoder that used to live in session.lua escaped only \ " \n \r \t, so one
-- ESC from a colored tool output or a NUL from a binary read wrote a line that
-- resume dropped silently. common.json_encode escapes every C0 control.
with_modules(base_env, function(mods)
  local dir = "/tmp/tether_t261_sessions"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  mods.session._session_dir = dir
  local id = mods.session.new_session("/tmp", "test-model")
  assert_notnil(id, "T261 the session is created")
  local nasty = "a\0b\1c\127d\27[31mred\7bell\bb\ff\ttab\nnl\rCR"
  assert_true(mods.session.append(id, { type = "assistant_delta", text = nasty }),
    "T261 the journal line is appended")
  local h = assert(io.open(dir .. "/" .. id .. ".jsonl"))
  local raw = h:read("*a")
  h:close()
  local lines = {}
  for one in raw:gmatch("[^\n]+") do lines[#lines + 1] = one end
  assert_eq(#lines, 2, "T261 one line per event")
  for i, one in ipairs(lines) do
    assert_true(one:find("[%z\1-\31]") == nil,
      "T261 line " .. i .. " carries no C0 control byte besides its terminator")
  end
  local events = mods.session.read(id)
  assert_eq(#events, 2, "T261 both events decode on resume")
  assert_eq(events[2].text, nasty, "T261 the control bytes decode back exactly")
  os.execute("rm -rf " .. dir)
  print("T261 session journal lines are valid JSON: OK")
end)

-- T262 (M2): HOME is not guaranteed (env -i, a container entrypoint, a unit
-- without User=). session.lua used to concatenate nil at load, which took down
-- every command rather than just journaling. Out of process, because the suite
-- itself runs with HOME set to a temp directory.
do
  local cmd = [==[env -u HOME lua -e 'c = loadfile("src/tether/session.lua") tether = { getcwd = function() return "/tmp" end } local ok, m = pcall(c) print(ok and "NOHOME_OK" or ("NOHOME_FAIL " .. tostring(m)))']==]
  local probe = io.popen(cmd)
  local out = probe and probe:read("*a") or ""
  if probe then probe:close() end
  assert_true(out:find("NOHOME_OK", 1, true) ~= nil,
    "T262 session.lua loads with HOME removed: " .. out)
  print("T262 session.lua survives a missing HOME: OK")
end

-- T263: the retry note shortens the provider's own error text on a byte budget.
-- transcript.lua stays dependency-free, so ui injects the shared UTF-8-safe
-- cutter; the plain :sub(1, 180) it replaces could end inside a multibyte glyph
-- and glue "…" to orphaned continuation bytes.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local uimod, _ = run_ui_with({ 17 }, { agent = agent_stub })
  -- 179 bytes of ASCII, then a 3-byte glyph straddling the 180-byte budget
  uimod._handle_agent_event({ type = "retry", attempt = 1, delay = 1.0,
                              reason = "overloaded",
                              detail = string.rep("a", 179) .. "\228\184\173tail" })
  local row
  for _, e in ipairs(tentries(uimod)) do if e.role == "system" then row = e end end
  assert_notnil(row, "T263 the retry row is appended")
  assert_true(utf8.len(row.text) ~= nil, "T263 the retry line stays valid UTF-8")
  assert_true(row.text:find("tail", 1, true) == nil,
    "T263 the glyph the budget split is dropped, not half-emitted")
  assert_true(#row.text < 179 + #("overloaded") + 40, "T263 the detail stayed truncated")

  -- the cutter is the injected one, not a leftover local
  local tr = assert(loadfile("src/tether/transcript.lua"))()
  tr.configure({ cut = function(_, n) return "<" .. n .. ">" end })
  tr.handle({ type = "retry", attempt = 1, delay = 1.0, reason = "r",
              detail = string.rep("z", 200) })
  assert_true(tr.last().text:find("<180>", 1, true) ~= nil,
    "T263 transcript asks the injected cutter to do the cut")
  print("T263 retry note truncation keeps glyphs whole: OK")
end

-- T264: the resume picker probes a bounded head + tail window of each journal
-- instead of decoding every byte of up to 100 files (a long session is
-- megabytes of tool output, so opening the picker was O(all sessions)). The
-- semantics it must keep: session_start ts, the first user message, the
-- session_end workspace override, message-free sessions filtered out.
do
  local orig = _G.tether
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return p end }
  local session = assert(loadfile("src/tether/session.lua"))()
  local dir = "/tmp/tether_t264_sessions"
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir)
  session._session_dir = dir

  local start_a = '{"ts":"T-START","type":"session_start","meta":{"workspace":"/ws-a","model":"m"}}'
  local start_b = '{"ts":"T-START-B","type":"session_start","meta":{"workspace":"/ws-a","model":"m"}}'
  local user_1 = '{"ts":"U1","type":"message","role":"user","content":"first prompt"}'
  local user_2 = '{"ts":"U2","type":"message","role":"user","content":"late prompt"}'
  local end_a = '{"ts":"E1","type":"session_end","meta":{"workspace":"/ws-a","model":"m"}}'
  local end_b = '{"ts":"E2","type":"session_end","meta":{"workspace":"/ws-b","model":"m"}}'
  local big_filler = '{"ts":"F","type":"tool_result","tool_call_id":"x","content":"'
      .. string.rep("f", 200 * 1024) .. '"}'

  local function journal(name, lines)
    local f = assert(io.open(dir .. "/" .. name .. ".jsonl", "w"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
  end
  journal("aaa", { start_a, user_1, big_filler, end_a }) -- huge body, message in the head
  journal("bbb", { start_b, user_1, end_b })             -- workspace only on session_end
  journal("ccc", { start_a, end_a })                     -- never produced a message
  journal("ddd", { start_a, big_filler, user_2, end_a }) -- message past the head window

  local function by_id(files, id)
    for _, e in ipairs(files) do if e.id == id then return e end end
  end
  local function listed_ids(files)
    local t = {}
    for _, e in ipairs(files) do t[e.id] = true end
    return t
  end

  -- instrument the reads so "did it stream the whole file" is observable
  local real_open, stats = io.open, { bytes = {}, streamed = {} }
  local function counting_open(path, mode)
    local f = real_open(path, mode)
    if not f or type(path) ~= "string" or not path:find(dir, 1, true) then return f end
    local key = path:match("([^/]+)%.jsonl$")
    return setmetatable({ g_t264 = true }, { __index = function(_, k)
      if k == "read" then
        return function(_, arg)
          local data = f:read(arg or 1)
          if type(data) == "string" then
            stats.bytes[key] = (stats.bytes[key] or 0) + #data
          end
          return data
        end
      elseif k == "lines" then
        return function(_)
          stats.streamed[key] = true
          return f:lines()
        end
      elseif k == "seek" then
        return function(_, a, b) if b ~= nil then return f:seek(a, b) end return f:seek(a) end
      elseif k == "close" then
        return function(_) return f:close() end
      end
    end })
  end

  local function probe(workspace)
    for k in pairs(stats.bytes) do stats.bytes[k] = nil end
    for k in pairs(stats.streamed) do stats.streamed[k] = nil end
    io.open = counting_open
    local ok, files = pcall(session.session_files, workspace)
    io.open = real_open
    assert_true(ok, "T264 the listing does not raise: " .. tostring(files))
    return files
  end

  local a = probe("/ws-a")
  local aaa = by_id(a, "aaa")
  assert_notnil(aaa, "T264 the big journal is listed")
  assert_eq(aaa.first_line, "first prompt", "T264 the first user message is read from the head")
  assert_eq(aaa.ts, "T-START", "T264 the ts comes from session_start")
  assert_true(not stats.streamed["aaa"],
    "T264 a journal whose head answers the query is never streamed")
  assert_true((stats.bytes["aaa"] or 0) <= 64 * 1024 + 8 * 1024 + 1024,
    "T264 the read stays inside the head+tail windows, got " .. tostring(stats.bytes["aaa"]))
  assert_eq(listed_ids(a)["ccc"], nil, "T264 a session without messages stays out of the picker")

  assert_true(not listed_ids(probe("/ws-a"))["bbb"],
    "T264 a journal whose last event moved workspace is not listed under its start one")
  local b = by_id(probe("/ws-b"), "bbb")
  assert_notnil(b, "T264 the session_end workspace override is read from the tail")
  assert_eq(b.first_line, "first prompt", "T264 the override keeps the head's label")

  local d = by_id(probe("/ws-a"), "ddd")
  assert_notnil(d, "T264 the journal with a late message is still listed")
  assert_eq(d.first_line, "late prompt",
    "T264 the head window misses the message, so the full read falls back")
  assert_true(stats.streamed["ddd"], "T264 the fallback path is the one that streamed it")

  session._session_dir = nil
  _G.tether = orig
  os.execute("rm -rf " .. dir)
  print("T264 the resume picker reads bounded windows: OK")
end

-- T265: confirm-menu-redesign R1/R2/D1-D3 — the confirmation event builds
-- the state: per-tool question, four name-labeled options, no body echo for
-- run/write, cwd in the header, danger warning as the whole body, patch
-- keeps the diff.
do
  local function menu_for(name, args)
    local uim, S = run_ui_with({ 17 }, {
      agent = { turn = function() return true end, get_history = function() return {} end },
    })
    uim._handle_agent_event({ type = "confirmation",
      details = { { id = "c1", name = name, args = args } } })
    local c = S.confirmation
    assert_notnil(c, "T265 menu raised for " .. name)
    return c
  end
  local run = menu_for("run", { command = "make test" })
  assert_eq(run.question, "Allow command execution?", "T265 run question")
  assert_eq(#run.options, 4, "T265 four options")
  assert_eq(run.options[1], "[once]     allow once", "T265 once row")
  assert_eq(run.options[4], "[deny]     decline", "T265 deny row")
  assert_eq(run.body, "", "T265 run body does not echo the command")
  local wr = menu_for("write", { path = "/etc/x", content = "abc" })
  assert_eq(wr.question, "Allow writing this file?", "T265 write question")
  assert_eq(wr.body, "", "T265 write body is not shown twice")
  local pt = menu_for("patch", { patch = "+++ b/src/x.c\n@@ -1 +1 @@\n-a\n+b" })
  assert_eq(pt.question, "Allow applying this patch?", "T265 patch question")
  assert_true(pt.body:find("+++ b/src/x.c", 1, true) ~= nil, "T265 patch keeps the diff body")
  assert_eq(menu_for("subagent", { task = "x" }).question,
    "Allow this action?", "T265 fallback question")
  local cwd = menu_for("run", { command = "ls", cwd = "/tmp/outside" })
  assert_true(cwd.label:find("(cwd=/tmp/outside)", 1, true) ~= nil, "T265 cwd rides in the header")
  local dng = menu_for("run", { command = "rm -rf /tmp/xx" })
  assert_eq(dng.body, "⚠ potentially dangerous command",
    "T265 the danger warning is the whole body")
  print("T265 confirmation state: question, options, body policy: OK")
end

-- T266: confirm-menu-redesign — the painted menu rows: header, optional body
-- under it, blank, question, blank, four options, blank, muted hint; no body
-- rows when the body is empty.
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._handle_agent_event({ type = "confirmation",
    details = { { id = "c1", name = "run", args = { command = "make test" } } } })
  local function plain(rows)
    return table.concat(rows, "\n"):gsub("\27%[[%d;]*m", "")
  end
  local raw = table.concat(uim._render_all(80), "\n")
  local joined = plain(uim._render_all(80))
  local function pos(pat) local i = joined:find(pat, 1, true); return i end
  local h, q = pos("⚠ run make test"), pos("Allow command execution?")
  local o1, o4 = pos("[once]     allow once"), pos("[deny]     decline")
  local hm = pos(uim.hint_plain(uim.CONFIRM_HINT))
  assert_true(h ~= nil and q ~= nil and o1 ~= nil and o4 ~= nil and hm ~= nil,
    "T266 all menu parts painted")
  assert_true(h < q and q < o1 and o1 < o4 and o4 < hm, "T266 row order header→hint")
  -- the command is painted exactly once (header), never echoed as a body row
  assert_true(joined:find("make test", h + 10, true) == nil,
    "T266 the command shows only in the header")
  -- palette-hints: the hint row is segmented — dim key token, muted action
  -- word, joined by a plain space (pairs separated by two spaces)
  assert_true(raw:find("  " .. uim.sgr_role("dim", "↑↓") .. " " ..
    uim.sgr_role("muted", "select"), 1, true) ~= nil,
    "T266 the hint row tiers keys and actions")
  print("T266 confirmation menu layout: OK")
end

-- T267: confirm-menu-redesign hint drift guard (T228 style) — every verb
-- painted in CONFIRM_HINT must exist in the handled confirmation bindings.
do
  local ui = dofile("src/tether/ui.lua")
  local hint = ui.hint_plain(ui.CONFIRM_HINT)
  assert_true(hint:find("↑↓ select", 1, true) ~= nil, "T267 hint names the arrows")
  assert_true(hint:find("enter submit", 1, true) ~= nil, "T267 hint names enter")
  assert_true(hint:find("esc dismiss", 1, true) ~= nil, "T267 hint names esc")
  -- bindings: esc cancels, digits 1..5 and y/a/A/n resolve, arrows move the
  -- selection over the four rows. Remove a binding and a line fails.
  assert_true(ui.KEYMAP["esc"] ~= nil and ui.KEYMAP["esc"]:find("cancel", 1, true) ~= nil,
    "T267 esc is bound to confirmation cancel")
  local dm = ui.CONFIRM_DIGITS
  assert_eq(#dm, 5, "T267 five confirmation digits stay bound (5 = cancel alias)")
  assert_eq(dm[5], "cancel", "T267 digit 5 is the cancel alias")
  assert_eq(ui.KEYMAP["4"], "confirm deny", "T267 digit 4 still denies")
  print("T267 confirmation hint matches the bindings: OK")
end

-- T268: confirm-menu-redesign — cancel is not a selectable row: ↓ walks the
-- selection over exactly the four event-built options and Enter takes deny,
-- never cancel.
do
  local resolved = {}
  local orig_turn = _G.turn
  local orig_agent = _G.agent
  _G.turn = {
    confirm = function(id, dec) resolved[#resolved + 1] = dec; return true end,
    continue = function() return true end,
    start = function() return true end,
    abort = function() end,
  }
  -- resolve_confirmation gates on `detail and agent`: the agent global must
  -- survive past the harness restore (post-run driving), not leak from others.
  _G.agent = { turn = function() return true end, get_history = function() return {} end }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._handle_agent_event({ type = "confirmation",
    details = { { id = "c1", name = "run", args = { command = "ls" } } } })
  for _ = 1, 6 do uim._handle_key({ kind = "special", name = "down" }) end
  assert_eq(S.confirmation_sel, 4, "T268 down clamps at the fourth row")
  uim._handle_key({ kind = "enter" })
  assert_eq(resolved[1], "deny", "T268 Enter on the clamped row takes deny")
  _G.turn = orig_turn
  _G.agent = orig_agent
  print("T268 arrows cannot reach cancel: OK")
end

-- T269: confirm-menu-redesign — a click on the [deny] row of the painted
-- four-option menu resolves deny (prefix match survives the relabeling and
-- the trailing hint rows).
do
  local resolved = {}
  local orig_turn = _G.turn
  local orig_agent = _G.agent
  _G.turn = {
    confirm = function(id, dec) resolved[#resolved + 1] = dec; return true end,
    continue = function() return true end,
    start = function() return true end,
    abort = function() end,
  }
  -- same post-run _G.agent dependence as T268 (resolve gates on it).
  _G.agent = { turn = function() return true end, get_history = function() return {} end }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._handle_agent_event({ type = "confirmation",
    details = { { id = "c1", name = "run", args = { command = "ls" } } } })
  local L = uim._layout()
  local cw = uim._content_width(L.w)
  local total = uim._transcript.ensure_index(cw)
  -- rows from the block tail: hint, blank, then options; [once] = first option
  local idx = total - #S.confirmation.options - 1
  local bottom = math.min(total, total - S.scroll)
  if bottom < 1 then bottom = 1 end
  local top = bottom - L.transcript_h + 1
  if top < 1 then top = 1 end
  local row = L.transcript_row + (idx - top)
  uim._handle_key({ kind = "mouse", name = "press", row = row, col = 5, button = 0 })
  assert_eq(resolved[1], "allow", "T269 click on the first option row takes allow")
  uim._handle_agent_event({ type = "confirmation",
    details = { { id = "c2", name = "run", args = { command = "ls" } } } })
  local L2 = uim._layout()
  local total2 = uim._transcript.ensure_index(uim._content_width(L2.w))
  local idx2 = total2 - 2 -- deny = fourth option = tail minus blank+hint
  local bottom2 = math.min(total2, total2 - S.scroll)
  if bottom2 < 1 then bottom2 = 1 end
  local top2 = bottom2 - L2.transcript_h + 1
  if top2 < 1 then top2 = 1 end
  uim._handle_key({ kind = "mouse", name = "press",
    row = L2.transcript_row + (idx2 - top2), col = 5, button = 0 })
  assert_eq(resolved[2], "deny", "T269 click on the [deny] row takes deny")
  _G.turn = orig_turn
  _G.agent = orig_agent
  print("T269 confirmation mouse clicks map to the painted option: OK")
end

-- T270: palette-hints 1.1 — the shared segmented hint painter: plain text,
-- dim key / muted word tiers, two-space separators, ASCII twins, clipping.
do
  local ui = dofile("src/tether/ui.lua")
  local hp = { { key = "↑↓", act = "select" }, { key = "enter", act = "submit" },
               { key = "esc", act = "dismiss" } }
  assert_eq(ui.hint_plain(hp), "↑↓ select  enter submit  esc dismiss",
    "T270 plain joins pairs with two spaces")
  assert_true(ui.hint_plain(hp):find("·", 1, true) == nil, "T270 plain has no · separator")
  local painted = ui.hint_paint(hp)
  assert_eq(ui._strip_sgr(painted), ui.hint_plain(hp), "T270 painted text equals plain")
  assert_true(painted:find(ui.sgr_role("dim", "↑↓") .. " " .. ui.sgr_role("muted", "select"),
    1, true) ~= nil, "T270 key token dim, action word muted")
  -- narrow width: the row clips to the budget and still carries the tiers
  local clipped = ui.hint_paint(hp, 12)
  assert_true(ui.vlen(ui._strip_sgr(clipped)) <= 12, "T270 clipped hint fits the width")
  assert_true(clipped:find(ui.sgr_role("dim", "↑↓"), 1, true) ~= nil,
    "T270 clipping keeps the dim tier")
  -- ASCII mode routes the glyphs through the GLYPH_MAP twins
  ui._ascii_mode = true
  local ascii = ui._strip_sgr(ui.hint_paint(hp))
  assert_true(ascii:find("^v select", 1, true) ~= nil, "T270 ASCII twin for the arrows")
  assert_true(ascii:find("↑", 1, true) == nil, "T270 ASCII hint carries no non-ASCII glyph")
  ui._ascii_mode = false
  print("T270 segmented hint painter: OK")
end

-- T271: palette-hints 4.1 — per-mode hint texts match the spec table exactly.
do
  local ui = dofile("src/tether/ui.lua")
  local want = {
    command = "type filter  ↑↓ select  enter run  tab insert  esc close",
    path = "tab cycle  esc restore",
    copy = "↑↓ select  enter copy  esc close",
    resume = "↑↓ select  enter resume  esc dismiss",
    model = "type filter  ↑↓ select  enter pick  esc close",
    login = "type filter  ↑↓ select  enter connect  esc close",
    logout = "type filter  ↑↓ select  enter confirm  esc close",
    -- logout-confirm 2.4: the step has no filter buffer, so no `type` pair
    ["logout-confirm"] = "↑↓ select  enter delete  y/n choose  esc back",
    think = "↑↓ select  enter set  esc close",
  }
  for mode, text in pairs(want) do
    assert_eq(ui.hint_plain(ui.PALETTE_HINTS[mode]), text, "T271 " .. mode .. " hint text")
  end
  print("T271 per-mode palette hint texts: OK")
end

-- T272: palette-hints 4.3 — the command palette paints the indicator, then a
-- blank row, then the two-tone hint flush under the footer anchor.
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._skills_stub = function() return {} end
  uim._handle_key({ kind = "text", char = "/" })
  uim._paint(true)
  local L = uim._layout()
  local function plain(r) return uim._strip_sgr(uim._row(r) or "") end
  local hint_row = L.palette_row + L.palette_h
  assert_eq(L.footer_row, hint_row + 2, "T272 the separator and the footer follow the hint")
  assert_true(plain(hint_row + 1):find("─", 1, true) ~= nil,
    "T272 the separator rule sits between the hint and the footer")
  local hint = plain(hint_row)
  assert_true(hint:find("type filter", 1, true) ~= nil and hint:find("esc close", 1, true) ~= nil,
    "T272 command hint painted on the last region row: " .. hint)
  assert_true((uim._row(hint_row) or ""):find(
    uim.sgr_role("dim", "type") .. " " .. uim.sgr_role("muted", "filter"), 1, true) ~= nil,
    "T272 hint row tiers keys and words")
  assert_true(plain(hint_row - 1):match("^%s*$") ~= nil,
    "T272 one blank row above the hint: [" .. plain(hint_row - 1) .. "]")
  -- 10 commands over a window of 8: indicator stays directly below the entries
  assert_true(plain(L.palette_row + 9):match("^%s*1/10%s*$") ~= nil,
    "T272 the indicator keeps its slot below the painted entries")
  -- 4.4: a click on the hint or the blank row selects nothing
  uim._handle_key({ kind = "mouse", name = "press", row = hint_row, col = 5, button = 0 })
  uim._handle_key({ kind = "mouse", name = "press", row = hint_row - 1, col = 5, button = 0 })
  assert_true(S.palette_active, "T272 clicks on hint/blank leave the palette open")
  assert_eq(S.input, "/", "T272 clicks on hint/blank insert nothing")
  print("T272 command palette hint painting + click bounds: OK")
end

-- T273: palette-hints 4.3 — every dock mode paints its own hint, the modal
-- query row keeps its slot above the blank, ASCII mode keeps the row pure.
do
  local function paint_mode(mode, items, query, size)
    local uim, S = run_ui_with({ 17 }, {
      agent = { turn = function() return true end, get_history = function() return {} end },
      size = size,
    })
    S.palette_active = true
    S.palette_mode = mode
    S.palette_items = items
    S.palette_sel = 1
    if query then S.palette_query = query end
    uim._paint(true)
    local L = uim._layout()
    return uim, L, uim._strip_sgr(uim._row(L.palette_row + L.palette_h) or "")
  end
  local one = { { label = "a", desc = "d" }, { label = "b", desc = "e" } }
  local _, _, h1 = paint_mode("copy", one, nil)
  assert_true(h1:find("enter copy", 1, true) ~= nil, "T273 copy mode hint")
  local _, _, h2 = paint_mode("resume", one, nil)
  assert_true(h2:find("enter resume", 1, true) ~= nil, "T273 resume mode hint")
  local _, _, h3 = paint_mode("think", one, nil)
  assert_true(h3:find("enter set", 1, true) ~= nil, "T273 think mode hint")
  local _, _, h4 = paint_mode("path", one, nil)
  assert_true(h4:find("tab cycle", 1, true) ~= nil and h4:find("esc restore", 1, true) ~= nil,
    "T273 path completion hint")
  local _, _, h5 = paint_mode("model", one, "gp")
  assert_true(h5:find("enter pick", 1, true) ~= nil, "T273 model mode names its own verb")
  local _, _, h6 = paint_mode("login", one, "op")
  assert_true(h6:find("enter connect", 1, true) ~= nil, "T273 login mode names connect")
  local uim7, L7, h7 = paint_mode("logout", {}, "ope")
  assert_true(h7:find("enter confirm", 1, true) ~= nil, "T273 logout mode asks for a confirm")
  assert_true(uim7._strip_sgr(uim7._row(L7.palette_row + 1) or ""):find("> ope (no matches)", 1, true) ~= nil,
    "T273 the query row keeps its slot above the blank and the hint")
  -- logout-confirm 2.4/D2: the step paints its own hint and reserves no query
  -- row — a leftover query from the list must not show up under it.
  local uim8, L8, h8 = paint_mode("logout-confirm", { { label = "yes" }, { label = "no" } }, "ope")
  assert_true(h8:find("↑↓ select  enter delete  y/n choose  esc back", 1, true) ~= nil,
    "T273 the step hints the step's keys: [" .. h8 .. "]")
  assert_true(uim8._strip_sgr(uim8._row(L8.palette_row + 3) or ""):find(">", 1, true) == nil,
    "T273 the step reserves no query row")
  print("T273 per-mode dock hints paint: OK")
end

-- T274: palette-hints 4.3 — on a short terminal the entry window shrinks
-- first; the hint is the last content standing; ASCII keeps the row plain.
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    size = { width = 80, height = 12 },
  })
  uim._skills_stub = function() return {} end
  uim._handle_key({ kind = "text", char = "/" })
  uim._paint(true)
  local L = uim._layout()
  assert_true(L.palette_h >= 1, "T274 the region survives")
  assert_true(uim._strip_sgr(uim._row(L.palette_row + L.palette_h) or ""):find("esc close", 1, true) ~= nil,
    "T274 the hint survives the shrink")
  local entries = 0
  for r = L.palette_row + 1, L.palette_row + L.palette_h - 2 do
    if uim._strip_sgr(uim._row(r) or ""):find("/clear", 1, true) then entries = entries + 1 end
  end
  local w12 = uim._palette_window(S.h, #S.palette_items, S.palette_sel)
  assert_true(entries < w12, "T274 the entry window shrank before the hint dropped")
  -- ASCII mode: no non-ASCII glyph on the hint row
  local uia = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uia._ascii_mode = true
  uia._skills_stub = function() return {} end
  uia._handle_key({ kind = "text", char = "/" })
  uia._paint(true)
  local La = uia._layout()
  local ahint = uia._strip_sgr(uia._row(La.palette_row + La.palette_h) or "")
  assert_true(ahint:find("esc close", 1, true) ~= nil, "T274 ASCII hint keeps its verbs")
  assert_true(not ahint:find("[\128-\255]", 1) , "T274 ASCII hint row is pure ASCII")
  uia._ascii_mode = false
  print("T274 hint survives the window shrink: OK")
end

-- T275: footer-separator — while the palette paints, a full-width muted rule
-- runs between the hint and the footer; with the palette closed there is
-- exactly one rule (the box's bottom) and no separator row.
do
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._skills_stub = function() return {} end
  uim._handle_key({ kind = "text", char = "/" })
  uim._paint(true)
  local L = uim._layout()
  local function plain(r) return uim._strip_sgr(uim._row(r) or "") end
  assert_eq(L.separator_row, L.palette_row + L.palette_h + 1,
    "T275 the separator sits directly under the palette region")
  assert_eq(L.footer_row, L.separator_row + 1, "T275 the footer sits directly under the separator")
  local sep = plain(L.separator_row)
  assert_true(sep:find("─", 1, true) ~= nil, "T275 the separator is a rule: " .. sep)
  assert_true(sep:gsub("─", ""):match("^%s*$") ~= nil, "T275 the separator row holds only the rule")
  -- closed palette: no separator row, footer right below the box's bottom rule
  uim._handle_key({ kind = "esc" })
  uim._paint(true)
  local Lc = uim._layout()
  assert_eq(Lc.separator_row, nil, "T275 no separator while the palette is closed")
  assert_eq(Lc.footer_row, Lc.rule_bottom_row + 1, "T275 the closed dock keeps a single rule")
  -- ASCII mode downgrades the separator through the same glyph map as the rules
  local uia = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uia._ascii_mode = true
  uia._skills_stub = function() return {} end
  uia._handle_key({ kind = "text", char = "/" })
  uia._paint(true)
  local La = uia._layout()
  local asep = uia._strip_sgr(uia._row(La.separator_row) or "")
  assert_true(asep:find("-", 1, true) ~= nil and not asep:find("[\128-\255]", 1),
    "T275 ASCII separator is pure ASCII: " .. asep)
  uia._ascii_mode = false
  print("T275 footer separator rule: OK")
end

-- T276 (at-file-picker 1.3/1.4): tree-wide ranked lookup. A basename matches
-- at any depth, a slash scopes the walk, pruned and hidden trees stay out.
do
  local orig_tether = _G.tether
  local ws = "/tmp/tether_t276_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws
    .. "/src/tether/providers " .. ws .. "/tests " .. ws
    .. "/node_modules/pkg " .. ws .. "/.git " .. ws .. "/.hidden")
  local files = {
    "src/tether/ui.lua", "src/tether/quilt.lua",
    "src/tether/providers/gemini.lua",
    "tests/ui.lua", "tests/gemini_test.lua", "a.txt", ".dotfile-hidden",
    ".hidden/inside.lua",
    "node_modules/pkg/index.js", ".git/config",
  }
  for _, rel in ipairs(files) do
    local h = io.open(ws .. "/" .. rel, "w"); h:write("x\n"); h:close()
  end
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return p end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }
  local function has(list, want)
    for _, p in ipairs(list) do if p == want then return true end end
    return false
  end

  -- deep match without typing a directory, prefix ranked over subsequence,
  -- and the shorter path winning a tie (spec tui: Path completion)
  local r = tools.path_complete("ui", cfg)
  assert_eq(r.candidates[1], "tests/ui.lua", "T276 prefix match ranks first")
  assert_eq(r.candidates[2], "src/tether/ui.lua", "T276 tie breaks toward the shorter path")
  assert_eq(r.candidates[3], "src/tether/quilt.lua", "T276 interior match ranks last")
  local deep = tools.path_complete("gem", cfg)
  assert_eq(deep.candidates[1], "tests/gemini_test.lua", "T276 deep match ranks shallow first")
  assert_eq(deep.candidates[2], "src/tether/providers/gemini.lua",
    "T276 a deep file matches its basename alone")

  -- the @ prefix is a mention marker, not part of the match
  assert_eq(tools.path_complete("@gem", cfg).candidates[1], deep.candidates[1],
    "T276 @-prefixed token ranks the same")

  -- a slash scopes the walk to that directory, still recursively
  local scoped = tools.path_complete("src/tether/ui", cfg)
  assert_eq(#scoped.candidates, 2, "T276 a scoped walk stays inside the scope")
  assert_eq(scoped.candidates[1], "src/tether/ui.lua", "T276 scoped candidate is workspace-relative")
  assert_eq(scoped.candidates[2], "src/tether/quilt.lua", "T276 the scope is searched recursively")
  assert_eq(#tools.path_complete("nosuchdir/ui", cfg).candidates, 0,
    "T276 a missing scope yields nothing")

  -- directories are listed with a trailing slash so the next lookup descends
  assert_true(has(tools.path_complete("src/", cfg).candidates, "src/tether/"),
    "T276 the walk lists directories with a trailing slash")

  -- pruned and hidden trees never appear
  assert_eq(#tools.path_complete("index", cfg).candidates, 0,
    "T276 node_modules is pruned out of the walk")
  assert_eq(#tools.path_complete("conf", cfg).candidates, 0,
    "T276 .git is out of the walk")
  assert_eq(#tools.path_complete("dot", cfg).candidates, 0,
    "T276 a hidden entry needs a dot in the token")
  assert_true(has(tools.path_complete(".", cfg).candidates, ".dotfile-hidden"),
    "T276 a dotted token offers hidden entries")
  assert_eq(#tools.path_complete("inside", cfg).candidates, 0,
    "T276 a hidden directory is not entered without a dot")
  local hid = tools.path_complete(".hidden/inside", cfg)
  assert_eq(#hid.candidates, 1, "T276 a typed hidden directory scopes the walk")
  assert_eq(hid.candidates[1], ".hidden/inside.lua", "T276 typed hidden scope resolves")

  -- the workspace jail holds through the rewrite
  assert_eq(#tools.path_complete("~/.ssh", cfg).candidates, 0, "T276 ~ token refused")
  assert_eq(#tools.path_complete("/etc/passwd", cfg).candidates, 0, "T276 absolute token refused")
  assert_eq(#tools.path_complete("../../etc", cfg).candidates, 0, "T276 .. token refused")

  _G.tether = orig_tether
  os.execute("rm -rf " .. ws)
  print("T276 tree-wide ranked lookup: OK")
end

-- T277 (at-file-picker 1.2/1.3): the walk is bounded, and both truncation
-- reasons surface through the same flag.
do
  local orig_tether = _G.tether
  local ws = "/tmp/tether_t277_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  for i = 1, 250 do
    local h = io.open(ws .. "/f" .. i .. ".txt", "w"); h:write("x\n"); h:close()
  end
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return p end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }

  local capped = tools.path_complete("", cfg)
  assert_eq(#capped.candidates, 200, "T277 the candidate list is capped at 200")
  assert_true(capped.truncated, "T277 a capped list says more candidates exist")
  assert_eq(tools.path_complete("zzz", cfg).truncated, false,
    "T277 an uncapped lookup does not claim truncation")

  -- A clock that runs ahead stands in for a tree too slow to walk: the walk
  -- stops early and says so instead of finishing.
  local fake_ms = 0
  _G.tether.monotonic_ms = function() fake_ms = fake_ms + 100; return fake_ms end
  local stopped = tools.path_complete("", cfg)
  assert_true(stopped.truncated, "T277 a budget-stopped walk reports truncation")

  _G.tether = orig_tether
  os.execute("rm -rf " .. ws)
  print("T277 bounded walk: OK")
end

-- T279 (at-file-picker 3.1/3.2): one tree walk per picker session. The picker
-- re-ranks on every keystroke, so only a first call — or one whose scope
-- changed — may reach the filesystem.
do
  local orig_tether = _G.tether
  local ws = "/tmp/tether_t279_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws .. "/src/tether "
    .. ws .. "/docs")
  for _, rel in ipairs({ "src/tether/ui.lua", "src/tether/quilt.lua",
    "src/tether/agent.lua", "docs/design.md", ".hiddenconf" }) do
    local h = io.open(ws .. "/" .. rel, "w"); h:write("x\n"); h:close()
  end
  local reads = 0
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
    realpath = function(p) return p end,
    readdir = function(p) reads = reads + 1; return host_fs.readdir(p) end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }

  local opened = tools.path_complete("@", cfg)
  local after_open = reads
  assert_true(after_open > 0, "T279 opening the picker walks the tree")
  assert_notnil(opened.cache, "T279 the lookup hands back its walk")

  local again = tools.path_complete("@ui", cfg, opened.cache)
  assert_eq(reads, after_open, "T279 a longer token re-ranks the cached walk")
  assert_eq(again.candidates[1], "src/tether/ui.lua", "T279 cached ranking holds")
  assert_eq(again.cache, opened.cache, "T279 the same bundle is handed back")

  -- A session that starts fresh has nothing to reuse and walks again.
  tools.path_complete("@ui", cfg)
  assert_true(reads > after_open, "T279 an uncached lookup walks")

  -- A different scope, or a different hidden rule, is a different walk.
  reads = 0
  tools.path_complete("@src/tether/qu", cfg, again.cache)
  assert_true(reads > 0, "T279 a new scope invalidates the cached walk")
  reads = 0
  tools.path_complete("@.hidden", cfg, again.cache)
  assert_true(reads > 0, "T279 asking for hidden entries invalidates the walk")
  reads = 0
  tools.path_complete("@ui", cfg, again.cache)
  assert_eq(reads, 0, "T279 an unchanged scope stays on the cache")

  _G.tether = orig_tether
  os.execute("rm -rf " .. ws)
  print("T279 one walk per picker session: OK")
end

-- T280 (at-file-picker 3.3): the listed candidates are a snapshot. A file
-- created while the picker is open shows up only after it is reopened.
do
  local orig_tether = _G.tether
  local ws = "/tmp/tether_t280_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local h = io.open(ws .. "/mark.lua", "w"); h:write("x\n"); h:close()
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                         realpath = function(p) return p end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }

  local open = tools.path_complete("@mark", cfg)
  assert_eq(#open.candidates, 1, "T280 the open session lists what exists")
  local late = io.open(ws .. "/marked.lua", "w"); late:write("x\n"); late:close()
  local kept = tools.path_complete("@mark", cfg, open.cache)
  assert_eq(#kept.candidates, 1, "T280 a file created mid-session stays out")
  local reopened = tools.path_complete("@mark", cfg)
  assert_eq(#reopened.candidates, 2, "T280 reopening picks the new file up")

  _G.tether = orig_tether
  os.execute("rm -rf " .. ws)
  print("T280 the candidate list is a snapshot: OK")
end

-- T281 (at-file-picker 4.3): a cut candidate list says so. tools reports the
-- cut as `truncated`; the palette's counter row gains a trailing `+`, and only
-- then — an uncut list keeps the digits-and-`/` row exactly as T83 pins it.
do
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local function cfg_at(pc)
    return { config = { load = function() return {
      model = "test", workspace = "/tmp/tw/test",
      ui = { input_max_lines = 8, path_completion = pc } } end,
      api_key = function() return "" end } }
  end
  local function picker(cut)
    local stub = { path_complete = function()
      local cands = {}
      for i = 1, 4 do cands[i] = ("src/f%d.lua"):format(i) end
      return { candidates = cands, truncated = cut, cache = { n = 1 } }
    end }
    local ui_mod = assert(run_ui_with({ 17 }, cfg_at(true)))
    ui_mod._tools_stub = stub
    ui_mod._handle_key({ kind = "text", char = "@" })
    ui_mod._paint(true)
    return ui_mod, ui_mod._get_state()
  end

  local ui_mod, S = picker(true)
  assert_eq(S.completion.truncated, true, "T281 the cut is carried on the session")
  local L = ui_mod._layout()
  local row = strip(ui_mod._row(L.palette_row + #S.palette_items + 1))
  assert_true(row:match("^%s*1/4%+%s*$") ~= nil,
    "T281 a cut list shows the more-candidates marker: " .. row)

  local ui_mod2, S2 = picker(false)
  assert_eq(S2.completion.truncated, false, "T281 an uncut list carries no cut")
  local L2 = ui_mod2._layout()
  local row2 = strip(ui_mod2._row(L2.palette_row + #S2.palette_items + 1))
  assert_true(row2:find("+", 1, true) == nil,
    "T281 an uncut list paints no marker: " .. row2)

  print("T281 more-candidates marker: OK")
end

-- T282 (tool-row-overflow): a successful tool row must never exceed the width
-- it is rendered for. The head is a clipped label plus an UNCLIPPED summary
-- tail ("exit 0, 81 ms"), so a long command pushed the row past the terminal
-- edge; the terminal autowrapped the remainder onto the NEXT screen row (the
-- blank gap above the input) and the line-diff cache, which only knows
-- logical rows, never repainted that spill. Scroll invalidation covers the
-- transcript window only, so the ghost survived scrolling too.
do
  local m, _ = run_ui_with({ 17 }, {})
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local cmd = 'grep -n "require\\|LUA_MODS\\|mods\\[" Makefile | head -30; echo ---; '
    .. 'grep -rn "package\\|require" src/tether/*.lua | grep "require(" | head -40'
  local function tool_row(w)
    m._transcript.reset({})
    m._transcript.append({ role = "tool", name = "run", status = "ok",
      summary = "exit 0, 81 ms", args = { command = cmd } })
    m._invalidate_all()
    for _, r in ipairs(m._render_all(w)) do
      if strip(r):find("run", 1, true) ~= nil then return r end
    end
    return nil
  end
  for _, w in ipairs({ 60, 80, 120 }) do
    local row = tool_row(w)
    assert_notnil(row, "T282 tool row painted at width " .. w)
    assert_true(m.vlen(row) <= w,
      ("T282 tool row fits width %d, got %d: %s"):format(w, m.vlen(row), strip(row)))
  end
  -- the status tail wins over the command: it stays whole, the label is clipped
  local row = tool_row(78)
  assert_true(strip(row):find("exit 0, 81 ms", 1, true) ~= nil,
    "T282 the exit status stays visible: " .. strip(row))

  -- the sibling tails the head also rides are covered by the same budget:
  -- a pending row's elapsed counter and a write row's +N -M meter bars.
  local function fits(list, w)
    m._transcript.reset({})
    for _, e in ipairs(list) do m._transcript.append(e) end
    m._invalidate_all()
    local worst = 0
    for _, r in ipairs(m._render_all(w)) do worst = math.max(worst, m.vlen(r)) end
    return worst
  end
  local pending_w = fits({ { role = "tool", name = "run", status = "pending",
    started_at = os.time(), args = { command = cmd },
    progress = "still running the thing" } }, 60)
  assert_true(pending_w <= 60, "T282 pending row fits the width, got " .. pending_w)
  local meter_w = fits({ { role = "tool", name = "write", status = "ok",
    summary = "+9000 −9000 lines", projection = { add = 9000, del = 9000 },
    args = { path = "src/tether/ui.lua" } } }, 60)
  assert_true(meter_w <= 60, "T282 meter row fits the width, got " .. meter_w)
  print("T282 tool row never outruns the width: OK")
end

-- T283 (ui-transcript-polish 1): the `code` role is soft lavender and
-- depth-aware, so inline code stays readable on the dark window. 16-color
-- magenta ("35") was the complaint; mono must still emit no SGR.
with_modules(base_env, function(mods)
  local ui = mods.ui
  for _, name in ipairs({ "default", "solarized" }) do
    local code = ui.THEMES[name].code
    assert_eq(type(code), "table", "T283 " .. name .. " theme code role is depth-tiered")
    assert_eq(code.truecolor, "38;2;180;142;173", "T283 " .. name .. " code truecolor")
    assert_eq(code["256"], "38;5;139", "T283 " .. name .. " code 256 fallback")
  end
  ui.set_theme("default")
  ui._color_depth = "truecolor"
  assert_eq(ui.sgr_role("code", "x"), "\27[38;2;180;142;173mx\27[0m",
    "T283 truecolor inline code is lavender")
  ui._color_depth = "256"
  assert_eq(ui.sgr_role("code", "x"), "\27[38;5;139mx\27[0m",
    "T283 256-color inline code falls back to 139")
  ui.set_theme("mono")
  assert_eq(ui.sgr_role("code", "x"), "x", "T283 mono leaves code raw")
  ui.set_theme("default")
  ui._color_depth = nil
end)

-- T284 (ui-transcript-polish 2): a thinking row's glyph is warn while reasoning
-- runs and dim once frozen — a finished block is not a success, and the spec
-- forbids the success role on any thinking row.
do
  local m = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  m._color_depth = "256"
  -- collapsed header: the label is then exactly dim("think · "), so the
  -- glyph/label pair can be matched as painted
  m._get_state().thinking_visible = false
  local function think_row(live)
    m._transcript.reset({})
    m._transcript.append({ role = "thinking", text = "reasoning",
      started_at = os.time(), live = live })
    m._invalidate_all()
    for _, r in ipairs(m._render_all(80)) do
      if (r or ""):gsub("\27%[[%d;]*m", ""):find("think", 1, true) then return r end
    end
    return nil
  end
  local live = think_row(true)
  local frozen = think_row(nil)
  assert_notnil(live, "T284 a live thinking row renders")
  assert_notnil(frozen, "T284 a frozen thinking row renders")
  assert_true(live:find("\27[33;1m•", 1, true) ~= nil, "T284 live glyph is warn")
  assert_true(frozen:find("\27[2m•", 1, true) ~= nil, "T284 frozen glyph takes the dim role")
  assert_eq(frozen:find("\27[32m", 1, true), nil, "T284 no success role on a thinking row")
  assert_true(frozen:find("\27[2m•\27[0m \27[2mthink", 1, true) ~= nil,
    "T284 the glyph shares the label's tone: " .. (frozen or ""))
  assert_true(live:find("\27[33;1m•\27[0m \27[2mthink", 1, true) ~= nil,
    "T284 only the glyph changes between the states: " .. (live or ""))
  m._color_depth = nil
  print("T284 thinking glyph follows the label: OK")
end

-- T285 (ui-transcript-polish 3): the footer cell drops the slash together with
-- an unknown model — `llama-cpp · off`, never a dangling `llama-cpp/`.
do
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local uimod = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local S = uimod._get_state()
  local function footer()
    S.cfg.reasoning = "off"
    uimod._paint(true)
    return strip(uimod._row(uimod._layout().footer_row))
  end
  S.cfg.provider = "llama-cpp"
  S.model_name = "deepseek-chat"
  local f1 = footer()
  assert_true(f1:find("llama-cpp/deepseek-chat · off", 1, true) ~= nil,
    "T285 provider and model join with a slash: " .. f1)
  S.model_name = nil
  local f2 = footer()
  assert_true(f2:find("llama-cpp · off", 1, true) ~= nil,
    "T285 a bare provider carries the level: " .. f2)
  assert_eq(f2:find("llama-cpp/", 1, true), nil,
    "T285 no dangling slash without a model: " .. f2)
  assert_eq(f2:find("?", 1, true), nil,
    "T285 no placeholder model name: " .. f2)
  S.cfg.provider = nil
  S.model_name = "solo-model"
  local f3 = footer()
  assert_true(f3:find("solo-model · off", 1, true) ~= nil,
    "T285 an unknown provider keeps the bare model: " .. f3)
  print("T285 footer omits the slash with the model: OK")
end

-- T286 (ui-transcript-polish 4): skill rows drop the [skill] hint and carry the
-- mark inside the description, in the one tone the whole palette row uses.
do
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local uimod = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uimod._skills_stub = function() return {
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
  } end
  for i = 1, #"/dep" do
    uimod._handle_key({ kind = "text", char = ("/dep"):sub(i, i) })
  end
  uimod._paint(true)
  local S = uimod._get_state()
  local row
  for r = 1, S.h do
    if strip(uimod._row(r)):find("/deploy", 1, true) then row = uimod._row(r) end
  end
  assert_notnil(row, "T286 the skill row is painted")
  assert_true(strip(row):find("[s] deploy stuff", 1, true) ~= nil,
    "T286 the description carries the [s] mark: " .. strip(row))
  assert_eq(strip(row):find("[skill]", 1, true), nil, "T286 no [skill] hint left")
  -- one tone: the row is a single SGR span, so mark and description cannot
  -- diverge from the rest of the line
  local esc = 0
  for _ in row:gmatch("\27%[[%d;]*m") do esc = esc + 1 end
  assert_eq(esc, 2, "T286 mark and description share the row's tone: " .. row)
  uimod._skills_stub = nil
  print("T286 skill rows marked [s] in the description: OK")
end

-- T287 (ui-transcript-polish 5): the user's own text is markdown-lite — inline
-- markup and fenced blocks render, in the code role the assistant uses.
do
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local m = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  m._color_depth = "256"
  local function user_rows(text, w)
    m._transcript.reset({})
    m._transcript.append({ role = "user", text = text })
    m._invalidate_all()
    local out = {}
    for _, r in ipairs(m._render_all(w or 60)) do out[#out + 1] = r end
    return out
  end
  local rows = user_rows("run `npm test` **now**")
  local joined = table.concat(rows)
  local plain = strip(joined)
  assert_true(plain:find("› ", 1, true) ~= nil, "T287 the user marker stays: " .. plain)
  assert_true(joined:find("\27[38;5;139m", 1, true) ~= nil,
    "T287 user inline code takes the lavender code role")
  assert_true(joined:find("\27[1m", 1, true) ~= nil, "T287 user bold takes the bold role")
  assert_eq(plain:find("`", 1, true), nil, "T287 the backticks are consumed")
  for _, r in ipairs(rows) do
    assert_true(m.vlen(r) <= 60, "T287 user markup row fits the width: " .. strip(r))
  end

  local fenced = user_rows("```lua\nlocal x = 1\n```")
  local stripped = {}
  for _, r in ipairs(fenced) do stripped[#stripped + 1] = strip(r) end
  local fplain = table.concat(stripped, "\n")
  assert_true(strip(fenced[1] or ""):find("┌", 1, true) ~= nil,
    "T287 a user fence opens the same frame: " .. strip(fenced[1] or ""))
  assert_true(fplain:find("local x = 1", 1, true) ~= nil, "T287 the fenced body renders")
  assert_true(strip(fenced[#fenced] or ""):find("└", 1, true) ~= nil,
    "T287 the frame closes")
  for _, r in ipairs(fenced) do
    assert_true(m.vlen(r) <= 60, "T287 user fence row fits the width: " .. strip(r))
  end

  -- md_render's shared tail also tightens blank rows in user text
  local gaps = {}
  for _, r in ipairs(user_rows("a\n\n\n\nb\n\n")) do gaps[#gaps + 1] = strip(r) end
  assert_eq(#gaps, 3, "T287 blank rows collapse to one: " .. table.concat(gaps, "|"))
  assert_true(gaps[1]:find("a", 1, true) ~= nil, "T287 the first row is content")
  assert_eq(gaps[2]:find("%S"), nil, "T287 one blank row between the paragraphs")
  assert_true(gaps[3]:find("b", 1, true) ~= nil, "T287 no trailing blank row")

  -- the new user path rides the same width contract as every other producer:
  -- a row that outruns the terminal autowraps onto a screen row the line-diff
  -- cache never repaints (T282's ghost)
  local long = ("`" .. string.rep("a", 90) .. "` **bold** # not-a-heading "
    .. string.rep("tail ", 20))
  for _, w in ipairs({ 60, 80, 120 }) do
    local wide = user_rows(long, w)
    assert_true(#wide > 0, "T287 a long user message renders at width " .. w)
    for _, r in ipairs(wide) do
      assert_true(m.vlen(r) <= w,
        ("T287 user row fits width %d, got %d: %s"):format(w, m.vlen(r), strip(r)))
    end
  end
  m._color_depth = nil
  print("T287 user text renders inline markup and fences: OK")
end

-- T288 (ui-transcript-polish 5): block structure is NOT parsed in user text —
-- the row stays a faithful echo, and an unclosed fence loses nothing.
do
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local m = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  m._color_depth = "256"
  local rows = {}
  m._transcript.reset({})
  m._transcript.append({ role = "user", text =
    "# Title\n- item\n1. step\n| a | b |" })
  m._invalidate_all()
  for _, r in ipairs(m._render_all(80)) do rows[#rows + 1] = strip(r) end
  local plain = table.concat(rows, "\n")
  for _, marker in ipairs({ "# Title", "- item", "1. step", "| a | b |" }) do
    assert_true(plain:find(marker, 1, true) ~= nil,
      "T288 the marker stays literal: " .. marker .. " in " .. plain)
  end
  assert_eq(plain:find("│ a", 1, true), nil, "T288 no table frame is built")
  local joined = table.concat(m._render_all(80))
  assert_eq(joined:find("\27[36;1m", 1, true), nil, "T288 no heading role in user text")
  -- an unmatched fence frames the rest instead of swallowing it
  local unclosed = {}
  m._transcript.reset({})
  m._transcript.append({ role = "user", text = "```sh\necho hi" })
  m._invalidate_all()
  for _, r in ipairs(m._render_all(80)) do unclosed[#unclosed + 1] = strip(r) end
  local uplain = table.concat(unclosed, "\n")
  assert_true(uplain:find("echo hi", 1, true) ~= nil,
    "T288 an unclosed fence keeps its body: " .. uplain)
  for _, r in ipairs(unclosed) do
    assert_true(m.vlen(r) <= 80, "T288 unclosed fence row fits the width: " .. r)
  end
  m._color_depth = nil
  print("T288 user text keeps block markers literal: OK")
end






if failed > 0 then
    os.exit(1)
end
