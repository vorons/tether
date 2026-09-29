CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -O2 -D_POSIX_C_SOURCE=200809L

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
	$(CC) -std=c11 -O2 -w -I$(MBEDTLS_DIR)/include -c $< -o $@

build/libmbedtls_vend.a: $(MBEDTLS_OBJS)
	@mkdir -p build
	ar rcs $@ $(MBEDTLS_OBJS)

# zlib only pulls in <unistd.h> (lseek) when HAVE_UNISTD_H is defined, which
# is what its own ./configure normally does; -std=gnu11 keeps the rest of the
# glibc declarations visible on modern GCC.
build/zlib/%.o: $(ZLIB_DIR)/%.c
	@mkdir -p build/zlib
	$(CC) -std=gnu11 -O2 -w -DHAVE_UNISTD_H=1 -I$(ZLIB_DIR) -c $< -o $@

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

# test-speed: unit files run under xargs -P (bounded by NPROC, default
# nproc) with per-file logs in build/test-logs (gitignored). Failures
# print the file name plus a tail of its log; exit is non-zero iff any
# file failed. Same files, same env (own LUA_HOME), same green criteria
# as the old sequential loop (rollback: git revert this hunk).
NPROC ?= $(shell nproc 2>/dev/null || echo 8)
TEST_FILES = $(filter-out tests/context_tests.lua,$(wildcard tests/*_tests.lua))

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

.PHONY: test clean
