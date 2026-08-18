"""Validate the PRODUCTION index in cards.sqlite end-to-end.

The vocabulary was retrained on the full 50,747-card set, so the 96.2% measured
with the old 8,000-pool vocabulary must be re-confirmed against the artifact the
app will actually ship. This reads ONLY the shipped tables -- no npz, no pickle
-- so it also proves the tables are self-sufficient and correctly encoded.

Deliberately reads the preprocessing recipe from orb_meta and applies it to the
queries: if the query side ever drifts from the recipe the index was built with,
descriptors stop matching, and this is where that must be caught.
"""
import csv, os, sqlite3, time
from collections import defaultdict
import numpy as np
import scipy.sparse as sp
import cv2

DB = "dataprep/out/cards.sqlite"
SHORTLIST, RATIO = 100, 0.75
GRID = (10, 20, 50, 100)
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
meta = {r["key"]: r["value"] for r in con.execute("SELECT * FROM orb_meta")}
K, SOFT = int(meta["k"]), int(meta["soft"])
NFEAT = int(meta["nfeatures"]); EDGE = int(meta["resize_long_edge"])
ART = tuple(float(x) for x in meta["art_box"].split(","))
print(f"index: {meta['cards']} cards, K={K:,}, soft={SOFT}, {meta['postings']} postings")
print(f"recipe from orb_meta: art={ART} edge={EDGE} nfeat={NFEAT} prep={meta['preprocess']}\n", flush=True)

Cb = np.frombuffer(con.execute("SELECT centroids FROM orb_vocab").fetchone()[0],
                   np.uint8).reshape(K, 32)
idf = np.frombuffer(con.execute("SELECT idf FROM orb_idf").fetchone()[0], np.float32)

# ---- build the in-RAM inverted index from orb_bow (weights DERIVED) ---------
t0 = time.time()
illus, rows, cols, vals = [], [], [], []
name_of = {}
for r in con.execute("SELECT p.name, b.illustration_id, b.n, b.words FROM orb_bow b "
                     "JOIN printings p ON p.illustration_id = b.illustration_id GROUP BY b.illustration_id"):
    ci = len(illus); illus.append(r["illustration_id"]); name_of[ci] = r["name"].lower()
    n = r["n"]
    if n == 0: continue
    w = np.frombuffer(r["words"], np.uint16)
    acc = defaultdict(float)
    for rank in range(SOFT):                      # weight implied by POSITION
        for wid in w[rank*n:(rank+1)*n]: acc[int(wid)] += 1.0/(rank+1)
    for wid, v in acc.items():
        rows.append(ci); cols.append(wid); vals.append(v)
NC = len(illus)
R = sp.csr_matrix((vals, (rows, cols)), shape=(NC, K), dtype=np.float32)
R = R.multiply(idf[None, :]).tocsr()
nrm = np.sqrt(R.multiply(R).sum(1)).A.ravel(); nrm[nrm == 0] = 1
R = sp.diags(1.0/nrm) @ R
R_csc = R.tocsc()
rn = np.array([name_of[i] for i in range(NC)])
print(f"inverted index built from orb_bow in {time.time()-t0:.0f}s: {R.nnz:,} postings, "
      f"{(R.data.nbytes + R.indices.nbytes)/1e6:.0f} MB\n", flush=True)

# ---- queries: apply the recipe from orb_meta -------------------------------
det = cv2.ORB_create(nfeatures=NFEAT)
bf = cv2.BFMatcher(cv2.NORM_HAMMING)
def kd(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None, None
    h, w = img.shape[:2]
    a = img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]
    s = EDGE / max(a.shape[:2])
    if s < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*s), int(a.shape[0]*s)), interpolation=cv2.INTER_AREA)
    return det.detectAndCompute(cv2.equalizeHist(a), None)

warps = []
for folder in ("dataprep/bench/warps", "dataprep/bench/bright/warps"):
    if not os.path.exists(f"{folder}/manifest.csv"): continue
    for r in csv.DictReader(open(f"{folder}/manifest.csv")):
        p = f"{folder}/{r['file']}"
        if os.path.exists(p): warps.append((p, r["true_label"].strip().lower()))
print(f"{len(warps)} benchmark warps\n", flush=True)

def desc_of(illu):
    r = con.execute("SELECT n,desc,kpts FROM orb_desc WHERE illustration_id=?", (illu,)).fetchone()
    if not r: return None, None
    return (np.frombuffer(r["desc"], np.uint8).reshape(-1,32),
            np.frombuffer(r["kpts"], np.float32).reshape(-1,2))

t1c = t1r = n = rec = 0; recN = [0]*len(GRID); accN = [[0,0] for _ in GRID]; per = defaultdict(lambda:[0,0,0]); tq = tr = 0.0
for p, lbl in warps:
    qk, qd = kd(p)
    if qd is None or len(qd) < 8: continue
    n += 1
    t = time.time()
    mm = bf.knnMatch(qd, Cb, k=SOFT)
    q = np.zeros(K, np.float32)
    for i, ms in enumerate(mm):
        for rank, m in enumerate(ms[:SOFT]): q[m.trainIdx] += 1.0/(rank+1)
    q *= idf
    nq = np.linalg.norm(q)
    if nq <= 0: continue
    q /= nq
    tq += time.time()-t
    t = time.time()
    wi = np.nonzero(q)[0]
    s = np.asarray(R_csc[:, wi] @ q[wi]).ravel()
    tr += time.time()-t
    short, seen = [], set()
    for j in np.argsort(-s):
        if rn[j] in seen: continue
        seen.add(rn[j]); short.append(j)
        if len(short) >= SHORTLIST: break
    ranked = [rn[j] for j in short]
    for gi, G in enumerate(GRID):
        if lbl in ranked[:G]: recN[gi] += 1
    best_c = best_r = (-1, -1, -1); scored = []
    for j in short:
        D2, P2 = desc_of(illus[j])
        if D2 is None or len(D2) < 2: continue
        pl = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, D2, k=2)
              if len(m)==2 and m[0].distance < RATIO*m[1].distance]
        inl = 0
        if len(pl) >= 8:
            src = np.float32([qk[a].pt for a,_ in pl]).reshape(-1,1,2)
            dst = np.float32([P2[b] for _,b in pl]).reshape(-1,1,2)
            _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
            inl = 0 if mask is None else int(mask.sum())
        scored.append((j, len(pl), inl))
        if len(pl) > best_c[1]: best_c = (j, len(pl), inl)
        if (inl, len(pl)) > (best_r[2], best_r[1]): best_r = (j, len(pl), inl)
    for gi, G in enumerate(GRID):
        sub = [x for x in scored if x[0] in short[:G]]
        if sub:
            bc = max(sub, key=lambda x: x[1]); br = max(sub, key=lambda x: (x[2], x[1]))
            accN[gi][0] += rn[bc[0]] == lbl; accN[gi][1] += rn[br[0]] == lbl
    okc = best_c[0] >= 0 and rn[best_c[0]] == lbl
    okr = best_r[0] >= 0 and rn[best_r[0]] == lbl
    t1c += okc; t1r += okr
    per[lbl][0] += okc; per[lbl][1] += okr; per[lbl][2] += 1

print(f"=== PRODUCTION INDEX ({NC:,} cards), n={n} ===")
print(f"   {'N':>4} {'recall@N':>9} {'count-only':>11} {'+RANSAC':>9}")
for gi, G in enumerate(GRID):
    print(f"   {G:4d} {recN[gi]/n*100:8.1f}% {accN[gi][0]/n*100:10.1f}% {accN[gi][1]/n*100:8.1f}%")
for k_, v in sorted(per.items()): print(f"     {k_:22s} {v[0]}/{v[2]} count , {v[1]}/{v[2]} ransac")
print(f"   quantize {tq/n*1000:.0f} ms | retrieve {tr/n*1000:.1f} ms  (desktop)")
