-- tether providers/gemini — Google Gemini API adapter.
-- Reference shape: dotMavriQ/linea src/api/gemini.lua (generateContent
-- payload, ?key= auth, candidates[].content.parts[].text extraction).
-- Streams via :streamGenerateContent (SSE, one full response object per
-- data: line); falls back to :generateContent (single JSON body), which
-- the transport routes through handle_non_sse into the same events.
-- Tool argument deltas are JSON-escaped (jesc) so agent.parse_args
-- unescapes exactly once (M7/D2b raw-args rule).
local M = {}

M.name = "gemini"

local common = (_G.provider_common)
    or (loadfile("src/tether/providers/common.lua")
        and loadfile("src/tether/providers/common.lua")())
assert(common, "gemini provider: cannot load provider_common")
local jesc = common.jesc
local json_unescape = common.json_unescape

-- Per-stream counter for synthesized tool-call ids (model-role parts carry
-- no ids). Reset per request via reset_stream().
local S = { tool_seq = 0, saw_rest = false }

function M.reset_stream()
    S.tool_seq = 0
    S.saw_rest = false
end

-- SSE object lines carry no stream terminator; the transport calls this at
-- clean EOF. Skipped when the REST fallback already closed the stream.
function M.stream_finished(on_event)
    if not S.saw_rest then
        on_event({ type = "done" })
    end
end

-- History (OpenAI shape, as stored by agent.lua) -> Gemini JSON body.
-- arguments in history are RAW (still-JSON-escaped): one unescape here
-- turns them back into valid JSON, spliced as `args` verbatim.
local function text_part(text)
    return string.format('{"text":"%s"}', jesc(text))
end

-- Raw argument fragments are still-JSON-escaped: one unescape restores the
-- JSON object for splicing. Anything that is not an object degrades to {}
-- instead of breaking the request envelope structurally.
local function clean_args(raw)
    if not raw or raw == "" then return "{}" end
    local unesc = json_unescape(raw)
    if unesc:match("^%s*{.*}%s*$") then return unesc end
    return "{}"
end

local function convert_contents(messages)
    local system_parts = {}
    -- agent history tool results carry no function name; recover it from
    -- the preceding assistant tool_call with the same id.
    local id_to_name = {}
    for _, m in ipairs(messages) do
        local c = m.content
        if m.role == "assistant" and type(c) == "table" and c.tool_calls then
            for _, tc in ipairs(c.tool_calls) do
                if tc.id and tc["function"] and tc["function"].name then
                    id_to_name[tc.id] = tc["function"].name
                end
            end
        end
    end
    local out = {}
    for _, m in ipairs(messages) do
        if m.role == "system" then
            system_parts[#system_parts + 1] = text_part(tostring(m.content or ""))
        elseif m.role == "tool" then
            out[#out + 1] = string.format(
                '{"role":"user","parts":[{"functionResponse":{"name":"%s","response":{"result":"%s"}}}]}',
                jesc(id_to_name[m.tool_call_id] or "tool"),
                jesc(tostring(m.content or "")))
        else
            local content = m.content
            if type(content) == "table" and content.tool_calls then
                local parts = {}
                if type(content.text) == "string" and content.text ~= "" then
                    parts[#parts + 1] = text_part(content.text)
                end
                for _, tc in ipairs(content.tool_calls) do
                    local raw = tc["function"] and tc["function"].arguments or ""
                    parts[#parts + 1] = string.format(
                        '{"functionCall":{"name":"%s","args":%s}}',
                        jesc(tc["function"] and tc["function"].name or ""),
                        clean_args(raw))
                end
                out[#out + 1] = string.format(
                    '{"role":"model","parts":[%s]}', table.concat(parts, ","))
            else
                local role = (m.role == "assistant") and "model" or "user"
                out[#out + 1] = string.format(
                    '{"role":"%s","parts":[%s]}', role, text_part(tostring(content or "")))
            end
        end
    end
    return "[" .. table.concat(system_parts, ",") .. "]",
           "[" .. table.concat(out, ",") .. "]"
end

local function declarations_payload()
    local decls = {}
    for _, t in ipairs(common.tools_schema()) do
        decls[#decls + 1] = common.json_encode({
            name = t.name, description = t.description,
            parameters = t.parameters,
        })
    end
    return string.format('[{"functionDeclarations":[%s]}]', table.concat(decls, ","))
end

function M.build_request(messages, _model, _max_tokens)
    local system, contents = convert_contents(messages)
    local parts = {
        string.format('"contents":%s', contents),
        string.format('"tools":%s', declarations_payload()),
    }
    if system ~= "[]" then
        parts[#parts + 1] = string.format('"systemInstruction":{"parts":%s}', system)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function stream_path(cfg, model)
    return string.format("%s/v1beta/models/%s:streamGenerateContent",
        (cfg.base_url or ""), (model or ""))
end

function M.stream_url(cfg, model, api_key)
    return stream_path(cfg, model) .. "?key=" .. (api_key or "")
end

function M.rest_url(cfg, model, api_key)
    return string.format("%s/v1beta/models/%s:generateContent?key=%s",
        (cfg.base_url or ""), (model or ""), (api_key or ""))
end

function M.header_lines(_api_key)
    return {}
end

function M.models_url(cfg, api_key)
    return (cfg.base_url or "") .. "/v1beta/models?key=" .. (api_key or "")
end

function M.models_headers(_api_key)
    return {}
end

function M.models_parse(body)
    -- [{"name":"models/gemini-2.5-flash",...}] — strip the models/ prefix.
    local result = {}
    for name in body:gmatch('"name"[%s]*:[%s]*"models/([^"]+)"') do
        result[#result + 1] = { id = name, name = name }
    end
    return result
end

function M.static_models()
    return {
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-flash-latest",
        "gemini-2.0-flash",
    }
end

-- Balance-scan the first {...} object starting at `pos` (handles nesting
-- and quoted strings). Returns the object substring or nil.
local function balanced_object(s, pos)
    local depth, i, instr, esc = 0, pos, false, false
    while i <= #s do
        local c = s:sub(i, i)
        if instr then
            if esc then esc = false
            elseif c == "\\" then esc = true
            elseif c == '"' then instr = false end
        else
            if c == '"' then instr = true
            elseif c == "{" then depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then return s:sub(pos, i) end
            end
        end
        i = i + 1
    end
    return nil
end

-- Shared core: map one decoded response OBJECT (SSE line payload or REST
-- body) to canonical events. Returns true when candidates were present.
local function emit_response(payload, on_event)
    if not payload:find('"candidates"', 1, true) then return false end
    local any = false
    -- text parts (skip the functionCall neighbourhood by matching per-part)
    for text in payload:gmatch('"text"[%s]*:[%s]*"(.-[^\\])"') do
        if text ~= "" then
            text = json_unescape(text)
            if text ~= "" then
                on_event({ type = "text_delta", text = text })
                any = true
            end
        end
    end
    -- functionCall parts: name + balanced args object, re-escaped (raw rule)
    local search_from = 1
    while true do
        local fs, fe, fname = payload:find(
            '"functionCall"[%s]*:[%s]*{%s*"name"[%s]*:[%s]*"([^"]+)"', search_from)
        if not fs then break end
        local as, ae = payload:find('"args"[%s]*:[%s]*{', fe)
        local args = "{}"
        if as then
            local obj = balanced_object(payload, ae)
            if obj then args = obj end
        end
        S.tool_seq = S.tool_seq + 1
        local id = "gemini_" .. S.tool_seq
        on_event({ type = "tool_call_start", id = id, name = fname })
        on_event({ type = "tool_call_delta", id = id, arguments = jesc(args) })
        any = true
        search_from = fe + 1
    end
    -- usage
    local pt = tonumber(payload:match('"promptTokenCount"[%s]*:[%s]*(%d+)'))
    local ct = tonumber(payload:match('"candidatesTokenCount"[%s]*:[%s]*(%d+)'))
    if pt or ct then
        on_event({ type = "usage", usage = {
            used = (pt or 0) + (ct or 0),
            prompt_tokens = pt, completion_tokens = ct,
        } })
        any = true
    end
    -- error payloads: {"error":{"message":"...","code":...}}
    if not any and payload:find('"error"', 1, true) then
        local msg = payload:match('"message"[%s]*:[%s]*"(.-[^\\])"')
        on_event({ type = "error", message = msg and json_unescape(msg) or "gemini error" })
        return true
    end
    return any
end

local function parse_sse_line(line, on_event)
    if line:sub(1, 6) ~= "data: " then return end
    local payload = line:sub(7)
    if payload == "[DONE]" then
        on_event({ type = "done" })
        return
    end
    if emit_response(payload, on_event) then
        -- SSE object lines carry no explicit terminator; completion is
        -- signalled by stream end. Surface per-chunk usage, not done.
    end
end

-- Non-SSE body (REST generateContent): same events, then done.
function M.handle_non_sse(body, on_event)
    if emit_response(body, on_event) then
        S.saw_rest = true
        on_event({ type = "done" })
        return true
    end
    return false
end

M.parse_sse_line = parse_sse_line
M.convert_contents = convert_contents

return M
