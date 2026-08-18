"""Test photometric normalization for the domain gap: does auto-contrast / CLAHE
on BOTH reference and query rescue dark, underexposed captures (Strategic
Betrayal) without hurting the cards that already work?

Fast focused pool. Usage: diag_norm.py [pool]
"""
import os, sys, sqlite3, csv, random
from collections import defaultdict
import numpy as np
from PIL import Image, ImageOps
import cv2
import torch, timm

random.seed(1)
POOL = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
DB, CACHE, WARPS = "dataprep/out/cards.sqlite", "dataprep/image_cache", "dataprep/bench/warps"
ART = (0.06, 0.09, 0.94, 0.58)
db = sqlite3.connect(DB); db.row_factory = sqlite3.Row

def cache_path(iid):
    if not iid:
        return None
    p = f"{CACHE}/{iid[0]}/{iid[1]}/{iid}_front.jpg"
    return p if os.path.exists(p) else None

def art_crop(im):
    w, h = im.size
    return im.crop((int(ART[0]*w), int(ART[1]*h), int(ART[2]*w), int(ART[3]*h)))

def clahe(im):
    a = cv2.cvtColor(np.array(im), cv2.COLOR_RGB2LAB)
    c = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
    a[:, :, 0] = c.apply(a[:, :, 0])
    return Image.fromarray(cv2.cvtColor(a, cv2.COLOR_LAB2RGB))

MODES = {
    "art":        lambda im: art_crop(im),
    "art+auto":   lambda im: ImageOps.autocontrast(art_crop(im), cutoff=1),
    "art+clahe":  lambda im: clahe(art_crop(im)),
}

illu_name, illu_imgs = {}, defaultdict(list)
for r in db.execute("SELECT illustration_id,name,image_id FROM printings "
                    "WHERE illustration_id IS NOT NULL AND image_id IS NOT NULL"):
    illu_name.setdefault(r["illustration_id"], r["name"])
    illu_imgs[r["illustration_id"]].append(r["image_id"])

def path_for_illu(iid):
    for im in illu_imgs.get(iid, []):
        p = cache_path(im)
        if p:
            return p
    return None

name_to_illus = defaultdict(list)
for iid, nm in illu_name.items():
    name_to_illus[nm.lower()].append(iid)

manifest = list(csv.DictReader(open(f"{WARPS}/manifest.csv")))
labels = {r["true_label"].strip().lower() for r in manifest}
ref, seen = [], set()
def add(iid):
    if iid in seen:
        return
    p = path_for_illu(iid)
    if p:
        seen.add(iid); ref.append((illu_name[iid].lower(), p))
for nm in labels | {"brass man", "drownyard amalgam", "pink horror", "ashiok, dream render",
                    "candlelit cavalry", "ancestral anger", "invasion of tolvada // the broken sky"}:
    for iid in name_to_illus.get(nm, []):
        add(iid)
allillu = list(illu_imgs.keys()); random.shuffle(allillu)
for iid in allillu:
    if len(ref) >= POOL:
        break
    add(iid)

m = timm.create_model('vit_small_patch14_dinov2.lvd142m', pretrained=True,
                      num_classes=0, img_size=224); m.eval()
cfg = timm.data.resolve_data_config({}, model=m); cfg['input_size'] = (3, 224, 224)
tf = timm.data.create_transform(**cfg)

def emb(im):
    with torch.no_grad():
        v = m(tf(im).unsqueeze(0))[0].numpy()
    return v / (np.linalg.norm(v) + 1e-9)

# subsample warps per label for speed
bylab = defaultdict(list)
for r in manifest:
    bylab[r["true_label"].strip().lower()].append(r)
sub = [r for lab, rs in bylab.items() for r in rs[:10]]
print(f"pool {len(ref)} refs | {len(sub)} warps ({len(bylab)} labels)\n")

for mode, fn in MODES.items():
    R = np.array([emb(fn(Image.open(p).convert("RGB"))) for _, p in ref])
    rn = np.array([nm for nm, _ in ref])
    per = defaultdict(lambda: [0, 0, 0])
    for r in sub:
        t = r["true_label"].strip().lower()
        q = emb(fn(Image.open(f"{WARPS}/{r['file']}").convert("RGB")))
        order = np.argsort(-(R @ q))
        ranked, s = [], set()
        for i in order:
            if rn[i] in s:
                continue
            s.add(rn[i]); ranked.append(rn[i])
            if len(ranked) >= 5:
                break
        per[t][0] += 1; per[t][1] += ranked[0] == t; per[t][2] += t in ranked
    tot = sum(v[0] for v in per.values()); t1 = sum(v[1] for v in per.values())
    t5 = sum(v[2] for v in per.values())
    detail = "  ".join(f"{k.split()[0]}:{v[1]}/{v[0]}" for k, v in sorted(per.items()))
    print(f"{mode:10s} top1={t1/tot*100:5.0f}%  top5={t5/tot*100:5.0f}%   {detail}", flush=True)
