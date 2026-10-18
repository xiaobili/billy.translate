import QtQuick
// @ROOT@ is substituted by tests/bubble-render.sh before the run: the generated
// tree lives in .renderroot, and absolute URLs keep this file free of any link
// that would have to be cleaned up inside the plugin folder afterwards.
import "file://@ROOT@/copy" as P
import "file://@ROOT@/qs/qs/Commons" as C

// Driven by tests/bubble-render.sh, which generates the Bubble.qml copy sitting
// in ./copy. Two assertions about layout rather than pixels: the card renders
// at a sane resting height, and opening the picker adds a row instead of being
// clipped by the cap.
Window {
  id: host
  width: 520
  height: 720
  visible: true
  color: "#f6f5f4"

  property bool opened: false
  property real base: 0

  P.Bubble {
    id: bubble
    placement: ({ x: 0, y: 0 })
    phase: "done"
    mode: "selection"
    sourceText: "Guten Tag, wie geht es Ihnen?"
    translation: "你好，您好，您好吗？"
    // What Overlay hands in: the label reflects the pair, the code names the
    // user's pick, and the picker's visibility is the overlay's own state.
    directionLabel: "DE → 日本語"
    targetCode: host.opened ? "ja" : ""
    pickerOpen: host.opened
  }

  Timer {
    interval: 8000
    running: true
    onTriggered: { console.log("FAIL timeout"); Qt.exit(2) }
  }

  Timer {
    interval: 400
    running: true
    onTriggered: {
      // A missing qs.Commons would leave every token at zero, which would make
      // the real assertions below pass for the wrong reason.
      if (C.Style.space(6) <= 0 || !C.Color.popups.background) {
        console.log("FAIL theme tokens did not resolve: space6=" + C.Style.space(6))
        Qt.exit(1)
        return
      }
      host.base = bubble.height
      if (!(host.base > 0)) {
        console.log("FAIL bubble has no height: " + host.base)
        Qt.exit(1)
        return
      }
      if (bubble.height > bubble.maxHeight + 1) {
        console.log("FAIL resting height " + bubble.height + " exceeds cap " + bubble.maxHeight)
        Qt.exit(1)
        return
      }
      host.opened = true
      openTimer.start()
    }
  }

  // The card's height follows the column's implicit height, and that binding is
  // evaluated in the layout pass after the one that measured the column — so
  // wait two ticks, not one, before reading it.
  Timer {
    id: openTimer
    interval: 0
    onTriggered: settleTimer.start()
  }

  Timer {
    id: settleTimer
    interval: 0
    onTriggered: {
      var grown = bubble.height
      if (!(grown > host.base)) {
        console.log("FAIL picker did not grow the card: " + host.base + " -> " + grown)
        Qt.exit(1)
        return
      }
      if (grown > bubble.maxHeight + 1) {
        console.log("FAIL open height " + grown + " exceeds cap " + bubble.maxHeight)
        Qt.exit(1)
        return
      }
      console.log("ok base=" + Math.round(host.base) + " open=" + Math.round(grown) +
        " cap=" + Math.round(bubble.maxHeight) + " width=" + Math.round(bubble.width))
      Qt.exit(0)
    }
  }
}
