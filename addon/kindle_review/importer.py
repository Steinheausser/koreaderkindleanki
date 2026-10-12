"""Replay answers recorded on the Kindle through Anki's own scheduler.

Collection-only work: safe to run in a background operation.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field

from anki.scheduler.v3 import CardAnswer

from . import common

RATINGS = {1: CardAnswer.AGAIN, 2: CardAnswer.HARD, 3: CardAnswer.GOOD, 4: CardAnswer.EASY}
LEDGER_KEEP_MS = 30 * 86400 * 1000


@dataclass
class ImportResult:
    applied: int = 0
    skipped: dict = field(default_factory=dict)  # entry id -> reason
    errors: list = field(default_factory=list)   # unreadable files


def read_entries(folder: str) -> tuple[dict[str, list[dict]], list[str]]:
    """{session file name: [entries]} for every Kindle review log, plus a list of read errors."""
    out, errors = {}, []
    rdir = os.path.join(folder, common.REVIEWS_DIR)
    if not os.path.isdir(rdir):
        return out, errors
    for name in sorted(os.listdir(rdir)):
        if not name.endswith(".jsonl"):
            continue
        entries = []
        try:
            with open(os.path.join(rdir, name), encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        entries.append(json.loads(line))
        except (OSError, ValueError) as e:
            errors.append("%s: %s" % (name, e))
            continue
        out[name] = entries
    return out, errors


class Ledger:
    """PC-side memory of what has been applied, kept in the add-on's user_files folder."""

    def __init__(self, path: str) -> None:
        self.path = path
        data = common.read_json(path, {}) or {}
        self.applied: dict[str, int] = data.get("applied", {})     # entry id -> answered_at_ms
        self.skipped: dict[str, str] = data.get("skipped", {})     # entry id -> reason
        self.our_revlog: dict[str, list[int]] = data.get("our_revlog", {})  # cid -> revlog ids we created

    def save(self) -> None:
        now = int(time.time() * 1000)
        cutoff = now - LEDGER_KEEP_MS
        self.applied = {k: v for k, v in self.applied.items() if v >= cutoff}
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        common.atomic_write_json(self.path, {
            "applied": self.applied, "skipped": self.skipped, "our_revlog": self.our_revlog})


def anki_day(col, ts_secs: float) -> int:
    """Anki day number a timestamp falls in (same rollover as col.sched.today)."""
    days_ago = int((col.sched.day_cutoff - 1 - ts_secs) // 86400)
    return col.sched.today - days_ago


def _conflict(col, cid: int, since_ms: int, ours: set[int]) -> bool:
    """True if the card was reviewed/rescheduled elsewhere after the pack was generated."""
    for (rid,) in col.db.all("select id from revlog where cid=? and id>?", cid, since_ms):
        if rid not in ours:
            return True
    return False


def apply_entries(col, folder: str, ledger: Ledger, backup=None) -> ImportResult:
    """Apply every not-yet-applied Kindle answer in time order. `backup` is called once before the first change."""
    res = ImportResult()
    sessions, res.errors = read_entries(folder)
    pending = [e for entries in sessions.values() for e in entries
               if e["id"] not in ledger.applied and e["id"] not in ledger.skipped]
    pending.sort(key=lambda e: (e["answered_at_ms"], e["id"]))
    backed_up = False

    for e in pending:
        cid = int(e["cid"])
        reason = None
        try:
            card = col.get_card(cid)
        except Exception:  # deleted on another device
            card, reason = None, "card no longer exists"
        if card is not None:
            ours = set(ledger.our_revlog.get(str(cid), []))
            if card.queue == -1:
                reason = "card is suspended"
            elif card.odid:
                reason = "card is in a filtered deck"
            elif _conflict(col, cid, int(e["pack_id"]), ours):
                reason = "card was reviewed elsewhere after the Kindle got it"
            elif e.get("rating") not in RATINGS:
                reason = "invalid rating"
        if reason:
            res.skipped[e["id"]] = reason
            ledger.skipped[e["id"]] = reason
            continue

        if not backed_up and backup is not None:
            backup()
            backed_up = True
        if card.queue in (-2, -3):  # buried (e.g. as a sibling of an earlier Kindle answer)
            col.sched.unbury_cards([cid])
            card.load()

        conf = col.decks.config_dict_for_deck_id(card.did)
        max_taken_ms = int(conf.get("maxTaken", 60)) * 1000
        states = col._backend.get_scheduling_states(cid)
        card.start_timer()  # build_answer reads the timer; the Kindle's time is set below
        answer = col.sched.build_answer(card=card, states=states, rating=RATINGS[e["rating"]])
        answer.answered_at_millis = int(e["answered_at_ms"])
        answer.milliseconds_taken = max(0, min(int(e.get("taken_ms", 0)), max_taken_ms))
        col.sched.answer_card(answer)

        # Anki computes intervals from *now*; move the due date back by the days the import was late.
        card.load()
        late = col.sched.today - anki_day(col, e["answered_at_ms"] / 1000)
        if late > 0 and card.queue in (2, 3):
            card.due -= late
            col.update_card(card, skip_undo_entry=True)

        new_ids = [rid for (rid,) in col.db.all(
            "select id from revlog where cid=? and id>=? order by id", cid, int(e["answered_at_ms"]))]
        known = set(ledger.our_revlog.get(str(cid), []))
        ledger.our_revlog[str(cid)] = sorted(known | set(new_ids))[-20:]
        ledger.applied[e["id"]] = int(e["answered_at_ms"])
        res.applied += 1

    ledger.save()
    return res


def write_ack(folder: str, ledger: Ledger) -> list[str]:
    """Tell the Kindle which of its entries are done (applied or permanently skipped)."""
    sessions, _ = read_entries(folder)
    present = {e["id"] for entries in sessions.values() for e in entries}
    applied = sorted(i for i in present if i in ledger.applied)
    skipped = {i: ledger.skipped[i] for i in present if i in ledger.skipped}
    common.atomic_write_json(os.path.join(folder, common.ACK_FILE), {
        "format": common.ACK_FORMAT,
        "updated_at": int(time.time() * 1000),
        "applied": applied,
        "skipped": skipped,
    })
    return applied
