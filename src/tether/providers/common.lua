-- tether providers/common — shared pure helpers (JSON string escape/unescape).
-- No globals, no I/O: safe to load in any order, in tests and in the binary.
local M = {}

function M.jesc(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return s
end

-- Single-pass JSON string unescape (M7/D2b). Sequential gsub chains corrupt
-- input like `\\n` (escaped backslash + n): the first pass turns it into `\n`,
-- the next pass turns THAT into a newline. A single left-to-right scan with a
-- replacement function never re-processes its own output.
function M.json_unescape(s)
    local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                  ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" and i < #s then
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code then
                    out[#out + 1] = utf8 and utf8.char and utf8.char(code) or ""
                    i = i + 6
                else
                    out[#out + 1] = n
                    i = i + 2
                end
            else
                out[#out + 1] = map[n] or n
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Minimal JSON encoder for tables (tool schemas, request envelopes).
-- Objects vs arrays: a table with only 1..n integer keys encodes as an array.
function M.json_encode(v)
    local t = type(v)
    if t == "string" then
        return '"' .. M.jesc(v) .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif v == nil then
        return "null"
    elseif t == "table" then
        -- _array marker forces array encoding (for ["x"] + {_array=true} mixes)
        if v._array == true then
            local items = {}
            for i = 1, #v do items[#items + 1] = M.json_encode(v[i]) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local n = #v
        local is_arr = n > 0
        if is_arr then
            for k in pairs(v) do
                if type(k) ~= "number" then is_arr = false break end
            end
        end
        if is_arr then
            local items = {}
            for i = 1, n do items[#items + 1] = M.json_encode(v[i]) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local items = {}
        for k, val in pairs(v) do
            if k ~= "_array" and val ~= nil then
                items[#items + 1] = '"' .. M.jesc(tostring(k)) .. '":' .. M.json_encode(val)
            end
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

-- Recursive-descent JSON parser (ADR: no load()). Shared by agent.lua and
-- session.lua after fix-audit-findings 3.9 — previously each module carried
-- its own copy. An unterminated string returns what was read instead of
-- looping (truncated tool_call arguments are common).
function M.json_decode(s)
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
                if pos > #s then break end
                local ch = s:sub(pos,pos)
                if ch == '"' then pos = pos + 1; return table.concat(buf)
                elseif ch == '\\' then
                    local esc = s:sub(pos+1,pos+1)
                    local m = {["n"]="\n",["t"]="\t",["r"]="\r",["b"]="\b",["f"]="\f",['"']='"',['\\']='\\',["/"]="/"}
                    if esc == "u" then
                        local hex = s:sub(pos+2,pos+5)
                        local code = tonumber(hex, 16) or 0
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

-- Canonical static tool schema (OpenAI function format). Anthropic/Gemini
-- adapters convert FROM this shape; agent.execute_tool names must match.
function M.tools_schema()
    local str = { type = "string" }
    local num = { type = "number" }
    local bool = { type = "boolean" }
    return {
        { name = "read", description = "Read file contents",
          parameters = { type = "object",
            properties = { path = str, offset = num, limit = num },
            required = { "path", _array = true } } },
        { name = "list", description = "List directory entries",
          parameters = { type = "object", properties = { path = str } } },
        { name = "glob", description = "Find files by glob pattern",
          parameters = { type = "object",
            properties = { pattern = str, path = str },
            required = { "pattern", _array = true } } },
        { name = "grep", description = "Search text in files",
          parameters = { type = "object",
            properties = { pattern = str, path = str, glob = str,
                           ignore_case = bool, max_results = num },
            required = { "pattern", _array = true } } },
        { name = "write", description = "Create or overwrite a file",
          parameters = { type = "object",
            properties = { path = str, content = str },
            required = { "path", "content", _array = true } } },
        { name = "patch", description = "Apply a unified diff, strictly",
          parameters = { type = "object",
            properties = { patch = str },
            required = { "patch", _array = true } } },
        { name = "run", description = "Run a shell command via /bin/sh -c",
          parameters = { type = "object",
            properties = { command = str, cwd = str, timeout = num },
            required = { "command", _array = true } } },
    }
end

-- Percent-encode for OAuth authorize URLs and form bodies (RFC 3986).
function M.url_encode(s)
    return (tostring(s):gsub("[^%w%.%-_~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function M.url_decode(s)
    return (tostring(s):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Standard OAuth authorization-code exchange body shared by provider adapters
-- (design.md: login_flow / token_exchange hooks keep OAuth out of auth.lua).
-- `post_json(url, body_table)` must return (body_string) or (nil, err).
function M.oauth_token_exchange(post_json, flow, code, now)
    if type(post_json) ~= "function" then return nil end
    if type(flow) ~= "table" or type(code) ~= "string" or code == "" then
        return nil
    end
    if type(flow.token_url) ~= "string" or flow.token_url == "" then return nil end
    local body = {
        grant_type = "authorization_code",
        code = code,
        redirect_uri = flow.redirect_uri or "",
        client_id = flow.client_id or "",
    }
    if type(flow.client_secret) == "string" and flow.client_secret ~= "" then
        body.client_secret = flow.client_secret
    end
    local ok, res = pcall(post_json, flow.token_url, body)
    if not ok or type(res) ~= "string" or res == "" then return nil end
    local pok, parsed = pcall(M.json_decode, res)
    if not pok or type(parsed) ~= "table" then return nil end
    local access = parsed.access_token
    if type(access) ~= "string" or access == "" then return nil end
    local entry = {
        kind = "oauth",
        access_token = access,
        refresh_url = flow.token_url,
        provider = flow.provider,
    }
    if type(parsed.refresh_token) == "string" and parsed.refresh_token ~= "" then
        entry.refresh_token = parsed.refresh_token
    end
    if parsed.expires_in ~= nil then
        entry.expires_at = (tonumber(now) or os.time())
            + (tonumber(parsed.expires_in) or 0)
    end
    if type(parsed.token_type) == "string" then
        entry.token_type = parsed.token_type
    end
    if type(parsed.scope) == "string" then
        entry.scope = parsed.scope
    end
    return entry
end

-- Build the authorize URL from a flow table (query-safe encoding).
function M.oauth_authorize_url(base, flow)
    if type(base) ~= "string" or base == "" then return nil end
    local sep = base:find("?", 1, true) and "&" or "?"
    local url = base .. sep
        .. "client_id=" .. M.url_encode(flow.client_id or "")
        .. "&redirect_uri=" .. M.url_encode(flow.redirect_uri or "")
        .. "&response_type=code"
    if type(flow.scope) == "string" and flow.scope ~= "" then
        url = url .. "&scope=" .. M.url_encode(flow.scope)
    end
    return url
end

return M
