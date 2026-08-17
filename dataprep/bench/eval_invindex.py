"""#2 SPARSE INVERTED INDEX — the actual retrieval fix.

Earlier I blamed the 211 ms/query on flat-vocabulary quantization. The vocab
tree then made quantization 10x faster and total time barely moved (184 ms),
which proved the cost is really the DENSE scoring matmul: R @ q over an
(ncards x K) matrix touches every card for every query (8000 x 72,955 ~= 583
MFLOP), even though a query only activates a few hundred words.

An inverted index scores only the cards that share a word with the query:
    score = R_csc[:, query_words] @ query_weights
Column slicing a CSC matrix walks just those words' posting lists, so the work
is proportional to postings touched, not to the whole corpus.

This measures dense vs sparse retrieval for identical scores (they must match
to ~1e-6, otherwise the index is wrong, not just fast), and reports how many
cards each query actually touches.
"""
import os, sqlite3, csv, random, time, pickle
from collections import defaultdict
import numpy as np
import scipy.sparse as sp
import cv2
import torch

random.seed(0); np.random.seed(0); torch.manual_seed(0)
POOL, PER, NF = 8000, 40, 100
K, SOFT, KM_ITERS, TRAIN_DESC = 65536, 3, 12, 200_000
CACHE, ART = "dataprep/image_cache", (0.06, 0.09, 0.94, 0.58)
DCACHE = "dataprep/bench/desc_cache.pkl"
VOCAB_FLAT = "dataprep/bench/vocab_flat65k.npy"

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
for folder in ("dataprep/bench/warps", "dataprep/bench/bright/warps"):
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
for nm in labels | {"brass man", "pink horror", "shadowblood ridge", "drownyard amalgam",
                    "telepathy", "time warp", "sandblast", "never happened",
                    "thundercloud elemental", "coral fighters", "ertai's meddling"}:
    for i in n2i.get(nm, []): add(i)
al = list(iimgs); random.shuffle(al)
for i in al:
    if len(ref) >= POOL: break
    add(i)
rn = np.array([n for n, _ in ref])
with open(DCACHE, "rb") as f:
    c = pickle.load(f)
RD, QD = c["RD"], c["QD"]
print(f"pool {len(ref)} refs | {len(warps)} warps | K={K}", flush=True)

def unpack(d): return np.unpackbits(d, axis=1).astype(np.float32)

if os.path.exists(VOCAB_FLAT):
    C = torch.from_numpy(np.load(VOCAB_FLAT)); print("flat vocab loaded from cache", flush=True)
else:
    pool_desc = np.vstack([d for d in RD if d is not None])
    idx = np.random.choice(len(pool_desc), min(TRAIN_DESC, len(pool_desc)), replace=False)
    X = torch.from_numpy(unpack(pool_desc[idx]))
    t0 = time.time()
    C = X[torch.randperm(len(X))[:K]].clone()
    for it in range(KM_ITERS):
        asg = torch.empty(len(X), dtype=torch.long)
        for s in range(0, len(X), 8192):
            e = min(s + 8192, len(X)); asg[s:e] = torch.cdist(X[s:e], C).argmin(1)
        newC = torch.zeros_like(C); cnt = torch.zeros(K)
        newC.index_add_(0, asg, X); cnt.index_add_(0, asg, torch.ones(len(X)))
        C = torch.where((cnt == 0)[:, None], C, newC / cnt.clamp(min=1)[:, None])
    np.save(VOCAB_FLAT, C.numpy())
    print(f"flat vocab built in {time.time()-t0:.0f}s (cached)", flush=True)

def bowvec(d):
    if d is None or len(d) == 0: return np.zeros(K, np.float32)
    X = torch.from_numpy(unpack(d)); out = torch.empty((len(X), SOFT), dtype=torch.long)
    for s in range(0, len(X), 4096):
        e = min(s + 4096, len(X)); out[s:e] = torch.cdist(X[s:e], C).topk(SOFT, largest=False).indices
    w = out.numpy(); v = np.zeros(K, np.float32)
    for r_ in range(w.shape[1]): np.add.at(v, w[:, r_], 1.0 / (r_ + 1))
    return v

t0 = time.time()
Rv = np.stack([bowvec(d) for d in RD])
dfc = (Rv > 0).sum(0); idf = (np.log((len(Rv) + 1) / (dfc + 1)) + 1.0).astype(np.float32)
R = Rv * idf; R /= np.clip(np.linalg.norm(R, axis=1, keepdims=True), 1e-9, None)
print(f"refs quantized in {time.time()-t0:.0f}s", flush=True)

R_csc = sp.csc_matrix(R)                       # column = word -> posting list
print(f"index: {R_csc.nnz:,} postings, {R_csc.nnz/len(R):.0f} words/card avg, "
      f"{R_csc.data.nbytes/1e6:.1f} MB (dense would be {R.nbytes/1e6:.0f} MB)\n", flush=True)

dense_ms, sparse_ms, touched, maxerr = [], [], [], 0.0
for (p, lbl), qd in zip(warps, QD):
    if qd is None or len(qd) < 8: continue
    q = bowvec(qd) * idf
    nrm = np.linalg.norm(q)
    if nrm <= 0: continue
    q /= nrm
    t = time.time(); s_dense = R @ q; dense_ms.append((time.time() - t) * 1000)
    words = np.nonzero(q)[0]
    t = time.time()
    s_sparse = R_csc[:, words] @ q[words]      # only these words' postings
    sparse_ms.append((time.time() - t) * 1000)
    s_sparse = np.asarray(s_sparse).ravel()
    maxerr = max(maxerr, float(np.abs(s_dense - s_sparse).max()))
    touched.append(int((s_sparse > 0).sum()))

print("=== dense vs sparse retrieval (identical scores required) ===")
print(f"   max score difference : {maxerr:.2e}   {'OK' if maxerr < 1e-4 else 'MISMATCH - index is wrong'}")
print(f"   dense  R @ q         : {np.mean(dense_ms):6.1f} ms/query")
print(f"   sparse inverted idx  : {np.mean(sparse_ms):6.1f} ms/query   "
      f"({np.mean(dense_ms)/max(np.mean(sparse_ms),1e-9):.1f}x faster)")
print(f"   cards touched        : {np.mean(touched):.0f} of {len(R)} "
      f"({np.mean(touched)/len(R)*100:.0f}% of the corpus)")
print(f"\n   projected at 50k cards: dense {np.mean(dense_ms)*49877/len(R):.0f} ms  "
      f"vs sparse ~{np.mean(sparse_ms)*49877/len(R):.0f} ms")
