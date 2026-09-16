# 划词翻译插件（billy.translate）设计

日期：2026-09-17
状态：待实现
目标插件目录：`~/.config/omarchy/plugins/billy.translate/`

## 1. 目标

在 Omarchy 桌面任意应用中选中文本，按一个快捷键，在**光标附近**的气泡里看到**流式**译文，一键复制。

## 2. 非目标（本版明确不做）

- 多引擎 / 多语言并排对照
- 翻译历史、跨会话持久化
- 把译文替换回原文
- 图形化设置界面 —— 配置直接编辑 JSON

## 3. 已确认的决策

| # | 决策 | 选择 | 理由 |
|---|---|---|---|
| 1 | 取词方式 | 主选择区优先，模拟 Ctrl+C 兜底 | 覆盖最广；绝大多数应用走零副作用的第一条路 |
| 2 | 翻译后端 | 插件独立配置，首次运行从 `billy.chat` 导入 | 翻译可用更便宜快的模型与独立 prompt，又不必重填 key |
| 3 | 功能范围 | 翻译 + 流式气泡 + 复制译文 | YAGNI |
| 4 | 弹窗位置 | 跟随光标的气泡 | 视线不离开选区 |
| 5 | 翻译方向 | 智能双向：中文→英文，其他→简体中文 | 中英混用桌面免切换 |
| 6 | 时序逻辑归属 | 全部推给 `bin/` 下的 shell 脚本，QML 只读 stdout | 取词有状态、有超时、有回滚；脚本能脱离 shell 单测 |
| 7 | 弹窗语义 | **模态**（全屏 + 遮罩 + `Exclusive` 键盘焦点），`toggle` | 与 clipboard / emojis / reminders 一致 |

### 决策 6 的代价（已接受）

多两个脚本文件。换来的是 `bin/pick-text` 与 `bin/cursor-pos` 可以在终端里直接跑、直接断言，不必启动 shell。

### 决策 7 的代价（已接受）

弹窗打开期间**无法用鼠标划选新文本** —— 全屏 layer surface 会吞掉指针事件。要翻译新内容需先按 Esc 或再按一次快捷键。

**被否决的替代方案：非模态气泡。** 气泡只占自身尺寸、`WlrKeyboardFocus.OnDemand`、不遮罩，可以连续划词翻译。否决原因：Esc 和「点击外部关闭」都依赖键盘/全屏焦点，一旦焦点未回到插件侧，就会留下一个**无法关闭的浮窗**。多按一次 Esc 比关不掉的窗口好。

## 4. 架构

```
Hyprland 键位 (SUPER + CTRL + T)
  └─ omarchy-shell shell toggle billy.translate '{}'
       └─ shell.summon() → Overlay.qml.open(payloadJson)
            ├─ ① Probe.cursorPos()   → bin/cursor-pos    （~15ms）
            ├─ ② Probe.pickText()    → bin/pick-text     （~5ms，兜底路径最多 ~400ms）
            └─ ③ phase=translating → Transport 发起 curl 流式请求
                                     → 译文逐字追加进 Bubble
```

### 硬约束：取词必须先于显示

气泡以 `WlrKeyboardFocus.Exclusive` 打开会抢走键盘焦点。焦点一旦被抢走，兜底路径的模拟 Ctrl+C 就打不到原应用了。**所以 `PanelWindow` 在取词完成前不得可见。**

实现方式：`opened` 属性在 `open()` 一进来就置 `true`（这样 shell 门面的 `isPluginOpen()` 立刻为真，避免取词期间重复按快捷键触发第二次取词），但

```qml
PanelWindow { visible: root.opened && root.phase !== "picking" }
```

取词期间**根本不存在 layer surface**：不抢焦点、不闪、不吞输入。

### 快捷键为什么能到达原应用

`omarchy-shell` 由 `hl.dsp.exec_cmd()` 以 `exec` 方式启动，**不是窗口**，所以按快捷键时原应用仍持有焦点。`wtype` 发送的是独立虚拟键盘事件，不受物理修饰键（手指还按着 SUPER）影响。

## 5. 组件

```
~/.config/omarchy/plugins/billy.translate/
  manifest.json
  Overlay.qml        根元素：PanelWindow + open()/close() + IpcHandler + 相位状态机
  Bubble.qml         气泡卡片：布局、内容渲染、摆放与夹紧、交互
  Probe.qml          对外部世界的**唯一**读取点：两个 Process（光标位置、取词）
  Transport.qml      对外部世界的**唯一**写入点：curl 流式请求
  Config.qml         配置读写 + 首次从 billy.chat 导入 + 目录创建
  Translate.js       纯函数：system prompt 构造、SSE 解析、错误文案
  bin/cursor-pos     光标位置 → 一行坐标
  bin/pick-text      取词 → stdout
  README.md
```

### manifest.json

字段全部按 `PluginRegistry.validateManifest` / `omarchy-plugin-validate` 的校验规则来（`schemaVersion` 必须是**数字** `1`，不是字符串；`entryPoints` 的值必须是安全相对路径）：

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

`keepLoaded: true` 是必需的：它在 shell 启动时就挂载组件，从而让 `IpcHandler` 的目标从启动起就存在。否则 `omarchy-shell billy.translate copy` 在首次召唤前会打到不存在的目标。

`id` 用 `billy.` 而非 `omarchy.` 前缀 —— 后者是保留给第一方插件的，第三方用会被扫描器直接丢弃。插件目录名必须与 `id` 一致。

### 职责边界

- **`Probe.qml`** —— 「读桌面状态」。两个方法：`cursorPos()`、`pickText()`。各自一个 `Process` + `StdioCollector { waitForEnd: true }`。不解析语义，只把 stdout 交给调用方。
- **`Transport.qml`** —— 「发一次请求」。沿用 `billy.chat/Transport.qml` 的已验证做法：`curl -K` 读 0600 配置文件（**API key 绝不进 argv**，否则出现在 world-readable 的 `/proc/<pid>/cmdline`）、`SplitParser` 逐行读 SSE、`FileView` 带 `blockWrites: true`。
- **`Translate.js`** —— 纯函数，无 QML 依赖，是最容易推理和验证的部分。
- **`Overlay.qml`** —— 只做编排：谁在什么时候调谁。

## 6. 取词：`bin/pick-text`

stdout 输出取到的文本；取不到则 stdout 为空且退出码非 0。

1. `wl-paste --primary --no-newline` → 非空即输出并退出。**这条路覆盖绝大多数应用，零副作用。**
2. 否则走兜底：
   1. 按 `wl-paste --list-types` 逐类型**备份**整个剪贴板到临时目录 —— 备份类型而非只备份文本，这样图片、富文本也能原样还原
   2. `wtype -M ctrl -k c -m ctrl`
   3. 每 25ms 轮询 `wl-paste --no-newline`，上限 ~400ms，直到内容 ≠ 备份内容
   4. **还原剪贴板**（逐类型 `wl-copy --type`）
   5. 输出取到的文本
3. 任何一步失败都要走还原路径后退出非 0（`trap` 或显式清理）。

> **选项名注意**：wl-clipboard 2.3.0 里**没有 `--clipboard` 这个选项** —— 剪贴板是默认目标，`--primary` 才是切到主选择区。所以是 `wl-paste`（剪贴板）与 `wl-paste --primary`（主选择区）的对比，不是两个对称的长选项。此机已实测确认。

### 已知副作用（写进 README）

兜底路径下，划选内容可能被 omarchy clipboard 插件抓进历史 —— 模拟的 Ctrl+C 与还原之间存在窗口期，无法完全消除。**只有主选择区为空时才会走这条路。**

## 7. 定位：`bin/cursor-pos`

在 bash + jq 里做完所有换算，输出**一行空格分隔**：

```
<屏幕名> <局部x> <局部y> <屏宽> <屏高>
```

#### 坐标系（2026-09-17 修正）

**Hyprland 的 IPC 输出混用两套坐标，字段名看不出来：**

| 字段 | 空间 |
|---|---|
| `monitors[].width` / `.height` | **物理**（mode）像素 |
| `monitors[].x` / `.y` | **逻辑**（已缩放）坐标 |
| `hyprctl cursorpos` | **逻辑** |

依据（两条独立来源）：

1. Hyprland wiki 关于位置的定义：「The position is calculated with the scaled (and transformed) resolution, meaning if you want your 4K monitor with scale 2 to the left of your 1080p one, you'd use the position `1920x0` for the second screen. (3840 / 2)」
2. omarchy 自己的 PR #6363 定义了 jq 助手 `logical($px; $s): ($px * 120 / (($s * 120) | round)) | round`，并以 `logical($f.width; $f.scale)` 调用 —— 即逻辑宽 = `width / scale`。

所以换算**不做除法**（两边同为逻辑空间），而屏幕尺寸**要做除法**：

```
局部x  = 光标全局x - 显示器x          # 不除 scale
局部y  = 光标全局y - 显示器y
屏宽   = 显示器width  / 显示器scale    # 除 scale
屏高   = 显示器height / 显示器scale
```

命中判定（哪块屏包含光标）也必须用**逻辑**宽度：`x >= mon.x and x < mon.x + mon.width/scale`。

**这个 bug 为什么差点漏掉**：scale = 1 时两套空间完全重合，除法是恒等变换，任何单屏 scale-1 的测试和变异测试都观察不到它。在 scale = 2 的显示器上会导致局部坐标错位；在**混合缩放的多屏**布局上，物理宽度会让判定选中**错误的显示器**（实测：两块屏的合成布局下，光标在右侧屏，错误实现选中了左侧屏并给出完全错误的局部坐标）。

因此 `bin/cursor-pos` 支持 `HYPRCTL` 环境变量覆盖（默认 `hyprctl`），测试据此注入合成布局 —— 否则这段换算在本机不可能被测到。

屏幕名与尺寸取 `hyprctl -j monitors` 中**包含光标点**的那一块。

QML 侧：按屏幕名匹配 `Quickshell.screens`，绑到 `PanelWindow.screen`。

### 摆放规则（全部夹在屏幕安全区内）

设 `GAP = Style.space(12)`（光标与卡片间距）、`EDGE = Style.space(8)`（卡片与屏幕边缘的安全距离）。

- **水平**：`x = 局部x + GAP`；若 `x + 卡片宽 + EDGE > 屏宽` 则 `x = 屏宽 - 卡片宽 - EDGE`；最后再夹到 `x >= EDGE`
- **垂直**：`y = 局部y + GAP`；若 `y + 卡片高 + EDGE > 屏高` 则翻到上方 `y = 局部y - 卡片高 - GAP`；若翻转后 `y < EDGE` 则夹紧到 `EDGE`
- **内容变高时重算** —— 译文是流式长出来的，卡片高度会变。夹紧逻辑必须绑定卡片高度，否则长译文溢出屏幕底

### 缓存

显示器列表不常变：**启动时拉一次** `hyprctl -j monitors` 缓存，召唤时只跑 `cursorpos`。若光标落在缓存中不存在的屏幕上（热插拔 / 改排列），补拉一次并更新缓存。

召唤路径成本：一次进程，~10-20ms。

### 风险

`scale` 的除法是理论推导，**必须在实机上校准**，尤其是非 1.0 缩放的屏幕。这是整个设计里唯一无法从代码读出来的部分。

## 8. 相位状态机

```
idle ──open()──> picking ──取到文本──> translating ──流结束──> done
                   │                      │
                   └──取不到──> empty     └──出错──> error
```

| 相位 | `PanelWindow.visible` | 气泡内容 |
|---|---|---|
| `idle` | 否 | — |
| `picking` | **否**（关键：此时不能有 surface） | — |
| `translating` | 是 | 原文 + 流式译文 + 游标指示 |
| `done` | 是 | 原文 + 完整译文 + 复制按钮 |
| `empty` | 是 | 单行提示 |
| `error` | 是 | 原文 + 错误摘要 |

`close()`：取消进行中的 curl、清空状态、回到 `idle`。

## 9. 气泡内容与交互

```
┌─────────────────────────────────────┐
│ EN → 中文                    ⧉   ✕ │  ← 方向标签 / 复制 / 关闭
├─────────────────────────────────────┤
│ The quick brown fox jumps over the  │  ← 原文，暗色，最多 3 行，超出省略
│ lazy dog                            │
├─────────────────────────────────────┤
│ 敏捷的棕色狐狸跃过那只懒狗。            │  ← 译文，正常前景色，流式
│                                     │
└─────────────────────────────────────┘
```

- 宽度固定 `Style.space(420)`（约 3 行正文宽，长句不会拉成一条），高度 `auto` 但夹在 `[Style.space(120), Style.space(420)]` 之间：下限避免首帧跳动，上限封顶后译文区滚动
- 卡片用 `BorderSurface`，圆角取 `Style.cornerRadius`，边框取 `Border.surfaceSpec(...)` —— 与 shell 里其他卡片同源
- 原文区给用户确认「取到的对不对」—— 少了它，取词兜底出错时用户无从判断
- 复制按钮**常驻**在头部，不做悬停才显示（billy.chat 是悬停式，但那边是长文档、这里是短气泡，常驻可发现性更好）
- 全部颜色走 `Color` / `Style` 单例，尺寸走 `Style.space(n)`，绝不硬编码十六进制或裸像素

| 输入 | 行为 |
|---|---|
| `Esc` | 取消进行中的请求并关闭 |
| 再按一次快捷键 | 同上（`toggle`） |
| 点击气泡外 | 关闭 |
| 点击复制 / `SUPER + CTRL + SHIFT + T` | 复制译文，图标变对勾反馈 |

复制的是**译文**（用户已确认的范围）。

## 10. 配置

`~/.local/state/omarchy/translate/config.json`，权限 **0600**，目录 0700。

```json
{
  "baseUrl": "https://api.deepseek.com/v1",
  "model": "deepseek-flash",
  "apiKey": "",
  "systemPrompt": "",
  "temperature": 0.2,
  "maxTokens": 0,
  "timeoutSec": 60
}
```

- **首次运行**（文件不存在）：读 `~/.local/state/omarchy/chat/config.json`，**拷贝**其 `baseUrl` / `model` / `apiKey` 写入自己的文件。拷贝而非联动 —— 之后改哪边都不影响另一边。chat 配置不存在则写默认值。
- `systemPrompt` 为空则用内置默认（见下）。
- `maxTokens: 0` 表示不发送该字段。
- **无设置界面。** README 说明如何编辑。

### 内置默认 system prompt

```
You are a translation engine. Translate the user's text and output only the translation.

- If the text is predominantly Chinese, translate it into English.
- Otherwise, translate it into Simplified Chinese.

Rules:
- Output the translation only. No preamble, no explanation, no quotes, no notes.
- Preserve the original's line breaks, formatting, and inline code.
- Keep proper nouns, code identifiers, and URLs unchanged.
- If the input is a single word, give the most common translation, plus its part of speech if useful.
```

`temperature: 0.2` —— 翻译要确定性，不要创造力。

### 目录创建的坑

`FileView` 写入不存在的目录会以 `FileNotFound` 失败，且在 `printErrors: false` 下**完全静默**。必须先 `Process` 跑 `mkdir -p`，并且**把首次写入门控在该进程的 `onExited` 上**。读一个不存在的文件触发的是 `loadFailed` 而不是空的 `loaded`，同样要处理。

## 11. 错误处理

| 情况 | 气泡表现 |
|---|---|
| 取不到文本 | 「没有检测到选中文字」 |
| `baseUrl` 或 `model` 为空 | 「翻译未配置」+ 配置文件的绝对路径 |
| curl 退出码非 0 | 错误摘要（stderr tail） |
| HTTP ≥ 400 | 状态码 + body tail（截断到 2000 字符，与 billy.chat 一致） |
| 超时 | 「请求超时」 |
| 流中断（无 `[DONE]`） | **保留已收到的部分译文**，下方加一行提示 |

部分译文要保留 —— 用户已经读到的内容是有效产出，不能因为收尾失败就丢掉。

## 12. 验证

诚实说明：**这个项目没有自动化测试设施。**

**可以自动/命令行验证的：**

- `bin/cursor-pos` —— 直接跑，人工核对输出与 `hyprctl cursorpos`、`hyprctl -j monitors` 是否自洽
- `bin/pick-text` —— 直接跑。分别在（a）已有主选择区、（b）无主选择区但有可复制选区 两种情况下验证；用 `wl-paste` 在跑之前/之后各取一次对拍，确认剪贴板被原样还原
- `Translate.js` 里的纯函数（prompt 构造、SSE 解析、错误文案）—— 可用 `qjs`/`node` 直接跑

**只能手动验证的：**

- QML 渲染、流式更新、摆放与翻转、键盘/鼠标交互
- **实机校准**：`scale` 除法、翻转阈值

**迭代时必须记住（来自既有经验）：**

- QML 插件**编译失败是粘性的**。改完文件后 `rescanPlugins` 会重放**同一个旧错误、同一行号**，看起来像没生效。修复后必须 `omarchy restart shell`。判断方法：日志里的行号与磁盘内容对不上。
- 读日志只看**当前进程**的行，否则上一个进程的错误看起来像现在的：`journalctl --user | grep "omarchy-shell\[$PID\]"`。
- `IpcHandler` 的方法参数**必须标注类型**，未标注的参数是 `QVariant`，加载时会被拒绝（"cannot be used across IPC"）。

## 13. 键位

`~/.config/hypr/bindings.lua`：

```lua
o.bind("SUPER + CTRL + T", "Translate selection", "omarchy-shell shell toggle billy.translate '{}'")
o.bind("SUPER + CTRL + SHIFT + T", "Copy translation", "omarchy-shell billy.translate copy")
```

第一条走 shell 门面（与 clipboard / emojis 的写法一致）；第二条直接打插件自己的 `IpcHandler`。因此根元素必须暴露 `open(payloadJson)`、`close()` 和 `opened` 属性 —— 这是 shell 门面的契约（`shell.summon()` 调 `loader.item.open()`，`isPluginOpen()` 优先读 `loader.item.opened === true`）。

## 14. 已知限制

1. 兜底取词路径下，划选内容可能进入剪贴板历史（窗口期）
2. 弹窗打开时无法用鼠标划选新文本
3. 部分应用不写主选择区，只能走兜底路径
4. 首次使用需要先有 `billy.chat` 的配置，或手编 `config.json`
