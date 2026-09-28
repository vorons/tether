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

if failed > 0 then
    os.exit(1)
end
