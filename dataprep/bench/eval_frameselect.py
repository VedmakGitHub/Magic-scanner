"""1a validation: does picking the BEST-QUALITY frame beat the FIRST stable frame?

Uses the pHash result already recorded per frame in manifest.csv (app_guess), so
this measures the CURRENT shipped matcher — no model needed.
"""
import csv, os
import numpy as np
import cv2
from collections import defaultdict

ART = (0.06, 0.09, 0.94, 0.58)
SETS = [("dataprep/bench/warps", "dim"), ("dataprep/bench/bright/warps", "torch")]


def metrics(path):
    im = cv2.imread(path)
    h, w = im.shape[:2]
    a = im[int(ART[1] * h):int(ART[3] * h), int(ART[0] * w):int(ART[2] * w)]
    g = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY).astype(np.float32)
    return {
        "contrast": float(g.std()),
        "sharp": float(cv2.Laplacian(g, cv2.CV_32F).var()),
        "lum": float(g.mean()),
        "glare": float((g > 245).mean() * 100),
    }


rows = []
for folder, tag in SETS:
    mf = f"{folder}/manifest.csv"
    if not os.path.exists(mf):
        continue
    for r in csv.DictReader(open(mf)):
        p = f"{folder}/{r['file']}"
        if not os.path.exists(p):
            continue
        m = metrics(p)
        m.update(set=tag, label=r["true_label"].strip().lower(),
                 ok=r["app_guess"].strip().lower() == r["true_label"].strip().lower(),
                 file=r["file"],
                 # runtime-available match confidence (lower dist / higher margin = better)
                 negdist=-float(r["best_dist"]), margin=float(r["margin"]),
                 conf=float(r["margin"]) - float(r["best_dist"]))
        rows.append(m)
print(f"loaded {len(rows)} frames\n")

# --- Q1: which metric predicts pHash correctness? (quartiles, hard cards only) ---
hard = [r for r in rows if r["label"] in ("flare of denial", "force of negation",
                                          "strategic betrayal")]
print("=== Does frame quality predict pHash correctness? (hard cards, n=%d) ===" % len(hard))
for k in ("contrast", "sharp", "lum", "glare"):
    v = np.array([r[k] for r in hard]); ok = np.array([r["ok"] for r in hard])
    qs = np.percentile(v, [25, 50, 75])
    bins = [ok[v <= qs[0]], ok[(v > qs[0]) & (v <= qs[1])],
            ok[(v > qs[1]) & (v <= qs[2])], ok[v > qs[2]]]
    print(f"  {k:9s} Q1={bins[0].mean()*100:5.1f}%  Q2={bins[1].mean()*100:5.1f}%  "
          f"Q3={bins[2].mean()*100:5.1f}%  Q4={bins[3].mean()*100:5.1f}%   "
          f"(lift Q4-Q1 = {(bins[3].mean()-bins[0].mean())*100:+.1f} pp)")

# --- Q2: simulate the policy, per card ---
print("\n=== Policy simulation: first-stable vs best-of-k (by metric) ===")
for metric in ("lum", "negdist", "margin", "conf"):
    print(f"\n  -- selecting by {metric} --")
    for k in (3, 5, 8):
        tot_f = tot_b = tot_o = n = 0
        per = defaultdict(lambda: [0, 0, 0, 0])
        bycard = defaultdict(list)
        for r in rows:
            bycard[(r["set"], r["label"])].append(r)
        for key, fr in bycard.items():
            if len(fr) < k:
                continue
            for i in range(len(fr) - k + 1):
                w = fr[i:i + k]
                first = w[0]["ok"]
                best = max(w, key=lambda x: x[metric])["ok"]
                orac = any(x["ok"] for x in w)
                tot_f += first; tot_b += best; tot_o += orac; n += 1
                p = per[key[1]]
                p[0] += first; p[1] += best; p[2] += orac; p[3] += 1
        print(f"    k={k}: first={tot_f/n*100:5.1f}%  best-of-k={tot_b/n*100:5.1f}%  "
              f"oracle={tot_o/n*100:5.1f}%   (n={n} windows)")
        if k == 5:
            for lbl, p in sorted(per.items()):
                if p[3]:
                    print(f"        {lbl:22s} first={p[0]/p[3]*100:5.1f}%  "
                          f"best={p[1]/p[3]*100:5.1f}%  oracle={p[2]/p[3]*100:5.1f}%")
