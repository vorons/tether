-- tether M5: session — JSONL journal, auto-save, resume by workspace
local M = {}

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
    elseif type(obj) == "table" then
        local items = {}
        for k, v in pairs(obj) do
            local key = type(k) == "string" and '"' .. json_escape(k) .. '"' or tostring(k)
            items[#items + 1] = key .. ":" .. json_encode(v)
        end
        return "{" .. table.concat(items, ",") .. "}"
    elseif type(obj) == "nil" then
        return "null"
    end
    return tostring(obj)
end

local SESSION_DIR = os.getenv("HOME") .. "/.tether/sessions"
local HISTORY_FILE = os.getenv("HOME") .. "/.tether/history.jsonl"

local function ensure_dir()
    os.execute("mkdir -p " .. SESSION_DIR)
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
    return SESSION_DIR .. "/" .. id .. ".jsonl"
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

local function parse_json_str(s)
    local obj = {}
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*"([^"]*)"') do
        obj[key] = val
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%d+%.?%d*)') do
        obj[key] = tonumber(val)
    end
    for key, val in s:gmatch('"([^"]+)"[%s]*:[%s]*(%S+)') do
        val = val:gsub("[,%}]]$", "")
        if val == "true" then obj[key] = true elseif val == "false" then obj[key] = false end
    end
    return next(obj) and obj or nil
end

local function read_events(id)
    local path = session_path(id)
    local f = io.open(path, "r")
    if not f then return {} end
    local events = {}
    for line in f:lines() do
        local obj = parse_json_str(line)
        if obj then events[#events + 1] = obj end
    end
    f:close()
    return events
end

local function session_files(workspace)
    ensure_dir()
    local files = {}
    local ok, result = pcall(function()
        local f = io.popen("find " .. SESSION_DIR .. " -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -100")
        local r = f:read("*a")
        f:close()
        return r
    end)
    if not ok then return files end
    for line in result:gmatch("[^]+") do
        local mtime, fname = line:match("^(%S+)%s+(.+)")
        if fname and fname:match("%.jsonl$") then
            local id = fname:match("([^/]+)%.jsonl$")
            local events = read_events(id)
            local meta = events[#events] and events[#events].meta
            if meta and meta.workspace == workspace then
                files[#files + 1] = {
                    id = id,
                    mtime = mtime,
                    first_line = events[1] and events[1].content or "",
                    ts = events[1] and events[1].ts or "",
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

function M.read(id)
    return read_events(id)
end

function M.latest(workspace)
    local files = session_files(workspace)
    if #files == 0 then return nil end
    return files[1].id, files[1].ts, files[1].first_line
end

function M.resume(id)
    local events = read_events(id)
    if #events == 0 then return nil end
    local messages = {}
    for _, ev in ipairs(events) do
        if ev.type == "message" then
            messages[#messages + 1] = { role = ev.role, content = ev.content }
        elseif ev.type == "tool_call" then
            messages[#messages + 1] = {
                role = "assistant",
                tool_calls = ev.tool_calls,
            }
        elseif ev.type == "tool_result" then
            messages[#messages + 1] = {
                role = "tool_result",
                tool_call_id = ev.tool_call_id,
                content = ev.content,
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
