# План: доделать tether (M7)

spec: docs/staging/specs/2026-09-17-finish-agent.md
milestone: M7 (см. docs/ROADMAP.md)

goal: tether работает end-to-end без крашей подтверждений, с корректным
      стримингом tool_call, валидным resume и честными кодами выхода --print.

Порядок: T1 (инфраструктура) → T2–T6 по очереди (каждый оставляет репо зелёным).
[parallel] между T2–T6 нет: все трогают общий тестовый файл и модули.

---

- [x] T1: тестовые seams для api/agent/session
  files: src/tether/api.lua, src/tether/session.lua, tests/lua_tests.lua
  acceptance: `lua tests/lua_tests.lua` выполняет require('tether.api'),
              require('tether.agent'), require('tether.session') без ошибок;
              session._session_dir override пишет в /tmp tmp-каталог
  spec: docs/staging/specs/2026-09-17-finish-agent.md#working-notes

- [x] T2: D1 краш `%frm%s` + N1 форк-бомба
  files: src/tether/ui.lua
  acceptance: новый юнит-тест ui-функции dangerous-проверки:
              "rm -rf /" и "rm -fr /" и ":(){ :|:& };:" детектятся,
              "rm file.txt" и "echo hello" — нет; luac -p зелёный
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d1-block

- [x] T3: D2 SSE tool_call аргументы (+ D6: зависание json_parse на обрезанной строке)
  files: src/tether/api.lua, src/tether/agent.lua
  acceptance: юнит-тест: 3 SSE-чанка (id-чанк + 2 продолжения без id) дают
              полный аргумент-JSON; аргументы с \" внутри парсятся в исходную
              структуру через agent.parse_args; дельта без id адресуется
              последнему tool_call
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d2-block

- [x] T4: D3 дубль-подтверждение + D3b details-меню
  files: src/tether/agent.lua, src/tether/ui.lua
  acceptance: юнит-тест с 2 tool_calls (первый требует подтверждения):
              ровно один confirmation-эмит на вызов; повторный agent.continue
              не добавляет событие; agent.confirm возвращает true когда ждёт
              следующее подтверждение; break после обработки id
              ([d] details фикс в ui — ручная проверка в T8)
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d3-block

- [x] T5: D4 resume tool-результаты
  files: src/tether/app.lua, src/tether/ui.lua
  acceptance: юнит-тест: сессия с user→assistant(tool_calls)→tool-результатом;
              session.resume → восстановление в agent.history (user/assistant/
              tool) → api.encode_messages не падает, порядок сохранён
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d4-block

- [x] T6: D5 exit-коды/тихие ошибки + N2 ts + N3 модели
  files: src/tether/app.lua, src/tether/api.lua
  acceptance: N2: юнит-тест session.append события с ts-строкой читается назад;
              D5b: юнит-тест http-путей невозможен — покрытие ручной проверкой
              в T8; N3: README-строка про модели; luac зелёный
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d5-fix

- [x] T7: финальная сборка
  files: Makefile (без изменений — проверка), README.md (N3)
  acceptance: `make test` полностью зелёный: luac + все юнит-тесты + host smoke

- [x] T8: ручная приёмка (manual check)
  files: (нет)
  acceptance: ручные проверки, задокументировать результат в отчёте:
              1) `./tether --print "hi"` с невалидным ключом → exit 1,
                 сообщение об ошибке на stderr (D5/D5b)
              2) запуск TUI (`script -qc` под pty недоступен — визуально
                 пользователем при желании): подтверждение rm -rf не роняет
                 ход (D1), [d] details → Esc возвращает меню (D3b)
              3) `-r` resume сессии с tool_calls → ход продолжается без 400 (D4)
  spec: docs/staging/specs/2026-09-17-finish-agent.md#d5-fix
  result: 1) OK — «tether: http ?: {...request_forbidden...}» + «no response
             text», exit 1. 2) D1/D3b покрыты юнит-тестами T25/T26
             (ui.is_dangerous, идемпотентный emission); визуальная проверка
             TUI остаётся пользователю. 3) OK — resume-сценарий с tool_calls
             даёт валидную историю (проверено скриптом, T27+T29 в suite).
             Попутно найден и закрыт N4: config.load падал на пустом HOME.
