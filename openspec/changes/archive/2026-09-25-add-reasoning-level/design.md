# Design

## Context

The plumbing for reasoning already exists above the provider layer:
`api-client`/`agent-core` specced `reasoning_delta` as a canonical event, the
agent forwards it with attempt tags, `transcript.lua` builds thinking entries
from it and `ui.lua` renders them (`thinking · Ns ▾`, Ctrl+T visibility,
`ui.thinking` collapsed/expanded). What is missing is the bottom layer — no
adapter sends a reasoning parameter and no stream parser reads reasoning
chunks — plus a way for the user to choose the level and see it.

Constraints that shaped the approach:

- `api.lua:339` calls the adapter as `P.build_request(messages, model, nil)`
  with no `cfg`; every adapter (openai, anthropic, gemini, Tier-B) shares that
  signature.
- `config.lua` machine-writes picks through `persist_keys`, whose
  `PERSIST_KEYS` whitelist and top-level key matcher currently know only
  `provider`/`model` (byte-preserving rewriter, spec `config`).
- The footer's right cell is built in one place
  (`render_footer` → `M.footer_stats(left, dim(model_cell), width)`), and
  `footer_stats` right-truncates the right cell from its left, so the tail of
  the cell is what survives narrow rows.
- Default `ui.thinking = "collapsed"` is specced; reasoning rows are therefore
  hidden by default and show the `think ▸ (Ctrl+T)` placeholder.

## Goals / Non-Goals

**Goals:**

- One user-facing level (`off`/`low`/`medium`/`high`) that flows: config →
  `/think` → request body → stream → thinking row → footer.
- Wire-level support for exactly the two in-scope wires (openai,
  anthropic), including the anthropic `max_tokens` interaction.
- Persistence of the level across restarts under the existing
  byte-preserving writer.

**Non-Goals:**

- Mapping the level for gemini / Tier-B wires (bedrock, vertex, azure, codex,
  radius) — the level is accepted and displayed but not sent; a follow-up
  change wires them.
- Per-provider raw parameters (`budget_tokens` numbers, per-model effort
  matrices) and capability flags in the catalog.
- Persisting reasoning text into history, journal or resume (reasoning is
  display-only; a resumed session shows no thinking rows).
- Flipping the specced `ui.thinking` default from `collapsed`.

## Decisions

1. **`cfg.reasoning` is a top-level key, normalized at load.**
   It drives request bodies like `model` does, so it does not belong under
   `ui`; unknown/missing values normalize to `off` once at config load, which
   lets every consumer (request builder, footer, palette) trust the value.
   Alternative: normalize at each use — rejected, four call sites with four
   chances to diverge.

2. **Adapter contract: optional 4th argument = the reasoning level.**
   `api.lua` calls `P.build_request(messages, model, nil, cfg.reasoning)`.
   Lua silently ignores extra arguments, so gemini/Tier-B adapters keep
   working untouched, and no adapter receives the whole `cfg` table — which
   matters because `cfg` can carry the resolved API key. Alternatives
   considered: passing `cfg` (rejected: credential surface), a per-request
   state table in the provider module (rejected: hidden state, hostile to
   tests).

3. **Level mapping.**
   - openai wire: `"reasoning_effort":"low|medium|high"`, omitted for `off`
     (chat-completions shape, accepted by openai-compatible gateways incl.
     agnes).
   - anthropic wire: `thinking = {type:"enabled", budget_tokens:N}` with
     N = 4096 / 16384 / 65536 (4× steps, all ≥ the API minimum), and
     `max_tokens = N + 4096`. The `max_tokens` raise is mandatory, not a
     nicety: the adapter's default is 4096, which is smaller than every
     budget, and Anthropic rejects `budget_tokens >= max_tokens`.
   Alternative: a flat `max_tokens` bump for all levels — rejected, it
   silently widens the completion window for `off`.

4. **Stream parsing stays with the existing heuristics.**
   openai's chunk scanner gains `reasoning_content` (and the `reasoning`
   alias) next to `content`, unescaped once through the existing
   `json_unescape`; anthropic maps `thinking_delta` → `reasoning_delta` and
   ignores `signature_delta`. Alternative: switch to a full JSON decode per
   chunk — rejected, the scanner pattern is the established, ADR-backed
   approach and the addition is local.

5. **Runtime state lives in `S.cfg.reasoning`; persistence reuses
   `config.persist_keys`.**
   `PERSIST_KEYS` grows `reasoning` and the rewriter's top-level key matcher
   learns the third key; a missing `reasoning =` line is appended before the
   top-table close exactly like a missing `provider`/`model`. Alternative:
   a side file — rejected, `config.lua` is the specced machine-written store.

6. **UI: `/think` mirrors `/model`.**
   One `SLASH_COMMANDS` entry; `execute_command("think", rest)` applies a
   valid level directly, shows an error banner for an unknown one, and with
   no argument opens palette mode `think` listing the four levels (current
   one marked in its description). Applying sets `S.cfg.reasoning`, persists
   best-effort, and appends the system row `→ мышление: <level>` — the same
   shape as `→ модель:`.

7. **Footer cell: append ` · <level>` inside the existing right cell.**
   `provider/model · medium` is passed to `footer_stats` unchanged, so the
   existing narrow-row behavior (right cell truncated from its left) already
   protects the level label at the tail and drops the model name's start
   first. The whole cell stays dim. Alternative: a third block joined with
   ` · ` on the left side — rejected, the spec defines the level as part of
   the right cell and it must not steal width from path/stats.

8. **History stays answer-only by construction.**
   `agent.run_attempt` accumulates `text_acc` from `text_delta` only;
   `reasoning_delta` is forwarded and dropped, so no agent, journal or
   resume change is needed.

## Risks / Trade-offs

- [A gateway rejects `reasoning_effort`/`thinking` with a 400] → the
  parameter is only sent when the level ≠ `off`, so the default path is
  byte-identical to today; the failure surfaces as a normal attempt failure
  and the fix is `/think off`. A catalog capability flag is the follow-up.
- [Anthropic `max_tokens = budget + 4096` exceeds a low-context endpoint's
  limit] → the fixed mapping is documented in the spec and the error names
  itself; revisit with per-model limits only if it bites.
- [Large reasoning bodies bloat the transcript] → default
  `ui.thinking = "collapsed"` renders one placeholder row per attempt; the
  row cache keys on entry version, so expanding pays only on toggle.
- [`persist_keys` misses a `reasoning` line nested deeper than the top
  level] → same fail-closed behavior as today: in-memory pick applies, file
  untouched.
- [Reasoning row order vs. text row: some gateways interleave] →
  transcript entries are role-based (first reasoning delta opens the
  thinking entry, first text delta opens the assistant entry), so
  interleaving degrades to adjacent rows, not corruption.

## Migration Plan

None: `reasoning` defaults to `off` (requests unchanged), existing configs
load untouched, and the key appears in `~/.tether/config.lua` only when the
bootstrap creates a fresh file or the user first picks a level. Rollback is
a no-op — remove the `/think` entry and the parameter stops being sent.

## Open Questions

- Whether `ui.thinking` should flip to `expanded` now that reasoning is
  actually reachable — defer until the placeholder row has been used in
  practice; flipping touches the specced config default and belongs to its
  own change.
