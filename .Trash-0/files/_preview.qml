import QtQuick
import "Translate.js" as Translate

Window {
  id: win
  width: 420
  height: 700
  visible: true
  color: "#f7f7f7"
  readonly property var blocks: Translate.splitBlocks("Each agent plugin is **self-contained** \u2014 it bundles the skills it uses, so installing the agent is all you need.\n\n| Function | Agent | What it does |\n| --- | --- | --- |\n| **Coverage & advisory** | **[Pitch Agent](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/pitch-agent)** | Comps, precedents, LBO \u2192 branded pitch deck, end to end |\n|  | **[Meeting Prep Agent](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/meeting-prep-agent)** | Briefing pack before every client meeting |\n| **Research & modeling** | **[Market Researcher](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/market-researcher)** | Sector or theme \u2192 industry overview, competitive landscape, peer comps, ideas shortlist |\n|  | **[Earnings Reviewer](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/earnings-reviewer)** | Earnings call + filings \u2192 model update \u2192 note draft |\n|  | **[Model Builder](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/model-builder)** | DCF, LBO, 3-statement, comps \u2014 live in Excel |\n| **Fund admin & finance ops** | **[Valuation Reviewer](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/valuation-reviewer)** | Ingests GP packages, runs valuation template, stages LP reporting |\n|  | **[GL Reconciler](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/gl-reconciler)** | Finds breaks, traces root cause, routes for sign-off |\n|  | **[Month-End Closer](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/month-end-closer)** | Accruals, roll-forwards, variance commentary |\n|  | **[Statement Auditor](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/statement-auditor)** | Audits LP statements before distribution |\n| **Operations & onboarding** | **[KYC Screener](https://github.com/anthropics/financial-services/blob/main/plugins/agent-plugins/kyc-screener)** | Parses onboarding docs, runs the rules engine, flags gaps |\n\nFor Managed Agent deployment \u2014 `agent.yaml`, leaf-worker subagents, steering-event examples, and per-agent security notes \u2014 see **[managed-agent-cookbooks/](https://github.com/anthropics/financial-services/blob/main/managed-agent-cookbooks)**.")
  Column {
    x: 14; y: 14; width: 392; spacing: 8
    Repeater {
      model: win.blocks
      delegate: Item {
        width: 392
        height: modelData.kind === "table" ? tb.implicitHeight : tx.implicitHeight
        Text {
          id: tx; width: parent.width; visible: modelData.kind !== "table"
          textFormat: Text.MarkdownText
          text: modelData.kind === "table" ? "" : Translate.escapeHtmlTags(modelData.text)
          wrapMode: Text.Wrap; color: "#1c1c1c"; font.pixelSize: 14
        }
        Table {
          id: tb; width: parent.width; visible: modelData.kind === "table"
          header: modelData.header || []; rows: modelData.rows || []
          borderColor: "#c8c8c8"; textColor: "#1c1c1c"; fontSize: 12; padding: 5; minColumnWidth: 68
        }
      }
    }
  }
  Timer { interval: 1500; running: true; onTriggered: win.contentItem.grabToImage(function (r) { r.saveToFile("/home/billy/.config/omarchy/plugins/billy.translate/.workbuddy/table-preview.png"); Qt.exit(0) }) }
  Timer { interval: 15000; running: true; onTriggered: Qt.exit(9) }
}
