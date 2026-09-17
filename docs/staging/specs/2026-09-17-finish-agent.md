# Спека: доделать tether до полноценной работы

date: 2026-09-17 · milestone: M7 (см. docs/ROADMAP.md)

## Контекст

`make test` зелёный (61/61, luac ok, host smoke ok), но при сплошном ревью кода
найдены дефекты, ломающие реальные сценарии: краш при подтверждении `rm -rf`,
потеря аргументов tool_call при стриминге, невалидная история после resume.
Это последний этап перед «полноценно работает из коробки».

## Контракт

```
contract:  ./tether (TUI) и ./tether --print "..." работают end-to-end:
           стрим ответа, вызовы инструментов (в т.ч. многочанковые аргументы),
           подтверждения, resume; коды выхода --print соответствуют tech-spec.
invariant: подтверждение/отказ не дублирует меню; resume даёт валидную для
           OpenAI-контракта историю; stderr без Lua-ошибок на опасных командах.
test:      make test + новые юнит-тесты в tests/lua_tests.lua.
```

## Дефекты

### D1 (BLOCK). Crash «%frm%s» — ui.lua:1061

- `body:match("%frm%s")` — невалидный Lua-паттерн (`%f` — boundary-префикс).
- Ход: подтверждение команды с `rm -rf` → Lua-ошибка внутри handle_agent_event →
  pcall(agent.turn) гасит ход, пользователь видит banner вместо работы.
- Фикс: заменить проверку `rm` на валидные паттерны обоих порядков флагов:
  `rm%s+%-[a-z]*r[a-z]*f` и `rm%s+%-[a-z]*f[a-z]*r` (ловят `-rf`, `-fr`, `-Rf`…).
- test: юнит-тест dangerous-паттернов (отдельная функция в ui или экспорт).

### D2 (BLOCK). Потеря/порча аргументов tool_call при стриминге — api.lua

Два под-дефекта в `parse_sse_line`:

- **D2a**: второй gmatch требует `"id":"..."` в чанке. Провайдеры стримят
  аргументы в несколько чанков: в продолжениях `id` отсутствует →
  `tool_call_delta` не эмитится → аргументы обрезаются → инструмент получает
  пустой/битый JSON (`parse_args` возвращает `{}`).
- **D2b**: api.lua сам разэкранирует фрагмент (`\"`→`"`, `\\n`→новая строка),
  затем agent.parse_args прогоняет результат через json_parse, который ожидает
  **экранированный** JSON. Любая экранированная кавычка внутри аргументов
  (`{"path":"a\"b"}`) даёт невалидный JSON → пустые аргументы.

Фикс:
- api.lua: эмитить **сырой** (не разэкранированный) фрагмент аргументов; матчить
  фрагменты `"arguments":"..."` без требования `id`; `ev.id` отсутствует → nil.
- agent.lua: дельту без id адресовать последнему незавершённому tool_call
  (`ordered[#ordered]`); экранирование снимает ровно один раз json_parse.
- Экспортировать `api.parse_sse_line` как `M.parse_sse_line` для тестов.
- test: накопление аргументов из 3 чанков (id-чанк + 2 продолжения), фрагмент
  с `\"` внутри; итоговый parse_args даёт исходную структуру.

### D3 (BLOCK). Дублирование подтверждения + отсутствующий break — agent.lua/ui.lua

- `agent.confirm` возвращает `drive_pending(...) == false`, т.е. true = «появилось
  новое подтверждение». ui.resolve_confirmation игнорирует возврат и всегда
  вызывает `agent.continue`, который дергает drive_pending повторно → меню
  одного и того же вызова рендерится/эмитится дважды.
- В confirm-цикле нет `break` после обработки целевого id (безвредно при
  уникальных id, но хрупко; после D2 id уникальны — фикс попутный).
- Фикс (агентная сторона, тестируемо): drive_pending делает emission
  идемпотентным — флаг `call.confirm_emitted`, повторный drive_pending не
  переэмитит `confirmation` для уже показанного вызова. UI тогда может
  спокойно вызывать continue. Плюс `break` после обработки id в M.confirm.
- **D3b**: ветка `[d] details` в ui.resolve_confirmation затирает
  S.confirmation до `{label="",body="",options={}}`, а
  S.pending_confirmation_restore никогда не устанавливается → после Esc из
  diff-оверлея пользователь видит пустое меню, в котором Enter = allow
  (нежелательное исполнение инструмента).
  Фикс: в details-ветке не трогать S.confirmation вообще; Esc закрывает
  оверлей, меню остаётся как было.
- test: юнит-тест confirm-очереди с двумя вызовами (один подтверждается,
  второй ждёт) — assert: ровно один confirmation-эмит на вызов, повторный
  agent.continue не добавляет событие; confirm возвращает true, когда ждёт
  следующее подтверждение.

### D4 (BLOCK). Resume даёт невалидную историю — app.lua / ui.lua

- `session.resume` возвращает и tool-сообщения, но оба пути resume
  (app.lua `-r`, ui overlay /resume) восстанавливают user/assistant, причём
  assistant с tool_calls добавляется **без** следующих tool-результатов.
  OpenAI-контракт: каждый tool_call требует tool-результат → такой истории
  API отклоняет запрос (400) при первом же turn после resume.
- Фикс: в обоих путях восстанавливать `role=="tool"` через
  `agent.add_tool_result(msg.tool_call_id, msg.content or "")`.
- test: session.resume → сборка истории → `api.encode_messages` не падает и
  последовательность assistant(tool_calls)→tool соблюдена.

### D6 (BLOCK, найден при T3). Зависание json_parse на обрезанной строке — agent.lua

- `s:sub(pos,pos)` возвращает `""` (не nil) за концом строки; строковый цикл
  парсера проверял `ch == nil` → бесконечный цикл на незакрытой строке
  (например, обрезанный tool_call-аргумент подвешивал агент навсегда).
- Фикс: `if pos > #s then break end` перед чтением символа.
- test: покрыт T24 (parse_args на обрезанном фрагменте завершается).

### D5 (FIX). --print/ошибки API: коды выхода и тихие ошибки — app.lua/api.lua

- tech-spec/README: «exit 0 (ok) / 1 (error or empty)». Код: `exit 1` только
  при `had_error`; пустой ответ без ошибки → exit 0.
- **D5b**: не-SSE тело ошибки (например, 401 JSON) не порождает error-события:
  parse_sse_line молча пропускает строки без `data: `, а http_request возвращает
  ok=true → и TUI, и --print молча показывают пустоту.
  Фикс: в http_request, если тело не SSE и не retryable — эмитить
  `on_event({type="error", message="http <status>: <первые 200 байт тела>"})`.
- Фикс D5: `last_text == ""` → stderr-сообщение + exit 1 (независимо от had_error).
- test: юнитом не покрывается (нужен живой HTTP) — ручная проверка в acceptance:
  `./tether --print "hi"` с невалидным ключом/URL → exit 1 и сообщение об ошибке.

## Допилы (NIT, попутно)

- **N1** ui.lua dangerous-check: форк-бомба — паттерн `:()%{%}:|:` не матчит
  `:(){ :|:& };:`; заменить на проверку `:%(%)%{` (или `:%(%)`).
- **N2** app.lua: `ts = os.date("*t")` (таблица) в session_end — сериализуется
  как объект-словарь, неконсистентно со строковым ts в остальных событиях.
  Заменить на `os.date()` в двух местах (print-режим и TUI-выход).
- **N3** api.list_models() — захардкожен gpt-4o*; расширить список
  (gpt-5*, o3/o4-mini, deepseek-*, qwen*) и добавить строку в README:
  «список моделей зависит от вашей API; задайте cfg.model».
- **N4 (найден при T8)** config.load вызывал результат loadfile без проверки:
  на свежей установке без ~/.tether/config.lua — crash «attempt to call a
  nil value (local 'result')» вместо тихих дефолтов. Закрыт: проверка chunk
  + pcall при вызове.

## Инварианты (фиксируем, не проверяем автотестом)

- API-ключ не попадает в argv (header-файл chmod 600, api.lua) — не регрессировать.
- `load` не используется (ADR 2026-09-17-lua-json-parser) — не регрессировать.
- workspace-boundary: write/patch/run вне workspace требуют подтверждения.

## Working notes

- build: vendor/lua-5.4.6 в репо, бинарник собирается, `make`/`make test` зелёные.
- `%frm%s` крэш проверен запуском: `lua -e '("x"):match("%frm%s")'` → error.
- D3: перепроверено — `call.done` ставится безусловно после run_tool_call,
  вечного цикла нет; реальная проблема — двойной drive_pending (см. D3).
- agent.lua и session.lua дублируют json_parse (~90 строк) — **deferred**:
  вынесение в общий модуль меняет embed-порядок; не в этом заходе.
- Тестируемость: api.parse_sse_line экспортируется (M.parse_sse_line);
  agent-тесты требуют заглушку `tether` (getcwd/realpath/exec) и `tools` —
  в tests/lua_tests.lua заглушки уже частично есть, дополнить минимально.
- Seam для D4-теста: session.lua получает `M._session_dir` override
  (session_path/ensure_dir учитывают его), тесты пишут в /tmp,
  прод-поведение не меняется.
- Тестам нужен package.path = "src/?.lua;..." для require('tether.api').
- «Полноценно» = перечисленные дефекты закрыты, end-to-end TUI + --print
  работают; PTY/фон/git/LSP остаются в Deferred (tech-spec).

## Out of scope

- Deferred из tech-spec (PTY, фоновые задачи, git, LSP, темы, векторная память).
- Общий json-модуль (dedup agent/session) — deferred.
- Anthropic/Google адаптеры.
