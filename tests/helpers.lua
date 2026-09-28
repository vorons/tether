-- tests/helpers.lua — shared test harness (Phase C, task 3.1).
-- Usage: dofile("tests/helpers.lua") at the top of a test file.
-- Defines globals: passed/failed counters, assert_* helpers, host_fs,
-- host_mock, with_modules, base_env, run_ui_with. No tests run here.

-- tests/lua_tests.lua — minimal Lua unit tests
-- Run: lua tests/lua_tests.lua

passed = 0
failed = 0

function assert_eq(a, b, msg)
    if a ~= b then
        failed = failed + 1
        print("FAIL: " .. (msg or "") .. " — expected " .. tostring(b) .. ", got " .. tostring(a))
    else
        passed = passed + 1
    end
end

function assert_true(v, msg)
    assert_eq(v, true, msg)
end

function assert_false(v, msg)
    assert_eq(v, false, msg)
end

function assert_notnil(v, msg)
    if v == nil then
        failed = failed + 1
        print("FAIL: " .. (msg or "") .. " — expected non-nil")
    else
        passed = passed + 1
    end
end
-- The shipped binary gets mkdirp/fchmod/readdir/stat from the C host
-- (src/host/main.c). The plain Lua test runtime has no C host, so these
-- stand-ins mirror the C contract and are merged into every `_G.tether`
-- mock below via host_mock{...}: names sorted without `.`/`..`, stat returns
-- {mtime, size, is_dir}, and failures return nil.
host_fs = {}
do
    local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    function host_fs.mkdirp(path)
        local ok = os.execute("mkdir -p " .. shq(path))
        if ok == true or ok == 0 then return true end
        return nil, "mkdir failed"
    end
    function host_fs.fchmod(path, mode)
        local ok = os.execute("chmod " .. string.format("%o", mode) .. " " .. shq(path))
        if ok == true or ok == 0 then return true end
        return nil, "chmod failed"
    end
    function host_fs.readdir(path)
        local f = io.popen("ls -1A " .. shq(path) .. " 2>/dev/null")
        if not f then return nil, "readdir failed" end
        local out = f:read("*a")
        f:close()
        local names = {}
        for name in out:gmatch("[^\n]+") do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    function host_fs.stat(path)
        -- LC_ALL=C: %F is translated, so a Russian locale reports the kind as
        -- "каталог" and the is_dir sniff below silently reports every directory
        -- as a file. The C host uses S_ISDIR, which has no locale.
        local f = io.popen("LC_ALL=C stat -c '%Y %s %F' " .. shq(path) .. " 2>/dev/null")
        if not f then return nil end
        local out = f:read("*a")
        f:close()
        local mtime, size, kind = out:match("(%d+) (%d+) (.+)")
        if not mtime then return nil end
        return { mtime = tonumber(mtime), size =tonumber(size),
                 is_dir = kind:find("directory") ~= nil }
    end
end

-- Build a `_G.tether` mock: declared members win, the fs primitives are
-- filled in from host_fs so tests only declare what they care about.
function host_mock(fields)
    fields = fields or {}
    fields.mkdirp = fields.mkdirp or host_fs.mkdirp
    fields.fchmod = fields.fchmod or host_fs.fchmod
    fields.readdir = fields.readdir or host_fs.readdir
    fields.stat = fields.stat or host_fs.stat
    -- reactor loop primitives: instant scripted readiness by default.
    -- The default reports stdin (fd 0) readable: scripted bytes drain,
    -- exhaustion drains as EOF and quits the loop. run_ui_with overrides
    -- poll below with byte-aware readiness.
    fields.poll = fields.poll or function() return { read = { 0 }, write = {} } end
    fields.monotonic_ms = fields.monotonic_ms or function() return 0 end
    fields.quit_requested = fields.quit_requested or function() return false end
    return fields
end
-- M7 helpers: module loader with _G stubs + restore
function with_modules(env_fn, fn)
    local names = {"tether", "config", "session", "agent", "api", "tools", "ui", "diff"}
    local originals = {}
    for _, name in ipairs(names) do originals[name] = _G[name] end
    env_fn()
    local mods = {}
    local ok, err = pcall(function()
        mods.diff = assert(loadfile("src/tether/diff.lua"))()
        _G.diff = mods.diff
        mods.tools = assert(loadfile("src/tether/tools.lua"))()
        _G.tools = mods.tools
        mods.api = assert(loadfile("src/tether/api.lua"))()
        _G.api = mods.api
        mods.agent = assert(loadfile("src/tether/agent.lua"))()
        _G.agent = mods.agent
        mods.session = assert(loadfile("src/tether/session.lua"))()
        _G.session = mods.session
        mods.config = assert(loadfile("src/tether/config.lua"))()
        _G.config = mods.config
        mods.ui = assert(loadfile("src/tether/ui.lua"))()
        _G.ui = mods.ui
        fn(mods)
    end)
    for _, name in ipairs(names) do _G[name] = originals[name] end
    if not ok then error(err, 0) end
end

function base_env()
    _G.tether = host_mock{
        getcwd = function() return "/tmp/ws" end,
        realpath = function(p) return p end,
        exec = function() return true, 0 end,
        write = function() end, sleep = function() end,
        http_stream = function() return true end,
        http_get = function() return "", nil end,
        get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
        read_char = function() return nil end,
        read_char_nb = function() return nil end,
        resize_requested = function() return false end,
        is_tty = function() return false end,
    }
    _G.config = { get_system_prompt = function() return nil end }
    _G.session = { append = function() end }
end

-- T53b: harness for run()-level transcript checks (quit immediately or
-- after scripted input). Returns the ui module and its post-run S.
-- `sink` (optional) captures every frame written to the terminal (T54).
-- `paintC` (optional) is a hook called on every M._paint() invocation; useful
-- for asserting on side effects that arent in the painted frame (e.g. repaint
-- count). Callers that need to assert later must provide a closure synchronously.
function run_ui_with(bytes, stubs, sink, paintC)
  local names = { "tether", "config", "session", "agent", "api", "tools", "diff" }
  local originals, preload = {}, {}
  if not (stubs and stubs.diff) then
    local okd, dmod = pcall(loadfile, "src/tether/diff.lua")
    _G.diff = (okd and dmod and dmod()) or _G.diff
  else
    _G.diff = stubs.diff
  end
  for _, n in ipairs(names) do
    originals[n] = _G[n]; preload[n] = package.preload[n]
  end
  local qi = 0
  local mock = {
    -- T54/T6+: capture frames so a test can assert on what reached the screen
    write = function(s) if sink then sink[#sink + 1] = s end end,
    resize_requested = function() return false end,
    get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
    getcwd = function() return "/tmp" end,
    -- reactor readiness: stdin (fd 0) reads ready while scripted bytes
    -- remain; exhaustion drains as EOF and quits the loop
    poll = function(rfds)
      local ready = { read = {}, write = {} }
      if qi <= #bytes then
        for _, fd in ipairs(rfds or {}) do
          if fd == 0 then ready.read = { 0 }; break end
        end
      else
        ready.read = { 0 }
      end
      return ready
    end,
    read_char = function()
      qi = qi + 1
      if qi <= #bytes then return bytes[qi] end
      return 17
    end,
    read_char_nb = function()
      qi = qi + 1
      if qi <= #bytes then return bytes[qi] end
      return nil
    end,
  }
  -- TW4: a test may replace primitives (poll/read/http transport) wholesale,
  -- on top of the defaults above.
  if stubs and stubs.tether then
    for k, v in pairs(stubs.tether) do mock[k] = v end
  end
  _G.tether = host_mock(mock)
  _G.config = stubs.config or { load = function()
      return { model = "test", workspace = "/tmp", ui = { input_max_lines = 8 } }
    end,
    api_key = function() return "" end }
  _G.session = stubs.session or { new_session = function() return "sid" end }
  _G.agent = stubs.agent or { turn = function() return true end,
    get_history = function() return {} end }
  _G.api = stubs.api or { list_models = function() return {} end }
  _G.tools = stubs.tools or _G.tools or nil
  package.preload.tether = function() return _G.tether end
  package.preload.config = function() return _G.config end
  package.preload.session = function() return _G.session end
  package.preload.agent = function() return _G.agent end
  package.preload.api = function() return _G.api end
  if _G.tools then package.preload.tools = function() return _G.tools end end
  local ui_mod
  local ok, err = pcall(function()
    ui_mod = assert(loadfile("src/tether/ui.lua"))()
    if paintC then
      local _paint = ui_mod._paint
      ui_mod._paint = function(force) _paint(force); paintC(force) end
    end
    ui_mod.run()
  end)
  local S = ui_mod and ui_mod._get_state and ui_mod._get_state()
  for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
  if not ok then error("T53 harness: " .. tostring(err), 0) end
  return ui_mod, S
end

-- end helpers

-- transcript view helpers, shared across split files.
function tentries(uimod) return uimod._transcript.entries() end
function tph(uimod)
  local _, _, ph = uimod._transcript.tails(); return ph
end
function task(uimod)
  local _, ask = uimod._transcript.tails(); return ask
end
function tassert(uimod, preset, name, sel)
  local rows = (uimod._render_all and uimod._render_all(80)) or {}
  for _, r in ipairs(rows) do print(name .. ": row: " .. tostring(r)) end
end
