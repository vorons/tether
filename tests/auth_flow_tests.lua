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

-- T3.4: loopback-callback login — begin opens the listener, the tick
-- consumes a matching callback into the exchange path, mismatch/timeout/
-- abort/paste keep the secret prompt with the listener freed.
do
  local auth = assert(loadfile("src/tether/ui/auth.lua"))()
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  local freed = {}
  local step_ret = { "waiting" }
  local aborted = false
  local host = {
    oauth_wait_start = function() return { id = "w" } end,
    oauth_wait_info = function(h) return 4567, "state-abc" end,
    oauth_wait_step = function(h) return step_ret[1], step_ret[2], step_ret[3] end,
    oauth_wait_free = function(h) freed[#freed + 1] = h return true end,
    abort_requested = function() return aborted end,
  }
  local noted = {}
  local stored, exchanged = nil, nil
  local deps = {
    errors = copy.errors,
    catalog = catalog,
    load_provider = function(name) return nil end, -- force the generic flow
    auth = { set = function(_, p, entry) stored = entry return true end },
    common = {
      url_decode = function(s) return s end,
      oauth_token_exchange = function(post, flow, code, now)
        exchanged = { flow = flow, code = code }
        return { kind = "oauth", access_token = "at-cb" }
      end,
    },
    host = host,
    note = function(t) noted[#noted + 1] = t end,
    bump = function() end,
  }
  local function oauth_cfg(extra)
    local cfg = { providers = { radius = {
      oauth_client_id = "cid-a",
      oauth_token_url = "https://example.com/token",
      oauth_authorize_url = "https://example.com/auth",
    } } }
    if extra then for k, v in pairs(extra) do cfg[k] = v end end
    return cfg
  end
  -- begin opens the listener and authorizes against its URI
  local bag = { cfg = oauth_cfg() }
  assert_true(auth.begin(bag, deps, "radius"), "T3.4 begin arms secret mode")
  assert_notnil(bag.login_wait, "T3.4 listener opened")
  assert_eq(bag.cfg._oauth_loopback.uri, "http://127.0.0.1:4567/",
    "T3.4 channel carries the listener URI")
  assert_notnil(bag.login_flow, "T3.4 flow built")
  assert_true((bag.login_flow.authorize_url or ""):find("127.0.0.1", 1, true) ~= nil,
    "T3.4 authorize URL points at the listener")
  assert_true((bag.login_flow.authorize_url or ""):find("state=state%-abc", 1) ~= nil,
    "T3.4 authorize URL carries state")
  -- matching callback auto-exchanges, stores, and frees the wait
  step_ret = { "code", "authcode-9", "state-abc" }
  assert_eq(auth.poll_tick(bag, deps), "granted", "T3.4 matching callback granted")
  assert_eq(stored and stored.access_token, "at-cb", "T3.4 callback token stored")
  assert_eq(exchanged and exchanged.code, "authcode-9", "T3.4 exchanged code")
  assert_eq(exchanged and exchanged.flow.redirect_uri, "http://127.0.0.1:4567/",
    "T3.4 exchange posts the authorizing URI")
  assert_eq(bag.login_wait, nil, "T3.4 wait freed after consume")
  assert_eq(bag.cfg._oauth_loopback, nil, "T3.4 channel cleared after consume")
  assert_eq(#freed, 1, "T3.4 listener freed once")
  -- mismatch banners, keeps the prompt, frees the single-shot wait
  freed = {}
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  step_ret = { "code", "evil", "wrong-state" }
  assert_eq(auth.poll_tick(bag, deps), "pending", "T3.4 mismatch pends")
  assert_eq(bag.error_banner, copy.errors.oauth_state_mismatch,
    "T3.4 mismatch bannered")
  assert_notnil(bag.login_secret, "T3.4 prompt stays open for paste")
  assert_eq(stored.access_token, "at-cb", "T3.4 mismatch exchanges nothing")
  assert_eq(bag.login_wait, nil, "T3.4 single-shot wait freed on mismatch")
  -- timeout falls back to paste with a note, prompt stays
  freed = {}
  noted = {}
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  bag.login_wait_deadline = os.time() - 1
  assert_eq(auth.poll_tick(bag, deps), "pending", "T3.4 timeout pends")
  assert_notnil(bag.login_secret, "T3.4 prompt stays open after timeout")
  assert_eq(bag.login_wait, nil, "T3.4 wait freed on timeout")
  assert_true(#noted == 1 and noted[1]:find("timed out", 1, true) ~= nil,
    "T3.4 timeout noted")
  -- abort ends the wait the same way
  freed = {}
  noted = {}
  aborted = true
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  assert_eq(auth.poll_tick(bag, deps), "pending", "T3.4 abort pends")
  assert_eq(bag.login_wait, nil, "T3.4 wait freed on abort")
  assert_true(#noted == 1 and noted[1]:find("aborted", 1, true) ~= nil,
    "T3.4 abort noted")
  aborted = false
  -- pasting while the wait is open wins and frees the listener
  freed = {}
  stored = nil
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  local w = bag.login_wait
  assert_notnil(w, "T3.4 wait open before paste")
  assert_true(auth.submit(bag, deps, "pasted-code-1"), "T3.4 paste submits")
  assert_eq(freed[#freed], w, "T3.4 paste frees the open wait")
  assert_eq(exchanged.code, "pasted-code-1", "T3.4 pasted code exchanged")
  -- fixed override bypasses the listener entirely
  freed = {}
  bag = { cfg = oauth_cfg({ providers = { radius = {
    oauth_client_id = "cid-a",
    oauth_token_url = "https://example.com/token",
    oauth_authorize_url = "https://example.com/auth",
    oauth_redirect_uri = "http://localhost:7777/",
  } } }) }
  auth.begin(bag, deps, "radius")
  assert_eq(bag.login_wait, nil, "T3.4 override keeps no listener")
  assert_eq(#freed, 1, "T3.4 unused listener freed again")
  assert_true((bag.login_flow.authorize_url or ""):find("localhost%3A7777", 1, true) ~= nil,
    "T3.4 override URI in the authorize link")
  -- T337 (audit M3): a code callback with no recorded state is a mismatch.
  -- The old check only compared when flow.state was a non-empty string, so
  -- a flow that recorded nothing silently granted whatever arrived.
  freed = {}
  stored = { access_token = "at-cb" }
  exchanged = nil
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  bag.login_flow.state = nil
  step_ret = { "code", "authcode-9", "state-abc" }
  assert_eq(auth.poll_tick(bag, deps), "pending", "T337 no recorded state pends")
  assert_eq(bag.error_banner, copy.errors.oauth_state_mismatch,
    "T337 no recorded state bannered")
  assert_eq(exchanged, nil, "T337 no recorded state exchanges nothing")
  assert_eq(stored.access_token, "at-cb", "T337 no recorded state stores nothing")
  assert_notnil(bag.login_secret, "T337 prompt stays open for paste")
  print("T337 callback with no recorded state is rejected: OK")

  -- no host support degrades to paste-only with no channel
  freed = {}
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, { errors = copy.errors, catalog = catalog,
    load_provider = function(name) return nil end,
    auth = deps.auth, common = deps.common, host = {},
    note = deps.note, bump = deps.bump }, "radius")
  assert_notnil(bag.login_flow, "T3.4 flow kept for paste without host support")
  assert_true(bag.login_flow.authorize_url == nil,
    "T3.4 no dead link without a listener")
  assert_eq(bag.cfg._oauth_loopback, nil, "T3.4 no channel without a listener")
  assert_eq(#freed, 0, "T3.4 nothing to free without a listener")
  -- second begin closes the first listener; cancel frees too
  freed = {}
  bag = { cfg = oauth_cfg() }
  auth.begin(bag, deps, "radius")
  local w1 = bag.login_wait
  auth.begin(bag, deps, "radius")
  assert_eq(freed[1], w1, "T3.4 second begin frees the first wait")
  assert_true(bag.login_wait ~= nil and bag.login_wait ~= w1,
    "T3.4 second begin opens a fresh wait")
  local w2 = bag.login_wait
  auth.cancel(bag)
  assert_eq(bag.login_wait, nil, "T3.4 cancel drops the wait")
  assert_eq(bag.cfg._oauth_loopback, nil, "T3.4 cancel clears the channel")
  assert_eq(freed[#freed], w2, "T3.4 cancel frees through the stashed host")
  print("T3.4 loopback-callback login: OK")
end

if failed > 0 then
    os.exit(1)
end
