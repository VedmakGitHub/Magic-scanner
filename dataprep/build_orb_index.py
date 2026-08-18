"""Production ORB index builder — the reference side of the deep-fix matcher.

Consumes dataprep/bench/orb_refs_all.npz (50,747 cards x 100 ORB keypoints) and
emits the tables the app will ship, appended to cards.sqlite so the existing
printings/hashes/meta are untouched and rollout can be staged:

  orb_meta    one row: vocab params + counts, so the app can sanity-check
  orb_vocab   65,536 x 32 packed BINARY centroids (2.1 MB, one BLOB)
  orb_bow     per card: soft-3 word ids as uint16, stored in RANK ORDER
              (first n = rank 1, next n = rank 2, next n = rank 3) so the
              1, 1/2, 1/3 weights are implied by POSITION and need not be
              stored -- this is the amended design that halves the in-RAM
              index after the device probe showed +137 MB, peak RSS 694 MB.
  orb_idf     65,536 float32 idf weights (derived, cached to avoid startup work)
  orb_desc    per card: raw descriptors + keypoints, read only for the ~10
              shortlisted candidates during stage-2 re-rank + RANSAC

Vocabulary is trained on a sample drawn from the FULL reference set (the earlier
65k vocab came from an 8,000-card pool, so most production descriptors would
have fallen far from any centroid).

Run: dataprep/.venv/Scripts/python.exe dataprep/build_orb_index.py [--sample N]
"""
import argparse, os, sqlite3, time
import numpy as np
import cv2

REFS = "dataprep/bench/orb_refs_all.npz"
DB = "dataprep/out/cards.sqlite"
SOFT, KM_ITERS = 3, 12

ap = argparse.ArgumentParser()
ap.add_argument("--sample", type=int, default=300_000, help="descriptors for k-means")
ap.add_argument("--limit", type=int, default=0, help="only N cards (smoke test)")
ap.add_argument("--k", type=int, default=65536, help="vocabulary size")
args = ap.parse_args()
K = args.k
if args.sample < K:
    raise SystemExit(f"--sample ({args.sample}) must be >= --k ({K}): k-means needs at least K seeds")

z = np.load(REFS, allow_pickle=True)
D, P, OFF, ILLU = z["desc"], z["kpts"], z["offset"], z["illu"]
NC = len(OFF) - 1
if args.limit: NC = min(NC, args.limit)
print(f"reference set: {NC:,} cards, {len(D):,} descriptors", flush=True)

# ---- 1. vocabulary: k-means on unpacked bits, then binarise -----------------
def unpack(d): return np.unpackbits(d, axis=1).astype(np.float32)
rng = np.random.default_rng(0)
idx = rng.choice(len(D), min(args.sample, len(D)), replace=False)
X = unpack(D[idx])
print(f"training vocabulary K={K:,} on {len(X):,} descriptors ...", flush=True)
t0 = time.time()
C = X[rng.choice(len(X), K, replace=False)].copy()
for it in range(KM_ITERS):
    asg = np.empty(len(X), np.int32)
    for s in range(0, len(X), 4096):
        e = min(s + 4096, len(X))
        d2 = (X[s:e]**2).sum(1)[:, None] - 2 * X[s:e] @ C.T + (C**2).sum(1)[None]
        asg[s:e] = d2.argmin(1)
    newC = np.zeros_like(C); cnt = np.zeros(K, np.float32)
    np.add.at(newC, asg, X); np.add.at(cnt, asg, 1.0)
    nz = cnt > 0
    C[nz] = newC[nz] / cnt[nz, None]
    if it % 3 == 0:
        print(f"    iter {it}  empty={int((~nz).sum()):,}  ({time.time()-t0:.0f}s)", flush=True)
Cb = np.packbits((C > 0.5).astype(np.uint8), axis=1)          # [K,32] uint8
print(f"vocabulary built in {time.time()-t0:.0f}s -> {Cb.nbytes/1e6:.1f} MB binary\n", flush=True)

# ---- 2. quantise every card (binary Hamming, soft-3, rank order) ------------
bf = cv2.BFMatcher(cv2.NORM_HAMMING)
bow = []                      # per card: uint16 word ids, rank-major
t0 = time.time()
for j in range(NC):
    a, b = OFF[j], OFF[j + 1]
    d = D[a:b]
    if len(d) == 0:
        bow.append(np.zeros(0, np.uint16)); continue
    mm = bf.knnMatch(d, Cb, k=SOFT)
    w = np.zeros((SOFT, len(d)), np.uint16)                    # rank-major
    for i, ms in enumerate(mm):
        for r, m in enumerate(ms[:SOFT]): w[r, i] = m.trainIdx
    bow.append(w.reshape(-1))
    if j and j % 5000 == 0:
        el = time.time() - t0
        print(f"    quantised {j:,}/{NC:,}  {el:.0f}s  eta {el/j*(NC-j):.0f}s", flush=True)
print(f"quantised {NC:,} cards in {time.time()-t0:.0f}s\n", flush=True)

# ---- 3. idf from document frequency ----------------------------------------
df = np.zeros(K, np.float64)
for w in bow:
    if len(w): np.add.at(df, np.unique(w), 1.0)
idf = (np.log((NC + 1) / (df + 1)) + 1.0).astype(np.float32)
postings = int(sum(len(np.unique(w)) for w in bow))
print(f"index: {postings:,} postings, {postings/max(NC,1):.0f} distinct words/card", flush=True)
print(f"  in-RAM at load: ~{postings*4/1e6:.0f} MB card ids (weights derived)\n", flush=True)

# ---- 4. write tables --------------------------------------------------------
con = sqlite3.connect(DB)
con.executescript("""
DROP TABLE IF EXISTS orb_meta;  DROP TABLE IF EXISTS orb_vocab;
DROP TABLE IF EXISTS orb_bow;   DROP TABLE IF EXISTS orb_idf;
DROP TABLE IF EXISTS orb_desc;
CREATE TABLE orb_meta  (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE orb_vocab (id INTEGER PRIMARY KEY, k INT, dim INT, centroids BLOB);
CREATE TABLE orb_bow   (illustration_id TEXT PRIMARY KEY, n INT, words BLOB);
CREATE TABLE orb_idf   (idf BLOB);
CREATE TABLE orb_desc  (illustration_id TEXT PRIMARY KEY, n INT, desc BLOB, kpts BLOB);
""")
con.execute("INSERT INTO orb_vocab VALUES (1,?,?,?)", (K, 32, Cb.tobytes()))
con.execute("INSERT INTO orb_idf VALUES (?)", (idf.tobytes(),))
con.executemany("INSERT INTO orb_bow VALUES (?,?,?)",
                [(str(ILLU[j]), int(len(bow[j]) // SOFT), bow[j].tobytes()) for j in range(NC)])
con.executemany("INSERT INTO orb_desc VALUES (?,?,?,?)",
                [(str(ILLU[j]), int(OFF[j+1]-OFF[j]),
                  D[OFF[j]:OFF[j+1]].tobytes(),
                  P[OFF[j]:OFF[j+1]].astype(np.float32).tobytes()) for j in range(NC)])
for k_, v_ in [("k", K), ("soft", SOFT), ("dim", 32), ("cards", NC),
               ("postings", postings), ("nfeatures", 100),
               ("art_box", "0.06,0.09,0.94,0.58"), ("resize_long_edge", 480),
               ("preprocess", "gray+equalizeHist"), ("built", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))]:
    con.execute("INSERT INTO orb_meta VALUES (?,?)", (k_, str(v_)))
con.commit()
sizes = {r[0]: r[1] for r in con.execute(
    "SELECT name, SUM(pgsize) FROM dbstat WHERE name LIKE 'orb_%' GROUP BY name")} \
    if con.execute("SELECT 1 FROM pragma_compile_options WHERE compile_options LIKE '%DBSTAT%'").fetchone() else {}
con.close()
print("wrote orb_meta / orb_vocab / orb_bow / orb_idf / orb_desc to cards.sqlite")
for k_, v_ in sizes.items(): print(f"    {k_:10s} {v_/1e6:7.1f} MB")
print(f"cards.sqlite now {os.path.getsize(DB)/1e6:.0f} MB")
