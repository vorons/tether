-- tether cache — pure prompt-cache policy (prompt-cache v1).
--
-- Key derivation, breakpoint planning and usage observation. No network, no
-- UI: adapters map the plan to wire markers (anthropic `cache_control`,
-- openai `prompt_cache_key`), api.lua threads it through, subagent.lua
-- hands the key to children. Same shape as confirm_policy/compression: a
-- shared global with a loadfile fallback for dev/test runs.
--
-- State (per cache key, in-process only): previous block hashes for the
-- head/tail split, the rolling usage window for the hit-rate diagnostic,
-- and a small ring of usage records. Streams are sequential (single agent
-- loop), so module-level state is safe; tests reset it via M.reset().
local M = {}

local common = _G.provider_common
    or (function()
        local chunk = loadfile("src/tether/providers/common.lua")
        return chunk and chunk()
    end)()
assert(common, "cache: cannot load provider_common")

-- Max breakpoints per Anthropic request (API limit).
M.MAX_BREAKPOINTS = 4

-- Rolling usage window for the hit-rate diagnostic (spec: 20 requests).
M.WINDOW = 20
-- Minimum window fill before a diagnostic can fire (avoids cold-start noise).
M.WINDOW_MIN = 5
-- Hit-rate floor: below this with a stable prefix something is wrong.
M.HIT_FLOOR = 0.6

-- Ring capacity for llm_cache_usage records.
M.RECORDS_CAP = 50

M._state = {}   -- key -> { hashes, window, prev_obs, diag_cooldown }
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
-- (tether has no named roles; divergent children derive under "child".)
function M.derive_key(parent_key, role)
    parent_key = tostring(parent_key or "")
    if parent_key == "" then return "" end
    return parent_key .. ":" .. M.slug(role or "child"):sub(1, 32)
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
-- comparison and the stability diff both run on this.
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
        local phash = os.getenv("TETHER_CACHE_SYS")
        if type(phash) == "string" and phash ~= ""
            and type(sys_hash) == "string" and sys_hash ~= ""
            and phash ~= sys_hash then
            return M.derive_key(parent, "child")
        end
        return parent
    end
    return M.session_key(cfg._session_id)
end

local function st_for(key)
    key = tostring(key or "")
    local st = M._state[key]
    if not st then
        st = { hashes = nil, window = {}, prev_obs = nil }
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
        and cfg.cache.retention == "1h" then
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

-- Observe one usage event. Returns a diagnostic string when the rolling
-- hit rate fell below HIT_FLOOR with a stable prefix, else nil.
-- usage: { prompt_tokens/input_tokens, cache_read_tokens, cache_write_tokens }
-- blocks: {{name, hash}} of the prefix just sent.
-- Quiet unless the provider shows cache activity (reads or writes): a
-- provider that never reports cache fields (local runtimes) must not spam.
function M.observe(key, usage, blocks)
    key = tostring(key or "")
    if key == "" then return nil end
    local st = st_for(key)
    usage = (type(usage) == "table") and usage or {}
    local inp = tonumber(usage.prompt_tokens or usage.input_tokens) or 0
    local read = tonumber(usage.cache_read_tokens) or 0
    local written = tonumber(usage.cache_write_tokens) or 0
    local w = st.window
    w[#w + 1] = { inp = inp, read = read, write = written }
    while #w > M.WINDOW do table.remove(w, 1) end
    if #w < M.WINDOW_MIN then
        st.prev_obs = blocks
        return nil
    end
    local tin, tr, tw = 0, 0, 0
    for _, e in ipairs(w) do
        tin = tin + e.inp; tr = tr + e.read; tw = tw + e.write
    end
    if tin == 0 or tw == 0 and tr == 0 then
        st.prev_obs = blocks
        return nil
    end
    if tr / tin >= M.HIT_FLOOR then
        st.prev_obs = blocks
        return nil
    end
    -- Low rate: blame only a stable prefix (changed blocks named).
    local prev = st.prev_obs
    st.prev_obs = blocks
    if prev == nil then return nil end
    local old = {}
    for _, b in ipairs(prev or {}) do
        if type(b) == "table" then old[tostring(b.name)] = tostring(b.hash) end
    end
    local changed = {}
    for _, b in ipairs(blocks or {}) do
        if type(b) == "table" then
            local n = tostring(b.name)
            if old[n] ~= nil and old[n] ~= tostring(b.hash) then
                changed[#changed + 1] = n
            elseif old[n] == nil then
                changed[#changed + 1] = n .. " (new)"
            end
        end
    end
    local rate = math.floor(tr / tin * 100)
    if #changed == 0 then
        return string.format(
            "prompt-cache: hit-rate %d%% (<%d%%) over last %d requests "
            .. "with a stable prefix (key=%s)",
            rate, math.floor(M.HIT_FLOOR * 100), #w, key)
    end
    return string.format(
        "prompt-cache: hit-rate %d%% (<%d%%) over last %d requests "
        .. "(key=%s); changed blocks: %s",
        rate, math.floor(M.HIT_FLOOR * 100), #w, key,
        table.concat(changed, ", "))
end

return M
