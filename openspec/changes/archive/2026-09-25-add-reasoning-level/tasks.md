# Tasks

## 1. Config: level key and persistence

- [x] 1.1 Add `reasoning` to the defaults (top-level, `"off"`) and normalize
      it at load (unknown/missing → `off` without failing the session);
      verify with config tests: fresh config has `reasoning = "off"` and
      `reasoning = "turbo"` loads as `"off"`.
- [x] 1.2 Extend `PERSIST_KEYS` and the rewriter's top-level key matcher with
      `reasoning` (bootstrap file carries the key with a comment); verify
      with a persist test: writing `{ reasoning = "medium" }` updates only
      that line, preserves comments/unknown keys, and appends the key when
      the config has none yet.

## 2. OpenAI wire: request and stream

- [x] 2.1 Pass the level into the request builder: `api.lua` calls
      `P.build_request(messages, model, nil, cfg.reasoning)`; verify with a
      seam test that the adapter receives the level string (and `nil` when
      unset).
- [x] 2.2 `openai.build_request` injects `"reasoning_effort":"low|medium|high"`
      for a non-`off` level and omits the parameter for `off`/unknown;
      verify with body-assertion tests for all four levels plus the unknown
      value (off body byte-identical to today's).
- [x] 2.3 `openai.parse_sse_line` maps `delta.reasoning_content` and the
      `delta.reasoning` alias to `reasoning_delta` (unescaped once, never
      `text_delta`); verify with an SSE fixture test: reasoning chunk → one
      `reasoning_delta`, then a text chunk → `text_delta`.

## 3. Anthropic wire: request and stream

- [x] 3.1 `anthropic.build_request` sends `thinking: {type:"enabled",
      budget_tokens:N}` for non-`off` (4096/16384/65536) with
      `max_tokens = N + 4096`, and no `thinking` field for `off` (default
      `max_tokens` unchanged); verify with body-assertion tests for `off`,
      `low`, `medium`, `high`.
- [x] 3.2 `anthropic.parse_sse_line` maps `thinking_delta` →
      `reasoning_delta` and ignores `signature_delta`; verify with an SSE
      fixture test covering both event shapes.

## 4. UI: /think command, palette, footer

- [x] 4.1 Add `/think` to `SLASH_COMMANDS` and implement
      `execute_command("think", rest)`: valid level applies directly
      (`S.cfg.reasoning`, best-effort `config.persist_keys`, system row
      `→ мышление: <level>`), unknown level shows an error banner and
      changes nothing; verify with command tests for `high`, `turbo` and
      the persistence call.
- [x] 4.2 Bare `/think` opens palette mode `think` listing
      `off`/`low`/`medium`/`high` (current level marked in its
      description); Enter applies, Esc closes without changes; verify with
      palette tests for both keys.
- [x] 4.3 Footer right cell becomes `provider/model · <level>` (always,
      including `off`, whole cell dim); verify with footer tests: medium →
      cell ends `· medium`, off → cell ends `· off`, and the cell still
      ends in the row's last column when it fits.

## 5. Reasoning reaches the transcript

- [x] 5.1 End-to-end event path: `reasoning_delta` events through
      `handle_agent_event` produce one thinking entry whose row shows the
      joined body under the header (expanded) or the `think ▸ (Ctrl+T)`
      placeholder (collapsed), while `text_delta` still builds the
      assistant row only; verify with a transcript test asserting both rows
      and that the assistant text excludes the reasoning text.

## 6. Integration

- [x] 6.1 Full suite green: `rtk luac -p` on every touched file and
      `rtk lua tests/lua_tests.lua` exits 0 with no FAIL lines.
- [x] 6.2 Spec contract holds: `openspec validate add-reasoning-level`
      passes and the run confirms requests with `reasoning = "off"` are
      unchanged (existing request-body tests untouched and passing).
