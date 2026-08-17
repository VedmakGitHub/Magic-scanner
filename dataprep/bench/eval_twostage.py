"""A + B: verify the ACTUAL two-stage pipeline end-to-end, and test REJECTION.

A) end-to-end: BoW(65k, soft-3, tf-idf) -> top-N shortlist -> exact Hamming
   re-rank on those N only. Compares against the numbers we inferred from
   measuring the stages separately (BoW recall@20 96.2%, exact top-1 94.7%).

B) rejection: re-run each query with its TRUE card REMOVED from the pool. A
   safe system must score these clearly lower than genuine matches, otherwise
   an unknown card silently commits as the nearest wrong one. Reports the
   separation between genuine and impostor scores (match count and RANSAC
   inliers), i.e. whether a threshold exists.
"""
import os, sqlite3, csv, random, time
from collections import defaultdict
import numpy as np
import cv2
import torch

random.seed(0); np.random.seed(0); torch.manual_seed(0)
POOL, PER, NF = 8000, 40, 100
K, SOFT, SHORTLIST, RATIO = 65536, 3, 10, 0.75
TRAIN_DESC, KM_ITERS = 200_000, 12
CACHE, ART = "dataprep/image_cache", (0.06, 0.09, 0.94, 0.58)

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
for folder, _ in [("dataprep/bench/warps", "d"), ("dataprep/bench/bright/warps", "t")]:
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
print(f"pool {len(ref)} refs | {len(warps)} warps | nfeat={NF} K={K} soft={SOFT} N={SHORTLIST}", flush=True)

det = cv2.ORB_create(nfeatures=NF)
def load(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None
    h, w = img.shape[:2]
    a = img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]
    s = 480 / max(a.shape[:2])
    if s < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*s), int(a.shape[0]*s)), interpolation=cv2.INTER_AREA)
    return cv2.equalizeHist(a)
def kd(path):
    a = load(path)
    if a is None: return None, None
    return det.detectAndCompute(a, None)

t0 = time.time()
RK, RD = zip(*[kd(p) for _, p in ref]); RK, RD = list(RK), list(RD)
QK, QD = zip(*[kd(p) for p, _ in warps]); QK, QD = list(QK), list(QD)
print(f"descriptors in {time.time()-t0:.0f}s", flush=True)

def unpack(d): return np.unpackbits(d, axis=1).astype(np.float32)
pool_desc = np.vstack([d for d in RD if d is not None])
idx = np.random.choice(len(pool_desc), min(TRAIN_DESC, len(pool_desc)), replace=False)
train = torch.from_numpy(unpack(pool_desc[idx]))
def kmeans(X, k, iters):
    C = X[torch.randperm(len(X))[:k]].clone()
    for it in range(iters):
        asg = torch.empty(len(X), dtype=torch.long)
        for s in range(0, len(X), 8192):
            e = min(s + 8192, len(X)); asg[s:e] = torch.cdist(X[s:e], C).argmin(1)
        newC = torch.zeros_like(C); cnt = torch.zeros(k)
        newC.index_add_(0, asg, X); cnt.index_add_(0, asg, torch.ones(len(X)))
        C = torch.where((cnt == 0)[:, None], C, newC / cnt.clamp(min=1)[:, None])
    return C
tk = time.time(); C = kmeans(train, K, KM_ITERS)
print(f"vocab built in {time.time()-tk:.0f}s", flush=True)

def words(d):
    if d is None or len(d) == 0: return np.zeros((0, SOFT), np.int64)
    X = torch.from_numpy(unpack(d)); out = torch.empty((len(X), SOFT), dtype=torch.long)
    for s in range(0, len(X), 4096):
        e = min(s + 4096, len(X)); out[s:e] = torch.cdist(X[s:e], C).topk(SOFT, largest=False).indices
    return out.numpy()
def bowvec(d):
    w = words(d); v = np.zeros(K, np.float32)
    for r_ in range(w.shape[1]): np.add.at(v, w[:, r_], 1.0 / (r_ + 1))
    return v
Rv = np.stack([bowvec(d) for d in RD])
dfc = (Rv > 0).sum(0); idf = np.log((len(Rv) + 1) / (dfc + 1)) + 1.0
R = Rv * idf; R /= np.clip(np.linalg.norm(R, axis=1, keepdims=True), 1e-9, None)
bf = cv2.BFMatcher(cv2.NORM_HAMMING)

def exact(qd, qk, j):
    dd = RD[j]
    if dd is None or len(dd) < 2: return 0, 0
    pl = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, dd, k=2)
          if len(m) == 2 and m[0].distance < RATIO * m[1].distance]
    if len(pl) < 8: return len(pl), 0
    src = np.float32([qk[a].pt for a, _ in pl]).reshape(-1, 1, 2)
    dst = np.float32([RK[j][b].pt for _, b in pl]).reshape(-1, 1, 2)
    _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
    return len(pl), (0 if mask is None else int(mask.sum()))

t1c = t1r = n = 0; sb = [0, 0, 0]
gen_c, gen_i, imp_c, imp_i = [], [], [], []
t2 = time.time()
for (p, lbl), qd, qk in zip(warps, QD, QK):
    if qd is None or len(qd) < 8: continue
    n += 1
    q = bowvec(qd) * idf; q /= max(np.linalg.norm(q), 1e-9)
    order = np.argsort(-(R @ q))
    short, seen2 = [], set()
    for j in order:
        if rn[j] in seen2: continue
        seen2.add(rn[j]); short.append(j)
        if len(short) >= SHORTLIST: break
    sc = [(j, *exact(qd, qk, j)) for j in short]
    bc = max(sc, key=lambda x: x[1]); br = max(sc, key=lambda x: (x[2], x[1]))
    okc = rn[bc[0]] == lbl; okr = rn[br[0]] == lbl
    t1c += okc; t1r += okr
    if lbl == "strategic betrayal": sb[0] += okc; sb[1] += okr; sb[2] += 1
    # B) rejection: same query, true card removed from the shortlist candidates
    imp = [x for x in sc if rn[x[0]] != lbl]
    gen = [x for x in sc if rn[x[0]] == lbl]
    if gen: gen_c.append(max(g[1] for g in gen)); gen_i.append(max(g[2] for g in gen))
    if imp: imp_c.append(max(i_[1] for i_ in imp)); imp_i.append(max(i_[2] for i_ in imp))

print(f"\n=== A) END-TO-END two-stage (BoW top-{SHORTLIST} -> exact re-rank), n={n} ===")
print(f"   count-only re-rank : {t1c/n*100:5.1f}%   (inferred ~94.7%, exact-brute 94.7%)")
print(f"   +RANSAC   re-rank : {t1r/n*100:5.1f}%   (exact-brute 95.7%)")
print(f"   strategic          : {sb[0]}/{sb[2]} count , {sb[1]}/{sb[2]} ransac   (exact 56/61 , 58/61)")
print(f"   re-rank cost       : {(time.time()-t2)/n*1000:.0f} ms/query (desktop, {SHORTLIST} candidates)")

def stat(a):
    a = np.array(a); return f"n={len(a)} mean={a.mean():5.1f} p10={np.percentile(a,10):5.1f} p50={np.percentile(a,50):5.1f} p90={np.percentile(a,90):5.1f} max={a.max():4.0f}"
print(f"\n=== B) REJECTION: genuine vs impostor scores (is a threshold possible?) ===")
print(f"   genuine  match-count : {stat(gen_c)}")
print(f"   impostor match-count : {stat(imp_c)}")
print(f"   genuine  RANSAC inl  : {stat(gen_i)}")
print(f"   impostor RANSAC inl  : {stat(imp_i)}")
for T in (8, 10, 12, 15, 20):
    tp = float(np.mean(np.array(gen_i) >= T) * 100); fp = float(np.mean(np.array(imp_i) >= T) * 100)
    print(f"   inlier threshold >={T:2d}: genuine accepted {tp:5.1f}%   impostor accepted {fp:5.1f}%")
