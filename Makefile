CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2

tether: src/host/main.c
	$(CC) $(CFLAGS) -o $@ $<

test: tether
	sh tests/host_smoke.sh

clean:
	rm -f tether

.PHONY: test clean
