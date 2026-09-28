-- tests/keys_tests.lua — ui_keys decoder (split from lua_tests.lua, Phase C).
-- Run: lua tests/keys_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- TKEY: ui_keys owns the decoder directly (ui-modular-split 5.2). The bag
-- carries stub state; byte input is not needed for these pure paths.
do
  local keys = assert(loadfile("src/tether/ui/keys.lua"))()
  local m = keys.decode_mods(5) -- ctrl(4) + shift(1)
  assert_true(m.ctrl and m.shift and not m.alt, "TKEY decode_mods bit field")
  local k = keys.decode_modified_key(13, { shift = true })
  assert_eq(k.kind, "newline", "TKEY shift+enter is newline")
  k = keys.decode_modified_key(97, { ctrl = true })
  assert_eq(k.kind, "ctrl", "TKEY ctrl+a kind")
  assert_eq(k.code, 1, "TKEY ctrl+a code")
  k = keys.decode_csi_u("97;5")
  assert_eq(k.kind, "ctrl", "TKEY kitty CSI-u kind")
  assert_eq(k.code, 1, "TKEY kitty CSI-u code")
  k = keys.decode_modify_other_keys("27;5;13")
  assert_eq(k.kind, "newline", "TKEY modifyOtherKeys ctrl+enter is newline")
  assert_notnil(keys.legacy_csi_mods("1;5"), "TKEY legacy CSI mods")
  assert_eq(keys.legacy_csi_mods("nop"), nil, "TKEY legacy CSI mods nil")
  -- stateful entry with a stub bag: esc alone decodes without host reads.
  local bag = { _byte_stash = {}, _esc_stash_s = nil, _paint_clock = function() return 1000 end }
  local ev = keys.decode_first_byte(bag, 13)
  assert_eq(ev.kind, "enter", "TKEY decode_first_byte enter via stub bag")
  ev = keys.decode_first_byte(bag, 9)
  assert_eq(ev.kind, "tab", "TKEY decode_first_byte tab via stub bag")
  -- facade parity: the same bytes through ui give the same events.
  local ui = dofile("src/tether/ui.lua")
  assert_eq(ui._keys.ESC_AGE_S, 0.15, "TKEY facade module constant")
  print("TKEY ui_keys direct: OK")
end

-- Phase B 2.1: dispatch routing order as data (byte-identical to the
-- facade switch). Key golden cases: every branch resolves first-wins.
do
  local keys = assert(loadfile("src/tether/ui/keys.lua"))()
  local function r(kind, extra, ctx)
    local k = { kind = kind }
    if extra then for x, y in pairs(extra) do k[x] = y end end
    return keys.route(k, ctx or {})
  end
  assert_eq(r("text", { char = "x" }, { login_secret = {} }), "login_secret", "T2.1 secret first")
  assert_eq(r("text", { char = "x" }, { login_secret = {}, confirmation = {} }), "login_secret", "T2.1 secret beats confirm")
  assert_eq(r("enter", {}, { confirmation = {} }), "confirmation", "T2.1 confirmation")
  assert_eq(r("text", nil, { confirmation = {}, ask = {} }), "confirmation", "T2.1 confirm beats ask")
  assert_eq(r("enter", nil, { ask = {} }), "ask", "T2.1 ask")
  assert_eq(r("enter", nil, { error_banner = "boom" }), "error_dismiss", "T2.1 error dismiss on enter")
  assert_eq(r("esc", nil, { error_banner = "boom" }), "error_dismiss", "T2.1 error dismiss on esc")
  assert_eq(r("text", { char = "x" }, { error_banner = "boom" }), "normal:text", "T2.1 error keeps text")
  assert_eq(r("mouse", { name = "scroll_up" }, {}), "mouse", "T2.1 mouse")
  assert_eq(r("ctrl", { code = 3 }, {}), "ctrl", "T2.1 ctrl")
  assert_eq(r("special", { name = "up", ctrl = true }, {}), "history", "T2.1 ctrl+up history")
  assert_eq(r("special", { name = "up" }, {}), "normal:special", "T2.1 plain up is normal")
  assert_eq(r("enter", nil, { palette_active = true, palette_mode = "model" }), "palette:model", "T2.1 palette model")
  assert_eq(r("esc", nil, { palette_active = true, palette_mode = "logout-confirm" }), "palette:logout-confirm", "T2.1 logout-confirm")
  assert_eq(r("tab", nil, { palette_active = true }), "palette:command", "T2.1 palette command default")
  assert_eq(r("tab", nil, {}), "tab_complete", "T2.1 tab completion")
  assert_eq(r("enter", nil, {}), "normal:enter", "T2.1 normal enter")
  assert_eq(r("text", { char = "@" }, {}), "normal:text", "T2.1 normal text")
  -- dispatch shape: every route key forwards to the callback table
  local called = {}
  local cb = { login_secret = function() called[#called + 1] = "secret" end,
    confirmation = function() called[#called + 1] = "confirm" end,
    palette = { model = function() called[#called + 1] = "model" end },
    normal = { enter = function() called[#called + 1] = "enter" end } }
  keys.dispatch["login_secret"]({}, cb, { kind = "text" })
  keys.dispatch["confirmation"]({}, cb, { kind = "enter" })
  keys.dispatch["palette:model"]({}, cb, { kind = "enter" })
  keys.dispatch["normal:enter"]({}, cb, { kind = "enter" })
  assert_eq(table.concat(called, ","), "secret,confirm,model,enter", "T2.1 dispatch forwards bag/callback")
  -- facade exposes the same table (proxy until 2.2)
  local ui = dofile("src/tether/ui.lua")
  assert_eq(ui._key_route({ kind = "enter" }, {}), "normal:enter", "T2.1 facade route proxy")
  assert_true(ui._key_dispatch["mouse"] ~= nil, "T2.1 facade dispatch proxy")
  print("T2.1 dispatch routing: OK")
end

-- Phase B 2.2: call sites ride the table, the facade switch is deleted.
do
  local ui = dofile("src/tether/ui.lua")
  -- every route key resolves to a facade callback (no unhandled branch)
  local keys = { "login_secret", "confirmation", "ask", "error_dismiss",
    "mouse", "ctrl", "history", "tab_complete",
    "palette:copy", "palette:resume", "palette:model", "palette:think",
    "palette:login", "palette:logout", "palette:logout-confirm",
    "palette:mention", "palette:path", "palette:command",
    "normal:paste", "normal:text", "normal:enter", "normal:newline",
    "normal:backspace", "normal:esc", "normal:ctrl", "normal:special" }
  for _, key in ipairs(keys) do
    assert_eq(type(ui._key_dispatch[key]), "function", "T2.2 dispatch owns " .. key)
  end
  -- the switch is gone: handle_key is route + table call, with no
  -- mode comparisons or direct handler calls left inside it.
  local f = io.open("src/tether/ui.lua", "r")
  local src = f:read("*a")
  f:close()
  local s = src:find("handle_key = function(k)", 1, true)
  assert_notnil(s, "T2.2 handle_key found")
  local e = src:find("\nend\n", s)
  local chunk = src:sub(s, e)
  assert_true(chunk:find("M._keys.dispatch", 1, true) ~= nil, "T2.2 handle_key drives the table")
  assert_true(chunk:find("S.palette_mode ==", 1, true) == nil, "T2.2 no mode switch in handle_key")
  assert_true(chunk:find("handle_confirmation_key", 1, true) == nil, "T2.2 no direct confirm call")
  assert_true(chunk:find("handle_ask_key", 1, true) == nil, "T2.2 no direct ask call")
  assert_true(chunk:find("S.login_secret", 1, true) == nil or chunk:find("login_secret = S.login_secret", 1, true) ~= nil,
    "T2.2 secret only travels via flags")
  print("T2.2 table-driven dispatch: OK")
end

-- Phase D 4.1: every S.ask/S.confirmation/palette write is attributed to
-- the OWN block in ui.lua. The test parses the block, scans both sources
-- for write sites (direct, indexed, and a/answer/comp/bag aliases), maps
-- each to its nearest enclosing definition, and fails on any write whose
-- owner is not documented. new_state initial values are exempt by design.
do
  local function read_lines(path)
    local f = assert(io.open(path, "r"))
    local t = {}
    for line in f:lines() do t[#t + 1] = line end
    f:close()
    return t
  end
  local ui_lines = read_lines("src/tether/ui.lua")
  -- documented owners per field, straight from the source of truth
  local expected = {}
  for _, line in ipairs(ui_lines) do
    local field, owners = line:match("^%-%- OWN: (S%.[%a_.*]+) <%- (.*)$")
    if field then
      expected[field] = {}
      for o in owners:gmatch("[^,%s]+") do expected[field][o] = true end
    end
  end
  assert_true(expected["S.ask"] ~= nil, "T4.1 OWN block present")
  local function def_name(line)
    local n = line:match("^%s*local function ([%a_][%w_]*)")
      or line:match("^%s*function (M%.[%a_][%w_]*)")
      or line:match("^%s*([%a_][%w_.]*) ?= ?function")
    if n then
      local slash = n:match("^slash_callbacks%.([%a_]+)$")
      if slash then return "on_slash_" .. slash end
      return n
    end
    return nil
  end
  local scope = { "ask", "ask.*", "confirmation", "confirmation_sel",
    "palette_active", "palette_mode", "palette_items", "palette_sel",
    "palette_query", "palette_skills", "_palette_all", "_in_copy_palette",
    "_in_resume_palette", "_in_model_palette", "_in_think_palette",
    "_in_login_palette", "_in_logout_palette", "_logout_confirm",
    "_logout_sel", "completion", "completion.*" }
  local in_scope = {}
  for _, s in ipairs(scope) do in_scope[s] = true end
  local function check_file(path, bag, ask_alias)
    local lines = read_lines(path)
    local owner, bad = nil, {}
    for i, line in ipairs(lines) do
      local d = def_name(line)
      if d then owner = d end
      if owner ~= "new_state" and owner then
        local function hit(field, why)
          if not in_scope[field] then return end
          local key = "S." .. field
          local set = expected[key]
          if not set then
            bad[#bad + 1] = string.format("%s:%d %s undocumented field", path, i, key)
          elseif not set[owner] then
            bad[#bad + 1] = string.format("%s:%d %s written by %s (%s)",
              path, i, key, owner, why)
          end
        end
        local recv = bag and "bag" or "S"
        for f in line:gmatch(recv .. "%.([%a_][%w_]*)%s*=[^=]") do hit(f, "direct") end
        if line:find(recv .. ".palette_items%s*%[") and line:find("=[^=]", line:find("%[")) then
          hit("palette_items", "append")
        end
        for f in line:gmatch(recv .. "%.completion%.([%a_][%w_]*)%s*=[^=]") do
          hit("completion.*", "sub")
        end
        for f in line:gmatch(recv .. "%.ask%.([%a_][%w_]*)%s*=[^=]") do hit("ask.*", "sub") end
        if not bag then
          for _ in line:gmatch("[^%.%w]a%.[%a_][%w_]*%s*=[^=]") do hit("ask.*", "alias a") end
          for _ in line:gmatch("[^%.%w]answer%.[%a_][%w_]*%s*=[^=]") do hit("ask.*", "alias answer") end
          for _ in line:gmatch("[^%.%w]comp%.[%a_][%w_]*%s*=[^=]") do hit("completion.*", "alias comp") end
        elseif ask_alias then
          for _ in line:gmatch("[^%.%w]a%.[%a_][%w_]*%s*=[^=]") do hit("ask.*", "alias a") end
          for _ in line:gmatch("[^%.%w]answer%.[%a_][%w_]*%s*=[^=]") do hit("ask.*", "alias answer") end
        end
      end
    end
    return bad
  end
  local bad = check_file("src/tether/ui.lua", false, false)
  for _, b in ipairs(check_file("src/tether/ui/auth.lua", true, false)) do bad[#bad + 1] = b end
  for _, b in ipairs(check_file("src/tether/ui/confirm.lua", true, false)) do bad[#bad + 1] = b end
  for _, b in ipairs(check_file("src/tether/ui/ask.lua", true, true)) do bad[#bad + 1] = b end
  if #bad > 0 then
    print("T4.1 unattributed writes:\n  " .. table.concat(bad, "\n  "))
  end
  assert_eq(#bad, 0, "T4.1 every interaction write is owned")
  print("T4.1 S-mutation ownership: OK")
end

if failed > 0 then
    os.exit(1)
end
