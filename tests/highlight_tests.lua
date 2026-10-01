-- tests/highlight_tests.lua — ui_highlight tokenizer (split from lua_tests.lua, Phase C).
-- Run: lua tests/highlight_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- THL: ui_highlight owns tokenize/highlight directly (ui-modular-split 4.2).
do
  local hl = assert(loadfile("src/tether/ui/highlight.lua"))()
  local tag = function(role, text) return "<" .. role .. ">" .. text .. "</" .. role .. ">" end
  local toks = hl.tokenize("local x = 42 -- c", "lua", {})
  assert_eq(toks[1].kind, "keyword", "THL keyword kind")
  assert_eq(toks[1].text, "local", "THL keyword text")
  assert_eq(hl.tokenize("anything", "unknownlang", {})[1].kind, "plain", "THL unknown lang")
  assert_eq(hl.highlight("local x = 1", "lua", {}, tag), "<keyword>local</keyword> x = <number>1</number>", "THL paint")
  assert_eq(hl.highlight("local x = 1", "lua", {}, nil), "local x = 1", "THL nil painter is raw")
  assert_eq(hl.roles.keyword, "keyword", "THL roles map")
  assert_notnil(hl.langs.lua, "THL langs table")
  -- module owns the behavior; the ui facade keeps M.* names until 2.4.
  assert_eq(hl.highlight("local x = 1 -- c", "lua", {}, nil), "local x = 1 -- c", "THL nil painter invariant")
  print("THL ui_highlight direct: OK")
end

-- T351 (audit L2): `[[\"']{3}$` never matched in Lua (`{3}` is literal),
-- so python triple-quotes never opened. Literal comparison opens them.
do
  local hl = assert(loadfile("src/tether/ui/highlight.lua"))()
  local toks = hl.tokenize('"""hello', "python", {})
  assert_eq(toks[1].kind, "string", "T351 triple-double opens a string")
  local st = {}
  hl.tokenize('"""hello', "python", st)
  assert_notnil(st.str, "T351 unterminated triple-quote keeps state")
  local toks2 = hl.tokenize("world", "python", st)
  assert_eq(toks2[1].kind, "string", "T351 string continues on the next line")
  local toks3 = hl.tokenize("x = '''v'''", "python", {})
  local seen_string = false
  for _, t in ipairs(toks3) do
    if t.kind == "string" then seen_string = true end
  end
  assert_true(seen_string, "T351 triple-single opens a string")
  local st_lua = {}
  hl.tokenize('"""x', "lua", st_lua)
  assert_eq(st_lua.str, nil, "T351 lua sets no triple-quote state")
  print("T351 python triple-quote highlighting: OK")
end

if failed > 0 then
    os.exit(1)
end
