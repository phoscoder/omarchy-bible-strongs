#!/usr/bin/env node
"use strict"

// convert-strongs.js — builds the Strong's data used by the KJV reader:
//
//   data/strongs-dictionary.json
//     { "H1": {lemma, xlit, pron, derivation, strongs_def, kjv_def}, ...,
//       "G1": {...} }
//     Generated from the openscriptures/strongs dictionaries (CC-BY-SA).
//
//   data/strongs/kjv/<Book>.json   (66 files, matching data/kjv.json's books)
//     { "translation": "kjv",
//       "book": "Genesis",
//       "chapters": [[verse, ...], ...] }
//     Each verse is an array of tokens: "word|H1234" or "word" (untagged),
//     or null when the tagged edition's text could not be aligned with
//     data/kjv.json's verse (the reader then falls back to plain text).
//
// The word|NUM format favors size: splitting on whitespace is all the reader
// does. Morphology tags ({(G5656)} tense/voice/mood codes) are dropped — only
// the primary lemma tags ({H7225}) are kept.
//
// data/kjv.json is NEVER modified by this script. Each verse's tagged text is
// normalized and compared against kjv.json; misaligned verses store null.
//
// Usage:
//   node scripts/convert-strongs.js --dict-dir ../strongs \
//         --tagged .tmp-kjv-Strong.raw.json

const fs = require("fs")
const path = require("path")

const ROOT = path.join(__dirname, "..")

// --- normalization ---------------------------------------------------------

// Strip Strong's tags from a tagged verse, returning plain KJV text.
// "{H7225}" and "{(H8804)}" both vanish; the latter is a grammar code, not a
// lemma, and carries no visible word.
function stripTags(text) {
  return String(text)
    .replace(/\{\(?[HG]\d+\)?\}/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

// Alignment normalization. The bundled kjv.json (scrollmapper) and the tagged
// edition (1769 KJV, "KJV Strong's + TVM") differ only in typography and a
// handful of spelling conventions; every difference found in the 31,102-verse
// corpus is covered by these rules (verified 31,094/31,102 exact after
// normalization; the remaining 8 are genuine edition variants -> stored null).
function normalizeForAlign(text) {
  return String(text)
    .replace(/[\u2018\u2019]/g, "'")   // curly -> straight apostrophes
    .replace(/,/g, "")                 // scrollmapper drops commas
    .replace(/[\u05d0-\u05ea]/g, "")   // Hebrew section letters (Ps 119)
    .replace(/[\u2013\u2014]/g, "-")   // en/em dash -> hyphen
    .replace(/-{2,}/g, "-")            // "--" (KJV italic marker) -> "-"
    .replace(/-/g, "")                 // beth-el == bethel
    .replace(/\(/g, " (")              // "(..." -> " (...": spaced parens
    .replace(/\s+/g, " ")
    .replace(/\(\s/g, "(")
    .toLowerCase()
    .replace(/ae/g, "e")               // judaea/judea, caesar/cesar, alphaeus/…
    .replace(/\u00e6/g, "e")           // ænon -> enon
    .replace(/[\[\]]/g, "")            // [but] == (but)
    .replace(/[;:]/g, ";")             // colon vs semicolon terminators
    .trim()
}

// --- tokenization ----------------------------------------------------------

// Corpus tag grammar (verified over all 31,102 verses of the tagged edition):
//   word{H1234}           word bound to its Strong's lemma
//   word{H123}{(H8804)}    lemma + grammar/morphology code (parenthesized or a
//                          plain H86xx/G56xx-range number; not a lemma)
//   word{H1}{H2}{H3}       one English word rendering multiple lemmas
//                          ("fifteen" = H7657+H8141+H2568): kept joined with +
//   {G3739}{G1161} word    leading tags bind forward to the next word
// Morphology/grammar codes are filtered by number range (not parentheses):
// the 54 non-parenthesized H86xx codes in the corpus are morphology too.
const TAG_RE = /\{\(?([HG]\d+)\)?\}/g

// Is this number a grammar/morphology code rather than a dictionary lemma?
// Hebrew H8602-H8764 (inflection codes) and Greek parsing codes (G5656 etc.,
// from G5200s+ inflection blocks) never appear as dictionary entries.
function _isMorphology(num) {
  const n = parseInt(num.slice(1), 10)
  if (num[0] === "H") return n >= 8600
  return n >= 5600
}

// Tokenize a tagged verse into wire tokens "word|NUM[+NUM…]" (or "word" for
// untagged words), such that joining the word parts with single spaces
// reproduces the verse text exactly (enforced per verse by the converter's
// round-trip check against stripTags).
//
// The scan tracks whether each emitted chunk was separated from its neighbor
// by a space in the RAW text. Chunks not separated by a space (tag-adjacent
// punctuation like "LORD{H3068}(for" -> "LORD" + "(for", or "law{H3618}.)"
// -> "law" + ".)") are glued back together, which reproduces the corpus's
// punctuation spacing without space-by-space guessing.
function tokenizeVerse(text) {
  const raw = String(text).replace(/\s+/g, " ").trim()
  if (raw === "") return null
  // parts: {word, nums, spaceBefore} — spaceBefore false means this part
  // began immediately after the previous part (or the verse start) with no
  // separating space in the raw text.
  const parts = []
  let pending = null // leading tag run awaiting its word
  let pos = 0
  let m
  TAG_RE.lastIndex = 0
  while ((m = TAG_RE.exec(raw)) !== null) {
    const num = _isMorphology(m[1]) ? null : m[1]
    // Gap text between the previous tag (or verse start) and this tag,
    // preserving whether it began with a space.
    const gapRaw = raw.slice(pos, m.index)
    const spaceBefore = /^\s/.test(gapRaw) || pos === 0
    const gap = gapRaw.trim()
    pos = m.index + m[0].length
    if (gap === "") {
      // No word between tags: stack the lemma onto the pending run (leading)
      // or the previous part's number list (trailing). Morphology (num ===
      // null) belongs to the run and changes nothing.
      if (num === null) continue
      if (pending !== null) { pending.push(num); continue }
      if (parts.length > 0) { parts[parts.length - 1].nums.push(num); continue }
      pending = [num]
      continue
    }
    // Split the gap on single spaces; each piece keeps whether it followed
    // the previous piece with a space.
    const pieces = _splitGapPieces(gap, spaceBefore)
    // The tag run binds to the last piece (a punct-only tail piece defers
    // the run to the piece before it; at verse start, forward).
    for (let i = 0; i < pieces.length; i++) {
      const piece = pieces[i]
      const isLast = i === pieces.length - 1
      if (isLast && _isPunctOnly(piece.word) && parts.length + i > 0) {
        // Punct-only tail: the tag binds to the piece BEFORE it, this piece
        // glues on after (it carries no number of its own here; the corpus
        // never tags a standalone punctuation piece).
        parts.push({ word: piece.word, nums: [], spaceBefore: piece.spaceBefore })
        continue
      }
      if (isLast) {
        const nums = pending ? pending.slice() : []
        pending = null
        if (num !== null) nums.push(num)
        parts.push({ word: piece.word, nums: nums, spaceBefore: piece.spaceBefore })
      } else {
        parts.push({ word: piece.word, nums: [], spaceBefore: piece.spaceBefore })
      }
    }
    if (pending !== null && parts.length > 0 && _isPunctOnly(parts[parts.length - 1].word)) {
      // The last piece was punct-only and consumed the run binding: bind the
      // run to the part before it instead.
      const punct = parts.pop()
      const target = parts[parts.length - 1]
      if (target) {
        for (const n of pending) target.nums.push(n)
        parts.push(punct)
      } else {
        parts.push(punct)
      }
      pending = null
    } else if (pending !== null) {
      pending = null // bound into the last piece above
    }
  }
  if (pending !== null) return null // leading tag with no word after it
  const tailRaw = raw.slice(pos)
  if (tailRaw.trim() !== "") {
    const pieces = _splitGapPieces(tailRaw.trim(), /^\s/.test(tailRaw) || pos === raw.length)
    for (const piece of pieces) parts.push({ word: piece.word, nums: [], spaceBefore: piece.spaceBefore })
  }
  if (parts.length === 0) return null
  const glued = _glue(parts)
  if (glued === null) return null
  return _render(glued)
}

// Split gap text on single spaces, tracking each piece's spaceBefore.
function _splitGapPieces(gap, firstSpaceBefore) {
  const out = []
  const words = gap.split(" ")
  for (let i = 0; i < words.length; i++) {
    if (words[i] === "") continue
    out.push({
      word: _cleanWord(words[i]),
      nums: [],
      spaceBefore: i === 0 ? firstSpaceBefore : true
    })
  }
  return out
}

// A gap word that is punctuation only.
const _PUNCT_ONLY = /^[.,;:!?%()'\u2019\u2014-]+$/
function _isPunctOnly(word) {
  return word !== "" && _PUNCT_ONLY.test(word)
}

// Glue parts that were not separated by a space in the raw text: merge each
// spaceBefore:false part into the one before it (word parts concatenate,
// number lists union). A leading spaceBefore:false at verse start (tag first)
// prefixes its word; the corpus has none, so treat it as a hard failure.
function _glue(parts) {
  const out = []
  for (const p of parts) {
    if (!p.spaceBefore && out.length === 0) return null
    if (!p.spaceBefore && out.length > 0) {
      const prev = out[out.length - 1]
      prev.word += p.word
      for (const n of p.nums) prev.nums.push(n)
      continue
    }
    out.push({ word: p.word, nums: p.nums })
  }
  return out
}

// Render {word, nums} parts to the wire format: "word" or "word|H1+H2".
function _render(parts) {
  const out = []
  for (const p of parts) out.push(p.nums.length === 0 ? p.word : p.word + "|" + p.nums.join("+"))
  return out
}

// Escape the token separator inside a word (the corpus has none, but stay
// defensive so a stray "|" cannot desync the reader's split).
function _cleanWord(word) {
  return String(word).replace(/\|/g, "/")
}

// The word part of a wire token (before "|").
function _wordPart(token) {
  const i = token.indexOf("|")
  return i === -1 ? token : token.slice(0, i)
}

// --- dictionary ------------------------------------------------------------

// Parse the bundled data/strongsgreek.dat ASCII file into a map of
// G<number> -> {translit, pron}. The file format is:
//
//   $$T0000001
//   \00001\
//    1  a  al'-fah
//
//    of Hebrew origin; ...
//
// The header line after the \\NUMBER\\ marker is: "<number>  <translit>  <pron>".
function parseGreekDat(datPath) {
  const text = fs.readFileSync(datPath, "utf8")
  const out = {}
  // Split on $$T markers; the first chunk is the file preamble.
  const blocks = text.split(/^\$\$T\d+\s*$/m)
  for (let i = 1; i < blocks.length; i++) {
    const block = blocks[i]
    // Find the backslash-delimited number line.
    const numMatch = block.match(/^\\0*(\d+)\\\s*$/m)
    if (!numMatch) continue
    const num = parseInt(numMatch[1], 10)
    // The next non-empty line is the transliteration/pronunciation header.
    const rest = block.slice(numMatch.index + numMatch[0].length)
    const headerMatch = rest.match(/^\s*(\d+)\s+(\S.*?)\s+(\S.*?)\s*$/m)
    if (!headerMatch) continue
    const key = "G" + num
    out[key] = {
      translit: headerMatch[2].trim(),
      pron: headerMatch[3].trim()
    }
  }
  return out
}

function buildDictionary(dictDir, greekDatPath) {
  const hebrew = require(path.join(dictDir, "hebrew/strongs-hebrew-dictionary.js"))
  const greek = require(path.join(dictDir, "greek/strongs-greek-dictionary.js"))
  const greekExtras = greekDatPath ? parseGreekDat(greekDatPath) : null
  const out = {}
  let h = 0, g = 0
  for (const key of Object.keys(hebrew)) {
    out[key] = _cleanEntry(hebrew[key], null)
    h++
  }
  for (const key of Object.keys(greek)) {
    out[key] = _cleanEntry(greek[key], greekExtras ? greekExtras[key] : null)
    g++
  }
  return { entries: out, hebrew: h, greek: g }
}

// Keep the display fields; drop null/empty ones to save space. lemma is
// mandatory (the source always has it); the rest are best-effort.
function _cleanEntry(entry, greekExtras) {
  const fields = ["lemma", "xlit", "pron", "derivation", "strongs_def", "kjv_def"]
  const o = {}
  if (!entry || typeof entry.lemma !== "string" || entry.lemma.trim() === "") return null
  for (const f of fields) {
    const v = entry[f]
    if (typeof v === "string" && v.trim() !== "") o[f] = v.trim()
  }
  // The openscriptures Greek JSON uses 'translit' instead of 'xlit' and has no
  // pronunciation. The bundled strongsgreek.dat ASCII file supplies both, so
  // merge them in here so the popup renders Greek words the same way as
  // Hebrew words (xlit + pron).
  if (greekExtras) {
    if (typeof greekExtras.translit === "string" && greekExtras.translit.trim() !== "") {
      o.xlit = greekExtras.translit.trim()
    }
    if (typeof greekExtras.pron === "string" && greekExtras.pron.trim() !== "") {
      o.pron = greekExtras.pron.trim()
    }
  }
  // Fallback to translit when the JSON uses that field name directly.
  if (typeof entry.translit === "string" && entry.translit.trim() !== "" && !o.xlit) {
    o.xlit = entry.translit.trim()
  }
  return o.lemma ? o : null
}

// --- tagged books ----------------------------------------------------------

function buildTaggedBooks(taggedPath, kjvPath, report) {
  const tagged = JSON.parse(fs.readFileSync(taggedPath, "utf8"))
  const kjv = JSON.parse(fs.readFileSync(kjvPath, "utf8"))

  // Group tagged verses by book name.
  const byBook = {}
  for (const key of Object.keys(tagged.verses)) {
    const v = tagged.verses[key]
    if (!v.book_name || typeof v.chapter !== "number" || typeof v.verse !== "number") continue
    ;(byBook[v.book_name] = byBook[v.book_name] || []).push(v)
  }

  const files = []
  let aligned = 0, misaligned = 0, taggedVerses = 0

  for (const book of kjv.books) {
    const src = byBook[book.name] || []
    const chapters = []
    for (let c = 0; c < book.chapters.length; c++) {
      const chapter = new Array(book.chapters[c].length).fill(null)
      chapters.push(chapter)
    }
    for (const v of src) {
      if (v.chapter < 1 || v.chapter > chapters.length) continue
      const chapter = chapters[v.chapter - 1]
      if (v.verse < 1 || v.verse > chapter.length) continue
      const cell = book.chapters[v.chapter - 1][v.verse - 1]
      if (typeof cell !== "string" || cell.trim() === "") { misaligned++; continue }
      if (normalizeForAlign(stripTags(v.text)) !== normalizeForAlign(cell)) {
        misaligned++
        report.misaligned.push(book.name + " " + v.chapter + ":" + v.verse)
        continue
      }
      const tokens = tokenizeVerse(v.text)
      if (tokens === null) {
        misaligned++
        report.unparseable.push(book.name + " " + v.chapter + ":" + v.verse)
        continue
      }
      // Round-trip: joining the WORD parts of the tokens with single spaces
      // must reproduce the tagged edition's text exactly, so the reader's
      // simple space-join rendering is guaranteed faithful (and punctuation
      // merging has not dropped or doubled anything).
      const wordsOnly = tokens.map((t) => _wordPart(t)).join(" ")
      if (wordsOnly !== stripTags(v.text).replace(/\s+/g, " ").trim()) {
        misaligned++
        report.unparseable.push(book.name + " " + v.chapter + ":" + v.verse + " (round-trip)")
        continue
      }
      chapter[v.verse - 1] = tokens
      aligned++
      if (tokens.length > 0) taggedVerses++
    }
    // Drop trailing all-null chapters never referenced (kjv.json has none).
    const out = { translation: "kjv", book: book.name, chapters: chapters }
    const file = path.join(ROOT, "data", "strongs", "kjv", book.name + ".json")
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, JSON.stringify(out))
    files.push(file)
  }
  return { files, aligned, misaligned, taggedVerses, total: Object.keys(tagged.verses).length }
}

// --- CLI -------------------------------------------------------------------

function argValue(args, flag) {
  const i = args.indexOf(flag)
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null
}

function main(argv) {
  const args = argv.slice(2)
  const dictDir = argValue(args, "--dict-dir") || path.join(ROOT, "..", "strongs")
  const taggedPath = argValue(args, "--tagged") || path.join(ROOT, ".tmp-kjv-Strong.raw.json")
  const greekDatPath = argValue(args, "--greek-dat") || path.join(ROOT, "data", "strongsgreek.dat")
  const kjvPath = path.join(ROOT, "data", "kjv.json")

  if (!fs.existsSync(path.join(dictDir, "hebrew"))) {
    console.error("convert-strongs: missing " + dictDir + "/hebrew (pass --dict-dir ../strongs)")
    process.exit(1)
  }
  if (!fs.existsSync(path.join(dictDir, "greek"))) {
    console.error("convert-strongs: missing " + dictDir + "/greek (pass --dict-dir ../strongs)")
    process.exit(1)
  }
  if (!fs.existsSync(taggedPath)) {
    console.error("convert-strongs: missing " + taggedPath + " (pass --tagged <kjv-Strong json>)")
    process.exit(1)
  }
  if (!fs.existsSync(greekDatPath)) {
    console.warn("convert-strongs: missing " + greekDatPath + " — Greek entries will not have transliteration/pronunciation (pass --greek-dat <strongsgreek.dat>)")
  }

  const dict = buildDictionary(dictDir, fs.existsSync(greekDatPath) ? greekDatPath : null)
  const dictFile = path.join(ROOT, "data", "strongs-dictionary.json")
  fs.writeFileSync(dictFile, JSON.stringify(dict.entries))
  console.log("wrote " + path.relative(ROOT, dictFile) + " — " +
    dict.hebrew + " Hebrew / " + dict.greek + " Greek entries, " +
    fs.statSync(dictFile).size + " bytes")

  const report = { misaligned: [], unparseable: [] }
  const books = buildTaggedBooks(taggedPath, kjvPath, report)
  console.log("wrote " + books.files.length + " tagged books to data/strongs/kjv/ — " +
    books.aligned + "/" + books.total + " verses aligned (" + books.misaligned + " -> null)")
  for (const ref of report.misaligned) console.log("  misaligned: " + ref)
  for (const ref of report.unparseable) console.log("  unparseable: " + ref)

  // Every kept tag must resolve to a dictionary entry (the reader shows a
  // definition card for each number; a dangling one would render a dead link).
  let dangling = 0
  for (const file of books.files) {
    const data = JSON.parse(fs.readFileSync(file, "utf8"))
    for (const chapter of data.chapters) {
      for (const tokens of chapter) {
        if (!tokens) continue
        for (const t of tokens) {
          const i = t.indexOf("|")
          if (i === -1) continue
          for (const num of t.slice(i + 1).split("+")) {
            if (!dict.entries[num]) { dangling++; console.error("  dangling " + num + " in " + data.book) }
          }
        }
      }
    }
  }
  if (dangling > 0) {
    console.error("convert-strongs: " + dangling + " tags without a dictionary entry")
    process.exit(1)
  }
  console.log("all tagged numbers resolve to dictionary entries")
}

try {
  main(process.argv)
} catch (e) {
  console.error("convert-strongs:", e.message)
  process.exit(1)
}