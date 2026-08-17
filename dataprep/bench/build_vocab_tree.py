"""Vocabulary tree (hierarchical k-means, Nister-Stewenius) for ORB BoW.

The flat 65k vocabulary works (two-stage = 96.2%) but quantizing a query costs
~1.7 GFLOP -- it compares every descriptor against all 65,536 centroids, which
dominated the 211 ms/query in eval_twostage.py and would be far worse on a
phone. A tree of branching factor B and depth D has B^D leaves but quantizes in
B*D comparisons: B=10,D=5 gives 100k words for 50 comparisons instead of 65,536
(~1300x less work).

This builds the tree, caches ORB descriptors, and evaluates the SAME two-stage
pipeline on it so we can see whether hierarchical quantization costs accuracy.

Baseline to beat (flat K=65536, soft-3, top-10 -> exact re-rank):
    two-stage 96.2%   strategic 55/61   ~211 ms/query
"""
import os, sqlite3, csv, random, time, pickle
from collections import defaultdict
import numpy as np
import cv2

random.seed(0); np.random.seed(0)
POOL, PER, NF = 8000, 40, 100
BRANCH, DEPTH = 10, 5          # 100,000 leaves, 50 comparisons per descriptor
KM_ITERS, SOFT, SHORTLIST, RATIO = 8, 3, 10, 0.75
import sys as _s
BEAM = int(_s.argv[1]) if len(_s.argv) > 1 else 3
CACHE, ART = "dataprep/image_cache", (0.06, 0.09, 0.94, 0.58)
DESC_CACHE = "dataprep/bench/desc_cache.pkl"
TREE_OUT = "dataprep/bench/vocab_tree.npz"

# ---------------------------------------------------------------- data
db = sqlite3.connect("dataprep/out/cards.sqlite"); db.row_factory = sqlite3.Row
iname, iimgs = {}, defaultdict(list)
for r in db.execute("SELECT illustration_id,name,image_id FROM printings "
                    "WHERE illustration_id IS NOT NULL AND image_id IS NOT NULL"):
    iname.setdefault(r["illustration_id"], r["name"]); iimgs[r["illustration_id"]].append(r["image_id"])
def cp(i):
    p = f"{CACHE}/{i[0]}/{i[1]}/{i}_front.jpg"; return p if os.path.exists(p) else None
def pfi(i):
    for im in iimgs.get(i, []):
        p = cp(im)
        if p: return p
n2i = defaultdict(list)
for i, nm in iname.items(): n2i[nm.lower()].append(i)

warps = []
for folder in ("dataprep/bench/warps", "dataprep/bench/bright/warps"):
    if not os.path.exists(f"{folder}/manifest.csv"): continue
    per = defaultdict(int)
    for r in csv.DictReader(open(f"{folder}/manifest.csv")):
        lbl = r["true_label"].strip().lower(); p = f"{folder}/{r['file']}"
        if per[lbl] >= PER or not os.path.exists(p): continue
        per[lbl] += 1; warps.append((p, lbl))
labels = {l for _, l in warps}
ref, seen = [], set()
def add(i):
    if i in seen: return
    p = pfi(i)
    if p: seen.add(i); ref.append((iname[i].lower(), p))
for nm in sorted(labels | {"brass man", "pink horror", "shadowblood ridge", "drownyard amalgam",
                    "telepathy", "time warp", "sandblast", "never happened",
                    "thundercloud elemental", "coral fighters", "ertai's meddling"}):
    for i in n2i.get(nm, []): add(i)
al = list(iimgs); random.shuffle(al)
for i in al:
    if len(ref) >= POOL: break
    add(i)
rn = np.array([n for n, _ in ref])
print(f"pool {len(ref)} refs | {len(warps)} warps | B={BRANCH} D={DEPTH} "
      f"({BRANCH**DEPTH:,} leaves, {BRANCH*DEPTH} cmp/descriptor)", flush=True)

det = cv2.ORB_create(nfeatures=NF)
def kd(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None, None
    h, w = img.shape[:2]
    a = img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]
    s = 480 / max(a.shape[:2])
    if s < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*s), int(a.shape[0]*s)), interpolation=cv2.INTER_AREA)
    return det.detectAndCompute(cv2.equalizeHist(a), None)

if os.path.exists(DESC_CACHE):
    with open(DESC_CACHE, "rb") as f:
        cache = pickle.load(f)
    RK, RD, QK, QD = cache["RK"], cache["RD"], cache["QK"], cache["QD"]
    print(f"descriptors loaded from cache", flush=True)
else:
    t0 = time.time()
    rk_pt, RD, qk_pt, QD = [], [], [], []
    for _, p in ref:
        k, d = kd(p); rk_pt.append(np.array([kp.pt for kp in k], np.float32) if k else None); RD.append(d)
    for p, _ in warps:
        k, d = kd(p); qk_pt.append(np.array([kp.pt for kp in k], np.float32) if k else None); QD.append(d)
    RK, QK = rk_pt, qk_pt
    with open(DESC_CACHE, "wb") as f:
        pickle.dump({"RK": RK, "RD": RD, "QK": QK, "QD": QD}, f)
    print(f"descriptors extracted in {time.time()-t0:.0f}s (cached)", flush=True)

def unpack(d): return np.unpackbits(d, axis=1).astype(np.float32)

# ---------------------------------------------------------------- tree
def kmeans_np(X, k, iters):
    if len(X) <= k: return X.copy()
    C = X[np.random.choice(len(X), k, replace=False)].copy()
    for _ in range(iters):
        a = np.empty(len(X), np.int32)
        for s in range(0, len(X), 20000):
            e = min(s + 20000, len(X))
            d2 = (X[s:e]**2).sum(1)[:, None] - 2 * X[s:e] @ C.T + (C**2).sum(1)[None]
            a[s:e] = d2.argmin(1)
        for j in range(k):
            m = a == j
            if m.any(): C[j] = X[m].mean(0)
    return C

nodes_C, nodes_ch = [], []          # centroid per node, child ids per node
def build(X, depth):
    nid = len(nodes_C); nodes_C.append(X.mean(0) if len(X) else np.zeros(256, np.float32))
    nodes_ch.append([])
    if depth == DEPTH or len(X) <= BRANCH:
        return nid
    C = kmeans_np(X, BRANCH, KM_ITERS)
    d2 = (X**2).sum(1)[:, None] - 2 * X @ C.T + (C**2).sum(1)[None]
    a = d2.argmin(1)
    kids = []
    for j in range(len(C)):
        Xi = X[a == j]
        if len(Xi) == 0: continue
        cid = build(Xi, depth + 1)
        nodes_C[cid] = C[j]
        kids.append(cid)
    nodes_ch[nid] = kids
    return nid

t0 = time.time()
if os.path.exists(TREE_OUT):
    _z = np.load(TREE_OUT)
    C_arr, ch_arr, leaf_word = _z["C"], _z["ch"], _z["leaf_word"]
    K = int((leaf_word >= 0).sum())
    print(f"tree loaded from cache: {len(C_arr):,} nodes, {K:,} leaves", flush=True)
else:
  pool_desc = np.vstack([d for d in RD if d is not None])
  sample = pool_desc[np.random.choice(len(pool_desc), min(200_000, len(pool_desc)), replace=False)]
  build(unpack(sample), 0)
  C_arr = np.stack(nodes_C).astype(np.float32)
  leaves = [i for i, ch in enumerate(nodes_ch) if not ch]
  leaf_word = -np.ones(len(nodes_C), np.int32)
  for w, nid in enumerate(leaves): leaf_word[nid] = w
  K = len(leaves)
  maxch = max(len(c) for c in nodes_ch)
  ch_arr = -np.ones((len(nodes_ch), maxch), np.int32)
  for i, c in enumerate(nodes_ch): ch_arr[i, :len(c)] = c
  print(f"tree built in {time.time()-t0:.0f}s: {len(nodes_C):,} nodes, {K:,} leaves "
      f"(flat 65k k-means took 639s)", flush=True)
  np.savez_compressed(TREE_OUT, C=C_arr, ch=ch_arr, leaf_word=leaf_word)
  print(f"saved {TREE_OUT} ({os.path.getsize(TREE_OUT)/1e6:.1f} MB; "
      f"binarized would be ~{len(nodes_C)*32/1e6:.1f} MB)", flush=True)

# Not every branch reaches DEPTH (a node stops splitting once it holds <= BRANCH
# descriptors). Those shallow leaves have no children, so a fixed-depth descent
# hits an all -1 row, every candidate distance becomes inf, and the beam
# collapses to node 0 -> the descriptor is silently dropped. Give each leaf a
# self-loop so descent parks on it and still ends on a real leaf.
_leafmask = (ch_arr < 0).all(axis=1)
ch_arr[_leafmask, 0] = np.nonzero(_leafmask)[0]
print(f"padded {int(_leafmask.sum()):,} leaves with self-loops", flush=True)

def quantize(d):
    """Beam-search descent -> SOFT nearest leaf words per descriptor."""
    if d is None or len(d) == 0: return np.zeros((0, SOFT), np.int32)
    X = unpack(d)
    beam = np.zeros((len(X), 1), np.int32)
    for _ in range(DEPTH):
        cand = ch_arr[beam.reshape(-1)].reshape(len(X), -1)
        if (cand < 0).all(): break
        cc = C_arr[np.clip(cand, 0, None)]
        d2 = ((X[:, None, :] - cc) ** 2).sum(2)
        d2[cand < 0] = np.inf
        take = min(BEAM, cand.shape[1])
        idx = np.argpartition(d2, take - 1, axis=1)[:, :take]
        # argpartition is UNORDERED; sort the survivors by distance so that
        # beam[:,0] is the nearest. Without this, taking the first SOFT of a
        # wider beam picks an arbitrary subset (BEAM>SOFT collapsed to ~6%).
        idx = np.take_along_axis(idx, np.argsort(np.take_along_axis(d2, idx, 1), axis=1), 1)
        beam = np.take_along_axis(cand, idx, 1)
        if (ch_arr[np.clip(beam, 0, None)] < 0).all(): break
    w = leaf_word[np.clip(beam, 0, None)]
    out = -np.ones((len(X), SOFT), np.int32)
    for i in range(min(SOFT, w.shape[1])): out[:, i] = w[:, i]
    return out

def bowvec(d):
    w = quantize(d); v = np.zeros(K, np.float32)
    for r_ in range(w.shape[1]):
        col = w[:, r_]; col = col[col >= 0]
        if len(col): np.add.at(v, col, 1.0 / (r_ + 1))
    return v

# SANITY CHECK before trusting any accuracy number: a reference quantized
# against itself must retrieve itself. If self-retrieval fails, the quantizer is
# broken and every downstream figure is meaningless.
_probe = [i for i in range(len(RD)) if RD[i] is not None and len(RD[i]) >= 8][:40]
_pv = np.stack([bowvec(RD[i]) for i in _probe])
_pv /= np.clip(np.linalg.norm(_pv, axis=1, keepdims=True), 1e-9, None)
_self = sum(int(np.argmax(_pv @ _pv[a]) == a) for a in range(len(_probe)))
_nz = float(np.mean([(bowvec(RD[i]) > 0).sum() for i in _probe[:10]]))
print(f"SANITY self-retrieval {_self}/{len(_probe)}  (avg {_nz:.0f} distinct words/card)",
      flush=True)
if _self < len(_probe) * 0.9:
    print("!! quantizer is broken - accuracy numbers below are meaningless", flush=True)

t0 = time.time()
Rv = np.stack([bowvec(d) for d in RD])
qt = (time.time() - t0) / max(len(RD), 1) * 1000
dfc = (Rv > 0).sum(0); idf = np.log((len(Rv) + 1) / (dfc + 1)) + 1.0
R = Rv * idf; R /= np.clip(np.linalg.norm(R, axis=1, keepdims=True), 1e-9, None)
print(f"refs quantized: {qt:.1f} ms/card (flat 65k was ~200 ms)", flush=True)

# ------------------------------------------------------- two-stage eval
bf = cv2.BFMatcher(cv2.NORM_HAMMING)
def exact(qd, qk, j):
    dd = RD[j]
    if dd is None or len(dd) < 2 or qk is None or RK[j] is None: return 0, 0
    pl = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, dd, k=2)
          if len(m) == 2 and m[0].distance < RATIO * m[1].distance]
    if len(pl) < 8: return len(pl), 0
    src = np.float32([qk[a] for a, _ in pl]).reshape(-1, 1, 2)
    dst = np.float32([RK[j][b] for _, b in pl]).reshape(-1, 1, 2)
    _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
    return len(pl), (0 if mask is None else int(mask.sum()))

t1c = t1r = n = 0; sb = [0, 0, 0]; rec = 0; tq = 0.0
for (p, lbl), qd, qk in zip(warps, QD, QK):
    if qd is None or len(qd) < 8: continue
    n += 1
    t0 = time.time()
    q = bowvec(qd) * idf; q /= max(np.linalg.norm(q), 1e-9)
    order = np.argsort(-(R @ q))
    tq += time.time() - t0
    short, seen2 = [], set()
    for j in order:
        if rn[j] in seen2: continue
        seen2.add(rn[j]); short.append(j)
        if len(short) >= SHORTLIST: break
    rec += lbl in [rn[j] for j in short]
    sc = [(j, *exact(qd, qk, j)) for j in short]
    okc = rn[max(sc, key=lambda x: x[1])[0]] == lbl
    okr = rn[max(sc, key=lambda x: (x[2], x[1]))[0]] == lbl
    t1c += okc; t1r += okr
    if lbl == "strategic betrayal": sb[0] += okc; sb[1] += okr; sb[2] += 1

print(f"\n=== VOCAB TREE two-stage (B={BRANCH} D={DEPTH}, {K:,} leaves), n={n} ===")
print(f"   BoW recall@{SHORTLIST} : {rec/n*100:5.1f}%   (flat 65k: 96.2%)")
print(f"   count-only re-rank : {t1c/n*100:5.1f}%   (flat 65k two-stage: 96.2%)")
print(f"   +RANSAC   re-rank : {t1r/n*100:5.1f}%   (flat 65k two-stage: 96.2%)")
print(f"   strategic          : {sb[0]}/{sb[2]} count , {sb[1]}/{sb[2]} ransac   (flat: 55/61)")
print(f"   quantize+retrieve  : {tq/n*1000:.0f} ms/query   (flat 65k: ~200 ms)")
