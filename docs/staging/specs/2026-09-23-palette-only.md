# Спека: palette-only — убрать overlays, всё через palette

date: 2026-09-23 · см. docs/ROADMAP.md
spec-base: docs/staging/specs/2026-09-17-tui-ux.md (M8/M9, закрыты)

## Контекст

`ui.lua` (~4900 строк) держит два параллельных механизма модального UI:
palette (dropdown под input: command/path/copy/login) и full-screen overlays
(`resume`, `model`, `diff`, `error`, login-диалог). Дублируется key-handling,
sel/items, закрытие по Esc. Overlays `diff`/`error` по продуктовой оценке
не нужны; `resume`/`model` — списки, которые уже умеет palette.

## Контракт

```
contract:  В TUI нет S.overlay / render_overlay / handle_overlay_key /
           M._set_overlay. Единственный модальный механизм — palette
           (palette_mode + palette_items + palette_sel) под input.
           login-секрет — отдельный masked-буфер + маскированный рендер
           input, не S.input, не overlay.
invariant: SLASH_COMMANDS = 9 (счётчики T39/T69/T71/T79/T83 не меняются);
           секреты/токены не в S.input, не в transcript, не в frame
           (только mask); confirmation-меню (allow/deny/…) сохраняется
           для outside-workspace write/patch/run; полный текст ошибки
           не пишется в чат.
test:      make test (единый lua_tests + luac -p по всем модулям);
           новые/переписанные юниты на resume/model palette-режимы,
           masked login-ввод, баннер ошибки без overlay, отсутствие
           опции details в confirmation.
convention: state — поля S; логика — locals в ui.lua или отдельный модуль
            по паттерну transcript/confirm_policy (configure-инъекция);
            каждый новый встраиваемый модуль = строка в Makefile LUA_MODS,
            embed-args и main.c mods[]; тесты — существующие seams
            (_execute_command, _handle_key, _get_state, _paint, _row).
```

## Решения

### R1. Удалить infra overlays полностью

- Вырезать: `S.overlay`, `S.overlay_data`, `render_overlay`, `overlay_full`,
  `handle_overlay_key`, `M._set_overlay`, ветки `if S.overlay then …` в
  `handle_key` / key-pump / mouse / caret.
- Бэкенды, которые были overlay-only, либо переезжают (R2), либо уходят (R3/R4).

### R2. Списки → palette-режимы

- **`/resume`** → `palette_mode = "resume"`: items из `commands.list_sessions`,
  Enter → `commands.resume` + `transcript.seed` (как сейчас в overlay-ветке),
  Esc закрывает, ↑↓/mouse как у copy/login.
- **`/model`** → `palette_mode = "model"`: items из `commands.list_models`,
  Enter → `S.model_name` + system-строка, Esc закрывает.
- Механика — общий паттерн `_in_*_palette` (как `_in_copy_palette` /
  `_in_login_palette`): `palette_sync` no-op, items задаются явно.

### R3. diff overlay и опция details — удалить

- Подтверждение **не для diff**: confirmation-меню остаётся только для
  outside-workspace write/patch/run (`confirm_policy.should_confirm`).
- Удалить опцию меню `details` / клавиши `[4]`/`[d]` и `CONFIRM_DIGITS[4]`
  → `nil`/сдвиг; ветку `decision == "details"` и `S.overlay = "diff"`.
- Полный diff/args смотреть не нужно отдельным окном: projected diff уже
  рисуется на pending tool-записи в transcript; result-body — по expand.
- `overlay_full("diff", …)` и `ov == "diff"` уходят вместе с R1.

### R4. error overlay — удалить; баннер + debug-лог

- Остаётся one-line `error_banner` (`render_error_banner`).
- **Не** открывать overlay по Enter на баннере; Enter/Esc баннера = очистить
  баннер (иначе submit блокируется навсегда — см. архив fix-error-overlay).
- Полный текст ошибки: при событии `error` — `slog`/debug-лог, если
  `--debug` или `cfg.debug`; **в transcript не писать**.
- `ov == "error"`, ветка `k.kind == "enter" and S.error_banner → overlay` —
  удалить.

### R5. login-диалог → masked input + palette-hints (без overlay)

- Состояние: `S.secret = { provider, flow, buf }` (или поля `S.login_*` +
  отдельный буфер; **не** `S.input`, **не** `overlay_data`).
- Рендер input: при активном secret-режиме показывать `*`×len(buf),
  плейсхолдер/заголовок — строка `login <provider>` (в rule/label input).
- Клавиши: text/paste/backspace → `buf`; Enter → `submit_login_secret(buf)`;
  Esc → `cancel_login()`; секрет не попадает в history/palette_sync/chat.
- Palette в secret-режиме: статические hints (authorize URL, «вставьте
  redirect/code», Enter/Esc) как items **без** выбора — или пустой palette
  + подсказка в footer. Выбор провайдера — уже `palette_mode = "login"`
  (picker остаётся).
- После submit/cancel — выйти из secret-режима, `palette_mode = "command"`.

### R6. confirmation-меню — остаётся (вариант A)

- Меню allow / session / always / deny / cancel + digit-map (без details).
- `resolve_confirmation("details")`, `S.overlay = "diff"` — удалить.
- Pending projection на tool-записи — без изменений (spec tui
  Pending change preview).

### R7. Спецификационный след (openspec — отдельным change при реализации)

- `openspec/specs/tui`: requirement «Error banner and overlay» → только
  banner; убрать modal-overlay поведение. Убрать/поправить упоминания
  overlay как механизма (caret «while overlay open» → «while palette owns
  keyboard» и т.п. по факту кода).
- confirmation details / diff overlay requirements — удалить или сузить.
- Архивные specs не трогать.

## Out of scope

- Перенос palette в отдельный `palette.lua` (возможен следующим cut'ом;
  здесь — убрать overlays, оставить palette внутри `ui.lua`).
- Изменение policy outside-workspace / auto_approve / allow_outside_workspace.
- ask-block (это transcript tail, не overlay).
- Клавиатурные сокращения команд, fuzzy-ранжирование, mouse hit-test palette.

## Риски / trade-offs

- [Долгий error без полного текста в чате] → баннер + debug-лог; полный
  текст уже classified в agent/retry.
- [login-секрет в input-режиме течёт в S.input] → отдельный буфер,
  masked render, unit-тесты isolation (T153/T156-подобные).
- [resume/model UX меняется с full-screen на dropdown] → длинные списки
  сессий прокручиваются palette-окном (≤8 + индикатор) — приемлемо.
- [Слом тестов на overlay] → переписать соответствующие assert'ы на
  palette_mode / баннер / отсутствие details.

## Working notes

- Открыто: footer-подсказка в secret-режиме login — item-hints в palette
  или одна строка в rule input; решить при impl, оба варианта проходят
  инварианты (секрет не в chat, не в frame plaintext).
- `CONFIRM_DIGITS` после удаления details: 5 опций, цифры 1..5
  (allow, session, always, deny, cancel) — порядок уточнить в impl,
  чтобы digit-map не съехал на details.
