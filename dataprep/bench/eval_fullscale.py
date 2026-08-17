"""#1 FULL-SCALE validation: does the ORB result hold against ALL ~50k cards?

Every accuracy figure so far (98.6% at 400kp, 96.2% two-stage) used an
8,000-artwork pool. Production has ~50k. Retrieval gets harder as the pool
grows, so this re-runs the SAME method (per-card knnMatch + Lowe ratio, top-25
shortlist, RANSAC re-rank) against the full reference set extracted by
extract_all_orb.py -- only the pool size changes.

Reference set: dataprep/bench/orb_refs_all.npz (49,877 artworks, ORB nfeat=100).
Queries:       dataprep/bench/desc_cache.pkl  (the 209 captured real warps).
"""
import os, pickle, time, csv, sys
from collections import defaultdict
import numpy as np
import cv2

REFS = "dataprep/bench/orb_refs_all.npz"
DCACHE = "dataprep/bench/desc_cache.pkl"
SHORTLIST, RATIO = 25, 0.75
LIMIT_Q = int(sys.argv[1]) if len(sys.argv) > 1 else 0     # 0 = all queries

z = np.load(REFS, allow_pickle=True)
D, P, OFF, NAME = z["desc"], z["kpts"], z["offset"], z["name"]
NCARD = len(OFF) - 1
rname = np.array([str(x).lower() for x in NAME])
print(f"reference set: {NCARD:,} cards, {len(D):,} descriptors", flush=True)

with open(DCACHE, "rb") as f:
    c = pickle.load(f)
QD, QK = c["QD"], c["QK"]

# labels for the cached queries, in the same order extract used
warps = []
for folder in ("dataprep/bench/warps", "dataprep/bench/bright/warps"):
    mf = f"{folder}/manifest.csv"
    if not os.path.exists(mf): continue
    per = defaultdict(int)
    for r in csv.DictReader(open(mf)):
        lbl = r["true_label"].strip().lower(); p = f"{folder}/{r['file']}"
        if per[lbl] >= 40 or not os.path.exists(p): continue
        per[lbl] += 1; warps.append((p, lbl))
assert len(warps) == len(QD), f"label/query mismatch {len(warps)} vs {len(QD)}"
if LIMIT_Q:
    keep = list(range(0, len(warps), max(1, len(warps) // LIMIT_Q)))[:LIMIT_Q]
    warps = [warps[i] for i in keep]; QD = [QD[i] for i in keep]; QK = [QK[i] for i in keep]
print(f"queries: {len(warps)} warps\n", flush=True)

# present-in-pool check: a label we cannot possibly retrieve would silently
# depress the score, so verify each benchmark card exists in the reference set.
for lbl in sorted({l for _, l in warps}):
    print(f"  {'OK ' if (rname == lbl).any() else 'MISSING'} {lbl}", flush=True)

bf = cv2.BFMatcher(cv2.NORM_HAMMING)
t1c = t1r = n = 0
per = defaultdict(lambda: [0, 0, 0])
t0 = time.time()
for qi, ((p, lbl), qd, qk) in enumerate(zip(warps, QD, QK)):
    if qd is None or len(qd) < 8:
        continue
    n += 1
    counts = np.zeros(NCARD, np.int32)
    pairs = {}
    for j in range(NCARD):
        a, b = OFF[j], OFF[j + 1]
        if b - a < 2: continue
        pl = [(m[0].queryIdx, m[0].trainIdx) for m in bf.knnMatch(qd, D[a:b], k=2)
              if len(m) == 2 and m[0].distance < RATIO * m[1].distance]
        if pl:
            counts[j] = len(pl); pairs[j] = pl
    inl = np.zeros(NCARD, np.int32)
    for j in np.argsort(-counts)[:SHORTLIST]:
        pl = pairs.get(j) or []
        if len(pl) < 8: continue
        a = OFF[j]
        src = np.float32([qk[x] for x, _ in pl]).reshape(-1, 1, 2)
        dst = np.float32([P[a + y] for _, y in pl]).reshape(-1, 1, 2)
        _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 5.0)
        if mask is not None: inl[j] = int(mask.sum())

    def top1(score):
        seen = set()
        for j in np.argsort(-score):
            if rname[j] in seen: continue
            return rname[j]
        return None
    okc = top1(counts.astype(np.float64)) == lbl
    okr = top1(inl.astype(np.float64) + counts / 1000.0) == lbl
    t1c += okc; t1r += okr
    per[lbl][0] += okc; per[lbl][1] += okr; per[lbl][2] += 1
    if qi % 5 == 0:
        el = time.time() - t0
        print(f"  {qi}/{len(warps)}  {el:.0f}s  eta {el/max(n,1)*(len(warps)-qi):.0f}s  "
              f"running top1={t1c/max(n,1)*100:.1f}%", flush=True)

print(f"\n=== FULL-SCALE ({NCARD:,} cards, {n} queries) ===")
print(f"   count-only : {t1c/n*100:5.1f}%   (8k pool was 94.7%)")
print(f"   +RANSAC    : {t1r/n*100:5.1f}%   (8k pool was 95.7%; two-stage 96.2%)")
for k, v in sorted(per.items()):
    print(f"     {k:22s} {v[0]}/{v[2]} count , {v[1]}/{v[2]} ransac")
print(f"   {(time.time()-t0)/n:.1f} s/query brute force")
