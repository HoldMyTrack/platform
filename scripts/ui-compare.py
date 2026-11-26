#!/usr/bin/env python3
"""Writes one static HTML page that puts each apps/docs/ui-states.json entry's Android and iOS
screenshots side by side, with what to expect, what may differ and why, the decided changes not
made yet and the differences still open. Images are embedded, so the page is one file to open or
send. `make ui-compare` takes the screenshots and runs this.

Usage: ui-compare.py --android <dir of <id>.png> --ios <xcresult bundle or dir of <id>.png> --out <file.html>
"""
import argparse
import base64
import datetime
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile

STATES = os.path.join(os.path.dirname(__file__), "..", "apps", "docs", "ui-states.json")


def ios_shots(path, work):
    """{id: png path} from a directory of <id>.png, or from an xcresult bundle's attachments."""
    if not path.endswith(".xcresult"):
        return {f[:-4]: os.path.join(path, f) for f in os.listdir(path) if f.endswith(".png")}
    out = os.path.join(work, "ios")
    os.makedirs(out, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", path, "--output-path", out],
                   check=True, capture_output=True)
    shots = {}
    for test in json.load(open(os.path.join(out, "manifest.json"))):
        for a in test["attachments"]:
            # Named "<id>_<n>_<uuid>.png" by the export.
            name = a.get("suggestedHumanReadableName", "").split("_")[0]
            if name:
                shots[name] = os.path.join(out, a["exportedFileName"])
    return shots


def embedded(png, work):
    """A data: URI, shrunk to a JPEG with sips where it's there (macOS), else the PNG as is."""
    if shutil.which("sips"):
        jpg = os.path.join(work, os.path.basename(png) + ".jpg")
        r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "1200", png, "--out", jpg],
                           capture_output=True)
        if r.returncode == 0:
            return "data:image/jpeg;base64," + base64.b64encode(open(jpg, "rb").read()).decode()
    return "data:image/png;base64," + base64.b64encode(open(png, "rb").read()).decode()


def commit():
    r = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() or "unknown"


def items(title, rows, cls):
    if not rows:
        return ""
    return f'<div class="{cls}"><h4>{title}</h4><ul>' + "".join(f"<li>{r}</li>" for r in rows) + "</ul></div>"


def figure(label, shot, work, entry):
    if shot:
        return f'<figure><figcaption>{label}</figcaption><img src="{embedded(shot, work)}" alt="{label}: {html.escape(entry["title"])}"></figure>'
    why = entry.get("capture") or "Not captured: the shot test has no step for this id, or it failed."
    return f'<figure class="none"><figcaption>{label}</figcaption><p>{html.escape(why)}</p></figure>'


def page(doc, android, ios, work):
    e = html.escape
    sections, missing, pending, open_ = [], [], [], []
    for s in doc["states"]:
        a, i = android.get(s["id"]), ios.get(s["id"])
        if "capture" not in s and not (a and i):
            missing.append(f'<a href="#{s["id"]}">{e(s["title"])}</a>: ' + ", ".join(n for n, x in (("Android", a), ("iOS", i)) if not x))
        pending += [f'<a href="#{s["id"]}">{e(s["title"])}</a>: {e(p)}' for p in s.get("pending", [])]
        open_ += [f'<a href="#{s["id"]}">{e(s["title"])}</a>: {e(p)}' for p in s.get("open", [])]
        diffs = [f"{e(d['what'])} <span class='why'>{e(d['why'])}</span>" for d in s.get("differences", [])]
        notes = (f'<p class="expect">{e(s["expect"])}</p>' if s.get("expect") else "") + \
            items("May differ", diffs, "diffs") + items("Decided, not made yet", [e(p) for p in s.get("pending", [])], "pending") + \
            items("Open", [e(p) for p in s.get("open", [])], "open")
        wide = " wide" if s["setup"] == "landscape" else ""
        sections.append(
            f'<section id="{s["id"]}" class="state{wide}"><header><h3>{e(s["title"])}</h3>'
            f'<span class="tag">{e(s["setup"])}</span><code>{e(s["id"])}</code></header>'
            f'<div class="notes">{notes}</div><div class="pair">{figure("Android", a, work, s)}{figure("iOS", i, work, s)}</div></section>')
    summary = items("Missing a screenshot", missing, "missing") + items("Decided, not made yet", pending, "pending") + items("Open, to decide", open_, "open")
    setups = "".join(f"<li><b>{e(k)}</b>: {e(v)}</li>" for k, v in doc["setups"].items())
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>HoldMyTrack UI, Android and iOS</title>
<style>
:root {{ --bg:#f6f4ef; --panel:#fff; --fg:#23211c; --muted:#6d675c; --rule:#e3ddd1; --accent:#a8742a; --warn:#b3402a; --ok:#3f6f4a; color-scheme: light }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1b1a17; --panel:#24221e; --fg:#ece7dd; --muted:#a39b8c; --rule:#38352e; --accent:#d39a48; --warn:#e2775f; --ok:#8fbf98; color-scheme: dark }} }}
body {{ margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif }}
main {{ max-width:1180px; margin:0 auto; padding:32px 16px 64px; display:grid; gap:32px }}
h1 {{ margin:0; font-size:1.8rem }} h3 {{ margin:0; font-size:1.2rem }} h4 {{ margin:0 0 4px; font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted) }}
.lede, .setups {{ color:var(--muted); max-width:75ch; margin:6px 0 0 }}
.summary {{ display:grid; gap:12px; background:var(--panel); border:1px solid var(--rule); border-radius:8px; padding:16px 20px }}
ul {{ margin:0; padding-left:18px; display:grid; gap:3px }}
a {{ color:inherit }}
.missing h4 {{ color:var(--warn) }} .pending h4 {{ color:var(--accent) }}
.state {{ display:grid; gap:12px; border-top:1px solid var(--rule); padding-top:24px }}
.state header {{ display:flex; gap:10px; align-items:baseline; flex-wrap:wrap }}
.tag {{ font-size:.75rem; border:1px solid var(--rule); border-radius:999px; padding:1px 8px; color:var(--muted) }}
code {{ font-size:.8rem; color:var(--muted) }}
.notes {{ display:grid; gap:8px; max-width:85ch }}
.expect {{ margin:0 }}
.why {{ color:var(--ok) }} .why::before {{ content:" — " }}
.pair {{ display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:20px; align-items:start }}
.wide .pair {{ grid-template-columns:1fr }}
figure {{ margin:0; display:grid; gap:6px; min-width:0 }}
figcaption {{ font-size:.8rem; color:var(--muted); font-weight:600 }}
img {{ width:100%; max-width:380px; height:auto; border:1px solid var(--rule); border-radius:10px; background:var(--panel) }}
.wide img {{ max-width:100% }}
.none p {{ margin:0; padding:16px; border:1px dashed var(--rule); border-radius:10px; color:var(--muted); max-width:380px }}
@media (max-width: 640px) {{ .pair {{ grid-template-columns:1fr }} }}
</style></head><body><main>
<header><h1>HoldMyTrack UI: Android and iOS</h1>
<p class="lede">Every entry of <code>apps/docs/ui-states.json</code> on the demo account, Android left, iOS right. Taken {when} at commit {e(commit())}. Anything that differs and isn't under "May differ" is a bug in one app or an open question.</p>
<ul class="setups">{setups}</ul></header>
<div class="summary">{summary or "<p>Nothing missing, pending or open.</p>"}</div>
{"".join(sections)}
</main></body></html>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--android", required=True)
    ap.add_argument("--ios", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    doc = json.load(open(STATES))
    with tempfile.TemporaryDirectory() as work:
        android = {f[:-4]: os.path.join(args.android, f) for f in os.listdir(args.android) if f.endswith(".png") and not f.startswith("_")} if os.path.isdir(args.android) else {}
        ios = ios_shots(args.ios, work) if os.path.exists(args.ios) else {}
        known = {s["id"] for s in doc["states"]}
        for app, shots in (("android", android), ("ios", ios)):
            extra = sorted(set(shots) - known)
            if extra:
                print(f"ui-compare: {app} has screenshots for ids not in ui-states.json: {', '.join(extra)}", file=sys.stderr)
        open(args.out, "w").write(page(doc, android, ios, work))
    print(args.out)


if __name__ == "__main__":
    main()