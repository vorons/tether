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

if failed > 0 then
    os.exit(1)
end
