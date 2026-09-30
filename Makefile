CC      ?= cc
# OPT is the optimization level shared by every compile rule (own code and
# vendored deps). Default stays portable -O2; `make release` overrides it
# with the full set (-O3 -march=native -flto -DNDEBUG).
OPT     ?= -O2
# -Werror stays on for dev builds; `make release` clears it because LTO
# surfaces vendor warnings at link time that would otherwise fail the link.
WERROR  ?= -Werror
CFLAGS  ?= -std=c11 -Wall -Wextra $(WERROR) $(OPT) -D_POSIX_C_SOURCE=200809L

# Vendored archive rules sit above `tether`, so GNU make would pick the first
# one as the default goal; name the binary explicitly instead.
.DEFAULT_GOAL := tether

LUA_DIR = vendor/lua-5.4.6/src
EMBED_OUT = src/host/embed.c
# Module registration is generated from tools/embed_order.txt (single source
# of truth). GNU make remakes the include first and re-execs, so a fresh
# clone and an edited order file both work with no hand edits here.
include build/embed_list.mk
EMBED_GEN = tools/gen_embed.lua tools/embed_order.txt
build/embed_list.mk src/host/embed_mods.inc: $(EMBED_GEN)
	@mkdir -p build
	@lua tools/gen_embed.lua tools/embed_order.txt build/embed_list.mk src/host/embed_mods.inc

LUA_SRCS = lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c \
           ldblib.c ldebug.c ldo.c ldump.c lfunc.c lgc.c linit.c \
           liolib.c llex.c lmathlib.c lmem.c loadlib.c lobject.c \
           lopcodes.c loslib.c lparser.c lstate.c lstring.c \
           lstrlib.c ltable.c ltablib.c ltm.c lundump.c lutf8lib.c \
           lvm.c lzio.c

LUA_OBJS = $(LUA_SRCS:%.c=$(LUA_DIR)/%.o)

# Vendor'd krep engine (grep backend). -DTESTING drops krep's own main().
KREP_DIR = vendor/krep
KREP_OBJS = build/krep.o build/aho_corasick.o
HOST_TEST = build/host_primitives_test

# Vendor'd static deps for the in-process HTTPS transport. The archives are
# assembled into build/ (gitignored); nothing is downloaded at build time.
VENDOR_ARCHIVES = build/libcurl_vend.a build/libmbedtls_vend.a build/libz_vend.a

MBEDTLS_DIR = vendor/mbedtls
MBEDTLS_SRCS = $(wildcard $(MBEDTLS_DIR)/library/*.c)
MBEDTLS_OBJS = $(patsubst $(MBEDTLS_DIR)/library/%.c,build/mbedtls/%.o,$(MBEDTLS_SRCS))

ZLIB_DIR = vendor/zlib
ZLIB_SRCS = $(wildcard $(ZLIB_DIR)/*.c)
ZLIB_OBJS = $(patsubst $(ZLIB_DIR)/%.c,build/zlib/%.o,$(ZLIB_SRCS))

# Vendored code is compiled warning-free-by-default: -w keeps the project's
# -Werror from turning upstream warnings into build failures.
build/mbedtls/%.o: $(MBEDTLS_DIR)/library/%.c
	@mkdir -p build/mbedtls
	$(CC) -std=c11 $(OPT) -w -I$(MBEDTLS_DIR)/include -c $< -o $@

build/libmbedtls_vend.a: $(MBEDTLS_OBJS)
	@mkdir -p build
	ar rcs $@ $(MBEDTLS_OBJS)

# zlib only pulls in <unistd.h> (lseek) when HAVE_UNISTD_H is defined, which
# is what its own ./configure normally does; -std=gnu11 keeps the rest of the
# glibc declarations visible on modern GCC.
build/zlib/%.o: $(ZLIB_DIR)/%.c
	@mkdir -p build/zlib
	$(CC) -std=gnu11 $(OPT) -w -DHAVE_UNISTD_H=1 -I$(ZLIB_DIR) -c $< -o $@

build/libz_vend.a: $(ZLIB_OBJS)
	@mkdir -p build
	ar rcs $@ $(ZLIB_OBJS)

# curl's sources, its hand-crafted config and the vendor makefile are all real
# prerequisites: without them make would treat an existing archive as current.
CURL_SRCS = $(wildcard vendor/curl/lib/*.c vendor/curl/lib/*/*.c)

build/libcurl_vend.a: $(CURL_SRCS) vendor/curl/Makefile.curl vendor/curl/lib/curl_config.h
	@mkdir -p build
	$(MAKE) -C vendor/curl -f Makefile.curl \
		OBJDIR=$(CURDIR)/build/curl-obj \
		ARCHIVE=$(CURDIR)/build/libcurl_vend.a

tether: $(LUA_OBJS) src/host/main.c $(EMBED_OUT) $(KREP_OBJS) $(VENDOR_ARCHIVES)
	$(CC) $(CFLAGS) -I$(LUA_DIR) -I$(KREP_DIR) -Ivendor/curl/include \
		-I$(MBEDTLS_DIR)/include \
		-o $@ src/host/main.c $(LUA_OBJS) $(KREP_OBJS) $(VENDOR_ARCHIVES) \
		-lpthread -lm
	# UPX-pack the binary (--best --lzma, same as `release`).
	# PACK=0 skips it (used by `release`, which strips first and packs
	# last); a missing upx is a warning, not an error, so minimal
	# environments and CI without upx keep building.
	@if [ "$(PACK)" = 0 ]; then exit 0; fi; \
	if command -v upx >/dev/null 2>&1; then upx -q --best --lzma $@; \
	else echo "tether: upx not found, skipping pack"; fi

build/krep.o: $(KREP_DIR)/krep.c
	@mkdir -p build
	$(CC) $(CFLAGS) -DTESTING -I$(KREP_DIR) -c $< -o $@

build/aho_corasick.o: $(KREP_DIR)/aho_corasick.c
	@mkdir -p build
	$(CC) $(CFLAGS) -DTESTING -I$(KREP_DIR) -c $< -o $@

$(LUA_DIR)/%.o: $(LUA_DIR)/%.c
	$(CC) $(CFLAGS) -I$(LUA_DIR) -DLUA_USE_POSIX -c $< -o $@

$(EMBED_OUT): $(LUA_MODS) tools/embed.lua build/embed_list.mk src/host/embed_mods.inc
	@lua tools/embed.lua $(EMBED_OUT) $(EMBED_ARGS)

# offline-provider-catalog: vendored slim snapshot. Built from the committed
# data file with no network; EMBED_OUT already depends on it via LUA_MODS
# (embed_order.txt points at the build path).
# build/version.lua embeds the git short hash (--version, splash); "dev"
# without .git (override with `make tether TETHER_VERSION=...`). CI always
# fresh-clones, so the hash is current there.
build/version.lua: tools/gen-version.lua
	@mkdir -p build
	@lua tools/gen-version.lua build/version.lua $(TETHER_VERSION)

build/providers_snapshot.lua: data/providers.json tools/gen-snapshot.lua
	@mkdir -p build
	@lua tools/gen-snapshot.lua data/providers.json build/providers_snapshot.lua

# test-speed: unit files run under xargs -P (bounded by NPROC, default
# nproc) with per-file logs in build/test-logs (gitignored). Failures
# print the file name plus a tail of its log; exit is non-zero iff any
# file failed. Same files, same env (own LUA_HOME), same green criteria
# as the old sequential loop (rollback: git revert this hunk).
NPROC ?= $(shell nproc 2>/dev/null || echo 8)
TEST_FILES = $(filter-out tests/context_tests.lua,$(wildcard tests/*_tests.lua))

# test-speed: fast red-green path. `make smoke` runs luac over all
# modules plus an explicit list of core unit files (<1s) — use it while
# iterating on a change. `make test` (parallel units + context + e2e +
# host) stays the merge gate — run it green before commit/merge.
# The smoke list is explicit by design (no last-commit heuristic, which
# goes wrong on rebases); override per change on the command line:
#   make smoke SMOKE_FILES="tests/rows_tests.lua tests/flow_tests.lua"
SMOKE_FILES ?= tests/keys_tests.lua tests/compression_tests.lua \
	tests/copy_tests.lua tests/markdown_tests.lua tests/highlight_tests.lua \
	tests/palette_tests.lua tests/tool_dispatch_tests.lua tests/busy_tests.lua \
	tests/auth_flow_tests.lua tests/ask_view_tests.lua

smoke: build/providers_snapshot.lua build/version.lua
	@for m in $(LUA_MODS); do luac -p $$m || exit $$?; done
	@echo "=== luac ok ==="
	@for t in $(SMOKE_FILES); do \
		H=$$(mktemp -d); rm -rf "$$H"; mkdir -p "$$H"; \
		HOME="$$H" TETHER_HOME="$$H" lua $$t || exit $$?; \
		rm -rf "$$H"; \
	done
	@echo "=== smoke ok ==="

test: tether
	# 6.1: the syntax check covers every embedded module with no manual
	# list — LUA_MODS is generated from tools/embed_order.txt (the same
	# single source as the binary embed). Adding a module to the order
	# file covers it here automatically.
	@for m in $(LUA_MODS); do luac -p $$m || exit $$?; done
	@echo "=== luac ok ==="
	@rm -rf build/test-logs && mkdir -p build/test-logs
	@printf '%s\n' $(TEST_FILES) | xargs -P$(NPROC) -n1 sh -c \
		'H=$$(mktemp -d); rm -rf "$$H"; mkdir -p "$$H"; \
		HOME="$$H" TETHER_HOME="$$H" lua "$$0" > "build/test-logs/$$(basename "$$0" .lua).log" 2>&1 \
		|| echo "$$(basename "$$0" .lua)"; rm -rf "$$H"' \
		> build/test-logs/failures.txt || exit $$?; \
		if [ -s build/test-logs/failures.txt ]; then \
			for f in $$(cat build/test-logs/failures.txt); do \
				echo "=== FAIL $$f ==="; tail -n 50 "build/test-logs/$$f.log"; \
			done; \
			exit 1; \
		fi
	@echo "=== unit files ok ==="
	@python3 tests/sync_providers_tests.py
	@CTX_H=$$(mktemp -d); CTX_W=$$(mktemp -d); \
		rm -rf "$$CTX_H" "$$CTX_W"; mkdir -p "$$CTX_H" "$$CTX_W"; \
		HOME="$$CTX_H" TETHER_TEST_WORKSPACE="$$CTX_W" lua tests/context_tests.lua; rc=$$?; \
		rm -rf "$$CTX_H" "$$CTX_W"; \
		if [ $$rc -ne 0 ]; then exit $$rc; fi
	sh tests/context_e2e.sh "$(CURDIR)/tether"
	sh tests/host_smoke.sh
	@mkdir -p build
	$(CC) $(CFLAGS) -I$(LUA_DIR) -I$(KREP_DIR) -Ivendor/curl/include \
		-I$(MBEDTLS_DIR)/include \
		-o $(HOST_TEST) tests/host_primitives_test.c \
		$(LUA_OBJS) $(KREP_OBJS) $(VENDOR_ARCHIVES) -lpthread -lm
	./$(HOST_TEST)

clean:
	rm -f tether
	rm -f $(LUA_OBJS)
	rm -f $(EMBED_OUT)
	rm -rf build

# install: build, then drop the self-contained binary on PATH. Default is
# the user tree (~/.local/bin, no root needed); DESTDIR offsets the whole
# path for staging/packaging:
#   make install
#   sudo make install PREFIX=/usr/local
#   make install DESTDIR=$PWD/pkg
# Depends on `tether`, so `make release && make install` installs the
# optimized binary without rebuilding it.
PREFIX  ?= $(HOME)/.local
DESTDIR ?=
install: tether
	@mkdir -p $(DESTDIR)$(PREFIX)/bin
	install -m 755 tether $(DESTDIR)$(PREFIX)/bin/tether

# release: maximum-optimization build for distribution. Non-portable
# (-march=native), asserts off (-DNDEBUG), link-time optimization, stripped
# and UPX-packed. Separate from the default build so dev iteration stays
# fast and portable. PACK=0 here: the tether rule must not pre-pack, since
# strip runs first and the final pack is --best --lzma below.
release:
	@$(MAKE) clean >/dev/null
	@$(MAKE) tether OPT="-O3 -march=native -flto=auto -DNDEBUG" WERROR= PACK=0
	@strip --strip-all tether
	@upx --best --lzma tether
	@ls -la tether

.PHONY: test smoke clean release install
