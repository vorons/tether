-- tether M5: session — JSONL journal, auto-save, resume by workspace
local M = {}

-- fix-audit-findings 3.9: shared JSON helpers from providers/common.lua.
-- The C host loads `provider_common` before this module; loadfile keeps dev
-- runs and tests working.
local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "session: cannot load provider_common")
local json_decode = common.json_decode
-- Encoding used to live here as a private copy. It escaped only
-- \ " \n \r \t and rendered a numeric table key as `[3]`, so a journal line
-- could hold a raw control byte or a Lua-shaped (non-JSON) key and the line
-- then failed to parse on resume. common.json_encode is the same encoder the
-- request bodies use: every C0 control escaped, keys always quoted.
local json_encode = common.json_encode

-- HOME is not guaranteed (a stripped environment, `env -i`, a container
-- entrypoint): the module used to crash at load while concatenating nil.
-- Falling back to the cwd keeps journaling working in a shell without HOME
-- instead of taking down every command with it.
local ROOT = (os.getenv("HOME") or tether.getcwd()) .. "/.tether"
local SESSION_DIR = ROOT .. "/sessions"
local HISTORY_FILE = ROOT .. "/history.jsonl"

-- M7/T1 test seam: tests set session._session_dir to a temp path.
local function session_dir()
    return M._session_dir or SESSION_DIR
end

local function ensure_dir()
    -- 1.3: in-process mkdir -p via the C host (no shell invocation).
    tether.mkdirp(session_dir())
end

local function uuid()
    local t = {}
    for i = 1, 32 do
        t[i] = string.format("%x", math.random(0, 15))
    end
    return table.concat(t, "")
end

local function now_iso()
    local now = os.date("*t")
    return string.format("%04d-%02d-%02dT%02d:%02d:%02d",
        now.year, now.month, now.day, now.hour, now.min, now.sec)
end

local function session_path(id)
    return session_dir() .. "/" .. id .. ".jsonl"
end

local function append_event(id, event)
    ensure_dir()
    local path = session_path(id)
    local f = io.open(path, "a")
    if not f then return nil, "cannot open session" end
    f:write(json_encode(event) .. "\n")
    f:close()
    return true
end

local function read_events(id)
    local path = session_path(id)
    local f = io.open(path, "r")
    if not f then return {} end
    local events = {}
    for line in f:lines() do
        local obj = json_decode(line)
        if obj then events[#events + 1] = obj end
    end
    f:close()
    return events
end

-- Picker probe: what the session list needs from a journal is the head
-- (session_start ts/workspace, first user message) and its last line
-- (session_end's meta.workspace, which wins over the start one because a
-- resumed run ends under the workspace it exited in). Decoding every journal
-- end to end made opening the picker O(all sessions x their size) — a single
-- long session carries megabytes of tool output, and the JSON decode dominates.
-- So read a bounded head and a bounded tail window, and only fall back to the
-- full read for the one case the window cannot answer.
local HEAD_BYTES = 64 * 1024
local TAIL_BYTES = 8 * 1024

-- Whole lines from the start of the file; a trailing partial line is dropped
-- (it cannot decode) and an undecodable line is skipped, as read_events does.
local function head_events(path)
    local events = {}
    local f = io.open(path, "r")
    if not f then return events end
    local chunk = f:read(HEAD_BYTES) or ""
    f:close()
    chunk = chunk:match("^(.*)\n") or ""
    for line in chunk:gmatch("[^\n]+") do
        local obj = json_decode(line)
        if obj then events[#events + 1] = obj end
    end
    return events
end

-- The last whole line's event, reading at most TAIL_BYTES from the end.
local function tail_event(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local size = f:seek("end") or 0
    if size == 0 then f:close(); return nil end
    local skip = size > TAIL_BYTES and (size - TAIL_BYTES) or 0
    f:seek("set", skip)
    local chunk = f:read("a") or ""
    f:close()
    -- the first fragment after a mid-file seek is a partial line
    if skip > 0 then chunk = chunk:sub((chunk:find("\n", 1, true) or 0) + 1) end
    local last
    for line in chunk:gmatch("[^\n]+") do
        local obj = json_decode(line)
        if obj then last = obj end
    end
    return last
end

local function list_session_files(workspace)
    ensure_dir()
    local files = {}
    -- 1.6: in-process listing — enumerate *.jsonl in the session directory and
    -- order by mtime (newest first) via tether.readdir + tether.stat; there is
    -- no `find`/`ls -1t`/`head` pipeline anymore.
    local names = tether.readdir(session_dir())
    if not names then return files end
    local candidates = {}
    for _, name in ipairs(names) do
        local id = name:match("^(.-)%.jsonl$")
        if id then
            local st = tether.stat(session_dir() .. "/" .. name)
            if st and not st.is_dir then
                candidates[#candidates + 1] = { id = id, mtime = st.mtime }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.mtime == b.mtime then return a.id < b.id end -- deterministic ties
        return a.mtime > b.mtime
    end)
    -- the previous pipeline was piped through `head -100`
    for i = #candidates, 101, -1 do candidates[i] = nil end
    local rank = 0
    for _, cand in ipairs(candidates) do
        rank = rank + 1
        local id = cand.id
        local path = session_path(id)
        local head = head_events(path)
        local first = head[1]
        -- meta.workspace: session_start, overridden by the last event's
        local ws = nil
        if first and first.meta and first.meta.workspace then ws = first.meta.workspace end
        local last = tail_event(path)
        if last and last.meta and last.meta.workspace then ws = last.meta.workspace end
        if ws == workspace then
            local first_line, has_message = "", false
            for _, ev in ipairs(head) do
                if ev.type == "message" then
                    has_message = true
                    if first_line == "" and ev.role == "user" and ev.content then
                        first_line = ev.content
                        break
                    end
                end
            end
            -- ponytail: ceiling — a session whose first message sits past the
            -- head window (tens of KiB of tool traffic before it) still costs a
            -- full read here, which is the pre-probe behavior. Upgrade path: an
            -- index line appended per turn instead of probing the journal.
            if not has_message then
                for _, ev in ipairs(read_events(id)) do
                    if ev.type == "message" then
                        has_message = true
                        if first_line == "" and ev.role == "user" and ev.content then
                            first_line = ev.content
                        end
                    end
                end
            end
            -- resuming an empty session restores nothing: a run that never
            -- produced a message only buries the real latest session.
            if has_message then
                files[#files + 1] = {
                    id = id,
                    mtime = rank,
                    first_line = first_line,
                    ts = first and first.ts or "",
                }
            end
        end
    end
    return files
end

function M.new_session(workspace, model)
    local id = uuid()
    local path = session_path(id)
    ensure_dir()
    local f = io.open(path, "w")
    if not f then return nil end
    local event = {
        ts = now_iso(),
        type = "session_start",
        meta = { workspace = workspace, model = model },
    }
    f:write(json_encode(event) .. "\n")
    f:close()
    return id
end

function M.append(id, event)
    return append_event(id, event)
end

function M.session_files(workspace)
    ensure_dir()
    return list_session_files(workspace)
end

function M.read(id)
    return read_events(id)
end

function M.latest(workspace)
    local files = list_session_files(workspace)
    if #files == 0 then return nil end
    return files[1].id, files[1].ts, files[1].first_line
end

function M.resume(id)
    local events = read_events(id)
    if #events == 0 then return nil end
    local messages = {}
    -- tool_call events carry the parsed args the transcript's arg label
    -- needs (the result event only keeps summary/body for the model)
    local call_args = {}
    for _, ev in ipairs(events) do
        if ev.type == "message" then
            if ev.role == "assistant" and ev.tool_calls then
                messages[#messages + 1] = { role = "assistant",
                    tool_calls = ev.tool_calls, content = ev.content }
            else
                messages[#messages + 1] = { role = ev.role, content = ev.content }
            end
        elseif ev.type == "tool_call" then
            if ev.tool_call_id ~= nil then call_args[ev.tool_call_id] = ev.args end
        elseif ev.type == "reasoning" then
            -- display-only: commands.resume skips it for the agent history,
            -- transcript.seed renders the think block from it
            if type(ev.text) == "string" and ev.text:match("%S") then
                messages[#messages + 1] = { role = "thinking", content = ev.text }
            end
        elseif ev.type == "tool_result" then
            local res = (type(ev.result) == "table" and ev.result) or {}
            messages[#messages + 1] = {
                role = "tool",
                tool_call_id = ev.tool_call_id,
                name = ev.name,
                args = call_args[ev.tool_call_id],
                summary = res.summary,
                error = res.error,
                -- full body first (model context), then error, then summary;
                -- old journals carry summary only and degrade gracefully.
                content = res.body or res.error or res.summary
                    or ev.content or "",
            }
        end
    end
    return messages
end

function M.add_history(text, workspace)
    ensure_dir()
    local event = {
        ts = now_iso(),
        workspace = workspace,
        text = text,
    }
    local f = io.open(HISTORY_FILE, "a")
    if f then
        f:write(json_encode(event) .. "\n")
        f:close()
    end
end

return M
