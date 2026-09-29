-- tether subagent — child agent runs for the `subagent` tool (config-less v1).
--
-- A task forks `tether --print` as a background child (exec_bg, same shape
-- as tools.run's blocking spawn but overlappable and killable); the call
-- blocks in the orchestrator's poll loop until every task completes.
-- Globals resolve late (embedded runtime / test stubs): bare `tools` and
-- `tether` at call time, like agent.lua does.
local M = {}

-- Static known names: allowlist validation must not depend on a (possibly
-- filtered) live schema.
M.KNOWN_TOOLS = {
    read = true, list = true, glob = true, grep = true,
    write = true, patch = true, run = true, subagent = true,
    ask = true,
}

local function is_nonempty_str(v)
    return type(v) == "string" and v ~= ""
end

-- shell single-quote (mirrors tools.sq).
local function sq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function host()
    return rawget(_G, "tether")
end

local function now_ms()
    local th = host()
    if th and th.monotonic_ms then
        local ok, ms = pcall(th.monotonic_ms)
        if ok and type(ms) == "number" then return ms end
    end
    return os.time() * 1000
end

local function toolset()
    return rawget(_G, "tools")
end

-- prompt-cache v1: " TETHER_CACHE_KEY=.. [TETHER_CACHE_SYS=..]" for the
-- child env, or "" when there is no key (or no cache module) to inherit.
-- Values are slug/hex charset, safe unquoted in the shell command.
local function cache_inherit_env(ctx)
    local cfg = (type(ctx) == "table") and ctx.cfg or nil
    local mod = rawget(_G, "cache")
        or (function()
            local chunk = loadfile("src/tether/cache.lua")
            return chunk and chunk()
        end)()
    if not mod then return "" end
    local sys_hash = nil
    if type(cfg) == "table" and type(cfg._system_blocks) == "table" then
        local okh, h = pcall(mod.blocks_hash, cfg._system_blocks)
        if okh and type(h) == "string" and h ~= "" then sys_hash = h end
    end
    local okk, key = pcall(mod.resolve_key, cfg, sys_hash)
    if not okk or type(key) ~= "string" or key == "" then return "" end
    if sys_hash then
        return " TETHER_CACHE_KEY=" .. key .. " TETHER_CACHE_SYS=" .. sys_hash
    end
    return " TETHER_CACHE_KEY=" .. key
end

-- Validate one task item. Defaults resolve per field item -> call -> run.
-- ctx = { cfg, workspace, model, timeout_default }.
-- Returns a normalized item or nil, err. Pure except cwd containment
-- (needs tools + cfg, like the run guard).
function M.validate_item(item, call_defs, ctx)
    if type(item) ~= "table" then
        return nil, "subagent task must be an object"
    end
    if not is_nonempty_str(item.task) then
        return nil, "subagent task must be a non-empty string"
    end
    call_defs = (type(call_defs) == "table") and call_defs or {}
    ctx = (type(ctx) == "table") and ctx or {}
    local function pick(...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if is_nonempty_str(v) then return v end
        end
        return nil
    end
    local out = { task = item.task }
    out.model = pick(item.model, call_defs.model, ctx.model)
    out.cwd = pick(item.cwd, call_defs.cwd, ctx.workspace)
    -- sequel: resume a finished child session instead of starting fresh.
    -- Only format-checked here; an unknown id fails fast in the child
    -- (print --resume exits 1 naming it).
    out.resume = pick(item.resume, nil, nil)
    if out.cwd == nil or out.cwd == "" then
        return nil, "subagent cwd is unknown (no workspace)"
    end
    local timeout = item.timeout ~= nil and item.timeout or call_defs.timeout
    if timeout == nil then timeout = ctx.timeout_default end
    timeout = tonumber(timeout) or 0
    if timeout < 1 then timeout = 600 end
    out.timeout = math.floor(timeout)
    local allow = (item.tools ~= nil) and item.tools or call_defs.tools
    if allow ~= nil then
        if type(allow) ~= "table" then
            return nil, "subagent tools must be an array"
        end
        for _, n in ipairs(allow) do
            if not M.KNOWN_TOOLS[n] then
                return nil, "unknown tool: " .. tostring(n)
            end
        end
        out.tools = allow
    end
    -- cwd containment now (fail cheap, before spawning anything).
    local tools = toolset()
    local cfg = ctx.cfg
    if tools and cfg then
        local abs = tools._resolve(out.cwd, cfg)
        if not tools._within(abs, cfg) then
            return nil, "subagent cwd outside workspace requires confirmation"
        end
        out.cwd = abs
    end
    return out
end

-- Validate the whole call: exactly one of task / tasks[]. Returns the item
-- list (each still unvalidated — run validate_item per item) or nil, err.
function M.normalize_call(args)
    if type(args) ~= "table" then
        return nil, "subagent requires task or tasks"
    end
    local has_task = is_nonempty_str(args.task)
    local has_tasks = type(args.tasks) == "table"
    if has_task == has_tasks then
        return nil, "subagent requires exactly one of task / tasks"
    end
    if has_task then return { args } end
    if #args.tasks == 0 then
        return nil, "subagent tasks must not be empty"
    end
    return args.tasks
end

-- Build the shell command for one validated item. Returns cmd, outfile.
-- The task rides argv (print_prompt) unless it starts with `-`, when it
-- goes through a printf pipe instead (parse_args would eat a leading dash
-- as a flag). Stdout+stderr land in a unique outfile, like tools.run.
function M.build_command(item, ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    -- Reserve the outfile before the shell redirects into it: `>` follows a
    -- symlink, so a pre-guessed name in world-writable /tmp would let another
    -- process own (and read) the child's output. os.tmpname() with
    -- LUA_USE_POSIX is mkstemp — created exclusively, 0600, unguessable.
    local outfile = os.tmpname()
    local binary = ctx.binary
    if not is_nonempty_str(binary) then
        binary = os.getenv("TETHER_BIN")
        if not is_nonempty_str(binary) then
            -- reuse the running binary: a PATH lookup can shadow `tether`
            -- with an unrelated program whose CLI rejects our flags.
            local th = host()
            if th and th.exepath then
                local ok, p = pcall(th.exepath)
                if ok and is_nonempty_str(p) then binary = p end
            end
        end
        if not is_nonempty_str(binary) then binary = "tether" end
    end
    -- flags first, `--print <task>` last: parse_args takes the prompt
    -- from the slot right after --print, so anything between them (like
    -- -w) would swallow the slot and drop the task onto a dead positional.
    local argv = { sq(binary), "-w", sq(item.cwd) }
    if is_nonempty_str(item.model) then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = sq(item.model)
    end
    if item.tools ~= nil then
        argv[#argv + 1] = "--tools"
        argv[#argv + 1] = sq(table.concat(item.tools, ","))
    end
    if ctx.cfg and ctx.cfg.debug then
        -- parent runs --debug: child stages join the shared debug log.
        argv[#argv + 1] = "--debug"
    end
    argv[#argv + 1] = "--print"
    local depth = tonumber(ctx.depth) or 0
    if depth < 0 then depth = 0 end
    local env = string.format("TETHER_SUBAGENT_DEPTH=%d TETHER_WORKSPACE=%s",
        depth + 1, sq(item.cwd))
    -- prompt-cache v1: the child joins the parent's cache pool. The key and
    -- the parent system-blocks hash ride the same env channel; the child
    -- (cache.resolve_key) reuses the key when its prompt matches and
    -- derives one when it diverged. Absent key = nothing to inherit.
    env = env .. cache_inherit_env(ctx)
    -- the child continues this journal (fresh or sequel): the flag rides
    -- after the prompt slot so parse_args keeps --print glued to the task.
    local function with_resume()
        if is_nonempty_str(item.sid) then
            argv[#argv + 1] = "--resume"
            argv[#argv + 1] = sq(item.sid)
        end
    end
    local cmd
    if item.task:match("^%-") then
        with_resume()
        cmd = string.format("cd %s && %s printf '%%s' %s | %s > %s 2>&1",
            sq(item.cwd), env, sq(item.task),
            table.concat(argv, " "), sq(outfile))
    else
        argv[#argv + 1] = sq(item.task)
        with_resume()
        -- stdin off the terminal: a bg-group child sharing the parent's
        -- tty stops at SIGTTOU in init_termios (State T, zero output).
        -- With /dev/null isatty is false and no read can block. The pipe
        -- branch above keeps its stdin pipe by design.
        cmd = string.format("cd %s && %s %s > %s 2>&1 < /dev/null",
            sq(item.cwd), env, table.concat(argv, " "), sq(outfile))
    end
    return cmd, outfile
end

-- Spawn one validated item. Returns a pending task record or nil, err.
-- The record owns the outfile until wait_task consumes it. The child
-- journal is minted here (sequel reuses item.resume): an empty journal
-- never surfaces in latest-session listings, so orphan mints are cheap.
function M.spawn_task(item, ctx)
    local th = host()
    if not th or not th.exec_bg_start then
        return nil, "no background spawn support"
    end
    if not is_nonempty_str(item.sid) then
        if is_nonempty_str(item.resume) then
            item.sid = item.resume
        else
            local sm = rawget(_G, "session")
            if sm and sm.new_session then
                local ok, sid = pcall(sm.new_session, item.cwd, item.model)
                if ok and is_nonempty_str(sid) then item.sid = sid end
            end
        end
    end
    local cmd, outfile = M.build_command(item, ctx)
    local h, err = th.exec_bg_start(cmd)
    if not h then
        return nil, err or "spawn failed"
    end
    return { handle = h, outfile = outfile, item = item, sid = item.sid,
             started_ms = now_ms(), done = false }, nil
end

local function read_outfile(path)
    local f = io.open(path, "r")
    local output = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(path)
    return output or ""
end

-- Consume a spawned task into a run-shaped result: free the handle,
-- read+remove the outfile (unless output is given), stamp elapsed/model.
-- A non-zero exit with empty output becomes an error naming the exit.
local function consume(pending, status, exit_code, output)
    local th = host()
    if th and th.exec_bg_free and pending.handle then
        pcall(th.exec_bg_free, pending.handle)
        pending.handle = nil
    end
    local body = output
    if body == nil then body = read_outfile(pending.outfile) end
    local res = { status = status, exit_code = exit_code, output = body or "",
                  elapsed_ms = now_ms() - pending.started_ms,
                  model = pending.item.model, session_id = pending.sid }
    if res.status == "ok" and res.exit_code ~= 0 and res.output == "" then
        res.status = "error"
        res.output = string.format("subagent exited %d with no output", res.exit_code)
    end
    return res
end

-- One non-blocking step for a spawned task: result when finished
-- (done/timeout), nil while still running. Kills on timeout.
function M.poll_task(pending, timeout_s)
    local th = host()
    if not th or not th.exec_bg_poll then
        return consume(pending, "error", 127, "no background spawn support")
    end
    local st, code = th.exec_bg_poll(pending.handle, 0)
    if st == "done" then
        return consume(pending, "ok", code, nil)
    elseif st ~= "running" then
        return consume(pending, "error", 127, tostring(code or "spawn failed"))
    end
    if now_ms() >= pending.started_ms + timeout_s * 1000 then
        if th.exec_bg_kill then pcall(th.exec_bg_kill, pending.handle) end
        return consume(pending, "error", 127, string.format(
            "subagent timeout after %d seconds", timeout_s))
    end
    return nil
end

-- Wait one spawned task to completion (blocking poll loop): timeout kills
-- the group, parent abort cancels. Frees the handle and consumes the
-- outfile either way. Returns a run-shaped result table.
function M.wait_task(pending, timeout_s)
    local th = host()
    if not th or not th.exec_bg_poll then
        return consume(pending, "error", 127, "no background spawn support")
    end
    while true do
        local res = M.poll_task(pending, timeout_s)
        if res then return res end
        if th.abort_requested then
            local ok, ab = pcall(th.abort_requested)
            if ok and ab then
                if th.exec_bg_kill then pcall(th.exec_bg_kill, pending.handle) end
                return consume(pending, "error", 127, "subagent cancelled")
            end
        end
        -- pace the spin: one short blocking poll on our own handle
        th.exec_bg_poll(pending.handle, 20)
    end
end

-- Run one validated item to completion. Returns a run-shaped result table.
function M.run_single(item, ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    local pending, err = M.spawn_task(item, ctx)
    if not pending then
        return { status = "error", exit_code = 127,
                 output = err or "spawn failed",
                 elapsed_ms = 0, model = item.model }
    end
    return M.wait_task(pending, item.timeout or 600)
end

-- Run validated items with at most max_parallel concurrent children
-- (ctx.max_parallel, floor 1); excess tasks queue in order. Results combine
-- in items order regardless of finish order. A parent abort cancels
-- everything unfinished: running children are killed, queued tasks never
-- spawn, all report cancellation. Returns an array of run-shaped results.
function M.run_batch(items, ctx)
    ctx = (type(ctx) == "table") and ctx or {}
    local max_par = math.floor(tonumber(ctx.max_parallel) or 0)
    if max_par < 1 then max_par = 1 end
    local th = host()
    local results = {}
    local queue = {}
    for i, it in ipairs(items) do queue[#queue + 1] = { idx = i, item = it } end
    local running = {}
    local function aborted()
        if th and th.abort_requested then
            local ok, ab = pcall(th.abort_requested)
            return ok and ab or false
        end
        return false
    end
    while #queue > 0 or #running > 0 do
        if aborted() then
            for _, r in ipairs(running) do
                if th and th.exec_bg_kill then
                    pcall(th.exec_bg_kill, r.pending.handle)
                end
                results[r.idx] = consume(r.pending, "error", 127,
                    "subagent cancelled")
            end
            running = {}
            for _, job in ipairs(queue) do
                results[job.idx] = { status = "error", exit_code = 127,
                    output = "subagent cancelled", elapsed_ms = 0,
                    model = job.item.model }
            end
            queue = {}
            break
        end
        while #queue > 0 and #running < max_par do
            local job = table.remove(queue, 1)
            local pending, err = M.spawn_task(job.item, ctx)
            if not pending then
                results[job.idx] = { status = "error", exit_code = 127,
                    output = err or "spawn failed", elapsed_ms = 0,
                    model = job.item.model }
            else
                running[#running + 1] =
                    { pending = pending, idx = job.idx, item = job.item }
            end
        end
        if #running == 0 then break end
        local i = 1
        local progressed = false
        while i <= #running do
            local r = running[i]
            local res = M.poll_task(r.pending, r.item.timeout or 600)
            if res then
                results[r.idx] = res
                table.remove(running, i)
                progressed = true
            else
                i = i + 1
            end
        end
        if not progressed and #running > 0 and th and th.exec_bg_poll then
            -- pace the spin; any completion lands on the next round
            th.exec_bg_poll(running[1].pending.handle, 20)
        end
    end
    return results
end

-- Entry for agent dispatch: validate everything first (fail cheap — nothing
-- spawns on bad input), then run single or batch. Top-level model/cwd/
-- tools/timeout act as defaults for batch items (per-field item wins).
-- Shared validation prologue for the blocking and background entries:
-- returns items, ctx, is_batch or nil, err.
local function prepare_call(args, cfg)
    cfg = (type(cfg) == "table") and cfg or {}
    local raws, err = M.normalize_call(args)
    if not raws then return nil, err end
    local subc = cfg.subagents or {}
    local is_batch = type(args.tasks) == "table"
    local call_defs = {}
    if is_batch then
        call_defs = { model = args.model, cwd = args.cwd,
                      tools = args.tools, timeout = args.timeout }
    end
    local ctx = {
        cfg = cfg,
        workspace = nil,
        model = is_nonempty_str(cfg.model) and cfg.model or nil,
        timeout_default = tonumber(subc.timeout) or 600,
        max_parallel = tonumber(subc.max_parallel) or 4,
        depth = tonumber(cfg._subagent_depth) or 0,
    }
    do
        local tools = toolset()
        if tools and tools._workspace then
            local ok, ws = pcall(tools._workspace, cfg)
            if ok and is_nonempty_str(ws) then ctx.workspace = ws end
        end
        if not is_nonempty_str(ctx.workspace) then
            ctx.workspace = cfg.workspace
        end
    end
    local items = {}
    for _, raw in ipairs(raws) do
        local item, verr = M.validate_item(raw, call_defs, ctx)
        if not item then return nil, verr end
        items[#items + 1] = item
    end
    return items, ctx, is_batch
end

-- Validation failures return nil, err; a failed single task returns its
-- text as err; a batch always returns one combined table (exit 1 when any
-- task failed) so partial results survive.
function M.run_call(args, cfg)
    local items, ctx_or_err, is_batch = prepare_call(args, cfg)
    if not items then return nil, ctx_or_err end
    local ctx = ctx_or_err
    if not is_batch then
        local res = M.run_single(items[1], ctx)
        if res.status ~= "ok" then return nil, res.output end
        -- the session trailer lets the model continue this child via the
        -- resume param instead of starting over.
        local output = res.output
        if is_nonempty_str(res.session_id) then
            output = output .. "\n[subagent session " .. res.session_id .. "]"
        end
        return { output = output, exit_code = res.exit_code,
                 elapsed_ms = res.elapsed_ms, model = res.model, tasks = 1,
                 session_id = res.session_id }
    end
    local results = M.run_batch(items, ctx)
    return M.combine_batch(results, #results)
end

-- Combine per-task run-shaped results (indexed 1..n) into the single
-- batch table the dispatch records: outputs in task order regardless of
-- finish order, exit 1 when any task failed. Shared by the blocking
-- run_call and the background pickup path.
function M.combine_batch(results, n)
    results = (type(results) == "table") and results or {}
    n = tonumber(n) or #results
    local parts, exit_code, elapsed = {}, 0, 0
    for i = 1, n do
        local r = results[i] or { status = "error", exit_code = 127,
            output = "missing result", elapsed_ms = 0 }
        elapsed = elapsed + (r.elapsed_ms or 0)
        if r.status ~= "ok" then exit_code = 1 end
        parts[#parts + 1] = string.format(
            "[subagent task %d/%d model=%s exit=%s session=%s]\n%s",
            i, n, tostring(r.model or "?"),
            (r.status == "ok") and tostring(r.exit_code) or "error",
            tostring(r.session_id or "?"), r.output or "")
    end
    return { output = table.concat(parts, "\n"), exit_code = exit_code,
             elapsed_ms = elapsed, model = nil, tasks = n }
end

-- Background registry: children that outlive the spawning turn.
-- _running maps id -> {pending, item, timeout, idx}; _queue is a FIFO of
-- {item, timeout, max_par, idx} waiting for a free slot.
M._running = {}
M._queue = {}
M._seq = 0

function M.running_count()
    local n = 0
    for _ in pairs(M._running) do n = n + 1 end
    return n
end

local function register(pending, item, timeout, idx)
    M._seq = M._seq + 1
    local id = string.format("sg%04d", M._seq)
    M._running[id] = { pending = pending, item = item,
                       timeout = timeout, idx = idx }
    return id
end

-- Background entry for interactive dispatch: same validation as run_call,
-- then spawn (up to max_parallel, rest queued) and return immediately
-- without any wait loop. Returns a pending record
-- {pending=true, jobs={{id, idx}}, done={[idx]=err_result}, tasks=N}
-- or nil, err when validation fails or a single spawn fails.
function M.run_call_bg(args, cfg)
    local items, ctx_or_err, _ = prepare_call(args, cfg)
    if not items then return nil, ctx_or_err end
    local ctx = ctx_or_err
    local max_par = math.floor(tonumber(ctx.max_parallel) or 0)
    if max_par < 1 then max_par = 1 end
    M._batch_seq = (M._batch_seq or 0) + 1
    local batch = "b" .. tostring(M._batch_seq)
    local rec = { pending = true, jobs = {}, done = {}, tasks = #items,
                  items = items, batch = batch,
                  model = (#items == 1) and items[1].model or nil }
    local slots = max_par
    for i, it in ipairs(items) do
        local timeout = it.timeout or 600
        if slots > 0 then
            local pending, serr = M.spawn_task(it, ctx)
            if not pending then
                if #items == 1 then return nil, serr or "spawn failed" end
                rec.done[i] = { status = "error", exit_code = 127,
                    output = serr or "spawn failed", elapsed_ms = 0,
                    model = it.model }
            else
                rec.jobs[#rec.jobs + 1] =
                    { id = register(pending, it, timeout, i), idx = i }
                slots = slots - 1
            end
        else
            M._queue[#M._queue + 1] =
                { item = it, timeout = timeout, max_par = max_par,
                  idx = i, ctx = ctx, batch = batch }
        end
    end
    return rec
end

-- Live excerpts of still-running children for the transcript progress
-- tail: {id, tail} per entry, tail capped to the newest bytes. Reads the
-- outfile without consuming it; missing/unreadable files are skipped.
local TAIL_BYTES = 2048
function M.running_tails()
    local out = {}
    for id, r in pairs(M._running) do
        local f = r.pending and io.open(r.pending.outfile, "r")
        if f then
            local data = f:read("*a") or ""
            f:close()
            if #data > TAIL_BYTES then data = data:sub(-TAIL_BYTES) end
            out[#out + 1] = { id = id, tail = data }
        end
    end
    return out
end

-- One tick step over the background registry: collect completions and
-- refill freed slots from the queue head (in order). Never blocks.
-- Returns {completed={{id, idx, result, immediate}}, spawned={{id, idx,
-- item}}} — spawned refills need their own transcript rows, so callers
-- must announce them. Immediate marks a refill spawn failure surfaced
-- without a child ever running.
function M.poll_running()
    local completed, spawned = {}, {}
    for id, r in pairs(M._running) do
        local res = M.poll_task(r.pending, r.timeout)
        if res then
            M._running[id] = nil
            completed[#completed + 1] =
                { id = id, idx = r.idx, result = res, immediate = false }
        end
    end
    while #M._queue > 0 do
        local head = M._queue[1]
        if M.running_count() >= head.max_par then break end
        table.remove(M._queue, 1)
        local pending, serr = M.spawn_task(head.item, head.ctx)
        if not pending then
            completed[#completed + 1] = { id = nil, idx = head.idx,
                batch = head.batch,
                result = { status = "error", exit_code = 127,
                    output = serr or "spawn failed", elapsed_ms = 0,
                    model = head.item.model },
                immediate = true }
        else
            local id = register(pending, head.item, head.timeout, head.idx)
            spawned[#spawned + 1] = { id = id, idx = head.idx,
                                      item = head.item, batch = head.batch }
        end
    end
    return { completed = completed, spawned = spawned }
end

-- Kill everything background: running children die, queued items never
-- spawn. Returns an array of {id, idx, result} for journaling.
-- The registry and queue are empty afterwards.
function M.cancel_all(reason)
    local out = {}
    for id, r in pairs(M._running) do
        local th = host()
        if th and th.exec_bg_kill and r.pending.handle then
            pcall(th.exec_bg_kill, r.pending.handle)
        end
        out[#out + 1] = { id = id, idx = r.idx,
            result = consume(r.pending, "error", 127, reason or "cancelled") }
    end
    for _, q in ipairs(M._queue) do
        out[#out + 1] = { id = nil, idx = q.idx,
            result = { status = "error", exit_code = 127,
                output = reason or "cancelled", elapsed_ms = 0,
                model = q.item.model } }
    end
    M._running = {}
    M._queue = {}
    return out
end

return M
