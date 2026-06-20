"""
Unit tests for the reference pHash (Section 5.1).

Run:  python -m pytest test_phash.py        (if pytest installed)
  or: python test_phash.py                  (built-in runner, no deps)
"""

from __future__ import annotations

import phash


def _solid(w, h, color):
    return [[color for _ in range(w)] for _ in range(h)]


def test_grayscale_luminance():
    # Pure white -> 255, pure black -> 0, pure red -> round(0.299*255)=76.
    g = phash.to_gray([[(255, 255, 255), (0, 0, 0), (255, 0, 0)]])
    assert g == [[255, 0, 76]]


def test_resize_box_constant_image():
    # A constant image must resize to a constant (every cell == the constant).
    gray = _solid(100, 140, 120)
    r = phash.resize_box(gray)
    assert len(r) == phash.RESIZE_N and len(r[0]) == phash.RESIZE_N
    assert all(abs(v - 120.0) < 1e-9 for row in r for v in row)


def test_hash_is_deterministic():
    rgb = [[((x * 7 + y * 13) % 256, (x * 3) % 256, (y * 5) % 256)
            for x in range(50)] for y in range(70)]
    h1 = phash.phash_from_rgb(rgb)
    h2 = phash.phash_from_rgb(rgb)
    assert h1 == h2
    assert 0 <= h1 < (1 << 64)


def test_hash_is_64_bit_and_distinguishes():
    # A horizontal gradient and its transpose-ish should differ.
    g1 = [[(x * 255 // 49, 0, 0) for x in range(50)] for _ in range(50)]
    g2 = [[(y * 255 // 49, 0, 0) for _ in range(50)] for y in range(50)]
    h1 = phash.phash_from_rgb(g1)
    h2 = phash.phash_from_rgb(g2)
    assert h1 != h2
    assert phash.hamming(h1, h1) == 0
    assert phash.hamming(h1, h2) > 0


def test_hamming_popcount():
    assert phash.hamming(0, 0) == 0
    assert phash.hamming(0b1011, 0b0001) == 2
    assert phash.hamming(0xFFFFFFFFFFFFFFFF, 0) == 64


def test_emit_dart_table_shape():
    src = phash.emit_dart_table()
    assert "const List<List<double>> kCos" in src
    assert "const List<double> kAlpha" in src
    assert f"const int kResizeN = {phash.RESIZE_N};" in src


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(_run_all())
