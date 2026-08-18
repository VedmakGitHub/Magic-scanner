"""Quantization is now the bottleneck: fix it with BINARY centroids + Hamming.

After the sparse inverted index (retrieval 450ms -> ~3ms at 50k), assigning
query descriptors to words dominates the query budget. The flat vocabulary does
it in float space: 100 descriptors x 65,536 centroids x 256 dims ~= 1.7 GFLOP.

But ORB descriptors ARE binary. Binarizing the centroids (threshold the k-means
means at 0.5) turns assignment into Hamming distance over 32-byte codes, which
cv2.BFMatcher already does with SIMD popcount -- the same primitive we use for
matching. This measures BOTH what that buys in speed and what it costs in
accuracy, since binarizing centroids discards the fractional means.

Baselines (flat float vocab, K=65536, soft-3, top-10 -> exact re-rank):
    two-stage 96.2%   recall@10 96.2%   quantization ~200 ms/card
"""
import os, sqlite3, csv, random, time, pickle
from collections import defaultdict
import numpy as np
import scipy.sparse as sp
import cv2
import torch

random.seed(0); np.random.seed(0)
POOL, PER, K, SOFT, SHORTLIST, RATIO = 8000, 40, 65536, 3, 10, 0.75
CACHE, ART = "dataprep/image_cache", (0.06, 0.09, 0.94, 0.58)
DCACHE, VOCAB_FLAT = "dataprep/bench/desc_cache.pkl", "dataprep/bench/vocab_flat65k.npy"

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
# The descriptor cache is indexed positionally, so it is only valid for the
# EXACT reference pool that produced it. Pool order used to depend on set
# iteration (randomized per process by PYTHONHASHSEED), which silently
# misaligned RD[j] from rn[j] and collapsed accuracy to ~0%. Store the pool
# identity with the cache and refuse to use a mismatched one.
det0 = cv2.ORB_create(nfeatures=100)
def _kd(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None, None
    h, w = img.shape[:2]
    a = img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]
    sc = 480 / max(a.shape[:2])
    if sc < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*sc), int(a.shape[0]*sc)), interpolation=cv2.INTER_AREA)
    k, d = det0.detectAndCompute(cv2.equalizeHist(a), None)
    return (np.array([x.pt for x in k], np.float32) if k else None), d

c = None
if os.path.exists(DCACHE):
    with open(DCACHE, "rb") as f:
        c = pickle.load(f)
    if list(c.get("pool", [])) != [p for _, p in ref]:
        print("!! descriptor cache does not match this reference pool - regenerating", flush=True)
        c = None
if c is None:
    t0 = time.time()
    RK, RD, QK, QD = [], [], [], []
    for _, pth in ref:
        k, d = _kd(pth); RK.append(k); RD.append(d)
    for pth, _ in warps:
        k, d = _kd(pth); QK.append(k); QD.append(d)
    with open(DCACHE, "wb") as f:
        pickle.dump({"RK": RK, "RD": RD, "QK": QK, "QD": QD,
                     "pool": [p for _, p in ref]}, f)
    print(f"descriptors extracted in {time.time()-t0:.0f}s (cached with pool identity)", flush=True)
else:
    RD, RK, QD, QK = c["RD"], c["RK"], c["QD"], c["QK"]
    print("descriptors loaded from cache (pool verified)", flush=True)
Cf = np.load(VOCAB_FLAT)                      # [K,256] float centroids
print(f"pool {len(ref)} refs | {len(warps)} warps | K={len(Cf):,}", flush=True)

# Binarize: k-means means live in [0,1] per bit, so threshold at 0.5 and pack.
Cb = np.packbits((Cf > 0.5).astype(np.uint8), axis=1)      # [K,32] uint8
print(f"centroids: float {Cf.nbytes/1e6:.0f} MB -> binary {Cb.nbytes/1e6:.1f} MB "
      f"({Cf.nbytes/Cb.nbytes:.0f}x smaller)\n", flush=True)

bf_v = cv2.BFMatcher(cv2.NORM_HAMMING)
Ct = torch.from_numpy(Cf)

def words_binary(d):
    """Assign via Hamming against packed binary centroids (SIMD popcount)."""
    if d is None or len(d) == 0: return np.zeros((0, SOFT), np.int32)
    mm = bf_v.knnMatch(d, Cb, k=SOFT)
    out = np.zeros((len(d), SOFT), np.int32)
    for i, ms in enumerate(mm):
        for r_, m in enumerate(ms[:SOFT]): out[i, r_] = m.trainIdx
    return out

def words_float(d):
    """Original: Euclidean against float centroids."""
    if d is None or len(d) == 0: return np.zeros((0, SOFT), np.int32)
    X = torch.from_numpy(np.unpackbits(d, axis=1).astype(np.float32))
    out = torch.empty((len(X), SOFT), dtype=torch.long)
    for s in range(0, len(X), 4096):
        e = min(s + 4096, len(X)); out[s:e] = torch.cdist(X[s:e], Ct).topk(SOFT, largest=False).indices
    return out.numpy().astype(np.int32)

def bowvec(w):
    v = np.zeros(K, np.float32)
    for r_ in range(w.shape[1]):
        col = w[:, r_]
        if len(col): np.add.at(v, col, 1.0 / (r_ + 1))
    return v

# ---- speed A/B on the query set ------------------------------------------
probe = [d for d in QD if d is not None and len(d) >= 8][:25]
t = time.time()
for d in probe: words_float(d)
t_float = (time.time() - t) / len(probe) * 1000
t = time.time()
for d in probe: words_binary(d)
t_bin = (time.time() - t) / len(probe) * 1000
print(f"quantization: float {t_float:7.1f} ms/card   binary {t_bin:6.1f} ms/card   "
      f"({t_float/max(t_bin,1e-9):.0f}x faster)\n", flush=True)

# agreement between the two assignments (how much did binarizing move things?)
agree = tot = 0
for d in probe:
    a, b = words_float(d), words_binary(d)
    agree += int((a[:, 0] == b[:, 0]).sum()); tot += len(a)
print(f"top-1 word agreement float vs binary: {agree/tot*100:.1f}%\n", flush=True)

# ---- accuracy: full two-stage on binary-quantized index -------------------
t0 = time.time()
Rv = np.stack([bowvec(words_binary(d)) for d in RD])
print(f"refs quantized (binary) in {time.time()-t0:.0f}s", flush=True)
dfc = (Rv > 0).sum(0); idf = (np.log((len(Rv) + 1) / (dfc + 1)) + 1.0).astype(np.float32)
R = Rv * idf; R /= np.clip(np.linalg.norm(R, axis=1, keepdims=True), 1e-9, None)
R_csc = sp.csc_matrix(R)

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

t1c = t1r = n = rec = 0; sb = [0, 0, 0]; tq = 0.0
for (p, lbl), qd, qk in zip(warps, QD, QK):
    if qd is None or len(qd) < 8: continue
    n += 1
    t = time.time()
    q = bowvec(words_binary(qd)) * idf
    nrm = np.linalg.norm(q)
    if nrm <= 0: continue
    q /= nrm
    wi = np.nonzero(q)[0]
    s = np.asarray(R_csc[:, wi] @ q[wi]).ravel()
    tq += time.time() - t
    short, seen2 = [], set()
    for j in np.argsort(-s):
        if rn[j] in seen2: continue
        seen2.add(rn[j]); short.append(j)
        if len(short) >= SHORTLIST: break
    rec += lbl in [rn[j] for j in short]
    sc = [(j, *exact(qd, qk, j)) for j in short]
    okc = rn[max(sc, key=lambda x: x[1])[0]] == lbl
    okr = rn[max(sc, key=lambda x: (x[2], x[1]))[0]] == lbl
    t1c += okc; t1r += okr
    if lbl == "strategic betrayal": sb[0] += okc; sb[1] += okr; sb[2] += 1

print(f"\n=== BINARY VOCAB two-stage (K={K:,}, soft={SOFT}, top-{SHORTLIST}), n={n} ===")
print(f"   BoW recall@{SHORTLIST} : {rec/n*100:5.1f}%   (float flat: 96.2%)")
print(f"   count-only re-rank : {t1c/n*100:5.1f}%   (float flat two-stage: 96.2%)")
print(f"   +RANSAC   re-rank : {t1r/n*100:5.1f}%   (float flat two-stage: 96.2%)")
print(f"   strategic          : {sb[0]}/{sb[2]} count , {sb[1]}/{sb[2]} ransac   (float: 55/61)")
print(f"   quantize+retrieve  : {tq/n*1000:.1f} ms/query   (float+dense was ~200 ms)")
