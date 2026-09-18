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

return M
