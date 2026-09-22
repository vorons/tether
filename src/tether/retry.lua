-- tether retry — retry policy for provider failures and truncated answers.
--
-- Pure Lua: no I/O, no globals, no transport knowledge. api.lua reports what
-- happened, agent.lua applies the decisions made here, and the policy tables
-- are exercised directly by tests/lua_tests.lua (the providers/common.lua
-- pattern). Keeping it pure is the point: classification, the backoff
-- schedule, the cutoff and the continuation policy are data, so they can be
-- tested and extended without a transport mock.
local M = {}

M.DEFAULTS = {
    base_delay_ms = 2000,
    max_delay_ms = 60000,
    multiplier = 2,
    max_failures_at_max_delay = 3,
}

-- Kinds. `unknown` is the catch-all and stays retryable: an unrecognised
-- provider failure is retried rather than silently ending the turn.
local RETRYABLE = {
    connection = true,
    credit = true,
    request = true,
    server = true,
    empty = true,
    unknown = true,
}

local REASONS = {
    quota = "quota/usage limit exhausted",
    permanent = "permanent failure",
    interrupted = "interrupted by user",
    connection = "connection error",
    credit = "credit/payment error",
    request = "bad request",
    server = "server error / rate limit",
    empty = "empty response",
    unknown = "provider error",
}

-- Matched case-insensitively as plain substrings, in this order: quota, then
-- permanent, then the retryable kinds. Do not add `invalid_request_error`
-- here — OpenAI wraps a context-overflow 400 in it, and a 400 must stay
-- retryable (without compaction) per the 400/413 rule.
-- The transport's own abort signal (libcurl's CURLE_ABORTED_BY_CALLBACK text,
-- raised by the Ctrl+C progress callback in src/host/main.c). Checked first: it
-- is never a provider failure, so it must never be retried as one.
local INTERRUPTED = {
    "aborted by an application callback",
    "aborted by callback",
}

local QUOTA = {
    "you've hit your limit", "you have hit your limit",
    "you've hit your usage limit", "you have hit your usage limit",
    "hit your usage limit",
    "you've exceeded your usage limit", "you have exceeded your usage limit",
    "usage limit reached", "usage_limit_reached", "5-hour limit reached",
    "insufficient_quota",
    "you exceeded your current quota", "exceeded your current quota",
    "exhausted your capacity", "quota will reset",
    "reached the quota limit", "resume using this model",
    "allocated quota exceeded", "free allocated quota exceeded",
    "premium request allowance",
    "out of budget", "budget has been exceeded", "budget exceeded",
    "spending limit", "monthly limit", "no resource package",
    "account is suspended", "account has been suspended",
    "exceeded_current_quota_error",
}

local PERMANENT = {
    "invalid api key", "invalid_api_key", "incorrect api key", "invalid key",
    "api key not found", "api key is missing", "no api key", "missing api key",
    "api key has been revoked", "key has been revoked",
    "invalid authentication", "authentication", "unauthorized",
    "model not found", "model_not_found", "no such model", "unknown model",
    "model does not exist", "does not exist",
    "unsupported model", "model is not supported",
}

local CONNECTION = {
    "connection reset", "connection refused", "connection closed",
    "connection error", "connection aborted", "connection timed out",
    "econnreset", "econnrefused", "etimedout", "enotfound", "eai_again",
    "epipe", "reset by peer",
    "socket hang up", "socket error", "socket closed",
    "dns", "tls", "ssl", "handshake", "upstream connect",
    "request ended without sending any chunks", "request failed",
    "max outbound streams", "outbound streams", "stream limit",
    "network error", "fetch failed", "timed out", "timeout",
    "broken pipe", "unexpected eof", "early eof",
}

-- Plain pay-as-you-go balance errors stay retryable: a top-up mid-loop can
-- resume them. Session limits, plan quotas and budgets do not self-resolve and
-- live in QUOTA instead.
local CREDIT = {
    "not enough credits", "insufficient credits", "insufficient credit",
    "insufficient balance", "insufficient funds", "out of credits",
    "no credits", "payment required",
    "exceeded your current token quota",
}

local REQUEST = {
    "bad request", "payload too large",
    "context length", "context_length_exceeded", "maximum context length",
    "too large",
}

local SERVER = {
    "rate limit", "rate_limit", "ratelimit", "too many requests",
    "overloaded", "internal server error", "bad gateway",
    "service unavailable", "server error", "temporarily unavailable",
    "try again later",
}

function M.is_retryable(kind)
    return RETRYABLE[kind or "unknown"] == true
end

function M.reason(kind)
    return REASONS[kind] or REASONS.unknown
end

-- Lower-case, straighten typographic apostrophes and collapse whitespace, so a
-- pattern does not have to guess which glyph a provider sends.
function M.normalize(text)
    if type(text) ~= "string" then return "" end
    local t = text:lower()
    t = t:gsub("\226\128\152", "'"):gsub("\226\128\153", "'")
    t = t:gsub("%s+", " ")
    return t:gsub("^%s+", ""):gsub("%s+$", "")
end

local function matches(text, patterns)
    for _, p in ipairs(patterns) do
        if text:find(p, 1, true) then return true end
    end
    return false
end

local function kind_of_status(status)
    if not status then return nil end
    if status == 401 or status == 403 then return "permanent" end
    if status == 402 then return "credit" end
    if status == 400 or status == 413 then return "request" end
    if status == 429 or status >= 500 then return "server" end
    return nil
end

-- Classify a failed attempt from its message text and optional HTTP status.
-- Text wins over status, so a 429 carrying `insufficient_quota` stops the loop
-- while a bare 429 is retried.
function M.classify(text, status)
    status = tonumber(status)
    local t = M.normalize(text)
    if t ~= "" then
        if matches(t, INTERRUPTED) then return "interrupted" end
        if matches(t, QUOTA) then return "quota" end
        if matches(t, PERMANENT) then return "permanent" end
    end
    local by_status = kind_of_status(status)
    if by_status then return by_status end
    if t ~= "" then
        if matches(t, CONNECTION) then return "connection" end
        if matches(t, CREDIT) then return "credit" end
        if matches(t, REQUEST) then return "request" end
        if matches(t, SERVER) then return "server" end
        return "unknown"
    end
    if not status then return "empty" end
    return "unknown"
end

-- Build the failure record api.stream returns and the loop interprets.
function M.failure(kind, message, status, retry_after)
    kind = kind or "unknown"
    return {
        kind = kind,
        retryable = M.is_retryable(kind),
        reason = M.reason(kind),
        message = message or "",
        status = tonumber(status),
        retry_after = tonumber(retry_after),
    }
end

-- Resolve the configured policy, falling back per value so a malformed retry
-- setting can never leave the agent without a schedule. A multiplier below 1
-- is treated as 1, which makes the schedule flat instead of collapsing.
function M.policy(cfg)
    local r = (cfg and cfg.retry) or {}
    local function positive(v, default)
        v = tonumber(v)
        if not v or v <= 0 then return default end
        return v
    end
    local multiplier = positive(r.multiplier, M.DEFAULTS.multiplier)
    if multiplier < 1 then multiplier = 1 end
    local max_attempts = tonumber(r.max_attempts)
    if max_attempts and max_attempts <= 0 then max_attempts = nil end
    return {
        base_delay_ms = positive(r.base_delay_ms, M.DEFAULTS.base_delay_ms),
        max_delay_ms = positive(r.max_delay_ms, M.DEFAULTS.max_delay_ms),
        multiplier = multiplier,
        max_failures_at_max_delay = positive(r.max_failures_at_max_delay,
            M.DEFAULTS.max_failures_at_max_delay),
        max_attempts = max_attempts,
    }
end

-- Per-turn state: the attempt that is running, how many waits at the cap have
-- already happened, and whether the empty-stop nudge was used.
function M.new_state()
    return { attempt = 1, failures_at_max_delay = 0, nudged = false }
end

function M.reset(state)
    state = state or M.new_state()
    state.attempt = 1
    state.failures_at_max_delay = 0
    state.nudged = false
    return state
end

-- The schedule wait, in seconds, for the n-th failed attempt (1-based), plus
-- whether it sits at the cap (which is what the cutoff counts).
function M.wait(p, attempt)
    local ms = p.base_delay_ms * (p.multiplier ^ (attempt - 1))
    if ms >= p.max_delay_ms then return p.max_delay_ms / 1000, true end
    return ms / 1000, false
end

-- Decide what to do with a failed attempt. Returns {action="retry", delay=…}
-- or {action="stop", …}. A server-provided Retry-After changes the duration of
-- the wait, never whether it counts toward the cutoff.
function M.verdict(p, state, failure)
    if not failure or not M.is_retryable(failure.kind) then
        return { action = "stop", kind = failure and failure.kind or "unknown" }
    end
    if p.max_attempts and state.attempt >= p.max_attempts then
        return { action = "stop", kind = failure.kind }
    end
    local delay, at_max = M.wait(p, state.attempt)
    if at_max then
        if state.failures_at_max_delay >= p.max_failures_at_max_delay then
            return { action = "stop", kind = failure.kind }
        end
        state.failures_at_max_delay = state.failures_at_max_delay + 1
    end
    if failure.retry_after and failure.retry_after > 0 then
        delay = failure.retry_after
    end
    return { action = "retry", delay = delay, at_max = at_max,
             kind = failure.kind, reason = failure.reason }
end

-- Hidden continuation messages. They are sent as user-role turns so no
-- provider is handed a trailing assistant message.
M.CONTINUE_TEXT = "Continue exactly where you left off, producing only the "
    .. "remainder of the answer. Do not repeat text you have already written."
M.EMPTY_TEXT = "Your previous response was empty. Produce your answer to the "
    .. "user's request now."
M.EMPTY_GIVEUP_MESSAGE = "model produced no output"

function M.continuation_text(kind)
    if kind == "empty" then return M.EMPTY_TEXT end
    return M.CONTINUE_TEXT
end

-- What to do with a finished attempt: "length" continues a truncated answer,
-- "empty" nudges an empty one once per turn, "empty_giveup" ends the turn, and
-- nil means the answer is complete. Tool calls take precedence over truncation.
function M.continuation_action(state, stop_reason, produced_text, produced_tools)
    if produced_tools then return nil end
    if stop_reason == "length" then return "length" end
    if stop_reason == "stop" and not produced_text then
        if state.nudged then return "empty_giveup" end
        state.nudged = true
        return "empty"
    end
    return nil
end

-- The message for the single error a stopped loop surfaces.
function M.terminal_message(failure, attempts)
    local text = failure and failure.message or nil
    if not text or text == "" then text = M.reason(failure and failure.kind) end
    local kind = failure and failure.kind
    if kind == "quota" then
        return "quota/usage limit exhausted; retries stopped: " .. text
    end
    if not M.is_retryable(kind) then return text end
    return "API failed after " .. tostring(attempts) .. " attempts: " .. text
end

return M
