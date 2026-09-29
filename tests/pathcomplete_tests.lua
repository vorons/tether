-- tests/pathcomplete_tests.lua — path completion + nested catalog/auth/listing (one outer block) (split from lua_tests.lua, Phase C).
-- Run: lua tests/pathcomplete_tests.lua

dofile("tests/helpers.lua")
-- T74: 4.2/4.3/4.4 — path completion via Tab.
-- Stubs tools.path_complete via M._tools_stub (no filesystem access).
-- run_ui_with() types characters during run(); manual calls to
-- M._path_complete_tab() / M._handle_key() drive the completion logic
-- after run() has set up S.

local fixture_ws = "/tmp/tw/test"
do
  -- Simulated fixture directory contents:
  --   file1.txt  file2.txt  sub2/ (contains inner.lua)
  -- dir candidates in the real tools module get a trailing "/"
  -- (tools.lua is_dir heuristic). The stub mirrors that convention.
  local tools_stub = {}
  local function path_complete_stub(token, _cfg)
    local clean = token:gsub("^@", "")
    local dir, filepfx
    local slash = clean:match("^(.*)/")
    if slash then dir, filepfx = slash, clean:sub(#slash + 2)
    else dir, filepfx = "", clean end
    -- entries keyed by dir-without-trailing-slash (or "" for root)
    local entries = {
      [""]     = { "file1.txt", "file2.txt", "sub2/" },
      ["sub2"] = { "sub2/inner.lua" },  -- full path label as tools returns
    }
    local out = {}
    for _, c in ipairs(entries[dir] or {}) do
      if c:sub(1, #filepfx) == filepfx then out[#out + 1] = c end
    end
    table.sort(out)
    return { candidates = out, truncated = false }
  end
  tools_stub.path_complete = path_complete_stub

  local function cfg_stubs(pc)
    return { config = { load = function() return {
        model = "test", workspace = fixture_ws,
        ui = { input_max_lines = 8, path_completion = pc } } end,
      api_key = function() return "" end } }
  end

  -- Run the harness with the given bytes (characters + Ctrl+Q to exit),
  -- then inject the stub. The Tab keypresses in `bytes` are processed by
  -- the real handle_key during run() — at that point M._tools_stub is nil and
  -- neither the `tools` global nor require("tools") resolves in the harness,
  -- so path_complete_tab is a no-op and the command-palette branch handles
  -- Tab (existing 3.3 behavior).
  local function run_and_state(bytes, pc)
    local ui_mod = assert((function()
      local m, _ = run_ui_with(bytes, cfg_stubs(pc))
      return m
    end)())
    ui_mod._tools_stub = tools_stub
    return ui_mod, ui_mod._get_state()
  end

  -- 4.3b: Tab inside an open command palette keeps command-completion
  -- meaning (existing 3.3/3.4/3.5 behavior, not changed by 4.2).
  do
    local ui_mod, S = run_and_state({ 47, 9, 17 }, true)
    assert_eq(S.input, "/clear ", "T74 cmd-palette: Tab completed /clear")
    assert_eq(S.palette_mode, "command", "T74 cmd-palette: mode stays 'command'")
    assert_eq(S.palette_active, false, "T74 cmd-palette: space closed palette")
  end

  -- 4.2a: multiple candidates open the path palette, first applied.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.palette_mode, "path", "T74 multi: palette mode is 'path'")
    assert_eq(S.palette_active, true, "T74 multi: palette active")
    assert_eq(#S.palette_items, 2, "T74 multi: two candidates listed")
    assert_eq(S.input, "file1.txt", "T74 multi: first candidate applied")
    assert_eq(S.cursor, #S.input, "T74 multi: cursor sits after the applied candidate")
  end

  -- 1.1: with text after the token the cursor stops before it, not at the end
  do
    local ui_mod, S = run_and_state({ 102, 105, 61, 17 }, true) -- "fi="
    S.cursor = 2 -- the cursor sits inside the token, so "=" is the tail
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "file1.txt=", "T74 tail: only the token was replaced")
    assert_eq(S.cursor, 9, "T74 tail: cursor stops before the text after the token")
  end

  -- 1.4: a unique candidate completes the token in place — the text after the
  -- token survives (the one-shot branch used to drop it and lose typed text).
  do
    local ui_mod, S = run_and_state({ 102, 105, 108, 101, 49, 61, 17 }, true) -- "file1="
    S.cursor = 5 -- the cursor sits after "file1", so "=" is the tail
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "file1.txt=", "T74 unique-tail: text after the token survives")
    assert_eq(S.cursor, 9, "T74 unique-tail: cursor stops before the text after the token")
    assert_eq(S.palette_active, false, "T74 unique-tail: unique candidate opens no palette")
  end

  -- 4.2c: Tab cycles to second candidate (via handle_key, not path_complete_tab
  -- which returns early when palette_active).
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, sel=1, input="file1.txt"
    ui_mod._handle_key({ kind = "tab" })      -- cycle, sel=2, input="file2.txt"
    S = ui_mod._get_state()
    assert_eq(S.input, "file2.txt", "T74 cycle: second Tab wraps to file2.txt")
    assert_eq(S.palette_active, true, "T74 cycle: palette still open")
    assert_eq(S.cursor, #S.input, "T74 cycle: cursor follows the cycled candidate")
  end

  -- 4.2d: Esc restores the token as typed.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, input="file1.txt"
    ui_mod._handle_key({ kind = "tab" })      -- cycle, input="file2.txt"
    ui_mod._handle_key({ kind = "esc" })       -- cancel, input="fi"
    S = ui_mod._get_state()
    assert_eq(S.input, "fi", "T74 Esc: token restored to typed value")
    assert_eq(S.cursor, #S.input, "T74 Esc: cursor sits after the restored token")
    assert_eq(S.palette_active, false, "T74 Esc: palette closed")
    assert_eq(S.palette_mode, "command", "T74 Esc: mode reset to 'command'")
  end

  -- 4.2e: Enter on the path palette applies the selected path + space.
  do
    local ui_mod, S = run_and_state({ 102, 105, 17 }, true)
    ui_mod._path_complete_tab()               -- open, sel=1
    ui_mod._handle_key({ kind = "tab" })      -- cycle, sel=2, input="file2.txt"
    ui_mod._handle_key({ kind = "enter" })    -- commit, input="file2.txt "
    S = ui_mod._get_state()
    assert_eq(S.input, "file2.txt ", "T74 Enter: selected path applied + space")
    assert_eq(S.completion, nil, "T74 Enter: completion state cleared")
  end

  -- 4.3: disabled — ui.path_completion=false → Tab is a no-op.
  do
    local ui_mod, S = run_and_state({ 102, 17 }, false)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "f", "T74 disabled: input unchanged")
    assert_eq(S.palette_active, false, "T74 disabled: no palette")
    assert_eq(S.palette_mode, "command", "T74 disabled: mode stays 'command'")
  end

  -- 4.4: dir candidate gets trailing / — "s" + Tab → "sub2/".
  do
    local ui_mod, S = run_and_state({ 115, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "sub2/", "T74 dir: trailing slash applied")
    assert_eq(S.palette_active, false, "T74 dir: unique dir completes in place")
  end

  -- 4.4b: completing inside a dir — "sub2/" + Tab → "sub2/inner.lua".
  do
    local ui_mod, S = run_and_state({ 115, 117, 98, 50, 47, 17 }, true)
    ui_mod._path_complete_tab()
    S = ui_mod._get_state()
    assert_eq(S.input, "sub2/inner.lua", "T74 dir-inside: entry listed inside sub2/")
    assert_eq(S.palette_active, false, "T74 dir-inside: unique candidate in place")
  end

-- T161: provider catalog + alias dispatch + per-preset headers
do
  local catalog = assert(loadfile("src/tether/providers/catalog.lua"))()
  -- dynamic-provider-catalog: Tier-A arrives via the pipeline cache; seed
  -- the merged view with a fixture (bootstrap alone has 9 locals + Tier-B).
  local tier_a = {
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini" },
    anthropic = { wire = "anthropic", base_url = "https://api.anthropic.com",
      api_key_env = "ANTHROPIC_API_KEY", model = "claude-x" },
    gemini = { wire = "gemini", base_url = "https://generativelanguage.googleapis.com",
      api_key_env = "GEMINI_API_KEY", model = "gemini-x" },
    deepseek = { wire = "openai", base_url = "https://api.deepseek.com",
      api_key_env = "DEEPSEEK_API_KEY", model = "deepseek-chat" },
    groq = { wire = "openai", base_url = "https://api.groq.com/openai/v1",
      api_key_env = "GROQ_API_KEY", model = "llama-3.3-70b-versatile" },
    agnes = { wire = "openai", base_url = "https://apihub.agnes-ai.com/v1",
      api_key_env = "AGNES_API_KEY", model = "agnes-2.5-flash" },
    ["agnes-cn"] = { wire = "openai", base_url = "https://api.agnes-ai.cn/v1",
      api_key_env = "AGNES_CN_API_KEY", model = "agnes-2.5-flash" },
    ["kimi-coding"] = { wire = "anthropic", base_url = "https://api.kimi.com/coding",
      api_key_env = "KIMI_API_KEY", model = "kimi-for-coding" },
    minimax = { wire = "anthropic", base_url = "https://api.minimax.io/anthropic",
      api_key_env = "MINIMAX_API_KEY", model = "MiniMax-M2.7" },
  }
  catalog.set_overlay(tier_a, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catalog
  assert_eq(catalog.count(), 9 + 9, "T162 merged bootstrap plus cache")
  local ids = catalog.ids()
  assert_eq(ids[1], "openai", "T162 big three pinned first")
  assert_eq(ids[2], "anthropic", "T162 pin 2")
  assert_eq(ids[3], "gemini", "T162 pin 3")
  assert_eq(catalog.get("deepseek").wire, "openai", "T162 deepseek alias")
  assert_eq(catalog.get("agnes").wire, "openai", "T162 agnes alias")
  assert_eq(catalog.get("agnes-cn").base_url, "https://api.agnes-ai.cn/v1",
    "T162 agnes-cn base")
  assert_eq(catalog.get("agnes").api_key_env, "AGNES_API_KEY", "T162 agnes env")
  assert_eq(catalog.get("kimi-coding").wire, "anthropic", "T162 kimi alias")
  assert_eq(catalog.get("amazon-bedrock").wire, "amazon-bedrock", "T162 bedrock adapter")
  assert_eq(catalog.get("nope"), nil, "T162 unknown id nil")

  local api = assert(loadfile("src/tether/api.lua"))()
  -- alias keeps provider identity, shares the wire module
  assert_eq(api._provider_of({ provider = "groq" }), "groq", "T162 groq identity")
  assert_eq(api._wire_module({ provider = "groq" }).name, "openai", "T162 groq on openai wire")
  assert_eq(api._wire_module({ provider = "minimax" }).name, "anthropic", "T162 minimax on anthropic wire")
  assert_eq(api._wire_module({}).name, "openai", "T162 default wire")

  local openai = assert(loadfile("src/tether/providers/openai.lua"))()
  -- opencode session routing header (pi opencode-headers.ts)
  -- zen-honest-headers: full honest set (session trio + identity pair)
  local ohl = openai.header_lines("k", { provider = "opencode", session_id = "s-1" })
  local has_session, has_sid, has_aff = false, false, false
  local has_ua, has_client, has_project = false, false, false
  for _, ln in ipairs(ohl) do
    if ln == "x-opencode-session: s-1" then has_session = true end
    if ln == "X-Session-Id: s-1" then has_sid = true end
    if ln == "x-session-affinity: s-1" then has_aff = true end
    if ln == "User-Agent: tether" then has_ua = true end
    if ln == "x-opencode-client: tether" then has_client = true end
    if ln:find("x-opencode-project", 1, true) then has_project = true end
    assert_true(ln:find("HTTP-Referer", 1, true) == nil, "T162 no attribution headers")
  end
  assert_true(has_session and has_sid and has_aff, "T162 opencode session trio")
  assert_true(has_ua and has_client, "T162 opencode honest identity")
  assert_true(not has_project, "T162 no x-opencode-project")
  local ohl2 = openai.header_lines("k", { provider = "opencode" })
  assert_eq(#ohl2, 3, "T162 session trio omitted (never empty) without session id")
  local ohl2_ua, ohl2_client = false, false
  for _, ln in ipairs(ohl2) do
    if ln == "User-Agent: tether" then ohl2_ua = true end
    if ln == "x-opencode-client: tether" then ohl2_client = true end
    assert_true(ln:find("x-opencode-session", 1, true) == nil, "T162 no session header without id")
    assert_true(ln:find("X-Session-Id", 1, true) == nil, "T162 no X-Session-Id without id")
    assert_true(ln:find("x-session-affinity", 1, true) == nil, "T162 no affinity without id")
    assert_true(ln:find("x-opencode-project", 1, true) == nil, "T162 no project without id")
  end
  assert_true(ohl2_ua and ohl2_client, "T162 identity pair present without session id")
  local ogo = openai.header_lines("k", { provider = "opencode-go", session_id = "s-2" })
  local go_sid, go_client = false, false
  for _, ln in ipairs(ogo) do
    if ln == "X-Session-Id: s-2" then go_sid = true end
    if ln == "x-opencode-client: tether" then go_client = true end
  end
  assert_true(go_sid and go_client, "T162 opencode-go shares honest header set")
  -- copilot dynamic headers (pi github-copilot-headers.ts)
  local chl = openai.header_lines("k", { provider = "github-copilot",
    messages = { { role = "user", content = "hi" } } })
  local saw_init, saw_intent = false, false
  for _, ln in ipairs(chl) do
    if ln == "X-Initiator: user" then saw_init = true end
    if ln == "Openai-Intent: conversation-edits" then saw_intent = true end
  end
  assert_true(saw_init and saw_intent, "T162 copilot user-initiated headers")
  local chl2 = openai.header_lines("k", { provider = "github-copilot",
    messages = { { role = "user", content = "hi" }, { role = "assistant", content = "ok" } } })
  local saw_agent = false
  for _, ln in ipairs(chl2) do if ln == "X-Initiator: agent" then saw_agent = true end end
  assert_true(saw_agent, "T162 copilot agent initiator after assistant message")

  local anthropic = assert(loadfile("src/tether/providers/anthropic.lua"))()
  local bhl = anthropic.header_lines("k", { auth_style = "bearer" })
  assert_eq(#bhl, 1, "T162 bearer single header")
  assert_true(bhl[1] == "Authorization: Bearer k", "T162 bearer shape")
  local khl = anthropic.header_lines("k")
  assert_true(khl[1] == "x-api-key: k", "T162 key shape unchanged without ctx")

  -- {VAR} URL templates expand from cfg.provider_env, else fail named
  do
    local old = _G.tether
    local got_url = nil
    _G.tether = host_mock{
      http_get = function(url) got_url = url; return '{"data":[{"id":"m"}]}', nil end,
      http_stream = function() return true end,
      sleep = function() end,
    }
    local res = api.list_models_live({
      provider = "cloudflare-workers-ai",
      base_url = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
      provider_env = { CLOUDFLARE_ACCOUNT_ID = "acc123" },
    }, "key")
    _G.tether = old
    assert_true(res ~= nil and res[1].id == "m", "T162 template expands from provider_env")
    assert_true(got_url:find("accounts/acc123/ai/v1/models", 1, true) ~= nil,
      "T162 expanded URL correct")
  end
  do
    local old = _G.tether
    _G.tether = host_mock{
      http_get = function() return nil, "must not be called" end,
      http_stream = function() return true end,
      sleep = function() end,
    }
    local res, err = api.list_models_live({
      provider = "cloudflare-workers-ai",
      base_url = "https://x/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
    }, "key")
    _G.tether = old
    assert_eq(res, nil, "T162 unexpanded placeholder fails")
    assert_true(tostring(err):find("CLOUDFLARE_ACCOUNT_ID", 1, true) ~= nil,
      "T162 failure names the missing piece")
  end
  print("T162 catalog + alias + headers: OK")
  _G.provider_catalog = orig_catalog
end

-- T278 (at-file-picker 2.1-2.5): the `@` trigger. Stub-driven through
-- M._tools_stub like T74, so the UI layer is tested without a filesystem.
do
    local mention_entries = {
        "src/tether/ui.lua", "src/tether/providers/gemini.lua",
        "src/tether/providers/openai.lua", "tests/ui.lua", "src/tether/",
    }
    local lookups = {}
    local mention_stub = {}
    -- The stub mirrors tools.path_complete's contract, cache field included:
    -- the first call of a session gets nil, later ones get the bundle back.
    function mention_stub.path_complete(token, _cfg, cache)
        lookups[#lookups + 1] = { token = token, cache = cache }
        local q = (token:gsub("^@", "")):lower()
        local out = {}
        for _, c in ipairs(mention_entries) do
            if q == "" or c:lower():find(q, 1, true) then out[#out + 1] = c end
        end
        return { candidates = out, truncated = false, cache = cache or { n = 1 } }
    end

    local function cfg_at(pc)
        return { config = { load = function() return {
            model = "test", workspace = "/tmp/tw/test",
            ui = { input_max_lines = 8, path_completion = pc } } end,
            api_key = function() return "" end } }
    end
    local function picker(pc)
        local ui_mod = assert((function()
            local m, _ = run_ui_with({ 17 }, cfg_at(pc))
            return m
        end)())
        ui_mod._tools_stub = mention_stub
        return ui_mod
    end
    local function type(ui_mod, s)
        for c in s:gmatch(".") do
            ui_mod._handle_key({ kind = "text", char = c })
        end
    end
    local function fresh() lookups = {} end

    -- 2.1: "@" at a token start opens the palette and applies nothing.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@")
        local S = ui_mod._get_state()
        assert_eq(S.input, "@", "T278 open: input holds only what was typed")
        assert_eq(S.cursor, 1, "T278 open: cursor untouched")
        assert_eq(S.palette_active, true, "T278 open: palette opened")
        assert_eq(S.palette_mode, "mention", "T278 open: palette mode is 'mention'")
        assert_eq(#S.palette_items, 5, "T278 open: every candidate listed")
        assert_eq(S.palette_items[1].label, "src/tether/ui.lua",
            "T278 open: the highlight previews, nothing is inserted")
    end

    -- 2.2: an "@" inside a token is ordinary text.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "voron@")
        local S = ui_mod._get_state()
        assert_eq(S.input, "voron@", "T278 mid: the @ stayed text")
        assert_eq(S.palette_active, false, "T278 mid: no palette opened")
        assert_eq(#lookups, 0, "T278 mid: the lookup never ran")
    end

    -- 2.3 + 3.1: each later character re-filters the open session, and the
    -- session's cached walk is handed back instead of taken again.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "read @ge")
        local S = ui_mod._get_state()
        assert_eq(S.input, "read @ge", "T278 filter: input holds only typed text")
        assert_eq(S.palette_active, true, "T278 filter: palette stayed open")
        assert_eq(S.palette_mode, "mention", "T278 filter: mode stayed 'mention'")
        assert_eq(#S.palette_items, 1, "T278 filter: narrowed to one candidate")
        assert_eq(S.palette_items[1].label, "src/tether/providers/gemini.lua",
            "T278 filter: a deep file listed from its basename")
        assert_eq(#lookups, 3, "T278 filter: one lookup per keystroke of the token")
        assert_eq(lookups[1].cache, nil, "T278 filter: the session starts uncached")
        assert_notnil(lookups[3].cache, "T278 filter: the cached walk came back")
        -- 2.4 (spec): a single candidate still lists under the @ trigger
        assert_eq(S.palette_active, true, "T278 single: one candidate still opens")
    end

    -- 2.4: the arrows move the highlight without touching the input; Enter and
    -- Tab both insert the highlighted path and close the preview.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@ui")
        local S = ui_mod._get_state()
        assert_eq(#S.palette_items, 2, "T278 tab: two candidates listed")
        local before = S.input
        ui_mod._handle_key({ kind = "special", name = "down" })
        S = ui_mod._get_state()
        assert_eq(S.palette_sel, 2, "T278 arrows: down moves the highlight")
        assert_eq(S.input, before, "T278 arrows: input untouched")
        ui_mod._handle_key({ kind = "special", name = "up" })
        S = ui_mod._get_state()
        assert_eq(S.palette_sel, 1, "T278 arrows: up moves the highlight")
        assert_eq(S.input, before, "T278 arrows: input still untouched")
        ui_mod._handle_key({ kind = "enter" })
        S = ui_mod._get_state()
        assert_eq(S.input, "@src/tether/ui.lua",
            "T278 enter: highlighted path inserted")
        assert_eq(S.cursor, 18, "T278 enter: cursor sits after the inserted path")
        assert_eq(S.palette_active, false, "T278 enter: palette closed")
        assert_eq(S.palette_mode, "command", "T278 enter: mode reset")
        assert_eq(S.completion, nil, "T278 enter: session dropped")
    end

    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@ui")
        ui_mod._handle_key({ kind = "special", name = "down" })
        ui_mod._handle_key({ kind = "tab" })
        local S = ui_mod._get_state()
        assert_eq(S.input, "@tests/ui.lua", "T278 tab: Tab inserts the highlighted path")
        assert_eq(S.cursor, 13, "T278 tab: cursor sits after the inserted path")
        assert_eq(S.palette_active, false, "T278 tab: palette closed")
        assert_eq(S.palette_mode, "command", "T278 tab: mode reset")
        assert_eq(S.completion, nil, "T278 tab: session dropped")
    end

    -- Enter mid-sentence keeps the text on both sides of the mention.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "read @g")
        ui_mod._handle_key({ kind = "enter" })
        local S = ui_mod._get_state()
        assert_eq(S.input, "read @src/tether/providers/gemini.lua",
            "T278 midline: only the token was replaced")
        assert_eq(S.cursor, #S.input, "T278 midline: cursor after the inserted path")
    end

    -- Esc leaves exactly what the user typed (nothing was ever applied).
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@u")
        ui_mod._handle_key({ kind = "special", name = "down" })
        ui_mod._handle_key({ kind = "esc" })
        local S = ui_mod._get_state()
        assert_eq(S.input, "@u", "T278 esc: typed text kept")
        assert_eq(S.cursor, 2, "T278 esc: cursor unchanged")
        assert_eq(S.palette_active, false, "T278 esc: palette closed")
        assert_eq(S.palette_mode, "command", "T278 esc: mode reset")
    end

    -- 2.3: erasing back through the "@" closes the palette.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@ui")
        local S = ui_mod._get_state()
        assert_eq(#S.palette_items, 2, "T278 erase: filtered to the ui pair")
        ui_mod._handle_key({ kind = "backspace" })
        S = ui_mod._get_state()
        assert_eq(S.input, "@u", "T278 erase: one character removed")
        assert_eq(S.palette_active, true, "T278 erase: still open")
        assert_eq(#S.palette_items, 4, "T278 erase: widened as the token shrank")
        ui_mod._handle_key({ kind = "backspace" })
        S = ui_mod._get_state()
        assert_eq(#S.palette_items, 5, "T278 erase: the bare @ lists everything")
        assert_eq(S.palette_active, true, "T278 erase: @ still opens")
        ui_mod._handle_key({ kind = "backspace" })
        S = ui_mod._get_state()
        assert_eq(S.input, "", "T278 erase: the mention is gone")
        assert_eq(S.palette_active, false, "T278 erase: palette closed")
        assert_eq(S.palette_mode, "command", "T278 erase: mode reset")
        assert_eq(S.completion, nil, "T278 erase: session dropped")
    end

    -- 2.5: ui.path_completion=false makes both triggers inert.
    do
        fresh()
        local ui_mod = picker(false)
        type(ui_mod, "@u")
        local S = ui_mod._get_state()
        assert_eq(S.input, "@u", "T278 disabled: @ stayed ordinary text")
        assert_eq(S.palette_active, false, "T278 disabled: no palette")
        assert_eq(#lookups, 0, "T278 disabled: the lookup never ran")
        ui_mod._handle_key({ kind = "tab" })
        S = ui_mod._get_state()
        assert_eq(S.input, "@u", "T278 disabled: Tab applied nothing")
        assert_eq(S.palette_active, false, "T278 disabled: Tab opened nothing")
    end

    -- 3.2: closing the picker drops the session, so reopening walks again.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@ui")
        ui_mod._handle_key({ kind = "esc" })
        ui_mod._handle_key({ kind = "esc" }) -- the first closed the picker, this clears the line
        type(ui_mod, "@ui")
        assert_eq(#lookups, 6, "T278 reopen: three keystrokes per session")
        assert_eq(lookups[1].cache, nil, "T278 reopen: a session starts uncached")
        assert_notnil(lookups[2].cache, "T278 reopen: the session runs cached")
        assert_eq(lookups[4].cache, nil, "T278 reopen: the closed session was dropped")
    end

    -- Cursor keys keep working while the preview is open: the token the
    -- cursor sits inside is what gets filtered.
    do
        fresh()
        local ui_mod = picker(true)
        type(ui_mod, "@ui")
        ui_mod._handle_key({ kind = "special", name = "left" })
        local S = ui_mod._get_state()
        assert_eq(S.cursor, 2, "T278 cursor: Left moved inside the token")
        assert_eq(S.input, "@ui", "T278 cursor: the input is unchanged")
        assert_eq(S.palette_active, true, "T278 cursor: still previewing")
        assert_eq(#S.palette_items, 4, "T278 cursor: filtered on the shorter token")
    end

    -- 2.6: the mention palette says what it does.
    do
        local ui_mod = picker(true)
        type(ui_mod, "@u")
        local S = ui_mod._get_state()
        assert_eq(S.palette_mode, "mention", "T278 hints: mode is 'mention'")
        assert_notnil(ui_mod.PALETTE_HINTS.mention, "T278 hints: mention hints exist")
        local hp = ui_mod.PALETTE_HINTS.mention
        local text = table.concat((function()
            local t = {}
            for _, p in ipairs(hp) do t[#t + 1] = p.key .. " " .. p.act end
            return t
        end)(), "  ")
        assert_true(text:find("enter/tab insert", 1, true) ~= nil,
            "T278 hints: both insert keys are advertised: " .. text)
        assert_true(not text:find("cycle", 1, true),
            "T278 hints: nothing promises a walk without applying: " .. text)
    end
    print("T278 @ picker: trigger, filter, insert, gate: OK")
end

-- T163: catalog defaults wired into config
do  -- dynamic-provider-catalog: seed the merged view (config snapshots it).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    deepseek = { wire = "openai", base_url = "https://api.deepseek.com",
      api_key_env = "DEEPSEEK_API_KEY", model = "deepseek-chat", _source = "test" },
    ["kimi-coding"] = { wire = "anthropic", base_url = "https://api.kimi.com/coding",
      api_key_env = "KIMI_API_KEY", model = "kimi-for-coding", _source = "test" },
    ["xiaomi-token-plan-sgp"] = { wire = "openai",
      base_url = "https://token-plan-sgp.xiaomimimo.com/v1",
      api_key_env = "XIAOMI_TOKEN_PLAN_SGP_API_KEY", model = "mimo-7b", _source = "test" },
    xai = { wire = "openai", base_url = "https://api.x.ai/v1",
      api_key_env = "XAI_API_KEY", model = "grok-4.6", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local cfgm = dofile("src/tether/config.lua")
  local function load_tbl(t)
    local p = "/tmp/tether_cfg_t163.lua"
    local f = io.open(p, "w")
    f:write("return " .. t)
    f:close()
    local c = cfgm.load(p)
    os.remove(p)
    return c
  end
  local d1 = load_tbl('{ provider = "deepseek" }')
  assert_eq(d1.base_url, "https://api.deepseek.com", "T163 deepseek base default")
  assert_eq(d1.api_key_env, "DEEPSEEK_API_KEY", "T163 deepseek env")
  assert_eq(d1.model, "deepseek-chat", "T163 deepseek model")
  local d2 = load_tbl('{ provider = "kimi-coding" }')
  assert_eq(d2.base_url, "https://api.kimi.com/coding", "T163 kimi base default")
  assert_eq(d2.api_key_env, "KIMI_API_KEY", "T163 kimi env")
  local d3 = load_tbl('{ provider = "xiaomi-token-plan-sgp" }')
  assert_true(d3.base_url:find("token-plan-sgp", 1, true) ~= nil, "T163 xiaomi sgp base")
  assert_eq(d3.api_key_env, "XIAOMI_TOKEN_PLAN_SGP_API_KEY", "T163 xiaomi sgp env")
  -- user override still wins over the catalog default
  local d4 = load_tbl('{ provider = "deepseek", providers = { deepseek = { model = "deepseek-reasoner" } } }')
  assert_eq(d4.model, "deepseek-reasoner", "T163 user model override wins")
  assert_eq(d4.base_url, "https://api.deepseek.com", "T163 catalog base kept")
  -- codex takes no env key: empty default, never falls back to OPENAI_API_KEY
  local d5 = load_tbl('{ provider = "openai-codex" }')
  assert_eq(d5.api_key_env, "", "T163 codex no env key")
  assert_eq(cfgm.api_key(d5), "", "T163 codex resolves empty without store")
  -- pipeline-sourced preset resolves without user config
  local d6 = load_tbl('{ provider = "xai" }')
  assert_eq(d6.base_url, "https://api.x.ai/v1", "T163 xai base from cache")
  assert_eq(d6.api_key_env, "XAI_API_KEY", "T163 xai env from cache")
  assert_eq(d6.model, "grok-4.6", "T163 xai model from cache")
  _G.provider_catalog = orig_catalog
  print("T163 catalog config defaults: OK")
end

-- T164: presets resolve live /models only (no static fallback)
do
  -- dynamic-provider-catalog: seed preset entries without models[].
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    groq = { wire = "openai", base_url = "https://api.groq.com/openai/v1",
      api_key_env = "GROQ_API_KEY", model = "x", _source = "test" },
    ["kimi-coding"] = { wire = "anthropic", base_url = "https://api.kimi.com/coding",
      api_key_env = "KIMI_API_KEY", model = "y", _source = "test" },
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local api = assert(loadfile("src/tether/api.lua"))()
  assert_eq(#api.list_models({ provider = "groq" }), 0, "T164 preset static empty")
  assert_eq(#api.list_models({ provider = "kimi-coding" }), 0, "T164 anthropic-alias static empty")
  assert_true(#api.list_models({ provider = "openai" }) >= 10, "T164 native openai keeps list")
  -- live failure on a preset yields empty (commands.list_models wraps this)
  do
    local old = _G.tether
    _G.tether = host_mock{
      http_get = function() return nil, "unreachable" end,
      http_stream = function() return true end,
      sleep = function() end,
    }
    local res, err = api.list_models_live(
      { provider = "groq", base_url = "http://x" }, "key")
    _G.tether = old
    assert_eq(res, nil, "T164 unreachable preset live nil")
  end
  _G.provider_catalog = orig_catalog
  print("T164 preset live-only models: OK")
end

-- T165: catalog login flows (device + code, config-sourced; key fallback)
do
  -- dynamic-provider-catalog: login_flow needs catalog ids; seed them.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    deepseek = { wire = "openai", base_url = "https://api.deepseek.com",
      api_key_env = "DEEPSEEK_API_KEY", model = "x", _source = "test" },
    ["github-copilot"] = { wire = "openai", base_url = "https://x",
      api_key_env = "COPILOT_GITHUB_TOKEN", model = "x", _source = "test" },
    xai = { wire = "openai", base_url = "https://api.x.ai/v1",
      api_key_env = "XAI_API_KEY", model = "x", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local catalog = catfix
  -- no oauth config → nil (API-key paste path)
  assert_eq(catalog.login_flow({ providers = {} }, "deepseek"), nil,
    "T165 no oauth config means key paste")
  assert_eq(catalog.login_flow({}, "nope"), nil, "T165 unknown id nil flow")
  -- device flow descriptor (endpoints from config, never invented)
  local dflow = catalog.login_flow({ providers = { ["github-copilot"] = {
    oauth_client_id = "cid", oauth_device_url = "https://example.com/device",
  } } }, "github-copilot")
  assert_notnil(dflow, "T165 device flow built")
  assert_true(dflow.device == true, "T165 device flag")
  assert_eq(dflow.authorize_url, "https://example.com/device", "T165 device url shown")
  -- code flow needs the full triple
  assert_eq(catalog.login_flow({ providers = { xai = { oauth_client_id = "c" } } },
    "xai"), nil, "T165 partial oauth config nil")
  local cflow = catalog.login_flow({ providers = { xai = {
    oauth_client_id = "c", oauth_token_url = "https://example.com/token",
    oauth_authorize_url = "https://example.com/auth",
  } } }, "xai")
  assert_notnil(cflow, "T165 code flow built")
  assert_true(cflow.authorize_url == nil,
    "T165 no listener means no authorize link, flow kept for paste")
  assert_true(cflow.token_url == "https://example.com/token",
    "T165 paste flow keeps token_url for the exchange")
  local lbflow = catalog.login_flow({
    providers = { xai = {
      oauth_client_id = "c", oauth_token_url = "https://example.com/token",
      oauth_authorize_url = "https://example.com/auth",
    } },
    _oauth_loopback = { uri = "http://127.0.0.1:9/", state = "s9" },
  }, "xai")
  assert_true((lbflow.authorize_url or ""):find("client_id=c", 1, true) ~= nil,
    "T165 listener authorize url carries client id")
  assert_true((lbflow.authorize_url or ""):find("state=s9", 1, true) ~= nil,
    "T165 listener authorize url carries state")

  -- ui: device paste stores an oauth entry, masked, no transcript leak
  local auth = assert(loadfile("src/tether/auth.lua"))()
  local home = "/tmp/tether_t165_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local orig_path = auth.path
  auth.path = function() return home .. "/.tether/auth.json" end
  local orig_auth = _G.auth
  _G.auth = auth
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
    config = { load = function()
        return { model = "test", workspace = "/tmp", provider = "github-copilot",
          providers = { ["github-copilot"] = {
            oauth_client_id = "cid", oauth_device_url = "https://example.com/device" } },
          ui = { input_max_lines = 8 } }
      end,
      api_key = function() return "" end },
  })
  uim._execute_command("login", "github-copilot")
  assert_notnil(S.login_secret, "T165 device login enters secret mode")
  assert_true(S.login_flow and S.login_flow.device == true, "T165 device flow active")
  local n0 = #uim._transcript.entries()
  uim._handle_key({ kind = "paste", text = "copilot-device-token-65" })
  uim._handle_key({ kind = "enter" })
  local e = auth.get(home, "github-copilot")
  assert_notnil(e, "T165 device paste stored")
  assert_eq(e.kind, "oauth", "T165 device paste stored as oauth")
  assert_eq(e.access_token, "copilot-device-token-65", "T165 token saved")
  local leaked = false
  for i = n0 + 1, #uim._transcript.entries() do
    if tostring(uim._transcript.entries()[i].text or ""):find("copilot-device-token-65", 1, true) then
      leaked = true
    end
  end
  assert_false(leaked, "T165 confirmation has no token text")
  auth.path = orig_path
  _G.auth = orig_auth
  _G.provider_catalog = orig_catalog
  print("T165 catalog login flows: OK")
end

-- T166: multi-source credential resolution (stored env merge, bearer style,
-- Vertex ADC mint, AWS chain)
do
  local auth = assert(loadfile("src/tether/auth.lua"))()
  local cfgm = dofile("src/tether/config.lua")
  local real_getenv = os.getenv
  local env_ov = {}
  os.getenv = function(k)
    if env_ov[k] ~= nil then return env_ov[k] end
    return real_getenv(k)
  end

  local home = "/tmp/tether_t166_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")

  -- stored env wins over ambient for compound providers
  env_ov.CLOUDFLARE_ACCOUNT_ID = "ambient-acc"
  auth.set(home, "cloudflare-ai-gateway", { kind = "api_key",
    access_token = "cf-key", env = { CLOUDFLARE_ACCOUNT_ID = "stored-acc" } })
  local penv = auth.provider_env("cloudflare-ai-gateway", home)
  assert_eq(penv.CLOUDFLARE_ACCOUNT_ID, "stored-acc", "T166 stored env wins")
  assert_eq(auth.provider_env("openai", home).CLOUDFLARE_ACCOUNT_ID, nil,
    "T166 non-compound empty")
  env_ov.CLOUDFLARE_ACCOUNT_ID = nil

  -- stored oauth resolves with bearer style
  auth.set(home, "anthropic", { kind = "oauth", access_token = "sk-oauth-66",
    expires_at = os.time() + 3600 })
  local c66 = { provider = "anthropic", _auth_home = home }
  local tok, style = cfgm.api_key(c66)
  assert_eq(tok, "sk-oauth-66", "T166 stored oauth token")
  assert_eq(style, "bearer", "T166 stored oauth bearer style")
  assert_eq(c66._auth_style, "bearer", "T166 style stashed on cfg")

  -- ANTHROPIC_AUTH_TOKEN rides Bearer
  os.execute("rm -f '" .. home .. "/.tether/auth.json'")
  env_ov.ANTHROPIC_AUTH_TOKEN = "auth-token-66"
  local c66b = { provider = "anthropic", _auth_home = home,
    api_key_env = "ANTHROPIC_API_KEY" }
  local tok2, style2 = cfgm.api_key(c66b)
  assert_eq(tok2, "auth-token-66", "T166 auth token resolves")
  assert_eq(style2, "bearer", "T166 auth token bearer style")
  env_ov.ANTHROPIC_AUTH_TOKEN = nil
  env_ov.ANTHROPIC_OAUTH_TOKEN = "oauth-token-66"
  assert_eq(cfgm.api_key(c66b), "oauth-token-66", "T166 oauth token resolves plain")
  env_ov.ANTHROPIC_OAUTH_TOKEN = nil

  -- Vertex ambient ADC mints a token when project+location exist
  local adc_path = home .. "/adc.json"
  local f = io.open(adc_path, "w")
  f:write('{"type":"authorized_user","client_id":"cid","client_secret":"cs","refresh_token":"rt"}')
  f:close()
  env_ov.GOOGLE_APPLICATION_CREDENTIALS = adc_path
  env_ov.GOOGLE_CLOUD_PROJECT = "proj"
  env_ov.GOOGLE_CLOUD_LOCATION = "us-central1"
  local posted = nil
  auth._post_json = function(url, body) posted = body; return '{"access_token":"ya29.test","expires_in":3600}' end
  local orig_auth = _G.auth
  _G.auth = auth
  local c66c = { provider = "google-vertex", _auth_home = home, provider_env = {} }
  local tok3, style3 = cfgm.api_key(c66c)
  assert_eq(tok3, "ya29.test", "T166 ADC mints access token")
  assert_eq(style3, "bearer", "T166 minted token bearer style")
  assert_eq(posted and posted.client_id, "cid", "T166 mint sends ADC client id")
  -- without location there is no mint (partial credential refused)
  env_ov.GOOGLE_CLOUD_LOCATION = nil
  assert_eq(cfgm.api_key(c66c), "", "T166 partial ADC refused")
  env_ov.GOOGLE_APPLICATION_CREDENTIALS = nil
  env_ov.GOOGLE_CLOUD_PROJECT = nil
  _G.auth = orig_auth

  -- AWS chain shapes
  env_ov.HOME = home
  env_ov.AWS_BEARER_TOKEN_BEDROCK = "bedrock-bearer"
  local b1 = auth.aws_creds()
  assert_eq(b1.mode, "bearer", "T166 bedrock bearer mode")
  env_ov.AWS_BEARER_TOKEN_BEDROCK = nil
  env_ov.AWS_ACCESS_KEY_ID = "AKID"
  env_ov.AWS_SECRET_ACCESS_KEY = "SECRET"
  local b2 = auth.aws_creds()
  assert_eq(b2.mode, "sigv4", "T166 static keys sigv4 mode")
  assert_eq(b2.key, "AKID", "T166 static key kept")
  env_ov.AWS_ACCESS_KEY_ID = nil
  env_ov.AWS_SECRET_ACCESS_KEY = nil
  env_ov.AWS_PROFILE = "nosuchprofile"
  assert_eq(auth.aws_creds(), nil, "T166 no creds yields nil")
  env_ov.AWS_PROFILE = nil
  env_ov.HOME = nil

  os.getenv = real_getenv
  print("T166 multi-source credentials: OK")
end

-- T167: Bedrock adapter (SigV4 cross-checked vs Python hmac reference,
-- Converse body mapping, non-stream response parsing)
do
  local bedrock = assert(loadfile("src/tether/providers/amazon-bedrock.lua"))()
  -- SigV4 vector (verified against an independent Python implementation)
  local authz = bedrock._sign("AKIDEXAMPLE",
    "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", nil,
    "us-east-1", "service", "GET",
    "https://host.foo.com/?Param2=value2&Param1=value1", "", false,
    "20150830T123600Z")
  assert_true(authz:find(
    "Signature=0562a53cd5f50f2397cff531737ea044394282c3148918524844055cfadfaa36",
    1, true) ~= nil, "T167 SigV4 GET vector")
  local authz2 = bedrock._sign("AKID", "SECRET", "TOKEN", "us-east-1",
    "bedrock", "POST",
    "https://bedrock-runtime.us-east-1.amazonaws.com/model/x/converse",
    '{"messages":[]}', true, "20240101T000000Z")
  assert_true(authz2:find(
    "Signature=d29aa5e92e93288854af3054c02fdf20a93af6c217cc4ff3408f890875831549",
    1, true) ~= nil, "T167 SigV4 POST+session vector")
  assert_true(authz2:find("bedrock/aws4_request", 1, true) ~= nil,
    "T167 bedrock scope")

  -- stream URL carries region + encoded model id
  local url = bedrock.stream_url(
    { model = "us.anthropic.claude-x-v1:0",
      providers = { ["amazon-bedrock"] = { region = "eu-west-1" } } },
    "us.anthropic.claude-x-v1:0")
  assert_eq(url, "https://bedrock-runtime.eu-west-1.amazonaws.com/model/us.anthropic.claude-x-v1%3A0/converse",
    "T167 converse URL")

  -- Converse body: system extracted, roles alternate, tools converted
  local hist = {
    { role = "system", content = "sys" },
    { role = "user", content = "hi" },
    { role = "assistant", content = { tool_calls = { { id = "t1", type = "function",
        ["function"] = { name = "read", arguments = '{"path":"a"}' } } } } },
    { role = "tool", tool_call_id = "t1", content = "out" },
  }
  local body = bedrock.build_request(hist, "m")
  assert_true(body:find('"system":[{"text":"sys"}]', 1, true) ~= nil,
    "T167 converse system")
  assert_true(body:find('"toolUseId":"t1"', 1, true) ~= nil,
    "T167 converse toolUse")
  assert_true(body:find('"name":"read"', 1, true) ~= nil,
    "T167 converse tool name")
  assert_true(body:find('"toolResult"', 1, true) ~= nil,
    "T167 converse toolResult")
  assert_true(body:find('"toolConfig":{"tools"', 1, true) ~= nil,
    "T167 converse toolConfig")

  -- non-stream Converse response → canonical events
  bedrock.reset_stream()
  local evs = {}
  local function on(ev) evs[#evs + 1] = ev end
  local resp = '{"output":{"message":{"role":"assistant","content":['
    .. '{"text":"hello"},{"toolUse":{"toolUseId":"t1","name":"read","input":{"path":"a"}}}],'
    .. '"stopReason":"tool_use"},"stopReason":"tool_use"},'
    .. '"usage":{"inputTokens":10,"outputTokens":5}}'
  assert_true(bedrock.handle_non_sse(resp, on), "T167 converse consumed")
  local saw = {}
  for _, ev in ipairs(evs) do
    saw[ev.type] = (saw[ev.type] or 0) + 1
    if ev.type == "tool_call_delta" then
      assert_eq(ev.id, "t1", "T167 delta id")
      assert_true(ev.arguments:find("a", 1, true) ~= nil, "T167 delta args")
    end
    if ev.type == "usage" then assert_eq(ev.usage.used, 15, "T167 usage sum") end
    if ev.type == "done" then assert_eq(ev.reason, "tool_calls", "T167 stop mapped") end
  end
  assert_eq(saw.text_delta, 1, "T167 text")
  assert_eq(saw.tool_call_start, 1, "T167 start")
  assert_eq(saw.tool_call_delta, 1, "T167 delta")
  assert_eq(saw.done, 1, "T167 done")
  assert_true(bedrock.stream_failure() == nil, "T167 no failure")

  -- error shape fails the attempt with the provider message
  bedrock.reset_stream()
  assert_true(bedrock.handle_non_sse('{"message":"ValidationException: bad"}', on),
    "T167 error consumed")
  local f = bedrock.stream_failure()
  assert_notnil(f, "T167 error recorded")
  assert_true(f.message:find("ValidationException", 1, true) ~= nil,
    "T167 provider message kept")

  -- preflight names missing credentials; bearer passes
  assert_true(bedrock.preflight({}, "", "u", "amazon-bedrock") ~= nil,
    "T167 preflight blocks keyless ambient-less")
  assert_true(bedrock.preflight({}, "tok", "u", "amazon-bedrock") == nil,
    "T167 bearer passes preflight")
  print("T167 bedrock adapter: OK")
end

-- T168: Tier-B adapters resolve + emit canonical events on canned streams
do
  local api = assert(loadfile("src/tether/api.lua"))()
  assert_eq(api._provider_of({ provider = "azure-openai" }), "azure-openai",
    "T168 azure identity")
  assert_eq(api._wire_module({ provider = "azure-openai" }).name, "azure-openai",
    "T168 azure own module")
  assert_eq(api._wire_module({ provider = "google-vertex" }).name, "google-vertex",
    "T168 vertex own module")
  assert_eq(api._wire_module({ provider = "openai-codex" }).name, "openai-codex",
    "T168 codex own module")
  assert_eq(#api.list_models({ provider = "azure-openai" }), 0,
    "T168 adapter static empty")

  local azure = assert(loadfile("src/tether/providers/azure-openai.lua"))()
  assert_eq(azure.stream_url(
    { base_url = "https://r.openai.azure.com", model = "d" }, "d"),
    "https://r.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21",
    "T168 azure deployments URL")
  assert_eq(azure.header_lines("k")[1], "api-key: k", "T168 azure api-key header")
  assert_true(azure.preflight({ model = "" }) ~= nil, "T168 azure preflight needs deployment")

  local vertex = assert(loadfile("src/tether/providers/google-vertex.lua"))()
  local vcfg = { model = "m", _auth_style = "bearer", provider_env = {
    GOOGLE_CLOUD_PROJECT = "p", GOOGLE_CLOUD_LOCATION = "l" } }
  assert_eq(vertex.stream_url(vcfg, "m", "tok"),
    "https://l-aiplatform.googleapis.com/v1/projects/p/locations/l/publishers/google/models/m:streamGenerateContent",
    "T168 vertex bearer URL has no key")
  -- vertex SSE delegates to the gemini wire
  vertex.reset_stream()
  local vevs = {}
  vertex.parse_sse_line('data: {"candidates":[{"content":{"parts":[{"text":"vhi"}],"role":"model"}}]}',
    function(ev) vevs[#vevs + 1] = ev end)
  assert_eq(#vevs, 1, "T168 vertex text via gemini wire")
  assert_eq(vevs[1].type, "text_delta", "T168 vertex event type")

  local cf = assert(loadfile("src/tether/providers/cloudflare-ai-gateway.lua"))()
  local chl = cf.header_lines("k")
  assert_eq(#chl, 1, "T168 gateway single header")
  assert_true(chl[1]:find("cf-aig-authorization", 1, true) ~= nil,
    "T168 gateway auth shape")
  for _, ln in ipairs(chl) do
    assert_true(ln:find("Authorization:", 1, true) == nil
      or ln:find("cf-aig", 1, true) ~= nil, "T168 no bare Authorization")
  end

  local radius = assert(loadfile("src/tether/providers/radius.lua"))()
  assert_eq(radius.stream_url({ base_url = "https://radius.pi.dev/" }, "m"),
    "https://radius.pi.dev/messages", "T168 radius messages URL")
  assert_eq(radius.models_url({ base_url = "https://radius.pi.dev" }, "k"),
    "https://radius.pi.dev/v1/config", "T168 radius config catalog")

  local codex = assert(loadfile("src/tether/providers/openai-codex.lua"))()
  codex.reset_stream()
  local cevs = {}
  local function con(ev) cevs[#cevs + 1] = ev end
  codex.parse_sse_line('data: {"type":"response.output_text.delta","delta":"Hi"}', con)
  codex.parse_sse_line('data: {"type":"response.output_item.added","output_index":0,'
    .. '"item":{"type":"function_call","call_id":"c9","name":"list"}}', con)
  codex.parse_sse_line('data: {"type":"response.function_call_arguments.delta",'
    .. '"output_index":0,"delta":"{}"}', con)
  codex.parse_sse_line('data: {"type":"response.completed","response":{"status":"completed",'
    .. '"usage":{"input_tokens":1,"output_tokens":2}}}', con)
  local csaw = {}
  for _, ev in ipairs(cevs) do csaw[ev.type] = (csaw[ev.type] or 0) + 1 end
  assert_eq(csaw.text_delta, 1, "T168 codex text")
  assert_eq(csaw.tool_call_start, 1, "T168 codex start")
  assert_eq(csaw.tool_call_delta, 1, "T168 codex delta")
  assert_eq(csaw.done, 1, "T168 codex done")
  assert_true(codex.stream_failure() == nil, "T168 codex no failure")
  codex.reset_stream()
  codex.parse_sse_line('data: {"type":"response.failed","error":{"message":"nope"}}', con)
  assert_true(codex.stream_failure() ~= nil, "T168 codex failure recorded")
  print("T168 tier-B adapters: OK")
end

-- T169: model-list cache (instant fresh hit, stale refresh ≤5s, fallback)
do
  -- dynamic-provider-catalog: curated openai static comes from the overlay.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local home = "/tmp/tether_t169_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local api = assert(loadfile("src/tether/api.lua"))()
  local orig_api = _G.api
  _G.api = api
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local calls = { n = 0, timeout = nil }
  local live_body = '{"data":[{"id":"live-a"}]}'
  local orig_tether = _G.tether
  _G.tether = host_mock{
    http_get = function(_, _, timeout)
      calls.n = calls.n + 1
      calls.timeout = timeout
      if live_body then return live_body, nil end
      return nil, "boom"
    end,
    http_stream = function() return true end,
    sleep = function() end,
  }
  local cfg = { provider = "openai", base_url = "http://x", model = "m",
    _auth_home = home }

  -- miss + live success → live served, short timeout used, cache written
  local m1 = commands.list_models(cfg, "key")
  assert_eq(#m1, 1, "T169 live served on miss")
  assert_eq(m1[1].id, "live-a", "T169 live id")
  assert_eq(calls.timeout, 5, "T169 refresh capped at 5s")
  assert_eq(calls.n, 1, "T169 one attempt")

  -- fresh hit → instant, no network
  live_body = '{"data":[{"id":"live-b"}]}'
  local m2 = commands.list_models(cfg, "key")
  assert_eq(m2[1].id, "live-a", "T169 fresh cache wins")
  assert_eq(calls.n, 1, "T169 no network on fresh hit")

  -- stale cache + live failure → stale served, attempt recorded once
  local cp = commands._models_cache_path(home)
  local f = io.open(cp, "r")
  local raw = f:read("*a")
  f:close()
  local stale_raw = raw:gsub('"checked_at":(%d+)',
    function(ts) return '"checked_at":' .. (tonumber(ts) - 5 * 3600) end)
  f = io.open(cp, "w")
  f:write(stale_raw)
  f:close()
  live_body = nil
  local m3 = commands.list_models(cfg, "key")
  assert_eq(m3[1].id, "live-a", "T169 stale served on failure")
  assert_eq(calls.n, 2, "T169 one refresh attempt on stale")

  -- second open right after failure → instant (checked_at persisted)
  local m4 = commands.list_models(cfg, "key")
  assert_eq(m4[1].id, "live-a", "T169 still served")
  assert_eq(calls.n, 2, "T169 dead endpoint not hammered")

  -- no key → static, no network
  os.execute("rm -f '" .. cp .. "'")
  local m5 = commands.list_models(cfg, "")
  assert_true(#m5 >= 10, "T169 static without key")
  assert_eq(calls.n, 2, "T169 no network without key")

  _G.tether = orig_tether
  _G.api = orig_api
  _G.provider_catalog = orig_catalog
  print("T169 model cache: OK")
end

-- T170: background refresh (instant stale display, spawn, poll pickup)
do
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local home = "/tmp/tether_t170_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local api = assert(loadfile("src/tether/api.lua"))()
  local orig_api = _G.api
  _G.api = api
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local spawned = {}
  local orig_tether = _G.tether
  _G.tether = host_mock{
    http_get = function() return nil, "must not be called" end,
    fetch_bg = function(url, headers, outpath, timeout)
      spawned[#spawned + 1] = { url = url, outpath = outpath, timeout = timeout,
        headers = headers }
      return true
    end,
    http_stream = function() return true end,
    sleep = function() end,
  }
  local cfg = { provider = "openai", base_url = "http://x", model = "m",
    _auth_home = home }

  -- miss: static instantly + one spawn, no sync network
  local m1, bg1 = commands.list_models(cfg, "key")
  assert_true(#m1 >= 10, "T170 static instantly on miss")
  assert_true(bg1 == true, "T170 spawn reported")
  assert_eq(#spawned, 1, "T170 one fetch spawned")
  assert_true(spawned[1].url:find("/models", 1, true) ~= nil, "T170 spawn hits models URL")
  assert_true(spawned[1].timeout >= 10, "T170 bg timeout generous")

  -- second open while fetch in flight: no duplicate spawn
  local m1b, bg1b = commands.list_models(cfg, "key")
  assert_true(#m1b >= 10, "T170 still instant")
  assert_eq(#spawned, 1, "T170 no duplicate spawn")

  -- poll before child writes: waiting
  assert_eq(commands.poll_models_refresh(cfg, { provider = "openai",
    started = os.time() }), "waiting", "T170 waiting for child")

  -- child lands: poll consumes, cache fills
  local f = io.open(spawned[1].outpath, "w")
  f:write('{"data":[{"id":"bg-live"}]}')
  f:close()
  assert_eq(commands.poll_models_refresh(cfg, { provider = "openai",
    started = os.time() }), "updated", "T170 updated on land")
  local m2 = commands.list_models(cfg, "key")
  assert_eq(#m2, 1, "T170 fresh cache served")
  assert_eq(m2[1].id, "bg-live", "T170 bg content wins")
  assert_eq(#spawned, 1, "T170 no spawn on fresh hit")

  -- failure marker: stale kept, checked_at settles (no hammering)
  local cp = commands._models_cache_path(home)
  local rf = io.open(cp, "r")
  local raw = rf:read("*a")
  rf:close()
  local old_raw = raw:gsub('"checked_at":(%d+)',
    function(ts) return '"checked_at":' .. (tonumber(ts) - 5 * 3600) end)
  local wf = io.open(cp, "w")
  wf:write(old_raw)
  wf:close()
  local m3, bg3 = commands.list_models(cfg, "key")
  assert_eq(m3[1].id, "bg-live", "T170 stale instantly")
  assert_true(bg3 == true, "T170 respawn on stale")
  assert_eq(#spawned, 2, "T170 second spawn")
  local ff = io.open(spawned[2].outpath, "w")
  ff:write("FETCH_FAILED timeout\n")
  ff:close()
  assert_eq(commands.poll_models_refresh(cfg, { provider = "openai",
    started = os.time() }), "updated", "T170 failure consumed")
  local m4 = commands.list_models(cfg, "key")
  assert_eq(m4[1].id, "bg-live", "T170 stale kept after failure")
  assert_eq(#spawned, 2, "T170 settled, no respawn")

  -- provider switch / ancient state settles
  assert_eq(commands.poll_models_refresh({ provider = "gemini" },
    { provider = "openai", started = os.time() }), "settled",
    "T170 provider switch settles")
  assert_eq(commands.poll_models_refresh(cfg,
    { provider = "openai", started = os.time() - 500 }), "settled",
    "T170 ancient state settles")

  -- multi-provider: a non-active id's pending file is consumed too
  local cfg_a = { provider = "openai", base_url = "http://x", model = "m",
    _auth_home = home }
  local m_a = commands.list_models(
    { provider = "agnes", base_url = "http://x", model = "m", _auth_home = home },
    "key")
  assert_eq(#m_a, 0, "T170 agnes preset empty instantly")
  local pend_a = commands._models_pending_path(home, "agnes")
  local fa = io.open(pend_a, "w")
  fa:write('{"data":[{"id":"agnes-poll-x"}]}')
  fa:close()
  assert_eq(commands.poll_models_refresh(cfg_a,
    { provider = "openai", started = os.time() }), "updated",
    "T170 non-active provider consumed")
  local m_a2 = commands.list_models(
    { provider = "agnes", base_url = "http://x", model = "m", _auth_home = home },
    "key")
  assert_eq(#m_a2, 1, "T170 agnes cache filled")
  assert_eq(m_a2[1].id, "agnes-poll-x", "T170 agnes content")

  _G.tether = orig_tether
  _G.api = orig_api
  _G.provider_catalog = orig_catalog
  print("T170 background refresh: OK")
end

-- T172: empty model list explains itself (no silent palette)
do
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local home = "/tmp/tether_t172_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local api = assert(loadfile("src/tether/api.lua"))()
  local orig_api = _G.api
  _G.api = api
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local orig_tether = _G.tether
  _G.tether = host_mock{
    http_get = function() return nil, "connection refused" end,
    http_stream = function() return true end,
    sleep = function() end,
  }
  -- keyless preset: names provider, login command and env var
  local m1, _, e1 = commands.list_models(
    { provider = "agnes", base_url = "http://x", model = "m", _auth_home = home,
      api_key_env = "AGNES_API_KEY" }, "")
  assert_eq(#m1, 0, "T172 keyless preset empty")
  assert_true(e1 ~= nil, "T172 keyless reason present")
  assert_true(e1:find("agnes", 1, true) ~= nil, "T172 reason names provider")
  assert_true(e1:find("/login agnes", 1, true) ~= nil, "T172 reason points at login")
  assert_true(e1:find("AGNES_API_KEY", 1, true) ~= nil, "T172 reason names env var")
  -- keyed preset, dead endpoint: live reason surfaces (no fetch_bg in mock → sync)
  local m2, _, e2 = commands.list_models(
    { provider = "groq", base_url = "http://x", model = "m", _auth_home = home,
      api_key_env = "GROQ_API_KEY" }, "key")
  assert_eq(#m2, 0, "T172 dead endpoint empty")
  assert_true(e2 ~= nil, "T172 live reason present")
  assert_true(e2:find("groq", 1, true) ~= nil, "T172 live reason names provider")
  assert_true(e2:find("refused", 1, true) ~= nil, "T172 live reason kept")
  -- non-empty list: no reason attached
  local m3, _, e3 = commands.list_models(
    { provider = "openai", base_url = "http://x", model = "m", _auth_home = home,
      api_key_env = "OPENAI_API_KEY" }, "")
  assert_true(#m3 > 0, "T172 static served")
  assert_true(e3 == nil, "T172 no reason when list non-empty")
  _G.tether = orig_tether
  _G.api = orig_api
  _G.provider_catalog = orig_catalog
  print("T172 empty list diagnosis: OK")
end

-- T173: providers_with_keys + for_provider (multi-provider /model basis)
do
  -- dynamic-provider-catalog: seed openai + deepseek (config snapshots it).
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
    deepseek = { wire = "openai", base_url = "https://api.deepseek.com",
      api_key_env = "DEEPSEEK_API_KEY", model = "deepseek-chat", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local cfgm = dofile("src/tether/config_auth.lua")
  local real_getenv = os.getenv
  local env_ov = {}
  os.getenv = function(k)
    if env_ov[k] ~= nil then return env_ov[k] end
    return real_getenv(k)
  end
  local home = "/tmp/tether_t173_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local auth = assert(loadfile("src/tether/auth.lua"))()
  auth.set(home, "openai", { kind = "api_key", access_token = "sk-oai" })

  -- nothing in env: only stored openai
  local k1 = cfgm.providers_with_keys({ provider = "openai", _auth_home = home })
  assert_eq(#k1, 1, "T173 one stored key")
  assert_eq(k1[1], "openai", "T173 stored id")

  -- env key adds a provider; active pins first
  env_ov.DEEPSEEK_API_KEY = "sk-deep"
  local k2 = cfgm.providers_with_keys({ provider = "deepseek", _auth_home = home })
  assert_eq(#k2, 2, "T173 stored + env")
  assert_eq(k2[1], "deepseek", "T173 active pinned first")
  assert_eq(k2[2], "openai", "T173 catalog order after")
  env_ov.DEEPSEEK_API_KEY = nil

  -- nothing anywhere → empty
  os.execute("rm -f '" .. home .. "/.tether/auth.json'")
  local k3 = cfgm.providers_with_keys({ provider = "openai", _auth_home = home })
  -- (CI env may hold real keys; only assert ours are absent)
  for _, id in ipairs(k3) do
    assert_true(id ~= "openai" or real_getenv("OPENAI_API_KEY") ~= nil,
      "T173 no phantom openai")
  end

  -- for_provider folds catalog defaults without mutating input
  local base = { provider = "openai", model = "gpt-4o-mini",
    base_url = "https://api.openai.com/v1", _auth_home = home }
  local c2 = cfgm.for_provider(base, "deepseek")
  assert_eq(c2.provider, "deepseek", "T173 copy provider")
  assert_eq(c2.base_url, "https://api.deepseek.com", "T173 catalog base")
  assert_eq(c2.api_key_env, "DEEPSEEK_API_KEY", "T173 catalog env")
  assert_eq(base.provider, "openai", "T173 input untouched")
  assert_eq(base.base_url, "https://api.openai.com/v1", "T173 input url untouched")

  os.getenv = real_getenv
  _G.provider_catalog = orig_catalog
  print("T173 providers_with_keys: OK")
end

-- T174: list_models_all aggregates keyed providers, tags provider
do
  -- dynamic-provider-catalog: seed openai + agnes.
  local catfix = assert(loadfile("src/tether/providers/catalog.lua"))()
  catfix.set_overlay({
    openai = { wire = "openai", base_url = "https://api.openai.com/v1",
      api_key_env = "OPENAI_API_KEY", model = "gpt-4o-mini", _source = "test" },
    agnes = { wire = "openai", base_url = "https://apihub.agnes-ai.com/v1",
      api_key_env = "AGNES_API_KEY", model = "agnes-2.5-flash", _source = "test" },
  }, { generated_at = 0 })
  local orig_catalog = _G.provider_catalog
  _G.provider_catalog = catfix
  local home = "/tmp/tether_t174_home"
  os.execute("rm -rf '" .. home .. "' && mkdir -p '" .. home .. "/.tether'")
  local auth = assert(loadfile("src/tether/auth.lua"))()
  auth.set(home, "openai", { kind = "api_key", access_token = "sk-oai" })
  auth.set(home, "agnes", { kind = "api_key", access_token = "sk-agnes" })
  local api = assert(loadfile("src/tether/api.lua"))()
  local orig_api = _G.api
  _G.api = api
  local orig_cfg = rawget(_G, "config")
  _G.config = assert(loadfile("src/tether/config.lua"))()
  local commands = assert(loadfile("src/tether/commands.lua"))()
  local orig_tether = _G.tether
  _G.tether = host_mock{
    http_get = function(url)
      if tostring(url):find("agnes", 1, true) then
        return '{"data":[{"id":"agnes-2.5-flash"}]}', nil
      end
      return '{"data":[{"id":"gpt-4o-mini"}]}', nil
    end,
    http_stream = function() return true end,
    sleep = function() end,
  }
  local cfg = { provider = "openai", _auth_home = home }
  local items, bg, err = commands.list_models_all(cfg)
  assert_true(#items >= 2, "T174 both providers listed")
  assert_eq(items[1].provider, "openai", "T174 active first")
  local seen = {}
  for _, m in ipairs(items) do seen[m.provider] = m.id end
  assert_eq(seen.openai, "gpt-4o-mini", "T174 openai model")
  assert_eq(seen.agnes, "agnes-2.5-flash", "T174 agnes model")
  assert_true(err == nil, "T174 no error when non-empty")

  -- no keys anywhere → empty + /login hint
  os.execute("rm -f '" .. home .. "/.tether/auth.json'")
  local real_getenv = os.getenv
  os.getenv = function() return nil end
  local items2, _, err2 = commands.list_models_all(cfg)
  os.getenv = real_getenv
  assert_eq(#items2, 0, "T174 keyless empty")
  assert_true(err2 ~= nil and err2:find("/login", 1, true) ~= nil,
    "T174 keyless hint points at /login")

  _G.tether = orig_tether
  _G.api = orig_api
  _G.config = orig_cfg
  _G.provider_catalog = orig_catalog
  print("T174 list_models_all: OK")
end

-- T175: picking another provider's model switches provider + re-resolves key
do
  local orig_commands = _G.commands
  local model_calls = 0
  _G.commands = {
    list_models_all = function()
      model_calls = model_calls + 1
      if model_calls == 1 then
        return { { id = "gpt-4o-mini", name = "GPT-4o mini", provider = "openai" },
                 { id = "agnes-2.5-flash", name = "Agnes Flash", provider = "agnes" } }
      end
      return { { id = "x-model", name = "X" } }
    end,
    list_models = function() return {} end,
  }
  local orig_config = _G.config
  _G.config = { load = function()
      return { model = "gpt-4o-mini", workspace = "/tmp", provider = "openai",
        ui = { input_max_lines = 8 } }
    end,
    api_key = function(cfg) return "key-for-" .. tostring(cfg.provider) end }
  local uim, S = run_ui_with({ 17 }, {
    agent = { turn = function() return true end, get_history = function() return {} end },
  })
  uim._execute_command("model")
  assert_true(S.palette_active, "T175 palette opens")
  assert_eq(#(S.palette_items or {}), 2, "T175 two providers shown")
  assert_eq(S.palette_items[2].provider, "agnes", "T175 item carries provider")
  -- pick the agnes model (second row)
  uim._handle_key({ kind = "special", name = "down" })
  uim._handle_key({ kind = "enter" })
  assert_eq(S.cfg.provider, "agnes", "T175 provider switched")
  assert_eq(S.cfg.model, "agnes-2.5-flash", "T175 model set")
  assert_eq(S.api_key, "key-for-agnes", "T175 key re-resolved for agnes")
  local rows = uim._transcript.entries()
  assert_true(tostring(rows[#rows].text or ""):find("agnes/agnes-2.5-flash", 1, true)
    ~= nil, "T175 row names provider/model")
  -- providerless item keeps current provider (backward compat)
  uim._execute_command("model")
  uim._handle_key({ kind = "enter" })
  assert_eq(S.cfg.provider, "agnes", "T175 provider kept without tag")
  assert_eq(S.cfg.model, "x-model", "T175 model still set")
  _G.commands = orig_commands
  _G.config = orig_config
  print("T175 cross-provider pick: OK")
end

-- T171: bracketed paste terminates on ESC [ 2 0 1 ~ (not a prefix of it).
-- Regression: the terminator check matched "[21~", so a real paste never
-- completed — the decoder swallowed all following input into the void.
do
  local function to_bytes(s)
    local t = {}
    for i = 1, #s do t[#t + 1] = s:byte(i) end
    return t
  end
  local qi, queue = 0, {}
  _G.tether = host_mock{
    -- exhausted queue yields nil (EOF): the paste loop must terminate.
    read_char = function()
      qi = qi + 1
      if qi <= #queue then return queue[qi] end
      return nil
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
  -- full bracketed paste arrives atomically: content only, no marker leak
  local k = one("\27[200~sk-test-key\27[201~")
  assert_eq(k.kind, "paste", "T171 bracketed paste kind")
  assert_eq(k.text, "sk-test-key", "T171 terminator excluded from content")
  -- ESC inside a paste that is NOT the terminator stays content
  local k2 = one("\27[200~a\27Xb\27[201~")
  assert_eq(k2.kind, "paste", "T171 paste with stray ESC kind")
  assert_eq(k2.text, "a\27Xb", "T171 stray ESC kept, terminator excluded")
  -- the byte after the paste is decoded separately, not swallowed
  queue, qi = to_bytes("\27[200~k\27[201~Z"), 0
  local p1 = keys.read_key(bag)
  assert_eq(p1.kind, "paste", "T171 first event paste")
  assert_eq(p1.text, "k", "T171 first content")
  local p2 = keys.read_key(bag)
  assert_eq(p2.kind, "text", "T171 byte after paste decoded separately")
  assert_eq(p2.char, "Z", "T171 trailing byte intact")
  print("T171 bracketed paste terminator: OK")
end

if failed > 0 then
    os.exit(1)
end
  print("T74 4.2/4.3/4.4 path completion: OK")
end

