# koreaderkindleanki

Review your Anki cards **offline on a jailbroken Kindle in KOReader**, with real spaced repetition, and have
every answer end up in your Anki collection and on AnkiWeb.

```
Anki Desktop + kindle_review add-on  ──►  Syncthing folder "anki-kindle"  ◄──  KOReader + ankireview.koplugin
  exports due cards, applies Kindle          pack/  (PC → Kindle)                 reviews offline, logs answers
  answers via Anki's own scheduler,          reviews/ (Kindle → PC)
  then syncs to AnkiWeb as usual             ack.json (PC → Kindle)
```

The Kindle never talks to AnkiWeb (only official Anki clients may), so your AnkiWeb account is not at risk.
Anki Desktop does the real scheduling: the Kindle only records which button you pressed and when, and the
add-on replays those answers through Anki's scheduler (SM-2 or FSRS, whatever your decks use).

Also included: [`kindle-mtp-fix/`](#bonus-usb-file-transfer-mtp-while-koreader-runs), a fix that lets
newer (MTP) Kindles keep USB file transfer working while KOReader is running.

## What you need
- **A jailbroken Kindle with [KOReader](https://koreader.rocks/)**. Developed on a Kindle Basic (FW 5.18) with
  KOReader 2026.07; any recent KOReader should work.
- **[Syncthing](https://syncthing.net/) on both sides. This is required: it is the only link between the PC
  and the Kindle.**
  - Kindle: KOReader's built-in *Syncthing* plugin (in the Tools menu). Set it up and pair it with your PC
    once.
  - PC: Syncthing itself, or a wrapper such as SyncTrayzor or Syncthing Tray.
  - The two only need to be on the same network now and then; reviewing works fully offline.
- **Anki Desktop** (tested with 25.09 and 26.9), logged in to AnkiWeb if you want answers synced there.
- **Your PC must run Anki now and then**. It applies the Kindle's answers and refreshes the cards when it runs.

## Setup
1. **Syncthing folder.** On the PC create a folder, e.g. `C:\Users\<you>\anki-kindle`, and add it in Syncthing
   with folder ID **`anki-kindle`** (the Kindle's *Sync with PC* button uses this ID). Share it with the Kindle
   and accept it there at **`/mnt/us/anki-kindle`**. Put a `.stignore` containing `*.tmp` in the folder on
   both sides.
2. **Anki add-on.**
   - Copy `addon/kindle_review` into Anki's add-ons folder: *Tools → Add-ons → View Files*.
   - Restart Anki.
   - Open *Tools → Add-ons → kindle_review → Config* and set `folder` to the PC folder from step 1.
     Options are explained in [`config.md`](addon/kindle_review/config.md).
3. **KOReader plugin.**
   - Copy `koplugin/ankireview.koplugin` to `/mnt/us/koreader/plugins/` on the Kindle, over USB or SSH.
   - Restart KOReader.
   - A new **Anki review** tab (cards with a check mark) appears in the top menu, next to Tools.
4. **First run.** Open Anki on the PC. The add-on writes the card pack, and Syncthing carries it to the Kindle.

## Using it
**On the Kindle**, use the *Anki review* tab:
- *Review all decks* or *Decks* → pick a deck. Tap the card (or *Show answer*), then Again / Hard / Good / Easy.
  The menu icon at the top left has Undo, card font size and Refresh. Page-turn keys also work:
  forward = show answer / Good, back = Undo.
- Deck rows show `new · learn · review` counts; decks with nothing due are under *Finished decks*. The title
  bar warns when the cards are a day or more old.
- *Card font size* sets the text size for cards (images and math scale with it).
- *Sync with PC* starts KOReader's Syncthing if needed and syncs with the PC (Wi-Fi must be on).
- *Status* shows how old the cards are and how many answers haven't reached Anki yet.
- *Exchange folder* lets you pick a different folder than `/mnt/us/anki-kindle`.

**On the PC**, just run Anki.
- The add-on runs when your profile opens, after every sync, and every 10 minutes.
- *Tools → Kindle review: import & export now* forces a run.
- A tooltip reports how many answers were applied or skipped. After applying answers it starts a normal
  AnkiWeb sync.

The pack covers the next 4 days by default (`days_ahead`), so you can review offline for that long.
What it includes:
- reviews due in that window
- learning cards
- new cards, up to each deck's daily limit

Math (MathJax `\( \)` / `\[ \]`) is pre-rendered to SVG on the PC. Images are copied over.

## Known limitations
- Intraday learning steps are approximated on the Kindle; the PC's replay is authoritative.
- FSRS sees the import day as the review day when counting elapsed days. Due dates are corrected for this.
- If a card was reviewed elsewhere (phone, desktop) after the pack was made, its Kindle answer is skipped and
  reported, never applied twice.
- Not supported: audio, type-in answers and card JavaScript. Parent-deck limits are approximated per deck.
- A cloze *inside* math whose closing `}}` collides with TeX braces (e.g. `{{c1::\frac{a}{b}}}`) stays as TeX
  source. Such clozes are malformed in Anki too; add a space before `}}` to fix them.

## How it works
### File formats (`"format": 2`; the plugin also reads format 1)
- **`pack/pack.json`**, written by the PC:
  - `pack_id`, `generated_at` (ms).
  - `today` and `day_cutoff`: Anki's day number and rollover time, so the Kindle needs no timezone.
  - `applied`: ids of Kindle answers already reflected in the pack.
  - `decks`: today's remaining and per-day limits, learning/relearning steps in seconds, bury flags.
  - `css`: one stylesheet per note type.
  - `cards`: `cid nid did mid queue type mod left labels`, plus `due_day` / `due_at` / `new_pos`, and
    `qo ql ao al`: byte offset and length of the question and answer HTML in `cards_file`.
  - `cards_file`: `cards-<pack_id>.bin`, all cards' HTML concatenated, written before `pack.json`. Keeping
    the HTML out of the JSON makes the pack load several times faster on the Kindle. The PC keeps the
    previous one too, and the Kindle keeps using its current pack until a new pack's file has fully arrived.
  - Math is pre-rendered to `pack/media/math-*.svg`; images are copied to `pack/media/`.
- **`reviews/<device>-<session>.jsonl`**, written by the Kindle:
  - One answer per line: `id cid rating answered_at_ms taken_ms pack_id`.
  - The file is rewritten atomically after every answer.
- **`ack.json`**, written by the PC:
  - The answer ids it applied, and any it skipped, with a reason.
  - The Kindle deletes a session log once the pack reflects all of its answers.

Each file has exactly one writer, and every write goes to `*.tmp` and is then renamed, so Syncthing never
produces conflict copies.

### Applying answers
For each new answer, oldest first, the add-on:
1. Checks in the revlog that the card wasn't reviewed elsewhere after the pack was made.
2. Calls `get_scheduling_states`, then `build_answer`.
3. Sets the Kindle's answer time and time taken.
4. Calls `answer_card`.

Anki computes intervals from the import time, so review-card due dates are moved back by the number of days
the import was late. A collection backup is made before the first change of each run. Applied ids are kept in
the add-on's `user_files/ledger.json`, so nothing is ever applied twice.

## Tests
```bash
# Add-on logic, against throwaway collections. Use the Python from your Anki install (or `pip install aqt`
# matching your Anki version) so the anki/aqt modules are importable.
QT_QPA_PLATFORM=offscreen python -m unittest discover -s tests
# Plugin scheduler, run on the Kindle with KOReader's LuaJIT
/mnt/us/koreader/luajit tests/test_scheduler.lua koplugin/ankireview.koplugin
```
Helpers for when you change rendering or scheduling:
- `tests/make_test_pack.py` builds a pack from a throwaway collection.
- `tests/render_cards.lua` renders every card the way the reviewer does.
- `tests/test_store.lua` (pack/log storage) and `tests/headless_ui.lua` (drives the real reviewer widgets
  off-screen) run on the Kindle; `tests/make_format2.lua` converts a format-1 pack.
- `tests/bench_pack.lua` times operations on a real pack, read-only.

## Bonus: USB file transfer (MTP) while KOReader runs
On Kindles that use MTP for USB (newer models and firmware), KOReader normally disables USB file transfer
while it is running. [`kindle-mtp-fix/`](kindle-mtp-fix) lets you have both.

How it works:
- The launcher starts KOReader in a private mount namespace, where `/mnt/us` is the real filesystem rather
  than Amazon's FUSE proxy (which locks up during an MTP session).
- A KOReader user patch lets the USB daemon run again.

To install it, copy the folder to the Kindle and run `sh apply-kindle-mtp-fix.sh` as root over SSH. It is safe
to re-run, for example after reinstalling KOReader. It assumes KOReader is launched through KMC/kpm
(`documents/KOReader.sh`) and leaves the launcher alone if it doesn't look as expected. A backup is kept at
`/mnt/us/koreader/KOReader.sh.pre-mtp-fix`.

Use it at your own risk: it changes how a system service behaves on a jailbroken device.

## License
MathJax (`addon/kindle_review/vendor/`) is Apache-2.0; see its license file.
