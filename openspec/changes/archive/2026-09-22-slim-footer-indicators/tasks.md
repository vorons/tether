# Tasks

## 1. Footer layout

- [x] 1.1 Collapse `flags_h` reserve to a constant single footer row in `layout()` and verify `flags_row` is nil (test: pi 2.2 flags-row elasticity in `tests/lua_tests.lua` updated and `make test` passes)
- [x] 1.2 Merge toast + scroll flag into the single footer row in `render_footer()` and verify the truncation cascade path → toast → scroll → stats with model right-aligned (test: pi 5.5 truncation order in `tests/lua_tests.lua`, `make test` passes)

## 2. Scroll indicator relocation

- [x] 2.1 Remove the in-transcript `↓ +N` marker paint and verify the indicator appears only on the footer row while followed-off (test: T65 updated in `tests/lua_tests.lua`, `make test` passes)

## 3. Flag cleanup

- [x] 3.1 Remove `🖱`/`⌨` icons from `static_flags()` while keeping mouse tracking behavior and verify no mode icons render in the footer (test: T93/T94/T95 updated in `tests/lua_tests.lua`, `make test` passes)

## 4. Acceptance and docs

- [x] 4.1 Update pi 5.3 footer tests and run full `make test` to verify all scenarios in `specs/tui/spec.md` pass
- [x] 4.2 Sync living docs (`README.md` ~220/238, `docs/tech-spec.md` L47, `docs/design.md` §6.13) and verify no stale 3-row/marker/mode-icon references via grep
