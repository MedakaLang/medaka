#!/usr/bin/env python3
"""Regenerate playground/og-card.png — the 1200x630 Open Graph card.

    python3 playground/build_og_card.py

Committed output, like vendor/: run this only when the card's content or the
wordmark changes. Requires Google Chrome on PATH (headless screenshot); no
other dependency.

The code sample is the playground's own `shapes` example, coloured with the
exact token palette from playground/medaka_lang.js, so the card shows the same
thing a visitor sees on arrival. The fish is read from brand/fish.svg rather than
duplicated, so the card cannot drift from the site.
"""
import pathlib, re, subprocess, sys, tempfile

PG = pathlib.Path(__file__).resolve().parent
PNG = PG / "og-card.png"

# The fish alone, in the accent color, from brand/fish.svg.
fish_d = re.search(r'\bd="([^"]+)"', (PG / "brand" / "fish.svg").read_text()).group(1)
paths = f'<path fill="#5fd38f" d="{fish_d}"/>'

# Token colors — medaka_lang.js
KW, CMT, STR, INTERP = "#5fd38f", "#6e7781", "#f0c674", "#ffb86c"
NUM, TYP, CTOR, VAR, OP, PUN = "#79c0ff", "#8ab4ff", "#d29cf5", "#d6dde8", "#a9b1ba", "#8b949e"

def s(cls, txt):
    return f'<span style="color:{cls}">{txt}</span>'

CODE = f"""{s(CMT, "-- A tiny shape calculator")}
{s(KW, "data")} {s(TYP, "Shape")}
  {s(OP, "=")} {s(CTOR, "Circle")} {s(TYP, "Float")}
  {s(OP, "|")} {s(CTOR, "Rect")} {s(TYP, "Float")} {s(TYP, "Float")}

{s(VAR, "area")} {s(OP, ":")} {s(TYP, "Shape")} {s(OP, "-&gt;")} {s(TYP, "Float")}
{s(VAR, "area")} {s(PUN, "(")}{s(CTOR, "Circle")} {s(VAR, "r")}{s(PUN, ")")} {s(OP, "=")} {s(NUM, "3.14159")} {s(OP, "*")} {s(VAR, "r")} {s(OP, "*")} {s(VAR, "r")}
{s(VAR, "area")} {s(PUN, "(")}{s(CTOR, "Rect")} {s(VAR, "w")} {s(VAR, "h")}{s(PUN, ")")} {s(OP, "=")} {s(VAR, "w")} {s(OP, "*")} {s(VAR, "h")}

{s(VAR, "main")} {s(OP, "=")}
  {s(KW, "let")} {s(VAR, "shapes")} {s(OP, "=")} {s(PUN, "[")}{s(CTOR, "Circle")} {s(NUM, "1.0")}{s(PUN, ",")} {s(CTOR, "Rect")} {s(NUM, "3.0")} {s(NUM, "4.0")}{s(PUN, "]")}
  {s(VAR, "println")} {s(STR, '"areas: ')}{s(INTERP, "\\{")}{s(VAR, "map")} {s(VAR, "area")} {s(VAR, "shapes")}{s(INTERP, "}")}{s(STR, '"')}"""

html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  html, body {{ width:1200px; height:630px; overflow:hidden; }}
  body {{
    background:
      radial-gradient(900px 500px at 88% 8%, rgba(138,180,255,0.08), transparent 60%),
      radial-gradient(800px 520px at 4% 96%, rgba(95,211,143,0.10), transparent 62%),
      #121826;
    color:#e4e9f2;
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    display:flex; align-items:center; gap:56px; padding:0 68px;
  }}
  .left {{ width:392px; flex:none; }}
  .mark {{ display:flex; align-items:center; gap:18px; margin-bottom:26px; }}
  .mark svg {{ display:block; filter: drop-shadow(0 2px 8px rgba(95,211,143,0.12)); }}
  .name {{
    font: 600 60px "SF Mono","Cascadia Code",Menlo,Consolas,monospace;
    letter-spacing:0.01em; color:#f2f5f9; line-height:1;
  }}
  .tag {{ font-size:27px; line-height:1.36; color:#aeb6c2; margin-bottom:30px; }}
  .tag b {{ color:#e8ecf2; font-weight:600; }}
  .rule {{ width:66px; height:3px; background:#5fd38f; border-radius:2px; margin-bottom:26px; }}
  .url {{ font: 600 25px "SF Mono","Cascadia Code",Menlo,Consolas,monospace; color:#5fd38f; }}
  .sub {{ font-size:17px; color:#79828f; margin-top:13px; letter-spacing:0.01em; }}
  .panel {{
    flex:1; background:#0e1320; border:1px solid #2b3550; border-radius:13px;
    padding:26px 30px; box-shadow:0 22px 60px rgba(0,0,0,0.5);
  }}
  .bar {{ display:flex; gap:7px; margin-bottom:19px; }}
  .dot {{ width:11px; height:11px; border-radius:50%; }}
  pre {{
    font: 400 20.5px/1.66 "SF Mono","Cascadia Code","Fira Code",Menlo,Consolas,monospace;
    white-space:pre; color:#d6dde8;
  }}
</style></head><body>
  <div class="left">
    <div class="mark">
      <svg width="125" height="50" viewBox="120 380 760 300">
      {paths}
      </svg>
      <span class="name">medaka</span>
    </div>
    <div class="tag">A practical <b>functional language</b> with static types, interfaces, and effects.</div>
    <div class="rule"></div>
    <div class="url">medaka-lang.dev</div>
    <div class="sub">Try it in your browser.</div>
  </div>
  <div class="panel">
    <div class="bar">
      <span class="dot" style="background:#2b3550"></span>
      <span class="dot" style="background:#2b3550"></span>
      <span class="dot" style="background:#2b3550"></span>
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
