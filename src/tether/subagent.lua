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
    local outfile = ("/tmp/tether_subagent_%d_%d.out"):format(
        os.time(), math.random(100000, 999999))
    local binary = ctx.binary
    if not is_nonempty_str(binary) then
        binary = os.getenv("TETHER_BIN")
        if not is_nonempty_str(binary) then binary = "tether" end
    end
    local argv = { sq(binary), "--print", "-w", sq(item.cwd) }
    if is_nonempty_str(item.model) then
        argv[#argv + 1] = "--model"
        argv[#argv + 1] = sq(item.model)
    end
    if item.tools ~= nil then
        argv[#argv + 1] = "--tools"
        argv[#argv + 1] = sq(table.concat(item.tools, ","))
    end
    local depth = tonumber(ctx.depth) or 0
    if depth < 0 then depth = 0 end
    local env = string.format("TETHER_SUBAGENT_DEPTH=%d TETHER_WORKSPACE=%s",
        depth + 1, sq(item.cwd))
    local cmd
    if item.task:match("^%-") then
        cmd = string.format("cd %s && %s printf '%%s' %s | %s > %s 2>&1",
            sq(item.cwd), env, sq(item.task),
            table.concat(argv, " "), sq(outfile))
    else
        argv[#argv + 1] = sq(item.task)
        cmd = string.format("cd %s && %s %s > %s 2>&1",
            sq(item.cwd), env, table.concat(argv, " "), sq(outfile))
    end
    return cmd, outfile
end

-- Spawn one validated item. Returns a pending task record or nil, err.
-- The record owns the outfile until wait_task consumes it.
function M.spawn_task(item, ctx)
    local th = host()
    if not th or not th.exec_bg_start then
        return nil, "no background spawn support"
    end
    local cmd, outfile = M.build_command(item, ctx)
    local h, err = th.exec_bg_start(cmd)
    if not h then
        return nil, err or "spawn failed"
    end
    return { handle = h, outfile = outfile, item = item,
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
                  model = pending.item.model }
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
-- Validation failures return nil, err; a failed single task returns its
-- text as err; a batch always returns one combined table (exit 1 when any
-- task failed) so partial results survive.
function M.run_call(args, cfg)
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
    if not is_batch then
        local res = M.run_single(items[1], ctx)
        if res.status ~= "ok" then return nil, res.output end
        return { output = res.output, exit_code = res.exit_code,
                 elapsed_ms = res.elapsed_ms, model = res.model, tasks = 1 }
    end
    local results = M.run_batch(items, ctx)
    local parts, exit_code, elapsed = {}, 0, 0
    for i, r in ipairs(results) do
        elapsed = elapsed + (r.elapsed_ms or 0)
        if r.status ~= "ok" then exit_code = 1 end
        parts[#parts + 1] = string.format(
            "[subagent task %d/%d model=%s exit=%s]\n%s",
            i, #results, tostring(r.model or "?"),
            (r.status == "ok") and tostring(r.exit_code) or "error",
            r.output or "")
    end
    return { output = table.concat(parts, "\n"), exit_code = exit_code,
             elapsed_ms = elapsed, model = nil, tasks = #results }
end

return M
