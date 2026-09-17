import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The card itself: where it sits, what it shows, and the two things you can do
// to it. Positioning is delegated to Layout.js — this file only supplies the
// numbers that go in.
Item {
  id: root

  // Set by Overlay.qml each time the cursor moves or the content resizes.
  property var placement: ({ x: 0, y: 0 })
  property string phase: "done" // translating | done | empty | error
  property string sourceText: ""
  property string translation: ""
  property string errorText: ""
  property string directionLabel: ""
  property bool copied: false

  property string mode: "selection"
  property string inputText: ""
  // The input area's own cap, and what Task 3's budget reads. `inputArea` is
  // the TextArea further down this same file.
  readonly property int maxInputHeight: Style.space(72)
  readonly property int inputHeight: root.mode === "input" ? Math.min(inputArea.implicitHeight, root.maxInputHeight) : 0
  signal submitRequested()

  signal copyRequested()
  signal closeRequested()
  signal inputChanged()

  readonly property int cardWidth: Style.space(420)
  readonly property int minHeight: Style.space(120)
  readonly property int maxHeight: Style.space(420)
  // Caps the translation area so the card stops growing once the text gets
  // long, and the text scrolls under a fixed ceiling instead.
  readonly property int maxResultHeight: Style.space(260)
  readonly property int cardPadding: Style.space(14)

  function selectAllInput() {
    if (root.mode !== "input") return
    inputArea.selectAll()
    inputArea.forceActiveFocus()
  }

  x: root.placement.x
  y: root.placement.y
  width: root.cardWidth
  // The column is inset by cardPadding on every side, so its content occupies
  // [padding, padding + implicitHeight] while the card would otherwise end at
  // implicitHeight — the last line would draw outside the card.
  height: Math.max(root.minHeight, Math.min(root.maxHeight, body.implicitHeight + 2 * root.cardPadding))

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

    Column {
      id: body
      // Not anchors.fill: the card's height is derived from this column's
      // implicit height, and filling would stretch it in the other direction.
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: root.cardPadding
      spacing: Style.space(8)

      // ------------------------------------------------------------- header
      Item {
        width: parent.width
        height: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.directionLabel
          color: Color.muted
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          Button {
            text: root.copied ? "✓" : "⧉"
            tooltipText: "Copy translation"
            bordered: false
            focusable: false
            onClicked: root.copyRequested()
          }

          Button {
            text: "✕"
            tooltipText: "Close"
            bordered: false
            focusable: false
            onClicked: root.closeRequested()
          }
        }
      }

      // -------------------------------------------------------------- input
      // The typed text *is* the source in this mode, so it takes the slot the
      // read-only source text occupies otherwise.
      BorderSurface {
        width: parent.width
        visible: root.mode === "input"
        height: root.inputHeight
        radius: Style.cornerRadius / 2
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

        TextArea {
          id: inputArea
          anchors.fill: parent
          anchors.margins: Style.space(6)
          placeholderText: "Type or paste text — Enter to translate"
          color: Color.foreground
          wrapMode: TextArea.Wrap
          textFormat: TextEdit.PlainText
          focus: root.mode === "input"
          background: null
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.body
          onTextChanged: {
            root.inputText = text
            root.inputChanged()
          }
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              event.accepted = true
              root.closeRequested()
              return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              // Shift+Enter falls through to TextArea's own newline.
              if (event.modifiers & Qt.ShiftModifier) return
              event.accepted = true
              root.submitRequested()
            }
          }
        }
      }

      // ------------------------------------------------------------- source
      // Shown so the fallback path is falsifiable: when the synthetic Ctrl+C
      // grabs the wrong thing, this is how you see it.
      Text {
        width: parent.width
        visible: root.mode !== "input" && root.sourceText !== ""
        text: root.sourceText
        color: Color.muted
        elide: Text.ElideRight
        maximumLineCount: 3
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        width: parent.width
        visible: root.mode !== "input" && root.sourceText !== ""
      }

      // ------------------------------------------------------------- result
      // One node for the answer in every state: partial while streaming,
      // final when done, or the failure reason when nothing arrived at all.
      // The block caret is what says "still arriving" — a spinner would be
      // heavier than a bubble this size deserves.
      Flickable {
        id: resultView
        width: parent.width
        visible: root.phase !== "empty"
        height: Math.min(resultText.implicitHeight, root.maxResultHeight)
        contentWidth: width
        contentHeight: resultText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Text {
          id: resultText
          width: resultView.width
          text: {
            if (root.phase === "error" && root.translation === "") return root.errorText
            if (root.phase === "empty") return ""
            return root.phase === "translating" ? root.translation + "▌" : root.translation
          }
          color: root.phase === "error" && root.translation === "" ? Color.urgent : Color.foreground
          wrapMode: Text.Wrap
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.body
        }
      }

      Text {
        width: parent.width
        visible: root.phase === "empty"
        text: root.errorText
        color: Color.muted
        elide: Text.ElideRight
        maximumLineCount: 3
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.body
      }

      // A failure that happened after text had already arrived: the
      // translation stays, the reason is appended under it.
      Text {
        width: parent.width
        visible: root.phase === "error" && root.translation !== ""
        text: root.errorText
        color: Color.urgent
        elide: Text.ElideRight
        maximumLineCount: 3
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
