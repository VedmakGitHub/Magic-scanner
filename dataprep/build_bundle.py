"""
build_bundle.py — produce the card-data bundle the app downloads on first launch.

Implements Section 4 of Phase1_Android_MTG_Scanner_Build_Plan.md:

  1. Resolve Scryfall bulk-data URLs programmatically (4.2) — never hard-coded.
  2. Download "unique_artwork" and "default_cards" bulk JSON.
  3. Build the `printings` table from default_cards (English printings; 4.4).
  4. Build the `hashes` table from unique_artwork: download each card's `normal`
     image and compute the reference pHash (4.3, Section 5.1).
  5. Emit dataprep/out/cards.sqlite, gzip it, and write manifest.json (4.5).
  6. Update docs/DATA.md with counts + source dates.

Publish with:
  gh release upload data-bundle dataprep/out/manifest.json \
      dataprep/out/cards.sqlite.gz --clobber

Usage:
  python build_bundle.py --repo <user>/<repo> [options]

Key options:
  --repo OWNER/NAME   GitHub repo hosting the data-bundle release (for sqlite_url).
  --limit N           Only process the first N unique-artwork objects (smoke test).
  --no-hash           Build metadata only; skip image download + hashing (fast).
  --concurrency N     Image-download workers (default 8; be polite, 4.3).
  --cache-dir PATH    Image cache dir (default dataprep/image_cache; reused across runs).
"""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from functools import partial
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests
from tqdm import tqdm

import phash

# ---------------------------------------------------------------------------
# Constants / config
# ---------------------------------------------------------------------------
APP_NAME = "MTGScanner"
APP_VERSION = "0.1.0"
# A real, specific User-Agent is REQUIRED on every api.scryfall.com call (4.2, Section 9).
USER_AGENT = f"{APP_NAME}/{APP_VERSION} (Phase1 dataprep; +https://github.com/)"
SCRYFALL_API = "https://api.scryfall.com"
SCRYFALL_MIN_DELAY = 0.1  # >=50-100ms between api.scryfall.com requests (<=10 req/s)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "out")
DEFAULT_CACHE_DIR = os.path.join(HERE, "image_cache")
DOCS_DATA = os.path.join(HERE, "..", "docs", "DATA.md")

_API_HEADERS = {"User-Agent": USER_AGENT, "Accept": "application/json"}
_last_api_call = 0.0

# Non-card layouts out of MVP scope. Excluded from BOTH printings and the hash
# set so every reference hash resolves to a real, collectible printing. (Their
# art-series backs are also a shared image that would otherwise produce thousands
# of identical degenerate hashes.)
EXCLUDED_LAYOUTS = {"art_series", "token", "double_faced_token", "emblem"}


# ---------------------------------------------------------------------------
# Scryfall fetch (4.2)
# ---------------------------------------------------------------------------
def _api_get(url: str) -> requests.Response:
    """GET an api.scryfall.com URL with required headers + polite rate limiting."""
    global _last_api_call
    wait = SCRYFALL_MIN_DELAY - (time.time() - _last_api_call)
    if wait > 0:
        time.sleep(wait)
    resp = requests.get(url, headers=_API_HEADERS, timeout=60)
    _last_api_call = time.time()
    resp.raise_for_status()
    return resp


def resolve_bulk_urls(wanted: Optional[set] = None) -> Dict[str, Dict[str, Any]]:
    """Return {type: bulk_object} for the wanted bulk types from /bulk-data (4.2)."""
    if wanted is None:
        wanted = {"unique_artwork", "default_cards"}
    data = _api_get(f"{SCRYFALL_API}/bulk-data").json()
    found: Dict[str, Dict[str, Any]] = {}
    for obj in data.get("data", []):
        t = obj.get("type")
        if t in wanted:
            found[t] = obj
    missing = wanted - found.keys()
    if missing:
        raise RuntimeError(f"Scryfall bulk-data missing types: {missing}")
    return found


def download_bulk(obj: Dict[str, Any], dest: str) -> str:
    """Download a bulk file from its `download_uri` (served from *.scryfall.io, 4.2)."""
    uri = obj["download_uri"]
    print(f"  downloading {obj['type']} -> {os.path.basename(dest)}")
    with requests.get(uri, headers={"User-Agent": USER_AGENT}, stream=True, timeout=600) as r:
        r.raise_for_status()
        total = int(r.headers.get("Content-Length", 0))
        with open(dest, "wb") as f, tqdm(
            total=total, unit="B", unit_scale=True, desc="    ", leave=False
        ) as bar:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
                bar.update(len(chunk))
    return dest


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Image CDN URL construction (4.6)
# ---------------------------------------------------------------------------
def cdn_url(image_id: str, size: str = "normal", face: str = "front") -> str:
    """https://cards.scryfall.io/<size>/<face>/<id[0]>/<id[1]>/<id>.jpg (4.6)."""
    return (
        f"https://cards.scryfall.io/{size}/{face}/"
        f"{image_id[0]}/{image_id[1]}/{image_id}.jpg"
    )


# ---------------------------------------------------------------------------
# Faces helper — normalize single-faced and double-faced cards (4.3 / 4.4)
# ---------------------------------------------------------------------------
def iter_faces(card: Dict[str, Any]) -> Iterable[Tuple[str, Dict[str, Any]]]:
    """Yield (face_label, face_data) for each hashable/printable face of a card.

    face_data carries the fields we need: image_uris, illustration_id, artist,
    plus a synthesized `image_id` used to build CDN urls.

    - Single-faced card: one ("front", ...).
    - Double-faced card with per-face image_uris: ("front", ...), ("back", ...).
    - A card whose images live at the top level but has card_faces (e.g. split /
      adventure cards share one image): one ("front", ...).
    """
    faces = card.get("card_faces")
    top_image_uris = card.get("image_uris")
    if faces and any(f.get("image_uris") for f in faces):
        labels = ["front", "back", "front", "back"]  # >2 faces is unheard of; clamp safe
        for i, f in enumerate(faces):
            iu = f.get("image_uris")
            if not iu:
                continue
            label = labels[i] if i < len(labels) else "front"
            # Per-face image id: prefer the face's own illustration-linked image.
            image_id = _image_id_from_uris(iu) or card.get("id")
            yield label, {
                "image_uris": iu,
                "illustration_id": f.get("illustration_id") or card.get("illustration_id"),
                "artist": f.get("artist") or card.get("artist"),
                "image_id": image_id,
            }
    else:
        iu = top_image_uris or (faces[0].get("image_uris") if faces else None)
        image_id = _image_id_from_uris(iu) if iu else None
        image_id = image_id or card.get("id")
        yield "front", {
            "image_uris": iu,
            "illustration_id": card.get("illustration_id"),
            "artist": card.get("artist"),
            "image_id": image_id,
        }


def _image_id_from_uris(image_uris: Optional[Dict[str, str]]) -> Optional[str]:
    """Extract the CDN image id from any image_uris entry (path .../<id>.jpg?...)."""
    if not image_uris:
        return None
    for key in ("normal", "large", "small", "art_crop", "png"):
        url = image_uris.get(key)
        if url:
            tail = url.split("?")[0].rsplit("/", 1)[-1]  # "<id>.jpg"
            return tail.rsplit(".", 1)[0]
    return None


# ---------------------------------------------------------------------------
# Step 3: printings table (4.4)
# ---------------------------------------------------------------------------
_PRINTINGS_INSERT = """INSERT OR REPLACE INTO printings
   (scryfall_id, oracle_id, illustration_id, name, set_code, set_name,
    collector_number, rarity, finishes, lang, released_at, image_id,
    face, price_usd, price_usd_foil, artist)
   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""


def _printing_rows_for_card(card: Dict[str, Any]) -> List[Tuple]:
    """Row tuples for one card object (one per face). Empty if out of scope."""
    if card.get("layout") in EXCLUDED_LAYOUTS:
        return []  # non-card layouts aren't real printings to scan/collect
    prices = card.get("prices") or {}
    out: List[Tuple] = []
    for face_label, face in iter_faces(card):
        out.append((
            card["id"], card.get("oracle_id"), face.get("illustration_id"),
            card.get("name"), card.get("set"), card.get("set_name"),
            card.get("collector_number"), card.get("rarity"),
            json.dumps(card.get("finishes") or []), card.get("lang", "en"),
            card.get("released_at"), face.get("image_id"), face_label,
            _to_float(prices.get("usd")), _to_float(prices.get("usd_foil")),
            face.get("artist"),
        ))
    return out


def build_printings(conn: sqlite3.Connection, default_cards: List[Dict[str, Any]]) -> int:
    """English-only printings from Default Cards (in-memory list)."""
    rows: List[Tuple] = []
    for card in default_cards:
        if card.get("lang") != "en":
            continue
        rows.extend(_printing_rows_for_card(card))
    conn.executemany(_PRINTINGS_INSERT, rows)
    conn.commit()
    return len(rows)


def build_printings_all_languages(conn: sqlite3.Connection, all_cards_path: str,
                                  batch: int = 20000) -> int:
    """All-language printings from the All Cards bulk, STREAMED with ijson so the
    2.5 GB file never loads fully into memory. Includes every language so the app
    can identify and resolve any card printed by Wizards (Section: any-language).
    """
    import ijson
    total = 0
    rows: List[Tuple] = []
    with open(all_cards_path, "rb") as f:
        for card in ijson.items(f, "item"):
            rows.extend(_printing_rows_for_card(card))
            if len(rows) >= batch:
                conn.executemany(_PRINTINGS_INSERT, rows)
                conn.commit()
                total += len(rows)
                rows.clear()
    if rows:
        conn.executemany(_PRINTINGS_INSERT, rows)
        conn.commit()
        total += len(rows)
    return total


def _to_float(v: Any) -> Optional[float]:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Step 4: hashes table (4.3)
# ---------------------------------------------------------------------------
def _cache_path(cache_dir: str, image_id: str, face: str) -> str:
    sub = os.path.join(cache_dir, image_id[0], image_id[1])
    os.makedirs(sub, exist_ok=True)
    return os.path.join(sub, f"{image_id}_{face}.jpg")


def _download_image(url: str, dest: str, retries: int = 3) -> bool:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return True  # cache hit; re-runs are incremental (4.3)
    for attempt in range(retries):
        try:
            with requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=120) as r:
                if r.status_code == 404:
                    return False
                r.raise_for_status()
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    f.write(r.content)
                os.replace(tmp, dest)
                time.sleep(0.02)  # small politeness delay
                return True
        except requests.RequestException:
            if attempt == retries - 1:
                return False
            time.sleep(0.5 * (attempt + 1))
    return False


def _hash_worker(job: Tuple, cache_dir: str) -> Optional[Tuple]:
    """Download (cache) one image and compute its pHash. Top-level + picklable so
    it runs in a ProcessPoolExecutor worker.

    Hashing is pure-Python (for Python<->Dart parity) and therefore CPU-bound and
    GIL-serialized — threads can't parallelize it. Processes give true multi-core
    parallelism while running the EXACT same phash.py code, so parity is
    preserved bit-for-bit.
    """
    illustration_id, scryfall_id, face_label, image_id, url = job
    dest = _cache_path(cache_dir, image_id, face_label)
    if not _download_image(url, dest):
        return None
    try:
        h = phash.phash_from_file(dest)
    except Exception:  # noqa: BLE001  (corrupt/partial image — skip)
        return None
    # 256-bit hash stored as a 32-byte big-endian BLOB.
    return (illustration_id, scryfall_id, face_label, phash.to_bytes(h))


# Checkpoint store: hashes are written here incrementally as they complete, so a
# crash/sleep/Ctrl-C loses at most a few seconds of work. The expensive hash run
# is the only thing worth checkpointing; printings rebuild in seconds. Lives in
# out/ (gitignored). The final cards.sqlite `hashes` table is copied from here.
CHECKPOINT_COMMIT_EVERY = 200


def _open_checkpoint(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE IF NOT EXISTS hashes (
             illustration_id TEXT,
             scryfall_id     TEXT,
             face            TEXT,
             phash           BLOB NOT NULL,
             PRIMARY KEY (scryfall_id, face)
           )"""
    )
    conn.commit()
    return conn


def collect_hash_jobs(
    unique_artwork: List[Dict[str, Any]], limit: Optional[int] = None
) -> List[Tuple[Optional[str], str, str, str, str]]:
    """Derive the set of hashable jobs from Unique Artwork (4.3).

    Each job is (illustration_id, scryfall_id, face_label, image_id, url). Shared
    by build_hashes and verify_bundle so the "expected" set is defined in exactly
    one place.
    """
    jobs: List[Tuple[Optional[str], str, str, str, str]] = []
    for card in unique_artwork:
        if limit is not None and len(jobs) >= limit:
            break
        if card.get("layout") in EXCLUDED_LAYOUTS:
            continue  # mirror build_printings so every hash resolves to a printing
        for face_label, face in iter_faces(card):
            iu = face.get("image_uris")
            illustration_id = face.get("illustration_id")
            image_id = face.get("image_id")
            if not iu or not image_id:
                continue  # skip objects with no usable image (4.3)
            if not illustration_id:
                continue  # skip objects without an illustration_id (4.3)
            url = iu.get("normal") or cdn_url(image_id, "normal", face_label)
            jobs.append((illustration_id, card["id"], face_label, image_id, url))
    return jobs


def build_hashes(
    conn: sqlite3.Connection,
    unique_artwork: List[Dict[str, Any]],
    cache_dir: str,
    concurrency: int,
    limit: Optional[int],
    checkpoint_path: str,
    resume: bool = True,
) -> int:
    jobs = collect_hash_jobs(unique_artwork, limit)

    os.makedirs(cache_dir, exist_ok=True)

    if not resume and os.path.exists(checkpoint_path):
        os.remove(checkpoint_path)
    cp = _open_checkpoint(checkpoint_path)

    # Skip jobs already hashed in a previous run (resume).
    done = {(r[0], r[1]) for r in cp.execute("SELECT scryfall_id, face FROM hashes")}
    if done:
        before = len(jobs)
        jobs = [j for j in jobs if (j[1], j[2]) not in done]
        print(f"      resume: {len(done):,} already hashed, {before - len(jobs):,} "
              f"skipped, {len(jobs):,} remaining")

    worker = partial(_hash_worker, cache_dir=cache_dir)
    batch: List[Tuple] = []

    def flush() -> None:
        if not batch:
            return
        cp.executemany(
            "INSERT OR REPLACE INTO hashes "
            "(illustration_id, scryfall_id, face, phash) VALUES (?,?,?,?)",
            batch,
        )
        cp.commit()
        batch.clear()

    if jobs:
        # map streams results with low per-task overhead; chunksize amortizes IPC.
        # All DB writes happen here in the parent (no multi-process write contention).
        with ProcessPoolExecutor(max_workers=concurrency) as ex:
            for res in tqdm(
                ex.map(worker, jobs, chunksize=8),
                total=len(jobs),
                desc="  hashing",
            ):
                if res is not None:
                    batch.append(res)
                    if len(batch) >= CHECKPOINT_COMMIT_EVERY:
                        flush()
            flush()

    # Copy the checkpoint into the final bundle DB enforcing two invariants:
    #   (a) every hash resolves to a printing (illustration_id present in
    #       printings) — drops excluded-layout / foreign-only-art rows;
    #   (b) exactly ONE hash per illustration_id ("one hash per artwork",
    #       Section 4.3) — collapses any duplicate coverage that arises when a
    #       checkpoint spans multiple daily Scryfall snapshots, preferring the
    #       row whose (scryfall_id, face) exists in the current printings.
    valid_ill = {r[0] for r in conn.execute(
        "SELECT DISTINCT illustration_id FROM printings WHERE illustration_id IS NOT NULL"
    )}
    current_keys = {(r[0], r[1]) for r in conn.execute(
        "SELECT scryfall_id, face FROM printings"
    )}
    all_rows = cp.execute(
        "SELECT illustration_id, scryfall_id, face, phash FROM hashes"
    ).fetchall()
    cp.close()

    best: dict = {}  # illustration_id -> chosen row
    dropped = 0
    for r in all_rows:
        ill, sid, face, _ = r
        if ill not in valid_ill:
            dropped += 1
            continue
        cur = best.get(ill)
        if cur is None:
            best[ill] = r
        elif (sid, face) in current_keys and (cur[1], cur[2]) not in current_keys:
            best[ill] = r  # prefer a current-snapshot printing as the representative
    kept = list(best.values())
    deduped = len(all_rows) - dropped - len(kept)
    if dropped:
        print(f"      dropped {dropped:,} unresolvable hashes (no matching printing)")
    if deduped:
        print(f"      collapsed {deduped:,} duplicate-artwork hashes "
              f"(multi-snapshot) to one per illustration")
    conn.executemany(
        "INSERT INTO hashes (illustration_id, scryfall_id, face, phash) VALUES (?,?,?,?)",
        kept,
    )
    conn.commit()
    return len(kept)


def backfill_missing_artworks(conn: sqlite3.Connection, cache_dir: str,
                              concurrency: int, checkpoint_path: str) -> int:
    """Hash any artwork that has a printing but no hash yet.

    Unique Artwork (the primary hash source) omits a few illustrations — some
    Secret Lair / Planechase / special-product cards and a few non-English-only
    printings. This pass guarantees 100% artwork coverage: for every
    illustration_id present in `printings` but missing from `hashes`, it hashes a
    representative printing (preferring English) and inserts into both the
    checkpoint and the bundle. Idempotent and cheap (typically a few dozen).
    """
    # One representative printing per missing illustration, English preferred.
    rows = conn.execute(
        """SELECT illustration_id, scryfall_id, face, image_id, lang FROM printings
           WHERE illustration_id IS NOT NULL AND image_id IS NOT NULL
             AND illustration_id NOT IN (SELECT illustration_id FROM hashes)"""
    ).fetchall()
    reps: dict = {}
    for ill, sid, face, image_id, lang in rows:
        cur = reps.get(ill)
        if cur is None or (lang == "en" and cur[4] != "en"):
            reps[ill] = (ill, sid, face, image_id, lang)
    if not reps:
        return 0
    jobs = [(ill, sid, face, image_id, cdn_url(image_id, "normal", face))
            for (ill, sid, face, image_id, _lang) in reps.values()]
    print(f"      backfilling {len(jobs):,} artworks missing from Unique Artwork")

    os.makedirs(cache_dir, exist_ok=True)
    worker = partial(_hash_worker, cache_dir=cache_dir)
    new_rows: List[Tuple] = []
    with ProcessPoolExecutor(max_workers=concurrency) as ex:
        for res in tqdm(ex.map(worker, jobs, chunksize=4), total=len(jobs),
                        desc="  backfill"):
            if res is not None:
                new_rows.append(res)
    if new_rows:
        cp = _open_checkpoint(checkpoint_path)
        cp.executemany(
            "INSERT OR REPLACE INTO hashes "
            "(illustration_id, scryfall_id, face, phash) VALUES (?,?,?,?)", new_rows)
        cp.commit()
        cp.close()
        conn.executemany(
            "INSERT INTO hashes (illustration_id, scryfall_id, face, phash) VALUES (?,?,?,?)",
            new_rows)
        conn.commit()
    return len(new_rows)


def _to_signed64(u: int) -> int:
    """Map a 64-bit unsigned int into the signed range SQLite INTEGER stores."""
    u &= 0xFFFFFFFFFFFFFFFF
    return u - (1 << 64) if u >= (1 << 63) else u


# ---------------------------------------------------------------------------
# Schema (Section 7)
# ---------------------------------------------------------------------------
SCHEMA = """
-- One row per printing PER FACE (a double-faced card's back face has its own
-- illustration_id, so scanning the back must resolve to a printing row too).
-- This is why the primary key is composite (scryfall_id, face) rather than
-- scryfall_id alone as sketched in Section 7.
CREATE TABLE printings (
  scryfall_id      TEXT NOT NULL,
  oracle_id        TEXT,
  illustration_id  TEXT,
  name             TEXT NOT NULL,
  set_code         TEXT NOT NULL,
  set_name         TEXT NOT NULL,
  collector_number TEXT NOT NULL,
  rarity           TEXT,
  finishes         TEXT,
  lang             TEXT NOT NULL,
  released_at      TEXT,
  image_id         TEXT,
  face             TEXT NOT NULL DEFAULT 'front',
  price_usd        REAL,
  price_usd_foil   REAL,
  artist           TEXT,
  PRIMARY KEY (scryfall_id, face)
);
CREATE INDEX idx_printings_illustration ON printings(illustration_id);
CREATE INDEX idx_printings_name ON printings(name);

CREATE TABLE hashes (
  illustration_id  TEXT,
  scryfall_id      TEXT,
  face             TEXT,
  phash            BLOB NOT NULL          -- 256-bit DCT pHash, 32-byte big-endian
);
CREATE INDEX idx_hashes_phash ON hashes(phash);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""


def create_db(path: str) -> sqlite3.Connection:
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# Step 5: package (4.5)
# ---------------------------------------------------------------------------
def gzip_file(src: str, dst: str) -> int:
    with open(src, "rb") as fin, gzip.open(dst, "wb", compresslevel=9) as fout:
        shutil.copyfileobj(fin, fout)
    return os.path.getsize(dst)


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest(
    path: str,
    bundle_version: str,
    scryfall_updated_at: str,
    card_count: int,
    hash_count: int,
    sqlite_sha256: str,
    sqlite_url: str,
    sqlite_gzip_bytes: int,
) -> None:
    manifest = {
        "bundle_version": bundle_version,
        "scryfall_updated_at": scryfall_updated_at,
        "card_count": card_count,
        "hash_count": hash_count,
        "sqlite_sha256": sqlite_sha256,
        "sqlite_url": sqlite_url,
        "sqlite_gzip_bytes": sqlite_gzip_bytes,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")


def write_docs_data(**kw: Any) -> None:
    os.makedirs(os.path.dirname(DOCS_DATA), exist_ok=True)
    content = f"""# Card data bundle

Generated by `dataprep/build_bundle.py`. Do not edit by hand.

| Field | Value |
|---|---|
| Bundle version | `{kw['bundle_version']}` |
| Build date (UTC) | {kw['build_date']} |
| Scryfall bulk `updated_at` | {kw['scryfall_updated_at']} |
| `printings` rows | {kw['card_count']:,} |
| `hashes` rows | {kw['hash_count']:,} |
| `cards.sqlite` SHA-256 | `{kw['sqlite_sha256']}` |
| `cards.sqlite.gz` bytes | {kw['sqlite_gzip_bytes']:,} |
| `sqlite_url` | {kw['sqlite_url']} |

## Sources
- Scryfall **Unique Artwork** bulk file — defines the reference set we hash (one hash per artwork/face).
- Scryfall **Default Cards** bulk file — every English printing (set / collector number / finishes / prices / image components).

## Refresh
Re-run `python build_bundle.py --repo <owner>/<repo>` weekly and after each new
set release, then publish:

```
gh release upload data-bundle dataprep/out/manifest.json dataprep/out/cards.sqlite.gz --clobber
```

## Recognition-accuracy results (Section 11)
Fill in after running the hand-built ≥100-card test set:

- Top-5 accuracy: _TBD_ (target ≥90%)
- Top-1 accuracy: _TBD_ (target ≥75%)
- Median hash+match latency: _TBD_ (target <500 ms)
"""
    with open(DOCS_DATA, "w", encoding="utf-8") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="Build the MTG card-data bundle.")
    ap.add_argument("--repo", default="<owner>/<repo>",
                    help="GitHub repo hosting the data-bundle release (for sqlite_url).")
    ap.add_argument("--limit", type=int, default=None,
                    help="Process only the first N unique-artwork faces (smoke test).")
    ap.add_argument("--no-hash", action="store_true",
                    help="Build metadata only; skip image download + hashing.")
    ap.add_argument("--concurrency", type=int, default=(os.cpu_count() or 8),
                    help="Parallel worker PROCESSES for image download+hash "
                         "(default: logical CPU count).")
    ap.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    ap.add_argument("--keep-bulk", action="store_true",
                    help="Keep downloaded bulk JSON in out/ for reuse.")
    ap.add_argument("--no-resume", action="store_true",
                    help="Start hashing from scratch, clearing the checkpoint "
                         "(default: resume from out/hashes_checkpoint.sqlite).")
    ap.add_argument("--languages", choices=["en", "all"], default="en",
                    help="Printings to include: 'en' (Default Cards, English only) "
                         "or 'all' (All Cards, every language printed by Wizards). "
                         "'all' is metadata-only and reuses the existing hash "
                         "checkpoint — no images are re-hashed.")
    args = ap.parse_args(argv[1:])

    os.makedirs(OUT_DIR, exist_ok=True)
    sqlite_path = os.path.join(OUT_DIR, "cards.sqlite")
    gz_path = sqlite_path + ".gz"
    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    checkpoint_path = os.path.join(OUT_DIR, "hashes_checkpoint.sqlite")

    all_langs = args.languages == "all"
    printings_type = "all_cards" if all_langs else "default_cards"

    print("[1/6] Resolving Scryfall bulk URLs ...")
    bulk = resolve_bulk_urls({"unique_artwork", printings_type})
    scryfall_updated_at = bulk[printings_type].get("updated_at", "")

    ua_path = os.path.join(OUT_DIR, "unique_artwork.json")
    printings_path = os.path.join(OUT_DIR, f"{printings_type}.json")

    print("[2/6] Downloading bulk files ...")
    if not (args.keep_bulk and os.path.exists(printings_path)):
        download_bulk(bulk[printings_type], printings_path)
    if not (args.keep_bulk and os.path.exists(ua_path)):
        download_bulk(bulk["unique_artwork"], ua_path)

    print(f"[3/6] Building printings table ({args.languages}) ...")
    conn = create_db(sqlite_path)
    if all_langs:
        # Streamed (ijson) so the 2.5 GB All Cards file never fully loads.
        card_count = build_printings_all_languages(conn, printings_path)
    else:
        card_count = build_printings(conn, load_json(printings_path))
    print(f"      printings rows: {card_count:,}")

    print("[4/6] Building hashes table ...")
    if args.no_hash:
        print("      --no-hash: skipping image download + hashing")
        hash_count = 0
    else:
        unique_artwork = load_json(ua_path)
        hash_count = build_hashes(
            conn, unique_artwork, args.cache_dir, args.concurrency, args.limit,
            checkpoint_path, resume=not args.no_resume,
        )
        # Hash any artwork that has a printing but no hash (gaps in Unique Artwork).
        if args.limit is None:
            hash_count += backfill_missing_artworks(
                conn, args.cache_dir, args.concurrency, checkpoint_path)
    print(f"      hashes rows: {hash_count:,}")

    bundle_version = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d")
    if all_langs:
        bundle_version += "-all"  # distinct version so clients re-download
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('bundle_version', ?)", (bundle_version,))
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('scryfall_updated_at', ?)",
                 (scryfall_updated_at,))
    conn.commit()
    conn.close()

    print("[5/6] Packaging (gzip + sha256 + manifest) ...")
    sqlite_sha256 = sha256_file(sqlite_path)
    gz_bytes = gzip_file(sqlite_path, gz_path)
    sqlite_url = (
        f"https://github.com/{args.repo}/releases/download/data-bundle/cards.sqlite.gz"
    )
    write_manifest(
        manifest_path, bundle_version, scryfall_updated_at, card_count, hash_count,
        sqlite_sha256, sqlite_url, gz_bytes,
    )

    print("[6/6] Writing docs/DATA.md ...")
    write_docs_data(
        bundle_version=bundle_version,
        build_date=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        scryfall_updated_at=scryfall_updated_at,
        card_count=card_count,
        hash_count=hash_count,
        sqlite_sha256=sqlite_sha256,
        sqlite_url=sqlite_url,
        sqlite_gzip_bytes=gz_bytes,
    )

    if not args.keep_bulk:
        for p in (ua_path, printings_path):
            if os.path.exists(p):
                os.remove(p)

    print("\nDone.")
    print(f"  {sqlite_path}  ({os.path.getsize(sqlite_path):,} bytes)")
    print(f"  {gz_path}  ({gz_bytes:,} bytes)")
    print(f"  {manifest_path}")
    print("\nPublish with:")
    print("  gh release upload data-bundle dataprep/out/manifest.json "
          "dataprep/out/cards.sqlite.gz --clobber")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
