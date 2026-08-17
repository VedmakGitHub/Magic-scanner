"""Accuracy/cost curve for ORB matching: how far can we cut keypoints (storage)
and drop RANSAC (which a compact index would force) before accuracy degrades?

For each nfeatures we report BOTH rankings from one pass:
  count-only  rank by Lowe-ratio good-match count   (compatible with a BoW index)
  +RANSAC     rank by homography inliers            (needs real keypoints)
plus projected storage and brute-force latency at the full 49,877-card scale.
"""
import os, sqlite3, csv, random, time
from collections import defaultdict
import numpy as np
import cv2

random.seed(0)
POOL, PER = 8000, 40
FULL_N = 49877
CACHE = "dataprep/image_cache"
ART = (0.06, 0.09, 0.94, 0.58)
SHORTLIST, RATIO = 25, 0.75
CONFIGS = [100]

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
for folder, tag in [("dataprep/bench/warps", "dim"), ("dataprep/bench/bright/warps", "torch")]:
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
print(f"pool {len(ref)} refs | {len(warps)} warps ({len(labels)} labels)\n", flush=True)
print(f"{'nfeat':>6} {'count-only':>11} {'+RANSAC':>9}   {'storage@50k':>12} {'brute@50k':>10}   strategic(count/ransac)")

def load(path):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None
    h, w = img.shape[:2]
    a = img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]
    s = 480 / max(a.shape[:2])
    if s < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*s), int(a.shape[0]*s)), interpolation=cv2.INTER_AREA)
    return cv2.equalizeHist(a)

for NF in CONFIGS:
    det = cv2.ORB_create(nfeatures=NF)
    bf = cv2.BFMatcher(cv2.NORM_HAMMING)
    RK, RD = [], []
    for _, p in ref:
        a = load(p)
        k, d = (None, None) if a is None else det.detectAndCompute(a, None)
        RK.append(k); RD.append(d)
    avg_kp = float(np.mean([0 if d is None else len(d) for d in RD]))

    t0 = time.time(); c1 = r1 = 0; n = 0
    sb = [0, 0, 0]
    for p, lbl in warps:
        a = load(p)
        qk, qd = (None, None) if a is None else det.detectAndCompute(a, None)
        if qd is None or len(qd) < 8: continue
        n += 1
        counts = np.zeros(len(ref), np.int32)
        pairs = {}
        for j, dd in enumerate(RD):
            if dd is None or len(dd) < 2: continue
            pl = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, dd, k=2)
                  if len(m) == 2 and m[0].distance < RATIO * m[1].distance]
            counts[j] = len(pl); pairs[j] = pl
        inl = np.zeros(len(ref), np.int32)
        for j in np.argsort(-counts)[:SHORTLIST]:
            pl = pairs.get(j) or []
            if len(pl) < 8: continue
            src = np.float32([qk[x].pt for x, _ in pl]).reshape(-1, 1, 2)
            dst = np.float32([RK[j][y].pt for _, y in pl]).reshape(-1, 1, 2)
            H, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
            if mask is not None: inl[j] = int(mask.sum())

        def top1(score):
            best, seen2 = None, set()
            for j in np.argsort(-score):
                if rn[j] in seen2: continue
                best = rn[j]; break
            return best == lbl
        ok_c = top1(counts.astype(np.float64))
        ok_r = top1(inl.astype(np.float64) + counts / 1000.0)
        c1 += ok_c; r1 += ok_r
        if lbl == "strategic betrayal":
            sb[0] += ok_c; sb[1] += ok_r; sb[2] += 1
    dt = (time.time() - t0) / max(n, 1)
    storage = avg_kp * 32 * FULL_N / 1e6
    brute = dt * FULL_N / len(ref)
    print(f"{NF:6d} {c1/n*100:10.1f}% {r1/n*100:8.1f}%   {storage:9.0f} MB {brute:9.1f}s   "
          f"{sb[0]}/{sb[2]} , {sb[1]}/{sb[2]}   (avg {avg_kp:.0f} kp)", flush=True)
