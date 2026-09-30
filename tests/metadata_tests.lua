-- tests/metadata_tests.lua — lazy per-provider metadata (offline-provider-catalog).
-- Run: lua tests/metadata_tests.lua

dofile("tests/helpers.lua")

local orig_tether = _G.tether
local orig_meta = _G.metadata

local function fresh_metadata()
    _G.metadata = nil
    return assert(loadfile("src/tether/metadata.lua"))()
end

local function tmp_home()
    local p = os.tmpname()
    os.remove(p)
    assert(os.execute("mkdir -p " .. p .. "/.tether"))
    return p
end

local function rm_home(p)
    os.execute("rm -rf " .. p)
end

local SHARD = '{"schema":1,"generated_at":777,"id":"deepseek",'
    .. '"models":[{"id":"deepseek-chat","context":128000},'
    .. '{"id":"mystery","context":"lots"},'
    .. '{"id":"plain"}]}'

local function write_entry(home, provider, checked_at, body)
    local common = assert(loadfile("src/tether/providers/common.lua"))()
    local path = home .. "/.tether/metadata_cache.json"
    local cache = {}
    local f = io.open(path, "r")
    if f then
        local ok, tbl = pcall(common.json_decode, f:read("*a") or "")
        f:close()
        if ok and type(tbl) == "table" then cache = tbl end
    end
    local models = nil
    if body then
        local md = fresh_metadata()
        local m, err = md.parse_shard(body, provider)
        assert(m ~= nil, "fixture shard parses (" .. tostring(err) .. ")")
        models = m
    end
    cache[provider] = { checked_at = checked_at, models = models or {} }
    local w = assert(io.open(path, "w"))
    w:write(common.json_encode(cache))
    w:close()
end

do
    local md = fresh_metadata()
    local u = md.shard_url("deepseek")
    assert_true(u ~= nil and u:sub(-24) == "/providers/deepseek.json",
        "META shard url derives from catalog url (" .. tostring(u) .. ")")
    assert_true(md.shard_url("../evil") == nil, "META bad id rejected")
    assert_true(md.shard_url("UPPER") == nil, "META non-kebab id rejected")
    local cu = md.shard_url("x", "https://mirror.example/p.json")
    assert_eq(cu, "https://mirror.example/providers/x.json",
        "META custom mirror convention")
    print("META shard_url: OK")
end

do
    local md = fresh_metadata()
    local models, err = md.parse_shard(SHARD, "deepseek")
    assert_true(models ~= nil, "META valid shard parses ("
        .. tostring(err) .. ")")
    assert_eq(#models, 3, "META all ids kept")
    assert_eq(models[1].context, 128000, "META numeric context kept")
    assert_eq(models[2].context, nil, "META non-numeric context dropped")
    assert_eq(models[3].context, nil, "META missing context is nil")
    assert_eq(md.parse_shard("FETCH_FAILED timeout", "deepseek"), nil,
        "META fetch failure rejected")
    assert_eq(md.parse_shard('{"schema":99,"id":"deepseek","models":[]}',
        "deepseek"), nil, "META bad schema rejected")
    assert_eq(md.parse_shard(
        '{"schema":1,"id":"other","models":[]}', "deepseek"), nil,
        "META id mismatch rejected")
    assert_eq(md.parse_shard("garbage", "deepseek"), nil,
        "META garbage rejected")
    print("META parse_shard: OK")
end

do
    -- fresh cache serves with zero network.
    local md = fresh_metadata()
    local home = tmp_home()
    write_entry(home, "deepseek", os.time(), SHARD)
    local calls = 0
    _G.tether = host_mock({ http_get = function()
        calls = calls + 1
        return nil, "must not be called"
    end })
    local models, st = md.models("deepseek", home)
    assert_eq(st, "fresh", "META fresh status")
    assert_eq(#models, 3, "META fresh models served")
    assert_eq(calls, 0, "META fresh issues no HTTP")
    assert_eq(#md.cached("deepseek", home), 3, "META cached reads disk")
    assert_eq(md.cached("nope", home), nil, "META cached miss is nil")
    _G.tether = orig_tether
    rm_home(home)
    print("META fresh instant: OK")
end

do
    -- stale cache refreshes once in the background, no duplicates.
    local md = fresh_metadata()
    local home = tmp_home()
    write_entry(home, "deepseek", os.time() - 25 * 3600, SHARD)
    local spawns = 0
    _G.tether = host_mock({
        fetch_bg = function(url, headers, pend, timeout)
            spawns = spawns + 1
            local f = assert(io.open(pend, "w"))
            f:close()
            return true
        end,
        http_get = function() return nil, "must be background" end,
    })
    local models, st = md.models("deepseek", home)
    assert_eq(st, "background", "META stale goes background")
    assert_eq(#models, 3, "META stale serves immediately")
    local _, st2 = md.models("deepseek", home)
    assert_eq(st2, "background", "META no duplicate fetch")
    assert_eq(spawns, 1, "META single background spawn")
    assert_eq(md.poll(home, "deepseek"), "waiting", "META poll waits")
    -- child lands the shard: consumed into the cache.
    local f = assert(io.open(md.pending_path(home, "deepseek"), "w"))
    f:write(SHARD)
    f:close()
    assert_eq(md.poll(home, "deepseek"), "updated", "META poll updates")
    assert_eq(md.poll(home, "deepseek"), "settled", "META poll settles")
    local fresh, st3 = md.models("deepseek", home)
    assert_eq(st3, "fresh", "META landed shard is fresh")
    assert_eq(#fresh, 3, "META landed models served")
    _G.tether = orig_tether
    rm_home(home)
    print("META background refresh: OK")
end

do
    -- miss blocks on one sync attempt; failures keep stale or report missing.
    local md = fresh_metadata()
    local home = tmp_home()
    _G.tether = host_mock({ http_get = function() return SHARD end })
    local models, st = md.models("deepseek", home)
    assert_eq(st, "ok", "META miss syncs")
    assert_eq(#models, 3, "META synced models served")
    _G.tether = host_mock({ http_get = function() return nil, "boom" end })
    local home2 = tmp_home()
    local stale, st4, reason = md.models("deepseek", home2)
    assert_eq(stale, nil, "META failure without cache serves nothing")
    assert_eq(st4, "missing", "META failure without cache is missing")
    assert_eq(reason, "boom", "META failure reason surfaces")
    write_entry(home2, "deepseek", os.time() - 25 * 3600, SHARD)
    local kept, st5, r2 = md.models("deepseek", home2)
    assert_eq(#kept, 3, "META failure keeps stale")
    assert_eq(st5, "stale", "META failure status is stale")
    assert_eq(r2, "boom", "META stale reason surfaces")
    _G.tether = host_mock({ http_get = function()
        return '{"schema":99,"id":"deepseek","models":[]}'
    end })
    local kept2, st6 = md.models("deepseek", home2)
    assert_eq(#kept2, 3, "META schema mismatch keeps stale")
    assert_eq(st6, "stale", "META schema mismatch is stale")
    _G.tether = orig_tether
    rm_home(home)
    rm_home(home2)
    print("META sync and failure paths: OK")
end

do
    -- failed background fetch settles and cools down.
    local md = fresh_metadata()
    local home = tmp_home()
    write_entry(home, "deepseek", os.time() - 25 * 3600, SHARD)
    _G.tether = host_mock({})
    local f = assert(io.open(md.pending_path(home, "deepseek"), "w"))
    f:write("FETCH_FAILED timeout\n")
    f:close()
    assert_eq(md.poll(home, "deepseek"), "settled", "META failure settles")
    assert_eq(#md.cached("deepseek", home), 3, "META failure keeps entry")
    _G.tether = orig_tether
    rm_home(home)
    print("META poll failure: OK")
end

do
    -- refresh opt-out: zero HTTP, disk still serves, absence stays silent.
    local md = fresh_metadata()
    local home = tmp_home()
    write_entry(home, "deepseek", os.time() - 25 * 3600, SHARD)
    local calls = 0
    _G.tether = host_mock({
        fetch_bg = function()
            calls = calls + 1
            return true
        end,
        http_get = function()
            calls = calls + 1
            return nil, "must not be called"
        end,
    })
    local stale, st, reason = md.models("deepseek", home, nil,
        { refresh = false })
    assert_eq(#stale, 3, "META opt-out serves stale disk")
    assert_eq(st, "stale", "META opt-out status is stale")
    assert_eq(reason, "metadata refresh disabled", "META opt-out reason")
    local missing, st2 = md.models("never-seen", home, nil,
        { refresh = false })
    assert_eq(missing, nil, "META opt-out miss serves nothing")
    assert_eq(st2, "missing", "META opt-out miss is missing")
    assert_eq(calls, 0, "META opt-out issues zero HTTP")
    _G.tether = orig_tether
    rm_home(home)
    print("META refresh opt-out: OK")
end

do
    local md = fresh_metadata()
    local models = md.parse_shard(SHARD, "deepseek")
    assert_eq(md.limit(models, "deepseek-chat", "plain"), 128000,
        "META limit exact hit")
    assert_eq(md.limit(models, "unknown", "deepseek-chat"), 128000,
        "META limit falls back to provider default")
    assert_eq(md.limit(models, "unknown", "plain"), nil,
        "META limit nil without numeric context")
    assert_eq(md.limit(nil, "x", "y"), nil, "META limit nil without models")
    print("META limit lookup: OK")
end

do
    -- the keyed-provider sweep never touches metadata: shards are fetched
    -- for the selected provider only, even with network available.
    local commands = assert(loadfile("src/tether/commands.lua"))()
    local home = tmp_home()
    local orig_config, orig_api, orig_tether2 = _G.config, _G.api, _G.tether
    _G.config = {
        providers_with_keys = function() return { "deepseek", "groq" } end,
        for_provider = function(_, id)
            return { provider = id, _auth_home = home }
        end,
        api_key = function() return "" end,
    }
    _G.api = nil
    _G.tether = host_mock({
        http_get = function() error("sweep must not fetch") end,
        fetch_bg = function() error("sweep must not spawn") end,
    })
    local ok, items = pcall(commands.list_models_all,
        { _auth_home = home })
    assert_true(ok, "META sweep runs without network")
    assert_true(type(items) == "table", "META sweep returns a list")
    local f = io.open(home .. "/.tether/metadata_cache.json", "r")
    assert_true(f == nil, "META sweep writes no shard cache")
    if f then f:close() end
    _G.config, _G.api, _G.tether = orig_config, orig_api, orig_tether2
    rm_home(home)
    print("META sweep quiet: OK")
end

_G.tether = orig_tether
_G.metadata = orig_meta

if failed > 0 then
    os.exit(1)
end
