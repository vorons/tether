#!/bin/sh
# tests/host_smoke.sh — M2: verify binary exists and EOF path exits 0
fail() { echo "FAIL: $1"; exit 1; }

[ -x ./tether ] || fail "./tether missing or not executable"

# EOF path: piped stdin -> read_char returns 0 -> clean exit
printf "abc" | ./tether > /dev/null 2>&1
code=$?
[ "$code" -eq 0 ] || fail "EOF path exit $code (expected 0)"

# /dev/null also exits 0
./tether </dev/null > /dev/null 2>&1
code=$?
[ "$code" -eq 0 ] || fail "/dev/null exit $code (expected 0)"

# SIGINT (external): the handler restores the terminal, then the process exits
# with the conventional 128+signum status (130) so a wrapper script can tell an
# interrupted run from a clean one. Stdin is a
# FIFO held open on fd 3 so the process stays alive waiting for input; tether is
# a direct background child (no pipeline), so `wait` returns its own status.
# A non-interactive shell starts background jobs with SIGINT ignored, so this
# requires the installed handler to actually terminate the process within the
# time box (without it the signal is ignored and the process lingers).
tmpd=$(mktemp -d)
fifo="$tmpd/stdin"
mkfifo "$fifo"
exec 3<>"$fifo"
./tether <"$fifo" > /dev/null 2>&1 &
pid=$!
sleep 1
kill -0 "$pid" 2>/dev/null || fail "SIGINT: process was not alive before the signal"
kill -INT "$pid" 2>/dev/null
i=0
while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i+1))
done
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exec 3>&-
    rm -rf "$tmpd"
    fail "SIGINT did not terminate the process (handler missing?)"
fi
wait "$pid"; code=$?
exec 3>&-
rm -rf "$tmpd"
[ "$code" -eq 130 ] || fail "SIGINT exit $code (expected 130 = 128+SIGINT)"

echo "PASS: all M2 smoke checks"
