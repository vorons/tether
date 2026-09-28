-- tests/copy_tests.lua — ui_copy safe-edit zone guard (split from lua_tests.lua, Phase C).
-- Run: lua tests/copy_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- TCOPY: ui/copy.lua safe-edit zone guard (ui-modular-split 2.5).
do
  local copy = assert(loadfile("src/tether/ui/copy.lua"))()
  local sections = { "splash", "confirm", "palette_hints", "commands", "keys",
    "ask", "secret", "palette", "errors", "session", "spinner", "rules", "footer" }
  for _, s in ipairs(sections) do
    assert_notnil(copy[s], "TCOPY section present: " .. s)
  end
  local function is_data(t, seen)
    if type(t) ~= "table" then return type(t) == "string" end
    if seen[t] then return true end
    seen[t] = true
    for k, v in pairs(t) do
      if type(k) ~= "string" and type(k) ~= "number" then return false end
      if not is_data(v, seen) then return false end
    end
    return true
  end
  assert_true(is_data(copy, {}), "TCOPY data-only: no functions/logic in ui_copy")
  assert_false(is_data({ f = function() end }, {}), "TCOPY scanner rejects function values")
  assert_false(is_data({ "ok", print }, {}), "TCOPY scanner rejects non-string leaves")
  -- no code outside table constructors: statements may only start a line
  -- as the two skeleton lines; anywhere else they mean logic leaked in.
  -- (String VALUES may contain English words like "for", so mid-line
  -- prose is never matched — only line-leading keywords and host tokens.)
  local fh = assert(io.open("src/tether/ui/copy.lua", "r"))
  for line in fh:lines() do
    local stripped = line:gsub("%-%-.*$", "")
    if stripped:find("%S") then
      if stripped ~= "local M = {}" and stripped ~= "return M" then
        for _, kw in ipairs({ "local", "for", "while", "if", "else",
            "end", "return", "function", "do", "then" }) do
          assert_eq(stripped:find("^%s*" .. kw .. "%f[%W]"), nil,
            "TCOPY logic keyword outside skeleton (" .. kw .. "):" .. stripped)
        end
      end
    end
  end
  fh:close()
  local src_all = assert(io.open("src/tether/ui/copy.lua", "r")):read("*a")
  local code_only = src_all:gsub("%-%-[^\n]*", "")
  for _, tok in ipairs({ "function", "require", "dofile", "loadfile", "_G",
      "tether", "os%.", "io%." }) do
    local pat = "%f[%w]" .. tok .. "%f[%W]"
    assert_eq(code_only:find(pat), nil, "TCOPY no outside access (" .. tok .. ")")
  end
  -- facade parity: ui.lua exposes the same tables under stable M.* names.
  local ui = dofile("src/tether/ui.lua")
  assert_true(ui.SLASH_COMMANDS == ui._copy.commands, "TCOPY facade SLASH_COMMANDS identity")
  assert_true(ui.PALETTE_HINTS == ui._copy.palette_hints, "TCOPY facade PALETTE_HINTS identity")
  assert_true(ui.CONFIRM_DIGITS == ui._copy.confirm.digits, "TCOPY facade CONFIRM_DIGITS identity")
  assert_true(ui.KEYMAP == ui._copy.keys.map, "TCOPY facade KEYMAP identity")
  assert_true(ui.ASK_KEYS == ui._copy.keys.ask, "TCOPY facade ASK_KEYS identity")
  assert_true(ui.SPLASH_WORDMARK == ui._copy.splash.wordmark, "TCOPY facade SPLASH_WORDMARK identity")
  print("TCOPY copy-zone guard: OK")
end

if failed > 0 then
    os.exit(1)
end
