"""#2 White-balance vs contrast decomposition.

PIL's autocontrast() stretches each RGB channel independently -> it is ALREADY a
crude white balance. This isolates which mechanism carries the win:
  none        art crop only
  tone        autocontrast(preserve_tone=True)  -> contrast only, NO wb
  perchan     autocontrast()                    -> contrast + implicit wb (current)
  gray+tone   gray-world wb, then contrast-only  -> principled wb
"""
import os, sqlite3, csv, random
from collections import defaultdict
import numpy as np
from PIL import Image, ImageOps
import torch, timm

random.seed(0)
CACHE = "dataprep/image_cache"
ART = (0.06, 0.09, 0.94, 0.58)
POOL = 1500
PER = 10

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

def grayworld(im):
    a = np.asarray(im, np.float32); mu = a.reshape(-1, 3).mean(0)
    a *= (mu.mean() / np.clip(mu, 1e-6, None))
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))

def prep(path, mode):
    im = Image.open(path).convert("RGB"); w, h = im.size
    im = im.crop((int(ART[0]*w), int(ART[1]*h), int(ART[2]*w), int(ART[3]*h)))
    if mode == "tone":      return ImageOps.autocontrast(im, cutoff=1, preserve_tone=True)
    if mode == "perchan":   return ImageOps.autocontrast(im, cutoff=1)
    if mode == "gray+tone": return ImageOps.autocontrast(grayworld(im), cutoff=1, preserve_tone=True)
    return im

m = timm.create_model('vit_small_patch14_dinov2.lvd142m', pretrained=True,
                      num_classes=0, img_size=224); m.eval()
cfg = timm.data.resolve_data_config({}, model=m); cfg['input_size'] = (3, 224, 224)
tf = timm.data.create_transform(**cfg)
def emb(path, mode):
    with torch.no_grad(): v = m(tf(prep(path, mode)).unsqueeze(0))[0].numpy()
    return v / (np.linalg.norm(v) + 1e-9)

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
for nm in sorted(labels | {"brass man", "pink horror", "shadowblood ridge", "drownyard amalgam",
                    "telepathy", "time warp", "sandblast", "never happened"}):
    for i in n2i.get(nm, []): add(i)
al = list(iimgs); random.shuffle(al)
for i in al:
    if len(ref) >= POOL: break
    add(i)
print(f"pool {len(ref)} refs | {len(warps)} warps ({len(labels)} labels)\n")

for mode in ("none", "tone", "perchan", "gray+tone"):
    R = np.array([emb(p, mode) for _, p in ref]); rn = np.array([n for n, _ in ref])
    t1 = t5 = 0; per = defaultdict(lambda: [0, 0])
    for p, lbl, tag in warps:
        s = R @ emb(p, mode); order = np.argsort(-s)
        rk, seen2 = [], set()
        for idx in order:
            if rn[idx] in seen2: continue
            seen2.add(rn[idx]); rk.append(rn[idx])
            if len(rk) >= 5: break
        t1 += rk[0] == lbl; t5 += lbl in rk
        per[lbl][0] += rk[0] == lbl; per[lbl][1] += 1
    n = len(warps)
    det = "  ".join(f"{k.split()[0][:9]}:{v[0]}/{v[1]}" for k, v in sorted(per.items()))
    print(f"{mode:10s} top1={t1/n*100:5.1f}%  top5={t5/n*100:5.1f}%   {det}", flush=True)
