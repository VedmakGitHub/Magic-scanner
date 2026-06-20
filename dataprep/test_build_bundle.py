"""
Offline tests for build_bundle.py logic that does NOT require the network
(schema, printings insertion, face normalization, CDN url, signed-int packing).

Run:  python test_build_bundle.py
"""

from __future__ import annotations

import json
import os
import sqlite3
import tempfile

import build_bundle as bb


def test_cdn_url():
    url = bb.cdn_url("abcd1234", "small", "back")
    assert url == "https://cards.scryfall.io/small/back/a/b/abcd1234.jpg"


def test_image_id_from_uris():
    iu = {"normal": "https://cards.scryfall.io/normal/front/1/2/12345678.jpg?abc=1"}
    assert bb._image_id_from_uris(iu) == "12345678"
    assert bb._image_id_from_uris(None) is None


def test_signed64_roundtrip():
    for u in (0, 1, (1 << 63) - 1, 1 << 63, 0xFFFFFFFFFFFFFFFF):
        s = bb._to_signed64(u)
        back = s & 0xFFFFFFFFFFFFFFFF
        assert back == u, (u, s, back)


def test_iter_faces_single():
    card = {
        "id": "card1",
        "illustration_id": "ill1",
        "artist": "Artist A",
        "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/imgid1.jpg"},
    }
    faces = list(bb.iter_faces(card))
    assert len(faces) == 1
    label, f = faces[0]
    assert label == "front"
    assert f["illustration_id"] == "ill1"
    assert f["image_id"] == "imgid1"


def test_iter_faces_double():
    card = {
        "id": "card2",
        "illustration_id": "ill_front",
        "card_faces": [
            {"illustration_id": "ill_front", "artist": "A",
             "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/front1.jpg"}},
            {"illustration_id": "ill_back", "artist": "B",
             "image_uris": {"normal": "https://cards.scryfall.io/normal/back/c/d/back1.jpg"}},
        ],
    }
    faces = list(bb.iter_faces(card))
    assert [lbl for lbl, _ in faces] == ["front", "back"]
    assert faces[1][1]["illustration_id"] == "ill_back"
    assert faces[1][1]["image_id"] == "back1"


def test_build_printings_filters_and_inserts():
    default_cards = [
        {  # English single-faced — kept
            "id": "en1", "oracle_id": "o1", "illustration_id": "ill1", "name": "Llanowar Elves",
            "set": "m19", "set_name": "Core 2019", "collector_number": "314",
            "rarity": "common", "finishes": ["nonfoil", "foil"], "lang": "en",
            "released_at": "2018-07-13", "artist": "Anna",
            "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/img1.jpg"},
            "prices": {"usd": "0.25", "usd_foil": "1.50"},
        },
        {  # Non-English — dropped
            "id": "de1", "name": "Wald", "set": "m19", "set_name": "Core 2019",
            "collector_number": "1", "lang": "de", "finishes": ["nonfoil"],
            "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/img2.jpg"},
        },
        {  # token layout — dropped
            "id": "tok1", "name": "Treasure", "set": "tm19", "set_name": "T",
            "collector_number": "1", "lang": "en", "layout": "token",
            "finishes": ["nonfoil"],
            "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/img3.jpg"},
        },
        {  # English double-faced — 2 rows
            "id": "dfc1", "oracle_id": "o2", "name": "Delver", "set": "isd",
            "set_name": "Innistrad", "collector_number": "51", "rarity": "common",
            "lang": "en", "finishes": ["nonfoil"], "released_at": "2011-09-30",
            "card_faces": [
                {"illustration_id": "ilf", "artist": "X",
                 "image_uris": {"normal": "https://cards.scryfall.io/normal/front/a/b/f.jpg"}},
                {"illustration_id": "ilb", "artist": "Y",
                 "image_uris": {"normal": "https://cards.scryfall.io/normal/back/a/b/b.jpg"}},
            ],
            "prices": {"usd": None, "usd_foil": None},
        },
    ]
    tmp = tempfile.mkdtemp()
    db = os.path.join(tmp, "t.sqlite")
    conn = bb.create_db(db)
    n = bb.build_printings(conn, default_cards)
    assert n == 3, n  # en1 (1) + dfc1 (2)
    cur = conn.execute("SELECT name, set_code, face, finishes, price_usd, artist "
                       "FROM printings ORDER BY scryfall_id, face")
    rows = cur.fetchall()
    names = sorted(r[0] for r in rows)
    assert names == ["Delver", "Delver", "Llanowar Elves"], names
    # finishes stored as JSON
    elf = [r for r in rows if r[0] == "Llanowar Elves"][0]
    assert json.loads(elf[3]) == ["nonfoil", "foil"]
    assert elf[4] == 0.25 and elf[5] == "Anna"
    conn.close()


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(_run_all())
