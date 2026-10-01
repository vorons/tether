-- tests/session_input_tests.lua — session journal/cursor/input/history (split from lua_tests.lua, Phase C).
-- Run: lua tests/session_input_tests.lua

dofile("tests/helpers.lua")
-- T43: B2 (Lua side) — a single >8KB data: line parses into ONE complete
-- tool_call_delta (C-side accumulator is covered by host smoke + e2e).
do
  local big = string.rep("X", 20000)
  local esc = big:gsub("", ""):gsub([[%\]], [[\\\\]]):gsub('"', '\\"')
  local line = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"big",' ..
    '"function":{"name":"write","arguments":"' .. esc .. '"}}]}}]}'
  assert(#line > 8191, "T43 fixture must exceed 8191 bytes: " .. #line)
  local evs = {}
  local api = dofile("src/tether/api.lua")
  api.parse_sse_line(line, function(ev) evs[#evs + 1] = ev end)
  local args_len = 0
  for _, ev in ipairs(evs) do
    if ev.type == "tool_call_delta" and ev.arguments then args_len = #ev.arguments end
  end
  assert_eq(args_len, #big, "T43 long argument line parsed whole")
  print("T43 long SSE line: OK")
end

-- T44: F4 — journal ts must round-trip as string (os.date(), not os.date("*t"))
with_modules(base_env, function(mods)
  local agent, session = mods.agent, mods.session
  local tmpdir = "/tmp/tether_t44_sessions"
  os.execute("rm -rf " .. tmpdir)
  session._session_dir = tmpdir
  local id = session.new_session("/tmp/ws", "m")
  -- log_message path: agent.slog with a string ts
  local cfg = { _session_id = id }
  session.append(id, { ts = os.date(), type = "message", role = "user", content = "x" })
  local evs = session.read(id)
  assert_true(type(evs[#evs].ts) == "string", "T44 ts is string in journal")
  os.execute("rm -rf " .. tmpdir)
  print("T44 journal ts string: OK")
end)

-- T45: N2 — cursor placement counts display cells (vlen), not bytes.
-- The block caret (render_input/input_row_text) relies on the same
-- display-column arithmetic: vlen must count cells, not bytes.
with_modules(base_env, function(mods)
  local ui = mods.ui
  assert_notnil(ui.vlen, "T45 ui.vlen exported")
  assert_eq(ui.vlen("привет"), 6, "T45 vlen cyrillic width")
  assert_eq(ui.vlen("中"), 2, "T45 vlen wide char")
  assert_eq(ui.vlen("abc"), 3, "T45 vlen ascii identity")
  print("T45 cursor display columns: OK")
end)

-- T49: TUI input/history/error fixes (change fix-tui-input-history-error)
do
  local ui = dofile("src/tether/ui.lua")

  -- 5.1: keymap reflects the Up/Down-always-recall bindings
  local km = ui.KEYMAP
  assert_eq(km["ctrl+up"], "history prev", "T49 ctrl+up = history prev")
  assert_eq(km["ctrl+down"], "history next", "T49 ctrl+down = history next")
  assert_eq(km["up"], "history prev / cursor up (multi-line, Shift+)", "T49 up = history/cursor")
  assert_eq(km["down"], "history next / cursor down (multi-line, Shift+)", "T49 down = history/cursor")
end

-- T49b: plain Up/Down with no history leaves the input empty; Ctrl+Up with
-- empty history too. (Up/Down recall history since the user request; nothing
-- scrolls on them anymore.)

-- TK1: Right moves the caret one character right. Regression: the handler
-- set cursor = nxt - 1, which re-wrote the same position, so Right appeared
-- dead (cursor never advanced). utf8.offset returns the 1-based byte start of
-- the next character; with the 0-based cursor convention the new cursor IS
-- nxt. A mid-character cursor must not raise (utf8.offset init inside a
-- multi-byte char) — walk to the end of that character instead.
do
  local names = {"tether", "config", "session", "agent", "api"}
  local originals, preload = {}, {}
  for _, n in ipairs(names) do
    originals[n] = _G[n]; preload[n] = package.preload[n]
  end
  local function trial(bytes)
    local q, qi = {}, 0
    for _, b in ipairs(bytes) do q[#q + 1] = b end
    _G.tether = host_mock{
      write = function() end,
      resize_requested = function() return false end,
      get_terminal_size = function() return { width = 80, height = 24 } end,
      getcwd = function() return "/tmp" end,
      read_char = function() qi = qi + 1; return q[qi] or 17 end,
      read_char_nb = function() qi = qi + 1; if qi <= #q then return q[qi] end return nil end,
    }
    _G.config = { load = function()
        return { model = "test", workspace = "/tmp", ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end }
    _G.session = { new_session = function() return "sid" end }
    _G.agent = { turn = function() return true end, get_history = function() return {} end }
    _G.api = { list_models = function() return {} end }
    package.preload.tether = function() return _G.tether end
    package.preload.config = function() return _G.config end
    package.preload.session = function() return _G.session end
    package.preload.agent = function() return _G.agent end
    package.preload.api = function() return _G.api end
    local ui_mod = assert(loadfile("src/tether/ui.lua"))()
    ui_mod.run()
    local S = ui_mod._get_state()
    return S.input, S.cursor
  end
  local LEFT = { 27, 91, 68 }
  local RIGHT = { 27, 91, 67 }
  local HOME = { 27, 91, 72 }
  local function bytes(...)
    local t = {}
    for _, part in ipairs({...}) do
      if type(part) == "table" then
        for _, b in ipairs(part) do t[#t + 1] = b end
      else
        t[#t + 1] = part
      end
    end
    return t
  end

  local ok, err = pcall(function()
    -- ascii: abc, Left, Right -> back to the end (cursor 3)
    -- (string.byte returns multiple values — wrap in a table so bytes() sees one)
    local ABC = { string.byte("abc", 1, 3) }
    local inp, cur = trial(bytes(ABC, LEFT, RIGHT))
    assert_eq(inp, "abc", "TK1 input intact")
    assert_eq(cur, 3, "TK1 Right undoes Left (was stuck at 2)")
    -- two Rights from start: Home, Right -> cursor 1, Right -> 2
    local _, cur2 = trial(bytes(ABC, HOME, RIGHT, RIGHT))
    assert_eq(cur2, 2, "TK1 two Rights from home reach 2")
    -- multibyte: 'привет' Home + Right -> after 'п' = byte 2
    local cyr = "привет"
    local tb = {}
    for i = 1, #cyr do tb[#tb + 1] = cyr:byte(i) end
    local _, cur3 = trial(bytes(tb, HOME, RIGHT))
    assert_eq(cur3, 2, "TK1 Right steps a full 2-byte char (was raising or stuck)")
  end)
  for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
  if not ok then error("TK1: " .. tostring(err), 0) end
  print("TK1 right-arrow caret move: OK")
end

-- TK2: Left / Backspace / Delete must survive a mid-character cursor (a byte
-- inside a multi-byte UTF-8 char). Real trigger: multiline input with lines of
-- different widths — move_cursor_up/down carry the byte column to another line
-- where it lands inside a character (set_cursor only clamps to #ln.text). The
-- handlers used bare utf8.offset, which RAISES "initial position is a
-- continuation byte" and crashed the whole UI. Also: move_cursor_up/down must
-- snap the column to a character boundary on the destination line.
do
  local names = {"tether", "config", "session", "agent", "api"}
  local originals, preload = {}, {}
  for _, n in ipairs(names) do
    originals[n] = _G[n]; preload[n] = package.preload[n]
  end
  local function trial(bytes)
    TK2_TRIAL = (tonumber(TK2_TRIAL) or 0) + 1
    local q, qi = {}, 0
    for _, b in ipairs(bytes) do q[#q + 1] = b end
    _G.tether = host_mock{
      write = function() end,
      resize_requested = function() return false end,
      get_terminal_size = function() return { width = 80, height = 24 } end,
      getcwd = function() return "/tmp" end,
      read_char = function() qi = qi + 1; local b = q[qi] or 17; if os.getenv("TK2_DEBUG") then io.stderr:write("T" .. TK2_TRIAL .. " RD ", tostring(b), "\n") end; return b end,
      read_char_nb = function() qi = qi + 1; local b = q[qi]; if os.getenv("TK2_DEBUG") then io.stderr:write("T" .. TK2_TRIAL .. " NB ", tostring(b), "\n") end; if qi <= #q then return b end return nil end,
    }
    _G.config = { load = function()
        return { model = "test", workspace = "/tmp", ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end }
    _G.session = { new_session = function() return "sid" end }
    _G.agent = { turn = function() return true end, get_history = function() return {} end }
    _G.api = { list_models = function() return {} end }
    package.preload.tether = function() return _G.tether end
    package.preload.config = function() return _G.config end
    package.preload.session = function() return _G.session end
    package.preload.agent = function() return _G.agent end
    package.preload.api = function() return _G.api end
    local ui_mod = assert(loadfile("src/tether/ui.lua"))()
    ui_mod.run()
    local S = ui_mod._get_state()
    if os.getenv("TK2_DEBUG") then io.stderr:write("T" .. TK2_TRIAL .. " END qi=", tostring(qi), " qlen=", tostring(#q), " cursor=", tostring(S.cursor), " input=", tostring(S.input), "\n") end
    return S.input, S.cursor
  end
  local LEFT = { 27, 91, 68 }
  local UP = { 27, 91, 65 }
  local DOWN = { 27, 91, 66 }
  local END_KEY = { 27, 91, 70 }
  local HOME = { 27, 91, 72 }
  local BS = { 127 }
  local DEL = { 27, 91, 51, 126 } -- ESC [ 3 ~
  local function bytes(...)
    local t = {}
    for _, part in ipairs({...}) do
      if type(part) == "table" then
        for _, b in ipairs(part) do t[#t + 1] = b end
      else
        t[#t + 1] = part
      end
    end
    return t
  end
  local cyr = { string.byte("привет", 1, -1) }

  local ok, err = pcall(function()
    -- Left walks full characters back over 'привет': end -> 10 -> 8 -> ... -> 0
    local _, c = trial(bytes(cyr, END_KEY, LEFT, LEFT))
    assert_eq(c, 8, "TK2 Left x2 from end of cyrillic")
    -- Backspace deletes a full 2-byte char: 'привет' + BS -> 'приве', cursor 10
    local inp, c2 = trial(bytes(cyr, BS))
    assert_eq(inp, "приве", "TK2 Backspace deletes whole cyrillic char")
    assert_eq(c2, 10, "TK2 Backspace cursor after char")
    -- Delete (forward) removes the whole first char: 'привет' Home + Del -> 'ривет'
    local inp3, c3 = trial(bytes(cyr, END_KEY, HOME, DEL))
    assert_eq(inp3, "ривет", "TK2 Delete removes whole first char")
    assert_eq(c3, 0, "TK2 Delete keeps cursor")
    -- THE CRASHER: type 'abc', Ctrl+J newline, 'привет'; caret after 'c'
    -- (col 3); Up carries col 3 into the cyrillic line = a continuation byte;
    -- Left there used to RAISE inside handle_key and kill the app.
    local ABC = { string.byte("abc", 1, 3) }
    local CTRL_J = { 10 }
    local inp4, c4 = trial(bytes(ABC, CTRL_J, cyr, END_KEY, UP, DOWN, LEFT))
    assert_eq(inp4, "abc\nпривет", "TK2 input intact after up/left across lines")
    assert_true(c4 ~= nil and c4 >= 0, "TK2 cursor sane after mid-char Left")
    -- and the same for Backspace on the mid-char cursor
    local _, c5 = trial(bytes(ABC, CTRL_J, cyr, END_KEY, UP, DOWN, BS))
    assert_true(c5 ~= nil and c5 >= 0, "TK2 cursor sane after mid-char Backspace")
    -- after the mid-char Backspace the input must still be VALID utf-8
  end)
  for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
  if not ok then error("TK2: " .. tostring(err), 0) end
  print("TK2 multibyte edge cases (Left/Backspace/Delete): OK")
end
do
  local names = {"tether", "config", "session", "agent", "api"}
  local originals, preload = {}, {}
  for _, n in ipairs(names) do
    originals[n] = _G[n]; preload[n] = package.preload[n]
  end

  -- Deliver a byte queue: Ctrl+Up (ESC [ 5 ; A), then plain Up (ESC [ A),
  -- then Ctrl+Q (17) to quit. read_char_nb must feed the non-blocking path
  -- that read_key uses for the byte after ESC.
  local q = {}
  local function push(...) for _, b in ipairs{...} do q[#q + 1] = b end end
  push(27, 91, 53, 59, 65)  -- ESC [ 5 ; A  (Ctrl+Up, kitty params "5")
  push(27, 91, 65)          -- ESC [ A      (plain Up)
  push(17)                   -- Ctrl+Q
  local qi = 0
  _G.tether = host_mock{
    write = function() end,
    resize_requested = function() return false end,
    get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
    getcwd = function() return "/tmp" end,
    read_char = function()
      qi = qi + 1
      if qi <= #q then return q[qi] end
      return 17
    end,
    read_char_nb = function()
      qi = qi + 1
      if qi <= #q then return q[qi] end
      return nil
    end,
  }
  _G.config = { load = function() return { model = "test", workspace = "/tmp", ui = { input_max_lines = 8 } } end,
    api_key = function() return "" end }
  _G.session = { new_session = function() return "sid" end }
  _G.agent = { turn = function(_, _, _, on_ev) on_ev({ type = "text_delta", text = "ok" }); return true end }
  _G.api = { list_models = function() return {} end }
  package.preload.tether = function() return _G.tether end
  package.preload.config = function() return _G.config end
  package.preload.session = function() return _G.session end
  package.preload.agent = function() return _G.agent end
  package.preload.api = function() return _G.api end

  local ok, err = pcall(function()
    local ui_mod = assert(loadfile("src/tether/ui.lua"))()
    ui_mod.run()
    local S = ui_mod._get_state()
    -- input must remain empty: neither scroll nor ctrl-up inserted text
    assert_eq(S.input, "", "T49b input empty after up/ctrl-up with empty field")
  end)

  for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
  if not ok then error("T49b: " .. tostring(err), 0) end
  print("T49b scroll not insert: OK")
end

-- T220: subagent allowlist — set_tools_filter restricts the offered schema;
-- nil restores everything. The module table is shared: always reset.
do
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local function names()
    local out = {}
    for _, t in ipairs(common.tools_schema()) do out[#out + 1] = t.name end
    return out
  end
  assert_true(#names() >= 7, "T220 unfiltered schema has all tools")
  assert_true(common.set_tools_filter({ "read", "grep" }), "T220 filter accepts a list")
  local kept = names()
  assert_eq(#kept, 2, "T220 filtered schema keeps two")
  assert_eq(kept[1], "read", "T220 read kept")
  assert_eq(kept[2], "grep", "T220 grep kept")
  assert_true(common.set_tools_filter(nil), "T220 nil resets the filter")
  assert_true(#names() >= 7, "T220 reset restores all tools")
  assert_false(common.set_tools_filter("read"), "T220 non-table filter rejected")
  assert_true(#names() >= 7, "T220 rejected filter changes nothing")
  print("T220 tools allowlist filter: OK")
end

-- T223: subagent schema entry — task/tasks/model/cwd/tools/timeout params.
do
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local entry = nil
  for _, t in ipairs(common.tools_schema()) do
    if t.name == "subagent" then entry = t end
  end
  assert_notnil(entry, "T223 subagent in schema")
  local props = entry.parameters and entry.parameters.properties or {}
  assert_notnil(props.task, "T223 task param")
  assert_notnil(props.tasks, "T223 tasks param")
  assert_notnil(props.model, "T223 model param")
  assert_notnil(props.cwd, "T223 cwd param")
  assert_notnil(props.tools, "T223 tools param")
  assert_notnil(props.timeout, "T223 timeout param")
  assert_notnil(props.resume, "T223 resume param")
  assert_true(common.set_tools_filter({ "read", "subagent" }), "T223 filter keeps subagent")
  local kept = {}
  for _, t in ipairs(common.tools_schema()) do kept[#kept + 1] = t.name end
  assert_eq(#kept, 2, "T223 filtered pair")
  assert_true(common.set_tools_filter(nil), "T223 reset")
  print("T223 subagent schema entry: OK")
end

-- T224: subagent orchestrator — call/item validation, command build,
-- single-task wait (mocked host): done/timeout/cancel paths.
do
  local orig_tether, orig_tools = _G.tether, _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg)
      return abs == "/ws" or abs:sub(1, 4) == "/ws/"
    end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local ctx = { cfg = { workspace = "/ws" }, workspace = "/ws",
                model = "parent-m", timeout_default = 600, depth = 0 }
  -- normalize_call: task xor tasks
  local only, err = sub.normalize_call({ task = "do it" })
  assert_notnil(only, "T224 single task normalizes")
  assert_eq(only[1].task, "do it", "T224 task kept")
  assert_true(sub.normalize_call({}) == nil, "T224 neither errors")
  assert_true(sub.normalize_call({ task = "a", tasks = { { task = "b" } } }) == nil, "T224 both errors")
  assert_true(sub.normalize_call({ tasks = {} }) == nil, "T224 empty tasks errors")
  -- validate_item: defaults + fail-cheap checks
  local it = assert(sub.validate_item({ task = "go" }, {}, ctx))
  assert_eq(it.model, "parent-m", "T224 model falls back to parent")
  assert_eq(it.cwd, "/ws", "T224 cwd falls back to workspace")
  assert_eq(it.timeout, 600, "T224 timeout falls back to default")
  local it2 = assert(sub.validate_item(
    { task = "go", model = "m2", tools = { "read" } }, {}, ctx))
  assert_eq(it2.model, "m2", "T224 item model wins")
  assert_true(sub.validate_item({ task = "go", tools = { "teleport" } }, {}, ctx) == nil, "T224 unknown allowlist tool fails")
  assert_true(sub.validate_item({ task = "go", cwd = "/etc" }, {}, ctx) == nil, "T224 outside cwd fails before spawn")
  -- build_command shape: argv table + opts, no shell string anywhere
  local argv, opts = sub.build_command(
    { task = "fix it", model = "m", cwd = "/ws", timeout = 5 }, ctx)
  assert_eq(type(argv), "table", "T224 argv is a table")
  local pi = nil
  for i, a in ipairs(argv) do if a == "--print" then pi = i end end
  assert_notnil(pi, "T224 argv print mode")
  assert_eq(argv[pi + 1], "fix it", "T224 task glued to --print")
  assert_eq(opts.env.TETHER_SUBAGENT_DEPTH, "1", "T224 opts carries depth+1")
  local mi = nil
  for i, a in ipairs(argv) do if a == "--model" then mi = i end end
  assert_notnil(mi, "T224 argv carries model flag")
  assert_eq(argv[mi + 1], "m", "T224 argv carries model value")
  assert_eq(opts.cwd, "/ws", "T224 opts carries cwd")
  assert_true(opts.outfile ~= nil and opts.outfile ~= "", "T224 opts reserves an outfile")
  assert_eq(opts.stdin, "null", "T224 argv child detaches stdin")
  local argv2, opts2 = sub.build_command(
    { task = "- review the diff", cwd = "/ws", timeout = 5 }, ctx)
  assert_eq(type(opts2.stdin), "table",
    "T224 leading-dash task goes through a pipe")
  assert_eq(opts2.stdin.pipe, "- review the diff",
    "T224 pipe carries the exact task bytes")
  assert_eq(argv2[#argv2], "--print",
    "T224 pipe branch keeps nothing after --print")
  -- wait_task: done path with a mocked host
  local polls = 0
  _G.tether = {
    exec_bg_poll = function(h, ms)
      polls = polls + 1
      if polls < 3 then return "running" end
      return "done", 0
    end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local outpath = os.tmpname()
  local f = io.open(outpath, "w")
  f:write("hello-child")
  f:close()
  local res = sub.wait_task(
    { handle = {}, outfile = outpath, item = { model = "m" }, started_ms = 1000 }, 600)
  assert_eq(res.status, "ok", "T224 done status")
  assert_eq(res.output, "hello-child", "T224 outfile content returned")
  assert_eq(res.exit_code, 0, "T224 exit code carried")
  assert_true(io.open(outpath, "r") == nil, "T224 outfile removed")
  -- failed child with empty output names the exit code
  _G.tether = {
    exec_bg_poll = function(h, ms) return "done", 1 end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local outpath0 = os.tmpname()
  local f0 = io.open(outpath0, "w")
  f0:write("")
  f0:close()
  local res0 = sub.wait_task(
    { handle = {}, outfile = outpath0, item = { model = "m" }, started_ms = 1000 }, 600)
  assert_eq(res0.status, "error", "T224 empty failure is an error")
  assert_true(res0.output:find("subagent exited 1", 1, true) ~= nil,
    "T224 empty failure names the exit code")
  -- timeout path
  local killed = false
  _G.tether = {
    exec_bg_poll = function(h, ms) return "running" end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) killed = true return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 2000000000 end,
  }
  local outpath2 = os.tmpname()
  local res2 = sub.wait_task(
    { handle = {}, outfile = outpath2, item = {}, started_ms = 1000 }, 600)
  assert_eq(res2.status, "error", "T224 timeout is an error")
  assert_true(killed, "T224 timeout kills the group")
  assert_true(res2.output:find("timeout", 1, true) ~= nil, "T224 timeout names the limit")
  -- cancel path
  local killed2 = false
  _G.tether = {
    exec_bg_poll = function(h, ms) return "running" end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) killed2 = true return true end,
    abort_requested = function() return true end,
    monotonic_ms = function() return 1000 end,
  }
  local outpath3 = os.tmpname()
  local res3 = sub.wait_task(
    { handle = {}, outfile = outpath3, item = {}, started_ms = 1000 }, 600)
  assert_eq(res3.status, "error", "T224 cancel is an error")
  assert_true(killed2, "T224 cancel kills the group")
  assert_true(res3.output:find("cancelled", 1, true) ~= nil, "T224 cancel says cancelled")
  _G.tether, _G.tools = orig_tether, orig_tools
  print("T224 subagent single-task orchestration: OK")
end

-- T230: subagent child reuses the RUNNING binary, never a PATH shadow.
-- A foreign `tether` on PATH rejects --print with its own help (exit 2),
-- so build_command must prefer tether.exepath() over bare "tether".
do
  local orig_tether = _G.tether
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local item = { task = "go", cwd = "/ws", timeout = 5 }
  local env_bin = os.getenv("TETHER_BIN")
  local env_empty = (env_bin == nil or env_bin == "")
  -- own binary wins over PATH lookup
  _G.tether = { exepath = function() return "/opt/own/tether" end }
  if env_empty then
    local argv = sub.build_command(item, {})
    assert_eq(argv[1], "/opt/own/tether",
      "T230 child uses the running binary, not PATH")
  end
  -- explicit overrides still win: ctx.binary first ...
  local argv_custom = sub.build_command(item, { binary = "/custom/tether" })
  assert_eq(argv_custom[1], "/custom/tether",
    "T230 ctx.binary wins")
  -- ... then TETHER_BIN over exepath
  if not env_empty then
    local argv_env = sub.build_command(item, {})
    assert_true(argv_env[1]:find(env_bin, 1, true) ~= nil,
      "T230 TETHER_BIN wins over exepath")
  end
  -- no exepath primitive (plain-lua) keeps the old PATH fallback
  _G.tether = {}
  if env_empty then
    local argv_fb = sub.build_command(item, {})
    assert_eq(argv_fb[1], "tether",
      "T230 PATH fallback without exepath")
  end
  _G.tether = orig_tether
  print("T230 subagent child binary resolution: OK")
end

-- T231: the task must ride glued to --print (`--print <task>` adjacent).
-- parse_args takes the prompt from the slot right after --print unless it
-- starts with `-`; with `--print -w ... <task>` the task lands on an
-- unknown positional and is silently dropped — the child then blocks on
-- inherited stdin (hang) or exits "requires a prompt argument".
do
  local orig_tether = _G.tether
  _G.tether = {}
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local argv = sub.build_command(
    { task = "fix it", model = "m", cwd = "/ws", timeout = 5 }, {})
  local pi, wi = nil, nil
  for i, a in ipairs(argv) do
    if a == "--print" then pi = i end
    if a == "-w" then wi = i end
  end
  assert_notnil(pi, "T231 argv has --print")
  assert_eq(argv[pi + 1], "fix it",
    "T231 task immediately follows --print")
  assert_true(wi ~= nil and pi ~= nil and wi < pi,
    "T231 flags precede --print")
  local argv2 = sub.build_command(
    { task = "fix it", cwd = "/ws", timeout = 5 }, {})
  local pi2 = nil
  for i, a in ipairs(argv2) do if a == "--print" then pi2 = i end end
  assert_eq(argv2[pi2 + 1], "fix it",
    "T231 task glued without optional flags too")
  _G.tether = orig_tether
  print("T231 subagent task rides with --print: OK")
end

-- T232: bg spawn returns pending without blocking. run_call_bg validates
-- like run_call, spawns, registers, and returns immediately: no wait loop
-- (exec_bg_poll with a blocking timeout never fires), and cleanup kills
-- everything so no child outlives the call.
do
  local orig_tether, orig_tools = _G.tether, _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg) return true end,
  }
  local spawned, polls, kills, freed = 0, 0, 0, 0
  _G.tether = {
    exec_bg_argv = function(argv, opts) spawned = spawned + 1 return {} end,
    exec_bg_poll = function(h, ms)
      polls = polls + 1
      assert_true((ms or 0) == 0, "T232 bg path never blocks in poll")
      return "running"
    end,
    exec_bg_kill = function(h) kills = kills + 1 return true end,
    exec_bg_free = function(h) freed = freed + 1 return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local cfg = { model = "m", workspace = "/ws",
    subagents = { max_parallel = 4, timeout = 600, max_depth = 1 } }
  local rec = assert(sub.run_call_bg({ task = "go" }, cfg))
  assert_true(rec.pending == true, "T232 single returns pending")
  assert_true(type(rec.jobs) == "table" and type(rec.jobs[1].id) == "string",
    "T232 pending carries a job id")
  assert_eq(spawned, 1, "T232 exactly one spawn, no wait loop")
  assert_eq(polls, 0, "T232 spawn path does not poll")
  assert_eq(sub.running_count(), 1, "T232 child registered as running")
  local done = sub.cancel_all("test over")
  assert_eq(sub.running_count(), 0, "T232 cleanup empties the registry")
  assert_eq(kills, 1, "T232 cleanup kills the child")
  assert_eq(#done, 1, "T232 cleanup reports the child")
  -- validation still fail-cheap: nothing spawns on bad input
  local before = spawned
  assert_true(sub.run_call_bg({ task = "a", tasks = { { task = "b" } } }, cfg) == nil,
    "T232 task+tasks rejected")
  assert_eq(spawned, before, "T232 rejected call spawns nothing")
  _G.tether, _G.tools = orig_tether, orig_tools
  print("T232 bg spawn returns pending: OK")
end

-- T233: poll_running steps the registry without blocking. While children
-- run it reports nothing; on completion it consumes (handle freed,
-- outfile removed) and returns run-shaped results; a freed slot pulls
-- the queued head in order.
do
  local orig_tether, orig_tools = _G.tether, _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg) return true end,
  }
  local spawned, freed = 0, 0
  local phase = "running"
  _G.tether = {
    exec_bg_argv = function(argv, opts) spawned = spawned + 1 return {} end,
    exec_bg_poll = function(h, ms) return phase, 0 end,
    exec_bg_kill = function(h) return true end,
    exec_bg_free = function(h) freed = freed + 1 return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local cfg = { model = "m", workspace = "/ws",
    subagents = { max_parallel = 1, timeout = 600, max_depth = 1 } }
  local rec = assert(sub.run_call_bg(
    { tasks = { { task = "one" }, { task = "two" } } }, cfg))
  assert_eq(#rec.jobs, 1, "T233 cap 1 spawns one")
  assert_eq(spawned, 1, "T233 second task queued")
  assert_eq(#sub._queue, 1, "T233 queue holds the second")
  local function fill_outfile(id, text)
    local p = assert(sub._running[id]).pending.outfile
    local f = assert(io.open(p, "w"))
    f:write(text)
    f:close()
    return p
  end
  local p1 = fill_outfile(rec.jobs[1].id, "out-one")
  local none = sub.poll_running().completed
  assert_eq(#none, 0, "T233 running children report nothing")
  assert_eq(sub.running_count(), 1, "T233 still registered")
  phase = "done"
  local step = sub.poll_running()
  local got = step.completed
  assert_eq(#got, 1, "T233 completion reported")
  assert_eq(got[1].idx, 1, "T233 completion carries the index")
  assert_eq(got[1].result.output, "out-one", "T233 outfile content kept")
  assert_eq(got[1].result.status, "ok", "T233 result shape ok")
  assert_true(io.open(p1, "r") == nil, "T233 outfile removed")
  assert_eq(freed, 1, "T233 handle freed")
  assert_eq(spawned, 2, "T233 freed slot pulls the queued head")
  assert_eq(#step.spawned, 1, "T233 refill announced")
  assert_eq(step.spawned[1].idx, 2, "T233 refilled job carries its index")
  assert_eq(step.spawned[1].item.task, "two", "T233 refilled job carries its task")
  assert_eq(#sub._queue, 0, "T233 queue drained")
  local rest_id = nil
  for id in pairs(sub._running) do rest_id = id end
  assert_notnil(rest_id, "T233 second child registered")
  fill_outfile(rest_id, "out-two")
  local got2 = sub.poll_running().completed
  assert_eq(#got2, 1, "T233 second completion reported")
  assert_eq(got2[1].result.output, "out-two", "T233 second output kept")
  assert_eq(sub.running_count(), 0, "T233 registry empty at the end")
  _G.tether, _G.tools = orig_tether, orig_tools
  print("T233 poll_running steps the registry: OK")
end

-- T234: batch on the split API — cap respected, out-of-order finishes
-- combine by idx, abort cancels running and queued per task.
do
  local orig_tether, orig_tools = _G.tether, _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg) return true end,
  }
  local spawned, kills = 0, 0
  local live, max_live = 0, 0
  local states = {} -- handle n -> "running" | "done"
  local outtext = {}
  _G.tether = {
    exec_bg_argv = function(argv, opts)
      spawned = spawned + 1
      live = live + 1
      max_live = math.max(max_live, live)
      states[spawned] = "running"
      return { n = spawned }
    end,
    exec_bg_poll = function(h, ms)
      if states[h.n] == "done" then live = live - 1 states[h.n] = "gone" return "done", 0 end
      return "running"
    end,
    exec_bg_kill = function(h) kills = kills + 1 return true end,
    exec_bg_free = function(h) return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local cfg = { model = "m", workspace = "/ws",
    subagents = { max_parallel = 2, timeout = 600, max_depth = 1 } }
  local rec = assert(sub.run_call_bg(
    { tasks = { { task = "one" }, { task = "two" }, { task = "three" } } }, cfg))
  assert_eq(#rec.jobs, 2, "T234 cap 2 spawns two")
  assert_eq(spawned, 2, "T234 third queued")
  local function fill_all(texts)
    for id, r in pairs(sub._running) do
      local f = assert(io.open(r.pending.outfile, "w"))
      f:write(texts[r.idx])
      f:close()
    end
  end
  fill_all({ "out-one", "out-two" })
  -- finish out of order: task 2 first
  states[2] = "done"
  local c1 = sub.poll_running().completed
  assert_eq(#c1, 1, "T234 one completion")
  assert_eq(c1[1].idx, 2, "T234 first finished is task 2")
  assert_eq(spawned, 3, "T234 freed slot pulls task 3")
  fill_all({ "out-one", "out-two", "out-three" })
  states[1], states[3] = "done", "done"
  local c2 = sub.poll_running().completed
  assert_eq(#c2, 2, "T234 rest complete")
  assert_true(max_live <= 2, "T234 cap never exceeded")
  local by_idx = {}
  for _, c in ipairs(c1) do by_idx[c.idx] = c.result.output end
  for _, c in ipairs(c2) do by_idx[c.idx] = c.result.output end
  assert_eq(by_idx[1] .. "|" .. by_idx[2] .. "|" .. by_idx[3],
    "out-one|out-two|out-three", "T234 order follows idx, not finish order")
  assert_eq(sub.running_count(), 0, "T234 registry drained")
  -- abort path on a fresh batch
  local rec2 = assert(sub.run_call_bg(
    { tasks = { { task = "a" }, { task = "b" }, { task = "c" } } }, cfg))
  assert_eq(#rec2.jobs, 2, "T234 second batch spawns two")
  local cancelled = sub.cancel_all("subagent cancelled")
  assert_eq(#cancelled, 3, "T234 cancel reports running and queued")
  assert_eq(kills, 2, "T234 cancel kills running children")
  assert_eq(sub.running_count(), 0, "T234 cancel empties registry")
  assert_eq(#sub._queue, 0, "T234 cancel empties queue")
  for _, c in ipairs(cancelled) do
    assert_true(c.result.output:find("cancelled", 1, true) ~= nil,
      "T234 each cancellation names the reason")
  end
  _G.tether, _G.tools = orig_tether, orig_tools
  print("T234 batch on the split API: OK")
end

-- T236: bg pickup collapses with the standard budget. The turn parks on
-- spawn (no tool_result yet, no second LLM segment); on completion the
-- pickup records history + journal once (never for progress) with the
-- truncation marker on oversized output, while the UI event keeps it.
do
  local orig_agent = _G.agent
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local orig_sm = _G.subagent
  _G.subagent = sub
  local orig_tools = _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg) return true end,
    _workspace = function(cfg) return "/tmp/ws" end,
  }
  local polls = 0
  local phase = "running"
  local journal = {}
  local orig_session = _G.session
  _G.session = { append = function(sid, ev)
    journal[#journal + 1] = ev
  end }
  local orig_tether = _G.tether
  _G.tether = {
    exec_bg_argv = function(argv, opts) return {} end,
    exec_bg_poll = function(h, ms)
      polls = polls + 1
      if polls > 50 then return "done", 0 end -- failsafe: no test hang
      return phase, 0
    end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
    getcwd = function() return "/tmp/ws" end,
    is_tty = function() return false end,
  }
  local sub2 = _G.subagent
  local orig_spawn = sub2.spawn_task
  sub2.spawn_task = function(item, ctx)
    local p = os.tmpname()
    local f = io.open(p, "w")
    f:write(("x"):rep(20000) .. "TAIL")
    f:close()
    return { handle = {}, outfile = p, item = item, started_ms = 1000 }
  end
  local agent = assert(loadfile("src/tether/agent.lua"))()
  _G.agent = agent
  local orig_api = _G.api
  local ncalls = 0
  _G.api = { stream = function(c, key, messages, on_event)
    ncalls = ncalls + 1
    on_event({ type = "tool_call_start", id = "c1", name = "subagent" })
    on_event({ type = "tool_call_delta", id = "c1",
               arguments = '{"task":"do research"}' })
    on_event({ type = "done", reason = "tool_calls" })
    return true
  end }
  agent.clear()
  local cfg = { workspace = "/tmp/ws", model = "parent-m", _session_id = "s1" }
  local events = {}
  agent.turn(cfg, "k", "delegate it", function(ev) events[#events + 1] = ev end)
  assert_eq(ncalls, 1, "T236 turn parks on spawn, no second segment")
  local early_result = false
  for _, ev in ipairs(events) do
    if ev.type == "tool_result" and ev.id == "c1" then early_result = true end
  end
  assert_false(early_result, "T236 no tool_result before pickup")
  assert_notnil(agent.bg_calls and agent.bg_calls["c1"],
    "T236 call tracked as background")
  phase = "done"
  local completed = agent.poll_background(cfg,
    function(ev) events[#events + 1] = ev end)
  assert_eq(#completed, 1, "T236 pickup completes the call")
  local final_ev = nil
  for _, ev in ipairs(events) do
    if ev.type == "tool_result" and ev.id == "c1" then final_ev = ev end
  end
  assert_notnil(final_ev, "T236 tool_result emitted on pickup")
  assert_true((final_ev.body or ""):find("TAIL", 1, true) ~= nil,
    "T236 UI event keeps the full body")
  local hist_tools, journal_results = 0, 0
  for _, m in ipairs(agent.get_history()) do
    if m.role == "tool" and m.tool_call_id == "c1" then
      hist_tools = hist_tools + 1
      assert_true(tostring(m.content):find("…(truncated)", 1, true) ~= nil,
        "T236 history body truncated with marker")
    end
  end
  for _, ev in ipairs(journal) do
    if ev.type == "tool_result" and ev.tool_call_id == "c1" then
      journal_results = journal_results + 1
      assert_true(tostring(ev.result.body):find("…(truncated)", 1, true) ~= nil,
        "T236 journal body truncated with marker")
    end
    assert_true(ev.type ~= "tool_progress", "T236 progress never journaled")
  end
  assert_eq(hist_tools, 1, "T236 exactly one history tool result")
  assert_eq(journal_results, 1, "T236 exactly one journal tool result")
  sub2.spawn_task = orig_spawn
  _G.subagent = orig_sm
  _G.tools = orig_tools
  _G.session = orig_session
  _G.api = orig_api
  _G.agent = orig_agent
  _G.tether = orig_tether
  print("T236 bg pickup collapses with budget: OK")
end

-- T225: subagent batch — bounded parallelism, task-order combination,
-- abort cancels running and queued tasks.
do
  local orig_tether, orig_tools = _G.tether, _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg)
      return abs == "/ws" or abs:sub(1, 4) == "/ws/"
    end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local live, max_live, spawned = 0, 0, 0
  local scripts = {}
  local abort_now = false
  _G.tether = {
    exec_bg_poll = function(h, ms)
      local sc = scripts[h]
      sc.i = sc.i + 1
      if sc.i >= 2 then
        live = live - 1
        return "done", 0
      end
      return "running"
    end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) return true end,
    abort_requested = function() return abort_now end,
    monotonic_ms = function() return 1000 end,
  }
  -- spawn at the spawn_task seam: fake handles + real outfiles with content.
  local orig_spawn = sub.spawn_task
  sub.spawn_task = function(item, ctx)
    spawned = spawned + 1
    local id = spawned
    live = live + 1
    if live > max_live then max_live = live end
    local h = { id = id }
    scripts[h] = { i = 0 }
    local p = os.tmpname()
    local f = io.open(p, "w")
    f:write("out" .. id)
    f:close()
    return { handle = h, outfile = p, item = item, started_ms = 1000 }
  end
  local function mkitems(n)
    local items = {}
    for i = 1, n do
      items[i] = { task = "t" .. i, cwd = "/ws", timeout = 600 }
    end
    return items
  end
  -- outfiles are pre-created at spawn (consume reads them on completion).
  local ctx = { cfg = { workspace = "/ws" }, max_parallel = 2,
                timeout_default = 600, depth = 0 }
  local res = sub.run_batch(mkitems(3), ctx)
  assert_eq(#res, 3, "T225 three results")
  assert_eq(res[1].output, "out1", "T225 task order kept (1)")
  assert_eq(res[2].output, "out2", "T225 task order kept (2)")
  assert_eq(res[3].output, "out3", "T225 task order kept (3)")
  assert_true(max_live <= 2, "T225 concurrency respects the cap")
  assert_eq(spawned, 3, "T225 all tasks spawned")
  -- abort cancels running and queued
  live, max_live, spawned = 0, 0, 0
  scripts = {}
  abort_now = true
  local res2 = sub.run_batch(mkitems(3), ctx)
  assert_eq(#res2, 3, "T225 abort yields three results")
  for i = 1, 3 do
    assert_eq(res2[i].status, "error", "T225 aborted task errors")
    assert_true(res2[i].output:find("cancelled", 1, true) ~= nil,
      "T225 aborted task says cancelled")
  end
  assert_eq(spawned, 0, "T225 abort before spawn starts nothing")
  abort_now = false
  sub.spawn_task = orig_spawn
  _G.tether, _G.tools = orig_tether, orig_tools
  print("T225 subagent parallel batch: OK")
end

-- T226: subagent dispatch — model emits subagent, execute_tool routes to the
-- orchestrator, the child output reaches the tool result body and history.
do
  local orig_sm = _G.subagent
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  _G.subagent = sub
  -- run_call validation needs no spawn: bad input fails cheap
  local cfg0 = { workspace = "/tmp/ws", model = "m" }
  local r0, e0 = sub.run_call({}, cfg0)
  assert_true(r0 == nil, "T226 empty call fails")
  assert_true(e0:find("task", 1, true) ~= nil, "T226 error names the contract")
  local r0b = sub.run_call({ task = "x", tasks = { { task = "y" } } }, cfg0)
  assert_true(r0b == nil, "T226 task+tasks fails")
end
with_modules(base_env, function(mods)
  local api, agent = mods.api, mods.agent
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local orig_sm = _G.subagent
  _G.subagent = sub
  local orig_tools = _G.tools
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg)
      return abs == "/tmp/ws" or abs:sub(1, 8) == "/tmp/ws/"
    end,
    _workspace = function(cfg) return "/tmp/ws" end,
  }
  -- fake spawn with a real outfile; host polls done on the second round
  local orig_spawn = sub.spawn_task
  local polls = 0
  sub.spawn_task = function(item, ctx)
    local p = os.tmpname()
    local f = io.open(p, "w")
    f:write("child says hi")
    f:close()
    return { handle = {}, outfile = p, item = item, started_ms = 0 }
  end
  _G.tether.exec_bg_poll = function(h, ms)
    polls = polls + 1
    if polls < 2 then return "running" end
    return "done", 0
  end
  _G.tether.exec_bg_free = function(h) return true end
  _G.tether.exec_bg_kill = function(h) return true end
  _G.tether.abort_requested = function() return false end
  local ncalls = 0
  api.stream = function(c, key, messages, on_event)
    ncalls = ncalls + 1
    if ncalls == 1 then
      on_event({ type = "tool_call_start", id = "c1", name = "subagent" })
      on_event({ type = "tool_call_delta", id = "c1",
                 arguments = '{"task":"do research"}' })
      on_event({ type = "done", reason = "tool_calls" })
    else
      on_event({ type = "text_delta", text = "noted" })
      on_event({ type = "done", reason = "stop" })
    end
    return true
  end
  agent.clear()
  -- print mode keeps the blocking core: the whole child output lands in
  -- this turn. (Interactive dispatch parks instead — see T236.)
  local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                model = "parent-m", non_interactive = true }
  local events = {}
  agent.turn(cfg, "k", "delegate it", function(ev) events[#events + 1] = ev end)
  local saw_body = false
  for _, ev in ipairs(events) do
    if ev.type == "tool_result" and ev.name == "subagent" and ev.body
      and ev.body:find("child says hi", 1, true) then saw_body = true end
  end
  assert_true(saw_body, "T226 child output reaches the tool result")
  assert_true(ncalls >= 2, "T226 loop continues after the subagent result")
  sub.spawn_task = orig_spawn
  _G.subagent = orig_sm
  _G.tools = orig_tools
  print("T226 subagent dispatch end-to-end: OK")
end)
do
  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()

  -- shared tool schema exists once (openai format), others convert it
  local schema = openai.tools_schema()
  assert_true(#schema >= 7, "T50 openai tools schema has 7 tools")
  assert_eq(schema[1].name, "read", "T50 first tool is read")

  -- auth header content per provider (never assert key values, only shape)
  local ohl = openai.header_lines("k")
  assert_eq(#ohl, 1, "T50 openai one header line")
  assert_true(ohl[1]:find("Authorization: Bearer", 1, true) ~= nil, "T50 openai bearer")
  local ahl = anthropic.header_lines("k")
  assert_eq(#ahl, 2, "T50 anthropic two header lines")
  assert_true(ahl[1] == "x-api-key: k", "T50 anthropic x-api-key")
  assert_true(ahl[2]:find("anthropic-version", 1, true) ~= nil, "T50 anthropic version")
  for _, ln in ipairs(ahl) do
    assert_true(ln:find("Authorization", 1, true) == nil, "T50 anthropic no bearer")
  end
  assert_eq(#gemini.header_lines("k"), 0, "T50 gemini key travels via ?key=, not headers")

  -- Anthropic build_request: system extracted, tool_use/tool_result blocks
  local hist = {
    { role = "system", content = "sys" },
    { role = "user", content = "read it" },
    { role = "assistant", content = { tool_calls = { { id = "toolu_9", type = "function",
        -- M2: history stores DECODED arguments (agent.lua unescapes at echo
        -- time), so the encoder splices them verbatim — no second unescape.
        ["function"] = { name = "read", arguments = '{"path":"f.lua"}' } } } } },
    { role = "tool", tool_call_id = "toolu_9", content = "5 x" },
  }
  local abody = anthropic.build_request(hist, "claude-x", 1024)
  assert_true(abody:find('"system":"sys"', 1, true) ~= nil, "T50 anthropic system field")
  assert_true(abody:find('"type":"tool_use"', 1, true) ~= nil, "T50 anthropic tool_use block")
  assert_true(abody:find('"type":"tool_result"', 1, true) ~= nil, "T50 anthropic tool_result block")
  assert_true(abody:find('"input":{"path":"f.lua"}', 1, true) ~= nil, "T50 anthropic input spliced once")
  assert_true(abody:find('"max_tokens":1024', 1, true) ~= nil, "T50 anthropic max_tokens")

  -- Anthropic SSE: text + tool_use start + index delta + usage + stop
  anthropic.reset_stream()
  local aevs = {}
  local function aon(ev) aevs[#aevs + 1] = ev end
  anthropic.parse_sse_line('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}', aon)
  anthropic.parse_sse_line('data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read"}}', aon)
  anthropic.parse_sse_line('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path"}}', aon)
  anthropic.parse_sse_line('data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}', aon)
  anthropic.parse_sse_line('data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}', aon)
  anthropic.parse_sse_line('data: {"type":"message_stop"}', aon)
  local saw = {}
  for _, ev in ipairs(aevs) do
    saw[ev.type] = (saw[ev.type] or 0) + 1
    if ev.type == "tool_call_delta" then
      assert_eq(ev.id, "toolu_1", "T50 anthropic index delta resolves id")
    end
    if ev.type == "usage" then
      assert_eq(ev.usage.used, 15, "T50 anthropic usage sums in+out")
    end
  end
  assert_eq(saw.text_delta, 1, "T50 anthropic text_delta")
  assert_eq(saw.tool_call_start, 1, "T50 anthropic tool_call_start")
  assert_eq(saw.tool_call_delta, 1, "T50 anthropic tool_call_delta")
  assert_eq(saw.done, 1, "T50 anthropic done")

  -- Gemini build_request: contents + functionDeclarations + functionResponse
  local gbody = gemini.build_request(hist, "gemini-x")
  assert_true(gbody:find('"contents"', 1, true) ~= nil, "T50 gemini contents")
  assert_true(gbody:find('"functionCall"', 1, true) ~= nil, "T50 gemini functionCall")
  assert_true(gbody:find('"functionResponse"', 1, true) ~= nil, "T50 gemini functionResponse")
  assert_true(gbody:find('"functionDeclarations"', 1, true) ~= nil, "T50 gemini declarations")
  assert_true(gbody:find('"functionResponse":{"name":"read"', 1, true) ~= nil,
    "T50 gemini response name recovered from tool_call id")
  -- garbage args degrade to {} instead of breaking the envelope
  local bad_hist = {
    { role = "assistant", content = { tool_calls = { { id = "b1", type = "function",
        ["function"] = { name = "read", arguments = 'not json at all' } } } } },
  }
  local abad = anthropic.build_request(bad_hist, "m", nil)
  assert_true(abad:find('"input":{}', 1, true) ~= nil, "T50 anthropic garbage args -> {}")
  local gbad = gemini.build_request(bad_hist, "m")
  assert_true(gbad:find('"args":{}', 1, true) ~= nil, "T50 gemini garbage args -> {}")

  -- Gemini SSE: text + usageMetadata, functionCall -> start + raw delta
  local gevs = {}
  local function gon(ev) gevs[#gevs + 1] = ev end
  gemini.parse_sse_line('data: {"candidates":[{"content":{"parts":[{"text":"hi"}],"role":"model"}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":7}}', gon)
  gemini.parse_sse_line('data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"read","args":{"path":"a"}}}],"role":"model"}}]}', gon)
  local gsaw = {}
  for _, ev in ipairs(gevs) do
    gsaw[ev.type] = (gsaw[ev.type] or 0) + 1
    if ev.type == "usage" then assert_eq(ev.usage.used, 12, "T50 gemini usage sum") end
  end
  assert_eq(gsaw.text_delta, 1, "T50 gemini text_delta")
  assert_eq(gsaw.tool_call_start, 1, "T50 gemini tool_call_start")
  assert_eq(gsaw.tool_call_delta, 1, "T50 gemini tool_call_delta")
  -- raw-args rule: agent parses the delta exactly once
  with_modules(base_env, function(mods)
    for _, ev in ipairs(gevs) do
      if ev.type == "tool_call_delta" then
        local parsed = mods.agent.parse_args(ev.arguments)
        assert_eq(parsed.path, "a", "T50 gemini delta parses once in agent")
      end
    end
  end)
  print("T50 provider mapping: OK")
end

-- T340/T341/T342 (audit M8): Gemini streams, encodes, and extracts text.
do
  local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
  local vertex = assert(loadfile("src/tether/providers/google-vertex.lua"))()
  -- T340: the stream asks for SSE framing, so deltas arrive per line.
  local url = gemini.stream_url({ base_url = "https://gen.example" },
    "gemini-2.5-flash", "k")
  assert_true(url:find("streamGenerateContent?alt=sse&key=k", 1, true) ~= nil,
    "T340 gemini stream asks for SSE")
  local vcfg = { model = "m", _auth_style = "bearer", provider_env = {
    GOOGLE_CLOUD_PROJECT = "p", GOOGLE_CLOUD_LOCATION = "l" } }
  assert_true(vertex.stream_url(vcfg, "m", "tok"):find(
    "streamGenerateContent?alt=sse", 1, true) ~= nil,
    "T340 vertex stream asks for SSE")
  gemini.reset_stream()
  local evs = {}
  local function gon(ev) evs[#evs + 1] = ev end
  gemini.parse_sse_line(
    'data: {"candidates":[{"content":{"parts":[{"text":"a"}],"role":"model"}}]}', gon)
  assert_eq(#evs, 1, "T340 first delta arrives on its own line")
  assert_eq(evs[1].text, "a", "T340 first delta text")
  gemini.parse_sse_line(
    'data: {"candidates":[{"content":{"parts":[{"text":"b"}],"role":"model"}}]}', gon)
  assert_eq(#evs, 2, "T340 second delta streams, not one end body")
  assert_eq(evs[2].text, "b", "T340 second delta text")
  print("T340 Gemini stream asks for SSE: OK")

  -- T341: model and key are URL-encoded, not pasted raw.
  local enc = gemini.stream_url({ base_url = "https://gen.example" },
    "my model/v2", "a b+c")
  assert_true(enc:find("my%20model%2Fv2", 1, true) ~= nil,
    "T341 model segment encoded")
  assert_true(enc:find("key=a%20b%2Bc", 1, true) ~= nil,
    "T341 key query encoded")
  assert_true(enc:find(" ", 1, true) == nil, "T341 no raw blanks survive")
  print("T341 Gemini URL values are encoded: OK")

  -- T342: a functionCall arg named `text` is not answer text.
  gemini.reset_stream()
  local cevs = {}
  gemini.parse_sse_line('data: {"candidates":[{"content":{"parts":'
    .. '[{"functionCall":{"name":"write","args":{"text":"should not surface",'
    .. '"path":"a"}}}],"role":"model"}}]}',
    function(ev) cevs[#cevs + 1] = ev end)
  local saw_text, saw_call = 0, 0
  for _, ev in ipairs(cevs) do
    if ev.type == "text_delta" then saw_text = saw_text + 1 end
    if ev.type == "tool_call_start" then
      saw_call = saw_call + 1
      assert_eq(ev.name, "write", "T342 the call still starts")
    end
  end
  assert_eq(saw_text, 0, "T342 arg text never becomes answer text")
  assert_eq(saw_call, 1, "T342 the call still reaches the agent")
  -- escaped answer text still decodes once through the walk
  gemini.reset_stream()
  local tevs = {}
  gemini.parse_sse_line(
    'data: {"candidates":[{"content":{"parts":[{"text":"a\\nb"}],"role":"model"}}]}',
    function(ev) tevs[#tevs + 1] = ev end)
  assert_eq(#tevs, 1, "T342 escaped text still emits")
  assert_eq(tevs[1].text, "a\nb", "T342 escaped text decodes once")
  print("T342 tool args are not answer text: OK")
end

-- T51: dispatcher — unknown provider falls back, per-provider streams work
do
  -- dynamic-provider-catalog: the binary ships a thin bootstrap (no cloud
  -- Tier-A), so seed the merged view with the three native wires.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    ["llama-cpp"] = { wire = "openai", base_url = "http://127.0.0.1:8080/v1",
      api_key_env = "LLAMA_API_KEY", model = "", _source = "test" },
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
      api_key_env = "ANTHROPIC_API_KEY", model = "claude-x", _source = "test" },
    gemini = { wire = "gemini", base_url = "https://generativelanguage.googleapis.com",
      api_key_env = "GEMINI_API_KEY", model = "gemini-x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local api = assert(loadfile("src/tether/api.lua"))()
  assert_eq(api._provider_of({}), "llama-cpp", "T51 default provider llama-cpp")
  assert_eq(api._provider_of({ provider = "gemini" }), "gemini", "T51 gemini selected")
  assert_eq(api._provider_of({ provider = "azure" }), "llama-cpp", "T51 unknown falls back")

  local function run_stream(script, cfg)
    local old = _G.tether
    local requests = 0
    _G.tether = host_mock{
      http_stream = function(_, _, _, _, on_line)
        requests = requests + 1
        for _, line in ipairs(script[requests] or {}) do on_line(line) end
        return true
      end,
      http_get = function() return nil, "not used" end,
      sleep = function() end,
    }
    local events = {}
    local ok = api.stream(cfg, "key", { { role = "user", content = "hi" } },
      function(ev) events[#events + 1] = ev end)
    _G.tether = old
    return ok, events
  end

  -- unknown provider streams via openai path
  local ok1, ev1 = run_stream({
    [1] = { 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}' },
  }, { provider = "azure", base_url = "http://x", model = "m", retries = 1 })
  assert_true(ok1, "T51 unknown provider streams")
  local got_text = false
  for _, ev in ipairs(ev1) do if ev.type == "text_delta" and ev.text == "ok" then got_text = true end end
  assert_true(got_text, "T51 unknown provider yields text")

  -- anthropic provider end-to-end through shared transport
  local ok2, ev2 = run_stream({
    [1] = {
      'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hey"}}',
      'data: {"type":"message_stop"}',
    },
  }, { provider = "anthropic", base_url = "http://x", model = "m", retries = 1 })
  assert_true(ok2, "T51 anthropic streams")
  local got_a = false
  for _, ev in ipairs(ev2) do if ev.type == "text_delta" and ev.text == "Hey" then got_a = true end end
  assert_true(got_a, "T51 anthropic text forwarded")

  -- gemini non-SSE generateContent fallback normalizes to events
  local ok3, ev3 = run_stream({
    [1] = { '{"candidates":[{"content":{"parts":[{"text":"yo"}],"role":"model"}}]}' },
  }, { provider = "gemini", base_url = "http://x", model = "m", retries = 1 })
  assert_true(ok3, "T51 gemini fallback streams")
  local got_g = false
  for _, ev in ipairs(ev3) do if ev.type == "text_delta" and ev.text == "yo" then got_g = true end end
  assert_true(got_g, "T51 gemini fallback text forwarded")

  -- per-provider static lists differ, missing key errors
  local openai_p = assert(loadfile("src/tether/providers/openai.lua"))()
  assert_true(#api.list_models({ provider = "openai" }) >= 10, "T51 openai static list")
  assert_true(api.list_models({ provider = "anthropic" })[1]:find("claude", 1, true) ~= nil, "T51 anthropic static list")
  assert_true(api.list_models({ provider = "gemini" })[1]:find("gemini", 1, true) ~= nil, "T51 gemini static list")
  assert_eq(openai_p.static_models()[1], api.list_models({ provider = "openai" })[1],
    "T51 openai list is curated static")
  assert_eq(#api.list_models({}), 0,
    "T51 default list empty (local id, live-authoritative)")
  local _, err = api.list_models_live({ provider = "gemini", base_url = "http://x" }, "")
  assert_eq(err, "no api key", "T51 gemini live without key")

  -- multi-event stream: empty line is a boundary, both deltas forwarded
  local ok4, ev4 = run_stream({
    [1] = {
      'data: {"choices":[{"delta":{"content":"a"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":"b"},"finish_reason":"stop"}]}',
    },
  }, { provider = "openai", base_url = "http://x", model = "m", retries = 1 })
  assert_true(ok4, "T51 multi-event streams")
  local got_a, got_b = false, false
  for _, ev in ipairs(ev4) do
    if ev.type == "text_delta" and ev.text == "a" then got_a = true end
    if ev.type == "text_delta" and ev.text == "b" then got_b = true end
  end
  assert_true(got_a and got_b, "T51 both deltas survive empty-line boundary")

  -- live list with no ids -> empty model list error
  do
    local old = _G.tether
    _G.tether = host_mock{
      http_get = function() return '{"data":[]}', nil end,
      http_stream = function() return true end,
      sleep = function() end,
    }
    local res, lerr = api.list_models_live(
      { provider = "openai", base_url = "http://x" }, "key")
    _G.tether = old
    assert_eq(res, nil, "T51 empty list returns nil")
    assert_eq(lerr, "empty model list", "T51 empty list reason")
  end
  _G.provider_catalog = orig_catalog
  print("T51 dispatcher: OK")
end

-- T52: config providers table resolution
do
  -- dynamic-provider-catalog: seed the merged view (thin bootstrap has no
  -- cloud Tier-A); config captures _G.provider_catalog at load.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    ["llama-cpp"] = { wire = "openai", base_url = "http://127.0.0.1:8080/v1",
      api_key_env = "LLAMA_API_KEY", model = "", _source = "test" },
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
      api_key_env = "ANTHROPIC_API_KEY", model = "claude-x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local cfgm = dofile("src/tether/config.lua")
  local p1 = "/tmp/tether_cfg_t52_a.lua"
  local f = io.open(p1, "w")
  f:write('return { provider = "anthropic", providers = { anthropic = { model = "claude-x" } } }')
  f:close()
  local c1 = cfgm.load(p1)
  assert_eq(c1.provider, "anthropic", "T52 provider kept")
  assert_eq(c1.base_url, "https://api.anthropic.com", "T52 anthropic base default")
  assert_eq(c1.model, "claude-x", "T52 per-provider model wins")
  assert_eq(c1.api_key_env, "ANTHROPIC_API_KEY", "T52 per-provider env")
  os.remove(p1)

  -- legacy top-level keys keep working (custom proxy safe)
  local p2 = "/tmp/tether_cfg_t52_b.lua"
  f = io.open(p2, "w")
  f:write('return { api_key_env = "FOO_KEY", base_url = "http://proxy:8080/v1" }')
  f:close()
  local c2 = cfgm.load(p2)
  assert_eq(c2.provider, "llama-cpp", "T52 default provider")
  assert_eq(c2.api_key_env, "FOO_KEY", "T52 legacy env kept")
  assert_eq(c2.base_url, "http://proxy:8080/v1", "T52 custom proxy kept")
  os.remove(p2)

  -- api_key reads the resolved variable: existing var yields value,
  -- missing var yields "" (never an error)
  local p3 = "/tmp/tether_cfg_t52_c.lua"
  f = io.open(p3, "w")
  f:write('return { api_key_env = "HOME" }')
  f:close()
  local c3 = cfgm.load(p3)
  assert_eq(cfgm.api_key(c3), os.getenv("HOME"), "T52 key read from custom env var")
  os.remove(p3)
  assert_eq(cfgm.api_key({ api_key_env = "TETHER_DEFINITELY_MISSING_XYZ" }), "",
    "T52 missing key yields empty string")
  -- api_key_env list end to end: first set wins, none set yields ""
  assert_eq(cfgm.api_key({ provider = "anthropic",
      api_key_env = { "TETHER_DEF_UNSET_X", "HOME" }, providers = {} }),
    os.getenv("HOME"), "T52 list env first set wins")
  assert_eq(cfgm.api_key({ provider = "anthropic",
      api_key_env = { "TETHER_DEF_UNSET_X", "TETHER_DEF_UNSET_Y" },
      providers = {} }),
    "", "T52 list env none set yields empty")
  _G.provider_catalog = orig_catalog
  print("T52 config providers: OK")
end

-- T53: transcript lifecycle — resume restore, /new + /resume clear
do
  local ui = dofile("src/tether/ui.lua")
  -- pure helper: agent history -> transcript entries (user + text only,
  -- never system/tool internals)
  assert_notnil(ui.transcript_entries, "T53 transcript_entries exported")
  local entries = ui.transcript_entries({
    { role = "system", content = "sys prompt" },
    { role = "user", content = "hi" },
    { role = "assistant", content = "hello" },
    { role = "assistant", content = { tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "read", arguments = "{}" } } } } },
    { role = "tool", tool_call_id = "c1", content = "out" },
  })
  assert_eq(#entries, 2, "T53 only user + text assistant restored")
  assert_eq(entries[1].role, "user", "T53 restored user role")
  assert_eq(entries[1].text, "hi", "T53 restored user text")
  assert_eq(entries[2].text, "hello", "T53 restored assistant text")
  print("T53 transcript_entries: OK")
end

-- T235: bg rows live in the transcript. tool_call_start opens a pending
-- subagent row (task as label); tool_progress updates a capped live tail
-- on the pending row without touching anything else; unknown ids are
-- ignored.
do
  local uim, _ = run_ui_with({ 17 }, {
    agent = { turn = function() return true end,
      get_history = function() return {} end },
  })
  local tr = uim._transcript
  uim._handle_agent_event({ type = "tool_call_start", id = "sg0001",
    name = "subagent", args = { task = "dig deep" } })
  local function find_row(id)
    for _, e in ipairs(tr.entries()) do
      if e.role == "tool" and e.id == id then return e end
    end
  end
  local row = find_row("sg0001")
  assert_notnil(row, "T235 spawn opens a pending row")
  assert_eq(row.status, "pending", "T235 row starts pending")
  local plain = table.concat(uim._render_all(80), "\n"):gsub("\27%[[0-9;]*m", "")
  assert_true(plain:find("dig deep", 1, true) ~= nil,
    "T235 task text labels the row")
  uim._handle_agent_event({ type = "tool_progress", id = "sg0001",
    tail = "child: calling read main.c\nchild: done" })
  assert_eq(row.status, "pending", "T235 progress keeps pending")
  assert_true((row.progress or ""):find("calling read main.c", 1, true) ~= nil,
    "T235 tail stored on the row")
  plain = table.concat(uim._render_all(80), "\n"):gsub("\27%[[0-9;]*m", "")
  assert_true(plain:find("child: done", 1, true) ~= nil,
    "T235 live tail renders without expansion")
  local n_before = #tr.entries()
  uim._handle_agent_event({ type = "tool_progress", id = "sg9999",
    tail = "ghost" })
  assert_eq(#tr.entries(), n_before, "T235 unknown id adds no row")
  local big = {}
  for i = 1, 50 do big[#big + 1] = "line " .. i end
  uim._handle_agent_event({ type = "tool_progress", id = "sg0001",
    tail = table.concat(big, "\n") })
  local lines = 0
  for _ in tostring(row.progress or ""):gmatch("[^\n]+") do lines = lines + 1 end
  assert_true(lines <= 8, "T235 tail capped")
  assert_true(tostring(row.progress):find("line 50", 1, true) ~= nil,
    "T235 cap keeps the newest lines")
  print("T235 bg rows live in the transcript: OK")
end

-- T237: tick harvest and deferred wake. _poll_subagents_bg emits live
-- tails and arms the wake on pickup; _drain_bg_wake starts the
-- continuation when idle (never inside the tick) and drops it on quit.
do
  local orig_sm, orig_agent, orig_turn = _G.subagent, _G.agent, _G.turn
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  _G.subagent = sub
  local outp = os.tmpname()
  do local f = assert(io.open(outp, "w")) f:write("line1\nprogress line X") f:close() end
  sub._running["sg0001"] = { pending = { outfile = outp, handle = {} },
    item = { task = "t", model = "m" }, timeout = 600, idx = 1 }
  local woke = 0
  _G.turn = {
    begin = function() end, finish = function() end,
    start = function() return true end, abort = function() end,
    take_abort = function() return false end, ack_abort = function() end,
    continue = function(...) woke = woke + 1 return true end,
  }
  local bg_round = 0
  local fake_agent = {
    turn = function() return true end,
    get_history = function() return {} end,
    poll_background = function(cfg, on_event)
      bg_round = bg_round + 1
      if bg_round == 1 then return {} end
      return { { call_id = "c1", combined = { output = "done-out",
        exit_code = 0, elapsed_ms = 5, model = "m", tasks = 1 } } }
    end,
  }
  _G.agent = fake_agent
  local uim, S = run_ui_with({ 17 }, {})
  _G.agent = fake_agent
  uim._handle_agent_event({ type = "tool_call_start", id = "sg0001",
    name = "subagent", args = { task = "t" } })
  uim._poll_subagents_bg()
  local row = nil
  for _, e in ipairs(uim._transcript.entries()) do
    if e.role == "tool" and e.id == "sg0001" then row = e end
  end
  assert_notnil(row, "T237 row seeded")
  assert_true((row.progress or ""):find("progress line X", 1, true) ~= nil,
    "T237 tick emits the live tail")
  assert_true(S._bg_wake_pending ~= true, "T237 no wake without pickup")
  uim._poll_subagents_bg()
  assert_true(S._bg_wake_pending == true, "T237 pickup arms the wake")
  assert_eq(woke, 0, "T237 tick never starts the turn itself")
  S.quit = false -- the drain lives inside the loop, post-run S is quit
  uim._drain_bg_wake()
  assert_eq(woke, 1, "T237 deferred drain starts the continuation")
  assert_true(S._bg_wake_pending ~= true, "T237 wake flag cleared")
  S._bg_wake_pending = true
  S.quit = true
  uim._drain_bg_wake()
  assert_eq(woke, 1, "T237 quit drops the wake")
  _G.subagent, _G.agent, _G.turn = orig_sm, orig_agent, orig_turn
  os.remove(outp)
  print("T237 tick harvest and deferred wake: OK")
end

-- T238: busy guard, wake queue, abort. A wake armed mid-turn parks in the
-- queue instead of firing; the next idle drain wakes once. Abort kills
-- the registry, collapses rows, records cancellations, drops the flags.
do
  -- agent level: cancel_background
  do
    local orig_agent, orig_api = _G.agent, _G.api
    local sub = assert(loadfile("src/tether/subagent.lua"))()
    local orig_sm = _G.subagent
    _G.subagent = sub
    local orig_tools = _G.tools
    _G.tools = {
      _resolve = function(p, cfg) return p end,
      _within = function(abs, cfg) return true end,
      _workspace = function(cfg) return "/tmp/ws" end,
    }
    local kills = 0
    local orig_tether = _G.tether
    _G.tether = {
      exec_bg_argv = function(argv, opts) return {} end,
      exec_bg_poll = function(h, ms) return "running", 0 end,
      exec_bg_kill = function(h) kills = kills + 1 return true end,
      exec_bg_free = function(h) return true end,
      abort_requested = function() return false end,
      monotonic_ms = function() return 1000 end,
      getcwd = function() return "/tmp/ws" end,
      is_tty = function() return false end,
    }
    local journal = {}
    local orig_session = _G.session
    _G.session = { append = function(sid, ev) journal[#journal + 1] = ev end }
    local agent = assert(loadfile("src/tether/agent.lua"))()
    _G.agent = agent
    _G.api = { stream = function(c, key, messages, on_event)
      on_event({ type = "tool_call_start", id = "c9", name = "subagent" })
      on_event({ type = "tool_call_delta", id = "c9",
                 arguments = '{"task":"slow job"}' })
      on_event({ type = "done", reason = "tool_calls" })
      return true
    end }
    agent.clear()
    local cfg = { workspace = "/tmp/ws", model = "m", _session_id = "s9" }
    local events = {}
    agent.turn(cfg, "k", "go", function(ev) events[#events + 1] = ev end)
    assert_notnil(agent.bg_calls and agent.bg_calls["c9"],
      "T238 bg call tracked")
    local jobid = agent.bg_calls["c9"].rec.jobs[1].id
    agent.cancel_background(cfg, "nope", function(ev) events[#events + 1] = ev end)
    assert_eq(kills, 1, "T238 abort kills the child")
    assert_eq(sub.running_count(), 0, "T238 registry cleared")
    assert_true(agent.bg_calls["c9"] == nil, "T238 tracking dropped")
    local collapsed, recorded = false, false
    for _, ev in ipairs(events) do
      if ev.type == "tool_result" and ev.id == jobid then collapsed = true end
      if ev.type == "tool_result" and ev.id == "c9" then recorded = true end
    end
    assert_true(collapsed, "T238 job row collapsed as cancelled")
    assert_true(recorded, "T238 call recorded as cancelled")
    local cancelled_hist = 0
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" and m.tool_call_id == "c9" and m.error then
        cancelled_hist = cancelled_hist + 1
      end
    end
    assert_eq(cancelled_hist, 1, "T238 cancellation in history once")
    _G.subagent, _G.tools, _G.session = orig_sm, orig_tools, orig_session
    _G.api, _G.agent, _G.tether = orig_api, orig_agent, orig_tether
  end
  -- ui level: busy parks, idle wakes, abort drops
  do
    local orig_sm, orig_agent, orig_turn = _G.subagent, _G.agent, _G.turn
    local woke = 0
    _G.turn = {
      begin = function() end, finish = function() end,
      start = function() return true end, abort = function() end,
      take_abort = function() return false end, ack_abort = function() end,
      continue = function(...) woke = woke + 1 return true end,
    }
    local cancelled = 0
    _G.agent = {
      turn = function() return true end,
      get_history = function() return {} end,
      cancel_background = function(...) cancelled = cancelled + 1 end,
    }
    local uim, S = run_ui_with({ 17 }, {})
    S.quit = false
    S.busy = true
    S._bg_wake_pending = true
    uim._drain_bg_wake()
    assert_eq(woke, 0, "T238 no wake mid-turn")
    assert_true(S._bg_wake_queued == true, "T238 wake parked in queue")
    S.busy = false
    uim._drain_bg_wake()
    assert_eq(woke, 1, "T238 queued wake fires when idle")
    S._bg_wake_queued = true
    uim._abort_bg("stop")
    assert_eq(cancelled, 1, "T238 abort cancels background")
    assert_true(S._bg_wake_queued ~= true, "T238 abort drops the queue")
    _G.subagent, _G.agent, _G.turn = orig_sm, orig_agent, orig_turn
  end
  print("T238 busy guard, wake queue, abort: OK")
end

-- T239: quitting kills background children. The run epilogue owns the
-- registry even when the loop stops immediately (plain Ctrl+Q, no turn).
do
  local orig_agent = _G.agent
  local cancelled = 0
  run_ui_with({ 17 }, {
    agent = {
      turn = function() return true end,
      get_history = function() return {} end,
      cancel_background = function(cfg, reason, on_event)
        cancelled = cancelled + 1
      end,
    },
  })
  assert_eq(cancelled, 1, "T239 quit cancels background children")
  _G.agent = orig_agent
  print("T239 quit kills background children: OK")
end
-- add-llm-compaction 3.2: commit_input parses free text after /compact.
do
  local captured
  local orig_commands = _G.commands
  _G.commands = {
    compact = function(cfg, key, focus)
      captured = focus
      return "── summary ──\nvia commands", "llm"
    end,
    list_sessions = function() return {} end,
    new = function() return nil end,
    resume = function() return nil end,
    list_models = function() return {} end,
  }
  local bytes = {}
  local function push(s)
    for i = 1, #s do bytes[#bytes + 1] = s:byte(i) end
  end
  push("/compact keep the plan")
  bytes[#bytes + 1] = 13 -- Enter
  bytes[#bytes + 1] = 17 -- Ctrl+Q quit
  local uimod = run_ui_with(bytes, {
    agent = {
      turn = function() return true end,
      get_history = function() return {} end,
      estimate_tokens = function() return 10 end,
    },
  })
  _G.commands = orig_commands
  assert_eq(captured, "keep the plan", "T134 UI parses free text after /compact: " ..
    tostring(captured))
  local entries = uimod._transcript.entries()
  local saw = false
  for _, e in ipairs(entries) do
    if e.text and e.text:find("via commands", 1, true) then saw = true end
  end
  assert_true(saw, "T134 /compact appends summary row with LLM body")
  print("T134 /compact free-text parse: OK")
end

-- TKwrap: a long single line soft-wraps and grows the box (regression:
-- the input stayed one row with the overflow hidden in horizontal scroll,
-- so a long prompt was invisible and the box never grew).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local uimod = run_ui_with({ 17 }, { agent = agent_stub, size = { width = 40, height = 24 } })
  local long = string.rep("ab ", 34) -- 102 chars, no newlines
  for i = 1, #long do
    uimod._handle_key({ kind = "text", char = long:sub(i, i) })
  end
  uimod._paint(true)
  local L = uimod._layout()
  assert_true(L.input_h >= 3, "TKwrap long line wraps to several rows")
  local r1 = strip(uimod._row(L.input_row) or "")
  local rlast = strip(uimod._row(L.input_row + L.input_h - 1) or "")
  assert_true(r1:find("^%s*ab", 1) ~= nil, "TKwrap head row shows the start")
  assert_true(rlast:find("ab", 1, true) ~= nil, "TKwrap tail row shows the end")
  -- caret sits on the last visual row: Up moves within the input instead
  -- of recalling history (pre-fix there was a single buffer line, so Up
  -- fell through to history_prev and the cursor never moved).
  local S = uimod._get_state()
  local cur0 = S.cursor
  assert_eq(cur0, #long, "TKwrap caret starts at end of input")
  uimod._handle_key({ kind = "special", name = "up" })
  assert_eq(S.input, long, "TKwrap Up keeps the input intact")
  assert_true(S.cursor < cur0, "TKwrap Up moves to the previous visual row")
  print("TKwrap long input wraps and grows: OK")
end
-- helpers for transcript assertions (entries/tails live on the module now)


if failed > 0 then
    os.exit(1)
end
