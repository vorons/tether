-- src/tether/ui/complete.lua — path completion engine: token, candidates,
-- cycle, restore, plus the `@` mention open/refilter/accept/close.
--
-- IN:  bag is the state (S.input/cursor/completion/palette_*/workspace/cfg);
--      deps is the impure edge { tools (tools module or M._tools_stub),
--      sync (facade palette_sync), lines (facade visual-rows closure) }.
--      Moved verbatim from ui.lua (ui-facade-thinning 1.1) with identical
--      function names, so the 4.1 OWN block needs only the file added to
--      the T4.1 scan; the facade keeps thin M.* seams tests drive.
-- OUT: module table { completion_token, completion_apply,
--      path_complete_tab, completion_cancel, completion_commit,
--      at_token_start, picker_close, token_refilter, mention_open,
--      mention_accept }.
--      No S, no globals, no terminal I/O.
-- EXAMPLE:
--      complete.path_complete_tab(bag, deps) --> first candidate applied
--      complete.completion_cancel(bag, deps) --> token restored as typed
local M = {}

-- Token = text from the cursor back to the previous whitespace or line
-- start; a leading @ is a mention prefix, kept verbatim in the input.
local function completion_token(bag, deps)
    local lines = deps.lines()
    for _, ln in ipairs(lines) do
        if bag.cursor >= ln.from and bag.cursor <= ln.from + #ln.text then
            local upto = ln.text:sub(1, bag.cursor - ln.from)
            local tok = upto:match("([^%s]*)$") or ""
            local pos = ln.from + 1 + #upto - #tok
            return tok, pos
        end
    end
    return nil
end
M.completion_token = completion_token

local function completion_apply(bag, label)
    local comp = bag.completion
    if not comp then return end
    local at = comp.original:match("^(@)")
    local replace = at and ("@" .. label) or label
    local head = bag.input:sub(1, comp.start - 1)
    bag.input = head .. replace .. (comp.tail or "")
    -- comp.start is one-based and bag.cursor is a zero-based offset, so the
    -- cursor lands directly after the applied text: before the tail, and never
    -- past the end of the input (spec tui: Path completion)
    bag.cursor = comp.start - 1 + #replace
end
M.completion_apply = completion_apply

-- 4.3: gated on ui.path_completion; Tab inside an open palette keeps its
-- command-completion meaning (handled by the palette branch of handle_key).
local function path_complete_tab(bag, deps)
    if bag.palette_active then return end
    if bag.cfg and bag.cfg.ui and bag.cfg.ui.path_completion == false then return end
    local tools_mod = deps.tools
    if tools_mod == nil or tools_mod.path_complete == nil then return end
    local tok, token_pos = completion_token(bag, deps)
    if not tok or tok == "" then return end
    -- A `@` preview can survive its palette emptying; Tab is a fresh, forcing
    -- completion, so that session (and its cached walk) is handed over here.
    local cache = nil
    if bag.completion and bag.completion.mention then
        cache = bag.completion.cache
        bag.completion = nil
    end
    local r = tools_mod.path_complete(tok, { workspace = bag.workspace }, cache)
    local cands = (r and r.candidates) or {}
    if #cands == 0 then return end -- no candidates -> input unchanged, no palette
    if #cands == 1 then
        -- one-shot apply; no cycle state to restore, but the text after the
        -- token still has to survive: a unique candidate completes the token
        -- in place (spec tui: Path completion), so completing `ag` inside
        -- `ag.bak` must not lose `.bak`. The palette branch carries the same tail.
        local one_comp = { start = token_pos, stop = token_pos + #tok,
            original = tok, tail = bag.input:sub(token_pos + #tok) }
        bag.completion = one_comp
        completion_apply(bag, cands[1])
        bag.completion = nil
        return
    end
    local comp = bag.completion or {}
    comp.start = comp.start or token_pos
    if not comp.original then
        comp.original = bag.input:sub(comp.start, comp.start + #tok - 1)
        comp.tail = bag.input:sub(comp.start + #tok)
    end
    comp.items = cands
    comp.cache = r.cache
    comp.truncated = r.truncated == true
    if not bag.palette_active then
        bag.palette_mode = "path"
        bag.palette_active = true
        bag.palette_items = {}
        for _, c in ipairs(cands) do
            bag.palette_items[#bag.palette_items + 1] = { label = c, desc = "" }
        end
        bag.palette_sel = 1
    else
        bag.palette_sel = (bag.palette_sel % #comp.items) + 1
    end
    bag.completion = comp
    completion_apply(bag, comp.items[bag.palette_sel])
end
M.path_complete_tab = path_complete_tab

-- 4.2: Esc while the completion palette is open restores the token exactly
-- as typed before the first Tab.
local function completion_cancel(bag, deps)
    local comp = bag.completion
    if not comp then return end
    bag.completion = nil
    bag.input = bag.input:sub(1, comp.start - 1) .. comp.original .. (comp.tail or "")
    bag.cursor = comp.start - 1 + #comp.original
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
    deps.sync()
end
M.completion_cancel = completion_cancel

-- 4.2: any non-tab/non-esc key during active completion keeps the applied
-- text and clears the cycle state (input is not touched).
local function completion_commit(bag, deps)
    if bag.completion then
        bag.completion = nil
        bag.palette_active = false
        bag.palette_mode = "command"
        bag.palette_items = {}
        bag.palette_sel = 1
        deps.sync()
    end
end
M.completion_commit = completion_commit

-- True when the cursor is at a token start: nothing typed yet, or the byte
-- before it is whitespace. An "@" anywhere else is ordinary text.
local function at_token_start(bag)
    if bag.cursor == 0 then return true end
    return bag.input:sub(bag.cursor, bag.cursor):find("%s") ~= nil
end
M.at_token_start = at_token_start

local function picker_close(bag)
    bag.completion = nil
    bag.palette_active = false
    bag.palette_mode = "command"
    bag.palette_items = {}
    bag.palette_sel = 1
end
M.picker_close = picker_close

-- Re-rank the token against the walk the session already did, whichever
-- trigger opened it. The cache key (scoped directory + hidden rule) is what
-- tools.path_complete compares, so a keystroke that only extends the fuzzy
-- remainder costs no filesystem work. For a `@` session the palette closes
-- once the token loses its `@`; for a Tab session the typed token becomes the
-- baseline Esc restores, so the user's own keystrokes are never undone.
local function token_refilter(bag, deps)
    local comp = bag.completion
    if not comp then return end
    local tok, token_pos = completion_token(bag, deps)
    if not tok or tok == "" then
        picker_close(bag)
        return
    end
    if comp.mention and tok:sub(1, 1) ~= "@" then
        picker_close(bag)
        return
    end
    local tools_mod = deps.tools
    if not tools_mod or tools_mod.path_complete == nil then
        picker_close(bag)
        return
    end
    comp.start = token_pos
    if not comp.mention then
        comp.original = tok
        comp.tail = bag.input:sub(token_pos + #tok)
    end
    local r = tools_mod.path_complete(tok, { workspace = bag.workspace }, comp.cache)
    local cands = (r and r.candidates) or {}
    comp.items = cands
    comp.cache = (r and r.cache) or comp.cache
    comp.truncated = (r and r.truncated) == true
    bag.completion = comp
    bag.palette_items = {}
    for _, c in ipairs(cands) do
        bag.palette_items[#bag.palette_items + 1] = { label = c, desc = "" }
    end
    bag.palette_sel = 1
    if #cands == 0 then
        -- Nothing matches yet: hide the palette but keep the session, so the
        -- next character can reopen it without typing "@" again.
        bag.palette_active = false
        bag.palette_mode = "command"
        return
    end
    bag.palette_active = true
    bag.palette_mode = comp.mention and "mention" or "path"
end
M.token_refilter = token_refilter

local function mention_open(bag, deps)
    if bag.cfg and bag.cfg.ui and bag.cfg.ui.path_completion == false then return end
    local tok, token_pos = completion_token(bag, deps)
    if not tok or tok:sub(1, 1) ~= "@" then return end
    bag.completion = { start = token_pos, mention = true }
    token_refilter(bag, deps)
end
M.mention_open = mention_open

-- Enter/Tab: swap the typed token for "@<candidate>", leave the text after it
-- alone, and put the cursor directly behind the inserted path.
local function mention_accept(bag, deps)
    local comp = bag.completion
    local it = comp and bag.palette_items[bag.palette_sel]
    if not it then return end
    local tok, token_pos = completion_token(bag, deps)
    if not tok then picker_close(bag) return end
    local replace = "@" .. it.label
    bag.input = bag.input:sub(1, token_pos - 1) .. replace
        .. bag.input:sub(token_pos + #tok)
    bag.cursor = token_pos - 1 + #replace
    picker_close(bag)
end
M.mention_accept = mention_accept

return M
