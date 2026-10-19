import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Translate.js" as Translate

// The card itself: where it sits, what it shows, and the two things you can do
// to it. Positioning is delegated to Layout.js — this file only supplies the
// numbers that go in.
Item {
  id: root

  // Set by Overlay.qml each time the cursor moves or the content resizes.
  property var placement: ({ x: 0, y: 0 })
  property string phase: "done" // recognizing | translating | done | empty | error
  property string sourceText: ""
  property string translation: ""
  property string errorText: ""
  property string directionLabel: ""
  property bool copied: false
  property bool stale: false

  property string mode: "selection"
  // True when this session came from a *rich* hotkey — `ALT + SHIFT + D` or
  // `ALT + SHIFT + I`. Set by Overlay.qml. Plain selection shares
  // mode === "selection" with the rich one, and the input field is shared by
  // both input hotkeys, so the mode alone cannot tell them apart: this can.
  property bool rich: false
  property string inputText: ""
  // The target language the user picked, "" when the built-in Chinese/English
  // pair is in force (see Translate.targetLang). The picker persists it.
  property string targetCode: ""
  // P0.2: shown under the result when the request was truncated.
  property string noticeText: ""
  // Modality: while the bubble is open it is the keyboard focus owner, so the
  // picker is opened with the mouse or Ctrl+L and closed with Esc — and Esc
  // has to close the picker before it closes the bubble.
  property bool pickerOpen: false

  signal targetPicked(string code)
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
  readonly property int captionHeight: (errorCaption.visible ? errorCaption.implicitHeight + body.spacing : 0)
      + (noticeCaption.visible ? noticeCaption.implicitHeight + body.spacing : 0)
  // P1.6: selection mode gets the same budget treatment input mode already
  // has. The source preview (up to 3 lines) and its separator are charged like
  // the input area is, so the card no longer leans on BorderSurface clipping
  // once [spacing] scale drops — the clipped last line from the README's
  // known limitations. Gap counts mirror the visible children:
  // header→source→separator→result is three gaps, header→result (no source)
  // is one.
  readonly property int sourceBlockHeight: sourcePreview.visible ? sourcePreview.implicitHeight + body.spacing : 0
  readonly property int selectionGaps: sourcePreview.visible ? 3 * body.spacing : body.spacing
  readonly property int selectionResultCap: Math.min(root.maxResultHeight, Math.max(0,
      root.bodyBudget - root.headerHeight - root.sourceBlockHeight - root.selectionGaps - root.captionHeight))
  // Markdown rendering is opt-in per hotkey, never inferred: only the two rich
  // variants ask for it (see Translate.rendersMarkdown). Everything else —
  // plain selection, OCR and now the plain input field — shows the text as it
  // arrived, because its `*`, `#`, backticks and `<...>` are usually literal
  // characters and MarkdownText would mangle the display.
  readonly property bool renderMarkdown: Translate.rendersMarkdown(root.mode, root.rich)
  readonly property int resultCap: root.mode === "input"
    ? Math.min(root.maxResultHeight, Math.max(0,
        root.bodyBudget - root.headerHeight - root.inputHeight - 2 * body.spacing - root.captionHeight))
    : root.selectionResultCap

  // The answer cut into renderable blocks, for the Markdown-rendered modes:
  // prose (a Text) and tables (a Table, drawn as QML). Empty in plain modes,
  // which render the raw translation in a single Text.
  //
  // Tables are lifted out here because Text.MarkdownText cannot draw one: Qt
  // builds a QTextTable and re-laying it out on the next text change crashes
  // the scene graph (prepareAlphaBatches, SIGSEGV — it took the shell down
  // mid-stream). Nothing about that is tied to table size, so every table goes
  // through Table.qml, at any stage of the stream.
  //
  // The caret is part of this model rather than the view: it belongs at the end
  // of the last block, and a table has no text to append it to.
  readonly property var blocks: {
    if (!root.renderMarkdown) return []
    var source = root.phase === "error" && root.translation === ""
      ? root.errorText : root.translation
    if (String(source) === "") return []
    var list = Translate.splitBlocks(source)
    if (root.phase === "translating") {
      var last = list.length > 0 ? list[list.length - 1] : null
      if (last !== null && last.kind === "md") last.text = last.text + "▌"
      else list.push({ kind: "md", text: "▌" })
    }
    return list
  }

  function restoreDraft(text) {
    if (root.mode !== "input") return
    inputArea.text = String(text || "")
  }

  // Opening the picker re-measures the card; it closes by itself when a new
  // translation starts, because it belongs to the gap between two answers and
  // not to the answer. A zero-interval timer rather than a direct assignment:
  // the phase changes inside the picker's own click handler, and hiding the
  // clicked item mid-signal is the kind of teardown QML does not like.
  property Timer pickerCloseTimer: Timer {
    interval: 0
    onTriggered: root.pickerOpen = false
  }

  Connections {
    target: root
    function onPhaseChanged() {
      if (root.phase === "translating") root.pickerCloseTimer.restart()
    }
  }

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
        id: headerRow
        width: parent.width
        height: Style.space(20)

        // The direction label doubles as the language picker's toggle. It is a
        // MouseArea rather than a Button so the header keeps its caption size:
        // the label is a glance, and a button would grow the 20px row.
        Item {
          id: directionChip
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          width: directionText.implicitWidth + (root.pickerOpen ? Style.space(8) : 0)

          Text {
            id: directionText
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            text: root.directionLabel
            color: directionArea.containsMouse || root.pickerOpen ? Color.foreground : Color.muted
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: directionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pickerOpen = !root.pickerOpen
          }
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

      // ------------------------------------------------------ language picker
      // Inline rather than a popup window: the overlay is the only focused
      // surface, and a second window would need its own focus handling to be
      // reachable at all. A Flow of small chips sits in the column under the
      // header, so the card grows by a row or two while it is open and the
      // placement clamp follows.
      PanelSeparator {
        width: parent.width
        visible: root.pickerOpen
      }

      Flow {
        id: languagePicker
        width: parent.width
        spacing: Style.space(4)
        visible: root.pickerOpen

        Repeater {
          // "Auto" first: it is what the config had before this setting
          // existed, and the only choice that lets the plugin decide.
          model: [""].concat(Translate.languageCodes())

          delegate: Button {
            required property string modelData
            readonly property bool isAuto: modelData === ""
            text: isAuto ? "Auto" : Translate.languageLabel(modelData)
            tooltipText: isAuto
              ? "Built-in pair: Chinese to English, everything else to Chinese"
              : Translate.languageName(modelData)
            selected: Translate.normalizeLang(root.targetCode) === modelData
            focusable: false
            onClicked: root.targetPicked(modelData)
          }
        }
      }

      // -------------------------------------------------------------- input
      // The typed text *is* the source in this mode, so it takes the slot the
      // read-only source text occupies otherwise.
      Item {
        width: parent.width
        visible: root.mode === "input"
        height: root.inputHeight

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
                // Esc unwinds one layer at a time: the picker first, then the
                // bubble. Closing both at once loses the draft-in-progress
                // context you were just in.
                if (root.pickerOpen) root.pickerOpen = false
                else root.closeRequested()
                return
              }
              // Ctrl+L opens the language picker in input mode too, where this
              // TextArea, not the overlay's key item, is the focus owner.
              if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
                event.accepted = true
                root.pickerOpen = !root.pickerOpen
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

      PanelSeparator {
        width: parent.width
        visible: root.mode === "input"
      }

      // ------------------------------------------------------------- source
      // Shown so the fallback path is falsifiable: when the synthetic Ctrl+C
      // grabs the wrong thing, this is how you see it.
      Text {
        id: sourcePreview
        width: parent.width
        visible: root.mode !== "input" && root.sourceText !== ""
        // PlainText: the preview shows the captured selection verbatim, and
        // the default AutoText would flip to rich text when the selection
        // looks like HTML — swallowing the very `<...>` this view exists to
        // make visible.
        textFormat: Text.PlainText
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

      Row {
        id: recognizingStatus
        width: parent.width
        visible: root.phase === "recognizing"
        spacing: Style.space(8)

        BusyIndicator {
          width: Style.space(18)
          height: width
          running: recognizingStatus.visible
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Recognizing screenshot..."
          color: Color.muted
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ------------------------------------------------------------- result
      // One node for the answer in every state: partial while streaming,
      // final when done, or the failure reason when nothing arrived at all.
      // The block caret is what says "still arriving" — a spinner would be
      // heavier than a bubble this size deserves.
      //
      // Markdown-rendered modes draw the answer as a column of blocks, because
      // tables need their own renderer: Text.MarkdownText would build a
      // QTextTable, and re-laying that out on the next text change crashes the
      // scene graph (see Translate.splitBlocks / Table.qml). Plain modes have
      // nothing to parse and stay a single Text.
      Flickable {
        id: resultView
        width: parent.width
        visible: root.phase !== "empty" && root.phase !== "recognizing"
        readonly property real bodyHeight: root.renderMarkdown
          ? resultBody.implicitHeight : resultText.implicitHeight
        height: Math.min(bodyHeight, root.resultCap)
        opacity: root.stale ? 0.6 : 1
        contentWidth: width
        contentHeight: bodyHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Follow the stream: when new text arrives while translating and the
        // view was already at the bottom, scroll to the new bottom so the
        // latest output stays visible. If the user dragged up to read earlier
        // output, the view stays where they left it instead of being yanked.
        // lastContentHeight tracks the pre-update height because
        // onContentHeightChanged already sees the new value.
        property real lastContentHeight: 0
        onContentHeightChanged: {
          if (root.phase === "translating") {
            var wasAtBottom = contentY >= lastContentHeight - height - 2
            if (wasAtBottom) contentY = Math.max(0, contentHeight - height)
          }
          lastContentHeight = contentHeight
        }

        Text {
          id: resultText
          width: parent.width
          visible: !root.renderMarkdown
          // Plain selection, OCR text and — since the plain input hotkey
          // `ALT + I` stopped rendering Markdown — plain typed input is
          // arbitrary: its `*`, `#`, backticks and `<...>` are usually literal
          // characters, so MarkdownText would mangle the display. PlainText
          // shows it as it arrived.
          textFormat: Text.PlainText
          text: {
            if (root.phase === "error" && root.translation === "") return root.errorText
            if (root.phase === "empty" || root.phase === "recognizing") return ""
            return root.translation
          }
          color: root.phase === "error" && root.translation === "" ? Color.urgent : Color.foreground
          wrapMode: Text.Wrap
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.body
        }

        Column {
          id: resultBody
          width: parent.width
          visible: root.renderMarkdown
          spacing: Style.space(6)

          Repeater {
            model: root.blocks.length

            delegate: Item {
              id: blockItem
              width: resultBody.width
              // `blocks` is rebuilt on every flush; reading it by index keeps
              // this delegate alive across updates — Repeater only recreates
              // when the block *count* changes, not when a cell grows.
              readonly property var block: root.blocks[index] || { kind: "md", text: "" }
              implicitHeight: block.kind === "table"
                ? tableBlock.implicitHeight : textBlock.implicitHeight
              height: implicitHeight

              Text {
                id: textBlock
                width: parent.width
                visible: blockItem.block.kind !== "table"
                // MarkdownText parses `<...>` as inline HTML and drops it, so
                // a tag-shaped sequence that survived translation
                // (List<String>, <name>, a literal tag) would vanish. Escaping
                // its `<` renders it literally; code spans and fences are
                // already literal and are left alone. Copy still takes the
                // unescaped `translation`, so pasting keeps the original.
                //
                // flattenTables is a safety net: splitBlocks already lifted
                // every table out of the prose, and this catches the one it
                // could not parse rather than letting a table reach the
                // renderer.
                textFormat: Text.MarkdownText
                text: blockItem.block.kind === "table" ? ""
                  : Translate.escapeHtmlTags(Translate.flattenTables(blockItem.block.text))
                color: root.phase === "error" && root.translation === "" ? Color.urgent : Color.foreground
                wrapMode: Text.Wrap
                font.family: Style.font.resolvedFamily
                font.pixelSize: Style.font.body
              }

              Table {
                id: tableBlock
                width: parent.width
                visible: blockItem.block.kind === "table"
                header: blockItem.block.header || []
                rows: blockItem.block.rows || []
                borderColor: Color.popups.border
                textColor: Color.foreground
                fontFamily: Style.font.resolvedFamily
                fontSize: Style.font.bodySmall
                minColumnWidth: Style.space(56)
              }
            }
          }
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
        // PlainText: the failure reason can embed a provider's raw (possibly
        // HTML) error body, which must be shown, not parsed.
        textFormat: Text.PlainText
        text: root.errorText
        color: Color.urgent
        elide: Text.ElideRight
        maximumLineCount: 3
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.caption
      }

      // P0.2: the request was truncated to maxChars — the answer covers only
      // the head of the input, and the bubble says so.
      Text {
        id: noticeCaption
        width: parent.width
        visible: root.noticeText !== ""
        textFormat: Text.PlainText
        text: root.noticeText
        color: Color.muted
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.Wrap
        font.family: Style.font.resolvedFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
