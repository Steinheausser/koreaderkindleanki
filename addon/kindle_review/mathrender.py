"""Render MathJax (\\(...\\) and \\[...\\]) to standalone SVG files that KOReader's MuPDF can display.

MathJax runs in an off-screen QWebEnginePage (Anki only bundles the CHTML build, so the SVG build is vendored).
Must be used from the Qt main thread. Rendered SVGs are cached on disk by hash of (display, tex).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Callable, Iterable

MATH_RE = re.compile(r"\\\((.+?)\\\)|\\\[(.+?)\\\]", re.S)

# MathJax measures in ex; KOReader sizes the <img> in em. MathJax assumes 1ex = 0.5em.
EX_TO_EM = 0.5

_PAGE_HTML = """<!doctype html><html><head><meta charset="utf-8">
<script>window.MathJax = {svg: {fontCache: 'local'}, startup: {typeset: false}};</script>
<script src="tex-svg-full.js"></script>
<script>
function renderAll(items) {
  return items.map(function (it) {
    try {
      var node = MathJax.tex2svg(it[1], {display: it[0]});
      var svg = node.querySelector('svg');
      if (node.querySelector('[data-mjx-error]')) { return {error: 'TeX error'}; }
      return {svg: svg.outerHTML};
    } catch (e) { return {error: String(e)}; }
  });
}
</script></head><body></body></html>"""


def math_key(display: bool, tex: str) -> str:
    return hashlib.sha1(("D" if display else "I").encode() + tex.encode("utf-8")).hexdigest()[:16]


def find_math(html: str) -> list[tuple[bool, str]]:
    """Return (display, tex) for every MathJax formula in html."""
    out = []
    for m in MATH_RE.finditer(html):
        if m.group(1) is not None:
            out.append((False, m.group(1)))
        else:
            out.append((True, m.group(2)))
    return out


def _unescape_tex(tex: str) -> str:
    # Field HTML escapes these; MathJax wants the raw characters.
    return tex.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").replace("&nbsp;", " ")


def make_standalone_svg(svg: str) -> tuple[str, float, float, float]:
    """Turn MathJax inline SVG into a standalone file; return (svg, width_em, height_em, valign_em)."""
    def ex(attr: str, default: float = 0.0) -> float:
        m = re.search(attr + r'="(-?[\d.]+)ex"', svg)
        return float(m.group(1)) if m else default

    width, height = ex("width"), ex("height")
    m = re.search(r"vertical-align:\s*(-?[\d.]+)ex", svg)
    valign = float(m.group(1)) if m else 0.0
    svg = svg.replace("currentColor", "#000")
    # Absolute pixel size (16px em) so renderers that ignore ex units still get the aspect ratio right.
    svg = re.sub(r'width="[\d.]+ex"', 'width="%.2fpx"' % (width * EX_TO_EM * 16), svg, count=1)
    svg = re.sub(r'height="[\d.]+ex"', 'height="%.2fpx"' % (height * EX_TO_EM * 16), svg, count=1)
    svg = re.sub(r'\sstyle="[^"]*"', "", svg, count=1)
    if "xmlns:xlink" not in svg:
        svg = svg.replace("<svg ", '<svg xmlns:xlink="http://www.w3.org/1999/xlink" ', 1)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n' + svg,
            width * EX_TO_EM, height * EX_TO_EM, valign * EX_TO_EM)


class MathCache:
    """On-disk cache: <dir>/<key>.svg plus index.json with sizes."""

    def __init__(self, cache_dir: str) -> None:
        self.dir = cache_dir
        os.makedirs(cache_dir, exist_ok=True)
        self.index_path = os.path.join(cache_dir, "index.json")
        try:
            with open(self.index_path, encoding="utf-8") as f:
                self.index: dict[str, dict] = json.load(f)
        except (OSError, ValueError):
            self.index = {}

    def has(self, key: str) -> bool:
        return key in self.index and (
            "error" in self.index[key] or os.path.exists(self.svg_path(key)))

    def svg_path(self, key: str) -> str:
        return os.path.join(self.dir, key + ".svg")

    def store(self, key: str, raw_svg: str | None, error: str | None = None) -> None:
        if raw_svg is None:
            self.index[key] = {"error": error or "unknown"}
            return
        svg, w, h, v = make_standalone_svg(raw_svg)
        with open(self.svg_path(key), "w", encoding="utf-8") as f:
            f.write(svg)
        self.index[key] = {"w": round(w, 3), "h": round(h, 3), "v": round(v, 3)}

    def save(self) -> None:
        tmp = self.index_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.index, f)
        os.replace(tmp, self.index_path)


def replace_math(html: str, cache: MathCache, used: set[str]) -> str:
    """Replace formulas with <img> tags pointing at cached SVGs; record used SVG file names."""
    def sub(m: re.Match) -> str:
        display = m.group(1) is None
        tex = _unescape_tex(m.group(2) if display else m.group(1))
        key = math_key(display, tex)
        info = cache.index.get(key)
        if not info or "error" in info:
            return m.group(0)  # leave the source visible rather than dropping it
        name = "math-%s.svg" % key
        used.add(name)
        # Width and height both set: MuPDF keeps the aspect ratio exactly and scales with the font size.
        img = '<img class="mj" src="%s" style="width:%.3fem;height:%.3fem;vertical-align:%.3fem">' % (
            name, info["w"], info["h"], info["v"])
        return '<div class="mj-display" style="text-align:center">%s</div>' % img if display else img

    return MATH_RE.sub(sub, html)


class MathRenderer:
    """Renders TeX with MathJax in an off-screen web page. Qt main thread only."""

    def __init__(self, vendor_dir: str) -> None:
        from aqt.qt import QUrl, QWebEnginePage

        self._page = QWebEnginePage()
        self._loaded = False
        self._page.loadFinished.connect(self._on_loaded)
        base = QUrl.fromLocalFile(os.path.join(vendor_dir, ""))
        self._page.setHtml(_PAGE_HTML, base)

    def _on_loaded(self, ok: bool) -> None:
        self._loaded = ok

    def _wait(self, predicate: Callable[[], bool], timeout_ms: int) -> bool:
        from aqt.qt import QElapsedTimer, QEventLoop, QCoreApplication

        timer = QElapsedTimer()
        timer.start()
        while not predicate():
            if timer.elapsed() > timeout_ms:
                return False
            QCoreApplication.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 50)
        return True

    def render_missing(self, formulas: Iterable[tuple[bool, str]], cache: MathCache,
                       batch: int = 200) -> int:
        """Render every formula not yet in cache. Returns number rendered."""
        todo: dict[str, tuple[bool, str]] = {}
        for display, tex in formulas:
            tex = _unescape_tex(tex)
            key = math_key(display, tex)
            if not cache.has(key):
                todo[key] = (display, tex)
        if not todo:
            return 0
        if not self._wait(lambda: self._loaded, 30000):
            raise RuntimeError("MathJax page failed to load")
        keys = list(todo)
        for i in range(0, len(keys), batch):
            chunk = keys[i:i + batch]
            result: list = []
            done = [False]

            def cb(value, result=result, done=done):
                result.extend(value or [])
                done[0] = True

            items = json.dumps([[todo[k][0], todo[k][1]] for k in chunk])
            self._page.runJavaScript("renderAll(%s)" % items, cb)
            if not self._wait(lambda: done[0], 60000):
                raise RuntimeError("MathJax rendering timed out")
            for key, res in zip(chunk, result):
                cache.store(key, (res or {}).get("svg"), (res or {}).get("error"))
        cache.save()
        return len(todo)
