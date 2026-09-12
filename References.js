// Random daily-verse selection. The plugin is fully offline, so it picks a
// reference from the bundled translations deterministically from a seed; the
// text itself is resolved from the selected translation (see
// Panel.verseOfDayText). Panel passes the KJV object as the pick universe
// (the 66-book Protestant canon), so every picked book/chapter/verse exists in
// all five bundled translations.

// FNV-1a 32-bit string hash. Deterministic across runs and JS engines; the
// shift/add form multiplies by the FNV prime without relying on Math.imul,
// which is not guaranteed in the QML JS engine.
function _hash(str) {
  var h = 2166136261
  for (var i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h += (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)
  }
  return h >>> 0
}

// Memoized flatten of every non-omitted verse reference, keyed on the bible
// object so repeated picks (and the node tests) enumerate once instead of
// walking ~31k verses per call. Stored as a non-enumerable own property of
// the bible object — same reasoning as the ReaderModel._bookByIdCache (a
// WeakMap was avoided due to observed QV4 WeakMap-key segfaults).
var _verseListCacheKey = "_verseListCache"

function _setVerseListCache(bible, list) {
  Object.defineProperty(bible, _verseListCacheKey, {
    value: list, enumerable: false, writable: true, configurable: true
  })
}

function _verseList(bible) {
  if (!bible || !bible.books) return []
  var list = bible[_verseListCacheKey]
  if (list !== undefined) return list
  list = []
  for (var i = 0; i < bible.books.length; i++) {
    var book = bible.books[i]
    for (var c = 0; c < book.chapters.length; c++) {
      var chapter = book.chapters[c]
      for (var v = 0; v < chapter.length; v++) {
        var text = chapter[v]
        if (typeof text !== "string" || text.trim() === "") continue
        list.push(book.name + " " + (c + 1) + ":" + (v + 1))
      }
    }
  }
  _setVerseListCache(bible, list)
  return list
}

// Deterministically pick one non-omitted verse reference from `bible` for the
// given seed. Returns "Book chapter:verse" (book name, 1-based chapter and
// verse), the same shape resolveText accepts; empty string if the bible has no
// verses.
function randomReference(seed, bible) {
  var list = _verseList(bible)
  if (list.length === 0) return ""
  return list[_hash(String(seed)) % list.length]
}
