-- tests/prompts_palette_tests.lua — prompts-as-commands: prompt rows in the
-- slash palette (list order, [p] marker, pick composes only).
-- Run: lua tests/prompts_palette_tests.lua

dofile("tests/helpers.lua")

local function type_text(uimod, text)
  for i = 1, #text do
    uimod._handle_key({ kind = "text", char = text:sub(i, i) })
  end
end

local function boot(skills_fn, prompts_fn)
  local uimod = run_ui_with({ 17 }, {
    agent = {
      turn = function() return true end,
      get_history = function() return {} end,
    },
  })
  uimod._skills_stub = skills_fn
  uimod._prompts_stub = prompts_fn
  return uimod
end

local no_rows = function() return {} end
local one_skill = function() return {
  { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
} end
local two_prompts = function() return {
  { name = "review", description = "check stuff", path = "/tmp/prompts/review.md" },
  { name = "nodesc", description = "", path = "/tmp/prompts/nodesc.md" },
} end

-- P10: prompts list after skills, [p] marker, bare marker on empty desc
do
  local uimod = boot(one_skill, two_prompts)
  type_text(uimod, "/")
  local S = uimod._get_state()
  local n_cmd = 0
  for _, it in ipairs(S.palette_items) do
    if it.cmd then n_cmd = n_cmd + 1 end
  end
  assert_eq(#S.palette_items, n_cmd + 3, "P10 commands + skill + prompts")
  assert_eq(S.palette_items[n_cmd + 1].name, "deploy", "P10 skill precedes prompts")
  assert_eq(S.palette_items[n_cmd + 2].name, "review", "P10 first prompt in order")
  assert_eq(S.palette_items[n_cmd + 3].name, "nodesc", "P10 second prompt in order")
  assert_eq(S.palette_items[n_cmd + 2].label, "/review", "P10 prompt row is the slash name")
  assert_eq(S.palette_items[n_cmd + 2].desc, "[p] check stuff", "P10 [p] marker with description")
  assert_eq(S.palette_items[n_cmd + 3].desc, "[p] ", "P10 bare marker on empty description")
  print("P10 prompt rows listed: OK")
end

-- P11: filter narrows to the prompt
do
  local uimod = boot(one_skill, two_prompts)
  type_text(uimod, "/rev")
  local S = uimod._get_state()
  assert_eq(#S.palette_items, 1, "P11 /rev narrows to one row")
  assert_eq(S.palette_items[1].name, "review", "P11 the prompt is selected")
  print("P11 prompt filter: OK")
end

-- P12: Enter/Tab on a prompt row only composes, sends nothing, reads no body
do
  local turns = 0
  local uimod = run_ui_with({ 17 }, {
    agent = {
      turn = function() turns = turns + 1; return true end,
      get_history = function() return {} end,
    },
  })
  uimod._skills_stub = one_skill
  uimod._prompts_stub = two_prompts
  type_text(uimod, "/rev")
  uimod._handle_key({ kind = "enter" })
  local S = uimod._get_state()
  assert_eq(S.input, "/review ", "P12 Enter composes the prompt name")
  assert_false(S.palette_active, "P12 palette closed after Enter")
  assert_eq(turns, 0, "P12 Enter sent nothing to the agent")
  assert_eq(#tentries(uimod), 1, "P12 only the startup splash is present")

  local uimod2 = run_ui_with({ 17 }, {
    agent = {
      turn = function() turns = turns + 1; return true end,
      get_history = function() return {} end,
    },
  })
  uimod2._skills_stub = one_skill
  uimod2._prompts_stub = two_prompts
  type_text(uimod2, "/rev")
  uimod2._handle_key({ kind = "tab" })
  assert_eq(uimod2._get_state().input, "/review ", "P12 Tab completes the prompt name")
  assert_eq(turns, 0, "P12 Tab sent nothing either")
  print("P12 prompt pick composes: OK")
end

-- P13: collisions — command wins over prompt; skill and prompt coexist
do
  local uimod = boot(
    function() return {
      { name = "deploy", description = "deploy stuff", path = "/tmp/skills/deploy/SKILL.md" },
    } end,
    function() return {
      { name = "Copy", description = "shadow", path = "/tmp/prompts/Copy.md" },
      { name = "deploy", description = "prompt twin", path = "/tmp/prompts/deploy.md" },
    } end)
  type_text(uimod, "/")
  local S = uimod._get_state()
  local seen_copy_prompt = false
  local deploy_rows = 0
  for _, it in ipairs(S.palette_items) do
    if it.prompt and (it.name or ""):lower() == "copy" then seen_copy_prompt = true end
    if (it.name or ""):lower() == "deploy" then deploy_rows = deploy_rows + 1 end
  end
  assert_false(seen_copy_prompt, "P13 command-colliding prompt not listed")
  assert_eq(deploy_rows, 2, "P13 skill and prompt twins both listed")
  print("P13 prompt collisions: OK")
end

-- P14: once per open; failure degrades to commands+skills
do
  local calls = 0
  local uimod = boot(one_skill, function()
    calls = calls + 1
    return two_prompts()
  end)
  type_text(uimod, "/")
  type_text(uimod, "re")
  assert_eq(calls, 1, "P14 discovery resolved once per open")
  uimod._handle_key({ kind = "esc" })
  type_text(uimod, "/")
  assert_eq(calls, 2, "P14 a new open resolves again")

  local broken = boot(one_skill, function() error("prompts exploded") end)
  type_text(broken, "/")
  local S = broken._get_state()
  assert_true(S.palette_active, "P14 palette survives prompts failure")
  local prompt_rows = 0
  for _, it in ipairs(S.palette_items) do
    if it.prompt then prompt_rows = prompt_rows + 1 end
  end
  assert_eq(prompt_rows, 0, "P14 no prompt rows on failure")
  print("P14 prompt discovery lifecycle: OK")
end

-- P15-P21: submit-time expansion (4.1 word pattern + 4.2 expand).
-- Prompt bodies live in real temp files; the stub rows point at them.
do
  local sent, turns = {}, 0
  local orig_agent = _G.agent
  local agent_stub = {
    turn = function(cfg, key, text) turns = turns + 1; sent[#sent + 1] = text; return true end,
    get_history = function() return {} end,
  }
  local pdir = os.tmpname()
  os.remove(pdir)
  os.execute("mkdir -p '" .. pdir:gsub("'", "'\\''") .. "'")
  local function pfile(name, content)
    local f = assert(io.open(pdir .. "/" .. name, "w"))
    f:write(content)
    f:close()
    return pdir .. "/" .. name
  end
  local review_path = pfile("review.md", "Check this: $ARGUMENTS")
  local static_path = pfile("static.md", "Static body")
  local multi_path = pfile("multi.md", "A $ARGUMENTS B $ARGUMENTS")
  local pass_path = pfile("pass.md", "$1 !`git log` @src/x.lua")
  local kebab_path = pfile("my-check.md", "Kebab: $ARGUMENTS")
  local twin_path = pfile("twin.md", "Twin: $ARGUMENTS")
  local prompts_fn = function() return {
    { name = "review", description = "r", path = review_path, prompt = true },
    { name = "static", description = "", path = static_path, prompt = true },
    { name = "multi", description = "", path = multi_path, prompt = true },
    { name = "pass", description = "", path = pass_path, prompt = true },
    { name = "my-check", description = "", path = kebab_path, prompt = true },
    { name = "twin", description = "", path = twin_path, prompt = true },
    { name = "gone", description = "", path = pdir .. "/gone.md", prompt = true },
  } end
  local function boot_submit(skills)
    local uimod = run_ui_with({ 17 }, { agent = agent_stub })
    uimod._skills_stub = skills or function() return {} end
    uimod._prompts_stub = prompts_fn
    _G.agent = agent_stub
    return uimod
  end
  local function submit(uimod, text)
    for i = 1, #text do
      uimod._handle_key({ kind = "text", char = text:sub(i, i) })
    end
    uimod._handle_key({ kind = "enter" })
  end
  local function user_rows(uimod)
    local out = {}
    for _, ent in ipairs(tentries(uimod)) do
      if ent.role == "user" then out[#out + 1] = ent.text end
    end
    return out
  end

  -- P15: expansion with args
  local a = boot_submit()
  submit(a, "/review fix login")
  assert_eq(turns, 1, "P15 prompt turn runs")
  assert_eq(sent[1], "Check this: fix login", "P15 $ARGUMENTS replaced")
  local rows_a = user_rows(a)
  assert_eq(rows_a[#rows_a], "Check this: fix login", "P15 transcript carries expanded text")
  assert_eq(a._get_state().input, "", "P15 input cleared after send")

  -- P16: empty args -> empty replacement; no-placeholder drops args
  local b = boot_submit()
  submit(b, "/review ")
  assert_eq(sent[2], "Check this: ", "P16 empty args empty the placeholder")
  local c = boot_submit()
  submit(c, "/static extra words")
  assert_eq(sent[3], "Static body", "P16 args dropped without placeholder")

  -- P17: multi-occurrence, passthrough of $1/shell/@
  local d = boot_submit()
  submit(d, "/multi hi")
  assert_eq(sent[4], "A hi B hi", "P17 every occurrence replaced")
  local e = boot_submit()
  submit(e, "/pass z")
  assert_eq(sent[5], "$1 !`git log` @src/x.lua", "P17 no shell/file/positional expansion")

  -- P18: kebab-case name routes (4.1 widened word pattern)
  local f = boot_submit()
  submit(f, "/my-check hi")
  assert_eq(sent[6], "Kebab: hi", "P18 hyphenated prompt expands")

  -- P19: hyphenated skill still falls through verbatim
  local g = boot_submit(function() return { { name = "my-skill" } } end)
  submit(g, "/my-skill hi")
  assert_eq(sent[7], "/my-skill hi", "P19 hyphenated skill sent verbatim")

  -- P20: "/- ..." keeps the legacy plain-message path
  local h = boot_submit()
  submit(h, "/- foo")
  assert_eq(sent[8], "/- foo", "P20 dash-only input sent as plain message")

  -- P21: unreadable file -> banner, input preserved, nothing sent
  local before = turns
  local k = boot_submit()
  submit(k, "/gone hi")
  assert_eq(turns, before, "P21 no turn on read failure")
  assert_eq(k._get_state().input, "/gone hi", "P21 input preserved on failure")
  assert_true((k._get_state().error_banner or "") ~= "", "P21 error banner shown")

  -- P22: case does not matter for a prompt name at submit time
  local m = boot_submit()
  submit(m, "/Review fix")
  assert_eq(sent[#sent], "Check this: fix", "P22 case-variant prompt expands")

  -- P23: prompt shadows skill on submit when names collide
  local n = boot_submit(function() return { { name = "twin" } } end)
  submit(n, "/twin go")
  assert_eq(sent[#sent], "Twin: go", "P23 prompt twin wins over the skill")

  os.execute("rm -rf '" .. pdir:gsub("'", "'\\''") .. "'")
  _G.agent = orig_agent
  print("P15-P23 prompt submit: OK")
end

if failed > 0 then
  print("FAILURES: " .. failed .. " (passed " .. passed .. ")")
  os.exit(1)
end
print("prompts palette: OK (" .. passed .. " assertions)")
