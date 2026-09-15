CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -O2 -D_POSIX_C_SOURCE=200809L
LUA_DIR = vendor/lua-5.4.6/src
EMBED_OUT = src/host/embed.c
LUA_MODS = src/tether/app.lua src/tether/ui.lua src/tether/config.lua src/tether/session.lua src/tether/api.lua src/tether/agent.lua src/tether/tools.lua

LUA_SRCS = lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c \
           ldblib.c ldebug.c ldo.c ldump.c lfunc.c lgc.c linit.c \
           liolib.c llex.c lmathlib.c lmem.c loadlib.c lobject.c \
           lopcodes.c loslib.c lparser.c lstate.c lstring.c \
           lstrlib.c ltable.c ltablib.c ltm.c lundump.c lutf8lib.c \
           lvm.c lzio.c

LUA_OBJS = $(LUA_SRCS:%.c=$(LUA_DIR)/%.o)

tether: $(LUA_OBJS) src/host/main.c $(EMBED_OUT)
	$(CC) $(CFLAGS) -I$(LUA_DIR) -o $@ src/host/main.c $(LUA_OBJS) -lm

$(LUA_DIR)/%.o: $(LUA_DIR)/%.c
	$(CC) $(CFLAGS) -I$(LUA_DIR) -DLUA_USE_POSIX -c $< -o $@

$(EMBED_OUT): $(LUA_MODS) tools/embed.lua
	@lua tools/embed.lua $(EMBED_OUT) \
		app_lua src/tether/app.lua \
		ui_lua src/tether/ui.lua \
		config_lua src/tether/config.lua \
		session_lua src/tether/session.lua \
		api_lua src/tether/api.lua \
		agent_lua src/tether/agent.lua \
		tools_lua src/tether/tools.lua

test: tether
	sh tests/host_smoke.sh

clean:
	rm -f tether
	rm -f $(LUA_OBJS)
	rm -f $(EMBED_OUT)

.PHONY: test clean
