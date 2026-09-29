-- tests/extensions_tests.lua — extension loader: discovery, validation,
-- fail-closed skips, restricted env (task 1.1).
-- Run: lua tests/extensions_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

local function tmp_home()
    local p = os.tmpname()
    os.remove(p)
    assert(host_fs.mkdirp(p))
    return p
end

local function write_file(path, text)
    local dir = path:match("^(.*)/[^/]*$")
    assert(host_fs.mkdirp(dir))
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function fresh_ext()
    package.loaded["extensions_test_mod"] = nil
    return assert(loadfile("src/tether/extensions.lua"))()
end

-- 1.1 loader: valid registers; broken warns and others load; mismatched
-- ignored; disabled skipped; unknown fields ignored.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/jira/jira.lua", [[
return {
  name = "jira", api_version = 1, future_field = { wow = true },
  tools = { { name = "jira_get", description = "get a ticket",
              schema = { type = "object" }, fn = function() return { content = "T-1" } end } },
  commands = { { name = "jira", description = "jira cmd", fn = function() end } },
  prompt = { text = "project = INFRA" },
  hooks = { on_before_tool = function() end },
}
]])
    write_file(home .. "/.tether/extensions/broken/broken.lua", "return { this is not lua !!!")
    write_file(home .. "/.tether/extensions/odd/other.lua", [[return { name = "odd", api_version = 1 }]])
    write_file(home .. "/.tether/extensions/dis/dis.lua", [[return { name = "dis", api_version = 1 }]])

    local ext = fresh_ext()
    local reg = ext.load(home, { extensions = { disabled = { "dis" } } })
    assert_notnil(reg.tools["jira_get"], "1.1 ext tool registers")
    assert_eq(reg.tools["jira_get"].ext, "jira", "1.1 tool carries ext name")
    assert_notnil(reg.commands["jira"], "1.1 ext command registers")
    assert_eq(#reg.prompt_parts, 1, "1.1 prompt part registers")
    assert_eq(#reg.before, 1, "1.1 before hook registers")
    assert_eq(#reg.exts, 1, "1.1 only the valid ext registers (broken/odd/dis out)")
    assert_eq(reg.exts[1].name, "jira", "1.1 registered ext is jira")
    os.execute("rm -rf '" .. home .. "'")
    print("1.1 loader registers/skips: OK")
end

-- 1.1 sandbox: no io, no tether host table, no loaders inside ext code.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/sb/sb.lua", [[
return {
  name = "sb", api_version = 1,
  tools = { { name = "sb_tool", description = "d",
              fn = function()
                local seen = {}
                if io ~= nil then seen[#seen + 1] = "io" end
                if tether ~= nil then seen[#seen + 1] = "tether" end
                if loadfile ~= nil then seen[#seen + 1] = "loadfile" end
                if os and os.execute ~= nil then seen[#seen + 1] = "os.execute" end
                if #seen > 0 then error("leak: " .. table.concat(seen, ",")) end
                return { content = "clean" }
              end } },
}
]])
    local ext = fresh_ext()
    ext.load(home, {})
    local fn = ext.tool_fn("sb_tool")
    assert_notnil(fn, "1.1 sandboxed tool loads")
    local ok, res = pcall(fn, {}, ext.ctx_for({}))
    assert_true(ok, "1.1 sandboxed fn runs without leaks")
    assert_eq(res.content, "clean", "1.1 sandboxed fn returns")
    os.execute("rm -rf '" .. home .. "'")
    print("1.1 sandbox denies io/tether/loaders: OK")
end

-- 1.1 validation: wrong name and bad api_version are fail-closed.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/wrong/wrong.lua", [[return { name = "nope", api_version = 1 }]])
    write_file(home .. "/.tether/extensions/old/old.lua", [[return { name = "old", api_version = 99 }]])
    local ext = fresh_ext()
    local reg = ext.load(home, {})
    assert_eq(#reg.exts, 0, "1.1 invalid manifests register nothing")
    os.execute("rm -rf '" .. home .. "'")
    print("1.1 manifest validation fail-closed: OK")
end

print("extensions loader section: OK")

-- Provider-shaped tool call events: the agent starts each call with empty
-- arguments (agent.lua tool_call_start) and assembles them only from
-- tool_call_delta chunks, so a scripted call must ride a delta.
local function tc_ev(idx, id, name, args_json)
    return { { type = "tool_call_start", id = id, name = name, arguments = "" },
             { type = "tool_call_delta", index = idx, id = id,
               arguments = args_json } }
end

-- 1.3/1.4 harness: real agent.turn with a scripted api.stream.
-- _G.extensions is pinned BEFORE agent loads (agent captures it at load).
local function drive_turn(home, cfg, script, session_sink)
    _G.tether = host_mock({
        getcwd = function() return cfg.workspace end,
        realpath = function(p) return p end,
    })
    local ext = fresh_ext()
    ext.load(home, cfg)
    _G.extensions = ext
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.session = { append = function(sid, entry)
        if cfg._journal then cfg._journal[#cfg._journal + 1] = entry end
        if session_sink then session_sink(sid, entry) end
    end }
    _G.config = { get_system_prompt = function() return nil end }
    local calls = 0
    _G.api = {
        stream = function(_, _, _, on_event)
            calls = calls + 1
            for _, ev in ipairs(script[calls] or script[#script]) do
                on_event(ev)
            end
            return true, nil
        end,
    }
    local agent = assert(loadfile("src/tether/agent.lua"))()
    agent.clear()
    local events = {}
    local ok = agent.turn(cfg, "", "do it", function(ev) events[#events + 1] = ev end)
    assert_true(ok, "1.3 turn completes")
    return agent, events
end

-- 1.3 dispatch: ext tool runs, unknown name keeps its contract,
-- second claimant of one tool name is skipped.
do
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/a/a.lua", [[
return { name = "a", api_version = 1,
  tools = { { name = "dup", description = "first",
              fn = function() return { content = "from-a" } end } } }]])
    write_file(home .. "/.tether/extensions/b/b.lua", [[
return { name = "b", api_version = 1,
  tools = { { name = "dup", description = "second",
              fn = function() return { content = "from-b" } end } } }]])
    local cfg = { workspace = tmp_home(), non_interactive = true }
    local agent, _ = drive_turn(home, cfg, {
        { { type = "tool_call_start", id = "c1", name = "dup" },
          { type = "done", reason = "stop" } },
        { { type = "text_delta", text = "ok" }, { type = "done", reason = "stop" } },
    })
    local got = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then got = m.content end
    end
    assert_eq(got, "from-a", "1.3 first claimant wins the collision")
    -- unknown tool contract preserved alongside ext tools
    local agent2, _ = drive_turn(home, cfg, {
        { { type = "tool_call_start", id = "c9", name = "nope" },
          { type = "done", reason = "stop" } },
        { { type = "text_delta", text = "ok" }, { type = "done", reason = "stop" } },
    })
    local got2 = nil
    for _, m in ipairs(agent2.get_history()) do
        if m.role == "tool" then got2 = m.content end
    end
    assert_eq(got2, "unknown tool: nope", "1.3 unknown tool contract preserved")
    os.execute("rm -rf '" .. home .. "'")
    print("1.3 ext dispatch + collision + unknown: OK")
end

-- 1.4 shaping: body reaches history, oversize body carries the marker,
-- event carries the byte summary.
do
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/big/big.lua", [[
return { name = "big", api_version = 1,
  tools = { { name = "big_out", description = "dumps",
              fn = function() return { content = string.rep("x", 20000) } end } } }]])
    local cfg = { workspace = tmp_home(), non_interactive = true }
    local agent, events = drive_turn(home, cfg, {
        { { type = "tool_call_start", id = "c1", name = "big_out" },
          { type = "done", reason = "stop" } },
        { { type = "text_delta", text = "ok" }, { type = "done", reason = "stop" } },
    })
    local body = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then body = m.content end
    end
    assert_notnil(body, "1.4 body reaches history")
    assert_true(#body < 20000, "1.4 oversize body truncated")
    assert_true(body:find("truncated", 1, true) ~= nil, "1.4 truncation marker present")
    local summary = nil
    for _, ev in ipairs(events) do
        if ev.type == "tool_result" and ev.id == "c1" then summary = ev.summary end
    end
    assert_true(summary ~= nil and summary:find("bytes", 1, true) ~= nil,
        "1.4 event carries the byte summary")
    os.execute("rm -rf '" .. home .. "'")
    print("1.4 ext result shaping: OK")
end

-- 1.4b spec scenario "Extension tool error degrades": a raising fn and a
-- non-table return become tool error results, the turn keeps going.
do
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/fail/fail.lua", [[
return { name = "fail", api_version = 1,
  tools = { { name = "boom_tool", description = "raises",
              fn = function() error("kaboom") end },
            { name = "weird_tool", description = "non table",
              fn = function() return "just a string" end } } }]])
    local cfg = { workspace = tmp_home(), non_interactive = true }
    local agent = drive_turn(home, cfg, {
        { { type = "tool_call_start", id = "c1", name = "boom_tool", arguments = "" },
          { type = "done", reason = "tool_calls" } },
        { { type = "tool_call_start", id = "c2", name = "weird_tool", arguments = "" },
          { type = "done", reason = "tool_calls" } },
        { { type = "text_delta", text = "recovered" }, { type = "done", reason = "stop" } },
    })
    local hist = agent.get_history()
    local tools_seen = {}
    for _, m in ipairs(hist) do
        if m.role == "tool" then tools_seen[#tools_seen + 1] = tostring(m.content) end
    end
    assert_eq(#tools_seen, 2, "1.4b both failed calls report back to the model")
    assert_true(tools_seen[1]:find("kaboom", 1, true) ~= nil, "1.4b raise becomes a tool error")
    assert_true(tools_seen[2]:find("non-table", 1, true) ~= nil, "1.4b non-table result degrades")
    assert_eq(hist[#hist].role, "assistant", "1.4b turn continues after tool failures")
    assert_true(tostring(hist[#hist].content):find("recovered", 1, true) ~= nil,
        "1.4b assistant answer lands")
    os.execute("rm -rf '" .. home .. "'")
    print("1.4b ext tool failure degrades: OK")
end

-- 1.1b spec scenario "Project directory not scanned": only ~/.tether wins.
do
    _G.tether = host_mock({})
    local home, ws = tmp_home(), tmp_home()
    write_file(ws .. "/.tether/extensions/inline/inline.lua", [[
return { name = "inline", api_version = 1,
  tools = { { name = "inline_tool", description = "d", fn = function() return { content = "x" } end } } }]])
    local ext = fresh_ext()
    local reg = ext.load(home, { workspace = ws })
    assert_eq(#reg.exts, 0, "1.1b workspace extensions are not discovered")
    assert_eq(reg.tools["inline_tool"], nil, "1.1b workspace tool never registers")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. ws .. "'")
    print("1.1b workspace never scanned: OK")
end

-- 1.5 config: extensions table defaults, malformed fallback, bootstrap.
do
    local cfgmod = assert(loadfile("src/tether/config_schema.lua"))()
    local d = cfgmod.default_config()
    assert_notnil(d.extensions, "1.5 defaults carry extensions")
    assert_eq(#d.extensions.disabled, 0, "1.5 disabled defaults to empty")
    local home = tmp_home()
    local function load_with(body)
        local p = home .. "/c" .. tostring(load_with_n or 0) .. ".lua"
        load_with_n = (load_with_n or 0) + 1
        local f = assert(io.open(p, "w"))
        f:write("return " .. body)
        f:close()
        return assert(loadfile("src/tether/config.lua"))().load(p, home)
    end
    local c1 = load_with("{}")
    assert_eq(#c1.extensions.disabled, 0, "1.5 missing table loads all")
    local c2 = load_with("{ extensions = { disabled = 'jira' } }")
    assert_eq(#c2.extensions.disabled, 0, "1.5 malformed disabled falls back")
    local c3 = load_with("{ extensions = { disabled = { 'jira', 42 } } }")
    assert_eq(#c3.extensions.disabled, 1, "1.5 non-string entries dropped")
    assert_eq(c3.extensions.disabled[1], "jira", "1.5 string entries kept")
    -- bootstrap carries the new key with a comment
    local boot = home .. "/boot_config.lua"
    assert_true(cfgmod.write_bootstrap(boot), "1.5 bootstrap writes")
    local bf = assert(io.open(boot, "r"))
    local btext = bf:read("*a")
    bf:close()
    assert_true(btext:find("extensions", 1, true) ~= nil, "1.5 bootstrap documents extensions")
    local ok, btbl = pcall(assert(loadfile(boot)))
    assert_true(ok and type(btbl) == "table", "1.5 bootstrap parses")
    os.execute("rm -rf '" .. home .. "'")
    print("1.5 extensions config: OK")
end

-- 2.1 ext commands: dispatch merge, local execution with note,
-- resolve_slash routing, collisions skipped loud.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/jira/jira.lua", [[
return { name = "jira", api_version = 1,
  commands = { { name = "jira", description = "jira helper",
                 fn = function(rest, ctx) return "hello " .. tostring(rest) end } } }]])
    local ext = fresh_ext()
    local reg = ext.load(home, {})
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    cmds.register_extension_commands(reg)
    assert_notnil(cmds.dispatch["jira"], "2.1 ext command lands in dispatch")
    local notes = {}
    cmds.dispatch["jira"]({ workspace = "/ws", cfg = {} },
        { note = function(t) notes[#notes + 1] = t end }, "jira", "T-1")
    assert_eq(notes[1], "hello T-1", "2.1 handler runs locally with a note")
    -- routing: ext name is a command, unknown stays unknown
    local set = {}
    for _, n in ipairs(cmds.slash_names) do set[n] = true end
    assert_eq(cmds.resolve_slash("jira", set, {}), "command", "2.1 /jira routes as command")
    assert_eq(cmds.resolve_slash("JIRA", set, {}), "command", "2.1 routing ignores case")
    assert_eq(cmds.resolve_slash("nope", set, {}), "unknown", "2.1 unknown unchanged")
    -- palette rows carry label/desc/cmd
    local rows = cmds.ext_palette_rows()
    assert_eq(#rows, 1, "2.1 one palette row")
    assert_eq(rows[1].label, "/jira", "2.1 row label")
    assert_eq(rows[1].cmd, "jira", "2.1 row cmd")
    -- collision with a built-in is skipped, built-in survives
    local home2 = tmp_home()
    write_file(home2 .. "/.tether/extensions/cl/cl.lua", [[
return { name = "cl", api_version = 1,
  commands = { { name = "clear", description = "hijack",
                 fn = function() return "hijacked" end } } }]])
    local ext2 = fresh_ext()
    local reg2 = ext2.load(home2, {})
    local before = cmds.dispatch["clear"]
    cmds.register_extension_commands(reg2)
    assert_eq(cmds.dispatch["clear"], before, "2.1 built-in wins the collision")
    local notes2 = {}
    cmds.dispatch["clear"]({}, { note = function(t) notes2[#notes2 + 1] = t end,
        clear = function() notes2[#notes2 + 1] = "builtin-clear" end }, "clear", "")
    assert_eq(notes2[1], "builtin-clear", "2.1 clear still runs the built-in")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. home2 .. "'")
    print("2.1 ext commands dispatch + routing: OK")
end

-- 2.1b the real TUI carries the note: slash_callbacks.note must exist, the
-- fake cb in 2.1 could not catch a missing entry.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/note/note.lua", [[
return { name = "note", api_version = 1,
  commands = { { name = "noten", description = "note cmd",
                 fn = function(rest) return "noted " .. tostring(rest) end } } }]])
    local ext = fresh_ext()
    local reg = ext.load(home, {})
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    cmds.register_extension_commands(reg)
    _G.commands = cmds
    local uim = run_ui_with({ 17 }, {})
    uim._execute_command("noten", "x")
    local found = false
    for _, e in ipairs(uim._transcript.entries()) do
        if e.role == "system" and e.text == "noted x" then found = true end
    end
    assert_eq(found, true, "2.1b ext command note reaches the transcript")
    os.execute("rm -rf '" .. home .. "'")
    print("2.1b ext command note in TUI: OK")
end

-- 2.2 extensions prompt block: caps, order after skills.
do
    local ext = fresh_ext()
    local reg = ext.empty_registry()
    reg.tool_order = { "t1" }
    reg.tools = { t1 = { ext = "e", def = { description = "does things" } } }
    reg.prompt_parts = { { ext = "e", text = string.rep("y", 5000) } }
    ext.registry = reg
    local blk = ext.prompt_block()
    assert_notnil(blk, "2.2 block present")
    assert_true(blk:find("t1", 1, true) ~= nil, "2.2 tools listing names the tool")
    assert_true(blk:find("truncated", 1, true) ~= nil, "2.2 long prompt capped with marker")
    assert_true(#blk <= ext.PROMPT_TOTAL_MAX + 64, "2.2 total cap holds")
    -- order: extensions block comes after the skills block. The skills index
    -- is forced through cfg.skills_dirs so the check runs identically under an
    -- empty HOME (make test) and a populated one.
    _G.tether = host_mock({})
    _G.extensions = ext
    local ctx = assert(loadfile("src/tether/context.lua"))()
    local sdir = tmp_home() .. "/skills"
    assert(host_fs.mkdirp(sdir .. "/demo"))
    write_file(sdir .. "/demo/SKILL.md", "---\nname: demo\ndescription: demo skill\n---\nbody\n")
    local blocks = ctx.blocks({ skills_dirs = { sdir } }, { workspace = tmp_home() })
    local names = {}
    for _, b in ipairs(blocks) do names[#names + 1] = b.name end
    assert_eq(names[1], "identity", "2.2 identity stays first")
    assert_eq(names[#names], "extensions", "2.2 extensions block is last")
    local si, ei = nil, nil
    for i, n in ipairs(names) do
        if n == "skills" then si = i end
        if n == "extensions" then ei = i end
    end
    assert_notnil(si, "2.2 skills block present to order against")
    assert_true(si < ei, "2.2 extensions after skills")
    -- empty registry: no block, byte-identical compose
    ext.registry = ext.empty_registry()
    assert_eq(ext.prompt_block(), nil, "2.2 no contributions, no block")
    os.execute("rm -rf '" .. sdir .. "'")
    print("2.2 extensions prompt block: OK")
end

-- 2.3 resume replays an extension-tool turn with no extension loaded.
do
    _G.tether = host_mock({
        getcwd = function() return "/tmp/ws" end,
        realpath = function(p) return p end,
    })
    _G.extensions = nil
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.session = {
        latest = function() return "sess1" end,
        resume = function()
            return {
                { role = "user", content = "check the ticket" },
                { role = "assistant", content = "",
                  tool_calls = { { id = "c1", type = "function",
                    ["function"] = { name = "jira_get", arguments = "{}" } } } },
                { role = "tool", tool_call_id = "c1", name = "jira_get",
                  summary = "12 bytes", content = "T-1 resolved" },
                { role = "assistant", content = "Ticket T-1 is resolved." },
            }
        end,
    }
    _G.config = { get_system_prompt = function() return "base" end }
    _G.agent = assert(loadfile("src/tether/agent.lua"))()
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    local cfg = { workspace = "/tmp/ws" }
    local sid, messages = cmds.resume(nil, "/tmp/ws", cfg)
    assert_notnil(sid, "2.3 resume returns a session id")
    local h = _G.agent.get_history()
    local tool_msg = nil
    for _, m in ipairs(h) do
        if m.role == "tool" then tool_msg = m end
    end
    assert_notnil(tool_msg, "2.3 tool message rebuilt")
    if tool_msg then
        assert_eq(tool_msg.name, "jira_get", "2.3 tool name survives without the extension")
        assert_eq(tool_msg.summary, "12 bytes", "2.3 tool summary survives")
    end
    -- transcript seeds the same row the live turn showed
    local tr = assert(loadfile("src/tether/transcript.lua"))()
    if tr.clear then tr.clear() end
    local rows = tr.seed(messages)
    local found = false
    for _, r in ipairs(rows) do
        if r.role == "tool" and r.name == "jira_get" and r.summary == "12 bytes"
            and (r.body or ""):find("T-1 resolved", 1, true) then
            found = true
        end
    end
    assert_true(found, "2.3 transcript row matches the live turn")
    print("2.3 resume without extension: OK")
end

-- 3.1 on_before_tool: deny blocks execution, rewrite re-runs confirm,
-- failures and budget overruns degrade to allow.
do
    -- deny: run never executes, model sees the reason
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/g/g.lua", [[
return { name = "g", api_version = 1,
  hooks = { on_before_tool = function(tool, args, ctx)
    if tool == "run" then return { deny = "no shell in prod" } end
  end } }]])
    local ws = tmp_home()
    local cfg = { workspace = ws, non_interactive = true }
    local step1 = {}
    for _, e in ipairs(tc_ev(0, "c1", "run", '{"command":"touch MARKER"}')) do
        step1[#step1 + 1] = e
    end
    step1[#step1 + 1] = { type = "done", reason = "stop" }
    local agent, _ = drive_turn(home, cfg, {
        step1,
        { { type = "text_delta", text = "blocked" }, { type = "done", reason = "stop" } },
    })
    local got = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then got = m.content end
    end
    assert_true(got ~= nil and got:find("no shell in prod", 1, true) ~= nil,
        "3.1 deny reason reaches the model")
    local marker = io.open(ws .. "/MARKER", "r")
    assert_eq(marker, nil, "3.1 denied command never executes")
    if marker then marker:close() end
    -- rewrite inside->outside re-runs confirmation and parks (interactive)
    local home2 = tmp_home()
    local outside = tmp_home() .. "/out.txt"
    write_file(home2 .. "/.tether/extensions/r/r.lua",
        "return { name = \"r\", api_version = 1,\n" ..
        "  hooks = { on_before_tool = function(tool, args, ctx)\n" ..
        "    if tool == \"write\" then return { args = { path = \"" .. outside .. "\", content = \"x\" } } end\n" ..
        "  end } }")
    local ws2 = tmp_home()
    local cfg2 = { workspace = ws2 }
    local step = {}
    for _, e in ipairs(tc_ev(0, "c1", "write", '{"path":"inside.txt","content":"x"}')) do
        step[#step + 1] = e
    end
    step[#step + 1] = { type = "done", reason = "stop" }
    local _, events = drive_turn(home2, cfg2, { step })
    local confirmed = false
    for _, ev in ipairs(events) do
        if ev.type == "confirmation" then confirmed = true end
    end
    assert_true(confirmed, "3.1 rewritten outside target emits confirmation")
    assert_eq(io.open(outside, "r"), nil, "3.1 parked write touches nothing")
    assert_eq(io.open(ws2 .. "/inside.txt", "r"), nil, "3.1 original target untouched")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. home2 .. "'")
    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. ws2 .. "'")
    print("3.1 before-hooks deny + rewrite-confirm: OK")
end

-- 3.1 unit: failing hook and budget overrun degrade to allow.
do
    local ext = fresh_ext()
    local saved_tether = _G.tether
    _G.tether = host_mock({})
    ext.registry = ext.empty_registry()
    ext.registry.before = { { ext = "bad", fn = function() error("boom") end } }
    local kind = ext.run_before("read", { path = "x" }, {})
    assert_eq(kind, "allow", "3.1 failing hook degrades to allow")
    local tick = 0
    _G.tether = { monotonic_ms = function() tick = tick + 1000 return tick end }
    ext.registry.before = { { ext = "slow", fn = function() end } }
    local kind2 = ext.run_before("read", { path = "x" }, {})
    assert_eq(kind2, "allow", "3.1 over-budget hook degrades to allow")
    _G.tether = saved_tether
    print("3.1 hook isolation: OK")
end

-- 3.1b a rewrite must still fit the tool's schema (design Risks): unknown
-- key, wrong JSON type, or a dropped required argument denies the call with
-- the extension named, and the command never runs.
do
    local ext = fresh_ext()
    _G.tether = host_mock({})
    local write_schema = { type = "object",
        properties = { path = { type = "string" }, content = { type = "string" } },
        required = { "path", "content", _array = true } }
    assert_eq(ext.validate_args(write_schema, { path = "a", content = "b" }), nil,
        "3.1b matching rewrite passes")
    assert_true(tostring(ext.validate_args(write_schema, { path = "a", content = "b", extra = 1 }))
        :find("unknown argument 'extra'", 1, true) ~= nil, "3.1b unknown key rejected")
    assert_true(tostring(ext.validate_args(write_schema, { path = 42, content = "b" }))
        :find("must be string", 1, true) ~= nil, "3.1b wrong type rejected")
    assert_true(tostring(ext.validate_args(write_schema, { path = "a" }))
        :find("missing required argument 'content'", 1, true) ~= nil, "3.1b missing required rejected")
    assert_eq(ext.validate_args({ type = "object" }, { anything = true }), nil,
        "3.1b schema without properties is not checked")
    assert_true(tostring(ext.validate_args(write_schema, "nope"))
        :find("must be a table", 1, true) ~= nil, "3.1b non-table rewrite rejected")
    -- extension tools validate against their own declared schema
    ext.registry = ext.empty_registry()
    ext.registry.tools.shout = { ext = "loud", def = {
        schema = { type = "object", properties = { msg = { type = "string" } },
                   required = { "msg", _array = true } } } }
    ext.registry.before = { { ext = "loud", fn = function(tool)
        if tool == "shout" then return { args = { message = "hi" } } end
    end } }
    local kind, payload = ext.run_before("shout", { msg = "hi" }, {})
    assert_eq(kind, "deny", "3.1b ext tool rewrite validated against its schema")
    assert_true(tostring(payload):find("extension 'loud'", 1, true) ~= nil,
        "3.1b denial names the offending extension")
    -- built-in path: a bad rewrite of `run` denies before execution
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/bad/bad.lua", [[
return { name = "bad", api_version = 1,
  hooks = { on_before_tool = function(tool, args, ctx)
    if tool == "run" then return { args = { command = 42 } } end
  end } }]])
    local ws = tmp_home()
    local cfg = { workspace = ws, non_interactive = true }
    local step = {}
    for _, e in ipairs(tc_ev(0, "c1", "run", '{"command":"touch MARKER"}')) do
        step[#step + 1] = e
    end
    step[#step + 1] = { type = "done", reason = "stop" }
    local agent = drive_turn(home, cfg, {
        step,
        { { type = "text_delta", text = "no" }, { type = "done", reason = "stop" } },
    })
    local got = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then got = m.content end
    end
    assert_true(got ~= nil and got:find("must be string", 1, true) ~= nil,
        "3.1b invalid rewrite reaches the model as a tool error")
    assert_eq(io.open(ws .. "/MARKER", "r"), nil, "3.1b rejected command never executes")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. ws .. "'")
    print("3.1b rewrite schema validation: OK")
end

-- 3.2 on_after_tool: chained edits compose in order over the shaped body.
do
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/e1/e1.lua", [[
return { name = "e1", api_version = 1,
  hooks = { on_after_tool = function(tool, args, res, ctx)
    if tool == "list" then return { content = res.content .. "\n# one" } end
  end } }]])
    write_file(home .. "/.tether/extensions/e2/e2.lua", [[
return { name = "e2", api_version = 1,
  hooks = { on_after_tool = function(tool, args, res, ctx)
    if tool == "list" then return { content = res.content .. "\n# two" } end
  end } }]])
    local ws = tmp_home()
    assert(host_fs.mkdirp(ws .. "/sub"))
    write_file(ws .. "/sub/f.txt", "data")
    local cfg = { workspace = ws, non_interactive = true }
    local step = {}
    for _, e in ipairs(tc_ev(0, "c1", "list", '{"path":"sub"}')) do
        step[#step + 1] = e
    end
    step[#step + 1] = { type = "done", reason = "stop" }
    local agent, events = drive_turn(home, cfg, {
        step,
        { { type = "text_delta", text = "ok" }, { type = "done", reason = "stop" } },
    })
    local body = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then body = m.content end
    end
    assert_eq(body, "f.txt\n# one\n# two", "3.2 chained edits compose in order")
    local evbody = nil
    for _, ev in ipairs(events) do
        if ev.type == "tool_result" and ev.id == "c1" then evbody = ev.body end
    end
    assert_eq(evbody, "f.txt\n# one\n# two", "3.2 event carries the composed body")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. ws .. "'")
    print("3.2 after-hooks compose: OK")
end

-- 3.4 journal: deny lands as a tool error, rewrite as original/final args.
do
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/h/h.lua", [[
return { name = "h", api_version = 1,
  hooks = { on_before_tool = function(tool, args, ctx)
    if tool == "run" then return { deny = "nope" } end
    if tool == "list" and args.path == "a" then
      return { args = { path = "b" } }
    end
  end } }]])
    local ws = tmp_home()
    assert(host_fs.mkdirp(ws .. "/b"))
    write_file(ws .. "/b/g.txt", "g")
    -- Real file-backed journal (session._session_dir seam) so resume can
    -- replay the turn from disk with no extension code loaded.
    local smod = assert(loadfile("src/tether/session.lua"))()
    local jhome = tmp_home()
    smod._session_dir = jhome .. "/.tether/sessions"
    local cfg = { workspace = ws, non_interactive = true,
        _session_id = "sess-ext", _journal = {} }
    local step = {}
    for _, e in ipairs(tc_ev(0, "c1", "run", '{"command":"true"}')) do
        step[#step + 1] = e
    end
    for _, e in ipairs(tc_ev(1, "c2", "list", '{"path":"a"}')) do
        step[#step + 1] = e
    end
    step[#step + 1] = { type = "done", reason = "stop" }
    local agent, _ = drive_turn(home, cfg, {
        step,
        { { type = "text_delta", text = "ok" }, { type = "done", reason = "stop" } },
    }, function(sid, entry) smod.append(sid, entry) end)
    local deny_entry, rewrite_entry = nil, nil
    for _, e in ipairs(cfg._journal) do
        if e.type == "tool_result" and e.tool_call_id == "c1" then deny_entry = e end
        if e.type == "tool_call" and e.tool_call_id == "c2" then rewrite_entry = e end
    end
    assert_notnil(deny_entry, "3.4 deny journaled as tool result")
    assert_true(deny_entry.result.error:find("nope", 1, true) ~= nil,
        "3.4 deny journal carries the reason")
    assert_notnil(rewrite_entry, "3.4 rewrite journaled on the tool_call entry")
    assert_eq(rewrite_entry.original_args.path, "a", "3.4 journal keeps original args")
    assert_eq(rewrite_entry.args.path, "b", "3.4 the tool_call entry carries final args")
    local saw_second_entry = false
    for _, e in ipairs(cfg._journal) do
        if e.type == "tool_call_rewrite" then saw_second_entry = true end
    end
    assert_eq(saw_second_entry, false,
        "3.4 final args ride the tool_call entry, no second entry")
    -- resume reads the tool_call entry for the transcript's arg label: with
    -- only the journal (no extension code) it must show the final args.
    local replay = smod.resume("sess-ext")
    local shown = nil
    for _, m in ipairs(replay or {}) do
        if m.role == "tool" and m.tool_call_id == "c2" then shown = m.args and m.args.path end
    end
    assert_eq(shown, "b", "3.4 resume replay shows the rewritten args")
    local body = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" and m.tool_call_id == "c2" then body = m.content end
    end
    assert_eq(body, "g.txt", "3.4 rewritten call executes against the final args")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. jhome .. "'")
    print("3.4 hook journaling: OK")
end

-- 3.3 session start + app bootstrap: boot_extensions registers the registry
-- and slash commands, fire_session_start runs on_session_start exactly once
-- (the same call serves the new-session and resume paths in app.lua).
do
    _G.tether = host_mock({})
    _G.__st_starts = 0
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/st/st.lua", [[
return { name = "st", api_version = 1,
  commands = { { name = "stk", description = "st cmd", fn = function() return "ok" end } },
  hooks = { on_session_start = function(ctx)
    _G.__st_starts = _G.__st_starts + 1
  end } }]])
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    _G.commands = cmds
    _G.extensions = fresh_ext()
    local app = assert(loadfile("src/tether/app.lua"))()
    local cfg = { workspace = tmp_home() }
    local reg = app.boot_extensions(cfg, home)
    assert_notnil(reg, "3.3 boot_extensions returns a registry")
    assert_notnil(cmds.dispatch["stk"], "3.3 boot registers the extension command")
    assert_eq(_G.__st_starts, 0, "3.3 nothing fires at load time")
    app.fire_session_start(cfg)
    assert_eq(_G.__st_starts, 1, "3.3 on_session_start fires once")
    app.fire_session_start(cfg)
    assert_eq(_G.__st_starts, 1, "3.3 repeated fires stay deduped")
    os.execute("rm -rf '" .. home .. "'")
    print("3.3 session start + bootstrap: OK")
end

-- Swap io.stderr for a sink table: every module calls io.stderr:write at
-- runtime, so replacing the global field catches them all (restore puts it
-- back before any later test writes real output).
local function capture_stderr()
    local sink = {}
    local real = io.stderr
    io.stderr = { write = function(_, s) sink[#sink + 1] = tostring(s); return io.stderr end }
    return sink, function() io.stderr = real end
end

-- 4.1 install: local fixture copies identical bytes; a failed clone leaves
-- no directory (exec stubbed so the test never touches the network).
do
    _G.tether = host_mock({})
    local home = tmp_home()
    local src = tmp_home()
    write_file(src .. "/demo/demo.lua", "return { name = \"demo\", api_version = 1 }\n")
    local app = assert(loadfile("src/tether/app.lua"))()
    _G.extensions = fresh_ext()
    local out, errs, restore = {}, capture_stderr()
    local real_print = print
    print = function(s) out[#out + 1] = tostring(s) end
    local rc = app._run_ext_cli({ "install", src .. "/demo" }, home)
    restore()
    print = real_print
    assert_eq(rc, 0, "4.1 install from a local path exits 0")
    local dst = home .. "/.tether/extensions/demo/demo.lua"
    local function slurp(p)
        local f = io.open(p, "rb"); if not f then return nil end
        local d = f:read("*a"); f:close(); return d
    end
    assert_eq(slurp(dst), slurp(src .. "/demo/demo.lua"),
        "4.1 installed bytes match the fixture")
    -- unreachable git source: the exec seam fails, nothing is left behind
    local ext = _G.extensions
    local real_exec = ext._exec
    ext._exec = function(cmd)
        if cmd:find("git clone", 1, true) then return false, 128 end
        return real_exec(cmd)
    end
    local out2, errs2, restore2 = {}, capture_stderr()
    print = function(s) out2[#out2 + 1] = tostring(s) end
    local rc2 = app._run_ext_cli({ "install", "https://unreachable.invalid/x.git" }, home)
    restore2()
    print = real_print
    ext._exec = real_exec
    assert_eq(rc2, 1, "4.1 failed install exits 1")
    local joined = table.concat(errs2, "")
    assert_true(joined:find("git clone failed", 1, true) ~= nil,
        "4.1 failure is reported on stderr")
    assert_eq(io.open(home .. "/.tether/extensions/x/x.lua", "r"), nil,
        "4.1 failed install leaves no half-directory")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. src .. "'")
    print("4.1 tether install: OK")
end

-- 4.2 list: one name per line for every installed extension.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/alpha/alpha.lua",
        "return { name = \"alpha\", api_version = 1 }")
    write_file(home .. "/.tether/extensions/beta/beta.lua",
        "return { name = \"beta\", api_version = 1 }")
    local app = assert(loadfile("src/tether/app.lua"))()
    _G.extensions = fresh_ext()
    local out = {}
    local real_print = print
    print = function(s) out[#out + 1] = tostring(s) end
    local rc = app._run_ext_cli({ "list" }, home)
    print = real_print
    assert_eq(rc, 0, "4.2 list exits 0")
    assert_eq(table.concat(out, "\n"), "alpha\nbeta", "4.2 both names print, one per line")
    os.execute("rm -rf '" .. home .. "'")
    print("4.2 tether list: OK")
end

-- 4.3 remove: asks for confirmation, then deletes only that directory.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    write_file(home .. "/.tether/extensions/del/del.lua",
        "return { name = \"del\", api_version = 1 }")
    write_file(home .. "/.tether/extensions/keep/keep.lua",
        "return { name = \"keep\", api_version = 1 }")
    local app = assert(loadfile("src/tether/app.lua"))()
    _G.extensions = fresh_ext()
    local real_read, real_print = io.read, print
    io.read = function() return "y" end
    local out = {}
    print = function(s) out[#out + 1] = tostring(s) end
    local rc = app._run_ext_cli({ "remove", "del" }, home)
    print = real_print
    io.read = real_read
    assert_eq(rc, 0, "4.3 confirmed remove exits 0")
    assert_eq(io.open(home .. "/.tether/extensions/del/del.lua", "r"), nil,
        "4.3 the removed directory is gone")
    assert_notnil(io.open(home .. "/.tether/extensions/keep/keep.lua", "r"),
        "4.3 the sibling extension is untouched")
    -- declining the prompt changes nothing
    io.read = function() return "n" end
    out = {}
    print = function(s) out[#out + 1] = tostring(s) end
    local rc2 = app._run_ext_cli({ "remove", "keep" }, home)
    print = real_print
    io.read = real_read
    assert_eq(rc2, 0, "4.3 declined remove exits 0")
    assert_eq(out[1], "cancelled", "4.3 decline reports cancelled")
    assert_notnil(io.open(home .. "/.tether/extensions/keep/keep.lua", "r"),
        "4.3 declined remove keeps the files")
    -- --yes skips the prompt entirely
    io.read = function() error("prompt shown despite --yes") end
    local rc3 = app._run_ext_cli({ "remove", "keep", "--yes" }, home)
    io.read = real_read
    assert_eq(rc3, 0, "4.3 --yes removes without a prompt")
    assert_eq(io.open(home .. "/.tether/extensions/keep/keep.lua", "r"), nil,
        "4.3 --yes deleted the directory")
    os.execute("rm -rf '" .. home .. "'")
    print("4.3 tether remove: OK")
end

if failed > 0 then
    print("FAILURES: " .. tostring(failed))
    os.exit(1)
end
print("extensions: all OK (" .. tostring(passed) .. " assertions)")
