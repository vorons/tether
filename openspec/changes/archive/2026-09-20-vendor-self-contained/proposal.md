# Proposal

## Why

The binary currently depends on external CLI tools (`curl`, `rg`, `grep`, `ls`, `find`, `head`, `chmod`, `mkdir`) that are not guaranteed to exist on every target system, and on system `sh` for several file-operations. The goal is a fully self-contained, single-file Linux binary whose only runtime dynamic dependencies are `libc` and `libm` (Lua 5.4.6 is embedded).

## What Changes

- **Vendor krep** into `vendor/krep/` (pure C, BSD-2, ~5000 lines across `krep.c`/`krep.h` + `aho_corasick.c/h`) as a static replacement for `rg`/`grep` in `tools.grep`. krep uses POSIX `regex.h` (already in glibc) and `fnmatch.h` for gitignore pattern matching — no new external dependencies. It natively honors `.gitignore`/`.ignore`, supports `--glob`, `--exclude`, `-i`, `-n`, and POSIX ERE. This replaces the two-step `rg → grep` shell fallback. krep's multithreading uses pthread (part of glibc on modern Linux), so no new `ldd` entries appear.
- **Vendor libcurl + mbedTLS + zlib** (all permissive licenses) into `vendor/` to eliminate the `open_pipe("curl …")` shelling. The C HTTP client in `main.c` replaces the shell-out transport in `api.lua` with in-process socket + TLS + HTTP/1.1 code.
- **Add `tether.mkdirp`, `tether.fchmod`, `tether.readdir`, `tether.stat`** to the C host (`main.c`) to replace all `os.execute("mkdir -p …")`, `io.popen("ls …")`, `io.popen("find …")`, and `chmod 600` shell-outs.
- **Remove the `find`/`ls` shell-outs** from `session.lua` (mtime-sorted session listing) and `context.lua` (skill directory listing) in favour of `tether.readdir` + `tether.stat`.
- **Delete the `open_pipe` family** (`open_pipe`, `read_line`, `close_pipe`, `pipe_eof`) and its global pipe state from the C host. With the transport in process, no Lua module referenced it, and `tools.run` turned out to call `tether.exec` rather than `read_line`; the four primitives were dead code. `host` records this as a removed requirement, and `tether.exec` becomes the host's only shell primitive.
- **BREAKING**: The `run` tool is unchanged (still `/bin/sh -c` via `tether.exec` — a design decision, not an external dependency in the traditional sense), but the host's `open_pipe` family is gone; nothing linked against the C host, so the only in-repo consumers were the Lua modules, and none of them used it. The grep tool record shape is unchanged (`{path, line, column, text}`), with two documented krep differences: `column` is always 1, and krep applies its own skip lists for a few directories and extensions. The `api-client` capability's transport changes from shell-piped curl to in-process libcurl; the event shape and retry semantics are preserved.

## Capabilities

### New Capabilities
- `vendor-transport`: In-process HTTP(S) client using vendor'd libcurl + mbedTLS + zlib; replaces the curl shell pipe in `api.lua`. Exposes `tether.http_stream(method, url, headers, body, on_line, opts)` and `tether.http_get(url, headers, timeout_s)` to Lua; `api.lua` keeps its own `api.stream(cfg, key, messages, on_event)` surface unchanged.
- `vendor-tools`: krep-based `grep` backend, plus `tether.readdir`/`tether.stat`/`tether.mkdirp`/`tether.fchmod` C primitives; replaces all remaining external CLI tool invocations for file operations.

### Modified Capabilities
- `api-client`: The transport layer changes from "curl pipe via `open_pipe`" to "in-process libcurl". The requirement text that says "passed to curl via `--data-binary @<file>`" becomes "sent via in-process HTTP client"; all event shapes, retry semantics, and provider routing are unchanged.
- `host`: The C host gains four new `tether.*` primitives: `tether.mkdirp`, `tether.fchmod`, `tether.readdir`, `tether.stat`.
- `tools`: `grep` now runs through vendor'd krep (single in-process invocation, not the rg-then-grep fallback); `list` and `glob` use `tether.readdir` instead of `ls`/`find`; `session` listing uses `tether.readdir` + `tether.stat` mtime sort instead of `find … ls -1t`.
- `sessions`: The "list sessions by mtime" mechanism changes from shell pipeline to in-process stat sort. `Session picker data` is rewritten to state that the listing comes from `tether.readdir` + `tether.stat` and is capped at the 100 most recent files; the picker payload (`{id, mtime, ts, first_line}`) and the resume path are unchanged.

## Impact

- `src/host/main.c`: +4 new `tether.*` primitives, +~200 lines for krep integration (calls krep's `search_directory_recursive`), +~400 lines for libcurl/mbedTLS/shim layer
- `vendor/krep/`: new, ~5000 lines pure C (krep.c, krep.h, aho_corasick.c, aho_corasick.h, LICENSE)
- `vendor/curl/`: new, curl sources + `Makefile.curl` (the archives are built into the gitignored `build/`)
- `vendor/mbedtls/`: new, mbedTLS sources (~400 KB of objects)
- `vendor/zlib/`: new, zlib sources (~100 KB of objects)
- `src/tether/api.lua`: transport layer rewritten from shell-out to `tether.http_stream`/`tether.http_get`
- `src/tether/tools.lua`: `grep`, `glob`, `list` rewritten
- `src/tether/session.lua`: `list_session_files` rewritten
- `src/tether/context.lua`: `ls_subdirs` rewritten
- `Makefile`: link vendor'd static libraries; final binary grows from ~550 KB to ~2.1 MB (`ldd` shows only `libc` + `libm`)
- `tests/lua_tests.lua`: update curl mock seam (`open_pipe`) to new `tether.http_*` seam
