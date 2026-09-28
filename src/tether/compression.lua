-- tether compression — pure context-compaction policy.
--
-- Data in → verdict out: token estimates, budget thresholds, the
-- should-compact decision (plain and preflight-projected), history span
-- splitting, deterministic truncation/anchor summaries and the summary
-- request messages. No I/O and no event emission: the LLM summarize call,
-- history swap and persistence stay in agent.lua (compact_history).
-- Same shape as confirm_policy: shared catalog/common instances resolve
-- through globals with loadfile fallbacks for dev/test runs.
local M = {}

-- fix-audit-findings 3.9: JSON helpers live once, in providers/common.lua.
-- The C host exposes it as the `provider_common` global (loaded before
-- every core module); the loadfile fallback keeps development runs and
-- plain-lua tests working.
local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "compression: cannot load provider_common")
local json_parse = common.json_decode

-- dynamic-provider-catalog: catalog lookup for the compaction budget.
-- Shared instance in the binary, loadfile fallback for dev/test runs.
local catalog = _G.provider_catalog
    or (function()
        local chunk = loadfile("src/tether/providers/catalog.lua")
        return chunk and chunk()
    end)()

-- Per-model context limit: exact (provider, model) hit, else the
-- provider's default model, else nil (caller keeps 32768). A model name
-- matching nothing falls down the chain, never fails.
local function catalog_max_tokens(cfg)
    if not (catalog and catalog.get and cfg) then return nil end
    local entry = catalog.get(cfg.provider)
    if not (entry and type(entry.models) == "table") then return nil end
    local want, fallback = cfg.model, entry.model
    local fb = nil
    for _, m in ipairs(entry.models) do
        local id = (type(m) == "table" and m.id) or m
        local cx = (type(m) == "table" and m.context) or nil
        if type(cx) == "number" and cx > 0 then
            if id == want then return cx end
            if id == fallback then fb = cx end
        end
    end
    return fb
end
M.catalog_max_tokens = catalog_max_tokens

local function estimate_tokens(history)
    local total = 0
    for _, m in ipairs(history) do
        local c = m.content
        if type(c) == "string" then total = total + #c / 4
        elseif type(c) == "table" then
            for _, tc in ipairs(c) do
                total = total + #(tc["function"] and (tc["function"].arguments or "") or "") / 4
            end
        end
    end
    return math.ceil(total)
end
M.estimate_tokens = estimate_tokens

local function context_flag(cfg, key, default)
    local ctx = cfg and cfg.context
    if ctx == nil then return default end
    local v = ctx[key]
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    return default
end
M.context_flag = context_flag

local function compaction_thresholds(cfg)
    local ctx = (cfg and cfg.context) or {}
    local max_tokens = tonumber(ctx.max_tokens)
    if not max_tokens then
        max_tokens = catalog_max_tokens(cfg) or 32768
    end
    local fraction = tonumber(ctx.summarize_at)
    if not fraction or fraction <= 0 or fraction >= 1 then fraction = 0.7 end
    local reserve = tonumber(ctx.reserve_tokens)
    if not reserve or reserve < 0 then reserve = 16384 end
    return max_tokens, fraction, reserve
end
M.compaction_thresholds = compaction_thresholds

local function over_threshold(est, max_tokens, fraction, reserve)
    -- OR of two thresholds: fraction of the budget, or the reply reserve.
    -- A large reserve can fire first; that is intentional (safety net).
    return est > fraction * max_tokens or est > max_tokens - reserve
end
M.over_threshold = over_threshold

local function should_summarize(history, cfg)
    local max_tokens, fraction, reserve = compaction_thresholds(cfg)
    return over_threshold(estimate_tokens(history), max_tokens, fraction, reserve)
end
M.should_summarize = should_summarize

-- Preflight: project current estimate + incoming prompt cost against the same
-- thresholds, so a single large paste compacts before the turn goes out.
local function should_summarize_projected(history, prompt_text, cfg)
    local max_tokens, fraction, reserve = compaction_thresholds(cfg)
    local prompt_cost = 0
    if type(prompt_text) == "string" and #prompt_text > 0 then
        prompt_cost = math.ceil(#prompt_text / 4)
    end
    return over_threshold(estimate_tokens(history) + prompt_cost,
        max_tokens, fraction, reserve)
end
M.should_summarize_projected = should_summarize_projected

local function keep_recent_of(cfg)
    local n = cfg and cfg.context and tonumber(cfg.context.keep_recent_messages)
    if not n or n < 0 then return 4 end
    return math.floor(n)
end
M.keep_recent_of = keep_recent_of

-- Split history into system + old span + keep window (walks back over leading
-- tool messages so a tool result is not orphaned from its call).
local function split_span(history, N)
    if #history <= N + 1 then return history[1], {}, {} end
    local keep_from = math.max(2, #history - N + 1)
    while keep_from > 2 and history[keep_from].role == "tool" do
        keep_from = keep_from - 1
    end
    local old = {}
    for i = 2, keep_from - 1 do old[#old + 1] = history[i] end
    local keep = {}
    for i = keep_from, #history do keep[#keep + 1] = history[i] end
    return history[1], old, keep
end
M.split_span = split_span

local function truncation_body(old)
    local parts = {}
    for _, m in ipairs(old) do
        local c = m.content
        if type(c) == "string" then
            parts[#parts + 1] = m.role .. ": " .. (c:sub(1, 200) .. (c:len() > 200 and "…" or ""))
        end
    end
    return table.concat(parts, "\n")
end
M.truncation_body = truncation_body

M.SUMMARY_MARKER = "── summary ──"
M.SUMMARY_SPAN_MAX = 2000

-- Deterministic summary anchors (adapted from pifydev/compact): facts worth
-- preserving, extracted by plain parsing with no model call. shapes handled:
-- user/assistant string content plus assistant {tool_calls, text} tables where
-- each call is {id, ["function"] = {name, arguments}} with arguments as a JSON
-- string (the history echo form) or a table.
M.ANCHOR_TASK_WORDS = { "fix", "implement", "add", "create", "build",
    "refactor", "remove", "update", "change", "make", "write", "support",
    "migrate", "debug", "investigate", "improve", "optimize", "optimise",
    "optimizing", "optimising", "rename", "delete", "integrate", "wire", "port" }
M.ANCHOR_SCOPE_HINTS = { "instead", "actually", "pivot", "scratch that",
    "on second thought", "change of plans", "let's not", "no, wait", "no wait" }
M.ANCHOR_PREF_HINTS = { "prefer", "always", "never", "please use",
    "please don't", "please dont", "make sure", "ensure", "don't use",
    "dont use", "avoid using", "instead", "keep it", "style:" }
M.ANCHOR_BLOCKER_HINTS = { "fail", "failed", "failing", "fails",
    "error", "errored", "broken", "cannot", "can't", "cant", "blocked",
    "crash", "crashed", "crashes", "not working", "unresolved", "still stuck",
    "doesn't work", "doesnt work", "don't work", "dont work" }
M.ANCHOR_NOISE_FIRST = { ok = true, okay = true, yes = true, no = true,
    thanks = true, sure = true, go = true, continue = true, proceed = true,
    next = true, yep = true, nope = true, k = true }
M.ANCHOR_GOAL_MAX = 140
M.ANCHOR_LINE_MAX = 120

-- Lua patterns have no alternation: single words match on word boundaries,
-- multi-word hints match as plain substrings.
local function anchor_any(lower, hints)
    for _, h in ipairs(hints) do
        if h:find("[^%w']") then
            if lower:find(h, 1, true) then return true end
        else
            if lower:find("%f[%a]" .. h .. "%f[%A]") then return true end
        end
    end
    return false
end

local function anchor_is_noise(text)
    local t = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = t:lower()
    if lower == "do it" then return true end
    local first = lower:match("^(%a+)")
    return first ~= nil and M.ANCHOR_NOISE_FIRST[first] == true
        and #t < 24
end

local function anchor_snippet(text, max)
    max = max or M.ANCHOR_GOAL_MAX
    local line = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #line > max then return line:sub(1, max - 1) .. "…" end
    return line
end

local function anchor_text(content)
    if type(content) == "string" then return content end
    if type(content) == "table" and type(content.text) == "string" then
        return content.text
    end
    return ""
end

local function anchor_tool_calls(content)
    local out = {}
    if type(content) ~= "table" then return out end
    local list = content.tool_calls
    if type(list) ~= "table" then
        -- tolerance: content itself may be the call list
        if #content > 0 then list = content else return out end
    end
    for _, tc in ipairs(list) do
        if type(tc) == "table" then out[#out + 1] = tc end
    end
    return out
end
M.anchor_tool_calls = anchor_tool_calls

local function anchor_call_args(tc)
    local fn = tc["function"] or tc.fn or {}
    local args = fn.arguments
    if type(args) == "string" and args ~= "" then
        local ok, tbl = pcall(json_parse, args)
        if ok and type(tbl) == "table" then return fn.name, tbl end
        return fn.name, {}
    elseif type(args) == "table" then
        return fn.name, args
    end
    return fn.name, {}
end
M.anchor_call_args = anchor_call_args

M.ANCHOR_WRITE_TOOLS = { write = true, patch = true, edit = true,
    apply_patch = true, multiedit = true }
M.ANCHOR_READ_TOOLS = { read = true, cat = true }

local function anchor_trim_prefix(paths)
    if #paths < 2 then return paths end
    local split = {}
    for i, p in ipairs(paths) do
        split[i] = {}
        for seg in tostring(p):gmatch("[^/\\]+") do split[i][#split[i] + 1] = seg end
    end
    local common = 0
    while true do
        local seg = split[1][common + 1]
        if seg == nil then break end
        local all = true
        for i = 2, #split do
            if #split[i] - 1 <= common or split[i][common + 1] ~= seg then
                all = false break
            end
        end
        if not all then break end
        common = common + 1
    end
    if common == 0 then return paths end
    local out = {}
    for i, parts in ipairs(split) do
        local tail = {}
        for j = common + 1, #parts do tail[#tail + 1] = parts[j] end
        out[i] = table.concat(tail, "/")
    end
    return out
end

local function extract_anchors(history)
    local goal, scope_change = nil, nil
    local modified, modified_order = {}, {}
    local read_set, read_order = {}, {}
    local prefs, commits, blockers = {}, {}, {}
    local pending_commit = nil
    local saw_goal = false
    history = history or {}
    for _, m in ipairs(history) do
        local role = m.role
        if role == "user" then
            local text = anchor_text(m.content)
            if text:match("%S") and not anchor_is_noise(text) then
                local lower = text:lower()
                if not saw_goal and anchor_any(lower, M.ANCHOR_TASK_WORDS) then
                    goal = anchor_snippet(text)
                    saw_goal = true
                elseif anchor_any(lower, M.ANCHOR_SCOPE_HINTS) then
                    scope_change = anchor_snippet(text)
                end
                if #prefs < 6 and not text:match("%?%s*$")
                    and anchor_any(lower, M.ANCHOR_PREF_HINTS) then
                    local hit = text
                    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
                        if anchor_any(line:lower(), M.ANCHOR_PREF_HINTS) then
                            hit = line break
                        end
                    end
                    prefs[#prefs + 1] = anchor_snippet(hit, M.ANCHOR_LINE_MAX)
                end
            end
        elseif role == "assistant" then
            for _, tc in ipairs(anchor_tool_calls(m.content)) do
                local name, args = anchor_call_args(tc)
                name = type(name) == "string" and name:lower() or ""
                if name == "run" then
                    local cmd = type(args.command) == "string" and args.command or ""
                    local msg = cmd:match("git commit%s[^\n]*%-m%s+[\"']([^\"']+)[\"']")
                        or cmd:match("git commit%s[^\n]*%-m%s+(%S%S%S+)")
                    if msg then pending_commit = anchor_snippet(msg, M.ANCHOR_LINE_MAX) end
                else
                    local p = args.path or args.file or args.filename
                    if type(p) == "string" and p:match("%S") then
                        p = p:gsub("^%s+", ""):gsub("%s+$", "")
                        if M.ANCHOR_WRITE_TOOLS[name] then
                            if not modified[p] then
                                modified[p] = true
                                modified_order[#modified_order + 1] = p
                            end
                        elseif M.ANCHOR_READ_TOOLS[name] then
                            if not read_set[p] then
                                read_set[p] = true
                                read_order[#read_order + 1] = p
                            end
                        end
                    end
                end
            end
        elseif role == "tool" then
            if pending_commit then
                local out = anchor_text(m.content)
                local hash = out:match("%f[%w]([0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][%w]*)%f[^%w]")
                if hash then
                    commits[#commits + 1] = hash:sub(1, 8) .. " " .. pending_commit
                else
                    commits[#commits + 1] = pending_commit
                end
                if #commits >= 4 then
                    -- keep scanning (pending cleared) but stop growing
                    pending_commit = nil
                else
                    pending_commit = nil
                end
            end
        end
    end
    -- Blockers: tail only, an old failure is usually resolved.
    local tail_from = math.max(1, #history - 23)
    for i = tail_from, #history do
        if #blockers >= 4 then break end
        local m = history[i]
        if m.role == "tool" or m.role == "user" then
            local text = anchor_text(m.content)
            if text:match("%S") then
                local hit = nil
                for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
                    if anchor_any(line:lower(), M.ANCHOR_BLOCKER_HINTS) then
                        hit = line break
                    end
                end
                if m.error or hit then
                    blockers[#blockers + 1] =
                        anchor_snippet(hit or text, M.ANCHOR_LINE_MAX)
                end
            end
        end
    end
    local modified_trimmed = anchor_trim_prefix(modified_order)
    local both = {}
    for i, p in ipairs(modified_order) do
        if read_set[p] then both[#both + 1] = modified_trimmed[i] end
    end
    local files_read = {}
    for _, p in ipairs(read_order) do
        if not modified[p] then files_read[#files_read + 1] = p end
    end
    local files_modified = {}
    for i = 1, math.min(12, #modified_trimmed) do
        files_modified[#files_modified + 1] = modified_trimmed[i]
    end
    return {
        goal = goal,
        scope_change = scope_change,
        files_modified = files_modified,
        files_both = (function()
            local b = {}
            for i = 1, math.min(12, #both) do b[#b + 1] = both[i] end
            return b
        end)(),
        files_read = (function()
            local r = {}
            for i = 1, math.min(8, #files_read) do r[#r + 1] = files_read[i] end
            return r
        end)(),
        preferences = prefs,
        commits = (function()
            local seen, c = {}, {}
            for _, v in ipairs(commits) do
                if not seen[v] then seen[v] = true c[#c + 1] = v end
                if #c >= 4 then break end
            end
            return c
        end)(),
        blockers = (function()
            local seen, b = {}, {}
            for _, v in ipairs(blockers) do
                if not seen[v] then seen[v] = true b[#b + 1] = v end
                if #b >= 4 then break end
            end
            return b
        end)(),
    }
end
M.extract_anchors = extract_anchors

local function has_anchors(a)
    return a ~= nil and (a.goal ~= nil or a.scope_change ~= nil
        or #a.files_modified > 0 or #a.files_read > 0
        or #a.preferences > 0 or #a.commits > 0 or #a.blockers > 0)
end

local function format_anchors(a)
    if not has_anchors(a) then return "" end
    local lines = {
        "Preserve these exact facts in the summary — do not drop or generalize them:",
    }
    if a.goal then lines[#lines + 1] = "- Task: " .. a.goal end
    if a.scope_change then
        lines[#lines + 1] = "- Latest scope change: " .. a.scope_change
    end
    if #a.files_modified > 0 then
        local both = {}
        for _, f in ipairs(a.files_both) do both[f] = true end
        local names = {}
        for _, f in ipairs(a.files_modified) do
            names[#names + 1] = both[f] and (f .. " (RW)") or f
        end
        lines[#lines + 1] = "- Files modified: " .. table.concat(names, ", ")
    end
    if #a.files_read > 0 then
        lines[#lines + 1] = "- Files read: " .. table.concat(a.files_read, ", ")
    end
    if #a.preferences > 0 then
        lines[#lines + 1] = "- Preferences: " .. table.concat(a.preferences, " | ")
    end
    if #a.commits > 0 then
        lines[#lines + 1] = "- Commits: " .. table.concat(a.commits, " | ")
    end
    if #a.blockers > 0 then
        lines[#lines + 1] = "- Open/unresolved: " .. table.concat(a.blockers, " | ")
    end
    return table.concat(lines, "\n")
end
M.format_anchors = format_anchors

local function anchor_block(history, cfg)
    if not context_flag(cfg, "anchors", true) then return "" end
    local ok, a = pcall(extract_anchors, history)
    if not ok or type(a) ~= "table" then return "" end
    return format_anchors(a)
end
M.anchor_block = anchor_block

-- Role-prefixed span for the summary request; tool results / long bodies are
-- bounded so one file read cannot blow the compaction request.
local function serialize_span(old)
    local parts = {}
    for _, m in ipairs(old) do
        local c = m.content
        if type(c) == "string" then
            local body = c
            if #body > M.SUMMARY_SPAN_MAX then
                -- boundary-safe: this span is the body of the compaction request
                body = common.utf8_prefix(body, M.SUMMARY_SPAN_MAX) .. "…"
            end
            parts[#parts + 1] = m.role .. ": " .. body
        elseif type(c) == "table" then
            parts[#parts + 1] = m.role .. ": [tool_calls]"
        end
    end
    return table.concat(parts, "\n")
end
M.serialize_span = serialize_span

local function build_summary_messages(old, focus, anchors_text)
    local prompt = table.concat({
        "Summarize the conversation for a coding agent that will continue.",
        "Cover exactly these sections:",
        "- Goal",
        "- Constraints",
        "- Progress",
        "- Key decisions",
        "- Next steps",
        "Be dense and factual. Use only information present in the history.",
    }, "\n")
    if type(anchors_text) == "string" and anchors_text ~= "" then
        prompt = prompt .. "\n\n" .. anchors_text
    end
    if type(focus) == "string" and focus ~= "" then
        prompt = prompt .. "\n\nFocus instructions:\n" .. focus
    end
    return {
        { role = "system", content = prompt },
        { role = "user", content = "Conversation history:\n" .. serialize_span(old) },
    }
end
M.build_summary_messages = build_summary_messages

-- Compress old history: keep system + last N messages, summarize the rest.
-- Truncation-only entry kept for tests / callers that do not need the LLM path.
local function compress_history(history, cfg)
    local N = keep_recent_of(cfg)
    local system, old, keep = split_span(history, N)
    if #old == 0 then return history end
    local new_history = { system }
    new_history[#new_history + 1] =
        { role = "system", content = M.SUMMARY_MARKER .. "\n" .. truncation_body(old) }
    for _, m in ipairs(keep) do new_history[#new_history + 1] = m end
    return new_history
end
M.compress_history = compress_history

return M
