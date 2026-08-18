"""
reprocess_missing.py — list and gently re-attempt images that failed to hash.

The main build skips any image it can't download/decode. This tool reconstructs
the FULL set of still-missing artwork/faces (expected from Unique Artwork minus
what's already in the checkpoint) and, optionally, re-attempts each one slowly
and serially — ideal for shaking out transient 429/timeout failures without
hammering the CDN. The actual HTTP status of each attempt is recorded, so you
can tell genuine 404s apart from throttling.

Successful re-hashes are written into the same checkpoint
(out/hashes_checkpoint.sqlite). After reprocessing, fold them into the bundle:

    python build_bundle.py --repo <owner>/<repo> --keep-bulk   # resume = default

Usage:
  python reprocess_missing.py --export                 # only write the missing list
  python reprocess_missing.py --delay 10               # 1 image per 10s, then update checkpoint
  python reprocess_missing.py --delay 10 --retries 5

Outputs:
  out/missing_images.csv     full list of still-missing entries (always written)
  out/reprocess_log.csv      per-attempt outcome (when actually reprocessing)
"""

from __future__ import annotations

import argparse
import csv
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from typing import List, Optional, Tuple

import requests

import phash
from build_bundle import (
    DEFAULT_CACHE_DIR,
    OUT_DIR,
    USER_AGENT,
    _cache_path,
    _open_checkpoint,
    collect_hash_jobs,
    load_json,
    iter_bulk,
)


def _done_keys(checkpoint_path: str, sqlite_path: str) -> set:
    """(scryfall_id, face) already hashed — prefer checkpoint, else cards.sqlite."""
    keys = set()
    if os.path.exists(checkpoint_path):
        cp = sqlite3.connect(checkpoint_path)
        keys |= {(r[0], r[1]) for r in cp.execute("SELECT scryfall_id, face FROM hashes")}
        cp.close()
    if os.path.exists(sqlite_path):
        db = sqlite3.connect(sqlite_path)
        try:
            keys |= {(r[0], r[1]) for r in db.execute("SELECT scryfall_id, face FROM hashes")}
        except sqlite3.OperationalError:
            pass
        db.close()
    return keys


def _download(url: str, dest: str, retries: int) -> Tuple[bool, str]:
    """Always (re)download — no cache shortcut. Returns (ok, reason)."""
    for attempt in range(retries):
        try:
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=120)
            if r.status_code == 200:
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(r.content)
                os.replace(tmp, dest)
                return True, "downloaded"
            if r.status_code == 404:
                return False, "http_404"  # genuine miss; no point retrying
            reason = f"http_{r.status_code}"
        except requests.Timeout:
            reason = "timeout"
        except requests.RequestException as e:
            reason = f"error_{type(e).__name__}"
        if attempt < retries - 1:
            time.sleep(2.0 * (attempt + 1))  # backoff within an item
    return False, reason


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="List/reprocess missing image hashes.")
    ap.add_argument("--delay", type=float, default=10.0,
                    help="Seconds between attempts (1 image per N seconds). Default 10.")
    ap.add_argument("--retries", type=int, default=5)
    ap.add_argument("--export", action="store_true",
                    help="Only write missing_images.csv; do not reprocess.")
    ap.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    args = ap.parse_args(argv[1:])

    ua_path = os.path.join(OUT_DIR, "unique_artwork.jsonl.gz")
    if not os.path.exists(ua_path):  # legacy JSON-array download
        ua_path = os.path.join(OUT_DIR, "unique_artwork.json")
    checkpoint_path = os.path.join(OUT_DIR, "hashes_checkpoint.sqlite")
    sqlite_path = os.path.join(OUT_DIR, "cards.sqlite")
    missing_csv = os.path.join(OUT_DIR, "missing_images.csv")
    log_csv = os.path.join(OUT_DIR, "reprocess_log.csv")

    if not os.path.exists(ua_path):
        print(f"{ua_path} not found. Re-run build_bundle.py with --keep-bulk first.")
        return 1

    print("Computing the missing set (expected - already hashed)…")
    jobs = collect_hash_jobs(load_json(ua_path))
    done = _done_keys(checkpoint_path, sqlite_path)
    missing = [j for j in jobs if (j[1], j[2]) not in done]
    print(f"  expected={len(jobs):,}  already hashed={len(done):,}  missing={len(missing):,}")

    # Always write the full missing list.
    with open(missing_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["illustration_id", "scryfall_id", "face", "image_id", "url", "cached"])
        for ill, sid, face, image_id, url in missing:
            dest = _cache_path(args.cache_dir, image_id, face)
            cached = os.path.exists(dest) and os.path.getsize(dest) > 0
            w.writerow([ill, sid, face, image_id, url, int(cached)])
    print(f"  wrote full list -> {missing_csv}")

    if args.export or not missing:
        if not missing:
            print("Nothing missing — bundle is complete.")
        return 0

    eta_min = len(missing) * args.delay / 60.0
    print(f"\nReprocessing {len(missing):,} images at 1 per {args.delay}s "
          f"(~{eta_min:.0f} min). Ctrl-C is safe — progress is saved each item.")
    cp = _open_checkpoint(checkpoint_path)

    ok = 0
    reasons: dict = {}
    with open(log_csv, "a", newline="", encoding="utf-8") as logf:
        lw = csv.writer(logf)
        if logf.tell() == 0:
            lw.writerow(["ts", "scryfall_id", "face", "url", "result", "reason"])
        for i, (ill, sid, face, image_id, url) in enumerate(missing):
            if i > 0:
                time.sleep(args.delay)  # gentle: 1 image per --delay seconds
            dest = _cache_path(args.cache_dir, image_id, face)
            result, reason, h = "fail", "", None
            # 1. Try the existing cache file first (may be fine).
            if os.path.exists(dest) and os.path.getsize(dest) > 0:
                try:
                    h = phash.to_bytes(phash.phash_from_file(dest))
                    result, reason = "ok", "cached"
                except Exception:  # noqa: BLE001
                    os.remove(dest)  # corrupt/truncated -> re-download below
            # 2. (Re)download fresh and hash.
            if result != "ok":
                got, reason = _download(url, dest, args.retries)
                if got:
                    try:
                        h = phash.to_bytes(phash.phash_from_file(dest))
                        result, reason = "ok", "redownloaded"
                    except Exception as e:  # noqa: BLE001
                        reason = f"decode_{type(e).__name__}"
            if result == "ok":
                cp.execute(
                    "INSERT OR REPLACE INTO hashes "
                    "(illustration_id, scryfall_id, face, phash) VALUES (?,?,?,?)",
                    (ill, sid, face, h),
                )
                cp.commit()
                ok += 1
            else:
                reasons[reason] = reasons.get(reason, 0) + 1
            lw.writerow([datetime.now(timezone.utc).isoformat(), sid, face, url, result, reason])
            logf.flush()
            if (i + 1) % 10 == 0 or (i + 1) == len(missing):
                print(f"  {i+1}/{len(missing)}  ok={ok}  fail={i+1-ok}", flush=True)

    cp.close()
    print(f"\nDone. recovered={ok}  still-failing={len(missing)-ok}")
    if reasons:
        print("Still-failing reasons:")
        for r, c in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"  {c:>6}  {r}")
    print(f"\nPer-attempt log: {log_csv}")
    if ok:
        print("Fold recovered hashes into the bundle with:")
        print("  python build_bundle.py --repo <owner>/<repo> --keep-bulk")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
