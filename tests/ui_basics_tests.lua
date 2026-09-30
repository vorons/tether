-- tests/ui_basics_tests.lua — token/mouse/width/scroll/keymap (split from lua_tests.lua, Phase C).
-- Run: lua tests/ui_basics_tests.lua

dofile("tests/helpers.lua")
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
  -- auto: always enabled — the wheel must scroll the transcript. Without
  -- tracking, terminals translate the wheel to Up/Down arrows, which recalled
  -- input history into the field (wheel-scroll regression TW1).
  assert_eq(mw("auto", { confirmation = true }), true, "T37 auto+confirmation")
  assert_eq(mw("auto", { palette_active = true }), true, "T37 auto+palette")
  assert_eq(mw("auto", {}), true, "T37 auto idle -> on (wheel capture)")
  assert_eq(mw("auto", { search = { input = "x" } }), true, "T37 auto+search -> on")
  -- off: never; on: always
  assert_eq(mw("off", { confirmation = true }), false, "T37 off never")
  assert_eq(mw("on", {}), true, "T37 on always")
  -- selection: same as off (terminal handles it)
  assert_eq(mw("selection", { confirmation = true }), false, "T37 selection = off")
  -- unknown/nil mode: default auto
  assert_eq(mw(nil, {}), true, "T37 nil mode defaults to auto")
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
  -- thresholds tint the dim cell: dim below, dim yellow >= summarize_at,
  -- dim red >= 90%; green is gone
  assert_true(ui.token_usage(4200, 32768):find("32m", 1, true) == nil, "T47 no green below threshold")
  assert_true(ui.token_usage(4200, 32768):find("%[2m", 1) ~= nil, "T47 dim below threshold")
  assert_true(ui.token_usage(24000, 32768):find("33;1", 1, true) ~= nil, "T47 yellow above summarize_at")
  assert_true(ui.token_usage(24000, 32768):find("%[2m", 1) ~= nil, "T47 warning stays dim")
  assert_true(ui.token_usage(31000, 32768):find("31;1", 1, true) ~= nil, "T47 red near full")
  assert_true(ui.token_usage(31000, 32768):find("%[2m", 1) ~= nil, "T47 error stays dim")
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
  -- add-provider-login adds /login /logout, add-reasoning-level adds /think
  -- → 7 + 2 + 1 = 10
  assert(#(ui.SLASH_COMMANDS or {}) == 10,
    "T39 slash commands = base 7 + login/logout + think")
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
  assert_eq(km["5"], "confirm cancel", "T42 digit 5 documented (details gone)")
  assert_eq(km["6"], nil, "T42 no digit 6 after details removal")
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

-- add-llm-compaction 1.1/1.2/1.3: config keys, reserve OR fraction trigger,
-- parameterized keep window, malformed reserve falls back at load time.
do
  local config = assert(loadfile("src/tether/config.lua"))()
  local home = "/tmp/tether_t130_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local cfg = config.load(home .. "/no-such-config.lua", home)
  assert_eq(cfg.context.reserve_tokens, 16384, "T130 default reserve_tokens")
  assert_eq(cfg.context.keep_recent_messages, 4, "T130 default keep_recent_messages")
  assert_eq(cfg.context.summarize_at, 0.7, "T130 default summarize_at")
  -- no max_tokens backfill: absent stays nil so the per-model metadata
  -- chain applies downstream (explicit values still pass through).
  assert_eq(cfg.context.max_tokens, nil, "T130 default max_tokens unset")

  local bad = assert(io.open(home .. "/.tether/config.lua", "w"))
  bad:write('return { context = { reserve_tokens = "lots", keep_recent_messages = "two" } }\n')
  bad:close()
  local cfg2 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg2.context.reserve_tokens, 16384, "T130 malformed reserve falls back")
  assert_eq(cfg2.context.keep_recent_messages, 4, "T130 malformed keep falls back")
  os.execute("rm -rf " .. home)

  local agent = dofile("src/tether/agent.lua")
  -- reserve_tokens=0 so only the fraction threshold is active unless a test
  -- sets its own reserve (default reserve 16384 would dominate max=1000).
  local base = { max_tokens = 1000, summarize_at = 0.7, reserve_tokens = 0 }
  local function hist(n_bytes)
    local h = { { role = "system", content = "s" } }
    local c = string.rep("x", n_bytes)
    for _ = 1, 4 do h[#h + 1] = { role = "user", content = c } end
    return h
  end
  -- estimate = ceil(#c/4 * 4) = #c for four equal messages (plus system)
  local small = hist(100)
  assert_true(not agent.should_summarize(small, { context = base }),
    "T130 under both thresholds does not summarize")
  -- fraction: need > 700 tokens → content ~700+ bytes total over estimate
  local frac = hist(800) -- estimate ~ 800+
  assert_true(agent.should_summarize(frac, { context = base }),
    "T130 fraction threshold fires")
  -- reserve only: max 1000, reserve 900 → threshold 100; summarize_at 0.7 → 700
  local reserve_only = hist(200) -- estimate ~200 > 100, not > 700
  assert_true(agent.should_summarize(reserve_only,
    { context = { max_tokens = 1000, summarize_at = 0.7, reserve_tokens = 900 } }),
    "T130 reserve threshold fires before fraction")
  -- keep_recent_messages = 2: keep system + last 2 → system, summary, a2, u3
  local h = {
    { role = "system", content = "sys" },
    { role = "user", content = "u1" },
    { role = "assistant", content = "a1" },
    { role = "user", content = "u2" },
    { role = "assistant", content = "a2" },
    { role = "user", content = "u3" },
  }
  local kept = agent.compress_history(h, { context = { keep_recent_messages = 2 } })
  assert_eq(kept[1].role, "system", "T130 keep window keeps system first")
  assert_eq(#kept, 4, "T130 keep_recent_messages=2 → system + summary + 2")
  assert_eq(kept[#kept - 1].content, "a2", "T130 keeps last-1")
  assert_eq(kept[#kept].content, "u3", "T130 keeps last")
  print("T130 compaction config/thresholds: OK")
end

-- add-llm-compaction 2.1: one-shot summary helper — success, transport failure
-- with single retry, empty output → nil.
do
  local api = assert(loadfile("src/tether/api.lua"))()
  local names = {"api", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local retry = assert(loadfile("src/tether/retry.lua"))()
  _G.retry = retry

  local calls, script = 0, nil
  local real_stream = api.stream
  api.stream = function(_, _, _, on_event)
    calls = calls + 1
    local step = script and script[calls]
    if not step then return false, retry.failure("connection", "connection error") end
    for _, t in ipairs(step.texts or {}) do
      on_event({ type = "text_delta", text = t })
    end
    if step.ok == false then return false, step.failure end
    return true
  end

  script = { { texts = { "summary ", "body" }, ok = true } }
  local t = api.summarize({ provider = "openai" }, "k",
    { { role = "system", content = "p" } })
  assert_eq(t, "summary body", "T131 summarize concatenates text_delta")
  assert_eq(calls, 1, "T131 success uses a single stream call")

  -- transport failure → one retry then success
  calls = 0
  script = {
    { ok = false, failure = retry.failure("connection", "connection error") },
    { texts = { "after retry" }, ok = true },
  }
  local t2 = api.summarize({ provider = "openai" }, "k",
    { { role = "system", content = "p" } })
  assert_eq(t2, "after retry", "T131 one transport retry then success")
  assert_eq(calls, 2, "T131 exactly one retry")

  -- permanent failure → no retry, nil
  calls = 0
  script = { { ok = false, failure = retry.failure("permanent", "invalid api key") } }
  local t3, fail = api.summarize({ provider = "openai" }, "k",
    { { role = "system", content = "p" } })
  assert_eq(t3, nil, "T131 permanent failure yields nil")
  assert_notnil(fail, "T131 permanent failure returns the record")
  assert_eq(calls, 1, "T131 permanent failure is not retried")

  -- empty output after ok stream → nil
  calls = 0
  script = { { texts = { "" }, ok = true } }
  local t4 = api.summarize({ provider = "openai" }, "k",
    { { role = "system", content = "p" } })
  assert_eq(t4, nil, "T131 empty output yields nil")
  assert_eq(calls, 1, "T131 empty output is not retried")

  api.stream = real_stream
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T131 api.summarize: OK")
end

-- add-llm-compaction 2.3: LLM success → mode=llm; failure → mode=truncation;
-- no error event; keep-window pairing preserved.
do
  local names = {"api", "agent", "session", "config", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }
  _G.api = { list_models = function() return {} end }

  local agent = assert(loadfile("src/tether/agent.lua"))()
  local long = string.rep("y", 4000)
  local call = {
    role = "assistant",
    content = { tool_calls = {
      { id = "r1", type = "function", ["function"] = { name = "read", arguments = "{}" } },
    } },
  }
  local result = { role = "tool", tool_call_id = "r1", content = string.rep("z", 4000) }
  local h = {
    { role = "system", content = "sys" },
    { role = "user", content = long },
    { role = "assistant", content = long },
    { role = "user", content = long },
    call,
    result,
    { role = "user", content = "tail" },
  }

  -- LLM success
  local summary_calls = 0
  _G.api = {
    list_models = function() return {} end,
    summarize = function(_, _, messages)
      summary_calls = summary_calls + 1
      assert_true(#messages >= 2, "T132 summary request has prompt + span")
      return "structured goal progress decisions"
    end,
  }
  agent.history = {}
  for _, m in ipairs(h) do agent.history[#agent.history + 1] = m end
  local out, summary, mode = agent.compact_history(
    agent.history, { context = { keep_recent_messages = 4 } }, "key", nil, true)
  assert_eq(mode, "llm", "T132 LLM success mode=llm")
  assert_true(summary:find("structured goal progress decisions", 1, true) ~= nil,
    "T132 summary body is LLM text")
  assert_true(summary:find("── summary ──", 1, true) == 1,
    "T132 summary carries stable marker prefix")
  assert_eq(out[1], h[1], "T132 system kept")
  local idx_call, idx_result
  for i, m in ipairs(out) do
    if m == call then idx_call = i end
    if m == result then idx_result = i end
  end
  assert_notnil(idx_call, "T132 keep window holds tool call")
  assert_notnil(idx_result, "T132 keep window holds tool result")
  assert_eq(idx_result, (idx_call or 0) + 1, "T132 call/result stay adjacent")
  assert_eq(out[#out].content, "tail", "T132 newest message kept")
  assert_eq(summary_calls, 1, "T132 one summary request")
  assert_eq(#h, 7, "T132 source history not mutated")

  -- failure → truncation
  agent.history = {}
  for _, m in ipairs(h) do agent.history[#agent.history + 1] = m end
  _G.api = {
    list_models = function() return {} end,
    summarize = function() return nil, { kind = "connection" } end,
  }
  local out2, summary2, mode2 = agent.compact_history(
    agent.history, { context = { keep_recent_messages = 4 } }, "key", nil, true)
  assert_eq(mode2, "truncation", "T132 summary failure mode=truncation")
  assert_true(summary2:find("── summary ──", 1, true) == 1, "T132 fallback marker")
  assert_eq(out2[1].content, "sys", "T132 system kept on fallback")
  assert_true(summary2:find(long:sub(1, 200), 1, true) ~= nil or summary2:find("user: y", 1, true) ~= nil,
    "T132 truncation body present")
  -- no error: compact_history does not emit; caller emits only context_compressed
  -- (covered by main_loop tests)

  -- no-op: only system + keep window
  local tiny = {
    { role = "system", content = "sys" },
    { role = "user", content = "a" },
    { role = "assistant", content = "b" },
  }
  local out3, summary3, mode3 = agent.compact_history(tiny, { context = {} }, "k", nil, true)
  assert_eq(mode3, "noop", "T132 system+keep only is a no-op")
  assert_eq(summary3, "", "T132 no-op reports empty summary")
  assert_eq(#out3, 3, "T132 no-op leaves history")

  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T132 compact_history llm/fallback/noop: OK")
end

-- add-llm-compaction 3.1/3.2: commands.compact(focus) forces + passes focus;
-- UI parses free text after /compact.
do
  local names = {"agent", "api", "session"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local got_focus, got_force
  local history = {
    { role = "system", content = "sys" },
    { role = "user", content = "q1" },
    { role = "assistant", content = "a1" },
    { role = "user", content = "q2" },
  }
  _G.agent = {
    get_history = function() return history end,
    estimate_tokens = function() return 10 end,
    compact_history = function(h, cfg, key, focus, force)
      got_focus, got_force = focus, force
      local out = { h[1], { role = "system", content = "── summary ──\nllm body" }, h[#h] }
      return out, "── summary ──\nllm body", "llm"
    end,
  }
  _G.api = {}
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local summary, mode = commands.compact({ context = {} }, "key", "keep the plan")
  assert_eq(got_focus, "keep the plan", "T133 compact passes focus text")
  assert_eq(got_force, true, "T133 compact force-bypasses threshold")
  assert_eq(mode, "llm", "T133 compact returns mode")
  assert_eq(summary, "── summary ──\nllm body", "T133 compact returns summary")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T133 commands.compact focus: OK")
end

-- transcript context_compressed mode label (3.3)
do
  local tr = assert(loadfile("src/tether/transcript.lua"))()
  tr.reset({})
  tr.handle({ type = "context_compressed", mode = "llm", summary = "goal: ship it" })
  local e = tr.entries()
  assert_eq(e[#e].text, "goal: ship it", "T135 llm mode shows summary body")
  tr.reset({})
  tr.handle({ type = "context_compressed", mode = "truncation" })
  e = tr.entries()
  assert_eq(e[#e].role, "separator", "T135 truncation mode is separator-styled")
  assert_eq(e[#e].text, "summary", "T135 truncation mode keeps marker")
  tr.reset({})
  tr.handle({ type = "context_compressed" })
  e = tr.entries()
  assert_eq(e[#e].role, "separator", "T135 missing mode is separator-styled")
  assert_eq(e[#e].text, "summary", "T135 missing mode keeps marker")
  print("T135 context_compressed mode label: OK")
end

-- add-llm-compaction 2.4: no compression between main-loop retry attempts.
do
  local names = {"agent", "session", "config", "api", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  local retry = assert(loadfile("src/tether/retry.lua"))()
  _G.retry = retry
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }

  local a = assert(loadfile("src/tether/agent.lua"))()
  local compressed = 0
  local orig_compact = a.compact_history
  a.compact_history = function(...)
    compressed = compressed + 1
    return orig_compact(...)
  end
  local seen = 0
  local function stream(_, _, messages, on_event)
    seen = seen + 1
    -- history is intentionally over threshold (huge user message)
    assert_true(a.should_summarize(messages, { context = { max_tokens = 100 } }),
      "T136 history is over threshold on every attempt")
    if seen == 1 then
      return false, retry.failure("server", "rate limit exceeded", 429)
    end
    on_event({ type = "text_delta", text = "ok" })
    on_event({ type = "done", reason = "stop" })
    return true
  end
  _G.api = { stream = stream, list_models = function() return {} end, summarize = function()
    compressed = compressed + 1
    return "should not run mid-retry"
  end }
  a.clear()
  a.add_user(string.rep("b", 4000))
  local events = {}
  local ok = a.turn({ workspace = "/ws", retry = { base_delay_ms = 1 } },
    "k", string.rep("b", 4000), function(ev) events[#events + 1] = ev end, true)
  assert_true(ok == true or ok == false, "T136 turn returns")
  -- turn with skip_user still may compact at top of main_loop before first attempt;
  -- but NOT between attempt 1 failure and attempt 2
  local compress_events = 0
  local order = {}
  for _, ev in ipairs(events) do
    if ev.type == "retry" then order[#order + 1] = "retry" end
    if ev.type == "context_compressed" then
      compress_events = compress_events + 1
      order[#order + 1] = "compress"
    end
  end
  assert_eq(compress_events, 0, "T136 no compaction between retry attempts: got " ..
    compress_events .. " compress events")
  local ri, ci
  for i, x in ipairs(order) do
    if x == "retry" and not ri then ri = i end
    if x == "compress" and not ci then ci = i end
  end
  assert_true(ci == nil or (ri and ci < ri) or ri == nil,
    "T136 any compression would precede the retry")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T136 no mid-retry compaction: OK")
end

-- compaction-anchors-preflight-prune 1.1: deterministic anchor extraction and
-- formatting on a fixture history; noise and word-boundary guards.
do
  local agent = dofile("src/tether/agent.lua")
  local h = {
    { role = "system", content = "sys" },
    { role = "user", content = "please implement dark mode, always use tabs" },
    { role = "assistant", content = { tool_calls = {
      { id = "r1", ["function"] = { name = "read",
        arguments = '{"path":"src/ui.lua"}' } } }, text = "" } },
    { role = "tool", tool_call_id = "r1", name = "read", content = "body" },
    { role = "assistant", content = { tool_calls = {
      { id = "w1", ["function"] = { name = "write",
        arguments = '{"path":"src/ui.lua"}' } } }, text = "" } },
    { role = "tool", tool_call_id = "w1", name = "write", content = "src/ui.lua" },
    { role = "assistant", content = { tool_calls = {
      { id = "c1", ["function"] = { name = "run",
        arguments = '{"command":"git commit -m \\"dark mode\\""}' } } },
      text = "" } },
    { role = "tool", tool_call_id = "c1", name = "run", content = "abc1234def ok" },
    { role = "user", content = "build failed on linux" },
  }
  local a = agent.extract_anchors(h)
  assert_true(a.goal ~= nil and a.goal:find("dark mode", 1, true) ~= nil,
    "T244 goal extracted")
  assert_eq(#a.files_modified, 1, "T244 one modified file")
  assert_eq(a.files_modified[1], "src/ui.lua", "T244 modified path")
  assert_eq(a.files_both[1], "src/ui.lua", "T244 read-before-write marked RW")
  assert_true(#a.preferences >= 1, "T244 preference extracted")
  assert_true(#a.commits == 1 and a.commits[1]:find("dark mode", 1, true) ~= nil,
    "T244 commit paired with hash")
  assert_true(#a.blockers == 1, "T244 tail blocker extracted")
  local block = agent.format_anchors(a)
  assert_true(block:find("Preserve these exact facts", 1, true) ~= nil,
    "T244 anchor header")
  assert_true(block:find("src/ui.lua (RW)", 1, true) ~= nil,
    "T244 RW marker rendered")
  assert_eq(agent.format_anchors(
    agent.extract_anchors({ { role = "system", content = "s" } })), "",
    "T244 empty history yields empty block")
  assert_eq(agent.extract_anchors(
    { { role = "user", content = "ok" } }).goal, nil,
    "T244 noise is not a goal")
  assert_eq(agent.extract_anchors(
    { { role = "user", content = "the prefix looks odd" } }).goal, nil,
    "T244 word boundary: prefix is not a task")
  print("T244 anchors extract/format: OK")
end

-- compaction-anchors-preflight-prune 1.2: anchors reach api.summarize behind
-- cfg.context.anchors (default on); anchors=false sends the bare prompt.
do
  local names = {"api", "agent", "session", "config", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local long = string.rep("y", 4000)
  local h = {
    { role = "system", content = "sys" },
    { role = "user", content = "implement dark mode" },
    { role = "assistant", content = long },
    { role = "user", content = long },
    { role = "assistant", content = long },
    { role = "user", content = "tail" },
  }
  local seen_prompt
  _G.api = { summarize = function(_, _, messages)
    seen_prompt = messages[1].content
    return "llm body"
  end }
  agent.history = {}
  for _, m in ipairs(h) do agent.history[#agent.history + 1] = m end
  local _, _, mode = agent.compact_history(
    agent.history, { context = { keep_recent_messages = 2 } }, "key", nil, true)
  assert_eq(mode, "llm", "T245 anchors path still llm")
  assert_true(seen_prompt:find("Preserve these exact facts", 1, true) ~= nil,
    "T245 anchor block in summary prompt by default")
  assert_true(seen_prompt:find("dark mode", 1, true) ~= nil,
    "T245 anchor carries the task text")
  seen_prompt = nil
  agent.history = {}
  for _, m in ipairs(h) do agent.history[#agent.history + 1] = m end
  agent.compact_history(agent.history,
    { context = { keep_recent_messages = 2, anchors = false } }, "key", nil, true)
  assert_true(seen_prompt ~= nil and
    seen_prompt:find("Preserve these exact facts", 1, true) == nil,
    "T245 anchors=false sends the bare prompt")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T245 anchors wired into summary: OK")
end

-- compaction-anchors-preflight-prune 1.3/2.3: config defaults and malformed
-- fallback for the three new context knobs.
do
  local config = assert(loadfile("src/tether/config.lua"))()
  local home = "/tmp/tether_anchors_home"
  os.execute("rm -rf " .. home .. " && mkdir -p " .. home .. "/.tether")
  local cfg = config.load(home .. "/no-such-config.lua", home)
  assert_eq(cfg.context.anchors, true, "T246 default anchors")
  assert_eq(cfg.context.preflight, true, "T246 default preflight")
  assert_eq(cfg.context.prune_superseded_reads, false,
    "T246 default prune_superseded_reads")
  local bad = assert(io.open(home .. "/.tether/config.lua", "w"))
  bad:write('return { context = { anchors = "yes", preflight = 1, prune_superseded_reads = "off" } }\n')
  bad:close()
  local cfg2 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg2.context.anchors, true, "T246 malformed anchors falls back")
  assert_eq(cfg2.context.preflight, true, "T246 malformed preflight falls back")
  assert_eq(cfg2.context.prune_superseded_reads, false,
    "T246 malformed prune falls back")
  local good = assert(io.open(home .. "/.tether/config.lua", "w"))
  good:write('return { context = { anchors = false, preflight = false, prune_superseded_reads = true } }\n')
  good:close()
  local cfg3 = config.load(home .. "/.tether/config.lua", home)
  assert_eq(cfg3.context.anchors, false, "T246 explicit anchors=false survives")
  assert_eq(cfg3.context.preflight, false, "T246 explicit preflight=false survives")
  assert_eq(cfg3.context.prune_superseded_reads, true,
    "T246 explicit prune=true survives")
  os.execute("rm -rf " .. home)
  print("T246 anchor/preflight/prune config: OK")
end

-- compaction-anchors-preflight-prune 2.1: projection reuses the thresholds.
do
  local agent = dofile("src/tether/agent.lua")
  local cfg = { context = { max_tokens = 1000, summarize_at = 0.7,
    reserve_tokens = 0 } }
  local small = { { role = "system", content = "s" },
    { role = "user", content = "hi" } }
  assert_true(not agent.should_summarize_projected(small, "tiny", cfg),
    "T247 small prompt stays quiet")
  assert_true(agent.should_summarize_projected(small, string.rep("z", 4000), cfg),
    "T247 large paste fires the projection")
  assert_true(not agent.should_summarize(small, cfg),
    "T247 history alone is under threshold")
  print("T247 preflight projection: OK")
end

-- compaction-anchors-preflight-prune 2.2: turn() compacts a large paste before
-- the first LLM call; preflight=false leaves an under-threshold turn alone.
do
  local names = {"agent", "session", "config", "api", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }
  _G.retry = assert(loadfile("src/tether/retry.lua"))()
  _G.api = {
    stream = function(_, _, _, on_event)
      on_event({ type = "text_delta", text = "ok" })
      on_event({ type = "done", reason = "stop" })
      return true
    end,
    list_models = function() return {} end,
    summarize = function() return "preflight summary" end,
  }
  local function fresh_agent()
    local a = assert(loadfile("src/tether/agent.lua"))()
    a.clear()
    a.history[#a.history + 1] = { role = "system", content = "sys" }
    for _ = 1, 4 do
      a.history[#a.history + 1] = { role = "user", content = string.rep("x", 100) }
    end
    return a
  end
  local base_cfg = { workspace = "/ws", retry = { base_delay_ms = 1 },
    context = { max_tokens = 1000, summarize_at = 0.7, reserve_tokens = 0,
      keep_recent_messages = 4 } }
  local a = fresh_agent()
  local events = {}
  a.turn(base_cfg, "k", string.rep("z", 3000),
    function(ev) events[#events + 1] = ev end)
  local compress = 0
  for _, ev in ipairs(events) do
    if ev.type == "context_compressed" then compress = compress + 1 end
  end
  assert_eq(compress, 1, "T248 preflight compacts the large paste")
  assert_eq(a.history[2].content:find("preflight summary", 1, true) ~= nil
    or a.history[2].content:find("── summary ──", 1, true) ~= nil, true,
    "T248 summary leads the compacted history")
  local a2 = fresh_agent()
  local events2 = {}
  local cfg_off = { workspace = "/ws", retry = { base_delay_ms = 1 },
    context = { max_tokens = 1000, summarize_at = 0.7, reserve_tokens = 0,
      keep_recent_messages = 4, preflight = false } }
  a2.turn(cfg_off, "k", "tiny",
    function(ev) events2[#events2 + 1] = ev end)
  local compress2 = 0
  for _, ev in ipairs(events2) do
    if ev.type == "context_compressed" then compress2 = compress2 + 1 end
  end
  assert_eq(compress2, 0, "T248 preflight=false leaves a small turn alone")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T248 turn preflight: OK")
end

-- compaction-anchors-preflight-prune 3.1: prune unit — fires, no-op same-ref,
-- idempotent, plan-file exempt, minimum-reclaim gate.
do
  local agent = dofile("src/tether/agent.lua")
  local big = string.rep("x", 30000)
  local function reads(path1, body1, path2, body2, tail)
    return {
      { role = "system", content = "sys" },
      { role = "assistant", content = { tool_calls = {
        { id = "r1", ["function"] = { name = "read",
          arguments = '{"path":"' .. path1 .. '"}' } } }, text = "" } },
      { role = "tool", tool_call_id = "r1", name = "read", content = body1 },
      { role = "assistant", content = { tool_calls = {
        { id = "r2", ["function"] = { name = "read",
          arguments = '{"path":"' .. path2 .. '"}' } } }, text = "" } },
      { role = "tool", tool_call_id = "r2", name = "read", content = body2 },
      { role = "user", content = tail },
    }
  end
  local h = reads("a.lua", big, "a.lua", "new body", string.rep("t", 170000))
  local out = agent.prune_superseded_reads(h)
  assert_true(out ~= h, "T249 prune rewrites the view")
  assert_eq(h[3].content, big, "T249 source history untouched")
  assert_eq(out[5].content, "new body", "T249 latest copy intact")
  assert_true(out[3].content:find("superseded", 1, true) ~= nil
    and out[3].content:find("a.lua", 1, true) ~= nil,
    "T249 placeholder names the file")
  assert_true(agent.prune_superseded_reads(out) == out,
    "T249 prune is idempotent")
  local plan = reads("docs/plan.md", big, "docs/plan.md", "new body",
    string.rep("t", 170000))
  assert_true(agent.prune_superseded_reads(plan) == plan,
    "T249 plan file exempt")
  local small = reads("a.lua", "v1", "a.lua", "v2", "tail")
  assert_true(agent.prune_superseded_reads(small) == small,
    "T249 below minimum reclaim is a no-op")
  assert_true(agent.prune_superseded_reads(
    { { role = "user", content = "hi" } })[1].content == "hi",
    "T249 single read untouched")
  print("T249 prune superseded reads: OK")
end

-- compaction-anchors-preflight-prune 3.2: the provider sees the pruned view
-- while M.history keeps the originals; disabled prune sends history as-is.
do
  local names = {"agent", "session", "config", "api", "tools", "context", "tether", "retry"}
  local orig = {}
  for _, n in ipairs(names) do orig[n] = _G[n] end
  _G.tether = host_mock{ getcwd = function() return "/ws" end,
    realpath = function(p) return p end, sleep = function() end }
  _G.session = { append = function() end }
  _G.config = { get_system_prompt = function() return nil end }
  _G.tools = { _within = function() return true end,
    _resolve = function(p) return p end, _workspace = function() return "/ws" end }
  _G.retry = assert(loadfile("src/tether/retry.lua"))()
  local agent = assert(loadfile("src/tether/agent.lua"))()
  local big = string.rep("x", 30000)
  local function seed(a)
    a.clear()
    a.history[#a.history + 1] = { role = "system", content = "sys" }
    a.history[#a.history + 1] = { role = "assistant", content = { tool_calls = {
      { id = "r1", ["function"] = { name = "read",
        arguments = '{"path":"a.lua"}' } } }, text = "" } }
    a.history[#a.history + 1] = { role = "tool", tool_call_id = "r1",
      name = "read", content = big }
    a.history[#a.history + 1] = { role = "assistant", content = { tool_calls = {
      { id = "r2", ["function"] = { name = "read",
        arguments = '{"path":"a.lua"}' } } }, text = "" } }
    a.history[#a.history + 1] = { role = "tool", tool_call_id = "r2",
      name = "read", content = "new body" }
    a.history[#a.history + 1] = { role = "user",
      content = string.rep("t", 170000) .. " go" }
  end
  local sent
  _G.api = {
    stream = function(_, _, messages, on_event)
      sent = messages
      on_event({ type = "text_delta", text = "ok" })
      on_event({ type = "done", reason = "stop" })
      return true
    end,
    list_models = function() return {} end,
    summarize = function() return "s" end,
  }
  seed(agent)
  agent.turn({ workspace = "/ws", retry = { base_delay_ms = 1 },
    context = { max_tokens = 4000000, summarize_at = 0.99, reserve_tokens = 0,
      prune_superseded_reads = true } }, "k", "go", function() end)
  assert_true(sent ~= agent.history, "T250 provider gets the pruned view")
  assert_true(sent[3].content:find("superseded", 1, true) ~= nil,
    "T250 earlier copy blanked outbound")
  assert_eq(sent[5].content, "new body", "T250 latest copy sent intact")
  assert_eq(agent.history[3].content, big, "T250 persisted history untouched")
  seed(agent)
  agent.turn({ workspace = "/ws", retry = { base_delay_ms = 1 },
    context = { max_tokens = 4000000, summarize_at = 0.99, reserve_tokens = 0 } },
    "k", "go", function() end)
  assert_true(sent == agent.history, "T250 disabled prune sends history as-is")
  for _, n in ipairs(names) do _G[n] = orig[n] end
  print("T250 pruned outbound view: OK")
end


if failed > 0 then
    os.exit(1)
end
