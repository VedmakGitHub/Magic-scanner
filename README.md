# MTG Scanner — Phase 1 MVP

Offline Android Magic: The Gathering card scanner. Scan a card with the camera,
identify it on-device with a perceptual hash, confirm the printing, and save it
to a local collection. See [`Phase1_Android_MTG_Scanner_Build_Plan.md`](Phase1_Android_MTG_Scanner_Build_Plan.md)
for the full spec.

## Layout

```
dataprep/   Python pipeline that builds the card-data bundle (Section 4)
app/        Flutter app (Sections 6–9)
docs/       DATA.md — bundle version, counts, accuracy results
```

## Quick start

1. **Build the data bundle** (the app can't recognize anything without it):
   ```bash
   cd dataprep
   python -m venv .venv && source .venv/bin/activate   # Win: .venv\Scripts\activate
   pip install -r requirements.txt
   python build_bundle.py --repo <owner>/<repo>        # multi-GB, multi-hour first run
   gh release upload data-bundle out/manifest.json out/cards.sqlite.gz --clobber
   ```
   See [docs/DATA.md](docs/DATA.md) for `--no-hash` / `--limit` smoke builds.

2. **Run the app** (needs the Flutter SDK + a physical Android device — Section 0.1):
   ```bash
   cd app
   flutter create --platforms=android --org com.example .   # one-time platform scaffold
   # apply the manifest edits in app/README.md (CAMERA + INTERNET)
   flutter pub get
   flutter test test/phash_parity_test.dart                 # MUST pass (Section 5.3)
   flutter run
   ```
   Set the GitHub Release URL in [`app/lib/data/config.dart`](app/lib/data/config.dart).

## The hash-parity contract (Section 5)

`dataprep/phash.py` (Python) and `app/lib/recognition/phash.dart` (Dart) must
produce **bit-identical** 64-bit hashes for the same image, or recognition
silently fails. They share:

- a hand-rolled, deterministic grayscale + area-resize + DCT-II (IEEE-754
  double, fixed operation order), and
- a generated cosine table (`app/lib/recognition/phash_cos_table.dart`, emitted
  by `phash.py --emit-dart-table`) so cross-runtime `cos()` differences can't
  break parity.

The mandatory parity test (`app/test/phash_parity_test.dart`) hashes the shared
fixtures in `app/test/fixtures/` and asserts equality against the Python golden
values in `app/test/fixtures/golden.json` (regenerate both with
`dataprep/gen_fixtures.py`).

## What's verified vs. what needs the SDK

This environment has Python but **no Flutter/Dart/gh** installed, so:

- **Verified here:** `dataprep` phash unit tests (6/6), build_bundle offline
  logic tests (6/6), live Scryfall `bulk-data` resolution, fixture/golden
  generation, Dart cosine-table emission.
- **Needs the Flutter SDK (run after `flutter pub get`):** `flutter analyze`,
  the Dart parity test, the matcher test, and the on-device camera/recognition
  flow. The full bundle build (`build_bundle.py` with image hashing) is the
  documented multi-hour/multi-GB step run on a dev machine.

Acceptance-criteria results (recognition accuracy, latency) go in
[docs/DATA.md](docs/DATA.md) after the device test (Section 11).
