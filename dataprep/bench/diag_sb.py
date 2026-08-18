"""Strategic Betrayal deep-dive: dump the captured warp(s) + every reference
artwork side-by-side, and report art-crop cosine of each warp vs each reference
printing (so we can see WHICH reference the physical card should match)."""
import os, sqlite3, csv
from collections import defaultdict
import numpy as np
from PIL import Image
import torch, timm

LABEL = "strategic betrayal"
DB, CACHE, WARPS = "dataprep/out/cards.sqlite", "dataprep/image_cache", "dataprep/bench/warps"
OUT = "dataprep/bench/diag_sb"
ART = (0.06, 0.09, 0.94, 0.58)
os.makedirs(OUT, exist_ok=True)
db = sqlite3.connect(DB); db.row_factory = sqlite3.Row

def cache_path(iid):
    if not iid:
        return None
    p = f"{CACHE}/{iid[0]}/{iid[1]}/{iid}_front.jpg"
    return p if os.path.exists(p) else None

def art_crop(im):
    w, h = im.size
    return im.crop((int(ART[0]*w), int(ART[1]*h), int(ART[2]*w), int(ART[3]*h)))

# every printing of the card, with its own image
rows = db.execute("SELECT scryfall_id,illustration_id,image_id,set_code,"
                  "collector_number,artist,lang FROM printings WHERE lower(name)=?",
                  (LABEL,)).fetchall()
byillu = {}
for r in rows:
    p = cache_path(r["image_id"])
    if p and r["illustration_id"] not in byillu:
        byillu[r["illustration_id"]] = (p, r)
print(f"{LABEL}: {len(rows)} printings, {len(byillu)} distinct cached artworks")
for iid, (p, r) in byillu.items():
    print(f"   illu={iid[:8]} set={r['set_code']:6s} #{r['collector_number']:8s} "
          f"artist={r['artist']} lang={r['lang']}")
    Image.open(p).convert("RGB").save(f"{OUT}/REF_{r['set_code']}_{iid[:8]}.jpg")
    art_crop(Image.open(p).convert("RGB")).save(f"{OUT}/REFART_{r['set_code']}_{iid[:8]}.jpg")

m = timm.create_model('vit_small_patch14_dinov2.lvd142m', pretrained=True,
                      num_classes=0, img_size=224); m.eval()
cfg = timm.data.resolve_data_config({}, model=m); cfg['input_size'] = (3, 224, 224)
tf = timm.data.create_transform(**cfg)

def emb(im):
    with torch.no_grad():
        v = m(tf(im).unsqueeze(0))[0].numpy()
    return v / (np.linalg.norm(v) + 1e-9)

refs = {}
for iid, (p, r) in byillu.items():
    im = Image.open(p).convert("RGB")
    refs[f"{r['set_code']}/{iid[:8]}"] = (emb(art_crop(im)), emb(im))

manifest = [x for x in csv.DictReader(open(f"{WARPS}/manifest.csv"))
            if x["true_label"].strip().lower() == LABEL]
print(f"\nper-warp cosine to each reference (ART | FULL):")
for r in manifest[:10]:
    im = Image.open(f"{WARPS}/{r['file']}").convert("RGB")
    im.save(f"{OUT}/WARP_{r['file']}")
    art_crop(im).save(f"{OUT}/WARPART_{r['file']}")
    qa, qf = emb(art_crop(im)), emb(im)
    parts = [f"{k}: {float(v[0]@qa):.2f} | {float(v[1]@qf):.2f}" for k, v in refs.items()]
    print(f"  {r['file']:26s} {'   '.join(parts)}")
print(f"\nwrote crops/refs to {OUT}/ — open WARPART_*.jpg vs REFART_*.jpg to compare visually")
