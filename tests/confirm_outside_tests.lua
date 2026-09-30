-- tests/confirm_outside_tests.lua — outside-workspace confirmation:
-- the menu grants an exception (spec tools: Outside-workspace guard), so an
-- approved call must execute instead of re-refusing, and the menu must show
-- the resolved path.
-- Run: lua tests/confirm_outside_tests.lua (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

local function tmp_dir()
    local p = os.tmpname()
    os.remove(p)
    assert(host_fs.mkdirp(p))
    return p
end

-- Symptom 2 (red first): one-shot "allow" on an outside-workspace write
-- must execute the write instead of failing with the same refusal text.
do
    local ws = tmp_dir()
    local outside = tmp_dir()
    local target = outside .. "/note.txt"
    _G.tether = host_mock({
        getcwd = function() return ws end,
        realpath = function(p) return p end,
    })
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.session = { append = function() end }
    _G.config = { get_system_prompt = function() return nil end }
    local args_json = '{"path":"' .. target .. '","content":"hello"}'
    _G.api = {
        stream = function(_, _, _, on_event)
            on_event({ type = "tool_call_start", id = "c1", name = "write", arguments = "" })
            on_event({ type = "tool_call_delta", index = 0, id = "c1", arguments = args_json })
            on_event({ type = "done", reason = "stop" })
            return true, nil
        end,
    }
    local agent = assert(loadfile("src/tether/agent.lua"))()
    agent.clear()
    local events = {}
    local ok = agent.turn({ workspace = ws }, "", "do it",
        function(ev) events[#events + 1] = ev end)
    assert_true(ok, "confirm-outside turn parks")
    local cid = nil
    for _, ev in ipairs(events) do
        if ev.type == "confirmation" and ev.details and ev.details[1] then
            cid = ev.details[1].id
        end
    end
    assert_notnil(cid, "confirm-outside menu parked the call")
    local events2 = {}
    agent.confirm(cid, "allow", { workspace = ws },
        function(ev) events2[#events2 + 1] = ev end)
    local f = io.open(target, "r")
    local body = f and f:read("*a")
    if f then f:close() end
    assert_eq(body, "hello", "confirm-outside approved write executes")
    local refused = false
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" and tostring(m.content):find("requires confirmation", 1, true) then
            refused = true
        end
    end
    assert_false(refused, "confirm-outside no refusal text after approval")
    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. outside .. "'")
    print("confirm-outside approval executes: OK")
end

-- Symptom 1 (red first): the menu label shows the resolved absolute path
-- with an outside marker, not the raw relative path the model sent.
do
    local ws = tmp_dir()
    _G.tether = nil
    local uimod, S
    do
        local names = { "tether", "config", "session", "agent", "api", "tools" }
        local originals = {}
        for _, n in ipairs(names) do originals[n] = _G[n] end
        _G.tether = host_mock({
            getcwd = function() return ws end,
            realpath = function(p) return p end,
        })
        _G.tools = assert(loadfile("src/tether/tools.lua"))()
        local stubs = {
            tether = {
                getcwd = function() return ws end,
                realpath = function(p) return p end,
            },
            tools = _G.tools,
            config = { load = function()
                return { model = "test", workspace = ws, ui = { input_max_lines = 8 } }
            end, api_key = function() return "" end },
        }
        uimod, S = run_ui_with({ 17 }, stubs)
        for _, n in ipairs(names) do _G[n] = originals[n] end
    end
    -- the handler resolves through _G.tools at event time (set in prod);
    -- the harness restored globals after run, so re-point for the event.
    local keep_tools = _G.tools
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.tether = host_mock({
        getcwd = function() return ws end,
        realpath = function(p) return p end,
    })
    local outside = tmp_dir()
    local outside_file = outside .. "/context7.lua"
    uimod._handle_agent_event({ type = "confirmation", details = { {
        id = "k1", name = "patch",
        args = { path = outside_file, patch = "--- a/x\n+++ b/x\n" },
    } } })
    _G.tools = keep_tools
    _G.tether = nil
    local label = S.confirmation and S.confirmation.label or ""
    assert_true(label:find(outside_file, 1, true) ~= nil,
        "confirm-outside label shows the resolved path")
    assert_true(label:find("outside workspace", 1, true) ~= nil,
        "confirm-outside label marks outside workspace")
    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. outside .. "'")
    print("confirm-outside menu shows resolved path: OK")
end

-- T318/T319 (audit H8): run's confirm target is its cwd, never the command
-- text, and the approval key is that cwd, so one approval cannot cover the
-- same command run somewhere else.
do
    local ws = tmp_dir()
    local outside = tmp_dir()
    local elsewhere = tmp_dir()
    _G.tether = host_mock({
        getcwd = function() return ws end,
        realpath = function(p) return p end,
    })
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    local cp = assert(loadfile("src/tether/confirm_policy.lua"))()
    local cfg = { workspace = ws }

    assert_true(cp.should_confirm("run", { command = "ls -la", cwd = outside }, cfg),
        "T318 run with an outside cwd asks for confirmation")
    assert_false(cp.should_confirm("run", { command = "ls -la" }, cfg),
        "T318 run without a cwd has no outside target to ask about")
    assert_false(cp.should_confirm("run", { command = "ls -la", cwd = ws }, cfg),
        "T318 run inside the workspace stays unconfirmed")
    -- the old bug: an innocuous command text hid the outside cwd
    assert_true(cp.should_confirm("run", { command = "echo hi", cwd = outside }, cfg),
        "T318 command text never hides an outside cwd")
    assert_true(cp.should_confirm("write", { path = outside .. "/note.txt", content = "x" }, cfg),
        "T318 write outside still asks")

    local key_outside = cp.approve_key("run", { command = "ls -la", cwd = outside })
    assert_eq(key_outside, "run:" .. outside, "T319 a run approves its cwd, not its command")
    local session = { [key_outside] = true }
    assert_true(cp.is_session_approved("run", { command = "ls -la", cwd = outside }, session),
        "T319 the approved cwd is covered")
    assert_false(cp.is_session_approved("run", { command = "ls -la", cwd = elsewhere }, session),
        "T319 approval does not leak to another cwd")
    assert_true(cp.check_auto_approve("run", { command = "ls -la", cwd = outside }, {
        workspace = ws, auto_approve = { "^run:" .. outside .. "$" },
    }), "T319 an auto-approve pattern on the cwd matches")
    assert_eq(cp.path_of({ command = "ls -la", cwd = outside }), outside,
        "T319 path_of prefers cwd over command")

    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. outside .. "'")
    os.execute("rm -rf '" .. elsewhere .. "'")
    print("T318-T319 run confirms on cwd: OK")
end

-- T318e2e (audit H8): end to end, an outside-cwd run must park on the menu
-- instead of running into tools.run's refusal.
do
    local ws = tmp_dir()
    local outside = tmp_dir()
    _G.tether = host_mock({
        getcwd = function() return ws end,
        realpath = function(p) return p end,
        -- if the menu ever stops opening the call would run for real; stub the
        -- exec so the assertions below report that instead of crashing.
        exec = function() return true, 0 end,
    })
    _G.tools = assert(loadfile("src/tether/tools.lua"))()
    _G.session = { append = function() end }
    _G.config = { get_system_prompt = function() return nil end }
    local args_json = '{"command":"ls -la","cwd":"' .. outside .. '"}'
    _G.api = {
        stream = function(_, _, _, on_event)
            on_event({ type = "tool_call_start", id = "r1", name = "run", arguments = "" })
            on_event({ type = "tool_call_delta", index = 0, id = "r1", arguments = args_json })
            on_event({ type = "done", reason = "stop" })
            return true, nil
        end,
    }
    local agent = assert(loadfile("src/tether/agent.lua"))()
    agent.clear()
    local events = {}
    local ok = agent.turn({ workspace = ws }, "", "look around",
        function(ev) events[#events + 1] = ev end)
    assert_true(ok, "T318e2e the outside run parks")
    local parked = nil
    for _, ev in ipairs(events) do
        if ev.type == "confirmation" then parked = ev end
    end
    assert_notnil(parked, "T318e2e a confirmation event was emitted")
    assert_eq(parked.details and parked.details[1] and parked.details[1].name, "run",
        "T318e2e the menu asks about the run call")
    local events2 = {}
    agent.confirm(parked.details[1].id, "deny", { workspace = ws },
        function(ev) events2[#events2 + 1] = ev end)
    local denied, refused = false, false
    for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then
            local body = tostring(m.content)
            if body:find("denied by user", 1, true) then denied = true end
            if body:find("requires confirmation", 1, true) then refused = true end
        end
    end
    assert_true(denied, "T318e2e denying records the denial")
    assert_false(refused, "T318e2e the menu opened, so the guard never refused")
    os.execute("rm -rf '" .. ws .. "'")
    os.execute("rm -rf '" .. outside .. "'")
    print("T318e2e outside run reaches the menu: OK")
end

print("confirm outside section: OK")
if failed > 0 then
    print("FAILURES: " .. tostring(failed))
    os.exit(1)
end
