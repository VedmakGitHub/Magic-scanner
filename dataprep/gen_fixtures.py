"""
Generate deterministic image fixtures + golden pHashes for the parity test.

Section 5.3 calls for hashing the same files in Python and Dart and asserting
the 64-bit values are identical. Rather than depend on network downloads, we
synthesize a spread of deterministic images (gradients, checkerboards, blocks,
pseudo-random texture), hash them with the REFERENCE implementation
(dataprep/phash.py), and write:

  app/test/fixtures/*.png        the images (committed; small)
  app/test/fixtures/golden.json  {filename: "<16-hex pHash>"}

The Dart parity test (app/test/phash_parity_test.dart) loads these same PNGs,
hashes them with phash.dart, and asserts equality against golden.json.

Run:  python gen_fixtures.py
"""

from __future__ import annotations

import json
import math
import os
from typing import Callable, List, Tuple

from PIL import Image

import phash

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "app", "test", "fixtures")


def _lcg(seed: int):
    """Tiny deterministic PRNG (so fixtures are reproducible across machines)."""
    state = seed & 0xFFFFFFFF

    def nxt() -> int:
        nonlocal state
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        return state

    return nxt


def _make(size: Tuple[int, int], fn: Callable[[int, int], Tuple[int, int, int]]) -> Image.Image:
    w, h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = fn(x, y)
    return img


def build_images() -> List[Tuple[str, Image.Image]]:
    out: List[Tuple[str, Image.Image]] = []

    # Card-ish aspect ratio (~0.716) at a few resolutions to exercise resize.
    sizes = [(146, 204), (488, 680), (63, 88)]

    for i, (w, h) in enumerate(sizes):
        # 1. Horizontal gradient
        out.append((f"gradient_h_{i}.png", _make((w, h), lambda x, y, w=w: (
            int(255 * x / max(1, w - 1)), 64, 200 - int(120 * x / max(1, w - 1))))))
        # 2. Vertical gradient
        out.append((f"gradient_v_{i}.png", _make((w, h), lambda x, y, h=h: (
            32, int(255 * y / max(1, h - 1)), 128))))
        # 3. Diagonal sine pattern (lots of mid frequencies)
        out.append((f"sine_{i}.png", _make((w, h), lambda x, y: (
            int(127 + 127 * math.sin(x * 0.3 + y * 0.2)),
            int(127 + 127 * math.sin(x * 0.1 - y * 0.25)),
            int(127 + 127 * math.cos(x * 0.2 + y * 0.05))))))
        # 4. Checkerboard
        out.append((f"checker_{i}.png", _make((w, h), lambda x, y: (
            (240, 240, 240) if ((x // 8 + y // 8) % 2 == 0) else (16, 16, 16)))))
        # 5. Quadrant blocks
        out.append((f"quads_{i}.png", _make((w, h), lambda x, y, w=w, h=h: (
            (200, 20, 20) if (x < w // 2 and y < h // 2) else
            (20, 200, 20) if (x >= w // 2 and y < h // 2) else
            (20, 20, 200) if (x < w // 2 and y >= h // 2) else
            (200, 200, 20)))))
        # 6. Seeded pseudo-random texture
        rnd = _lcg(1234 + i)
        out.append((f"noise_{i}.png", _make((w, h), lambda x, y, rnd=rnd: (
            rnd() % 256, rnd() % 256, rnd() % 256))))

    return out


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    golden = {}
    for name, img in build_images():
        path = os.path.join(OUT_DIR, name)
        img.save(path, "PNG")
        h = phash.phash_from_file(path)
        golden[name] = f"{h:064x}"
        print(f"{golden[name]}  {name}")
    with open(os.path.join(OUT_DIR, "golden.json"), "w", encoding="utf-8") as f:
        json.dump(golden, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"\nWrote {len(golden)} fixtures + golden.json to {os.path.normpath(OUT_DIR)}")


if __name__ == "__main__":
    main()
