import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "ReaderModel.js" as ReaderModel
import "search.js" as Search
import "References.js" as References

// Two-column panel: a slim icon sidebar on the left plus a scrollable
// content column on the right. Bible search runs client-side via
// ReaderModel.
Panel {
  id: root
  moduleName: "bible"
  manageIpc: false

  // Centered copy-feedback banner plus a fixed spacer, shared by the Bible
  // reader.
  component CenteredCopyFeedback: Column {
    id: centeredCopyFeedback
    // Defaulted (not required): CopyFeedback below binds during component
    // construction, before the outer assignment lands, so `required` made
    // these transiently undefined and produced the
    // "[undefined] to QString" warnings at Panel.qml:31/32 on every load.
    property string copyFeedback: ""
    property string fontFamily: Style.font.family

    width: parent.width
    spacing: Style.spacing.sm

    CopyFeedback {
      centered: true
      copyFeedback: centeredCopyFeedback.copyFeedback
      fontFamily: centeredCopyFeedback.fontFamily
    }

    // Guaranteed breathing room between the header and the reader content,
    // independent of whether the feedback is showing.
    Item { width: parent.width; height: Style.space(16) }
  }

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  onServiceChanged: root.verseOfDayEnsurePick()

  // The day's random verse pick, persisted to bible-state.json as
  // { date: <todayKey>, reference: <ref> }. Reused all day; re-picked when
  // service.todayKey changes (midnight rollover).
  property var verseOfDay: ({ date: "", reference: "" })

  // Re-pick when the service's day key rolls over at midnight.
  Connections {
    target: root.service
    function onTodayKeyChanged() { root.verseOfDayEnsurePick() }
  }

  property string currentTab: "verse"
  property string query: ""
  property string statusText: ""
  // True while a Bible search is in flight, so the empty-result placeholder
  // can show "Searching…" instead of "No matches".
  property bool searching: false
  // Transient feedback shown after copying a verse (e.g. "Copied — John 3:16").
  // The source URL is added to the clipboard text, not to this feedback string.
  // Auto-clears via copyFeedbackTimer.
  property string copyFeedback: ""
  property int selectedIndex: 0
  // Autocomplete suggestions drawn from the book content, for the current query.
  property var suggestions: []
  // Set while a clicked suggestion fills the field, so the follow-up search
  // does not immediately re-open the autocomplete popup for the completed text.
  property bool suppressSuggestions: false
  // Translation the search worker currently holds cached; used to decide
  // whether to re-send the bible object on the next search.
  property string workerCachedTranslation: ""
  // Exact verse pinned as the top result when a reference query also runs the
  // content search; cleared at the start of each searchBible call.
  property var pinnedExact: null
  // In-flight Bible worker requests (0 or 1). The search worker answers each
  // sendMessage with exactly one reply, so this counts dispatched-but-unanswered
  // queries.
  property int bibleOutstanding: 0
  // Latest Bible query awaiting dispatch while a worker request is in flight
  // ("" = none). Single-flight keeps at most one query in the worker at a time
  // without dropping the trailing query.
  property string biblePendingQuery: ""
  // Compiled highlight regexes keyed by normalized query (see highlightQuery);
  // avoids rebuilding the RegExp on every result card per keystroke.
  property var highlightCache: ({})

  // --- Strong's numbers (KJV only) -------------------------------------------

  // Toggle for rendering Strong's numbers in the KJV reader. Persisted in
  // bible-state.json alongside verseOfDay. Off by default: the numbers are
  // a study aid, not reading typography.
  property bool strongsNumbers: false

  // Parsed data/strongs-dictionary.json (all H/G entries), or null before
  // the first load / on failure. Loaded lazily on first toggle-on.
  property var strongsDictionary: null

  // Parsed data/strongs/kjv/<Book>.json for the book the reader is on (or
  // null). Keyed to bibleBook; reloaded when the book (or toggle) changes.
  property var strongsBook: null

  // The Strong's number whose definition card is open ("" when closed).
  property string strongsPopupNumber: ""

  // Strong's data is only relevant for the KJV reader; the toggle, loads and
  // rendering all gate on this.
  readonly property bool strongsActive: root.strongsNumbers && root.translation === "kjv"

  readonly property var activeBible: root.translations[root.translation]
  property string bibleBook: ReaderModel.DEFAULT_BOOK
  property int bibleChapter: ReaderModel.DEFAULT_CHAPTER
  property int bibleVerse: ReaderModel.DEFAULT_VERSE
  property string bibleMode: "read" // read | books | chapters
  property string bibleTestament: ""

  // The single translation used by every tab (Bible reader, Verse).
  property string translation: "dr" // dr | bsb | kjv | web | cpdv

  readonly property var bibleBookMeta: ReaderModel.bookById(root.activeBible, root.bibleBook)
  readonly property int bibleChapterCount: ReaderModel.chapterCount(root.activeBible, root.bibleBook)
  readonly property int bibleVerseCount: ReaderModel.verseCount(root.activeBible, root.bibleBook, root.bibleChapter)

  readonly property var barOwner: hostWidget || root
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string stateFileHelperPath: Search.fileUrlToPath(Qt.resolvedUrl("bin/omarchy-statefile"))

  // State-file base dir. Canonicalized once at startup (readlink -f) purely as
  // normalization so the resolved path is what stateFilePath concatenates onto;
  // it is NOT the security boundary — bin/omarchy-statefile pins the parent dir
  // and O_NOFOLLOWs the leaf in a single open, so a post-resolution path swap
  // is refused at read time regardless of what this string holds.
  property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"

  // The two state files the panel owns. stateFilePath refuses any other name
  // so a caller can never concatenate a traversal ("../…") into the path chain.
  readonly property var stateFileNames: ["bible-state", "bible-tab-state"]

  // Shared state-file path under the omarchy settings dir; the two readers
  // each persist their last position to a sibling file here.
  function stateFilePath(name) {
    if (stateFileNames.indexOf(name) === -1) return ""
    return stateDir + "/" + name + ".json"
  }

  // Resolve symlinks in the state dir chain once at startup so stateFilePath
  // concatenates onto a canonical base.
  Process {
    id: stateDirResolve
    command: ["readlink", "-f", root.stateDir]
    stdout: StdioCollector { id: stateDirResolveOut; waitForEnd: true }
    onExited: function() {
      var resolved = String(stateDirResolveOut.text || "").trim()
      if (resolved !== "") root.stateDir = resolved
      // Load the two state files only after stateDir is canonicalized so the
      // helpers open the resolved path (onExited also fires when readlink
      // fails, leaving stateDir at the raw path). Security boundary: see the
      // stateDir comment above.
      bibleStateFile.reload()
      tabStateFile.reload()
    }
  }

  // ---- layout + type tokens -------------------------------------------------

  // Fixed text opacities: primary is full-strength, secondary is muted
  // supporting copy, tertiary is for keyboard/pointer hints.
  readonly property real opacityPrimary: 1.0
  readonly property real opacitySecondary: 0.62
  readonly property real opacityTertiary: 0.46

  // Popup text color. The panel is a dark surface; use the panel foreground
  // (always light) rather than barForeground, which follows the bar theme and
  // can be dark — invisible against the dark panel background.
  readonly property color foreground: Color.foreground

  readonly property int sidebarWidth: Style.space(44)
  // Fixed height for the reader/list viewports (Bible verses, books, chapters).
  readonly property int readerHeight: Style.space(360)

  // Larger reading size: expands the panel for comfortable reading.
  property bool expanded: false

  // Single source for the translation pickers across both tabs.
  readonly property var translationOptions: [
    { value: "bsb", label: "BSB" },
    { value: "cpdv", label: "CPDV" },
    { value: "dr", label: "Douay-Rheims" },
    { value: "kjv", label: "KJV" },
    { value: "web", label: "WEB" }
  ]

  function isKnownTranslation(code) {
    for (var i = 0; i < root.translationOptions.length; i++)
      if (root.translationOptions[i].value === code) return true
    return false
  }

  readonly property var glyphs: ({
    close: "\uf00d",
    expand: "\uf065",
    collapse: "\uf066"
  })

  // Result cap for the off-thread Bible search worker. Results are revealed a
  // page (pageSize) at a time as the user scrolls the results list.
  readonly property int maxResults: 153   // 153 fish (John 21:11)
  readonly property int pageSize: 7       // 7 disciples in the boat (John 21:2)
  property var pendingResults: []      // {reference, verse} objects not yet revealed
  property int revealedCount: 0
  property bool truncated: false       // backend hit its cap (there may be more)

  // Attribution appended to copied verses.
  readonly property string sourceUrl: "https://github.com/ronald2wing/Omarchy-Bible"

  readonly property string sectionTitle: {
    switch (root.currentTab) {
      case "verse": return "Verse of the Day"
      case "bible": return "Bible"
    }
  }

  readonly property string sectionSubtitle: {
    switch (root.currentTab) {
      case "verse": return "Today's verse in your chosen translation"
      case "bible": return "Search and read Scripture"
    }
  }

  function open() {
    controller.show()
    // Load the translation lazily on first open rather than at shell startup,
    // where parsing the ~4.7MB JSON would stall the bar. The Verse tab's text
    // and the Bible reader both depend on it, so load regardless of tab;
    // ensureTranslationLoaded is a no-op once the translation is cached.
    root.ensureTranslationLoaded(root.translation)
    root.verseOfDayEnsurePick()
    // Strong's data loads the same way: only once the panel is actually
    // open (and only when the toggle is on and the reader is on KJV).
    if (root.strongsActive) root.ensureStrongsLoaded()
  }

  function close() {
    controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function setTab(tab) {
    if (root.currentTab === tab) return
    root.currentTab = tab
    root.saveTabState()
    root.query = ""
    resultModel.clear()
    root.selectedIndex = 0
    root.statusText = ""
    // Switching tabs is a click outside the search field: return keyboard
    // focus to the catcher so arrow navigation stays live on the new tab.
    keyCatcher.forceActiveFocus()
    if (tab === "verse") {
      // The verse service is always live; the translation is loaded lazily so
      // the verse text appears as soon as the data is ready.
      root.ensureTranslationLoaded(root.translation)
    }
    if (tab === "bible") Qt.callLater(function() {
      root.ensureTranslationLoaded(root.translation)
      if (root.strongsActive) root.ensureStrongsLoaded()
    })
  }

  function selectTranslation(code) {
    if (root.translation === code) return
    // Remember where the reader is before swapping so restoreBibleState can
    // land on the equivalent verse in the new canon (psalm numbering diverges
    // between Vulgate and Protestant translations; deuterocanonical books have
    // no Protestant equivalent).
    root.pendingSwitchFrom = { code: root.translation, book: root.bibleBook, chapter: root.bibleChapter, verse: root.bibleVerse }
    root.translation = code
    root.query = ""
    root.biblePendingQuery = ""
    resultModel.clear()
    root.selectedIndex = 0
    root.statusText = ""
    root.bibleMode = "read"
    root.bibleStateLoaded = false
    if (root.ensureTranslationLoaded(code)) {
      // Already cached: onTranslationLoaded never fires for a cached load, so
      // restore the equivalent position now (otherwise cached switches would
      // keep the old verbatim behavior).
      root.restoreBibleState()
    }
  }

  // Daily verse text looked up in the selected bundled translation. When this
  // translation omits the picked verse (a null/empty slot), fall back to the
  // next available verse for display only — the cached reference is unchanged.
  function verseOfDayText() {
    var bible = root.activeBible
    if (!bible) return ""
    var ref = root.service ? root.service.todayReference : ""
    if (ref === "") return ""
    var r = ReaderModel.resolveText(ref, bible)
    if (r && r.ok && r.text.trim() !== "") return r.text
    var place = ReaderModel.parsePlace(ref, bible)
    if (!place) return ""
    return root.verseOfDayFallbackText(bible, place)
  }

  // Walk forward from place (next verse, then next chapter, wrapping into the
  // next book as a safety net) to the first non-omitted verse in this
  // translation. Display-only fallback, so the day's pick stays stable even
  // when the current translation omits it. The walk lives in
  // ReaderModel.firstNonOmittedVerseAfter; this resolves its result to text.
  function verseOfDayFallbackText(bible, place) {
    var next = ReaderModel.firstNonOmittedVerseAfter(bible, place)
    if (!next) return ""
    var book = ReaderModel.bookById(bible, next.book)
    if (!book) return ""
    var ch = book.chapters[next.chapter - 1]
    var t = ch ? ch[next.verse - 1] : null
    return typeof t === "string" ? t.trim() : ""
  }

  function scheduleSearch() {
    root.selectedIndex = 0
    searchTimer.restart()
  }

  // HTML- and regex-escape helpers, hoisted to module scope so highlightQuery
  // does not re-create two closures for every result card.
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function escapeRegex(s) {
    return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  // Wrap every occurrence of the query's words in the verse text with an
  // accent-colored <font> tag so RichText renders them highlighted.
  function highlightQuery(text, query) {
    var t = String(text || "")
    var q = String(query || "").trim()
    if (q === "") return escapeHtml(t)
    // The regex depends only on the lowercased, whitespace-split query words,
    // so cache it keyed by the normalized query rather than rebuilding it for
    // every card on every keystroke.
    var key = q.toLowerCase()
    var re = root.highlightCache[key]
    if (re === undefined) {
      var words = key.split(/\s+/).filter(function(w) { return w !== "" })
      if (words.length === 0) return escapeHtml(t)
      re = new RegExp("(" + words.map(escapeRegex).join("|") + ")", "gi")
      root.highlightCache[key] = re
    }
    var accent = Color.accent.toString()
    return escapeHtml(t).replace(re, '<font color="' + accent + '">$1</font>')
  }

  // Append one result card to the list, highlighting the query in both the
  // reference and the verse text.
  function appendResult(reference, text) {
    resultModel.append({
      reference: reference, verse: text,
      referenceHtml: root.highlightQuery(reference, root.query),
      verseHtml: root.highlightQuery(text, root.query)
    })
  }

  // Render a Strong's-tagged verse as RichText: each word followed by a tiny
  // accent-colored superscript of its Strong's number(s), wrapped as <a> so
  // onLinkActivated carries the number. Words with several numbers
  // ("fifteen|H7657+H8141+H2568") render one superscript per number.
  // RichText ignores Text.color, so the word run carries its own <font>;
  // the verse-number separator uses &nbsp; because rich text collapses
  // runs of plain spaces.
  function strongsVerseHtml(verse, tokens, baseColor) {
    var accent = Color.accent.toString()
    var out = []
    out.push('<font color="' + Color.muted.toString() + '">' + verse + "&nbsp;&nbsp;</font>")
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i]
      var sep = t.indexOf("|")
      var word = sep === -1 ? t : t.slice(0, sep)
      var nums = sep === -1 ? "" : t.slice(sep + 1)
      out.push('<font color="' + baseColor + '">' + root.escapeHtml(word) + "</font>")
      if (nums !== "") {
        var list = nums.split("+")
        for (var n = 0; n < list.length; n++) {
          out.push('<a href="' + list[n] + '"><font color="' + accent
            + '"><sup>' + list[n] + "</sup></font></a> ")
        }
      } else {
        out.push(" ")
      }
    }
    return out.join("")
  }

  function runSearch() {
    resultModel.clear()
    root.highlightCache = {}
    root.suggestions = []
    if (root.currentTab !== "bible") return
    if (root.query.trim() === "") {
      root.statusText = ""
      root.biblePendingQuery = ""
      root.searching = false
      return
    }
    root.searchBible(root.query)
  }

  // Bible branch: a "john 3:16" style reference shows that verse's text as a
  // result card; otherwise the word/phrase search runs off the UI thread via
  // the worker.
  function searchBible(query) {
    var bible = root.activeBible
    if (!bible) {
      root.statusText = "Loading…"
      return
    }
    root.pinnedExact = null
    // Reference lookup: "john 3:16" resolves to a verse and shows its text as a
    // result card, so the text is visible in the results list (and clickable).
    var parsed = ReaderModel.resolvePlace(query, bible)
    // A bare "chapter[:verse]" (no book name) resolves against the current book.
    if (!parsed) {
      var bare = Search.parseBarePlace(query)
      if (bare) {
        var ch = bare.chapter
        var verse = bare.verse === null ? 1 : bare.verse
        if (ReaderModel.isValidPlace(bible, root.bibleBook, ch, verse)) {
          parsed = { book: root.bibleBook, chapter: ch, verse: verse }
        }
      }
    }
    if (parsed) {
      var ref = ReaderModel.formatRef(bible, parsed.book, parsed.chapter, parsed.verse)
      var r = ReaderModel.resolveText(ref, bible)
      if (r && r.ok) {
        // Pin the exact verse as the top result, then also run the content
        // search so all related verses appear.
        root.pinnedExact = {
          reference: ref,
          verse: r.text,
          referenceHtml: root.highlightQuery(ref, query),
          verseHtml: root.highlightQuery(r.text, query)
        }
        resultModel.clear()
        resultModel.append(root.pinnedExact)
        root.searching = false
        root.statusText = "1 result · click to open"
        root.selectedIndex = 0
      }
    }
    // Word/phrase search fallback — run off the UI thread via the worker.
    // Single-flight: the query is queued as biblePendingQuery and dispatched by
    // flushBiblePending once any in-flight request has answered, so a burst of
    // debounced queries never piles unbounded work into the worker's queue.
    root.biblePendingQuery = query
    if (root.bibleOutstanding === 0) root.flushBiblePending()
  }

  // Single-flight dispatch for the Bible worker: at most one query is in
  // flight at a time, and the latest queued query is dispatched once the
  // in-flight reply lands — never dropped.
  function flushBiblePending() {
    if (root.biblePendingQuery === "") return
    var query = root.biblePendingQuery
    root.biblePendingQuery = ""
    // When a reference query pinned an exact verse, the result status is
    // already set; don't overwrite it with "Searching…" while the worker
    // catches up.
    if (!root.pinnedExact) {
      root.statusText = "Searching…"
      root.searching = true
    }
    if (root.workerCachedTranslation !== root.translation) {
      root.workerCachedTranslation = root.translation
      searchWorker.sendMessage({ bible: root.activeBible, translation: root.translation, query: query, maxResults: root.maxResults })
    } else {
      searchWorker.sendMessage({ query: query, maxResults: root.maxResults })
    }
    root.bibleOutstanding++
  }

  // Derived status: "N+ results · scroll for more" while lazy-loading, an exact
  // count once fully revealed, and "+ results" when the backend was truncated.
  function updateResultStatus() {
    root.searching = false
    var pinnedCount = root.pinnedExact ? 1 : 0
    var total = pinnedCount + root.pendingResults.length
    if (total === 0) {
      root.statusText = "No matches for \"" + root.query + "\""
      return
    }
    var revealed = pinnedCount + root.revealedCount
    if (revealed < total) root.statusText = revealed + "+ results · scroll for more"
    else if (root.truncated) root.statusText = total + "+ results"
    else root.statusText = total + " result" + (total === 1 ? "" : "s") + " · click to open"
  }

  // Append the next pageSize pending results, then refresh the status.
  function revealMore() {
    var end = Math.min(root.pendingResults.length, root.revealedCount + root.pageSize)
    for (var i = root.revealedCount; i < end; i++) {
      root.appendResult(root.pendingResults[i].reference, root.pendingResults[i].verse)
    }
    root.revealedCount = end
    root.updateResultStatus()
  }

  function moveSelection(delta) {
    if (resultModel.count === 0) return
    root.selectedIndex = Math.max(0, Math.min(resultModel.count - 1, root.selectedIndex + delta))
    // Reveal the selected card using its actual delegate geometry rather than
    // a fixed 72px-per-row offset, which drifted on variable-height (multi-line)
    // cards. Contain scrolls the minimum distance that brings the card fully
    // into view, the least-jumpy behavior for incremental up/down stepping.
    resultScroll.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateSelected() {
    if (resultModel.count > 0) openResult(root.selectedIndex)
  }

  // Jump the reader to the verse a search result points at, then
  // dismiss the search UI (results, suggestions, and field focus) so the
  // popup closes even if navigation could not be resolved.
  function openResult(index) {
    if (index < 0 || index >= resultModel.count) return
    var row = resultModel.get(index)
    if (root.currentTab === "bible") {
      var bible = root.activeBible
      if (bible) {
        var parsed = ReaderModel.parsePlace(row.reference, bible)
        if (parsed) root.bibleGoTo(parsed.book, parsed.chapter, parsed.verse, true)
      }
    }
    root.query = ""
    resultModel.clear()
    root.suggestions = []
    root.statusText = ""
    searchField.focus = false
    keyCatcher.forceActiveFocus()
  }

  // Fill the search field from a clicked suggestion, close the suggestion
  // popup, and hand focus back to the field so typing can continue.
  function applySuggestion(suggestion) {
    root.suppressSuggestions = true
    searchField.text = suggestion
    root.suggestions = []
    searchField.forceActiveFocus()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barOwner, direction)
    return false
  }

  // Resolve the day's random verse: reuse the cached pick when its date still
  // matches service.todayKey, otherwise seed a fresh pick from the KJV canon
  // and persist it. Idempotent and safe to call from any of the load/service
  // hooks; each precondition is checked and missing pieces are left for the
  // next callback to finish.
  function verseOfDayEnsurePick() {
    var key = root.service ? root.service.todayKey : ""
    if (key === "") return
    var cached = root.verseOfDay
    if (cached && cached.date === key && cached.reference !== "") {
      root.service.todayReference = cached.reference
      return
    }
    if (root.translations.kjv === undefined) {
      // The pick universe loads lazily through the same single FileView the
      // reader uses. Wait until it is idle (and the panel is open) rather than
      // interrupting an in-flight translation load or stalling the bar at
      // shell startup/midnight while closed. The load is deferred with
      // Qt.callLater because this runs from inside a translation onLoaded
      // handler, and reload()ing the same FileView re-entrantly drops the load.
      if (!root.opened || root.translationLoading !== "") return
      Qt.callLater(function() { root.ensureTranslationLoaded("kjv") })
      return
    }
    var ref = References.randomReference(Date.now(), root.translations.kjv)
    root.verseOfDay = { date: key, reference: ref }
    root.service.todayReference = ref
    // Persist once the state file has been read; before then, persisting would
    // write a fresh translations map over the saved reading position.
    if (root.bibleStateMap !== null) root.writeBibleState()
  }

  function writeBibleState() {
    var json = ReaderModel.savePlace(root.bibleStateMap || {}, root.translation, root.bibleBook, root.bibleChapter, root.bibleVerse, root.translation)
    // savePlace rebuilds the map and drops these top-level entries; merge
    // them back so the day's pick and the Strong's toggle survive a restart.
    var data = JSON.parse(json)
    if (root.verseOfDay && root.verseOfDay.date !== "") {
      data.verseOfDay = { date: root.verseOfDay.date, reference: root.verseOfDay.reference }
    }
    data.strongsNumbers = root.strongsNumbers
    json = JSON.stringify(data)
    bibleStateFile.setText(json)
  }

  function saveBibleStateIfLoaded() {
    if (!root.bibleStateLoaded) return
    bibleSaveTimer.restart()
  }

  // Debounce the per-translation reading-position write: held-key chapter
  // paging (and verse clicks) would otherwise spawn a fresh
  // bin/omarchy-statefile write process per step. StateFile coalesces to the
  // trailing value, so the delay never drops the final position. The startup
  // read path (restoreBibleState) never routes through here with a persistNow
  // write on initial load, so reads stay un-debounced.
  Timer {
    id: bibleSaveTimer
    interval: 500
    repeat: false
    onTriggered: root.writeBibleState()
  }

  function bibleGoTo(bookId, chapter, verse, persistNow) {
    if (!ReaderModel.isValidPlace(root.activeBible, bookId, chapter, 1)) return false
    root.bibleBook = bookId
    root.bibleChapter = chapter
    root.bibleVerse = ReaderModel.clampVerse(root.activeBible, bookId, chapter, verse || 1)
    root.bibleMode = "read"
    if (persistNow !== false) root.saveBibleStateIfLoaded()
    Qt.callLater(root.bibleScrollToVerse)
    return true
  }

  function bibleStepChapter(delta) {
    var next = delta > 0
      ? ReaderModel.nextChapter(root.activeBible, root.bibleBook, root.bibleChapter)
      : ReaderModel.prevChapter(root.activeBible, root.bibleBook, root.bibleChapter)
    root.bibleGoTo(next.book, next.chapter, 1, true)
  }

  // Center the 1-based `position` (verse number) in the list viewport,
  // clamped to [0, count-1].
  function scrollToIndex(listView, position, count) {
    if (count <= 0) return
    var idx = Math.max(0, Math.min(count - 1, position - 1))
    listView.positionViewAtIndex(idx, ListView.Center)
  }

  function bibleScrollToVerse() {
    root.scrollToIndex(bibleVerseList, root.bibleVerse, root.bibleVerseCount)
  }

  function bibleShowBooks(testament) {
    root.bibleTestament = testament
    root.bibleMode = "books"
  }

  function bibleSelectBook(id) {
    var place = ReaderModel.initialPlaceForBook(root.activeBible, id)
    if (!place) return
    root.bibleBook = place.book
    root.bibleChapter = place.chapter
    root.bibleVerse = place.verse
    root.bibleMode = "chapters"
  }

  function bibleSelectChapter(n) {
    root.bibleGoTo(root.bibleBook, n, 1, true)
  }

  ListModel { id: resultModel }

  Timer {
    id: searchTimer
    interval: 160
    repeat: false
    onTriggered: root.runSearch()
  }

  WorkerScript {
    id: searchWorker
    source: "SearchWorker.js"
    onMessage: function(msg) {
      // Decrement before the stale check so the count can never wedge, then
      // dispatch the query typed while this one was in flight.
      root.bibleOutstanding--
      root.flushBiblePending()
      // Ignore stale responses from an earlier query or translation.
      if (msg.translation !== root.translation || msg.query !== root.query) return
      resultModel.clear()
      root.suggestions = root.suppressSuggestions ? [] : (msg.suggestions || [])
      var hits = msg.results || []
      var bible = root.activeBible
      var pinned = root.pinnedExact
      root.pendingResults = []
      root.truncated = hits.length >= root.maxResults
      for (var i = 0; i < hits.length; i++) {
        var ref = ReaderModel.formatRef(bible, hits[i].book, hits[i].chapter, hits[i].verse)
        if (pinned && ref === pinned.reference) continue
        root.pendingResults.push({ reference: ref, verse: hits[i].text })
      }
      if (pinned) resultModel.append(pinned)
      root.revealedCount = 0
      root.revealMore()
      root.selectedIndex = 0
    }
  }

  property var translations: ({})          // code -> parsed bible object
  // Translation codes in load order, most recent last (deduped on store).
  // Eviction walks this to pick the non-current translation to retain.
  property var translationOrder: []
  property string translationToLoad: ""      // FileView path driver
  property string translationLoading: ""        // code in flight, or "" when idle

  FileView {
    id: translationFile
    path: root.translationToLoad === "" ? ""
      : Search.fileUrlToPath(Qt.resolvedUrl("data/" + root.translationToLoad + ".json"))
    printErrors: false
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      root.storeTranslation(root.translationLoading, parsed)
    }
    onLoadFailed: root.storeTranslation(root.translationLoading, null)
  }

  function ensureTranslationLoaded(code) {
    if (root.translations[code] !== undefined) return true
    root.translationLoading = code
    root.translationToLoad = code
    translationFile.reload()
    return false
  }

  // --- Strong's lazy loads ----------------------------------------------------

  // Dictionary FileView: driven by strongsDictionaryToLoad; empty when idle
  // so no load happens at shell startup (same discipline as translations).
  // printErrors stays on (unlike the translation view) so a failed Strong's
  // load is visible in the shell log during bring-up.
  FileView {
    id: strongsDictionaryFile
    path: root.strongsDictionaryToLoad === "" ? ""
      : Search.fileUrlToPath(Qt.resolvedUrl("data/strongs-dictionary.json"))
    printErrors: true
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      root.strongsDictionaryToLoad = ""
      if (parsed && typeof parsed === "object") root.strongsDictionary = parsed
      else console.warn("bible: strongs dictionary failed to parse")
    }
    onLoadFailed: { root.strongsDictionaryToLoad = ""; console.warn("bible: strongs dictionary load failed") }
  }

  // Tagged-book FileView: loads the file for root.bibleBook when Strong's is
  // active; a book change (or toggle-off) swaps the path and reloads.
  FileView {
    id: strongsBookFile
    path: root.strongsBookToLoad === "" ? ""
      : Search.fileUrlToPath(Qt.resolvedUrl("data/strongs/kjv/" + root.strongsBookToLoad + ".json"))
    printErrors: true
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      // Only store when the answer still matches what was wanted (a stale
      // answer after a fast book switch is dropped; the newer request's
      // load follows right behind it).
      if (parsed && parsed.book === root.strongsBookToLoad) root.strongsBook = parsed
      else console.warn("bible: strongs book mismatch/parse failed: " + root.strongsBookToLoad)
      root.strongsBookToLoad = ""
    }
    onLoadFailed: {
      // A failed book load leaves the reader on plain-text fallback.
      console.warn("bible: strongs book load failed: " + root.strongsBookToLoad)
      root.strongsBookToLoad = ""
    }
  }

  // Path drivers for the two Strong's FileViews (mirrors translationToLoad).
  property string strongsDictionaryToLoad: ""
  property string strongsBookToLoad: ""

  // Ensure the dictionary is loaded (idempotent). Called when the toggle
  // turns on; the ~3MB parse mirrors a translation load.
  function ensureStrongsDictionaryLoaded() {
    if (root.strongsDictionary !== null || root.strongsDictionaryToLoad !== "") return
    root.strongsDictionaryToLoad = "dictionary"
    strongsDictionaryFile.reload()
  }

  // Ensure the tagged file for the current book is loaded (idempotent).
  function ensureStrongsBookLoaded() {
    if (!root.strongsActive) return
    if (root.strongsBook !== null && root.strongsBook.book === root.bibleBook) return
    if (root.strongsBookToLoad === root.bibleBook) return
    root.strongsBookToLoad = root.bibleBook
    root.strongsBook = null
    strongsBookFile.reload()
  }

  // Tokens for a verse of the current book, or null when Strong's rendering
  // is unavailable (toggle off, non-KJV, book not yet loaded, or this verse
  // has no tagged data — the reader then falls back to plain text).
  function strongsTokensFor(verse) {
    if (!root.strongsActive || !root.strongsBook) return null
    if (root.strongsBook.book !== root.bibleBook) return null
    var ch = root.strongsBook.chapters ? root.strongsBook.chapters[root.bibleChapter - 1] : null
    if (!ch) return null
    var tokens = ch[verse - 1]
    return tokens instanceof Array ? tokens : null
  }

  // The dictionary entry for a Strong's number, or null.
  function strongsEntryFor(number) {
    return root.strongsDictionary ? (root.strongsDictionary[number] || null) : null
  }

  // Toggle handler: persist the new state and kick the lazy loads (only if
  // the panel is open; open()/setTab cover the closed case).
  function setStrongsNumbers(on) {
    if (root.strongsNumbers === on) return
    root.strongsNumbers = on
    if (on && root.opened) root.ensureStrongsLoaded()
    root.saveBibleStateIfLoaded()
  }

  // Open the definition card for a Strong's number ("H3068" / "G26"). The
  // dictionary is normally already loaded (the toggle loaded it before any
  // number could render); ensure defensively so the card never shows the
  // no-entry fallback just because a load raced.
  function openStrongsPopup(number) {
    if (number === "") return
    root.ensureStrongsDictionaryLoaded()
    root.strongsPopupNumber = number
    strongsPopup.open()
  }

  function closeStrongsPopup() {
    strongsPopup.close() // fires closed -> strongsPopupClosed
  }

  // Idempotent cleanup after the card hides, from any close path (Esc, ✕,
  // scrim, tab switch, panel close).
  function strongsPopupClosed() {
    root.strongsPopupNumber = ""
    keyCatcher.forceActiveFocus()
  }

  // Book/translation/toggle changes keep the tagged book in step with the
  // reader. Gated on root.opened so the startup state restore (which fires
  // these change handlers before the panel is ever shown) cannot trigger
  // disk loads — the same lazy discipline as the translation loads.
  onStrongsActiveChanged: {
    if (!root.strongsActive) return
    if (root.opened) root.ensureStrongsLoaded()
  }
  onBibleBookChanged: {
    if (root.strongsActive && root.opened) root.ensureStrongsLoaded()
    else if (!root.strongsActive) root.strongsBook = null
  }
  onTranslationChanged: {
    if (root.strongsActive && root.opened) root.ensureStrongsLoaded()
    else if (!root.strongsActive) root.strongsBook = null
  }

  // Load both Strong's data sets (dictionary + current book) if missing.
  // Idempotent; called whenever Strong's becomes active with the panel open.
  function ensureStrongsLoaded() {
    root.ensureStrongsDictionaryLoaded()
    root.ensureStrongsBookLoaded()
  }

  // Copy the parsed bible (or null on failure) into the translations map and
  // notify the reader; shared by translationFile.onLoaded/onLoadFailed so the
  // map-copy does not live twice.
  function storeTranslation(code, parsed) {
    var map = {}
    for (var k in root.translations) map[k] = root.translations[k]
    map[code] = parsed
    root.translations = map
    root.onTranslationLoaded(code)
    // Record load recency and enforce the 2-translation cap. This runs AFTER
    // onTranslationLoaded on purpose: a pending switch (selectTranslation) still
    // needs the OLD translation to resolve equivalentPlace, and restoreBibleState
    // consumes it synchronously inside onTranslationLoaded before
    // pendingSwitchFrom is cleared. Evicting earlier would break that mapping.
    var order = root.translationOrder.filter(function(c) { return c !== code })
    order.push(code)
    root.translationOrder = order
    root.evictTranslations()
  }

  // Cap root.translations at 2: the current translation (never evicted — the
  // reader's activeBible depends on it) plus the single most-recently-used OTHER
  // translation. Anything else is dropped; switching back to an evicted code
  // re-loads it from disk via ensureTranslationLoaded's cache-miss path.
  function evictTranslations() {
    var keep = {}
    keep[root.translation] = true
    for (var i = root.translationOrder.length - 1; i >= 0; i--) {
      var code = root.translationOrder[i]
      if (code !== root.translation) { keep[code] = true; break }
    }
    var map = {}
    var evicted = false
    for (var k in root.translations) {
      if (keep[k]) map[k] = root.translations[k]
      else evicted = true
    }
    // Reassign only when something was dropped; a fresh load that fits the cap
    // must not churn the activeBible binding.
    if (evicted) root.translations = map
  }

  function onTranslationLoaded(code) {
    root.translationLoading = ""
    if (code === root.translation) root.restoreBibleState()
    root.verseOfDayEnsurePick()
  }

  Timer {
    id: copyFeedbackTimer
    interval: 2000
    onTriggered: root.copyFeedback = ""
  }

  function showCopyFeedback(msg) {
    root.copyFeedback = msg
    copyFeedbackTimer.restart()
  }

  property var bibleStateMap: null            // parsed per-translation map
  property bool bibleStateLoaded: false
  // The reading position (and translation code) the user was at when they
  // switched versions; restoreBibleState consumes it to land on the equivalent
  // verse in the new canon. Null when no switch is pending.
  property var pendingSwitchFrom: null

  StateFile {
    id: bibleStateFile
    path: root.stateFilePath("bible-state")
    helperPath: root.stateFileHelperPath
    onRestored: function(parsed) {
      // ReaderModel.parseState's contract: only a map carrying a `translations`
      // object is accepted, anything else becomes {}. parsed is already the
      // JSON.parse result, so re-apply that shape check instead of re-parsing.
      root.bibleStateMap = (parsed && typeof parsed === "object"
        && parsed.translations && typeof parsed.translations === "object") ? parsed : {}
      var vod = root.bibleStateMap.verseOfDay
      if (vod && typeof vod === "object" && typeof vod.date === "string" && typeof vod.reference === "string") {
        root.verseOfDay = { date: vod.date, reference: vod.reference }
      }
      if (typeof root.bibleStateMap.strongsNumbers === "boolean") {
        root.strongsNumbers = root.bibleStateMap.strongsNumbers
      }
      var saved = ReaderModel.selectedTranslation(root.bibleStateMap)
      if (saved !== "" && root.isKnownTranslation(saved)) {
        root.translation = saved
      }
      root.restoreBibleState()
      root.verseOfDayEnsurePick()
    }
    onFailed: { root.bibleStateMap = {}; root.restoreBibleState(); root.verseOfDayEnsurePick() }
  }

  function restoreBibleState() {
    if (!root.activeBible || !root.bibleStateMap) return
    if (root.pendingSwitchFrom) {
      var src = root.translations[root.pendingSwitchFrom.code]
      var place = ReaderModel.equivalentPlace(src, root.activeBible, root.pendingSwitchFrom)
      root.pendingSwitchFrom = null
      // No equivalent (book absent from the target canon, or chapter out of
      // range after the psalm remap): fall back to the target's own bookmark.
      if (!place) place = ReaderModel.restorePlace(JSON.stringify(root.bibleStateMap), root.activeBible, root.translation)
      // Persist the mapped position (and the newly selected translation) into
      // the target's bookmark; bibleStateLoaded gates the write, so set it first.
      root.bibleStateLoaded = true
      root.bibleGoTo(place.book, place.chapter, place.verse, true)
      return
    }
    var place = ReaderModel.restorePlace(JSON.stringify(root.bibleStateMap), root.activeBible, root.translation)
    root.bibleGoTo(place.book, place.chapter, place.verse, false)
    root.bibleStateLoaded = true
  }

  // Remembers the last-opened tab so the panel reopens where the user left
  // off. Defaults to the verse of the day when no tab has been saved yet.
  property string tabState: ""
  property bool tabStateLoaded: false

  StateFile {
    id: tabStateFile
    path: root.stateFilePath("bible-tab-state")
    helperPath: root.stateFileHelperPath
    onRestored: function(parsed) {
      root.tabState = parsed === null ? "" : String(parsed.tab || "")
      root.tabStateLoaded = true
      root.restoreTabState()
    }
    onFailed: {
      root.tabState = ""
      root.tabStateLoaded = true
      root.restoreTabState()
    }
  }

  function restoreTabState() {
    if (!root.tabStateLoaded) return
    var tab = ["verse", "bible"].indexOf(root.tabState) !== -1 ? root.tabState : "verse"
    root.currentTab = tab
    root.statusText = ""
  }

  function saveTabState() {
    if (!root.tabStateLoaded) return
    tabStateFile.setText(JSON.stringify({ tab: root.currentTab }))
  }

  function copyToClipboard(text) {
    Quickshell.clipboardText = text
  }

  // Copies a reference + text with the source attribution, then shows the
  // "Copied" feedback. Shared by the bible and verse-of-day copy actions.
  function copyWithSource(ref, text) {
    root.copyToClipboard(ref + " — " + text + "\n\nSource: " + root.sourceUrl)
    root.showCopyFeedback("Copied — " + ref)
  }

  function bibleCopyVerse(n, text) {
    var ref = ReaderModel.formatRef(root.activeBible, root.bibleBook, root.bibleChapter, n)
    root.copyWithSource(ref, text)
  }

  function verseOfDayCopy() {
    var ref = root.service ? root.service.todayReference : ""
    if (ref === "") ref = "Bible Verse of the Day"
    var text = root.verseOfDayText()
    if (text === "") return
    root.copyWithSource(ref, text)
  }

  Component.onCompleted: {
    // The translation (a ~4.7MB JSON blob) is not parsed here: parsing
    // synchronously on the UI thread stalls first paint. It loads lazily on
    // first visit via ensureTranslationLoaded() in open()/setTab().
    // Resolve symlinks in the state dir (readlink -f) before the state files
    // load. The state-file reloads run from stateDirResolve.onExited once the
    // canonical path is known, so their guards never validate the
    // un-canonicalized stateDir.
    stateDirResolve.running = true
  }

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root.barOwner
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: keyboardPanel.fittedContentWidth(root.expanded ? Style.space(760) : Style.space(520))
    contentHeight: keyboardPanel.fittedContentHeight(
      Math.max(bodyColumn.implicitHeight + Style.spacing.lg * 2, sidebarColumn.implicitHeight),
      root.expanded ? Style.space(900) : Style.space(640)
    )

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
        || translationDropdown.popupOpen
      onCloseRequested: {
        // The Strong's card is the innermost overlay: Esc closes it before
        // the panel itself. The popup's scrim does not steal focus, so the
        // catcher stays the focus owner while the card is open.
        if (strongsPopup.popupOpen) { root.closeStrongsPopup(); return }
        root.close()
      }
      onMoveRequested: function(dx, dy) {
        // Reader navigation gates on search focus, not query text: with text
        // still in the (unfocused) field, arrows must keep paging the reader.
        // The focused-field path is owned by SearchField's key handler, since
        // keyCatcher is `blocked` while the field has activeFocus.
        if (root.currentTab === "bible") {
          if (dx !== 0) root.bibleStepChapter(dx)
          if (dy < 0) root.bibleVerse = Math.max(1, root.bibleVerse - 1)
          if (dy > 0) root.bibleVerse = ReaderModel.clampVerse(root.activeBible, root.bibleBook, root.bibleChapter, root.bibleVerse + 1)
          if (dy !== 0) root.bibleScrollToVerse()
          return
        }
        if (dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: {
        if (root.currentTab === "bible" && root.query.trim() === "") { root.saveBibleStateIfLoaded(); return }
        root.activateSelected()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Background click target: a press on any non-interactive region (the
      // sidebar below the tab icons, margins) returns focus here so the search
      // field's activeFocus clears and `blocked` drops. Interactive elements
      // (verse/result MouseAreas, buttons) sit above this layer and
      // take their clicks first; the reader-body ones refocus keyCatcher
      // directly in their own onClicked handlers.
      MouseArea {
        anchors.fill: parent
        z: -1
        onPressed: keyCatcher.forceActiveFocus()
      }

      // Strong's definition card (KJV reader). The card and its scrim
      // reparent into this keyCatcher as overlays, above the dropdown list.
      // Esc (keyCatcher.onCloseRequested), the card's ✕, and clicks on the
      // scrim all funnel into onClosed -> closeStrongsPopup cleanup.
      StrongsPopup {
        id: strongsPopup
        keyCatcher: keyCatcher
        panel: root
        barForeground: root.barForeground
        foreground: root.foreground
        fontFamily: root.fontFamily
        number: root.strongsPopupNumber
        // Touch strongsDictionary explicitly: the entry lookup happens
        // inside a function call, so the binding needs the dependency read
        // in the binding itself to re-evaluate when the dictionary loads.
        entry: { root.strongsDictionary; return root.strongsEntryFor(root.strongsPopupNumber) }
        onClosed: root.strongsPopupClosed()
      }

      Row {
        anchors.fill: parent

        // ---- Sidebar --------------------------------------------------------
        Item {
          id: sidebar
          width: root.sidebarWidth
          height: parent.height

          Column {
            id: sidebarColumn
            width: parent.width
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.sm
            spacing: Style.spacing.xxs

            Repeater {
              model: [
                { icon: Qt.resolvedUrl("assets/star.svg"), tab: "verse", name: "Verse of the Day" },
                { icon: Qt.resolvedUrl("assets/bible.svg"), tab: "bible", name: "Bible" }
              ]
              delegate: NavItem {
                required property var modelData
                width: sidebarColumn.width
                iconSource: modelData.icon
                label: modelData.name
                active: root.currentTab === modelData.tab
                barForeground: root.barForeground
                foreground: root.foreground
                opacityPrimary: root.opacityPrimary
                opacitySecondary: root.opacitySecondary
                fontFamily: root.fontFamily
                onClicked: root.setTab(modelData.tab)
              }
            }
          }
        }

        // ---- Scrollable content --------------------------------------------
        Flickable {
          id: bodyScroll
          width: parent.width - sidebar.width
          height: parent.height
          clip: true
          contentWidth: width
          contentHeight: bodyColumn.implicitHeight + Style.spacing.lg * 2
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          Column {
            id: bodyColumn
            x: Style.spacing.lg
            y: Style.spacing.lg
            width: bodyScroll.width - Style.spacing.lg * 2
            spacing: Style.spacing.sm

            // ---- Minimal section header ------------------------------------
            // z:1 lifts the whole header (and the translation dropdown's
            // in-panel dropdown list) above the separator/search/results below,
            // which are later siblings and would otherwise draw on top.
            Row {
              z: 1
              width: parent.width
              spacing: Style.spacing.sm

              Column {
                width: parent.width - headerActions.width - parent.spacing
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  text: root.sectionTitle
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.sectionSubtitle
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: root.opacitySecondary
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Row {
                id: headerActions
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.sm

                // Global translation selector, inline next to the actions.
                TranslationDropdown {
                  id: translationDropdown
                  value: root.translation
                  translationOptions: root.translationOptions
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  opacitySecondary: root.opacitySecondary
                  keyCatcher: keyCatcher
                  bodyScroll: bodyScroll
                  panel: root
                  onChanged: function(v) { root.selectTranslation(v) }
                }

                NavButton {
                  glyph: root.expanded ? root.glyphs.collapse : root.glyphs.expand
                  barForeground: root.barForeground
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.expanded = !root.expanded
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: Util.alpha(root.barForeground, 0.10)
            }

            // ---- Search (bible) ----------------------------------------------
            Column {
              width: parent.width
              visible: root.currentTab === "bible"
              spacing: Style.spacing.md

              SearchField {
                id: searchField
                width: parent.width
                text: root.query
                placeholderText: "Search the Bible…"
                hasResults: resultModel.count > 0
                panel: root
                barForeground: root.barForeground
                closeGlyph: root.glyphs.close
                opacityPrimary: root.opacityPrimary
                opacitySecondary: root.opacitySecondary
                opacityTertiary: root.opacityTertiary
                fontFamily: root.fontFamily
                keyCatcher: keyCatcher
                onTextChanged: {
                  root.query = text
                  root.scheduleSearch()
                }
                onTextEdited: root.suppressSuggestions = false
                onActiveFocusChanged: {
                  if (activeFocus && text.trim() !== "") {
                    // root.query can drift from the visible text: openResult /
                    // setTab / selectTranslation clear root.query, but the
                    // `text: root.query` binding is broken once the user types,
                    // so the field keeps the old text while root.query is empty.
                    // Re-sync so the re-search runs against what the user sees.
                    root.query = text
                    // A completed suggestion left suppressSuggestions set; clear
                    // it so the re-search can repopulate the dropdown on refocus.
                    root.suppressSuggestions = false
                    if (root.suggestions.length === 0) root.scheduleSearch()
                  }
                }
                onNavigate: function(delta) { root.moveSelection(delta) }
                onClear: searchField.text = ""
              }

              Column {
                width: parent.width
                visible: searchField.activeFocus && root.suggestions.length > 0
                spacing: Style.spacing.xxs

                Repeater {
                  model: root.suggestions

                  delegate: Rectangle {
                    required property string modelData
                    width: parent.width
                    height: Style.spacing.controlHeight
                    radius: Style.cornerRadius
                    color: sugMouse.containsMouse
                      ? Style.hoverFillFor(root.barForeground, Color.accent)
                      : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.spacing.sm
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    MouseArea {
                      id: sugMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.applySuggestion(modelData)
                    }
                  }
                }
              }

              Row {
                width: parent.width
                visible: root.query.trim() !== ""
                spacing: Style.spacing.sm

                Text {
                  id: statusLabel
                  width: Math.min(Style.space(260), implicitWidth)
                  text: root.statusText
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: root.opacitySecondary
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Item {
                  width: Math.max(0, parent.width - statusLabel.width - keyboardHint.implicitWidth - Style.spacing.sm)
                  height: 1
                }

                Text {
                  id: keyboardHint
                  text: resultModel.count > 0 ? "↑ ↓  navigate" : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: root.opacityTertiary
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                width: parent.width
                height: Style.space(96)
                visible: root.query.trim() !== "" && resultModel.count === 0

                Text {
                  anchors.centerIn: parent
                  text: root.searching ? "Searching the Bible…" : "No matches"
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: root.opacitySecondary
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              ListView {
                id: resultScroll
                width: parent.width
                visible: root.query.trim() !== "" && resultModel.count > 0
                height: Math.min(Style.space(320), Math.max(Style.space(96), contentHeight))
                clip: true
                model: resultModel
                spacing: Style.spacing.xs
                boundsBehavior: Flickable.StopAtBounds
                onContentYChanged: {
                  // Reveal the next page once the user has scrolled ~20% down
                  // the list, so more results keep flowing in before the end.
                  // revealMore() is idempotent when nothing is left. A 20%
                  // threshold is used (not a bottom-adjacent one) because
                  // ListView virtualization makes contentHeight fluctuate
                  // during flicks, so a near-bottom threshold can land short
                  // of the true bottom — 20% is far enough up to always be
                  // crossed by any real scroll.
                  var scrollable = contentHeight - height
                  if (scrollable > 0 && contentY >= scrollable * 0.2)
                    root.revealMore()
                }

                delegate: Rectangle {
                  required property int index
                  required property string referenceHtml
                  required property string verseHtml

                  width: resultScroll.width
                  height: cardColumn.implicitHeight + Style.spacing.md * 2
                  radius: Style.cornerRadius
                  color: root.selectedIndex === index
                    ? Style.selectedFillFor(root.barForeground, Color.accent)
                    : "transparent"

                  Column {
                    id: cardColumn
                    anchors.fill: parent
                    anchors.margins: Style.spacing.md
                    spacing: Style.spacing.xs

                    Row {
                      width: parent.width

                      Text {
                        id: referenceLabel
                        text: referenceHtml
                        textFormat: Text.RichText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }

                      Item {
                        width: Math.max(0, parent.width - referenceLabel.implicitWidth - copyHint.implicitWidth - Style.spacing.sm)
                        height: 1
                      }

                      Text {
                        id: copyHint
                        text: "OPEN"
                        textFormat: Text.PlainText
                        color: root.foreground
                        opacity: root.opacityTertiary
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 0.8
                      }
                    }

                    Text {
                      width: parent.width
                      text: verseHtml
                      textFormat: Text.RichText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      lineHeight: 1.45
                      wrapMode: Text.WordWrap
                    }
                  }

                  Rectangle {
                    visible: index < resultModel.count - 1
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: Util.alpha(root.barForeground, 0.10)
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = index
                    onClicked: root.openResult(index)
                  }
                }
              }
            }

            // ---- Verse of the day -------------------------------------------
            Column {
              width: parent.width
              visible: root.currentTab === "verse"
              spacing: Style.spacing.md

              Text {
                width: parent.width
                text: root.service && root.service.todayReference !== "" ? root.service.todayReference : "Bible Verse of the Day"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
              }

              // The verse itself in a subtle card.
              Rectangle {
                width: parent.width
                height: verseBody.implicitHeight + Style.spacing.lg * 2
                radius: Style.cornerRadius
                color: Util.alpha(root.barForeground, 0.06)

                Text {
                  id: verseBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.lg
                  anchors.rightMargin: Style.spacing.lg
                  // Bind to the real dependencies (service + translations) so
                  // the text re-evaluates when the service is injected or the
                  // day rolls over. QML does not capture property reads made
                  // inside a called function, so a bare root.verseOfDayText()
                  // binding would not re-evaluate; touch the dependencies
                  // explicitly and delegate the value to verseOfDayText().
                  text: {
                    root.translations[root.translation]
                    root.service ? root.service.todayReference : ""
                    return root.verseOfDayText()
                  }
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  lineHeight: 1.55
                  wrapMode: Text.WordWrap
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.verseOfDayCopy()
                }
              }

              // Copy hint.
              Text {
                width: parent.width
                text: "Click the verse to copy"
                textFormat: Text.PlainText
                color: root.foreground
                opacity: root.opacityTertiary
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }

              CopyFeedback { copyFeedback: root.copyFeedback; fontFamily: root.fontFamily }

            }

            // ---- Bible reader -----------------------------------------------
            Column {
              width: parent.width
              visible: root.currentTab === "bible" && root.query.trim() === ""
              spacing: Style.spacing.sm
              topPadding: Style.spacing.lg

              ReaderHeader {
                title: ReaderModel.formatRef(root.activeBible, root.bibleBook, root.bibleChapter, 0)
                subtitle: "v. " + root.bibleVerse + "/" + root.bibleVerseCount
                positionValue: root.bibleVerse
                positionMax: root.bibleVerseCount
                positionLabelPrefix: "v. "
                showExtraButton: true
                extraButtonActive: root.bibleMode !== "read"
                showStrongsButton: root.translation === "kjv"
                strongsButtonActive: root.strongsNumbers
                barForeground: root.barForeground
                foreground: root.foreground
                fontFamily: root.fontFamily
                keyCatcher: keyCatcher
                onJump: function(target) { root.bibleGoTo(root.bibleBook, root.bibleChapter, target) }
                onPrev: root.bibleStepChapter(-1)
                onNext: root.bibleStepChapter(1)
                onExtraClicked: {
                  if (root.bibleMode === "books") {
                    root.bibleMode = "read"
                  } else {
                    root.bibleShowBooks(root.bibleBookMeta && root.bibleBookMeta.testament === "nt" ? "nt" : "ot")
                  }
                }
                onStrongsClicked: root.setStrongsNumbers(!root.strongsNumbers)
              }

              CenteredCopyFeedback { copyFeedback: root.copyFeedback; fontFamily: root.fontFamily }

              ListView {
                id: bibleVerseList
                width: parent.width
                height: root.readerHeight
                visible: root.bibleMode === "read"
                clip: true
                model: ReaderModel.verseObjectsFor(root.activeBible, root.bibleBook, root.bibleChapter)
                spacing: Style.space(10)
                boundsBehavior: Flickable.StopAtBounds
                QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                // Clicks in the viewport below the last verse land on the
                // ListView itself, which grabs them for drag detection and
                // would leave the search field focused. TapHandler passive-
                // grabs, so it clears focus without blocking flicking;
                // delegate MouseAreas exclusive-grab first and cancel it.
                TapHandler {
                  onTapped: keyCatcher.forceActiveFocus()
                }

                // Keep the position bar in sync with the scroll: as the user
                // scrolls, the current verse follows the verse nearest the
                // vertical center of the viewport.
                onContentYChanged: {
                  var idx = bibleVerseList.indexAt(0, bibleVerseList.contentY + bibleVerseList.height / 2)
                  if (idx >= 0) {
                    var verse = idx + 1
                    if (verse !== root.bibleVerse) root.bibleVerse = verse
                  }
                }

                delegate: Item {
                  required property var modelData
                  width: bibleVerseList.width
                  height: bibleVerseText.implicitHeight + Style.space(4)

                  // Strong's tokens for this verse, or null (plain-text
                  // fallback). QML does not capture property reads made
                  // inside a called function (see the verse-of-day text
                  // binding), so the dependencies are touched explicitly
                  // before delegating to strongsTokensFor; the one that
                  // matters most is strongsBook, which arrives async after
                  // the delegates already exist.
                  readonly property var strongsTokens: {
                    root.strongsNumbers
                    root.translation
                    root.strongsBook
                    root.bibleBook
                    root.bibleChapter
                    return root.strongsTokensFor(modelData.verse)
                  }

                  Text {
                    id: bibleVerseText
                    z: 1 // above the copy MouseArea so RichText links get their clicks
                    width: parent.width
                    // The delegate's plain-text color logic, resolved for the
                    // rich-text call (RichText ignores Text.color).
                    readonly property color runColor: modelData.verse === root.bibleVerse
                      ? Color.accent
                      : (modelData.omitted ? Color.muted : Color.foreground)
                    text: parent.strongsTokens !== null
                      ? root.strongsVerseHtml(modelData.verse, parent.strongsTokens, runColor.toString())
                      : modelData.verse + "  " + modelData.text
                    textFormat: parent.strongsTokens !== null ? Text.RichText : Text.PlainText
                    color: runColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.italic: modelData.omitted
                    lineHeight: 1.5
                    wrapMode: Text.WordWrap
                    // RichText links (the superscript Strong's numbers) are
                    // activated here; the copy MouseArea below sits beneath
                    // and only sees clicks that miss a link.
                    onLinkActivated: function(link) { root.openStrongsPopup(String(link)) }
                  }

                  // Copy action. Beneath the Text (z:1) so link clicks win;
                  // clicking anywhere else on the verse still selects, saves
                  // position, and copies.
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      keyCatcher.forceActiveFocus()
                      root.bibleVerse = modelData.verse
                      root.saveBibleStateIfLoaded()
                      root.bibleCopyVerse(modelData.verse, modelData.text)
                    }
                  }
                }
              }

              Column {
                width: parent.width
                visible: root.bibleMode === "books"
                spacing: Style.spacing.sm

                Row {
                  width: parent.width
                  spacing: Style.spacing.xs

                  TestamentButton {
                    width: (parent.width - parent.spacing) / 2
                    label: "Old Testament"
                    active: root.bibleTestament === "ot"
                    barForeground: root.barForeground
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.bibleShowBooks("ot")
                  }

                  TestamentButton {
                    width: (parent.width - parent.spacing) / 2
                    label: "New Testament"
                    active: root.bibleTestament === "nt"
                    barForeground: root.barForeground
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.bibleShowBooks("nt")
                  }
                }

                ListView {
                  id: bibleBooksList
                  width: parent.width
                  height: root.readerHeight
                  model: ReaderModel.booksForTestament(root.activeBible, root.bibleTestament)
                  clip: true
                  spacing: Style.spacing.xs
                  boundsBehavior: Flickable.StopAtBounds

                  delegate: Item {
                    required property var modelData
                    width: bibleBooksList.width
                    height: Style.space(32)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name
                      textFormat: Text.PlainText
                      color: modelData.id === root.bibleBook ? Color.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: modelData.id === root.bibleBook
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        keyCatcher.forceActiveFocus()
                        root.bibleSelectBook(modelData.id)
                      }
                    }
                  }
                }
              }

              GridView {
                id: bibleChaptersGrid
                width: parent.width
                height: root.readerHeight
                visible: root.bibleMode === "chapters"
                model: root.bibleChapterCount
                cellWidth: Style.space(40)
                cellHeight: Style.space(32)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                  required property int index
                  width: bibleChaptersGrid.cellWidth
                  height: bibleChaptersGrid.cellHeight

                  Text {
                    anchors.centerIn: parent
                    text: index + 1
                    textFormat: Text.PlainText
                    color: (index + 1) === root.bibleChapter ? Color.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: (index + 1) === root.bibleChapter
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      keyCatcher.forceActiveFocus()
                      root.bibleSelectChapter(index + 1)
                    }
                  }
                }
              }
            }

          }

          // Clicks on the reader body land on the Flickable, which grabs
          // them for drag detection and would leave the search field
          // focused. TapHandler passive-grabs, so it clears focus without
          // blocking flicking.
          TapHandler {
            onTapped: keyCatcher.forceActiveFocus()
          }
        }
      }
    }
  }
}
