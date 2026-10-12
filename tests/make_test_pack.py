"""Build a pack from a throwaway collection, for trying the KOReader plugin without touching real data.

    QT_QPA_PLATFORM=offscreen "%LOCALAPPDATA%/AnkiProgramFiles/.venv/Scripts/python.exe" tests/make_test_pack.py OUT_DIR
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "addon"))

from anki.collection import Collection  # noqa: E402
from aqt.qt import QApplication, QImage, QPainter, QColor, QFont, Qt  # noqa: E402

from kindle_review import export, mathrender  # noqa: E402

out = sys.argv[1]
os.environ.setdefault("QT_QPA_FONTDIR", os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"))  # offscreen Qt has no fonts otherwise
QApplication.setAttribute(Qt.ApplicationAttribute.AA_ShareOpenGLContexts)
app = QApplication(sys.argv)
tmp = tempfile.mkdtemp()
col = Collection(os.path.join(tmp, "test.anki2"))

# A small diagram image
img = QImage(300, 120, QImage.Format.Format_RGB32)
img.fill(QColor("white"))
p = QPainter(img)
p.setFont(QFont("Arial", 28))
p.drawRect(5, 5, 290, 110)
p.drawText(30, 75, "test diagram")
p.end()
img.save(os.path.join(col.media.dir(), "diagram.png"))

deck = col.decks.id("Physics")
lang = col.decks.id("Languages::French")
basic = col.models.by_name("Basic")
cloze = col.models.by_name("Cloze")
notes = [
    (basic, deck, {"Front": r"Mass–energy equivalence?", "Back": r"\(E = mc^2\)"}),
    (basic, deck, {"Front": "Gaussian integral", "Back": r"\[\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}\]"}),
    (basic, deck, {"Front": "What does this show?<br><img src=\"diagram.png\">", "Back": "A <b>test diagram</b>."}),
    (cloze, deck, {"Text": r"Newton's second law: {{c1::\(F = ma\)}}, where {{c2::m}} is mass."}),
    (basic, lang, {"Front": "le chat", "Back": "the cat"}),
    (basic, lang, {"Front": "la maison", "Back": "the house"}),
    (basic, lang, {"Front": "un livre", "Back": "a book"}),
]
for model, did, fields in notes:
    n = col.new_note(model)
    for k, v in fields.items():
        n[k] = v
    col.add_note(n, did)

# Make two French cards review cards due today/overdue and one a learning card, without revlog noise.
fr = col.find_cards('deck:"Languages::French"')
for cid, (typ, queue, due) in zip(fr, [(2, 2, col.sched.today), (2, 2, col.sched.today - 2)]):
    c = col.get_card(cid)
    c.type, c.queue, c.ivl, c.due, c.factor = typ, queue, 4, due, 2500
    col.update_card(c)

data = export.collect(col, days_ahead=4)
cache = mathrender.MathCache(os.path.join(tmp, "mathcache"))
mathrender.MathRenderer(os.path.join(HERE, "..", "addon", "kindle_review", "vendor")).render_missing(
    export.all_math(data), cache)
print(export.write_pack(col, data, out, cache, []))
col.close()
