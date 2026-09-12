# Bible for Omarchy

An [Omarchy](https://omarchy.org) (Quickshell) bar-widget plugin (id: `bible`)
with a two-tab panel: a **Verse of the Day** widget and an offline **Bible**
search and reader. A book icon sits in the bar; left-clicking it toggles the
panel:

- **Verse** — the day's Bible verse, resolved locally from the bundled
  translations. A random verse is picked from the entire KJV canon via an
  FNV-1a hash of a `Date.now()` millisecond seed. The pick stays stable all day
  (cached as `{date, reference}` in `bible-state.json`), is re-picked at
  midnight, and is resolved in the currently-selected translation with omitted
  verses skipped.
- **Bible** — search and read the selected translation. This tab holds both the
  search box and the offline reader. Search is debounced (160ms), matching by
  word, phrase, or reference; results come back in reference order (no
  relevance scoring). References like `John 3:16`, `Genesis 1`, `3:16` (against
   the current book), or `gen 1` (abbreviations work) resolve directly.

## Install

```sh
omarchy plugin add https://github.com/phoscoder/omarchy-bible-strongs --enable
```

The plugin is fully offline — no network request is made at runtime.

## Usage

- **Click** a verse to copy it. Copies carry a source referral.
- **Bible tab:** type to search (debounced). `↑`/`↓` move the
  selection, `Enter` opens the selected result, `Esc` returns focus from the
  search field, then `Esc` closes the panel. Bible results come back in
  reference order.
- **Bible tab (reader):** with the search box empty, the reader shows. `←`/`→`
  step to the previous/next chapter, `↑`/`↓` move between verses, and `Enter`
  saves the reading position.
- **Strong's numbers (KJV only):** the reader header shows an **S** button when
  the translation is the KJV. Toggle it to render tiny superscript Strong's
  numbers after each word; click a number to open its dictionary card (lemma,
  transliteration, pronunciation, derivation, Strong's definition, and KJV
  renderings). `Esc` (or a click outside) closes the card. The toggle is
  remembered in `bible-state.json`. Verses where the tagged edition could not
  be aligned fall back to plain text. Data loads lazily — only when the
  toggle is on.
- **Clicking** the reader header title/subtitle or the blank space below the
  last verse clears search focus.
- `Tab` / `Shift+Tab` switches to the neighbouring bar panel.

## Configuration

The plugin has no external settings. The translation used by the Verse of the
Day and the Bible tab defaults to `dr` (Douay-Rheims) and is shared across all
tabs. Switch it at any time with the translation dropdown in the panel header;
the choice is remembered in `bible-state.json` (see Data and privacy).

## Data and privacy

Five translations are bundled:

- The Douay-Rheims Bible (Challoner revision) is public domain; bundled as
  `data/dr.json` (73 books of the Catholic canon).
- The Catholic Public Domain Version is public domain; bundled as
  `data/cpdv.json` (73 books of the Catholic canon).
- The King James Version is public domain; bundled as `data/kjv.json`.
- The World English Bible is public domain; bundled as `data/web.json`.
- The Berean Standard Bible (CC0 1.0, public domain) is bundled as
  `data/bsb.json`.

State is saved under `~/.local/state/omarchy/settings/`:

- `bible-state.json` — the Bible reading position (book/chapter/verse +
  translation), the day's verse pick (`verseOfDay`), and the Strong's numbers
  toggle (`strongsNumbers`).
- `bible-tab-state.json` — the last-opened tab (defaults to Verse on first
  run).

The plugin does not request elevated privileges, runs no background services,
and starts no second Quickshell process.

See [NOTICE.md](NOTICE.md) for sources and licensing of the bundled data.

## Development checks

```sh
omarchy plugin validate .
node tests/test_bibles.js
node tests/test_canon.js
node tests/test_strongs.js
node --check search.js SearchWorker.js References.js scripts/convert-strongs.js
qmllint -I "$OMARCHY_PATH/shell" Panel.qml Service.qml components/StrongsPopup.qml
```

Note: `qmllint` on `BarWidget.qml` may exit 255 due to a Quickshell tooling
limitation — expected, not a regression. `ReaderModel.js` fails `node --check`
on `.pragma library` — expected, not an error.

## Remove

```sh
omarchy plugin remove bible-strongs
```

## Credits & Fork Notice

This project was forked from
[ronald2wing/Omarchy-Bible](https://github.com/ronald2wing/Omarchy-Bible).
Special thanks to [@ronald2wing](https://github.com/ronald2wing) for laying
the foundation — the original plugin architecture, the Verse of the Day and
offline reader design, and the bundled translations. This fork extends the
original with Strong's numbers support in the KJV reader.

## License

Plugin code is MIT licensed. See [LICENSE](LICENSE). Data sources are covered
in [NOTICE.md](NOTICE.md).
