import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The plugin root. The shell's facade calls open(payloadJson)/close() and
// reads `opened` to decide what the toggle verb means, so all three are part
// of the contract rather than conveniences.
PanelWindow {
  id: root

  property string phase: "idle" // idle | picking | translating | done | empty | error
  property bool opened: false

  // The surface must not exist while picking: opening it grabs the keyboard
  // focus that the fallback Ctrl+C needs to reach the app underneath.
  visible: root.opened && root.phase !== "picking"
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "billy-translate"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = {} }
    root.opened = true
    root.phase = "done"
  }

  function close() {
    root.opened = false
    root.phase = "idle"
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  Rectangle { anchors.fill: parent; color: Color.menu.scrim }
  MouseArea { anchors.fill: parent; onClicked: root.close() }

  IpcHandler {
    target: "billy.translate"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function ping(): string { return "ok" }
  }
}
