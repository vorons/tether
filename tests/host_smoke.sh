#!/bin/sh
# smoke: EOF path exits 0
if [ ! -x ./tether ]; then echo "FAIL: ./tether missing or not executable"; exit 1; fi
printf "ab" | ./tether > /dev/null 2>&1
code=$?
if [ "$code" -eq 0 ]; then echo "PASS: EOF exit 0"; else echo "FAIL: exit $code"; exit 1; fi
