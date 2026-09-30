#!/usr/bin/env python3
"""Tests for tools/sync-providers.py shard output (offline-provider-catalog).

Stdlib unittest only: runs anywhere without extra dependencies.
Usage: python3 tests/sync_providers_tests.py
"""

import functools
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "tools", "sync-providers.py")

FIXTURE_API = {
    "deepseek": {
        "npm": "@ai-sdk/openai-compatible",
        "api": "https://api.deepseek.com/v1",
        "env": ["DEEPSEEK_API_KEY"],
        "models": {
            "deepseek-chat": {"limit": {"context": 128000}},
            "deepseek-old": {"limit": {"context": 64000},
                             "status": "deprecated"},
        },
    },
}

EMPTY_OVERRIDES = {
    "endpoints.json": {},
    "url_templates.json": {},
    "wires.json": {},
    "defaults.json": {},
    "headers.json": {},
    "aliases.json": {},
    "extra.json": {},
    "skip.json": [],
}


def write_overrides(path):
    os.makedirs(path, exist_ok=True)
    for name, payload in EMPTY_OVERRIDES.items():
        with open(os.path.join(path, name), "w",
                  encoding="utf-8") as f:
            json.dump(payload, f)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve(directory):
    handler = functools.partial(QuietHandler, directory=directory)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    return srv


def run_sync(api_url, overrides, out):
    return subprocess.run(
        [sys.executable, SCRIPT, "--api", api_url,
         "--overrides", overrides, "--out", out],
        capture_output=True, text=True)


class ShardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        with open(os.path.join(self.root, "api.json"), "w",
                  encoding="utf-8") as f:
            json.dump(FIXTURE_API, f)
        self.srv = serve(self.root)
        self.addCleanup(self.srv.shutdown)
        self.addCleanup(self.srv.server_close)
        self.api = "http://127.0.0.1:%d/api.json" % self.srv.server_port
        self.ov = os.path.join(self.root, "ov")
        write_overrides(self.ov)
        self.out = os.path.join(self.root, "out", "providers.json")

    def test_shards_match_main_file(self):
        proc = run_sync(self.api, self.ov, self.out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(self.out, encoding="utf-8") as f:
            main = json.load(f)
        shard_path = os.path.join(self.root, "out", "providers",
                                  "deepseek.json")
        with open(shard_path, encoding="utf-8") as f:
            shard = json.load(f)
        self.assertEqual(shard["schema"], main["schema"])
        self.assertEqual(shard["generated_at"], main["generated_at"])
        self.assertEqual(shard["id"], "deepseek")
        self.assertEqual(shard["models"],
                         main["providers"]["deepseek"]["models"])
        self.assertEqual(
            [m["id"] for m in shard["models"]],
            ["deepseek-chat", "deepseek-old"])

    def test_stale_shards_removed(self):
        shards = os.path.join(self.root, "out", "providers")
        os.makedirs(shards, exist_ok=True)
        stale = os.path.join(shards, "stale.json")
        with open(stale, "w", encoding="utf-8") as f:
            f.write("{}")
        proc = run_sync(self.api, self.ov, self.out)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(
            os.path.join(shards, "deepseek.json")))

    def test_outage_writes_nothing(self):
        dead_api = "http://127.0.0.1:1/api.json"
        proc = run_sync(dead_api, self.ov, self.out)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(os.path.exists(self.out))
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "out", "providers")))


if __name__ == "__main__":
    unittest.main()
