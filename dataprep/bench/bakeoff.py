"""Deep-fix bake-off: score a learned embedding against pHash on the REAL
captured-warp benchmark (dataprep/bench/warps). Whole-card DINOv2-S, cosine NN
over a reference pool that force-includes the true cards + known confusers.

Run: dataprep/.venv/Scripts/python.exe dataprep/bench/bakeoff.py [pool_size]
"""
import os, sys, sqlite3, csv, time, random
from collections import defaultdict
import numpy as np
from PIL import Image
import torch, timm

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
random.seed(0)
DB = "dataprep/out/cards.sqlite"
CACHE = "dataprep/image_cache"
WARPS = "dataprep/bench/warps"
POOL = int(sys.argv[1]) if len(sys.argv) > 1 else 8000

MODE = sys.argv[2] if len(sys.argv) > 2 else "full"  # "full" | "art" | "art+auto"
# Fractional art box on the canonical card (strips title bar, text box, borders).
# Generous enough to cover both modern and retro frames.
ART = (0.06, 0.09, 0.94, 0.58)  # x0,y0,x1,y1

db = sqlite3.connect(DB); db.row_factory = sqlite3.Row

def art_crop(im):
    w, h = im.size
    return im.crop((int(ART[0] * w), int(ART[1] * h), int(ART[2] * w), int(ART[3] * h)))

def cache_path(image_id):
    if not image_id:
        return None
    p = f"{CACHE}/{image_id[0]}/{image_id[1]}/{image_id}_front.jpg"
    return p if os.path.exists(p) else None

illu_name, illu_imgs = {}, defaultdict(list)
for r in db.execute("SELECT illustration_id, name, image_id FROM printings "
                    "WHERE illustration_id IS NOT NULL AND image_id IS NOT NULL"):
    illu_name.setdefault(r["illustration_id"], r["name"])
    illu_imgs[r["illustration_id"]].append(r["image_id"])

def path_for_illu(iid):
    for im in illu_imgs.get(iid, []):
        p = cache_path(im)
        if p:
            return p
    return None

manifest = list(csv.DictReader(open(f"{WARPS}/manifest.csv")))
labels = {r["true_label"].strip().lower() for r in manifest}
confusers = ["Brass Man", "Thundercloud Elemental", "Coral Fighters",
             "Drownyard Amalgam", "Pink Horror", "Devious Cover-Up",
             "Ertai's Meddling", "Water Elemental", "Candlegrove Witch",
             "Retribution of the Meek"]

name_to_illus = defaultdict(list)
for iid, nm in illu_name.items():
    name_to_illus[nm.lower()].append(iid)

ref, seen = [], set()
def add_illu(iid):
    if iid in seen:
        return
    p = path_for_illu(iid)
    if p:
        seen.add(iid); ref.append((illu_name[iid].lower(), p))

must = set(labels) | {c.lower() for c in confusers}
for nm in must:
    for iid in name_to_illus.get(nm, []):
        add_illu(iid)
forced = len(ref)
have = {nm for nm, _ in ref}
for nm in labels:
    print(f"  label present in pool: {nm}: {'YES' if nm in have else 'MISSING'}")
allillu = list(illu_imgs.keys()); random.shuffle(allillu)
for iid in allillu:
    if len(ref) >= POOL:
        break
    add_illu(iid)
print(f"ref pool: {len(ref)} artworks ({forced} forced) + {len(manifest)} warps\n")

torch.set_num_threads(os.cpu_count())
m = timm.create_model('vit_small_patch14_dinov2.lvd142m', pretrained=True,
                      num_classes=0, img_size=224); m.eval()
cfg = timm.data.resolve_data_config({}, model=m); cfg['input_size'] = (3, 224, 224)
tf = timm.data.create_transform(**cfg)

def embed(path):
    im = Image.open(path).convert("RGB")
    if MODE.startswith("art"):
        im = art_crop(im)
    if MODE.endswith("auto"):
        from PIL import ImageOps
        im = ImageOps.autocontrast(im, cutoff=1)
    x = tf(im).unsqueeze(0)
    with torch.no_grad():
        v = m(x)[0].numpy()
    return v / (np.linalg.norm(v) + 1e-9)

t0 = time.time()
R = np.zeros((len(ref), 384), np.float32); rnames = []
for i, (nm, p) in enumerate(ref):
    R[i] = embed(p); rnames.append(nm)
    if i % 500 == 0:
        print(f"  ref {i}/{len(ref)} ({time.time()-t0:.0f}s)", flush=True)
rnames = np.array(rnames)
print(f"refs embedded in {time.time()-t0:.0f}s\n", flush=True)

per = defaultdict(lambda: [0, 0, 0])  # n, top1, top5
for r in manifest:
    t = r["true_label"].strip().lower()
    q = embed(f"{WARPS}/{r['file']}")
    order = np.argsort(-(R @ q))
    ranked, s = [], set()
    for idx in order:
        nm = rnames[idx]
        if nm in s:
            continue
        s.add(nm); ranked.append(nm)
        if len(ranked) >= 5:
            break
    per[t][0] += 1
    per[t][1] += (ranked[0] == t)
    per[t][2] += (t in ranked)

print(f"\n=== MODE={MODE} ===")
print(f"{'card':22s} {'n':>3} {'DINO t1':>8} {'DINO t5':>8}   (pHash t1)")
phash = {"dauthi voidwalker": 100, "flare of denial": 48, "force of negation": 21,
         "strategic betrayal": 6, "subtlety": 100, "undercity sewers": 100}
N = T1 = T5 = 0
for t, (n, a, b) in sorted(per.items()):
    N += n; T1 += a; T5 += b
    print(f"{t:22s} {n:3d} {a/n*100:7.0f}% {b/n*100:7.0f}%   {phash.get(t,'?')}%")
print(f"\nTOTAL {N}: DINOv2 top1={T1/N*100:.0f}%  top5={T5/N*100:.0f}%   (pHash top1=59%)")
