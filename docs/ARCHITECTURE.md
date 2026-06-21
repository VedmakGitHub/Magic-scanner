# Architecture & change-tracking

Single source of truth for the app's functional elements, the card-identification
pipeline, and the **known-good baseline** for every recognition tunable.

## Why this exists
Recognition quality is sensitive to a handful of tunables (resolution, inset
count, detection downscaling, thresholds). Changing them ad-hoc for one goal
(e.g. speed) silently regressed another (accuracy), causing back-and-forth.
**Rule:** do not change any tunable in the baseline table without first writing a
change proposal (format at the bottom) and getting sign-off.

---

## Functional elements

| Element | Scope | Primary code |
|---|---|---|
| **A. Scan UI** | Camera preview + detection outline + control pill; shows the result panel + chip bar (Quick ON) **or** the version row (Quick OFF) | `app/lib/camera/scan_screen.dart`, `app/lib/scan/widgets/control_pill.dart`, `scan_result_panel.dart` |
| **B. Version Picker** *(shared)* | Same printing data in two layouts: horizontal **row** (scan-time) and full **grid** (edit-time) | `app/lib/scan/widgets/version_row.dart`, `version_grid.dart`, `version_tile.dart` |
| **C. Scan Session UI** | Transient "N cards scanned" staging list; Clear / Add-to commits to the collection | `app/lib/scan/session_sheet.dart`, `app/lib/scan/scan_session.dart` |
| **D. Edit Panel** *(sub-surface of C)* | One staged card: version, quality (condition), quantity, language, foil | `app/lib/scan/edit_panel.dart` |
| **E. Settings UI** | Quick mode, Lock set, Prefer foil, Play sounds | `app/lib/scan/scan_settings_sheet.dart`, `app/lib/data/scan_settings.dart` |
| **F. Collection UI** | The **persisted** collection (distinct from the transient session) | `app/lib/collection/collection_screen.dart`, `card_detail_screen.dart`, `app/lib/data/collection_database.dart` |
| **G. Data / Bundle layer** *(non-UI)* | Printings DB, reference hashes + matcher, bundle loader, image/set-symbol fetch | `app/lib/data/card_database.dart`, `app/lib/recognition/matcher.dart`, `app/lib/data/bundle_loader.dart`, `app/lib/data/image_urls.dart`, `app/lib/ui/widgets.dart` |

---

## Card-identification pipeline

| # | Step | Job | Code |
|---|---|---|---|
| 1 | **Frame gating** | Throttle; require a *stable* card (outline steady) past cooldown before expensive work. Cheap detect runs every frame for the overlay + this gate. | `scan_screen.dart` `_onFrame` |
| 2 | **Border detection** | Find the card quad. Two-tier: downscaled for the overlay, full-res for the capture. | `card_detector.dart` `detectFromNv21`, `_findQuad` |
| 3 | **Capture / normalize** | Perspective-warp the bordered region to canonical 488×680. | `card_detector.dart` `_warpFrom` |
| 4 | **Hash** | Multi-scale 256-bit pHash at the inset set. | `phash.dart` `multiScale` |
| 5 | **Nearest-neighbour match** | Hamming top-K over the reference hashes (min distance across insets). | `matcher.dart` `topKMulti` |
| 6 | **Confidence** | best distance + margin to #2 → confident / near-tie / weak. | `scan_screen.dart` `_handleMatch` |
| 7 | **OCR disambiguation** | Near-tie only: encode the warp JPEG **on-demand** (lazy — not every pass), read the printed name, pick the matching candidate. | `ocr.dart` `CardOcr`, `frame_processor.dart` `process(jpegOnly:)` |
| 8 | **Confirmation (consensus)** | Adaptive: a clearly confident match (margin to #2 ≥ 12) commits on the **first** stable frame; marginal/near-tie matches need **2** agreeing frames. | `scan_screen.dart` `_pendingMatchKey/_pendingMatchCount` |
| 9 | **Dedup / lifecycle** | Don't re-add the same physical card until it leaves the frame; re-arm after N no-detect frames. (Distinct from consensus.) | `scan_screen.dart` `_lastAddedKey`, `_noDetectStreak` |
| 10 | **Resolve + apply settings** | Matched illustration → **its own printing** (the scanned set/art) as the default; Lock-set overrides the set, Prefer-foil the finish → final card + finish. | `scan_screen.dart` `_resolveQuickPrinting`, `_quickFinish` |
| 11 | **Outcome routing** | Quick ON → auto-add + feedback + result panel; Quick OFF → version row (**same-artwork versions first, newest→oldest, then other artworks; matched highlighted**); no confident match → keep scanning. | `scan_screen.dart` `_handleMatch`, `_matchedFirst` |

---

## Baseline tunables (known-good — change only via a proposal)

| Tunable | Value | Where |
|---|---|---|
| Camera resolution | `ResolutionPreset.high` | `scan_screen.dart` `_init` |
| Overlay detect downscale | 480 px long edge (overlay only) | `card_detector.dart` `_fastDetectEdge` |
| Capture/hash detect | **full resolution** (precise corners) | `card_detector.dart` `_detectAndWarp` |
| Warp size | 488 × 680 | `card_detector.dart` `kWarpW/kWarpH` |
| Hash | 256-bit pHash | `phash.dart` |
| Inset set | `{0, .02, .03, .04, .05, .06}` (6), min-distance | `phash.dart` `kInsets`, `matcher.dart` `topKMulti` |
| Max match distance (weak above) | 70 | `scan_screen.dart` `_maxMatchDist` |
| Near-tie margin (→ OCR) | 4 | `scan_screen.dart` `_tieMargin` |
| Consensus frames | adaptive: **1 if margin ≥ 12** (`_confidentSkipMargin`), else **2** (`_consensus`) | `scan_screen.dart` |
| Re-arm no-detect frames | 3 | `scan_screen.dart` `_reArmNoDetect` |
| Throttle / stable / cooldown | 90 ms / 3 frames / 1200 ms | `scan_screen.dart` `_throttleMs`/`_stableNeeded`/`_cooldownMs` |
| OCR | ML Kit Latin, near-tie only, name substring/token match | `ocr.dart`, `scan_screen.dart` |
| Debug logging | `kScanDebug = true` (turn off for release) | `scan_screen.dart` |

History: dropping resolution to medium, cutting insets to 3–4, and downscaling
the capture detection each regressed hard retro frames (e.g. Flare of Denial);
all reverted. The validated config that scored 15/15 on the labeled benchmark is
high res + full-res capture detection + the 6-inset set above.

---

## Deferred (not in scope; documented so they aren't half-built)
- **Buylist / purchase price** — result panel shows a placeholder; no real price source yet.
- **Ignore promos** / **Display total value** — settings plumbing exists (`ScanSettings`) but the UI controls are hidden until implemented.
- **Price currency/region** localization (the country-flag price).
- **Ownership counts** (decks/wishlist) — collection count only.
- **Set-symbol disk cache** — currently session-memory cached.
- **Nav tabs** Home / Search / Decks (ManaBox has them; out of scope).
- **OCR title-crop + upscale** — currently OCRs the whole warp.
- **Resource profiling (future phase)** — measure CPU / memory / battery impact during continuous scanning to understand device-lifetime/performance cost. Not this phase.
- **Exclude online-only sets** — we scan physical cards, so MTGO/Arena (and other digital-only) printings can never be present. Filter them out in `dataprep/build_bundle.py` (and/or queries) so they don't appear as candidates/versions. Backlog.
- **Common set symbol legibility** — a Common (black) symbol is indistinguishable from a black spot on the dark theme (and the fallback dot is a black circle). Investigate a fix (outline/ring, lighter rendering, or shape cue). Backlog.
- **Hash compute cost (~500 ms)** — the 6-inset pHash is the dominant per-attempt cost; profile/AOT does NOT improve it (allocation/memory-bound in the `image` package), and it's parity-locked to the Python reference pipeline. A real fix needs an allocation-light/native resize that stays bit-identical, or a re-hash of the bundle. Backlog. (Measured: AOT cut `match` 260→55 ms but left `hash` ~500 ms.)

---

## Change-proposal format
Before changing anything in the baseline table or a pipeline step, state:

> **Element/step** · **current → proposed** · **expected effect** · **how we'll verify** · **risk**

Example:
> Step 4 (Hash) · insets 6 → 4 · ~30 % faster hashing · re-run the 15-card benchmark, expect ≥14/15 top-1 · may regress retro frames (Flare).

## Decision log
Approved changes (via the rule above), newest first.

### 2026-06-21 — P4 adaptive consensus
- **Change:** consensus 3 → adaptive (1 frame if margin ≥ 12, else 2).
- **Why / impact:** confident cards committed in 3 attempts (~2.4 s); large margins are reliable, so 1 frame is safe. Validated on-device: 6/8 cards added on the first frame, all correct; ~3× faster time-to-add.
- **Code:** `scan_screen.dart` `_confidentSkipMargin` / `_consensus`.

### 2026-06-21 — Lazy JPEG for OCR (Option A)
- **Change:** the warp JPEG is no longer encoded on every full pass; it's encoded on-demand (`process(jpegOnly:)`) only when a near-tie triggers the OCR tiebreak.
- **Why:** profiling showed JPEG encode ≈ 100–340 ms/attempt (avg ~180), used only on rare near-ties (`margin ≤ 4`) — pure waste on the common path; AOT didn't reduce it.
- **Impact:** confident 1-frame add ~0.8–1 s → ~0.6–0.8 s; a tie pays one extra ~250 ms detect+warp+encode pass (rare, already slow).
- **Alternatives rejected:** B (match-in-isolate + conditional JPEG) — `match` is only ~55 ms in AOT, not worth moving the 50k-hash matcher into the isolate; C (cheaper title-strip encode) — shrinks but doesn't eliminate the waste.
- **Code:** `frame_processor.dart` `process(jpegOnly:)` + `_entry`; `scan_screen.dart` `_handleMatch`.
