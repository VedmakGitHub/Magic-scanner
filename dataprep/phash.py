"""
Reference DCT perceptual hash (64-bit) — Section 5.1 of the build plan.

THIS IS THE PARITY-CRITICAL FILE. Its output MUST be bit-identical to
``app/lib/recognition/phash.dart`` for the same input image. See Section 5 of
Phase1_Android_MTG_Scanner_Build_Plan.md and the parity test in Section 5.3.

Algorithm (frozen — change BOTH sides together or recognition breaks):

  1. Decode image to RGB.
  2. Grayscale via luminance Y = round(0.299*R + 0.587*G + 0.114*B), clamped 0..255.
  3. Resize to 32x32 using an explicit area/box average (NOT a library resampler).
     We deliberately hand-roll this so Python and Dart produce identical floats.
  4. 2-D DCT-II of the 32x32 matrix, keeping only the top-left 8x8 block.
  5. Exclude the DC term (0,0) when computing the threshold.
  6. Threshold = median of the remaining 63 coefficients.
  7. bit = 1 if coeff > median else 0, in row-major order, MSB first, for all 64.
  8. Pack into a 64-bit unsigned integer.

Parity engineering notes
------------------------
* All arithmetic is IEEE-754 ``double``. CPython ``float`` and Dart ``double`` are
  both binary64, so a fixed operation order yields bit-identical results for +,
  -, *, /, and ``sqrt`` (all correctly rounded).
* The only transcendental we need is ``cos`` for the DCT basis. ``cos`` is NOT
  guaranteed to match across language runtimes, so we DO NOT call ``cos`` on the
  Dart side. Instead we precompute a cosine lookup table here and emit it as a
  Dart source file (``--emit-dart-table``). Both sides then index the exact same
  doubles (decimal ``repr`` round-trips a binary64 exactly in both languages).
* The median of an even-length (63 is odd, so this is moot, but documented):
  63 coefficients -> the median is simply the middle element after sorting.
"""

from __future__ import annotations

import math
import sys
from typing import List, Sequence

# ---------------------------------------------------------------------------
# Frozen constants
# ---------------------------------------------------------------------------
RESIZE_N = 32          # resize target is RESIZE_N x RESIZE_N
DCT_KEEP = 16          # keep top-left DCT_KEEP x DCT_KEEP coefficients (256 total)
HASH_BITS = DCT_KEEP * DCT_KEEP   # 256-bit hash
HASH_BYTES = HASH_BITS // 8       # 32 bytes
_TWO_N = 2 * RESIZE_N  # denominator in the DCT-II cosine argument

# NOTE: This is a 256-bit DCT pHash. The original 64-bit (8x8) hash proved too
# coarse for real camera photos (the correct card ranked below random matches);
# 256 bits restores discrimination. Algorithm is otherwise unchanged.


def _build_cos_table() -> List[List[float]]:
    """COS[u][x] = cos(pi * (2x + 1) * u / (2N)) for u in 0..DCT_KEEP-1, x in 0..N-1.

    Computed once here from ``math.cos``. The Dart side consumes the emitted
    table rather than recomputing, so cross-runtime ``cos`` differences cannot
    break parity.
    """
    table: List[List[float]] = []
    for u in range(DCT_KEEP):
        row = []
        for x in range(RESIZE_N):
            row.append(math.cos(math.pi * (2 * x + 1) * u / _TWO_N))
        table.append(row)
    return table


COS = _build_cos_table()

# Orthonormal DCT-II scale factors: alpha(0) = sqrt(1/N), alpha(u>0) = sqrt(2/N).
_ALPHA: List[float] = [math.sqrt(1.0 / RESIZE_N)] + [
    math.sqrt(2.0 / RESIZE_N) for _ in range(DCT_KEEP - 1)
]


# ---------------------------------------------------------------------------
# Step 2: grayscale
# ---------------------------------------------------------------------------
def to_gray(rgb: Sequence[Sequence[Sequence[int]]]) -> List[List[int]]:
    """rgb is H x W x 3 of ints 0..255 -> H x W of ints 0..255."""
    out: List[List[int]] = []
    for row in rgb:
        gray_row = []
        for (r, g, b) in row:
            # floor(x + 0.5) on BOTH sides: Python round() is banker's rounding
            # but Dart .round() is half-away-from-zero, so we pin an explicit rule.
            y = int(math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5))
            if y < 0:
                y = 0
            elif y > 255:
                y = 255
            gray_row.append(y)
        out.append(gray_row)
    return out


# ---------------------------------------------------------------------------
# Step 3: deterministic area/box resize to 32x32
# ---------------------------------------------------------------------------
def resize_box(gray: Sequence[Sequence[int]]) -> List[List[float]]:
    """Area-average resize of an H x W gray image to RESIZE_N x RESIZE_N.

    For each output cell we average source pixels weighted by their fractional
    overlap with the cell's source footprint. The loop order is fixed so Dart
    can reproduce the exact summation.
    """
    h = len(gray)
    w = len(gray[0])
    n = RESIZE_N
    out = [[0.0] * n for _ in range(n)]
    for oy in range(n):
        y0 = oy * h / n
        y1 = (oy + 1) * h / n
        for ox in range(n):
            x0 = ox * w / n
            x1 = (ox + 1) * w / n
            total = 0.0
            area = 0.0
            iy = int(math.floor(y0))
            while iy < y1:
                top = iy if iy > y0 else y0
                bot = (iy + 1) if (iy + 1) < y1 else y1
                fy = bot - top
                if fy > 0.0:
                    ix = int(math.floor(x0))
                    while ix < x1:
                        left = ix if ix > x0 else x0
                        right = (ix + 1) if (ix + 1) < x1 else x1
                        fx = right - left
                        if fx > 0.0:
                            wgt = fx * fy
                            total += gray[iy][ix] * wgt
                            area += wgt
                        ix += 1
                iy += 1
            out[oy][ox] = total / area
    return out


# ---------------------------------------------------------------------------
# Step 4: 2-D DCT-II, top-left 8x8 only
# ---------------------------------------------------------------------------
def dct_8x8(matrix: Sequence[Sequence[float]]) -> List[List[float]]:
    """Return the top-left DCT_KEEP x DCT_KEEP block of the 2-D DCT-II.

    Separable: first DCT each row (length N) keeping DCT_KEEP outputs, then DCT
    each resulting column. Fixed accumulation order for parity.
    """
    n = RESIZE_N
    k = DCT_KEEP
    # Row pass: tmp[y][u] for y in 0..N-1, u in 0..k-1
    tmp = [[0.0] * k for _ in range(n)]
    for y in range(n):
        row = matrix[y]
        for u in range(k):
            cos_u = COS[u]
            s = 0.0
            for x in range(n):
                s += row[x] * cos_u[x]
            tmp[y][u] = s * _ALPHA[u]
    # Column pass: out[v][u] for v in 0..k-1, u in 0..k-1
    out = [[0.0] * k for _ in range(k)]
    for u in range(k):
        for v in range(k):
            cos_v = COS[v]
            s = 0.0
            for y in range(n):
                s += tmp[y][u] * cos_v[y]
            out[v][u] = s * _ALPHA[v]
    return out


# ---------------------------------------------------------------------------
# Steps 5-8: threshold + pack
# ---------------------------------------------------------------------------
def _median(values: Sequence[float]) -> float:
    s = sorted(values)
    return s[len(s) // 2]  # odd count -> the middle element


def pack_hash(block: Sequence[Sequence[float]]) -> int:
    """block is DCT_KEEP x DCT_KEEP -> HASH_BITS-bit int (row-major, MSB first)."""
    flat: List[float] = []
    for v in range(DCT_KEEP):
        for u in range(DCT_KEEP):
            flat.append(block[v][u])
    # Median over all but the DC term (index 0).
    median = _median(flat[1:])
    bits = 0
    for i in range(HASH_BITS):
        bits <<= 1
        if flat[i] > median:
            bits |= 1
    return bits


def to_bytes(h: int) -> bytes:
    """Big-endian HASH_BYTES blob for SQLite storage (matches Dart byte order)."""
    return h.to_bytes(HASH_BYTES, "big")


# ---------------------------------------------------------------------------
# Top-level helpers
# ---------------------------------------------------------------------------
def phash_from_gray(gray: Sequence[Sequence[int]]) -> int:
    resized = resize_box(gray)
    block = dct_8x8(resized)
    return pack_hash(block)


def phash_from_rgb(rgb: Sequence[Sequence[Sequence[int]]]) -> int:
    return phash_from_gray(to_gray(rgb))


def phash_from_file(path: str) -> int:
    """Decode an image file (via Pillow) and compute its 64-bit pHash."""
    from PIL import Image

    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()
    rgb = [[px[x, y] for x in range(w)] for y in range(h)]
    return phash_from_rgb(rgb)


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


# ---------------------------------------------------------------------------
# Dart cosine-table emitter (keeps the two phash implementations in lockstep)
# ---------------------------------------------------------------------------
def emit_dart_table() -> str:
    """Emit app/lib/recognition/phash_cos_table.dart with identical doubles."""
    lines: List[str] = []
    lines.append("// GENERATED by dataprep/phash.py --emit-dart-table. DO NOT EDIT.")
    lines.append("// Shared cosine + alpha tables that guarantee Python<->Dart pHash parity.")
    lines.append("// See Section 5 of Phase1_Android_MTG_Scanner_Build_Plan.md.")
    lines.append("")
    lines.append(f"const int kResizeN = {RESIZE_N};")
    lines.append(f"const int kDctKeep = {DCT_KEEP};")
    lines.append("")
    lines.append("// kCos[u][x] = cos(pi * (2x + 1) * u / (2N))")
    lines.append("const List<List<double>> kCos = [")
    for u in range(DCT_KEEP):
        vals = ", ".join(repr(v) for v in COS[u])
        lines.append(f"  [{vals}],")
    lines.append("];")
    lines.append("")
    lines.append("// Orthonormal DCT-II scale factors.")
    alpha_vals = ", ".join(repr(v) for v in _ALPHA)
    lines.append(f"const List<double> kAlpha = [{alpha_vals}];")
    lines.append("")
    return "\n".join(lines)


def _main(argv: List[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--emit-dart-table":
        sys.stdout.write(emit_dart_table())
        return 0
    if len(argv) >= 2:
        for path in argv[1:]:
            h = phash_from_file(path)
            # 16-hex-digit, zero-padded, lowercase — the parity test parses this.
            print(f"{h:064x}\t{path}")
        return 0
    sys.stderr.write(
        "usage:\n"
        "  python phash.py <image> [<image> ...]   # print 16-hex pHash per file\n"
        "  python phash.py --emit-dart-table        # print the Dart cos table\n"
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
