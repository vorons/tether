-- tests/stderr_guard_tests.lua — TUI stderr guard (tui-stderr-guard change).
-- The TUI must never write diagnostics to the terminal: everything goes to
-- the session log file, user-visible problems to error_banner/note.
-- Run: lua tests/stderr_guard_tests.lua (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

local function tmp_dir()
    local p = os.tmpname()
    os.remove(p)
    assert(host_fs.mkdirp(p))
    return p
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d or ""
end

local function sink_has(sink, needle)
    for _, s in ipairs(sink) do
        if tostring(s):find(needle, 1, true) then return true end
    end
    return false
end

-- 1.1: io.stderr writes issued inside ui.run land in the session log file,
-- never in the terminal frames; io.stderr is restored afterwards. The probe
-- rides stubs.agent.turn: the turn runs inside the guarded window (paintC
-- cannot be used — the loop calls the local paint, not M._paint).
do
    local logdir = tmp_dir()
    local term_sink = {}
    local real_stderr = io.stderr
    local stubs = {
        config = {
            load = function()
                return { model = "test", workspace = "/tmp",
                         ui = { input_max_lines = 8 }, _log_dir = logdir }
            end,
            api_key = function() return "" end,
        },
        agent = {
            turn = function()
                io.stderr:write("guard-probe-line\n")
                return true
            end,
            get_history = function() return {} end,
        },
    }
    run_ui_with({ 104, 105, 13, 17 }, stubs, term_sink)
    assert_eq(io.stderr, real_stderr, "1.1 io.stderr restored after ui.run")
    assert_false(sink_has(term_sink, "guard-probe-line"),
        "1.1 terminal frames stay clean")
    local log = read_file(logdir .. "/tether.log") or ""
    assert_true(log:find("guard-probe-line", 1, true) ~= nil,
        "1.1 stderr write lands in the session log")
    os.execute("rm -rf '" .. logdir .. "'")
    print("1.1 TUI stderr guard captures io.stderr: OK")
end

-- 1.3a: pre-TUI warnings carried in cfg._startup_warnings surface as the
-- error banner on first paint; the terminal frames stay clean.
do
    local logdir = tmp_dir()
    local term_sink = {}
    local stubs = {
        config = {
            load = function()
                return { model = "test", workspace = "/tmp",
                         ui = { input_max_lines = 8 }, _log_dir = logdir,
                         _startup_warnings = {
                            "tether: extension broken: boom",
                         } }
            end,
            api_key = function() return "" end,
        },
    }
    local _, S = run_ui_with({ 17 }, stubs, term_sink)
    assert_notnil(S, "1.3a state readable after run")
    assert_true((S.error_banner or ""):find("broken", 1, true) ~= nil,
        "1.3a startup warning surfaces as the error banner")
    -- The banner is a TUI surface, so its text legitimately shows in the
    -- frames: "clean" means no RAW stderr leak. Raw stderr bypasses the
    -- harness sink entirely, so frames carrying only the banner prove it.
    assert_true(sink_has(term_sink, "broken"),
        "1.3a banner rendered inside the TUI frames")
    os.execute("rm -rf '" .. logdir .. "'")
    print("1.3a startup warnings surface as banner: OK")
end

-- 1.3b: the app early sink captures pre-TUI stderr (extension load
-- warnings) into the session log and collects them, never the terminal.
do
    _G.tether = host_mock({})
    local home = tmp_dir()
    local logdir = tmp_dir()
    local dir = home .. "/.tether/extensions/broken"
    assert(host_fs.mkdirp(dir))
    local f = assert(io.open(dir .. "/broken.lua", "w"))
    f:write("return { this is not lua !!!")
    f:close()
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    _G.commands = cmds
    _G.extensions = assert(loadfile("src/tether/extensions.lua"))()
    local app = assert(loadfile("src/tether/app.lua"))()
    local real_stderr = io.stderr
    local cfg = { workspace = "/tmp", _log_dir = logdir }
    app._early_stderr_sink(cfg)
    assert_true(io.stderr ~= real_stderr, "1.3b sink active during capture")
    app.boot_extensions(cfg, home)
    app._restore_early_stderr_sink()
    assert_eq(io.stderr, real_stderr, "1.3b io.stderr restored")
    assert_true(#(cfg._startup_warnings or {}) >= 1,
        "1.3b warning collected for the banner")
    local log = read_file(logdir .. "/tether.log") or ""
    assert_true(log:find("broken", 1, true) ~= nil,
        "1.3b warning lands in the session log")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. logdir .. "'")
    print("1.3b app early sink captures pre-TUI stderr: OK")
end

-- 2.1: ctx.log never touches stderr in any mode — one log line, zero
-- stderr captures. Covers both the extensions module and the commands
-- mirror (reached through a registered probe command's dispatch).
do
    _G.tether = host_mock({})
    local logdir = tmp_dir()
    local ext = assert(loadfile("src/tether/extensions.lua"))()
    _G.extensions = ext
    local captured = {}
    local real = io.stderr
    io.stderr = { write = function(_, s)
        captured[#captured + 1] = tostring(s)
        return io.stderr
    end }
    local cfg = { workspace = "/tmp", _log_dir = logdir }
    ext.ctx_for(cfg, { ext = "probe", surface = "tool" }).log("hello-log-line")
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    cmds.register_extension_commands({
        commands = { probe = { ext = "probe", def = {
            name = "probe", description = "probe",
            fn = function(_, ctx) ctx.log("cmd-log-line") return "" end,
        } } },
        command_order = { "probe" },
    })
    cmds.dispatch["probe"]({ cfg = cfg, workspace = "/tmp" }, nil, "probe", "")
    io.stderr = real
    assert_eq(#captured, 0, "2.1 ctx.log produces zero stderr")
    local log = read_file(logdir .. "/tether.log") or ""
    assert_true(log:find("hello-log-line", 1, true) ~= nil,
        "2.1 extensions ctx.log lands in the session log")
    assert_true(log:find("cmd-log-line", 1, true) ~= nil,
        "2.1 commands ctx.log lands in the session log")
    os.execute("rm -rf '" .. logdir .. "'")
    print("2.1 ctx.log is file-only: OK")
end

-- 2.2: warn keeps stderr when no guard is active, and goes to the session
-- log while the TUI guard runs. Warn code itself is untouched — the sinks
-- do the routing.
do
    _G.tether = host_mock({})
    local home = tmp_dir()
    local dir = home .. "/.tether/extensions/broken"
    assert(host_fs.mkdirp(dir))
    local f = assert(io.open(dir .. "/broken.lua", "w"))
    f:write("return { this is not lua !!!")
    f:close()
    -- no guard: warning reaches stderr
    local ext = assert(loadfile("src/tether/extensions.lua"))()
    local captured = {}
    local real = io.stderr
    io.stderr = { write = function(_, s)
        captured[#captured + 1] = tostring(s)
        return io.stderr
    end }
    ext.load(home, {})
    io.stderr = real
    local noisy = false
    for _, s in ipairs(captured) do
        if s:find("broken", 1, true) then noisy = true end
    end
    assert_true(noisy, "2.2 warn reaches stderr with no guard")
    -- guard active: warning reaches the file, stderr untouched
    base_env()
    local uimod = assert(loadfile("src/tether/ui.lua"))()
    local logdir = tmp_dir()
    local before = io.stderr
    uimod._stderr_guard_install({ _log_dir = logdir })
    local ext2 = assert(loadfile("src/tether/extensions.lua"))()
    ext2.load(home, {})
    uimod._stderr_guard_restore()
    assert_eq(io.stderr, before, "2.2 io.stderr restored after guard")
    local log = read_file(logdir .. "/tether.log") or ""
    assert_true(log:find("broken", 1, true) ~= nil,
        "2.2 warn lands in the session log under guard")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. logdir .. "'")
    print("2.2 warn routes by mode: OK")
end

-- 2.3: the fixed pattern — tool + command + prompt, no on_session_start
-- banner — starts silently: no stderr, no log line on the happy path.
do
    _G.tether = host_mock({})
    local home = tmp_dir()
    local logdir = tmp_dir()
    local dir = home .. "/.tether/extensions/changes"
    assert(host_fs.mkdirp(dir))
    local f = assert(io.open(dir .. "/changes.lua", "w"))
    f:write([[
return { name = "changes", api_version = 1,
  prompt = { text = "use changes_summary" },
  tools = { { name = "changes_summary", description = "d",
              fn = function() return { content = "none" } end } },
  commands = { { name = "changes", description = "d",
                 fn = function() return "none" end } },
}]])
    f:close()
    local ext = assert(loadfile("src/tether/extensions.lua"))()
    local captured = {}
    local real = io.stderr
    io.stderr = { write = function(_, s)
        captured[#captured + 1] = tostring(s)
        return io.stderr
    end }
    local cfg = { workspace = "/tmp", _log_dir = logdir }
    local reg = ext.load(home, cfg)
    ext.fire_start(cfg, cfg.workspace)
    io.stderr = real
    assert_notnil(reg.tools["changes_summary"], "2.3 tool still registers")
    assert_notnil(reg.commands["changes"], "2.3 command still registers")
    assert_eq(#captured, 0, "2.3 silent start emits no stderr")
    local log = read_file(logdir .. "/tether.log")
    assert_true(log == nil or log:find("changes extension up") == nil,
        "2.3 silent start emits no banner line")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. logdir .. "'")
    print("2.3 session start stays silent: OK")
end

-- 1.4: one destination — the ui guard, the app sink and ctx.log resolve
-- the same session file for the same cfg (single source of truth).
do
    base_env()
    _G.tether = host_mock({})
    local logdir = tmp_dir()
    local cfg = { workspace = "/tmp", _log_dir = logdir }
    local uimod = assert(loadfile("src/tether/ui.lua"))()
    local ext = assert(loadfile("src/tether/extensions.lua"))()
    _G.extensions = ext
    assert_eq(ext.session_log_path(cfg), logdir .. "/tether.log",
        "1.4 canonical path resolves under _log_dir")
    uimod._stderr_guard_install(cfg)
    ext.ctx_for(cfg, { ext = "probe", surface = "tool" }).log("shared-dest-probe")
    uimod._stderr_guard_restore()
    local log = read_file(logdir .. "/tether.log") or ""
    assert_true(log:find("shared-dest-probe", 1, true) ~= nil,
        "1.4 guard window and ctx.log share the file")
    os.execute("rm -rf '" .. logdir .. "'")
    print("1.4 single session-log destination: OK")
end

-- 1.5: non-TUI verbs never install a sink — management CLI leaves the
-- caller's stderr alone (print mode returns before the sink for the same
-- reason; a full --print run needs network and stays manual).
do
    _G.tether = host_mock({})
    local home = tmp_dir()
    _G.extensions = assert(loadfile("src/tether/extensions.lua"))()
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    _G.commands = cmds
    local app = assert(loadfile("src/tether/app.lua"))()
    local real = io.stderr
    local touched = 0
    local swap = { write = function(_, s)
        touched = touched + 1
        return io.stderr
    end }
    io.stderr = swap
    local rc = app._run_ext_cli({ "list" }, home)
    local after = io.stderr
    io.stderr = real
    assert_eq(rc, 0, "1.5 list verb succeeds")
    assert_eq(after, swap, "1.5 verbs leave caller stderr alone")
    assert_eq(touched, 0, "1.5 verbs emit no stderr on empty home")
    os.execute("rm -rf '" .. home .. "'")
    print("1.5 non-TUI verbs keep stderr: OK")
end

-- 1.6: a raise inside the guarded window still hands the terminal back —
-- the same three restores M.run performs on failure.
do
    base_env()
    _G.tether = host_mock({})
    local logdir = tmp_dir()
    local cfg = { workspace = "/tmp", _log_dir = logdir }
    local uimod = assert(loadfile("src/tether/ui.lua"))()
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    _G.commands = cmds
    _G.extensions = assert(loadfile("src/tether/extensions.lua"))()
    local app = assert(loadfile("src/tether/app.lua"))()
    local real = io.stderr
    app._early_stderr_sink(cfg)
    uimod._stderr_guard_install(cfg)
    local ok = pcall(error, "boom-fatal")
    pcall(function()
        uimod._stderr_guard_restore()
    end)
    pcall(app._restore_early_stderr_sink)
    local th = rawget(_G, "tether")
    if th and th.stderr_restore then pcall(th.stderr_restore) end
    assert_false(ok, "1.6 the fatal actually raised")
    assert_eq(io.stderr, real, "1.6 terminal stderr restored after raise")
    local term = {}
    io.stderr = { write = function(_, s)
        term[#term + 1] = tostring(s)
        return io.stderr
    end }
    io.stderr:write("tether: boom-fatal\n")
    io.stderr = real
    assert_true(sink_has(term, "boom-fatal"),
        "1.6 fatal reaches the terminal after restore")
    os.execute("rm -rf '" .. logdir .. "'")
    print("1.6 restore on raise: OK")
end

print("stderr guard section: OK")
if failed > 0 then
    print("FAILURES: " .. tostring(failed))
    os.exit(1)
end
