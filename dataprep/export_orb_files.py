"""Export the large ORB arrays as FILES instead of sqlite BLOBs.

Android's CursorWindow caps a single row at ~2 MB, so sqflite cannot read the
vocabulary (2.1 MB) or the posting arrays (57 MB each) at all:

  E SQLiteQuery: Row too big to fit into CursorWindow ... FROM orb_vocab

Files have no such limit, load faster, and can be mmapped later. orb_desc stays
in sqlite because its rows are ~3.2 KB, well under the cap.

Emits into dataprep/out/orb/:
  vocab.bin        uint8   [K,32]      binary centroids
  idf.bin          float32 [K]
  post_card.bin    int32   [P]         card index per posting, grouped by word
  post_weight.bin  float32 [P]         tf-idf / L2, final scored weight
  word_offset.bin  int32   [K+1]       CSC slice bounds
  cards.txt        text                row order -> illustration_id
  index.json       manifest for the app to validate what it loaded
"""
import json, os, sqlite3
import numpy as np

DB = "dataprep/out/cards.sqlite"
OUT = "dataprep/out/orb"
os.makedirs(OUT, exist_ok=True)
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
meta = {r["key"]: r["value"] for r in con.execute("SELECT * FROM orb_meta")}
K = int(meta["k"])

def dump(name, blob):
    with open(f"{OUT}/{name}", "wb") as f: f.write(blob)
    return len(blob)

sizes = {}
sizes["vocab.bin"] = dump("vocab.bin", con.execute("SELECT centroids FROM orb_vocab").fetchone()[0])
sizes["idf.bin"] = dump("idf.bin", con.execute("SELECT idf FROM orb_idf").fetchone()[0])
ix = con.execute("SELECT postings, cards, post_card, post_weight, word_offset FROM orb_index").fetchone()
sizes["post_card.bin"] = dump("post_card.bin", ix["post_card"])
sizes["post_weight.bin"] = dump("post_weight.bin", ix["post_weight"])
sizes["word_offset.bin"] = dump("word_offset.bin", ix["word_offset"])
illus = [r["illustration_id"] for r in con.execute("SELECT illustration_id FROM orb_cards ORDER BY idx")]
with open(f"{OUT}/cards.txt", "w", encoding="utf-8") as f: f.write("\n".join(illus))
sizes["cards.txt"] = os.path.getsize(f"{OUT}/cards.txt")

manifest = {"k": K, "soft": int(meta["soft"]), "nfeatures": int(meta["nfeatures"]),
            "art_box": meta["art_box"], "resize_long_edge": int(meta["resize_long_edge"]),
            "preprocess": meta["preprocess"], "cards": ix["cards"], "postings": ix["postings"],
            "files": sizes}
with open(f"{OUT}/index.json", "w") as f: json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
total = sum(sizes.values())
print(f"\ntotal {total/1e6:.0f} MB in {OUT}")

# the file copies make these tables dead weight in the DB; drop + VACUUM
con.executescript("DROP TABLE IF EXISTS orb_index; DROP TABLE IF EXISTS orb_bow;"
                  "DROP TABLE IF EXISTS orb_vocab; DROP TABLE IF EXISTS orb_idf;"
                  "DROP TABLE IF EXISTS orb_cards;")
con.commit(); con.execute("VACUUM"); con.close()
print(f"dropped file-backed tables + VACUUM -> cards.sqlite {os.path.getsize(DB)/1e6:.0f} MB "
      f"(printings + hashes + orb_desc + orb_meta)")
