import QtQuick
import QtQuick.Controls

// Headless check that the language picker's markup renders: a Bubble-shaped
// card with the real Translate.js helpers driving the chips, and a label that
// follows the picked target. Proves Qt accepts the generated labels and the
// Flow/Repeater/Button combination — the parts qmllint cannot see.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml tests/lang-render.qml

import "../Translate.js" as Translate

Window {
  id: win
  width: 460
  height: 320
  visible: true
  color: "#ffffff"

  property string targetCode: ""
  property string label: Translate.directionLabel("en", win.targetCode)
  property int codeCount: Translate.languageCodes().length

  Rectangle {
    id: card
    anchors.fill: parent
    anchors.margins: 12
    color: "#f6f6f6"
    radius: 12

    Column {
      anchors.fill: parent
      anchors.margins: 14
      spacing: 8

      Text {
        id: labelText
        text: win.label
        font.pixelSize: 10
        color: "#555"
      }

      Flow {
        id: picker
        width: parent.width
        spacing: 4

        Repeater {
          model: [""].concat(Translate.languageCodes())

          delegate: Button {
            required property string modelData
            readonly property bool isAuto: modelData === ""
            text: isAuto ? "Auto" : Translate.languageLabel(modelData)
            font.pixelSize: 10
            padding: 4
            onClicked: win.targetCode = modelData
          }
        }
      }

      Text {
        id: probe
        visible: false
        text: "probe"
      }
    }
  }

  // The watchdog: an exception inside a completion handler would otherwise
  // leave the runtime hanging with no verdict at all.
  Timer {
    interval: 6000
    running: true
    onTriggered: {
      console.log("TIMEOUT")
      Qt.exit(2)
    }
  }

  Timer {
    interval: 300
    running: true
    repeat: false
    onTriggered: {
      var failures = []

      // Every offered code must have a label, and no label may be the code
      // itself (the sign that languageInfo() returned null).
      for (var i = 0; i < win.codeCount; i++) {
        var code = Translate.languageCodes()[i]
        var text = Translate.languageLabel(code)
        if (text === code || text === "") failures.push("no label for " + code)
      }
      if (win.codeCount < 4) failures.push("too few languages offered")
      if (labelText.text !== "EN → 中文") failures.push("label was " + labelText.text)

      // The chips really laid out: twelve codes plus Auto, in more than one row
      // at this width, and none of them zero-sized or blank. A blank chip is
      // what a broken label helper produces, so its text is checked too.
      var chips = picker.children
      var buttons = 0
      for (var j = 0; j < chips.length; j++) {
        var chip = chips[j]
        if (chip.text === undefined || !chip.visible) continue
        buttons++
        if (chip.implicitWidth <= 0) failures.push("chip has no width")
        if (String(chip.text).trim() === "") failures.push("blank chip at " + buttons)
      }
      if (buttons !== win.codeCount + 1) failures.push("chips: " + buttons + " of " + (win.codeCount + 1))
      if (picker.implicitHeight <= 0) failures.push("picker has no height")

      // Picking a target moves the label, through the same resolver the
      // request body uses.
      win.targetCode = "ja"
      if (win.label !== "EN → 日本語") failures.push("after pick: " + win.label)
      win.targetCode = "en"
      if (win.label !== "EN → 中文") failures.push("target == source: " + win.label)

      if (failures.length > 0) {
        console.log("FAIL " + failures.join("; "))
        Qt.exit(1)
        return
      }
      console.log("ok label=" + win.label + " chips=" + buttons + " height=" + Math.round(picker.implicitHeight))
      Qt.exit(0)
    }
  }
}
