"""Offline tests for the kindle_review add-on logic, against throwaway collections.

Run with Anki's own Python (same anki version as Anki Desktop):
    QT_QPA_PLATFORM=offscreen "%LOCALAPPDATA%/AnkiProgramFiles/.venv/Scripts/python.exe" -m unittest discover tests
"""

import json
import re
import os
import shutil
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "addon"))

from anki.collection import Collection  # noqa: E402
from anki.scheduler.v3 import CardAnswer  # noqa: E402

from kindle_review import common, export, importer, mathrender  # noqa: E402

VENDOR = os.path.join(HERE, "..", "addon", "kindle_review", "vendor")


def make_col(path):
    col = Collection(path)
    basic = col.models.by_name("Basic")
    for front, back in [("capital of France", "Paris <img src='paris.png'>"),
                        (r"energy \(E=mc^2\)", r"\[\int_0^1 x\,dx = \tfrac12\]"),
                        ("<script>alert(1)</script>plain", "[sound:a.mp3]answer")]:
        n = col.new_note(basic)
        n["Front"], n["Back"] = front, back
        col.add_note(n, 1)
    cloze = col.models.by_name("Cloze")
    n = col.new_note(cloze)
    n["Text"] = "The {{c1::mitochondria}} is the {{c2::powerhouse}}"
    col.add_note(n, 1)
    with open(os.path.join(col.media.dir(), "paris.png"), "wb") as f:
        f.write(b"\x89PNG fake")
    return col


def entry(i, cid, rating, at_ms, pack_id):
    return {"id": "s1-%d" % i, "cid": cid, "rating": rating, "answered_at_ms": at_ms,
            "taken_ms": 4000, "pack_id": str(pack_id)}


def write_session(folder, name, entries):
    os.makedirs(os.path.join(folder, common.REVIEWS_DIR), exist_ok=True)
    with open(os.path.join(folder, common.REVIEWS_DIR, name), "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


class AddonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.col = make_col(os.path.join(self.tmp, "a.anki2"))
        self.folder = os.path.join(self.tmp, "anki-kindle")
        self.ledger = importer.Ledger(os.path.join(self.tmp, "user_files", "ledger.json"))

    def tearDown(self):
        self.col.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def new_cid(self, text):
        return self.col.find_cards('"Front:%s"' % text)[0]

    def read_pack(self):
        return common.read_json(os.path.join(self.folder, "pack", "pack.json"))

    def card_html(self, pack, rec):
        """(q, a) of a card record, sliced out of the cards file by byte offset/length."""
        with open(os.path.join(self.folder, "pack", pack["cards_file"]), "rb") as f:
            blob = f.read()
        return (blob[rec["qo"]:rec["qo"] + rec["ql"]].decode("utf-8"),
                blob[rec["ao"]:rec["ao"] + rec["al"]].decode("utf-8"))

    def bins(self):
        return sorted(n for n in os.listdir(os.path.join(self.folder, "pack")) if n.endswith(".bin"))

    def test_export_pack(self):
        data = export.collect(self.col, days_ahead=4)
        stats = export.write_pack(self.col, data, self.folder, None, [])
        pack = common.read_json(os.path.join(self.folder, "pack", "pack.json"))
        self.assertEqual(pack["format"], 2)
        self.assertEqual(stats["cards"], 5)  # 3 basic + 2 cloze
        self.assertEqual(pack["decks"]["1"]["learn_steps"], [60, 600])
        for c in pack["cards"]:
            self.assertNotIn("q", c)
            self.assertNotIn("a", c)
        cq = {c["cid"]: self.card_html(pack, c)[0] for c in pack["cards"]}
        visible = [re.sub(r"<[^>]+>", "", q) for q in cq.values()]  # data-cloze attributes are never displayed
        self.assertTrue(any("mitochondria" not in v and "[...]" in v for v in visible))  # cloze hidden on front
        plain = next(c for c in pack["cards"] if "plain" in cq[c["cid"]])
        pq, pa = self.card_html(pack, plain)
        self.assertNotIn("script", pq)
        self.assertNotIn("sound", pa)
        self.assertEqual(len(plain["labels"]), 4)
        self.assertFalse(any("⁨" in label for label in plain["labels"]))
        self.assertTrue(os.path.exists(os.path.join(self.folder, "pack", "media", "paris.png")))
        self.assertTrue(os.path.exists(os.path.join(self.folder, ".stignore")))

    def test_cards_file_slices(self):
        """q/a live in pack/cards-<pack_id>.bin; qo/ql/ao/al are byte offsets/lengths (not characters)."""
        basic = self.col.models.by_name("Basic")
        n = self.col.new_note(basic)
        n["Front"], n["Back"] = "Mass–energy équivalence 😀", "é — “quoted” 日本語"
        self.col.add_note(n, 1)
        data = export.collect(self.col, days_ahead=4)
        expected = {c["cid"]: (c["q"], c["a"]) for c in data.cards}
        export.write_pack(self.col, data, self.folder, None, [])
        pack = self.read_pack()
        self.assertEqual(self.bins(), [pack["cards_file"]])
        self.assertEqual(pack["cards_file"], "cards-%s.bin" % pack["pack_id"])
        with open(os.path.join(self.folder, "pack", pack["cards_file"]), "rb") as f:
            blob = f.read()
        pos = 0
        for rec in pack["cards"]:  # q then a per card, in order, no separators
            for k in ("qo", "ql", "ao", "al"):
                self.assertIsInstance(rec[k], int)
            self.assertEqual(rec["qo"], pos)
            self.assertEqual(rec["ao"], rec["qo"] + rec["ql"])
            pos = rec["ao"] + rec["al"]
        self.assertEqual(pos, len(blob))
        for rec in pack["cards"]:
            self.assertEqual(self.card_html(pack, rec), expected[rec["cid"]])
        uni = next(r for r in pack["cards"] if "Mass–energy" in expected[r["cid"]][0])
        q, a = self.card_html(pack, uni)
        self.assertIn("équivalence", q)
        self.assertIn("é — “quoted” 日本語", a)
        self.assertGreater(uni["ql"], len(q))  # multi-byte: byte length exceeds character count
        self.assertEqual(os.listdir(os.path.join(self.folder, "pack")).count("pack.json"), 1)
        self.assertFalse([f for f in os.listdir(os.path.join(self.folder, "pack")) if f.endswith(".tmp")])

    def test_old_cards_files_pruned(self):
        ids = []
        for _ in range(3):
            data = export.collect(self.col, days_ahead=4)
            export.write_pack(self.col, data, self.folder, None, [])
            pack = self.read_pack()
            ids.append(pack["cards_file"])
            self.assertEqual(self.bins(), sorted(ids[-2:]))  # current + one previous
            self.assertIn(pack["cards_file"], self.bins())
        self.assertEqual(len(set(ids)), 3)
        self.assertEqual(self.bins(), sorted(ids[1:]))
        for stale in ("cards-1.bin", "cards-2.bin"):  # leftovers from older runs are removed too
            open(os.path.join(self.folder, "pack", stale), "wb").close()
        data = export.collect(self.col, days_ahead=4)
        export.write_pack(self.col, data, self.folder, None, [])
        pack = self.read_pack()
        self.assertEqual(self.bins(), sorted([ids[2], pack["cards_file"]]))

    def test_ack_format_independent_of_pack_format(self):
        common.ensure_layout(self.folder)
        importer.write_ack(self.folder, self.ledger)
        self.assertEqual(common.read_json(os.path.join(self.folder, common.ACK_FILE))["format"], 1)
        self.assertEqual(common.FORMAT, 2)

    def test_math_rendered(self):
        from aqt.qt import QApplication, Qt
        QApplication.setAttribute(Qt.ApplicationAttribute.AA_ShareOpenGLContexts)
        app = QApplication.instance() or QApplication(sys.argv)  # noqa: F841
        data = export.collect(self.col, days_ahead=4)
        cache = mathrender.MathCache(os.path.join(self.tmp, "mathcache"))
        n = mathrender.MathRenderer(VENDOR).render_missing(export.all_math(data), cache)
        self.assertEqual(n, 2)
        export.write_pack(self.col, data, self.folder, cache, [])
        pack = self.read_pack()
        html = {c["cid"]: self.card_html(pack, c) for c in pack["cards"]}
        mc2 = next(h for h in html.values() if "energy" in h[0])
        self.assertIn('<img class="mj" src="math-', mc2[0])
        self.assertNotIn(r"\(", mc2[0])
        self.assertIn('<img class="mj" src="math-', mc2[1])  # block math on the back
        svgs = [f for f in os.listdir(os.path.join(self.folder, "pack", "media")) if f.startswith("math-")]
        self.assertEqual(len(svgs), 2)

    def test_replay_matches_live(self):
        """Again, Good, Good on a new card via the importer == answering live on a copy."""
        self.col.close()
        shutil.copy(os.path.join(self.tmp, "a.anki2"), os.path.join(self.tmp, "b.anki2"))
        self.col = Collection(os.path.join(self.tmp, "a.anki2"))
        live = Collection(os.path.join(self.tmp, "b.anki2"))
        try:
            cid = self.new_cid("capital of France")
            now = int(time.time() * 1000)
            for r in (CardAnswer.AGAIN, CardAnswer.GOOD, CardAnswer.GOOD):
                c = live.get_card(cid)
                c.start_timer()
                live.sched.answer_card(live.sched.build_answer(
                    card=c, states=live._backend.get_scheduling_states(cid), rating=r))
            write_session(self.folder, "s1.jsonl", [entry(i, cid, r, now - 3000 + i * 1000, now - 60000)
                                                    for i, r in enumerate((1, 3, 3))])
            res = importer.apply_entries(self.col, self.folder, self.ledger)
            self.assertEqual(res.applied, 3, res.skipped)
            a, b = self.col.get_card(cid), live.get_card(cid)
            self.assertEqual((a.type, a.queue, a.ivl, a.left), (b.type, b.queue, b.ivl, b.left))
            ids = self.col.db.list("select id from revlog where cid=? order by id", cid)
            self.assertEqual(ids, [now - 3000, now - 2000, now - 1000])  # Kindle timestamps kept
        finally:
            live.close()

    def test_late_review_due_shifted(self):
        cid = self.new_cid("capital of France")
        card = self.col.get_card(cid)  # make it a review card due today, without a revlog entry
        card.type, card.queue, card.ivl, card.due, card.factor = 2, 2, 5, self.col.sched.today, 2500
        self.col.update_card(card)
        two_days_ago = int((time.time() - 2 * 86400) * 1000)
        write_session(self.folder, "s1.jsonl", [entry(0, cid, 3, two_days_ago, two_days_ago - 60000)])
        res = importer.apply_entries(self.col, self.folder, self.ledger)
        self.assertEqual(res.applied, 1, res.skipped)
        card = self.col.get_card(cid)
        answered_day = importer.anki_day(self.col, two_days_ago / 1000)
        self.assertEqual(answered_day, self.col.sched.today - 2)
        self.assertEqual(card.due, answered_day + card.ivl)
        self.assertEqual(self.col.db.scalar("select max(id) from revlog where cid=?", cid), two_days_ago)

    def test_reimport_is_noop_and_ack(self):
        cid = self.new_cid("capital of France")
        now = int(time.time() * 1000)
        write_session(self.folder, "s1.jsonl", [entry(0, cid, 3, now, now - 60000)])
        self.assertEqual(importer.apply_entries(self.col, self.folder, self.ledger).applied, 1)
        ledger2 = importer.Ledger(self.ledger.path)  # reload from disk
        self.assertEqual(importer.apply_entries(self.col, self.folder, ledger2).applied, 0)
        self.assertEqual(self.col.db.scalar("select count() from revlog where cid=?", cid), 1)
        self.assertEqual(importer.write_ack(self.folder, ledger2), ["s1-0"])

    def test_conflict_skipped(self):
        cid = self.new_cid("capital of France")
        pack_ms = int(time.time() * 1000) - 120000
        c = self.col.get_card(cid)  # reviewed on the phone after the Kindle got the pack
        c.start_timer()
        self.col.sched.answer_card(self.col.sched.build_answer(
            card=c, states=self.col._backend.get_scheduling_states(cid), rating=CardAnswer.GOOD))
        write_session(self.folder, "s1.jsonl", [entry(0, cid, 4, pack_ms + 1000, pack_ms)])
        res = importer.apply_entries(self.col, self.folder, self.ledger)
        self.assertEqual(res.applied, 0)
        self.assertIn("reviewed elsewhere", res.skipped["s1-0"])
        ack = (importer.write_ack(self.folder, self.ledger),
               common.read_json(os.path.join(self.folder, common.ACK_FILE)))
        self.assertIn("s1-0", ack[1]["skipped"])

    def test_buried_sibling_still_applied(self):
        n = self.col.get_note(self.col.get_card(self.col.find_cards("note:Cloze")[0]).nid)
        c1, c2 = sorted(n.card_ids())
        now = int(time.time() * 1000)
        self.col.sched.bury_cards([c2])
        write_session(self.folder, "s1.jsonl", [entry(0, c1, 3, now - 2000, now - 60000),
                                                 entry(1, c2, 3, now - 1000, now - 60000)])
        res = importer.apply_entries(self.col, self.folder, self.ledger)
        self.assertEqual(res.applied, 2, res.skipped)


if __name__ == "__main__":
    unittest.main()
