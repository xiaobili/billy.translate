import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout
import "Translate.js" as Translate

// The plugin root. The shell's facade calls open(payloadJson)/close() and
// reads `opened` to decide what the toggle verb means, so all three are part
// of the contract rather than conveniences.
PanelWindow {
  id: root

  property var manifest: null

  property string phase: "idle" // idle | picking | translating | done | empty | error
  property bool opened: false

  // Orthogonal to `phase`: "selection" is the pick-a-selection flow, "input"
  // is the typed-text flow. The phase set is unchanged — input mode uses
  // empty / translating / done / error, and never picking (no probe runs).
  property string mode: "selection"
  // Bound, never assigned here: the TextArea inside Bubble.qml is the only
  // writer, so the two cannot drift. Ids are file-scoped — Bubble's own
  // `inputText` is a different property from this one.
  property string inputText: bubble.inputText
  // Set when a submit lands while a stream is in flight: cancel() is async, so
  // the new request has to wait for finished() rather than pressing start()
  // into the streaming guard.
  property bool pendingSubmit: false

  property var cursorPos: null
  property string selectedText: ""
  property string directionLabel: ""
  property string failureText: ""
  property bool copied: false

  // Only the screen the cursor is on is used, so there is no ambiguity about
  // which monitor a summon affects.
  screen: root.screenFor(root.cursorPos ? root.cursorPos.screen : "")

  // The surface must not exist while picking: opening it grabs the keyboard
  // focus that the fallback Ctrl+C needs to reach the app underneath.
  visible: root.opened && root.phase !== "picking" && root.phase !== "idle"
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "billy-translate"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // This plugin's own directory, derived from this file's URL. Not from the
  // manifest: the shell strips `__sourceDir` before handing a manifest to a
  // third-party plugin (shell.qml publicPluginManifest() deletes it on the
  // non-first-party branch), so `root.manifest.__sourceDir` is always empty
  // here and every spawn would target a path that does not exist. Nothing else
  // the shell injects carries a path either.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return decodeURIComponent(u).replace(/\/$/, "")
  }

  // ------------------------------------------------------------------ layout

  function screenFor(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === String(name)) return screens[i]
    }
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  // Recomputed whenever the cursor, the screen or the card height changes —
  // a streaming translation grows, and a clamp computed once would let the
  // card walk off the bottom of the screen.
  readonly property var placement: {
    // No cursor position means hyprctl failed. Centre on the surface rather
    // than leaving the card pinned in the corner, which reads as a rendering
    // bug rather than an error.
    if (!root.cursorPos) {
      return {
        x: Math.max(0, (root.width - bubble.cardWidth) / 2),
        y: Math.max(0, (root.height - bubble.height) / 2)
      }
    }
    return Layout.place(
      { x: root.cursorPos.x, y: root.cursorPos.y },
      { w: root.cursorPos.w, h: root.cursorPos.h },
      { w: bubble.cardWidth, h: bubble.height },
      Style.space(12),
      Style.space(8)
    )
  }

  // ------------------------------------------------------------------- state

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = {} }
    // `opened` is set before the pick runs, so from this moment the shell
    // facade already reports the plugin open: a second hotkey press takes the
    // toggle's hide branch and cancels rather than re-picking. (R13)
    root.opened = true
    root.copied = false
    root.failureText = ""
    root.selectedText = ""
    root.directionLabel = ""
    if (payload.mode === "input") {
      root.mode = "input"
      // Nothing to pick: the surface can appear at once.
      root.phase = "empty"
      transport.cancel()
      Qt.callLater(function () { bubble.selectAllInput() })
      return
    }
    root.mode = "selection"
    root.phase = "picking"
    transport.cancel()
    probe.queryCursor()
    probe.pickText()
  }

  function close() {
    transport.cancel()
    root.opened = false
    root.phase = "idle"
    root.selectedText = ""
    root.failureText = ""
    root.copied = false
    root.pendingSubmit = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function inputMode() {
    if (root.opened && root.mode === "input") {
      root.close()
      return
    }
    root.open('{"mode":"input"}')
  }

  function submitInput() {
    if (root.mode !== "input") return
    if (root.inputText.trim() === "") return
    if (transport.streaming) {
      // Cancel and re-submit from finished(): Transport's start() returns
      // early while a child is still exiting, and cancel() cannot be awaited.
      root.pendingSubmit = true
      transport.cancel()
      return
    }
    root.failureText = ""
    root.phase = "translating"
    transport.start()
  }

  function copyTranslation() {
    if (transport.output === "") return
    // argv, not a shell: the text is its own element, so `-l` bought nothing
    // and cost a profile source on every copy.
    Quickshell.execDetached(["wl-copy", "--", transport.output])
    root.copied = true
    copiedTimer.restart()
  }

  property Timer copiedTimer: Timer {
    interval: 1500
    onTriggered: root.copied = false
  }

  // ---------------------------------------------------------------- components

  property Config config: Config {}
  property Probe probe: Probe {
    pluginDir: root.pluginDir
    onCursorReady: function (pos) { root.cursorPos = pos }
    onCursorFailed: function (message) {
      root.failureText = message
      root.phase = "empty"
    }
    onTextReady: function (text) {
      // A second hotkey press inside the pick window takes the toggle's hide
      // branch, but the pick is already in flight: without this, its late
      // textReady starts a full translation behind a closed overlay.
      if (!root.opened) return
      root.selectedText = text
      root.directionLabel = Translate.directionLabel(text)
      root.phase = "translating"
      transport.start()
    }
    onTextFailed: function (message) {
      if (!root.opened) return
      root.failureText = message
      root.phase = "empty"
    }
  }

  property Transport transport: Transport {
    config: root.config.ready ? root.config.config : null
    // F2: Transport does not derive the state path — Config owns it.
    dir: root.config.dir
    text: root.mode === "input" ? root.inputText : root.selectedText
    // The phase stays "translating" until the stream ends — the bubble shows
    // whatever has arrived, so there is no need to promote a partial answer
    // to "done" and lose the distinction.
    onFinished: function (outcome) {
      if (root.pendingSubmit) {
        root.pendingSubmit = false
        root.failureText = ""
        root.phase = "translating"
        transport.start()
        return
      }
      if (transport.output === "") {
        root.failureText = outcome === "error" ? transport.errorText : "No translation returned."
        root.phase = "error"
        return
      }
      // A failure after text had already arrived keeps the text and reports
      // the reason underneath it.
      root.failureText = transport.errorText
      root.phase = transport.errorText === "" ? "done" : "error"
    }
  }

  Rectangle { anchors.fill: parent; color: Color.menu.scrim }
  MouseArea { anchors.fill: parent; onClicked: root.close() }

  // The overlay takes WlrKeyboardFocus.Exclusive, so a key it does not handle is
  // swallowed rather than reaching the app underneath: without this, Esc does
  // nothing at all while the bubble is open. Same shape as the shell's own
  // Ui/SpeedTestOverlay.qml.
  Item {
    anchors.fill: parent
    focus: root.mode !== "input"
    Keys.onEscapePressed: root.close()
  }

  // Declared in the body rather than as a `property Bubble bubble: ...` so the
  // visual parent is unambiguous and the card is actually in the scene.
  Bubble {
    id: bubble
    placement: root.placement
    phase: root.phase
    mode: root.mode
    sourceText: root.selectedText
    translation: transport.output
    errorText: root.failureText
    directionLabel: root.directionLabel
    copied: root.copied
    onCopyRequested: root.copyTranslation()
    onCloseRequested: root.close()
    onInputChanged: root.directionLabel = Translate.directionLabel(root.inputText)
    onSubmitRequested: root.submitInput()
  }

  IpcHandler {
    target: "billy.translate"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function copy(): void { root.copyTranslation() }
    function input(): void { root.inputMode() }
    function ping(): string { return "ok" }
  }
}
