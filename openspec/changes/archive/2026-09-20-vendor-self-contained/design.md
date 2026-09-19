# Design

## Context

See proposal.md — Why. The binary today is ~550 KB and links only `libm` + embedded Lua 5.4.6. It shells out to `curl`, `rg`, `grep`, `ls`, `find`, `chmod`, and `mkdir` at runtime. The C host (`src/host/main.c`) is the only place where C code lives; all application logic is in Lua modules embedded at build time.

## Goals / Non-Goals

**Goals:**
- Zero external dynamic dependencies at runtime: `ldd ./tether` shows only `libc` and `libm`.
- All file-system operations (mkdir, readdir, stat, fchmod) happen in-process via new `tether.*` C primitives.
- `grep`/`glob` work without any external binary; `.gitignore` is honored by the krep engine.
- HTTP/SSE transport for LLM APIs works in-process; the API key never appears in argv.
- Binary remains a single static executable.

**Non-Goals:**
- The `run` tool (`/bin/sh -c` via `tether.exec`) stays — shell execution is a deliberate feature, not an accidental dependency. The rest of the pipe API does not: see decision 3.
- No HTTP/2 support (LLM provider APIs work on HTTP/1.1; libcurl built with `--enable-http1` only).
- No proxy/HTTP-agent support beyond what libcurl provides by default.
- No Windows or macOS target (Linux-only per the earlier decision).

## Decisions

### 1. krep vs. hand-rolled Lua grep

**Chosen: vendor krep** (davidesantangelo/krep, pure C11, BSD-2, ~5000 lines: `krep.c`, `krep.h`, `aho_corasick.c`, `aho_corasick.h`).

- krep is pure C (no C++ runtime); its only libc dependencies are `regex.h` (POSIX ERE) and `fnmatch.h` (glob/gitignore pattern matching), both in glibc. Its pthread use is the standard glibc thread library — no new `ldd` entries on modern Linux (glibc ≥ 2.34 merges libpthread into libc).
- It natively honors `.gitignore`/`.ignore` files (recursive parent-chain loading), which the current `rg → grep` fallback does not.
- It supports POSIX ERE (`-E`), `--glob`/`--exclude` filters, `-i`, `-n`, and `max_count` — matching the existing tool semantics.
- An alternative (Lua `string.find` + `regcomp`) would be ~200 lines but loses `.gitignore` and is slower on large trees.

**Integration**: link `vendor/krep/krep.c` + `vendor/krep/aho_corasick.c` into the static binary (`-DTESTING` drops krep's own `main`). Expose a C function `tether.krep_search(base_dir, pattern, glob_filter, ignore_case, use_gitignore, max_results)` in `main.c` that builds a `search_params_t`, sets the gitignore flag, and calls `search_directory_recursive`. Match records are surfaced to Lua as `{path, line, column, text}`.

**As implemented**: krep's `search_directory_recursive` prints `path:lineno:line` records to stdout and returns only an error count, so it cannot hand back `match_result_t`. The host captures stdout through a `tmpfile` + `dup2` around the call and parses the records back (stdout is not a TTY during the call, so krep emits no ANSI color). krep's printed form carries no column, so every record reports `column = 1`.

**Note**: the earlier draft of this design named "ugrep" — the actual `Genivia/ugrep` release is C++ and would pull `libstdc++` into `ldd`, violating the self-contained constraint. krep is the pure-C substitute with the same feature set.

### 2. libcurl + mbedTLS + zlib as vendor'd static libs

**Chosen: vendor libcurl, mbedTLS, and zlib; link statically.**

- All three have permissive licenses (MIT, Apache-2.0, MIT/bsd-2).
- Static size: libcurl ~600 KB, mbedTLS ~400 KB, zlib ~100 KB. Measured result: the final binary is ~2.1 MB.
- libcurl gives: DNS resolution (`getaddrinfo`), TLS handshake, HTTP/1.1 request/response framing, chunked encoding, streaming read callback. No hand-written socket + TLS state machine.
- Building: `sh configure --disable-shared --enable-static --with-mbedtls` + `make`.
  - **Deviation**: curl autotools release (8.13.0) requires `mbedtls_havege_init` (removed in mbedTLS ≥ 3.6) so `configure` cannot auto-detect a vendored mbedTLS 3.6.4. Workaround: `sh configure --with-mbedtls=PATH` (PATH points to a dir containing `include/` + `lib/`) plus `MBEDTLS_ENABLED=1` injection, or link the static archives by hand in the Makefile. The latter is chosen: build `libmbedtls.a`/`libmbedx509.a`/`libmbedcrypto.a` directly with `gcc -c` (bypassing the broken `framework/` makefile) and link them into the tether binary.
  - **As implemented**: the autotools path is not used at all. `vendor/curl/Makefile.curl` compiles the vendored curl translation units directly, and the three archives land in the gitignored `build/` (`build/libcurl_vend.a` 177 objects, `build/libmbedtls_vend.a` 108, `build/libz_vend.a` 15). `curl_config.h` had to stop defining `HAVE_BROTLI`/`HAVE_LIBZSTD` as `0` (curl guards them with `#ifdef`), curl needs `-D_GNU_SOURCE`, and zlib needs `-DHAVE_UNISTD_H=1`.

**Alternative considered**: hand-written HTTP/1.1 + raw mbedTLS (~1000 lines C). Rejected: no streaming read callback, no retry/backoff built in, and every edge case (chunked encoding, 100-continue, keep-alive) is a bug surface.

### 3. Expose two Lua-facing functions in main.c

```
tether.http_stream(method, url, headers_array, body, on_line_lua_func, opts)
  → true | nil, error_string

tether.http_get(url, headers_array, timeout_s)
  → body_string | nil, error_string
```

- `headers_array` is an array of `"Name: value"` strings; an entry `"@<path>"` is replaced by the lines of that file. The API key travels as such a file path — the C code opens the file, reads the key, and passes it to libcurl's `CURLOPT_HTTPHEADER` without ever copying it into a Lua-visible string (and never into argv).
- `body` is a string or `"@<path>"` (the request-body temp file), matching the previous `--data-binary @file` behaviour.
- `on_line_lua_func` is called for each body line in streaming mode; a blank line arrives as `""`. The C code manages the libcurl write callback and decodes `data:` SSE frames in Lua (the Lua layer already parses SSE).
- `opts` is `{timeout_s | connect_timeout_s, idle_timeout_s}`: the connect timeout defaults to 10 s and the idle timeout to 60 s (implemented with `CURLOPT_LOW_SPEED_LIMIT`/`TIME`, since libcurl has no native idle timeout).
- `http_get` is blocking and returns the full body — used for model listing.
- **As implemented**: the `open_pipe` / `read_line` / `close_pipe` / `pipe_eof` family was deleted from the host. Once the transport and the file/search paths stopped using it, `tools.run` (its supposed remaining consumer) turned out to call `tether.exec`, so the family had no caller; the host spec records this as a removal (see `specs/host/spec.md`) and `tether.exec` is the only shell primitive.

### 4. File-system primitives in main.c

Four new functions, all thin syscall wrappers:

| Function | Implementation | ~LOC |
|---|---|---|
| `tether.mkdirp(path)` | Recursive `mkdir(2)`, `EEXIST` ignored, returns `true`/`nil, err` | 30 |
| `tether.fchmod(path, mode)` | `open()` + `fchmod()` + `close()`, mode is int (0600) | 10 |
| `tether.readdir(path)` | `opendir`/`readdir`/`closedir`, returns Lua table of names (sorted) | 25 |
| `tether.stat(path)` | `lstat()`, returns `{mtime, size, is_dir}` table | 15 |

These replace every `os.execute("mkdir -p …")`, `io.popen("ls …")`, `io.popen("find …")`, and `chmod 600` call in the Lua layer.

### 5. Test seam for the HTTP transport

The existing test seam is `open_pipe` returning a script-table. The new seam is:

```lua
-- In tests, override:
_G.tether = { http_stream = function(method, url, headers, body, on_line)
    -- yield scripted lines from a table, call on_line for each
end, http_get = function(url, headers, timeout_s)
    return scripted_body, nil
end }
```

`http_get` takes an optional `timeout_s` (seconds, default 30) mapped to `CURLOPT_TIMEOUT_MS`.

This mirrors the previous pattern in `tests/lua_tests.lua` (`base_env` / `host_mock{...}`) — the mock seam moved from `open_pipe` to `http_stream`/`http_get` without changing test logic.

## Risks / Trade-offs

- [Binary grows 550 KB → ~2.1 MB] → Acceptable; the binary remains a single static file, no `ldd` deps. The delta is TLS + HTTP infrastructure, not application logic.
- [krep is C11] → The Makefile currently uses `-std=c11` for the Lua objects; krep needs the same standard. No conflict.
- [krep regex is POSIX ERE, not full PCRE] → The current `rg`-based tool supports PCRE; krep with `-E` covers the common subset. Patterns using lookaround or other PCRE-only features will fail. This is a known, documented limitation.
- [libcurl static build requires mbedTLS build] → One-time build step; commit `vendor/mbedtls/` as a vendored source tree. The Makefile adds a `vendor/` target that builds `.a` files.
- [mbedTLS trust store] → libcurl with mbedTLS backend uses `mbedtls_ssl_load_trust_ca` pointing at `/etc/ssl/certs/ca-certificates.crt`. If the file is missing the TLS handshake fails. This is a documented runtime requirement, not a build-time one.
- [krep SIMD baseline] → krep compiles without AVX2 (scalar fallback). No feature loss on non-AVX2 machines.

## Migration Plan

1. **Phase 1** (1 day): Vendor krep + add the 4 C fs primitives + replace `ls`/`find`/`chmod`/`mkdir` in the Lua layer. No HTTP changes yet. Run existing test suite.
2. **Phase 2** (2 days): Vendor libcurl + mbedTLS + zlib. Build static `.a` files. Wire `tether.http_stream`/`tether.http_get` into main.c. Update `api.lua` transport.
3. **Phase 3** (0.5 day): Remove the `open_pipe` family from the host (it turned out to have no caller — `run` uses `tether.exec`). Update test seams. Run full test suite + host_smoke.

**Vendor source policy (decided)**: the vendored sources the build consumes are committed to the repo (`vendor/krep/`, `vendor/curl/`, `vendor/mbedtls/`, `vendor/zlib/`, `vendor/lua-5.4.6/src/`); upstream docs, tests and alternate build systems stay out of git. The Makefile builds everything in-tree into the gitignored `build/`. No download-at-build-time. (The pre-existing `vendor/lua-5.4.6` was untracked too, so this also closes a reproducibility gap that predates the change.)

Rollback: each phase is independently revertable; the old code paths (`io.popen("curl …")`, `io.popen("ls …")`) are removed only in the final phase.

## Open Questions

*(All resolved)*

- `tether.http_get` takes an optional `timeout_s` parameter (default 30 s), mapped to `CURLOPT_TIMEOUT_MS`. `http_stream` takes the same parameter; SSE streams have no total-timeout by default (long streams are legitimate) but DO have a connect timeout (10 s) and an idle timeout (60 s of no data → abort).
- Vendor sources are committed to the repo, built in-tree by the Makefile.
