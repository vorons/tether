-- tests/prompts_discovery_tests.lua — prompts-as-commands: prompt file
-- discovery, description parsing, body strip + cap.
-- Run: HOME=<sandbox> lua tests/prompts_discovery_tests.lua
-- (the Makefile unit target always provides a fresh mktemp HOME).

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

local function has(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local HOME = os.getenv("HOME")
assert(HOME, "prompts_discovery_tests: HOME must be set (Makefile provides a sandbox)")

-- Never write into a real home: refuse anything outside the temp root.
local TMPROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/"
assert(#HOME > #TMPROOT and HOME:sub(1, #TMPROOT) == TMPROOT,
    "prompts_discovery_tests: HOME must live under " .. TMPROOT .. " (sandbox guard)")

local function sq(p)
    return "'" .. tostring(p):gsub("'", "'\\''") .. "'"
end

local WS = HOME .. "/ws"
os.execute("mkdir -p " .. sq(WS))

local DIRS = {
    HOME .. "/.tether/prompts",
    WS .. "/.tether/prompts",
    HOME .. "/.agents/prompts",
    WS .. "/.agents/prompts",
}

local function reset_prompts()
    for _, d in ipairs(DIRS) do
        os.execute("rm -rf " .. sq(d))
        os.execute("mkdir -p " .. sq(d))
    end
end

-- tether.readdir stub over ls, same idiom as context_tests.lua.
_G.tether = {}
function _G.tether.readdir(path)
    local f = io.popen("ls -1A " .. sq(path) .. " 2>/dev/null")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    local names = {}
    for name in out:gmatch("[^\n]+") do names[#names + 1] = name end
    table.sort(names)
    return names
end

local ctx = assert(loadfile("src/tether/context.lua"))()

local function by_name(prompts)
    local m = {}
    for _, p in ipairs(prompts) do m[p.name] = p end
    return m
end

-- default dir order: home tether, ws tether, home agents, ws agents
do
    local dirs = ctx.default_prompt_dirs(WS, HOME)
    assert_eq(#dirs, 4, "P1 four prompt dirs")
    assert_eq(dirs[1], HOME .. "/.tether/prompts", "P1 first is home tether")
    assert_eq(dirs[2], WS .. "/.tether/prompts", "P1 second is ws tether")
    assert_eq(dirs[3], HOME .. "/.agents/prompts", "P1 third is home agents")
    assert_eq(dirs[4], WS .. "/.agents/prompts", "P1 fourth is ws agents")
    print("P1 default_prompt_dirs: OK")
end

-- basic discovery + first-wins (case-insensitive)
do
    reset_prompts()
    write_file(HOME .. "/.tether/prompts/review.md", "home body $ARGUMENTS")
    write_file(WS .. "/.tether/prompts/review.md", "ws body")
    write_file(WS .. "/.tether/prompts/plan.md", "plan body")
    local prompts = ctx.discover_prompts({}, WS)
    assert_eq(#prompts, 2, "P2 two prompts")
    local m = by_name(prompts)
    assert_eq(m.review.path, HOME .. "/.tether/prompts/review.md", "P2 home wins")
    assert_true(m.plan ~= nil, "P2 ws-only prompt found")
    print("P2 first-wins: OK")
end

-- case-insensitive dedup across dirs
do
    reset_prompts()
    write_file(HOME .. "/.tether/prompts/Review.md", "home")
    write_file(WS .. "/.agents/prompts/review.md", "ws agents")
    local prompts = ctx.discover_prompts({}, WS)
    assert_eq(#prompts, 1, "P3 case-insensitive dedup")
    assert_eq(prompts[1].path, HOME .. "/.tether/prompts/Review.md", "P3 first dir wins")
    print("P3 case dedup: OK")
end

-- subdirs, non-md, bare ".md" ignored
do
    reset_prompts()
    os.execute("mkdir -p " .. sq(WS .. "/.tether/prompts/nested"))
    write_file(WS .. "/.tether/prompts/nested/inner.md", "nested")
    write_file(WS .. "/.tether/prompts/notes.txt", "txt")
    write_file(WS .. "/.tether/prompts/.md", "bare")
    write_file(WS .. "/.tether/prompts/ok.md", "ok")
    local prompts = ctx.discover_prompts({}, WS)
    assert_eq(#prompts, 1, "P4 only top-level md")
    assert_eq(prompts[1].name, "ok", "P4 the md file found")
    print("P4 file filter: OK")
end

-- command-name passthrough: discovery returns the file (suppression lives
-- in the palette/submit layers, per spec)
do
    reset_prompts()
    write_file(HOME .. "/.tether/prompts/clear.md", "clear body")
    local prompts = ctx.discover_prompts({}, WS)
    assert_eq(#prompts, 1, "P5 command-named file still discovered")
    assert_eq(prompts[1].name, "clear", "P5 name is basename")
    print("P5 no command filtering: OK")
end

-- empty everywhere
do
    reset_prompts()
    local prompts = ctx.discover_prompts({}, WS)
    assert_eq(#prompts, 0, "P6 no prompts anywhere")
    print("P6 empty: OK")
end

-- description parsing
do
    reset_prompts()
    write_file(HOME .. "/.tether/prompts/a.md",
        "---\ndescription: Check the diff\n---\nBody here $ARGUMENTS")
    write_file(HOME .. "/.tether/prompts/b.md", "no frontmatter body")
    write_file(HOME .. "/.tether/prompts/c.md", "---\nname: other\n---\nBody c")
    local m = by_name(ctx.discover_prompts({}, WS))
    assert_eq(m.a.description, "Check the diff", "P7 frontmatter description")
    assert_eq(m.b.description, "", "P7 no frontmatter, empty desc")
    assert_eq(m.c.description, "", "P7 missing desc key, empty desc")
    assert_eq(m.c.name, "c", "P7 name stays basename despite frontmatter name")
    assert_true(m.a.path ~= nil and m.b.path ~= nil, "P7 paths carried")
    print("P7 descriptions: OK")
end

-- split_frontmatter bodies
do
    assert_eq(ctx.split_frontmatter("---\ndescription: x\n---\nBody $ARGUMENTS"),
        "Body $ARGUMENTS", "P8 strips block")
    assert_eq(ctx.split_frontmatter("plain body"), "plain body", "P8 no block passthrough")
    assert_eq(ctx.split_frontmatter("---\nunclosed"), "---\nunclosed", "P8 unclosed kept whole")
    assert_eq(ctx.split_frontmatter(nil), "", "P8 nil safe")
    print("P8 split_frontmatter: OK")
end

-- read_prompt_body: normal, missing, cap
do
    reset_prompts()
    write_file(HOME .. "/.tether/prompts/a.md",
        "---\ndescription: x\n---\nHello $ARGUMENTS")
    assert_eq(ctx.read_prompt_body(HOME .. "/.tether/prompts/a.md"),
        "Hello $ARGUMENTS", "P9 body stripped of frontmatter")
    assert_eq(ctx.read_prompt_body(HOME .. "/.tether/prompts/missing.md"),
        nil, "P9 missing file is nil")
    write_file(HOME .. "/.tether/prompts/big.md", string.rep("a", 20 * 1024))
    local big = ctx.read_prompt_body(HOME .. "/.tether/prompts/big.md")
    assert_true(big ~= nil, "P9 big body readable")
    assert_true(has(big, "…(truncated)"), "P9 truncation marker")
    assert_true(#big < 20 * 1024, "P9 big body capped")
    -- utf8-safe cut: multibyte run straddling the boundary survives
    write_file(HOME .. "/.tether/prompts/uni.md",
        string.rep("a", 16 * 1024 - 2) .. "éé tail")
    local uni = ctx.read_prompt_body(HOME .. "/.tether/prompts/uni.md")
    assert_true(uni ~= nil and has(uni, "…(truncated)"), "P9 multibyte capped with marker")
    print("P9 read_prompt_body: OK")
end

os.execute("rm -rf " .. sq(WS))

if failed > 0 then
    print("FAILURES: " .. failed .. " (passed " .. passed .. ")")
    os.exit(1)
end
print("prompts discovery: OK (" .. passed .. " assertions)")
