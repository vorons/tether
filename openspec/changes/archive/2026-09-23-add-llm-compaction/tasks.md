# Tasks

## 1. Config and trigger

- [x] 1.1 Add `context.reserve_tokens` (16384) and `context.keep_recent_messages` (4) defaults in `config.lua`; unit-test defaults and malformed-value fallback (`tests/lua_tests.lua`)
- [x] 1.2 Change `should_summarize` to fire on fraction OR reserve threshold using the new config keys; unit-test both thresholds and the OR semantics
- [x] 1.3 Parameterize keep-window size from `keep_recent_messages` while preserving tool-boundary walk-back; extend existing compression unit tests

## 2. LLM summary path

- [x] 2.1 Add a one-shot summary helper (dedicated messages array, accumulate `text_delta`, single transport retry, empty-output detection) next to `api.stream`; unit-test success, transport failure, and empty output with a stubbed provider
- [x] 2.2 Serialize the old span (role prefixes, tool-result truncation) and build the structured summary prompt (goal/constraints/progress/decisions/next steps + optional focus); unit-test serialization bounds
- [x] 2.3 Wire compaction: LLM success → summary system message + `context_compressed{mode="llm"}`; failure → truncation fallback + `mode="truncation"`; no `error` event; unit-test both paths including keep-window pairing
- [x] 2.4 Confirm compaction does not run between main-loop retry attempts (existing scenario still green) and that the summary call does not mutate main retry state

## 3. Manual /compact

- [x] 3.1 Extend `commands.compact` (or successor) to accept focus text and force-bypass the threshold; unit-test no-op when history is only system+keep window
- [x] 3.2 Parse optional free text after `/compact` in the UI command path; transcript row shows LLM summary or `── summary ──` fallback; unit-test command parsing and row text
- [x] 3.3 Update `transcript` handling of `context_compressed` if `mode` needs a dim label; keep ASCII mode clean

## 4. Verification

- [x] 4.1 Run `make test` (luac, unit, e2e, host smoke) green
- [x] 4.2 Manual: long session hits reserve threshold, summary appears, next turn still coherent; kill network mid-`/compact` → fallback row, no error banner
