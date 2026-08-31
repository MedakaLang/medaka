#!/usr/bin/env python3
"""Regenerate playground/og-card.png — the 1200x630 Open Graph card.

    python3 playground/build_og_card.py

Committed output, like vendor/: run this only when the card's content or the
wordmark changes. Requires Google Chrome on PATH (headless screenshot); no
other dependency.

The code sample is the playground's own `shapes` example, coloured with the
exact token palette from playground/medaka_lang.js, so the card shows the same
thing a visitor sees on arrival. The fish is read from favicon.svg rather than
duplicated, so the card cannot drift from the site.
"""
import pathlib, re, subprocess, sys, tempfile

PG = pathlib.Path(__file__).resolve().parent
PNG = PG / "og-card.png"

# Wordmark paths, reused from the favicon so the card cannot drift from the site.
fav = (PG / "favicon.svg").read_text()
paths = "\n      ".join(re.findall(r'<path[^>]*/>', fav))

# Token colours — medaka_lang.js:44-56
KW, CMT, STR, INTERP = "#e2b96f", "#6e7781", "#7ee787", "#d2a8ff"
NUM, TYP, VAR, OP, PUN = "#79c0ff", "#58a6ff", "#c9d1d9", "#a9b1ba", "#8b949e"

def s(cls, txt):
    return f'<span style="color:{cls}">{txt}</span>'

CODE = f"""{s(CMT, "-- A tiny shape calculator")}
{s(KW, "data")} {s(TYP, "Shape")}
  {s(OP, "=")} {s(TYP, "Circle")} {s(TYP, "Float")}
  {s(OP, "|")} {s(TYP, "Rect")} {s(TYP, "Float")} {s(TYP, "Float")}

{s(VAR, "area")} {s(OP, ":")} {s(TYP, "Shape")} {s(OP, "-&gt;")} {s(TYP, "Float")}
{s(VAR, "area")} {s(PUN, "(")}{s(TYP, "Circle")} {s(VAR, "r")}{s(PUN, ")")} {s(OP, "=")} {s(NUM, "3.14159")} {s(OP, "*")} {s(VAR, "r")} {s(OP, "*")} {s(VAR, "r")}
{s(VAR, "area")} {s(PUN, "(")}{s(TYP, "Rect")} {s(VAR, "w")} {s(VAR, "h")}{s(PUN, ")")} {s(OP, "=")} {s(VAR, "w")} {s(OP, "*")} {s(VAR, "h")}

{s(VAR, "main")} {s(OP, "=")}
  {s(KW, "let")} {s(VAR, "shapes")} {s(OP, "=")} {s(PUN, "[")}{s(TYP, "Circle")} {s(NUM, "1.0")}{s(PUN, ",")} {s(TYP, "Rect")} {s(NUM, "3.0")} {s(NUM, "4.0")}{s(PUN, "]")}
  {s(VAR, "println")} {s(STR, '"areas: ')}{s(INTERP, "\\{")}{s(VAR, "map")} {s(VAR, "area")} {s(VAR, "shapes")}{s(INTERP, "}")}{s(STR, '"')}"""

html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  html, body {{ width:1200px; height:630px; overflow:hidden; }}
  body {{
    background:
      radial-gradient(900px 500px at 88% 8%, rgba(88,166,255,0.10), transparent 60%),
      radial-gradient(800px 520px at 4% 96%, rgba(226,185,111,0.13), transparent 62%),
      #0b0e14;
    color:#d6dbe3;
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    display:flex; align-items:center; gap:56px; padding:0 68px;
  }}
  .left {{ width:392px; flex:none; }}
  .mark {{ display:flex; align-items:center; gap:16px; margin-bottom:26px; }}
  .mark svg {{ display:block; filter: drop-shadow(0 3px 14px rgba(226,185,111,0.32)); }}
  .name {{
    font: 600 60px "SF Mono","Cascadia Code",Menlo,Consolas,monospace;
    letter-spacing:0.01em; color:#f2f5f9; line-height:1;
  }}
  .tag {{ font-size:27px; line-height:1.36; color:#aeb6c2; margin-bottom:30px; }}
  .tag b {{ color:#e8ecf2; font-weight:600; }}
  .rule {{ width:66px; height:3px; background:#e2b96f; border-radius:2px; margin-bottom:26px; }}
  .url {{ font: 600 25px "SF Mono","Cascadia Code",Menlo,Consolas,monospace; color:#e2b96f; }}
  .sub {{ font-size:17px; color:#79828f; margin-top:13px; letter-spacing:0.01em; }}
  .panel {{
    flex:1; background:#0d1117; border:1px solid #262d3a; border-radius:13px;
    padding:26px 30px; box-shadow:0 22px 60px rgba(0,0,0,0.5);
  }}
  .bar {{ display:flex; gap:7px; margin-bottom:19px; }}
  .dot {{ width:11px; height:11px; border-radius:50%; }}
  pre {{
    font: 400 20.5px/1.66 "SF Mono","Cascadia Code","Fira Code",Menlo,Consolas,monospace;
    white-space:pre; color:#c9d1d9;
  }}
</style></head><body>
  <div class="left">
    <div class="mark">
      <svg width="72" height="72" viewBox="0 0 16 16">
      {paths}
      </svg>
      <span class="name">medaka</span>
    </div>
    <div class="tag">A pragmatic <b>functional language</b> that self-hosts &mdash; and runs in your browser.</div>
    <div class="rule"></div>
    <div class="url">medaka-lang.dev</div>
    <div class="sub">The real compiler, client-side. Nothing sent to a server.</div>
  </div>
  <div class="panel">
    <div class="bar">
      <span class="dot" style="background:#3d434f"></span>
      <span class="dot" style="background:#3d434f"></span>
      <span class="dot" style="background:#3d434f"></span>
    </div>
    <pre>{CODE}</pre>
  </div>
</body></html>"""

chrome = next((c for c in ("google-chrome", "google-chrome-stable", "chromium")
               if subprocess.run(["which", c], capture_output=True).returncode == 0), None)
if chrome is None:
    sys.exit("FAIL: need Google Chrome or Chromium on PATH to render the card")

with tempfile.TemporaryDirectory() as tmp:
    src = pathlib.Path(tmp) / "card.html"
    src.write_text(html)
    subprocess.run([chrome, "--headless", "--disable-gpu", "--no-sandbox",
                    "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--window-size=1200,630", f"--screenshot={PNG}", str(src)],
                   check=True, capture_output=True)

import struct
w, h = struct.unpack(">II", PNG.read_bytes()[16:24])
if (w, h) != (1200, 630):
    sys.exit(f"FAIL: expected a 1200x630 card, got {w}x{h}")
print(f"wrote {PNG} ({w}x{h}, {PNG.stat().st_size // 1024} KB)")
