CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -O2 -D_POSIX_C_SOURCE=200809L
LUA_DIR = vendor/lua-5.4.6/src
EMBED_OUT = src/host/embed.c
LUA_MODS = src/tether/app.lua src/tether/ui.lua src/tether/transcript.lua src/tether/commands.lua src/tether/config.lua src/tether/session.lua src/tether/api.lua src/tether/agent.lua src/tether/tools.lua src/tether/diff.lua src/tether/retry.lua src/tether/ask.lua src/tether/confirm_policy.lua src/tether/providers/common.lua src/tether/providers/openai.lua src/tether/providers/anthropic.lua src/tether/providers/gemini.lua

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

$(EMBED_OUT): $(LUA_MODS) tools/embed.lua
	@lua tools/embed.lua $(EMBED_OUT) \
		app_lua src/tether/app.lua \
		ui_lua src/tether/ui.lua \
		transcript_lua src/tether/transcript.lua \
		commands_lua src/tether/commands.lua \
		config_lua src/tether/config.lua \
		session_lua src/tether/session.lua \
		provider_common_lua src/tether/providers/common.lua \
		provider_openai_lua src/tether/providers/openai.lua \
		provider_anthropic_lua src/tether/providers/anthropic.lua \
		provider_gemini_lua src/tether/providers/gemini.lua \
		api_lua src/tether/api.lua \
		retry_lua src/tether/retry.lua \
		ask_lua src/tether/ask.lua \
		confirm_policy_lua src/tether/confirm_policy.lua \
		context_lua src/tether/context.lua \
		agent_lua src/tether/agent.lua \
		tools_lua src/tether/tools.lua \
		diff_lua src/tether/diff.lua

test: tether
	@luac -p src/tether/app.lua
	@luac -p src/tether/ui.lua
	@luac -p src/tether/transcript.lua
	@luac -p src/tether/commands.lua
	@luac -p src/tether/config.lua
	@luac -p src/tether/session.lua
	@luac -p src/tether/api.lua
	@luac -p src/tether/providers/common.lua
	@luac -p src/tether/providers/openai.lua
	@luac -p src/tether/providers/anthropic.lua
	@luac -p src/tether/providers/gemini.lua
	@luac -p src/tether/agent.lua
	@luac -p src/tether/retry.lua
	@luac -p src/tether/ask.lua
	@luac -p src/tether/confirm_policy.lua
	@luac -p src/tether/context.lua
	@luac -p src/tether/tools.lua
	@luac -p src/tether/diff.lua
	@echo "=== luac ok ==="
	lua tests/lua_tests.lua
	@CTX_H=$$(mktemp -d); CTX_W=$$(mktemp -d); \
		rm -rf "$$CTX_H" "$$CTX_W"; mkdir -p "$$CTX_H" "$$CTX_W"; \
		HOME="$$CTX_H" TETHER_TEST_WORKSPACE="$$CTX_W" lua tests/context_tests.lua; rc=$$?; \
		rm -rf "$$CTX_H" "$$CTX_W"; \
		if [ $$rc -ne 0 ]; then exit $$rc; fi
	sh tests/context_e2e.sh "$(CURDIR)/tether"
	sh tests/host_smoke.sh
	@mkdir -p build
	$(CC) $(CFLAGS) -I$(LUA_DIR) -I$(KREP_DIR) -Ivendor/curl/include \
		-o $(HOST_TEST) tests/host_primitives_test.c \
		$(LUA_OBJS) $(KREP_OBJS) $(VENDOR_ARCHIVES) -lpthread -lm
	./$(HOST_TEST)

clean:
	rm -f tether
	rm -f $(LUA_OBJS)
	rm -f $(EMBED_OUT)
	rm -rf build

.PHONY: test clean
