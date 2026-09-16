import QtQuick
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

  signal copyRequested()
  signal closeRequested()

  readonly property int cardWidth: Style.space(420)
  readonly property int minHeight: Style.space(120)
  readonly property int maxHeight: Style.space(420)
  // Caps the translation area so the card stops growing once the text gets
  // long, and the text scrolls under a fixed ceiling instead.
  readonly property int maxResultHeight: Style.space(260)

  x: root.placement.x
  y: root.placement.y
  width: root.cardWidth
  height: Math.max(root.minHeight, Math.min(root.maxHeight, body.implicitHeight))

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, 1)

    Column {
      id: body
      // Not anchors.fill: the card's height is derived from this column's
      // implicit height, and filling would stretch it in the other direction.
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(14)
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

      // ------------------------------------------------------------- source
      // Shown so the fallback path is falsifiable: when the synthetic Ctrl+C
      // grabs the wrong thing, this is how you see it.
      Text {
        width: parent.width
        visible: root.sourceText !== ""
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
        visible: root.sourceText !== ""
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
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
