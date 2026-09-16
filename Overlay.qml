import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// The plugin root. The shell's facade calls open(payloadJson)/close() and
// reads `opened` to decide what the toggle verb means, so all three are part
// of the contract rather than conveniences.
PanelWindow {
  id: root

  property var manifest: null

  property string phase: "idle" // idle | picking | translating | done | empty | error
  property bool opened: false
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
    // `opened` is set before the pick runs, so from this moment the shell
    // facade already reports the plugin open: a second hotkey press takes the
    // toggle's hide branch and cancels rather than re-picking. The pick below
    // runs once, on this call. (R13)
    root.opened = true
    root.copied = false
    root.failureText = ""
    root.selectedText = ""
    root.directionLabel = ""
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
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function copyTranslation() {
    if (transport.output === "") return
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", "wl-copy", "--", transport.output])
    root.copied = true
    copiedTimer.restart()
  }

  // "EN → 中文" — enough to tell at a glance which way it went, without a
  // language-detection pass of our own.
  function labelFor(text) {
    var chinese = /[一-鿿]/.test(text)
    return chinese ? "中文 → EN" : "→ 中文"
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
      root.directionLabel = root.labelFor(text)
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
    text: root.selectedText
    // The phase stays "translating" until the stream ends — the bubble shows
    // whatever has arrived, so there is no need to promote a partial answer
    // to "done" and lose the distinction.
    onFinished: function (outcome) {
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
    focus: true
    Keys.onEscapePressed: root.close()
  }

  // Declared in the body rather than as a `property Bubble bubble: ...` so the
  // visual parent is unambiguous and the card is actually in the scene.
  Bubble {
    id: bubble
    placement: root.placement
    phase: root.phase
    sourceText: root.selectedText
    translation: transport.output
    errorText: root.failureText
    directionLabel: root.directionLabel
    copied: root.copied
    onCopyRequested: root.copyTranslation()
    onCloseRequested: root.close()
  }

  IpcHandler {
    target: "billy.translate"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function copy(): void { root.copyTranslation() }
    function ping(): string { return "ok" }
  }
}
