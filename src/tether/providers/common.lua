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

-- expand-provider-catalog: pure-Lua SHA-256 / HMAC-SHA-256 (Bedrock SigV4).
-- Lua 5.4 integers make this exact; bodies are kilobytes, speed is fine.
local SHA_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_words(msg)
    local len = #msg
    local bitlen_hi = math.floor(len * 8 / 2^32)
    local bitlen_lo = (len * 8) % 2^32
    msg = msg .. "\128"
    local pad = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep("\0", pad)
        .. string.char(
            math.floor(bitlen_hi / 2^24) % 256, math.floor(bitlen_hi / 2^16) % 256,
            math.floor(bitlen_hi / 2^8) % 256, bitlen_hi % 256,
            math.floor(bitlen_lo / 2^24) % 256, math.floor(bitlen_lo / 2^16) % 256,
            math.floor(bitlen_lo / 2^8) % 256, bitlen_lo % 256)
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local w = {}
    for off = 1, #msg, 64 do
        for i = 0, 15 do
            local b1, b2, b3, b4 = msg:byte(off + i * 4, off + i * 4 + 3)
            w[i + 1] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 16, 63 do
            local s0 = (w[i - 15 + 1] >> 7 | w[i - 15 + 1] << 25)
                ~ (w[i - 15 + 1] >> 18 | w[i - 15 + 1] << 14)
                ~ (w[i - 15 + 1] >> 3)
            local s1 = (w[i - 2 + 1] >> 17 | w[i - 2 + 1] << 15)
                ~ (w[i - 2 + 1] >> 19 | w[i - 2 + 1] << 13)
                ~ (w[i - 2 + 1] >> 10)
            w[i + 1] = (w[i - 16 + 1] + s0 + w[i - 7 + 1] + s1) & 0xFFFFFFFF
        end
        local a, b, c, d, e, f, g, hh =
            h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local S1 = (e >> 6 | e << 26) ~ (e >> 11 | e << 21) ~ (e >> 25 | e << 7)
            local ch = (e & f) ~ ((~e) & g)
            local t1 = (hh + S1 + ch + SHA_K[i] + w[i]) & 0xFFFFFFFF
            local S0 = (a >> 2 | a << 30) ~ (a >> 13 | a << 19) ~ (a >> 22 | a << 10)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & 0xFFFFFFFF
            hh, g, f, e, d, c, b, a =
                g, f, e, (d + t1) & 0xFFFFFFFF, c, b, a, (t1 + t2) & 0xFFFFFFFF
        end
        h[1] = (h[1] + a) & 0xFFFFFFFF
        h[2] = (h[2] + b) & 0xFFFFFFFF
        h[3] = (h[3] + c) & 0xFFFFFFFF
        h[4] = (h[4] + d) & 0xFFFFFFFF
        h[5] = (h[5] + e) & 0xFFFFFFFF
        h[6] = (h[6] + f) & 0xFFFFFFFF
        h[7] = (h[7] + g) & 0xFFFFFFFF
        h[8] = (h[8] + hh) & 0xFFFFFFFF
    end
    return h
end

function M.sha256hex(msg)
    local h = sha256_words(msg or "")
    local out = {}
    for i = 1, 8 do out[i] = string.format("%08x", h[i]) end
    return table.concat(out)
end

local function hmac_bytes(key, msg)
    if #key > 64 then
        local h = sha256_words(key)
        local parts = {}
        for i = 1, 8 do
            local v = h[i]
            parts[i] = string.char(
                math.floor(v / 2^24) % 256, math.floor(v / 2^16) % 256,
                math.floor(v / 2^8) % 256, v % 256)
        end
        key = table.concat(parts)
    end
    key = key .. string.rep("\0", 64 - #key)
    local function xor_pad(byte)
        local t = {}
        for i = 1, 64 do t[i] = string.char(key:byte(i) ~ byte) end
        return table.concat(t)
    end
    local inner = sha256_words(xor_pad(0x36) .. msg)
    local parts = {}
    for i = 1, 8 do
        local v = inner[i]
        parts[i] = string.char(
            math.floor(v / 2^24) % 256, math.floor(v / 2^16) % 256,
            math.floor(v / 2^8) % 256, v % 256)
    end
    return xor_pad(0x5c) .. table.concat(parts)
end

function M.hmac_sha256hex(key, msg)
    local h = sha256_words(hmac_bytes(key or "", msg or ""))
    local out = {}
    for i = 1, 8 do out[i] = string.format("%08x", h[i]) end
    return table.concat(out)
end

-- Raw 32-byte HMAC-SHA-256 (SigV4 key derivation needs binary chaining).
function M.hmac_sha256_raw(key, msg)
    return hmac_bytes(key or "", msg or "")
end

return M
