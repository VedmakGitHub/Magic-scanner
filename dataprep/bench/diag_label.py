"""Diagnose one benchmark label: show its reference artworks + per-warp DINOv2
top-5 and where the TRUE card ranks. Fast (small focused pool)."""
import os, sys, sqlite3, csv, random
from collections import defaultdict
import numpy as np
from PIL import Image
import torch, timm

random.seed(1)
LABEL = (sys.argv[1] if len(sys.argv) > 1 else "strategic betrayal").lower()
DB, CACHE, WARPS = "dataprep/out/cards.sqlite", "dataprep/image_cache", "dataprep/bench/warps"
db = sqlite3.connect(DB); db.row_factory = sqlite3.Row

def cache_path(iid):
    if not iid:
        return None
    p = f"{CACHE}/{iid[0]}/{iid[1]}/{iid}_front.jpg"
    return p if os.path.exists(p) else None

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

print(f"illustrations for '{LABEL}':")
for iid in name_to_illus.get(LABEL, []):
    rr = db.execute("SELECT set_code,collector_number,artist FROM printings "
                    "WHERE illustration_id=? LIMIT 1", (iid,)).fetchone()
    print(f"   {iid}  set={rr['set_code']} #{rr['collector_number']} "
          f"artist={rr['artist']}  img={'OK' if path_for_illu(iid) else 'MISSING'}")

ref, seen = [], set()
def add(iid):
    if iid in seen:
        return
    p = path_for_illu(iid)
    if p:
        seen.add(iid); ref.append((illu_name[iid].lower(), p))

for nm in [LABEL, "brass man", "thundercloud elemental", "coral fighters",
           "drownyard amalgam", "pink horror", "devious cover-up",
           "ertai's meddling", "water elemental"]:
    for iid in name_to_illus.get(nm, []):
        add(iid)
allillu = list(illu_imgs.keys()); random.shuffle(allillu)
for iid in allillu:
    if len(ref) >= 600:
        break
    add(iid)

m = timm.create_model('vit_small_patch14_dinov2.lvd142m', pretrained=True,
                      num_classes=0, img_size=224); m.eval()
cfg = timm.data.resolve_data_config({}, model=m); cfg['input_size'] = (3, 224, 224)
tf = timm.data.create_transform(**cfg)

def embed(p):
    x = tf(Image.open(p).convert("RGB")).unsqueeze(0)
    with torch.no_grad():
        v = m(x)[0].numpy()
    return v / (np.linalg.norm(v) + 1e-9)

R = np.array([embed(p) for _, p in ref]); rn = np.array([nm for nm, _ in ref])
manifest = [r for r in csv.DictReader(open(f"{WARPS}/manifest.csv"))
            if r["true_label"].strip().lower() == LABEL]
print(f"\npool {len(ref)} refs, {len(manifest)} '{LABEL}' warps. per-warp DINO top-5:")
for r in manifest[:14]:
    q = embed(f"{WARPS}/{r['file']}"); sims = R @ q; order = np.argsort(-sims)
    truerank = next((k for k, idx in enumerate(order) if rn[idx] == LABEL), -1)
    truecos = float(sims[rn == LABEL].max()) if (rn == LABEL).any() else -1
    top, s = [], set()
    for idx in order:
        if rn[idx] in s:
            continue
        s.add(rn[idx]); top.append(f"{rn[idx]}({sims[idx]:.2f})")
        if len(top) >= 5:
            break
    print(f"  {r['file']:24s} trueRank={truerank:2d} trueCos={truecos:.2f} | {'  '.join(top)}")
