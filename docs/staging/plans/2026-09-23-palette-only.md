# Plan: palette-only

spec: `docs/staging/specs/2026-09-23-palette-only.md`  
Файлы правок: `src/tether/ui.lua`, `tests/lua_tests.lua`,  
`docs/design.md`, `README.md`, `docs/tech-spec.md`,  
`openspec/changes/remove-overlay-ui/` (delta по R7).

Общий acceptance каждого task: `lua tests/lua_tests.lua` exit 0,  
затем по завершении набора — `make test`.

---

## 1. Убрать ненужные overlay-бэкенды

- [x] T1: error — только баннер + debug-лог (R4)
  - goal: Enter/Esc на `error_banner` очищает баннер; полный текст error-события уходит в slog/debug при включённом логировании, не в transcript; `ov == "error"` и ветка `enter → overlay` удалены.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: unit — после error-события с `cfg.debug` в логе есть полный текст, в transcript нет; `_handle_key(enter)` на баннере: баннер `nil`, overlay не открыт; существующие T-тесты баннера зелёные.
  - spec: `…-palette-only.md` §R4

- [x] T2: confirmation без details/[d] (R3/R6)
  - goal: из меню удалены опция `details` и клавиши `[4]`/`[d]`; `CONFIRM_DIGITS` и `resolve_confirmation("details")` / `S.overlay = "diff"` вырезаны; allow/session/always/deny/cancel и digit-map 1..5 (без details) работают.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: unit — digit `4`/`d` не открывает details; `d` не трактуется как details; allow/deny по-прежнему резолвят; T33/T141-style тесты меню зелёные с новым набором опций.
  - spec: `…-palette-only.md` §R3, §R6

- [x] T3: удалить diff overlay (R3)
  - goal: `overlay_full("diff", …)`, `ov == "diff"`, `q`-закрытие и `S.overlay = "diff"` отсутствуют; projected diff смотрят только на tool-записи transcript (pending preview / expand result).
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: grep `overlay.*diff|ov == "diff"` пуст в `src/tether`; unit — открытие details невозможно (уже из T2), paint-тесты pending projection (2.2/4.5) зелёные.
  - depends: T2
  - spec: `…-palette-only.md` §R3

## 2. Списки → palette

- [x] T4: `/resume` → `palette_mode = "resume"` (R2)
  - goal: items из `commands.list_sessions`; Enter → resume + `transcript.seed` + system-строка; Esc/↑↓/mouse-клик как у copy/login; `_in_resume_palette` (или общий helper) — `palette_sync` не перетирает.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: unit — `_execute_command("resume")` даёт `palette_mode == "resume"`, `overlay == nil`, список не пуст при наличии сессий; Enter на выбранной сессии: `S.session_id` обновлён, palette закрыта; Esc — без побочных эффектов.
  - spec: `…-palette-only.md` §R2

- [x] T5: `/model` → `palette_mode = "model"` (R2)
  - goal: items из `commands.list_models`; Enter → `S.model_name` + system-строка `→ модель: …`; Esc/↑↓/mouse как в T4.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: unit — `_execute_command("model")`: `palette_mode == "model"`, items непустые (stub `list_models`); Enter меняет `S.model_name`, закрывает palette; `overlay == nil`.
  - spec: `…-palette-only.md` §R2

## 3. login без overlay

- [x] T6: login-секрет → masked input + palette-hints (R5)
  - goal: состояние секрета — отдельный буфер (`S.secret` / `S.login_*` + `buf`), не `S.input`, не `overlay_data`; рендер input маскирует (`*`×len); text/paste/backspace → буфер; Enter → `submit_login_secret`; Esc → `cancel_login`; picker провайдеров остаётся `palette_mode = "login"`; после submit/cancel — `palette_mode = "command"`, буфер пуст.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: unit — T153/T155/T156 переписаны: секрет в буфере, не в `S.input`/transcript; frame содержит mask и не plaintext; Esc cancel без store; после Enter store 0600 (как сейчас); `S.overlay == nil` всегда в login-путях.
  - spec: `…-palette-only.md` §R5

## 4. Вырезать infra

- [x] T7: удалить overlay-infrastructure (R1)
  - goal: нет `S.overlay`, `S.overlay_data`, `render_overlay`, `overlay_full`, `handle_overlay_key`, `M._set_overlay`; нет `if S.overlay then` в `handle_key`, key-pump, mouse, caret-гейтах (caret/pump — по факту: modal-владение теперь confirmation/ask/palette/secret).
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua`
  - acceptance: grep `S.overlay|render_overlay|handle_overlay_key|_set_overlay` пуст в `src/`; все тесты, трогавшие overlay, переписаны на palette/secret/баннер; `lua tests/lua_tests.lua` exit 0.
  - depends: T1, T3, T4, T5, T6
  - spec: `…-palette-only.md` §R1

## 5. Приёмка и docs

- [x] T8: полный прогон + зачистка мёртвых ссылок
  - goal: `make test` green (luac по всем `LUA_MODS`, lua_tests, context, e2e, host); в `src/tether` нет упоминаний удалённых symbols; KEYMAP/footer-подсказки без `details`/`overlay`.
  - files: `src/tether/ui.lua`, `tests/lua_tests.lua` (если что-то всплыло)
  - acceptance: `make test` exit 0; `rtk grep` overlay/details в `src/tether` — 0 hits.
  - depends: T7

- [x] T9: docs + openspec delta (R7)
  - goal: `docs/design.md` §6 (регионы, overlays → palette, баннер ошибки, confirmation без details), `README.md`, `docs/tech-spec.md` — без «overlays» как механизма; создан `openspec/changes/remove-overlay-ui/` с proposal/design/tasks + deltas: `tui` (Error banner без overlay, palette-only, confirmation без details), при необходимости `provider-auth` (login masked input, не dialog overlay); `openspec validate remove-overlay-ui` = valid.
  - files: `docs/design.md`, `README.md`, `docs/tech-spec.md`, `openspec/changes/remove-overlay-ui/**`
  - acceptance: `openspec validate remove-overlay-ui`; ручной grep docs от «overlay» в описании текущего TUI (архивные openspec не трогать).
  - depends: T8
  - spec: `…-palette-only.md` §R7

---

Не входит (spec out of scope): перенос palette в `palette.lua`, изменение confirm policy, ask-block.
