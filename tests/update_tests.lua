-- tests/update_tests.lua — add-self-update: the release probe, its cache,
-- the banner row, and the `tether update` verb.
-- Run: lua tests/update_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

local orig_tether = _G.tether
local orig_update = _G.update
local orig_build = _G.build_version

local function fresh_update()
    _G.update = nil
    return assert(loadfile("src/tether/update.lua"))()
end

local function tmp_home()
    local p = os.tmpname()
    os.remove(p)
    assert(host_fs.mkdirp(p .. "/.tether"))
    return p
end

local function rm_tree(p)
    os.execute("rm -rf " .. p)
end

local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function cache_of(home) return home .. "/.tether/update.json" end
local function marker_of(home) return cache_of(home) .. ".pending" end

local function put_record(home, sha, checked_at)
    write_file(cache_of(home),
        '{"sha":"' .. sha .. '","checked_at":' .. tostring(checked_at) .. "}")
end

local function record_sha(home)
    local body = read_file(cache_of(home)) or ""
    return body:match('"sha"%s*:%s*"(%x+)"')
end

local function record_age(home)
    local body = read_file(cache_of(home)) or ""
    return tonumber(body:match('"checked_at"%s*:%s*(%d+)'))
end

-- ---------------------------------------------------------------
-- T293: update_check normalises like metadata_refresh — anything that is
-- not a boolean means "enabled", never a failed load.
do
    local config = assert(loadfile("src/tether/config.lua"))()
    local home = tmp_home()
    assert_eq(config.load(home .. "/.tether/nope.lua", home).update_check,
        true, "T293 absent update_check defaults on")
    write_file(home .. "/.tether/config.lua", 'return { update_check = true }\n')
    assert_eq(config.load(home .. "/.tether/config.lua", home).update_check,
        true, "T293 explicit true stays on")
    write_file(home .. "/.tether/config.lua", 'return { update_check = false }\n')
    assert_eq(config.load(home .. "/.tether/config.lua", home).update_check,
        false, "T293 explicit false opts out")
    write_file(home .. "/.tether/config.lua",
        'return { update_check = "yes" }\n')
    local cfg = config.load(home .. "/.tether/config.lua", home)
    assert_eq(cfg.update_check, true, "T293 non-boolean falls back to on")
    assert_notnil(cfg.ui, "T293 the bad value does not fail the load")
    rm_tree(home)
    print("T293 update_check configuration: OK")
end

-- ---------------------------------------------------------------
-- T294: the first-run bootstrap documents the key, and an existing
-- hand-edited config is never rewritten.
do
    local config = assert(loadfile("src/tether/config.lua"))()
    local home = tmp_home()
    local cfgpath = home .. "/.tether/config.lua"
    config.load(cfgpath, home)
    local boot = read_file(cfgpath)
    assert_notnil(boot, "T294 bootstrap config written on first load")
    assert_true(boot:find("update_check = true", 1, true) ~= nil,
        "T294 bootstrap carries the key")
    assert_true(boot:find("release probe", 1, true) ~= nil,
        "T294 bootstrap documents the key")

    local hand = 'return { model = "keep-me" }\n'
    write_file(cfgpath, hand)
    config.load(cfgpath, home)
    assert_eq(read_file(cfgpath), hand, "T294 a hand-edited config survives")
    rm_tree(home)
    print("T294 bootstrap carries update_check: OK")
end

-- ---------------------------------------------------------------
-- T295: the probe body is read strictly — one hex token or no release.
do
    local upd = fresh_update()
    assert_eq(upd.parse_version("abc1234\n"), "abc1234",
        "T295 a padded sha is accepted")
    assert_eq(upd.parse_version("  ABC1234 "), "abc1234",
        "T295 upper-case sha is normalised")
    assert_eq(upd.parse_version("<!DOCTYPE html>\n<html>404</html>"), nil,
        "T295 an html page is not a release")
    assert_eq(upd.parse_version(""), nil, "T295 empty body rejected")
    assert_eq(upd.parse_version("abc1234 and trailing junk"), nil,
        "T295 trailing junk rejected")
    assert_eq(upd.parse_version("tether-abc123"), nil,
        "T295 the release tag is not a sha")
    assert_eq(upd.parse_version("abc12"), nil, "T295 too short rejected")
    assert_eq(upd.parse_version("FETCH_FAILED timeout"), nil,
        "T295 failure marker is not a release")
    local _, why = upd.parse_version("FETCH_FAILED timeout")
    assert_eq(why, "timeout", "T295 failure reason surfaces")
    print("T295 strict version parse: OK")
end

-- ---------------------------------------------------------------
-- T296/T297: the cache record round-trips; corrupt content is absent, not
-- an error.
do
    local upd = fresh_update()
    local home = tmp_home()
    put_record(home, "dead001", os.time())
    assert_eq(record_sha(home), "dead001", "T296 fixture written")
    assert_eq(upd.notice({ update_check = true }, home, "aaaaaaa"),
        "update available: tether dead001  (run: tether update)",
        "T296 record round-trips into the notice")

    -- T297: a truncated json body must not raise anywhere.
    write_file(cache_of(home), '{"sha": "dead001", "check')
    local ok, res = pcall(upd.notice, { update_check = true }, home, "aaaaaaa")
    assert_true(ok, "T297 truncated cache does not raise")
    assert_eq(res, nil, "T297 truncated cache shows no notice")
    local ok2, st = pcall(upd.check, { update_check = false }, home)
    assert_true(ok2 and st == "off", "T297 truncated cache still checks")

    write_file(cache_of(home), "not json at all")
    assert_eq(upd.notice({ update_check = true }, home, "aaaaaaa"), nil,
        "T297 non-json cache shows no notice")
    rm_tree(home)
    print("T296/T297 cache record read and write: OK")
end

-- ---------------------------------------------------------------
-- T298–T301: check() — fresh cache never reaches the network, an expired
-- one schedules exactly one detached probe, a landed marker folds into the
-- cache, and a dead child's marker is dropped and retried.
do
    local upd = fresh_update()
    local home = tmp_home()
    local spawns, urls = 0, nil
    _G.tether = host_mock({
        fetch_bg = function(url, headers, pend, timeout)
            spawns = spawns + 1
            urls = url
            assert_eq(type(headers), "table", "T298 headers table passed")
            assert_eq(timeout, upd.PROBE_TIMEOUT_S, "T298 probe timeout passed")
            assert_true(tostring(pend):find("update.json.pending", 1, true) ~= nil,
                "T298 the marker is the output path: " .. tostring(pend))
            return true
        end,
        http_get = function() error("T298 startup must never fetch in sync") end,
    })

    -- T298 fresh cache: no network at all.
    put_record(home, "dead001", os.time())
    local st, sha = upd.check({ update_check = true }, home)
    assert_eq(st, "fresh", "T298 fresh cache status")
    assert_eq(sha, "dead001", "T298 fresh cache serves the sha")
    assert_eq(spawns, 0, "T298 fresh cache issues no fetch")

    -- opt-out silences the whole path.
    assert_eq(upd.check({ update_check = false }, home), "off",
        "T298 opt-out returns off")
    assert_eq(spawns, 0, "T298 opt-out issues no fetch")

    -- T299 expired cache: one background probe, never duplicated.
    put_record(home, "dead001", os.time() - 25 * 3600)
    st, sha = upd.check({ update_check = true }, home)
    assert_eq(st, "background", "T299 expired cache schedules a probe")
    assert_eq(sha, "dead001", "T299 the old sha still serves meanwhile")
    assert_eq(spawns, 1, "T299 one probe spawned")
    assert_true(urls:find("/releases/latest/download/VERSION", 1, true) ~= nil,
        "T299 probe url is the VERSION asset: " .. tostring(urls))
    local st2 = upd.check({ update_check = true }, home)
    assert_eq(st2, "waiting", "T299 in-flight probe is not repeated")
    assert_eq(spawns, 1, "T299 still one probe spawned")

    -- T300 the child lands a release: folded into the cache, marker gone.
    write_file(marker_of(home), "cafe123\n")
    assert_eq(upd.consume(home), "updated", "T300 landed probe consumed")
    assert_eq(read_file(marker_of(home)), nil, "T300 marker removed")
    assert_eq(record_sha(home), "cafe123", "T300 cache holds the new sha")
    assert_true(record_age(home) >= os.time() - 5, "T300 cache stamp is now")

    -- ...and a landed failure keeps the previous sha, cooling the retry down.
    write_file(marker_of(home), "FETCH_FAILED could not connect\n")
    assert_eq(upd.consume(home), "failed", "T300 failed probe consumed")
    assert_eq(read_file(marker_of(home)), nil, "T300 failure marker removed")
    assert_eq(record_sha(home), "cafe123", "T300 failure keeps the sha")
    assert_true(record_age(home) >= os.time() - 5, "T300 failure stamps checked_at")
    assert_eq(upd.check({ update_check = true }, home), "fresh",
        "T300 failure cools the next start down")
    assert_eq(spawns, 1, "T300 no probe spawned by the cooled-down check")

    -- T301 an empty marker is one child still running, then a dead one.
    rm_tree(home)
    local home2 = tmp_home()
    put_record(home2, "dead001", os.time() - 25 * 3600)
    write_file(marker_of(home2), "")
    spawns = 0
    assert_eq(upd.check({ update_check = true }, home2), "waiting",
        "T301 young empty marker waits")
    assert_eq(spawns, 0, "T301 waiting start spawns nothing")
    assert_notnil(read_file(marker_of(home2)), "T301 the marker is left alone")
    -- backdate it past the stale window: the child died, drop and retry.
    os.execute("touch -d @" .. (os.time() - upd.STALE_MARKER_S - 60) .. " "
        .. marker_of(home2))
    assert_eq(upd.check({ update_check = true }, home2), "background",
        "T301 stale marker retries the probe")
    assert_eq(spawns, 1, "T301 stale marker spawns once")
    rm_tree(home)
    rm_tree(home2)
    _G.tether = orig_tether
    print("T298-T301 background probe lifecycle: OK")
end

-- ---------------------------------------------------------------
-- T302/T303: notice() decides from disk only, and the sha-inequality rule
-- stays documented where it lives.
do
    local upd = fresh_update()
    local home = tmp_home()
    local cfg = { update_check = true }
    assert_eq(upd.notice(cfg, home, "aaaaaaa"), nil,
        "T302 no cache means no notice")

    put_record(home, "aaaaaaa", os.time())
    assert_eq(upd.notice(cfg, home, "aaaaaaa"), nil,
        "T302 same sha means no notice")

    put_record(home, "dead001", os.time())
    local text = upd.notice(cfg, home, "aaaaaaa")
    assert_notnil(text, "T302 differing sha notices")
    assert_true(text:find("dead001", 1, true) ~= nil,
        "T302 notice names the release verbatim")
    assert_true(text:find("tether update", 1, true) ~= nil,
        "T302 notice tells the command to run")
    assert_eq(text:find("newer"), nil,
        "T302 notice never claims an ordering")

    assert_eq(upd.notice({ update_check = false }, home, "aaaaaaa"), nil,
        "T302 opt-out silences the notice")
    put_record(home, "dead001", os.time() - 25 * 3600)
    assert_eq(upd.notice(cfg, home, "aaaaaaa"), nil,
        "T302 an expired cache never notices")
    assert_eq(upd.notice(cfg, home, nil), nil,
        "T302 no build version means no notice")

    local src = read_file("src/tether/update.lua") or ""
    assert_true(src:find("ponytail:", 1, true) ~= nil,
        "T303 the inequality shortcut is marked")
    assert_true(src:find("no ordering", 1, true) ~= nil,
        "T303 the inequality shortcut explains itself")
    rm_tree(home)
    print("T302/T303 notice rules: OK")
end

-- ---------------------------------------------------------------
-- T304: the startup hook never runs for a one-shot or piped run, and never raises.
do
    local upd = fresh_update()
    _G.update = upd
    local app = assert(loadfile("src/tether/app.lua"))()
    local home = tmp_home()
    put_record(home, "dead001", os.time() - 25 * 3600)
    local spawns = 0
    _G.tether = host_mock({ fetch_bg = function()
        spawns = spawns + 1
        return true
    end })
    assert_eq(app._startup_update({ update_check = true },
        { print_mode = true }, home), nil, "T304 print mode gets no status")
    assert_eq(spawns, 0, "T304 print mode schedules nothing")
    assert_eq(app._startup_update({ update_check = true }, {}, home),
        "background", "T304 interactive start schedules the probe")
    assert_eq(spawns, 1, "T304 interactive start spawns one probe")
    -- a piped stdin is a one-shot run without the flag: same silence, and no
    -- marker left behind for a user who never sees a banner. A fresh home,
    -- because the probe above already parked a marker in this one and a marker
    -- is itself a reason to schedule nothing.
    local home2 = tmp_home()
    put_record(home2, "dead001", os.time() - 25 * 3600)
    _G.tether = host_mock({ is_tty = function() return false end,
        fetch_bg = function() spawns = spawns + 1 return true end })
    assert_eq(app._startup_update({ update_check = true }, {}, home2), nil,
        "T304 a piped start gets no status")
    assert_eq(spawns, 1, "T304 a piped start schedules nothing")
    assert_eq(read_file(marker_of(home2)), nil,
        "T304 a piped start leaves no marker")
    _G.tether = host_mock({ is_tty = function() return true end,
        fetch_bg = function() spawns = spawns + 1 return true end })
    assert_eq(app._startup_update({ update_check = true }, {}, home2),
        "background", "T304 a tty start schedules the probe")
    assert_eq(spawns, 2, "T304 the tty start spawned one probe")
    rm_tree(home2)
    _G.tether = host_mock({ fetch_bg = function()
        spawns = spawns + 1
        return true
    end })
    -- a raising module must not take the session down with it
    _G.update = { check = function() error("boom") end }
    assert_eq(app._startup_update({ update_check = true }, {}, home), nil,
        "T304 a raising check is swallowed")
    _G.update = upd
    rm_tree(home)
    _G.tether = orig_tether
    print("T304 startup hook: OK")
end

-- ---------------------------------------------------------------
-- T305/T306: the notice seeds right below the splash, once, and fits.
do
    local seen = {}
    local NOTICE = "update available: tether dead001  (run: tether update)"
    _G.build_version = "aaaaaaa"
    local function stub_update(ret)
        _G.update = {
            notice = function(cfg, home, current)
                seen.cfg = cfg
                seen.current = current
                return ret
            end,
        }
    end

    stub_update(NOTICE)
    local uimod, S = run_ui_with({ 17 }, {})
    local entries = tentries(uimod)
    assert_eq(entries[1] and entries[1].role, "splash",
        "T305 the splash is still the first row")
    assert_eq(entries[2] and entries[2].role, "system",
        "T305 the notice is a system row")
    assert_eq(entries[2] and entries[2].text, NOTICE,
        "T305 the notice text is what the module returned")
    assert_eq(#entries, 2, "T305 nothing else is seeded")
    assert_eq(seen.current, "aaaaaaa", "T305 ui passes the running build version")
    assert_true(seen.cfg ~= nil, "T305 ui passes the config")
    assert_eq(S.w, 80, "T305 default width seeded the state")

    -- up to date: the module says nothing, so the transcript shows nothing.
    stub_update(nil)
    local ui2 = run_ui_with({ 17 }, {})
    local e2 = tentries(ui2)
    assert_eq(#e2, 1, "T305 an up-to-date build seeds only the splash")
    assert_eq(e2[1].role, "splash", "T305 the splash is still first")

    -- T306 narrow + mono + ascii: the notice rows stay inside the width.
    -- Only the rows the notice adds are measured — the splash's own version
    -- line is a fixed-format row that predates this change.
    stub_update(nil)
    local ui0 = run_ui_with({ 17 }, { size = { width = 8, height = 24 } })
    local bare = ui0._render_all(8)
    stub_update(NOTICE)
    local ui3 = run_ui_with({ 17 }, { size = { width = 8, height = 24 } })
    local rows = ui3._render_all(8)
    assert_true(#rows > #bare, "T306 the notice wraps into extra rows at width 8 ("
        .. #rows .. " vs " .. #bare .. ")")
    for i = 1, #bare do
        assert_eq(ui3._strip_sgr(rows[i]), ui3._strip_sgr(bare[i]),
            "T306 the splash block is untouched above the notice")
    end
    local longest = 0
    for i = #bare + 1, #rows do
        local w = ui3.vlen(ui3._strip_sgr(rows[i]))
        if w > longest then longest = w end
    end
    assert_true(longest <= 8, "T306 no notice row exceeds the width ("
        .. longest .. ")")

    local function at(width, cfg_ui, before)
        local function conf()
            return { model = "test", workspace = "/tmp",
                ui = cfg_ui or { input_max_lines = 8 } }
        end
        local u = run_ui_with({ 17 }, { size = { width = width, height = 24 },
            config = { load = conf, api_key = function() return "" end } })
        if before then before(u) end
        local r = u._render_all(width)
        local n, over = 0, 0
        for i = #bare + 1, #r do
            local w = u.vlen(u._strip_sgr(r[i]))
            n = n + 1
            if w > width then over = over + 1 end
        end
        return n, over
    end
    local mono_n, mono_over = at(8, nil, function(u) u.set_theme("mono") end)
    assert_true(mono_n > 0, "T306 mono still renders the notice")
    assert_eq(mono_over, 0, "T306 mono notice rows fit the width")
    local ascii_n, ascii_over = at(8, { input_max_lines = 8, ascii = "on" })
    assert_true(ascii_n > 0, "T306 ascii mode still renders the notice")
    assert_eq(ascii_over, 0, "T306 ascii notice rows fit the width")
    local wide_n = at(40)
    assert_true(wide_n >= 1, "T306 the notice renders on a wide terminal too")

    -- a module that raises must cost the session nothing.
    _G.update = { notice = function() error("boom") end }
    local ui4 = run_ui_with({ 17 }, {})
    assert_eq(#tentries(ui4), 1, "T305 a raising notice module shows only splash")
    print("T305/T306 notice seeding and width: OK")
end

-- ---------------------------------------------------------------
-- T313: the notice is a startup row — ordered right after the splash when a
-- resumed session seeds ahead of it, and gone for good once the transcript is
-- reset inside the session (spec: "at most once per session").
do
    local NOTICE = "update available: tether dead001  (run: tether update)"
    _G.build_version = "aaaaaaa"
    _G.update = { notice = function() return NOTICE end }

    -- resumed history: splash, notice, then the restored messages, then the
    -- resume marker. The insert walks the rows in reverse into position 1, so
    -- the order here is what that loop produces.
    local hist = { { role = "user", content = "one" },
                  { role = "assistant", content = "two" } }
    local uim = run_ui_with({ 17 }, { agent = {
        get_history = function() return hist end,
        turn = function() return true end } })
    local e = tentries(uim)
    assert_eq(e[1] and e[1].role, "splash",
        "T313 the splash leads a resumed transcript")
    assert_eq(e[2] and e[2].text, NOTICE,
        "T313 the notice follows the splash, ahead of the history")
    assert_eq(e[3] and e[3].role, "user",
        "T313 the restored messages keep their order after the notice")
    assert_eq(e[4] and e[4].role, "assistant", "T313 both history rows seeded")
    assert_true(tostring(e[#e].text):find("session resumed", 1, true) ~= nil,
        "T313 the resume marker still closes the transcript")

    -- inside the session a reset re-seeds the splash only, so the notice
    -- cannot be shown twice by clearing or starting over.
    local function str_bytes(s)
        local b = {}
        for i = 1, #s do b[#b + 1] = s:byte(i) end
        return b
    end
    local bytes = str_bytes("/clear")
    bytes[#bytes + 1] = 13
    bytes[#bytes + 1] = 17
    local uic = run_ui_with(bytes, { agent = {
        get_history = function() return nil end,
        turn = function() return true end } })
    local ce = tentries(uic)
    assert_eq(#ce, 1, "T313 /clear leaves only the splash")
    assert_eq(ce[1] and ce[1].role, "splash", "T313 the splash survives /clear")
    print("T313 notice lifetime: OK")
end
_G.update = orig_update
_G.build_version = orig_build

-- ---------------------------------------------------------------
-- T307: the verb is dispatched before flag parsing, through the seam.
do
    local app = assert(loadfile("src/tether/app.lua"))()
    local got = {}
    _G.build_version = "aaaaaaa"
    _G.update = { run = function(home, current)
        got.home = home
        got.current = current
        return 0, "tether is already up to date (aaaaaaa)"
    end }
    local code, text = app._update_verb("/tmp/somehome")
    assert_eq(code, 0, "T307 the verb returns the module code")
    assert_true(tostring(text):find("up to date", 1, true) ~= nil,
        "T307 the verb returns the module message")
    assert_eq(got.home, "/tmp/somehome", "T307 the home is forwarded")
    assert_eq(got.current, "aaaaaaa", "T307 the build version is forwarded")

    _G.update = nil
    local code2, text2 = app._update_verb("/tmp/somehome")
    assert_eq(code2, 1, "T307 a missing module exits non-zero")
    assert_true(tostring(text2):find("unavailable", 1, true) ~= nil,
        "T307 a missing module explains itself")

    -- the dispatch point: before parse_args, or the verb opens a session.
    local src = read_file("src/tether/app.lua") or ""
    local verb_at = src:find('argv[1] == "update"', 1, true)
    local parse_at = src:find("local opts = parse_args()", 1, true)
    assert_true(verb_at ~= nil and parse_at ~= nil and verb_at < parse_at,
        "T307 update is trimmed before the flag parser")
    _G.update = orig_update
    _G.build_version = orig_build
    print("T307 update verb dispatch: OK")
end

-- ---------------------------------------------------------------
-- T308–T312: `tether update` — probe, verify, swap, refuse.
local function exe_tree()
    local dir = os.tmpname()
    os.remove(dir)
    assert(host_fs.mkdirp(dir .. "/bin"))
    local exe = dir .. "/bin/tether"
    write_file(exe, "old build")
    os.execute("chmod 0755 " .. exe)
    return dir, exe
end

local ELF = "\127ELF" .. string.rep("\n\x00built", 2000)

do
    local upd = fresh_update()
    upd.MIN_BINARY_BYTES = 16

    -- T308: up to date, probe failure, and the download path.
    local dir, exe = exe_tree()
    local home = tmp_home()
    local before = read_file(exe)
    local calls = 0
    _G.tether = host_mock({
        exepath = function() return exe end,
        http_get = function(url)
            calls = calls + 1
            if url:find("VERSION", 1, true) then return "aaaaaaa\n" end
            return ELF
        end,
    })
    local code, text = upd.run(home, "aaaaaaa")
    assert_eq(code, 0, "T308 up to date exits zero")
    assert_true(tostring(text):find("up to date", 1, true) ~= nil,
        "T308 up to date says so")
    assert_eq(calls, 1, "T308 up to date downloads nothing")
    assert_eq(read_file(exe), before, "T308 up to date leaves the binary alone")

    calls = 0
    _G.tether.http_get = function(url)
        calls = calls + 1
        if url:find("VERSION", 1, true) then return nil, "http 404" end
        error("must not download after a failed probe")
    end
    local c2, t2 = upd.run(home, "aaaaaaa")
    assert_eq(c2, 1, "T308 probe failure exits non-zero")
    assert_true(tostring(t2):find("http 404", 1, true) ~= nil,
        "T308 probe failure surfaces the reason: " .. tostring(t2))
    assert_eq(calls, 1, "T308 probe failure downloads nothing")
    assert_eq(read_file(exe), before, "T308 probe failure changes nothing")

    -- T309: a differing release is downloaded, verified, renamed into place.
    calls = 0
    _G.tether.http_get = function(url)
        calls = calls + 1
        if url:find("VERSION", 1, true) then return "dead001\n" end
        assert_true(url:find("/releases/download/tether-dead001/", 1, true) ~= nil,
            "T309 binary url is built from the probed sha: " .. url)
        return ELF
    end
    local c3, t3 = upd.run(home, "aaaaaaa")
    assert_eq(c3, 0, "T309 the swap succeeds: " .. tostring(t3))
    assert_eq(calls, 2, "T309 probe then download")
    assert_true(read_file(exe) == ELF, "T309 the executable holds the new build")
    assert_eq(read_file(dir .. "/bin/tether.update.tmp"), nil,
        "T309 no temp file is left behind")
    local mp = io.popen("LC_ALL=C stat -c '%a' " .. exe .. " 2>/dev/null")
    local mode = (mp and mp:read("*a") or "?"):gsub("%s", "")
    if mp then mp:close() end
    assert_eq(mode, "755", "T309 the new executable is 0755, got " .. mode)
    assert_true(tostring(t3):find("dead001", 1, true) ~= nil,
        "T309 the message reports the installed sha")
    assert_true(tostring(t3):find("restart", 1, true) ~= nil,
        "T309 the message says a restart is needed")
    -- the cache is folded to the installed sha, so no banner downgrades next start
    assert_eq(record_sha(home), "dead001", "T309 the cache records the install")
    assert_eq(upd.notice({ update_check = true }, home, "dead001"), nil,
        "T309 the freshly installed build is not offered an update")
    rm_tree(home)
    os.execute("rm -rf " .. dir)

    -- T310: a rejected download leaves the target byte-identical.
    for _, bad in ipairs({ "", "plain text, not an executable",
                           "\127ELF tiny" }) do
        local d2, e2 = exe_tree()
        local keep = read_file(e2)
        local h2 = tmp_home()
        _G.tether = host_mock({
            exepath = function() return e2 end,
            http_get = function(url)
                if url:find("VERSION", 1, true) then return "dead001\n" end
                return bad
            end,
        })
        local c4, t4 = upd.run(h2, "aaaaaaa")
        assert_eq(c4, 1, "T310 a bad payload exits non-zero: " .. bad)
        assert_eq(read_file(e2), keep, "T310 the target is untouched")
        assert_eq(read_file(d2 .. "/bin/tether.update.tmp"), nil,
            "T310 no temp file is left behind")
        assert_true(tostring(t4):find("refused", 1, true) ~= nil
            or tostring(t4):find("empty", 1, true) ~= nil,
            "T310 the refusal is explained: " .. tostring(t4))
        assert_eq(record_sha(h2), nil, "T310 a refused install records nothing")
        rm_tree(h2)
        os.execute("rm -rf " .. d2)
    end

    -- T312: an unresolvable executable is refused, never guessed.
    local h3 = tmp_home()
    _G.tether = host_mock({
        exepath = function() return nil end,
        http_get = function() return "dead001\n" end,
    })
    local c5, t5 = upd.run(h3, "aaaaaaa")
    assert_eq(c5, 1, "T312 no exepath exits non-zero")
    assert_true(tostring(t5):find("executable", 1, true) ~= nil,
        "T312 no exepath explains itself: " .. tostring(t5))
    -- a dev build carries no release identity to compare against
    _G.tether = host_mock({
        exepath = function() return "/tmp/somewhere/tether" end,
        http_get = function() return "dead001\n" end,
    })
    local c6, t6 = upd.run(h3, "dev")
    assert_eq(c6, 1, "T312 a dev build is refused")
    assert_true(tostring(t6):find("rebuild", 1, true) ~= nil,
        "T312 the refusal says how to proceed: " .. tostring(t6))
    rm_tree(h3)

    -- T311: an unwritable install directory names the path and changes
    -- nothing. (Skipped for root, which mode bits cannot deny.)
    local is_root = false
    local probe = io.popen("id -u 2>/dev/null")
    if probe then
        is_root = (probe:read("*a"):gsub("%s", "") == "0")
        probe:close()
    end
    if is_root then
        print("T311 unwritable directory: skipped (running as root)")
    else
        local h4 = tmp_home()
        local d4, e4 = exe_tree()
        local bin = d4 .. "/bin"
        local keep = read_file(e4)
        os.execute("chmod 0555 " .. bin)
        _G.tether = host_mock({
            exepath = function() return e4 end,
            http_get = function(url)
                if url:find("VERSION", 1, true) then return "dead001\n" end
                return ELF
            end,
        })
        local c7, t7 = upd.run(h4, "aaaaaaa")
        assert_eq(c7, 1, "T311 an unwritable directory exits non-zero")
        assert_eq(read_file(e4), keep, "T311 the target is untouched")
        assert_true(tostring(t7):find(bin, 1, true) ~= nil,
            "T311 the message names the path: " .. tostring(t7))
        assert_true(tostring(t7):find("sudo", 1, true) ~= nil
            or tostring(t7):find("make install", 1, true) ~= nil,
            "T311 the message gives a way forward")
        os.execute("chmod 0755 " .. bin)
        os.execute("rm -rf " .. d4)
        rm_tree(h4)
    end

    _G.tether = orig_tether
    print("T308-T312 tether update: OK")
end

-- ---------------------------------------------------------------
-- T314: `update_check = false` silences the startup probe and the banner, not
-- the verb — opting out of checking must not opt out of updating.
do
    local upd = fresh_update()
    upd.MIN_BINARY_BYTES = 16
    _G.update = upd
    local app = assert(loadfile("src/tether/app.lua"))()
    local dir, exe = exe_tree()
    local home = tmp_home()
    write_file(home .. "/.tether/config.lua", "return { update_check = false }\n")
    _G.build_version = "aaaaaaa"
    _G.tether = host_mock({
        exepath = function() return exe end,
        http_get = function(url)
            if url:find("VERSION", 1, true) then return "dead001\n" end
            return ELF
        end,
    })
    assert_eq(upd.notice({ update_check = false }, home, "aaaaaaa"), nil,
        "T314 the opt-out still silences the banner")
    local code, text = app._update_verb(home)
    assert_eq(code, 0, "T314 the verb runs with the check off: " .. tostring(text))
    assert_true(read_file(exe) == ELF, "T314 the swap happened with the check off")
    rm_tree(home)
    os.execute("rm -rf " .. dir)
    _G.tether = orig_tether
    _G.update = orig_update
    _G.build_version = orig_build
    print("T314 tether update ignores update_check: OK")
end

-- ---------------------------------------------------------------
-- T315: the release URLs are the published asset names — pinned verbatim so a
-- rename in .github/workflows/build.yml fails a test instead of users.
do
    local upd = fresh_update()
    local base = upd.base_url()
    assert_eq(upd.version_url(), base .. "/releases/latest/download/VERSION",
        "T315 the probe url names the VERSION asset")
    assert_eq(upd.binary_url("dead001"), base
        .. "/releases/download/tether-dead001/tether-dead001-linux-x86_64",
        "T315 the install url names the bare-binary asset")
    -- the probed sha is hex-checked before it can reach a URL: nothing else may
    -- steer the updater to a host or path of its own.
    assert_eq(upd.binary_url("dead001/../x"), nil, "T315 a non-hex sha is refused")
    assert_eq(upd.binary_url(""), nil, "T315 an empty sha is refused")
    assert_eq(upd.binary_url(7), nil, "T315 a non-string sha is refused")
    print("T315 release url contract: OK")
end

_G.tether = orig_tether
_G.update = orig_update
_G.build_version = orig_build

if failed > 0 then
    os.exit(1)
end
