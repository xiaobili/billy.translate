import QtQuick
import QtQuick.Layouts
import "Translate.js" as Translate

// A Markdown table drawn as QML, because Text.MarkdownText must not draw one.
//
// Qt's Markdown importer builds a QTextTable, and re-laying that out on the
// next text change crashes the scene graph (QSGBatchRenderer::Renderer::
// prepareAlphaBatches, SIGSEGV — it took quickshell down mid-stream). So the
// bubble cuts tables out of the Markdown (Translate.splitBlocks) and renders
// them here: a grid of bordered cells, the header row in a heavier weight.
//
// Style comes in as properties rather than being read from qs.Commons, which
// keeps this file runnable on its own — the layout is worth looking at without
// booting the shell.
Item {
  id: root

  property var header: []
  property var rows: []
  property color borderColor: "#4a4a4a"
  property color textColor: "#eeeeee"
  property string fontFamily: ""
  property int fontSize: 13
  property int padding: 5
  // A column never gets narrower than this, so a `k`/`v` table stays readable.
  property int minColumnWidth: 56

  // Flat cells + column widths, computed in one testable place.
  readonly property var grid: Translate.tableGrid(root.header, root.rows, root.width, root.minColumnWidth)

  implicitWidth: gridLayout.implicitWidth
  implicitHeight: gridLayout.implicitHeight

  GridLayout {
    id: gridLayout
    width: root.width
    columns: Math.max(1, root.grid.columns)
    columnSpacing: 0
    rowSpacing: 0

    Repeater {
      model: root.grid.cells
      delegate: Rectangle {
        id: cellBox

        // Widths sum to the card width, so the rightmost border sits on the
        // frame instead of a pixel short of it.
        Layout.preferredWidth: modelData.width
        Layout.preferredHeight: label.implicitHeight + 2 * root.padding
        Layout.fillWidth: false
        Layout.fillHeight: true
        color: "transparent"

        // Interior lines are drawn by the cells themselves — right and bottom
        // only — and the outer frame by the Rectangle above, so no two lines
        // ever double up.
        Rectangle {
          anchors.right: parent.right
          width: 1
          height: parent.height
          color: root.borderColor
          visible: !modelData.lastColumn
        }
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: root.borderColor
          visible: !modelData.lastRow
        }

        Text {
          id: label
          x: root.padding
          y: root.padding
          width: parent.width - 2 * root.padding
          // A cell is one line of Markdown (inline code, bold, links); it can
          // never be a table, so MarkdownText is safe here. `[x]` still has to
          // be escaped or Qt eats it as a tag.
          text: Translate.escapeHtmlTags(modelData.text)
          textFormat: Text.MarkdownText
          wrapMode: Text.Wrap
          color: root.textColor
          font.family: root.fontFamily
          font.pixelSize: root.fontSize
          font.weight: modelData.header ? Font.DemiBold : Font.Normal
        }
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: 1
    border.color: root.borderColor
  }
}
