"""Build the card pack the Kindle reviews offline.

collect() and write_pack() only touch the collection/database, so they can run in a background operation.
Math rendering (mathrender.MathRenderer) needs the Qt main thread and runs between the two.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import time
from dataclasses import dataclass, field

from . import common, mathrender

_STRIP_RES = [
    re.compile(r"<script\b.*?</script>", re.S | re.I),
    re.compile(r"\[sound:[^\]]*\]"),
    re.compile(r"\[anki:[^\]]*\]"),
    re.compile(r"\[\[type:[^\]]*\]\]"),
    re.compile(r"<input\b[^>]*>", re.I),
    re.compile(r"\son\w+=(\"[^\"]*\"|'[^']*')", re.I),
]
_BIDI = re.compile("[⁦-⁩]")


def clean_html(html: str) -> str:
    for rx in _STRIP_RES:
        html = rx.sub("", html)
    return html


_IMG_RE = re.compile(r"<img\b[^>]*>", re.I)
_SRC_RE = re.compile(r"""\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""", re.I)
_PX_PER_EM = 16  # desktop Anki: images are shown at 1 CSS px per pixel with a 16px font


def size_images(html: str, media_dir: str) -> str:
    """Give images without explicit size an em-based width, so they scale with KOReader's font size
    (MuPDF would otherwise draw them at device pixels: tiny on a 300 dpi screen)."""
    from aqt.qt import QImageReader

    def sub(m: re.Match) -> str:
        tag = m.group(0)
        if re.search(r"\b(width|height|style)\s*=", tag, re.I):
            return tag
        src = _SRC_RE.search(tag)
        name = src and next(g for g in src.groups() if g is not None)
        if not name:
            return tag
        size = QImageReader(os.path.join(media_dir, name)).size()
        if not size.isValid() or size.width() <= 0:
            return tag
        style = ' style="width:%.2fem;max-width:100%%"' % (size.width() / _PX_PER_EM)
        return tag[:-2] + style + " />" if tag.endswith("/>") else tag[:-1] + style + ">"

    return _IMG_RE.sub(sub, html)


@dataclass
class PackData:
    today: int
    day_cutoff: int
    decks: dict = field(default_factory=dict)
    cards: list = field(default_factory=list)
    css: dict = field(default_factory=dict)
    media: set = field(default_factory=set)  # media file names referenced by exported cards


def _steps(delays) -> list[int]:
    """Deck-config steps (minutes) -> seconds."""
    return [int(round(float(d) * 60)) for d in delays or []]


def _deck_info(col, node, out: dict) -> None:
    for child in node.children:
        did = child.deck_id
        deck = col.decks.get(did, default=False)
        if deck and not deck.get("dyn"):
            conf = col.decks.config_dict_for_deck_id(did)
            out[str(did)] = {
                "name": col.decks.name(did),
                "new_today": child.new_count,
                "rev_today": child.review_count,
                "new_per_day": conf["new"]["perDay"],
                "rev_per_day": conf["rev"]["perDay"],
                "learn_steps": _steps(conf["new"]["delays"]),
                "relearn_steps": _steps(conf["lapse"]["delays"]),
                "bury_new": bool(conf["new"].get("bury")),
                "bury_rev": bool(conf["rev"].get("bury")),
                "bury_interday": bool(conf.get("buryInterdayLearning")),
            }
        _deck_info(col, child, out)


def _select_card_ids(col, days_ahead: int, decks: dict) -> list[int]:
    today = col.sched.today
    db = col.db
    ids = db.list(
        "select id from cards where odid=0 and ("
        " (queue=2 and due<=?) or queue=1 or (queue=3 and due<=?))"
        " order by due, id", today + days_ahead, today + days_ahead)
    # New cards: per deck, in position order, up to today's remaining + future days' allowance.
    taken: dict[int, int] = {}
    for cid, did in db.all("select id, did from cards where odid=0 and queue=0 order by due, ord, id"):
        info = decks.get(str(did))
        if info is None:
            continue
        cap = info["new_today"] + info["new_per_day"] * days_ahead
        if taken.get(did, 0) < cap:
            taken[did] = taken.get(did, 0) + 1
            ids.append(cid)
    return ids


def collect(col, days_ahead: int) -> PackData:
    data = PackData(today=col.sched.today, day_cutoff=col.sched.day_cutoff)
    _deck_info(col, col.sched.deck_due_tree(), data.decks)
    for cid in _select_card_ids(col, days_ahead, data.decks):
        card = col.get_card(cid)
        if str(card.did) not in data.decks:
            continue
        out = card.render_output()
        note = card.note()
        mid = str(note.mid)
        if mid not in data.css:
            data.css[mid] = out.css
        media_dir = col.media.dir()
        q = size_images(clean_html(out.question_text), media_dir)
        a = size_images(clean_html(out.answer_text), media_dir)
        for html in (q, a):
            data.media.update(col.media.files_in_str(note.mid, html))
        states = col._backend.get_scheduling_states(card.id)
        labels = [_BIDI.sub("", s) for s in col.sched.describe_next_states(states)]
        rec = {
            "cid": card.id, "nid": card.nid, "did": card.did, "mid": mid,
            "queue": card.queue, "type": card.type, "mod": card.mod,
            "left": card.left % 1000, "labels": labels, "q": q, "a": a,
        }
        if card.queue == 1:
            rec["due_at"] = card.due  # epoch seconds
        elif card.queue in (2, 3):
            rec["due_day"] = card.due - data.today  # days from export day; <= 0 means due today
        else:
            rec["new_pos"] = card.due
        data.cards.append(rec)
    return data


def all_math(data: PackData) -> list[tuple[bool, str]]:
    out = []
    for c in data.cards:
        out += mathrender.find_math(c["q"]) + mathrender.find_math(c["a"])
    return out


def _file_hash(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _sync_media(src_files: dict[str, str], media_dir: str) -> int:
    """Make media_dir contain exactly src_files {name: source path}; returns files copied."""
    copied = 0
    for name, src in src_files.items():
        dst = os.path.join(media_dir, name)
        if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src) and _file_hash(dst) == _file_hash(src):
            continue
        tmp = dst + ".tmp"
        shutil.copyfile(src, tmp)
        os.replace(tmp, dst)
        copied += 1
    for name in os.listdir(media_dir):
        if name not in src_files and not name.endswith(".tmp"):
            os.remove(os.path.join(media_dir, name))
    return copied


def write_pack(col, data: PackData, folder: str, math_cache: mathrender.MathCache | None,
               applied_ids: list[str]) -> dict:
    """Write pack/media/*, then pack/cards-<pack_id>.bin, then pack/pack.json (all atomically) into the exchange folder."""
    common.ensure_layout(folder)
    used_math: set[str] = set()
    if math_cache is not None:
        for c in data.cards:
            c["q"] = mathrender.replace_math(c["q"], math_cache, used_math)
            c["a"] = mathrender.replace_math(c["a"], math_cache, used_math)

    col_media = col.media.dir()
    files = {n: os.path.join(col_media, n) for n in data.media if os.path.isfile(os.path.join(col_media, n))}
    if math_cache is not None:
        for n in used_math:
            files[n] = math_cache.svg_path(n[len("math-"):-len(".svg")])
    media_dir = os.path.join(folder, common.PACK_DIR, common.MEDIA_DIR)
    copied = _sync_media(files, media_dir)

    pack_dir = os.path.join(folder, common.PACK_DIR)
    now_ms = int(time.time() * 1000)
    while os.path.exists(os.path.join(pack_dir, _cards_name(str(now_ms)))):  # same-millisecond rewrite
        now_ms += 1
    pack_id = str(now_ms)
    cards_name = _cards_name(pack_id)

    # Cards' HTML goes to a side file the Kindle reads one slice at a time: q then a per card, no separators.
    blob = bytearray()
    records = []
    for c in data.cards:
        q, a = c["q"].encode("utf-8"), c["a"].encode("utf-8")
        rec = {k: v for k, v in c.items() if k not in ("q", "a")}
        rec["qo"], rec["ql"] = len(blob), len(q)
        blob += q
        rec["ao"], rec["al"] = len(blob), len(a)
        blob += a
        records.append(rec)
    common.atomic_write_bytes(os.path.join(pack_dir, cards_name), bytes(blob))

    pack = {
        "format": common.FORMAT,
        "pack_id": pack_id,
        "generated_at": now_ms,
        "today": data.today,
        "day_cutoff": data.day_cutoff,
        "applied": applied_ids,
        "cards_file": cards_name,
        "decks": data.decks,
        "css": data.css,
        "cards": records,
    }
    common.atomic_write_json(os.path.join(pack_dir, common.PACK_FILE), pack)
    _prune_cards_files(pack_dir, cards_name)
    return {"cards": len(data.cards), "media_copied": copied, "media_total": len(files)}


def _cards_name(pack_id: str) -> str:
    return common.CARDS_PREFIX + pack_id + common.CARDS_SUFFIX


def _prune_cards_files(pack_dir: str, current: str) -> None:
    """Keep the current cards file plus the newest previous one (a Kindle may still be reading it); delete the rest."""
    def pack_id_of(name: str) -> int:
        digits = name[len(common.CARDS_PREFIX):-len(common.CARDS_SUFFIX)]
        return int(digits) if digits.isdigit() else -1

    others = sorted((n for n in os.listdir(pack_dir)
                     if n.startswith(common.CARDS_PREFIX) and n.endswith(common.CARDS_SUFFIX) and n != current),
                    key=lambda n: (pack_id_of(n), n))
    for name in others[:-1]:
        try:
            os.remove(os.path.join(pack_dir, name))
        except OSError:  # e.g. still open by Syncthing; the next export retries
            pass
