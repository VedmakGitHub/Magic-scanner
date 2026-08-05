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
| 7 | **OCR disambiguation** | Near-tie only: encode a **title-strip** JPEG on-demand, OCR the name; match it to a top-K candidate, **else look it up in the full bundle by name** (catches cards pHash didn't shortlist). If unconfirmed, **don't commit**. | `ocr.dart` `CardOcr`, `card_database.dart` `getByExactName`, `frame_processor.dart` `process(jpegOnly:)` |
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

## Deferred / backlog (documented so they aren't half-built)
Tags: effort S/M/L, value L/M/H. (DONE 2026-08-03: OCR title-crop + upscale — the `b5d1f06` fix crops+upscales the title strip.)

**Recognition / accuracy**
- **★ Local-feature matching (ORB + RANSAC) — best measured descriptor, 2026-08-04** [L, High] — on the same 8000-ref pool and all 209 real warps: **98.6% top-1 / 99.0% top-5**, vs DINOv2 art+auto 80% and pHash 59%. Fixes **every** card, including Strategic Betrayal (58/61 = 95%) which neither other descriptor could (16% / 6%). Local gradient descriptors ignore global statistics, so the photometric domain gap doesn't apply; RANSAC homography verification is qualitatively stronger evidence than a distance threshold. Recipe: art crop → gray → 480 px → `equalizeHist` → ORB(400) → BFMatcher Hamming knn k=2 + Lowe 0.75 → top-25 shortlist → `findHomography(RANSAC,5.0)` → rank by inliers. **Supersedes the embedding as the recommended direction** (no model, no TFLite; OpenCV already ships via `dartcv4`). **Deployment is the open problem, not accuracy:** brute force is 7.3 s/query at 8k refs ⇒ **~46 s at 49,877** (needs a BoW/VLAD inverted index), and raw descriptors are 12.8 KB/card ⇒ **~640 MB** vs the 88 MB bundle (needs a compact index; which in turn complicates RANSAC, as verification needs real keypoints). Harness: `dataprep/bench/eval_local.py`.
  - **Operating point decided (accuracy/cost curve, `eval_local_cost.py`): ORB @ 100 keypoints, count-only ranking.** 400 kp 95.7% / 638 MB / 43.8 s · 200 kp 95.7% / 319 MB / 17.4 s · **100 kp 94.3% / 160 MB / 8.4 s** · 50 kp 82.9% / 80 MB / 4.1 s (collapses; Strategic 17→11). Knee is unambiguous at 100. **RANSAC adds nothing to ranking at ≥100 kp**, so a BoW/VLAD inverted index costs no accuracy — this is what makes it deployable (at 50 kp RANSAC *does* help, 82.9→88.6). Storage fits the envelope (ManaBox on-device is 547 MB total; our bundle is already ~225 MB on disk), and a BoW index storing word IDs would be only ~10–20 MB. **Open: latency** — 8.4 s brute force at 50k still needs the index. **Untested:** BoW quantization loss (94.3% is exact matching); and RANSAC may still matter for *rejection* (card-not-in-DB), which this benchmark doesn't measure.
  - **CORRECTED on the full 209-warp sample (same-sample numbers, supersedes the 70-warp figures above):** 400 kp **98.6%** · 100 kp **95.7%** (+RANSAC) / **94.7%** (count-only), Strategic 58/61 vs 56/61. So (a) cutting 400→100 kp costs **2.9 pp**, not 1.4 — the small sample understated it; and (b) **RANSAC does add ~1 pp at 100 kp** — the earlier "adds nothing at ≥100 kp" was an artifact of the smaller sample. **Reframe:** the storage constraint only applies to RAW descriptors. Under a BoW index, storage scales with stored word IDs (~400 IDs × 2–4 B ≈ 1.6 KB/card ≈ **80 MB at 400 kp**) — *less* than 100 kp raw (160 MB). So we need not trade accuracy for storage: keep 400 kp **if** BoW quantization holds up. ⇒ **BoW quantization loss is now the single decisive unknown** (determines ~98% vs ~95%); everything else is measured.
- **Deep fix: better descriptor for pHash "noise-floor" cards** [L, High] — *the structural cause of slow hard-card ID.* A class of low-contrast / busy-art cards sits ~60–70 bits from its OWN reference warp (at the pHash noise floor), so the true card is a near-tie or **not even in the top-5** — identification then falls entirely to the OCR name-lookup path, which is the slow part (see the OCR-path speedups below). This is a **descriptor discrimination** limit, not a crop/warp/perf issue (multi-scale insets already fixed the sleeve-crop artifact). Evidence (on-device, 2026-08-03):
  - **Strategic Betrayal** (ordinary black card) — true card ABSENT from top-5; `top5: 66:Fruit of Tizerus  66:Dark Bargain  66:Promise of Loyalty  68:Broken Wings  68:Dreadfeast Demon`. Resolved only by full-bundle OCR `getByExactName`.
  - **Flare of Denial** (retro blue) — bimodal: sometimes `28:Flare…` rank-1, sometimes absent (`top5: Telepathy, Glowing Anemone, Fighting Drake, Paradigm Shift, Merfolk…`).
  - **Force of Negation** (foil retro) — rank 1–3 (`48:Force…` or `68:Force…` behind `66:Brass Man`); foil glare also corrupts the OCR fallback.
  - **Subtlety** (retro) — rank-1 but only `62` with margin ≤ 8 (persistent near-tie). Earlier benchmark also flagged **Fallaji Archaeologist** (generic art).
  - Fix = a learned **instance-level embedding** that shortlists these cards so OCR isn't needed. Try pretrained **DINOv2 / CLIP / MobileCLIP** first (ImageNet MobileNetV3 already tested offline — NOT enough, top-1 3/9); else **fine-tune / metric-learn** (contrastive warped-photo ↔ reference). Deployment: ~256-float embedding/card (~50 MB), TFLite model on-device, NN over embeddings — requires a bundle **re-embed + re-publish** and swapping the matcher. Full history + offline results in [[recognition-descriptor-investigation]] / [[labeled-benchmark]]. This REMOVES the OCR dependency (and its latency) for the hardest cards; big separate effort.
  - **EXPLORATION UPDATE 2026-08-04 — it's a DOMAIN GAP, not clean-art discrimination.** Analysis of the bundle's own clean-ref pHashes shows the on-device confusers are FAR in clean-hash space (clean Force of Negation ↔ clean Brass Man = **136 bits**, vs unrelated-card median 92). pHash separates the clean arts fine; the confusion is entirely that the **photo adds ~65 bits of noise** (foil/glare/lens/warp), sinking the true match into the noise floor. So the descriptor must be **domain-gap robust** (photo ≈ scan), exactly what DINOv2/SSCD target. Consequence: clean-ref/synthetic experiments can't measure it — **the gate needs real phone warps.** Architecture = **hybrid** (pHash for the easy majority; embedding replaces the OCR tiebreak in the high-best-distance zone). Env ready: `dataprep/.venv` (py3.14 CPU) runs `timm`/`open_clip`; DINOv2-S ~66 ms/img CPU. Captured a **180-warp real benchmark** (`e1f7c31` tool; data in `dataprep/bench/warps`, gitignored) — pHash real-photo baseline 59% top-1 (Force 21%, Strategic 6%, Flare 48%; easy controls 100%).
  - **BAKE-OFF RESULT 2026-08-04 — GATE A PASSED.** `dataprep/bench/bakeoff.py` (DINOv2 ViT-S/14, cosine NN, 8k pool): pHash 59% → whole-card DINO 65% → **art-crop DINO 77%** top-1 (84% top-5). **Force of Negation 21%→100%, Flare 48%→97%** — the motivating cards SOLVED. Data confirms the **hybrid**: pHash is 100% on easy controls (DINO regresses them, e.g. Undercity 100→59), DINO wins the hard cards → keep pHash for the low-distance majority, embedding as the high-distance fallback only. **Best recipe = art-crop + autocontrast: 80% top-1 / 89% top-5** (autocontrast applied identically to refs and queries; CLAHE *hurts*). Per card vs pHash: force 100/21, flare 97/48, subtlety 100/100, dauthi 93/100, undercity 73/100, strategic betrayal 16/6. **Strategic Betrayal — resolved by measurement (2026-08-04).** Two hypotheses tested and **refuted**: "wrong cached printing" (`cos(ref#94, ref#422promo)=0.983`) and "underexposed + glare" (run1 photometrics: **0.00% crushed blacks, 0.00% blown highlights**). The card's art is simply dark/low-contrast. **Contrast — not brightness — is the lever:** a torch re-capture was *darker* (mean lum 67.7 vs 73.6) but higher-contrast (std 43.9 vs 30.9) and doubled top-1 (16%→38%); pHash stayed 0/29 on both. **Multi-frame similarity aggregation works only above a capture-quality threshold:** torch k=1 38% → k=8 **68%** (median true-rank 3→1), but dim k=1 16% → k=8 **0%** (low-contrast frames drift systematically to the same wrong neighbour, so averaging reinforces the error). ⇒ **aggregation + frame-quality gating must ship together.** Best-of-N rank is 1 in both sets, so the card is recoverable — a stronger encoder (SSCD/fine-tune) is not yet justified.
  - **Two mitigations tested and REJECTED (2026-08-04)** — recorded so they aren't re-attempted. **(a) Best-frame selection** (`eval_frameselect.py`, 209 warps, simulated on the pHash result logged per frame): no selector beats first-stable (49.7%) — luminance 49.2, pHash distance 48.6, margin 50.8, contrast 45.9 (*hurts*: Flare 44.8→20.7), sharpness ~neutral; the oracle is 65.7 (k=5)/72.5 (k=8) so headroom exists but is unreachable — for noise-floor cards which distractor wins is uncorrelated with frame quality. Note the descriptors want **opposite** inputs: contrast helps the embedding but hurts pHash (pHash correlates with *luminance*, hard-card quartiles 3.1%→40.6%). **(b) White balance** (`eval_wb.py`): the +10 pp normalization win is **entirely contrast** — `preserve_tone` (no WB) 78.6%, per-channel (current) 78.6%, explicit gray-world WB 78.6%, vs 68.6% unnormalized. Keep contrast normalization; skip WB. Then deploy (TFLite + re-embed 56k `embeddings` table + Dart cosine matcher + hybrid routing). Details in [[recognition-descriptor-investigation]] / [[labeled-benchmark]].
- **OCR-path speedups for hard cards** — *P-A/P-B/P-D DONE 2026-08-03 (`ce28db0`), validated on-device (Pixel 9a, profile), 13/13 adds correct.* The noise-floor cards above always hit the OCR tiebreak, which was slow: ML Kit ~800–1000 ms warm (~2000 ms first call), a redundant second detect+warp for the title JPEG, and 2× for consensus. Shipped: **P-D** pre-warm ML Kit at startup (first OCR 2004 → **734 ms**; bit-neutral); **P-B** reuse the `full`-pass warp via a `jpegFromLast` isolate op instead of re-detecting (warm OCR ~900 → **~786 ms**; bit-neutral); **P-A** commit on the **first** OCR-positively-confirmed near-tie frame instead of requiring 2 (halves OCR passes; tie-safety still blocks unconfirmed reads → no mis-adds). **Result: Force of Negation / Strategic Betrayal ~3–3.6 s → ~1 s.** *P-D polish DONE (`a8a9be6`)* — warm-up now fires in `initState` and `readText` awaits it, so the model load is hidden at normal pace (first OCR 978 ms, no tail) or concentrated on card #1 if you scan within ~2 s of a cold launch; the mid-session 1.5–1.8 s spikes on calls #2–#3 are gone (validated, 18/18 correct). *Still open:* **P-C** fuzzy name match to rescue glare misreads (`"fore of Negatlon"`, `"Bubtlety"`) [S–M, Med, accuracy-sensitive → proposal].

**Recognition / perf**
- **Hash compute cost** [L, High] — *DONE 2026-08-03 (`8aa026a` instrument, `79a8344` fix), bit-identical, measured on-device (Pixel 9a, profile).* Root cause was NOT the resize but the grayscale: `multiScale` grayscaled the card 6× via per-pixel `image.getPixel` plus 5× `copyCrop`. Fix = grayscale the full warp **once** (single contiguous `getBytes(rgb)` pass) and window each inset over that shared buffer (no crop). Bit-identical (parity + windowed==crop tests green), so NOT a tunable change. **Result: `hash` 603 → 119 ms (5.1×); h.gray 302 → 30, h.crop 210 → 0, h.resize 90 unchanged; full isolate pass 716 → 234 ms; confident add ~780 → ~300 ms.** Accuracy unchanged (all cards still correct). *New floor:* `h.resize` (87 ms, 6× box resize) then `convert` (76 ms, NV21→BGR+rotate) — both further wins are **bit-changing** (reuse overlapping inset resamples; or hash the NV21 luma plane directly) and would need a proposal + bundle re-hash.
- **Exclude online-only sets** [S–M, Med] — MTGO/Arena/digital printings can never be a physical scan yet pollute candidates/versions. Filter `digital`/non-paper in `dataprep/build_bundle.py` (needs a bundle rebuild) or at query/match time (faster to ship; their hashes still occupy the matcher).

**Data / pricing**
- **Buylist / purchase price** [S→L, Med] — result panel shows a placeholder. We already have Scryfall RETAIL prices in the bundle (`price_usd`/`price_usd_foil`) — cheap to show as "est." Real buylist needs an external API + keys + legal review. Edit-panel purchase-price is a user-entered field (small).
- **Price currency/region** [M, Low] — localized price + country flag; needs FX rates + locale (USD only now).

**UI polish**
- **Common set-symbol legibility** [S, Low–Med] — Common = black symbol (and the fallback dot is a black circle) near-invisible on the dark theme; add an outline/ring/lighter rendering. Isolated to the `SetSymbol` widget.
- **Set-symbol disk cache** [S, Low–Med] — session-memory only; add a bytes disk cache for offline + fewer refetches.
- **Ignore promos / Display total value** [S each, Low–Med] — `ScanSettings` plumbing exists, UI toggles hidden. Ignore-promos filters promos in the version pick; Display-total shows the session/collection total.
- **Ownership counts (decks/wishlist)** [L, Low] — edit-panel `📇/🃏/◈` shows collection count only; decks/wishlist aren't features yet.
- **Nav tabs Home / Search / Decks** [L, product-scope] — we have Scan/Collection/Settings; Home/Search are modest, Decks is a whole feature.

**Ops**
- **Resource profiling** [M, Med] — measure CPU/memory/battery during continuous scanning (OCR + 6-inset hash are heavy) via the Android profiler / `adb dumpsys` or in-app counters.

Suggested next: cheap wins = OCR-path speedups (P-D pre-warm, P-B reuse warp), exclude online-only sets, common-symbol legibility, set-symbol disk cache, show est. price. Big lever = **descriptor deep-fix** (embeddings — removes the OCR dependency for noise-floor cards). Product-scope calls = decks/nav, buylist, ownership counts. (Hash compute cost — DONE.)

---

## Change-proposal format
Before changing anything in the baseline table or a pipeline step, state:

> **Element/step** · **current → proposed** · **expected effect** · **how we'll verify** · **risk**

Example:
> Step 4 (Hash) · insets 6 → 4 · ~30 % faster hashing · re-run the 15-card benchmark, expect ≥14/15 top-1 · may regress retro frames (Flare).

## Decision log
Approved changes (via the rule above), newest first.

### 2026-08-03 — OCR-tiebreak speedups for hard cards (P-A + P-B + P-D)
- **Change:** (P-D) pre-warm the ML Kit model at startup (`CardOcr.warmUp`); (P-B) the frame isolate caches the `full`-pass warp and a new `jpegFromLast` op encodes the OCR title strip from it, replacing a redundant same-frame detect+warp; (P-A) an OCR-positively-confirmed near-tie commits on the **first** frame (`needed=1`) instead of `_consensus`=2.
- **Why:** pHash noise-floor cards (Strategic Betrayal, Force of Negation, Flare of Denial, Subtlety) always hit the OCR tiebreak, which cost ~2000 ms first call / ~900 ms warm × 2 frames + a redundant warp — ~3–3.6 s per hard card.
- **Safety:** P-B and P-D are **bit-neutral** (hash path + parity unchanged). P-A is behavioral but safe because tie-safety already rejects unconfirmed OCR reads; validated on-device with **13/13 correct adds, zero mis-adds**.
- **Result (Pixel 9a, profile):** first OCR 2004 → 734 ms; warm OCR ~900 → ~786 ms; near-tie adds 2 OCR passes → 1; **hard card ~3–3.6 s → ~1 s**.
- **Code:** `ocr.dart` `warmUp`; `frame_processor.dart` `jpegFromLast`/`_encodeTitleStrip`/cached `lastWarp`; `scan_screen.dart` `_init` warm-up, `jpegFromLast` call, `ocrConfirmed` in the `needed` calc.

### 2026-08-03 — Hash grayscale-once + windowed resize (bit-identical, measure-first)
- **Change:** `PerceptualHash.multiScale` no longer grayscales the card 6× (per inset) with per-pixel `getPixel` + 5× `copyCrop`. It grayscales the full warp **once** into a flat buffer via a single contiguous `getBytes(order: rgb)` pass, then hashes each inset as a sub-window of that buffer (offset indexing in the box resize).
- **Why:** sub-step reasoning (confirmed by the Commit-1 instrumentation) pinned the ~500 ms `hash` step on grayscale + crop allocations in the `image` package, not the DCT/resize/matcher.
- **Not a tunable change:** output is **bit-identical** — insets, resolution, warp size all unchanged. Guarded by `phash_parity_test` (18 fixtures vs Python golden) + new `phash_multiscale_test` (windowed inset == crop-then-hash for all 6 insets; BGR==RGB; RGBA==RGB).
- **Process:** done as Option A / two commits — `8aa026a` adds sub-step timings (measure), `79a8344` applies the fix. **Measured on-device (Pixel 9a, profile): `hash` 603 → 119 ms (5.1×); h.gray 302 → 30, h.crop 210 → 0, h.resize 90 unchanged; full isolate pass 716 → 234 ms.** Prediction (~130–160 ms) held. Accuracy unchanged.
- **Code:** `phash.dart` `multiScale`/`fromImage`/`_toGrayFlat`/`_resizeBoxWindow`/`_hashFromGrayWindow`; timings surfaced in `frame_processor.dart`.

### 2026-06-21 — OCR full-bundle name lookup + tie safety
- **Change:** on a near-tie, OCR a title-strip crop and resolve the card by (1) matching the read name to a top-K candidate, else (2) an indexed full-bundle name lookup (`getByExactName`, via an in-memory normalized-name index). If neither confirms a card, **do not commit** (keep scanning) — stops wrong-card false adds.
- **Why:** logs showed busy-blue retro frames (Flare of Denial) where the true card is frequently *outside* the pHash top-5, so the old OCR-among-top-5 couldn't pick it and a flipping wrong rank-1 either never committed or committed the wrong card (Paradigm Shift / Avenger en-Dal).
- **Cost:** OCR + lazy JPEG already paid on ties; the new bit is an ~5–20 ms in-memory name scan + one indexed `name = ?` query (a one-time ~tens-of-ms name-index build on first tie). Confident cards still run zero OCR.
- **Code:** `card_database.dart` `distinctNames`/`getByExactName`; `ocr.dart` `matchBundleName`; `frame_processor.dart` jpegOnly title-strip; `scan_screen.dart` `_handleMatch`/`_ensureNameIndex`.

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
