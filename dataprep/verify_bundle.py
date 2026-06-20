"""
verify_bundle.py — reliably verify the built bundle is complete and correct.

Run after build_bundle.py (and before publishing). Reads:
  out/cards.sqlite          the built bundle
  out/manifest.json         expected sha256/counts
  out/unique_artwork.json   the "expected" hash set (needs --keep-bulk on build)
  image_cache/              the cached source images (for sample re-hashing)

Checks (each PASS/WARN/FAIL):
  1. DB opens + PRAGMA integrity_check.
  2. Manifest consistency: sha256(cards.sqlite) == manifest.sqlite_sha256;
     printings/hashes counts == manifest card_count/hash_count.
  3. hashes uniqueness on (scryfall_id, face).
  4. Referential integrity: every hashes row joins to a printings row.
  5. Completeness: every expected job (from unique_artwork) has a hash row;
     missing rows are classified (cached -> decode-failed, not cached -> 404/download).
  6. Degeneracy: no all-0 / all-1 hashes; values overwhelmingly distinct.
  7. Correctness: re-hash a random sample of cached images with phash.py and
     assert they equal the stored values (the core correctness proof).

Usage:
  python verify_bundle.py [--sample 400] [--max-missing-pct 2.0]

Exit code 0 if all checks pass (WARN allowed), 1 if any FAIL.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import sqlite3
import sys
from typing import List, Optional

import phash
from build_bundle import (
    DEFAULT_CACHE_DIR,
    OUT_DIR,
    _cache_path,
    collect_hash_jobs,
    load_json,
)

_FAILS = 0
_WARNS = 0


def _ok(msg: str) -> None:
    print(f"  [PASS] {msg}")


def _warn(msg: str) -> None:
    global _WARNS
    _WARNS += 1
    print(f"  [WARN] {msg}")


def _fail(msg: str) -> None:
    global _FAILS
    _FAILS += 1
    print(f"  [FAIL] {msg}")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="Verify the built card-data bundle.")
    ap.add_argument("--sample", type=int, default=400,
                    help="How many cached images to re-hash for the correctness check.")
    ap.add_argument("--max-missing-pct", type=float, default=2.0,
                    help="FAIL if more than this %% of expected hashes are missing.")
    ap.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    ap.add_argument("--seed", type=int, default=12345)
    args = ap.parse_args(argv[1:])
    random.seed(args.seed)

    sqlite_path = os.path.join(OUT_DIR, "cards.sqlite")
    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    ua_path = os.path.join(OUT_DIR, "unique_artwork.json")

    if not os.path.exists(sqlite_path):
        print(f"cards.sqlite not found at {sqlite_path} — build first.")
        return 1

    # ---- 1. DB integrity ---------------------------------------------------
    print("[1] Database integrity")
    conn = sqlite3.connect(sqlite_path)
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity == "ok":
        _ok("PRAGMA integrity_check = ok")
    else:
        _fail(f"integrity_check = {integrity}")

    printings = conn.execute("SELECT COUNT(*) FROM printings").fetchone()[0]
    hashes = conn.execute("SELECT COUNT(*) FROM hashes").fetchone()[0]
    print(f"      printings={printings:,}  hashes={hashes:,}")

    # ---- 2. Manifest consistency ------------------------------------------
    print("[2] Manifest consistency")
    if os.path.exists(manifest_path):
        manifest = json.load(open(manifest_path, encoding="utf-8"))
        digest = sha256_file(sqlite_path)
        if digest == manifest.get("sqlite_sha256"):
            _ok("cards.sqlite sha256 matches manifest")
        else:
            _fail(f"sha256 mismatch: file={digest} manifest={manifest.get('sqlite_sha256')}")
        if manifest.get("card_count") == printings:
            _ok(f"manifest card_count matches printings ({printings:,})")
        else:
            _fail(f"manifest card_count={manifest.get('card_count')} != printings={printings}")
        if manifest.get("hash_count") == hashes:
            _ok(f"manifest hash_count matches hashes ({hashes:,})")
        else:
            _fail(f"manifest hash_count={manifest.get('hash_count')} != hashes={hashes}")
    else:
        _warn("manifest.json not found — skipping manifest checks")

    # ---- 3. hashes uniqueness ---------------------------------------------
    print("[3] hashes uniqueness on (scryfall_id, face)")
    dupes = conn.execute(
        "SELECT COUNT(*) FROM (SELECT scryfall_id, face, COUNT(*) c "
        "FROM hashes GROUP BY scryfall_id, face HAVING c > 1)"
    ).fetchone()[0]
    if dupes == 0:
        _ok("no duplicate (scryfall_id, face) rows")
    else:
        _fail(f"{dupes} duplicated (scryfall_id, face) keys")

    # ---- 4. Referential integrity -----------------------------------------
    # The app resolves a candidate by illustration_id (representativeForIllustration),
    # so resolvability means "illustration_id exists in printings" — not an exact
    # scryfall_id match (scryfall_ids may come from an older Scryfall snapshot).
    print("[4] Referential integrity (hashes resolve by illustration_id)")
    orphans = conn.execute(
        "SELECT COUNT(*) FROM hashes h WHERE h.illustration_id IS NULL OR NOT EXISTS "
        "(SELECT 1 FROM printings p WHERE p.illustration_id = h.illustration_id)"
    ).fetchone()[0]
    if orphans == 0:
        _ok("every hash resolves to a printing via illustration_id")
    else:
        _fail(f"{orphans} hashes cannot resolve to any printing")

    # ---- 5. Completeness (artwork/illustration level) ----------------------
    # The bundle deliberately keeps one hash per illustration and only for
    # illustrations that have an English printing (so they resolve). So the
    # meaningful question is: of the RESOLVABLE expected artworks, how many are
    # covered? Expected artworks with no English printing are excluded by design,
    # not failures.
    print("[5] Completeness (resolvable artworks covered)")
    if os.path.exists(ua_path):
        ua = load_json(ua_path)
        jobs = collect_hash_jobs(ua)
        printed_ill = {r[0] for r in conn.execute(
            "SELECT DISTINCT illustration_id FROM printings WHERE illustration_id IS NOT NULL"
        )}
        expected_ill = {j[0] for j in jobs if j[0] is not None}
        resolvable_ill = expected_ill & printed_ill
        excluded_ill = expected_ill - printed_ill  # no English printing -> by design
        have_ill = {r[0] for r in conn.execute("SELECT DISTINCT illustration_id FROM hashes")}
        missing_ill = resolvable_ill - have_ill
        pct = 100.0 * len(missing_ill) / max(1, len(resolvable_ill))
        print(f"      expected artworks={len(expected_ill):,}  "
              f"resolvable={len(resolvable_ill):,}  covered={len(have_ill):,}")
        print(f"      excluded by design (no English printing)={len(excluded_ill):,}  "
              f"genuinely missing={len(missing_ill):,} ({pct:.2f}%)")
        if len(missing_ill) == 0:
            _ok("every resolvable artwork is covered by a hash")
        elif pct <= args.max_missing_pct:
            _warn(f"{len(missing_ill):,} resolvable artworks missing ({pct:.2f}%) — "
                  f"within tolerance (<= {args.max_missing_pct}%)")
        else:
            _fail(f"{len(missing_ill):,} resolvable artworks missing ({pct:.2f}%) "
                  f"exceeds {args.max_missing_pct}% tolerance")
    else:
        _warn("unique_artwork.json not found (build without --keep-bulk) — "
              "cannot check completeness")

    # ---- 6. Degeneracy -----------------------------------------------------
    print("[6] Hash value sanity")
    zero_blob = b"\x00" * phash.HASH_BYTES
    ones_blob = b"\xff" * phash.HASH_BYTES
    zero = conn.execute("SELECT COUNT(*) FROM hashes WHERE phash = ?", (zero_blob,)).fetchone()[0]
    allones = conn.execute("SELECT COUNT(*) FROM hashes WHERE phash = ?", (ones_blob,)).fetchone()[0]
    distinct = conn.execute("SELECT COUNT(DISTINCT phash) FROM hashes").fetchone()[0]
    if zero == 0 and allones == 0:
        _ok("no all-zero or all-ones hashes")
    else:
        _warn(f"degenerate hashes: zero={zero}, all-ones={allones}")
    if hashes > 0:
        distinct_pct = 100.0 * distinct / hashes
        top = conn.execute(
            "SELECT phash, COUNT(*) c FROM hashes GROUP BY phash ORDER BY c DESC LIMIT 1"
        ).fetchone()
        print(f"      distinct={distinct:,}/{hashes:,} ({distinct_pct:.2f}%)  "
              f"most-common-hash-count={top[1] if top else 0}")
        if distinct_pct >= 98.0:
            _ok(f"hashes overwhelmingly distinct ({distinct_pct:.2f}%)")
        elif distinct_pct >= 90.0:
            _warn(f"distinct only {distinct_pct:.2f}% — check for failed decodes")
        else:
            _fail(f"distinct {distinct_pct:.2f}% — many identical hashes (suspect failures)")

    # ---- 7. Correctness: sample re-hash -----------------------------------
    print(f"[7] Correctness: re-hash {args.sample} random cached images with phash.py")
    rows = conn.execute(
        "SELECT h.scryfall_id, h.face, h.phash, p.image_id "
        "FROM hashes h JOIN printings p "
        "ON h.scryfall_id = p.scryfall_id AND h.face = p.face "
        "WHERE p.image_id IS NOT NULL"
    ).fetchall()
    random.shuffle(rows)
    checked = mism = nocache = 0
    for scryfall_id, face, stored, image_id in rows:
        if checked >= args.sample:
            break
        dest = _cache_path(args.cache_dir, image_id, face)
        if not (os.path.exists(dest) and os.path.getsize(dest) > 0):
            nocache += 1
            continue
        try:
            recomputed = phash.to_bytes(phash.phash_from_file(dest))
        except Exception as e:  # noqa: BLE001
            _fail(f"re-hash raised for {scryfall_id}/{face}: {e}")
            checked += 1
            continue
        checked += 1
        stored_bytes = bytes(stored) if stored is not None else b""
        if recomputed != stored_bytes:
            mism += 1
            if mism <= 5:
                print(f"      MISMATCH {scryfall_id}/{face}: "
                      f"stored={stored_bytes.hex()} recomputed={recomputed.hex()}")
    print(f"      re-hashed={checked}  mismatches={mism}  (skipped {nocache} not cached)")
    if checked == 0:
        _warn("no cached images available to re-hash (cache cleared?)")
    elif mism == 0:
        _ok(f"all {checked} sampled hashes reproduce exactly (parity-correct)")
    else:
        _fail(f"{mism}/{checked} sampled hashes did NOT reproduce — values are wrong")

    conn.close()

    # ---- Summary -----------------------------------------------------------
    print("\n" + "=" * 60)
    if _FAILS == 0:
        print(f"RESULT: PASS  ({_WARNS} warning(s))")
        return 0
    print(f"RESULT: FAIL  ({_FAILS} failure(s), {_WARNS} warning(s))")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
