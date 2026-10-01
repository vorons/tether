-- src/tether/ui/highlight.lua — per-line syntax token scanner + painter.
--
-- IN:  tokenize(line, lang, state): line is source text; lang names the
--      language (unknown/nil -> single plain token); state is an in/out
--      table (one per fence block): state.bc = inside /* */, state.str =
--      open triple quote (python). No globals.
--      highlight(line, lang, state, sgr_fn): sgr_fn(role, text) paints a
--      token; nil = plain text (no SGR). No globals.
-- OUT: module table { langs, tokenize, highlight }. Pure, no TUI state.
-- EXAMPLE:
--      highlight('local x = 1 -- c', 'lua', {}, function(role, text) return '<' .. role .. '>' .. text end)
--      --> '<keyword>local</keyword> x = <number>1</number> <comment>-- c</comment>'
--
-- Kinds: comment, string, number, keyword, plain. Plain tokens emit no SGR
-- (default foreground); token-scoped SGR wraps let the SGR-aware wrap()
-- split at any char boundary later.
local M = {}

local function kwset(list)
    local s = {}
    for _, w in ipairs(list) do s[w] = true end
    return s
end

local LANGS = {
    lua = { lc = "--", kw = kwset({"local","function","end","return","if","then","else","elseif","for","while","do","in","nil","true","false","repeat","until","not","and","or","break"}) },
    c   = { lc = "//", bo = "/*", bc = "*/", kw = kwset({"int","char","void","if","else","for","while","do","return","static","const","struct","typedef","sizeof","unsigned","long","float","double","switch","case","break","continue","sizeof"}) },
    sh  = { lc = "#", kw = kwset({"if","then","else","fi","for","do","done","while","case","esac","function","local","return","echo","export","set","readonly"}) },
    python = { lc = "#", triple = true, kw = kwset({"def","return","if","else","elif","for","while","import","from","as","class","try","except","finally","with","in","not","and","or","None","True","False","lambda","pass","yield","global","assert","raise","print","len"}) },
    js  = { lc = "//", bo = "/*", bc = "*/", kw = kwset({"var","let","const","function","return","if","else","for","while","class","new","export","import","from","async","await","true","false","null","undefined","of","in","typeof"}) },
    go  = { lc = "//", bo = "/*", bc = "*/", kw = kwset({"func","package","return","if","else","for","range","go","defer","chan","map","type","struct","interface","var","const","true","false","nil","error","len","make"}) },
    rust = { lc = "//", bo = "/*", bc = "*/", kw = kwset({"fn","let","mut","if","else","for","while","match","return","impl","trait","pub","use","mod","struct","enum","const","true","false","loop","async","await","where","crate","self","move","dyn"}) },
    json = { kw = kwset({"true","false","null"}) },
}
LANGS.h = LANGS.c
LANGS.bash = LANGS.sh
LANGS.ts = LANGS.js
-- common aliases (spec delta): share the canonical tokenizer/table
LANGS.javascript, LANGS.tsx, LANGS.jsx = LANGS.js, LANGS.js, LANGS.js
LANGS.py = LANGS.python
LANGS.shell, LANGS.zsh = LANGS.sh, LANGS.sh
LANGS["c++"], LANGS.cpp, LANGS.cc, LANGS.cxx = LANGS.c, LANGS.c, LANGS.c, LANGS.c
LANGS.rs = LANGS.rust
LANGS.golang = LANGS.go
-- supported languages with no keyword set: string literals and numbers only
LANGS.yaml = { kw = kwset({}), strq = { "'", '"' } }
LANGS.yml, LANGS.rb = LANGS.yaml, LANGS.yaml
-- string quotes per language family
LANGS.c.strq, LANGS.h.strq = { '"', "'" }, { '"', "'" }
LANGS.go.strq = { '"', "'", '`' }
LANGS.js.strq, LANGS.ts.strq = { "'", '"', "`" }, { "'", '"', "`" }
LANGS.rust.strq = { "'", '"' }
LANGS.lua.strq = { "'", '"' }
LANGS.sh.strq, LANGS.bash.strq = { "'", '"' }, { "'", '"' }
LANGS.python.strq = { "'", '"' }
LANGS.json.strq = { '"' }
M.langs = LANGS

local function tokenize(line, lang, state)
    lang = lang and lang:lower()
    local L = lang and LANGS[lang]
    if not L then return {{ text = line, kind = "plain" }} end
    state = state or {}
    local toks, n, i = {}, #line, 1
    local buf = {}
    local function flush()
        if #buf > 0 then toks[#toks + 1] = { text = table.concat(buf), kind = "plain" } end
        buf = {}
    end
    local function add(kind, t) if t ~= "" then toks[#toks + 1] = { text = t, kind = kind } end end
    local strq = L.strq or { "'", '"' }
    while i <= n do
        local c = line:sub(i, i)
        local closed, j, q
        -- open/continue triple-quoted string (python)
        if L.triple and (state.str or line:sub(i, i + 2) == '"""' or line:sub(i, i + 2) == "'''") then
            local tri = state.str or line:sub(i, i + 2)
            local start = state.str and i or i + 3
            local cclose = line:find(tri, start, true)
            if cclose then
                flush()
                add("string", line:sub(i, cclose + 2))
                state.str = nil; i = cclose + 3
            else
                flush()
                add("string", line:sub(i))
                state.str = tri; i = n + 1
            end
        else
            local consumed = false
            -- block comment (c/js/go/rust family)
            if L.bo then
                if state.bc then
                    cclose = line:find(L.bc, i, true)
                    if cclose then
                        add("comment", line:sub(i, cclose + #L.bc - 1)); state.bc = nil; i = cclose + #L.bc
                    else
                        add("comment", line:sub(i)); i = n + 1
                    end
                    consumed = true
                elseif line:sub(i, i + #L.bo - 1) == L.bo then
                    flush()
                    cclose = line:find(L.bc, i + #L.bo, true)
                    if cclose then
                        add("comment", line:sub(i, cclose + #L.bc - 1)); i = cclose + #L.bc
                    else
                        add("comment", line:sub(i)); state.bc = true; i = n + 1
                    end
                    consumed = true
                end
            end
            if not consumed then
                -- line comment
                if L.lc and line:sub(i, i + #L.lc - 1) == L.lc then
                    flush(); add("comment", line:sub(i)); i = n + 1; consumed = true
                elseif c:match("[%\"']") then
                    local qmatch = strq[1]
                    for _, qq in ipairs(strq) do if c == qq then qmatch = qq; break end end
                    if c == qmatch then
                        flush()
                        j = i + 1
                        closed = false
                        while j <= n do
                            local cj = line:sub(j, j)
                            if cj == "\\" then j = j + 2
                            elseif cj == qmatch then closed = true; break
                            else j = j + 1 end
                        end
                        if closed then add("string", line:sub(i, j)); i = j + 1; consumed = true
                        else add("string", line:sub(i)); i = n + 1; consumed = true end
                    end
                end
            end
            if not consumed and c:match("%d") then
                local num
                if c == "0" and line:sub(i + 1, i + 1):lower() == "x" then
                    num = line:match("0[xX][%a%d_]*", i)
                else
                    num = line:match("%d+", i)
                end
                if num and num ~= "." then
                    flush(); add("number", num); i = i + #num; consumed = true
                end
            end
            if not consumed and c:match("[%a_]\z") then
                local w = line:match("^[%a_][%a%d_]*", i)
                if w then
                    if L.kw[w] then flush(); add("keyword", w)
                    else buf[#buf + 1] = w end
                    i = i + #w; consumed = true
                end
            end
            if not consumed then
                buf[#buf + 1] = c; i = i + 1
            end
        end
    end
    flush()
    return toks
end
M.tokenize = tokenize

local ROLE = { comment = "comment", string = "string", number = "number", keyword = "keyword" }
M.roles = ROLE

local function highlight(line, lang, state, sgr_fn)
    local toks = tokenize(line, lang, state)
    local out = {}
    for _, t in ipairs(toks) do
        local role = ROLE[t.kind]
        -- mono theme / nil painter: raw token (roles missing), so the
        -- strip-invariant stays byte-exact even when roles are requested.
        if role and sgr_fn then out[#out + 1] = sgr_fn(role, t.text)
        else out[#out + 1] = t.text end
    end
    return table.concat(out)
end
M.highlight = highlight

return M
