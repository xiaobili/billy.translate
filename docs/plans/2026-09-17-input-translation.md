# 输入翻译（billy.translate）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给插件增加"手输文字直接翻译"的输入态：`SUPER + CTRL + I` 呼出，输入框常驻、回车译、Shift+回车换行、可改字重译、Esc 关闭后内容保留。

**Architecture:** 在现有唯一的 overlay 上增加与 `phase` **正交**的 `mode`（`selection` | `input`），复用同一套 Transport、取消、超时、Esc、复制与气泡渲染；输入框用 `TextArea` 顶替只读原文区；草稿靠 manifest 已有的 `keepLoaded: true` 常驻内存，不落盘。

**Tech Stack:** Quickshell 0.3.1 / QML（`qs.Commons`、`qs.Ui`、`QtQuick.Controls`）、node（纯函数测试）、bash。

**Spec:** `docs/specs/2026-09-17-select-to-translate-design.md` §15（本计划同步了 §8/§9/§13/§14）。冲突时以 spec 为准。

## Global Constraints

- 插件目录：`~/.config/omarchy/plugins/billy.translate/`，目录名必须等于 manifest 里的 `id`
- 插件目录内**不得有符号链接**（`omarchy-plugin-validate` 会拒绝整个插件）
- 颜色一律走 `Color` 单例，尺寸一律走 `Style.space(n)`，**不硬编码十六进制或裸像素数字**
- 密钥只存在于 `~/.local/state/omarchy/translate/config.json`（文件 0600、目录 0700）；**绝不进 argv**
- `IpcHandler` 的方法参数**必须标注类型**（未标注是 `QVariant`，加载期被拒绝）
- `manifest.json` 的 `keepLoaded: true` 是本功能草稿存活的前提，不要动它
- **QML 编译错误是粘性的**：热重载与 `rescanPlugins` 都会重放旧错误，改完 QML 必须 `omarchy restart shell` 才会重新编译
- 读日志只看当前进程：`pgrep -x quickshell`（`pgrep -x omarchy-shell` 匹配不到任何东西，外层 `grep` 会静默读作"没有错误"）
- **agent 不得执行 `omarchy restart shell`**；**不得运行 `tests/scripts.test.sh` 或 `tools/test.sh`**（会向焦点窗口发真实 Ctrl+C 并替换人类搭档的剪贴板）。需要它们的验证一律交给人来做
- **文档同步约定**：本计划落地后，`docs/plans/2026-09-17-select-to-translate.md` 视为**已关闭的历史记录**，不再随本功能同步（它内嵌的文件副本会与新代码产生差异，这是有意的）

---

### Task 1: `directionLabel()` 提为纯函数（TDD）

**Files:**
- Modify: `Translate.js`（新增纯函数，放在 `defaultSystemPrompt()` 之后）
- Test: `tests/translate.test.js`（新增 4 条，放在 `report()` 之前）
- Modify: `Overlay.qml`（删掉内联的 `labelFor`，改调 `Translate.directionLabel`；新增 `Translate` 导入）

**Interfaces:**
- Consumes: 无
- Produces: `Translate.directionLabel(text) -> "中文 → EN" | "→ 中文"` —— Task 2 会用它做实时标签

- [ ] **Step 1: 先写失败的测试**

在 `tests/translate.test.js` 的 `report()` **之前**插入：

```js
// ---------------------------------------------------------------- direction

// A client-side heuristic, deliberately not the rule the prompt hands the
// model: "predominantly Chinese" is the model's judgement, while this counts
// any CJK character as Chinese. The two can disagree at the margin.
check("empty text labels as non-Chinese", T.directionLabel(""), "→ 中文")
check("Chinese text labels the other way", T.directionLabel("你好，世界"), "中文 → EN")
check("English text labels to Chinese", T.directionLabel("hello world"), "→ 中文")
check("a single CJK character is enough", T.directionLabel("hello 你好"), "中文 → EN")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node tests/translate.test.js`
Expected: **抛异常并非零退出**：`TypeError: T.directionLabel is not a function`，**没有** `N/N passed` 汇总行（脚本在第一次调用处就死了，`report()` 到不了）。这是这个 runner 的真实失败形态——不要期待"失败计数 +1"。

- [ ] **Step 3: 写实现**

在 `Translate.js` 的 `defaultSystemPrompt()` 之后插入：

```js
// Which way the label points, in one place: the bubble shows it and the input
// field recomputes it on every keystroke. Any CJK character counts as Chinese
// — a label is a glance, not a language-detection pass of our own.
function directionLabel(text) {
  var chinese = /[一-鿿]/.test(String(text === undefined || text === null ? "" : text))
  return chinese ? "中文 → EN" : "→ 中文"
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node tests/translate.test.js`
Expected: `40/40 passed`（原 36 条 + 新增 4 条）

- [ ] **Step 5: 让 Overlay 用它**

`Overlay.qml` 的导入列表里（`import "Layout.js" as Layout` 之后）加一行：

```qml
import "Translate.js" as Translate
```

删掉整个 `labelFor`：

```qml
  // "EN → 中文" — enough to tell at a glance which way it went, without a
  // language-detection pass of our own.
  function labelFor(text) {
    var chinese = /[一-鿿]/.test(text)
    return chinese ? "中文 → EN" : "→ 中文"
  }
```

并把 `onTextReady` 里的调用改为：

```qml
      root.directionLabel = Translate.directionLabel(text)
```

- [ ] **Step 6: 跑门禁与两套纯函数测试，提交**

```bash
./tools/check-syntax.sh          # 期望：qml syntax ok
node tests/layout.test.js        # 期望：6/6 passed
node tests/translate.test.js     # 期望：40/40 passed
git add Translate.js tests/translate.test.js Overlay.qml
git commit -m "Extract the direction label into a tested pure function

The bubble shows it and the input field will recompute it on every keystroke,
and the rule was inline and untested. Behaviour is unchanged: any CJK
character still counts as Chinese."
```

---

### Task 2: 模式、输入框与提交/取消时序

**Files:**
- Modify: `Overlay.qml`（`mode`、`inputText`、`input()`、`submitInput()`、transport 文本绑定、`onFinished`）
- Modify: `Bubble.qml`（`mode`、`inputText`、`submitRequested()` 信号、输入区、焦点与按键）

**Interfaces:**
- Consumes: `Translate.directionLabel(text)`（Task 1）
- Produces:
  - `Overlay.mode: "selection" | "input"` —— Task 3 据此算高度预算
  - `Overlay.inputText: string`、`Overlay.submitInput(): void`
  - `Bubble.selectAllInput(): void`、`Bubble.submitRequested()` 信号
  - `IpcHandler.input(): void` —— Task 4 的键位绑它

- [ ] **Step 1: Overlay 加模式与入口**

在 `property bool opened: false` 之后加：

```qml
  // Orthogonal to `phase`: "selection" is the pick-a-selection flow, "input"
  // is the typed-text flow. The phase set is unchanged — input mode uses
  // empty / translating / done / error, and never picking (no probe runs).
  property string mode: "selection"
  // Bound, never assigned here: the TextArea inside Bubble.qml is the only
  // writer, so the two cannot drift. Ids are file-scoped — Bubble's own
  // `inputText` is a different property from this one.
  property string inputText: bubble.inputText
  // Set when a submit lands while a stream is in flight: cancel() is async, so
  // the new request has to wait for finished() rather than pressing start()
  // into the streaming guard.
  property bool pendingSubmit: false
```

`open(payloadJson)` 改为先看 payload 里的模式（其余行为不变）：

```qml
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = {} }
    // `opened` is set before the pick runs, so from this moment the shell
    // facade already reports the plugin open: a second hotkey press takes the
    // toggle's hide branch and cancels rather than re-picking. (R13)
    root.opened = true
    root.copied = false
    root.failureText = ""
    root.selectedText = ""
    root.directionLabel = ""
    if (payload.mode === "input") {
      root.mode = "input"
      // Nothing to pick: the surface can appear at once.
      root.phase = "empty"
      transport.cancel()
      Qt.callLater(function () { bubble.selectAllInput() })
      return
    }
    root.mode = "selection"
    root.phase = "picking"
    transport.cancel()
    probe.queryCursor()
    probe.pickText()
  }
```

`close()` 末尾加一行（清掉待提交标记，但不碰 `inputText` —— 草稿要留着）：

```qml
    root.pendingSubmit = false
```

新增入口函数与 IPC 方法（IPC 方法在现有 `IpcHandler` 块内，紧挨 `copy()` 之后）：

```qml
  function inputMode() {
    if (root.opened && root.mode === "input") {
      root.close()
      return
    }
    root.open('{"mode":"input"}')
  }
```

```qml
    function input(): void { root.inputMode() }
```

- [ ] **Step 2: 提交与取消时序**

在 `copyTranslation()` 之前加：

```qml
  function submitInput() {
    if (root.mode !== "input") return
    if (root.inputText.trim() === "") return
    if (transport.streaming) {
      // Cancel and re-submit from finished(): Transport's start() returns
      // early while a child is still exiting, and cancel() cannot be awaited.
      root.pendingSubmit = true
      transport.cancel()
      return
    }
    root.failureText = ""
    root.phase = "translating"
    transport.start()
  }
```

`transport.text` 的绑定改为随模式取源：

```qml
    text: root.mode === "input" ? root.inputText : root.selectedText
```

`onFinished` 开头插入 pendingSubmit 分支（**必须在最前**，否则被取消的那次会先写一个假的 `No translation returned.`）：

```qml
    onFinished: function (outcome) {
      if (root.pendingSubmit) {
        root.pendingSubmit = false
        root.failureText = ""
        root.phase = "translating"
        transport.start()
        return
      }
      if (transport.output === "") {
```

- [ ] **Step 3: Bubble 渲染输入区**

`Bubble.qml` 头部导入加 `import QtQuick.Controls`；根 `Item` 的属性区加：

```qml
  property string mode: "selection"
  property string inputText: ""
  // The input area's own cap, and what Task 3's budget reads. `inputArea` is
  // the TextArea further down this same file.
  readonly property int maxInputHeight: Style.space(72)
  readonly property int inputHeight: root.mode === "input" ? Math.min(inputArea.implicitHeight, root.maxInputHeight) : 0
  signal submitRequested()
```

`selectAllInput()` 放在 `x:` 之前：

```qml
  function selectAllInput() {
    if (root.mode !== "input") return
    inputArea.selectAll()
    inputArea.forceActiveFocus()
  }
```

只读原文那段（`// ------------- source` 的 `Text` 与它下面的 `PanelSeparator`）各加一行可见性，并在它们**之前**插入输入区：

```qml
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
```

`Bubble` 新增一个信号给实时标签用（Overlay 接它更新 `directionLabel`）：

```qml
  signal inputChanged()
```

并把原文 `Text` 与 `PanelSeparator` 的 `visible` 各改为：

```qml
        visible: root.mode !== "input" && root.sourceText !== ""
```

- [ ] **Step 4: Overlay 接线（焦点互斥、标签、信号）**

取词态那个 key catcher（`Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: root.close() }`）的 `focus` 改为：

```qml
    focus: root.mode !== "input"
```

`Bubble` 实例化块加三行：

```qml
    mode: root.mode
    onInputChanged: root.directionLabel = Translate.directionLabel(root.inputText)
    onSubmitRequested: root.submitInput()
```

（`inputText` 不从这里回写：输入框是唯一写入方，避免双向绑定打架。）

- [ ] **Step 5: 门禁 + 提交**

```bash
./tools/check-syntax.sh          # 期望：qml syntax ok，且无 [syntax] 行
git add Overlay.qml Bubble.qml
git commit -m "Add the input mode: a persistent field, Enter to translate

mode is orthogonal to phase, so the input flow reuses the existing transport,
cancel, timeout, Esc and copy paths untouched. Re-submitting while a stream is
in flight cancels and re-submits from finished(), because Transport's start()
returns early while a child is still exiting and cancel() cannot be awaited."
```

**本任务的验证边界（如实说明）**：QML 层没有自动化载体，上面这些改动**只能靠门禁 + 人工走查**确认。走查条目在 Task 4，且需要 `omarchy restart shell`——那是人类搭档的动作。

---

### Task 3: 布局预算、吞点击与旧结果变暗

**Files:**
- Modify: `Bubble.qml`（高度预算、输入框上限、吞点击、变暗）
- Modify: `Overlay.qml`（`submittedText` 与 `stale` 传参）

**Interfaces:**
- Consumes: `Overlay.mode`、`Overlay.inputText`（Task 2）
- Produces: `Bubble.stale: bool`（Task 4 的走查第 6 条看它）

- [ ] **Step 1: 高度预算（避免内容画到卡片外）**

`Bubble.qml` 的属性区加：

```qml
  readonly property int headerHeight: Style.space(20)
  // The card is clamped at maxHeight and BorderSurface does not clip, so the
  // input and the result share one budget instead of each capping itself —
  // their sum can otherwise exceed the card and draw over the scrim.
  readonly property int bodyBudget: root.maxHeight - 2 * root.cardPadding
  readonly property int resultCap: root.mode === "input"
    ? Math.max(0, root.bodyBudget - root.headerHeight - root.inputHeight - 2 * body.spacing)
    : root.maxResultHeight
```

`Flickable`（`resultView`）的高度绑定改为：

```qml
        height: Math.min(resultText.implicitHeight, root.resultCap)
```

- [ ] **Step 2: 卡片吞掉点击**

在 `Bubble.qml` 的根 `Item` 里、`BorderSurface` **之前**插入（声明在前的在底层，之后声明的按钮与输入框照常收到点击）：

```qml
  // Clicks inside the card must not reach the scrim's MouseArea behind it: in
  // input mode that would dismiss the bubble the moment you click to place the
  // caret, and in selection mode "click the text and it vanishes" is a
  // surprise either way.
  MouseArea { anchors.fill: parent }
```

- [ ] **Step 3: 旧结果变暗**

`Overlay.qml` 加一个属性并在提交时记录产出该译文的文本：

```qml
  property string submittedText: ""
```

`submitInput()` 的两条提交路径各加一行 `root.submittedText = root.inputText`（在 `root.failureText = ""` 之前），`onFinished` 的 pendingSubmit 分支同样在 `transport.start()` 之前加这一行。

`Bubble.qml` 加属性并从实例化处传入：

```qml
  property bool stale: false
```

`resultView` 的 `Flickable` 加一行：

```qml
        opacity: root.stale ? 0.6 : 1
```

`Overlay.qml` 的 `Bubble` 实例化块加：

```qml
    stale: root.mode === "input" && root.inputText !== root.submittedText && root.submittedText !== ""
```

- [ ] **Step 4: 门禁 + 提交**

```bash
./tools/check-syntax.sh          # 期望：qml syntax ok
git add Bubble.qml Overlay.qml
git commit -m "Budget the card's height, swallow clicks, dim a stale result

The card is clamped and does not clip, so the input box and the result now
share one budget rather than each capping itself. The card swallows clicks so
placing the caret cannot dismiss the bubble. A result whose input has since
changed dims to 0.6 rather than passing as current."
```

---

### Task 4: 键位、README 与验收走查

**Files:**
- Modify: `~/.config/hypr/bindings.lua`（仓库外，人类搭档的活配置）
- Modify: `README.md`
- Modify: `tests/translate.test.js`（收紧一条断言，见 Step 1）
- Modify: `docs/plans/2026-09-17-select-to-translate.md`（加一行"本文已关闭"的说明）
- Test: 人工走查 12 条 + `./tools/test.sh`

**Interfaces:**
- Consumes: `IpcHandler.input()`（Task 2）、`Bubble.stale`（Task 3）
- Produces: 可交付的功能

- [ ] **Step 1: 收紧方向标签的一条断言**

`tests/translate.test.js` 里那条 `check("a single CJK character is enough", T.directionLabel("hello 你好"), "中文 → EN")` 的**名字与输入不符**：`"hello 你好"` 含两个 CJK 字符，而全套里没有任何用例只含一个 —— 于是"要求至少两个 CJK 才判中文"的实现也能通过这条。改名，并补一条真正只含一个 CJK 字符的：

```js
check("CJK among Latin text is enough", T.directionLabel("hello 你好"), "中文 → EN")
check("one CJK character alone is enough", T.directionLabel("好"), "中文 → EN")
```

（Task 1 留下的那条名字保持不变地删掉，位置不动。）

Run: `node tests/translate.test.js`
Expected: `41/41 passed`（40 条 + 新增 1 条）

- [ ] **Step 2: 装键位**

先确认仍空闲（**不要假设** —— 上一轮就是在这里撞上了 omarchy 自带的 Activity）：

```bash
omarchy menu keybindings --print | grep -E "^SUPER CTRL \+ I( |$)"   # 期望无输出
```

在 `~/.config/hypr/bindings.lua` **末尾**追加一行（其余一行不动）：

```lua
o.bind("SUPER + CTRL + I", "Translate typing", "omarchy-shell billy.translate input")
```

再确认它进去了：

```bash
omarchy menu keybindings --print | grep -i "translate"
# 期望三行：Translate selection / Copy translation / Translate typing
```

- [ ] **Step 3: README**

`## Keys` 表加一行：

```markdown
| `SUPER + CTRL + I` | Type or paste text to translate; Enter translates, Shift+Enter adds a line |
```

在 `## Keys` 之后新增一节：

```markdown
## Typing text

`SUPER + CTRL + I` opens the bubble with an input field instead of the
selection. Enter translates, Shift+Enter adds a line, and editing the text and
pressing Enter again re-translates — the request in flight is cancelled first.
A result whose text you have since changed is dimmed, so an old translation
never reads as the current one.

The draft lives in memory: it survives closing the bubble and comes back
selected next time, but a shell restart clears it.
```

`## Known limitations` 追加第 5 条：

```markdown
5. The draft in the input field is in memory only — a shell restart clears it.
```

- [ ] **Step 4: 旧计划标记为已关闭**

在 `docs/plans/2026-09-17-select-to-translate.md` 的标题行之后插入：

```markdown
> **本文已关闭（2026-09-17）**：输入翻译功能见 `2026-09-17-input-translation.md`。此后改动只同步到新计划，
> 本文内嵌的文件副本不再随之更新 —— 它们是那次实现的历史快照。
```

- [ ] **Step 5: 提交**

```bash
git add README.md tests/translate.test.js docs/plans/2026-09-17-select-to-translate.md
git commit -m "Document input translation and give T back its neighbours

README gains the third chord, a Typing text section, and the draft's
in-memory lifetime as a known limitation; the previous plan is marked closed
so its embedded file copies are read as a historical snapshot."
```

（`bindings.lua` 在仓库外，不随提交走。）

- [ ] **Step 6: 跑全量测试（人类搭档执行）**

Run（独立终端窗口，**不要**用 `$()` 捕获）：

```bash
cd ~/.config/omarchy/plugins/billy.translate && ./tools/test.sh; echo "EXIT=$?"
```

Expected: 三段全绿、`25/25 passed`、`EXIT=0`。套件会替换剪贴板（文本会后还原），并向焦点窗口发一次真实 Ctrl+C —— 所以要在能承受这个的终端里跑。

- [ ] **Step 7: 重启 shell 并走查（人类搭档执行）**

```bash
omarchy restart shell && sleep 3
journalctl --user --since "1 min ago" | grep "omarchy-shell\[$(pgrep -x quickshell)\]" | grep -i translate
```

Expected: 无 `failed` / `Expected token` / `is not a type`。**行号与磁盘文件对不上说明是旧的缓存错误**，不是新问题。

| # | 操作 | 期望 |
|---|---|---|
| 1 | `SUPER + CTRL + I` | 气泡出现，只有输入框；空输入时无标签 |
| 2 | 输入英文 / 中文 | 标签随打字实时变 `→ 中文` / `中文 → EN` |
| 3 | `Enter` | 译文流式出现 |
| 4 | `Shift + Enter` | 换行，不翻译 |
| 5 | 译文出现后改字再回车 | 旧请求被取消、新译文出现；全程**无**假错误 |
| 6 | 改了字但未回车 | 旧译文变暗；回车后恢复 |
| 7 | 点气泡内部 / 点暗区 | 不关闭 / 关闭 |
| 8 | `Esc` 后重按 `SUPER + CTRL + I` | 内容还在，且全选 |
| 9 | 空输入回车 | 无反应、无请求（可 `pgrep -a curl` 佐证） |
| 10 | 输入态点复制按钮 | 复制的是译文 |
| 11 | **回归**：`SUPER + CTRL + U` 取词翻译 | 照旧（Esc、复制、长文封顶、401 文案） |
| 12 | 输入十行长文 | 输入框约 3 行后内部滚动；卡片不越出屏幕 |

## 完成标准

- `./tools/test.sh` 全绿（`25/25`），`node tests/translate.test.js` 41/41
- 上面 12 条走查全部通过，且第 11 条（取词回归）没有被本功能破坏
- 没有一处硬编码颜色或裸像素数字
- `docs/specs/2026-09-17-select-to-translate-design.md` §15 与本实现一致（实现中若发现 spec 有错，改 spec 而不是默默偏离）
