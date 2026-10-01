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

# T335 (M12): raw mode belongs to the TUI only. Under a pty,
# --version must emit only its version line (no termios/alternate-screen
# bytes), and a blocking non-TUI verb (remove prompt) must keep ECHO/ISIG
# on so Ctrl+C terminates it with 130. --print shares the same main()
# entry (never reaches ui.run), so the same guarantee holds; its pty run
# must also carry no mode bytes.
python3 - <<'PYEOF'
import os, pty, select, sys, termios, time

def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)

# T335a: --version emits only its version line, no mode bytes.
pid, fd = pty.fork()
if pid == 0:
    os.execv("./tether", ["tether", "--version"])
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.close(fd)
_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
if code != 0:
    fail("--version pty exit %r (expected 0)" % code)
if b"\x1b" in out:
    fail("--version pty emitted escape bytes: %r" % out[:200])
for marker in (b"?1049", b"[<u", b">4;0m", b"?1000", b"?2004"):
    if marker in out:
        fail("--version pty emitted mode bytes %r: %r" % (marker, out[:200]))
text = out.replace(b"\r", b"").decode("utf-8", "replace").strip()
lines = [ln for ln in text.split("\n") if ln.strip()]
if len(lines) != 1 or not lines[0].startswith("tether "):
    fail("--version pty output not a single version line: %r" % out[:200])
print("T335a: --version pty clean (%s)" % lines[0])

# T335b: blocking non-TUI verb keeps ECHO/ISIG; Ctrl+C (0x03) kills it.
import tempfile
tmpd = tempfile.mkdtemp(prefix="t335-")
pid, fd = pty.fork()
if pid == 0:
    os.environ["HOME"] = tmpd
    os.environ["TETHER_HOME"] = tmpd
    os.execv("./tether", ["tether", "remove", "dummy-no-such-ext"])
out = b""
deadline = time.time() + 8
while b"[y/N]" not in out and time.time() < deadline:
    r, _, _ = select.select([fd], [], [], max(0, deadline - time.time()))
    if not r:
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
if b"[y/N]" not in out:
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    fail("remove prompt never appeared: %r" % out[:200])
try:
    attrs = termios.tcgetattr(fd)
except termios.error as e:
    fail("tcgetattr failed: %r" % e)
if not (attrs[3] & termios.ECHO):
    fail("ECHO off during non-TUI run (raw mode leaked)")
if not (attrs[3] & termios.ISIG):
    fail("ISIG off during non-TUI run (Ctrl+C would not signal)")
os.write(fd, b"\x03")
end = time.time() + 3
status = None
while time.time() < end:
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
    time.sleep(0.05)
if status is None:
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    fail("Ctrl+C did not terminate the non-TUI run (ISIG off?)")
code = os.waitstatus_to_exitcode(status)
if code != 130:
    fail("Ctrl+C exit %r (expected 130 = 128+SIGINT)" % code)
if b"\x1b[?1049" in out or b"[<u" in out:
    fail("non-TUI run emitted mode bytes: %r" % out[:200])
os.close(fd)
print("T335b: non-TUI keeps ECHO/ISIG, Ctrl+C -> 130")

# T335c: --print under a pty carries no mode bytes (same entry as above;
# ui.run/terminal_enter is only reached by the interactive path).
pid, fd = pty.fork()
if pid == 0:
    os.environ["HOME"] = tmpd
    os.environ["TETHER_HOME"] = tmpd
    os.execv("./tether", ["tether", "--print", "x"])
import errno
out = b""
end = time.time() + 10
alive = True
status = None
while time.time() < end:
    r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            out += chunk
            if b"\x1b[?1049" in out or b"[<u" in out:
                fail("--print pty emitted mode bytes: %r" % out[:200])
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        # Drain anything left behind the exit.
        try:
            while True:
                r2, _, _ = select.select([fd], [], [], 0.2)
                if not r2:
                    break
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        status = st
        alive = False
        break
if alive:
    # Still running (waiting on providers/network): ECHO/ISIG must be on.
    try:
        attrs = termios.tcgetattr(fd)
        if not (attrs[3] & termios.ECHO) or not (attrs[3] & termios.ISIG):
            fail("--print left cooked mode (ECHO/ISIG off)")
    except termios.error:
        pass
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
else:
    if b"\x1b" in out:
        fail("--print pty emitted escape bytes: %r" % out[:200])
os.close(fd)
import shutil
shutil.rmtree(tmpd, ignore_errors=True)
print("T335c: --print pty carries no mode bytes")
PYEOF

echo "PASS: all M2 smoke checks (incl. T335 raw-mode-is-TUI-only)"
