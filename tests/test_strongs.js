// Unit tests for the Strong's data (dictionary + tagged KJV books).
// Run with: node tests/test_strongs.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")

const ROOT = path.join(__dirname, "..")
const DATA = path.join(ROOT, "data")

function test(name, fn) {
  try { fn(); console.log("ok - " + name) }
  catch (e) { console.error("FAIL - " + name); console.error(e); process.exitCode = 1 }
}

function load(name) {
  return JSON.parse(fs.readFileSync(path.join(DATA, name), "utf8"))
}

// --- dictionary ------------------------------------------------------------

const dict = load("strongs-dictionary.json")

test("dictionary entry counts (8674 Hebrew / 5523 Greek)", () => {
  let h = 0, g = 0
  for (const key of Object.keys(dict)) {
    if (key[0] === "H") h++
    else if (key[0] === "G") g++
    else assert.fail("unexpected key prefix: " + key)
  }
  assert.strictEqual(h, 8674)
  assert.strictEqual(g, 5523)
})

test("dictionary key format (H/G + 1-4 digits, no padding)", () => {
  for (const key of Object.keys(dict)) {
    assert.ok(/^[HG]\d{1,4}$/.test(key), "bad key: " + key)
  }
})

test("dictionary entries carry lemma and at least one definition field", () => {
  for (const key of Object.keys(dict)) {
    const e = dict[key]
    assert.strictEqual(typeof e.lemma, "string", key + " lemma missing")
    assert.ok(e.lemma.trim() !== "", key + " lemma blank")
    assert.ok(typeof e.strongs_def === "string" || typeof e.derivation === "string",
      key + " has neither strongs_def nor derivation")
  }
})

test("dictionary spot checks (H1 father, H3068 YHWH, G26 agape, G2316 theos)", () => {
  assert.strictEqual(dict.H1.lemma, "אָב")
  assert.ok(dict.H1.strongs_def.indexOf("father") !== -1)
  assert.strictEqual(dict.H3068.lemma, "יְהֹוָה")
  assert.ok(dict.H3068.strongs_def.indexOf("Jehovah") !== -1)
  assert.ok(dict.G26.lemma.indexOf("\u1f00\u03b3\u03ac\u03c0\u03b7") !== -1) // ἀγάπη
  assert.ok(dict.G26.strongs_def.indexOf("love") !== -1)
  assert.strictEqual(dict.G2316.lemma, "\u03b8\u03b5\u03cc\u03c2") // θεός
})

// --- tagged books ----------------------------------------------------------

const kjv = load("kjv.json")
const strongsDir = path.join(DATA, "strongs", "kjv")

test("66 tagged book files match kjv.json's books", () => {
  for (const b of kjv.books) {
    const file = path.join(strongsDir, b.name + ".json")
    assert.ok(fs.existsSync(file), "missing " + file)
    const data = JSON.parse(fs.readFileSync(file, "utf8"))
    assert.strictEqual(data.translation, "kjv")
    assert.strictEqual(data.book, b.name)
    // Chapter/verse shape parity: same chapter count, same verse slots.
    assert.strictEqual(data.chapters.length, b.chapters.length, b.name + " chapter count")
    for (let c = 0; c < b.chapters.length; c++) {
      assert.strictEqual(data.chapters[c].length, b.chapters[c].length,
        b.name + " " + (c + 1) + " verse count")
    }
  }
})

test("no unexpected extra book files", () => {
  const files = fs.readdirSync(strongsDir).filter((f) => f.endsWith(".json"))
  assert.strictEqual(files.length, 66)
})

const NUM_RE = /^[HG]\d{1,4}$/

test("every tag resolves to a dictionary entry and tags are well-formed", () => {
  for (const b of kjv.books) {
    const data = JSON.parse(fs.readFileSync(path.join(strongsDir, b.name + ".json"), "utf8"))
    for (let c = 0; c < data.chapters.length; c++) {
      for (let v = 0; v < data.chapters[c].length; v++) {
        const tokens = data.chapters[c][v]
        if (tokens === null) continue
        assert.ok(Array.isArray(tokens), b.name + " " + (c + 1) + ":" + (v + 1) + " not array/null")
        for (const t of tokens) {
          assert.strictEqual(typeof t, "string", b.name + " " + (c + 1) + ":" + (v + 1) + " token not string")
          const i = t.indexOf("|")
          if (i === -1) continue
          assert.ok(i > 0, b.name + " " + (c + 1) + ":" + (v + 1) + " empty word part")
          for (const num of t.slice(i + 1).split("+")) {
            assert.ok(NUM_RE.test(num), b.name + " " + (c + 1) + ":" + (v + 1) + " bad number " + num)
            assert.ok(dict[num] !== undefined, b.name + " " + (c + 1) + ":" + (v + 1) + " dangling " + num)
          }
        }
      }
    }
  }
})

test("tagged verses reproduce kjv.json text when tags are stripped", () => {
  // Spot verses (full-corpus alignment is the converter's job; the reader
  // only guarantees that where tokens exist, the words are the verse).
  // Equality uses the converter's alignment normalization: the bundled
  // kjv.json and the tagged edition differ in typography only (commas,
  // LORD/Lord casing, ae/e spellings).
  const norm = (s) => s
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/,/g, "")
    .replace(/[\u05d0-\u05ea]/g, "")
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/-/g, "")
    .replace(/\(/g, " (")
    .replace(/\s+/g, " ")
    .replace(/\(\s/g, "(")
    .toLowerCase()
    .replace(/ae/g, "e")
    .replace(/\u00e6/g, "e")
    .replace(/[\[\]]/g, "")
    .replace(/[;:]/g, ";")
    .trim()
  const spots = [
    ["Genesis", 1, 1],
    ["Genesis", 1, 2],
    ["Genesis", 25, 7],   // multi-lemma tokens
    ["Exodus", 9, 28],    // "LORD(for" punctuation glue
    ["Joshua", 19, 2],    // one of the null fallbacks
    ["Psalms", 23, 1],
    ["Isaiah", 53, 5],
    ["Matthew", 5, 3],
    ["John", 3, 16],
    ["John", 11, 2],      // null fallback (leading tag + unspaced paren)
    ["Romans", 8, 28],
    ["Revelation", 22, 21]
  ]
  for (const [name, c, v] of spots) {
    const book = kjv.books.find((b) => b.id === name)
    const data = JSON.parse(fs.readFileSync(path.join(strongsDir, name + ".json"), "utf8"))
    const tokens = data.chapters[c - 1][v - 1]
    const text = book.chapters[c - 1][v - 1]
    if (tokens === null) {
      // null fallback: at least confirm the kjv.json verse exists (the
      // reader renders its plain text).
      assert.strictEqual(typeof text, "string", name + " " + c + ":" + v + " missing in kjv.json")
      continue
    }
    const joined = tokens.map((t) => {
      const i = t.indexOf("|")
      return i === -1 ? t : t.slice(0, i)
    }).join(" ")
    assert.strictEqual(norm(joined), norm(text), name + " " + c + ":" + v + " text mismatch")
  }
})

test("known-null verses store null (edition variants fall back to plain text)", () => {
  // The converter's alignment report lists exactly these verses as null.
  const nulls = [
    ["Joshua", 19, 2],
    ["Romans", 4, 18],
    ["Galatians", 6, 18],
    ["Ephesians", 6, 24],
    ["Philippians", 4, 23],
    ["Colossians", 4, 18],
    ["1 Thessalonians", 5, 28],
    ["1 John", 2, 23],
    ["John", 11, 2]
  ]
  for (const [name, c, v] of nulls) {
    const data = JSON.parse(fs.readFileSync(path.join(strongsDir, name + ".json"), "utf8"))
    assert.strictEqual(data.chapters[c - 1][v - 1], null, name + " " + c + ":" + v + " expected null")
  }
})

test("null rate is tiny (alignment held)", () => {
  let total = 0, nulls = 0
  for (const b of kjv.books) {
    const data = JSON.parse(fs.readFileSync(path.join(strongsDir, b.name + ".json"), "utf8"))
    for (const ch of data.chapters) {
      for (const t of ch) {
        total++
        if (t === null) nulls++
      }
    }
  }
  assert.strictEqual(total, 31102)
  assert.ok(nulls <= 12, "null count grew: " + nulls)
})

test("spot checks: John 3:16 and Genesis 1:1 carry the right numbers", () => {
  const john = JSON.parse(fs.readFileSync(path.join(strongsDir, "John.json"), "utf8"))
  const j316 = john.chapters[2][15]
  assert.ok(j316.some((t) => t === "God|G2316"), "God|G2316 missing in John 3:16")
  assert.ok(j316.some((t) => t === "loved|G25"), "loved|G25 missing in John 3:16")
  assert.ok(j316.some((t) => t === "life.|G2222"), "life.|G2222 missing in John 3:16")

  const gen = JSON.parse(fs.readFileSync(path.join(strongsDir, "Genesis.json"), "utf8"))
  const g111 = gen.chapters[0][0]
  assert.ok(g111.some((t) => t === "beginning|H7225"), "beginning|H7225 missing in Genesis 1:1")
  assert.ok(g111.some((t) => t === "God|H430"), "God|H430 missing in Genesis 1:1")
  assert.ok(g111.some((t) => t === "created|H1254+H853"), "created|H1254+H853 missing in Genesis 1:1")
  assert.ok(g111.some((t) => t === "earth.|H776"), "earth.|H776 missing in Genesis 1:1")
})

console.log("done")