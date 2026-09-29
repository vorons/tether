-- tether cache — pure prompt-cache policy.
--
-- Key derivation, breakpoint planning and usage records. No network, no
-- UI: adapters map the plan to wire markers (anthropic `cache_control`,
-- openai `prompt_cache_key`), api.lua threads it through, subagent.lua
-- hands the key to children. Same shape as confirm_policy/compression: a
-- shared global with a loadfile fallback for dev/test runs.
--
-- State (per cache key, in-process only): previous block hashes for the
-- head/tail split and a small ring of usage records. Streams are
-- sequential (single agent loop), so module-level state is safe; tests
-- reset it via M.reset().
local M = {}

local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "cache: cannot load provider_common")

-- Ring capacity for llm_cache_usage records.
M.RECORDS_CAP = 50

M._state = {}   -- key -> { hashes }
M._records = {} -- newest-first llm_cache_usage records (cap RECORDS_CAP)

function M.reset()
    M._state = {}
    M._records = {}
end

-- slug: lowercase [a-z0-9-], runs collapsed. Empty input -> "session".
function M.slug(s)
    s = tostring(s or ""):lower()
        :gsub("[^%w]", "-"):gsub("%-+", "-")
        :gsub("^%-+", ""):gsub("%-+$", "")
    if s == "" then s = "session" end
    return s
end

-- One logical conversation = one key. OpenAI caps prompt_cache_key at 64.
function M.session_key(session_id)
    if type(session_id) ~= "string" or session_id == "" then return "" end
    return M.slug(session_id):sub(1, 64)
end

-- A child with a fully different system prompt gets a derived pool key.
function M.derive_key(parent_key)
    parent_key = tostring(parent_key or "")
    if parent_key == "" then return "" end
    return parent_key .. ":child"
end

function M.enabled(cfg)
    if type(cfg) ~= "table" then return true end
    if type(cfg.cache) ~= "table" then return true end
    if cfg.cache.enabled == nil then return true end
    return cfg.cache.enabled == true
end

function M.debug_on(cfg)
    return type(cfg) == "table" and type(cfg.cache) == "table"
        and cfg.cache.debug == true
end

local function dbg(cfg, msg)
    if M.debug_on(cfg) then
        io.stderr:write("tether cache: " .. tostring(msg) .. "\n")
    end
end

function M.block_hash(text)
    return common.sha256hex(tostring(text or ""))
end

-- Identity of a block list (names + contents): the child-inheritance
-- comparison runs on this.
function M.blocks_hash(blocks)
    local parts = {}
    for _, b in ipairs(blocks or {}) do
        if type(b) == "table" then
            parts[#parts + 1] = tostring(b.name or "") .. "\0"
                .. tostring(b.text or b.content or "")
        end
    end
    return common.sha256hex(table.concat(parts, "\0"))
end

-- Child key decision (pure, testable without env): a child that shares
-- the parent system prompt reuses the parent key, otherwise it derives.
function M.child_key(parent, parent_hash, sys_hash)
    parent = tostring(parent or "")
    if parent == "" then return "" end
    if type(parent_hash) == "string" and parent_hash ~= ""
        and type(sys_hash) == "string" and sys_hash ~= ""
        and parent_hash ~= sys_hash then
        return M.derive_key(parent)
    end
    return parent
end

-- Final key for this request: explicit override, inherited parent key
-- (derived when the system prompt diverged), else the session slug.
-- sys_hash is blocks_hash() of the blocks actually being sent.
function M.resolve_key(cfg, sys_hash)
    cfg = (type(cfg) == "table") and cfg or {}
    if type(cfg._cache_key) == "string" and cfg._cache_key ~= "" then
        return cfg._cache_key
    end
    local parent = os.getenv("TETHER_CACHE_KEY")
    if type(parent) == "string" and parent ~= "" then
        return M.child_key(parent, os.getenv("TETHER_CACHE_SYS"), sys_hash)
    end
    return M.session_key(cfg._session_id)
end

local function st_for(key)
    key = tostring(key or "")
    local st = M._state[key]
    if not st then
        st = { hashes = nil }
        M._state[key] = st
    end
    return st
end

-- Plan the breakpoints for one request.
-- cfg: session config (reads cache.enabled, _session_id, _system_blocks).
-- messages: the outbound view (OpenAI shape, as stored by agent.lua).
-- blocks_override: explicit labeled blocks (tests); else cfg._system_blocks;
--   else one block per system message in the view.
-- Returns nil when caching is disabled, else:
--   { key, sys_texts[], sys_head (idx or nil), sys_end, tools, last_msg,
--     blocks ({name,hash}[]), sys_hash, ttl }
function M.plan(cfg, messages, blocks_override)
    if not M.enabled(cfg) then return nil end
    messages = (type(messages) == "table") and messages or {}
    local sys_texts = {}
    for _, m in ipairs(messages) do
        if m.role == "system" and m.content ~= nil then
            sys_texts[#sys_texts + 1] = tostring(m.content)
        end
    end
    -- Labeled compose blocks describe history[1]; extra system messages
    -- (compaction summaries) ride as volatile tail blocks after them.
    local seg = {}
    local blocks = blocks_override
    if blocks == nil and type(cfg) == "table" then blocks = cfg._system_blocks end
    if type(blocks) == "table" and #blocks > 0 and #sys_texts > 0 then
        for _, b in ipairs(blocks) do
            if type(b) == "table" then
                seg[#seg + 1] = {
                    name = tostring(b.name or "block"),
                    text = tostring(b.text or b.content or ""),
                }
            end
        end
        for i = 2, #sys_texts do
            seg[#seg + 1] = { name = "system-" .. i, text = sys_texts[i] }
        end
    else
        for i, t in ipairs(sys_texts) do
            seg[#seg + 1] = {
                name = (#sys_texts > 1) and ("system-" .. i) or "system",
                text = t,
            }
        end
    end
    local hashes, infos = {}, {}
    for _, b in ipairs(seg) do
        local h = M.block_hash(b.name .. "\0" .. b.text)
        hashes[#hashes + 1] = h
        infos[#infos + 1] = { name = b.name, hash = h }
    end
    local sys_hash = M.blocks_hash(seg)
    local key = M.resolve_key(cfg, sys_hash)
    -- Head/tail split: diff against the previous request under this key.
    -- head = leading run of unchanged blocks; the head breakpoint lands on
    -- the last unchanged block so a tail change keeps the head entry warm.
    local st = st_for(key)
    local prev = st.hashes
    local head = nil
    if prev == nil then
        head = nil -- first sight: whole system is one segment (end marker)
    else
        local run = 0
        for i = 1, #hashes do
            if prev[i] ~= nil and prev[i] == hashes[i] then
                run = run + 1
            else
                break
            end
        end
        if run >= 1 and run < #hashes then head = run end
    end
    st.hashes = hashes
    local texts = {}
    for _, b in ipairs(seg) do texts[#texts + 1] = b.text end
    local ttl = nil
    if type(cfg) == "table" and type(cfg.cache) == "table"
        and cfg.cache.long_retention == true then
        ttl = "1h"
    end
    local plan = {
        key = key,
        sys_texts = texts,
        sys_head = head,
        sys_end = #texts > 0,
        tools = true,
        last_msg = true,
        blocks = infos,
        sys_hash = sys_hash,
        ttl = ttl,
    }
    dbg(cfg, "plan key=" .. tostring(key) .. " sys_blocks=" .. #texts
        .. " head=" .. tostring(head))
    return plan
end

-- Build the llm_cache_usage record (spec §9). Pure: callers store/log it.
function M.usage_record(opts)
    opts = (type(opts) == "table") and opts or {}
    local usage = (type(opts.usage) == "table") and opts.usage or {}
    local blocks = (type(opts.blocks) == "table") and opts.blocks or {}
    local prefixes = {}
    for _, b in ipairs(blocks) do
        if type(b) == "table" then
            prefixes[#prefixes + 1] = { name = tostring(b.name or ""),
                                        hash = tostring(b.hash or "") }
        end
    end
    return {
        event = "llm_cache_usage",
        session_id = opts.session_id,
        cache_key = opts.cache_key,
        provider = opts.provider,
        model = opts.model,
        input_tokens = tonumber(usage.prompt_tokens) or 0,
        cache_read_tokens = tonumber(usage.cache_read_tokens) or 0,
        cache_write_tokens = tonumber(usage.cache_write_tokens) or 0,
        cache_write_ttl = opts.ttl,
        cache_key_present = opts.cache_key_present,
        prefix_blocks = prefixes,
        turn_blocks_count = tonumber(opts.turn_blocks_count) or 0,
    }
end

function M.store_record(rec)
    if type(rec) ~= "table" then return end
    table.insert(M._records, 1, rec)
    while #M._records > M.RECORDS_CAP do
        table.remove(M._records)
    end
end

-- Test seam: newest stored record, or nil.
function M.last_record()
    return M._records[1]
end

return M
