-- src/tether/ui/keys.lua — key reading: bytes -> typed events.
--
-- IN:  every entry takes a `bag` first: the state + host boundary table.
--      Required bag fields (ui.lua passes its own M, so its M._* seams
--      keep working; direct tests pass a stub):
--        bag._byte_stash    array of queued byte values (read/write)
--        bag._esc_stash_s   wall-clock of a stashed lone ESC, or nil (read/write)
--        bag._paint_clock() wall-clock seconds (ui's M._paint_clock)
--      Byte input comes from the `tether` host global (read_char,
--      read_char_nb) — present in the binary, stubbed by tests.
--      Pure decoders (decode_mods, decode_modified_key, decode_csi_u,
--      decode_modify_other_keys, legacy_csi_mods) take values only.
-- OUT: module table { decode_*, read_nb, stash_front, read_utf8_char,
--      decode_first_byte, read_key, read_key_nb }. No TUI state, no S.
-- EXAMPLE:
--      local bag = { _byte_stash = {}, _paint_clock = os.clock }
--      keys.read_key(bag) --> { kind = "enter" } | { kind = "text", char = "x" } | ...
--
-- Event shapes produced here (and the only ones handle_key consumes):
--   { kind = "esc" | "enter" | "newline" | "backspace" | "tab" }
--   { kind = "text",  char = string }
--   { kind = "paste", text = string }
--   { kind = "ctrl",  code = number, shift = bool?, alt = bool? }
--   { kind = "alt",   code = number }
--   { kind = "special", name = string, ctrl = bool?, shift = bool? }
--   { kind = "mouse", name = string, col = number, row = number, button = number }
-- No layout, palette, or mode knowledge lives here — decode is pure
-- bytes -> event. Terminal quirks (kitty CSI-u, modifyOtherKeys, X11 copy
-- chords) are normalized into the typed fields above before return.
--
-- Phase B 2.1 dispatch table (kind -> handler, bag/callback shape):
--   route(k, ctx) -> string key, encoding handle_key's routing ORDER
--     byte-identically (login_secret > confirmation > ask > error_dismiss >
--     mouse > ctrl > history > palette:<mode> > tab_complete > normal:<kind>).
--     ctx is values only: { login_secret, confirmation, ask, error_banner,
--       palette_active, palette_mode, busy } (truthy flags, no S).
--   dispatch maps each key to a handler fn(bag, cb, k): bag is the state
--     (S in the facade), cb is the callback table the facade supplies
--     ({ login_secret, confirmation, ask, error_dismiss, mouse, ctrl,
--       history, palette = { copy, resume, model, think, login, logout,
--       logout_confirm, mention, path, command }, tab_complete,
--       normal = { paste, text, enter, newline, backspace, esc, ctrl,
--       special } }). Until 2.2 the facade keeps its switch; this table
--     exists alongside it for routing-parity tests, then takes over.
-- EXAMPLE:
--      keys.route({kind="enter"}, {}) --> "normal:enter"
--      keys.route({kind="text",char="x"}, {palette_active=true,
--        palette_mode="model"}) --> "palette:model"
local M = {}

-- kitty keyboard protocol (spec: "Comprehensive keyboard handling in
-- terminals"). Flag 1 (disambiguate escape codes) is pushed at startup and
-- popped on exit, so modified keys arrive as `CSI <code>; <mods> u`
-- instead of ambiguous legacy bytes. Modifiers are a bit field plus one:
-- shift 1, alt 2, ctrl 4, super 8 (so the encoded value is mask + 1).
local function decode_mods(mask)
    return {
        shift = mask % 2 == 1,
        alt   = math.floor(mask / 2) % 2 == 1,
        ctrl  = math.floor(mask / 4) % 2 == 1,
    }
end
M.decode_mods = decode_mods

-- xterm modifyOtherKeys uses its own encoding: 2 shift, 3 alt, 4 shift+alt,
-- 5 ctrl, 6 shift+ctrl, 7 alt+ctrl, 8 shift+alt+ctrl (1 = no modifiers).
local function mods_from_xterm(m)
    local shift = m == 2 or m == 4 or m == 6 or m == 8
    local alt   = m == 3 or m == 4 or m == 7 or m == 8
    local ctrl  = m == 5 or m == 6 or m == 7 or m == 8
    return { shift = shift, alt = alt, ctrl = ctrl }
end
M.mods_from_xterm = mods_from_xterm

-- One key with explicit modifiers -> the same key table read_key builds for
-- legacy bytes, so the rest of the TUI is encoding-agnostic.
local function decode_modified_key(code, mods)
    if code == 27 then return { kind = "esc" } end
    if code == 13 then
        -- Enter stays legacy when unmodified; any modifier means the terminal
        -- sends it here (Shift/Ctrl/Alt+Enter insert a newline). Alt is kept
        -- on the event so the busy pump can tell Alt+Enter (follow-up) from
        -- Shift/Ctrl+Enter (plain newline).
        if mods.shift or mods.ctrl or mods.alt then
            return { kind = "newline", alt = mods.alt or nil }
        end
        return { kind = "enter" }
    end
    if code == 9 then return { kind = "tab" } end
    if code == 127 or code == 8 then return { kind = "backspace" } end
    if mods.ctrl then
        -- legacy ctrl mapping: a-z -> 1..26, space -> 0, rest masked to 0x1f
        local c = code
        if c >= 97 and c <= 122 then c = c - 96
        elseif c == 32 then c = 0
        else c = c % 32 end
        return { kind = "ctrl", code = c, shift = mods.shift, alt = mods.alt }
    end
    if mods.alt and code >= 32 then return { kind = "alt", code = code } end
    -- No modifiers: only terminals reporting every key (flag 8) send text here.
    -- Kitty functional codes (57312..57343) are keys, never text.
    if code >= 32 and code < 57344 and not (code >= 57312 and code <= 57343) then
        return { kind = "text", char = utf8.char(code) }
    end
    return { kind = "special", name = "unknown" }
end
M.decode_modified_key = decode_modified_key

-- kitty CSI-u: `<code>[:shifted[:base]] [;<mods>[:event]] [;<text>] u`
local function decode_csi_u(p)
    local code = p:match("^(%d+)")
    if not code then return nil end
    local rest = p:sub(#code + 1)
    local mods_field = rest:match("^[^;]*;([^;]*)") or ""
    local mods = tonumber(mods_field:match("^(%d+)")) or 1
    return decode_modified_key(tonumber(code), decode_mods(mods - 1))
end
M.decode_csi_u = decode_csi_u

-- xterm modifyOtherKeys (mode 2): `27 ; <xterm mods> ; <code> ~`
local function decode_modify_other_keys(p)
    local m, code = p:match("^27;(%d+);(%d+)$")
    if not m then return nil end
    return decode_modified_key(tonumber(code), mods_from_xterm(tonumber(m)))
end
M.decode_modify_other_keys = decode_modify_other_keys

-- Modifier mask from an arrow/Home/End style CSI parameter list: the standard
-- form is `1;<mods>`, and the odd bare `5;` form old terminals sent.
local function legacy_csi_mods(p)
    local m = p:match("^1;(%d+)$") or p:match("^(%d+);$")
    return m and decode_mods(tonumber(m) - 1) or nil
end
M.legacy_csi_mods = legacy_csi_mods

-- T176: non-ASCII keys arrive as multibyte UTF-8, but decode_first_byte
-- only owns one byte — the rest of the keypress is already queued behind it.
-- A lead byte pulls its continuation bytes (non-blocking: they arrive
-- atomically with the keypress) and emits ONE text event. A peeked byte that
-- is not a valid continuation starts the next event and is stashed for the
-- next read; a truncated tail emits what arrived (display code degrades it
-- instead of raising). Previously every byte became its own text event, so
-- S.input filled with invalid UTF-8 fragments and vlen raised
-- "invalid UTF-8 code" on any Russian input.
local ESC_AGE_S = 0.15
M.ESC_AGE_S = ESC_AGE_S

local function read_nb(bag)
    bag._byte_stash = bag._byte_stash or {}
    if #bag._byte_stash > 0 then return table.remove(bag._byte_stash, 1) end
    return tether.read_char_nb()
end
M.read_nb = read_nb

-- Push bytes back to the FRONT of the stash (order preserved) so a
-- fragmented escape sequence is retried whole on the next tick instead of
-- leaking its tail ("[<65;48;31M") into the input as text.
local function stash_front(bag, list)
    if not list or #list == 0 then return end
    -- Consumed bytes (in list) were removed from the stash by read_nb()
    -- calls inside nb_read(). The stash is therefore always empty here,
    -- and we can safely replace it with the list.
    bag._byte_stash = list
end
M.stash_front = stash_front

local function read_utf8_char(bag, first)
    local need
    if first >= 0xC2 and first <= 0xDF then need = 1
    elseif first >= 0xE0 and first <= 0xEF then need = 2
    elseif first >= 0xF0 and first <= 0xF4 then need = 3
    else return string.char(first) end
    local parts = { string.char(first) }
    for _ = 1, need do
        local b = tether.read_char_nb()
        if b == nil then break end -- truncated arrival: emit what we have
        b = b & 0xFF
        if b < 0x80 or b > 0xBF then
            bag._byte_stash = bag._byte_stash or {}
            bag._byte_stash[#bag._byte_stash + 1] = b
            break
        end
        parts[#parts + 1] = string.char(b)
    end
    return table.concat(parts)
end
M.read_utf8_char = read_utf8_char

-- Decode one already-read first byte; continuation bytes come from
-- read_char_nb (and the paste body from read_char). Shared by read_key and
-- read_key_nb so blocking and non-blocking paths stay identical.
-- nb (non-blocking caller, the busy pump): an escape sequence split across
-- reads must not decode as a lone esc plus a text tail. When the next byte
-- is not available yet, the consumed prefix goes back to the stash front
-- and decode yields nil — the next tick retries the sequence whole.
local function decode_first_byte(bag, c, nb)
    bag._byte_stash = bag._byte_stash or {}
    if c == 27 then
        local consumed = { c }
        local function nb_read()
            local b = read_nb(bag)
            if b == nil then
                if nb then stash_front(bag, consumed) end
                return nil
            end
            consumed[#consumed + 1] = b & 0xFF
            return b
        end
        local function incomplete()
            if not nb then return { kind = "esc" } end
            -- A split sequence's tail lands on the next tick (the pump and
            -- the idle retry re-run the decoder every quantum). A lone ESC
            -- that no tail follows past the age window is its own keypress:
            -- stop re-stashing it and emit, instead of holding it until the
            -- next key arrives.
            if #consumed == 1 then
                local now = bag._paint_clock()
                if bag._esc_stash_s and now - bag._esc_stash_s >= ESC_AGE_S then
                    bag._byte_stash = {}
                    bag._esc_stash_s = nil
                    return { kind = "esc" }
                end
                bag._esc_stash_s = bag._esc_stash_s or now
            end
            return nil
        end
        local b2 = nb_read()
        if b2 == nil then return incomplete() end
        local c2 = b2 & 0xFF
        if c2 ~= 91 and c2 ~= 79 then
            return { kind = "alt", code = c2 }
        end
        local params = {}
        while true do
            local b3 = nb_read()
            if b3 == nil then return incomplete() end
            local c3 = b3 & 0xFF
            -- digits, ';', ':', '<', '>': ':' carries kitty alternate-key
            -- sub-fields, so it must not terminate the sequence
            if (c3 >= 48 and c3 <= 57) or c3 == 58 or c3 == 59 or c3 == 60 or c3 == 62 then
                params[#params + 1] = string.char(c3)
            else
                local p = table.concat(params)
                if p == "200" and c3 == 126 then
                    local buf = {}
                    while true do
                        local ch = tether.read_char()
                        if ch == nil or ch == -1 then break end
                        local cc = ch & 0xFF
                        if cc == 27 then
                            -- paste terminator is ESC [ 2 0 1 ~. Match it
                            -- incrementally: a stray ESC (or split arrival)
                            -- flushes as content and can never eat a real
                            -- terminator that starts later.
                            local target = "[201~"
                            local cand = {}
                            local b0 = read_nb(bag)
                            if b0 then cand[#cand + 1] = string.char(b0 & 0xFF) end
                            while #cand > 0
                                and target:sub(1, #cand) == table.concat(cand)
                                and #cand < #target do
                                local b = tether.read_char()
                                if b == nil or b == -1 then break end
                                cand[#cand + 1] = string.char(b & 0xFF)
                            end
                            if table.concat(cand) == target then
                                return { kind = "paste", text = table.concat(buf) }
                            end
                            buf[#buf + 1] = string.char(cc)
                            for _, s in ipairs(cand) do buf[#buf + 1] = s end
                        elseif cc >= 32 or cc == 10 then
                            buf[#buf + 1] = string.char(cc)
                        end
                    end
                    return { kind = "paste", text = table.concat(buf) }
                end
                -- kitty CSI-u (flag 1 pushed) and xterm modifyOtherKeys
                -- (mode 2 enabled): both encode one key with modifiers.
                if c3 == 117 and p ~= "" then
                    local kitty = decode_csi_u(p)
                    if kitty then return kitty end
                    return { kind = "special", name = "unknown" }
                end
                -- T18: some terminals report Ctrl+Shift+C (copy) as a CSI
                -- whose final byte is C with a non-arrow params blob. Normalize
                -- to a typed ctrl event so handle_key never re-parses params.
                if p == "4:53;96" and c3 == 67 then
                    return { kind = "ctrl", code = 3, shift = true }
                end
                local names = {
                    [65] = "up", [66] = "down", [67] = "right", [68] = "left",
                    [72] = "home", [70] = "end",
                }
                if names[c3] then
                    local mods = legacy_csi_mods(p)
                    -- X11 fallback: Shift+Ctrl+C as `CSI 1;2 C` — same chord
                    if c3 == 67 and p == "1;2" then
                        return { kind = "ctrl", code = 3, shift = true }
                    end
                    return { kind = "special", name = names[c3],
                             ctrl = mods and mods.ctrl, shift = mods and mods.shift }
                end
                if c3 == 126 then
                    -- modifyOtherKeys: 27;<xterm mods>;<code>~
                    local mok = decode_modify_other_keys(p)
                    if mok then return mok end
                    -- `~` keys carry modifiers as `<code>;<mods>`
                    local base, mp = p:match("^(%d+);(%d+)$")
                    base = base or p
                    local mods = mp and decode_mods(tonumber(mp) - 1) or nil
                    local m = ({ ["1"]="home", ["2"]="insert", ["3"]="delete",
                                 ["4"]="end", ["5"]="pgup", ["6"]="pgdn",
                                 ["7"]="home", ["8"]="end" })[base]
                    if m then
                        return { kind = "special", name = m,
                                 ctrl = mods and mods.ctrl, shift = mods and mods.shift }
                    end
                end
                -- M8/R6: F3 (CSI 1~ with modifier 1;3~ etc) — terminal sends
                -- ESC[13~ / ESC[14~ for F3/Shift+F3 on xterm; match by params
                if c3 == 126 and p == "13" then return { kind = "special", name = "f3" } end
                if c3 == 126 and p == "14" then return { kind = "special", name = "sf3" } end
                -- T17/TW1: mouse SGR (1006) — final byte M (press) / m
                -- (release). Per xterm the params are code;col;row (button
                -- code first: 0 press, 32 release, 64 wheel up, 65 wheel
                -- down; the '<' SGR prefix lands in p and the pattern skips
                -- it). The old col;row;code read the button code from the
                -- last field: every wheel tick decoded as button 5 = unknown,
                -- so the wheel never scrolled and the terminal's arrow
                -- fallback fed history into the input.
                if c3 == 77 or c3 == 109 then
                    local code, col, row = p:match("(%d+);(%d+);(%d+)")
                    code, col, row = tonumber(code), tonumber(col), tonumber(row)
                    local name
                    if code == 0 then name = "press"
                    elseif code == 32 then name = "release"
                    elseif code == 64 then name = "scroll_up"
                    elseif code == 65 then name = "scroll_down"
                    else name = "unknown" end
                    return { kind = "mouse", name = name,
                             col = col, row = row, button = code }
                end
                return { kind = "special", name = "unknown" }
            end
        end
    elseif c == 13 then return { kind = "enter" }
    elseif c == 10 then return { kind = "newline" }
    elseif c == 127 or c == 8 then return { kind = "backspace" }
    elseif c == 9 then return { kind = "tab" }
    elseif c < 32 then return { kind = "ctrl", code = c }
    elseif c >= 0x80 then
        return { kind = "text", char = read_utf8_char(bag, c) }
    else
        return { kind = "text", char = string.char(c) }
    end
end
M.decode_first_byte = decode_first_byte

-- Phase B 2.1: routing order as data. Mirrors handle_key's branch order
-- exactly; the facade's switch stays until 2.2 migrates bodies here.
local function route(k, ctx)
    ctx = ctx or {}
    k = k or {}
    if ctx.login_secret then return "login_secret" end
    if ctx.confirmation then return "confirmation" end
    if ctx.ask then return "ask" end
    if (k.kind == "enter" or k.kind == "esc") and ctx.error_banner then
        return "error_dismiss"
    end
    if k.kind == "mouse" then return "mouse" end
    if k.kind == "ctrl" then return "ctrl" end
    if k.kind == "special" and (k.name == "up" or k.name == "down") and k.ctrl then
        return "history"
    end
    if ctx.palette_active then
        local mode = ctx.palette_mode or "command"
        if mode == "copy" then return "palette:copy"
        elseif mode == "resume" then return "palette:resume"
        elseif mode == "model" then return "palette:model"
        elseif mode == "think" then return "palette:think"
        elseif mode == "login" then return "palette:login"
        elseif mode == "logout" then return "palette:logout"
        elseif mode == "logout-confirm" then return "palette:logout-confirm"
        elseif mode == "mention" then return "palette:mention"
        elseif mode == "path" then return "palette:path"
        else return "palette:command" end
    end
    if k.kind == "tab" then return "tab_complete" end
    return "normal:" .. tostring(k.kind or "nil")
end
M.route = route

-- Handler shape: fn(bag, cb, k). Each entry forwards to the facade's
-- callback of the same name; palette/normal sub-tables forward by mode/kind.
local function cb_call(cb, name, bag, k)
    local fn = cb and cb[name]
    if type(fn) == "function" then return fn(bag, k) end
end
local dispatch = {}
dispatch["login_secret"] = function(bag, cb, k) return cb_call(cb, "login_secret", bag, k) end
dispatch["confirmation"] = function(bag, cb, k) return cb_call(cb, "confirmation", bag, k) end
dispatch["ask"] = function(bag, cb, k) return cb_call(cb, "ask", bag, k) end
dispatch["error_dismiss"] = function(bag, cb, k) return cb_call(cb, "error_dismiss", bag, k) end
dispatch["mouse"] = function(bag, cb, k) return cb_call(cb, "mouse", bag, k) end
dispatch["ctrl"] = function(bag, cb, k) return cb_call(cb, "ctrl", bag, k) end
dispatch["history"] = function(bag, cb, k) return cb_call(cb, "history", bag, k) end
dispatch["tab_complete"] = function(bag, cb, k) return cb_call(cb, "tab_complete", bag, k) end
local palette_modes = { "copy", "resume", "model", "think", "login",
    "logout", "logout-confirm", "mention", "path", "command" }
for _, mode in ipairs(palette_modes) do
    local key = "palette:" .. mode
    dispatch[key] = function(bag, cb, k)
        local pal = cb and cb.palette
        local fn = pal and pal[mode:gsub("-", "_")]
        if type(fn) == "function" then return fn(bag, k) end
    end
end
local normal_kinds = { "paste", "text", "enter", "newline", "backspace",
    "esc", "ctrl", "special", "tab", "alt" }
for _, kind in ipairs(normal_kinds) do
    local key = "normal:" .. kind
    dispatch[key] = function(bag, cb, k)
        local norm = cb and cb.normal
        local fn = norm and norm[kind]
        if type(fn) == "function" then return fn(bag, k) end
    end
end
M.dispatch = dispatch

local function read_key(bag)
    -- Blocking: wait on read_char directly when the stash is empty, so no
    -- poll timeout delays the keypress; a stashed lookahead byte goes first.
    bag._byte_stash = bag._byte_stash or {}
    local b
    if #bag._byte_stash > 0 then b = table.remove(bag._byte_stash, 1)
    else b = tether.read_char() end
    if b == nil or b == -1 then return nil end
    return decode_first_byte(bag, b & 0xFF)
end
M.read_key = read_key

-- Non-blocking variant for the busy pump: first byte via read_char_nb so a
-- silent turn never stalls on input. Incomplete escape sequences surface as
-- esc (same as a short blocking read); the pump never blocks.
local function read_key_nb(bag)
    local b = read_nb(bag)
    if b == nil or b == -1 then return nil end
    return decode_first_byte(bag, b & 0xFF, true)
end
M.read_key_nb = read_key_nb

return M
