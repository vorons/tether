-- tests/context_tests.lua — context-injection: prompt composition, AGENTS.md,
-- skills discovery. Run: lua tests/context_tests.lua

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

local function has(haystack, needle, literal)
    return haystack:find(needle, 1, literal or false) ~= nil
end

local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

-- Build an isolated HOME so tests don't touch the real one, and a scratch
-- workspace. context.lua reads os.getenv("HOME") at call time.
local function setup_sandbox(prefix)
    local home = os.tmpname()
    os.remove(home)
    os.execute("mkdir -p " .. home)
    local ws = os.tmpname()
    os.remove(ws)
    os.execute("mkdir -p " .. ws)
    os.execute("mkdir -p " .. ws .. "/.tether/skills " .. ws .. "/.agents/skills")
    os.execute("mkdir -p " .. home .. "/.tether/skills " .. home .. "/.agents/skills")
    -- point HOME at the sandbox
    _ENV.HOME = home
    -- os.getenv is fixed for the process; use a shim via `env` override is not
    -- available, so instead we export HOME by relaunching? No — set it through
    -- a global hook the test harness owns:
    -- context.lua calls os.getenv("HOME"). We capture it by setting the env var
    -- for this Lua process:
    os.execute("true")
    return home, ws
end

-- We need HOME to actually be the sandbox. The cleanest way is to set it in the
-- environment before launching the tests. The Makefile test target does:
--   HOME=$(TMP) lua tests/context_tests.lua
-- So here we just read HOME and assume it's the sandbox.
local HOME = os.getenv("HOME")
local WS = os.getenv("TETHER_TEST_WORKSPACE")
assert(HOME and WS, "context_tests: run with HOME=<sandbox> TETHER_TEST_WORKSPACE=<dir> lua tests/context_tests.lua")

local function reset_sandbox()
    -- wipe skill + agents files
    os.execute("rm -rf " .. WS .. "/.tether/skills " .. WS .. "/.agents/skills")
    os.execute("rm -rf " .. HOME .. "/.tether/skills " .. HOME .. "/.agents/skills")
    os.execute("rm -f " .. WS .. "/AGENTS.md " .. HOME .. "/AGENTS.md")
    os.execute("mkdir -p " .. WS .. "/.tether/skills " .. WS .. "/.agents/skills")
    os.execute("mkdir -p " .. HOME .. "/.tether/skills " .. HOME .. "/.agents/skills")
end

-- Stub the C host's tether.exec (used for ls-based skill enumeration) so the
-- test works under a plain Lua runtime without the C host.
local function stub_tether()
    local tether_stub = {}
    function tether_stub.exec(cmd)
        -- emulates: ls -1A "<dir>" > "<tmp>" 2>/dev/null
        -- capture via io.popen inside the stub (test runtime has it).
        local ok, code = pcall(function()
            local f = io.popen(cmd .. " >/dev/null 2>&1; echo $?")
            -- simpler: just run and rely on io.popen availability
        end)
        -- Provide exec() that mirrors the C host: run the command, return
        -- (exit==0, code). For the redirect-to-tmp pattern used by context.lua,
        -- we instead implement ls_subdirs directly via a popen of `ls -1A dir`.
        return true, 0
    end
    -- But context.lua's ls_subdirs calls `tether.exec('ls -1A dir > tmp')` then
    -- reads the tmp file. Under plain Lua, io.popen works, so we emulate by
    -- running the command through a real shell via os.execute is not enough to
    -- capture. Instead, override the module after load with a fake that uses a
    -- precomputed directory listing. The tests set the directories up on disk,
    -- so we can fake tether.exec to actually run `ls -1A` via io.popen and
    -- write to the tmp file the command redirected to. That's complex.
    --
    -- Simpler: patch context to allow an injected `ls` function. We do that in
    -- the test by re-loading context.lua with a stubbed global `tether`.
    return tether_stub
end

-- Load context.lua with a fake `tether` global so skill discovery works
-- without the C host. ls_subdirs uses tether.readdir (src/host/main.c), so the
-- stub stands in with `ls -1A` over io.popen, which the test runtime has.
local function load_context()
    _G.tether = {}
    function _G.tether.readdir(path)
        local f = io.popen("ls -1A '" .. tostring(path):gsub("'", "'\\''") .. "' 2>/dev/null")
        if not f then return nil end
        local out = f:read("*a")
        f:close()
        local names = {}
        for name in out:gmatch("[^\n]+") do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    local chunk = assert(loadfile("src/tether/context.lua"))
    return chunk()
end

-- Provide a config stub for the base-prompt path.
_G.config = {
    get_system_prompt = function(cfg)
        if cfg and cfg.system_prompt then
            return cfg.system_prompt
        end
        return nil
    end,
}

local ctx = load_context()

-- ============ 1. AGENTS.md discovery order ============
do
    reset_sandbox()
    write_file(HOME .. "/AGENTS.md", "home-rules")
    write_file(WS .. "/AGENTS.md", "ws-rules")

    local auto = ctx.load_agents_files(WS)
    assert_eq(#auto, 2, "T1 both AGENTS.md found")
    assert_eq(auto[1].label, "home", "T1 home first")
    assert_eq(auto[1].content, "home-rules", "T1 home content")
    assert_eq(auto[2].label, "workspace", "T1 workspace second")
    assert_eq(auto[2].content, "ws-rules", "T1 ws content")

    reset_sandbox()
    write_file(WS .. "/AGENTS.md", "only-ws")
    local auto2 = ctx.load_agents_files(WS)
    assert_eq(#auto2, 1, "T2 only workspace")
    assert_eq(auto2[1].label, "workspace", "T2 label")

    reset_sandbox()
    local auto3 = ctx.load_agents_files(WS)
    assert_eq(#auto3, 0, "T3 no AGENTS.md anywhere")
    print("T1/T2/T3 AGENTS.md discovery: OK")
end

-- ============ 2. Frontmatter parse ============
do
    local r = ctx.parse_skill_frontmatter("---\nname: deploy\ndescription: Ship the app\n---\nbody", "deploy")
    assert_eq(r.name, "deploy", "T4 name")
    assert_eq(r.description, "Ship the app", "T4 description")

    local r2 = ctx.parse_skill_frontmatter("no frontmatter here", "mydir")
    assert_eq(r2.name, "mydir", "T5 fallback name = dir")
    assert_eq(r2.description, "", "T5 empty description")

    local r3 = ctx.parse_skill_frontmatter("---\nname: onlyname\n---\nbody", "x")
    assert_eq(r3.name, "onlyname", "T6 name only")
    assert_eq(r3.description, "", "T6 missing description empty")

    local r4 = ctx.parse_skill_frontmatter("---\ndescription: 'quoted desc'\n---\nbody", "q")
    assert_eq(r4.name, "q", "T7 fallback name")
    assert_eq(r4.description, "quoted desc", "T7 quoted description")
    print("T4-T7 frontmatter: OK")
end

-- ============ 3. Skills discovery ============
do
    reset_sandbox()
    -- workspace .tether/skills has a skill
    os.execute("mkdir -p " .. WS .. "/.tether/skills/deploy")
    write_file(WS .. "/.tether/skills/deploy/SKILL.md",
               "---\nname: deploy\ndescription: Ship the app\n---\n# Deploy\n")

    local skills = ctx.discover_skills({}, WS)
    assert_true(#skills >= 1 and skills[1].name == "deploy", "T8 workspace skill found")
    assert_eq(#skills, 1, "T8 exactly one skill")
    assert_eq(skills[1].name, "deploy", "T8 skill name")
    assert_eq(skills[1].description, "Ship the app", "T8 skill description")

    reset_sandbox()
    local none = ctx.discover_skills({}, WS)
    assert_eq(#none, 0, "T9 no skills anywhere")
    print("T8/T9 skill discovery: OK")
end

-- ============ 4. skills_dirs override ============
do
    reset_sandbox()
    local custom = os.tmpname()
    os.remove(custom)
    os.execute("mkdir -p " .. custom .. "/only-skill")
    write_file(custom .. "/only-skill/SKILL.md", "---\nname: only\ndescription: custom dir\n---\n")

    local skills = ctx.discover_skills({ skills_dirs = { custom } }, WS)
    assert_eq(#skills, 1, "T10 skills_dirs override finds one")
    assert_eq(skills[1].name, "only", "T10 name")

    -- skills_dirs replacing defaults: ensure default ws skill is NOT included
    os.execute("mkdir -p " .. WS .. "/.tether/skills/extra")
    write_file(WS .. "/.tether/skills/extra/SKILL.md", "---\nname: extra\n---\n")
    local skills2 = ctx.discover_skills({ skills_dirs = { custom } }, WS)
    assert_eq(#skills2, 1, "T11 skills_dirs excludes default dirs")
    assert_eq(skills2[1].name, "only", "T11 only custom")

    os.execute("rm -rf " .. custom)
    print("T10/T11 skills_dirs: OK")
end

-- ============ 5. first-wins collision ============
do
    reset_sandbox()
    os.execute("mkdir -p " .. HOME .. "/.tether/skills/dup " .. WS .. "/.tether/skills/dup")
    write_file(HOME .. "/.tether/skills/dup/SKILL.md", "---\nname: dup\ndescription: from home\n---\n")
    write_file(WS .. "/.tether/skills/dup/SKILL.md", "---\nname: dup\ndescription: from ws\n---\n")

    local skills = ctx.discover_skills({}, WS)
    local found = {}
    for _, s in ipairs(skills) do
        if s.name == "dup" then
            found[#found + 1] = s
        end
    end
    assert_eq(#found, 1, "T12 collision: exactly one dup")
    assert_eq(found[1].description, "from home", "T12 first-wins = home (default order)")
    print("T12 first-wins collision: OK")
end

-- ============ 6. compose ordering & content ============
do
    reset_sandbox()
    write_file(HOME .. "/AGENTS.md", "home-rules")
    write_file(WS .. "/AGENTS.md", "ws-rules")
    os.execute("mkdir -p " .. WS .. "/.tether/skills/deploy")
    write_file(WS .. "/.tether/skills/deploy/SKILL.md",
               "---\nname: deploy\ndescription: Ship the app\n---\n# Deploy\n")

    local prompt = ctx.compose({}, { workspace = WS, agents_files = {} })
    -- base (built-in) must be first
    assert_true(has(prompt, "You are tether", true), "T13 base present")
    local home_pos = prompt:find("home-rules", 1, true)
    local ws_pos = prompt:find("ws-rules", 1, true)
    local skills_pos = prompt:find("## Skills", 1, true)
    assert_true((home_pos ~= nil) and (ws_pos ~= nil) and (skills_pos ~= nil), "T13 all sections present")
    assert_true(home_pos < ws_pos, "T13 home before workspace")
    assert_true(ws_pos < skills_pos, "T13 workspace before skills")
    assert_true(has(prompt, "Ship the app", true), "T13 skill description in index")

    print("T13 compose ordering: OK")
end

-- ============ 7. config system_prompt replaces base only ============
do
    reset_sandbox()
    write_file(WS .. "/AGENTS.md", "ws-rules")
    os.execute("mkdir -p " .. WS .. "/.tether/skills/deploy")
    write_file(WS .. "/.tether/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: d\n---\n")

    local prompt = ctx.compose({ system_prompt = "CUSTOM BASE" }, { workspace = WS })
    -- custom base first, then AGENTS.md, then skills — AGENTS/skills still appended
    assert_true(has(prompt, "CUSTOM BASE", true), "T14 custom base present")
    assert_true(has(prompt, "ws-rules", true), "T14 AGENTS.md appended after base")
    assert_true(has(prompt, "## Skills", 1, true) and has(prompt, "deploy", true), "T14 skills appended")
    local base_pos = prompt:find("CUSTOM BASE", 1, true)
    local agents_pos = prompt:find("ws-rules", 1, true)
    assert_true(base_pos < agents_pos, "T14 base before AGENTS.md")
    print("T14 config system_prompt override: OK")
end

-- ============ 8. agents_files (config + CLI) merged before skills ============
do
    reset_sandbox()
    local afile = os.tmpname()
    write_file(afile, "AGENTA-CONTENT")
    local bfile = os.tmpname()
    write_file(bfile, "AGENTB-CONTENT")

    -- config agents_files + CLI flag files, order: config first then CLI
    local prompt = ctx.compose(
        { agents_files = { afile } },
        { workspace = WS, agents_files = { bfile } }
    )
    local a_pos = prompt:find("AGENTA-CONTENT", 1, true)
    local b_pos = prompt:find("AGENTB-CONTENT", 1, true)
    local skills_pos = prompt:find("## Skills", 1, true)
    assert_true((a_pos ~= nil) and (b_pos ~= nil), "T15 both agents files present")
    assert_true(a_pos < b_pos, "T15 config agents_files before CLI --agents-file")
    if skills_pos then
        assert_true(b_pos < skills_pos, "T15 agents files before skills")
    end
    os.remove(afile); os.remove(bfile)
    print("T15 agents_files merging: OK")
end

-- ============ 9. 16 KB truncation ============
do
    reset_sandbox()
    local big = string.rep("x", ctx.AGENTS_CAP_BYTES + 1000)
    write_file(WS .. "/AGENTS.md", big)
    local prompt = ctx.compose({}, { workspace = WS })
    assert_true(has(prompt, "…(truncated)", true), "T16 truncated marker present")
    assert_true(has(prompt, string.rep("x", ctx.AGENTS_CAP_BYTES), true), "T16 cap honored")
    -- ensure it did NOT include the full 17000+
    assert_true(not has(prompt, string.rep("x", ctx.AGENTS_CAP_BYTES + 1000), true), "T16 not full")
    print("T16 16KB truncation: OK")
end

-- ============ 10. skills_dirs empty defaults (no dirs) ============
do
    reset_sandbox()
    -- remove all default skill dirs entirely
    os.execute("rm -rf " .. HOME .. "/.tether " .. WS .. "/.tether " .. HOME .. "/.agents " .. WS .. "/.agents")
    local skills = ctx.discover_skills({}, WS)
    assert_eq(#skills, 0, "T17 no default dirs -> no skills")
    print("T17 no default dirs: OK")
end

print(string.format("CONTEXT PASS: %d/%d", passed, passed + failed))
if failed > 0 then
    os.exit(1)
end
