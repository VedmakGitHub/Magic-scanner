"""Step 1: local-feature matching (ORB / AKAZE + Lowe ratio + RANSAC homography)
benchmarked against pHash and the DINOv2 embedding on the SAME real warps.

Two-stage for tractability:
  stage 1  ratio-test good-match count against every reference (cheap)
  stage 2  RANSAC homography on the top-N shortlist -> inlier count = final score

NOTE: brute force does not scale to 50k refs; this measures ACCURACY on a
reduced pool. Production would need a BoW/VLAD index.

Run: dataprep/.venv/Scripts/python.exe dataprep/bench/eval_local.py [pool] [per] [algo]
"""
import os, sys, sqlite3, csv, random, time
from collections import defaultdict
import numpy as np
import cv2

random.seed(0)
POOL = int(sys.argv[1]) if len(sys.argv) > 1 else 800
PER = int(sys.argv[2]) if len(sys.argv) > 2 else 8
ALGO = sys.argv[3] if len(sys.argv) > 3 else "orb"
CACHE = "dataprep/image_cache"
ART = (0.06, 0.09, 0.94, 0.58)
NFEAT, SHORTLIST, RATIO = 400, 25, 0.75

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

det = cv2.ORB_create(nfeatures=NFEAT) if ALGO == "orb" else cv2.AKAZE_create()
norm = cv2.NORM_HAMMING
bf = cv2.BFMatcher(norm)

def art(img):
    h, w = img.shape[:2]
    return img[int(ART[1]*h):int(ART[3]*h), int(ART[0]*w):int(ART[2]*w)]

def feats(path, size=480):
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is None: return None, None
    a = art(img)
    s = size / max(a.shape[:2])
    if s < 1.0:
        a = cv2.resize(a, (int(a.shape[1]*s), int(a.shape[0]*s)), interpolation=cv2.INTER_AREA)
    a = cv2.equalizeHist(a)
    return det.detectAndCompute(a, None)

# queries
warps = []
for folder, tag in [("dataprep/bench/warps", "dim"), ("dataprep/bench/bright/warps", "torch")]:
    if not os.path.exists(f"{folder}/manifest.csv"): continue
    per = defaultdict(int)
    for r in csv.DictReader(open(f"{folder}/manifest.csv")):
        lbl = r["true_label"].strip().lower(); p = f"{folder}/{r['file']}"
        if per[lbl] >= PER or not os.path.exists(p): continue
        per[lbl] += 1; warps.append((p, lbl, tag))
labels = {l for _, l, _ in warps}

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
print(f"[{ALGO}] pool {len(ref)} refs | {len(warps)} warps ({len(labels)} labels)", flush=True)

t0 = time.time()
RK, RD = [], []
for nm, p in ref:
    k, d = feats(p)
    RK.append(k); RD.append(d)
print(f"ref features in {time.time()-t0:.0f}s "
      f"(avg {np.mean([0 if d is None else len(d) for d in RD]):.0f} kp)", flush=True)
rn = np.array([n for n, _ in ref])

def score(qk, qd):
    counts = np.zeros(len(ref), np.int32)
    for j, dd in enumerate(RD):
        if dd is None or len(dd) < 2: continue
        good = 0
        for m in bf.knnMatch(qd, dd, k=2):
            if len(m) == 2 and m[0].distance < RATIO * m[1].distance:
                good += 1
        counts[j] = good
    inl = np.zeros(len(ref), np.int32)
    for j in np.argsort(-counts)[:SHORTLIST]:
        dd = RD[j]
        if dd is None or counts[j] < 8: continue
        pts = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, dd, k=2)
               if len(m) == 2 and m[0].distance < RATIO * m[1].distance]
        if len(pts) < 8: continue
        src = np.float32([qk[a].pt for a, _ in pts]).reshape(-1, 1, 2)
        dst = np.float32([RK[j][b].pt for _, b in pts]).reshape(-1, 1, 2)
        H, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
        if mask is not None: inl[j] = int(mask.sum())
    return inl, counts

t1 = time.time(); t1c = t5c = 0; per = defaultdict(lambda: [0, 0])
for qi, (p, lbl, tag) in enumerate(warps):
    qk, qd = feats(p)
    if qd is None or len(qd) < 8:
        per[lbl][1] += 1; continue
    inl, cnt = score(qk, qd)
    fin = inl.astype(np.float64) + cnt / 1000.0     # inliers primary, matches tiebreak
    rk, s = [], set()
    for j in np.argsort(-fin):
        if rn[j] in s: continue
        s.add(rn[j]); rk.append(rn[j])
        if len(rk) >= 5: break
    t1c += rk[0] == lbl; t5c += lbl in rk
    per[lbl][0] += rk[0] == lbl; per[lbl][1] += 1
    if qi % 10 == 0:
        print(f"  {qi}/{len(warps)} ({time.time()-t1:.0f}s)", flush=True)
n = len(warps)
print(f"\n[{ALGO}] top1={t1c/n*100:.1f}%  top5={t5c/n*100:.1f}%   ({time.time()-t1:.0f}s)")
for k, v in sorted(per.items()):
    print(f"    {k:22s} {v[0]}/{v[1]}")
