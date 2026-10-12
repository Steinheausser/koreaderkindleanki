"""Shared constants and file helpers for the Kindle exchange folder."""

from __future__ import annotations

import json
import os

FORMAT = 2  # pack.json format; cards' HTML lives in pack/cards-<pack_id>.bin (see export.write_pack)
ACK_FORMAT = 1  # ack.json format: independent of the pack format
CARDS_PREFIX = "cards-"
CARDS_SUFFIX = ".bin"
PACK_DIR = "pack"
PACK_FILE = "pack.json"
MEDIA_DIR = "media"
REVIEWS_DIR = "reviews"
ACK_FILE = "ack.json"
STIGNORE = ".stignore"
STIGNORE_CONTENT = "// Written by the Anki kindle_review add-on: never sync half-written files\n*.tmp\n"


def atomic_write_bytes(path: str, data: bytes) -> None:
    """Write to <path>.tmp then rename, so Syncthing (which ignores *.tmp) never sees a partial file."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def atomic_write_json(path: str, obj) -> None:
    atomic_write_bytes(path, json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def read_json(path: str, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def ensure_layout(folder: str) -> None:
    os.makedirs(os.path.join(folder, PACK_DIR, MEDIA_DIR), exist_ok=True)
    os.makedirs(os.path.join(folder, REVIEWS_DIR), exist_ok=True)
    stignore = os.path.join(folder, STIGNORE)
    if not os.path.exists(stignore):
        with open(stignore, "w", encoding="utf-8") as f:
            f.write(STIGNORE_CONTENT)
