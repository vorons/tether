-- src/tether/ui/confirm.lua — one-shot confirmation menu: rows, key kernel,
-- resolve + keyboard handler.
--
-- IN:  rows(c, sel, width, P) takes values only (no S, no globals):
--        c (confirmation {label, body, question, options} or nil),
--        sel (1-based highlight), width, P { yellow, rev, wrap(text, w),
--        hint(pairs, inner), confirm_hint } -> row strings out.
--      decide_key(k, sel, n, digits) is the pure key kernel (no S):
--        k {kind, char, name}, sel, n (option count), digits (per-copy
--        digit table) -> { decision = "allow"|... } | { move = -1|+1 } |
--        { dismiss = true } (esc) | nil (unhandled kind). Mouse hit-testing
--        needs the viewport and stays in handle_confirmation_key.
--      resolve_confirmation(bag, deps, decision) + handle_confirmation_key
--      take (bag, deps, ...) like the busy-pump handlers: bag is the state
--      (S.confirmation/confirmation_sel/error_banner/cfg/api_key), deps is
--      the impure edge { turn, agent, on_event, sync, paint, bump, settle,
--      note, layout, content_width, ensure, row_text, digits }.
--      Moved verbatim from ui.lua (Phase D 4.2); the facade keeps thin
--      proxies so call sites and M.* seams keep working, and the 2.2 key
--      table keeps owning the keyboard.
-- OUT: module table { menu_rows, decide_key, resolve_confirmation,
--      handle_confirmation_key }. No S, no globals, no terminal I/O.
-- EXAMPLE:
--      decide_key({kind="text",char="y"}, 1, 5, digits) --> { decision = "allow" }
--      menu_rows(c, 1, 80, P) --> { "", "⚠ label", ... }
local M = {}

-- confirm-menu-redesign: header, optional payload body (patch diff /
-- danger warning) directly under it, question, options, muted hint.
local function menu_rows(c, sel, width, P)
    if not c then return {} end
    local co = { "", P.yellow("⚠ " .. (c.label or "confirmation")) }
    if c.body and c.body ~= "" then
        -- patch bodies render through the diff pipeline (highlighted, same
        -- as the tool result rows); everything else wraps plainly. P.diff
        -- is the facade hook — older callers without it keep plain wrap.
        local dname = c.detail and c.detail.name
        local dargs = c.detail and c.detail.args
        if dname == "patch" and P.diff then
            for _, l in ipairs(P.diff(c.body, dargs and dargs.path, width - 2) or {}) do
                co[#co + 1] = "  " .. l
            end
        else
            for _, l in ipairs(P.wrap(c.body, width - 2)) do
                co[#co + 1] = "  " .. l
            end
        end
    end
    co[#co + 1] = ""
    co[#co + 1] = (c.question or "Allow this action?")
    co[#co + 1] = ""
    for i, opt in ipairs(c.options or {}) do
        local t = "  " .. opt
        co[#co + 1] = (i == sel) and P.rev(t) or t
    end
    co[#co + 1] = ""
    co[#co + 1] = "  " .. P.hint(P.confirm_hint)
    return co
end
M.menu_rows = menu_rows

-- Index verdicts in option order (palette-only: 5 options).
local DECISIONS = { [1] = "allow", [2] = "session", [3] = "always",
    [4] = "deny", [5] = "cancel" }

-- The pure key kernel: which keys resolve, move, or dismiss — no state.
local function decide_key(k, sel, n, digits)
    if not k then return nil end
    if k.kind == "esc" then return { dismiss = true } end
    if k.kind == "enter" then return { decision = DECISIONS[sel] or "deny" } end
    if k.kind == "text" then
        local c = k.char
        -- palette-only T2: digit shortcuts 1..5 (plus legacy y/a/A/n)
        local digit = tonumber(c)
        if digit and digits and digits[digit] then
            return { decision = digits[digit] }
        elseif c == "y" then return { decision = "allow" }
        elseif c == "n" then return { decision = "deny" }
        elseif c == "a" then return { decision = "session" }
        elseif c == "A" then return { decision = "always" } end
        return nil
    end
    if k.kind == "special" then
        if k.name == "up" then return { move = -1 } end
        if k.name == "down" then return { move = 1 } end
        return nil
    end
    return nil
end
M.decide_key = decide_key
M.DECISIONS = DECISIONS

local function resolve_confirmation(bag, deps, decision)
    deps = deps or {}
    local detail = bag.confirmation and bag.confirmation.detail
    -- palette-only R3/R6: every decision clears the menu.
    bag.confirmation = nil
    bag.confirmation_sel = 1
    if detail and deps.agent then
        local needs_resume = true
        local ok, err = deps.turn.confirm(detail.id, decision, bag.cfg, deps.on_event)
        if not ok and err then bag.error_banner = tostring(err) end
        if deps.note then
            deps.note("→ confirmation: " .. decision .. " (" .. detail.name .. ")")
        end
        if decision == "cancel" then needs_resume = false end
        if needs_resume then
            -- resume the agent loop after confirmation; turn owns begin/finish
            local ok2, err2 = deps.turn.continue(bag, bag.cfg, bag.api_key or "",
                deps.on_event, function()
                    deps.sync()
                    deps.paint(true)
                end)
            if not ok2 and err2 then bag.error_banner = tostring(err2) end
        end
        if deps.settle then deps.settle() end
    end
    if deps.bump then deps.bump() end -- the decision line appended above
    if deps.sync then deps.sync() end -- menu gone, back to the idle input box
end
M.resolve_confirmation = resolve_confirmation

local function handle_confirmation_key(bag, deps, k)
    deps = deps or {}
    if not k then return end
    -- the menu owns the keyboard but never the scroll: wheel and PgUp/PgDn
    -- reach the transcript (same math as the normal handlers), otherwise a
    -- long patch body is unviewable while deciding.
    if k.kind == "mouse" and (k.name == "scroll_up" or k.name == "scroll_down") then
        if k.name == "scroll_up" then
            bag.scroll = (bag.scroll or 0) + 3
            bag.user_scrolled = true
        else
            bag.scroll = math.max(0, (bag.scroll or 0) - 3)
            if bag.scroll == 0 then bag.user_scrolled = false end
        end
        if deps.sync then deps.sync() end
        return
    end
    if k.kind == "special" and (k.name == "pgup" or k.name == "pgdn") then
        local h = (bag.h and bag.h > 0) and bag.h or 24
        local step = math.max(1, math.floor(h / 2))
        if k.name == "pgup" then
            bag.scroll = (bag.scroll or 0) + step
            bag.user_scrolled = true
        else
            bag.scroll = math.max(0, (bag.scroll or 0) - step)
            if bag.scroll == 0 then bag.user_scrolled = false end
        end
        if deps.sync then deps.sync() end
        return
    end
    if k.kind == "mouse" and k.name == "press" then
        -- options are rendered inside the transcript flow; match by column band
        local c = bag.confirmation
        if c and c.options and #c.options > 0 then
            local L = deps.layout()
            local cw = deps.content_width(L.w)
            local total = deps.ensure(cw)
            -- options are the last block lines except the trailing
            -- confirm-menu-redesign blank + hint rows (2 lines)
            local above = total - #c.options - 2
            -- k.row is a SCREEN row; map it to a transcript line index the
            -- same way the tool-row click below does (mixing screen rows with
            -- line indices picked the wrong option, i.e. the wrong verdict).
            local bottom = math.min(total, total - bag.scroll)
            if bottom < 1 then bottom = 1 end
            local top = bottom - L.transcript_h + 1
            if top < 1 then top = 1 end
            if k.row and k.row >= L.transcript_row
                and k.row <= L.transcript_row + L.transcript_h - 1 then
                local idx = top + (k.row - L.transcript_row)
                local text = (idx >= above + 1 and idx <= total)
                    and deps.row_text(idx, cw) or ""
                for i, opt in ipairs(c.options) do
                    if text:find(opt:sub(1, 10), 1, true) then
                        bag.confirmation_sel = i
                        resolve_confirmation(bag, deps, DECISIONS[i] or "deny")
                        break
                    end
                end
            end
        end
        return
    end
    local n = #((bag.confirmation and bag.confirmation.options) or {})
    local r = decide_key(k, bag.confirmation_sel, n, deps.digits)
    if not r then return end
    if r.dismiss then
        resolve_confirmation(bag, deps, "cancel")
    elseif r.decision then
        resolve_confirmation(bag, deps, r.decision)
    elseif r.move then
        if n > 0 then
            bag.confirmation_sel = math.min(n,
                math.max(1, bag.confirmation_sel + r.move))
            if deps.sync then deps.sync() end -- selection lives in the menu's rows
        end
    end
end
M.handle_confirmation_key = handle_confirmation_key

return M
