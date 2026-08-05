"""Step 3: extract ORB descriptors for EVERY cached reference artwork.

Produces the reference side of the deep-fix index. One entry per illustration
(the unit the matcher resolves to), stored as concatenated arrays + offsets so
it loads without per-card object overhead:

    desc     [total_kp, 32] uint8    ORB descriptors
    kpts     [total_kp,  2] float32  keypoint x,y (needed for RANSAC re-rank)
    offset   [n_cards+1]    int64    slice bounds per card
    illu     [n_cards]      str      illustration_id
    name     [n_cards]      str      card name (diagnostics)

Recipe must match the query side exactly (eval_local/eval_twostage):
    art crop (0.06,0.09,0.94,0.58) -> gray -> long edge 480 -> equalizeHist
    -> ORB(nfeatures=100)
"""
import os, sqlite3, time, sys
from collections import defaultdict
import numpy as np
import cv2

NF = 100
CACHE, ART = "dataprep/image_cache", (0.06, 0.09, 0.94, 0.58)
OUT = "dataprep/bench/orb_refs_all.npz"
LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 0   # 0 = all

db = sqlite3.connect("dataprep/out/cards.sqlite"); db.row_factory = sqlite3.Row
iname, iimgs = {}, defaultdict(list)
for r in db.execute("SELECT illustration_id,name,image_id FROM printings "
                    "WHERE illustration_id IS NOT NULL AND image_id IS NOT NULL"):
    iname.setdefault(r["illustration_id"], r["name"])
    iimgs[r["illustration_id"]].append(r["image_id"])

def cpath(i):
    p = f"{CACHE}/{i[0]}/{i[1]}/{i}_front.jpg"
    return p if os.path.exists(p) else None
def path_for(iid):
    for im in iimgs.get(iid, []):
        p = cpath(im)
        if p: return p
    return None

targets = []
for iid in iimgs:
    p = path_for(iid)
    if p: targets.append((iid, p))
if LIMIT: targets = targets[:LIMIT]
print(f"{len(targets):,} illustrations with cached art -> {OUT}", flush=True)

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

descs, kpts, offs, illu, names = [], [], [0], [], []
t0 = time.time(); empty = 0
for n, (iid, p) in enumerate(targets):
    k, d = kd(p)
    if d is None or len(d) == 0:
        d = np.zeros((0, 32), np.uint8); kp = np.zeros((0, 2), np.float32); empty += 1
    else:
        kp = np.array([x.pt for x in k], np.float32)
    descs.append(d); kpts.append(kp)
    offs.append(offs[-1] + len(d)); illu.append(iid); names.append(iname.get(iid, "?"))
    if n and n % 5000 == 0:
        el = time.time() - t0
        print(f"  {n:,}/{len(targets):,}  {el:.0f}s  eta {el/n*(len(targets)-n):.0f}s", flush=True)

D = np.vstack(descs) if descs else np.zeros((0, 32), np.uint8)
P = np.vstack(kpts) if kpts else np.zeros((0, 2), np.float32)
np.savez_compressed(OUT, desc=D, kpts=P, offset=np.array(offs, np.int64),
                    illu=np.array(illu), name=np.array(names))
mb = os.path.getsize(OUT) / 1e6
print(f"\ndone in {time.time()-t0:.0f}s: {len(targets):,} cards, {len(D):,} descriptors "
      f"(avg {len(D)/max(len(targets),1):.0f} kp), {empty} with no features")
print(f"  {OUT}  {mb:.0f} MB compressed")
print(f"  raw descriptors {len(D)*32/1e6:.0f} MB + keypoints {len(P)*8/1e6:.0f} MB")
