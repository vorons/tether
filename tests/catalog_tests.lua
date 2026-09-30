-- tests/catalog_tests.lua — vendored snapshot layering (offline-provider-catalog).
-- Run: lua tests/catalog_tests.lua

dofile("tests/helpers.lua")

local function fresh_catalog()
    return assert(loadfile("src/tether/providers/catalog.lua"))()
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

do
    -- snapshot() via the source-tree fallback (plain-lua: no embedded global).
    local cat = fresh_catalog()
    local snap, gen = cat.snapshot()
    assert_notnil(snap, "CAT snapshot present via source tree")
    assert_eq(type(gen), "number", "CAT snapshot generated_at is a number")
    local n = 0
    for _ in pairs(snap) do n = n + 1 end
    assert_true(n > 200, "CAT snapshot holds the pipeline ids")
    assert_notnil(snap.deepseek, "CAT snapshot has deepseek")
    assert_eq(snap.deepseek.models, nil, "CAT snapshot entry carries no models[]")
    assert_eq(snap.deepseek._source, "snapshot", "CAT snapshot source tag")
    assert_notnil(snap.deepseek.base_url, "CAT snapshot entry has an endpoint")
    print("CAT snapshot fallback: OK")
end

do
    -- ensure() with an empty HOME: no cache, no models.lua, no network.
    local cat = fresh_catalog()
    local home = tmp_home()
    local ok, err = cat.ensure(home)
    assert_eq(ok, "ready", "CAT ensure ready with no cache (" .. tostring(err) .. ")")
    local e = cat.get("deepseek")
    assert_notnil(e, "CAT Tier-A id resolves from snapshot")
    assert_eq(e._source, "snapshot", "CAT Tier-A entry source is snapshot")
    assert_notnil(e.base_url, "CAT snapshot entry has endpoint")
    local local_e = cat.get("llama-cpp")
    assert_notnil(local_e, "CAT local id resolves")
    assert_eq(local_e._source, "bootstrap", "CAT bootstrap wins over snapshot")
    local meta = cat.overlay_meta()
    assert_notnil(meta, "CAT meta present")
    assert_eq(meta.snapshot, true, "CAT meta marks snapshot layer")
    assert_notnil(meta.generated_at, "CAT meta carries snapshot generated_at")
    local ids = cat.ids()
    assert_true(#ids > 200, "CAT ids() serves snapshot ids with no cache")
    rm_home(home)
    print("CAT offline ensure: OK")
end

do
    -- cache layer wins over the snapshot for the same id.
    local cat = fresh_catalog()
    local home = tmp_home()
    local common = assert(loadfile("src/tether/providers/common.lua"))()
    local cache = { checked_at = os.time(), schema = 1, generated_at = 111,
        providers = { deepseek = { wire = "openai",
            base_url = "https://custom.example/v1",
            api_key_env = { "X" }, model = "m" } } }
    local f = assert(io.open(home .. "/.tether/providers_cache.json", "w"))
    f:write(common.json_encode(cache))
    f:close()
    assert_eq(cat.ensure(home), "ready", "CAT ensure ready with cache")
    local e = cat.get("deepseek")
    assert_eq(e.base_url, "https://custom.example/v1", "CAT cache wins over snapshot")
    assert_eq(e._source, "cache", "CAT cache source tag")
    assert_notnil(cat.get("groq"), "CAT other ids still come from snapshot")
    rm_home(home)
    print("CAT cache precedence: OK")
end

do
    -- models.lua overlay wins over the snapshot for the same id.
    local cat = fresh_catalog()
    local home = tmp_home()
    local f = assert(io.open(home .. "/.tether/models.lua", "w"))
    f:write('return { providers = { deepseek = { wire = "openai", '
        .. 'base_url = "https://overlay.example/v1", model = "m" } } }\n')
    f:close()
    assert_eq(cat.ensure(home), "ready", "CAT ensure ready with overlay")
    local e = cat.get("deepseek")
    assert_eq(e.base_url, "https://overlay.example/v1", "CAT overlay wins over snapshot")
    assert_eq(e._source, "models.lua", "CAT overlay source tag")
    rm_home(home)
    print("CAT overlay precedence: OK")
end

do
    -- an unusable snapshot with no cache and no overlay is still an error
    -- naming the cache file (the residual brick path).
    local cat = fresh_catalog()
    local home = tmp_home()
    local saved = _G.providers_snapshot
    _G.providers_snapshot = "garbage"
    -- hide the source-tree fallback for this case: point at nothing by
    -- keeping the bad global (it takes precedence over the file).
    assert_eq(cat.snapshot(), nil, "CAT bad snapshot parses to nil")
    local ok, err = cat.ensure(home)
    assert_eq(ok, nil, "CAT ensure fails with no usable layer")
    assert_true(err ~= nil and err:find("providers_cache.json", 1, true) ~= nil,
        "CAT error names the cache file")
    _G.providers_snapshot = saved
    rm_home(home)
    print("CAT unusable snapshot errors: OK")
end

do
    -- check_providers passes a Tier-A id with an empty HOME and no network.
    local commands = assert(loadfile("src/tether/commands.lua"))()
    local home = tmp_home()
    local ok, err = commands.check_providers(home, "deepseek")
    assert_eq(ok, true, "CAT check_providers passes Tier-A offline ("
        .. tostring(err) .. ")")
    local ok2 = commands.check_providers(home, "llama-cpp")
    assert_eq(ok2, true, "CAT check_providers passes local offline")
    rm_home(home)
    print("CAT check_providers offline: OK")
end

do
    -- api.list_models Tier-A chain: live cache -> shard ids -> empty.
    -- A snapshot-backed catalog carries no entry.models for Tier-A ids.
    local common = assert(loadfile("src/tether/providers/common.lua"))()
    local home = tmp_home()
    local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
    assert_eq(catfix.ensure(home), "ready", "CAT tiers ensure ready")
    local orig_catalog = _G.provider_catalog
    _G.provider_catalog = catfix
    local api = assert(loadfile("src/tether/api.lua"))()
    local cfg = { provider = "groq", _auth_home = home }

    -- empty: no live cache, no shard, no network attempted.
    local empty = api.list_models(cfg)
    assert_eq(#empty, 0, "CAT tiers empty with no data")

    -- shard tier serves ids from disk.
    local mcache = { groq = { checked_at = os.time(),
        models = { { id = "shard-a", context = 100 } } } }
    local mf = assert(io.open(home .. "/.tether/metadata_cache.json", "w"))
    mf:write(common.json_encode(mcache))
    mf:close()
    local shard_ids = api.list_models(cfg)
    assert_eq(#shard_ids, 1, "CAT tiers shard serves one id")
    assert_eq(shard_ids[1], "shard-a", "CAT tiers shard id")

    -- live-cache tier wins over the shard.
    local lcache = { groq = { checked_at = os.time(),
        models = { { id = "live-a" }, { id = "live-b" } } } }
    local lf = assert(io.open(home .. "/.tether/models_cache.json", "w"))
    lf:write(common.json_encode(lcache))
    lf:close()
    local live_ids = api.list_models(cfg)
    assert_eq(#live_ids, 2, "CAT tiers live cache wins")
    assert_eq(live_ids[1], "live-a", "CAT tiers live id")
    _G.provider_catalog = orig_catalog
    rm_home(home)
    print("CAT api tiers: OK")
end

do
    -- warm_metadata fetches the shard on selection and honors the opt-out.
    local commands = assert(loadfile("src/tether/commands.lua"))()
    local home = tmp_home()
    local shard_body = '{"schema":1,"generated_at":1,"id":"deepseek",'
        .. '"models":[{"id":"m","context":9}]}'
    local calls = 0
    local orig_tether = _G.tether
    _G.tether = host_mock({ http_get = function()
        calls = calls + 1
        return shard_body
    end })
    local cfg = { provider = "deepseek", _auth_home = home }
    assert_eq(commands.warm_metadata(cfg), false,
        "CAT warm sync miss spawns nothing")
    assert_eq(calls, 1, "CAT warm fetches the shard once")
    local md = assert(loadfile("src/tether/metadata.lua"))()
    assert_eq(#md.cached("deepseek", home), 1, "CAT warm lands the shard")
    -- second open is fresh: no more traffic.
    assert_eq(commands.warm_metadata(cfg), false, "CAT warm fresh is quiet")
    assert_eq(calls, 1, "CAT warm fresh issues no HTTP")
    -- opt-out: stale disk serves, zero HTTP even on miss.
    local home2 = tmp_home()
    assert_eq(commands.warm_metadata({ provider = "deepseek",
        _auth_home = home2, metadata_refresh = false }), false,
        "CAT warm opt-out spawns nothing")
    assert_eq(calls, 1, "CAT warm opt-out issues zero HTTP")
    assert_eq(commands.poll_metadata(home2, "deepseek"), "settled",
        "CAT poll quiet settles")
    _G.tether = orig_tether
    rm_home(home)
    rm_home(home2)
    print("CAT warm_metadata: OK")
end

do
    -- config pin warning: mismatch warns (legacy list or shard), absence
    -- of any known list stays silent.
    local common = assert(loadfile("src/tether/providers/common.lua"))()
    local home = tmp_home()
    local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
    catfix.set_overlay({
        legacyp = { wire = "openai", base_url = "https://l.example/v1",
            api_key_env = "L", model = "a",
            models = { { id = "a", context = 1 } }, _source = "test" },
        emptyp = { wire = "openai", base_url = "https://e.example/v1",
            api_key_env = "E", model = "", models = {}, _source = "test" },
        warnp = { wire = "openai", base_url = "https://w.example/v1",
            api_key_env = "W", model = "", _source = "test" },
        shardp = { wire = "openai", base_url = "https://s.example/v1",
            api_key_env = "S", model = "", _source = "test" },
    }, { generated_at = 0 })
    local orig_catalog = _G.provider_catalog
    _G.provider_catalog = catfix
    local mcache = { shardp = { checked_at = os.time(),
        models = { { id = "s-a", context = 10 } } } }
    local mf = assert(io.open(home .. "/.tether/metadata_cache.json", "w"))
    mf:write(common.json_encode(mcache))
    mf:close()
    local cfgmod = assert(loadfile("src/tether/config.lua"))()
    local function load_quiet(provider, model)
        local cf = assert(io.open(home .. "/.tether/cfg.lua", "w"))
        cf:write('return { provider = "' .. provider .. '", model = "'
            .. model .. '" }\n')
        cf:close()
        local ef = assert(io.open(home .. "/.tether/stderr.txt", "w"))
        local old_err = io.stderr
        io.stderr = ef
        local rc = cfgmod.load(home .. "/.tether/cfg.lua", home)
        io.stderr = old_err
        ef:close()
        local rf = assert(io.open(home .. "/.tether/stderr.txt", "r"))
        local captured = rf:read("*a")
        rf:close()
        return rc, captured
    end
    local rc1, w1 = load_quiet("legacyp", "renamed-away")
    assert_eq(rc1.model, "renamed-away", "CAT pin resolves verbatim")
    assert_true(w1:find("renamed-away", 1, true) ~= nil,
        "CAT legacy mismatch warns")
    local _, w2 = load_quiet("warnp", "whatever")
    assert_eq(w2:find("whatever", 1, true), nil, "CAT absent list silent")
    local _, w3 = load_quiet("emptyp", "whatever")
    assert_eq(w3:find("whatever", 1, true), nil, "CAT empty list silent")
    local _, w4 = load_quiet("shardp", "s-a")
    assert_eq(w4:find("s-a", 1, true), nil, "CAT shard hit silent")
    local _, w5 = load_quiet("shardp", "gone")
    assert_true(w5:find("gone", 1, true) ~= nil, "CAT shard mismatch warns")
    _G.provider_catalog = orig_catalog
    rm_home(home)
    print("CAT pin warning states: OK")
end

do
    -- 6.1: single-model local server is adopted without /model.
    local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
    catfix.set_overlay({
        ["llama-cpp"] = { wire = "openai",
            base_url = "http://127.0.0.1:8080/v1",
            api_key_env = "LLAMA_API_KEY", model = "", _source = "test" },
    }, { generated_at = 0 })
    local orig_catalog = _G.provider_catalog
    _G.provider_catalog = catfix
    local api = assert(loadfile("src/tether/api.lua"))()
    local orig_tether = _G.tether
    local calls, body = 0, '{"data":[{"id":"served-model"}]}'
    _G.tether = host_mock({ http_get = function()
        calls = calls + 1
        if body == nil then return nil, "down" end
        return body
    end })
    local function llamacfg(model)
        return { provider = "llama-cpp",
            base_url = "http://127.0.0.1:8080/v1", model = model or "" }
    end
    local single = llamacfg()
    api._adopt_local_model(single, "")
    assert_eq(single.model, "served-model", "CAT single model adopted")
    assert_eq(calls, 1, "CAT adopt lists once")
    -- ambiguity leaves the pin empty.
    body = '{"data":[{"id":"a"},{"id":"b"}]}'
    local multi = llamacfg()
    api._adopt_local_model(multi, "")
    assert_eq(multi.model, "", "CAT ambiguous list not adopted")
    -- a set pin is never re-listed.
    local preset = llamacfg("picked")
    api._adopt_local_model(preset, "")
    assert_eq(preset.model, "picked", "CAT preset pin kept")
    -- non-loopback never lists.
    local remote = { provider = "llama-cpp",
        base_url = "https://lan.example:8080/v1", model = "" }
    api._adopt_local_model(remote, "")
    assert_eq(remote.model, "", "CAT non-loopback untouched")
    -- dead server leaves the pin empty for the verbatim request.
    body = nil
    local dead = llamacfg()
    api._adopt_local_model(dead, "")
    assert_eq(dead.model, "", "CAT dead server untouched")
    assert_eq(calls, 3, "CAT preset and remote issue no HTTP")
    _G.tether = orig_tether
    _G.provider_catalog = orig_catalog
    print("CAT local auto-adopt: OK")
end

if failed > 0 then
    os.exit(1)
end
