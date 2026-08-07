#!/usr/bin/env python3
"""Drives a running AppPlayer through the probe bundle and reports what the
declared capabilities actually did.

Two questions per section, because either alone passes while the widget is
broken:

  * did it REPORT — `<key> err:` must read `(none)`. A capability that is
    absent says so (§6.13.2), so an empty string is itself a failure: something
    fired an error with nothing in it.
  * did it DRAW — the section's own strip of the screen must not be flat
    background. A pdf that reads no bytes draws an empty box and reports
    nothing at all; only the pixels catch that.

Exits non-zero on the first failing section so a publish gate can call it.
"""

import argparse
import base64
import io
import json
import struct
import sys
import time
import urllib.request
import zlib

HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


class Debug:
    """The debug MCP host, over its streamable-HTTP endpoint."""

    def __init__(self, port: int):
        self.url = f"http://127.0.0.1:{port}/mcp"
        headers, _ = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "capability-probe", "version": "1"}},
        })
        self.session = headers.get("mcp-session-id")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _post(self, body):
        headers = dict(HEADERS)
        if getattr(self, "session", None):
            headers["mcp-session-id"] = self.session
        request = urllib.request.Request(self.url, json.dumps(body).encode(), headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.headers, response.read().decode()

    def call(self, tool: str, arguments: dict):
        _, text = self._post({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                              "params": {"name": tool, "arguments": arguments}})
        for line in text.splitlines():
            if line.startswith("data: "):
                payload = json.loads(line[6:])
                return payload.get("result") or payload.get("error") or {}
        return {}

    def texts(self):
        result = self.call("ui.text", {})
        return json.loads(result["content"][0]["text"])["texts"]

    def screenshot(self) -> bytes:
        for item in self.call("ui.screenshot", {}).get("content", []):
            if item.get("type") == "image":
                return base64.b64decode(item["data"])
        raise RuntimeError("no image in ui.screenshot result")

    def tap(self, x: float, y: float):
        return self.call("ui.tap", {"x": x, "y": y})

    def scroll(self, x: float, y: float, dy: float):
        return self.call("ui.scroll", {"x": x, "y": y, "dy": dy})


def png_rows(data: bytes):
    """Decodes a PNG into rows of RGBA tuples. Enough of the format for a
    screenshot: 8-bit, colour type 6, no interlace — what the debug host
    produces."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a png")
    pos, width, height, idat = 8, 0, 0, bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            if depth != 8 or colour != 6:
                raise ValueError(f"unsupported png: depth {depth} colour {colour}")
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    raw = zlib.decompress(bytes(idat))
    stride = width * 4
    rows, previous = [], bytearray(stride)
    at = 0
    for _ in range(height):
        filter_type = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = previous[i]
            c = previous[i - 4] if i >= 4 else 0
            if filter_type == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(bytes(line))
        previous = line
    return width, height, rows


def painted_pixels(rows, width, top: int, bottom: int) -> int:
    """Pixels in the strip that differ from its own background.

    Counting distinct colours punished a widget that draws one strong shape on
    a flat page — a red square on black is two colours and unmistakably drawn.
    The background is whatever the strip holds most of; everything else is what
    the widget put there.
    """
    counts: dict[bytes, int] = {}
    for y in range(max(0, top), min(len(rows), bottom)):
        row = rows[y]
        for x in range(width):
            i = x * 4
            pixel = row[i:i + 3]
            counts[pixel] = counts.get(pixel, 0) + 1
    if not counts:
        return 0
    background = max(counts, key=lambda k: counts[k])

    def near(a: bytes, b: bytes) -> bool:
        return all(abs(a[i] - b[i]) <= 8 for i in range(3))

    return sum(n for pixel, n in counts.items() if not near(pixel, background))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7930)
    parser.add_argument("--bundle", default="Capability probe")
    parser.add_argument("--bundle-id", default="com.makemind.probe.capability")
    parser.add_argument("--min-painted", type=int, default=400,
                        help="pixels a section must put on top of its own "
                             "background to count as drawn")
    parser.add_argument("--platform-view", action="append",
                        default=["web", "video"],
                        help="sections drawn by a native view. A Flutter "
                             "screenshot does not capture those, so they are "
                             "judged by their report alone — the pixels would "
                             "read blank however well they work.")
    args = parser.parse_args()

    debug = Debug(args.port)

    # The door first: `app.open` reaches an installed bundle without touching
    # the user's app list. The launcher is the fallback for a tier that has not
    # wired it yet.
    listed = debug.call("app.bundles", {})
    if listed and listed.get("content"):
        try:
            ids = json.loads(listed["content"][0]["text"])["bundles"]
        except (KeyError, ValueError, TypeError):
            ids = []
        probe = next((b for b in ids if b["id"] == args.bundle_id), None)
        if probe is not None:
            opened = debug.call("app.open", {"id": args.bundle_id})
            if opened and not opened.get("isError"):
                time.sleep(5)
                return run_sections(debug, args)

    def find_tile():
        return next((t for t in debug.texts()
                     if t["text"] == args.bundle and t["rect"][0] > 0), None)

    tile = find_tile()
    if tile is None:
        # The launcher opens on Recent; a bundle installed for a gate has never
        # been used, so it lives under All apps.
        catalogue = next((t for t in debug.texts()
                          if t["text"] == "All apps" and t["rect"][0] > 0), None)
        if catalogue is not None:
            rect = catalogue["rect"]
            debug.tap(rect[0] + rect[2] / 2, rect[1] + rect[3] / 2)
            time.sleep(2)
            tile = find_tile()
    if tile is None:
        print(f"probe bundle '{args.bundle}' is not on the launcher — run "
              f"build_probe.py into this tier's bundle root and register_probe.py "
              f"for its preferences domain (with the app closed)",
              file=sys.stderr)
        return 2
    rect = tile["rect"]
    debug.tap(rect[0] + rect[2] / 2, rect[1] - 25)
    time.sleep(5)

    return run_sections(debug, args)


def run_sections(debug: "Debug", args) -> int:
    failures, checked = [], 0
    for _ in range(8):
        texts = debug.texts()
        shot = debug.screenshot()
        width, _, rows = png_rows(shot)
        reports = [t for t in texts if " err:" in t["text"]]
        for report in reports:
            name, _, value = report["text"].partition(" err:")
            value = value.strip()
            top = int(report["rect"][1]) - 230
            bottom = int(report["rect"][1]) - 10
            if top < 0 or bottom > len(rows):
                continue          # section is partly off-screen; a later pass takes it
            checked += 1
            if value != "(none)":
                failures.append(f"{name}: reported {value or '<empty>'}")
                continue
            if name in args.platform_view:
                continue
            drawn = painted_pixels(rows, width, top, bottom)
            if drawn < args.min_painted:
                failures.append(
                    f"{name}: reported nothing and drew nothing "
                    f"({drawn} pixels over its background)")
        debug.scroll(width / 2, 600, 1200)
        time.sleep(1.2)

    if not checked:
        print("no capability sections were read — the page did not open",
              file=sys.stderr)
        return 2
    if failures:
        print(f"capability probe FAILED ({len(failures)} of {checked} checks):",
              file=sys.stderr)
        for line in sorted(set(failures)):
            print(f"  - {line}", file=sys.stderr)
        return 1
    print(f"capability probe OK — {checked} section checks, all reported "
          f"(none) and drew")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
