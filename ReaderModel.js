.pragma library
.import "search.js" as Search

// Translation-agnostic reader model. All book/chapter/verse logic is driven by
// the parsed `bible` object ({ translation, books: [{ id, name, testament,
// chapters: [[verse, ...]] }] }), so it works for any canon (66-book
// Protestant or 73-book Catholic). Reference parsing (book aliases and place
// resolution) lives in search.js so the panel and the search worker share it.

var OMITTED_VERSE_LABEL = "Not included in this translation."
var DEFAULT_BOOK = "Genesis"
var DEFAULT_CHAPTER = 1
var DEFAULT_VERSE = 1

// Memoized id -> book lookup. Each parsed bible object gets its own map so the
// O(73) scan in bookById runs once per bible instead of on every caller
// (formatRef, isValidPlace, chapterCount, verseCount, nextChapter, prevChapter,
// …). The cache is stored as a non-enumerable own property of the bible
// object: skipped by JSON.stringify (so what goes to the search worker is
// unchanged), invisible to for-in / Object.keys, and freed with the bible.
// (A WeakMap was avoided: QV4's WeakMap key lookup has been observed to
// segfault — QV4::Value::sameValueZero — in quickshell 0.3.1 / Qt 6.11.2.)
var _bookByIdCacheKey = "_bookByIdCache"

function _setBookByIdCache(bible, map) {
  Object.defineProperty(bible, _bookByIdCacheKey, {
    value: map, enumerable: false, writable: true, configurable: true
  })
}

function bookById(bible, id) {
  if (!bible || !bible.books) return null
  var map = bible[_bookByIdCacheKey]
  if (map === undefined) {
    map = Object.create(null)
    for (var i = 0; i < bible.books.length; i++) {
      map[bible.books[i].id] = bible.books[i]
    }
    _setBookByIdCache(bible, map)
  }
  return map[id] || null
}

function booksForTestament(bible, testament) {
  var out = []
  if (!bible || !bible.books) return out
  for (var i = 0; i < bible.books.length; i++) {
    if (bible.books[i].testament === testament) out.push(bible.books[i])
  }
  return out
}

function chapterCount(bible, id) {
  var book = bookById(bible, id)
  return book ? book.chapters.length : 0
}

function isValidPlace(bible, bookId, chapter, verse) {
  var book = bookById(bible, bookId)
  if (!book) return false
  if (typeof chapter !== "number" || chapter < 1 || chapter > book.chapters.length || Math.floor(chapter) !== chapter)
    return false
  if (verse === undefined || verse === null) return true
  return typeof verse === "number" && verse >= 1 && Math.floor(verse) === verse
}

function verseObjectsFor(bible, bookId, chapter) {
  var book = bookById(bible, bookId)
  if (!book) return []
  var ch = book.chapters[chapter - 1]
  if (!ch) return []
  var out = []
  for (var v = 0; v < ch.length; v++) {
    var text = typeof ch[v] === "string" ? ch[v].trim() : ""
    var omitted = text === ""
    out.push({
      verse: v + 1,
      text: omitted ? OMITTED_VERSE_LABEL : text,
      omitted: omitted
    })
  }
  return out
}

function verseCount(bible, bookId, chapter) {
  // Read the chapter array length directly instead of building the full verse
  // array (with per-verse trim) just to count it. Chapters are 0-indexed by
  // chapter-1, matching verseObjectsFor/resolveText.
  var book = bookById(bible, bookId)
  if (!book) return 0
  var ch = book.chapters[chapter - 1]
  return ch ? ch.length : 0
}

function clampVerse(bible, bookId, chapter, verse) {
  var count = verseCount(bible, bookId, chapter)
  if (count <= 0) return 1
  var n = typeof verse === "number" && Math.floor(verse) === verse ? verse : 1
  if (n < 1) return 1
  if (n > count) return count
  return n
}

// Parse a "book chapter[:verse]" (or "bookchapter" glued) string into a
// { book, chapter, verse } place, or null if it does not resolve in the given
// bible. Delegates to the canonical parser in search.js.
function parsePlace(input, bible) {
  return Search.parsePlace(input, bible)
}

function formatRef(bible, bookId, chapter, verse) {
  var book = bookById(bible, bookId)
  var name = book ? book.name : (bookId || "")
  if (!chapter) return name || "Bible"
  if (!verse) return name + " " + chapter
  return name + " " + chapter + ":" + verse
}

// Parse and validate a reference down to a single existing verse: parsePlace
// only checks that the chapter exists, so this additionally rejects a verse
// beyond the end of the chapter.
function resolvePlace(input, bible) {
  var place = parsePlace(input, bible)
  if (!place) return null
  var count = verseCount(bible, place.book, place.chapter)
  if (count <= 0 || place.verse > count) return null
  return place
}

// Index of a book by id within a bible, or -1 when absent.
function _bookIndex(bible, bookId) {
  for (var i = 0; i < bible.books.length; i++) {
    if (bible.books[i].id === bookId) return i
  }
  return -1
}

function nextChapter(bible, bookId, chapter) {
  if (!bible || !bible.books || bible.books.length === 0)
    return { book: DEFAULT_BOOK, chapter: DEFAULT_CHAPTER }
  var idx = _bookIndex(bible, bookId)
  if (idx < 0) return { book: DEFAULT_BOOK, chapter: DEFAULT_CHAPTER }
  var book = bible.books[idx]
  if (chapter < book.chapters.length) return { book: bookId, chapter: chapter + 1 }
  var next = bible.books[(idx + 1) % bible.books.length]
  return { book: next.id, chapter: 1 }
}

function prevChapter(bible, bookId, chapter) {
  if (!bible || !bible.books || bible.books.length === 0)
    return { book: DEFAULT_BOOK, chapter: DEFAULT_CHAPTER }
  var idx = _bookIndex(bible, bookId)
  if (idx < 0) return { book: DEFAULT_BOOK, chapter: DEFAULT_CHAPTER }
  if (chapter > 1) return { book: bookId, chapter: chapter - 1 }
  var prevIdx = (idx - 1 + bible.books.length) % bible.books.length
  var prev = bible.books[prevIdx]
  return { book: prev.id, chapter: prev.chapters.length }
}

// Return the first non-omitted verse after `place` ({ book, chapter, verse }),
// advancing verse -> chapter -> book and wrapping around the canon. The daily
// verse fallback uses this when the picked verse is omitted in the current
// translation; returns null if the whole bible has no non-omitted verse.
function firstNonOmittedVerseAfter(bible, place) {
  if (!bible || !bible.books || !place) return null
  var start = _bookIndex(bible, place.book)
  if (start < 0) return null
  for (var bi = 0; bi < bible.books.length; bi++) {
    var book = bible.books[(start + bi) % bible.books.length]
    var firstChapter = bi === 0 ? place.chapter : 1
    for (var c = firstChapter; c <= book.chapters.length; c++) {
      var ch = book.chapters[c - 1]
      var firstVerse = (bi === 0 && c === place.chapter) ? place.verse + 1 : 1
      for (var v = firstVerse; v <= ch.length; v++) {
        var t = ch[v - 1]
        if (typeof t === "string" && t.trim() !== "") {
          return { book: book.id, chapter: c, verse: v }
        }
      }
    }
  }
  return null
}

function initialPlaceForBook(bible, bookId) {
  var book = bookById(bible, bookId)
  if (!book) return null
  return { book: bookId, chapter: DEFAULT_CHAPTER, verse: DEFAULT_VERSE }
}

// Vulgate psalm numbering applies to DR/CPDV. The `translation` field is
// lowercase ("dr"/"cpdv"); normalize defensively in case a stale cached bible
// object or regenerated file still carries an uppercase code.
function usesVulgateNumbering(bible) {
  if (!bible || typeof bible.translation !== "string") return false
  var t = bible.translation.toLowerCase()
  return t === "dr" || t === "cpdv"
}

// Hebrew (Masoretic/protestant) psalm chapter -> Vulgate numbering. Only the
// psalm chapters that diverge between the two numberings are remapped; the
// rest are identical and pass through unchanged.
function _hebrewPsalmToVulgate(h) {
  if (h >= 1 && h <= 8) return h
  if (h === 9 || h === 10) return 9
  if (h >= 11 && h <= 113) return h - 1
  if (h === 114 || h === 115) return 113
  if (h === 116) return 114
  if (h >= 117 && h <= 146) return h - 1
  if (h === 147) return 146
  return h
}

// Vulgate psalm chapter -> Hebrew numbering (inverse of _hebrewPsalmToVulgate).
function _vulgatePsalmToHebrew(v) {
  if (v >= 1 && v <= 8) return v
  if (v === 9) return 9
  if (v >= 10 && v <= 112) return v + 1
  if (v === 113) return 114
  if (v === 114 || v === 115) return 116
  if (v >= 116 && v <= 145) return v + 1
  if (v === 146 || v === 147) return 147
  return v
}

// Map a reading place ({ book, chapter, verse }) from one translation's canon
// and psalm numbering to the equivalent place in another translation, or null
// when there is no equivalent (book absent, or chapter out of range after the
// psalm remap). The verse is clamped to the target chapter and advanced past
// an omitted target cell so the reader never lands on "Not included".
function equivalentPlace(sourceBible, targetBible, place) {
  if (!sourceBible || !targetBible || !place) return null
  var targetBook = Search.bookByName(targetBible, place.book)
  if (!targetBook) return null
  var chapter = place.chapter
  var verse = place.verse
  if (targetBook.id === "Psalms" && usesVulgateNumbering(sourceBible) !== usesVulgateNumbering(targetBible)) {
    chapter = usesVulgateNumbering(sourceBible) ? _vulgatePsalmToHebrew(chapter) : _hebrewPsalmToVulgate(chapter)
  }
  if (typeof chapter !== "number" || chapter < 1 || chapter > targetBook.chapters.length || Math.floor(chapter) !== chapter)
    return null
  verse = clampVerse(targetBible, targetBook.id, chapter, verse)
  var cell = targetBook.chapters[chapter - 1][verse - 1]
  if (typeof cell !== "string" || cell.trim() === "") {
    var adv = firstNonOmittedVerseAfter(targetBible, { book: targetBook.id, chapter: chapter, verse: verse })
    if (adv) { chapter = adv.chapter; verse = adv.verse }
  }
  return { book: targetBook.id, chapter: chapter, verse: verse }
}

// Resolve a readings reference (universalis style) to concatenated verse text.
// Handles: "Matthew 23:23-26", "2 Thessalonians 2:1-3,14-17",
// "Psalm 95(96):10-13" (Vulgate vs Protestant numbering), and "cf.Ac16:14".
function resolveText(reference, bible) {
  var raw = String(reference || "").trim().replace(/^cf\./i, "").trim()
  if (!raw || !bible || !bible.books) return { ok: false }
  // Glued book abbrev ("Ac16:14") -> spaced ("Ac 16:14").
  raw = raw.replace(/([A-Za-z])(\d)/, "$1 $2")
  var m = raw.match(/^(.+?)\s+(\d+)(?:\((\d+)\))?(?::(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*))?$/)
  if (!m) return { ok: false }
  var book = Search.bookByName(bible, m[1])
  if (!book) return { ok: false }
  var chapter = parseInt(m[2], 10)
  if (m[3]) chapter = usesVulgateNumbering(bible) ? chapter : parseInt(m[3], 10)
  var ch = book.chapters[chapter - 1]
  if (!ch) return { ok: false }
  var out = []
  if (!m[4]) {
    for (var v = 0; v < ch.length; v++) if (typeof ch[v] === "string") out.push(ch[v].trim())
  } else {
    var groups = m[4].split(",")
    for (var g = 0; g < groups.length; g++) {
      var rg = groups[g].match(/^(\d+)(?:-(\d+))?$/)
      if (!rg) continue
      var start = parseInt(rg[1], 10), end = rg[2] ? parseInt(rg[2], 10) : start
      for (var v2 = start; v2 <= end; v2++) {
        var t = ch[v2 - 1]
        if (typeof t === "string") out.push(t.trim())
      }
    }
  }
  if (out.length === 0) return { ok: false }
  return { ok: true, text: out.join(" ") }
}

// Parse the outer per-translation state file. Tolerates malformed input.
function parseState(json) {
  var data = null
  try { data = json ? JSON.parse(json) : null } catch (e) { data = null }
  if (data && typeof data === "object" && data.translations && typeof data.translations === "object")
    return data
  return {}
}

// Read the persisted selected translation code from a parsed state map, or ""
// if none was saved.
function selectedTranslation(map) {
  if (map && typeof map === "object" && typeof map.selectedTranslation === "string")
    return map.selectedTranslation
  return ""
}

// Read this translation's saved place from the state file, validating against
// the bible and falling back to defaults for anything out of range.
function restorePlace(json, bible, translation) {
  var data = parseState(json)
  var entry = data.translations ? data.translations[translation] : null
  var book = DEFAULT_BOOK
  var chapter = DEFAULT_CHAPTER
  var verse = DEFAULT_VERSE
  if (entry && typeof entry === "object") {
    if (typeof entry.book === "string" && bookById(bible, entry.book)) book = entry.book
    if (typeof entry.chapter === "number" && isValidPlace(bible, book, entry.chapter, 1))
      chapter = entry.chapter
    if (typeof entry.verse === "number" && entry.verse >= 1 && Math.floor(entry.verse) === entry.verse)
      verse = entry.verse
  }
  verse = clampVerse(bible, book, chapter, verse)
  return { book: book, chapter: chapter, verse: verse }
}

// Serialize the per-translation state file to JSON. `existingMap` is the result
// of a prior parseState call (or {} for a fresh map); other translations'
// entries are preserved while `translation` is updated to the new position.
// `selectedTranslation` (optional) is persisted at the top level so the chosen
// bible version survives a plugin restart.
function savePlace(existingMap, translation, book, chapter, verse, selectedTranslation) {
  var map = existingMap && typeof existingMap === "object" ? existingMap : {}
  var translations = {}
  var key
  if (map.translations && typeof map.translations === "object") {
    for (key in map.translations) translations[key] = map.translations[key]
  }
  translations[translation] = { book: book, chapter: chapter, verse: verse }
  var out = { translations: translations }
  if (typeof selectedTranslation === "string" && selectedTranslation !== "")
    out.selectedTranslation = selectedTranslation
  return JSON.stringify(out)
}
