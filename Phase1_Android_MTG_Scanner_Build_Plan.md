# Phase 1 MVP — Android MTG Card Scanner

**A build specification for Claude Code.**

This document is a complete, self-contained plan to build the Phase 1 MVP of a Magic: The Gathering card-scanning Android app. It is written to be handed directly to Claude Code as the source of truth. It specifies the tech stack, repository layout, the **external data pipeline** (the heart of card identification), exact data schemas, the perceptual-hash algorithm (which must be implemented identically in two places), the on-device recognition flow, the app screens, legal-notice requirements, and acceptance criteria.

Scope is deliberately narrow: **scan a card with the camera, identify it on-device, let the user confirm/correct the exact printing, and save it to a local collection.** No user accounts, no cloud sync, no payments, no OCR. Those are later phases.

---

## 0. How to use this with Claude Code

1. Complete developer machine setup (Section 0.1) and create the GitHub repo with the data-bundle release (Section 0.2). These are human/interactive steps Claude Code can't do for you — do them first.
2. Place this file at the root of the repo created in Section 0.2.
3. Tell Claude Code: *"Implement the MVP described in `Phase1_Android_MTG_Scanner_Build_Plan.md`. Start with the `dataprep` Python pipeline (Section 4), then the Flutter app (Sections 6–9). Follow the acceptance criteria in Section 11."*
4. Build the `dataprep` pipeline **first** and run it once to produce the data bundle, then publish it via the GitHub Release from Section 0.2 — the app cannot recognize anything without it.
5. Implement and verify the **hash-parity test** (Section 5.3) before building the camera flow; everything downstream depends on it.

### 0.1 Developer machine setup

Do this once, before pointing Claude Code at the repo. Installing Android Studio, pairing a physical device, and accepting SDK licenses are interactive, human steps — Claude Code cannot do these for you.

**1. Git and GitHub CLI**
- Install git if it isn't already present (commonly preinstalled on macOS/Linux; on Windows install Git for Windows).
- Install the GitHub CLI (`gh`) — it's used to publish the data bundle in Section 0.2. macOS: `brew install gh`; Windows: `winget install GitHub.cli`; Linux: see cli.github.com for your distro's package manager.
- Authenticate once: `gh auth login` (choose GitHub.com → HTTPS → authenticate via browser).

**2. Flutter SDK (stable channel)**
- Download the SDK from the official install page (docs.flutter.dev/install) or the SDK archive, and extract it to a short path with no spaces (e.g. `~/development/flutter` on macOS/Linux, `C:\src\flutter` on Windows). Avoid `Program Files` and avoid paths that require elevated permissions.
- Add `<flutter_dir>/bin` to your PATH and restart your terminal.
- Make sure you're tracking the stable channel and have the latest build on it:
  ```
  flutter channel stable
  flutter upgrade
  ```
- Run `flutter doctor`. Resolve everything it flags **except** the Android toolchain/licenses (next step) and iOS/Xcode (not needed — Phase 1 is Android-only).

**3. Android SDK + physical device**
- Install **Android Studio**. During first-run setup, let it install the Android SDK, the latest stable platform, and the Android SDK Command-line Tools component — this is the most reliable way to get a correctly configured SDK, even though day-to-day work happens via Claude Code/the command line.
- If Flutter doesn't auto-detect the SDK, point it there explicitly: `flutter config --android-sdk <path-to-sdk>` (find the path in Android Studio under Settings → Languages & Frameworks → Android SDK).
- Accept the SDK licenses (required before any Gradle build will run): `flutter doctor --android-licenses`, answering `y` to each prompt.
- Re-run `flutter doctor` until the Android toolchain line shows a checkmark.
- **Use a physical device for real testing, not just the emulator** — the recognition-accuracy criteria in Section 11 depend on a real camera and real lighting:
  - On the phone: Settings → About phone → tap "Build number" seven times to unlock Developer options.
  - Settings → Developer options → enable **USB debugging**.
  - Connect the phone via USB and accept the "Allow USB debugging?" prompt on the phone (tick "always allow from this computer").
  - Verify: `adb devices` should list it as `device` (not `unauthorized`), and `flutter devices` should also show it.
  - If the phone doesn't appear: try a different cable/port (some cables are charge-only), check the phone's USB mode is set to file transfer rather than charging-only, and on Windows confirm a driver installed.

**4. Python 3.11+**
- Install Python 3.11 or later: macOS (`brew install python@3.11`), Windows (installer from python.org — tick "Add python.exe to PATH"), Linux (your distro's package manager, or `pyenv` if you want it isolated from the system Python).
- Confirm with `python3 --version` (`python --version` on Windows).
- Once `dataprep/requirements.txt` exists, create an isolated virtual environment for it:
  ```
  cd dataprep
  python3 -m venv .venv
  source .venv/bin/activate        # Windows: .venv\Scripts\activate
  pip install -r requirements.txt
  ```
  Expect that file to include at least `requests`, `Pillow`, `numpy`/`scipy` (for the DCT in Section 5.1), and `tqdm`; Claude Code will pin exact versions when it writes the pipeline.

**Disk space:** budget roughly 20 GB free for the one-time Unique Artwork image download in Section 4.3. That space is freed once the bundle is built, since images aren't shipped in the final bundle.

### 0.2 Repository and GitHub Releases setup

This creates the repo that holds the code **and** sets up the mechanism that will host the data bundle — Section 4.5 depends on this existing first.

**1. Create the repository**
- On GitHub: New repository → name it (e.g. `mtg-scanner`) → **public**. Public is what makes the release-asset URLs below fetchable by the app with no authentication and no API rate limit, and keeps hosting free.
- Locally:
  ```
  git clone https://github.com/<your-username>/mtg-scanner.git
  cd mtg-scanner
  ```
  (Or `git init` in an existing folder and `git remote add origin https://github.com/<your-username>/mtg-scanner.git`.)
- Place this spec file at the repo root, then create the `dataprep/` and `app/` folders per Section 3.

**2. Add a `.gitignore`**
At minimum, ignore: `dataprep/out/`, `dataprep/.venv/`, the image cache from Section 4.3 (e.g. `dataprep/image_cache/`), Python caches (`__pycache__/`, `*.pyc`), and Flutter/Dart build output (`app/build/`, `app/.dart_tool/`, `app/.flutter-plugins*`). The bundle and any build artifacts don't belong in git — the bundle is distributed via Releases, not the repo.

**3. Commit and push**
```
git add .
git commit -m "Initial structure: spec, dataprep scaffold, Flutter scaffold"
git push -u origin main
```

**4. Set up the data-bundle release**

This is the concrete hosting mechanism Section 4.5 refers to: a single, continuously-updated GitHub Release at a **fixed tag**, so the app always knows exactly where to look without ever calling a rate-limited API.

- Create the release once, with a fixed tag:
  ```
  gh release create data-bundle --title "MTG card data bundle" \
    --notes "Rolling release; assets are replaced on each dataprep run. See manifest.json for the current bundle_version."
  ```
- Each time `dataprep/build_bundle.py` produces a new `cards.sqlite.gz` + `manifest.json`, publish them by overwriting that same release's assets:
  ```
  gh release upload data-bundle dataprep/out/manifest.json dataprep/out/cards.sqlite.gz --clobber
  ```
  `--clobber` replaces existing assets of the same filename instead of erroring, so the two URLs below never change — only their contents do.
- This gives two **fixed, public, unauthenticated** URLs for the app to use directly:
  ```
  https://github.com/<your-username>/mtg-scanner/releases/download/data-bundle/manifest.json
  https://github.com/<your-username>/mtg-scanner/releases/download/data-bundle/cards.sqlite.gz
  ```
  Wire these into the app's bundle-loader config (Section 4.5) as the manifest URL and the `sqlite_url` referenced from it.

**Why this avoids the GitHub API entirely:** a `releases/download/...` link is a direct asset download — it redirects to GitHub's object storage rather than hitting `api.github.com` — so it isn't subject to the **60-requests/hour unauthenticated limit** on the REST API. Using a fixed tag with `--clobber` also means the app never needs to ask "what's the latest release"; it just re-fetches the same two URLs and compares `bundle_version` in the manifest to decide whether to re-download. Each release asset is capped at 2 GiB (the gzipped bundle is expected to be tens of MB, well under this), and GitHub does not cap total bandwidth for public release downloads.

After the first real publish, record the actual repo URL in `docs/DATA.md` alongside the bundle version and source dates from Section 4.

---

## 1. Product definition (MVP)

The user opens the app, points the camera at a single MTG card laid on a contrasting surface, aligns it inside an on-screen guide frame, and captures. The app computes a perceptual hash of the card image, matches it against a bundled reference database entirely on-device, and shows the **top 3–5 candidate cards** with thumbnails. The user taps the correct one. If the matched artwork was reprinted in several sets, the user can open a **version picker** to choose the exact set / collector number / finish. The card is added to a **local collection** stored on the device. The user can browse, search, edit quantities, and delete from the collection.

Everything works **offline** after the one-time data bundle download. Card images are fetched lazily from Scryfall's CDN and cached.

### In scope
- Camera capture with an alignment guide overlay.
- On-device whole-card perceptual-hash recognition against a bundled reference set.
- Top-K candidate confirmation UI.
- Manual version/set/finish picker for the matched card.
- Local collection: add, list, search, edit quantity, delete; quantities per finish.
- Lazy card-image loading + disk cache.
- Optional, clearly-labelled "estimated value" using bulk price data (display only).
- Required legal/attribution notices.

### Explicitly out of scope for Phase 1
- Accounts, login, cloud sync, multi-device.
- OCR / collector-number reading (Phase 2).
- Automatic edge/contour detection and perspective correction (use the guide frame instead; auto-detect is Phase 2).
- Foil detection from glare (never attempt; finish is user-selected).
- Marketplace/affiliate integration, real-time prices, buying/selling.
- iOS (the codebase is cross-platform Flutter, but only Android is built/tested in Phase 1).

---

## 2. Tech stack

- **Framework:** Flutter (stable channel), Dart. Cross-platform now, ship Android only in Phase 1.
- **Language for data pipeline:** Python 3.11+.
- **On-device DB:** SQLite via `drift` (typed, migration-friendly) or `sqflite` if simpler. Prefer `drift`.
- **Camera:** `camera` (official Flutter plugin).
- **Image pixel access / hashing:** `image` (pure-Dart; gives raw pixel buffers and DCT-friendly grayscale).
- **HTTP + caching:** `dio` for downloads; `cached_network_image` for lazy card-image display + disk cache.
- **State management:** `riverpod` (or `provider` if Claude Code prefers); keep it simple.
- **Misc:** `path_provider` (file paths), `archive` (gzip unpack of the data bundle).

Do **not** require OpenCV for the MVP. The guide-frame approach removes the need for automatic card detection. Note `opencv_dart`/`dartcv` as a Phase 2 dependency for auto-detection, not Phase 1.

---

## 3. Repository layout

```
/                              # this spec at root
/dataprep/                     # Python pipeline that builds the data bundle (Section 4)
  build_bundle.py
  phash.py                     # reference pHash implementation (Section 5)
  requirements.txt
  out/                         # generated bundle (gitignored)
/app/                          # Flutter app
  lib/
    main.dart
    data/                      # DB access, models, bundle loader
    recognition/               # on-device pHash + matcher (Section 5)
    camera/                    # capture screen + guide overlay
    collection/                # collection storage + screens
    ui/                        # shared widgets, theme
    legal/                     # notices screen + strings
  assets/
  android/
  pubspec.yaml
/docs/
  DATA.md                      # generated: bundle version, counts, source dates
```

The `dataprep` output is a **data bundle** the app downloads on first launch (Section 4.5). It is not committed to git.

---

## 4. External data — the card-identification pipeline

This is the part of the system that makes identification possible. The app ships with **no** card data baked in; it downloads a pre-built bundle on first launch. The bundle is produced by `dataprep/build_bundle.py`, which is run by us (not on the device) whenever data needs refreshing.

### 4.1 Data sources (authoritative, free)

| Data | Source | Use |
|---|---|---|
| Unique artworks (one card per distinct illustration) | Scryfall **Unique Artwork** bulk file | Defines the reference set we hash — one hash per artwork |
| All printings (English) | Scryfall **Default Cards** bulk file | Maps each `illustration_id` to all its printings (set, collector number, finishes, prices, image URIs) for the version picker |
| Card images | Scryfall image CDN (`cards.scryfall.io`) | (a) downloaded during preprocessing to compute hashes; (b) fetched lazily at runtime for display |
| (Optional) Oracle/identifier cross-refs | MTGJSON `AllPrintings` / `AllIdentifiers` | Not required for MVP; Scryfall alone is sufficient. Listed as an alternative source. |

Scryfall is the single required source for Phase 1. MTGJSON is optional and not used in the MVP path.

### 4.2 How to fetch Scryfall bulk data (do not hard-code URLs)

Bulk file URLs are **timestamped and change daily**, so resolve them programmatically:

1. `GET https://api.scryfall.com/bulk-data`
   - Required headers on **every** `api.scryfall.com` request: `User-Agent: <AppName>/<version>` (a real, specific value — do not let the HTTP lib set a generic one) and `Accept: application/json`.
   - Insert 50–100 ms delay between `api.scryfall.com` requests (≤10 req/s). The pipeline makes only a couple of these calls, so this is trivial.
2. From the returned list, find the objects with `type == "unique_artwork"` and `type == "default_cards"`. Read each object's `download_uri`.
3. `GET` each `download_uri`. These are served from the `*.scryfall.io` file origin, which is **not rate-limited** (but stay polite).
4. Record the bulk file's `updated_at` and the run date into `docs/DATA.md` and into a `bundle_version` (Section 4.5).

### 4.3 Building the reference hash set

For each card object in **Unique Artwork**:

- Skip objects without an `illustration_id` (e.g., some tokens/funny cards may lack one) and skip cards with no usable image. For double-faced cards, hash **each face** that has its own image (`card_faces[].image_uris`) and store a row per face.
- Choose the image to hash: use the **`normal`** full-card image (`image_uris.normal`, or the face's `image_uris.normal`). Whole-card hashing is more robust across MTG's many frame types than art-only cropping, and the top-K + version-picker UI compensates for any same-art ambiguity.
- Download the image from `cards.scryfall.io` (parallelize with a modest concurrency cap, e.g., 8, and a small delay; this is the long step — tens of thousands of images, plan for several GB and a multi-hour run; cache downloads so re-runs are incremental).
- Compute the perceptual hash using `dataprep/phash.py` (Section 5.1). Store the 64-bit hash.

Respect Scryfall's image rules throughout: never crop/distort/recolor card images, and never strip artist/copyright. (We are hashing pixels, not redistributing images — but the same images are displayed at runtime, where these rules apply.)

### 4.4 Building the card metadata DB

From **Default Cards**, build the SQLite tables in Section 7. Key points:

- Store every English printing (one row per printing per face as needed) with: `scryfall_id`, `oracle_id`, `illustration_id`, `name`, `set_code`, `set_name`, `collector_number`, `rarity`, `finishes` (array → store as JSON/text), `lang`, `released_at`, the **image path components** needed to build CDN URLs at runtime (see 4.6), and optionally `prices` (USD/EUR + foil) flagged as estimate-only.
- Build an index from `illustration_id` → list of printings. This powers the version picker: once recognition resolves an `illustration_id`, the app can list every set/printing that shares that artwork.
- Trim aggressively. The app does not need oracle rules text, legalities, rulings, etc. for the MVP. Keep the bundle small.

### 4.5 Packaging and distribution of the bundle

- Output two artifacts into `dataprep/out/`:
  - `cards.sqlite` — metadata tables + the `hashes` table (Section 7). One file keeps things simple.
  - `manifest.json` — `{ "bundle_version": "<UTC date or incrementing int>", "scryfall_updated_at": "...", "card_count": N, "hash_count": M, "sqlite_sha256": "...", "sqlite_url": "...", "sqlite_gzip_bytes": N }`.
- gzip `cards.sqlite`. Expected size on the order of tens of MB compressed (no images inside).
- Publish `manifest.json` + `cards.sqlite.gz` to the fixed-tag GitHub Release set up in Section 0.2, via `gh release upload data-bundle dataprep/out/manifest.json dataprep/out/cards.sqlite.gz --clobber`. This gives two stable URLs (`.../releases/download/data-bundle/manifest.json` and `.../releases/download/data-bundle/cards.sqlite.gz`) that never change, so no other hosting is needed for Phase 1. Set the `sqlite_url` field in `manifest.json` to the second URL.
- **App first-launch flow:** fetch the fixed `manifest.json` URL → if no local DB or `bundle_version` differs → download `cards.sqlite.gz` from its fixed URL → verify `sha256` → unzip into app documents dir → open with `drift`. Show progress. Allow the app to run offline thereafter. Provide a "check for card data update" action in settings that re-runs the same two fetches.

Refresh cadence: re-run `build_bundle.py` weekly and after each new set release; bump `bundle_version`.

### 4.6 Runtime card images (display)

Do not ship images in the bundle. Build Scryfall CDN URLs at runtime from stored components. Scryfall image paths follow the pattern using the first two characters of the image id:

```
https://cards.scryfall.io/<size>/<face>/<id[0]>/<id[1]>/<id>.jpg
# size ∈ {small, normal, large, art_crop, ...}; face ∈ {front, back}
```

Use `small` for list thumbnails and `normal` for detail views. Fetch via `cached_network_image` so images are cached on disk after first view. If offline and an image isn't cached, show a placeholder with the card name/set.

---

## 5. The perceptual-hash contract (most important correctness requirement)

The hash computed during preprocessing (`dataprep/phash.py`, Python) and the hash computed on-device (`app/lib/recognition/phash.dart`, Dart) **must produce bit-identical results for the same input image.** If they differ, every Hamming distance is meaningless and recognition silently fails. Treat this as the central invariant.

### 5.1 Algorithm (DCT perceptual hash, 64-bit)

Implement exactly this on both sides:

1. Decode the image to RGB.
2. Convert to grayscale using luminance `Y = 0.299*R + 0.587*G + 0.114*B`, rounded to an integer 0–255.
3. Resize to **32×32** using **bilinear** interpolation. (Pin the interpolation method on both sides; document it. If exact bilinear parity between Pillow and Dart `image` proves hard, switch both to a simple, explicitly-implemented box/area resize so they match — parity matters more than which method.)
4. Compute the 2-D **DCT-II** of the 32×32 matrix.
5. Keep the top-left **8×8** block of DCT coefficients (low frequencies).
6. Exclude the very first coefficient `(0,0)` (the DC term) when computing the threshold.
7. Compute the **median** of the remaining 63 coefficients.
8. For each of the 64 coefficients (row-major order, including `(0,0)`), set bit = 1 if coefficient > median, else 0. Define and freeze the bit ordering (row-major, MSB first) identically on both sides.
9. Pack into a 64-bit unsigned integer.

Document the exact DCT formula (DCT-II, orthonormal or not — pick one and match it) in `phash.py` and mirror it in `phash.dart`. Do not rely on a library's pHash on one side and a hand-rolled one on the other unless you have proven they match.

### 5.2 Matching (on-device)

- Load all reference hashes into memory at startup (e.g., a `List<int>` / `Int64List` of M entries, M ≈ tens of thousands). With one 64-bit hash per row, this is a few hundred KB — trivial.
- For a query hash, compute **Hamming distance = popcount(query XOR ref)** against every reference (linear scan; M is small enough that this is well under ~10 ms on a mid-range phone — no ANN index needed for Phase 1).
- Return the **top 5** lowest-distance matches.
- Confidence heuristic: treat distance ≤ ~10 bits as a strong match; show the single best result pre-selected but still display alternates. If the best distance is large (> ~18 bits) or the top two are within 1–2 bits of each other, present the candidate list without a pre-selection and prompt the user to choose or rescan. Tune these thresholds during testing (Section 11).

### 5.3 Mandatory parity test

Before building the camera flow, add a test that:

1. Picks ~20 known cards' `normal` images.
2. Hashes them with `dataprep/phash.py`.
3. Hashes the identical files with `app/lib/recognition/phash.dart` (via a small Dart test harness).
4. Asserts the 64-bit values are **identical**.

This test must pass and must run in CI / be runnable on demand. If it can't pass with bilinear resize, change both implementations to the same simpler resize until it does.

---

## 6. On-device recognition flow

1. **Capture screen:** live camera preview with a card-shaped guide overlay (aspect ratio of a real card is 63 mm × 88 mm ≈ 0.716 w/h). Instruct: card on a contrasting, evenly-lit surface, fully inside the frame. Provide a capture button (and optionally auto-capture on stability later; manual is fine for MVP).
2. On capture, take the still image, **crop to the guide-frame rectangle** in image coordinates (the overlay defines a fixed crop region relative to the preview). No perspective correction in MVP.
3. Compute the query pHash (Section 5.1) on the cropped image.
4. Run the matcher (Section 5.2) → top-5 candidates with `illustration_id`s.
5. Resolve each candidate's display data from the metadata DB; show **candidate cards** (thumbnail + name + a representative set) in a confirmation sheet.
6. User taps the correct card (or "none → rescan").
7. If the chosen artwork has multiple printings (multiple rows sharing its `illustration_id`), offer the **version picker**: list printings (set name, set code, collector number, rarity, available finishes) sorted by release date desc; default to the most recent or most common; let the user pick set + finish.
8. Add the chosen printing to the collection with quantity 1 (increment if already present for that printing+finish).

Latency target for steps 3–5: well under 500 ms on a mid-range device.

---

## 7. SQLite schema (bundle + collection)

Bundle DB (`cards.sqlite`, read-only at runtime):

```sql
-- one row per printing (per face where a face has its own image)
CREATE TABLE printings (
  scryfall_id      TEXT PRIMARY KEY,
  oracle_id        TEXT,
  illustration_id  TEXT,                 -- nullable; links reprints of same art
  name             TEXT NOT NULL,
  set_code         TEXT NOT NULL,
  set_name         TEXT NOT NULL,
  collector_number TEXT NOT NULL,
  rarity           TEXT,
  finishes         TEXT,                 -- JSON array, e.g. ["nonfoil","foil"]
  lang             TEXT NOT NULL,        -- "en" for MVP
  released_at      TEXT,
  image_id         TEXT,                 -- id used to build CDN url (often = scryfall_id or face id)
  face             TEXT,                 -- "front" | "back"
  price_usd        REAL,                 -- estimate only, may be null/stale
  price_usd_foil   REAL
);
CREATE INDEX idx_printings_illustration ON printings(illustration_id);
CREATE INDEX idx_printings_name ON printings(name);

-- one row per reference artwork/face that we hashed
CREATE TABLE hashes (
  illustration_id  TEXT,                 -- key back to printings
  scryfall_id      TEXT,                 -- the representative printing we hashed
  face             TEXT,
  phash            INTEGER NOT NULL      -- 64-bit DCT pHash
);
CREATE INDEX idx_hashes_phash ON hashes(phash);
```

Collection DB (separate file, read-write; or separate tables in the app's own DB — keep it apart from the replaceable bundle):

```sql
CREATE TABLE collection_items (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  scryfall_id    TEXT NOT NULL,          -- the exact printing the user confirmed
  finish         TEXT NOT NULL,          -- "nonfoil" | "foil" | "etched" ...
  quantity       INTEGER NOT NULL DEFAULT 1,
  added_at       TEXT NOT NULL,
  UNIQUE(scryfall_id, finish)
);
```

Keep collection storage in a **separate file** from `cards.sqlite` so refreshing the bundle never risks the user's collection.

---

## 8. App screens

1. **First-launch / data setup** — downloads and verifies the bundle (Section 4.5) with a progress bar; explains it runs offline afterward.
2. **Scan** — camera preview + guide overlay + capture (Section 6).
3. **Candidate confirmation** — bottom sheet with top-5 thumbnails; pick or rescan.
4. **Version picker** — printings sharing the chosen artwork; pick set + finish.
5. **Collection** — searchable list (by name/set), quantity badges, per-finish entries, tap for detail, edit quantity, delete. Optional total "estimated value" with a clear "estimate, may be stale" label.
6. **Card detail** — large image (lazy from CDN), name, set, collector number, rarity, finish, estimated price (labelled).
7. **Settings** — check for card-data update; view legal notices; app version + bundle version.

Keep the UI clean and fast. Use `cached_network_image` everywhere images appear.

---

## 9. Legal and attribution requirements (must implement)

These are build requirements, not optional polish:

- **Wizards Fan Content Policy notice** must appear in the app (e.g., Settings → Legal and the about screen). Include wording to the effect that the app is unofficial Fan Content permitted under the Fan Content Policy, is not approved or endorsed by Wizards, that portions of the materials are property of Wizards of the Coast, and a "©Wizards of the Coast LLC" line. Do **not** use any Wizards logos or trademarks in branding or icons.
- **Scryfall:** do not paywall card data; if the app ever gains accounts, card data must remain accessible to free/anonymous users (not relevant in Phase 1 since there are no accounts, but bake the principle in). When displaying card images, do not crop, distort, recolor, or watermark them, and do not strip artist/copyright. Surface the artist name on the card detail screen (Scryfall provides `artist` in card data — add it to the `printings` table if you show it).
- **Prices** must be labelled as estimates and may be stale; never present them as live/market prices or as a basis for transactions.
- Set the HTTP `User-Agent` on all Scryfall API calls to a specific app identifier.

---

## 10. Build order (recommended sequence for Claude Code)

0. Developer machine setup (Section 0.1) and GitHub repo + data-bundle release setup (Section 0.2) — human steps, done once, before anything below.
1. `dataprep/phash.py` + unit test on a couple of fixed images.
2. `dataprep/build_bundle.py`: resolve bulk URLs → download Unique Artwork + Default Cards → build `printings` + `hashes` → emit `cards.sqlite` + `manifest.json` + gzip. Run it once for real to produce a bundle.
3. Flutter project scaffold + `pubspec.yaml` deps + Android camera permissions.
4. Bundle loader + first-launch download/verify/unzip + `drift` schema.
5. `phash.dart` + **parity test** against `phash.py` (Section 5.3). Gate further work on this passing.
6. In-memory matcher (load `hashes`, Hamming top-K).
7. Camera capture + guide overlay + crop.
8. Wire capture → hash → match → candidate sheet → version picker.
9. Collection storage + screens (add/list/search/edit/delete).
10. Card detail + lazy images + cache.
11. Legal notices + settings + data-update check.
12. Polish, tune thresholds, run acceptance tests.

---

## 11. Acceptance criteria

The MVP is "done" for Phase 1 when:

- **Pipeline:** `build_bundle.py` runs end-to-end and produces a `cards.sqlite` whose `printings` row count matches the number of English printings processed and whose `hashes` count matches the number of unique artworks/faces hashed; `manifest.json` validates; gzip + sha256 verified.
- **Parity:** the Python↔Dart hash-parity test (5.3) passes with identical 64-bit values on all sample images.
- **Recognition accuracy:** on a hand-built test set of **≥100 real cards** photographed by hand in decent lighting against a plain background (spanning several frame types, rarities, and at least a few reprinted-art cards), the correct card identity appears in the **top-5 candidates ≥90%** of the time, and is the **top-1 candidate ≥75%** of the time. Record the numbers in `docs/DATA.md`.
- **Latency:** hash + match completes in **< 500 ms** on a mid-range Android device for a typical capture.
- **Offline:** after the first-launch bundle download, scanning, matching, version-picking, and collection management all work with networking disabled (only card-image thumbnails may be missing if never cached).
- **Collection:** add/list/search/edit-quantity/delete all work and persist across app restarts; collection survives a bundle refresh.
- **Legal:** Wizards Fan Content notice and Scryfall-compliant image handling are present; prices are labelled as estimates; a specific `User-Agent` is sent to Scryfall.

---

## 12. Key decisions, risks, and how they're handled in Phase 1

- **Whole-card hashing vs art-crop:** MVP hashes the whole card for robustness across MTG's many frame types; same-art ambiguity is resolved by the top-K UI + version picker. Art-crop + OCR disambiguation is a Phase 2 accuracy upgrade.
- **No auto edge detection:** the guide-frame overlay replaces OpenCV contour detection and perspective correction for MVP. This trades some user effort for much lower complexity and more predictable cropping. Auto-detection is Phase 2.
- **Same-art reprints:** recognition resolves *which artwork*, not *which exact printing*. The version picker (driven by `illustration_id` → printings) is the deliberate, user-facing solution and is a required MVP feature, not a fallback.
- **Foils/finishes:** never inferred from the image. The user selects finish in the version picker. Quantities are tracked per finish.
- **Bundle size/first-launch download:** images are excluded from the bundle and loaded lazily; the bundle is a trimmed SQLite (tens of MB gzipped). If even that is too large, the pipeline can split into a hashes-only bundle plus on-demand metadata, but start with the single-file approach.
- **Data freshness:** card data is rebuilt weekly / post-set-release and re-downloaded via the manifest version check. Prices in the bundle are explicitly estimate-only and may be stale.
- **Bundle hosting via GitHub:** the fixed-tag release + `--clobber` approach (Section 0.2) means the app only ever hits direct asset-download URLs, never `api.github.com`, so the 60-requests/hour unauthenticated API limit never applies. The only hard constraint is GitHub's 2 GiB per-asset cap, comfortably above the expected tens-of-MB bundle size.
- **Hash parity fragility:** mitigated by the mandatory parity test and a willingness to use a simpler, identically-implemented resize on both sides rather than chase exact library-parity.
- **Compliance:** no paywalling of card data, Scryfall image rules respected, Wizards Fan Content notice shown, specific User-Agent sent. Phase 1 has no accounts/payments, which keeps the compliance surface small.

---

*Sources for the external-data and hosting details above: Scryfall API documentation (bulk-data endpoint, image formats, rate limits, paywall and image-use rules), MTGJSON documentation (file models, Scryfall image-path construction), and GitHub's documentation on REST API rate limits and Releases (asset size limits, `gh release upload --clobber` behavior). Verify current bulk file contents and the Fan Content Policy wording at build time, as both evolve.*
