import QtQuick
import Quickshell
import Quickshell.Io

// The only place the plugin reads state from outside itself: where the cursor
// is, and what is selected. Both answers come from scripts under bin/, which
// keeps the timing-sensitive work testable from a terminal.
QtObject {
  id: root

  // Injected by Overlay.qml from the manifest.
  property string pluginDir: ""

  signal cursorReady(var pos)
  signal cursorFailed(string message)
  signal textReady(string text)
  signal textFailed(string message)

  readonly property string cursorScript: root.pluginDir + "/bin/cursor-pos"
  readonly property string pickScript: root.pluginDir + "/bin/pick-text"

  function queryCursor() {
    if (root.pluginDir === "") {
      root.cursorFailed("Plugin directory is unknown.")
      return
    }
    root.cursorProcess.running = true
  }

  function pickText() {
    if (root.pluginDir === "") {
      root.textFailed("Plugin directory is unknown.")
      return
    }
    root.pickProcess.running = true
  }

  // "<screen> <x> <y> <w> <h>", on one line.
  function parseCursor(raw) {
    var line = String(raw || "").trim()
    if (line === "") return null
    var parts = line.split(/\s+/)
    if (parts.length !== 5) return null
    var values = []
    for (var i = 1; i < 5; i++) {
      var n = Number(parts[i])
      if (!isFinite(n)) return null
      values.push(n)
    }
    if (parts[0] === "") return null
    return { screen: parts[0], x: values[0], y: values[1], w: values[2], h: values[3] }
  }

  property Process cursorProcess: Process {
    // bash always starts, so a missing or non-executable script cannot raise
    // QProcess::FailedToStart — which emits no `exited` and would leave a
    // caller waiting on this probe's signals forever. It arrives as an ordinary
    // exit code instead: 127 for a missing file, 126 for one without its exec
    // bit, both of which onExited already reports. Process exposes no error
    // signal to hook: the `onErrorOccurred` in the module metadata is a Method
    // (the internal QProcess slot), not a signal, so `onErrorOccurred:` would be
    // a load-time error the syntax gate cannot see.
    command: ["bash", "-c", "exec \"$1\"", "bash", root.cursorScript]
    stdout: StdioCollector {
      id: cursorOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.cursorFailed("Could not read the cursor position.")
        return
      }
      var pos = root.parseCursor(cursorOut.text)
      if (!pos) {
        root.cursorFailed("Could not read the cursor position.")
        return
      }
      root.cursorReady(pos)
    }
  }

  // The text arrives on stdout; a non-zero exit means there was no selection,
  // which is a normal outcome rather than a failure worth logging.
  property Process pickProcess: Process {
    // bash always starts, so a missing or non-executable script cannot raise
    // QProcess::FailedToStart — which emits no `exited` and would leave a
    // caller waiting on this probe's signals forever. It arrives as an ordinary
    // exit code instead: 127 for a missing file, 126 for one without its exec
    // bit, both of which onExited already reports. Process exposes no error
    // signal to hook: the `onErrorOccurred` in the module metadata is a Method
    // (the internal QProcess slot), not a signal, so `onErrorOccurred:` would be
    // a load-time error the syntax gate cannot see.
    command: ["bash", "-c", "exec \"$1\"", "bash", root.pickScript]
    stdout: StdioCollector {
      id: pickOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var text = String(pickOut.text || "")
      if (exitCode !== 0 || text.trim() === "") {
        root.textFailed("No text selected.")
        return
      }
      root.textReady(text)
    }
  }
}
