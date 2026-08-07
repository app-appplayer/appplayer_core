#!/usr/bin/env python3
"""Writes the capability probe bundle: one page that exercises every declared
capability, each section reporting its own failure into its own state key.

The assets are generated, not checked in: a WAV whose amplitude ramps (so a
waveform that ignores the samples cannot fake it), a one-page PDF with visible
text, and a Lottie animation of a moving square.
"""

import json
import math
import os
import struct
import sys
import wave


def write_wav(path: str) -> None:
    sample_rate, seconds = 22050, 3.0
    frames = []
    for i in range(int(sample_rate * seconds)):
        t = i / sample_rate
        # Ramps from silence to full: a waveform drawn from anything other than
        # these samples will not have that shape.
        value = math.sin(2 * math.pi * 440 * t) * (t / seconds) * 0.9
        frames.append(struct.pack("<h", int(value * 32767)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(b"".join(frames))


def write_pdf(path: str) -> None:
    content = b"BT /F1 36 Tf 60 700 Td (AppPlayer PDF probe) Tj ET"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % index + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        xref,
    )
    open(path, "wb").write(bytes(out))


def write_lottie(path: str) -> None:
    json.dump(
        {
            "v": "5.7.4", "fr": 30, "ip": 0, "op": 60, "w": 200, "h": 200,
            "nm": "probe", "ddd": 0, "assets": [],
            "layers": [{
                "ddd": 0, "ind": 1, "ty": 4, "nm": "box", "sr": 1,
                "ks": {
                    "o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0},
                    "p": {"a": 1, "k": [
                        {"t": 0, "s": [40, 100, 0], "e": [160, 100, 0],
                         "i": {"x": [0.5], "y": [1]}, "o": {"x": [0.5], "y": [0]}},
                        {"t": 60, "s": [160, 100, 0]}]},
                    "a": {"a": 0, "k": [0, 0, 0]},
                    "s": {"a": 0, "k": [100, 100, 100]},
                },
                "ao": 0,
                "shapes": [{"ty": "gr", "it": [
                    {"ty": "rc", "d": 1, "s": {"a": 0, "k": [60, 60]},
                     "p": {"a": 0, "k": [0, 0]}, "r": {"a": 0, "k": 0}},
                    {"ty": "fl", "c": {"a": 0, "k": [1, 0, 0, 1]},
                     "o": {"a": 0, "k": 100}},
                    {"ty": "tr", "p": {"a": 0, "k": [0, 0]},
                     "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]},
                     "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}]}],
                "ip": 0, "op": 60, "st": 0, "bm": 0,
            }],
        },
        open(path, "w"),
    )


def section(title: str, body: dict, error_key: str) -> list:
    """A titled section whose widget reports its own failure into `error_key`.

    Every capability answers the same way, so the verifier reads one shape.
    """
    widget = dict(body)
    widget["onError"] = {
        "type": "state", "action": "set", "binding": error_key,
        "value": "{{event.error}}",
    }
    return [
        {"type": "text", "text": title,
         "style": {"fontSize": 16, "fontWeight": "bold"}},
        {"type": "box", "height": 220, "child": widget},
        {"type": "text", "text": f"{error_key} err: {{{{{error_key}}}}}"},
    ]


def build(root: str) -> str:
    bundle = os.path.join(root, "com.makemind.probe.capability")
    os.makedirs(os.path.join(bundle, "ui", "pages"), exist_ok=True)
    os.makedirs(os.path.join(bundle, "assets"), exist_ok=True)
    write_wav(os.path.join(bundle, "assets", "tone.wav"))
    write_pdf(os.path.join(bundle, "assets", "probe.pdf"))
    write_lottie(os.path.join(bundle, "assets", "probe.json"))

    children = []
    children += section(
        "audio — bundled",
        {"type": "mediaPlayer", "id": "audio",
         "source": "bundle://assets/tone.wav", "mediaType": "audio",
         "controls": True, "waveform": True},
        "audio")
    children += section(
        "video — network",
        {"type": "mediaPlayer", "id": "video",
         "source": "https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4",
         "mediaType": "video", "controls": True},
        "video")
    children += section(
        "pdf — bundled",
        {"type": "pdfViewer", "source": "bundle://assets/probe.pdf"},
        "pdf")
    children += section(
        "lottie — bundled",
        {"type": "lottieAnimation", "source": "bundle://assets/probe.json",
         "loop": True, "autoPlay": True},
        "lottie")
    children += section(
        "webView — inline html",
        {"type": "webView",
         "html": "<html><body style='background:#4caf50'><h1>probe</h1></body></html>"},
        "web")
    children += section(
        "chart — datasets from state",
        {"type": "chart", "chartType": "bar", "showGrid": True,
         "options": {"animation": {"duration": 0}},
         "data": {"labels": ["a", "b", "c"], "datasets": "{{series}}"}},
        "chart")

    page = {
        "type": "page",
        "metadata": {"title": "Capability probe"},
        "state": {"initial": {
            "audio": "(none)", "video": "(none)", "pdf": "(none)",
            "lottie": "(none)", "web": "(none)", "chart": "(none)",
            "series": [
                {"label": "one", "data": [3, 7, 5], "backgroundColor": "#1E88E5"},
                {"label": "two", "data": [6, 4, 9], "backgroundColor": "#F4511E"},
            ],
        }},
        "content": {
            "type": "singleChildScrollView",
            "padding": {"all": 20},
            "child": {"type": "linear", "direction": "vertical",
                      "spacing": 12, "children": children},
        },
    }
    json.dump(page, open(os.path.join(bundle, "ui", "pages", "main.json"), "w"),
              indent=1)
    # `ui://pages/<name>` — the loader's own spelling. `ui.main` is the
    # manifest's entry point id, not a route, and using it here fails with
    # `Unsupported page URI` at open time.
    json.dump({"type": "application", "title": "Capability probe",
               "routes": {"/": "ui://pages/main"}, "initialRoute": "/",
               "version": "1.4"},
              open(os.path.join(bundle, "ui", "app.json"), "w"), indent=1)
    json.dump({"schemaVersion": "1.0.0", "manifest": {
        "id": "com.makemind.probe.capability", "name": "Capability probe",
        "version": "1.0.0", "type": "application", "entryPoint": "ui.main"}},
        open(os.path.join(bundle, "manifest.json"), "w"), indent=1)
    return bundle


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: build_probe.py <bundle-root>", file=sys.stderr)
        raise SystemExit(2)
    print(build(sys.argv[1]))
