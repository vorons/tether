-- tether / reactor.lua — single-threaded event loop.
--
-- One iteration polls standard input, the active transport's sockets and the
-- nearest timer deadline together, then dispatches what is ready in a fixed
-- order: input first, transport sources next, expired timers last. Nothing
-- on this path blocks past one tick quantum, and no callback touches stdin
-- except through the non-blocking drain: readiness waiting belongs to the
-- single poll call, so a transfer or a timer can never stall key dispatch.
--
-- Pure Lua over two injected primitives (poll + monotonic clock), so tests
-- drive scripted readiness without wall-clock waits:
--   reactor.new({ poll = fn, clock = fn, stdin_fd = 0, quantum_ms = 80 })
local M = {}

M.QUANTUM_MS = 80

-- The loop that owns waiting right now: ui.run binds it around run() so a
-- synchronous caller parked inside the loop's dispatch (api.stream between
-- steps, an agent backoff deadline) can pump the same loop instead of
-- blocking the OS thread. nil in print mode and outside any run().
local active_loop = nil
function M.set_active(r) active_loop = r end
function M.active() return active_loop end

function M.new(opts)
    opts = opts or {}
    assert(type(opts.poll) == "function", "reactor needs poll")
    assert(type(opts.clock) == "function", "reactor needs clock")
    local r = {
        _poll = opts.poll,
        _clock = opts.clock,
        _stdin_fd = opts.stdin_fd or 0,
        _quantum = opts.quantum_ms or M.QUANTUM_MS,
        _stdin_cb = nil,
        _stdin_armed = true,
        _on_eof = nil,
        _sources = {},
        _timers = {},
        _next_id = 1,
        _stop = false,
    }

    -- fn() called when stdin is readable; must drain via read_char_nb and
    -- return the byte count (0 with a readable fd means EOF, see on_eof).
    -- Return false to disarm stdin polling.
    function r:on_stdin(fn) self._stdin_cb = fn end
    function r:on_eof(fn) self._on_eof = fn end
    -- fn() called at the end of every tick, after timers. Per-tick work
    -- (spinner cadence, background polls, redraw) lives here.
    function r:on_tick(fn) self._tick_cb = fn end

    -- src = { fds = fn() -> {read={fd}, write={fd}},
    --         ready = fn(kinds) } with kinds = {read=bool, write=bool}.
    -- ready fires when any of the source's fds is ready, or with both false
    -- on a pure timeout tick (so curl timeouts still get their step).
    -- Returns a handle for remove_source.
    function r:add_source(src)
        assert(type(src.fds) == "function", "source needs fds")
        assert(type(src.ready) == "function", "source needs ready")
        self._sources[#self._sources + 1] = src
        return src
    end
    function r:remove_source(handle)
        for i, s in ipairs(self._sources) do
            if s == handle then
                table.remove(self._sources, i)
                return true
            end
        end
        return false
    end

    -- fn fires no later than one quantum after its deadline. Returns an id.
    function r:after(delay_ms, fn)
        assert(type(fn) == "function", "timer needs fn")
        local id = self._next_id
        self._next_id = id + 1
        self._timers[#self._timers + 1] = {
            at = self._clock() + (delay_ms or 0), fn = fn, id = id,
        }
        return id
    end
    function r:cancel(id)
        for i, t in ipairs(self._timers) do
            if t.id == id then
                table.remove(self._timers, i)
                return true
            end
        end
        return false
    end

    function r:stop() self._stop = true end
    function r:stopped() return self._stop end

    local function fd_in(list, fd)
        for i = 1, #list do
            if list[i] == fd then return true end
        end
        return false
    end

    -- One iteration. Returns false when the loop is stopped.
    function r:tick()
        if self._stop then return false end
        local now = self._clock()
        local wait = self._quantum
        for _, t in ipairs(self._timers) do
            local left = t.at - now
            if left < wait then wait = left end
        end
        if wait < 0 then wait = 0 end

        local read_fds, write_fds = {}, {}
        if self._stdin_cb and self._stdin_armed then
            read_fds[#read_fds + 1] = self._stdin_fd
        end
        for _, s in ipairs(self._sources) do
            local f = s.fds() or {}
            for _, fd in ipairs(f.read or {}) do
                if not fd_in(read_fds, fd) then
                    read_fds[#read_fds + 1] = fd
                end
            end
            for _, fd in ipairs(f.write or {}) do
                if not fd_in(write_fds, fd) then
                    write_fds[#write_fds + 1] = fd
                end
            end
        end

        local ready = self._poll(read_fds, write_fds, wait) or {}
        local rready = ready.read or {}
        local wready = ready.write or {}
        local any_ready = #rready > 0 or #wready > 0

        -- input first: keys always win the tick
        if self._stdin_cb and self._stdin_armed
            and fd_in(rready, self._stdin_fd) then
            local n = self._stdin_cb()
            if n == false then
                self._stdin_armed = false
            elseif (n or 0) == 0 then
                -- readable with nothing to drain = EOF/HUP; a tty never
                -- reports this spuriously
                self._stdin_armed = false
                if self._on_eof then self._on_eof() end
            end
        end
        if self._stop then return false end

        -- transport sources next
        for _, s in ipairs(self._sources) do
            local f = s.fds() or {}
            local kinds = { read = false, write = false }
            for _, fd in ipairs(f.read or {}) do
                if fd_in(rready, fd) then kinds.read = true; break end
            end
            for _, fd in ipairs(f.write or {}) do
                if fd_in(wready, fd) then kinds.write = true; break end
            end
            if kinds.read or kinds.write or not any_ready then
                s.ready(kinds)
            end
            if self._stop then return false end
        end

        -- expired timers last, in deadline then insertion order
        now = self._clock()
        local due = {}
        for i = #self._timers, 1, -1 do
            if self._timers[i].at <= now then
                due[#due + 1] = self._timers[i]
                table.remove(self._timers, i)
            end
        end
        table.sort(due, function(a, b)
            if a.at == b.at then return a.id < b.id end
            return a.at < b.at
        end)
        for _, t in ipairs(due) do
            t.fn()
            if self._stop then return false end
        end
        if self._tick_cb then self._tick_cb() end
        return not self._stop
    end

    function r:run()
        while self:tick() do end
    end

    return r
end

return M
