-- tests/tools_tests.lua — tools/session/grep/retry intro (split from lua_tests.lua, Phase C).
-- Run: lua tests/tools_tests.lua

dofile("tests/helpers.lua")
-- T103 (2.1): persisted [A] always patterns load on the next start.
do
  local config = assert(loadfile("src/tether/config.lua"))()
  local home = "/tmp/tether_t103_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local f = assert(io.open(home .. "/.tether/auto_approve.lua", "w"))
  f:write('-- added by tether ([A] always) on 2026-01-01\nreturn {\n  "^run:/tmp/x$",\n}\n')
  f:close()
  local cfg = config.load(home .. "/no-such-config.lua", home)
  assert_eq(type(cfg.auto_approve), "table", "T103 auto_approve is a table")
  assert_eq(#cfg.auto_approve, 1, "T103 one persisted pattern")
  assert_eq(cfg.auto_approve[1], "^run:/tmp/x$", "T103 pattern loaded")
  local cfg2 = config.load(home .. "/no-such-config.lua", "/tmp/tether_t103_missing")
  assert_eq(#cfg2.auto_approve, 0, "T103 missing file contributes nothing")
  os.execute("rm -rf " .. home)
  print("T103 auto_approve load: OK")
end

-- T104 (2.2/2.3): patch is gated by the confirmation policy; the tool's own
-- refusal uses the shared "requires confirmation" wording.
do
  local names = {"tether", "config", "session", "api", "agent", "tools", "context"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local function norm(p)
    if p:sub(1, 1) ~= "/" then p = "/ws/" .. p end
    while p:find("/[^/]+/%.%./") do p = p:gsub("/[^/]+/%.%./", "/") end
    return p
  end
  _G.tether = host_mock{ getcwd = function() return "/ws" end, realpath = norm }
  _G.tools = {
    _resolve = norm,
    _within = function(p) return p == "/ws" or p:sub(1, 4) == "/ws/" end,
    _workspace = function() return "/ws" end,
  }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.api = { stream = function() return true end }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local confirm_policy = _G.confirm_policy
      or assert(loadfile("src/tether/confirm_policy.lua"))()
  local cfg = { workspace = "/ws", allow_outside_workspace = false }
  assert_false(confirm_policy.should_confirm("patch",
    { patch = "--- a/src/a.lua\n+++ b/src/a.lua\n@@ -1 +1 @@\n-a\n+b\n" }, cfg),
    "T104 in-workspace patch: no confirmation")
  assert_true(confirm_policy.should_confirm("patch",
    { patch = "--- a/../etc/hosts\n+++ b/../etc/hosts\n@@ -1 +1 @@\n-a\n+b\n" }, cfg),
    "T104 out-of-workspace patch: confirmation")
  assert_true(confirm_policy.should_confirm("patch",
    { patch = "--- ../etc/hosts\n+++ ../etc/hosts\n@@ -1 +1 @@\n-a\n+b\n" }, cfg),
    "T104 prefix-less out-of-workspace patch: confirmation")
  local tools_real = assert(loadfile("src/tether/tools.lua"))()
  local _, err = tools_real.patch("--- /etc/hosts\n+++ /etc/hosts\n@@ -1 +1 @@\n-a\n+b\n",
    { workspace = "/tmp/tether_t104_ws" })
  assert_true(err ~= nil and err:find("requires confirmation", 1, true) ~= nil,
    "T104 patch refusal wording: " .. tostring(err))
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T104 patch confirmation: OK")
end

-- T105 (2.4): path completion appends "/" to directories and descends.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t105_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws .. "/sub")
  local f = assert(io.open(ws .. "/a.txt", "w")); f:write("x"); f:close()
  local g = assert(io.open(ws .. "/sub/inner.lua", "w")); g:write("x"); g:close()
  -- realpath stub with C semantics: a trailing slash only resolves for a dir
  local dirs = {}; dirs[ws] = true; dirs[ws .. "/sub"] = true
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
    realpath = function(p)
      local n = (p:gsub("/+$", ""))
      if p:sub(-1) == "/" and not dirs[n] then return nil end
      return n
    end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }
  local r = tools.path_complete("su", cfg)
  assert_eq(#r.candidates, 1, "T105 one candidate for 'su'")
  assert_eq(r.candidates[1], "sub/", "T105 directory gets a trailing slash")
  local r2 = tools.path_complete("sub/", cfg)
  assert_eq(#r2.candidates, 1, "T105 descends into the directory")
  -- the candidate carries the typed directory: the UI replaces the whole token,
  -- so a bare name would complete `read sub/inner.lua` to `read inner.lua`
  assert_eq(r2.candidates[1], "sub/inner.lua",
    "T105 candidate keeps the typed directory")
  local r3 = tools.path_complete("a", cfg)
  assert_eq(r3.candidates[1], "a.txt", "T105 files get no trailing slash")
  -- several candidates keep it too, since the palette applies one of them
  local h = assert(io.open(ws .. "/sub/inner.txt", "w")); h:write("x"); h:close()
  local r4 = tools.path_complete("sub/in", cfg)
  assert_eq(#r4.candidates, 2, "T105 two candidates inside the directory")
  assert_eq(r4.candidates[1], "sub/inner.lua", "T105 first candidate keeps the directory")
  assert_eq(r4.candidates[2], "sub/inner.txt", "T105 second candidate keeps the directory")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T105 directory completion: OK")
end

-- T106 (3.1): portable session listing works without GNU `find -printf`.
do
  local orig = _G.tether
  _G.tether = host_mock{}
  local session = assert(loadfile("src/tether/session.lua"))()
  local dir = "/tmp/tether_t106_sessions"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  session._session_dir = dir
  local function write(id, ws)
    local h = assert(io.open(dir .. "/" .. id .. ".jsonl", "w"))
    h:write('{"ts":"2026-01-01T00:00:00","type":"session_start","meta":{"workspace":"' .. ws .. '","model":"m"}}\n')
    h:write('{"ts":"2026-01-01T00:00:01","type":"message","role":"user","content":"hi"}\n')
    h:close()
  end
  write("aaaa", "/ws1")
  write("bbbb", "/ws2")
  local files = session.session_files("/ws1")
  assert_eq(#files, 1, "T106 workspace filter")
  assert_eq(files[1].id, "aaaa", "T106 id parsed")
  assert_eq(files[1].first_line, "hi", "T106 first user line")
  local src = assert(io.open("src/tether/session.lua")):read("*a")
  assert_true(src:find("%-printf", 1, true) == nil, "T106 no GNU find -printf")
  session._session_dir = nil
  _G.tether = orig
  os.execute("rm -rf " .. dir)
  print("T106 portable session listing: OK")
end

-- T106b: latest() skips empty sessions (a run that never produced a message
-- only buries the real latest session; every launch used to mint one).
do
  local orig = _G.tether
  _G.tether = host_mock{}
  local session = assert(loadfile("src/tether/session.lua"))()
  local dir = "/tmp/tether_t106b_sessions"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  session._session_dir = dir
  local function write(id, body)
    local h = assert(io.open(dir .. "/" .. id .. ".jsonl", "w"))
    h:write(body)
    h:close()
  end
  write("real-old",
    '{"ts":"2026-01-01T00:00:00","type":"session_start","meta":{"workspace":"/ws","model":"m"}}\n'
    .. '{"ts":"2026-01-01T00:00:01","type":"message","role":"user","content":"hi"}\n')
  write("empty-new",
    '{"ts":"2026-01-01T00:00:00","type":"session_start","meta":{"workspace":"/ws","model":"m"}}\n'
    .. '{"ts":"2026-01-01T00:00:02","type":"session_end","meta":{"workspace":"/ws","model":"m"}}\n')
  -- newest file first despite the empty one being younger
  os.execute("touch -d '2026-01-01 00:00:10' '" .. dir .. "/empty-new.jsonl'")
  local files = session.session_files("/ws")
  assert_eq(#files, 1, "T106b empty sessions are hidden")
  assert_eq(files[1].id, "real-old", "T106b only the real session lists")
  assert_eq(session.latest("/ws"), "real-old", "T106b latest skips the empty session")
  session._session_dir = nil
  _G.tether = orig
  os.execute("rm -rf " .. dir)
  print("T106b latest skips empty sessions: OK")
end

-- T107 (1.2): assistant text survives alongside tool_calls in encoding.
do
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  local enc = openai.encode_messages({
    { role = "assistant", content = { text = "let me check", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "run", arguments = '{"command":"ls"}' } } } } },
  })
  assert_true(enc:find('"content":"let me check"', 1, true) ~= nil,
    "T107 text kept with tool_calls")
  local enc2 = openai.encode_messages({
    { role = "assistant", content = { text = "", tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "run", arguments = "{}" } } } } },
  })
  assert_true(enc2:find('"content":null', 1, true) ~= nil,
    "T107 empty text stays null")
  local msgs = { { role = "assistant", content = { text = "see", tool_calls = {
      { id = "c1", type = "function", ["function"] = { name = "run", arguments = "{}" } } } } } }
  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local abody = anthropic.build_request(msgs, "m", 128)
  assert_true(abody:find('"text":"see"', 1, true) ~= nil, "T107 anthropic text block")
  local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
  local gbody = gemini.build_request(msgs, "m", 128)
  assert_true(gbody:find('"text":"see"', 1, true) ~= nil, "T107 gemini text part")
  print("T107 assistant text with tool calls: OK")
end

-- T108 (3.4): provider errors keep the real message text.
-- add-retry-and-continuation: an error now fails the attempt (the transport
-- reads it) instead of being emitted as an event, so the retry policy decides.
do
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  openai.reset_stream()
  local got
  openai.parse_sse_line('data: {"error":{"message":"bad key","status":401}}',
    function(e) got = e end)
  local failure = openai.stream_failure()
  assert_true(got == nil, "T108 no error event emitted")
  assert_true(failure ~= nil, "T108 failure recorded")
  assert_true(failure and failure.message:find("bad key", 1, true) ~= nil, "T108 real message surfaced")
  assert_eq(failure and failure.status, 401, "T108 status kept")
  print("T108 openai error message: OK")
end

-- T109 (3.5): the auth header temp file is created with mode 0600 before the
-- key is written, and a failed fchmod aborts the request instead of writing the
-- secret into a world-readable file.
do
  local orig = _G.tether
  local seen = {}
  _G.tether = host_mock{
    fchmod = function(path, mode)
      seen[#seen + 1] = { path = path, mode = mode }
      return true
    end,
  }
  local api = assert(loadfile("src/tether/api.lua"))()
  local path = api._header_file({ "Authorization: Bearer secret" })
  assert_notnil(path, "T109 header file created")
  assert_eq(#seen, 1, "T109 mode applied before the key is written")
  assert_eq(seen[1].mode, tonumber("600", 8), "T109 mode 0600 requested")
  assert_eq(seen[1].path, path, "T109 mode applied to the header file")
  local h = assert(io.open(path))
  local content = h:read("*a")
  h:close()
  assert_true(content:find("secret", 1, true) ~= nil, "T109 key written")
  os.remove(path)

  _G.tether = host_mock{ fchmod = function() return nil, "not permitted" end }
  local api2 = assert(loadfile("src/tether/api.lua"))()
  assert_eq(api2._header_file({ "Authorization: Bearer secret" }), nil,
    "T109 no header file when fchmod fails")
  _G.tether = orig
  print("T109 header file permissions: OK")
end

-- T110 (3.7): a string/float timeout from the model is coerced, not fatal.
-- `run` is the only caller of tether.exec, and it must hand the command over as
-- `/bin/sh -c` under `timeout` (host spec: Process and pipe API).
do
  local orig = _G.tether
  local ws = "/tmp/tether_t110_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local seen_cmd
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                realpath = function(p) return (p:gsub("/+$", "")) end,
                -- mirrors the C contract: (ok, exit_code) where ok is true only
                -- for exit code 0 (src/host/main.c l_exec)
                exec = function(cmd)
                  seen_cmd = cmd
                  local ok, how, code = os.execute(cmd)
                  if ok then return true, 0 end
                  if how == "exit" then return false, code end
                  return false, 1
                end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local r = tools.run({ command = "echo hi", timeout = "1" }, { workspace = ws })
  assert_true(r ~= nil and type(r.exit_code) == "number", "T110 string timeout coerced")
  assert_true((r.output or ""):find("hi", 1, true) ~= nil, "T110 command ran")
  assert_true(seen_cmd ~= nil and seen_cmd:find("sh -c", 1, true) ~= nil,
    "T110 run goes through /bin/sh -c")
  assert_true(seen_cmd:find("timeout", 1, true) ~= nil, "T110 run is timeout-wrapped")
  local r2 = tools.run({ command = "exit 3", timeout = "1" }, { workspace = ws })
  assert_eq(r2.exit_code, 3, "T110 non-zero exit code propagated")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T110 run timeout coercion: OK")
end

-- T111 (3.9): the shared JSON helpers decode nested objects and escapes.
do
  local common = assert(loadfile("src/tether/providers/common.lua"))()
  local obj = common.json_decode('{"a":{"b":[1,2,3]},"c":"x\\ny"}')
  assert_eq(obj.a.b[3], 3, "T111 json_decode nested array")
  assert_eq(obj.c, "x\ny", "T111 json_decode newline escape")
  assert_true(common.json_decode and common.json_unescape ~= nil, "T111 helpers exported")
  print("T111 shared JSON helpers: OK")
end

-- T112 (bonus regression): patch applies in-workspace. Before this change the
-- patch body wrapped gmatch in ipairs and raised on the first line.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t112_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local f = assert(io.open(ws .. "/a.txt", "w")); f:write("one\ntwo\n"); f:close()
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                realpath = function(p) return (p:gsub("/+$", "")) end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local function read(p)
    local hh = assert(io.open(p)); local d = hh:read("*a"); hh:close(); return d
  end
  -- prefix-less header
  local diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+three\n"
  local r, err = tools.patch(diff, { workspace = ws })
  assert_true(r ~= nil, "T112 patch applied (" .. tostring(err) .. ")")
  local out = read(ws .. "/a.txt")
  assert_true(out:find("three", 1, true) ~= nil and out:find("two", 1, true) == nil,
    "T112 file content updated")
  -- git-style a//b/ headers target the real path, not b/...
  local f2 = assert(io.open(ws .. "/g.txt", "w")); f2:write("one\n"); f2:close()
  local r2, err2 = tools.patch("--- a/g.txt\n+++ b/g.txt\n@@ -1 +1 @@\n-one\n+two\n", { workspace = ws })
  assert_true(r2 ~= nil, "T112 git-style patch applied (" .. tostring(err2) .. ")")
  assert_true(read(ws .. "/g.txt"):find("two", 1, true) ~= nil, "T112 git-style target updated")
  assert_true(not io.open(ws .. "/b/g.txt"), "T112 no b/ prefixed file created")
  -- new file via /dev/null
  local r3, err3 = tools.patch("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+fresh\n", { workspace = ws })
  assert_true(r3 ~= nil, "T112 new file patch applied (" .. tostring(err3) .. ")")
  assert_true(read(ws .. "/new.txt"):find("fresh", 1, true) ~= nil, "T112 new file created")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T112 patch applies: OK")
end

-- T322/T323 (audit H5): a malformed argument shape is a tool error the model
-- can correct, not a Lua raise. `patch` used to call gmatch on whatever it got
-- (a table, when arguments failed to decode); `run` reached sq()'s gsub with the
-- same payload.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t322_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local exec_calls = 0
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                realpath = function(p) return (p:gsub("/+$", "")) end,
                exec = function() exec_calls = exec_calls + 1; return true, 0 end }
  local tools = assert(loadfile("src/tether/tools.lua"))()

  local p1, e1 = tools.patch({}, { workspace = ws })
  assert_true(p1 == nil, "T322 a table diff is refused")
  assert_true(type(e1) == "string" and e1:find("patch", 1, true) ~= nil,
    "T322 the refusal names the argument (" .. tostring(e1) .. ")")
  local p2, e2 = tools.patch({ patch = { "a" } }, { workspace = ws })
  assert_true(p2 == nil, "T322 a nested table diff is refused")
  assert_true(type(e2) == "string", "T322 the nested refusal is text")
  local f = assert(io.open(ws .. "/t322.txt", "w")); f:write("one\n"); f:close()
  local p3, e3 = tools.patch("--- a/t322.txt\n+++ b/t322.txt\n@@ -1 +1 @@\n-one\n+two\n",
    { workspace = ws })
  assert_true(p3 ~= nil, "T322 a real diff still applies (" .. tostring(e3) .. ")")

  local r1, r1err = tools.run({ command = { "ls" } }, { workspace = ws })
  assert_true(r1 == nil, "T323 a table command is refused")
  assert_true(type(r1err) == "string" and r1err:find("command", 1, true) ~= nil,
    "T323 the refusal names the command (" .. tostring(r1err) .. ")")
  assert_eq(exec_calls, 0, "T323 nothing was spawned for the malformed call")
  local r2 = tools.run({ command = "echo ok" }, { workspace = ws })
  assert_true(r2 ~= nil and exec_calls == 1, "T323 a string command still runs")

  -- specs/tools: an absent argument keeps the pre-existing degradation — empty
  -- output for `run`, the named error for `read` — rather than a new raise.
  local r3 = tools.run({}, { workspace = ws })
  assert_true(r3 ~= nil, "T323 run without a command still returns a result")
  assert_eq(r3.output, "", "T323 run without a command captures nothing")
  assert_eq(r3.exit_code, 0, "T323 run without a command reports exit 0")
  local rd, rderr = tools.read({}, { workspace = ws })
  assert_true(rd == nil, "T323 read without a path is refused")
  assert_eq(rderr, "missing path argument", "T323 read names its missing argument")

  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T322-T323 malformed tool arguments degrade: OK")
end

-- T324/T325/T326 (audit H6): `run` bounds what it reads back and what the model
-- can ask for. An oversized capture is cut at max_output_bytes with the shared
-- truncation marker; a timeout with no integer representation (or above the
-- ceiling) is clamped instead of failing `string.format("%d", …)`.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t324_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local MARKER = "\n…(truncated)"
  _G.tether = host_mock{ getcwd = function() return ws end,
                realpath = function(p) return (p:gsub("/+$", "")) end,
                exec = function(cmd)
                  local ok, how, code = os.execute(cmd)
                  if ok then return true, 0 end
                  if how == "exit" then return false, code end
                  return false, 1
                end }
  local tools = assert(loadfile("src/tether/tools.lua"))()

  local capped = tools.run({ command = "head -c 5000 /dev/zero | tr '\\0' 'x'",
    timeout = 5 }, { workspace = ws,
    tools = { run_shell = { max_output_bytes = 100 } } })
  assert_notnil(capped, "T324 an oversized capture still returns")
  assert_eq(capped.truncated, true, "T324 the result says the output was capped")
  assert_eq(#capped.output, 100 + #MARKER, "T324 the body is the cap plus the marker")
  assert_eq(capped.output:sub(-#MARKER), MARKER, "T324 the marker is the shared one")
  assert_eq(capped.exit_code, 0, "T324 the real exit code survives the cap")

  local small = tools.run({ command = "printf ok", timeout = 5 }, { workspace = ws })
  assert_eq(small.output, "ok", "T324 a small output is untouched")
  assert_eq(small.truncated, false, "T324 and is not marked truncated")

  -- timeout clamp: the composed command is what matters, so inspect it
  local seen
  _G.tether = host_mock{ getcwd = function() return ws end,
                realpath = function(p) return (p:gsub("/+$", "")) end,
                exec = function(cmd) seen = cmd; return true, 0 end }
  local function clamped(args, cfg)
    local r = tools.run(args, cfg)
    assert_notnil(r, "T325 the call returns a result")
    return tonumber(seen:match("timeout (%-?%d+)"))
  end
  local wide = { workspace = ws, tools = { run_shell = { timeout = 30, max_timeout = 60 } } }
  assert_eq(clamped({ command = "true", timeout = 999999 }, wide), 60,
    "T325 a timeout above the ceiling is clamped to it")
  assert_eq(clamped({ command = "true", timeout = 1e308 }, wide), 60,
    "T325 an astronomical timeout is clamped, not an error")
  assert_eq(clamped({ command = "true", timeout = math.huge }, wide), 30,
    "T325 an infinite timeout falls back to the configured default")
  assert_eq(clamped({ command = "true", timeout = "abc" }, wide), 30,
    "T325 a non-numeric timeout falls back to the configured default")
  assert_eq(clamped({ command = "true", timeout = 7 }, wide), 7,
    "T325 a sane timeout passes through")
  assert_eq(clamped({ command = "true", timeout = 0 }, wide), 1,
    "T325 a zero timeout keeps the one-second floor")
  -- no tools table at all (a hand-built cfg): the built-in ceiling applies
  assert_eq(clamped({ command = "true", timeout = 1e308 }, { workspace = ws }), 1800,
    "T325 the default ceiling applies without a config table")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T324-T325 run output capped, timeout clamped: OK")
end

-- T326 (audit H6): the two limits are defaults a fresh install resolves, a config
-- written before they existed keeps them, and a malformed value falls back.
do
  local config = assert(loadfile("src/tether/config.lua"))()
  local home = "/tmp/tether_t326_home"
  os.execute("rm -rf " .. home)
  assert(host_fs.mkdirp(home .. "/.tether"))
  local function write_cfg(name, body)
    local p = home .. "/.tether/" .. name
    local f = assert(io.open(p, "w")); f:write(body); f:close()
    return p
  end
  local fresh = config.load(home .. "/.tether/no-such-config.lua", home)
  assert_eq(fresh.tools.run_shell.timeout, 120, "T326 the default timeout")
  assert_eq(fresh.tools.run_shell.max_output_bytes, 1048576, "T326 the default cap")
  assert_eq(fresh.tools.run_shell.max_timeout, 1800, "T326 the default ceiling")

  local old = config.load(write_cfg("old.lua",
    "return { tools = { run_shell = { timeout = 5 } } }\n"), home)
  assert_eq(old.tools.run_shell.timeout, 5, "T326 an old override still applies")
  assert_eq(old.tools.run_shell.max_output_bytes, 1048576, "T326 pre-key config keeps the cap")
  assert_eq(old.tools.run_shell.max_timeout, 1800, "T326 pre-key config keeps the ceiling")

  local bad = config.load(write_cfg("bad.lua",
    "return { tools = { run_shell = { max_timeout = \"later\", max_output_bytes = {} } } }\n"),
    home)
  assert_eq(bad.tools.run_shell.max_timeout, 1800, "T326 a malformed ceiling falls back")
  assert_eq(bad.tools.run_shell.max_output_bytes, 1048576, "T326 a malformed cap falls back")
  os.execute("rm -rf " .. home)
  print("T326 run_shell limits defaults: OK")
end

-- T113 (1.4/1.5/2.2): `list`, `glob` and `grep` run on the in-process
-- primitives (readdir/stat/krep_search) with their documented record shapes:
-- workspace-relative paths, glob's recursive walk plus 500-file cap and `**`
-- depth, and grep's {path, line, column, text} with column always 1.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t113_ws"
  local last_krep = {}

  local dirs = {
    [ws] = { "a.txt", "big", "sub" },
    [ws .. "/sub"] = { "b.lua", "deep" },
    [ws .. "/sub/deep"] = { "c.lua" },
    [ws .. "/big"] = {},
  }
  for i = 1, 600 do dirs[ws .. "/big"][i] = ("f%03d.txt"):format(i) end

  _G.tether = host_mock{
    getcwd = function() return ws end,
    realpath = function(p) return (p:gsub("/+$", "")) end,
    readdir = function(p)
      local d = dirs[p]
      if not d then return nil, "no such directory" end
      local out = {}
      for i, n in ipairs(d) do out[i] = n end
      table.sort(out)
      return out
    end,
    stat = function(p)
      if dirs[p] then return { mtime = 1, size = 0, is_dir = true } end
      if p:match("%.[a-z]+$") then return { mtime = 1, size = 3, is_dir = false } end
      return nil, "no such file"
    end,
    krep_search = function(base, pattern, glob, ignore_case, gitignore, max)
      last_krep = { base = base, pattern = pattern, glob = glob,
                    ignore_case = ignore_case, gitignore = gitignore, max = max }
      -- the C host returns krep's printed records as {path, line, column, text}
      return {
        { path = ws .. "/a.txt", line = 1, column = 1, text = "needle one" },
        { path = ws .. "/sub/b.lua", line = 7, column = 1, text = "needle two" },
      }
    end,
  }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }

  -- list: sorted root entries with a count; a sub-directory path is accepted
  local l = tools.list({}, cfg)
  assert_eq(l.count, 3, "T113 list counts the workspace root")
  assert_eq(l.entries[1], "a.txt", "T113 list entries are sorted")
  assert_eq(l.entries[3], "sub", "T113 list covers the whole root")
  local l2 = tools.list({ path = "sub" }, cfg)
  assert_eq(l2.count, 2, "T113 list accepts a sub-directory")
  assert_eq(l2.entries[1], "b.lua", "T113 sub-directory entries sorted")

  -- glob: recursive walk, relative sorted paths, `**` crosses directories
  local g = tools.glob({ pattern = "**/*.lua" }, cfg)
  assert_eq(g.count, 2, "T113 glob ** finds nested .lua files")
  assert_eq(g.files[1], "sub/b.lua", "T113 glob returns workspace-relative paths")
  assert_eq(g.files[2], "sub/deep/c.lua", "T113 glob descends into sub-tree")
  local g2 = tools.glob({ pattern = "*.txt" }, cfg)
  assert_eq(g2.files[1], "a.txt", "T113 glob matches the basename")
  local g3 = tools.glob({ path = "big", pattern = "*.txt" }, cfg)
  assert_eq(g3.count, 500, "T113 glob caps 600 matches at 500")

  -- grep: one in-process krep_search call, records kept workspace-relative
  local r = tools.grep({ pattern = "needle", max_results = 5 }, cfg)
  assert_eq(r.count, 2, "T113 grep returns the krep records")
  assert_eq(r.matches[1].path, "a.txt", "T113 grep path is workspace-relative")
  assert_eq(r.matches[1].line, 1, "T113 grep carries the line number")
  assert_eq(r.matches[1].column, 1, "T113 grep column is 1 (krep prints none)")
  assert_eq(r.matches[1].text, "needle one", "T113 grep carries the line text")
  assert_eq(r.matches[2].path, "sub/b.lua", "T113 grep keeps nested paths")
  assert_eq(last_krep.pattern, "needle", "T113 pattern reaches krep")
  assert_eq(last_krep.max, 5, "T113 max_results reaches krep")
  assert_eq(last_krep.base, ws, "T113 search base is the workspace")
  assert_true(last_krep.gitignore == true, "T113 .gitignore honored by default")
  tools.grep({ pattern = "x", ignore_case = true, glob = "*.py" }, cfg)
  assert_true(last_krep.ignore_case == true, "T113 ignore_case reaches krep")
  assert_eq(last_krep.glob, "*.py", "T113 glob filter reaches krep")
  _G.tether = orig
  print("T113 list/glob/grep on in-process primitives: OK")
end

-- T114 (1.6): session listing enumerates *.jsonl through tether.readdir, orders
-- by mtime descending and keeps only the 100 most recent files, exposing the
-- recency rank as `mtime`.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t114_ws"
  local dir = "/tmp/tether_t114_sessions"
  os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir)
  local names, mtimes = {}, {}
  for i = 1, 105 do
    local id = ("s%03d"):format(i)
    local name = id .. ".jsonl"
    names[#names + 1] = name
    mtimes[name] = i -- s105 is the newest
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write('{"ts":"2026-01-01T00:00:00","type":"session_start",'
            .. '"meta":{"workspace":"' .. ws .. '","model":"m"}}\n')
    f:write('{"ts":"2026-01-01T00:00:01","type":"message","role":"user",'
            .. '"content":"hi"}\n')
    f:close()
  end
  _G.tether = host_mock{
    readdir = function(p)
      if p ~= dir then return nil, "no such directory" end
      local out = {}
      for i, n in ipairs(names) do out[i] = n end
      table.sort(out)
      return out
    end,
    stat = function(p)
      local name = p:match("([^/]+)$")
      if p:sub(1, #dir) ~= dir or mtimes[name] == nil then return nil, "missing" end
      return { mtime = mtimes[name], size = 1, is_dir = false }
    end,
  }
  local session = assert(loadfile("src/tether/session.lua"))()
  session._session_dir = dir
  local files = session.session_files(ws)
  assert_eq(#files, 100, "T114 listing keeps the 100 most recent")
  assert_eq(files[1].id, "s105", "T114 newest session first")
  assert_eq(files[1].mtime, 1, "T114 mtime is the recency rank")
  assert_eq(files[2].id, "s104", "T114 ordered by mtime descending")
  assert_eq(files[100].id, "s006", "T114 the oldest fall off the cap")
  assert_eq(files[1].first_line, "hi", "T114 first user message is the preview")
  session._session_dir = nil
  _G.tether = orig
  os.execute("rm -rf " .. dir)
  print("T114 session listing order/cap: OK")
end

-- === pretty-transcript-rendering: diff engine (tasks 1.1-1.5) ============
do
  local d = assert(loadfile("src/tether/diff.lua"))()

  -- 1.1 new file: all additions, +N -0
  local t1, c1 = d.unified("", "a\nb\nc\n", "a/x", "b/x")
  assert_eq(c1.add, 3, "1.1 new file add count")
  assert_eq(c1.del, 0, "1.1 new file del count")
  assert_true(t1:find("@@ -0,0 +1,3 @@", 1, true) ~= nil, "1.1 new file hunk header")
  assert_true(t1:find("^+a$") ~= nil or t1:find("\n+a\n", 1, true) ~= nil, "1.1 new file addition")

  -- 1.1 overwrite keeps surrounding context
  local t2, c2 = d.unified("l1\nl2\nl3\nl4\nl5\n", "l1\nl2\nl3\nX\nl5\n", "a/x", "b/x")
  assert_eq(c2.add, 1, "1.1 overwrite add")
  assert_eq(c2.del, 1, "1.1 overwrite del")
  assert_true(t2:find("\n l3\n", 1, true) ~= nil, "1.1 context line kept")
  assert_true(t2:find("-l4", 1, true) ~= nil, "1.1 removed line")
  assert_true(t2:find("+X", 1, true) ~= nil, "1.1 added line")

  -- 1.1 identical input -> empty diff
  local t3, c3 = d.unified("x\ny\n", "x\ny\n")
  assert_eq(t3, "", "1.1 identical -> empty diff")
  assert_eq(c3.add, 0, "1.1 identical add 0")
  assert_eq(c3.del, 0, "1.1 identical del 0")

  -- 1.2 parse a multi-file diff
  local multi = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
             .. "--- a/y\n+++ b/y\n@@ -3,2 +3,3 @@\n ctx\n+ins\n ctx2\n"
  local rows = d.parse(multi)
  assert_notnil(rows, "1.2 parse multi-file")
  local add_rows, hunk_count, file_count = 0, 0, 0
  for _, r in ipairs(rows) do
    if r.kind == "add" then add_rows = add_rows + 1 end
    if r.kind == "hunk-header" then hunk_count = hunk_count + 1 end
    if r.kind == "file-header" then file_count = file_count + 1 end
  end
  assert_eq(hunk_count, 2, "1.2 two hunks")
  assert_eq(file_count, 4, "1.2 four file headers")
  -- hunk without explicit counts: `@@ -1 +1 @@` means one old / one new line
  local first_add, first_rem
  for _, r in ipairs(rows) do
    if r.kind == "add" and not first_add then first_add = r end
    if r.kind == "remove" and not first_rem then first_rem = r end
  end
  assert_eq(first_rem and first_rem.old, 1, "1.2 hunk-without-counts old line number")
  assert_eq(first_add and first_add.new, 1, "1.2 hunk-without-counts new line number")
  local second_add
  for _, r in ipairs(rows) do
    if r.kind == "add" and r.new == 4 then second_add = r end
  end
  assert_notnil(second_add, "1.2 add line number from hunk header")

  -- 1.2 no-newline marker is recognised, not fatal
  local marker = "@@ -1,1 +1,1 @@\n-a\n+b\n\\ No newline at end of file\n"
  local mrows = d.parse(marker)
  assert_notnil(mrows, "1.2 no-newline diff parses")
  local saw_marker = false
  for _, r in ipairs(mrows) do if r.kind == "no-newline" then saw_marker = true end end
  assert_true(saw_marker, "1.2 no-newline row emitted")

  -- 1.2 non-diff text -> nil
  assert_eq(d.parse("hello\nworld"), nil, "1.2 plain text is not a diff")
  assert_eq(d.parse(""), nil, "1.2 empty text is not a diff")

  -- 1.3 only-changed-word pairing
  local oseg, nseg = d.pair_words({ text = "foo(a, 1)" }, { text = "foo(a, 2)" })
  assert_notnil(oseg, "1.3 paired only-changed-word")
  local function changed_text(segs)
    local out = {}
    for _, s in ipairs(segs) do if s.changed then out[#out + 1] = s.text end end
    return table.concat(out)
  end
  assert_eq(changed_text(oseg), "1)", "1.3 old changed word")
  assert_eq(changed_text(nseg), "2)", "1.3 new changed word")
  assert_eq(d.pair_words({ text = "alpha beta" }, { text = "gamma delta" }), nil,
    "1.3 dissimilar pair not paired")
  local longline = string.rep("x ", 300)
  assert_eq(d.pair_words({ text = longline }, { text = longline .. "y" }), nil,
    "1.3 over-long line skips comparison")
  assert_eq(d.pair_words({ text = "one two" }, { text = "one" }), nil,
    "1.3 unequal runs not paired")

  -- 1.4 meter
  local a12, d12 = d.meter(12, 3)
  assert_true(a12 >= 1 and d12 >= 1, "1.4 +12 -3 both sides")
  assert_true(a12 > d12, "1.4 +12 -3 added side longer")
  local a34, d34 = d.meter(34, 0)
  assert_true(a34 > 0 and d34 == 0, "1.4 +34 -0 added only")
  local a05, d05 = d.meter(0, 5)
  assert_true(a05 == 0 and d05 > 0, "1.4 +0 -5 removed only")

  -- 1.5 module is callable through dofile
  assert_true(type(d.unified) == "function" and type(d.parse) == "function"
    and type(d.pair_words) == "function" and type(d.meter) == "function",
    "1.5 diff module exports full API")
  print("1.1-1.5 diff engine: OK")
end

-- === pretty-transcript-rendering: agent (tasks 2.1-2.5) =================
do
  local ws = "/tmp/tether_ptr_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local diffmod = assert(loadfile("src/tether/diff.lua"))()
  local pc = assert(loadfile("src/tether/providers/common.lua"))()

  local saved = {}
  for _, n in ipairs({"tether","config","session","api","agent","context","tools","diff","provider_common"}) do
    saved[n] = _G[n]
  end

  local function fresh()
    _G.tether = host_mock{
      realpath = function(p) return (p:gsub("/+$", "")) end,
      getcwd = function() return ws end,
      exec = function() return true, 0 end,
    }
    _G.config = { get_system_prompt = function() return nil end }
    _G.session = { append = function() end }
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.diff = diffmod
    _G.provider_common = pc
    local a = assert(loadfile("src/tether/agent.lua"))()
    _G.agent = a
    return a
  end

  local function scripted(steps)
    local n = 0
    return function(cfg, key, hist, cb)
      n = n + 1
      local s = steps[n]
      if not s then return true end
      for _, ev in ipairs(s) do cb(ev) end
      return true
    end
  end

  local function write_file(name, content)
    local f = assert(io.open(ws .. "/" .. name, "w")); f:write(content); f:close()
  end
  local function read_file(name)
    local f = io.open(ws .. "/" .. name, "r")
    if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end
  local function cfg() return { workspace = ws, context = {}, _session_id = "s" } end
  local function turn_events(a)
    local starts, results = {}, {}
    a.turn(cfg(), "k", "go", function(e)
      if e.type == "tool_call_start" then starts[#starts + 1] = e end
      if e.type == "tool_result" then results[#results + 1] = e end
    end)
    return starts, results
  end

  -- 2.1 + 2.3 write carries args, body is the applied diff, history matches
  do
    write_file("w.txt", "l1\nl2\nl3\n")
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c1", name = "write" },
        { type = "tool_call_delta", id = "c1", arguments = pc.json_encode({ path = "w.txt", content = "l1\nX\nl3\n" }) } },
      { { type = "text_delta", text = "done" } },
    }) }
    local starts, results = turn_events(a)
    assert_eq(starts[1] and starts[1].args and starts[1].args.path, "w.txt", "2.1 tool_call_start carries args")
    local proj = starts[1] and starts[1].projection
    assert_notnil(proj, "2.2 write event carries projection")
    assert_eq(proj.kind, "overwrite", "2.2 projection kind overwrite")
    assert_true(proj.diff:find("-l2", 1, true) ~= nil and proj.diff:find("+X", 1, true) ~= nil,
      "2.2 projection diff describes change")
    local res = results[1]
    assert_notnil(diffmod.parse(res.body), "2.3 write body is a diff")
    assert_true(res.summary:find("+1", 1, true) ~= nil and res.summary:find("−1", 1, true) ~= nil,
      "2.3 write summary +N −M")
    assert_true(res.summary:find("overwritten", 1, true) ~= nil, "2.3 write summary overwritten")
    local hist
    for _, m in ipairs(a.get_history()) do if m.role == "tool" then hist = m.content end end
    assert_eq(hist, res.body, "2.3 history body equals UI body")
  end

  -- 2.2 new file projects a creation diff
  do
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c2", name = "write" },
        { type = "tool_call_delta", id = "c2", arguments = pc.json_encode({ path = "new.txt", content = "a\nb\n" }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    local starts = turn_events(a)
    local proj = starts[1] and starts[1].projection
    assert_eq(proj and proj.kind, "new", "2.2 new file projection kind")
    assert_true(proj.diff:find("@@ -0,0 +1,2 @@", 1, true) ~= nil, "2.2 new file creation diff")
  end

  -- 2.2 patch projects the submitted diff; 2.3 body is that diff
  do
    write_file("p.txt", "a\nb\n")
    local patchstr = "--- a/p.txt\n+++ b/p.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n"
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c3", name = "patch" },
        { type = "tool_call_delta", id = "c3", arguments = pc.json_encode({ patch = patchstr }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    local starts, results = turn_events(a)
    local proj = starts[1] and starts[1].projection
    assert_eq(proj and proj.kind, "patch", "2.2 patch projection kind")
    assert_eq(proj.add, 1, "2.2 patch add count")
    assert_eq(proj.del, 1, "2.2 patch del count")
    assert_true(results[1].body:find("+B", 1, true) ~= nil, "2.3 patch body is the diff")
  end

  -- 2.2 oversized / outside-workspace / non-write tools: no projection, no read
  do
    write_file("big.txt", string.rep("z\n", 600000))
    local helper = fresh()
    local before = read_file("big.txt")
    local c = { workspace = ws }
    assert_eq(helper._projection_for("write", { path = "big.txt", content = "x" }, c), nil,
      "2.2 oversized target: no projection")
    assert_eq(read_file("big.txt"), before, "2.2 oversized target file unchanged")
    assert_eq(helper._projection_for("write", { path = "/etc/passwd", content = "x" }, c), nil,
      "2.2 outside workspace: no projection")
    assert_eq(helper._projection_for("read", { path = "big.txt" }, c), nil,
      "2.2 other tools: no projection")
  end

  -- 2.4 oversized previous content falls back to the written path, no counts
  do
    write_file("big2.txt", string.rep("z\n", 600000))
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c4", name = "write" },
        { type = "tool_call_delta", id = "c4", arguments = pc.json_encode({ path = "big2.txt", content = "small\n" }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    local _, results = turn_events(a)
    assert_eq(results[1].body, "big2.txt", "2.4 oversized fallback body is the path")
    assert_true(results[1].summary:find("−", 1, true) == nil, "2.4 fallback summary has no diff counts")
    assert_true(results[1].summary:find("B", 1, true) ~= nil, "2.4 fallback summary keeps byte form")
  end

  -- 2.4 a failed call keeps its error body and error summary
  do
    write_file("p2.txt", "a\nb\n")
    local bad = "--- a/p2.txt\n+++ b/p2.txt\n@@ -1,2 +1,2 @@\n x\n-y\n+Y\n"
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c5", name = "patch" },
        { type = "tool_call_delta", id = "c5", arguments = pc.json_encode({ patch = bad }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    local _, results = turn_events(a)
    assert_notnil(results[1].error, "2.4 failed call reports error")
    assert_true(results[1].body:find("conflict", 1, true) ~= nil, "2.4 error body is kept")
    assert_true(results[1].summary:find("✗", 1, true) ~= nil, "2.4 error summary uses the failure marker")
  end

  -- 2.5 other tools keep their body/summary; truncation still applies
  do
    local a = fresh()
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c6", name = "run" },
        { type = "tool_call_delta", id = "c6", arguments = pc.json_encode({ command = "echo hi" }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    local _, results = turn_events(a)
    assert_true(results[1].summary:find("exit", 1, true) ~= nil, "2.5 run summary unchanged")

    local a2 = fresh()
    local bigout = string.rep("L", 20000)
    _G.tools.run = function() return { output = bigout, exit_code = 0, elapsed_ms = 1 } end
    _G.api = { stream = scripted({
      { { type = "tool_call_start", id = "c7", name = "run" },
        { type = "tool_call_delta", id = "c7", arguments = pc.json_encode({ command = "x" }) } },
      { { type = "text_delta", text = "ok" } },
    }) }
    turn_events(a2)
    local hist
    for _, m in ipairs(a2.get_history()) do if m.role == "tool" then hist = m.content end end
    assert_true(hist and hist:find("truncated", 1, true) ~= nil, "2.5 TOOL_BODY_MAX truncation still applies")
  end

  for _, n in ipairs({"tether","config","session","api","agent","context","tools","diff","provider_common"}) do
    _G[n] = saved[n]
  end
  os.execute("rm -rf " .. ws)
  print("2.1-2.5 agent projection/diff bodies: OK")
end

-- === pretty-transcript-rendering: UI rows/expansion/diffs (3.1-4.6) ====
do
  local diffmod = assert(loadfile("src/tether/diff.lua"))()

  local uimod, S = run_ui_with({ 17 }, {})
  local strip = uimod.strip_sgr
  local function boot()
    local m, st = run_ui_with({ 17 }, {})
    return m, st
  end
  local function set_tools(m, st, list)
    m._transcript.reset({})
    st.expand_all = false
    st.scroll = 0
    st.user_scrolled = false
    for _, e in ipairs(list) do
      e.role = "tool"
      m._transcript.append(e)
    end
    m._invalidate_all()
    return m._transcript.entries()
  end

  -- 3.1 status marker + clipped first error line
  do
    local m, st = boot()
    local e = set_tools(m, st, { { name = "read", status = "ok", summary = "214 стр.", body = "abc" } })[1]
    assert_true(strip(m._render_all(80)[1]):find("✓ read", 1, true) ~= nil,
      "3.1 success row leads with the done glyph")
    -- tool rows name their primary argument (which file ran what)
    local m2, st2 = boot()
    local labelled = set_tools(m2, st2, {
      { name = "read", status = "ok", summary = "214 стр.",
        args = { path = "src/tether/ui.lua" } },
      { name = "run", status = "ok", summary = "exit 0",
        args = { command = "npm test" } },
      { name = "grep", status = "ok", summary = "3 совп.",
        args = { pattern = "scroll", path = "src" } },
    })
    assert_eq(#labelled, 3, "3.1a labelled rows built")
    local all = strip(table.concat(m2._render_all(120), "\n"))
    assert_true(all:find("src/tether/ui.lua", 1, true) ~= nil,
      "3.1a read row shows the path")
    assert_true(all:find("npm test", 1, true) ~= nil,
      "3.1a run row shows the command")
    assert_true(all:find("scroll", 1, true) ~= nil,
      "3.1a grep row shows the pattern")
    assert_eq(m2._tool_arg_label("patch", { patch = "--- a/src/x.lua\n+++ b/src/x.lua\n" }),
      "src/x.lua", "3.1a patch label is the target file")
    local f = set_tools(m, st, { { name = "run", status = "error", summary = "✗ boom1",
      body = "boom1\nboom2\nboom3\nboom4" } })[1]
    local rows = m._render_all(60)
    assert_eq(#rows, 1, "3.1 failed row occupies exactly one row")
    assert_true(strip(rows[1]):find("✗ run", 1, true) == 1, "3.1 failed row starts with ✗ run")
    assert_true(strip(rows[1]):find("boom1", 1, true) ~= nil, "3.1 first error line visible")
    assert_true(strip(rows[1]):find("boom2", 1, true) == nil, "3.1 later error lines hidden")
    assert_true(m.vlen(rows[1]) <= 60, "3.1 failed row stays within the width")
    f.expand_state = "expanded"
    m._invalidate_all()
    assert_true(strip(table.concat(m._render_all(60), "\n")):find("boom4", 1, true) ~= nil,
      "3.1 full error behind expansion")
    f.expand_state = nil
    m._ascii_mode = true
    m._invalidate_all()
    assert_true(strip(m._render_all(80)[1]):find("[x] run", 1, true) ~= nil,
      "3.1 ascii failure marker")
    m._ascii_mode = nil
  end

  -- 3.2 sanitize_output
  do
    local m, st = boot()
    local s = m.sanitize_output("abc\27[2K\27]0;title\7def\r\nghi\rj")
    assert_true(s:find("\27", 1, true) == nil, "3.2 no escape sequence survives")
    assert_true(s:find("title", 1, true) == nil, "3.2 OSC dropped")
    assert_true(s:find("\r", 1, true) == nil, "3.2 carriage returns dropped")
    assert_eq(s, "abcdef\nghij", "3.2 visible text only")
    assert_eq(m.sanitize_output("a\27[31mb\27[0m"), "a\27[31mb\27[0m", "3.2 SGR survives while colour on")
    m._ascii_mode = true
    assert_eq(m.sanitize_output("a\27[31mb\27[0m"), "ab", "3.2 colour off strips SGR")
    m._ascii_mode = nil
    assert_eq(m.sanitize_output("a\n\n\n\nb"), "a\n\nb", "3.2 blank-line runs collapse")
    local e = set_tools(m, st, { { name = "run", status = "ok", summary = "exit 0",
      body = "x\27[2Ky\r" } })[1]
    local before = e.body
    m._invalidate_all()
    m._render_all(80)
    assert_eq(e.body, before, "3.2 stored body stays raw")
  end

  -- 3.3 per-entry / all-entries expansion
  do
    local m, st = boot()
    st.kb_protocol = 1
    local list = set_tools(m, st, {
      { name = "read", status = "ok", summary = "1 стр.", body = "a" },
      { name = "read", status = "ok", summary = "2 стр.", body = "b" },
    })
    m._handle_key({ kind = "ctrl", code = 15, shift = false })
    assert_eq(list[2].expand_state, "expanded", "3.3 ctrl+o toggles the newest visible entry")
    assert_eq(list[1].expand_state, nil, "3.3 the older entry is untouched")
    assert_eq(m.transcript_height(80), #m._render_all(80), "3.3 height exact after per-entry toggle")
    m._handle_key({ kind = "ctrl", code = 15, shift = true })
    assert_eq(st.expand_all, true, "3.3 ctrl+shift+o expands all")
    assert_eq(list[1].expand_state, nil, "3.3 ctrl+shift+o clears per-entry state")
    assert_eq(list[2].expand_state, nil, "3.3 ctrl+shift+o clears per-entry state (2)")
    st.kb_protocol = 0
    m._handle_key({ kind = "ctrl", code = 15, shift = false })
    assert_eq(st.expand_all, false, "3.3 plain terminal keeps ctrl+o = expand-all")
  end

  -- 3.3 ctrl+o with no tool row in the viewport falls back to the newest tool
  do
    local m, st = boot()
    st.kb_protocol = 1
    m._transcript.reset({ { role = "tool", name = "read", status = "ok", summary = "1 стр.", body = "a" } })
    for i = 1, 60 do
      m._transcript.append({ role = "system", text = "row " .. i })
    end
    m._invalidate_all()
    st.scroll = 10
    st.user_scrolled = true
    m._handle_key({ kind = "ctrl", code = 15, shift = false })
    assert_eq(m._transcript.entries()[1].expand_state, "expanded",
      "3.3 ctrl+o falls back to the newest tool when the viewport holds none")
  end

  -- 3.4 click toggling under ui.mouse = "on" / "auto"
  do
    local m, st = boot()
    st.cfg.ui = st.cfg.ui or {}
    st.cfg.ui.mouse = "on"
    local e = set_tools(m, st, { { name = "grep", status = "ok", summary = "1 совп.", body = "a" } })[1]
    m._handle_key({ kind = "mouse", name = "press", row = 1, col = 1, button = 0 })
    assert_eq(e.expand_state, "expanded", "3.4 click toggles the entry")
    st.cfg.ui.mouse = "auto"
    e.expand_state = nil
    m._invalidate_all()
    m._handle_key({ kind = "mouse", name = "press", row = 1, col = 1, button = 0 })
    assert_eq(e.expand_state, nil, "3.4 auto mode delivers no transcript click")
  end

  -- 3.5 keymap documents the new bindings
  do
    assert_notnil(uimod.KEYMAP["ctrl+shift+o"], "3.5 ctrl+shift+o documented")
    assert_true(uimod.KEYMAP["ctrl+o"]:find("tool", 1, true) ~= nil, "3.5 ctrl+o documents the per-entry toggle")
  end

  -- 4.1 tool body highlighting
  do
    local m, st = boot()
    st.cfg.ui = st.cfg.ui or {}
    st.cfg.ui.highlight = "on"
    local e = set_tools(m, st, { { name = "read", status = "ok", summary = "1 стр.",
      body = "1\tlocal x = 1 -- comment", path = "src/a.lua", expand_state = "expanded" } })[1]
    local on = m._render_all(80)
    assert_true(table.concat(on):find("\27[", 1, true) ~= nil, "4.1 lua read body is coloured")
    st.cfg.ui.highlight = "off"
    m._invalidate_all()
    local off = m._render_all(80)
    st.cfg.ui.highlight = "on"
    m._invalidate_all()
    local on2 = m._render_all(80)
    assert_eq(#on2, #off, "4.1 strip-equality: same row count")
    for i = 1, #on2 do
      assert_eq(strip(on2[i]), strip(off[i]), "4.1 strip equals plain row " .. i)
      assert_eq(m.vlen(on2[i]), m.vlen(off[i]), "4.1 identical geometry row " .. i)
    end
    set_tools(m, st, { { name = "read", status = "ok", summary = "1 стр.",
      body = "1\tlocal x", path = "a.xyz", expand_state = "expanded" } })
    local urows = m._render_all(80)
    local ubody = {}
    for i = 2, #urows do ubody[#ubody + 1] = urows[i] end
    assert_true(table.concat(ubody):find("\27[", 1, true) == nil,
      "4.1 unknown extension stays plain")
    set_tools(m, st, { { name = "run", status = "ok", summary = "exit 0",
      body = "local x = 1", expand_state = "expanded" } })
    local rrows = m._render_all(80)
    local rbody = {}
    for i = 2, #rrows do rbody[#rbody + 1] = rrows[i] end
    assert_true(table.concat(rbody):find("\27[", 1, true) == nil,
      "4.1 run body stays plain")
    set_tools(m, st, { { name = "grep", status = "ok", summary = "2 совп.", expand_state = "expanded",
      body = "a.lua:1: local x = 1\nb.json:1: {\"a\":1}" } })
    assert_true(table.concat(m._render_all(80)):find("\27[", 1, true) ~= nil,
      "4.1 grep rows follow their own paths")
  end

  -- 4.2 write/patch rendered as a unified diff, plain fallback
  do
    local m, st = boot()
    st.cfg.ui = st.cfg.ui or {}
    st.cfg.ui.highlight = "on"
    local dtxt = diffmod.unified("l1\nl2\nl3\nl4\nl5\n", "l1\nl2\nl3\nX\nl5\n", "a/w.lua", "b/w.lua")
    set_tools(m, st, { { name = "write", status = "ok", summary = "+1 −1 перезаписан",
      body = dtxt, path = "w.lua", expand_state = "expanded" } })
    local joined = table.concat(m._render_all(80), "\n")
    assert_true(strip(joined):find("+X", 1, true) ~= nil, "4.2 added line rendered")
    assert_true(strip(joined):find("-l4", 1, true) ~= nil, "4.2 removed line rendered")
    assert_true(joined:find("\27[", 1, true) ~= nil, "4.2 diff coloured")
    set_tools(m, st, { { name = "write", status = "ok", summary = "+1 B",
      body = "just text", path = "w.txt", expand_state = "expanded" } })
    assert_true(strip(table.concat(m._render_all(80), "\n")):find("just text", 1, true) ~= nil,
      "4.2 non-diff body renders as plain text")
  end

  -- 4.3 word-level emphasis and mono degradation
  do
    local m, st = boot()
    st.cfg.ui = st.cfg.ui or {}
    st.cfg.ui.highlight = "on"
    local dtxt = diffmod.unified("local foo = 1\n", "local foo = 2\n")
    set_tools(m, st, { { name = "write", status = "ok", summary = "+1 −1 перезаписан",
      body = dtxt, path = "w.lua", expand_state = "expanded" } })
    local joined = table.concat(m._render_all(80), "")
    assert_true(joined:find("\27[2m", 1, true) ~= nil, "4.3 carried words rendered muted")
    m.set_theme("mono")
    m._invalidate_all()
    assert_true(table.concat(m._render_all(80), ""):find("\27[", 1, true) == nil,
      "4.3 mono theme renders without emphasis or escapes")
    m.set_theme("default")
    -- over-long line skips emphasis; row still one per line
    local long = string.rep("x ", 300)
    local dtxt2 = diffmod.unified(long .. "\n", long .. "y\n")
    set_tools(m, st, { { name = "write", status = "ok", summary = "+1 −1 перезаписан",
      body = dtxt2, path = "w.lua", expand_state = "expanded" } })
    assert_true(table.concat(m._render_all(80), ""):find("\27[", 1, true) ~= nil,
      "4.3 over-long diff still renders")
  end

  -- 4.4 summary meter
  do
    local m, st = boot()
    set_tools(m, st, { { name = "write", status = "ok", summary = "+12 −3 перезаписан", path = "w.lua" } })
    local head = strip(m._render_all(80)[1])
    assert_true(head:find("+12 −3", 1, true) ~= nil, "4.4 summary counts")
    assert_true(head:find("━", 1, true) ~= nil, "4.4 meter present")
    set_tools(m, st, { { name = "write", status = "ok", summary = "+34 −0 создан", path = "n.lua" } })
    assert_true(strip(m._render_all(80)[1]):find("━", 1, true) ~= nil, "4.4 created meter present")
    m._ascii_mode = true
    m._invalidate_all()
    assert_true(strip(m._render_all(80)[1]):find("#", 1, true) ~= nil, "4.4 ascii meter uses #")
    m._ascii_mode = nil
  end

  -- 4.5 pending projection, result replacement and denial drop
  do
    local m, st = boot()
    local proj = { path = "w.lua", kind = "overwrite", diff = "@@ -1 +1 @@\n-a\n+b\n", add = 1, del = 1 }
    local e = set_tools(m, st, { { id = "x", name = "write", status = "pending", summary = "",
      body = proj.diff, projection = proj, path = "w.lua" } })[1]
    assert_true(strip(m._render_all(80)[1]):find("write", 1, true) ~= nil, "4.5 pending row rendered")
    e.expand_state = "expanded"
    m._invalidate_all()
    assert_true(strip(table.concat(m._render_all(80), "\n")):find("+b", 1, true) ~= nil,
      "4.5 pending projection is expandable")
    set_tools(m, st, { { id = "x", name = "write", status = "pending", summary = "",
      body = proj.diff, projection = proj, path = "w.lua" } })
    m._handle_agent_event({ type = "tool_result", id = "x", name = "write",
      summary = "+1 −1 перезаписан", body = "NEWBODY" })
    assert_eq(tentries(m)[1].body, "NEWBODY", "4.5 result replaces the preview")
    assert_eq(tentries(m)[1].projection, nil, "4.5 projection cleared on result")
    set_tools(m, st, { { id = "y", name = "write", status = "pending", summary = "",
      body = proj.diff, projection = proj, path = "w.lua" } })
    m._handle_agent_event({ type = "tool_result", id = "y", name = "write",
      error = "denied by user", summary = "✗ denied by user", body = "denied by user" })
    assert_eq(tentries(m)[1].body, "", "4.5 denied call drops the preview/result body")
    assert_eq(tentries(m)[1].projection, nil, "4.5 denied call clears the projection")
  end

  -- 4.6 virtualization invariants with the new row shapes
  do
    local m, st = boot()
    st.cfg.ui = st.cfg.ui or {}
    st.cfg.ui.highlight = "on"
    local old = string.rep("line\n", 50)
    local new = string.rep("line\n", 49) .. "CHANGED\n"
    local dtxt = diffmod.unified(old, new)
    local e = set_tools(m, st, { { name = "write", status = "ok", summary = "+1 −1 перезаписан",
      body = dtxt, path = "w.lua" } })[1]
    assert_eq(m.transcript_height(80), #m._render_all(80), "4.6 collapsed parity")
    e.expand_state = "expanded"
    m._touch_entry(e)
    assert_eq(m.transcript_height(80), #m._render_all(80), "4.6 per-entry toggle keeps parity")
    assert_true(m.cache_rows() <= math.max(4 * (st.h - 6), 1024) + 64, "4.6 large diff respects the cache bound")
  end

  print("3.1-4.6 UI rows/expansion/diffs: OK")
end

-- T82 (2.1): the palette window helper is pure — at most 8 rows and at most
-- half the terminal height, never below one, with the offset keeping the
-- selected row inside the window.
do
  local pal = assert(loadfile("src/tether/ui/palette.lua"))()
  local function inside(h, n, sel)
    local w, o = pal.window(h, n, sel)
    return sel >= o and sel <= o + w - 1
  end
  assert_eq(pal.window(24, 20, 1), 8, "T82 window capped at 8 rows")
  assert_eq(pal.window(12, 20, 1), 6, "T82 half the terminal shrinks the window")
  assert_eq(pal.window(24, 3, 2), 3, "T82 a short list fits its own window")
  assert_eq(pal.window(24, 0, 1), 0, "T82 no entries, no window")
  assert_eq(pal.window(1, 5, 3), 1, "T82 the window never drops below one row")
  assert_true(inside(24, 20, 1), "T82 selection stays inside (first)")
  assert_true(inside(24, 20, 10), "T82 selection stays inside (middle)")
  assert_true(inside(24, 20, 20), "T82 selection stays inside (last)")
  assert_true(inside(12, 20, 7), "T82 selection stays inside on a short terminal")
  local _, o = pal.window(24, 20, 10)
  assert_true(o > 1, "T82 the window shifts off the first entry")
  print("T82 2.1 palette window: OK")
end

-- T-missing-paths: nonexistent paths resolve lexically for containment (a
-- new file inside the workspace is not "outside"), and write creates
-- missing parents (an approved write must not die on a missing dir).
-- Regression: realpath fails on missing paths, so within_workspace said
-- "outside" for every new file (bogus menu), and atomic_write's sibling
-- temp file then failed with "cannot open temp file" (bogus ✗).
do
  local ws = os.tmpname()
  os.remove(ws)
  assert(host_fs.mkdirp(ws))
  local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
  _G.tether = host_mock{
    getcwd = function() return ws end,
    -- faithful realpath: fails on missing paths, like the C host. `-e` matters:
    -- bare coreutils realpath tolerates a missing LAST component, while
    -- realpath(3) (src/host/main.c:437) requires every component to exist, so
    -- without the flag the lexical walk stops one level too deep.
    realpath = function(p)
      local f = io.popen("realpath -e " .. shq(p) .. " 2>/dev/null")
      if not f then return nil end
      local out = f:read("*a") or ""
      f:close()
      out = out:gsub("%s+$", "")
      if out == "" then return nil end
      return out
    end,
  }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = ws }
  -- missing file inside the workspace: contained, not outside
  local inside_missing = tools._resolve("newdir/newfile.lua", cfg)
  assert_true(tools._within(inside_missing, cfg),
    "T-missing-paths missing inside path is within workspace")
  -- missing file outside the workspace: still outside (no silent pass)
  local outside_missing = ws .. "/../tether_outside_probe_x7q/file.lua"
  assert_false(tools._within(outside_missing, cfg),
    "T-missing-paths missing outside path stays outside")
  -- TP2: a MISSING intermediate plus enough ".." must not read as contained.
  -- Regression: realpath_lexical cancelled the surplus ".." with table.remove
  -- on an empty list, so ws/newdir2/../../<outside>/file.lua answered
  -- "inside" — and atomic_write's new mkdirp then created newdir2, at which
  -- point the kernel resolved that very string above the workspace.
  local crafted = ws .. "/newdir2/../../tether_outside_probe_x7q/file.lua"
  assert_false(tools._within(crafted, cfg),
    "TP2 surplus .. above the existing ancestor stays outside")
  assert_false(tools._within("newdir2/../../tether_outside_probe_x7q/file.lua", cfg),
    "TP2 relative crafted traversal stays outside")
  -- a .. that cancels a named missing component is still contained
  assert_true(tools._within(ws .. "/a/../b/file.lua", cfg),
    "TP2 cancelling .. inside the missing tail stays inside")
  -- existing outside path: still outside
  assert_false(tools._within("/etc/hosts", cfg),
    "T-missing-paths existing outside path stays outside")
  -- write creates missing parents
  local res, err = tools.write(
    { path = "newdir/newfile.lua", content = "hello-new" }, cfg)
  assert_notnil(res, "T-missing-paths write into missing dir succeeds: " .. tostring(err))
  local f = assert(io.open(ws .. "/newdir/newfile.lua", "r"))
  assert_eq(f:read("*a"), "hello-new", "T-missing-paths written content lands")
  f:close()
  -- patch creating a new file in a missing dir
  local pres, perr = tools.patch(
    "--- /dev/null\n+++ b/other/new.lua\n@@ -0,0 +1 @@\n+brand new\n", cfg)
  assert_notnil(pres, "T-missing-paths patch into missing dir succeeds: " .. tostring(perr))
  local pf = assert(io.open(ws .. "/other/new.lua", "r"))
  assert_true((pf:read("*a") or ""):find("brand new", 1, true) ~= nil,
    "T-missing-paths patched content lands")
  pf:close()
  os.execute("rm -rf " .. shq(ws))
  print("T-missing-paths nonexistent paths resolve + write: OK")
end

if failed > 0 then
    os.exit(1)
end

-- T83 (2.2/2.3/2.4/2.5/3.1): frames — the window follows the selection, the
-- overflow indicator sits in the row the reserved region already holds and is
-- built from digits and `/` only, a short terminal shrinks the window and drops
-- the indicator instead of painting over the separator or the status line, the
-- argument hint is visible on a skill row only, and a palette click is resolved
-- through the window offset.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local function many_skills()
    local out = {}
    for i = 1, 12 do
      out[i] = {
        name = "skill" .. string.format("%02d", i),
        description = "desc " .. i,
        path = "/tmp/skills/s" .. i .. "/SKILL.md",
      }
    end
    return out
  end
  local function boot(stub, size)
    local uimod = run_ui_with({ 17 }, { agent = agent_stub, size = size })
    uimod._skills_stub = stub
    return uimod
  end
  local function type_text(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
  end
  local function rows_with(uimod, S, needle)
    local out = {}
    for r = 1, S.h do
      if strip(uimod._row(r)):find(needle, 1, true) then out[#out + 1] = r end
    end
    return out
  end

  -- 2.2/2.3: 22 entries on a 24-row terminal → an 8-row window plus indicator
  -- add-provider-login: /login /logout; add-reasoning-level: /think → 10 + 12
  local uimod = boot(many_skills)
  type_text(uimod, "/")
  uimod._paint(true)
  local S = uimod._get_state()
  local L = uimod._layout()
  assert_eq(#S.palette_items, 22, "T83 twelve skills join the ten commands")
  local win, off = uimod._palette.window(S.h, #S.palette_items, S.palette_sel)
  assert_eq(win, 8, "T83 eight window rows")
  assert_eq(off, 1, "T83 the first entry starts the window")
  local painted = 0
  for i = 1, win do
    if strip(uimod._row(L.palette_row + i)):find("/", 1, true) then painted = painted + 1 end
  end
  assert_eq(painted, win, "T83 every window row is painted")
  assert_true(strip(uimod._row(L.palette_row + win + 1)):match("^%s*1/22%s*$") ~= nil,
    "T83 the indicator is digits and a slash")
  assert_true(L.palette_row + win + 1 <= L.footer_row - 1, "T83 the indicator row is inside the region")

  -- 2.2: the window follows the selection
  for _ = 1, 10 do uimod._handle_key({ kind = "special", name = "down" }) end
  uimod._paint(true)
  S = uimod._get_state()
  local win2 = uimod._palette.window(S.h, #S.palette_items, S.palette_sel)
  assert_eq(S.palette_sel, 11, "T83 the selection moved to the 11th entry")
  assert_eq(#rows_with(uimod, S, "/clear"), 0, "T83 the first entry is no longer painted")
  assert_true(#rows_with(uimod, S, S.palette_items[S.palette_sel].label) > 0,
    "T83 the selected entry is painted")
  assert_true(strip(uimod._row(L.palette_row + win2 + 1)):match("^%s*11/22%s*$") ~= nil,
    "T83 the indicator follows the selection")
  assert_true(strip(uimod._row(L.rule_bottom_row)):find("─", 1, true) ~= nil,
    "T83 the box bottom rule survives the palette")
  assert_true(strip(uimod._row(L.stats_row)):find("test", 1, true) ~= nil,
    "T83 the stats footer keeps its content")

  -- 3.1: the hint is on the skill row only
  -- add-provider-login + add-reasoning-level: 10 commands + 1 skill = 11 > win 8
  -- — command (pos 1) and skill (pos 11) never share one window; check each
  -- via its own filter.
  local one = boot(function() return {
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" } } end)
  type_text(one, "/")
  assert_eq(#one._get_state().palette_items, 11, "T83 eleven entries listed")
  -- skill row: narrow to the skill, paint, require the hint
  type_text(one, "dep")
  one._paint(true)
  local S1 = one._get_state()
  local L1 = one._layout()
  local skill_rows = rows_with(one, S1, "/deploy")
  assert_eq(#skill_rows, 1, "T83 the skill row is painted")
  assert_true(strip(one._row(skill_rows[1])):find("[s] deploy stuff", 1, true) ~= nil,
    "T83 the skill row marks its description with [s]")
  -- command row: fresh palette, no filter, top window has /clear without a hint
  local cmdui = boot(function() return {
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" } } end)
  type_text(cmdui, "/")
  cmdui._paint(true)
  local SCmd = cmdui._get_state()
  local LCmd = cmdui._layout()
  local command_rows = rows_with(cmdui, SCmd, "/clear")
  assert_eq(#command_rows, 1, "T83 the command row is painted")
  assert_true(strip(cmdui._row(command_rows[1])):find("[", 1, true) == nil,
    "T83 the command row shows no hint")
  -- descriptions align: the name column is padded to the widest name+hint
  -- across ALL listed entries, so command rows and the hinted skill row
  -- start their descriptions at the same column.
  local function widest_label(items)
    local lw = 0
    for _, it in ipairs(items) do
      local l = it.label or ""
      if it.hint then l = l .. " " .. it.hint end
      if #l > lw then lw = #l end
    end
    return lw
  end
  local lwcmd = widest_label(SCmd.palette_items)
  local _, offcmd = cmdui._palette.window(SCmd.h, #SCmd.palette_items, SCmd.palette_sel)
  for i = 1, 8 do
    local it = SCmd.palette_items[offcmd + i - 1]
    if it and it.desc and it.desc ~= "" then
      local row = strip(cmdui._row(LCmd.palette_row + i))
      local col = row:find(it.desc, 1, true)
      -- gutter (ui.padding) shifts every painted row right by one column
      local gutter = cmdui.ui_padding(LCmd.w)
      assert_eq(col, gutter + lwcmd + 3,
        "T83 descriptions align on row " .. i .. " (" .. it.label .. "), col " .. tostring(col))
    end
  end
  local lwski = widest_label(S1.palette_items)
  local gutter_ski = one.ui_padding(one._layout().w)
  assert_eq(strip(one._row(skill_rows[1])):find("[s] deploy stuff", 1, true),
    gutter_ski + lwski + 3,
    "T83 the skill description column aligns with the command rows")
  -- 10 > 8: an indicator is expected on the scrolling window
  local _, off0 = cmdui._palette.window(SCmd.h, #SCmd.palette_items, SCmd.palette_sel)
  assert_true(off0 == 1 and #SCmd.palette_items > 8,
    "T83 the window scrolls and needs an indicator")
  assert_true(strip(cmdui._row(LCmd.palette_row + 8 + 1)):match("%d+/%d+") ~= nil,
    "T83 the indicator is painted for a scrolling window")

  -- 2.5: a click is resolved through the window offset
  -- 22 items: 12 downs → sel=13, off=9, third painted row = item 11 = first skill
  local m = boot(many_skills)
  type_text(m, "/")
  for _ = 1, 12 do m._handle_key({ kind = "special", name = "down" }) end
  local Sm = m._get_state()
  local Lm = m._layout()
  local _, offm = m._palette.window(Sm.h, #Sm.palette_items, Sm.palette_sel)
  local target = Sm.palette_items[offm + 2] -- the third painted row
  assert_notnil(target, "T83 the third painted row has an entry")
  assert_true(target.skill, "T83 the third painted row is a skill")
  m._handle_key({ kind = "mouse", name = "press", row = Lm.palette_row + 3, col = 5, button = 0 })
  Sm = m._get_state()
  assert_eq(Sm.input, "/" .. target.name .. " ", "T83 the click follows the window offset")

  -- 2.5: the indicator row selects nothing
  local m2 = boot(many_skills)
  type_text(m2, "/")
  for _ = 1, 10 do m2._handle_key({ kind = "special", name = "down" }) end
  local S2 = m2._get_state()
  local L2 = m2._layout()
  local w2 = m2._palette.window(S2.h, #S2.palette_items, S2.palette_sel)
  local sel_before, input_before = S2.palette_sel, S2.input
  m2._handle_key({ kind = "mouse", name = "press", row = L2.palette_row + w2 + 1, col = 5, button = 0 })
  S2 = m2._get_state()
  assert_eq(S2.palette_sel, sel_before, "T83 the indicator row selects nothing")
  assert_eq(S2.input, input_before, "T83 the indicator row changes no input")
  assert_true(S2.palette_active, "T83 the palette stays open")

  -- 2.4: a 12-row terminal halves the window; the new dock budget
  -- (top rule + input + palette + bottom rule + 2 footer rows) leaves room
  -- for the entry rows, and the indicator only when one row remains.
  local t12 = boot(many_skills, { width = 80, height = 12 })
  type_text(t12, "/")
  t12._paint(true)
  local S12 = t12._get_state()
  local L12 = t12._layout()
  local w12 = t12._palette.window(S12.h, #S12.palette_items, S12.palette_sel)
  assert_eq(w12, 6, "T83 a 12-row terminal shrinks the window to half")
  -- The dock budget may shrink the reserved region below the ideal window+2
  -- (the transcript minimum takes priority); what must
  -- hold is that entries still paint inside the region and never past it.
  assert_true(L12.palette_h >= 1, "T83 the reserved region is non-empty")
  assert_true(L12.palette_h <= w12 + 3, "T83 the reserved region is at most window+3")
  local painted12 = 0
  local last12 = L12.palette_row + L12.palette_h
  for r = L12.palette_row + 1, last12 do
    if strip(t12._row(r)):find("/", 1, true) then painted12 = painted12 + 1 end
  end
  assert_true(painted12 >= 1, "T83 the short terminal still paints palette entries")
  local irow12 = L12.palette_row + w12 + 1
  if irow12 <= last12 then
    assert_true(strip(t12._row(irow12)):match("^%s*1/21%s*$") ~= nil,
      "T83 the indicator fits when the region has room")
  end
  assert_true(strip(t12._row(L12.rule_bottom_row)):find("─", 1, true) ~= nil,
    "T83 bottom rule intact on a short terminal")
  assert_true(strip(t12._row(L12.footer_row)) ~= nil and strip(t12._row(L12.footer_row)) ~= "",
    "T83 footer row intact on a short terminal")
  assert_true(strip(t12._row(L12.stats_row)):find("test", 1, true) ~= nil,
    "T83 stats footer intact on a short terminal")

  -- 2.3: on an 8-row terminal the indicator has no room: it is dropped and the
  -- palette paints nothing over the bottom rule or the footer
  local t8 = boot(many_skills, { width = 80, height = 8 })
  type_text(t8, "/")
  t8._paint(true)
  local S8 = t8._get_state()
  local L8 = t8._layout()
  local w8 = t8._palette.window(S8.h, #S8.palette_items, S8.palette_sel)
  assert_true(L8.palette_row + w8 + 1 > L8.footer_row - 1, "T83 the indicator row is outside the region")
  for r = L8.palette_row + 1, L8.footer_row - 1 do
    assert_true(strip(t8._row(r)):match("%d+/%d+") == nil,
      "T83 no indicator is painted when it does not fit (row " .. r .. ")")
  end
  -- palette-hints: on an 8-row terminal the region shrinks to the hint alone —
  -- the entry window is cut first, the hint is the last content standing.
  -- footer-separator: the rule above the footer keeps its row even then.
  assert_true(strip(t8._row(L8.footer_row - 1)):find("─", 1, true) ~= nil,
    "T83 the separator rule survives the shrink on an 8-row terminal")
  assert_true(strip(t8._row(L8.footer_row - 2)):find("select", 1, true) ~= nil,
    "T83 the hint row survives the shrink on an 8-row terminal")
  assert_true(strip(t8._row(L8.rule_bottom_row)):find("─", 1, true) ~= nil,
    "T83 the bottom rule is never painted by the palette")
  assert_true(strip(t8._row(L8.footer_row)) ~= nil and strip(t8._row(L8.footer_row)) ~= "",
    "T83 the footer row is never painted by the palette")
  assert_true(strip(t8._row(L8.stats_row)):find("test", 1, true) ~= nil,
    "T83 the stats footer is never painted by the palette")

  print("T83 2.2-3.1 window/indicator/hint frames: OK")
end

-- T84 (1.2): Tab completion resolves tools through the host global — the
-- production lookup path, with no M._tools_stub in play. Regression: ui.lua
-- looked the module up with require("tools"), which the host does not provide
-- (modules are globals, main.c load_module), so Tab was a silent no-op in the
-- binary while every stubbed test still passed.
do
  local orig_tools = _G.tools
  local real_tools = { path_complete = function(token, _cfg)
    if token == "src/tether/ag" then
      return { candidates = { "src/tether/agent.lua" }, truncated = false }
    end
    return { candidates = {}, truncated = false }
  end }
  local uimod = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._tools_stub = nil
  _G.tools = real_tools -- the harness restores globals after run()

  local input = "src/tether/ag"
  for i = 1, #input do
    uimod._handle_key({ kind = "text", char = input:sub(i, i) })
  end
  uimod._handle_key({ kind = "tab" })
  local S = uimod._get_state()
  assert_eq(S.input, "src/tether/agent.lua", "T84 Tab completes through the host global")
  assert_eq(S.cursor, #S.input, "T84 cursor follows the completion")
  assert_true(S.cursor <= #S.input, "T84 cursor never moves past the end of the input")

  -- a token with no candidate leaves the input alone (the lookup still worked)
  local uimod2 = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod2._tools_stub = nil
  _G.tools = real_tools
  for i = 1, #"src/nope" do
    uimod2._handle_key({ kind = "text", char = ("src/nope"):sub(i, i) })
  end
  uimod2._handle_key({ kind = "tab" })
  assert_eq(uimod2._get_state().input, "src/nope", "T84 no candidate leaves the input alone")

  -- the production path keeps text after the token too, with the cursor left
  -- directly after the completed path and before that text
  local uimod3 = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod3._tools_stub = nil
  _G.tools = real_tools
  local tailed = "src/tether/ag.bak"
  for i = 1, #tailed do
    uimod3._handle_key({ kind = "text", char = tailed:sub(i, i) })
  end
  for _ = 1, 4 do uimod3._handle_key({ kind = "special", name = "left" }) end
  uimod3._handle_key({ kind = "tab" })
  local S3 = uimod3._get_state()
  assert_eq(S3.input, "src/tether/agent.lua.bak", "T84 unique completion keeps the tail")
  assert_eq(S3.cursor, #"src/tether/agent.lua", "T84 cursor stops before the tail")
  assert_true(S3.cursor < #S3.input, "T84 cursor is not pushed to the end of the input")

  _G.tools = orig_tools
  print("T84 1.2 production tools lookup: OK")
end

-- T116: stop reasons are surfaced per provider, and a provider error fails the
-- attempt for every adapter (add-retry-and-continuation).
do
  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  local reasons = {}
  local function collect(e) if e.type == "done" then reasons[#reasons + 1] = e.reason end end

  openai.reset_stream()
  openai.parse_sse_line('data: {"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}', collect)
  openai.parse_sse_line('data: [DONE]', collect)
  assert_eq(reasons[1], "length", "T116 openai length reason")
  assert_eq(reasons[2], "length", "T116 the sentinel repeats the reason")
  openai.reset_stream()
  reasons = {}
  openai.parse_sse_line('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}', collect)
  assert_eq(reasons[1], "tool_calls", "T116 openai tool_calls reason")
  openai.reset_stream()
  reasons = {}
  openai.parse_sse_line('data: {"choices":[{"delta":{}}]}', collect)
  assert_eq(#reasons, 0, "T116 no reason without a finish_reason")

  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  anthropic.reset_stream()
  reasons = {}
  anthropic.parse_sse_line('data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":7}}', collect)
  anthropic.parse_sse_line('data: {"type":"message_stop"}', collect)
  assert_eq(reasons[1], "length", "T116 anthropic max_tokens")
  anthropic.reset_stream()
  reasons = {}
  anthropic.parse_sse_line('data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}', collect)
  anthropic.parse_sse_line('data: {"type":"message_stop"}', collect)
  assert_eq(reasons[1], "stop", "T116 anthropic end_turn")

  local gemini = assert(loadfile("src/tether/providers/gemini.lua"))()
  gemini.reset_stream()
  reasons = {}
  gemini.parse_sse_line('data: {"candidates":[{"content":{"parts":[{"text":"yo"}],"role":"model"},"finishReason":"MAX_TOKENS"}]}', collect)
  gemini.stream_finished(collect)
  assert_eq(reasons[1], "length", "T116 gemini MAX_TOKENS")
  gemini.reset_stream()
  reasons = {}
  gemini.parse_sse_line('data: {"candidates":[{"content":{"parts":[]},"finishReason":"SAFETY"}]}', collect)
  gemini.stream_finished(collect)
  assert_eq(reasons[1], "other", "T116 gemini unmapped reason")
  gemini.reset_stream()
  reasons = {}
  gemini.stream_finished(collect)
  assert_eq(reasons[1], "other", "T116 gemini without a reason")

  -- a provider error fails the attempt, and reset_stream clears it
  openai.reset_stream()
  openai.parse_sse_line('data: {"error":{"message":"rate limit exceeded"}}', function() end)
  assert_true(openai.stream_failure() ~= nil, "T116 openai error fails the attempt")
  anthropic.reset_stream()
  anthropic.parse_sse_line('data: {"type":"error","error":{"message":"Overloaded"}}', function() end)
  local af = anthropic.stream_failure()
  assert_true(af ~= nil and af.message:find("Overloaded", 1, true) ~= nil,
    "T116 anthropic error fails the attempt")
  gemini.reset_stream()
  gemini.handle_non_sse('{"candidates":[],"error":{"message":"gemini boom","code":500}}', function() end)
  local gf = gemini.stream_failure()
  assert_true(gf ~= nil and gf.message:find("gemini boom", 1, true) ~= nil,
    "T116 gemini error fails the attempt")
  gemini.reset_stream()
  assert_true(gemini.stream_failure() == nil, "T116 reset clears the failure")
  print("T116 provider stop reasons: OK")
end

-- T119: retry and continuation notices (add-retry-and-continuation). The UI
-- is driven through its agent-event seam after a run, like T84's key seam.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
  local function find_entry(pred)
    for _, e in ipairs(tentries(uimod)) do if pred(e) then return e end end
  end
  -- attempt 1 streams text, then fails retryably
  uimod._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uimod._handle_agent_event({ type = "retry", attempt = 1, delay = 4.0,
                              reason = "server error / rate limit" })
  assert_eq(find_entry(function(e) return e.role == "assistant" and e.text == "half an ans" end),
    nil, "T119 the failed attempt's row is dropped")
  local retry_row = find_entry(function(e)
    return e.role == "system" and (e.text or ""):find("retry 1", 1, true) ~= nil end)
  assert_notnil(retry_row, "T119 the retry row is appended")
  assert_true(retry_row and retry_row.text:find("4.0s", 1, true) ~= nil,
    "T119 the retry row names the wait")
  assert_true(retry_row and retry_row.text:find("rate limit", 1, true) ~= nil,
    "T119 the retry row names the reason")
  assert_notnil(S.retry_wait, "T119 the pending retry is tracked")
  assert_eq(S.retry_wait and S.retry_wait.attempt, 1, "T119 the pending attempt number")

  -- block gap (transcript-visual-refresh): the retry row is a top-level
  -- system entity, so after a user row a blank row precedes it, and the
  -- viewport index stays at parity with the full render.
  local qb = {}
  for c in ("q1"):gmatch(".") do qb[#qb + 1] = c:byte() end
  qb[#qb + 1] = 13
  qb[#qb + 1] = 17
  local uig = run_ui_with(qb, { agent = agent_stub })
  uig._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uig._handle_agent_event({ type = "retry", attempt = 1, delay = 4.0, reason = "server error" })
  local gfull = uig._render_all(80)
  assert_eq(uig.transcript_height(80), #gfull, "T119d gap: index == full render")
  local grow
  for i, r in ipairs(gfull) do
    if (r:gsub("\27%[[0-9;]*m", "")):find("retry 1", 1, true) then grow = i end
  end
  assert_notnil(grow, "T119d the retry row is rendered")
  local before = grow and gfull[grow - 1]
  assert_eq(before and (before:gsub("\27%[[0-9;]*m", "")) or nil, "",
    "T119d a blank row precedes the retry row")
  assert_true(grow > 2 and (gfull[grow - 2] or ""):find("q1", 1, true) ~= nil,
    "T119d the user row sits directly before the gap")

  uimod._paint(true)
  local L119 = uimod._layout()
  local top_rule = uimod._row(L119.rule_top_row) or ""
  assert_true(top_rule:find("retry", 1, true) == nil,
    "T119 the top rule no longer shows the pending retry, got: " .. top_rule:sub(1, 80))

  -- attempt 2's text is kept, and clears the pending indicator
  uimod._handle_agent_event({ type = "text_delta", text = "the answer", attempt = 2 })
  local kept = find_entry(function(e) return e.role == "assistant" and e.text == "the answer" end)
  assert_notnil(kept, "T119 the successful attempt's row is kept")
  assert_eq(kept and kept.attempt, 2, "T119 the row remembers its attempt")
  assert_eq(S.retry_wait, nil, "T119 the indicator clears on the next delta")
  assert_eq(find_entry(function(e)
    return e.role == "assistant" and e.text == "half an ans" end), nil,
    "T119 the failed attempt stays dropped")

  -- continuation notices
  uimod._handle_agent_event({ type = "continuation", kind = "length" })
  assert_notnil(find_entry(function(e)
    return e.role == "system" and (e.text or ""):find("continuation", 1, true) ~= nil end),
    "T119 the continuation row is appended")
  uimod._handle_agent_event({ type = "continuation", kind = "empty" })
  assert_notnil(find_entry(function(e)
    return e.role == "system" and (e.text or ""):find("empty", 1, true) ~= nil end),
    "T119 the empty-stop row is appended")
  assert_true(#uimod._render_all(80) > 0, "T119 the notices render")

  -- ASCII mode degrades the glyphs (the arrow becomes [r] in the transcript row)
  local uimod2, S2 = run_ui_with({ 17 }, { agent = agent_stub })
  uimod2._ascii_mode = true
  uimod2._handle_agent_event({ type = "retry", attempt = 1, delay = 2.0,
                               reason = "connection error" })
  local saw_ascii, saw_arrow = false, false
  for _, r in ipairs(uimod2._render_all(80)) do
    if r:find("[r]", 1, true) then saw_ascii = true end
    if r:find("↻", 1, true) then saw_arrow = true end
  end
  assert_true(saw_ascii, "T119 the retry glyph degrades to [r] in ascii mode")
  assert_false(saw_arrow, "T119 no arrow glyph is left in ascii mode")
  uimod2._paint(true)
  local L119b = uimod2._layout()
  local top_rule2 = uimod2._row(L119b.rule_top_row) or ""
  assert_true(top_rule2:find("[r]", 1, true) == nil,
    "T119 the top rule no longer shows the retry glyph, got: " .. top_rule2:sub(1, 80))
  print("T119 retry and continuation notices: OK")
end

-- T119b: the retry row carries the provider's own error text (a bare
-- "bad request" never says which field the gateway rejected).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local uimod, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod._handle_agent_event({ type = "retry", attempt = 1, delay = 2.0,
                              reason = "bad request",
                              detail = 'http 400: {"error":{"message":"Invalid arguments"}}' })
  local row = nil
  for _, e in ipairs(tentries(uimod)) do
    if e.role == "system" and (e.text or ""):find("retry 1", 1, true) then row = e end
  end
  assert_notnil(row, "T119b the retry row is appended")
  assert_true(row and row.text:find("Invalid arguments", 1, true) ~= nil,
    "T119b the retry row carries the provider text")
  -- no detail: old shape still renders
  local uimod2, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod2._handle_agent_event({ type = "retry", attempt = 1, delay = 2.0,
                               reason = "bad request" })
  local row2 = nil
  for _, e in ipairs(tentries(uimod2)) do
    if e.role == "system" and (e.text or ""):find("retry 1", 1, true) then row2 = e end
  end
  assert_true(row2 and row2.text:find("bad request", 1, true) ~= nil,
    "T119b the retry row renders without detail")
  print("T119b retry row carries provider text: OK")
end

-- T119c: a failed attempt's partial output hidden by the retry drop comes
-- back on terminal error/abort (only user rows and tool rows remained).
-- Fresh output supersedes the stash: recovery then error keeps just recovery.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function texts(uimod)
    local out = {}
    for _, e in ipairs(tentries(uimod)) do
      if e.role == "assistant" then out[#out + 1] = e.text end
    end
    return table.concat(out, "|")
  end
  -- error restores
  local uimod, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uimod._handle_agent_event({ type = "retry", attempt = 1, delay = 1.0, reason = "x" })
  assert_eq(texts(uimod), "", "T119c the failed attempt stays hidden on retry")
  uimod._handle_agent_event({ type = "error", message = "boom" })
  assert_eq(texts(uimod), "half an ans", "T119c terminal error restores partial output")
  -- recovery supersedes: retry, then fresh deltas, then error
  local uimod2, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod2._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uimod2._handle_agent_event({ type = "retry", attempt = 1, delay = 1.0, reason = "x" })
  uimod2._handle_agent_event({ type = "text_delta", text = "the answer", attempt = 2 })
  uimod2._handle_agent_event({ type = "error", message = "boom" })
  assert_eq(texts(uimod2), "the answer", "T119c recovery output is not duplicated")
  -- abort restores too
  local uimod3, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod3._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uimod3._handle_agent_event({ type = "retry", attempt = 1, delay = 1.0, reason = "x" })
  uimod3._handle_agent_event({ type = "aborted" })
  assert_eq(texts(uimod3), "half an ans", "T119c abort restores partial output")
  print("T119c failed-attempt output restored on terminal failure: OK")
end

-- T119d: the retry drop removes only the failed attempt's ANSWER TEXT, not
-- the context it reasoned from. A think block built up before the failure
-- (and the tool rows that produced its evidence) survive the retry: the
-- model reasoned from them, they carry no answer, and dropping them left the
-- chat blank the moment any error arrived (the think block and every tool
-- row below it vanished with the failed attempt's text).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function find_role(uimod, role)
    for _, e in ipairs(tentries(uimod)) do if e.role == role then return e end end
  end
  local function has_role(uimod, role)
    for _, e in ipairs(tentries(uimod)) do if e.role == role then return true end end
    return false
  end
  -- think -> tool -> retry on the SAME attempt as the think
  local uimod, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "planning the work", attempt = 1 })
  uimod._handle_agent_event({ type = "tool_call_start", id = "t1", name = "read",
                              args = { path = "/x" } })
  uimod._handle_agent_event({ type = "tool_result", id = "t1", name = "read",
                              summary = "92 lines", body = "..." })
  uimod._handle_agent_event({ type = "retry", attempt = 1, delay = 2.0,
                              reason = "connection error" })
  local think = find_role(uimod, "thinking")
  assert_notnil(think, "T119d the think block survives the retry")
  assert_eq(think.text, "planning the work", "T119d the think text is intact")
  assert_eq(think.attempt, 1, "T119d the think row keeps its attempt tag")
  assert_true(has_role(uimod, "tool"), "T119d the tool row survives the retry")
  assert_true(has_role(uimod, "system"), "T119d the retry row is appended")
  assert_true(#uimod._render_all(80) > 0, "T119d the chat still renders after the retry")

  -- the failed attempt's ANSWER TEXT is still dropped (the invariant T119c
  -- guards), while the think and tool rows stay
  local uimod2, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod2._handle_agent_event({ type = "reasoning_delta", text = "planning", attempt = 1 })
  uimod2._handle_agent_event({ type = "text_delta", text = "half an ans", attempt = 1 })
  uimod2._handle_agent_event({ type = "retry", attempt = 1, delay = 1.0, reason = "x" })
  local assts = {}
  for _, e in ipairs(tentries(uimod2)) do
    if e.role == "assistant" then assts[#assts + 1] = e.text end
  end
  assert_eq(table.concat(assts, "|"), "", "T119d the failed attempt's answer text is still dropped")
  assert_notnil(find_role(uimod2, "thinking"),
    "T119d the think block is kept alongside the dropped answer")

  -- retry on a LATER attempt (attempt 2) keeps the attempt-1 context too
  local uimod3, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod3._handle_agent_event({ type = "reasoning_delta", text = "planning", attempt = 1 })
  uimod3._handle_agent_event({ type = "tool_call_start", id = "t1", name = "list", args = {} })
  uimod3._handle_agent_event({ type = "tool_result", id = "t1", name = "list",
                              summary = "18 entries", body = "..." })
  uimod3._handle_agent_event({ type = "retry", attempt = 2, delay = 2.0, reason = "connection error" })
  assert_notnil(find_role(uimod3, "thinking"),
    "T119d attempt-1 think survives a retry of attempt 2")
  assert_true(has_role(uimod3, "tool"), "T119d attempt-1 tool survives a retry of attempt 2")
  print("T119d retry drops only the failed attempt's answer text: OK")
end

-- T135b: the summary marker renders like turn separators (dim rule across
-- the full width, not a short caption).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local uimod, _ = run_ui_with({ 17 }, { agent = agent_stub })
  uimod._handle_agent_event({ type = "context_compressed", mode = "truncation" })
  local rows = uimod._render_all(40)
  local last = (rows[#rows] or ""):gsub("\27%[[%d;]*m", "")
  assert_true(last:find("── summary", 1, true) == 1,
    "T135b marker leads like a separator: " .. last)
  assert_true(#last >= 40, "T135b marker rule spans the width")
  print("T135b summary marker renders full-width: OK")
end

-- T118: retry configuration resolution (add-retry-and-continuation).
do
  local config = assert(loadfile("src/tether/config.lua"))()
  local policy = assert(loadfile("src/tether/retry.lua"))()
  local home = "/tmp/tether_t118_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")

  local function write_config(body)
    local f = assert(io.open(home .. "/.tether/config.lua", "w"))
    f:write(body)
    f:close()
  end

  -- defaults: the retry table is present, and nothing caps the attempts
  local cfg0 = config.load(home .. "/.tether/no-config.lua", home)
  assert_eq(type(cfg0.retry), "table", "T118 retry table by default")
  assert_eq(cfg0.retry.base_delay_ms, 2000, "T118 default base delay")
  assert_eq(cfg0.retry.max_delay_ms, 60000, "T118 default max delay")
  assert_eq(cfg0.retry.multiplier, 2, "T118 default multiplier")
  assert_eq(cfg0.retry.max_failures_at_max_delay, 3, "T118 default max failures")
  assert_eq(cfg0.retry.max_attempts, nil, "T118 no default attempt cap")
  assert_eq(cfg0.retries, nil, "T118 retries is not a default")

  -- a partial retry table keeps the other defaults
  write_config('return { retry = { base_delay_ms = 5000 } }\n')
  local cfg1 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg1.retry.base_delay_ms, 5000, "T118 partial table overrides")
  assert_eq(cfg1.retry.max_delay_ms, 60000, "T118 partial table keeps defaults")
  assert_eq(policy.policy(cfg1).base_delay_ms, 5000, "T118 the policy reads it")

  -- a legacy retries value still caps the attempts
  write_config('return { retries = 5 }\n')
  local cfg2 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg2.retry.max_attempts, 5, "T118 legacy retries caps attempts")

  -- the new key wins over the legacy one
  write_config('return { retries = 5, retry = { max_attempts = 2 } }\n')
  local cfg3 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg3.retry.max_attempts, 2, "T118 retry.max_attempts wins")

  -- a malformed value does not stop the session; the policy falls back
  write_config('return { retry = { base_delay_ms = "soon" } }\n')
  local cfg4 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(policy.policy(cfg4).base_delay_ms, 2000, "T118 malformed value falls back")

  os.execute("rm -rf " .. home)
  print("T118 retry configuration: OK")
end

-- T117: the turn-level retry loop and continuations (add-retry-and-
-- continuation). The provider is stubbed through the agent's `api` global, so
-- the assertions are about history shape, journal calls and event order.
with_modules(base_env, function(mods)
  local agent = mods.agent
  local policy = assert(loadfile("src/tether/retry.lua"))()
  local saved_context = _G.context
  _G.context = nil

  local journaled = {}
  _G.session = { append = function(_, ev) journaled[#journaled + 1] = ev end }

  local function make_stream(scripts)
    local st = { calls = 0, seen = {} }
    st.fn = function(_, _, messages, on_event)
      st.calls = st.calls + 1
      local copy = {}
      for i, m in ipairs(messages) do
        copy[i] = { role = m.role, content = m.content, tool_calls = m.tool_calls }
      end
      st.seen[st.calls] = copy
      local entry = scripts[st.calls] or {}
      for _, ev in ipairs(entry.events or {}) do on_event(ev) end
      if entry.ok == false then return false, entry.failure end
      return true
    end
    return st
  end

  local function run(scripts, delay_ms)
    local st = make_stream(scripts)
    _G.api = { stream = st.fn }
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  retry = { base_delay_ms = delay_ms or 1 } }
    local events = {}
    local ok = agent.turn(cfg, "k", "hello", function(ev) events[#events + 1] = ev end)
    return st, events, ok
  end

  local function count_role(history, role)
    local n = 0
    for _, m in ipairs(history) do if m.role == role then n = n + 1 end end
    return n
  end

  -- 1. a retryable failure is retried with the same conversation
  journaled = {}
  agent.clear()
  local st1, ev1 = run({
    { ok = false, failure = policy.failure("server", "rate limit exceeded", 429) },
    { events = { { type = "text_delta", text = "hi" }, { type = "done", reason = "stop" } } },
  })
  assert_eq(st1.calls, 2, "T117 a retryable failure is retried")
  local retries, errors = 0, 0
  for _, ev in ipairs(ev1) do
    if ev.type == "retry" then retries = retries + 1 end
    if ev.type == "error" then errors = errors + 1 end
  end
  assert_eq(retries, 1, "T117 one retry event")
  assert_eq(errors, 0, "T117 no error for a retried attempt")
  assert_eq(count_role(agent.get_history(), "user"), 1, "T117 one user message")
  assert_eq(#st1.seen[1], #st1.seen[2], "T117 the retry re-sends the same conversation")
  assert_eq(st1.seen[1][#st1.seen[1]].role, "user", "T117 the retry adds no message")
  local answer
  for _, m in ipairs(agent.get_history()) do
    if m.role == "assistant" then answer = m.content end
  end
  assert_eq(answer, "hi", "T117 the retried answer is kept")

  -- 2. a failed attempt leaves no trace, and its deltas carry its attempt
  journaled = {}
  agent.clear()
  local st2, ev2 = run({
    { ok = false, failure = policy.failure("server", "overloaded"),
      events = { { type = "text_delta", text = "half an ans" } } },
    { events = { { type = "text_delta", text = "final" }, { type = "done", reason = "stop" } } },
  })
  assert_eq(st2.calls, 2, "T117 a mid-stream failure is retried")
  local attempts = {}
  for _, ev in ipairs(ev2) do
    if ev.type == "text_delta" then attempts[#attempts + 1] = ev.attempt end
  end
  assert_eq(attempts[1], 1, "T117 deltas carry their attempt")
  assert_eq(attempts[#attempts], 2, "T117 the second attempt's deltas carry 2")
  for _, m in ipairs(agent.get_history()) do
    assert_false(m.role == "assistant" and type(m.content) == "string"
      and m.content:find("half an ans", 1, true) ~= nil,
      "T117 the failed attempt's text never reaches history")
  end
  for _, j in ipairs(journaled) do
    assert_false(j.type == "message" and j.content ~= nil and type(j.content) == "string"
      and j.content:find("half an ans", 1, true) ~= nil,
      "T117 the failed attempt's text is not journaled")
  end

  -- 3. a non-retryable failure stops at once with the provider's text
  agent.clear()
  local st3, ev3 = run({
    { ok = false, failure = policy.failure("permanent", "invalid api key") },
  })
  assert_eq(st3.calls, 1, "T117 a permanent failure is not retried")
  local msg3, kind3 = nil, nil
  for _, ev in ipairs(ev3) do
    if ev.type == "error" then msg3, kind3 = ev.message, ev.kind end
  end
  assert_eq(msg3, "invalid api key", "T117 the provider text is surfaced")
  assert_eq(kind3, "permanent", "T117 the error carries its kind")

  -- 4. a quota failure explains that the loop stopped
  agent.clear()
  local st4, ev4 = run({
    { ok = false, failure = policy.failure("quota", "You've hit your limit") },
  })
  assert_eq(st4.calls, 1, "T117 a quota failure is not retried")
  local msg4
  for _, ev in ipairs(ev4) do if ev.type == "error" then msg4 = ev.message end end
  assert_true(msg4 and msg4:find("retries stopped", 1, true) ~= nil,
    "T117 quota explains the stop")

  -- 5. abort during the wait stops the loop immediately
  agent.clear()
  local saved_sleep = _G.tether.sleep
  _G.tether.sleep = function() agent.abort_requested = true end
  local st5, ev5 = run({
    { ok = false, failure = policy.failure("connection", "ECONNRESET") },
    { events = { { type = "text_delta", text = "late" }, { type = "done", reason = "stop" } } },
  }, 60000)
  _G.tether.sleep = saved_sleep
  assert_eq(st5.calls, 1, "T117 an abort during the wait stops the loop")
  local aborted = false
  for _, ev in ipairs(ev5) do if ev.type == "aborted" then aborted = true end end
  assert_true(aborted, "T117 aborted is emitted")
  assert_false(agent.abort_requested, "T117 the abort flag is cleared")

  -- 6. a truncated answer is continued into one assistant entry
  journaled = {}
  agent.clear()
  local st6, ev6 = run({
    { events = { { type = "text_delta", text = "part one " }, { type = "done", reason = "length" } } },
    { events = { { type = "text_delta", text = "part two" }, { type = "done", reason = "stop" } } },
  })
  assert_eq(st6.calls, 2, "T117 a truncated answer is continued")
  local conts = 0
  for _, ev in ipairs(ev6) do if ev.type == "continuation" and ev.kind == "length" then conts = conts + 1 end end
  assert_eq(conts, 1, "T117 one continuation event")
  local history6 = agent.get_history()
  local assistants6 = {}
  for _, m in ipairs(history6) do
    if m.role == "assistant" then assistants6[#assistants6 + 1] = m end
  end
  assert_eq(#assistants6, 1, "T117 the answer is one assistant entry")
  assert_eq(assistants6[1].content, "part one part two", "T117 the answer is merged")
  assert_eq(count_role(history6, "user"), 1, "T117 the hidden continuation leaves history")
  local last6 = st6.seen[2][#st6.seen[2]]
  assert_eq(last6.role, "user", "T117 the continuation is a user turn")
  assert_true(type(last6.content) == "string" and last6.content:find("Continue", 1, true) ~= nil,
    "T117 the continuation text is sent")
  local journaled_assistants = 0
  for _, j in ipairs(journaled) do
    if j.type == "message" and j.role == "assistant" then journaled_assistants = journaled_assistants + 1 end
  end
  assert_eq(journaled_assistants, 1, "T117 the merged answer is journaled once")

  -- 7. an empty answer is nudged once, then answered
  agent.clear()
  local st7, ev7 = run({
    { events = { { type = "done", reason = "stop" } } },
    { events = { { type = "text_delta", text = "answer" }, { type = "done", reason = "stop" } } },
  })
  assert_eq(st7.calls, 2, "T117 an empty answer is nudged once")
  local nudges = 0
  for _, ev in ipairs(ev7) do if ev.type == "continuation" and ev.kind == "empty" then nudges = nudges + 1 end end
  assert_eq(nudges, 1, "T117 one nudge event")
  local history7 = agent.get_history()
  assert_eq(count_role(history7, "user"), 1, "T117 the nudge does not add a user turn")
  local users7 = {}
  for _, m in ipairs(history7) do if m.role == "user" then users7[#users7 + 1] = m end end
  assert_eq(users7[1].content, "hello", "T117 the nudge is not left in the user message")
  local nudged = st7.seen[2][#st7.seen[2]]
  assert_true(type(nudged.content) == "string" and nudged.content:find("hello", 1, true) == 1
    and nudged.content:find("empty", 1, true) ~= nil, "T117 the nudge is folded into the user turn")
  local answer7
  for _, m in ipairs(history7) do if m.role == "assistant" then answer7 = m.content end end
  assert_eq(answer7, "answer", "T117 the nudged answer is kept")

  -- 8. two empty answers give up with one error
  agent.clear()
  local st8, ev8 = run({
    { events = { { type = "done", reason = "stop" } } },
    { events = { { type = "done", reason = "stop" } } },
  })
  assert_eq(st8.calls, 2, "T117 the empty answer is nudged exactly once")
  local errs8 = 0
  for _, ev in ipairs(ev8) do if ev.type == "error" then errs8 = errs8 + 1 end end
  assert_eq(errs8, 1, "T117 giving up emits one error")

  -- 9. continuations are bounded by the iteration cap
  agent.clear()
  local endless = {}
  local st9 = make_stream(setmetatable({}, { __index = function()
    return { events = { { type = "text_delta", text = "x" }, { type = "done", reason = "length" } } }
  end }))
  _G.api = { stream = st9.fn }
  agent.turn({ workspace = "/tmp/ws", auto_approve = {}, retry = { base_delay_ms = 1 } },
    "k", "go", function() end)
  assert_eq(st9.calls, 50, "T117 the iteration cap bounds continuations")

  -- T120 (group 8): the interrupt the host delivers. While a turn blocks the
  -- UI is not reading stdin, so the host watches it and reports Ctrl+C through
  -- tether.abort_requested(); the turn must stop exactly as for the UI flag,
  -- and must clear it again so the next turn is not aborted by a spent Ctrl+C.
  local saved_abort = _G.tether.abort_requested
  local saved_clear = _G.tether.clear_abort
  local saved_t_sleep = _G.tether.sleep
  -- The host flag is sticky: it stays set until the turn clears it, so the same
  -- Ctrl+C keeps aborting an in-flight transfer until the turn has stopped.
  local interrupt, cleared = false, 0
  _G.tether.abort_requested = function() return interrupt end
  _G.tether.clear_abort = function() cleared = cleared + 1; interrupt = false end

  local function saw(events, kind)
    for _, ev in ipairs(events) do if ev.type == kind then return true end end
    return false
  end

  -- 10. an interrupt that arrives during the backoff wait ends the wait, and is
  -- cleared so the next turn is not aborted by the Ctrl+C that ended this one
  agent.clear()
  interrupt, cleared = false, 0
  _G.tether.sleep = function() interrupt = true end
  local st10, ev10 = run({
    { ok = false, failure = policy.failure("connection", "ECONNRESET") },
    { events = { { type = "text_delta", text = "late" }, { type = "done", reason = "stop" } } },
  }, 60000)
  _G.tether.sleep = saved_t_sleep
  assert_eq(st10.calls, 1, "T120 a host interrupt during the wait stops the loop")
  assert_true(saw(ev10, "aborted"), "T120 aborted is emitted")
  assert_false(saw(ev10, "error"), "T120 an aborted turn reports no error")
  -- the retry notice precedes the wait; the abort ends it, and no second attempt
  -- is ever sent
  local retry_seen, abort_seen = 0, 0
  for i, ev in ipairs(ev10) do
    if ev.type == "retry" then retry_seen = i end
    if ev.type == "aborted" then abort_seen = i end
  end
  assert_true(retry_seen > 0 and retry_seen < abort_seen,
    "T120 the interrupted wait follows its retry notice")
  assert_false(interrupt, "T120 the handled interrupt is cleared, not left set")
  assert_eq(cleared, 2, "T120 cleared at the turn start and when the abort is handled")

  -- 11. an interrupt raised while the transfer is in flight (what the libcurl
  -- progress callback does): the transfer fails, and the turn still ends as
  -- aborted rather than retrying the transport error
  agent.clear()
  interrupt, cleared = false, 0
  local st11 = make_stream({
    { ok = false, failure = policy.failure("interrupted", "interrupted by user") },
    { events = { { type = "done", reason = "stop" } } },
  })
  local real_stream11 = st11.fn
  _G.api = { stream = function(...) interrupt = true; return real_stream11(...) end }
  local ev11 = {}
  agent.turn({ workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
               retry = { base_delay_ms = 1 } },
      "k", "hello", function(ev) ev11[#ev11 + 1] = ev end)
  assert_eq(st11.calls, 1, "T120 an aborted transfer is not retried")
  assert_true(saw(ev11, "aborted"), "T120 an aborted transfer ends the turn as aborted")
  assert_false(saw(ev11, "error"), "T120 an aborted transfer shows no error banner")

  -- 11b. and if the flag was already consumed, the interrupted kind is still not
  -- retryable — the turn ends with the distinct message instead of looping
  agent.clear()
  interrupt, cleared = false, 0
  local st11b, ev11b = run({
    { ok = false, failure = policy.failure("interrupted", "interrupted by user") },
    { events = { { type = "done", reason = "stop" } } },
  }, 1)
  assert_eq(st11b.calls, 1, "T120 an interrupted failure with no flag is not retried")
  local kind11b, msg11b = nil, nil
  for _, ev in ipairs(ev11b) do
    if ev.type == "error" then kind11b = ev.kind; msg11b = ev.message end
  end
  assert_false(saw(ev11b, "retry"), "T120 the interrupted fallback never retries")
  assert_eq(kind11b, "interrupted", "T120 the fallback error carries its kind")
  assert_eq(msg11b, "interrupted by user", "T120 the fallback error explains itself")

  -- 12. the policy has no retry for the interrupted kind at all
  local p = policy.policy({ retry = { base_delay_ms = 1 } })
  local verdict = policy.verdict(p, policy.new_state(), policy.failure("interrupted", "interrupted by user"))
  assert_eq(verdict.action, "stop", "T120 interrupted stops the retry loop")
  assert_eq(policy.is_retryable("interrupted"), false, "T120 interrupted is not retryable")
  assert_eq(policy.reason("interrupted"), "interrupted by user", "T120 interrupted has a reason")

  _G.tether.abort_requested = saved_abort
  _G.tether.clear_abort = saved_clear
  _G.context = saved_context
  print("T117 turn retry and continuation: OK")
  print("T120 host interrupt delivery: OK")
end)

