-- src/tether/ui/busy.lua — busy pump and queue affordances.
--
-- IN:  every function takes the state bag S first (the facade's S; tests
--      pass a stub table). Callbacks are explicit parameters:
--        pump_keys(S, read_key_nb, handle_key): drain non-blocking keys so
--          Enter / Alt+Enter / Escape work mid-turn without a second
--          concurrent turn. Confirmation/ask/secret own the keyboard first
--          — pump is a no-op then. Returns whether any key was handled.
--        drain_stash(S, read_key_nb, handle_key): idle-tick variant used
--          when NOT busy (a lone Esc prefix waits for its tail); returns
--          the count of handled keys.
--        enqueue_busy(S, kind, queue_push, push_history, say_user,
--          clear_input, cap): shared submit path for Enter / Alt+Enter
--          while busy — user row now, queue FIFO, clear input. kind is
--          "followup" or anything else (steer). say_user(text) appends the
--          user row; clear_input() resets the field. cap is the queue cap
--          for the "queue full" banner. Does not start a turn.
--        restore_queues(S, clear_input, palette_sync): Escape while busy
--          with a non-empty queue — steers first, then follow-ups, one per
--          line. Empty queues: leave the input alone (via clear_input).
--        parse_bang(s): pure — nil = not a bang; "empty" = bare !/!!;
--          ("bang"|"double", cmd) = runnable.
-- OUT: module table { pump_keys, drain_stash, enqueue_busy, restore_queues,
--      parse_bang }. Turn control (run_bang, take_steer, drain_followups,
--      commit_input, sessions) stays in ui.lua — it owns turn.start,
--      handle_agent_event, paint and sync_tail.
-- EXAMPLE:
--      busy.pump_keys(S, read_key_nb, handle_key) --> true when keys handled
local M = {}

local function pump_keys(S, read_key_nb, handle_key)
    if not S or not S.busy then return false end
    if S.confirmation or S.ask or S.login_secret then return false end
    local handled = false
    while true do
        local k = read_key_nb()
        if not k then break end
        handled = true
        handle_key(k)
        if not S or not S.busy then break end
        if S.confirmation or S.ask or S.login_secret then break end
    end
    return handled
end
M.pump_keys = pump_keys

-- Idle retry for a stashed escape prefix: the stdin drain fires only when
-- fresh bytes arrive, so without a tick-driven retry (see run's on_tick) a
-- lone Esc would sit in the stash until the next keypress. Same shape as the
-- drain: decode everything currently readable, dispatch, count handled.
local function drain_stash(S, read_key_nb, handle_key)
    if not S or S.busy then return 0 end
    local n = 0
    while true do
        local k = read_key_nb()
        if not k then break end
        n = n + 1
        handle_key(k)
        if not S or S.quit then break end
    end
    return n
end
M.drain_stash = drain_stash

-- Shared submit path for Enter / Alt+Enter while busy: user row now, queue
-- FIFO, clear input. Does not start a turn.
local function enqueue_busy(S, kind, queue_push, push_history, say_user, clear_input, cap)
    local text = S.input
    if text:match("^%s*$") then return end
    local q = kind == "followup" and S.followup_queue or S.steer_queue
    if not queue_push(q, text) then
        S.error_banner = "queue full (" .. tostring(cap) .. ")"
        return
    end
    push_history(text)
    say_user(text)
    clear_input()
    S.error_banner = nil
    S.scroll = 0
    S.user_scrolled = false
end
M.enqueue_busy = enqueue_busy

-- Escape while busy with a non-empty queue: steers first, then follow-ups,
-- one per line (submission order across both queues is not tracked — the
-- spec fixes steering-first order). Empty queues: leave the input alone
-- (handle_key's esc branch clears / no-ops as before).
local function restore_queues(S, clear_input, palette_sync)
    if not S then return end
    local parts = {}
    for _, t in ipairs(S.steer_queue or {}) do parts[#parts + 1] = t end
    for _, t in ipairs(S.followup_queue or {}) do parts[#parts + 1] = t end
    S.steer_queue = {}
    S.followup_queue = {}
    if #parts == 0 then
        clear_input()
        return
    end
    S.input = table.concat(parts, "\n")
    S.cursor = #S.input
    palette_sync()
end
M.restore_queues = restore_queues

-- ! / !! parser: nil = not a bang; "empty" = bang with no command;
-- ("bang"|"double", cmd) = runnable.
local function parse_bang(s)
    if type(s) ~= "string" or s:sub(1, 1) ~= "!" then return nil end
    local double = s:sub(2, 2) == "!"
    local cmd = double and s:sub(3) or s:sub(2)
    cmd = cmd:match("^%s*(.-)%s*$") or ""
    if cmd == "" then return "empty" end
    return double and "double" or "bang", cmd
end
M.parse_bang = parse_bang

return M
