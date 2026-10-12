"""Kindle review: offline Anki reviews in KOReader, exchanged through a Syncthing folder.

Imports answers recorded on the Kindle (replayed through Anki's scheduler), then exports a fresh pack of due cards.
"""

from __future__ import annotations

import os

from aqt import gui_hooks, mw

if mw is not None:  # not when the logic modules are imported by tests
    from anki.collection import OpChanges
    from aqt.operations import CollectionOp, QueryOp
    from aqt.qt import QAction
    from aqt.utils import showWarning, tooltip

    from . import export, importer, mathrender

    ADDON_DIR = os.path.dirname(os.path.abspath(__file__))
    USER_FILES = os.path.join(ADDON_DIR, "user_files")
    _state = {"running": False, "renderer": None, "timer": None}

    def _config() -> dict:
        return mw.addonManager.getConfig(__name__) or {}

    def _done(msg: str | None = None, error: str | None = None, manual: bool = False) -> None:
        _state["running"] = False
        if error:
            if manual:
                showWarning("Kindle review: " + error)
            else:
                tooltip("Kindle review: " + error, period=6000)
        elif msg and (manual or "imported" in msg):
            tooltip(msg, period=5000)

    def run(manual: bool = False) -> None:
        cfg = _config()
        folder = (cfg.get("folder") or "").strip()
        if mw.col is None or _state["running"]:
            return
        if not cfg.get("enabled", True) and not manual:
            return
        if not folder or not os.path.isdir(folder):
            if manual:
                showWarning("Kindle review: set \"folder\" in Tools → Add-ons → Kindle review → Config "
                            "to your Syncthing 'anki-kindle' folder.")
            return
        _state["running"] = True
        result: dict = {}

        def do_import(col) -> OpChanges:
            ledger = importer.Ledger(os.path.join(USER_FILES, "ledger.json"))

            def backup() -> None:
                col.create_backup(backup_folder=mw.pm.backupFolder(), force=True, wait_for_completion=True)

            res = importer.apply_entries(col, folder, ledger, backup)
            result["import"] = res
            result["applied_ids"] = importer.write_ack(folder, ledger)
            return OpChanges(card=True, study_queues=True, browser_table=True)

        def after_import(_changes) -> None:
            QueryOp(parent=mw, op=lambda col: export.collect(col, int(cfg.get("days_ahead", 4))),
                    success=after_collect).failure(fail).run_in_background()

        def after_collect(data) -> None:
            cache = mathrender.MathCache(os.path.join(USER_FILES, "mathcache"))
            try:
                if _state["renderer"] is None:
                    _state["renderer"] = mathrender.MathRenderer(os.path.join(ADDON_DIR, "vendor"))
                _state["renderer"].render_missing(export.all_math(data), cache)
            except Exception as e:  # math stays as TeX source on the Kindle
                result["math_error"] = str(e)
            QueryOp(parent=mw,
                    op=lambda col: export.write_pack(col, data, folder, cache, result["applied_ids"]),
                    success=after_write).failure(fail).run_in_background()

        def after_write(stats) -> None:
            res: importer.ImportResult = result["import"]
            parts = []
            if res.applied:
                parts.append("%d Kindle reviews imported" % res.applied)
            if res.skipped:
                parts.append("%d skipped (%s)" % (len(res.skipped), "; ".join(sorted(set(res.skipped.values())))))
            if res.errors:
                parts.append("unreadable: " + ", ".join(res.errors))
            parts.append("%d cards exported" % stats["cards"])
            if result.get("math_error"):
                parts.append("math not rendered: " + result["math_error"])
            _done("Kindle review: " + ", ".join(parts), manual=manual)
            if res.applied and cfg.get("sync_after_import", True) and mw.pm.sync_auth():
                mw.on_sync_button_clicked()

        def fail(exc: Exception) -> None:
            _done(error=str(exc), manual=manual)

        CollectionOp(parent=mw, op=do_import).success(after_import).failure(fail).run_in_background()

    def _on_timer() -> None:
        if mw.state != "review":  # don't reshuffle the queue under someone reviewing in Anki
            run(False)

    def _on_profile_open() -> None:
        minutes = int(_config().get("auto_interval_minutes", 10))
        if minutes > 0 and _state["timer"] is None:
            _state["timer"] = mw.progress.timer(minutes * 60 * 1000, _on_timer, True, parent=mw)
        mw.progress.single_shot(5000, lambda: run(False))

    def _setup_menu() -> None:
        action = QAction("Kindle review: import && export now", mw)
        action.triggered.connect(lambda: run(True))
        mw.form.menuTools.addAction(action)

    gui_hooks.profile_did_open.append(_on_profile_open)
    gui_hooks.sync_did_finish.append(lambda: run(False))
    _setup_menu()
