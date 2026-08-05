"""Measure BoW QUANTIZATION LOSS for ORB matching.

Exact matching (brute-force Hamming over stored descriptors) is the accuracy
ceiling but costs ~160-640 MB and seconds per query. A bag-of-visual-words
inverted index is compact and fast, but replaces each 256-bit descriptor with a
single word ID -- discarding information. This measures what that costs, and
whether soft assignment recovers it.

Baseline to beat (same pool/warps, nfeatures=100, exact matching):
    count-only 94.7%   +RANSAC 95.7%   strategic 56/61 , 58/61
"""
import os, sqlite3, csv, random, time
from collections import defaultdict
import numpy as np
import cv2
import torch

random.seed(0); np.random.seed(0); torch.manual_seed(0)
POOL, PER, NF = 8000, 40, 100
VOCABS = [16384, 65536]
TRAIN_DESC, KM_ITERS = 200_000, 12
CACHE = "dataprep/image_cache"
ART = (0.06, 0.09, 0.94, 0.58)

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
for folder, _ in [("dataprep/bench/warps", "dim"), ("dataprep/bench/bright/warps", "torch")]:
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
for nm in labels | {"brass man", "pink horror", "shadowblood ridge", "drownyard amalgam",
                    "telepathy", "time warp", "sandblast", "never happened",
                    "thundercloud elemental", "coral fighters", "ertai's meddling"}:
    for i in n2i.get(nm, []): add(i)
al = list(iimgs); random.shuffle(al)
for i in al:
    if len(ref) >= POOL: break
    add(i)
rn = np.array([n for n, _ in ref])
print(f"pool {len(ref)} refs | {len(warps)} warps | ORB nfeatures={NF}", flush=True)

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
def desc(path):
    a = load(path)
    if a is None: return None
    _, d = det.detectAndCompute(a, None)
    return d

t0 = time.time()
RD = [desc(p) for _, p in ref]
QD = [desc(p) for p, _ in warps]
print(f"descriptors extracted in {time.time()-t0:.0f}s", flush=True)

def unpack(d):  # uint8 [n,32] -> float32 [n,256] of 0/1
    return np.unpackbits(d, axis=1).astype(np.float32)

pool_desc = np.vstack([d for d in RD if d is not None])
idx = np.random.choice(len(pool_desc), min(TRAIN_DESC, len(pool_desc)), replace=False)
train = torch.from_numpy(unpack(pool_desc[idx]))
print(f"vocab training set: {tuple(train.shape)}", flush=True)

def kmeans(X, k, iters):
    C = X[torch.randperm(len(X))[:k]].clone()
    for it in range(iters):
        assign = torch.empty(len(X), dtype=torch.long)
        for s in range(0, len(X), 8192):
            e = min(s + 8192, len(X))
            assign[s:e] = torch.cdist(X[s:e], C).argmin(1)
        newC = torch.zeros_like(C); cnt = torch.zeros(k)
        newC.index_add_(0, assign, X); cnt.index_add_(0, assign, torch.ones(len(X)))
        empty = cnt == 0
        C = torch.where(empty[:, None], C, newC / cnt.clamp(min=1)[:, None])
        if it % 4 == 0: print(f"    kmeans iter {it}  empty={int(empty.sum())}", flush=True)
    return C

def assign_words(d, C, topk):
    if d is None or len(d) == 0: return np.zeros((0, topk), np.int64)
    X = torch.from_numpy(unpack(d))
    out = torch.empty((len(X), topk), dtype=torch.long)
    for s in range(0, len(X), 4096):
        e = min(s + 4096, len(X))
        out[s:e] = torch.cdist(X[s:e], C).topk(topk, largest=False).indices
    return out.numpy()

base = {"count-only": 94.7, "+RANSAC": 95.7}
print(f"\nEXACT baseline (nfeat=100): count-only {base['count-only']}%  "
      f"+RANSAC {base['+RANSAC']}%  strategic 56/61\n")

for K in VOCABS:
    tk = time.time(); C = kmeans(train, K, KM_ITERS)
    print(f"  vocab K={K} built in {time.time()-tk:.0f}s", flush=True)
    for SOFT in (1, 3):
        tq = time.time()
        # reference tf vectors (sparse via dict) + document frequency
        Rw = [assign_words(d, C, SOFT) for d in RD]
        dfc = np.zeros(K)
        rows = []
        for w in Rw:
            v = np.zeros(K, np.float32)
            for r_ in range(w.shape[1]):
                np.add.at(v, w[:, r_], 1.0 / (r_ + 1))   # rank-weighted soft assign
            rows.append(v); dfc += (v > 0)
        idf = np.log((len(rows) + 1) / (dfc + 1)) + 1.0
        R = np.stack(rows) * idf
        R /= np.clip(np.linalg.norm(R, axis=1, keepdims=True), 1e-9, None)

        t1 = 0; n = 0; sb = [0, 0]; rec = [0,0,0]; sbrec = [0,0,0]
        for (p, lbl), qd in zip(warps, QD):
            if qd is None or len(qd) < 8: continue
            n += 1
            w = assign_words(qd, C, SOFT)
            q = np.zeros(K, np.float32)
            for r_ in range(w.shape[1]):
                np.add.at(q, w[:, r_], 1.0 / (r_ + 1))
            q *= idf; q /= max(np.linalg.norm(q), 1e-9)
            s = R @ q
            ranked, seen2 = [], set()
            for j in np.argsort(-s):
                if rn[j] in seen2: continue
                seen2.add(rn[j]); ranked.append(rn[j])
                if len(ranked) >= 50: break
            ok = ranked[0] == lbl
            t1 += ok
            for gi, G in enumerate((10, 20, 50)):
                rec[gi] += lbl in ranked[:G]
                if lbl == "strategic betrayal": sbrec[gi] += lbl in ranked[:G]
            if lbl == "strategic betrayal":
                sb[0] += ok; sb[1] += 1
        print(f"    K={K:6d} soft={SOFT}: top1={t1/n*100:5.1f}%  "
              f"recall@10={rec[0]/n*100:5.1f}%  @20={rec[1]/n*100:5.1f}%  @50={rec[2]/n*100:5.1f}%   "
              f"strategic top1={sb[0]}/{sb[1]} rec@20={sbrec[1]}/{sb[1]}   "
              f"[{time.time()-tq:.0f}s]", flush=True)
