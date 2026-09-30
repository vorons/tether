-- tests/model_budget_tests.lua — per-model metadata: the catalog warning
-- consults the live models list (not just the stale metadata shard), the
-- budget follows the selected model, and max_tokens stays nil unless the
-- user sets it (so the metadata chain is reachable).
-- Run: lua tests/model_budget_tests.lua (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

local function tmp_home()
    local p = os.tmpname()
    os.remove(p)
    assert(host_fs.mkdirp(p .. "/.tether"))
    return p
end

local function write_file(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function fixture(home, model)
    write_file(home .. "/.tether/providers_cache.json",
        '{"checked_at":' .. os.time() .. ',"schema":1,"generated_at":'
        .. os.time() .. ',"providers":{"testp":{"wire":"openai",'
        .. '"base_url":"https://t","api_key_env":["T"],"model":"base-m",'
        .. '"models":[{"id":"base-m","context":400},'
        .. '{"id":"other-m","context":100}]}}}')
    -- metadata shard is stale: no new-m here (lives only in the live list)
    write_file(home .. "/.tether/metadata_cache.json",
        '{"testp":{"checked_at":' .. os.time() .. ',"models":['
        .. '{"id":"base-m","context":400}]}}')
    -- live /models list knows new-m (no context numbers on this path)
    write_file(home .. "/.tether/models_cache.json",
        '{"testp":{"checked_at":' .. os.time() .. ',"models":['
        .. '{"id":"new-m","name":"new-m"}]}}')
    write_file(home .. "/.tether/config.lua",
        'return { provider = "testp", model = "' .. model .. '" }')
end

local function load_capture(home)
    _G.tether = host_mock({
        getcwd = function() return "/tmp" end,
        realpath = function(p) return p end,
    })
    local cfgmod = assert(loadfile("src/tether/config.lua"))()
    local captured = {}
    local real = io.stderr
    io.stderr = { write = function(_, s)
        captured[#captured + 1] = tostring(s)
        return io.stderr
    end }
    local cfg = cfgmod.load(home .. "/.tether/config.lua", home)
    io.stderr = real
    return cfg, table.concat(captured)
end

-- R1: a model known to the live list is not warned about, even when the
-- metadata shard is stale without it; a truly unknown id still warns.
do
    local home = tmp_home()
    fixture(home, "new-m")
    local _, err = load_capture(home)
    assert_true(err:find("not in the providers catalog", 1, true) == nil,
        "R1 live-listed model stays silent")
    local home2 = tmp_home()
    fixture(home2, "nope")
    local _, err2 = load_capture(home2)
    assert_true(err2:find("not in the providers catalog", 1, true) ~= nil,
        "R1 unknown model still warns")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. home2 .. "'")
    print("R1 catalog warning consults the live list: OK")
end

-- R2: max_tokens is not backfilled — nil unless the user sets it, so the
-- per-model metadata chain stays reachable downstream.
do
    local home = tmp_home()
    fixture(home, "new-m")
    local cfg = load_capture(home)
    assert_eq(cfg.context.max_tokens, nil, "R2 max_tokens stays nil when unset")
    local home2 = tmp_home()
    fixture(home2, "new-m")
    local f = assert(io.open(home2 .. "/.tether/config.lua", "a"))
    f:write('\n')
    f:close()
    write_file(home2 .. "/.tether/config.lua",
        'return { provider = "testp", model = "new-m", context = { max_tokens = 4000 } }')
    local cfg2 = load_capture(home2)
    assert_eq(cfg2.context.max_tokens, 4000, "R2 explicit max_tokens survives")
    os.execute("rm -rf '" .. home .. "'")
    os.execute("rm -rf '" .. home2 .. "'")
    print("R2 max_tokens backfill removed: OK")
end

-- R3 (guard): the resolution chain itself — provider default via the
-- metadata fallback entry, explicit user value on top.
do
    _G.tether = host_mock({})
    local home = tmp_home()
    fixture(home, "new-m")
    _G.provider_catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
    assert_eq(_G.provider_catalog.ensure(home), "ready", "R3 cache loads")
    local comp = assert(loadfile("src/tether/compression.lua"))()
    local function budget(cfg)
        return (comp.compaction_thresholds(cfg))
    end
    assert_eq(budget({ provider = "testp", model = "nope",
        context = {}, _auth_home = home }), 400,
        "R3 provider default applies")
    assert_eq(budget({ provider = "testp", model = "nope",
        context = { max_tokens = 4000 }, _auth_home = home }), 4000,
        "R3 explicit max_tokens wins")
    _G.provider_catalog = nil
    os.execute("rm -rf '" .. home .. "'")
    print("R3 chain guard: OK")
end

-- R4: picking a model re-resolves the budget from metadata (explicit
-- user value stays untouched).
do
    _G.tether = host_mock({})
    local home = tmp_home()
    fixture(home, "base-m")
    _G.provider_catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
    assert_eq(_G.provider_catalog.ensure(home), "ready", "R4 cache loads")
    _G.config = { persist_keys = function() return true end }
    local cmds = assert(loadfile("src/tether/commands.lua"))()
    local deps = { append = function() end, bump = function() end }
    local bag = { cfg = { provider = "testp", model = "old-m",
        context = {}, _auth_home = home }, tokens_max = 32768 }
    cmds.pick_model(bag, deps, { label = "base-m" })
    assert_eq(bag.cfg.model, "base-m", "R4 model applied")
    assert_eq(bag.tokens_max, 400, "R4 pick refreshes the budget from metadata")
    local bag2 = { cfg = { provider = "testp", model = "old-m",
        context = { max_tokens = 4000 }, _auth_home = home }, tokens_max = 32768 }
    cmds.pick_model(bag2, deps, { label = "base-m" })
    assert_eq(bag2.tokens_max, 4000, "R4 explicit budget survives the pick")
    _G.provider_catalog = nil
    _G.config = nil
    os.execute("rm -rf '" .. home .. "'")
    print("R4 pick refreshes the budget: OK")
end

print("model budget section: OK")
if failed > 0 then
    print("FAILURES: " .. tostring(failed))
    os.exit(1)
end
