-- tests/markdown_tests.lua — ui_markdown inline-strip (split from lua_tests.lua, Phase C).
-- Run: lua tests/markdown_tests.lua  (helpers via tests/helpers.lua)

dofile("tests/helpers.lua")

-- TMD: ui_markdown owns the inline-strip pass directly (ui-modular-split 3.2).
-- The ui facade keeps M.md_strip_inline as a proxy until 2.4.
do
  local md = assert(loadfile("src/tether/ui/markdown.lua"))()
  local tag = function(kind, text) return "<" .. kind .. ">" .. text .. "</" .. kind .. ">" end
  assert_eq(md.strip_inline("**b** and `c`", tag), "<bold>b</bold> and <code>c</code>", "TMD paint")
  assert_eq(md.strip_inline("**b** and `c`", nil), "b and c", "TMD strip")
  assert_eq(md.strip_inline("a *i* b", tag), "a <italic>i</italic> b", "TMD italic")
  assert_eq(md.strip_inline("esc \\`tick\\*star", tag), "esc `tick*star", "TMD escapes")
  assert_eq(md.strip_inline("unclosed `code", tag), "unclosed `code", "TMD unclosed backtick")
  assert_eq(md.strip_inline("plain", tag), "plain", "TMD plain passthrough")
  print("TMD ui_markdown direct: OK")
end

if failed > 0 then
    os.exit(1)
end
