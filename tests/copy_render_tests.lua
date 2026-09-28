-- tests/copy_render_tests.lua — copy/skills/md_render/footer/keys (split from lua_tests.lua, Phase C).
-- Run: lua tests/copy_render_tests.lua

dofile("tests/helpers.lua")
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
  assert_eq(r[1].name, "last answer", "T75 target 1 is last answer")
  assert_eq(r[1].text, "see:\n```lua\nlocal x = 1\n```", "T75 target 1 text")
  assert_eq(r[2].name, "last tool output", "T75 target 2 is tool output")
  assert_eq(r[2].text, "tool out", "T75 target 2 text")
  assert_eq(r[3].name, "last code block", "T75 target 3 is fenced block")
  assert_eq(r[3].text, "local x = 1", "T75 target 3 content")
  assert_eq(r[4].name, "whole transcript", "T75 target 4 is whole transcript")
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
    if tg.name == "last code block" then fenced = tg end
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
  assert_eq(r3[1].name, "whole transcript", "T75 only target is whole transcript")

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
  assert_true(S.toast ~= nil and S.toast:find("✓ copied", 1, true) == 1,
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
  assert_true(S.toast ~= nil and S.toast:find("✓ copied", 1, true) == 1,
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
  -- add-provider-login: /login /logout; add-reasoning-level: /think → 10 + 2
  local uimod = boot(two_skills)
  type_text(uimod, "/")
  local S = uimod._get_state()
  assert_eq(#S.palette_items, 12, "T79 commands + skills share one list")
  assert_eq(S.palette_items[1].cmd, "clear", "T79 first entry is the first command")
  assert_eq(S.palette_items[10].cmd, "think", "T79 the last command precedes the skills")
  assert_eq(S.palette_items[11].name, "deploy", "T79 first skill follows the commands")
  assert_eq(S.palette_items[12].name, "review", "T79 skills keep discovery order")

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
  assert_eq(#S.palette_items, 11, "T79 a colliding skill is not listed")
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
  assert_eq(#S.palette_items, 10, "T79 discovery failure degrades to commands")
  assert_true(S.palette_active, "T79 the palette survives a discovery failure")

  -- the production path: the host registers modules as globals (main.c
  -- load_module), so discovery is reached without require()
  local orig_context = _G.context
  _G.context = { discover_skills = function() return two_skills() end }
  local real = boot(nil)
  type_text(real, "/")
  S = real._get_state()
  assert_eq(#S.palette_items, 12, "T79 skills resolve through the context global")
  assert_eq(S.palette_items[11].name, "deploy", "T79 the global path lists the skill")
  _G.context = orig_context

  print("T79 unified palette list: OK")
end

-- T80 (4.1 + 3.1): a skill row only composes `/<name> ` into the input —
-- Enter and Tab send nothing, run nothing and never read the body; the row is
-- marked `[s]` in its description and produces no [skill: …] reference.
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
  assert_eq(S.palette_items[1].hint, nil, "T80 skill rows carry no hint")
  assert_eq(S.palette_items[1].desc, "[s] deploy stuff", "T80 the mark rides the description")
  uimod._handle_key({ kind = "enter" })
  S = uimod._get_state()
  assert_eq(S.input, "/deploy ", "T80 Enter composes the skill name")
  assert_eq(S.cursor, #S.input, "T80 cursor at the end of the input")
  assert_false(S.palette_active, "T80 palette closed after Enter")
  assert_eq(turns, 0, "T80 Enter sent nothing to the agent")
  -- the transcript keeps only the startup splash: composition added nothing
  local boot_entries = #tentries(uimod)
  assert_eq(boot_entries, 1, "T80 only the startup splash is present")
  assert_eq(tentries(uimod)[1].role, "splash", "T80 the only entry is the splash")
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
  local e_only_splash = true
  for _, ent in ipairs(tentries(e)) do
    if ent.role ~= "splash" then e_only_splash = false; break end
  end
  assert_true(e_only_splash and #tentries(e) == 1,
    "T81 an unknown name adds no user row (splash only)")

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
  local hl = assert((function() return loadfile("src/tether/ui/highlight.lua")() end)())
  local function kinds(line, lang, state)
    local out = {}
    for _, t in ipairs(hl.tokenize(line, lang, state or {})) do
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
  hl.tokenize("if (1) { /* open", "c", st)
  assert_true(st.bc == true, "T83 c block comment open sets state.bc")
  hl.tokenize(") end */ x", "c", st)
  assert_true(st.bc == nil, "T83 c block comment close clears state.bc")
  assert_true(eqkinds(kinds('{"k": 1, "b": true}', "json"),
    { "plain", "string", "plain", "number", "plain", "string", "plain", "keyword", "plain" }),
    "T83 json kinds")
  local unk = hl.tokenize("whatever", "unknownlang", {})
  assert_eq(#unk, 1, "T83 unknown lang single token")
  assert_eq(unk[1].kind, "plain", "T83 unknown lang kind")
  assert_eq(unk[1].text, "whatever", "T83 unknown lang text")
  -- supported aliases share the canonical tokenizer (case-insensitive)
  assert_true(eqkinds(kinds("var x = 1", "javascript"),
    { "keyword", "plain", "number" }), "T83 javascript alias kinds")
  assert_true(eqkinds(kinds("var x = 1", "JAVASCRIPT"),
    { "keyword", "plain", "number" }), "T83 javascript alias case-insensitive")
  assert_true(eqkinds(kinds("int x = 1", "c++"),
    { "keyword", "plain", "number" }), "T83 c++ alias kinds")
  assert_true(eqkinds(kinds("s = 'v'", "py"),
    { "plain", "string" }), "T83 py alias string")
  -- supported languages with no keyword set: strings and numbers only
  assert_true(eqkinds(kinds("port: 8080", "yaml"),
    { "plain", "number" }), "T83 yaml no-keyword-set number")
  assert_true(eqkinds(kinds('k: "v"', "rb"),
    { "plain", "string" }), "T83 rb no-keyword-set string")
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
  -- the frame may be dim (spec: frame renders dim), but an unknown/absent
  -- language must carry no token-color SGR — only dim (2) / reset (0).
  local function only_frame_sgr(s)
    for seq in s:gmatch("\27%[([0-9;]*)m") do
      if seq ~= "2" and seq ~= "0" and seq ~= "" then return false end
    end
    return true
  end
  ui._color_depth = "256"
  local out = ui.md_render("```zfoobar\nabc\n```", 40)
  assert_true(only_frame_sgr(table.concat(out, "\n")),
    "T86 unknown fence lang: no token SGR")
  assert_true(table.concat(out, "\n"):find("abc", 1, true) ~= nil,
    "T86 unknown fence lang: text present")
  local out2 = ui.md_render("```\nabc\n```", 40)
  assert_true(only_frame_sgr(table.concat(out2, "\n")),
    "T86 absent fence lang: no token SGR")
  -- supported aliases colour tokens inside the frame
  local out_js = ui.md_render("```javascript\nvar x = 1\n```", 40)
  assert_true(not only_frame_sgr(table.concat(out_js, "\n")),
    "T86 javascript alias: token SGR present")
  -- no-keyword-set languages colour string literals
  local out_yaml = ui.md_render("```yaml\nk: \"v\"\n```", 40)
  assert_true(not only_frame_sgr(table.concat(out_yaml, "\n")),
    "T86 yaml: string token SGR present")
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
  local keys = assert(loadfile("src/tether/ui/keys.lua"))()
  local bag = { _byte_stash = {}, _esc_stash_s = nil, _paint_clock = function() return 0 end }
  local function one(seq)
    queue, qi = to_bytes(seq), 0
    return keys.read_key(bag)
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
  local names = {"arg", "tether", "config", "session", "agent", "ui", "context",
    "commands"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local log = {}
  _G.arg = { "--print", "hello" }
  _G.tether = host_mock{ getcwd = function() return "/ws" end, realpath = function(p) return p end,
                is_tty = function() return false end }
  _G.config = { load = function() return { context = {} } end, api_key = function() return "k" end }
  -- providers gate is orthogonal here (its own tests: T198); stub it open.
  _G.commands = { new = function() return "id" end,
    boot_providers = function() return true end }
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

-- T161: add-provider-login — --print rejects interactive /login /logout
-- with a clear error (spec: print mode errors, no interactive flow).
do
  local app = assert(loadfile("src/tether/app.lua"))()
  assert_true(type(app._print_prompt_error) == "function",
    "T161 app exposes _print_prompt_error")
  assert_notnil(app._print_prompt_error("/login"),
    "T161 /login rejected in print mode")
  assert_notnil(app._print_prompt_error("/logout anthropic"),
    "T161 /logout rejected in print mode")
  assert_notnil(app._print_prompt_error("  /login openai"),
    "T161 leading whitespace still rejected")
  assert_eq(app._print_prompt_error("hello login"), nil,
    "T161 normal prompt allowed")
  assert_eq(app._print_prompt_error("/compact now"), nil,
    "T161 other slash commands out of this check's scope")
  assert_eq(app._print_prompt_error(nil), nil,
    "T161 nil prompt is not this error's job")
  print("T161 print rejects /login /logout: OK")
end


if failed > 0 then
    os.exit(1)
end
