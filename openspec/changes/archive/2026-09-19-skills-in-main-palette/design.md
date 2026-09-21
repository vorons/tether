# Design: skills-in-main-palette

## Context

The palette is derived state: `palette_sync()` rebuilds `S.palette_items` from
the static `SLASH_COMMANDS` table on every input change, and the command branch
of `handle_key` runs `execute_command(item.cmd)` on Enter. Skills live in a
second, explicitly-managed mode (`palette_mode == "skills"`, guarded by
`S._in_skills_palette` so `palette_sync` does not clobber it), fed lazily from
`context.discover_skills`.

The requested behavior is one list: type `/`, see commands and skills together,
pick a skill by name.

## Decisions

### D1 — Skills are candidates of the same palette, not a second mode

`palette_sync()` builds one candidate list: `SLASH_COMMANDS` in declared order,
then the discovered skills in discovery order. One `fuzzy_rank` pass ranks them
by the same rule (prefix match first, ties by candidate order). This reuses the
existing 3.1/3.2 machinery instead of adding a second list, and makes the filter
work over skill names for free.

*Rejected:* keeping `/skills` as a filter that opens the main palette pre-filled
with a prefix — it keeps two code paths and a hidden command for the common case.

### D2 — A skill row is rendered `/<name>`

The row label is `"/" .. sk.name` so it sits next to the commands, participates
in `/`-filtering, and Enter/Tab completion produce the same text the user could
have typed by hand. The description comes from the `SKILL.md` frontmatter.

A skill whose `/<name>` equals a command label is dropped, so `/copy` cannot
appear twice and command semantics are never shadowed by a user directory name
(discovery order already resolves skill-vs-skill collisions first-wins).

### D3 — Enter substitutes `/name `; it does not run anything

Enter on a skill row sets the input to `/name ` (trailing space, cursor at the
end) and closes the palette. Nothing is executed and no skill body or `SKILL.md`
path is inserted, matching the existing "index only, the agent reads the file on
demand" rule from `context-injection`. The trailing space is what keeps the
palette closed afterwards (a space in the filter closes it, per the Palette
requirement), so the user simply appends the task.

*Rejected:* keeping the `[skill: name — path]` reference from the old separate
palette — the user asked for a plain `/name` reference; *rejected:* submitting
the message immediately on Enter — it would send an empty task.

### D4 — A submitted `/name` that is not a command is a message

`commit_input` currently dispatches any `^/(%w+)` to `execute_command`, which
starts with `input_clear()`; an unknown name therefore clears the input and does
nothing. With skills referenced as `/name …`, that would silently drop the
message. Command dispatch now requires the name to be one of `SLASH_COMMANDS`;
anything else falls through to the normal submit path and reaches the agent
exactly once.

Consequence: `/help` (a command removed on request) is now sent to the model
instead of being silently cleared. That is the intended trade: text the user
typed and submitted is never discarded without an effect.

### D5 — Discovery is cached per session

`palette_sync` runs on every keystroke, and `discover_skills` shells out per
skills directory. The rows are computed once, lazily (on the first `/`), stored
on `S.skill_rows`, and reset by `start_new_session()`. Failures degrade to no
skill rows and never break the palette or the session.

The existing `M._skills_stub` seam is kept and moved above `palette_sync` so the
closure captures it; tests keep injecting skill lists without touching the
filesystem.

### D6 — Module resolution follows api.lua, not `require`

`main.c` exposes every module as a *global* (`load_module` → `lua_setglobal`) and
installs no `package.preload`/`package.path`, so `require("context")` and
`pcall(require, "tools")` resolve nothing in the shipped binary. `api.lua`
already established the project convention for exactly this problem: the global
first, then a `loadfile` fallback for tests and dev runs.

`embedded_module(name)` applies that convention to `context` and `tools`.
Without it the palette's discovery silently degraded to `{}` (the `pcall` hid
the error — the old `/skills` palette had the same defect, which is why users
never saw skills there) and Tab path completion was silently dead, because
`require("tools")` never resolved either.

### D7 — The TUI takes the config app.lua already prepared

`ui.run()` re-ran `config.load()` and threw away the table `app.lua` had built.
Because `config.load()` rebuilds from defaults on every call, that dropped:

- `-w` — `S.workspace` fell back to the process cwd, so discovery scanned the
  wrong tree and every tool ran outside the requested workspace;
- `-m`, `--debug`, `--agents-file` — all CLI overrides;
- `cfg._session_id` — back as nil, so the TUI opened a *second* session file on
  every start (the resume path at `ui.lua:3393` documents the id as arriving
  from `app.lua`).

`M.run(cfg)` now accepts the prepared config and keeps loading from disk as the
fallback for direct callers and the test harness.

Both defects sit on the path the user reported (no skills in the palette when
running with `-w`), which is why they are fixed here rather than deferred.

## Removals

- `SLASH_COMMANDS` entry `/skills` and the `cmd == "skills"` branch of
  `execute_command`.
- `S._in_skills_palette`, its two `palette_sync` guards, the `palette_mode ==
  "skills"` branch of `handle_key`, and the `(нет скиллов)` placeholder row.

## Risks

- **Skill names that are not plain words** (`my-skill`, `fix.bug`). The row label
  carries them verbatim, so `/my-skill ` works as typed text; only the command
  dispatch match is `%w+`, and such a name is never a command, so it submits as a
  message (D4).
- **A palette that opens on a slow filesystem** would block the first `/` for the
  duration of the `ls` calls. Discovery already ran at startup for the system
  prompt, so this is the same work; the cache keeps every later keystroke free.
- **Tests T79–T81** assert the removed mode and are rewritten as part of this
  change rather than deleted, so the palette/Enter/submit behavior stays covered.
