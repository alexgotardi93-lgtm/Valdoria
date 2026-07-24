#!/usr/bin/env python3
import base64, io
from PIL import Image

SRC = {
    "splash": "assets/bg-orig/splash-coliseu.png",
    "map":    "assets/bg-orig/map-mapa.png",
    "duel":   "assets/bg-orig/duel-arena.png",
    "home":   "assets/bg-orig/home-ilha.png",
}
TARGET_W = 720   # ~1.5x the 480px frame
QUALITY  = 76

out = {}
for key, path in SRC.items():
    im = Image.open(path).convert("RGB")
    w, h = im.size
    if w > TARGET_W:
        nh = round(h * TARGET_W / w)
        im = im.resize((TARGET_W, nh), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=QUALITY, optimize=True)
    b = buf.getvalue()
    out[key] = "data:image/jpeg;base64," + base64.b64encode(b).decode()
    print(f"{key:8s} {im.size[0]}x{im.size[1]}  {len(b)//1024} KB")

with open("bgdata.js", "w") as f:
    f.write("window.BGIMG={\n")
    f.write(",\n".join(f'"{k}":"{v}"' for k, v in out.items()))
    f.write("\n};\n")

import os
print("bgdata.js:", os.path.getsize("bgdata.js")//1024, "KB total")
