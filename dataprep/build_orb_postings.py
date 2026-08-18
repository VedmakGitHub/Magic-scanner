"""Precompute the inverted index so the app LOADS it instead of building it.

Building postings from orb_bow takes ~19 s in Python and would be slower in
Dart -- far too slow for app start. This flattens the index into three blobs
the app can read directly:

  post_card    int32  [P]      card index per posting, grouped by word
  post_weight  float32[P]      tf * idf / L2norm, i.e. the final scored weight
  word_offset  int32  [K+1]    slice bounds per word (CSC indptr)
  card_illu    text            row order -> illustration_id

Query scoring is then: for each query word w with weight qw, walk
post_card[word_offset[w] : word_offset[w+1]] and accumulate qw * post_weight.
"""
import sqlite3, time
from collections import defaultdict
import numpy as np

DB = "dataprep/out/cards.sqlite"
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
meta = {r["key"]: r["value"] for r in con.execute("SELECT * FROM orb_meta")}
K, SOFT = int(meta["k"]), int(meta["soft"])
idf = np.frombuffer(con.execute("SELECT idf FROM orb_idf").fetchone()[0], np.float32)

t0 = time.time()
illus, per_word = [], defaultdict(list)     # word -> [(card, weight)]
for r in con.execute("SELECT illustration_id, n, words FROM orb_bow"):
    ci = len(illus); illus.append(r["illustration_id"])
    n = r["n"]
    if n == 0: continue
    w = np.frombuffer(r["words"], np.uint16)
    acc = defaultdict(float)
    for rank in range(SOFT):                # weight implied by POSITION
        for wid in w[rank*n:(rank+1)*n]: acc[int(wid)] += 1.0/(rank+1)
    # tf-idf then L2 normalise per card, so the query only does a dot product
    ws = np.fromiter(acc.values(), np.float32) * idf[np.fromiter(acc.keys(), np.int32)]
    nrm = float(np.sqrt((ws*ws).sum())) or 1.0
    for (wid, _), wv in zip(acc.items(), ws/nrm): per_word[wid].append((ci, float(wv)))
NC = len(illus)
print(f"scored {NC:,} cards in {time.time()-t0:.0f}s", flush=True)

off = np.zeros(K+1, np.int32)
for wid in range(K): off[wid+1] = off[wid] + len(per_word.get(wid, ()))
P = int(off[-1])
card = np.zeros(P, np.int32); weight = np.zeros(P, np.float32)
for wid, lst in per_word.items():
    a = off[wid]
    for i, (ci, wv) in enumerate(lst): card[a+i] = ci; weight[a+i] = wv
print(f"postings {P:,} | card {card.nbytes/1e6:.0f} MB + weight {weight.nbytes/1e6:.0f} MB "
      f"+ offsets {off.nbytes/1e6:.1f} MB = {(card.nbytes+weight.nbytes+off.nbytes)/1e6:.0f} MB in RAM")

con.executescript("""
DROP TABLE IF EXISTS orb_index; DROP TABLE IF EXISTS orb_cards;
CREATE TABLE orb_index (id INTEGER PRIMARY KEY, postings INT, cards INT,
                        post_card BLOB, post_weight BLOB, word_offset BLOB);
CREATE TABLE orb_cards (idx INTEGER PRIMARY KEY, illustration_id TEXT);
""")
con.execute("INSERT INTO orb_index VALUES (1,?,?,?,?,?)",
            (P, NC, card.tobytes(), weight.tobytes(), off.tobytes()))
con.executemany("INSERT INTO orb_cards VALUES (?,?)", list(enumerate(illus)))
con.execute("INSERT OR REPLACE INTO orb_meta VALUES ('postings_prebuilt','1')")
con.commit(); con.close()
print("wrote orb_index + orb_cards (app now loads postings, does not build them)")
