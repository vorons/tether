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

local function json_escape(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

local function json_encode(obj)
    if type(obj) == "string" then
        return '"' .. json_escape(obj) .. '"'
    elseif type(obj) == "number" then
        return tostring(obj)
    elseif type(obj) == "boolean" then
        return obj and "true" or "false"
    elseif type(obj) == "nil" then
        return "null"
    elseif type(obj) == "table" then
        local is_array = (#obj > 0)
        local items = {}
        if is_array then
            for _, v in ipairs(obj) do
                items[#items + 1] = json_encode(v)
            end
            return "[" .. table.concat(items, ",") .. "]"
        end
        for k, v in pairs(obj) do
            local key = type(k) == "string" and '"' .. json_escape(k) .. '"' or ("[" .. tostring(k) .. "]")
            items[#items + 1] = key .. ":" .. json_encode(v)
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return tostring(obj)
end

local SESSION_DIR = os.getenv("HOME") .. "/.tether/sessions"
local HISTORY_FILE = os.getenv("HOME") .. "/.tether/history.jsonl"

-- M7/T1 test seam: tests set session._session_dir to a temp path.
local function session_dir()
    return M._session_dir or SESSION_DIR
end

local function ensure_dir()
    os.execute("mkdir -p " .. session_dir())
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

local function list_session_files(workspace)
    ensure_dir()
    local files = {}
    local function run(cmd)
        local ok, res = pcall(function()
            local f = io.popen(cmd)
            local r = f:read("*a")
            f:close()
            return r
        end)
        return ok and res or nil
    end
    -- 3.1: portable listing — GNU `find -printf` is Linux-only; `ls -1t`
    -- orders by mtime and exists on BSD/macOS too.
    local data = run("find " .. session_dir() .. " -name '*.jsonl' -type f -exec ls -1t {} + 2>/dev/null | head -100")
    if not data or data == "" then
        data = run("ls -1t " .. session_dir() .. "/*.jsonl 2>/dev/null | head -100")
    end
    if not data then return files end
    local rank = 0
    for fname in data:gmatch("[^\n]+") do
        if fname ~= "" and fname:match("%.jsonl$") then
            rank = rank + 1
            local id = fname:match("([^/]+)%.jsonl$")
            local events = read_events(id)
            -- meta.workspace: check session_start (first) and session_end (last)
            local ws = nil
            local first = events[1]
            if first and first.meta and first.meta.workspace then ws = first.meta.workspace end
            local last = events[#events]
            if last and last.meta and last.meta.workspace then ws = last.meta.workspace end
            if ws == workspace then
                local first_line = ""
                for _, ev in ipairs(events) do
                    if ev.type == "message" and ev.role == "user" and ev.content then
                        first_line = ev.content
                        break
                    end
                end
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
    for _, ev in ipairs(events) do
        if ev.type == "message" then
            if ev.role == "assistant" and ev.tool_calls then
                messages[#messages + 1] = { role = "assistant", tool_calls = ev.tool_calls }
            else
                messages[#messages + 1] = { role = ev.role, content = ev.content }
            end
        elseif ev.type == "tool_result" then
            messages[#messages + 1] = {
                role = "tool",
                tool_call_id = ev.tool_call_id,
                content = ev.result and ev.result.summary or (ev.content or ""),
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
