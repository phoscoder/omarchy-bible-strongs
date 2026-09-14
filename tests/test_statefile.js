#!/usr/bin/env node
"use strict"
// Security + behavior tests for bin/omarchy-statefile. Each case exercises a
// property the QML side relies on: the pinned-ancestor walk (no symlinked or
// traversed ancestor), check-and-use leaf validation (uid/nlink/mode/type/
// size in the one open), atomic writes, and refusal paths. Runs entirely
// under /tmp — nothing outside the tree or /tmp is touched.

const { execFileSync, spawnSync } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")

const HELPER = path.join(__dirname, "..", "bin", "omarchy-statefile")
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "statefile-test-"))
const DIR = path.join(ROOT, "settings")
const FILE = path.join(DIR, "bible-state.json")

let passed = 0
let failed = 0

function ok(name, cond, detail) {
  if (cond) { passed++; console.log("  ok " + name) }
  else { failed++; console.error("  FAIL " + name + (detail ? " — " + detail : "")) }
}

function run(mode, target, payload) {
  const args = [mode, target]
  if (payload !== undefined) args.push(payload)
  return spawnSync("/usr/bin/node", [HELPER, ...args], { encoding: "buffer" })
}

function refuse(name, mode, target, payload) {
  const r = run(mode, target, payload)
  ok(name, r.status !== 0 && r.status !== null,
    "expected refusal, got status " + r.status + " stderr=" + String(r.stderr || ""))
}

function expectExit0(name, mode, target, payload) {
  const r = run(mode, target, payload)
  ok(name, r.status === 0, "expected exit 0, got " + r.status + " stderr=" + String(r.stderr || ""))
  return r
}

// ---- 1. Round trip ---------------------------------------------------------

fs.mkdirSync(DIR, 0o700, { recursive: true })
const payload = JSON.stringify({ translations: { kjv: { book: "John" } } })
expectExit0("write creates state file", "write", FILE, payload)
const rd = run("read", FILE)
ok("read returns exact payload + trailing newline",
  rd.stdout.toString() === payload + "\n", JSON.stringify(rd.stdout.toString()))

// The trailing newline is tolerated by the QML side's JSON.parse.
try { JSON.parse(rd.stdout.toString()); ok("output parses as JSON", true) }
catch (e) { ok("output parses as JSON", false, String(e)) }

// ---- 2. Refusals: name policy, traversal, relative paths -------------------

refuse("refuse leaf outside allowlist", "write", path.join(DIR, "evil.json"), "x")
refuse("refuse ../ traversal in dir part", "write", path.join(DIR, "..", "..", "evil.json"), "x")
refuse("refuse .. leaf", "write", path.join(DIR, ".."), "x")
refuse("refuse relative path", "read", "bible-state.json")
refuse("refuse empty-ish target dir", "read", "bible-state.json")
refuse("refuse bad mode", "rm", FILE)

// ---- 3. Leaf symlink refused (O_NOFOLLOW on the leaf) ----------------------

const linkTarget = path.join(ROOT, "outside.json")
fs.writeFileSync(linkTarget, "planted")
const leafLink = path.join(DIR, "bible-tab-state.json")
fs.symlinkSync(linkTarget, leafLink)
refuse("read refuses planted leaf symlink", "read", leafLink)
expectExit0("write atomically replaces planted leaf symlink", "write", leafLink, "x")
ok("planted symlink gone (rename replaced it, never followed it)",
  fs.lstatSync(leafLink).isFile() && fs.readFileSync(leafLink).toString() === "x"
  && fs.readFileSync(linkTarget).toString() === "planted")

// ---- 4. Ancestor symlink refused (no traversal through a symlinked dir) ----

const outsideDir = path.join(ROOT, "outside-dir")
fs.mkdirSync(outsideDir)
fs.writeFileSync(path.join(outsideDir, "bible-state.json"), "planted")
const ancestorLink = path.join(ROOT, "settings-link")
fs.symlinkSync(outsideDir, ancestorLink)
refuse("read refuses symlinked ancestor", "read", path.join(ancestorLink, "bible-state.json"))
ok("planted file behind ancestor symlink untouched",
  fs.readFileSync(path.join(outsideDir, "bible-state.json")).toString() === "planted")

// ---- 5. Hardlinked leaf refused (nlink !== 1) ------------------------------

const hardlinkTwin = path.join(ROOT, "twin.json")
fs.writeFileSync(FILE, payload)
fs.linkSync(FILE, hardlinkTwin)
refuse("read refuses hardlinked leaf", "read", FILE)
fs.unlinkSync(hardlinkTwin)
ok("read succeeds again once nlink is back to 1",
  run("read", FILE).status === 0)

// ---- 6. Foreign/group-writable leaf refused --------------------------------

if (process.getuid() !== 0) {
  const before = fs.readFileSync(FILE)
  fs.chmodSync(FILE, 0o664)
  refuse("read refuses group-writable leaf", "read", FILE)
  fs.chmodSync(FILE, 0o600)
  fs.writeFileSync(FILE, payload)
  ok("read succeeds again once mode is 0600", run("read", FILE).status === 0)
  // Foreign-owned leaf: chown requires privileges, so only attempt as root.
}

// ---- 7. Group-writable ancestor dir refused --------------------------------

fs.chmodSync(DIR, 0o775)
refuse("read refuses group-writable parent dir", "read", FILE)
fs.chmodSync(DIR, 0o700)
ok("read succeeds again once parent is 0700", run("read", FILE).status === 0)

// ---- 8. FIFO at the leaf refused without hanging ---------------------------

const fifoLeaf = path.join(DIR, "bible-tab-state.json")
fs.rmSync(fifoLeaf, { force: true })
try { fs.unlinkSync(leafLink) } catch (e) {}
fs.mkfifoSync ? fs.mkfifoSync(fifoLeaf, 0o600) : execFileSync("mkfifo", [fifoLeaf])
const fifoR = run("read", fifoLeaf)
ok("read refuses FIFO at leaf without hanging",
  fifoR.status !== 0 && fifoR.status !== null, "status " + fifoR.status)
fs.rmSync(fifoLeaf, { force: true })

// ---- 9. Oversized payload refused ------------------------------------------

refuse("write refuses payload over MAX_BYTES", "write", FILE, "x".repeat(70000))
ok("oversized write left file untouched", fs.readFileSync(FILE).toString() === payload)

// A file that grew past MAX_BYTES server-side is refused on read.
const bigLeaf = path.join(DIR, "bible-tab-state.json")
fs.writeFileSync(bigLeaf, "y".repeat(70000))
refuse("read refuses oversized on-disk leaf", "read", bigLeaf)
fs.rmSync(bigLeaf, { force: true })

// ---- 10. Missing file / missing dir ---------------------------------------

const missingLeaf = path.join(DIR, "bible-tab-state.json")
refuse("read of missing file exits nonzero", "read", missingLeaf)
refuse("read through missing deep dir exits nonzero (no auto-mkdir of foreign roots)",
  "read", "/nonexistent-statefile-test/deeper/bible-state.json")

// ---- 11. Auto-creation of the final dir + atomic write --------------------

const deepDir = path.join(ROOT, "a/b/c")
const deepFile = path.join(deepDir, "bible-state.json")
expectExit0("write auto-creates missing final dir (created through pinned fds)",
  "write", deepFile, payload)
ok("created dir has restrictive mode",
  (fs.statSync(deepDir).mode & 0o777) === 0o700,
  (fs.statSync(deepDir).mode & 0o777).toString(8))
ok("write through auto-created dir round-trips",
  run("read", deepFile).stdout.toString() === payload + "\n")

// ---- 12. Temp files never collide or leak ----------------------------------

const before = fs.readdirSync(DIR).filter(function(n) { return n.startsWith(".") })
expectExit0("write #1", "write", FILE, payload)
expectExit0("write #2 (nonce prevents stranded-pid collision)", "write", FILE, payload)
const after = fs.readdirSync(DIR).filter(function(n) { return n.startsWith(".") })
ok("no temp files left behind", before.length === after.length && after.every(function(n, i) { return n === before[i] }),
  JSON.stringify(after))

// ---- 13. Missing interpreter is a clean failure ----------------------------

const noNode = spawnSync(HELPER, ["read", FILE], { env: {} })
ok("helper with empty env still runs (absolute interpreter)",
  noNode.status === 0, "status " + noNode.status + " stderr=" + String(noNode.stderr || ""))

// ---- Summary ----------------------------------------------------------------

fs.rmSync(ROOT, { recursive: true, force: true })
console.log("\n" + passed + " passed, " + failed + " failed")
process.exit(failed === 0 ? 0 : 1)