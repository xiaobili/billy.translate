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
  // Chunks accumulate here and flush to `output` on the paint timer, so the
  // Markdown is re-parsed at most every 100ms instead of on every token.
  property string pendingText: ""
  property string errorText: ""
  property int httpStatus: -1

  readonly property bool streaming: root.state === "streaming"

  signal finished(string outcome)

  property bool sawDone: false
  property bool writeFailed: false
  property string rawTail: ""
  property string stderrTail: ""
  property string stopReason: "" // "" | "user" | "timeout"

  // P0.1: a 429 or 5xx is usually transient, and the user has already waited —
  // retry with a fixed backoff (1s, 2s) rather than failing outright. curl is
  // not asked to dump response headers, so Retry-After is not visible here.
  property int retryCount: 0
  readonly property int maxRetries: 2

  // P0.2: the text actually sent. A whole-page rich capture can be tens of
  // thousands of characters; cap it before it burns tokens or trips the
  // provider's context limit. `truncated` lets the bubble say so.
  property string sendText: ""
  property bool truncated: false
  readonly property int maxChars: {
    var configured = root.config ? Number(root.config.maxChars) : NaN
    return isFinite(configured) && configured > 0 ? Math.floor(configured) : 8000
  }

  // P0.3: the same text through the same model and prompt is the same
  // request. An in-memory LRU (8 entries, most-recent first) answers a
  // repeated translation — re-selecting the same paragraph, Enter on an
  // unchanged input — instantly and without another API call. Set by
  // Overlay.qml; the capture mode is part of the key.
  property string cacheTag: ""
  property var cache: []

  function cacheFind(key) {
    for (var i = 0; i < root.cache.length; i++) {
      if (root.cache[i].key === key) {
        var entry = root.cache[i]
        root.cache.splice(i, 1)
        root.cache.unshift(entry)
        return entry.output
      }
    }
    return null
  }

  function cacheStore(key, output) {
    root.cache.unshift({ key: key, output: output })
    while (root.cache.length > 8) root.cache.pop()
  }

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

    root.retryTimer.stop()
    root.retryCount = 0

    var text = String(root.text || "")
    root.truncated = text.length > root.maxChars
    root.sendText = root.truncated ? Translate.truncateText(text, root.maxChars) : text

    var key = Translate.cacheKey(root.cacheTag, root.config, root.sendText)
    var hit = root.cacheFind(key)
    if (hit !== null) {
      root.output = hit
      root.pendingText = ""
      root.errorText = ""
      root.httpStatus = 200
      root.state = "idle"
      root.finished("done")
      return
    }

    root.launch()
  }

  // (Re)starts the curl child for the current sendText. start() validates
  // first; retryRequest() reuses the validated state, so the cache key and
  // the truncation survive across attempts.
  function launch() {
    root.output = ""
    root.pendingText = ""
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
      root.bodyFile.setText(JSON.stringify(Translate.buildBody(root.config, root.sendText)) + "\n")
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

  function retryRequest() {
    // A dismissal during the backoff stops the timer via cancel(), so reaching
    // here with no stream means this retry is stale.
    if (!root.streaming) return
    // A fresh per-attempt timeout: the timer has been running since the first
    // attempt, and an attempt that consumed most of the budget must not leave
    // the retry with only seconds.
    root.timeoutTimer.restart()
    root.launch()
  }

  function cancel() {
    var backingOff = root.retryTimer.running
    root.retryTimer.stop()
    if (backingOff) {
      // Dismissed during the retry backoff: no child is running, so no
      // handleExit() will come to close this out.
      root.state = "idle"
      root.stopReason = ""
      root.finished(root.output !== "" ? "done" : "canceled")
      return
    }
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
    // Paint-throttled: appending straight to `output` re-parses the Markdown
    // and re-lays out the bubble on every token, which stutters on long
    // translations. Chunks accumulate here and flush to `output` at most
    // every paintTimer interval.
    if (event.content !== "") root.pendingText = root.pendingText + event.content
  }

  // Moves accumulated chunks to `output`, triggering one re-parse. Called by
  // the paint timer while streaming and synchronously when the stream ends,
  // so no text is ever left behind.
  function flushPaint() {
    if (root.pendingText === "") return
    root.output = root.output + root.pendingText
    root.pendingText = ""
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
    // Paint anything still buffered before the state flips (which stops the
    // paint timer): the final text must be complete for copy and display.
    root.flushPaint()
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

    // Retryable failure: 429/5xx with no [DONE] and no user/timeout
    // involvement. The state stays "streaming" through the backoff, so the
    // bubble keeps its translating phase and the paint timer keeps running;
    // launch() clears the partial output of the failed attempt rather than
    // appending a regenerated answer onto it.
    if (outcome === "error" && reason === "" &&
        root.retryCount < root.maxRetries &&
        (root.httpStatus === 429 || root.httpStatus >= 500)) {
      root.retryCount++
      root.stopReason = ""
      root.retryTimer.interval = 1000 * Math.pow(2, root.retryCount - 1)
      root.retryTimer.start()
      return
    }

    root.state = "idle"
    root.stopReason = ""
    // Only a clean, complete answer is cached: a partial answer with an error
    // caption, or a canceled one, must not be served as the whole truth.
    if (outcome === "done" && root.errorText === "" && root.output !== "") {
      root.cacheStore(Translate.cacheKey(root.cacheTag, root.config, root.sendText), root.output)
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

  // Retry backoff: one-shot, armed by handleExit() on a retryable failure.
  // Kept separate from timeoutTimer so a per-attempt timeout can restart
  // without disturbing the backoff schedule.
  property Timer retryTimer: Timer {
    repeat: false
    onTriggered: root.retryRequest()
  }

  // Paint throttle: flushes accumulated chunks to `output` at most every
  // 100ms while streaming. Each flush is one Markdown re-parse instead of
  // one per token; 10fps still reads as live streaming.
  property Timer paintTimer: Timer {
    interval: 100
    repeat: true
    running: root.state === "streaming"
    onTriggered: root.flushPaint()
  }
}
