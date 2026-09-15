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

echo "PASS: all M2 smoke checks"
