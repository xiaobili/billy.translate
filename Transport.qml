import QtQuick
import Quickshell
import Quickshell.Io
import "Translate.js" as Translate

// The one place a request is made. Writes the body and the curl config, runs
// curl, and turns its stdout back into translation deltas.
//
// The API key never appears in argv (world-readable /proc/<pid>/cmdline) or in
// the environment: curl reads url, headers and the body path from a 0600
// config file inside the 0700 state directory.
QtObject {
  id: root

  property var config: null
  property string text: ""

  property string state: "idle" // idle | streaming
  property string output: ""
  property string errorText: ""
  property int httpStatus: -1

  readonly property bool streaming: root.state === "streaming"

  signal finished(string outcome)

  property bool sawDone: false
  property bool writeFailed: false
  property string rawTail: ""
  property string stderrTail: ""
  property string stopReason: "" // "" | "user" | "timeout"

  // Injected by Overlay.qml from Config's dir, which owns the state path —
  // the plugin derives it in exactly one place. Two derivations of the same
  // path drift, and only one of them can be right.
  property string dir: ""
  readonly property string bodyPath: root.dir + "/body.json"
  readonly property string curlConfPath: root.dir + "/curl.conf"

  readonly property int timeoutSec: {
    var configured = root.config ? Number(root.config.timeoutSec) : NaN
    return isFinite(configured) && configured > 0 ? configured : 60
  }

  // ------------------------------------------------------------------ config

  // curl config-file values live inside double quotes, where curl itself
  // understands \\ and \". Newlines would end the line, so they are folded.
  function quote(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, "\\\"")
      .replace(/[\r\n]+/g, " ")
  }
  // Same as quote(), except that a newline survives as curl's own \n
  // escape: curl reads it back as a real line break. The HTTP status marker
  // needs those breaks — folded to spaces by quote() it glues onto the
  // response body and parseHttpMarker reads -1, silently disabling every
  // status branch of errorText.
  function curlEscape(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, "\\\"")
      .replace(/\r?\n/g, "\\n")
  }

  function curlConfigText() {
    var lines = []
    lines.push("url = \"" + root.quote(Translate.completionsUrl(root.config.baseUrl)) + "\"")
    lines.push("request = \"POST\"")
    lines.push("header = \"Content-Type: application/json\"")
    var key = String(root.config.apiKey || "").trim()
    if (key !== "") lines.push("header = \"Authorization: Bearer " + root.quote(key) + "\"")
    lines.push("data-binary = \"@" + root.quote(root.bodyPath) + "\"")
    lines.push("connect-timeout = \"10\"")
    lines.push("max-time = \"" + (root.timeoutSec + 10) + "\"")
    lines.push("silent")
    lines.push("show-error")
    lines.push("no-buffer")
    // The status marker is the last line curl writes, so it survives even when
    // the body is an error document rather than a stream.
    lines.push("write-out = \"" + root.curlEscape(Translate.httpMarker()) + "\"")
    return lines.join("\n") + "\n"
  }

  // ------------------------------------------------------------------ sending

  function start() {
    // Absorbs a duplicate signal, not a changed one: the probe can emit
    // textReady twice for one pickText() call, so start() legitimately arrives
    // twice for the same text. A changed text cannot arrive here — while a
    // stream runs the overlay is open and modal, so no new selection can be
    // made, and a second hotkey press cancels rather than picks; the next pick
    // comes from a later open(), by which point the state is idle. If a later
    // task ever makes a concurrent selection possible, this is the line to
    // revisit.
    if (root.streaming) return
    if (!root.config) {
      root.fail("Translation is not configured.")
      return
    }
    if (Translate.completionsUrl(root.config.baseUrl) === "") {
      root.fail("Translation is not configured.")
      return
    }
    if (String(root.config.model || "").trim() === "") {
      root.fail("Translation is not configured.")
      return
    }
    if (String(root.text || "").trim() === "") {
      root.fail("No text selected.")
      return
    }

    root.output = ""
    root.errorText = ""
    root.httpStatus = -1
    root.sawDone = false
    root.writeFailed = false
    root.rawTail = ""
    root.stderrTail = ""
    root.stopReason = ""

    // Both FileViews set blockWrites, so setText() has completed by the time
    // it returns. An async save would let the process start before the files
    // it reads exist.
    try {
      root.confFile.setText(root.curlConfigText())
      root.bodyFile.setText(JSON.stringify(Translate.buildBody(root.config, root.text)) + "\n")
    } catch (e) {
      root.fail("Could not prepare the request: " + e)
      return
    }
    if (root.writeFailed) {
      root.fail("Could not write the request to disk.")
      return
    }

    root.state = "streaming"
    root.process.command = ["setpriv", "--pdeathsig", "TERM", "curl", "-K", root.curlConfPath]
    root.process.running = true
  }

  function cancel() {
    if (!root.streaming) return
    root.stopReason = "user"
    // A dismissal's SIGTERM is still in flight; Process.running stays true
    // until the child exits, so handleExit() does the rest.
    root.process.running = false
  }

  function fail(message) {
    root.errorText = String(message || "The request failed.")
    root.state = "idle"
    root.finished("error")
  }

  // -------------------------------------------------------------------- input

  function handleLine(line) {
    var status = Translate.parseHttpMarker(line)
    if (status >= 0) {
      root.httpStatus = status
      return
    }
    var event = Translate.parseSseLine(line)
    if (!event) {
      root.noteRaw(line)
      return
    }
    if (event.done) {
      root.sawDone = true
      return
    }
    if (event.content !== "") root.output = root.output + event.content
  }

  // Non-SSE lines are either keep-alives or the provider's error document.
  // Keep a bounded tail so a failed request can explain itself.
  function noteRaw(line) {
    var text = String(line || "").trim()
    if (text === "") return
    root.rawTail = root.rawTail === "" ? text : root.rawTail + "\n" + text
    if (root.rawTail.length > 2000) root.rawTail = root.rawTail.substring(root.rawTail.length - 2000)
  }

  function handleExit(exitCode) {
    var wasStreaming = root.streaming
    var reason = root.stopReason
    root.state = "idle"
    root.stopReason = ""
    if (!wasStreaming) return

    var outcome = "done"
    if (reason === "timeout") {
      outcome = "error"
      root.errorText = "Timed out after " + root.timeoutSec + "s."
    } else if (reason === "user") {
      // A canceled request keeps whatever arrived: the user has already read
      // part of the translation and it is still the answer to what they asked.
      outcome = root.output !== "" ? "done" : "canceled"
    } else if (!root.sawDone) {
      // No [DONE] means the stream never completed. A partial translation is
      // kept and the reason is reported alongside it rather than replacing it.
      var detail = Translate.errorText(root.httpStatus, root.rawTail !== "" ? root.rawTail : root.stderrTail)
      if (root.output !== "") root.errorText = detail
      else {
        outcome = "error"
        root.errorText = detail
      }
    }
    root.finished(outcome)
  }

  // ------------------------------------------------------------------- wiring

  property FileView confFile: FileView {
    path: root.dirsReadyForFiles ? root.curlConfPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.writeFailed = true
  }

  property FileView bodyFile: FileView {
    path: root.dirsReadyForFiles ? root.bodyPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.writeFailed = true
  }

  // The state directory is created by Config.qml. Writing before it exists
  // fails with FileNotFound and, with printErrors off, that failure is silent.
  readonly property bool dirsReadyForFiles: root.dir !== "" && root.config !== null

  property Process process: Process {
    onExited: function (exitCode) { root.handleExit(exitCode) }
    stdout: SplitParser {
      onRead: function (line) { root.handleLine(String(line)) }
    }
    stderr: StdioCollector {
      id: stderrCollector
      waitForEnd: true
      onStreamFinished: {
        var text = String(stderrCollector.text || "").trim()
        if (text !== "") root.stderrTail = text
      }
    }
  }

  property Timer timeoutTimer: Timer {
    interval: root.timeoutSec * 1000
    running: root.state === "streaming"
    onTriggered: {
      root.stopReason = "timeout"
      root.process.running = false
    }
  }
}
