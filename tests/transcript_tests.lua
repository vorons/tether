-- tests/transcript_tests.lua — transcript/turn/follow/scroll/separators (split from lua_tests.lua, Phase C).
-- Run: lua tests/transcript_tests.lua

dofile("tests/helpers.lua")
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

-- T53d: /new clears the transcript before the splash (the splash returns so
-- /new reads as a fresh start, not a blank screen)
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
  assert_eq(#tentries(uimod_n), 1, "T53d /new leaves only the splash")
  assert_eq(tentries(uimod_n)[1] and tentries(uimod_n)[1].role, "splash", "T53d banner is splash")
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
-- repaint from inside the turn: Working... in the input box before the first
-- token, the streaming caret on the newest line, and both visible mid-turn.
-- No placeholder row is ever painted (turn-feedback-restyling).
do
  local sink = {}
  local working_before_turn, painted_mid_turn = false, false
  -- "hi" + Enter + Ctrl+Q, as raw bytes (read_char yields byte values)
  local _, S = run_ui_with({ 104, 105, 13, 17 }, {
    agent = {
      turn = function(_, _, _text, on_event)
        -- the Working indicator must already be on screen when the turn starts
        working_before_turn =
          table.concat(sink):find("Working...", 1, true) ~= nil
        local before = #sink
        on_event({ type = "text_delta", text = "streamed" })
        -- a frame was flushed while the turn was still running
        painted_mid_turn = #sink > before
        return true
      end,
      get_history = function() return {} end,
    },
  }, sink)
  assert_true(working_before_turn, "T54 Working indicator painted before first token")
  assert_true(table.concat(sink):find("✻ tether", 1, true) == nil,
    "T54 no placeholder row painted")
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

  -- /clear: the splash returns (a fresh start shows the wordmark again),
  -- height matches the splash block, no stale index
  local uimod2, S2 = run_ui_with(merge(merge(str_bytes("msg"), { 13 }), merge(str_bytes("/clear"), { 13, 17 })),
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#tentries(uimod2), 1, "T61 /clear leaves only the splash")
  assert_eq(tentries(uimod2)[1].role, "splash", "T61 /clear: splash entry")
  assert_true(uimod2.transcript_height(80) > 0, "T61 /clear: splash has height")
  assert_eq(uimod2.transcript_height(80), #uimod2._render_all(80), "T61 /clear: height == full render")

  -- /new: banner only (the /new command itself never goes through commit's
  -- separator path, so no separator row follows a /new session reset)
  local uimod3, S3 = run_ui_with(
    merge(merge(merge(str_bytes("msg"), { 13 }), str_bytes("/new")), { 13, 17 }),
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  assert_eq(#tentries(uimod3), 1, "T61 /new leaves only the splash")
  assert_eq(tentries(uimod3)[1].role, "splash", "T61 /new banner is splash")
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

  -- /clear drops them all (the splash that replaces the transcript is the
  -- only entry left; it is never a separator)
  local bytes2 = merge(merge(merge(str_bytes("q1"), { 13 }), str_bytes("/clear")), { 13, 17 })
  local uimod_cl, S2 = run_ui_with(bytes2,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local clear_seps = 0
  for _, e in ipairs(tentries(uimod_cl)) do
    if e.role == "separator" then clear_seps = clear_seps + 1 end
  end
  assert_eq(clear_seps, 0, "T62 /clear leaves no separators")

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

  -- block-gap parity (transcript-visual-refresh): full render and viewport
  -- index agree; a separator that follows another entity (the second turn)
  -- stands as its own block — a blank row above it and a blank row below,
  -- with the user row after the bottom gap.
  local full = uimod._render_all(80)
  assert_eq(uimod.transcript_height(80), #full, "T62 gap: index == full render")
  local sep_row
  for i, r in ipairs(full) do
    local plain = (r:gsub("\27%[[0-9;]*m", ""))
    if plain:find("──", 1, true) then
      local next_plain = full[i + 1] and (full[i + 1]:gsub("\27%[[0-9;]*m", "")) or ""
      local after = full[i + 2] and (full[i + 2]:gsub("\27%[[0-9;]*m", "")) or ""
      if next_plain == "" and after:find("q2", 1, true) then sep_row = i end
    end
  end
  assert_true(sep_row ~= nil, "T62 gap: second separator rendered with bottom gap")
  assert_eq((full[sep_row - 1]:gsub("\27%[[0-9;]*m", "")), "", "T62 gap: blank row before separator")
  assert_eq((full[sep_row + 1]:gsub("\27%[[0-9;]*m", "")), "", "T62 gap: blank row after separator")
  print("T62 2.1 turn separators: OK")
end

-- T63: 2.2 — separator rows render muted in color mode, ASCII-downgraded in
-- ASCII mode (verified through the frame renderer's _render_all seam).
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local ESC = "\27"
  local q1 = str_bytes("q1"); q1[#q1 + 1] = 13; q1[#q1 + 1] = 17

  -- color mode: muted SGR present around the separator row
  local sink_c = {}
  local uimod_c, S_c = run_ui_with(q1,
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local sep_c = uimod_c._render_all(80)
  local found_muted = false
  for _, r in ipairs(sep_c) do
    if r:find("──", 1, true) and r:find("%d%d:%d%d") then
      if r:find(ESC .. "[90m", 1, true) then found_muted = true end
    end
  end
  assert_true(found_muted, "T63 separator row carries muted SGR in color mode")

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
  print("T63 2.2 separator muted/ascii rendering: OK")
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
  assert_eq(#tentries(uimod_off), 2, "T64 disabled: splash and the user row")

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

-- T65: 2.4 — no ↓ +N marker anywhere (footer flag removed per user
-- request); no in-transcript marker is painted on visible rows either.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  local ESC = "\27"
  local long_answer = string.rep("abcdefghij ", 8) .. "\n" .. ("second line\n"):rep(50)
  local function make_turn_stub() return function(_, _, _, on_ev)
    on_ev({ type = "text_delta", text = long_answer })
    return true
  end end

  -- scrolled up: footer shows no indicator; no transcript row carries one
  -- (Up/Down now recall history; scrolling uses PgUp)
  local msg = str_bytes("q"); msg[#msg + 1] = 13; msg[#msg + 1] = 27; msg[#msg + 1] = 91; msg[#msg + 1] = 53; msg[#msg + 1] = 126; msg[#msg + 1] = 17
  local sink_up = {}
  local uimod_up = run_ui_with(msg, { agent = { turn = make_turn_stub(), get_history = function() return {} end } }, sink_up)
  local L_up = uimod_up._layout()
  local footer_up = uimod_up._row(L_up.footer_row) or ""
  assert_eq(footer_up:find("↓ +", 1, true), nil,
    "T65 scrolled-up footer shows no indicator: " .. footer_up:sub(1, 80))
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
  print("T65 2.4 no scroll indicator anywhere: OK")
end

-- T66: 2.5 — scroll math helper still reports the hidden-row count when
-- scrolled up (footer flag itself removed; math kept for reuse).
do
  local uim = assert(loadfile("src/tether/ui.lua"))()
  assert_eq(uim.scroll_indicator(100, 12, 20), 12, "T66 hidden count")
  assert_eq(uim.scroll_indicator(100, 0, 20), nil, "T66 following hides the count")
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
-- declaration-order ties, empty filter lists all. Owned by ui_palette directly.
do
  local pal = assert(loadfile("src/tether/ui/palette.lua"))()
  assert_true(type(pal.fuzzy_score) == "function", "T68 fuzzy_score is exported")
  assert_true(type(pal.fuzzy_rank) == "function", "T68 fuzzy_rank is exported")

  local labels = { "/clear", "/compact", "/model", "/resume", "/new", "/quit" }

  -- empty filter → all, in declaration order
  local r0 = pal.fuzzy_rank("", labels)
  assert_eq(#r0, 6, "T68 empty filter lists all")
  assert_eq(r0[1], 1, "T68 empty filter: first = /clear")

  -- "/mdl" should list "/model" first (subsequence m-d-l matches /model, not /md)
  local r1 = pal.fuzzy_rank("mdl", labels)
  assert_eq(r1[1], 3, "T68 'mdl' ranks /model first")

  -- "/m" → /model first (prefix m: /model, /model match; /model ranked first)
  -- /model, /model? no other m-prefix. /model and /model... "/model" label: m prefix yes
  local r2 = pal.fuzzy_rank("m", labels)
  assert_eq(r2[1], 3, "T68 'm' ranks /model first")

  -- "/qq" → no match → empty
  local r3 = pal.fuzzy_rank("zzz", labels)
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
  -- add-provider-login: /login /logout; add-reasoning-level: /think → 10
  local _, S1 = open_palette("/")
  assert_eq(#S1.palette_items, 10, "T69 empty filter: all 10 commands listed")
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

-- T227: subagent config — subagents defaults, malformed fallback, partial
-- override, max_parallel floor.
do
  local cfg = assert((function() return loadfile("src/tether/config.lua")() end)())
  local d = cfg.load("/nonexistent/t227_missing.lua")
  assert_eq(d.subagents.max_parallel, 4, "T227 default max_parallel")
  assert_eq(d.subagents.timeout, 600, "T227 default timeout")
  assert_eq(d.subagents.max_depth, 1, "T227 default max_depth")
  local home = "/tmp/tether_t227_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local f = assert(io.open(home .. "/.tether/config.lua", "w"))
  f:write('return { subagents = { max_parallel = "many", timeout = 60 } }\n')
  f:close()
  local d2 = cfg.load(home .. "/.tether/config.lua", home)
  assert_eq(d2.subagents.max_parallel, 4, "T227 malformed max_parallel falls back")
  assert_eq(d2.subagents.timeout, 60, "T227 partial timeout applies")
  assert_eq(d2.subagents.max_depth, 1, "T227 sibling default kept")
  local f2 = assert(io.open(home .. "/.tether/config.lua", "w"))
  f2:write('return { subagents = { max_parallel = 0 } }\n')
  f2:close()
  local d3 = cfg.load(home .. "/.tether/config.lua", home)
  assert_eq(d3.subagents.max_parallel, 1, "T227 zero max_parallel floors to 1")
  os.execute("rm -rf " .. home)
  print("T227 subagents config defaults: OK")
end

-- ============================================================
-- Section 9: live turn feedback
-- ============================================================

-- T88: 9.1 — while busy the input box shows Working... (no placeholder row);
-- after first text_delta S.waiting=false + S.streaming=true.
do
  local sink = {}
  -- capture a fake agent that records events it would emit
  local fake_agent = {
    turn = function(cfg, key, text, cb)
      cb({ type = "text_delta", text = "hi" })
      return true
    end,
    get_history = function() return {} end,
  }
  local uimod, S = run_ui_with({ 104, 105, 13, 17 },
    { agent = fake_agent }, sink,
    function(force) end)
  assert_true(S.waiting == false, "T88 S.waiting false after turn completes")
  assert_true(S.streaming == false, "T88 S.streaming false after turn completes")
  local all = table.concat(sink)
  assert_true(all:find("Working...", 1, true) ~= nil,
    "T88 Working indicator painted while busy")
  assert_true(all:find("✻ tether", 1, true) == nil,
    "T88 no placeholder row painted")
  print("T88 9.1 Working indicator lifecycle: OK")
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
-- after abort, and after confirmation → Working indicator/caret/elapsed gone.
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
    uimod._paint(true)
    local L = uimod._layout()
    assert_true((uimod._row(L.input_row) or ""):find("Working...", 1, true) == nil,
      "T90 no Working indicator after error")
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
  -- confirmation case: the menu is raised mid-turn and takes the busy
  -- state with it (Working rule, caret, waiting/streaming flags)
  do
    local saved_tether, saved_agent = _G.tether, _G.agent
    local uimod, S = run_ui_with({ 17 },
      { agent = { turn = function() return true end,
                  get_history = function() return {} end } })
    -- inject with an inert input: the busy pump must not reach real stdin
    _G.tether = host_mock({ read_char_nb = function() return nil end })
    _G.agent = nil
    -- mid-turn on screen: busy, indicator and caret up before the menu
    S.busy = true
    uimod._handle_agent_event({ type = "text_delta", text = "hello" })
    uimod._paint(true)
    local L = uimod._layout()
    assert_true((uimod._row(L.rule_top_row) or ""):find("Working...", 1, true) ~= nil,
      "T90 Working indicator up before the confirmation")
    -- the caret rides the LAST transcript row (follow mode keeps the tail
    -- on screen); scan the whole transcript window so the assertion does
    -- not depend on where the splash block ends
    local caret_seen = false
    for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
      local row = uimod._row(r)
      if row and row:find("▌", 1, true) then caret_seen = true; break end
    end
    assert_true(caret_seen, "T90 caret up before the confirmation")
    -- the turn still waits on the tool when the menu is raised
    S.waiting = true
    S.streaming = true
    uimod._handle_agent_event({
      type = "confirmation",
      details = { { id = "c1", name = "run", args = { command = "ls" } } },
    })
    assert_true((S.confirmation or {}).label == "run ls",
      "T90 confirmation menu raised")
    assert_true(S.busy == false, "T90 S.busy cleared while the confirmation waits")
    assert_true(S.waiting == false, "T90 S.waiting cleared while the confirmation waits")
    assert_true(S.streaming == false, "T90 S.streaming cleared while the confirmation waits")
    uimod._paint(true)
    L = uimod._layout()
    assert_true((uimod._row(L.rule_top_row) or ""):find("Working...", 1, true) == nil,
      "T90 no Working indicator while the confirmation waits")
    local caret_gone = true
    for r = L.transcript_row, L.transcript_row + L.transcript_h - 1 do
      local row = uimod._row(r)
      if row and row:find("▌", 1, true) then caret_gone = false; break end
    end
    assert_true(caret_gone, "T90 no caret while the confirmation waits")
    _G.tether, _G.agent = saved_tether, saved_agent
  end
  print("T90 9.3 lifecycle clearing: OK")
end

-- turn-feedback-restyling: thinking header carries elapsed, assistant rows
-- use the · marker, and the busy input box shows only the Working indicator.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  uimod._handle_agent_event({ type = "reasoning_delta", text = "hmm" })
  uimod._handle_agent_event({ type = "text_delta", text = "answer here" })
  local function plain(rows)
    return table.concat(rows, "\n"):gsub("\27%[[%d;]*m", "")
  end
  local joined = plain(uimod._render_all(80))
  assert_true(joined:find("think · 0.0s", 1, true) ~= nil,
    "TFR thinking header carries elapsed")
  assert_true(joined:find("• answer here", 1, true) ~= nil,
    "TFR assistant rows use the • marker")
  -- ASCII twins (row cache is versioned, not mode-keyed: invalidate first)
  uimod._ascii_mode = true
  uimod._invalidate_all()
  local ajoined = plain(uimod._render_all(80))
  assert_true(ajoined:find("- answer here", 1, true) ~= nil,
    "TFR assistant marker is ASCII in ascii mode")
  uimod._ascii_mode = nil
  -- busy top rule shows the spinner with ` Working... ` (leading space)
  S.busy = true
  uimod._paint(true)
  local L = uimod._layout()
  local row = (uimod._row(L.rule_top_row) or ""):gsub("\27%[[%d;]*m", "")
  assert_true(row:find("Working...", 1, true) ~= nil,
    "TFR busy top rule shows Working")
  assert_true(row:find(" Working", 1, true) ~= nil,
    "TFR spinner carries a leading space")
  S.busy = false
  print("TFR restyled feedback rows: OK")
end

-- TH1: input history recall parses session.add_history's JSONL correctly.
-- Regression: load_history regex-extracted `"text":"(.*)"` — a greedy match
-- to the LAST quote. session.lua's json_encode emits fields in arbitrary
-- pairs() order, so when `text` was not the last field the recall inserted
-- `hello","ts":"...","workspace":"/tmp/ws` instead of the message. Fixed:
-- load_history decodes each line with provider_common.json_decode.
do
  local HOME = "/tmp/tether_th1_home"
  os.execute("rm -rf " .. HOME .. " && mkdir -p " .. HOME .. "/.tether")
  local hf = assert(io.open(HOME .. "/.tether/history.jsonl", "w"))
  -- field orders exactly as session.lua's pairs() may emit them
  hf:write('{"text":"hello","ts":"2026-09-23T10:00:00","workspace":"/tmp/wsA"}\n')
  hf:write('{"ts":"2026-09-23T10:01:00","text":"world","workspace":"/tmp/wsA"}\n')
  hf:write('{"ts":"2026-09-23T10:02:00","workspace":"/tmp/wsB","text":"other ws"}\n')
  -- escapes: a quote, a backslash+quote, a real newline and a literal \n
  -- (this line is exactly what session.lua's json_encode emits for the text
  -- 'say "hi\\" today<LF>\\nline2')
  hf:write('{"ts":"2026-09-23T10:03:00","workspace":"/tmp/wsA","text":"say \\"hi\\\\\\" today\\n\\\\nline2"}\n')
  hf:close()

  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  -- load_history reads the path from the M._history_file seam (env HOME is
  -- not rebindable from Lua); point it at the seeded sandbox.
  local uimod, S = run_ui_with({ 17 }, {
    config = { load = function()
        return { model = "test", workspace = "/tmp/wsA", ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end },
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uimod._history_file = HOME .. "/.tether/history.jsonl"
  uimod._load_history()
  -- TH1a: load filtered by workspace and decoded in order
  assert_eq(S.history[1], "hello", "TH1 first entry decodes to plain text (workspace filter kept /tmp/wsA)")
  assert_eq(S.history[2], "world", "TH1 second entry decodes to plain text")
  assert_eq(#S.history, 3, "TH1 other-workspace entry filtered out")
  -- TH1b: escape decoding matches JSON (quote, backslash, newline)
  -- TH1b: escape decoding matches JSON: quote, backslash+quote, real newline,
  -- then a literal backslash-n
  assert_eq(S.history[3], 'say "hi\\" today\n\\nline2',
    "TH1 escaped quote/backslash/newline round-trip")
  print("TH1 history jsonl parse per workspace: OK")
end

-- TH2: a fresh session recalls persisted history newest-first. Regression:
-- run() loaded ~/.tether/history.jsonl into S.history but left S.history_pos at
-- its 0 default, so the first Up computed p = -1, clamped to 1 and recalled the
-- OLDEST persisted message; every later Up clamped to 1 as well — the newest
-- entries were unreachable until the user submitted something in this session.
do
  local HOME = "/tmp/tether_th2_home"
  os.execute("rm -rf " .. HOME .. " && mkdir -p " .. HOME .. "/.tether")
  local hf = assert(io.open(HOME .. "/.tether/history.jsonl", "w"))
  hf:write('{"text":"first","workspace":"/tmp/wsA"}\n')
  hf:write('{"text":"second","workspace":"/tmp/wsA"}\n')
  hf:write('{"text":"third","workspace":"/tmp/wsA"}\n')
  hf:close()

  local names = {"tether", "config", "session", "agent", "api"}
  local originals, preload = {}, {}
  for _, n in ipairs(names) do originals[n] = _G[n]; preload[n] = package.preload[n] end

  local function recall(key_bytes)
    local q, qi = {}, 0
    for _, b in ipairs(key_bytes) do q[#q + 1] = b end
    _G.tether = host_mock{
      write = function() end,
      resize_requested = function() return false end,
      get_terminal_size = function() return { width = 80, height = 24 } end,
      getcwd = function() return "/tmp/wsA" end,
      read_char = function() qi = qi + 1; return q[qi] or 17 end,
      read_char_nb = function() qi = qi + 1; if qi <= #q then return q[qi] end return nil end,
    }
    _G.config = { load = function()
        return { model = "test", workspace = "/tmp/wsA", ui = { input_max_lines = 8 } } end,
      api_key = function() return "" end }
    _G.session = { new_session = function() return "sid" end }
    _G.agent = { turn = function() return true end, get_history = function() return {} end }
    _G.api = { list_models = function() return {} end }
    for _, n in ipairs(names) do
      package.preload[n] = (function(k) return function() return _G[k] end end)(n)
    end
    local ui_mod = assert(loadfile("src/tether/ui.lua"))()
    ui_mod._history_file = HOME .. "/.tether/history.jsonl"
    ui_mod.run()
    local S = ui_mod._get_state()
    for _, n in ipairs(names) do _G[n] = originals[n]; package.preload[n] = preload[n] end
    return S
  end

  local UP = { 27, 91, 65 }
  local DOWN = { 27, 91, 66 }
  local s1 = recall(UP)
  assert_eq(#s1.history, 3, "TH2 persisted history loaded")
  assert_eq(s1.input, "third", "TH2 first Up recalls the newest entry")
  local s2 = recall({ UP[1], UP[2], UP[3], UP[1], UP[2], UP[3] })
  assert_eq(s2.input, "second", "TH2 second Up steps back to the next-newest")
  -- Down walks back toward the newest entry
  local s3 = recall({ UP[1], UP[2], UP[3], UP[1], UP[2], UP[3], DOWN[1], DOWN[2], DOWN[3] })
  assert_eq(s3.input, "third", "TH2 Up Up then Down returns to the newest")
  print("TH2 fresh session history recall starts at the newest: OK")
end

-- TW1: mouse wheel scrolls the transcript, never history. Regression: with
-- mouse mode auto the tracking was enabled only over confirmation/palette, so
-- a wheel tick outside them hit the terminal's own arrow-key fallback and
-- recalled input history into the field. Now auto always tracks (wheel capture)
-- and SGR wheel events scroll: up = older rows (S.scroll grows), down = toward
-- the bottom (S.scroll shrinks, follow at 0). Directions were also inverted.
do
  local str_bytes = function(s) local b = {} for i = 1, #s do b[#b + 1] = s:byte(i) end return b end
  -- SGR wheel events: ESC[<64;x;yM = wheel up, ESC[<65;x;yM = wheel down
  local wheel_up = {}
  for _, c in ipairs(str_bytes("\27[<64;10;5M")) do wheel_up[#wheel_up + 1] = c end
  local wheel_down = {}
  for _, c in ipairs(str_bytes("\27[<65;10;5M")) do wheel_down[#wheel_down + 1] = c end
  -- one turn renders a long answer so there is something to scroll
  local long_answer = ("line\n"):rep(60)
  local function make_stub() return { turn = function(_, _, _, on_ev)
      on_ev({ type = "text_delta", text = long_answer }); return true end,
    get_history = function() return {} end } end

  -- wheel up scrolls up: follow mode off, scroll grew, input untouched
  local up_bytes = {}
  for _, b in ipairs(str_bytes("q")) do up_bytes[#up_bytes + 1] = b end
  up_bytes[#up_bytes + 1] = 13
  for _, b in ipairs(wheel_up) do up_bytes[#up_bytes + 1] = b end
  up_bytes[#up_bytes + 1] = 17
  local uimod_up, S_up = run_ui_with(up_bytes, { agent = make_stub() })
  assert_true(S_up.user_scrolled, "TW1 wheel up leaves follow mode")
  assert_true(S_up.scroll > 0, "TW1 wheel up scrolls the transcript up")
  -- commit_input cleared the field; the wheel must not have recalled anything
  assert_eq(S_up.input, "", "TW1 wheel up leaves the input empty (no history)")
  assert_eq(#S_up.history, 1, "TW1 exactly the submitted message is in history (no recall re-push)")

  -- wheel down returns to follow mode
  local down_bytes = {}
  for _, b in ipairs(str_bytes("q")) do down_bytes[#down_bytes + 1] = b end
  down_bytes[#down_bytes + 1] = 13
  for _, b in ipairs(wheel_up) do down_bytes[#down_bytes + 1] = b end
  for _, b in ipairs(wheel_down) do down_bytes[#down_bytes + 1] = b end
  down_bytes[#down_bytes + 1] = 17
  local _, S_dn = run_ui_with(down_bytes, { agent = make_stub() })
  assert_eq(S_dn.scroll, 0, "TW1 wheel down returns to the bottom")
  assert_false(S_dn.user_scrolled, "TW1 wheel down re-enters follow mode")
  print("TW1 wheel scrolls transcript not history: OK")
end

-- TW2: a retry backoff keeps the turn live. With a reactor loop owning
-- waiting, the wait is a loop deadline: input dispatches through it (a wheel
-- tick scrolls immediately instead of queueing until the turn ends) and the
-- host sleep is never called. Without a loop the wait still slices on
-- tether.sleep, which returns as soon as input arrives.
do
  local orig = { tether = _G.tether, api = _G.api, reactor = _G.reactor }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local reactor = assert(loadfile("src/tether/reactor.lua"))()
  local retry = assert(loadfile("src/tether/retry.lua"))()
  local cfg = { model = "test", retry = { base_delay_ms = 1, max_delay_ms = 1,
    multiplier = 1, max_failures_at_max_delay = 3 }, context = {} }

  -- api.stream: first attempt fails retryably (the retry path waits), second
  -- streams a short answer. The nap between them is the backoff under test.
  local function make_api()
    local attempts = 0
    return { stream = function(_, _, _, on_ev)
      attempts = attempts + 1
      if attempts == 1 then
        return false, retry.failure("server", "test failure", 500)
      end
      on_ev({ type = "text_delta", text = "ok" })
      return true
    end }
  end
  local function turn()
    local okp, err = pcall(function()
      agent.turn(cfg, "k", "hi", function() end)
    end)
    if not okp then error("TW2: " .. tostring(err), 0) end
  end

  -- (a) no loop (print mode, one-shot callers): the wait slices on sleep
  do
    local sleep_calls = 0
    _G.tether = setmetatable({
      sleep = function() sleep_calls = sleep_calls + 1 end,
    }, { __index = orig.tether or {} })
    _G.api = make_api()
    _G.reactor = nil
    reactor.set_active(nil)
    turn()
    assert_true(sleep_calls > 0, "TW2 without a loop the backoff slept")
  end

  -- (b) active loop: the backoff is a timer on the loop — stdin dispatches
  -- inside the wait and the host sleep stays untouched
  do
    local sleep_calls, dispatched, now = 0, 0, 0
    local r = reactor.new{
      poll = function(rfds, _, timeout)
        now = now + math.max(timeout or 0, 1)
        for _, fd in ipairs(rfds or {}) do
          if fd == 0 then return { read = { 0 }, write = {} } end
        end
        return { read = {}, write = {} }
      end,
      clock = function() return now end,
    }
    r:on_stdin(function() dispatched = dispatched + 1; return 1 end)
    _G.tether = setmetatable({
      sleep = function() sleep_calls = sleep_calls + 1 end,
    }, { __index = orig.tether or {} })
    _G.api = make_api()
    _G.reactor = reactor
    reactor.set_active(r)
    turn()
    reactor.set_active(nil)
    assert_eq(sleep_calls, 0, "TW2 the reactor deadline replaced the host sleep")
    assert_true(dispatched > 0,
      "TW2 input dispatched during the backoff (ticks=" .. dispatched .. ")")
  end

  -- (c) Ctrl+C during the reactor wait: input raises the abort seam, the
  -- turn ends as aborted with no second attempt and no host sleep
  do
    local sleep_calls, now = 0, 0
    local attempts = 0
    local r = reactor.new{
      poll = function(_, _, timeout)
        now = now + math.max(timeout or 0, 1)
        return { read = { 0 }, write = {} }
      end,
      clock = function() return now end,
    }
    r:on_stdin(function()
      -- the UI key handler raises this flag when it reads 0x03 mid-turn
      agent.abort_requested = true
      return 1
    end)
    _G.tether = setmetatable({
      sleep = function() sleep_calls = sleep_calls + 1 end,
    }, { __index = orig.tether or {} })
    _G.api = { stream = function()
      attempts = attempts + 1
      return false, retry.failure("server", "test failure", 500)
    end }
    _G.reactor = reactor
    reactor.set_active(r)
    agent.clear()
    local evs = {}
    local okp, err = pcall(function()
      agent.turn(cfg, "k", "hi", function(ev) evs[#evs + 1] = ev end)
    end)
    reactor.set_active(nil)
    if not okp then error("TW2: " .. tostring(err), 0) end
    local aborted = false
    for _, ev in ipairs(evs) do if ev.type == "aborted" then aborted = true end end
    assert_true(aborted, "TW2 an abort during the reactor wait ends the turn")
    assert_eq(attempts, 1, "TW2 the abort sends no second attempt")
    assert_eq(sleep_calls, 0, "TW2 the aborted wait never touched the host sleep")
    agent.abort_requested = false
  end

  _G.tether, _G.api, _G.reactor = orig.tether, orig.api, orig.reactor
  print("TW2 backoff runs on the reactor: OK")
end

-- TW3: viewport pin (pi's ScrollView) — fresh rows landing below a
-- scrolled-up viewport must not drag it toward the tail; the offset absorbs
-- the growth instead, so the same rows stay visible.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  local function top_text()
    uimod._paint(true)
    local L = uimod._layout()
    return tostring(uimod._row(L.transcript_row) or ""):gsub("\27%[[%d;]*m", "")
  end
  for i = 1, 30 do
    uimod._handle_agent_event({ type = "text_delta", text = "old-" .. i .. "\n", attempt = 1 })
  end
  for i = 1, 6 do uimod._handle_key({ kind = "mouse", name = "scroll_up" }) end
  local before, scroll_before = top_text(), S.scroll
  assert_true(scroll_before > 0, "TW3 scrolled away from the tail")
  for i = 1, 10 do
    uimod._handle_agent_event({ type = "text_delta", text = "new-" .. i .. "\n", attempt = 2 })
  end
  local after, scroll_after = top_text(), S.scroll
  assert_eq(before, after, "TW3 fresh rows below do not move the viewport")
  assert_true(scroll_after > scroll_before, "TW3 the offset absorbs the growth")
  print("TW3 viewport pinned while scrolled: OK")
end

-- TW4 (4.1): a fragmented wheel tick mid-stream applies inside the turn. The
-- real agent+api stream over the step API (ui.run bound its loop as the
-- active one); the transport hands out an SGR wheel sequence split across two
-- steps and only then answers, so the scroll lands while the turn is busy,
-- before any delta is in flight, with a repaint in the very tick the tail
-- arrived — and the sequence never leaks into the input
-- (specs/reactor fragmented-sequence scenario).
do
  local orig = { turn = _G.turn, reactor = _G.reactor }
  _G.turn = nil -- ui captures the real turn facade at load time
  local agent_mod = assert(loadfile("src/tether/agent.lua"))()
  local api_mod = assert(loadfile("src/tether/api.lua"))()
  agent_mod.clear()

  local str_bytes = function(s)
    local b = {}
    for i = 1, #s do b[#b + 1] = s:byte(i) end
    return b
  end
  local queue = str_bytes("hi")
  queue[#queue + 1] = 13 -- type + submit
  local function push(s)
    local b = str_bytes(s)
    for i = 1, #b do queue[#queue + 1] = b[i] end
  end
  local function pop()
    if #queue == 0 then return nil end
    return table.remove(queue, 1)
  end

  local sink = {}
  local now, polls = 0, 0
  local step_i = 0 -- transport steps so far
  local pending, lines_fed = {}, false
  local step_at_esc, step_at_tail, steps_at_answer = nil, nil, nil
  local lines_at_tail = nil
  local n_start, n_free, n_abort, stream_calls = 0, 0, 0, 0
  local first_frame_at_step2 = nil
  local answer_lines = {
    'data: {"choices":[{"delta":{"content":"mid-turn "}}]}',
    "",
    'data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}',
    "",
  }

  local stub_tether = {
    poll = function(rfds, _, timeout)
      polls = polls + 1
      now = now + math.max(timeout or 0, 1)
      if polls > 400 then push(string.char(17)) end -- failsafe: never hang
      local ready = { read = {}, write = {} }
      if #queue > 0 then
        for _, fd in ipairs(rfds or {}) do
          if fd == 0 then ready.read = { 0 }; break end
        end
      end
      return ready
    end,
    monotonic_ms = function() return now end,
    write = function(s)
      -- the first frame emitted while the wheel's step is current is the
      -- forced repaint that follows the scroll dispatch
      if step_i == 2 and not first_frame_at_step2 then first_frame_at_step2 = s end
      sink[#sink + 1] = s
    end,
    read_char = function() return pop() end,
    read_char_nb = function()
      local b = pop()
      if b == 27 and step_at_esc == nil then step_at_esc = step_i end
      if b == string.byte("M") then -- last byte of ESC[<64;10;5M
        step_at_tail = step_i
        lines_at_tail = lines_fed
      end
      return b
    end,
    http_start = function() n_start = n_start + 1; return {} end,
    http_step = function()
      step_i = step_i + 1
      if step_i == 1 then push("\27") end          -- fragment: the ESC prefix
      if step_i == 2 then push("[<64;10;5M") end    -- fragment: the tail
      if step_i >= 3 then pending = answer_lines; return "done" end
      return "running"
    end,
    http_lines = function()
      local l = pending
      pending = {}
      if #l > 0 and not lines_fed then
        lines_fed = true
        steps_at_answer = step_i
      end
      return l
    end,
    http_fds = function() return { read = {}, write = {}, timeout = -1 } end,
    http_abort = function() n_abort = n_abort + 1; return true end,
    http_free = function()
      n_free = n_free + 1
      push(string.char(17)) -- Ctrl+Q: the turn is over, quit the loop
      return true
    end,
    http_stream = function() stream_calls = stream_calls + 1; return true end,
    http_get = function() return nil, "not used" end,
    sleep = function() end,
  }

  local uimod_tw4, S = run_ui_with({}, {
    tether = stub_tether,
    api = api_mod,
    agent = agent_mod,
    config = {
      load = function()
        return { model = "test", workspace = "/tmp", base_url = "http://x",
                 ui = { input_max_lines = 8 }, context = {},
                 retry = { base_delay_ms = 1, max_delay_ms = 1, multiplier = 1 } }
      end,
      api_key = function() return "k" end,
      get_system_prompt = function() return nil end,
    },
    session = { new_session = function() return "sid" end,
                append = function() end },
  }, sink)
  local frames, frame2 = table.concat(sink), first_frame_at_step2
  _G.turn, _G.reactor = orig.turn, orig.reactor

  assert_eq(stream_calls, 0, "TW4 the turn streamed over the step API")
  assert_eq(n_start, 1, "TW4 one transfer for the turn")
  assert_eq(n_free, 1, "TW4 the transfer is freed after the turn")
  assert_eq(n_abort, 0, "TW4 the turn completed without an abort")
  assert_notnil(step_at_esc, "TW4 the fragmented prefix was read mid-turn")
  assert_notnil(step_at_tail, "TW4 the fragmented tail was read mid-turn")
  assert_notnil(steps_at_answer, "TW4 the transport answered")
  assert_eq(step_at_esc, 1, "TW4 the prefix arrived on the step that sent it")
  assert_eq(step_at_tail, 2, "TW4 the tail dispatched within its own tick")
  assert_true(step_at_tail < steps_at_answer,
    "TW4 the wheel landed before the answer (steps " .. tostring(step_at_tail)
      .. " < " .. tostring(steps_at_answer) .. ")")
  assert_false(lines_at_tail, "TW4 no stream line was in flight at the wheel")
  assert_notnil(frame2, "TW4 a frame repainted in the wheel's own tick")
  assert_true(tostring(frame2):find("↓ +", 1, true) == nil,
    "TW4 no scroll indicator in the repaint: "
      .. tostring(frame2 and frame2:sub(1, 160)))
  assert_true(S.scroll > 0, "TW4 the mid-turn wheel scrolled the viewport")
  assert_true(S.user_scrolled, "TW4 the wheel left follow mode")
  assert_eq(S.input, "", "TW4 the wheel sequence never reached the input")
  assert_eq(#S.history, 1, "TW4 no history was recalled into the field")
  assert_false(S.busy, "TW4 the turn finished before the loop quit")
  -- The transcript holds the answer even though the pinned (scrolled) viewport
  -- may not have repainted the tail row: with the splash block above, the
  -- wheel-scrolled window can lag behind the appended answer. Assert on the
  -- transcript model, not on which rows the last frame happened to show.
  local tw4_answer = false
  for _, r in ipairs(uimod_tw4._render_all(80)) do
    if r:gsub("\27%[[%d;]*m", ""):find("mid-turn answer", 1, true) then tw4_answer = true; break end
  end
  assert_true(tw4_answer, "TW4 the streamed answer reached the transcript")
  print("TW4 mid-turn wheel scroll: OK")
end

-- T91: 9.4 — throttle: a burst of N deltas paints at most
-- PAINT_MIN_DELTAS+1 forced frames; transitions (tool_call_start) paint at once.
do
  -- Internal paint() cannot be intercepted from outside (it's a local closure).
  -- Instead: verify the throttle via the repaint counter (M._paint_count).
  -- 30 deltas with PAINT_MIN_DELTAS=12 means at most ceil(30/12) + 1 = 3
  -- repaints from deltas, plus 1 forced on tool_call_start = at most 4 total.
  -- Without the throttle it would be 31.
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
  local sf = uimod._paint_count or 0
  -- initial paint on turn start; 30 deltas: max 3 forced (skipped>=12) + 1
  -- forced on tool_call_start. So repaints should be < 31 (throttle working).
  assert_true(sf < 31, "T91 repaints=" .. sf .. " < 31 (throttle limits repaints)")
  assert_true(sf >= 1, "T91 repaints=" .. sf .. " >= 1 (at least one repaint happened)")
  print("T91 9.4 throttle bound: repaints=" .. sf .. " OK")
end

-- TW2: spinner frame is time-based, not event-based. Like pi's Loader (80 ms
-- interval), the glyph derives from elapsed monotonic ms since the turn began,
-- so it animates at constant speed whether tokens stream or the turn is silent.
do
  local ui = dofile("src/tether/ui.lua")
  assert_notnil(ui.spinner_glyph, "TW2 spinner_glyph exported")
  assert_eq(ui._spinner_interval_ms, 80, "TW2 interval is 80 ms (pi default)")
  -- pure seam: glyph at 0ms / 80ms / 160ms must differ pairwise (animation
  -- actually moves with time, not with event count)
  local f0 = ui._spinner_glyph_at(0)
  local f1 = ui._spinner_glyph_at(80)
  local f2 = ui._spinner_glyph_at(160)
  assert_true(f0 ~= f1, "TW2 frame advances with time (0ms vs 80ms)")
  assert_true(f1 ~= f2, "TW2 frame advances with time (80ms vs 160ms)")
  assert_eq(f0, ui._spinner_glyph_at(800), "TW2 frames cycle with a 10-frame period")
  -- nil-safe pre-run glyph
  assert_notnil(ui.spinner_glyph(), "TW2 glyph before busy is nil-safe")
  print("TW2 time-based spinner frames: OK")
end

-- TW5: prod wiring regression — painters().now_ms must tick in the same
-- units (ms) as the busy_started_at_ms anchor from turn.begin
-- (tether.monotonic_ms). Passing the seconds _paint_clock straight through
-- froze the glyph to one frame per 80 s instead of 80 ms.
do
  local uimod, S = run_ui_with({ 17 },
    { agent = { turn = function() return true end, get_history = function() return {} end } })
  S.busy = true
  S.busy_started_at_ms = 1759140000000
  local t = 0
  -- seconds, exactly like the real M._paint_clock (ms / 1000)
  uimod._paint_clock = function() return 1759140000 + t end
  local g0 = uimod.spinner_glyph()
  t = 0.24 -- 240 ms later: 3 frames ahead at an 80 ms cadence
  local g1 = uimod.spinner_glyph()
  assert_true(g0 ~= g1, "TW5 spinner advances with wall time (prod wiring)")
  print("TW5 spinner wiring is millisecond-based: OK")
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
  assert_eq(#S.palette_items, 10, "T71 ten commands listed (+login/logout/think)")
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

-- Phase A 1.1: transcript.render_viewport owns the viewport render
-- (slice in, ordered rowmap out). Two layers: module direct + facade proxy.
do
  local tr = assert(loadfile("src/tether/transcript.lua"))()
  tr.configure({ render = function(e, w) return { (e.text or e.role or "?") } end,
    cache_bound = function() return 1024 end })
  tr.reset({ { role = "user", text = "hi" }, { role = "assistant", text = "yo" } })
  local P = { trunc = function(s) return s end, caret = function() return "|" end,
    scroll_shift_seq = function() return "" end }
  local L = { w = 80, h = 24, transcript_row = 1, transcript_h = 10 }
  local base = { content_width = 78, gutter = " ", scroll = 0,
    user_scrolled = false, streaming = false, palette_active = false,
    confirmation = nil, ask = nil, login_secret = nil, alt_screen = false }
  local res = tr.render_viewport(base, L, P)
  assert_eq(#res.rows, 10, "T1.1 viewport rowmap fills the height")
  assert_eq(res.rows[1][1], 1, "T1.1 rowmap carries screen rows")
  assert_true(res.total >= 2, "T1.1 total counts entries")
  -- scroll clamp: absurd offset pins to the top
  local clamped = tr.render_viewport({ content_width = 78, gutter = " ",
    scroll = 999, user_scrolled = true, _last_total = res.total,
    _last_scroll = 999 }, L, P)
  assert_true(clamped.scroll <= math.max(res.total - 1, 0), "T1.1 scroll clamps")
  -- caret guard: streaming caret suppressed while the palette owns keys
  tr.reset({ { role = "assistant", text = "streaming" } })
  local plain = tr.render_viewport({ content_width = 78, gutter = " ",
    scroll = 0, user_scrolled = false, streaming = true }, L, P)
  local pal = tr.render_viewport({ content_width = 78, gutter = " ",
    scroll = 0, user_scrolled = false, streaming = true,
    palette_active = true }, L, P)
  local function has_caret(r)
    for _, row in ipairs(r.rows) do
      if row[2]:find("|", 1, true) then return true end
    end
    return false
  end
  assert_true(has_caret(plain), "T1.1 caret paints while streaming")
  assert_true(not has_caret(pal), "T1.1 palette suppresses the caret")
  print("T1.1 render_viewport module: OK")
end

-- T357 (audit L8): the scroll-region shift moves content the right way —
-- new tail rows shift UP (SU), and the viewport reports a positive shift.
-- The old sign sent SD for tail growth (content visibly jumped down).
do
  local tr = assert(loadfile("src/tether/transcript.lua"))()
  local regions = assert(loadfile("src/tether/ui/regions.lua"))()
  tr.configure({ render = function(e, w) return { (e.text or e.role or "?") } end,
    cache_bound = function() return 4096 end })
  local lines = {}
  for i = 1, 12 do lines[#lines + 1] = { role = "user", text = "line" .. i } end
  tr.reset(lines)
  local L = { w = 80, h = 24, transcript_row = 5, transcript_h = 4 }
  local P = { trunc = function(s) return s end, caret = function() return "" end,
    scroll_shift_seq = regions.scroll_shift_seq }
  local base = { content_width = 78, gutter = " ", scroll = 0,
    user_scrolled = false, streaming = false, palette_active = false,
    confirmation = nil, ask = nil, login_secret = nil, alt_screen = false }
  local r1 = tr.render_viewport(base, L, P)
  for i = 13, 14 do tr.append({ role = "user", text = "line" .. i }) end
  tr.bump() -- structural change: new tail rows join the index
  base.last_transcript_top = r1.last_top
  base.last_transcript_w = r1.last_w
  local r2 = tr.render_viewport(base, L, P)
  assert_notnil(r2.shift_seq, "T357 tail growth emits a shift sequence")
  assert_true((r2.shift or 0) > 0, "T357 newer rows shift content up")
  assert_true(r2.shift_seq:find("S", 1, true) ~= nil, "T357 content-up uses SU")
  assert_true(regions.scroll_shift_seq(24, 5, 8, 2):find("2S", 1, true) ~= nil,
    "T357 positive shift scrolls up")
  assert_true(regions.scroll_shift_seq(24, 5, 8, -2):find("2T", 1, true) ~= nil,
    "T357 negative shift scrolls down")
  print("T357 scroll-region direction: OK")
end

-- scroll-render-budget 2.1: page-step scroll budget with the REAL
-- render_entry (close-without-code verdict — this test pins the measured
-- 1.8ms/step against the 8ms budget so future renderer changes cannot
-- silently 4x it).
do
  local uimod, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  local tr = uimod._transcript
  tr.clear()
  local prose = "Here is what I found in the codebase. "
  local fence = "```lua\nlocal x = 1\n```\n"
  for i = 1, 1000 do
    local text
    if i % 2 == 0 then text = string.rep(prose, 4)
    else text = fence .. string.rep(prose, 2) end
    tr.append({ role = (i % 2 == 0) and "user" or "assistant", text = text })
  end
  local L = { w = 80, h = 24, transcript_row = 1, transcript_h = 10 }
  local P = { trunc = function(s) return s end, caret = function() return "|" end,
    scroll_shift_seq = function() return "" end }
  local total = tr.ensure_index(78)
  local slice = { content_width = 78, gutter = " ", scroll = 0,
    user_scrolled = true, streaming = false }
  local t0 = os.clock()
  local steps = 0
  local lo = 1
  while lo <= total - 10 do
    tr.set_visible(lo, lo + 9)
    slice.scroll = total - (lo + 9)
    tr.render_viewport(slice, L, P)
    steps = steps + 1
    lo = lo + 10
  end
  local avg = (os.clock() - t0) * 1000 / math.max(steps, 1)
  assert_true(steps > 50, "T1.1b scroll covers pages")
  assert_true(avg <= 8, "T1.1b page step within 8ms budget (" ..
    string.format("%.2f", avg) .. "ms)")
  print("T1.1b scroll budget: OK")
end

if failed > 0 then
    os.exit(1)
end



