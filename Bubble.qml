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
  property bool stale: false

  property string mode: "selection"
  property string inputText: ""
  // The input area's own cap, and what Task 3's budget reads. `inputArea` is
  // the TextArea further down this same file.
  readonly property int inputInset: Style.space(6)
  readonly property int maxInputHeight: Style.space(72)
  // The box is the text plus its inset, capped; past the cap the Flickable
  // scrolls instead of the box growing.
  readonly property int inputHeight: root.mode === "input" ? Math.min(inputArea.implicitHeight + 2 * root.inputInset, root.maxInputHeight) : 0
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
  readonly property int headerHeight: Style.space(20)
  // The card is clamped at maxHeight and BorderSurface does not clip, so the
  // input and the result share one budget instead of each capping itself —
  // their sum can otherwise exceed the card and draw over the scrim.
  readonly property int bodyBudget: root.maxHeight - 2 * root.cardPadding
  // The caption is the column's fourth visible child when it shows, and it opens
  // a third gap. Charging its height without the gap leaves an 8 px spill;
  // charging neither (this plan's first draft) left 22-50 px of red text over
  // the scrim. `maxResultHeight` is a ceiling in BOTH modes: without the
  // Math.min the no-caption column lands exactly on bodyBudget with zero
  // headroom, which is how the overflow went unnoticed.
  readonly property int captionHeight: errorCaption.visible ? errorCaption.implicitHeight + body.spacing : 0
  readonly property int resultCap: root.mode === "input"
    ? Math.min(root.maxResultHeight, Math.max(0,
        root.bodyBudget - root.headerHeight - root.inputHeight - 2 * body.spacing - root.captionHeight))
    : root.maxResultHeight

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

  // Clicks inside the card must not reach the scrim's MouseArea behind it: in
  // input mode that would dismiss the bubble the moment you click to place the
  // caret, and in selection mode "click the text and it vanishes" is a
  // surprise either way.
  MouseArea { anchors.fill: parent }

  BorderSurface {
    anchors.fill: parent
    // The card is clamped at maxHeight while the column below is what decides
    // how tall it wants to be, so any child that forgets the budget would paint
    // over the scrim underneath. Selection mode's column is not budgeted at all
    // (see the design spec §15), which makes that a reachable mistake once
    // [spacing] scale drops far enough. Clipping turns that whole class of bug
    // into a cut edge instead of a spill. Nothing here deliberately overflows —
    // no shadow, no gradient border — and the buttons' hover tooltip lands well
    // inside a card at minHeight, so clipping does not eat anything intended.
    clip: true
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

        // A TextArea carries no scroll state of its own — no contentY, no
        // internal Flickable — so capping its height would simply cut the caret
        // off: typing past the cap goes blind. The Flickable is the scroll
        // carrier, and the caret-follow below is what keeps the line you are
        // typing visible. It hangs off the caret's own movement, because
        // contentY only changes when something scrolls it. (billy.chat's
        // Composer hooks onContentYChanged for this; that fires on scrolling,
        // not on typing, so it does not actually follow the caret.)
        Flickable {
          id: inputView
          anchors.fill: parent
          anchors.margins: root.inputInset
          contentWidth: width
          contentHeight: inputArea.contentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          TextArea {
            id: inputArea
            width: inputView.width
            placeholderText: "Type or paste text — Enter to translate"
            color: Color.foreground
            wrapMode: TextArea.Wrap
            textFormat: TextEdit.PlainText
            focus: root.mode === "input"
            background: null
            // The Flickable's margins are the inset; the control's own padding
            // would add a style-dependent number on top of it.
            padding: 0
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.body
            onTextChanged: {
              root.inputText = text
              root.inputChanged()
            }
            onCursorRectangleChanged: {
              if (!activeFocus) return
              var caret = cursorRectangle
              if (caret.y < inputView.contentY) inputView.contentY = caret.y
              else if (caret.y + caret.height > inputView.contentY + inputView.height)
                inputView.contentY = caret.y + caret.height - inputView.height
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
        height: Math.min(resultText.implicitHeight, root.resultCap)
        opacity: root.stale ? 0.6 : 1
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
        id: errorCaption
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
