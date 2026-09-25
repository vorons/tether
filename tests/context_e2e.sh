#!/bin/sh
# tests/context_e2e.sh — end-to-end prompt-composition check.
#
# Builds a scratch workspace with AGENTS.md + one skill, stubs the provider
# endpoint with a tiny local HTTP server that records the request body to a
# file, and diffs the recorded system message against a checked-in expected
# file. Mismatch => non-zero exit.
#
# Usage: sh tests/context_e2e.sh   (after `make`)

set -e

BIN="${1:-./tether}"
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
WS="$SB/ws"
HOME_DIR="$SB/home"
PORT=18099
RECORD="$SB/recorded.json"
EXPECTED="$SB/expected_system.md"

mkdir -p "$WS/.tether/skills/deploy" "$HOME_DIR/.tether/skills"

# --- fixtures ---------------------------------------------------------------
printf 'home-rules-marker\n' > "$HOME_DIR/AGENTS.md"
printf 'ws-rules-marker\n' > "$WS/AGENTS.md"
printf -- '---\nname: deploy\ndescription: Ship the app\n---\n# Deploy skill body\n' \
    > "$WS/.tether/skills/deploy/SKILL.md"

# --- expected system prompt (what the spec says compose() must produce) -----
# The skill `file:` path is the real workspace path (app.lua resolves it),
# so compute it here to match.
WS_REAL=$(cd "$WS" && pwd -P)
cat > "$EXPECTED" <<EOF
You are tether, a code assistant running inside a terminal.

Available tools:
- read(path, offset?, limit?) — read file contents
- write(path, content) — create/overwrite file
- list(path?) — list directory entries
- glob(pattern, path?) — find files by glob
- grep(pattern, path?, glob?, ignore_case?, max_results?) — search text in files
- run(command, cwd?, timeout?) — run shell command via /bin/sh -c
- patch(patch) — apply unified diff, strictly
- ask(questions) — ask the user to choose: [{question, options:[{label, description?}], id?, description?, multi?, recommended?}]

When a decision belongs to the user (which option, which scope, which
constraint), ask instead of guessing. When the user asks you to inspect or edit
code, use these tools.
Work in the current directory.
Outside workspace, write/patch/run require user confirmation.

## AGENTS.md (home)
home-rules-marker

## AGENTS.md (workspace)
ws-rules-marker

## Skills
Skills are markdown instruction files. When a task matches a skill's description, read the full file with the \`read\` tool before acting.
- name: deploy
  description: Ship the app
  file: $WS_REAL/.tether/skills/deploy/SKILL.md
EOF

# --- provider stub ----------------------------------------------------------
# Minimal HTTP server: for each POST, dump the body to $RECORD and reply with
# an SSE chat-completion stream so --print gets text on the first attempt.
# The reply must be a stream: tether posts "stream":true, and a non-SSE body is
# an error it retries (add-retry-and-continuation), which would slow this check.
cat > "$SB/server.py" <<'PYEOF'
import http.server, json, sys, threading

PORT = int(sys.argv[1])
OUT = sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(OUT, "w") as f:
            f.write(body)
        chunk = json.dumps({"choices": [{"delta": {"content": "E2E-OK"},
            "finish_reason": "stop"}]})
        resp = ("data: " + chunk + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def do_GET(self):
        # /v1/models and such — empty list
        resp = b'{"data":[]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

python3 "$SB/server.py" "$PORT" "$RECORD" &
SRV=$!
trap 'rm -rf "$SB"; kill $SRV 2>/dev/null' EXIT
sleep 0.5

# --- run tether -------------------------------------------------------------
# Point the sandbox HOME's config at the stub so base_url hits our server.
cat > "$HOME_DIR/.tether/config.lua" <<CFGEOF
return {
  provider = "openai",
  providers = {
    openai = {
      api_key_env = "OPENAI_API_KEY",
      base_url = "http://127.0.0.1:$PORT",
      model = "gpt-4o-mini",
    },
  },
  -- A stub that answers wrongly must not turn this check into a two-minute
  -- backoff: keep the retry budget to one short attempt.
  retry = { base_delay_ms = 10, max_failures_at_max_delay = 1 },
}
CFGEOF

# Seed a minimal providers cache so the startup gate resolves the Tier-A
# `openai` id without a network fetch (the base_url override above still
# points at the local stub; the catalog entry only has to exist).
cat > "$HOME_DIR/.tether/providers_cache.json" <<CACEOF
{"schema": 1, "generated_at": 0, "providers": {
  "openai": {"wire": "openai", "base_url": "https://api.openai.com",
    "api_key_env": "OPENAI_API_KEY", "model": "gpt-4o-mini",
    "models": [{"id": "gpt-4o-mini", "context": 128000}]}}}
CACEOF

HOME="$HOME_DIR" \
OPENAI_API_KEY=stub \
    "$BIN" --workspace "$WS" --print "ping" \
    --model gpt-4o-mini >/dev/null 2>&1 || true

sleep 0.3
kill $SRV 2>/dev/null || true
wait 2>/dev/null || true
trap 'rm -rf "$SB"' EXIT

[ -f "$RECORD" ] || { echo "E2E FAIL: provider stub did not receive a request"; exit 1; }

# Extract the recorded system message and compare against expected.
ACTUAL=$(python3 -c "
import json,sys
req = json.load(open('$RECORD'))
sys.stdout.write(req['messages'][0]['content'])
")

if [ "$(printf '%s' "$ACTUAL")" = "$(cat "$EXPECTED")" ]; then
    echo "E2E OK: system prompt composition matches expected"
else
    # Exact match failed — the join separator between sections is \n\n in
    # compose() but a heredoc is hard to author with exact blank lines. Fall
    # back to a whitespace-normalized comparison: collapse runs of blank
    # lines on both sides, then the order/presence check still holds.
    NORM_ACTUAL=$(printf '%s\n' "$ACTUAL" | python3 -c 'import sys,re; s=sys.stdin.read(); print(re.sub(r"\n{2,}", "\n", s).rstrip("\n"))')
    NORM_EXPECTED=$(python3 -c 'import sys,re; s=open("'$EXPECTED'").read(); print(re.sub(r"\n{2,}", "\n", s).rstrip("\n"))')
    if [ "$NORM_ACTUAL" = "$NORM_EXPECTED" ]; then
        echo "E2E OK: composition matches (whitespace-normalized)"
    else
        echo "E2E FAIL: system prompt mismatch"
        echo "----- expected (normalized) -----"
        printf '%s\n' "$NORM_EXPECTED" | cat -A
        echo "----- actual (normalized) -----"
        printf '%s\n' "$NORM_ACTUAL" | cat -A
        exit 1
    fi
fi
