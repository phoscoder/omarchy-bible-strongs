import QtQuick
import Quickshell.Io

// Shared reader for the panel's two JSON state files. All disk access goes
// through bin/omarchy-statefile, which is the security boundary: it performs
// check-and-use in a single open (O_NOFOLLOW on the leaf, O_DIRECTORY|O_NOFOLLOW
// on every ancestor pinned via /proc/self/fd, fstat + read on that same fd),
// so no separate validation step can race a path swap — a symlinked, oversized,
// special (FIFO/device), hardlinked, or foreign-owned state file is refused in
// the one open that reads it. Writes land in a temp file inside the pinned dir
// and are atomically renamed over the leaf (rename replaces a symlink, never
// follows it).
//
// The command pins /usr/bin/node explicitly (no ambient env/PATH lookup), and
// helper output is streamed live through a line parser with a hard byte cap
// and a deadline timer — a runaway or wedged helper is killed and reported as
// failed(), never buffered without bound.
//
// autoload fires one reload() at component completion, so the panel loads its
// state files directly at startup (no canonicalization pass).
//
// restored(parsed) fires after a successful read with the parsed JSON object
// (or null when JSON.parse threw); failed() fires when the helper exited
// nonzero, crashed, was killed by the deadline, or streamed past the byte cap
// (missing/refused/unreadable file). setText() stages the latest text and
// flushes it through the writer when the previous write finishes, so a burst
// of saves collapses to the trailing value without dropping it.
Item {
  id: root

  required property string path
  required property string helperPath

  // Pinned interpreter: the helper runs under /usr/bin/node so neither a
  // shebang nor PATH resolution is ever consulted at runtime.
  readonly property string nodePath: "/usr/bin/node"
  // Hard cap on buffered helper output; matches bin/omarchy-statefile's
  // MAX_BYTES (its reads are additionally capped server-side).
  readonly property int maxBytes: 65536
  // Hard deadline for a helper operation; a wedged read/write is killed.
  readonly property int opTimeoutMs: 5000

  // Fire one reload() when the component completes.
  property bool autoload: false

  signal restored(var parsed)
  signal failed()

  // Latest text awaiting a free writer; cleared by flushPendingWrite() the
  // moment it is dispatched so a save arriving mid-write is not lost.
  property string pendingText: ""
  // Text currently being written by writeProc; captured at dispatch so a
  // failed write can re-stage the exact value that was just lost (see
  // writeFailed()).
  property string inFlightText: ""

  // Live byte count of helper stdout buffered for readProc; reset on
  // dispatch, enforced in onRead, so output is capped as it streams.
  property int readBytes: 0
  // Accumulated helper stdout (up to maxBytes); reset on dispatch.
  property string readText: ""
  // True once this read has already been reported as failed() (deadline or
  // byte cap), so its onExited does not report a second failure or a
  // spurious restored().
  property bool readReported: false
  // True once the deadline killed writeProc, so its onExited treats the
  // exit as a failure even when the kill left a zero exit code.
  property bool writeReported: false

  Component.onCompleted: if (root.autoload) root.reload()

  function reload() {
    if (readProc.running) return
    root.readBytes = 0
    root.readText = ""
    root.readReported = false
    opDeadline.restart()
    readProc.command = [root.nodePath, root.helperPath, "read", root.path]
    readProc.running = true
  }

  function setText(text) {
    root.pendingText = text
    if (!writeProc.running) root.flushPendingWrite()
  }

  function flushPendingWrite() {
    if (root.pendingText === "") return
    var t = root.pendingText
    root.pendingText = ""
    root.inFlightText = t
    root.writeReported = false
    opDeadline.restart()
    writeProc.command = [root.nodePath, root.helperPath, "write", root.path, t]
    writeProc.running = true
  }

  // Shared failure path for readProc (cap or deadline): reports exactly
  // once via readReported; onExited() is a no-op after it.
  function readFailed() {
    opDeadline.stop()
    root.readReported = true
    root.readBytes = 0
    root.readText = ""
    root.failed()
  }

  function writeFailed(exitCode) {
    opDeadline.stop()
    // Re-stage the value this write just lost so the next setText()/flush
    // retries it; do not retry here (a failing path would loop forever).
    if (root.pendingText === "") root.pendingText = root.inFlightText
    root.inFlightText = ""
    console.warn("StateFile write failed (exit " + exitCode + "): " + root.path)
  }

  Timer {
    id: opDeadline
    interval: root.opTimeoutMs
    running: false
    repeat: false
    onTriggered: {
      // Either operation missing its deadline is a failure: kill the
      // helper. The exited() handler still fires, but the report flags are
      // set first so the failure is recorded exactly once.
      if (readProc.running) {
        readProc.running = false
        root.readFailed()
      }
      if (writeProc.running) {
        root.writeReported = true
        root.writeFailed("timeout")
      }
      if (writeProc.running) writeProc.running = false
    }
  }

  Process {
    id: readProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) {
        var line = String(data || "")
        if (root.readBytes + line.length > root.maxBytes) {
          readProc.running = false
          root.readFailed()
          return
        }
        root.readBytes += line.length
        root.readText += line
      }
    }
    onExited: function(exitCode, exitStatus) {
      opDeadline.stop()
      if (root.readReported) return
      var text = String(root.readText || "")
      root.readBytes = 0
      root.readText = ""
      if (exitCode === 0 && exitStatus === 0) {
        var parsed = null
        try { parsed = JSON.parse(text) } catch (e) { parsed = null }
        root.restored(parsed)
      } else {
        root.failed()
      }
    }
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      opDeadline.stop()
      if (root.writeReported) return
      if (exitCode === 0 && exitStatus === 0) {
        root.inFlightText = ""
        if (root.pendingText !== "") root.flushPendingWrite()
      } else {
        root.writeFailed(exitCode)
      }
    }
  }
}