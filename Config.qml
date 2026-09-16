import QtQuick
import Quickshell
import Quickshell.Io

// Owns the one file the plugin persists. State lives under XDG_STATE_HOME
// alongside omarchy's own plugins, not in the config tree: shell.json is
// rewritten by the shell on every layout change, and an API key must not be
// in a file that gets rewritten.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")
  readonly property string dir: root.stateHome + "/omarchy/translate"
  readonly property string configPath: root.dir + "/config.json"
  // Read once, on first run, to seed the config. Never written back to.
  readonly property string chatConfigPath: root.stateHome + "/omarchy/chat/config.json"

  // Nothing may be written before the directory exists: a FileView write into
  // a missing directory fails with FileNotFound, and with printErrors off that
  // failure is completely silent.
  property bool dirsReady: false
  // A request must not be attempted before the config is known.
  property bool configLoaded: false
  readonly property bool ready: root.dirsReady && root.configLoaded

  property var config: root.defaultConfig()
  property string lastError: ""

  function defaultConfig() {
    return {
      baseUrl: "https://api.deepseek.com/v1",
      model: "deepseek-flash",
      apiKey: "",
      systemPrompt: "",
      temperature: 0.2,
      maxTokens: 0,
      timeoutSec: 60
    }
  }

  // Anything the file does not define falls back to the default, so a config
  // written by an older version keeps working.
  function normalize(raw) {
    var base = root.defaultConfig()
    if (!raw || typeof raw !== "object") return base
    var out = {}
    for (var key in base) {
      out[key] = (raw[key] === undefined || raw[key] === null) ? base[key] : raw[key]
    }
    return out
  }

  // First run: copy the chat plugin's credentials so the API key does not have
  // to be typed twice. A copy, not a reference — afterwards the two configs
  // are independent.
  function seedFromChat() {
    var text = root.chatFile.text()
    if (!text) return root.defaultConfig()
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      return root.defaultConfig()
    }
    var base = root.defaultConfig()
    if (parsed && typeof parsed.baseUrl === "string" && parsed.baseUrl !== "") base.baseUrl = parsed.baseUrl
    if (parsed && typeof parsed.model === "string" && parsed.model !== "") base.model = parsed.model
    if (parsed && typeof parsed.apiKey === "string" && parsed.apiKey !== "") base.apiKey = parsed.apiKey
    return base
  }

  function save() {
    if (!root.dirsReady) {
      root.lastError = "State directory is not ready."
      return
    }
    root.file.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  // Writes must be complete before the caller proceeds, and setText() is
  // asynchronous otherwise. blockWrites makes it return once the write has
  // landed or failed.
  property FileView file: FileView {
    path: root.dirsReady ? root.configPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.lastError = "Cannot write " + root.configPath
    onLoaded: {
      var parsed = null
      try {
        parsed = JSON.parse(root.file.text())
      } catch (e) {
        parsed = null
      }
      root.config = root.normalize(parsed)
      root.configLoaded = true
    }
    onLoadFailed: {
      // No file yet is the first run, not an error: seed from chat and write
      // it out so the next run takes the normal path.
      root.config = root.seedFromChat()
      root.configLoaded = true
      root.save()
    }
  }

  // Read-only access to the chat config for seeding. A failed read is normal
  // (the user may not have the chat plugin), so it is not surfaced.
  property FileView chatFile: FileView {
    path: root.chatConfigPath
    printErrors: false
  }

  // umask 077 rather than `mkdir -m 700`: the mode flag covers only the
  // directory, while the umask covers everything created inside it too. This
  // is the same invocation billy.chat uses.
  //
  // The config file itself comes out 0600 because atomicWrites writes to a
  // temporary file and renames it, and Qt creates temporary files with that
  // mode. Step 4 asserts the result rather than assuming it.
  property Process mkdir: Process {
    command: ["bash", "-c", "umask 077; mkdir -p \"$1\"; chmod 700 \"$1\"", "--", root.dir]
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.dirsReady = true
      } else {
        root.lastError = "Cannot create " + root.dir
      }
    }
  }

  Component.onCompleted: root.mkdir.running = true
}
