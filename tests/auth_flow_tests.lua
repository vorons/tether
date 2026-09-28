-- tests/auth_flow_tests.lua — ui_auth login/logout flows (Phase C 3.2).
-- Run: lua tests/auth_flow_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- Module direct: bag in, S-mutation out, impure edge via deps.
do
  local auth = assert(loadfile("src/tether/ui/auth.lua"))()
  assert_eq(#auth.known_providers(nil), 3, "T3.2 fallback triple")
  assert_eq(auth.known_providers({ ids = function() return { "x" } end })[1], "x", "T3.2 catalog ids")
  assert_true(auth.is_known_provider(nil, "openai"), "T3.2 fallback known")
  assert_true(not auth.is_known_provider(nil, "nope"), "T3.2 fallback unknown")
  assert_true(not auth.is_known_provider(nil, 42), "T3.2 non-string refused")
  assert_true(auth.is_known_provider({ get = function() return {} end }, "custom"), "T3.2 catalog get")

  local noted, bumped = {}, 0
  local deps = { errors = {}, auth = nil, note = function(t) noted[#noted + 1] = t end,
    bump = function() bumped = bumped + 1 end, apply_query = function() end }
  -- logout cluster on a stub bag
  local bag = { palette_active = true, palette_mode = "logout", palette_items = { 1 },
    palette_sel = 2, _in_logout_palette = true, palette_query = "q",
    _palette_all = { 1 }, _logout_confirm = "p", _logout_sel = 2 }
  auth.logout_close(bag)
  assert_eq(bag.palette_mode, "command", "T3.2 close resets mode")
  assert_eq(bag._logout_confirm, nil, "T3.2 close drops confirm state")
  bag.palette_sel = 2
  auth.logout_ask_confirm(bag, "openai")
  assert_eq(bag.palette_mode, "logout-confirm", "T3.2 deletion step opens")
  assert_eq(#bag.palette_items, 2, "T3.2 yes/no rows")
  assert_eq(bag._logout_sel, 2, "T3.2 return row remembered")
  local deleted = {}
  deps.auth = { delete = function(_, p) deleted[#deleted + 1] = p end }
  auth.logout_confirm_accept(bag, deps)
  assert_eq(deleted[1], "openai", "T3.2 accept deletes through the store")
  assert_eq(bag.palette_mode, "command", "T3.2 accept closes")
  assert_true(#noted == 1 and noted[1]:find("logout openai", 1, true) ~= nil, "T3.2 delete notes the transcript")
  assert_eq(bumped, 1, "T3.2 delete bumps")
  -- back path keeps query snapshot semantics
  bag = { palette_mode = "logout-confirm", _logout_confirm = "x", _logout_sel = 3,
    palette_items = { 1, 2, 3 }, palette_sel = 1 }
  local applied = 0
  deps.apply_query = function() applied = applied + 1 end
  auth.logout_confirm_back(bag, deps)
  assert_eq(bag.palette_mode, "logout", "T3.2 back returns to the list")
  assert_eq(bag.palette_sel, 3, "T3.2 back restores the highlight")
  assert_eq(applied, 1, "T3.2 back refilters")
  auth.logout_ask_confirm(bag, nil)
  assert_eq(bag.palette_mode, "logout", "T3.2 nil provider no-ops")

  -- login guards
  assert_eq(auth.submit({ login_provider = nil }, deps, "sk-x"), false, "T3.2 submit needs a provider")
  assert_eq(auth.submit({ login_provider = "openai" }, deps, "   "), false, "T3.2 submit rejects blank")
  local nbag = { cfg = { non_interactive = true } }
  assert_eq(auth.begin(nbag, deps, "openai"), false, "T3.2 non-interactive refused")
  assert_true((nbag.error_banner or "") ~= "", "T3.2 refusal explains itself")
  local sbag = { cfg = {} }
  assert_eq(auth.begin(sbag, { errors = {} }, "openai"), true, "T3.2 begin arms secret mode")
  assert_eq(sbag.login_secret.buf, "", "T3.2 dedicated buffer, never the input")
  assert_eq(auth.poll_tick({ login_flow = nil }, deps), nil, "T3.2 tick idles without a flow")
  local ebag = { login_flow = { device = true, device_code = "c",
    device_token_url = "u", poll_deadline = 0 }, error_banner = nil }
  assert_eq(auth.poll_tick(ebag, { errors = { device_expired = "exp" } }), "failed", "T3.2 deadline fails")
  assert_eq(ebag.error_banner, "exp", "T3.2 expiry explains itself")
  assert_eq(ebag.login_secret, nil, "T3.2 expiry leaves secret mode")
  -- facade parity: the same entry points through ui keep working
  local ui = dofile("src/tether/ui.lua")
  assert_eq(type(ui._auth_flow.begin), "function", "T3.2 facade loads ui_auth")
  assert_eq(type(ui._device_poll_tick), "function", "T3.2 poll seam kept")
  assert_eq(type(ui._logout_delete), "function", "T3.2 logout seam kept")
  print("T3.2 ui_auth direct: OK")
end

-- Phase C 3.3: /login and /logout command bodies live in ui_auth.
do
  local auth = assert(loadfile("src/tether/ui/auth.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local deps = { errors = copy.errors, catalog = nil, auth = nil }
  -- bare /login builds the provider picker, active marked
  local bag = { cfg = { provider = "openai" } }
  auth.login_command(bag, deps, "")
  assert_eq(bag.palette_mode, "login", "T3.3 bare login opens the picker")
  assert_eq(#bag.palette_items, 3, "T3.3 fallback triple listed")
  assert_eq(bag.palette_items[1].desc, "active", "T3.3 active provider marked")
  -- unknown provider explains itself
  bag = { cfg = {} }
  auth.login_command(bag, deps, "nope")
  assert_true((bag.error_banner or ""):find("nope", 1, true) ~= nil, "T3.3 unknown provider banner")
  -- non-interactive refused
  bag = { cfg = { non_interactive = true } }
  auth.login_command(bag, deps, "")
  assert_true((bag.error_banner or "") ~= "", "T3.3 non-interactive refused")
  -- bare /logout with an empty store is a state, not a failure
  bag = { cfg = {} }
  deps.auth = { load = function() return {} end }
  auth.logout_command(bag, deps, "")
  assert_true((bag.error_banner or "") ~= "", "T3.3 empty store banner")
  assert_eq(bag.palette_active, nil, "T3.3 picker stays closed on empty store")
  -- bare /logout lists stored credentials, active marked
  bag = { cfg = { provider = "openai" } }
  deps.auth = { load = function()
    return { openai = { kind = "api_key" }, gemini = { kind = "oauth" } }
  end }
  auth.logout_command(bag, deps, "")
  assert_eq(bag.palette_mode, "logout", "T3.3 bare logout opens the picker")
  assert_eq(#bag.palette_items, 2, "T3.3 stored providers listed")
  -- named /logout on a missing entry reports honestly (known provider,
  -- nothing stored under it)
  bag = { cfg = {} }
  auth.logout_command(bag, deps, "anthropic")
  assert_true((bag.error_banner or ""):find("anthropic", 1, true) ~= nil, "T3.3 missing entry banner")
  print("T3.3 login/logout command bodies: OK")
end

if failed > 0 then
    os.exit(1)
end
