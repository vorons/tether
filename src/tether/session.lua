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

-- Hand-rolled recursive-descent JSON parser (no load; matches agent.lua's).
local function json_parse(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s and s:sub(pos,pos):match("[%s]") do pos = pos + 1 end
    end
    local function parse_value()
        skip_ws()
        local c = s:sub(pos,pos)
        if c == nil then return nil end
        if c == '"' then
            pos = pos + 1
            local buf = {}
            while true do
                local ch = s:sub(pos,pos)
                if ch == nil then break end
                if ch == '"' then pos = pos + 1; return table.concat(buf)
                elseif ch == '\\' then
                    local esc = s:sub(pos+1,pos+1)
                    local m = {["n"]="\n",["t"]="\t",["r"]="\r",["b"]="\b",["f"]="\f",['"']='"',['\\']='\\',["/"]="/"}
                    if esc == "u" then
                        local code = tonumber(s:sub(pos+2,pos+5)) or 0
                        pos = pos + 6
                        buf[#buf+1] = utf8 and utf8.char and utf8.char(code) or ""
                    else
                        buf[#buf+1] = m[esc] or ""
                        pos = pos + 2
                    end
                else
                    buf[#buf+1] = ch
                    pos = pos + 1
                end
            end
            return table.concat(buf)
        elseif c == "{" then
            pos = pos + 1
            local obj = {}
            skip_ws()
            if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
            while true do
                skip_ws()
                local key
                if s:sub(pos,pos) == '"' then
                    key = parse_value()
                else
                    local ks = s:match("[%w_%-]+", pos)
                    if not ks then break end
                    key = ks
                    pos = pos + #key
                end
                skip_ws()
                if s:sub(pos,pos) ~= ":" then break end
                pos = pos + 1
                obj[key] = parse_value()
                skip_ws()
                local nx = s:sub(pos,pos)
                if nx == "," then pos = pos + 1
                elseif nx == "}" then pos = pos + 1; break
                else break end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr+1] = parse_value()
                skip_ws()
                local nx = s:sub(pos,pos)
                if nx == "," then pos = pos + 1
                elseif nx == "]" then pos = pos + 1; break
                else break end
            end
            return arr
        elseif s:sub(pos, pos+3) == "true" then
            pos = pos + 4; return true
        elseif s:sub(pos, pos+4) == "false" then
            pos = pos + 5; return false
        elseif s:sub(pos, pos+3) == "null" then
            pos = pos + 4; return nil
        else
            local st, fin = s:find("%-?%d+%.?%d*[eE][%+%-]?%d+", pos)
            if not st then st, fin = s:find("%-?%d+%.?%d*", pos) end
            if st then
                local num = s:sub(st, fin)
                pos = fin + 1
                return tonumber(num)
            end
            return nil
        end
    end
    return parse_value()
end

local function read_events(id)
    local path = session_path(id)
    local f = io.open(path, "r")
    if not f then return {} end
    local events = {}
    for line in f:lines() do
        local obj = json_parse(line)
        if obj then events[#events + 1] = obj end
    end
    f:close()
    return events
end

local function list_session_files(workspace)
    ensure_dir()
    local files = {}
    local data
    local ok, res = pcall(function()
        local f = io.popen("find " .. session_dir() .. " -name '*.jsonl' -type f -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -100")
        local r = f:read("*a")
        f:close()
        return r
    end)
    if ok then data = res end
    if not data then return files end
    for line in data:gmatch("[^\n]+") do
        local mtime, fname = line:match("^(%S+)%s+(.+)")
        if fname and fname:match("%.jsonl$") then
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
                    mtime = mtime,
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
