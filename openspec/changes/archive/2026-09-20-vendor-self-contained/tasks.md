# Tasks

## 1. Vendor krep + fs C primitives

- [x] 1.1 Vendor krep source (`krep.c`, `krep.h`, `aho_corasick.c`, `aho_corasick.h`, `LICENSE`) into `vendor/krep/` and verify the two `.c` files compile with `-std=c11 -Wall -Wextra` (decided: krep, not ugrep — ugrep release is C++ and would pull libstdc++)
- [x] 1.2 Add `tether.mkdirp`, `tether.fchmod`, `tether.readdir`, `tether.stat` to `src/host/main.c` and verify each with a minimal C test
- [x] 1.3 Replace `os.execute("mkdir -p …")` in `agent.lua`, `session.lua`, `ui.lua` with `tether.mkdirp` and verify `make test` passes
- [x] 1.4 Replace `io.popen("ls -1A …")` in `tools.lua` (`list`) and `context.lua` (`ls_subdirs`) with `tether.readdir` and verify `make test` passes
- [x] 1.5 Replace `io.popen("find … -type f")` in `tools.lua` (`glob`) with a recursive `tether.readdir` + `tether.stat` walk and verify glob output is unchanged
- [x] 1.6 Replace `io.popen("find … ls -1t")` in `session.lua` (`list_session_files`) with `tether.readdir` + `tether.stat` mtime sort and verify session list order is correct
- [x] 1.7 Replace `os.execute("chmod 600 …")` in `api.lua` (`header_file`) with `tether.fchmod` and verify the test at `lua_tests.lua:3467` still passes

## 2. krep engine integration

- [x] 2.1 Add a C function `tether.krep_search(base_dir, pattern, glob_filter, ignore_case, use_gitignore, max_results)` in `main.c` that builds krep's `search_params_t` and calls `search_directory_recursive`; verify with a unit test in `lua_tests.lua` (T123: fallback walk+gitignore exercised under plain Lua; krep C path exercised via host_smoke)
      - **Deviation**: krep's `search_directory_recursive` prints `path:lineno:line` records to stdout and returns only an error count, so it cannot hand back `match_result_t`. The matches are captured through a temporary stream (`tmpfile` + `dup2` on stdout) and parsed back; stdout is not a TTY during the call, so krep emits no ANSI color. Consequently every record reports `column = 1` (the tools spec allows this: "column is 1 when the engine omits it"). Verified in `tests/host_primitives_test.c` (a C test that links the real krep objects) rather than `host_smoke.sh`, because the TUI binary cannot be driven into a grep.
- [x] 2.2 Replace the `rg → grep` fallback in `tools.lua` (`M.grep`) with a single `tether.krep_search` call and verify grep output format is unchanged
      - **Deviation**: the record shape `{path, line, column, text}` is unchanged but `column` is now always 1 (krep's printed form has no column), and krep applies its own built-in skip lists (`skip_directories` drops `build`/`bin`/`obj`/`dist`/`target`/`.git`/`node_modules`/`venv`; `skip_extensions` drops `.log`/`.dat`/`.bin`/`.tmp`/`.o`/`.a`/archives/images/fonts). Those directories and extensions are therefore no longer searched — a coverage difference from the old `rg` path, now documented in the `tools` delta (`Grep engine`) and in the `vendor-tools` delta (`krep search engine`).
- [x] 2.3 Verify `.gitignore` is honored: create a test fixture with a `.gitignore` and confirm matching files are excluded from grep results (T123)
      - Verified in `tests/host_primitives_test.c` (`krep honors .gitignore (ignored.txt excluded)`, plus the gitignore-off, `ignore_case`, glob-filter and `max_results` cases).

## 3. Vendor libcurl + mbedTLS + zlib

- [x] 3.1 Add `vendor/libcurl/`, `vendor/mbedtls/`, `vendor/zlib/` source trees (check in source, not pre-built `.a`) and verify a static build succeeds
      - **Deviation**: the curl tree lives at `vendor/curl/`, not `vendor/libcurl/` as the task names it, and the old prebuilt archives (`vendor/*_build/`) were deleted — everything is now built into the gitignored `build/` directory. The vendored sources are committed (`.gitignore` narrowed to the sources the build consumes, with upstream docs/tests/build systems left out), so a fresh clone builds offline.
      - **Deviation**: mbedTLS 3.6.4 removed `mbedtls_havege_init` (mbedTLS < 3.0 API). curl 8.13.0's autotools `configure` probes for it, so it cannot auto-detect mbedTLS 3.6. Workaround: skip `./configure`, build libcurl sources directly with `gcc` and force `-DUSE_MBEDTLS=1` into the generated `lib/curl_config.h` by hand (the Makefile does this). Static archives `libmbedtls.a`/`libmbedx509.a`/`libmbedcrypto.a`/`libz.a` are built with a simple `gcc -c` loop (bypassing the broken `framework/` makefile) and linked into the final binary.
      - **Note**: the pre-existing `vendor/lua-5.4.6` was also untracked, so this fixes a reproducibility gap that predates the change.
- [x] 3.2 Update `Makefile` to build and link the vendor `.a` files; verify `ldd ./tether` shows only `libc` and `libm`
      - `make` now builds `build/libmbedtls_vend.a` (108 objects), `build/libz_vend.a` (15) and `build/libcurl_vend.a` (177) from the vendored sources and links them; `ldd ./tether` reports only `libm` + `libc`. Fixed along the way: `Makefile.curl` computed an empty object list (`filter $(CURDIR)/lib/%` never matched the relative `SRCS` entries) and its curated source list was missing translation units (`cf-https-connect.c`, `idn.c`, `http_aws_sigv4.c`, `curl_ctype.c`, ...) that left undefined references; the source list is now derived from the tree. `curl_config.h` defined `HAVE_BROTLI`/`HAVE_LIBZSTD` as `0`, which curl's `#ifdef` guards still treat as enabled (`undefined reference to BrotliDecoderVersion`); they are now left undefined. `-D_GNU_SOURCE` is required for the declared `HAVE_GLIBC_STRERROR_R`, and zlib needs `-DHAVE_UNISTD_H=1` (its `lseek` declaration).
- [x] 3.3 Add `tether.http_stream(method, url, headers, body, on_line_lua, opts)` to `main.c` using libcurl streaming read callback; `opts` is `{timeout_s?, connect_timeout_s?, idle_timeout_s?}`; verify with a local HTTP test server
      - **Deviation**: the first draft of the `vendor-transport` delta said the function "returns a line-iterator function" while also saying "a successful call returns `true`" and taking an `on_line` argument; those three cannot all hold. The callback model from `design.md` §3 was implemented (`on_line(line)` per body line, `true | nil, err` return) because that is what `api.lua`'s existing read loop needs, and the delta was corrected to describe it (plus the real `headers`/`body` forms: `"Name: value"` / `"@path"` entries, i.e. curl's `-H @file`). So the auth/material temp files stay the mechanism and the key never enters argv or the environment.
- [x] 3.4 Add `tether.http_get(url, headers, timeout_s)` to `main.c`; verify with a local HTTP test server
      - Both functions are exercised in `tests/host_primitives_test.c` against a forked loopback HTTP server: 200 body, `nil, "http 404"` on >= 400, and per-line streaming including the blank SSE boundary. TLS is covered by a second check in the same file: `openssl s_server` serves a freshly generated self-signed certificate on a loopback port and the call must fail verification with `nil, err` and no body (the check is skipped when the `openssl` CLI is unavailable; the system CA bundle remains a documented runtime requirement).

## 4. Replace curl shell transport

- [x] 4.1 Rewrite `api.lua` `http_request` to use `tether.http_stream` instead of `tether.open_pipe("curl …")`; preserve all retry/backoff and error event logic
      - Retry/backoff, `Retry-After`, `retry`/`error` events, the empty-line SSE boundary and the non-SSE error-body handling are unchanged. A failed transfer occupies the old "pipe never started" slot (retry, then `request failed: <reason>`); an SSE parse failure still stops parsing and returns `false`.
- [x] 4.2 Rewrite `api.lua` `list_models_live` to use `tether.http_get`; preserve error return format
- [x] 4.3 Update test seams in `tests/lua_tests.lua`: replace `open_pipe` mock with `http_stream`/`http_get` mock; verify all existing API tests pass
      - T15/T28/T51 and the shared `base_env` now script `http_stream`/`http_get`; the per-attempt scripts are indexed by request number instead of handle.
- [x] 4.4 Run `make test` + `sh tests/host_smoke.sh` and verify no regressions

## 5. Final cleanup

- [x] 5.1 Remove `tether.open_pipe` from the API transport path (keep it for the `run` tool); verify `run` tool tests still pass
      - No Lua module references `open_pipe` any more, and `tether.exec` is what `tools.run` uses. The family itself was later deleted — see 6.7.
- [x] 5.2 Update `docs/tech-spec.md` and `docs/design.md` to reflect the new dependency model
      - Also updated `README.md`, whose architecture list and "SSE via pipes" / "passed to curl" bullets described the old transport.
- [x] 5.3 Run full test suite and `host_smoke.sh`; verify binary size and `ldd` output
      - `make clean && make test` (46 s) is green end to end; binary is ~2.1 MB (was ~626 KB) and `ldd` still shows only `libm` + `libc`.

## 6. Verification follow-ups

Found by `/opsx-verify` after implementation and closed before archiving.

- [x] 6.1 Correct the delta headers so archive can apply them: `api-client transport` → `SSE streaming request`, `api-client key handling` → `API key never in argv`, `host.tether-exec-api` → `Process and pipe API`, `host.tether-fs-api` → `Path and terminal API`, `sessions list` → `Session picker data`, `tools.list/glob/grep` → `Directory listing` / `Glob semantics` / `Grep engine`; keep every scenario the live specs already had (a MODIFIED block replaces the whole requirement)
- [x] 6.2 Drop the `REMOVED Requirements` / `legacy-rg-fallback` block — no such requirement exists (the `rg → grep` fallback lived inside `Grep engine`, which this change modifies)
- [x] 6.3 Rewrite the `vendor-transport` `HTTP stream` text to the implemented callback API, the real `headers`/`body` forms (`"Name: value"` / `"@path"`) and `opts` defaults; make the `TLS trust store` scenario testable
- [x] 6.4 Replace the `Process and pipe API` claim that `run` uses `open_pipe` with the real call graph (`tools.run` → `tether.exec`, the only caller) — first by rewording the requirement, then by removing the family outright once it turned out to have no caller (see 6.7)
- [x] 6.5 Add tool-level coverage: T113 (`list`/`glob`/`grep` on in-process primitives — sorted entries, `**` depth, 500-file cap, `{path, line, column, text}` shape, `krep_search` arguments) and T114 (session listing ordered by mtime, capped at the 100 most recent, `mtime` as recency rank)
- [x] 6.6 Cover TLS verification in `tests/host_primitives_test.c` (self-signed peer via `openssl s_server`); strengthen T110 to assert `run` goes through `/bin/sh -c` under `timeout`, and drop the last `io.popen` from T109 in favour of a recording `fchmod` mock plus the fchmod-failure path
- [x] 6.7 Delete the `open_pipe` family (`l_open_pipe`, `l_read_line`, `l_close_pipe`, `l_pipe_eof`, the `g_pipe` state and its helpers) and its four registry entries from `src/host/main.c`: with the transport in process and `tools.run` on `tether.exec`, nothing called it. `host` now records the removal instead of the false "kept for the `run` tool" claim, `tether.exec` is documented as the only shell primitive (with an exit-code scenario, asserted by T110), and the `sys/wait.h` include that only the pipe code needed moved to the top because `l_exec` uses `WEXITSTATUS`. README, `docs/tech-spec.md` and `docs/design.md` no longer list the removed primitives.
- [x] 6.8 Bring the change docs in line with reality: `design.md` (stdout capture for krep records and `column = 1`, archives in the gitignored `build/`, ~2.1 MB binary, real `http_stream`/`http_get` signatures, vendored trees and policy), `proposal.md` (signatures, `vendor/curl/`, sizes, `sessions` requirement now rewritten), `docs/design.md` (§9 in-process transport, skill listing via `tether.readdir`, five `make test` stages)
