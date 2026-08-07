#!/usr/bin/env python3
"""Run the spec's own expression examples against a real host, before publishing.

The release suite tests the package against its own assumptions. This runs the
*author's* forms — the lines the spec prints in its own body — through a built
host and reads the answer off the painted screen. That is the check that was
missing: a suite can be green while `round(price * quantity, 2)`, which §3.6.1
writes down as its example, renders as nothing.

    python3 run_corpus.py --port 7930

It builds a bundle from spec_expression_corpus.json, installs it, opens it via
the debug host's `app.open`, reads `ui.text`, and prints PASS/FAIL per case.
Exit code is non-zero if any case fails, so a release gate can call it.

Pairs with the unit half in the runtime package
(`test/spec/spec_expressions_test.dart`), which runs the same corpus through
the engine directly. Both are needed: the unit half runs on every change and
names the defect precisely; this half proves the value survives the whole way
to paint, which is where an empty string stops looking like a defect and starts
looking like a design.

Caveat, measured: a host caches an opened bundle, so after swapping the bundle
on disk the host must be restarted for the new document to be read. Cases that
were never painted are reported as such rather than counted as passes.
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "spec_expression_corpus.json")
BUNDLE_ID = "com.makemind.probe.corpus"


# --------------------------------------------------------------------------- MCP

class Debug:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.sid = None
        self.path = None
        self._handshake()

    def _post(self, path, payload):
        req = urllib.request.Request(
            self.base + path, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream",
                     **({"Mcp-Session-Id": self.sid} if self.sid else {})},
            method="POST")
        with urllib.request.urlopen(req, timeout=30) as r:
            if r.headers.get("Mcp-Session-Id"):
                self.sid = r.headers["Mcp-Session-Id"]
            raw = r.read().decode()
        if raw.startswith("event:") or "\ndata:" in raw or raw.startswith("data:"):
            raw = "\n".join(l[5:].strip() for l in raw.splitlines() if l.startswith("data:"))
        return json.loads(raw) if raw.strip() else None

    def _handshake(self):
        for p in ("/mcp", "/", "/message"):
            try:
                r = self._post(p, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                   "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                              "clientInfo": {"name": "corpus", "version": "1"}}})
            except Exception:
                continue
            if r and "result" in r:
                self.path = p
                self._post(p, {"jsonrpc": "2.0", "method": "notifications/initialized"})
                return
        raise SystemExit(f"no debug MCP on {self.base} — is a host running with debug enabled?")

    def call(self, name, args=None):
        r = self._post(self.path, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": {"name": name, "arguments": args or {}}})
        res = r.get("result", r)
        out = [c["text"] for c in res.get("content", []) if c.get("type") == "text"]
        return json.loads(out[0]) if out and out[0].lstrip().startswith("{") else out


# ----------------------------------------------------------------------- bundle

def build_bundle(corpus, dest):
    """One line per case: `<id>| <rendered>` so the reader can diff by id."""
    rows = [{"type": "text",
             "content": f"{c['id']}| {c['expr']}",
             "style": {"fontSize": 13}}
            for c in corpus["cases"]]

    page = {
        "type": "page",
        "metadata": {"title": "Spec expression corpus"},
        "state": {"initial": corpus["state"]},
        "content": {"type": "container", "padding": {"all": 16},
                    "child": {"type": "singleChildScrollView",
                              "child": {"type": "linear", "direction": "vertical",
                                        "children": rows}}},
    }
    app = {"type": "application", "title": "Spec expression corpus", "version": "1.4",
           "initialRoute": "/", "routes": {"/": "ui://pages/main"}}
    man = {"schemaVersion": "1.0.0",
           "manifest": {"id": BUNDLE_ID, "name": "Spec expression corpus", "version": "1.0.0",
                        "schemaVersion": "1.0.0", "type": "application", "entryPoint": "ui.app",
                        "description": "The spec's own expression examples, rendered."}}

    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(os.path.join(dest, "ui", "pages"), exist_ok=True)
    json.dump(man, open(os.path.join(dest, "manifest.json"), "w"), indent=1)
    json.dump(app, open(os.path.join(dest, "ui", "app.json"), "w"), indent=1)
    json.dump(page, open(os.path.join(dest, "ui", "pages", "main.json"), "w"), indent=1)


def install_dirs():
    """Every tier's installed-bundle directory that exists on this machine."""
    base = os.path.expanduser("~/Library/Application Support")
    out = []
    for name in os.listdir(base):
        if "ppplayer" in name.lower() or "ppPlayer" in name:
            d = os.path.join(base, name, "bundles")
            if os.path.isdir(d):
                out.append(d)
    return out


# ------------------------------------------------------------------------ check

def norm(v):
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    return str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="8081")
    ap.add_argument("--keep", action="store_true", help="leave the bundle installed")
    args = ap.parse_args()

    corpus = json.load(open(CORPUS))
    staged = os.path.join(HERE, "_corpus_build", f"{BUNDLE_ID}")
    build_bundle(corpus, staged)

    targets = install_dirs()
    if not targets:
        raise SystemExit("no AppPlayer bundle directory found")
    for t in targets:
        dst = os.path.join(t, BUNDLE_ID)
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(staged, dst)

    dbg = Debug(args.port)
    ids = {b["id"] for b in dbg.call("app.bundles").get("bundles", [])}
    if BUNDLE_ID not in ids:
        raise SystemExit(f"host does not see the bundle — it reads a different directory "
                         f"(saw: {sorted(ids)}). Restart the host after install.")
    dbg.call("app.open", {"id": BUNDLE_ID})
    time.sleep(3)

    painted = {}
    for t in dbg.call("ui.text").get("texts", []):
        s = t["text"].strip()
        if "|" in s:
            k, _, v = s.partition("|")
            painted[k.strip()] = v.strip()

    fails, passes, missing = [], [], []
    for c in corpus["cases"]:
        got = painted.get(c["id"])
        if got is None:
            missing.append(c["id"])
            continue
        if "expect" in c:
            ok = norm(got) == norm(c["expect"])
        elif c.get("expectNonEmptyList"):
            ok = got.startswith("[") and got != "[]" 
        else:
            ok = bool(got)
        (passes if ok else fails).append((c, got))

    print(f"\n  spec expression corpus — {len(passes)} pass · {len(fails)} FAIL"
          f"{f' · {len(missing)} not painted' if missing else ''}\n")
    for c, got in fails:
        known = c.get("known_failing")
        print(f"    FAIL  {c['id']:28} {c['spec']}")
        print(f"          {c['expr']}")
        print(f"          expected {c['expect'] if 'expect' in c else c.get('expectLength')!r}"
              f"   got {got!r}" + (f"   [known: {known}]" if known else ""))
    if missing:
        print(f"    not painted: {', '.join(missing)}")

    if not args.keep:
        for t in targets:
            shutil.rmtree(os.path.join(t, BUNDLE_ID), ignore_errors=True)

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
