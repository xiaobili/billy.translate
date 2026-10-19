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

  property string phase: "idle" // idle | picking | recognizing | translating | done | empty | error
  property bool opened: false

  // Orthogonal to `phase`: "selection" is the pick-a-selection flow, "input"
  // is the typed-text flow. The phase set is unchanged — input mode uses
  // empty / translating / done / error, and never picking (no probe runs).
  property string mode: "selection"
  // True when this session was opened through a *rich* hotkey — the user asked
  // for formatting, not only for a translation. What that buys depends on the
  // mode: in selection mode the capture goes through a synthetic Ctrl+C so a
  // rendered HTML preview keeps its text/html flavour instead of arriving as
  // flat plain text; in input mode there is nothing to capture, so it decides
  // how the answer is drawn. Either way the translation renders as Markdown
  // (Translate.rendersMarkdown); without it every mode shows text verbatim.
  property bool rich: false
  // Bound, never assigned here: the TextArea inside Bubble.qml is the only
  // writer, so the two cannot drift. Ids are file-scoped — Bubble's own
  // `inputText` is a different property from this one.
  property string inputText: bubble.inputText
  // Set when a submit lands while a stream is in flight: cancel() is async, so
  // the new request has to wait for finished() rather than pressing start()
  // into the streaming guard.
  property bool pendingSubmit: false
  // Set when a mode switch cancels a stream: that cancel's finished() is not a
  // result, and painting a verdict from it would put a false "No translation
  // returned." under whatever the bubble is doing now — or a stray
  // phase="error", which would make the surface appear during the pick window.
  property bool discardNextFinish: false
  property string submittedText: ""

  property var cursorPos: null
  property string selectedText: ""
  property string directionLabel: ""
  // The detected language of the text in hand, and the language it will go to.
  // Both are resolved in exactly two places — admitText() for everything
  // captured (selection/OCR/draft/typing) and admitSource() for a submission —
  // so the bubble label and the request body cannot disagree.
  property string sourceLang: ""
  property string targetLang: "zh"
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
    root.ocrLaunchTimer.stop()
    probe.cancelOcrText()
    // `opened` is set before the pick runs, so from this moment the shell
    // facade already reports the plugin open: a second hotkey press takes the
    // toggle's hide branch and cancels rather than re-picking. (R13)
    root.opened = true
    root.copied = false
    root.failureText = ""
    root.selectedText = ""
    root.directionLabel = ""
    // Set before the mode branch: both modes honour it, and the input branch
    // returns before a later assignment would be reached.
    root.rich = payload.rich === true
    if (payload.mode === "input") {
      root.mode = "input"
      // Nothing to pick: the surface can appear at once.
      root.phase = "empty"
      root.pendingSubmit = false
      root.discardNextFinish = transport.streaming
      transport.cancel()
      root.refreshInputLabel()
      // Fetch the current cursor position so the bubble appears near the cursor,
      // not at the stale position left over from the previous selection mode.
      probe.queryCursor()
      // P0.4: the draft survived the restart on disk; put it back selected.
      var draft = root.config.loadDraft()
      Qt.callLater(function () {
        if (draft !== "") bubble.restoreDraft(draft)
        bubble.selectAllInput()
      })
      return
    }
    root.mode = payload.mode === "ocr" ? "ocr" : "selection"
    // In selection mode `rich` means a rich *pick*: skip the primary selection
    // and synthesise Ctrl+C, so a rendered HTML preview keeps its structure
    // (text/html -> Markdown) instead of arriving as flat plain text. In ocr
    // mode there is no such choice and the flag does nothing.
    root.phase = "picking"
    root.pendingSubmit = false
    root.discardNextFinish = transport.streaming
    transport.cancel()
    probe.queryCursor()
    if (root.mode === "ocr") root.ocrLaunchTimer.start()
    else if (root.rich) probe.pickRichText()
    else probe.pickText()
  }

  function close() {
    root.ocrLaunchTimer.stop()
    probe.cancelOcrText()
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

  // The input field, plain: the answer is shown as it came back. Pressing the
  // same hotkey again dismisses it; pressing the rich one instead switches the
  // open bubble over, because both are the same surface and the text in the
  // field survives the switch (open() restores it from the draft).
  function inputMode() {
    if (root.opened && root.mode === "input" && !root.rich) {
      root.close()
      return
    }
    root.open('{"mode":"input"}')
  }

  // The same field, with the answer rendered as Markdown — for pasting
  // Markdown in and reading it back rendered. Toggle semantics mirror
  // inputMode(): the same hotkey dismisses, the other one switches.
  function richInputMode() {
    if (root.opened && root.mode === "input" && root.rich) {
      root.close()
      return
    }
    root.open('{"mode":"input","rich":true}')
  }

  function ocrMode() {
    if (root.opened && root.mode === "ocr") {
      root.close()
      return
    }
    root.open('{"mode":"ocr"}')
  }

  // Translate the selection capturing rich formatting: skips the primary
  // selection and synthesises Ctrl+C so a rendered HTML preview arrives as
  // Markdown (via text/html) instead of flat plain text. Toggle semantics
  // match inputMode()/ocrMode().
  function richMode() {
    if (root.opened) {
      root.close()
      return
    }
    root.open('{"rich":true}')
  }

  function submitInput() {
    if (root.mode !== "input") return
    if (root.inputText.trim() === "") return
    // The direction must match the text being submitted, not the last
    // keystroke's — a paste-then-Enter can outrun the label refresh.
    root.refreshInputLabel()
    if (transport.streaming) {
      // Cancel and re-submit from finished(): Transport's start() returns
      // early while a child is still exiting, and cancel() cannot be awaited.
      root.pendingSubmit = true
      transport.cancel()
      return
    }
    root.admitText(root.inputText)
    root.submittedText = root.inputText
    root.failureText = ""
    root.phase = "translating"
    transport.start()
  }

  // The label follows the input, but goes blank rather than claiming a
  // direction for an empty field (walkthrough row 1), and is refreshed when a
  // restored draft reopens (row 8) rather than waiting for the next keystroke.
  //
  // Detection runs here rather than at submit: the label is the only feedback
  // that the language was recognised, so it has to follow the typing. It is a
  // script-and-stopword scan, not a model call — see Translate.detectLang.
  //
  // The target comes from targetLangSetting, not the raw config object, so it
  // re-derives when the picker writes the config underneath it.
  function admitText(text) {
    var s = String(text === undefined || text === null ? "" : text)
    root.sourceLang = Translate.detectLang(s)
    root.targetLang = Translate.targetLang(root.sourceLang, root.targetLangSetting)
    root.directionLabel = s.trim() === ""
      ? "" : Translate.directionLabel(root.sourceLang, root.targetLangSetting)
  }

  function refreshInputLabel() {
    root.admitText(root.inputText)
  }

  // Re-derive the label after the default language changed without new text
  // (the picker, or a config edit): the source is unchanged, only the target.
  function refreshDirection() {
    if (root.mode === "input") root.refreshInputLabel()
    else root.admitText(root.selectedText)
  }

  // P0.4: every input change refreshes the label and (debounced) persists the
  // draft, so a shell restart no longer clears it.
  function handleInputChanged() {
    root.refreshInputLabel()
    root.draftTimer.restart()
  }

  // The target the user picked, or "" for the built-in Chinese/English pair.
  // Derived rather than stored on its own: the config is the truth, so a hand
  // edit to config.json takes effect the next time a bubble opens.
  readonly property string targetLangSetting: root.config.ready
    ? Translate.normalizeLang(root.config.config.targetLang || "") : ""

  // A hand edit to config.json — the other way to set the target — must move
  // the open bubble too, not just the next one. The picker path calls
  // refreshDirection() itself before the config write lands, so this is only
  // extra work when the two disagree.
  onTargetLangSettingChanged: root.refreshDirection()

  // Picker selection: persist it, then move the open bubble to the new
  // direction. A translation already in flight was asked for the old one, so
  // it is discarded rather than allowed to land under a label it contradicts;
  // the input flow re-asks immediately, and so does a captured text that is
  // still on screen. Empty is a real choice — it restores the built-in pair —
  // and an unknown code is refused, since nothing would name it.
  function setTargetLanguage(code) {
    var next = Translate.normalizeLang(code)
    if (next !== "" && Translate.languageInfo(next) === null) {
      root.failureText = "Unknown language: " + String(code)
      return
    }
    if (next === Translate.normalizeLang(root.config.config.targetLang || "")) return
    root.config.setTargetLang(next)
    root.discardNextFinish = transport.streaming
    transport.cancel()
    root.copied = false
    root.refreshDirection()
    if (root.mode === "input") {
      if (root.inputText.trim() !== "") root.submitInput()
      return
    }
    if (root.selectedText.trim() === "") return
    // The text is still here; only the answer to it changed.
    if (root.phase === "done" || root.phase === "error" || root.phase === "translating") {
      root.failureText = ""
      root.phase = "translating"
      transport.start()
    }
  }

  function copyTranslation() {
    transport.flushPaint()
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

  // P0.4: debounce for draft persistence — one write per pause in typing,
  // not one per keystroke.
  property Timer draftTimer: Timer {
    interval: 600
    onTriggered: root.config.saveDraft(root.inputText)
  }

  property Timer ocrLaunchTimer: Timer {
    interval: 120
    onTriggered: {
      if (!root.opened || root.mode !== "ocr" || root.phase !== "picking") return
      probe.pickOcrText()
    }
  }

  // ---------------------------------------------------------------- components

  property Config config: Config {}
  property Probe probe: Probe {
    pluginDir: root.pluginDir
    onCursorReady: function (pos) { root.cursorPos = pos }
    onCursorFailed: function (message) {
      if (!root.opened || root.mode !== "selection") return
      root.failureText = message
      root.phase = "empty"
    }
    onOcrSelectionReady: function () {
      if (!root.opened || root.mode !== "ocr" || root.phase !== "picking") return
      root.phase = "recognizing"
    }
    onTextReady: function (text) {
      // A second hotkey press inside the pick window takes the toggle's hide
      // branch, but the pick is already in flight: without this, its late
      // textReady starts a full translation behind a closed overlay.
      if (!root.opened || root.mode === "input") return
      root.selectedText = text
      root.admitText(text)
      root.phase = "translating"
      transport.start()
    }
    onTextFailed: function (message) {
      if (!root.opened || root.mode === "input") return
      root.failureText = message
      root.phase = "empty"
    }
  }

  property Transport transport: Transport {
    config: root.config.ready ? root.config.config : null
    // F2: Transport does not derive the state path — Config owns it.
    dir: root.config.dir
    text: root.mode === "input" ? root.inputText : root.selectedText
    // The direction the text was admitted in (label and body agree), and part
    // of the cache key — the same words in a new target is a new request.
    sourceLang: root.sourceLang
    targetLang: root.targetLang
    // P0.3: the capture mode is part of the cache key — the same words as
    // Markdown (rich) and as plain text are different requests.
    cacheTag: root.mode + (root.rich ? "-rich" : "")
    // The phase stays "translating" until the stream ends — the bubble shows
    // whatever has arrived, so there is no need to promote a partial answer
    // to "done" and lose the distinction.
    onFinished: function (outcome) {
      if (root.discardNextFinish) {
        root.pendingSubmit = false
        root.discardNextFinish = false
        return
      }
      if (root.pendingSubmit) {
        root.pendingSubmit = false
        root.admitText(root.inputText)
        root.submittedText = root.inputText
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
  //
  // This Item only has focus outside input mode (the TextArea takes it there,
  // and handles Esc itself), so Ctrl+L — open the language picker without the
  // mouse — is bound here for the captured-text modes and in Bubble's TextArea
  // for input mode.
  Item {
    focus: root.mode !== "input"
    anchors.fill: parent
    Keys.onEscapePressed: {
      if (bubble.pickerOpen) bubble.pickerOpen = false
      else root.close()
    }
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
        event.accepted = true
        bubble.pickerOpen = !bubble.pickerOpen
      }
    }
  }

  // Declared in the body rather than as a `property Bubble bubble: ...` so the
  // visual parent is unambiguous and the card is actually in the scene.
  Bubble {
    id: bubble
    placement: root.placement
    phase: root.phase
    mode: root.mode
    rich: root.rich
    sourceText: root.selectedText
    translation: transport.output
    errorText: root.failureText
    directionLabel: root.directionLabel
    targetCode: root.config.ready ? root.config.config.targetLang : ""
    copied: root.copied
    stale: root.mode === "input" && root.inputText !== root.submittedText
    onCopyRequested: root.copyTranslation()
    onCloseRequested: root.close()
    onInputChanged: root.handleInputChanged()
    onSubmitRequested: root.submitInput()
    onTargetPicked: function (code) { root.setTargetLanguage(code) }
    // P0.2: the request was capped — say so under the result. A verbatim echo
    // that survived its retry is reported too, so it never reads as a
    // successful translation.
    noticeText: transport.truncated ? "Input truncated to " + transport.maxChars + " characters."
      : transport.echoed ? "The model returned the input unchanged." : ""
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
    function richInput(): void { root.richInputMode() }
    function ocr(): void { root.ocrMode() }
    function rich(): void { root.richMode() }
    function ping(): string { return "ok" }
  }
}
