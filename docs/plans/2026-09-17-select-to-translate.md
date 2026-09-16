# 划词翻译插件（billy.translate）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Omarchy 桌面选中文本后按 `SUPER + CTRL + T`，在光标位置的气泡里看到流式译文，并可一键复制。

**Architecture:** 一个第三方 overlay 插件。取词与光标定位两种「有状态、有超时」的时序逻辑交给 `bin/` 下的两个 shell 脚本，QML 侧只读它们的 stdout；从脚本里拿到的光标与屏幕数据经 `Layout.js` 的纯几何函数算出气泡坐标；翻译请求沿用 `billy.chat` 已验证的 curl 流式方案（API key 走 0600 配置文件，不进 argv）。

**Tech Stack:** Quickshell 0.3.1 / QML（`qs.Commons`、`qs.Ui`）、bash、`wl-clipboard` 2.3.0、`wtype`、`hyprctl`、`curl`、node（仅用于跑纯函数测试）

**Spec:** `docs/specs/2026-09-17-select-to-translate-design.md`

## Global Constraints

- 插件目录：`~/.config/omarchy/plugins/billy.translate/`，目录名必须等于 manifest 里的 `id`
- `manifest.json` 的 `schemaVersion` 必须是**数字** `1`，不是字符串
- 插件 `id` 用 `billy.` 前缀；`omarchy.` 是保留给第一方插件的，第三方用会被扫描器丢弃
- 插件目录内**不得有符号链接**（`omarchy-plugin-validate` 会拒绝整个插件）
- 颜色一律走 `Color` 单例，尺寸一律走 `Style.space(n)`，**不硬编码十六进制或裸像素数字**
- 密钥只存在于 `~/.local/state/omarchy/translate/config.json`，权限 0600，目录 0700；**绝不进 argv**
- `IpcHandler` 的方法参数**必须标注类型**，未标注是 `QVariant`，加载时会被拒绝
- `FileView` 凡是「写完下一步就要读」的场景，必须 `blockWrites: true`
- 配置目录必须先 `mkdir -p`，且首次写入门控在该进程的 `onExited` 上
- `wl-paste` **没有 `--clipboard` 选项**：剪贴板是默认，`--primary` 才是主选择区
- 本机屏幕：单屏 `DP-1`，2560×1080，`scale` 1，`transform` 0

### 三个必须记住的操作事实

1. **QML 编译错误是粘性的。** `rescanPlugins` 会重放**同一个旧错误、同一行号**，看起来像没生效。修复后必须 `omarchy restart shell`。判断方法：日志行号与磁盘内容对不上。
2. **读日志只看当前进程**，否则上个进程的错误看起来像现在的：

   ```bash
   journalctl --user --since "2 min ago" | grep "omarchy-shell\[$(pgrep -x quickshell)\]"
   ```

   **注意进程名**：shell 进程的 argv[0] 是 `quickshell`（不是 `omarchy-shell`），但 journald 把它的行标成 `omarchy-shell[PID]`。所以 `pgrep -x omarchy-shell` 会**退出码 1、无匹配**，外面套的 `grep` 于是静默匹配不到任何东西 —— 读起来就像「没有错误」。已在本机实测确认。

3. **`qmllint` 是语法门禁，但只证明语法。** `/usr/lib/qt6/bin/qmllint <file> 2>&1 | grep '\[syntax\]'` 必须为空。实测第一方 `Clipboard.qml` 命中 0 条，缺右括号/表达式截断各命中 1 条 —— 零假阳性。这把「重启 shell 才发现语法错」提前到了编辑时。

   **通过它不等于插件能加载。** 加载期的拒绝（未标注类型的 `IpcHandler` 参数、解析不了的导入、manifest 问题）不是解析错误，门禁看不见。真正的加载检查只有 `omarchy restart shell` 之后读日志。

> `qmllint` 对 `qs.*` 导入和 `PanelWindow` 会报大量无法解析的警告，那是正常的（它们由运行中的 shell 注册）。**只过滤 `[syntax]`**，别的都忽略。

### 前置条件：插件必须先启用

第三方 overlay 插件**默认不启用**。`id` 必须出现在 `~/.config/omarchy/shell.json` 的顶层 `plugins[]` 里，否则 `shell.summon()` 会拒绝：

```
WARN qml: summon: plugin not enabled, not summoning: billy.translate
```

注意 `omarchy-shell shell toggle ...` 在这种情况下**仍然以 0 退出**，看起来像成功 —— 这是静默失败。启用：

```bash
omarchy plugin enable billy.translate
```

Task 1 的验证已在本机执行过这一步。**Task 10 的 README 必须写明它**，否则全新克隆第一次 summon 会静默无反应。

---

### Task 1: 插件骨架与语法门禁

先让一个最小的插件能被 shell 认出来并召唤 —— 契约通了，后面所有代码才有地方落。

**Files:**
- Create: `manifest.json`
- Create: `Overlay.qml`
- Create: `README.md`
- Create: `tools/check-syntax.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: 无（第一个任务）
- Produces: 插件 id `billy.translate`；根元素暴露 `open(payloadJson: string): void`、`close(): void`、属性 `opened: bool`；IPC 目标 `billy.translate`

- [ ] **Step 1: 写 manifest.json**

```json
{
  "schemaVersion": 1,
  "id": "billy.translate",
  "name": "Translate",
  "version": "0.1.0",
  "author": "Billy",
  "license": "MIT",
  "description": "Select text, press a key, read the translation in a bubble at the cursor.",
  "kinds": ["overlay"],
  "keepLoaded": true,
  "entryPoints": { "overlay": "Overlay.qml" }
}
```

- [ ] **Step 2: 写最小 Overlay.qml**

先只做骨架：能开、能关、`opened` 正确。译文和取词后面再加。

```qml
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
```

- [ ] **Step 3: 写语法门禁脚本**

`tools/check-syntax.sh`：

```bash
#!/usr/bin/env bash
# Fails on QML syntax errors before the shell gets a chance to cache them.
#
# qmllint cannot resolve qs.* imports or PanelWindow (the running shell
# registers those), so it emits a lot of unresolved-type noise that is not
# worth reading. The [syntax] tag is the subset that actually blocks a
# compile, and it is clean: a good file reports none.
set -uo pipefail

Qmllint="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
[ -x "$Qmllint" ] || { echo "qmllint not found at $Qmllint" >&2; exit 2; }

cd "$(dirname "$0")/.." || exit 2
status=0
for file in *.qml; do
  [ -e "$file" ] || continue
  hits="$("$Qmllint" "$file" 2>&1 | grep '\[syntax\]')"
  if [ -n "$hits" ]; then
    echo "$hits"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "qml syntax ok"
exit "$status"
```

- [ ] **Step 4: 写 .gitignore 和 README 占位**

`.gitignore`：
```
*.qmlc
*.jsc
```

`README.md` 先只写标题和一句说明，Task 10 补全：
```markdown
# Translate (billy.translate)

Select text anywhere, press `SUPER + CTRL + T`, read the translation in a
bubble at the cursor.

Full documentation is written in Task 10 of the implementation plan.
```

- [ ] **Step 5: 跑语法门禁**

Run: `chmod +x tools/check-syntax.sh && ./tools/check-syntax.sh`
Expected: 输出 `qml syntax ok`，退出码 0

- [ ] **Step 6: 确认插件被 shell 认出**

Run: `omarchy-shell shell rescanPlugins && omarchy-shell shell listPlugins | jq '.[] | select(.id=="billy.translate")'`
Expected: 一个有 `"id": "billy.translate"`、`"kinds": ["overlay"]`、`"active": false` 的对象。**若为空**，说明 manifest 被拒 —— 读 `journalctl --user | grep "omarchy-shell\[$(pgrep -x omarchy-shell)\]" | tail -20` 看拒绝原因。

- [ ] **Step 7: 召唤并确认 surface 出现**

Run: `omarchy-shell shell toggle billy.translate '{}'`
Expected: 屏幕变暗（遮罩出现）。再跑一次同一个命令应当关闭它。**若报 `unknown`**，检查 manifest 里的 `id` 与目录名是否一致。

- [ ] **Step 8: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add -A
git commit -m "Add plugin skeleton: manifest, summonable overlay, qml syntax gate"
```

---

### Task 2: Layout.js —— 摆放与夹紧（纯函数，TDD）

气泡坐标是纯几何，和 QML 无关，所以可以先把它钉死。这是整个插件最容易出边界 bug 的地方。

**Files:**
- Create: `Layout.js`
- Create: `tests/run.js`
- Test: `tests/run.js`

**Interfaces:**
- Consumes: 无
- Produces: `place(cursor, screen, card, gap, edge) -> {x, y}`，其中 `cursor`/`screen`/`card` 都是 `{x,y}` / `{w,h}` 形状的普通对象

- [ ] **Step 1: 写测试运行器**

QML 的 `.js` 导入把顶层声明暴露成模块对象的属性。用 `node:vm` 把同一份源码加载进一个 context，就得到同样的形状 —— 测试跑的是**真正要发布的源文件**，不是副本。

`tests/run.js`：

```js
// Loads the plugin's QML-flavoured .js files into a vm context and asserts
// against them. No dependencies: node's own test runner would need the files
// to be ES modules, and they are not.
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const ROOT = path.join(__dirname, "..")

// QML `.js` imports expose top-level declarations as properties of a module
// object; a vm context gives the same shape for free.
function load(name) {
  const file = path.join(ROOT, name)
  const context = vm.createContext({})
  vm.runInContext(fs.readFileSync(file, "utf8"), context, { filename: file })
  return context
}

let checks = 0
let failures = 0

function check(what, actual, expected) {
  checks++
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log("ok   " + what)
  } else {
    failures++
    console.log("FAIL " + what + "\n       expected " + e + "\n       actual   " + a)
  }
}

function report() {
  console.log("\n" + (checks - failures) + "/" + checks + " passed")
  process.exit(failures === 0 ? 0 : 1)
}

module.exports = { load, check, report }
```

- [ ] **Step 2: 写失败的测试**

`tests/layout.test.js`：

```js
const { load, check, report } = require("./run")

const Layout = load("Layout.js")

// A 2560x1080 screen, a 420x200 card, matching the machine this targets.
const SCREEN = { w: 2560, h: 1080 }
const CARD = { w: 420, h: 200 }
const GAP = 12
const EDGE = 8

// Middle of the screen: below and to the right of the cursor.
check("places below-right when there is room",
  Layout.place({ x: 800, y: 400 }, SCREEN, CARD, GAP, EDGE),
  { x: 812, y: 412 })

// Near the bottom edge: must flip above the cursor.
check("flips above when it would overflow the bottom",
  Layout.place({ x: 800, y: 1003 }, SCREEN, CARD, GAP, EDGE),
  { x: 812, y: 791 })

// Near the right edge: must clamp to the safe area.
check("clamps to the right edge",
  Layout.place({ x: 2550, y: 400 }, SCREEN, CARD, GAP, EDGE),
  { x: 2132, y: 412 })

// Cursor at the origin. The gap alone (12) already clears the edge floor (8),
// so the card lands at the gap offset and the edge clamp never fires. (This
// case originally expected {8,8}; that expectation was wrong, not the code.)
check("a cursor at the origin lands at the gap offset",
  Layout.place({ x: 0, y: 0 }, SCREEN, CARD, GAP, EDGE),
  { x: 12, y: 12 })

// A card taller than the screen cannot fit either way; the top edge is the
// only position that stays reachable.
check("clamps a card taller than the screen",
  Layout.place({ x: 800, y: 600 }, { w: 2560, h: 400 }, { w: 420, h: 900 }, GAP, EDGE),
  { x: 812, y: 8 })

// Bottom-right corner: x clamps to the right margin, and y flips above the
// cursor. That flip is already legal (card bottom 1068 <= 1080 - 8), so the
// second clamp does not fire — only one axis clamps. (This case originally
// expected {2132,8}; that expectation was wrong, not the code.)
check("clamps to the right margin and flips above near the bottom",
  Layout.place({ x: 2560, y: 1080 }, SCREEN, CARD, GAP, EDGE),
  { x: 2132, y: 868 })

report()
```

- [ ] **Step 3: 跑测试确认失败**

Run: `node tests/layout.test.js`
Expected: FAIL —— 测试运行器用 `fs.readFileSync` 读被测文件，所以 `Layout.js` 不存在时失败形态是 `run.js` 抛出的**未捕获 `ENOENT`**（退出码 1，一条断言都没跑），**不是** `Cannot find module`。（已实测确认。）

- [ ] **Step 4: 写实现**

`Layout.js`：

```js
// Where the bubble goes. Pure geometry: no QML, no state, so it can be
// exercised from a plain JS runtime.
//
// Every value here is in logical pixels within one screen's coordinate space.
// Converting the global cursor position into that space is bin/cursor-pos's
// job — this file never sees a global coordinate.

// Places the card near the cursor, kept inside the screen's safe area.
//
//   cursor  {x, y}  cursor position, screen-local logical pixels
//   screen  {w, h}  screen size, logical pixels
//   card    {w, h}  card size, logical pixels
//   gap             distance between the cursor and the card
//   edge            minimum distance between the card and the screen edge
//
// Returns {x, y} for the card's top-left corner.
function place(cursor, screen, card, gap, edge) {
  var x = cursor.x + gap
  var maxX = screen.w - card.w - edge
  if (x > maxX) x = maxX
  if (x < edge) x = edge

  // Below the cursor by default; flip above it when that would overflow. When
  // neither fits (a card taller than the screen) the second clamp wins, which
  // keeps the top edge reachable rather than the bottom.
  var y = cursor.y + gap
  var maxY = screen.h - card.h - edge
  if (y > maxY) y = cursor.y - card.h - gap
  if (y > maxY) y = maxY
  if (y < edge) y = edge

  return { x: x, y: y }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `node tests/layout.test.js`
Expected: `6/6 passed`，退出码 0

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Layout.js tests/
git commit -m "Add bubble placement geometry with tests

Pure function: cursor + screen + card size -> top-left corner, flipping
above the cursor when the card would overflow the bottom and clamping to
the safe area on both axes."
```

---

### Task 3: Translate.js —— prompt、SSE、错误文案（纯函数，TDD）

**Files:**
- Create: `Translate.js`
- Test: `tests/translate.test.js`

**Interfaces:**
- Consumes: 无
- Produces:
  - `defaultSystemPrompt() -> string`
  - `completionsUrl(baseUrl: string) -> string`
  - `buildBody(config, text: string) -> object`
  - `parseHttpMarker(line: string) -> number`（-1 = 不是标记行；0 = 连不上服务器）
  - `parseSseLine(line: string) -> {done: bool, content: string} | null`
  - `errorText(status: number, raw: string) -> string`
  - `httpMarker() -> string`

- [ ] **Step 1: 写失败的测试**

`tests/translate.test.js`：

```js
const { load, check, report } = require("./run")

const T = load("Translate.js")

// ------------------------------------------------------------------ endpoint

check("bare host gets the completions path",
  T.completionsUrl("https://api.deepseek.com/v1"), "https://api.deepseek.com/v1/chat/completions")
check("a trailing slash is tolerated",
  T.completionsUrl("https://api.deepseek.com/v1/"), "https://api.deepseek.com/v1/chat/completions")
check("a full path is left alone",
  T.completionsUrl("https://x.y/v1/chat/completions"), "https://x.y/v1/chat/completions")
check("empty stays empty",
  T.completionsUrl(""), "")

// --------------------------------------------------------------------- body

const body = T.buildBody({ model: "m", temperature: 0.2, maxTokens: 0 }, "hello")
check("model is passed through", body.model, "m")
check("stream is on", body.stream, true)
check("exactly one system and one user turn", body.messages.length, 2)
check("system turn comes first", body.messages[0].role, "system")
check("user turn carries the text verbatim", body.messages[1].content, "hello")
check("temperature is sent", body.temperature, 0.2)
// 0 means "do not send the field": some servers reject it, and the provider
// default is a better ceiling than an arbitrary one.
check("max_tokens is omitted when 0", "max_tokens" in body, false)
check("max_tokens is sent when set",
  "max_tokens" in T.buildBody({ model: "m", maxTokens: 512 }, "x"), true)
check("a configured prompt replaces the default",
  T.buildBody({ model: "m", systemPrompt: "custom" }, "x").messages[0].content, "custom")
check("a blank configured prompt falls back to the default",
  T.buildBody({ model: "m", systemPrompt: "   " }, "x").messages[0].content, T.defaultSystemPrompt())
check("empty text still produces a user turn",
  T.buildBody({ model: "m" }, "").messages[1].content, "")

const prompt = T.defaultSystemPrompt()
check("the default prompt forbids commentary", /only the translation/i.test(prompt), true)
check("the default prompt states both directions", /Chinese/.test(prompt) && /English/.test(prompt), true)

// ------------------------------------------------------------------- markers

check("a marker line parses", T.parseHttpMarker("@@HTTP:200"), 200)
check("a marker line tolerates whitespace", T.parseHttpMarker("  @@HTTP:404  "), 404)
check("a non-marker is -1", T.parseHttpMarker("data: {}"), -1)
check("an unparseable code is -1", T.parseHttpMarker("@@HTTP:abc"), -1)

// ---------------------------------------------------------------------- sse

check("a plain line is ignored", T.parseSseLine(": keep-alive"), null)
check("the done sentinel is recognised", T.parseSseLine("data: [DONE]"), { done: true, content: "" })
check("content is extracted",
  T.parseSseLine('data: {"choices":[{"delta":{"content":"你好"}}]}'), { done: false, content: "你好" })
check("a leading newline survives the splitter",
  T.parseSseLine('\ndata: {"choices":[{"delta":{"content":"a"}}]}'), { done: false, content: "a" })
// A reasoning-only chunk must come back as an empty delta, not null: it
// proves the stream is alive and the caller must not read it as a stall.
check("a reasoning-only chunk yields empty content",
  T.parseSseLine('data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}'), { done: false, content: "" })
check("a malformed payload is ignored", T.parseSseLine("data: {oops"), null)
check("an empty payload is ignored", T.parseSseLine("data:"), null)
check("a choiceless chunk is ignored", T.parseSseLine('data: {"id":"x"}'), null)

// -------------------------------------------------------------------- errors

check("a 401 names the api key", /API key/.test(T.errorText(401, "")), true)
check("a 404 points at the base url", /\/v1/.test(T.errorText(404, "")), true)
check("status 0 means unreachable", /Cannot reach/.test(T.errorText(0, "")), true)
check("a 500 carries the server detail",
  T.errorText(500, '{"error":{"message":"boom"}}'), "Server error (500). boom")
check("a plain body is used as the detail", T.errorText(400, "bad request"), "HTTP 400: bad request")
check("a long detail is truncated to 300 chars",
  T.errorText(400, "x".repeat(500)).length, "HTTP 400: ".length + 300 + 1)

report()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node tests/translate.test.js`
Expected: FAIL —— 未捕获的 `ENOENT`（`tests/run.js` 用 `fs.readFileSync` 读被测文件，见 Task 2 同名步骤的说明），退出码 1，一条断言都没跑。**不是** `Cannot find module`。

- [ ] **Step 3: 写实现**

`Translate.js`：

```js
// Pure helpers for the translate plugin: the prompt, the request body, SSE
// parsing, and error copy. No QML objects, no state. Imported with
// `import "Translate.js" as Translate`.

var SSE_PREFIX = "data:"
var HTTP_MARKER = "@@HTTP:"

// Translation, not conversation. The two directions are stated as rules
// rather than left to the model's judgement, and the "only the translation"
// line is what keeps a bubble from filling with commentary.
var DEFAULT_SYSTEM_PROMPT = [
  "You are a translation engine. Translate the user's text and output only the translation.",
  "",
  "- If the text is predominantly Chinese, translate it into English.",
  "- Otherwise, translate it into Simplified Chinese.",
  "",
  "Rules:",
  "- Output the translation only. No preamble, no explanation, no quotes, no notes.",
  "- Preserve the original's line breaks, formatting, and inline code.",
  "- Keep proper nouns, code identifiers, and URLs unchanged.",
  "- If the input is a single word, give the most common translation, plus its part of speech if useful."
].join("\n")

function defaultSystemPrompt() {
  return DEFAULT_SYSTEM_PROMPT
}

// The endpoint to POST to. Accepts a bare host, a /v1 root, or the full
// completions path, so whatever a provider documents can be pasted in.
function completionsUrl(baseUrl) {
  var url = String(baseUrl || "").trim().replace(/\/+$/, "")
  if (url === "") return ""
  if (/\/chat\/completions$/.test(url)) return url
  return url + "/chat/completions"
}

// The request body for one translation. The text is the only user turn —
// there is no history, which is what stops a word like "bank" from being
// answered as though it were a follow-up to something.
function buildBody(config, text) {
  var system = String((config && config.systemPrompt) || "").trim()
  if (system === "") system = DEFAULT_SYSTEM_PROMPT

  var body = {
    model: String((config && config.model) || ""),
    messages: [
      { role: "system", content: system },
      { role: "user", content: text === undefined || text === null ? "" : String(text) }
    ],
    stream: true
  }
  if (config && typeof config.temperature === "number" && config.temperature >= 0) {
    body.temperature = config.temperature
  }
  if (config && typeof config.maxTokens === "number" && config.maxTokens > 0) {
    body.max_tokens = config.maxTokens
  }
  return body
}

// The wrapper curl writes last, so it survives even when the body is an error
// document rather than a stream.
function httpMarker() {
  return "\n" + HTTP_MARKER + "%{http_code}\n"
}

// curl's --write-out line, e.g. "@@HTTP:200". -1 for any other line; 0 when
// curl could not reach the server at all.
function parseHttpMarker(line) {
  var s = String(line || "").trim()
  if (s.indexOf(HTTP_MARKER) !== 0) return -1
  var code = parseInt(s.substring(HTTP_MARKER.length), 10)
  return isNaN(code) ? -1 : code
}

// One SSE line -> {done, content}, or null when the line carries nothing.
//
// Reasoning-only chunks come back with empty content rather than null: they
// prove the stream is alive, and the caller must not mistake them for a
// stall. They are not displayed — a bubble has room for the translation, not
// the deliberation.
function parseSseLine(line) {
  // Trimmed before the prefix test: the stream splitter hands back some
  // chunks with a leading newline still attached.
  var s = String(line || "").trim()
  if (s.indexOf(SSE_PREFIX) !== 0) return null
  var payload = s.substring(SSE_PREFIX.length).trim()
  if (payload === "") return null
  if (payload === "[DONE]") return { done: true, content: "" }

  var chunk = null
  try {
    chunk = JSON.parse(payload)
  } catch (e) {
    return null
  }
  if (!chunk || !Array.isArray(chunk.choices) || chunk.choices.length === 0) return null

  var delta = (chunk.choices[0] || {}).delta || {}
  return { done: false, content: typeof delta.content === "string" ? delta.content : "" }
}

// A human sentence for a failed request. `raw` is whatever body arrived.
function errorText(status, raw) {
  var body = String(raw || "").trim()
  var detail = ""
  if (body !== "") {
    try {
      var parsed = JSON.parse(body)
      if (parsed && parsed.error) {
        detail = String(parsed.error.message || parsed.error.type || parsed.error)
      } else if (parsed && parsed.message) {
        detail = String(parsed.message)
      } else {
        detail = body
      }
    } catch (e) {
      detail = body
    }
  }
  if (detail.length > 300) detail = detail.substring(0, 300) + "…"

  if (status === 0) return detail === "" ? "Cannot reach the server." : "Cannot reach the server: " + detail
  if (status === 401 || status === 403) return "Authentication failed (" + status + "). Check the API key."
  if (status === 404) return "Not found (404). The base URL usually ends in /v1."
  if (status === 429) return "Rate limited (429)." + (detail === "" ? "" : " " + detail)
  if (status >= 500) return "Server error (" + status + ")." + (detail === "" ? "" : " " + detail)
  if (status === -1) return detail === "" ? "The request ended unexpectedly." : detail
  return "HTTP " + status + (detail === "" ? "" : ": " + detail)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node tests/translate.test.js`
Expected: `35/35 passed`，退出码 0

- [ ] **Step 5: 确认两个测试文件都能一起跑**

Run: `node tests/layout.test.js && node tests/translate.test.js`
Expected: 两个都通过。这是 Task 10 里 `tools/test.sh` 会串起来的东西。

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Translate.js tests/translate.test.js
git commit -m "Add translation helpers with tests

Prompt construction, request body, SSE parsing and error copy as pure
functions. Reasoning-only chunks return an empty delta rather than null
so a thinking model does not read as a stalled stream."
```

---

### Task 4: bin/cursor-pos

把 hyprctl 的两次调用和坐标换算收进一个脚本，QML 侧只解析一行。

**Files:**
- Create: `bin/cursor-pos`
- Test: `tests/scripts.test.sh`

**Interfaces:**
- Consumes: 无
- Produces: 脚本输出**一行**、空格分隔的 `<屏幕名> <局部x> <局部y> <屏宽> <屏高>`；失败时退出码非 0 且输出为空

- [ ] **Step 1: 写测试**

`tests/scripts.test.sh`（Task 5 会往里加 `pick-text` 的用例）：

```bash
#!/usr/bin/env bash
# Command-line checks for the bin/ scripts. These run outside the shell, which
# is the whole reason the timing-sensitive work lives in scripts rather than
# in QML.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0
failures=0

check() { # check <description> <actual> <expected>
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected $3"
    echo "       actual   $2"
  fi
}

check_match() { # check_match <description> <actual> <extended-regex>
  checks=$((checks + 1))
  if printf '%s' "$2" | grep -qE "$3"; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected to match $3"
    echo "       actual   $2"
  fi
}

# ---------------------------------------------------------------- cursor-pos

out="$("$ROOT/bin/cursor-pos")"
check "cursor-pos exits 0" "$?" "0"
# Counted from a fresh run, not from $out: command substitution strips the
# trailing newline, so `printf '%s' "$out" | wc -l` is 0 no matter what.
check "cursor-pos emits exactly one line" "$("$ROOT/bin/cursor-pos" | wc -l)" "1"
check "cursor-pos emits five fields" "$(printf '%s' "$out" | awk '{print NF}')" "5"

# The screen it reports must be a screen hyprctl knows, and the local
# coordinates must land inside it. Compared against hyprctl directly rather
# than a hard-coded value so the test survives a resolution change.
mon="$(hyprctl -j monitors | jq -c --arg n "$(printf '%s' "$out" | awk '{print $1}')" '.[] | select(.name==$n)')"
check_match "cursor-pos names a real monitor" "$mon" '^\{'
check "reported width matches hyprctl" "$(printf '%s' "$out" | awk '{print $4}')" "$(printf '%s' "$mon" | jq -r '.width')"
check "reported height matches hyprctl" "$(printf '%s' "$out" | awk '{print $5}')" "$(printf '%s' "$mon" | jq -r '.height')"

lx="$(printf '%s' "$out" | awk '{print $2}')"
ly="$(printf '%s' "$out" | awk '{print $3}')"
check_match "local x is inside the screen" "$(awk -v a="$lx" -v w="$(printf '%s' "$out" | awk '{print $4}')" 'BEGIN{print (a>=0 && a<=w) ? "yes" : "no"}')" '^yes$'
check_match "local y is inside the screen" "$(awk -v a="$ly" -v h="$(printf '%s' "$out" | awk '{print $5}')" 'BEGIN{print (a>=0 && a<=h) ? "yes" : "no"}')" '^yes$'

# The invariant that matters: local + monitor origin must reproduce hyprctl's
# global cursor position (scale is 1 on this machine).
global="$(hyprctl cursorpos | tr -d ' ')"
gx="${global%,*}"
gy="${global#*,}"
ox="$(printf '%s' "$mon" | jq -r '.x')"
oy="$(printf '%s' "$mon" | jq -r '.y')"
scale="$(printf '%s' "$mon" | jq -r '.scale')"
check "local x reconstructs the global position" \
  "$(awk -v l="$lx" -v s="$scale" -v o="$ox" 'BEGIN{printf "%d", l*s + o}')" "$gx"
check "local y reconstructs the global position" \
  "$(awk -v l="$ly" -v s="$scale" -v o="$oy" 'BEGIN{printf "%d", l*s + o}')" "$gy"

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
```

- [ ] **Step 2: 跑测试确认失败**

Run: `chmod +x tests/scripts.test.sh && ./tests/scripts.test.sh`
Expected: FAIL —— `.../bin/cursor-pos: No such file or directory`

- [ ] **Step 3: 写实现**

`bin/cursor-pos`：

```bash
#!/usr/bin/env bash
# Reports where the cursor is, in the coordinate space a layer-shell surface
# on that screen uses.
#
# Output is one line: <screen-name> <local-x> <local-y> <screen-w> <screen-h>
# Nothing on stdout and a non-zero exit means the position could not be read.
#
# Why a script: hyprctl reports the cursor in *global* layout coordinates, but
# a layer surface is positioned in its own screen's *logical* local
# coordinates. The conversion needs the monitor list and the scale factor, and
# doing it here keeps that arithmetic out of QML and testable from a terminal.
set -uo pipefail

cursor="$(hyprctl cursorpos 2>/dev/null)" || exit 1
# "1551, 1003"
gx="${cursor%%,*}"
gy="${cursor##*,}"
gx="${gx//[!0-9-]/}"
gy="${gy//[!0-9-]/}"
[ -n "$gx" ] && [ -n "$gy" ] || exit 1

monitors="$(hyprctl -j monitors 2>/dev/null)" || exit 1
[ -n "$monitors" ] || exit 1

# The monitor whose rectangle contains the cursor. Hyprland reports a monitor
# covering the cursor even when the cursor sits on a gap between screens, so a
# plain containment test is enough. No match at all is a failure, not an empty
# success — the caller cannot act on a blank line.
line="$(printf '%s' "$monitors" | jq -r --argjson x "$gx" --argjson y "$gy" '
  [ .[]
    | select($x >= .x and $x < (.x + .width) and $y >= .y and $y < (.y + .height))
  ]
  | .[0]
  | if . == null then empty
    else
      # scale converts global device pixels into the surface logical pixels;
      # transform 1/3/5/7 swap the axes, so the local extent has to follow the
      # rotation rather than the raw width/height.
      (if (.transform == 1 or .transform == 3 or .transform == 5 or .transform == 7)
         then (.height / .scale) else (.width / .scale) end) as $w
      | (if (.transform == 1 or .transform == 3 or .transform == 5 or .transform == 7)
         then (.width / .scale) else (.height / .scale) end) as $h
      | [ .name,
          ((($x - .x) / .scale) | floor),
          ((($y - .y) / .scale) | floor),
          ($w | floor),
          ($h | floor) ]
      | @tsv
    end
')" || exit 1
[ -n "$line" ] || exit 1

printf '%s\n' "$line" | tr '\t' ' '
```

- [ ] **Step 4: 跑测试确认通过**

Run: `chmod +x bin/cursor-pos && ./tests/scripts.test.sh`
Expected: 全部 `ok`，`10/10 passed`

- [ ] **Step 5: 和 hyprctl 肉眼对一次**

Run: `hyprctl cursorpos && ./bin/cursor-pos`
Expected: 例如光标在 `1551, 1003`，脚本输出 `DP-1 1551 1003 2560 1080`。数字对得上（本机 scale 1，所以局部坐标等于全局坐标）。

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add bin/cursor-pos tests/scripts.test.sh
git commit -m "Add cursor-pos: global cursor to screen-local layer coordinates

hyprctl reports global layout coordinates; a layer surface is positioned
in its own screen's logical space. The conversion (monitor lookup, scale
division, transform-aware extents) lives in the script so it stays
testable outside the shell."
```

---

### Task 5: bin/pick-text

**Files:**
- Create: `bin/pick-text`
- Modify: `tests/scripts.test.sh`（追加用例）

**Interfaces:**
- Consumes: 无
- Produces: stdout = 取到的文本；取不到则 stdout 为空且退出码非 0。**无论成功失败，剪贴板必须还原。**

- [ ] **Step 1: 追加测试**

在 `tests/scripts.test.sh` 的 `echo` / 汇总行**之前**插入：

```bash
# ----------------------------------------------------------------- pick-text

# pick-text synthesises a real Ctrl+C, and the focused surface while a test
# runs is the terminal that started it. The terminal turns that into SIGINT
# for its foreground process group — this script. Ignoring SIGINT here is what
# keeps the fallback test from killing its own runner. The disposition is
# inherited across exec, so the children ignore it too.
trap '' INT

# Path 1: a populated primary selection is used as-is, with no clipboard
# side effects at all.
printf 'primary-selection-probe' | wl-copy --primary
before="$(wl-paste --no-newline)"
check "pick-text prefers the primary selection" "$("$ROOT/bin/pick-text")" "primary-selection-probe"
check "the primary path leaves the clipboard untouched" "$(wl-paste --no-newline)" "$before"
wl-copy --clear --primary

# Path 2: an empty primary selection falls back to the clipboard, and the
# clipboard is restored afterwards. Verified against a distinctive sentinel so
# a partially-restored clipboard cannot pass.
printf 'clipboard-sentinel-do-not-lose' | wl-copy
wl-copy --clear --primary
out2="$("$ROOT/bin/pick-text" 2>/dev/null)"
check "the fallback path leaves the clipboard restored" "$(wl-paste --no-newline)" "clipboard-sentinel-do-not-lose"
# Nothing was selected and nothing received the synthetic Ctrl+C, so the
# script must report failure rather than return the clipboard's own contents.
check "the fallback reports failure when nothing is selected" "$?" "1"
check "no text is emitted on failure" "$out2" ""
```

- [ ] **Step 2: 跑测试确认失败**

Run: `./tests/scripts.test.sh`
Expected: FAIL —— `bin/pick-text: No such file or directory`；且必须确认 `the fallback path leaves the clipboard restored` 这一条在实现前是**失败**的。

- [ ] **Step 3: 写实现**

`bin/pick-text`：

```bash
#!/usr/bin/env bash
# Prints the current selection, or nothing (with a non-zero exit) when there
# is none.
#
# The primary selection is tried first: it is what a mouse drag fills in, and
# reading it touches nothing. Only when it is empty does this fall back to
# synthesising Ctrl+C and reading the clipboard — which clobbers the user's
# clipboard, so the original is captured and put back.
#
# Why a script: the fallback is a timed sequence — press, poll, restore — with
# a failure path at every step. In QML that becomes a web of Processes and
# timers; here it is one file that can be run and asserted from a terminal.
set -uo pipefail

# How long to wait for the synthetic Ctrl+C to land. Long enough for a slow
# app to service the key, short enough that a keypress that goes nowhere does
# not feel like a hang.
POLL_INTERVAL_MS=25
POLL_ATTEMPTS=16

# ------------------------------------------------------- path 1: primary

primary="$(wl-paste --primary --no-newline 2>/dev/null)" && [ -n "$primary" ] && {
  printf '%s' "$primary"
  exit 0
}

# --------------------------------------------------- path 2: the fallback

backup="$(mktemp -d)" || exit 1
restored=0

restore() {
  [ "$restored" -eq 1 ] && return
  restored=1
  # Types are replayed in the order they were captured. A type whose data
  # could not be read is skipped rather than copied empty, so one unreadable
  # flavour cannot blank the whole clipboard.
  while IFS= read -r type; do
    [ -n "$type" ] || continue
    [ -s "$backup/data" ] || continue
    if [ -f "$backup/by-type/$type" ]; then
      wl-copy --type "$type" < "$backup/by-type/$type" 2>/dev/null || true
    fi
  done < "$backup/types"
  rm -rf "$backup"
}

cleanup() {
  local code=$?
  restore
  exit "$code"
}
trap cleanup EXIT

mkdir -p "$backup/by-type"
wl-paste --list-types 2>/dev/null > "$backup/types" || true

# The full payload is captured first so the "did it change" comparison below
# has something to compare against even for non-text flavours.
wl-paste --no-newline 2>/dev/null > "$backup/data" || true

while IFS= read -r type; do
  [ -n "$type" ] || continue
  safe="${type//\//_}"
  wl-paste --type "$type" 2>/dev/null > "$backup/by-type/$safe" || rm -f "$backup/by-type/$safe"
done < "$backup/types"

# Remember which flavour was the text one, if any, so the comparison uses the
# same representation the app will actually offer.
before="$(cat "$backup/data" 2>/dev/null || true)"

wtype -M ctrl -k c -m ctrl 2>/dev/null || exit 1

# Poll rather than sleep a fixed interval: a fast app answers on the first
# tick, and a slow one gets the full budget.
after=""
for _ in $(seq "$POLL_ATTEMPTS"); do
  sleep "$(awk -v ms="$POLL_INTERVAL_MS" 'BEGIN{printf "%.3f", ms/1000}')"
  after="$(wl-paste --no-newline 2>/dev/null || true)"
  [ "$after" != "$before" ] && break
done

[ "$after" != "$before" ] || exit 1
[ -n "$after" ] || exit 1

printf '%s' "$after"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `chmod +x bin/pick-text && ./tests/scripts.test.sh`
Expected: 全部 `ok`，`15/15 passed`

- [ ] **Step 5: 在真实应用里手动验一次**

取词的兜底路径自动化测不到（没有应用会响应脚本发出的 Ctrl+C）。手动验：

1. 打开一个终端，`printf 'hello world' | wl-copy` 记下当前剪贴板
2. 在任意应用里用鼠标选中一段文字（这会填主选择区）→ `./bin/pick-text` 应立即输出选中内容
3. 在**不写主选择区**的应用里（试试 Electron 应用，如 VS Code）选中文字，**保持选中状态**，在另一个终端跑 `./bin/pick-text`
4. 确认：输出了选中内容，且 `wl-paste` 仍是第 1 步的内容

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add bin/pick-text tests/scripts.test.sh
git commit -m "Add pick-text: primary selection with a Ctrl+C fallback

Reads the primary selection first, which is what a mouse drag fills and
what costs nothing to read. Only when it is empty does it synthesise
Ctrl+C, poll for the clipboard to change, and restore the original
clipboard by flavour."
```

---

### Task 6: Config.qml

**Files:**
- Create: `Config.qml`

**Interfaces:**
- Consumes: `Translate.js`（不需要 —— 配置里只存值）
- Produces:
  - `readonly property string dir` —— 状态目录绝对路径
  - `readonly property string configPath`
  - `property var config` —— 解析后的配置对象
  - `property bool ready` —— 目录已建好且配置已加载；**为 false 时不得发起请求**
  - `function save(): void`

- [ ] **Step 1: 写实现**

配置的读写没有独立可断言的单元（它依赖 QML 的 `FileView`），所以这个任务靠 Step 2 的端到端检查验证，不硬凑一个假测试。

```qml
import QtQuick
import Quickshell
import Quickshell.Io

// Owns the one file the plugin persists. State lives under XDG_STATE_HOME
// alongside omarchy's own plugins, not in the config tree: shell.json is
// rewritten by the shell on every layout change, and an API key must not be
// in a file that gets rewritten.
QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")
  readonly property string off("XDG_STATE_HOME")
  readonly property string dir: root.stateHome + "/omarchy/translate"
  readonly property string configPath: root.dir + "/config.json"
  // Read once, on first run, to seed the config. Never written back to.
  readonly property string chatConfigPath: root.stateHome + "/omarchy/chat/config.json"

  // Nothing may be written before the directory exists: a FileView write into
  // a missing directory fails with FileNotFound, and with printErrors off that
  // failure is completely silent.
  property bool dirsReady: false
  // A request must not be attempted before the config is known.
  property bool configLoaded: false
  readonly property bool ready: root.dirsReady && root.configLoaded

  property var config: root.defaultConfig()
  property string lastError: ""

  function defaultConfig() {
    return {
      baseUrl: "https://api.deepseek.com/v1",
      model: "deepseek-flash",
      apiKey: "",
      systemPrompt: "",
      temperature: 0.2,
      maxTokens: 0,
      timeoutSec: 60
    }
  }

  // Anything the file does not define falls back to the default, so a config
  // written by an older version keeps working.
  function normalize(raw) {
    var base = root.defaultConfig()
    if (!raw || typeof raw !== "object") return base
    var out = {}
    for (var key in base) {
      out[key] = (raw[key] === undefined || raw[key] === null) ? base[key] : raw[key]
    }
    return out
  }

  // First run: copy the chat plugin's credentials so the API key does not have
  // to be typed twice. A copy, not a reference — afterwards the two configs
  // are independent.
  function seedFromChat() {
    var text = root.chatFile.text()
    if (!text) return root.defaultConfig()
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      return root.defaultConfig()
    }
    var base = root.defaultConfig()
    if (parsed && typeof parsed.baseUrl === "string" && parsed.baseUrl !== "") base.baseUrl = parsed.baseUrl
    if (parsed && typeof parsed.model === "string" && parsed.model !== "") base.model = parsed.model
    if (parsed && typeof parsed.apiKey === "string" && parsed.apiKey !== "") base.apiKey = parsed.apiKey
    return base
  }

  function save() {
    if (!root.dirsReady) {
      root.lastError = "State directory is not ready."
      return
    }
    root.file.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  // Writes must be complete before the caller proceeds, and setText() is
  // asynchronous otherwise. blockWrites makes it return once the write has
  // landed or failed.
  property FileView file: FileView {
    path: root.dirsReady ? root.configPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.lastError = "Cannot write " + root.configPath
    onLoaded: {
      var parsed = null
      try {
        parsed = JSON.parse(root.file.text())
      } catch (e) {
        parsed = null
      }
      root.config = root.normalize(parsed)
      root.configLoaded = true
    }
    onLoadFailed: {
      // No file yet is the first run, not an error: seed from chat and write
      // it out so the next run takes the normal path.
      root.config = root.seedFromChat()
      root.configLoaded = true
      root.save()
    }
  }

  // Read-only access to the chat config for seeding. A failed read is normal
  // (the user may not have the chat plugin), so it is not surfaced.
  property FileView chatFile: FileView {
    path: root.chatConfigPath
    printErrors: false
  }

  // umask 077 rather than `mkdir -m 700`: the mode flag covers only the
  // directory, while the umask covers everything created inside it too. This
  // is the same invocation billy.chat uses.
  //
  // The config file itself comes out 0600 because atomicWrites writes to a
  // temporary file and renames it, and Qt creates temporary files with that
  // mode. Step 4 asserts the result rather than assuming it.
  property Process mkdir: Process {
    command: ["bash", "-c", "umask 077; mkdir -p \"$1\"; chmod 700 \"$1\"", "--", root.dir]
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.dirsReady = true
      } else {
        root.lastError = "Cannot create " + root.dir
      }
    }
  }

  Component.onCompleted: root.mkdir.running = true
}
```

- [ ] **Step 2: 跑语法门禁**

Run: `./tools/check-syntax.sh`
Expected: `qml syntax ok`

- [ ] **Step 3: 端到端验证首次导入**

先删掉状态目录模拟首次运行，重启 shell，然后在 shell 日志里确认没有错误：

```bash
rm -rf ~/.local/state/omarchy/translate
omarchy restart shell
sleep 3
ls -l ~/.local/state/omarchy/translate/
```

Expected: `config.json` 存在，权限 `-rw-------`（0600）。目录权限 `drwx------`（0700）。

- [ ] **Step 4: 验证导入的内容**

Run: `jq '{baseUrl, model, apiKey: (.apiKey | length)}' ~/.local/state/omarchy/translate/config.json`
Expected: `baseUrl` 与 `model` 与 `~/.local/state/omarchy/chat/config.json` 一致；`apiKey` 是**长度**而非明文。若 chat 配置不存在，则应看到默认值。

- [ ] **Step 5: 验证二次运行不覆盖**

```bash
jq '.model = "sentinel-model"' ~/.local/state/omarchy/translate/config.json > /tmp/c.json
mv /tmp/c.json ~/.local/state/omarchy/translate/config.json
omarchy restart shell && sleep 3
jq -r '.model' ~/.local/state/omarchy/translate/config.json
```
Expected: `sentinel-model` —— 已有的配置不被首次导入逻辑覆盖。

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Config.qml
git commit -m "Add config: state file, first-run import from the chat plugin

Seeds baseUrl/model/apiKey from billy.chat once, then owns its copy.
Directory creation gates the first write, since a FileView write into a
missing directory fails silently."
```

---

### Task 7: Probe.qml

**Files:**
- Create: `Probe.qml`

**Interfaces:**
- Consumes: `bin/cursor-pos`、`bin/pick-text`（Task 4、5）
- Produces:
  - `signal cursorReady(var pos)` —— `pos` 是 `{screen: string, x: real, y: real, w: real, h: real}`
  - `signal cursorFailed(string message)`
  - `signal textReady(string text)`
  - `signal textFailed(string message)`
  - `function queryCursor(): void`
  - `function pickText(): void`
  - `property string pluginDir` —— 由 Overlay.qml 注入脚本所在目录

- [ ] **Step 1: 写实现**

```qml
import QtQuick
import Quickshell
import Quickshell.Io

// The only place the plugin reads state from outside itself: where the cursor
// is, and what is selected. Both answers come from scripts under bin/, which
// keeps the timing-sensitive work testable from a terminal.
QtObject {
  id: root

  // Injected by Overlay.qml from the manifest.
  property string pluginDir: ""

  signal cursorReady(var pos)
  signal cursorFailed(string message)
  signal textReady(string text)
  signal textFailed(string message)

  readonly property string cursorScript: root.pluginDir + "/bin/cursor-pos"
  readonly property string pickScript: root.pluginDir + "/bin/pick-text"

  function queryCursor() {
    if (root.pluginDir === "") {
      root.cursorFailed("Plugin directory is unknown.")
      return
    }
    root.cursorProcess.running = true
  }

  function pickText() {
    if (root.pluginDir === "") {
      root.textFailed("Plugin directory is unknown.")
      return
    }
    root.pickProcess.running = true
  }

  // "<screen> <x> <y> <w> <h>", on one line.
  function parseCursor(raw) {
    var line = String(raw || "").trim()
    if (line === "") return null
    var parts = line.split(/\s+/)
    if (parts.length !== 5) return null
    var values = []
    for (var i = 1; i < 5; i++) {
      var n = Number(parts[i])
      if (!isFinite(n)) return null
      values.push(n)
    }
    if (parts[0] === "") return null
    return { screen: parts[0], x: values[0], y: values[1], w: values[2], h: values[3] }
  }

  property Process cursorProcess: Process {
    command: [root.cursorScript]
    stdout: StdioCollector {
      id: cursorOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.cursorFailed("Could not read the cursor position.")
        return
      }
      var pos = root.parseCursor(cursorOut.text)
      if (!pos) {
        root.cursorFailed("Could not read the cursor position.")
        return
      }
      root.cursorReady(pos)
    }
  }

  // The text arrives on stdout; a non-zero exit means there was no selection,
  // which is a normal outcome rather than a failure worth logging.
  property Process pickProcess: Process {
    command: [root.pickScript]
    stdout: StdioCollector {
      id: pickOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var text = String(pickOut.text || "")
      if (exitCode !== 0 || text.trim() === "") {
        root.textFailed("No text selected.")
        return
      }
      root.textReady(text)
    }
  }
}
```

- [ ] **Step 2: 跑语法门禁**

Run: `./tools/check-syntax.sh`
Expected: `qml syntax ok`

- [ ] **Step 3: 单独验证两个进程能被驱动**

临时把下面这段贴进 `Overlay.qml` 的 `open()` 里，重启 shell，按快捷键：

```qml
probe.queryCursor()
probe.pickText()
```

并在 `Probe.qml` 里临时加：

```qml
Component.onCompleted: {
  root.cursorReady.connect(function (p) { console.log("CURSOR", JSON.stringify(p)) })
  root.cursorFailed.connect(function (m) { console.log("CURSOR-FAIL", m) })
  root.textReady.connect(function (t) { console.log("TEXT", JSON.stringify(t)) })
  root.textFailed.connect(function (m) { console.log("TEXT-FAIL", m) })
}
```

Run:
```bash
omarchy restart shell && sleep 3
# 在任意应用里选中一段文字，保持选中
omarchy-shell shell toggle billy.translate '{}'
journalctl --user --since "1 min ago" | grep -E 'CURSOR|TEXT'
```
Expected: 一行 `CURSOR {"screen":"DP-1","x":...,"y":...,"w":2560,"h":1080}` 和一行 `TEXT "..."`。**验证完把临时代码删掉。**

- [ ] **Step 4: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Probe.qml
git commit -m "Add probe: read cursor position and selection via bin/ scripts"
```

---

### Task 8: Transport.qml

从 `billy.chat/Transport.qml` 移植，去掉会话概念 —— 一次翻译就是一个请求，没有历史。

**Files:**
- Create: `Transport.qml`

**Interfaces:**
- Consumes: `Translate.js`、`Config.qml`
- Produces:
  - `property var config`
  - `property string text`
  - `property string state` —— `idle` | `streaming`
  - `property string output` —— 累积的译文
  - `property string errorText`
  - `signal finished(string outcome)` —— `done` | `error` | `canceled`
  - `function start(): void`
  - `function cancel(): void`

- [ ] **Step 1: 写实现**

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import "Translate.js" as Translate

// The one place a request is made. Writes the body and the curl config, runs
// curl, and turns its stdout back into translation deltas.
//
// The API key never appears in argv (world-readable /proc/<pid>/cmdline) or in
// the environment: curl reads url, headers and the body path from a 0600
// config file inside the 0700 state directory.
QtObject {
  id: root

  property var config: null
  property string text: ""

  property string state: "idle" // idle | streaming
  property string output: ""
  property string errorText: ""
  property int httpStatus: -1

  readonly property bool streaming: root.state === "streaming"

  signal finished(string outcome)

  property bool sawDone: false
  property bool writeFailed: false
  property string rawTail: ""
  property string stderrTail: ""
  property string stopReason: "" // "" | "user" | "timeout"

  readonly property string dir: (Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy/translate"
  readonly property string bodyPath: root.dir + "/body.json"
  readonly property string curlConfPath: root.dir + "/curl.conf"

  readonly property int timeoutSec: {
    var configured = root.config ? Number(root.config.timeoutSec) : NaN
    return isFinite(configured) && configured > 0 ? configured : 60
  }

  // ------------------------------------------------------------------ config

  // curl config-file values live inside double quotes, where curl itself
  // understands \\ and \". Newlines would end the line, so they are folded.
  function quote(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, "\\\"")
      .replace(/[\r\n]+/g, " ")
  }

  function curlConfigText() {
    var lines = []
    lines.push("url = \"" + root.quote(Translate.completionsUrl(root.config.baseUrl)) + "\"")
    lines.push("request = \"POST\"")
    lines.push("header = \"Content-Type: application/json\"")
    var key = String(root.config.apiKey || "").trim()
    if (key !== "") lines.push("header = \"Authorization: Bearer " + root.quote(key) + "\"")
    lines.push("data-binary = \"@" + root.quote(root.bodyPath) + "\"")
    lines.push("connect-timeout = \"10\"")
    lines.push("max-time = \"" + (root.timeoutSec + 10) + "\"")
    lines.push("silent")
    lines.push("show-error")
    lines.push("no-buffer")
    // The status marker is the last line curl writes, so it survives even when
    // the body is an error document rather than a stream.
    lines.push("write-out = \"" + root.quote(Translate.httpMarker()) + "\"")
    return lines.join("\n") + "\n"
  }

  // ------------------------------------------------------------------ sending

  function start() {
    if (root.streaming) return
    if (!root.config) {
      root.fail("Translation is not configured.")
      return
    }
    if (Translate.completionsUrl(root.config.baseUrl) === "") {
      root.fail("Translation is not configured.")
      return
    }
    if (String(root.config.model || "").trim() === "") {
      root.fail("Translation is not configured.")
      return
    }
    if (String(root.text || "").trim() === "") {
      root.fail("No text selected.")
      return
    }

    root.output = ""
    root.errorText = ""
    root.httpStatus = -1
    root.sawDone = false
    root.writeFailed = false
    root.rawTail = ""
    root.stderrTail = ""
    root.stopReason = ""

    // Both FileViews set blockWrites, so setText() has completed by the time
    // it returns. An async save would let the process start before the files
    // it reads exist.
    try {
      root.confFile.setText(root.curlConfigText())
      root.bodyFile.setText(JSON.stringify(Translate.buildBody(root.config, root.text)) + "\n")
    } catch (e) {
      root.fail("Could not prepare the request: " + e)
      return
    }
    if (root.writeFailed) {
      root.fail("Could not write the request to disk.")
      return
    }

    root.state = "streaming"
    root.process.command = ["setpriv", "--pdeathsig", "TERM", "curl", "-K", root.curlConfPath]
    root.process.running = true
  }

  function cancel() {
    if (!root.streaming) return
    root.stopReason = "user"
    // A dismissal's SIGTERM is still in flight; Process.running stays true
    // until the child exits, so handleExit() does the rest.
    root.process.running = false
  }

  function fail(message) {
    root.errorText = String(message || "The request failed.")
    root.state = "idle"
    root.finished("error")
  }

  // -------------------------------------------------------------------- input

  function handleLine(line) {
    var status = Translate.parseHttpMarker(line)
    if (status >= 0) {
      root.httpStatus = status
      return
    }
    var event = Translate.parseSseLine(line)
    if (!event) {
      root.noteRaw(line)
      return
    }
    if (event.done) {
      root.sawDone = true
      return
    }
    if (event.content !== "") root.output = root.output + event.content
  }

  // Non-SSE lines are either keep-alives or the provider's error document.
  // Keep a bounded tail so a failed request can explain itself.
  function noteRaw(line) {
    var text = String(line || "").trim()
    if (text === "") return
    root.rawTail = root.rawTail === "" ? text : root.rawTail + "\n" + text
    if (root.rawTail.length > 2000) root.rawTail = root.rawTail.substring(root.rawTail.length - 2000)
  }

  function handleExit(exitCode) {
    var wasStreaming = root.streaming
    var reason = root.stopReason
    root.state = "idle"
    root.stopReason = ""
    if (!wasStreaming) return

    var outcome = "done"
    if (reason === "timeout") {
      outcome = "error"
      root.errorText = "Timed out after " + root.timeoutSec + "s."
    } else if (reason === "user") {
      // A canceled request keeps whatever arrived: the user has already read
      // part of the translation and it is still the answer to what they asked.
      outcome = root.output !== "" ? "done" : "canceled"
    } else if (!root.sawDone) {
      // No [DONE] means the stream never completed. A partial translation is
      // kept and the reason is reported alongside it rather than replacing it.
      var detail = Translate.errorText(root.httpStatus, root.rawTail !== "" ? root.rawTail : root.stderrTail)
      if (root.output !== "") root.errorText = detail
      else {
        outcome = "error"
        root.errorText = detail
      }
    }
    root.finished(outcome)
  }

  // ------------------------------------------------------------------- wiring

  property FileView confFile: FileView {
    path: root.dirsReadyForFiles ? root.curlConfPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.writeFailed = true
  }

  property FileView bodyFile: FileView {
    path: root.dirsReadyForFiles ? root.bodyPath : ""
    printErrors: false
    atomicWrites: true
    blockWrites: true
    onSaveFailed: root.writeFailed = true
  }

  // The state directory is created by Config.qml. Writing before it exists
  // fails with FileNotFound and, with printErrors off, that failure is silent.
  readonly property bool dirsReadyForFiles: root.dir !== "" && root.config !== null

  property Process process: Process {
    onExited: function (exitCode) { root.handleExit(exitCode) }
    stdout: SplitParser {
      onRead: function (line) { root.handleLine(String(line)) }
    }
    stderr: StdioCollector {
      id: stderrCollector
      waitForEnd: true
      onStreamFinished: {
        var text = String(stderrCollector.text || "").trim()
        if (text !== "") root.stderrTail = text
      }
    }
  }

  property Timer timeoutTimer: Timer {
    interval: root.timeoutSec * 1000
    running: root.state === "streaming"
    onTriggered: {
      root.stopReason = "timeout"
      root.process.running = false
    }
  }
}
```

- [ ] **Step 2: 跑语法门禁**

Run: `./tools/check-syntax.sh`
Expected: `qml syntax ok`

- [ ] **Step 3: 用真实后端验一次**

临时在 `Overlay.qml` 的 `open()` 里接上（`probe.textReady` → `transport.start()`），重启 shell，选中一段英文按快捷键：

```bash
omarchy restart shell && sleep 3
# 选中 "The quick brown fox jumps over the lazy dog"，按 SUPER+CTRL+T
journalctl --user --since "1 min ago" | grep -iE 'translate|error' | tail -20
```

Expected: 无 `Authentication failed` / `Cannot reach` / `Not found (404)`。若报 401，编辑 `~/.local/state/omarchy/translate/config.json` 填 `apiKey`。

- [ ] **Step 4: 验证 API key 没进 argv**

选中文字触发一次请求，在 curl 还活着的时候：

```bash
pgrep -a curl
```

Expected: 命令行里只有 `curl -K /home/billy/.local/state/omarchy/translate/curl.conf`，**没有 Bearer token，也没有请求体**。

- [ ] **Step 5: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Transport.qml
git commit -m "Add transport: streaming translation over curl

Ported from billy.chat's transport, minus the session concept: one
translation is one request with no history. A canceled stream keeps
whatever arrived, since a partial translation is still the answer."
```

---

### Task 9: Bubble.qml 与 Overlay 编排

把前面所有部件接起来，这是唯一一个只能靠手动验证的任务。

**Files:**
- Create: `Bubble.qml`
- Modify: `Overlay.qml`（替换 Task 1 的骨架实现）

**Interfaces:**
- Consumes: `Layout.js`、`Probe.qml`、`Transport.qml`、`Config.qml`、`Translate.js`
- Produces: 完整的 `billy.translate` 插件

- [ ] **Step 1: 写 Bubble.qml**

```qml
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
```

- [ ] **Step 2: 写 Overlay.qml（替换骨架）**

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// The plugin root. The shell's facade calls open(payloadJson)/close() and
// reads `opened` to decide what the toggle verb means, so all three are part
// of the contract rather than conveniences.
PanelWindow {
  id: root

  property var manifest: null

  property string phase: "idle" // idle | picking | translating | done | empty | error
  property bool opened: false
  property var cursorPos: null
  property string selectedText: ""
  property string directionLabel: ""
  property string failureText: ""
  property bool copied: false

  // Only the screen the cursor is on is used, so there is no ambiguity about
  // which monitor a summon affects.
  screen: root.screenFor(root.cursorPos ? root.cursorPos.screen : "")

  // The surface must not exist while picking: opening it grabs the keyboard
  // focus that the fallback Ctrl+C needs to reach the app underneath.
  visible: root.opened && root.phase !== "picking" && root.phase !== "idle"
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "billy-translate"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir ? root.manifest.__sourceDir : ""

  // ------------------------------------------------------------------ layout

  function screenFor(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === String(name)) return screens[i]
    }
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  // Recomputed whenever the cursor, the screen or the card height changes —
  // a streaming translation grows, and a clamp computed once would let the
  // card walk off the bottom of the screen.
  readonly property var placement: {
    // No cursor position means hyprctl failed. Centre on the surface rather
    // than leaving the card pinned in the corner, which reads as a rendering
    // bug rather than an error.
    if (!root.cursorPos) {
      return {
        x: Math.max(0, (root.width - bubble.cardWidth) / 2),
        y: Math.max(0, (root.height - bubble.height) / 2)
      }
    }
    return Layout.place(
      { x: root.cursorPos.x, y: root.cursorPos.y },
      { w: root.cursorPos.w, h: root.cursorPos.h },
      { w: bubble.cardWidth, h: bubble.height },
      Style.space(12),
      Style.space(8)
    )
  }

  // ------------------------------------------------------------------- state

  function open(payloadJson) {
    // Toggling closed is the caller's job; a second open re-runs the pick so
    // that the key always means "translate what is selected".
    root.opened = true
    root.copied = false
    root.failureText = ""
    root.selectedText = ""
    root.directionLabel = ""
    root.phase = "picking"
    transport.cancel()
    probe.queryCursor()
    probe.pickText()
  }

  function close() {
    transport.cancel()
    root.opened = false
    root.phase = "idle"
    root.selectedText = ""
    root.failureText = ""
    root.copied = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function copyTranslation() {
    if (transport.output === "") return
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", "wl-copy", "--", transport.output])
    root.copied = true
    copiedTimer.restart()
  }

  // "EN → 中文" — enough to tell at a glance which way it went, without a
  // language-detection pass of our own.
  function labelFor(text) {
    var chinese = /[一-鿿]/.test(text)
    return chinese ? "中文 → EN" : "→ 中文"
  }

  property Timer copiedTimer: Timer {
    interval: 1500
    onTriggered: root.copied = false
  }

  // ---------------------------------------------------------------- components

  property Config config: Config {}
  property Probe probe: Probe {
    pluginDir: root.pluginDir
    onCursorReady: function (pos) { root.cursorPos = pos }
    onCursorFailed: function (message) {
      root.failureText = message
      root.phase = "empty"
    }
    onTextReady: function (text) {
      root.selectedText = text
      root.directionLabel = root.labelFor(text)
      root.phase = "translating"
      transport.start()
    }
    onTextFailed: function (message) {
      root.failureText = message
      root.phase = "empty"
    }
  }

  property Transport transport: Transport {
    config: root.config.ready ? root.config.config : null
    text: root.selectedText
    // The phase stays "translating" until the stream ends — the bubble shows
    // whatever has arrived, so there is no need to promote a partial answer
    // to "done" and lose the distinction.
    onFinished: function (outcome) {
      if (transport.output === "") {
        root.failureText = outcome === "error" ? transport.errorText : "No translation returned."
        root.phase = "error"
        return
      }
      // A failure after text had already arrived keeps the text and reports
      // the reason underneath it.
      root.failureText = transport.errorText
      root.phase = transport.errorText === "" ? "done" : "error"
    }
  }

  Rectangle { anchors.fill: parent; color: Color.menu.scrim }
  MouseArea { anchors.fill: parent; onClicked: root.close() }

  // Declared in the body rather than as a `property Bubble bubble: ...` so the
  // visual parent is unambiguous and the card is actually in the scene.
  Bubble {
    id: bubble
    placement: root.placement
    phase: root.phase
    sourceText: root.selectedText
    translation: transport.output
    errorText: root.failureText
    directionLabel: root.directionLabel
    copied: root.copied
    onCopyRequested: root.copyTranslation()
    onCloseRequested: root.close()
  }

  IpcHandler {
    target: "billy.translate"
    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function copy(): void { root.copyTranslation() }
    function ping(): string { return "ok" }
  }
}
```

- [ ] **Step 3: 跑语法门禁**

Run: `./tools/check-syntax.sh`
Expected: `qml syntax ok`

- [ ] **Step 4: 重启 shell 并走查**

```bash
omarchy restart shell && sleep 3
journalctl --user --since "1 min ago" | grep "omarchy-shell\[$(pgrep -x omarchy-shell)\]" | grep -i "translate" | tail -20
```
Expected: 无 `failed` / `Expected token` / `is not a type`。

- [ ] **Step 5: 手动走查表**

逐条验证。**每改一次 QML 都要 `omarchy restart shell`** —— 否则会看到缓存的旧错误和错位的行号。

| # | 操作 | 期望 |
|---|---|---|
| 1 | 在 GTK 应用选中英文，按 `SUPER+CTRL+T` | 气泡出现在光标右下，方向标签 `→ 中文`，译文流式增长 |
| 2 | 同上但选中文 | 标签 `中文 → EN`，译文是英文 |
| 3 | 在屏幕最底部划词 | 气泡翻到光标**上方**，不越出底边 |
| 4 | 在屏幕最右侧划词 | 气泡被夹在右边界内 |
| 5 | 长文（几百字） | 气泡长到封顶后不再变高，译文不越出屏幕 |
| 6 | 按 `Esc` | 关闭 |
| 7 | 再按 `SUPER+CTRL+T` | 打开 |
| 8 | 点击气泡外的暗区 | 关闭 |
| 9 | 点复制按钮 | 图标变 `✓`，`wl-paste` 得到译文 |
| 10 | `omarchy-shell billy.translate copy` | 同样复制译文 |
| 11 | 什么都不选，按快捷键 | 气泡显示「没有检测到选中文字」 |
| 12 | 把 `config.json` 的 `apiKey` 改错，再翻译 | 气泡显示 `Authentication failed` |
| 13 | 在 Electron 应用（VS Code）里选词 | 走兜底路径，仍能取到；之后 `wl-paste` 是原内容 |
| 14 | 流式进行中按 `Esc` | 关闭；已收到的部分不崩 |

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add Bubble.qml Overlay.qml
git commit -m "Add bubble and wire the overlay end to end

Bubble placement recomputes on card height, since a streaming translation
grows and a clamp computed once would let it walk off the bottom. The
source text is shown so the fallback path is falsifiable: when the
synthetic Ctrl+C grabs the wrong thing, that is how you see it."
```

---

### Task 10: README、键位与交付走查

**Files:**
- Modify: `README.md`
- Create: `tools/test.sh`
- Modify: `~/.config/hypr/bindings.lua`

**Interfaces:**
- Consumes: 前九个任务的全部产物
- Produces: 可交付的插件

- [ ] **Step 1: 写测试入口**

`tools/test.sh`：

```bash
#!/usr/bin/env bash
# Everything that can be checked without starting the shell.
#
# The QML layer is not covered here: there is no harness for it, and a plugin
# that fails to compile stays broken through hot-reload, so a restart is the
# only honest test. See docs/specs for that reasoning.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
status=0

echo "== qml syntax =="
./tools/check-syntax.sh || status=1

echo
echo "== pure functions =="
node tests/layout.test.js || status=1
node tests/translate.test.js || status=1

echo
echo "== bin/ scripts =="
./tests/scripts.test.sh || status=1

exit "$status"
```

- [ ] **Step 2: 跑全量**

Run: `chmod +x tools/test.sh && ./tools/test.sh`
Expected: 三段全过，退出码 0

- [ ] **Step 3: 写 README.md**

````markdown
# Translate (billy.translate)

Select text anywhere, press `SUPER + CTRL + T`, read the translation in a
bubble at the cursor. Translations stream in, and the bubble copies with one
click.

- **Selects Chinese** → translates to English
- **Selects anything else** → translates to Simplified Chinese

## Keys

| Key | Action |
|---|---|
| `SUPER + CTRL + T` | Translate the selection; press again to dismiss |
| `SUPER + CTRL + SHIFT + T` | Copy the current translation |
| `Esc`, or click outside | Dismiss |

Bind them in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + T", "Translate selection", "omarchy-shell shell toggle billy.translate '{}'")
o.bind("SUPER + CTRL + SHIFT + T", "Copy translation", "omarchy-shell billy.translate copy")
```

## Configuration

`~/.local/state/omarchy/translate/config.json` (mode 0600), written on first
run from the chat plugin's config:

| Key | Meaning |
|---|---|
| `baseUrl` | Any OpenAI-compatible root, e.g. `https://api.deepseek.com/v1` |
| `model` | Model id |
| `apiKey` | Bearer token; leave empty for a local server that needs none |
| `systemPrompt` | Empty uses the built-in translation prompt |
| `temperature` | `0.2` by default — translation wants determinism |
| `maxTokens` | `0` means "do not send the field" |
| `timeoutSec` | Request timeout, `60` by default |

The API key deliberately does **not** live in `~/.config/omarchy/shell.json`:
plugin settings there are inline on the bar entry, and the shell rewrites that
file on every layout change. It is also kept out of `argv` — curl reads it from
a 0600 config file, because `/proc/<pid>/cmdline` is world-readable.

## How the selection is read

The primary selection first — that is what a mouse drag fills, and reading it
touches nothing. Only when it is empty does the plugin synthesise `Ctrl+C` and
read the clipboard, restoring the original afterwards.

**Known side effect:** on that fallback path the selection may land in the
omarchy clipboard history. The synthetic copy and its undo are separate
clipboard writes, and a clipboard watcher can observe the one in between.

## Known limitations

1. The fallback path may leave the selection in clipboard history (above).
2. While the bubble is open it covers the screen, so you cannot select new text
   until you dismiss it. This is deliberate: a non-modal bubble that cannot
   take keyboard focus would also be one you could not close with `Esc`.
3. Some apps do not populate the primary selection at all, so they always take
   the fallback path.
4. There is no settings UI. Edit the JSON.

## Tests

```bash
./tools/test.sh
```

Covers QML syntax (`qmllint`'s `[syntax]` class only), the pure functions in
`Layout.js` and `Translate.js`, and both `bin/` scripts. The QML layer has no
harness — after any QML edit, restart the shell rather than trusting a
hot-reload, because a plugin that fails to compile keeps reporting the stale
error and the stale line number.
````

- [ ] **Step 4: 装键位**

在 `~/.config/hypr/bindings.lua` 末尾追加：

```lua
o.bind("SUPER + CTRL + T", "Translate selection", "omarchy-shell shell toggle billy.translate '{}'")
o.bind("SUPER + CTRL + SHIFT + T", "Copy translation", "omarchy-shell billy.translate copy")
```

Run: `omarchy menu keybindings --print | grep -i translat`
Expected: 两行都在。**若第一条没有出现**，说明 `SUPER + CTRL + T` 已被占用 —— `o.bind` 会覆盖，但值得确认没踩到别的功能：`omarchy menu keybindings --print | grep "SUPER + CTRL + T"`。

- [ ] **Step 5: 从零验一次全新安装**

```bash
rm -rf ~/.local/state/omarchy/translate
omarchy restart shell && sleep 3
# 选中一段文字，按 SUPER + CTRL + T
ls -l ~/.local/state/omarchy/translate/config.json
```
Expected: 插件可用，配置被自动创建。这验证的是一条新用户会走的路径 —— 前面所有测试都跑在已经配好的状态上。

- [ ] **Step 6: 提交**

```bash
cd ~/.config/omarchy/plugins/billy.translate
git add -A
git commit -m "Add README, test entry point, and keybind documentation

Documents the fallback path's clipboard-history side effect and the
choice to make the bubble modal, so both are visible to a reader rather
than only to whoever took the decision."
```

---

## 完成标准

- `./tools/test.sh` 全绿
- Task 9 Step 5 的 14 条手动走查全部通过
- Task 10 Step 5 的全新安装路径可用
- 没有一处硬编码的颜色或裸像素数字
- `~/.local/state/omarchy/translate/` 权限 0700、`config.json` 权限 0600
