# tether — design doc

**Версия:** 0.1.0 (MVP) · **Лицензия:** MIT

## 1. Цели

Терминальный кодинг-агент с интерактивным TUI, аналог Claude Code и Codex, реализованный на Lua. Один бинарник без внешних runtime-зависимостей, кроме `libc` и (в HTTPS-режиме) системного `curl`. Работа в workspace, инструменты чтения/записи/поиска/shell/patch, стриминг ответа модели, подтверждения опасных действий, возобновляемые сессии.

## 2. Не-цели MVP

- Anthropic и Google API — контракт адаптера закладывается, реализация позже.
- Вкладки, темы, мультисессии, плагины, векторная память, in-app drag-selection.
- Интерактивный PTY, фоновые задачи, git-интеграция, LSP.
- Windows вне WSL.

## 3. Целевые платформы

Linux x86_64, macOS arm64/x86_64. Терминалы: xterm-256color, tmux, kitty, wezterm, foot, alacritty, Ghostty, Windows Terminal (в WSL).

## 4. Архитектура

```
┌─────────────────────────────────────────────────────────┐
│  C-хост (src/host)                                      │
│  main · term (raw mode, ANSI) · spawn (fork/exec/pipe)  │
│  http (curl subprocess + SSE reader)                    │
│  embed (C-массивы Lua-модулей)                          │
├─────────────────────────────────────────────────────────┤
│  vendored: Lua 5.4.6 · luasystem · terminal.lua         │
├─────────────────────────────────────────────────────────┤
│  Lua-ядро (src/tether)                                  │
│  app · ui · agent · api · tools · session · config      │
└─────────────────────────────────────────────────────────┘
```

C-хост даёт Lua узкий syscall-API: raw mode, `ioctl(TIOCGWINSZ)`, `fork/exec/waitpid/pipe`, чтение stdout/stderr, `realpath`, `stat`, запуск `curl`. Вся логика — на Lua.

## 5. Компоненты

**app** — точка входа, разбор CLI (`--resume/-r`, `--workspace/-w`, `--model/-m`, `--print/-p`, `--debug/-d`, `--version/-v`), выбор режима TUI(по умолчанию)/print.

**config** — загрузка `~/.tether/config.lua`, merge с CLI-флагами, значения по умолчанию.

**ui** — TUI: транскрипт, ввод, hint, статус-строка, палитры, confirmation, diff/help/log overlays, стриминг. Детали — §6.

**agent** — цикл LLM → tool calls → выполнение → tool results → LLM. Лимит итераций 50 (настраивается). Системный промпт: канонический coding-agent, переопределяется `system_prompt` в конфиге (строка или путь к файлу).

**api** — единый адаптер. Модуль реализует `stream(request, on_event)` и `list_models()`. Канонические события:
`message_start`, `reasoning_start`, `reasoning_delta`, `reasoning_end`, `text_delta`, `tool_call_start`, `tool_call_delta`, `tool_call_end`, `usage`, `done`, `error`. Первый модуль — OpenAI-compatible. Anthropic и Google — позже по тому же контракту. OpenAI-модуль маппит `reasoning_summary` на reasoning-события; модели без reasoning их не шлют.

**tools** — read, write, list, glob, grep, run, patch (§7).

**session** — JSONL-журнал, автосохранение, возобновление по `-r` (§10).

## 6. TUI

### 6.1 Регионы экрана

```
┌──────────────────────────────────────────────────────────────┐
│ transcript (flex, скроллится)                                │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ error banner (0–2 строки, только при ошибке)                 │
├──────────────────────────────────────────────────────────────┤
│ input (1..8 строк, растёт вверх)                             │
├──────────────────────────────────────────────────────────────┤
│ palette (0..10 строк, только при активной палитре)           │
├──────────────────────────────────────────────────────────────┤
│ hint line (1 строка, контекстные подсказки)                  │
├──────────────────────────────────────────────────────────────┤
│ status line (1 строка)                                       │
└──────────────────────────────────────────────────────────────┘
```

Header отсутствует (`ui.header = false`). Overlay-слои поверх всего: **confirmation** (у блока инструмента), **diff viewer**, **help**, **log**, **resume picker**. Overlay перехватывает клавиатуру; `Esc` закрывает, кроме confirmation во время работы агента (там `Esc` = Cancel turn).

При ширине < 80 колонок: hint и status схлопываются в одну строку, отступы уменьшаются с 2 до 1 пробела.

### 6.2 Основной экран — пример

```
 › как устроен цикл агента?

 ● LLM возвращает tool calls, я выполняю их в workspace и отправляю
   результаты обратно. Повторяется до завершения или лимита.

 ✻ thinking ▸ (Ctrl+T)

 ⚙ read src/tether/agent.lua                         12 ms · 214 стр.
 ⚙ grep "tool_call" src/tether/ glob=*.lua            8 ms · 7 совп.
 ⚙ run "make test" cwd=.                             1.2 s · exit 0
 ⚠ patch src/tether/agent.lua                         3 ms
   ┌ a/src/tether/agent.lua
   │ @@ -40,6 +40,8 @@
   │  local function on_event(ev)
   │ +  if ev.tool_call_start then
   │ +    calls[#calls+1] = ev
   │    table.insert(calls, ev)
   └──────────────────────────────────────────────
     [y] once  [a] session  [A] always  [d] details  [n] deny

 ● Готово: добавил обработку tool_call_start.

──────────────────────────────────────────────────────────────
 › █
   Enter отправить · Ctrl+J новая строка · Ctrl+C отмена · ? помощь
   gpt-4o-mini · ~/proj/tether · 4.1k/32k (13%) · 🖱 on
```

### 6.3 Блоки транскрипта

Каждый блок — gutter (1–2 символа) + содержимое с висячим отступом.

| Тип | Gutter | Цвет | Правила |
|---|---|---|---|
| user | `›` | cyan bold | Перенос с отступом 2 |
| assistant text | `●` | default | Markdown-lite (§6.4) |
| reasoning | `✻ thinking` | dim italic | `ui.thinking = "collapsed"` (дефолт) — заголовок и `▸`; `expanded` — тело видно; `hidden` — блок отсутствует. `Ctrl+T` — тумблер collapsed↔expanded |
| tool success (без подтверждения) | `⚙ <name>` | name yellow | Одна строка: `<name> <key-args> · <время> · <сводка>` |
| tool success (с подтверждением) | `⚠ <name>` | name yellow | Заголовок + diff/команда + меню подтверждения |
| tool error | `✗ <name>` | red | Тело ошибки показывается **всегда** |
| diff | внутри `⚠ patch` | +/- | Unified diff, рамка `┌│└` |
| summary marker | `── summary ──` | dim | Разделитель |
| error banner | `!` | red bg | Над input, до 2 строк, `Esc` закрывает |
| resume banner | `↻` | dim | «возобновлена сессия `<id>` от `<ts>`» |
| streaming caret | `▌` | default | Мигает в конце стримящегося текста |

### 6.4 Markdown-lite

Жирный (`**`), инлайн-код (`` ` ``), код-блоки (```` ``` ````), маркированные и нумерованные списки, заголовки `#`–`###`, ссылки как `<текст> (url)`. Без таблиц, HTML и картинок.

### 6.5 Скрытие и раскрытие результатов

**Правило.** Результаты инструментов **без подтверждения** (`read`, `list`, `glob`, `grep`, `run` внутри workspace) скрыты по умолчанию. Инструменты **с подтверждением** (`write`, `patch`, `run` вне workspace) показывают детали всегда. Ошибки — всегда. Длинные результаты дополнительно сворачиваются при раскрытии, пороги `ui.collapse = {read = 20, list = 30, grep = 15}`.

**Краткая сводка** для скрытого результата:

| Инструмент | Сводка |
|---|---|
| `read` | `<N> стр.` |
| `list` | `<N> записей` |
| `glob` | `<N> файлов` |
| `grep` | `<N> совп.` |
| `run` | `exit <code>`, `<time>` |
| `write` | `+<bytes> B` |
| `patch` | `+<N> −<M>` |

**`run`** скрывает stdout и stderr целиком; в строке только `exit <code>` и время. Раскрытие — `Ctrl+O`.

**Раскрытие.** `Ctrl+O` раскрывает все свёрнутые результаты в текущем вьюпорте; повторное — сворачивает. Раскрытые помечаются `▾` вместо `▸`. Состояние не сохраняется между сессиями.

### 6.6 Стриминг

```
 ● Цикл устроен так: LLM возвращает tool calls, я выполняю их в
   workspace и отправляю результаты обратно. Повторяется до▌

   ✻ tether думает… ⠋
```

- Плейсхолдер `✻ tether думает…` со спиннером (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) — сразу после отправки, исчезает с первым `text_delta` или `reasoning_delta`.
- `Ctrl+C` — прерывает стрим, оставляет полученный текст, пишет `message` с `meta.aborted = true`.
- Двойной `Ctrl+C` за < 1 с — выход; подтверждение, если стрим активен.
- Автоскролл вниз, пока пользователь не прокрутил вверх; после ручной прокрутки — индикатор `↓ новые` в правом нижнем углу transcript, `End` возвращает к низу.

### 6.7 Поле ввода

```
 › первая строка ввода█
   вторая строка, отступ 2
```

- Префикс `› ` только у первой строки; продолжения — отступ 2.
- Растёт вверх до `ui.input_max_lines = 8`, дальше скроллится внутри себя.
- `Enter` — отправить; `Ctrl+J` — новая строка; `Shift+Enter` — новая строка при Kitty/modifyOtherKeys.
- `↑`/`↓` при пустом вводе — история (§6.13); при непустом — перемещение курсора по строкам.
- `Ctrl+A/E/U/W/K` — readline-подобные.
- `Ctrl+V` — bracketed paste; многострочная вставка сохраняет переводы строк.
- Ввод блокируется при открытом confirmation и на время выполнения инструмента без стрима.

### 6.8 Слэш-команды и палитра

Палитра открывается, когда первая непробельная последовательность в текущей строке начинается с `/`. Фильтруется по мере набора; `↑↓` — навигация, `Enter` — выполнить, `Tab` — дополнить, `Esc` — закрыть палитру, оставив `/` как обычный символ.

```
 › /mo█
 ┌─────────────────────────────────────────────┐
 │ /model    сменить модель                    │
 └─────────────────────────────────────────────┘
   ↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть
```

```
 › /
 ┌─────────────────────────────────────────────┐
 │ /help     справка по клавишам               │
 │ /clear    очистить транскрипт               │
 │ /compact  сжать контекст (суммаризация)     │
 │ /model    сменить модель                    │
 │ /resume   возобновить сессию для workspace  │
 │ /new      начать новую сессию               │
 │ /status   полный статус сессии              │
 │ /log      последние ошибки из лога          │
 │ /quit     выход                             │
 └─────────────────────────────────────────────┘
```

Поведение:

- `/help` — help overlay.
- `/clear` — очищает транскрипт в памяти; подтверждение; сессия на диске не трогается.
- `/compact` — принудительная суммаризация старых сообщений; отчёт о сжатии показывается строкой `── summary ──`.
- `/model` — палитра из `list_models()`, если доступно, иначе ручной ввод; сохраняется в сессии, не в конфиге.
- `/resume` — палитра последних 10 сессий текущего workspace (§6.9).
- `/new` — новая сессия; старая остаётся на диске с `session_end`.
- `/status` — полноэкранный overlay: id сессии, workspace, модель, использовано/доступно токенов, число tool calls, число summary, время старта, путь лога.
- `/log` — полноэкранный overlay с последними 200 строками `~/.tether/log/tether.log`.
- `/quit` — как `Ctrl+Q` / двойной `Ctrl+C`; при активном стриме — подтверждение.

`Enter` при открытой палитре выполняет команду, а не отправляет сообщение.

### 6.9 Resume picker

```
 ┌ возобновить сессию ──────────────────────────────────────────┐
 │ 14:32 · a1b2c3d4 · добавь тесты для glob                      │
 │ 13:07 · e5f6a7b8 · объясни структуру проекта                  │
 │ вчера · 9c8d7e6f · почини падающий парсер                     │
 └──────────────────────────────────────────────────────────────┘
   ↑↓ выбрать · Enter возобновить · Esc закрыть
```

Формат: `<время> · <id[:8]> · <первая строка пользователя>`. Сортировка по mtime, только сессии текущего workspace, до 10 записей.

### 6.10 Confirmation-меню

```
 ⚠ patch src/tether/agent.lua
   ┌ a/src/tether/agent.lua
   │ @@ -40,6 +40,8 @@
   │  local function on_event(ev)
   │ +  if ev.tool_call_start then
   │ +    calls[#calls+1] = ev
   │    table.insert(calls, ev)
   └──────────────────────────────────────────────
   › [y] once      разрешить один раз
     [a] session   разрешить этот тип до конца сессии
     [A] always    сохранить в auto_approve конфига
     [d] details   показать diff/аргументы целиком
     [n] deny      отклонить, вернуть отказ агенту
     [Esc] cancel  прервать текущий ход агента
```

- Навигация `↑↓` + `Enter`; горячие клавиши сразу.
- Текущий пункт — `›`, подсветка reverse video.
- `[A] always` открывает под-меню: что сохранять — путь, префикс команды или всё действие. Запись в `~/.tether/config.lua` с датой-комментарием.
- `[d] details` — полноэкранный diff overlay; `Esc` возвращает к меню.
- Для `run`: полная команда, cwd, timeout и предупреждение при `rm`, `curl | sh`, `sudo`, `> /` и подобном.

### 6.11 Diff overlay

```
 ┌ diff · src/tether/agent.lua · 2 файла · +14 −3 ────────────────┐
 │  38  local function on_event(ev)                              │
 │  39    if ev.text_delta then                                  │
 │  40      ui.append(ev.text)                                   │
 │  41 +  elseif ev.tool_call_start then                         │
 │  42 +    calls[#calls+1] = ev                                 │
 │  43 +    ui.show_tool(ev)                                     │
 │  44    end                                                    │
 │  45  end                                                      │
 ├────────────────────────────────────────────────────────────────┤
 │ [/] файл  ↑↓ скролл  PgUp/PgDn страница  g/G начало/конец  Esc │
 └────────────────────────────────────────────────────────────────┘
```

Цвета: `+` зелёный, `−` красный, контекст dim, номера строк dim. Длинные строки переносятся, `←`/`→` — горизонтальный скролл при `ui.wrap = false`.

### 6.12 Help overlay (`?`)

```
 ┌ помощь ───────────────────────────────────────────────────────┐
 │ Ввод          Enter отправить · Ctrl+J / Shift+Enter newline  │
 │               ↑↓ история · Ctrl+A/E/U/W/K · Ctrl+V вставка    │
 │ Навигация     PgUp/PgDn · Ctrl+Home/End · мышь-колесо         │
 │ Транскрипт    Ctrl+O развернуть · Ctrl+T thinking · Ctrl+L    │
 │               очистить экран                                  │
 │ Сессия        Ctrl+R возобновить · Ctrl+N новая · Ctrl+Q выход│
 │ Прочее        ? помощь · F1 ошибки · --debug лог              │
 └────────────────────────────────────────────────────────────────┘
```

### 6.13 История ввода

`~/.tether/history.jsonl`, по строке на запись:

```json
{"ts":"...","workspace":"/abs/path","text":"..."}
```

`↑` в поле ввода фильтрует по текущему workspace; лимит — последние 200 записей на workspace, без дублей подряд. Глобальный лимит файла — 5000 записей, обрезается при старте.

### 6.14 Hint-строка

| Состояние | Текст |
|---|---|
| Ожидание ввода | `Enter отправить · Ctrl+J новая строка · Ctrl+C отмена · ? помощь` |
| Палитра открыта | `↑↓ выбрать · Tab дополнить · Enter выполнить · Esc закрыть` |
| Стрим | `Ctrl+C прервать · Ctrl+O развернуть · PgUp/PgDn скролл` |
| Confirmation | `↑↓ выбрать · Enter подтвердить · y/a/A/d/n горячие · Esc отмена` |
| Diff overlay | `↑↓ скролл · [/] предыдущий/следующий файл · Esc закрыть` |
| Нет `curl`, HTTPS | `! curl не найден — установите curl или укажите http://localhost (F1 подробнее)` |

### 6.15 Статус-строка

```
 gpt-4o-mini · ~/proj/tether · 4.1k/32k (13%) · 🖱 on
```

Поля слева направо, разделитель ` · `, отбрасываются справа налево при нехватке ширины:

1. **model**.
2. **workspace** (`$HOME` → `~`).
3. **tokens** — `4.1k/32k (13%)`. `used` из `usage` API или оценка `ceil(chars/4)` (тогда префикс `≈`). `max` из API или конфига.
4. **keyboard** — `⌨ kitty` / `⌨ modifyOtherKeys` / `⌨ ctrl+j`. Только при первом запуске и в `--debug`.
5. **mouse** — `🖱 on` / `🖱 off`.

### 6.16 Цвета (тема `default`)

| Роль | Атрибут |
|---|---|
| accent / user gutter | cyan bold |
| assistant gutter | default bold |
| thinking | dim italic |
| tool name | yellow |
| tool success | green |
| tool error / error banner | red |
| diff add / remove | green / red |
| diff context / line numbers | dim |
| status line | reverse |
| hint line | dim |
| selection (в overlay) | reverse |

`ui.ascii = "auto" | true | false`. При `auto`: `TERM=dumb`, `NO_COLOR=1` или `LANG=C`/`LC_ALL=C` → ASCII-глифы (`>` вместо `›`, `*` вместо `●`, `-` вместо `─`) и без цвета.

### 6.17 Устойчивость

- `SIGWINCH` — пересчёт размеров, перерисовка из буфера транскрипта.
- Transcript — список готовых строк (с переносами); перерисовка O(видимой области).
- При выходе — восстановление termios, выключение mouse reporting и kitty protocol, `CSI ? 25 h`.
- Паника в C-хосте — `atexit` восстанавливает терминал.

## 7. Инструменты

| Имя | Аргументы | Поведение |
|---|---|---|
| `read` | `path, offset?, limit?` | 1 MiB максимум; бинарные (NUL в первых 8 KiB) отклоняются; длинные строки обрезаются до 8 KiB |
| `write` | `path, content` | Создаёт/перезаписывает; подтверждение вне workspace |
| `list` | `path?` | Список каталога |
| `glob` | `pattern, path?` | `*`, `**`, `?`, `[abc]`, `[!abc]`; сортировка по пути; лимит 500 |
| `grep` | `pattern, path?, glob?, ignore_case?, max_results?` | Предпочитает `rg`, затем `grep -R`, затем Lua-fallback; формат `{path, line, column, text}` |
| `run` | `command, cwd?, timeout?` | `/bin/sh -c`; cwd внутри workspace; timeout 120 с; `TETHER_*` в env |
| `patch` | `patch` | Unified diff, строгое применение; при конфликте — ошибка и просьба перечитать файл |

Все пути относительно workspace, если не абсолютные. Выход за корень требует подтверждения. `allow_outside_workspace = false` по умолчанию. Workspace = текущая директория запуска, если не задан `-w`; путь приводится к `realpath`; symlink-и раскрываются.

## 8. Terminal I/O

**Keyboard.** `ui.keyboard_protocol = "auto" | "kitty" | "modifyOtherKeys" | "none"`. При старте: Kitty (`CSI > 1 u`) → modifyOtherKeys → fallback на `Ctrl+J`. Подсказка в статусе при первом запуске.

**Mouse.** `ui.mouse = "auto" | "off"`. SGR mouse (`CSI ? 1006 h` + `CSI ? 1000 h`). В MVP: скролл колесом, клики по пунктам меню подтверждений и палитр. `Shift+мышь` всегда отдаёт выделение терминалу. `ui.mouse_selection = false` — in-app drag-selection отложен.

**Clipboard.** OSC 52 с fallback на `pbcopy`/`xclip`/`wl-copy`. `Ctrl+Shift+C` — копировать последний ответ ассистента.

## 9. Потоки данных

**Стриминг чата.** `agent` формирует запрос → `api.stream` → C-хост запускает `curl` и парсит SSE → канонические события → `ui` обновляет транскрипт.

**Tool-call.** LLM возвращает `tool_call` → агент проверяет политику (workspace/подтверждение) → `tools.*` выполняет → результат как `tool_result` → следующий запрос LLM.

**Суммаризация.** При 70% заполнения контекста (`summarize_at`) старые сообщения сжимаются отдельным вызовом той же модели с промптом «сожми факты, решения, открытые вопросы»; summary хранится как системное сообщение. Бюджет: `max_tokens` из API (если поддерживается) или конфига (по умолчанию 32768), резерв на ответ 20%.

**Ретраи API.** До 3 повторов с экспоненциальной задержкой (0.5/1/2 с) при 429, 5xx и сетевых ошибках; без повторов при прочих 4xx; уважать `Retry-After`; после исчерпания — ошибка в TUI и лог.

## 10. Схемы данных

**Сессия** (`~/.tether/sessions/<id>.jsonl`), по строке на событие:

```json
{"ts": "...", "type": "session_start|message|tool_call|tool_result|summary|session_end",
 "role?": "...", "content?": "...", "tool_call_id?": "...", "name?": "...",
 "args?": {...}, "result?": {...}, "usage?": {...},
 "meta?": {"workspace": "/abs/path", "model": "...", "aborted?": true}}
```

`-r` выбирает последнюю сессию по mtime с совпадающим `meta.workspace`. При отсутствии совпадений — сообщает и предлагает запустить новую.

**config.lua** (`~/.tether/config.lua`):

```lua
return {
  provider = "openai",
  api_key_env = "OPENAI_API_KEY",
  base_url = "https://api.openai.com/v1",
  model = "gpt-4o-mini",
  workspace = nil,
  allow_outside_workspace = false,
  auto_approve = {},
  context = { max_tokens = 32768, summarize_at = 0.7 },
  ui = {
    theme = "default",
    header = false,
    keyboard_protocol = "auto",
    mouse = "auto",
    mouse_selection = false,
    thinking = "collapsed",         -- "collapsed" | "expanded" | "hidden"
    ascii = "auto",                 -- "auto" | true | false
    wrap = true,
    collapse = { read = 20, list = 30, grep = 15 },
    input_max_lines = 8,
  },
  tools = { run_shell = { timeout = 120 } },
  system_prompt = nil,              -- строка или путь к файлу
  log_level = "info",
}
```

Секреты — только через env.

## 11. Сборка

```
tether/
  Makefile
  README.md
  LICENSE
  docs/design.md
  vendor/lua-5.4.6/
  vendor/luasystem/
  vendor/terminal.lua/
  src/host/          # main, term, spawn, http, embed
  src/tether/        # app, ui, agent, api, tools, session, config
  tools/embed.lua    # генератор C-массивов
  tests/
```

`make`: 1) `luasystem.a`; 2) генератор `tools/embed`; 3) встраивание всех `.lua` (tether + terminal.lua) в C-массивы; 4) линковка `tether` с `lua`, `luasystem`, libc. Цель — один бинарник `tether`. Без CMake и luarocks.

**Транспорт HTTPS.** C-хост запускает системный `curl` как subprocess, читает SSE из pipe. Если `curl` не найден: при `base_url` на localhost — автоматический HTTP-fallback, иначе — понятная ошибка с инструкцией.

## 12. Этапы

| Этап | Содержание | Приёмка |
|---|---|---|
| M0 | design doc | этот документ согласован |
| M1 | C-хост + raw mode + TUI-эхо | `tether` печатает ввод, корректно выходит |
| M2 | OpenAI-compatible streaming chat | стриминг ответа в TUI |
| M3 | read/list/glob/grep | поиск по workspace |
| M4 | write/patch/run + подтверждения | меню, diff, отказ/разрешение |
| M5 | сессии, конфиг, `-r` | возобновление последней сессии проекта |
| M6 | single binary | `make` → один `tether` |

**Приёмка MVP:** `make` даёт один бинарник; `tether` запускает TUI; `-r` возобновляет сессию; инструменты работают в workspace; вне workspace требуют подтверждения.

## 13. Риски

| Риск | Митигация |
|---|---|
| Нет `curl` и HTTPS-эндпоинт | ошибка с инструкцией; HTTP-fallback для localhost |
| Терминал не различает Shift+Enter | chain: kitty → modifyOtherKeys → `Ctrl+J` |
| Нет точного токенизатора | `usage` из API или `ceil(chars/4)`; хранить оба |
| Суммаризация искажает контекст | summary как системное сообщение + полный JSONL на диске |
| Различия SSE у провайдеров | канонические события + per-provider модуль |
| Медленный Lua-grep | приоритет `rg`/`grep`, Lua — fallback |
| Поведение мыши в tmux | документируем `set -g mouse on`; `Shift+мышь` для выделения |
| Совместимость luasystem | пиннинг версии в vendor/ |

## 14. CLI

```
tether                 интерактивный TUI
tether -r              возобновить последнюю сессию для текущего проекта
tether -w PATH         задать workspace
tether -m NAME         задать модель
tether -p "prompt"     неинтерактивный один прогон
tether --debug         подробный лог
tether --version, -v   версия
```

В режиме `-p`: финальный текст — в stdout, трассировка — в stderr, код возврата 0/1; выход за workspace и опасные действия блокируются без `auto_approve`.

## 15. Логи

`--debug`, файл `~/.tether/log/tether.log`, уровень в конфиге. Без секретов и без полного содержимого файлов по умолчанию. Ошибки API — в TUI и лог.

## 16. Тесты

`make test` — Lua-юнит-тесты для чистых модулей (config, session, api-парсинг, glob, патч) и smoke-скрипт для C-хоста (raw mode включается/выключается, spawn работает). Без внешних фреймворков.

---

