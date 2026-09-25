#!/usr/bin/env python3
"""Sync tether's provider catalog from models.dev.

Fetches https://models.dev/api.json, projects it to the tether providers
schema (data/providers.json), merges data/overrides/, and writes the result.

Principles (see openspec change dynamic-provider-catalog):
- Endpoints are never invented: an OpenAI/Anthropic/Gemini-wire entry
  without a verified base_url is skipped with a warning, not shipped broken.
- Unknown future npm values fail loudly (non-zero exit), never ship a
  wrong wire. All currently-known exotic ids must be covered by
  data/overrides/{wires,skip}.json instead.
- Output is deterministic (sorted keys, indent=1) so git diffs are reviewable.

Usage:
    python3 tools/sync-providers.py [--api URL] [--overrides DIR] [--out PATH]
"""

import argparse
import json
import re
import sys
import time
import urllib.request

USER_AGENT = "tether-sync/1.0"
SCHEMA_VERSION = 1

# npm package -> tether wire. Entries NOT listed here must be resolved via
# data/overrides/wires.json (explicit wire) or data/overrides/skip.json
# (explicit skip); anything else is a loud failure.
NPM_WIRE = {
    "@ai-sdk/openai-compatible": "openai",
    "@ai-sdk/openai": "openai",
    "@ai-sdk/anthropic": "anthropic",
    "@ai-sdk/google": "gemini",
    # First-party packages over OpenAI-compatible HTTP APIs. The endpoint
    # still has to come from the api field or endpoints.json.
    "@ai-sdk/xai": "openai",
    "@ai-sdk/groq": "openai",
    "@ai-sdk/cerebras": "openai",
    "@ai-sdk/mistral": "openai",
    "@ai-sdk/deepinfra": "openai",
    "@ai-sdk/togetherai": "openai",
    "@ai-sdk/perplexity": "openai",
    "@ai-sdk/cohere": "openai",
    "@ai-sdk/azure": "azure-openai",
    "@ai-sdk/amazon-bedrock": "amazon-bedrock",
    "@ai-sdk/google-vertex": "google-vertex",
    "@openrouter/ai-sdk-provider": "openai",
    "ai-gateway-provider": "cloudflare-ai-gateway",
    "venice-ai-sdk-provider": "openai",
}

TIER_B_WIRES = {
    "azure-openai",
    "amazon-bedrock",
    "google-vertex",
    "cloudflare-ai-gateway",
    "radius",
    "openai-codex",
}

NATIVE_WIRES = {"openai", "anthropic", "gemini"}


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def fetch_api(url):
    req = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "identity"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        if resp.status != 200:
            raise RuntimeError("HTTP %s fetching %s" % (resp.status, url))
        return json.load(resp)


def normalize_endpoint(url):
    # models.dev templates use ${VAR}; tether expands {VAR} (see expand_url).
    if isinstance(url, str) and "${" in url:
        url = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", r"{\1}", url)
    # Wires append their own paths (e.g. "/chat/completions",
    # "/v1/messages"), so a trailing slash would double it.
    if isinstance(url, str) and len(url) > 1:
        url = url.rstrip("/")
    return url


def pick_default(pid, models, pinned):
    if pinned:
        return pinned
    cands = [
        (mid, m)
        for mid, m in models.items()
        if isinstance(m, dict) and m.get("status") != "deprecated"
    ]
    if not cands:
        cands = list(models.items())
    if not cands:
        return ""
    # Newest non-deprecated by last_updated, then release_date; tie: alphabetical.
    def key(item):
        mid, m = item
        if not isinstance(m, dict):
            return ("", "", mid)
        return (m.get("last_updated") or "", m.get("release_date") or "", mid)

    cands.sort(key=key)
    return cands[-1][0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="https://models.dev/api.json")
    ap.add_argument("--overrides", default="data/overrides")
    ap.add_argument("--out", default="data/providers.json")
    args = ap.parse_args()

    ov = args.overrides
    endpoints = load_json("%s/endpoints.json" % ov)
    url_templates = load_json("%s/url_templates.json" % ov)
    wire_ov = load_json("%s/wires.json" % ov)
    skip_ids = set(load_json("%s/skip.json" % ov))
    default_pins = load_json("%s/defaults.json" % ov)
    headers_ov = load_json("%s/headers.json" % ov)
    aliases = load_json("%s/aliases.json" % ov)
    extra = load_json("%s/extra.json" % ov)

    upstream = fetch_api(args.api)
    providers = {}
    skipped = []
    failures = []

    for pid in sorted(upstream.keys()):
        if pid in skip_ids:
            skipped.append((pid, "explicit skip list"))
            continue
        p = upstream[pid]
        npm = p.get("npm", "")
        wire = wire_ov.get(pid, NPM_WIRE.get(npm))
        if wire is None:
            failures.append(
                "%s: unknown npm %r (add to wires.json or skip.json)" % (pid, npm)
            )
            continue
        if wire not in NATIVE_WIRES and wire not in TIER_B_WIRES:
            failures.append("%s: unknown wire %r" % (pid, wire))
            continue

        # endpoints.json wins over upstream: it holds reviewed
        # tether-specific corrections (wire path conventions, auth-tested
        # hosts, preserved product endpoints). Never invented, only pinned.
        base_url = normalize_endpoint(
            endpoints.get(pid) or p.get("api") or ""
        )
        url_template = url_templates.get(pid, "")
        if wire in NATIVE_WIRES and not base_url and not url_template:
            skipped.append((pid, "no verified endpoint (never invented)"))
            continue

        models = p.get("models") or {}
        model_list = []
        for mid in sorted(models.keys()):
            m = models[mid] if isinstance(models[mid], dict) else {}
            ctx = (m.get("limit") or {}).get("context")
            model_list.append(
                {"id": mid, "context": ctx if isinstance(ctx, int) else None}
            )

        entry = {
            "wire": wire,
            "api_key_env": p.get("env") or [],
        }
        if url_template:
            entry["url_template"] = url_template
        else:
            entry["base_url"] = base_url
        entry["model"] = pick_default(pid, models, default_pins.get(pid))
        if headers_ov.get(pid):
            entry["extra_headers"] = headers_ov[pid]
        entry["models"] = model_list
        providers[pid] = entry

    # Aliases duplicate an existing entry under a second id (naming bridges).
    for alias, target in sorted(aliases.items()):
        if target not in providers:
            failures.append("alias %s -> missing target %s" % (alias, target))
            continue
        if alias in providers:
            failures.append("alias %s collides with upstream id" % alias)
            continue
        providers[alias] = dict(providers[target])
        if alias in default_pins:
            providers[alias]["model"] = default_pins[alias]

    # Full entries for ids models.dev does not carry (pi-specific, local).
    for pid in sorted(extra.keys()):
        e = extra[pid]
        if pid in providers:
            failures.append("extra %s collides with generated id" % pid)
            continue
        wire = e.get("wire")
        if wire not in NATIVE_WIRES and wire not in TIER_B_WIRES:
            failures.append("extra %s: unknown wire %r" % (pid, wire))
            continue
        if wire in NATIVE_WIRES and not e.get("base_url") and not e.get(
            "url_template"
        ):
            failures.append("extra %s: native wire without endpoint" % pid)
            continue
        entry = {
            "wire": wire,
            "api_key_env": e.get("api_key_env") or [],
            "model": e.get("model") or "",
            "models": e.get("models") or [],
        }
        if e.get("url_template"):
            entry["url_template"] = e["url_template"]
        else:
            entry["base_url"] = e.get("base_url") or ""
        if e.get("extra_headers"):
            entry["extra_headers"] = e["extra_headers"]
        providers[pid] = entry

    if failures:
        for f in failures:
            print("sync-providers: ERROR %s" % f, file=sys.stderr)
        sys.exit(1)

    out = {
        "schema": SCHEMA_VERSION,
        "generated_at": int(time.time()),
        "providers": providers,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")

    print(
        "sync-providers: %d providers -> %s (skipped %d)"
        % (len(providers), args.out, len(skipped))
    )
    for pid, reason in skipped:
        print("sync-providers: skip %s (%s)" % (pid, reason))


if __name__ == "__main__":
    main()
