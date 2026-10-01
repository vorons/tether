-- tests/cli_tests.lua — app/print/resume/transport/gateway (split from lua_tests.lua, Phase C).
dofile("tests/helpers.lua")


-- Test json_encode/session.lua
do
    local function json_encode(obj)
        if type(obj) == "string" then
            return '"' .. obj:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
        elseif type(obj) == "number" then
            return tostring(obj)
        elseif type(obj) == "boolean" then
            return obj and "true" or "false"
        elseif type(obj) == "nil" then
            return "null"
        elseif type(obj) == "table" then
            local items = {}
            for k, v in pairs(obj) do
                local key = type(k) == "string" and '"' .. k:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' or tostring(k)
                items[#items + 1] = key .. ":" .. json_encode(v)
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
        return tostring(obj)
    end

    assert_eq(json_encode({name = "test"}), '{"name":"test"}', "json_encode table")
    assert_eq(json_encode(42), "42", "json_encode number")
    assert_eq(json_encode(true), "true", "json_encode true")
    assert_eq(json_encode(false), "false", "json_encode false")
    assert_eq(json_encode("hello"), '"hello"', "json_encode string")
    assert_eq(json_encode(nil), "null", "json_encode nil")
end

-- Test parse_json_str (api.lua pattern)
do
    local function parse_json_str(s)
        local obj = {}
        for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*"([^"]*)"') do
            obj[key] = val
        end
        for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%d+%.?%d*)') do
            obj[key] = tonumber(val)
        end
        for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%S+)') do
            val = val:gsub("[,%}]$", "")
            if val == "true" then obj[key] = true elseif val == "false" then obj[key] = false end
        end
        return next(obj) and obj or nil
    end

    local r = parse_json_str('{"name": "test", "count": 42, "ok": true}')
    assert_eq(r and r.name, "test", "parse_json_str string field")
    assert_eq(r and r.count, 42, "parse_json_str number field")
    assert_eq(r and r.ok, true, "parse_json_str bool field")

    r = parse_json_str('{}')
    assert_true(r == nil or next(r) == nil, "parse_json_str empty returns nil")
end

-- Test tools.sq and within_workspace
do
    local WS = "/home/voron/project"
    local function sq(s)
        return "'" .. s:gsub("'", "'\\''") .. "'"
    end

    assert_eq(sq("hello"), "'hello'", "sq simple")
    assert_eq(sq("it's"), "'it'\\''s'", "sq escaped")

    local function to_rel(path)
        local prefix = WS .. "/"
        if path:sub(1, #prefix) == prefix then
            return path:sub(#prefix + 1)
        end
        return path
    end

    local function within(path, allow)
        local rel = to_rel(path)
        return rel ~= path or allow
    end

    assert_true(within("/home/voron/project/src", false), "within workspace")
    assert_false(within("/etc/passwd", false), "outside workspace")
    assert_true(within("/etc/passwd", true), "outside allowed")
end

-- Test resolve/to_rel
do
    local WS = "/home/voron/project"
    local function resolve(path)
        if path:find("^/") then return path end
        return WS .. "/" .. path
    end
    local function to_rel(path)
        local prefix = WS .. "/"
        if path:sub(1, #prefix) == prefix then
            return path:sub(#prefix + 1)
        end
        return path
    end

    assert_eq(resolve("src/foo.lua"), WS .. "/src/foo.lua", "resolve relative")
    assert_eq(resolve("/abs/foo.lua"), "/abs/foo.lua", "resolve absolute")
    assert_eq(to_rel(WS .. "/src/foo.lua"), "src/foo.lua", "to_rel")
end

-- Test uuid format
do
    local function uuid()
        local t = {}
        for i = 1, 32 do
            t[i] = string.format("%x", math.random(0, 15))
        end
        return table.concat(t, "")
    end
    local id = uuid()
    assert_eq(#id, 32, "uuid length")
    assert_true(id:match("^[0-9a-f]+$") ~= nil, "uuid hex")
end

-- Test glob pattern matching
do
    local function match_glob(filename, pattern)
        local lp = pattern:gsub("%.", "%%."):gsub("%.%.", ".*"):gsub("%*", ".*")
        return filename:match(lp) ~= nil
    end
    assert_true(match_glob("foo.lua", "*.lua"), "glob *.lua matches foo.lua")
    assert_false(match_glob("foo.txt", "*.lua"), "glob *.lua doesn't match foo.txt")
    assert_true(match_glob("main.py", "*.py"), "glob *.py matches main.py")
end

-- Test JSON parser (shared logic — test the actual parse_args via agent module)
do
    local names = {"tether", "config", "session", "agent", "api"}
    local originals = {}
    for _, name in ipairs(names) do originals[name] = _G[name] end
    _G.tether = host_mock{ write = function() end, getcwd = function() return "/tmp" end,
                   read_char = function() return nil end, read_char_nb = function() return nil end,
                   resize_requested = function() return false end,
                   get_terminal_size = function() return { width = 80, height = 24 } end }
    _G.config = { load = function() return { model = "test", workspace = "/tmp" } end,
                  api_key = function() return "" end }
    _G.session = {}
    _G.agent = nil
    _G.api = { stream = function() return true end, list_models = function() return {} end }
    local agent_mod = assert(loadfile("src/tether/agent.lua"))()
    -- get parse_args via upvalue of turn
    local function upvalue(fn, wanted)
        local i = 1
        while true do
            local n, v = debug.getupvalue(fn, i)
            if not n then return nil end
            if n == wanted then return v end
            i = i + 1
        end
    end
    local _ = upvalue  -- parse_args is local, not easily exposed
    -- Instead test the public M.turn path is green: parse_args now handles nested JSON
    -- We verify via a quick standalone copy check:
    local function json_parse_test(s)
        -- mirror the agent.lua json_parse with the same fix applied
        local pos = 1
        local function skip_ws()
            while pos <= #s and s:sub(pos,pos):match("[%s]") do pos = pos + 1 end
        end
        local function parse_value()
            skip_ws()
            local c = s:sub(pos,pos)
            if c == nil then return nil end
            if c == '"' then
                pos = pos + 1
                local buf = {}
                while true do
                    local ch = s:sub(pos,pos)
                    if ch == nil then break end
                    if ch == '"' then pos = pos + 1; return table.concat(buf)
                    else buf[#buf+1] = ch; pos = pos + 1 end
                end
                return table.concat(buf)
            elseif c == "{" then
                pos = pos + 1
                local obj = {}
                skip_ws()
                if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
                while true do
                    skip_ws()
                    local key
                    if s:sub(pos,pos) == '"' then key = parse_value()
                    else
                        local ks = s:match("[%w_%-]+", pos)
                        if not ks then break end
                        key = ks; pos = pos + #key
                    end
                    skip_ws()
                    if s:sub(pos,pos) ~= ":" then break end
                    pos = pos + 1
                    obj[key] = parse_value()
                    skip_ws()
                    local nx = s:sub(pos,pos)
                    if nx == "," then pos = pos + 1
                    elseif nx == "}" then pos = pos + 1; break
                    else break end
                end
                return obj
            elseif c == "[" then
                pos = pos + 1
                local arr = {}
                skip_ws()
                if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
                while true do
                    arr[#arr+1] = parse_value()
                    skip_ws()
                    local nx = s:sub(pos,pos)
                    if nx == "," then pos = pos + 1
                    elseif nx == "]" then pos = pos + 1; break
                    else break end
                end
                return arr
            elseif s:sub(pos, pos+3) == "true" then
                pos = pos + 4; return true
            elseif s:sub(pos, pos+4) == "false" then
                pos = pos + 5; return false
            elseif s:sub(pos, pos+3) == "null" then
                pos = pos + 4; return nil
            else
                local st, fin = s:find("%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
                if st then
                    local num = s:sub(st, fin)
                    pos = fin + 1
                    return tonumber(num)
                end
                return nil
            end
        end
        return parse_value()
    end

    local obj = json_parse_test('{"path":"a","offset":3,"limit":null,"timeout":120}')
    assert_eq(obj.path, "a", "json path")
    assert_eq(obj.offset, 3, "json offset")
    assert_eq(obj.timeout, 120, "json timeout")

    local arr = json_parse_test('[1,2,3]')
    assert_eq(#arr, 3, "json array len")
    assert_eq(arr[2], 2, "json array[2]")

    local nested = json_parse_test('{"a":{"b":[{"c":true}]}}')
    assert_true(nested.a.b[1].c, "json nested")

    for _, name in ipairs(names) do
        _G[name] = originals[name]
    end
end

-- Test TUI streaming keeps assistant text in the transcript
do
    local names = {"tether", "config", "session", "agent", "api"}
    local originals = {}
    local preload = {}
    for _, name in ipairs(names) do
        originals[name] = _G[name]
        preload[name] = package.preload[name]
    end

    -- Simulate: scripted bytes "hi" + Enter, then Ctrl+Q exits. The
    -- reactor loop drains read_char_nb, so the script lives there (a shared
    -- counter keeps blocking/read ordering identical); exhaustion is EOF.
    local char_calls = 0
    local seq = { ("h"):byte(), ("i"):byte(), 13, 17 }
    local function next_byte()
        char_calls = char_calls + 1
        if char_calls <= #seq then return seq[char_calls] end
        return nil
    end
    _G.tether = host_mock{
        write = function(s) end,
        resize_requested = function() return false end,
        get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
        getcwd = function() return "/tmp" end,
        read_char = function() return next_byte() or 17 end,
        read_char_nb = function() return next_byte() end,
    }
    _G.config = {
        load = function() return { model = "test-model", workspace = "/tmp", ui = { input_max_lines = 8 } } end,
        api_key = function() return "" end,
    }
    _G.session = { new_session = function() return "session-id" end }
    _G.agent = {
        turn = function(_, _, text, on_event)
            on_event({ type = "text_delta", text = "streamed text" })
            return true
        end,
    }
    _G.api = { list_models = function() return {} end }
    package.preload.tether = function() return _G.tether end
    package.preload.config = function() return _G.config end
    package.preload.session = function() return _G.session end
    package.preload.agent = function() return _G.agent end
    package.preload.api = function() return _G.api end

    local ok, err = pcall(function()
        local ui = assert(loadfile("src/tether/ui.lua"))()
        -- run the UI: types "hi" + Enter, then Ctrl+Q exits
        ui.run()
        local last = ui._transcript.last()
        assert_eq(last and last.role, "assistant", "TUI stores streamed assistant text")
        assert_eq(last and last.text, "streamed text", "TUI retains streamed text after redraw")
    end)
    if not ok then err = err end

    for _, name in ipairs(names) do
        _G[name] = originals[name]
        package.preload[name] = preload[name]
    end
    if not ok then error(err, 0) end
end

-- T15: the transport makes exactly ONE attempt and reports a classified
-- failure. add-retry-and-continuation: the retry loop moved to the agent turn,
-- so the client no longer sleeps, repeats a request, or emits
-- `retry`/`error` events. Each http_stream call plays back the script entry
-- for that request: script[n] = array of body lines.
do
    local api_mod = assert(loadfile("src/tether/api.lua"))()

    local function run_stream(script, cfg)
        local requests = 0
        local _G_old_tether = _G.tether
        _G.tether = host_mock{
            http_stream = function(_, _, _, _, on_line)
                requests = requests + 1
                for _, line in ipairs(script[requests] or {}) do
                    on_line(line)
                end
                return true
            end,
            http_get = function() return nil, "not used" end,
            sleep = function() end,
        }
        local events = {}
        local function on_event(ev) events[#events + 1] = ev end
        local ok, failure = api_mod.stream(cfg or { base_url = "http://x", model = "m" },
            "key", { { role = "user", content = "hi" } }, on_event)
        _G.tether = _G_old_tether
        return ok, failure, events, requests
    end

    -- The same call, but the transport itself fails with `err` (no bytes).
    local function run_stream_with_error(err)
        local _G_old_tether = _G.tether
        _G.tether = host_mock{
            http_stream = function() return false, err end,
            http_get = function() return nil, "not used" end,
            sleep = function() end,
        }
        local events = {}
        local ok, failure = api_mod.stream({ base_url = "http://x", model = "m" },
            "key", { { role = "user", content = "hi" } }, function(ev) events[#events + 1] = ev end)
        _G.tether = _G_old_tether
        return ok, failure
    end

    -- Case 1: a 429 body is one attempt, returned as a retryable failure
    local ok1, f1, ev1, requests1 = run_stream({
        [1] = { '{"error":{"status":429,"code":"rate_limit"}}' },
        [2] = { 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}' },
    })
    assert_false(ok1, "T15 429 fails the attempt")
    assert_eq(requests1, 1, "T15 exactly one request")
    assert_true(f1 ~= nil, "T15 failure returned")
    assert_eq(f1 and f1.kind, "server", "T15 429 classified server")
    assert_true(f1 and f1.retryable, "T15 429 is retryable")
    assert_eq(f1 and f1.status, 429, "T15 status carried")
    local saw_retry, saw_error = false, false
    for _, ev in ipairs(ev1) do
        if ev.type == "retry" then saw_retry = true end
        if ev.type == "error" then saw_error = true end
    end
    assert_false(saw_retry, "T15 no retry event from the client")
    assert_false(saw_error, "T15 no error event from the client")

    -- Case 2: a valid SSE stream succeeds on the first attempt
    local ok2 = run_stream({
        [1] = { 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}' },
    })
    assert_true(ok2, "T15 SSE stream succeeds")

    -- Case 3: an empty body is a retryable `empty` failure
    local ok3, f3 = run_stream({ [1] = {} })
    assert_false(ok3, "T15 empty body fails the attempt")
    assert_eq(f3 and f3.kind, "empty", "T15 empty body classified")
    assert_true(f3 and f3.retryable, "T15 empty body retryable")

    -- Case 4: a non-SSE 401 body is a permanent failure
    local ok4, f4 = run_stream({ [1] = { '{"error":{"message":"Invalid API key","status":401}}' } })
    assert_false(ok4, "T15 401 fails the attempt")
    assert_eq(f4 and f4.kind, "permanent", "T15 401 permanent")
    assert_false(f4 and f4.retryable, "T15 permanent is not retryable")

    -- Case 5: Retry-After is carried on the failure
    local ok5, f5 = run_stream({ [1] = { '{"error":{"message":"rate limit","status":429,"retry_after":5}}' } })
    assert_false(ok5, "T15 429 with retry_after fails")
    assert_eq(f5 and f5.retry_after, 5, "T15 retry_after carried")

    -- Case 6: status-only classification survives the snippet path
    local _, f6 = run_stream({ [1] = { '{"error":{"message":"boom","status":503}}' } })
    assert_eq(f6 and f6.kind, "server", "T15 503 classified server")

    -- Case 7 (add-retry-and-continuation): a transfer the user stopped with
    -- Ctrl+C is reported distinctly and is never retryable
    local ok7, f7 = run_stream_with_error("Operation was aborted by an application callback")
    assert_false(ok7, "T15 an interrupted transfer fails the attempt")
    assert_eq(f7 and f7.kind, "interrupted", "T15 aborted transfer classified interrupted")
    assert_false(f7 and f7.retryable, "T15 an interrupted transfer is not retryable")
    assert_eq(f7 and f7.message, "interrupted by user",
        "T15 an interrupted transfer says so instead of reporting a transport error")

    -- Case 8: any other transport error still classifies as a connection error
    local _, f8 = run_stream_with_error("Could not connect to server")
    assert_eq(f8 and f8.kind, "connection", "T15 a refused connection stays retryable")
    assert_true(f8 and f8.retryable, "T15 a refused connection is retryable")

    -- Case 9: a long provider error body survives into the failure message
    -- whole (regression: the 200-char snippet cut the evidence — a 400
    -- naming the bad tool call arrived truncated mid-JSON, undebuggable
    -- in both transcript and debug log).
    local long_body = '{"error":{"message":"' .. string.rep("E", 400)
        .. 'TAIL-MARKER","status":400}}'
    local _, f9 = run_stream({ [1] = { long_body } })
    assert_true(f9 and f9.message and f9.message:find("TAIL-MARKER", 1, true) ~= nil,
        "T15 long error body reaches the failure message intact")
end

-- T19: print mode — parse --print/-p with optional prompt, mark non-interactive
do
    -- Mirror app.lua parse_args logic inline (app.lua uses global 'arg')
    local function parse_args(args)
        local opts = { interactive = true, print_mode = false, print_prompt = nil }
        local i = 1
        while i <= #args do
            local a = args[i]
            if a == "--print" or a == "-p" then
                opts.print_mode = true
                opts.interactive = false
                if args[i + 1] and not args[i + 1]:match("^%-") then
                    opts.print_prompt = args[i + 1]
                    i = i + 1
                end
            end
            i = i + 1
        end
        return opts
    end
    local o = parse_args({ "--print", "hello" })
    assert_true(o.print_mode, "T19 print_mode true")
    assert_false(o.interactive, "T19 interactive false")
    assert_eq(o.print_prompt, "hello", "T19 prompt captured")

    local o2 = parse_args({ "-p" })
    assert_true(o2.print_mode, "T19 short -p sets print_mode")
    assert_eq(o2.print_prompt, nil, "T19 no prompt -> nil")

    local o3 = parse_args({ "--print", "--model", "gpt" })
    assert_true(o3.print_mode, "T19 print with following flags")
    assert_eq(o3.print_prompt, nil, "T19 --print followed by flag -> no prompt")
end

-- T240: --resume takes an optional session id (sequel), bare -r keeps
-- latest-session behavior. Tested against the REAL app parser.
do
  local app = assert(loadfile("src/tether/app.lua"))()
  assert_notnil(app._parse_args, "T240 parser exposed for tests")
  local o = app._parse_args({ "-w", "/ws", "--print", "hi", "--resume", "abc123" })
  assert_true(o.print_mode, "T240 print mode")
  assert_eq(o.print_prompt, "hi", "T240 prompt kept")
  assert_eq(o.workspace, "/ws", "T240 workspace kept")
  assert_eq(o.resume, "abc123", "T240 resume id captured")
  local o2 = app._parse_args({ "--print", "hi", "--resume", "abc123" })
  assert_eq(o2.print_prompt, "hi", "T240 prompt-first order")
  assert_eq(o2.resume, "abc123", "T240 resume id after prompt")
  local o3 = app._parse_args({ "-r" })
  assert_eq(o3.resume, true, "T240 bare -r keeps latest behavior")
  local o4 = app._parse_args({ "--print", "hi" })
  assert_eq(o4.resume, nil, "T240 no resume by default")
  local o5 = app._parse_args({ "-r", "-w", "/ws" })
  assert_eq(o5.resume, true, "T240 -r before flags stays latest")
  print("T240 resume takes an optional session id: OK")
end

-- T348 (audit M16): flags are validated. An unknown flag is refused, -w/-m
-- never swallow another flag as their value, and a trailing valueless flag
-- is reported — each without starting a session.
do
  local app = assert(loadfile("src/tether/app.lua"))()
  local o, err = app._parse_args({ "--frobnicate" })
  assert_eq(o, nil, "T348 unknown flag parses to nothing")
  assert_true((err or ""):find("--frobnicate", 1, true) ~= nil,
    "T348 unknown flag reported")
  local o2, err2 = app._parse_args({ "-w", "--model", "gpt" })
  assert_eq(o2, nil, "T348 -w refuses a flag as its value")
  assert_true((err2 or ""):find("--workspace", 1, true) ~= nil,
    "T348 missing workspace value reported")
  local o3, err3 = app._parse_args({ "-m" })
  assert_eq(o3, nil, "T348 trailing -m parses to nothing")
  assert_true((err3 or ""):find("--model", 1, true) ~= nil,
    "T348 missing model value reported")
  -- valid spellings keep working, including the positional --print prompt
  local ok = app._parse_args({ "-w", "/ws", "--print", "summarize this" })
  assert_eq(ok.workspace, "/ws", "T348 good -w value kept")
  assert_eq(ok.print_prompt, "summarize this", "T348 positional prompt kept")
  print("T348 command-line flags are validated: OK")
end

-- T349 (audit M17): a workspace that does not exist is reported, not run.
do
  local app = assert(loadfile("src/tether/app.lua"))()
  local orig = _G.tether
  -- realpath fails: refused, naming the path
  _G.tether = host_mock({ realpath = function() return nil end })
  local cfg = { workspace = "/definitely-not-a-real-ws-xyz" }
  local ok, bad = app.resolve_workspace(cfg)
  assert_eq(ok, nil, "T349 unresolvable workspace refused")
  assert_eq(bad, "/definitely-not-a-real-ws-xyz", "T349 refusal names the path")
  -- realpath ok but not a directory: refused too
  _G.tether = host_mock({
    realpath = function(p) return p end,
    stat = function() return { mtime = 0, size = 1, is_dir = false } end,
  })
  local cfg2 = { workspace = "/tmp/definitely-a-file" }
  assert_eq(app.resolve_workspace(cfg2), nil, "T349 a file is not a workspace")
  -- a real directory resolves (symlinks expand through realpath)
  _G.tether = host_mock({
    realpath = function(p) return (p:gsub("link$", "target")) end,
    stat = function() return { mtime = 0, size = 0, is_dir = true } end,
  })
  local cfg3 = { workspace = "/ws/link" }
  assert_true(app.resolve_workspace(cfg3), "T349 a directory resolves")
  assert_eq(cfg3.workspace, "/ws/target", "T349 symlinks resolve")
  _G.tether = orig
  print("T349 missing workspace is reported: OK")
end

-- T241: sequel plumbing. validate keeps resume; spawn mints the child
-- journal (sequel reuses the given one); the child command carries
-- --resume after the prompt slot; results report the session id.
do
  local orig_tether, orig_tools, orig_session = _G.tether, _G.tools, _G.session
  _G.tools = {
    _resolve = function(p, cfg) return p end,
    _within = function(abs, cfg) return true end,
    _workspace = function(cfg) return "/tmp/ws" end,
  }
  local minted = {}
  _G.session = { new_session = function(ws, model)
    minted[#minted + 1] = { ws = ws, model = model }
    return "childsid" .. #minted
  end }
  local spawns = {}
  _G.tether = {
    exec_bg_argv = function(argv, opts)
      spawns[#spawns + 1] = { argv = argv, opts = opts }
      return {}
    end,
    exec_bg_poll = function(h, ms) return "done", 0 end,
    exec_bg_free = function(h) return true end,
    exec_bg_kill = function(h) return true end,
    abort_requested = function() return false end,
    monotonic_ms = function() return 1000 end,
  }
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local cfg = { workspace = "/tmp/ws", model = "m",
    subagents = { max_parallel = 4, timeout = 600, max_depth = 1 } }
  local it = assert(sub.validate_item({ task = "go", resume = "abc" }, {}, cfg))
  assert_eq(it.resume, "abc", "T241 validate keeps resume")
  -- fresh spawn mints the journal
  local rec = assert(sub.run_call_bg({ task = "go" }, cfg))
  assert_eq(#minted, 1, "T241 spawn mints one journal")
  assert_eq(minted[1].ws, "/tmp/ws", "T241 journal minted in task cwd")
  local a1 = spawns[1].argv
  local pi1 = nil
  for i, v in ipairs(a1) do if v == "--print" then pi1 = i end end
  assert_notnil(pi1, "T241 child argv has --print")
  assert_eq(a1[pi1 + 1], "go", "T241 prompt glued to --print")
  assert_eq(a1[pi1 + 2], "--resume", "T241 resume flag after the prompt")
  assert_eq(a1[pi1 + 3], "childsid1", "T241 child resumes the minted journal")
  assert_eq(spawns[1].opts.env.TETHER_WORKSPACE, "/tmp/ws", "T241 workspace in child env")
  local jid = rec.jobs[1].id
  assert_eq(sub._running[jid].item.sid, "childsid1", "T241 item carries sid")
  sub.cancel_all("over")
  -- sequel reuses the given journal, mints nothing
  local rec2 = assert(sub.run_call_bg({ task = "again", resume = "abc" }, cfg))
  assert_eq(#minted, 1, "T241 sequel mints nothing")
  local a2 = spawns[2].argv
  local pi2 = nil
  for i, v in ipairs(a2) do if v == "--print" then pi2 = i end end
  assert_notnil(pi2, "T241 sequel argv has --print")
  assert_eq(a2[pi2 + 1], "again", "T241 sequel prompt glued to --print")
  assert_eq(a2[pi2 + 2], "--resume", "T241 sequel resume flag after the prompt")
  assert_eq(a2[pi2 + 3], "abc", "T241 sequel resumes the given journal")
  sub.cancel_all("over")
  -- results report the session
  local fuller = { status = "ok", exit_code = 0, output = "hi",
    elapsed_ms = 1, model = "m", session_id = "s9" }
  local comb = sub.combine_batch({ fuller }, 1)
  assert_true(comb.output:find("session=s9", 1, true) ~= nil,
    "T241 batch header reports the session")
  _G.tether, _G.tools, _G.session = orig_tether, orig_tools, orig_session
  print("T241 sequel plumbing: OK")
end

-- T242: --debug propagates to the child command so its stages land in
-- the shared log; without debug the command stays clean.
do
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local item = { task = "go", cwd = "/ws", timeout = 5, sid = "s1" }
  local function has_flag(a, flag)
    for _, v in ipairs(a) do if v == flag then return true end end
    return false
  end
  local plain = sub.build_command(item, {})
  local dbg = sub.build_command(item, { cfg = { debug = true } })
  assert_true(has_flag(dbg, "--debug"),
    "T242 debug reaches the child argv")
  assert_true(not has_flag(plain, "--debug"),
    "T242 no debug flag without debug")
  print("T242 debug propagates to child: OK")
end

-- T243: argv-branch children detach stdin. A bg-group child sharing the
-- parent's terminal stops at SIGTTOU in init_termios (State T, zero
-- output) — </dev/null keeps isatty false. The pipe branch (leading
-- dash) must keep its stdin pipe: no redirect there.
do
  local sub = assert(loadfile("src/tether/subagent.lua"))()
  local _, opts = sub.build_command(
    { task = "go", cwd = "/ws", timeout = 5, sid = "s1" }, {})
  assert_eq(opts.stdin, "null",
    "T243 argv child detaches stdin")
  local pargv, popts = sub.build_command(
    { task = "- go", cwd = "/ws", timeout = 5, sid = "s1" }, {})
  assert_eq(type(popts.stdin), "table",
    "T243 leading-dash task still goes through the pipe")
  assert_eq(popts.stdin.pipe, "- go",
    "T243 pipe carries the exact task bytes")
  assert_eq(pargv[#pargv - 1], "--resume",
    "T243 pipe branch argv ends at the resume flag, task rides stdin")
  assert_eq(pargv[#pargv], "s1",
    "T243 pipe branch keeps the resume session")
  print("T243 bg child detaches stdin: OK")
end

-- === M7 regression suite (recreated) + M8 TDD tests =========================


-- M7/T24: raw tool_call argument deltas (D2a/D2b) + D6 hang regression
with_modules(base_env, function(mods)
    local api = mods.api
    assert_notnil(api.parse_sse_line, "T24 api.parse_sse_line exported")

    local evs = {}
    -- wire format: \92 = backslash in Lua literals, explicit for clarity
    api.parse_sse_line('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\92"path\92":\92"a"}}]}}]}',
        function(ev) evs[#evs + 1] = ev end)
    api.parse_sse_line('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":".lua","extra":1}}]}}]}',
        function(ev) evs[#evs + 1] = ev end)

    local saw_start, saw_delta = false, false
    local arg_parts = {}
    for _, ev in ipairs(evs) do
        if ev.type == "tool_call_start" then saw_start = true end
        if ev.type == "tool_call_delta" then
            saw_delta = true
            arg_parts[#arg_parts + 1] = ev.arguments
            if ev.id then assert_eq(ev.id, "call_1", "T24 id-delta carries id") end
            if ev.index then assert_eq(ev.index, 0, "T24 index-delta carries index") end
        end
    end
    assert_true(saw_start, "T24 D2a tool_call_start emitted")
    assert_true(saw_delta, "T24 D2a delta emitted for id-less chunk")
    assert_eq(#arg_parts, 2, "T24 both argument fragments emitted")

    local full = table.concat(arg_parts)
    local parsed = mods.agent.parse_args(full)
    assert_eq(parsed.path, "a.lua", "T24 D2b one unescape -> source struct")

    -- D6: truncated arguments must terminate (used to hang forever)
    local truncated = mods.agent.parse_args('{\92"path\92":\92"a.lua')
    assert_eq(type(truncated), "table", "T24 D6 truncated args terminate")

    -- D2b: escaped backslash survives one unescape
    local p2 = mods.agent.parse_args('{\92"a\92\92\92\92nb\92":1}')
    local tricky_key = 'a\92nb'
    assert_eq(p2 and p2[tricky_key], 1, "T24 D2b backslash survives")
end)

-- T24b: realistic gateway chunks — envelope id present, arguments split
-- mid-string. The envelope id must not hijack the tool_call id, a chunk
-- must emit exactly once (id- plus index-form double-emit duplicated the
-- arguments into invalid JSON), and unterminated fragments must survive.
with_modules(base_env, function(mods)
    local api = mods.api
    local evs = {}
    local function feed(l) api.parse_sse_line(l, function(ev) evs[#evs + 1] = ev end) end
    feed('data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list","arguments":"{\92"pa"}]},"role":"assistant"},"finish_reason":null}]}')
    feed('data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\92":\92"/tmp\92"}"}}]},"finish_reason":null}]}')
    local start_id, deltas = nil, {}
    for _, ev in ipairs(evs) do
        if ev.type == "tool_call_start" then start_id = ev.id end
        if ev.type == "tool_call_delta" then deltas[#deltas + 1] = ev end
    end
    assert_eq(start_id, "call_1", "T24b start carries the tool id, not the envelope id")
    assert_eq(#deltas, 2, "T24b one delta per chunk, no double emit")
    local raw = (deltas[1] and deltas[1].arguments or "")
        .. (deltas[2] and deltas[2].arguments or "")
    assert_eq(raw, '{\92"path\92":\92"/tmp\92"}', "T24b fragments assemble to exact bytes")
    local parsed = mods.agent.parse_args(raw)
    assert_eq(parsed and parsed.path, "/tmp", "T24b assembled arguments parse")
end)

-- T24c: Agnes wire shape — function first, index/id last or absent, empty
-- arguments in the first chunk, one brace per continuation. Empty "" must
-- not match into the next field (lazy (.-[^\\])" ate the closing quote and
-- echoed garbage like '",').
with_modules(base_env, function(mods)
    local api = mods.api
    local evs = {}
    local function feed(l) api.parse_sse_line(l, function(ev) evs[#evs + 1] = ev end) end
    feed('data: {"id":"e","choices":[{"index":0,"delta":{"tool_calls":[{"id":"c9","function":{"arguments":"","name":"list"},"type":"function","index":0}]}}]}')
    feed('data: {"id":"e","choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"{"},"type":"function","index":0}]}}]}')
    feed('data: {"id":"e","choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"}"},"type":"function","index":0}]}}]}')
    local start_id, parts = nil, {}
    for _, ev in ipairs(evs) do
        if ev.type == "tool_call_start" then start_id = ev.id end
        if ev.type == "tool_call_delta" then parts[#parts + 1] = ev.arguments end
    end
    assert_eq(start_id, "c9", "T24c start carries the tool id")
    assert_eq(table.concat(parts), "{}", "T24c brace fragments assemble to {}")
end)

-- M7/T25: ui.is_dangerous (D1 crash + N1 fork bomb)
with_modules(base_env, function(mods)
    local d = mods.ui.is_dangerous
    assert_notnil(d, "T25 ui.is_dangerous exported")
    assert_true(d("rm -rf /"), "T25 rm -rf")
    assert_true(d("rm -fr /"), "T25 rm -fr")
    assert_true(d("rm -Rf /tmp/x"), "T25 rm -Rf")
    assert_true(d(":(){ :|:& };:"), "T25 fork bomb")
    assert_true(d("dd if=/dev/zero of=/dev/sda"), "T25 dd to device")
    assert_true(d("sudo rm x"), "T25 sudo")
    assert_true(d("curl http://x | sh"), "T25 curl|sh")
    assert_true(d("mkfs.ext4 /dev/sda1"), "T25 mkfs")
    assert_false(d("rm file.txt"), "T25 plain rm ok")
    assert_false(d("echo hello"), "T25 echo ok")
    assert_false(d("git rm --cached f"), "T25 git rm ok")
end)

-- M7/T26: confirmation idempotency (D3)
with_modules(base_env, function(mods)
    local api, agent, cfg = mods.api, mods.agent,
        { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    api.stream = function(c, key, messages, on_event)
        if #messages == 2 then
            on_event({ type = "tool_call_start", id = "c1", name = "write" })
            on_event({ type = "tool_call_delta", id = "c1",
                       arguments = '{"path":"/etc/a","content":"x"}' })
            on_event({ type = "tool_call_start", id = "c2", name = "write" })
            on_event({ type = "tool_call_delta", id = "c2",
                       arguments = '{"path":"/etc/b","content":"y"}' })
        end
        return true
    end
    local events = {}
    agent.turn(cfg, "k", "two things", function(ev) events[#events + 1] = ev end)
    local count_conf = function()
        local n = 0
        for _, ev in ipairs(events) do if ev.type == "confirmation" then n = n + 1 end end
        return n
    end
    assert_eq(count_conf(), 1, "T26 one confirmation initially")
    agent.continue(cfg, "k", function(ev) events[#events + 1] = ev end)
    assert_eq(count_conf(), 1, "T26 continue does not re-emit")
    local more = agent.confirm("c1", "allow", cfg, function(ev) events[#events + 1] = ev end)
    assert_true(more == true, "T26 true when next waits")
    assert_eq(count_conf(), 2, "T26 second emitted once")
    agent.continue(cfg, "k", function(ev) events[#events + 1] = ev end)
    assert_eq(count_conf(), 2, "T26 no re-emit after second")
    local more2 = agent.confirm("c2", "deny", cfg, function(ev) events[#events + 1] = ev end)
    assert_true(more2 == false, "T26 false when queue empty")
end)

-- T221: subagent — confirmations degrade to deny in non-interactive runs
-- (mirrors the ask degradation): no confirmation event, deny tool result,
-- the loop continues instead of parking forever.
with_modules(base_env, function(mods)
    local api, agent = mods.api, mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  non_interactive = true }
    local ncalls = 0
    api.stream = function(c, key, messages, on_event)
        ncalls = ncalls + 1
        if ncalls == 1 then
            on_event({ type = "tool_call_start", id = "c1", name = "write" })
            on_event({ type = "tool_call_delta", id = "c1",
                       arguments = '{"path":"/etc/a","content":"x"}' })
            on_event({ type = "done", reason = "tool_calls" })
        else
            on_event({ type = "text_delta", text = "denied, moving on" })
            on_event({ type = "done", reason = "stop" })
        end
        return true
    end
    agent.clear()
    local events = {}
    agent.turn(cfg, "k", "write outside", function(ev) events[#events + 1] = ev end)
    local saw_conf, saw_deny = false, false
    for _, ev in ipairs(events) do
        if ev.type == "confirmation" then saw_conf = true end
        if ev.type == "tool_result" and ev.name == "write" and ev.error
            and ev.error:find("no interactive user", 1, true) then saw_deny = true end
    end
    assert_false(saw_conf, "T221 no confirmation event without a user")
    assert_true(saw_deny, "T221 deny tool result without a user")
    assert_true(ncalls >= 2, "T221 loop continues after the deny")
    print("T221 non-interactive deny: OK")
end)

-- T222: subagent guards — allowlist refusal and depth rejection both speak
-- the unknown-tool contract; the loop continues with the error result.
with_modules(base_env, function(mods)
    local api, agent = mods.api, mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  _tools_allowlist = { "list" } }
    local ncalls = 0
    api.stream = function(c, key, messages, on_event)
        ncalls = ncalls + 1
        if ncalls == 1 then
            on_event({ type = "tool_call_start", id = "c1", name = "write" })
            on_event({ type = "tool_call_delta", id = "c1",
                       arguments = '{"path":"/tmp/ws/f","content":"x"}' })
            on_event({ type = "done", reason = "tool_calls" })
        else
            on_event({ type = "text_delta", text = "refused, moving on" })
            on_event({ type = "done", reason = "stop" })
        end
        return true
    end
    agent.clear()
    local events = {}
    agent.turn(cfg, "k", "try a write", function(ev) events[#events + 1] = ev end)
    local saw_refusal = false
    for _, ev in ipairs(events) do
        if ev.type == "tool_result" and ev.name == "write" and ev.error
            and ev.error:find("unknown tool: write", 1, true) then saw_refusal = true end
    end
    assert_true(saw_refusal, "T222 non-allowlisted tool refused as unknown")
    assert_true(ncalls >= 2, "T222 loop continues after the refusal")
    print("T222 allowlist dispatch guard: OK")
end)
with_modules(base_env, function(mods)
    local api, agent = mods.api, mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  _subagent_depth = 1 }
    api.stream = function(c, key, messages, on_event)
        on_event({ type = "tool_call_start", id = "c1", name = "subagent" })
        on_event({ type = "tool_call_delta", id = "c1",
                   arguments = '{"task":"recurse"}' })
        on_event({ type = "done", reason = "tool_calls" })
        return true
    end
    agent.clear()
    local events = {}
    agent.turn(cfg, "k", "spawn down", function(ev) events[#events + 1] = ev end)
    local saw_depth = false
    for _, ev in ipairs(events) do
        if ev.type == "tool_result" and ev.name == "subagent" and ev.error
            and ev.error:find("unknown tool: subagent", 1, true) then saw_depth = true end
    end
    assert_true(saw_depth, "T222 subagent at depth limit is unknown")
    print("T222 depth dispatch guard: OK")
end)

-- T26b: split tool_call chunks (gateway style: id+name first, arguments in
-- index-only continuation deltas) assemble exactly. Dropped fragments made
-- the tool run on fallback {} while the echoed arguments went out truncated
-- and strict providers 400'd every follow-up request ("bad request").
with_modules(base_env, function(mods)
    local agent = mods.agent
    local ncalls = 0
    mods.api.stream = function(c, key, messages, on_event)
        ncalls = ncalls + 1
        if ncalls == 1 then
            on_event({ type = "tool_call_start", id = "c1", name = "list" })
            on_event({ type = "tool_call_delta", index = 0,
                       arguments = '{"path":' })
            on_event({ type = "tool_call_delta", index = 0,
                       arguments = '"/tmp/ws"}' })
            on_event({ type = "done", reason = "tool_calls" })
        else
            on_event({ type = "text_delta", text = "done" })
            on_event({ type = "done", reason = "stop" })
        end
        return true
    end
    agent.clear()
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    agent.turn(cfg, "k", "list files", function() end)
    local echoed = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "assistant" and type(m.content) == "table"
            and m.content.tool_calls then
            echoed = m.content.tool_calls[1]["function"].arguments
        end
    end
    assert_eq(echoed, '{"path":"/tmp/ws"}',
        "T26b index-only deltas assemble into exact arguments")
end)

-- T26c: the echoed arguments are transport-DECODED. Fragments arrive raw
-- (still SSE-escaped); echoing them raw adds a whole escape layer and
-- strict providers 400 every follow-up ("arguments must be valid JSON").
with_modules(base_env, function(mods)
    local agent = mods.agent
    local ncalls = 0
    mods.api.stream = function(c, key, messages, on_event)
        ncalls = ncalls + 1
        if ncalls == 1 then
            on_event({ type = "tool_call_start", id = "c1", name = "list" })
            on_event({ type = "tool_call_delta", index = 0,
                       arguments = '{\92"path\92":' })
            on_event({ type = "tool_call_delta", index = 0,
                       arguments = '\92"/tmp/ws\92"}' })
            on_event({ type = "done", reason = "tool_calls" })
        else
            on_event({ type = "text_delta", text = "done" })
            on_event({ type = "done", reason = "stop" })
        end
        return true
    end
    agent.clear()
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    agent.turn(cfg, "k", "list files", function() end)
    local echoed = nil
    for _, m in ipairs(agent.get_history()) do
        if m.role == "assistant" and type(m.content) == "table"
            and m.content.tool_calls then
            echoed = m.content.tool_calls[1]["function"].arguments
        end
    end
    assert_eq(echoed, '{"path":"/tmp/ws"}',
        "T26c echo carries decoded arguments (no extra escape layer)")
end)

-- M7/T27: resume produces valid OpenAI sequence (D4)
with_modules(base_env, function(mods)
    local messages = {
        { role = "user", content = "read the file" },
        { role = "assistant", tool_calls = { { id = "t9", type = "function",
            ["function"] = { name = "read", arguments = '{"path":"f.lua"}' } } } },
        { role = "tool", tool_call_id = "t9", content = "5 стр." },
        { role = "assistant", content = "done" },
    }
    local agent, api = mods.agent, mods.api
    agent.clear()
    for _, msg in ipairs(messages) do
        if msg.role == "user" then agent.add_user(msg.content)
        elseif msg.role == "assistant" then
            if msg.tool_calls then agent.add_assistant({ tool_calls = msg.tool_calls })
            else agent.add_assistant(msg.content) end
        elseif msg.role == "tool" then
            agent.add_tool_result(msg.tool_call_id, msg.content or "")
        end
    end
    local history = agent.get_history()
    local ok_contract = true
    for i, m in ipairs(history) do
        if m.role == "assistant" and type(m.content) == "table" and m.content.tool_calls then
            local nxt = history[i + 1]
            if not nxt or nxt.role ~= "tool"
                or nxt.tool_call_id ~= m.content.tool_calls[1].id then
                ok_contract = false
            end
        end
    end
    assert_true(ok_contract, "T27 D4 tool_call followed by tool result")
    local encoded = api.encode_messages(history)
    assert_true(encoded:find('"tool_call_id":"t9"', 1, true) ~= nil,
        "T27 D4 request carries tool result")
end)

-- M7/T28: non-SSE error body -> error event (D5b)
with_modules(base_env, function(mods)
    local old = _G.tether
    _G.tether = host_mock{
        http_stream = function(_, _, _, _, on_line)
            on_line('{"error":{"message":"Invalid API key","status":401}}')
            return true
        end,
        http_get = function() return nil, "not used" end,
        sleep = function() end,
    }
    local events = {}
    local ok, failure = mods.api.stream({ base_url = "http://x", model = "m" },
        "badkey", { { role = "user", content = "hi" } },
        function(ev) events[#events + 1] = ev end)
    _G.tether = old
    assert_false(ok, "T28 401 body fails stream")
    assert_eq(failure and failure.kind, "permanent", "T28 401 classified permanent")
    assert_true(failure and failure.message:find("401", 1, true) ~= nil, "T28 status in message")
    -- add-retry-and-continuation: the client reports the failure instead of
    -- emitting an `error` event; the retry loop decides whether that surfaces.
    local saw_error = false
    for _, ev in ipairs(events) do
        if ev.type == "error" then saw_error = true end
    end
    assert_false(saw_error, "T28 no error event from the client")
end)

-- M7/T29: session ts round-trip as string (N2) via _session_dir seam
with_modules(base_env, function(mods)
    local session = mods.session
    local tmpdir = "/tmp/tether_test_sessions"
    os.execute("rm -rf " .. tmpdir)
    session._session_dir = tmpdir
    local id = session.new_session("/tmp/ws", "m")
    assert_notnil(id, "T29 session created")
    session.append(id, { ts = os.date(), type = "session_end", meta = { workspace = "/tmp/ws" } })
    local evs = session.read(id)
    assert_eq(#evs, 2, "T29 two events")
    assert_true(type(evs[2].ts) == "string" and #evs[2].ts > 0, "T29 N2 ts is string")
    os.execute("rm -rf " .. tmpdir)
end)

-- M8/T30: ASCII mode — glyph mapping, spinner, no high bytes (R1)
with_modules(base_env, function(mods)
    mods.ui._ascii_mode = true -- test seam (env is not ASCII in CI)
    assert_notnil(mods.ui.to_ascii, "T30 ui.to_ascii exported")
    local glyph_cases = {
        { "●", "*" }, { "⚙", "[t]" }, { "›", ">" }, { "✗", "[x]" }, { "✓", "[ok]" }, { "✻", "*" },
        { "↻", "[r]" }, { "⏹", "[x]" }, { "⚠", "!" }, { "▸", ">" }, { "▾", "v" },
        { "┌", "+" }, { "┐", "+" }, { "└", "+" }, { "┘", "+" }, { "─", "-" },
        { "│", "|" }, { "•", "-" }, { "…", "..." }, { "▓", "#" }, { "░", "-" },
        { "↑", "^" }, { "↓", "v" }, { "←", "<" }, { "→", ">" },
        -- pi-style 1.2: scroll-label glyphs the box rules carry
        { "↑ 3 more", "^ 3 more" }, { "↓ 2 more", "v 2 more" },
    }
    for _, case in ipairs(glyph_cases) do
        local out = mods.ui.to_ascii(case[1])
        assert_eq(out, case[2], "T30 ascii " .. case[1])
        for i = 1, #out do
            assert_true(out:byte(i) <= 0x7F, "T30 byte <= 0x7F for " .. case[1])
        end
    end
    assert_eq(mods.ui.to_ascii("⚠ потенциально опасная"),
              "! потенциально опасная", "T30 cyrillic preserved")
    assert_notnil(mods.ui.SPINNER_ASCII, "T30 SPINNER_ASCII exported")
    for _, frame in ipairs(mods.ui.SPINNER_ASCII) do
        for i = 1, #frame do
            assert_true(frame:byte(i) <= 0x7F, "T30 spinner frame ascii")
        end
    end
end)

-- M8/T31: themes (role→sgr), ui.wrap, mono has no SGR (R2)
with_modules(base_env, function(mods)
    local ui = mods.ui
    assert_notnil(ui.set_theme, "T31 ui.set_theme exported")
    assert_notnil(ui.THEMES, "T31 THEMES exported")

    -- default theme exists with core roles (spec delta: at least accent,
    -- warn, error, success, dim, italic, reverse, bold, comment, string,
    -- number, keyword, code, heading)
    local t = ui.THEMES["default"]
    assert_notnil(t, "T31 default theme exists")
    for _, role in ipairs({ "accent", "warn", "error", "success", "dim", "reverse",
        "italic", "bold", "comment", "string", "number", "keyword", "code", "heading" }) do
        assert_notnil(t[role], "T31 default role " .. role)
    end

    -- unknown theme -> fallback to default
    ui.set_theme("nonexistent")
    assert_eq(ui._theme_name, "default", "T31 unknown theme falls back")

    -- mono theme: role lookups yield no SGR codes
    ui.set_theme("mono")
    assert_eq(ui._theme_name, "mono", "T31 mono selected")
    local s = ui.sgr_role("accent", "x")
    assert_eq(s, "x", "T31 mono strips SGR")
    assert_eq(ui.sgr_role("heading", "x"), "x", "T31 mono leaves heading raw")
    assert_eq(ui.sgr_role("code", "x"), "x", "T31 mono leaves code raw")

    ui.set_theme("default")
    local s2 = ui.sgr_role("accent", "x")
    assert_true(#s2 > #"x", "T31 default accent wraps text")
    assert_true(s2:find("\27[", 1, true) ~= nil, "T31 default emits SGR")

    -- wrap toggle honored by wrap() through seam
    assert_notnil(ui.set_wrap, "T31 ui.set_wrap exported")
    ui.set_wrap(false)
    local lines = ui.wrap_lines("hello world this is long", 10)
    assert_eq(#lines, 1, "T31 wrap=false truncates to one line")
    ui.set_wrap(true)
    local lines2 = ui.wrap_lines("hello world this is long", 10)
    assert_true(#lines2 > 1, "T31 wrap=true wraps")
end)

-- accent-mint-no-bold: default accent is mint without bold per depth; heading keeps bold
with_modules(base_env, function(mods)
    local ui = mods.ui
    ui.set_theme("default")
    ui._color_depth = "truecolor"
    local tc = ui.sgr_role("accent", "x")
    assert_true(tc:find("38;2;105;224;152", 1, true) ~= nil, "accent mint on truecolor")
    assert_true(tc:find(";1m", 1, true) == nil, "accent has no bold on truecolor")
    ui._color_depth = "256"
    local c256 = ui.sgr_role("accent", "x")
    assert_true(c256:find("38;5;78", 1, true) ~= nil, "accent fallback on 256")
    assert_true(c256:find(";1m", 1, true) == nil, "accent has no bold on 256")
    local h = ui.sgr_role("heading", "x")
    assert_true(h:find("36;1", 1, true) ~= nil, "heading keeps bold")
    ui._color_depth = "none"
end)

-- splash-colors 2.2: light-background probe for the default theme's light
-- variant (muted tier switch, dark fallback). Seams: M._light_bg override,
-- M._colorfgbg override for the COLORFGBG parse.
with_modules(base_env, function(mods)
    local ui = mods.ui
    ui.set_theme("default")
    ui._color_depth = "truecolor"
    -- explicit override wins over the probe
    ui._light_bg = true
    assert_true(ui.is_light_bg(), "light override true")
    local lm = ui.sgr_role("muted", "x")
    assert_true(lm:find("30", 1, true) ~= nil, "light muted uses the dark-gray tier")
    ui._light_bg = false
    assert_true(not ui.is_light_bg(), "light override false")
    local dm = ui.sgr_role("muted", "x")
    assert_true(dm:find("90", 1, true) ~= nil, "dark muted stays light gray")
    -- probe parses COLORFGBG bg: 7/15 mean light, anything else dark
    ui._light_bg = nil
    ui._colorfgbg = "0;15"
    assert_true(ui.is_light_bg(), "COLORFGBG bg 15 is light")
    ui._colorfgbg = "0;0"
    assert_true(not ui.is_light_bg(), "COLORFGBG bg 0 is dark")
    ui._colorfgbg = "nonsense"
    assert_true(not ui.is_light_bg(), "unparseable COLORFGBG falls back to dark")
    ui._colorfgbg = ""
    assert_true(not ui.is_light_bg(), "missing COLORFGBG falls back to dark")
    ui._colorfgbg = nil
    ui._light_bg = nil
    ui._color_depth = "none"
end)

-- splash-colors 1.3: AGENTS.md ancestor chain (repo root down to ws,
-- outermost first). Temp dirs with a .git marker for the repo root.
with_modules(base_env, function(mods)
    local ui = mods.ui
    local root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p " .. root .. "/sub/deep")
    local git = io.open(root .. "/.git", "w")
    git:write("gitdir: elsewhere")
    git:close()
    local chain = ui._agents_chain(root .. "/sub/deep")
    assert_eq(#chain, 3, "chain holds repo root plus descendants")
    assert_eq(chain[1], root, "chain starts at the repo root (outermost first)")
    assert_eq(chain[3], root .. "/sub/deep", "chain ends at ws")
    -- no .git above ws: only ws itself
    local lone = os.tmpname()
    os.remove(lone)
    os.execute("mkdir -p " .. lone)
    local single = ui._agents_chain(lone)
    assert_eq(#single, 1, "no repository above ws means ws only")
    assert_eq(single[1], lone, "ws itself is the only entry")
    os.execute("rm -rf " .. root .. " " .. lone)
end)

-- M8/T32: markdown-lite md.render_entry (R4)
with_modules(base_env, function(mods)
    local ui = mods.ui
    -- 7.x: unit tests render md_render without M.run; force depth "none"
    -- so SGR-free rendering is deterministic regardless of COLORTERM env
    ui._color_depth = "none"
    assert_notnil(ui.md_render, "T32 ui.md_render exported")
    local render = ui.md_render

    -- plain text passes through
    local out = render("just text", 40)
    assert_eq(#out, 1, "T32 plain text one line")

    -- code block with lang: framed, lang in top border
    out = render("before\n```lua\nlocal x = 1\nlocal y = 2\n```\nafter", 40)
    -- expected: "before", border, 2 code lines, border, "after"
    assert_eq(#out, 6, "T32 code block line count: " .. #out)
    assert_true(out[2]:find("lua", 1, true) ~= nil, "T32 lang in border")
    assert_true(out[2]:find("+", 1, true) ~= nil or out[2]:find("┌", 1, true) ~= nil,
        "T32 top border char")
    local joined = table.concat(out, "\n")
    assert_true(joined:find("local x = 1", 1, true) ~= nil, "T32 code line preserved")

    -- inline code is preserved with markers stripped (color is role-based)
    out = render("run `npm test` now", 40)
    joined = table.concat(out)
    assert_true(joined:find("npm test", 1, true) ~= nil, "T32 inline code text")
    assert_true(joined:find("`", 1, true) == nil, "T32 backticks stripped")

    -- bold stripped, text kept
    out = render("**bold** word", 40)
    joined = table.concat(out)
    assert_true(joined:find("bold", 1, true) ~= nil, "T32 bold text kept")
    assert_true(joined:find("%*%*", 1, true) == nil, "T32 ** stripped")

    -- heading (no trailing blank: collapse handles spacing)
    out = render("# Title", 40)
    assert_eq(#out, 1, "T32 heading one row")
    assert_true(out[1]:find("Title", 1, true) ~= nil, "T32 heading text")

    -- list items get bullet prefix
    out = render("- one\n- two", 40)
    assert_eq(#out, 2, "T32 list 2 items")
    local bullet = (mods.ui._ascii_mode) and "-" or "•"
    assert_true(out[1]:find(bullet, 1, true) ~= nil, "T32 bullet prefix")

    -- escaping: backtick escaped is literal
    out = render("\\`not code\\`", 40)
    joined = table.concat(out)
    assert_true(joined:find("not code", 1, true) ~= nil, "T32 escaped text kept")

    -- wide unicode width: uses ulen not bytes (display width via utf8.len)
    out = render("привет мир большой текст строки", 10)
    for _, l in ipairs(out) do
        local w = utf8.len(l) or #l
        assert_true(w <= 10, "T32 unicode width respected: " .. w)
    end

    -- ASCII mode: bullet and arrows map
    ui._ascii_mode = true
    out = render("- item", 40)
    for i = 1, #out[1] do
        assert_true(out[1]:byte(i) <= 0x7F, "T32 ascii bullet bytes")
    end
    ui._ascii_mode = nil

    -- code frame: the top border, the body rails and the bottom border all
    -- share the display width (no one-off narrow top edge)
    out = render("```lua\nlocal x = 1\n```", 40)
    assert_eq(#out, 3, "T32 bare frame has top, body, bottom")
    assert_eq(ui.vlen(out[1]), 40, "T32 frame top border spans the width")
    assert_eq(ui.vlen(out[2]), 40, "T32 frame body spans the width")
    assert_eq(ui.vlen(out[3]), 40, "T32 frame bottom border spans the width")

    -- tables: cells padded to the widest cell, the separator row renders as
    -- a rule, and every row shares the column grid
    out = render("| a | bb |\n| --- | --- |\n| 1 | 22 |", 40)
    assert_eq(#out, 3, "T32 table renders three rows")
    assert_true(out[1]:find("a   │ bb", 1, true) ~= nil, "T32 table cells padded to widest cell")
    assert_true(out[2]:find("─┼─", 1, true) ~= nil, "T32 table separator renders as a rule")
    assert_eq(out[1]:find("│", 1, true), out[3]:find("│", 1, true),
        "T32 table columns align")
    assert_eq(ui.vlen(out[1]), ui.vlen(out[3]), "T32 table rows share the grid")

    -- ordered lists: numbered prefix, continuation aligned to the prefix
    out = render("1. first\n2. second", 40)
    assert_eq(#out, 2, "T32 ordered list renders two items")
    assert_true(out[1]:find("1. first", 1, true) ~= nil, "T32 ordered prefix on item one")
    assert_true(out[2]:find("2. second", 1, true) ~= nil, "T32 ordered prefix on item two")
    out = render("1. lorem ipsum dolor sit amet", 20)
    assert_true(#out > 1, "T32 ordered item wraps")
    assert_eq(out[2]:sub(1, 3), "   ", "T32 ordered continuation indent")

    -- blank runs collapse to a single row; leading/trailing blanks drop
    out = render("a\n\n\n\nb\n\n", 40)
    assert_eq(#out, 3, "T32 blank runs collapse to a single row")
    assert_eq(out[2], "", "T32 the collapsed blank row sits between content")
    out = render("\n\na\n\n", 40)
    assert_eq(#out, 1, "T32 leading and trailing blanks are dropped")

    -- headings wrap to the width
    out = render("# alpha beta gamma delta epsilon", 16)
    assert_true(#out > 1, "T32 heading wraps to several rows")
    for _, hl in ipairs(out) do
        assert_true(ui.vlen(hl) <= 16, "T32 heading row fits the width")
    end
    assert_true(table.concat(out, " "):find("epsilon", 1, true) ~= nil,
        "T32 heading text survives the wrap")

    -- role colours for inline markup and headings (depth 256; ansi_fn wired
    -- exactly like the assistant and ask call sites pass M.md_ansi)
    ui._color_depth = "256"
    out = render("run `npm test` now", 40, ui.md_ansi)
    joined = table.concat(out)
    assert_true(joined:find("\27[38;5;139m", 1, true) ~= nil, "T32 inline code takes the code role")
    assert_true(joined:find("`", 1, true) == nil, "T32 inline code marker stripped when coloured")
    out = render("**bold** and *italic*", 40, ui.md_ansi)
    joined = table.concat(out)
    assert_true(joined:find("\27[1m", 1, true) ~= nil, "T32 bold takes the bold role")
    assert_true(joined:find("\27[3m", 1, true) ~= nil, "T32 italic takes the italic role")
    out = render("# Heading colours", 40)
    assert_true(table.concat(out):find("\27[36;1m", 1, true) ~= nil,
        "T32 heading takes the heading role")
    ui._color_depth = "none"
end)

-- M11/T54: word wrap on display width + code soft-wrap (readability)
with_modules(base_env, function(mods)
    local ui = mods.ui
    -- force SGR-free rendering so md_render output is plain-text deterministic
    ui._color_depth = "none"
    ui.set_wrap(true)

    -- prose breaks on spaces, never mid-word
    local wl = ui.wrap_lines("aa bb cc dd", 5)
    assert_eq(#wl, 2, "T54 greedy packs to two lines")
    assert_eq(wl[1], "aa bb", "T54 first line")
    assert_eq(wl[2], "cc dd", "T54 second line")

    -- overlong token without spaces is cut hard, nothing lost
    wl = ui.wrap_lines("abcdefghij", 4)
    assert_eq(#wl, 3, "T54 overlong token cut")
    assert_eq(table.concat(wl, ""), "abcdefghij", "T54 hard cut loses nothing")

    -- every line fits the width; join restores the source
    local src = "lorem ipsum dolor sit amet consectetur"
    wl = ui.wrap_lines(src, 12)
    for _, l in ipairs(wl) do
        assert_true(ui.vlen(l) <= 12, "T54 width respected")
    end
    assert_eq(table.concat(wl, " "), src, "T54 join restores source")

    -- leading indentation survives on the first line
    wl = ui.wrap_lines("  indented line here", 12)
    assert_eq(wl[1], "  indented", "T54 indent kept")

    -- CJK counts 2 columns per character
    wl = ui.wrap_lines("中文测试换行", 5)
    assert_eq(#wl, 3, "T54 CJK wraps by display width")
    for _, l in ipairs(wl) do
        assert_true(ui.vlen(l) <= 5, "T54 CJK width respected")
    end

    -- SGR sequences are zero-width and preserved
    wl = ui.wrap_lines("\27[36;1mhello world\27[0m", 10)
    assert_true(ui.vlen(wl[1]) <= 10 and ui.vlen(wl[2]) <= 10, "T54 SGR zero width")
    assert_eq((table.concat(wl, " "):gsub("\27%[[0-9;]*m", "")), "hello world", "T54 SGR content kept")

    -- code block soft-wraps inside the frame: no cut marker, content kept
    local out = ui.md_render("```lua\nlocal very_long_variable_name = some_function_call(arg1, arg2)\n```", 30)
    assert_true(#out > 4, "T54 code block grows rows: " .. #out)
    local joined = table.concat(out, "\n")
    assert_true(joined:find("→", 1, true) == nil, "T54 no cut marker")
    assert_true(joined:find("very_long_variable_name", 1, true) ~= nil, "T54 code content kept")
    assert_true(joined:find("some_function_call", 1, true) ~= nil, "T54 code tail kept")
    for _, l in ipairs(out) do
        assert_true(ui.vlen(l) <= 30, "T54 frame rows fit width")
    end

    -- list continuation aligns to content start (2-column prefix now)
    out = ui.md_render("- lorem ipsum dolor sit amet", 20)
    assert_eq(#out, 2, "T54 list wraps to two rows")
    assert_eq(out[2]:sub(1, 2), "  ", "T54 continuation indent")

    -- wrap=false still truncates to one line
    ui.set_wrap(false)
    wl = ui.wrap_lines("hello world this is long", 10)
    assert_eq(#wl, 1, "T54 wrap=false one line")
    ui.set_wrap(true)
end)

-- M8/T33: digit-map for confirmation menu (R3)
with_modules(base_env, function(mods)
    local dm = mods.ui.CONFIRM_DIGITS
    assert_notnil(dm, "T33 CONFIRM_DIGITS exported")
    assert_eq(dm[1], "allow", "T33 1=allow")
    assert_eq(dm[2], "session", "T33 2=session")
    assert_eq(dm[3], "always", "T33 3=always")
    -- palette-only T2: details removed — 5 options, deny/cancel shift left
    assert_eq(dm[4], "deny", "T33 4=deny")
    assert_eq(dm[5], "cancel", "T33 5=cancel")
    assert_eq(dm[6], nil, "T33 no 6th option (details gone)")
    assert_eq(#dm, 5, "T33 five confirmation options")
end)

-- M8/T34: scroll indicator math (R3)
with_modules(base_env, function(mods)
    local calc = mods.ui.scroll_indicator
    assert_notnil(calc, "T34 scroll_indicator exported")
    -- (total_lines, scroll, visible_h) -> nil when following, else N hidden below
    assert_eq(calc(50, 0, 20), nil, "T34 following -> nil")
    local n = calc(50, 10, 20)
    -- bottom = 50-10=40; visible rows 21..40; below = 50-40 = 10
    assert_eq(n, 10, "T34 hidden-below count")
end)


if failed > 0 then
    os.exit(1)
end
