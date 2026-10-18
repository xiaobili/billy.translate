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
// Translation wants the answer, not the model's chain of thought: the
// configured model enables thinking by default, and thinking mode also makes
// the API ignore `temperature`.
check("thinking is disabled", body.thinking && body.thinking.type, "disabled")
// 0 means "do not send the field": some servers reject it, and the provider
// default is a better ceiling than an arbitrary one.
check("max_tokens is omitted when 0", "max_tokens" in body, false)
check("max_tokens is sent when set",
  "max_tokens" in T.buildBody({ model: "m", maxTokens: 512 }, "x"), true)
check("a configured prompt is appended to the built-in rules",
  T.buildBody({ model: "m", systemPrompt: "custom" }, "x").messages[0].content,
  T.defaultSystemPrompt() + "\n\ncustom")
check("a blank configured prompt falls back to the default",
  T.buildBody({ model: "m", systemPrompt: "   " }, "x").messages[0].content, T.defaultSystemPrompt())
check("empty text still produces a user turn",
  T.buildBody({ model: "m" }, "").messages[1].content, "")
check("a system suffix is appended to the prompt",
  T.buildBody({ model: "m" }, "x", "nudge").messages[0].content,
  T.defaultSystemPrompt() + "\n\nnudge")
check("no suffix leaves the prompt alone",
  T.buildBody({ model: "m" }, "x").messages[0].content, T.defaultSystemPrompt())

const prompt = T.defaultSystemPrompt()
check("the default prompt forbids commentary", /only the translation/i.test(prompt), true)
check("the default prompt names its one direction", /Translate the text into Simplified Chinese/.test(prompt), true)
check("the default prompt preserves Markdown structure", /Markdown/i.test(prompt), true)
// The rules that keep a bubble readable are shared by every direction now.
check("every direction keeps the shared rules",
  ["zh", "en", "ja"].every(function (code) {
    var p = T.systemPrompt({}, "en", code)
    return /only the translation/i.test(p) && /Markdown/i.test(p) && /proper nouns/i.test(p)
  }), true)

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

// ---------------------------------------------------------------- direction
//
// The bubble labels the direction and the prompt states it. Both come from
// detectLang() and targetLang(), which is what keeps a label reading "EN → 中文"
// over a body that asked for Japanese.

check("empty text has no source language", T.detectLang(""), "")
check("whitespace is not a language", T.detectLang("   \n\t"), "")
check("digits and emoji are not a language", T.detectLang("2024 + 1 = 2025 😀"), "")
check("Chinese text is Chinese", T.detectLang("你好，世界"), "zh")
check("one Chinese character alone is enough", T.detectLang("好"), "zh")
check("English text is English", T.detectLang("hello world"), "en")
check("a longer English sentence is English",
  T.detectLang("The quick brown fox jumps over the lazy dog"), "en")
check("Latin letters inside a Chinese sentence do not flip it",
  T.detectLang("React 是用于构建界面的库"), "zh")
check("a Chinese sentence with an English product name stays Chinese",
  T.detectLang("我用 Vim 写代码"), "zh")
check("Japanese is recognised by its kana, not its kanji",
  T.detectLang("こんにちは、元気ですか？"), "ja")
check("Korean is recognised by Hangul", T.detectLang("안녕하세요, 잘 지내세요?"), "ko")
check("Cyrillic is recognised", T.detectLang("Привет, как дела?"), "ru")
check("Arabic is recognised", T.detectLang("مرحبا كيف حالك"), "ar")
check("Thai is recognised", T.detectLang("สวัสดีครับ"), "th")
check("Hindi is recognised", T.detectLang("नमस्ते"), "hi")
check("one Cyrillic word inside English is still English",
  T.detectLang("the word привет means hi"), "en")
check("Latin-script languages are told apart by their function words",
  [T.detectLang("Guten Tag, wie geht es Ihnen?"),
    T.detectLang("Bonjour le monde, comment allez-vous?"),
    T.detectLang("El perro come la comida"),
    T.detectLang("Questo è un testo italiano"),
    T.detectLang("Obrigado pela ajuda")],
  ["de", "fr", "es", "it", "pt"])
check("an unaccented German sentence still reads as German",
  T.detectLang("Das ist nicht gut"), "de")
check("a source code line is not mistaken for prose",
  T.detectLang("function translate(text) { return text }"), "en")

// Detection is a density measurement, so non-prose tokens outvote short
// passages. Rich mode (ALT+SHIFT+D) hands in exactly that: HTML turned into
// Markdown, with URLs, link targets, code spans and bare paths. A URL once
// scored Portuguese on the `a` inside "example.com" and flipped a Chinese
// sentence.
check("a URL does not make Chinese look Portuguese",
  T.detectLang("参考 https://example.com/docs 这个页面。"), "zh")
check("two bare URLs do not outvote the Chinese around them",
  T.detectLang("见 https://a.co 与 https://b.io 两处。"), "zh")
check("a Markdown link keeps its label and loses its target",
  T.detectLang("详见 [官方文档](https://example.com/a) 的说明。"), "zh")
check("an image alt text is not the passage",
  T.detectLang("中文正文，附图：![img](https://x.co/a.png)"), "zh")
check("a shell command inside Chinese stays Chinese",
  T.detectLang("运行 `npm run build` 即可。"), "zh")
check("a fenced block does not become the language",
  T.detectLang("```js\nconst a = 1;\n```\n\n这是代码示例。"), "zh")
check("HTML tags and attributes are not words",
  T.detectLang('<div class="the and this">中文内容在这里</div>'), "zh")
check("a dunder identifier does not leak its letters",
  T.detectLang("这是 __init__ 方法的说明。"), "zh")
check("a bare file name is not a word",
  T.detectLang("把内容写进 package.json 就行。"), "zh")
check("stripping leaves the Latin languages it was not aimed at alone",
  [T.detectLang("Read https://example.com/the/and/this for the truth"),
    T.detectLang("Die Einstellungen liegen unter https://example.com/die/und/das und gelten für alle."),
    T.detectLang("Guten Tag, wie geht es Ihnen?")],
  ["en", "de", "de"])
check("text that is nothing but a URL still says Latin",
  T.detectLang("https://example.com"), "en")
check("stripping does not eat the words the lists need",
  ["the", "and", "nicht", "não"].every(function (w) {
    return T.stripNonLanguage("a " + w + " b").indexOf(w) !== -1
  }), true)

check("the default target is Chinese for a non-Chinese source",
  T.targetLang("en", ""), "zh")
check("the default target for Chinese is English",
  T.targetLang("zh", ""), "en")
check("a configured target wins for any other source",
  T.targetLang("ja", "en"), "en")
check("a configured target that equals the source falls back to the pair",
  T.targetLang("en", "en"), "zh")
check("Chinese source with Chinese configured falls back to English",
  T.targetLang("zh", "zh"), "en")
check("an unknown source still resolves to the configured target",
  T.targetLang("", "ja"), "ja")

check("the label names both ends",
  T.directionLabel("en", ""), "EN → 中文")
check("the label reverses for Chinese input",
  T.directionLabel("zh", ""), "中文 → EN")
check("the label follows a configured target",
  T.directionLabel("en", "ja"), "EN → 日本語")
check("no source yet labels the destination only",
  T.directionLabel("", "ja"), "→ 日本語")
check("the label and the target resolver never disagree",
  ["", "zh", "en", "ja", "de"].every(function (src) {
    var label = T.directionLabel(src, "fr")
    return label.indexOf(T.languageLabel(T.targetLang(src, "fr"))) !== -1
  }), true)

check("language codes normalise case and separators",
  [T.normalizeLang("ZH-tw"), T.normalizeLang("zh_TW"), T.normalizeLang(" en "), T.normalizeLang("")],
  ["zh-TW", "zh-TW", "en", ""])
check("an unknown code is passed through, not dropped",
  T.normalizeLang("xx"), "xx")
check("an unknown code has no name", T.languageInfo("xx"), null)
check("a known code has both forms",
  T.languageInfo("ja"), { name: "Japanese", label: "日本語" })

// ------------------------------------------------------------------ prompts

check("the prompt names the target the label showed",
  /Translate it into Japanese\./.test(T.systemPrompt({}, "en", "ja")), true)
check("the prompt names the source when it can",
  /The text is in English\. Translate it into Simplified Chinese\./.test(T.systemPrompt({}, "en", "zh")), true)
check("with no source the prompt states only the target",
  /^- Translate the text into Japanese\.$/m.test(T.systemPrompt({}, "", "ja")), true)
check("a target equal to the source is not a direction",
  /^- Translate the text into English\.$/m.test(T.systemPrompt({}, "en", "en")), true)
check("the built-in pair with no default target still translates both ways",
  [/Translate it into English/.test(T.systemPrompt({}, "zh", T.targetLang("zh", ""))),
    /Translate it into Simplified Chinese/.test(T.systemPrompt({}, "en", T.targetLang("en", "")))],
  [true, true])

check("a configured prompt without placeholders keeps the direction rules",
  /Translate it into Japanese/.test(T.systemPrompt({ systemPrompt: "Use a formal tone." }, "en", "ja")), true)
check("a configured prompt without placeholders keeps its own words",
  /Use a formal tone\.$/.test(T.systemPrompt({ systemPrompt: "Use a formal tone." }, "en", "ja")), true)
check("{{lang}} is filled in with the target's name",
  T.systemPrompt({ systemPrompt: "Translate to {{lang}}." }, "en", "ja"), "Translate to Japanese.")
check("{{source}} is filled in with the source's name",
  T.systemPrompt({ systemPrompt: "From {{source}} to {{lang}}." }, "en", "ko"), "From English to Korean.")
check("a templated prompt replaces the built-in one entirely",
  T.systemPrompt({ systemPrompt: "Only {{lang}}, nothing else." }, "en", "ja"),
  "Only Japanese, nothing else.")
check("{{source}} with no detection says so",
  T.systemPrompt({ systemPrompt: "From {{source}}." }, "", "ja"), "From the detected language.")
check("a blank templated prompt is just the built-in one",
  T.systemPrompt({ systemPrompt: "   " }, "en", "ja"), T.systemPrompt({}, "en", "ja"))

check("the echo nudge repeats the target, not the old pair",
  T.echoNudge("ja"), "Your previous response repeated the user's input verbatim instead of translating it. Translate the text into Japanese. Output only the translation.")
check("the nudge still forbids commentary", /only the translation/i.test(T.echoNudge("de")), true)
check("the old constant still exists for callers that pass no target",
  T.ECHO_NUDGE, T.echoNudge("zh"))

// The direction is part of the request identity: switching the target must
// not replay the previous answer from the cache.
check("the cache key includes the direction",
  T.cacheKey("input", cfgA, "hi", "en", "zh") === T.cacheKey("input", cfgA, "hi", "en", "ja"), false)
check("the cache key is stable for the same direction",
  T.cacheKey("input", cfgA, "hi", "en", "ja") === T.cacheKey("input", cfgA, "hi", "en", "ja"), true)

// ------------------------------------------------------------ truncation
// A whole-page rich capture must not go out unbounded: it burns tokens and
// risks the provider's context limit.

check("short text passes through",
  T.truncateText("hello", 8000), "hello")
check("long text is cut to the limit",
  T.truncateText("abcdefgh", 5), "abcde")
check("a non-positive limit disables the cap",
  T.truncateText("abcdefgh", 0), "abcdefgh")
check("a surrogate pair is never split at the cut",
  T.truncateText("ab\uD83D\uDE00cd", 3), "ab")
check("null and undefined are empty",
  T.truncateText(null, 10) + T.truncateText(undefined, 10), "")

// ------------------------------------------------------------------- cache
// The same text through the same model and prompt is the same request.

var cfgA = { model: "m", systemPrompt: "" }
check("the key is stable",
  T.cacheKey("selection", cfgA, "hi") === T.cacheKey("selection", cfgA, "hi"), true)
check("the text matters",
  T.cacheKey("selection", cfgA, "hi") === T.cacheKey("selection", cfgA, "yo"), false)
check("the model matters",
  T.cacheKey("selection", cfgA, "hi") === T.cacheKey("selection", { model: "n", systemPrompt: "" }, "hi"), false)
check("the prompt matters",
  T.cacheKey("selection", cfgA, "hi") === T.cacheKey("selection", { model: "m", systemPrompt: "x" }, "hi"), false)
check("the capture tag matters",
  T.cacheKey("selection", cfgA, "hi") === T.cacheKey("input", cfgA, "hi"), false)

// ------------------------------------------------------ html-tag escaping
// A tag-shaped `<...>` must render literally instead of being parsed as
// inline HTML by Text.MarkdownText; lone `<` and `>` already render
// literally and stay untouched.

check("a generic type is escaped",
  T.escapeHtmlTags("List<String>"), "List&lt;String>")
check("a close tag is escaped",
  T.escapeHtmlTags("a </div> b"), "a &lt;/div> b")
check("an HTML comment is escaped",
  T.escapeHtmlTags("<!-- hi -->"), "&lt;!-- hi -->")
check("a placeholder in translated text is escaped",
  T.escapeHtmlTags("你好 <name>"), "你好 &lt;name>")
check("a lone less-than is untouched",
  T.escapeHtmlTags("a < b"), "a < b")
check("a greater-than is never escaped",
  T.escapeHtmlTags("a > b"), "a > b")
check("a blockquote marker survives",
  T.escapeHtmlTags("> quoted"), "> quoted")
check("markdown around the tag is preserved",
  T.escapeHtmlTags("**bold** <tag> and `code`"), "**bold** &lt;tag> and `code`")
check("inline code is left alone",
  T.escapeHtmlTags("use `<div>` here"), "use `<div>` here")
check("a multi-backtick span is left alone",
  T.escapeHtmlTags("`` `<b>` ``"), "`` `<b>` ``")
check("an unmatched backtick run is literal text",
  T.escapeHtmlTags("a `< b"), "a `< b")
check("a fenced block is left alone",
  T.escapeHtmlTags("```\n<div>\n```"), "```\n<div>\n```")
check("a fenced block with an info string is left alone",
  T.escapeHtmlTags("```html\n<div>\n```"), "```html\n<div>\n```")
check("a tilde fence is honoured",
  T.escapeHtmlTags("~~~\n<x>\n~~~"), "~~~\n<x>\n~~~")
check("an unclosed fence treats the tail as code",
  T.escapeHtmlTags("```\n<div>"), "```\n<div>")
check("text after a closed fence is escaped again",
  T.escapeHtmlTags("```\n<x>\n```\n<y>"), "```\n<x>\n```\n&lt;y>")
check("null and undefined are empty",
  T.escapeHtmlTags(null) + T.escapeHtmlTags(undefined), "")

// ------------------------------------------------------ verbatim echo
// A model that returns the input unchanged gets one retry with a nudge.
// Short inputs (proper nouns, single words) and URLs are often correctly
// returned verbatim, so only longer inputs count.

check("an identical sentence is an echo",
  T.isVerbatimEcho("hello world, this is a test", "hello world, this is a test"), true)
check("a real translation is not an echo",
  T.isVerbatimEcho("hello world", "你好世界"), false)
check("whitespace differences still count as an echo",
  T.isVerbatimEcho("hello  world\ftest", "hello world test"), true)
check("a proper noun is flagged too — the retry confirms it",
  T.isVerbatimEcho("Billy", "Billy"), true)
check("an identical URL is not an echo",
  T.isVerbatimEcho("https://example.com/some/path", "https://example.com/some/path"), false)
check("empty inputs are not echoes",
  T.isVerbatimEcho("", "") === false && T.isVerbatimEcho("hello world test", "") === false, true)
check("the nudge names the failure",
  /verbatim/.test(T.ECHO_NUDGE) && /only the translation/i.test(T.ECHO_NUDGE), true)

// ------------------------------------------------- incremental escaping
// escapeHtmlLines carries fence state across calls so the bubble can escape
// only the new lines of a growing stream. Chunked escaping must equal the
// one-shot result.

function escapeIncremental(chunks) {
  var text = ""
  var fc = ""
  var fl = 0
  for (var i = 0; i < chunks.length; i++) {
    var res = T.escapeHtmlLines(chunks[i], fc, fl)
    text += res.text
    fc = res.fenceChar
    fl = res.fenceLen
  }
  return { text: text, fenceChar: fc, fenceLen: fl }
}

check("one chunk equals the one-shot result",
  escapeIncremental(["a <b>\n"]).text, T.escapeHtmlTags("a <b>\n"))
check("fence state carries across chunks",
  escapeIncremental(["```\n", "<div>\n", "```\n", "<p>\n"]).text,
  T.escapeHtmlTags("```\n<div>\n```\n<p>\n"))
check("an unclosed fence keeps the tail literal across chunks",
  escapeIncremental(["```\n", "<div>\n"]).text, T.escapeHtmlTags("```\n<div>\n"))
check("state is reported back to the caller",
  escapeIncremental(["~~~\n"]).fenceChar, "~")

// -------------------------------------------------------- table flattening
// Text.MarkdownText cannot render a table here: Qt re-lays it out on the next
// text change and the scene graph dies in prepareAlphaBatches, taking the
// shell with it. flattenTables() turns every row into a list item so a table
// never reaches the renderer. (See the comment on the function.)
//
// The bubble now lifts tables out into real Table.qml grids instead, so this
// is the safety net for prose that splitBlocks leaves behind — but the tests
// stay: the net must still hold.

check("a row becomes a list item, the delimiter row is dropped",
  T.flattenTables("| a | b |\n| --- | --- |\n| 1 | 2 |\n"),
  "- a — b\n- 1 — 2\n")
check("the header row is kept as the first item",
  T.flattenTables("| File | Purpose |\n| --- | --- |\n| `SKILL.md` | Setup |\n"),
  "- File — Purpose\n- `SKILL.md` — Setup\n")
check("alignment colons are a delimiter row too",
  T.flattenTables("h1 | h2 | h3\n:--- | :---: | ---:\n1 | 2 | 3\n"),
  "- h1 — h2 — h3\n- 1 — 2 — 3\n")
check("a pipe inside inline code is content, not a separator",
  T.flattenTables("| expr | mean |\n| --- | --- |\n| `a|b` | or |\n"),
  "- expr — mean\n- `a|b` — or\n")
check("an escaped pipe stays inside its cell",
  T.flattenTables("| k | v |\n| --- | --- |\n| a \\| b | both |\n"),
  "- k — v\n- a | b — both\n")
check("empty cells do not leave dangling separators",
  T.flattenTables("| k | v |\n| --- | --- |\n| a | |\n"),
  "- k — v\n- a\n")
check("prose with a pipe and no delimiter row is left alone",
  T.flattenTables("use a | b in shell\n"), "use a | b in shell\n")
check("a table stop at the first line without a pipe",
  T.flattenTables("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter the table\n"),
  "- a — b\n- 1 — 2\n\nafter the table\n")
check("a table inside a fenced block stays literal",
  T.flattenTables("```\n| a | b |\n| --- | --- |\n```\n"),
  "```\n| a | b |\n| --- | --- |\n```\n")
check("a partial table (header only, no delimiter yet) stays as it is",
  T.flattenTables("| a | b |\n"), "| a | b |\n")
check("flattening is idempotent",
  T.flattenTables(T.flattenTables("| a | b |\n| --- | --- |\n| 1 | 2 |\n")),
  T.flattenTables("| a | b |\n| --- | --- |\n| 1 | 2 |\n"))

// ----------------------------------------------------------- block split
// The bubble renders prose and tables as separate items (Table.qml draws the
// grid), so splitBlocks() is the boundary the crash cannot cross: whatever it
// hands to Text.MarkdownText must contain no table.

check("prose and table become two blocks in order",
  JSON.stringify(T.splitBlocks("## Files\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter")),
  JSON.stringify([
    { kind: "md", text: "## Files" },
    { kind: "table", header: ["a", "b"], rows: [["1", "2"]] },
    { kind: "md", text: "after" }
  ]))
check("the header row is split out of the body rows",
  T.splitBlocks("| h1 | h2 |\n| --- | --- |\n| 1 | 2 |\n")[0],
  { kind: "table", header: ["h1", "h2"], rows: [["1", "2"]] })
check("two tables with prose between give three blocks",
  T.splitBlocks("| a |\n| --- |\nmid\n| b |\n| --- |").map(function (b) { return b.kind }),
  ["table", "md", "table"])
check("a table in a fenced block stays prose",
  T.splitBlocks("```\n| a |\n| --- |\n```\n").map(function (b) { return b.kind }),
  ["md"])
check("a prose-only answer stays one block, blank lines and all",
  T.splitBlocks("a\n\n\n\nb"),
  [{ kind: "md", text: "a\n\n\n\nb" }])
check("empty input gives no blocks", T.splitBlocks("").length, 0)
check("blocks carry no table syntax into the md kind",
  T.splitBlocks("| a | b |\n| --- | --- |\n| 1 | 2 |").every(function (b) {
    return b.kind === "table"
  }), true)

// ------------------------------------------------------------ table layout

check("widths sum exactly to the available width",
  T.tableWidths(["a", "b"], [["1", "2"]], 392, 68).reduce(function (a, b) { return a + b }, 0), 392)
check("no column is narrower than the minimum",
  T.tableWidths(["k", "v"], [["k", "a very long value column that dominates the row"]], 392, 68)
    .every(function (w) { return w >= 68 }), true)
check("no column takes more than 60% of a multi-column row",
  T.tableWidths(["a", "b"], [["a", new Array(80).join("w")]], 392, 68).every(function (w) {
    return w <= Math.ceil(392 * 0.6)
  }), true)
check("a single-column table fills the row",
  T.tableWidths(["only"], [["one"]], 392, 68), [392])
check("too many columns fall back to equal shares",
  T.tableWidths(["a", "b", "c", "d", "e", "f", "g", "h"], [new Array(8).fill("x")], 100, 68),
  [13, 13, 13, 13, 12, 12, 12, 12])

check("grid flattens every cell with its width and edge flags",
  (function () {
    var g = T.tableGrid(["h1", "h2"], [["r1c1", "r1c2"], ["r2c1"]], 392, 68)
    return [
      g.columns, g.rows, g.cells.length,
      g.cells[0].header, g.cells[0].width === g.widths[0], g.cells[1].lastColumn,
      g.cells[4].lastRow, g.cells[4].text, g.cells[5].text
    ]
  })(),
  [2, 3, 6, true, true, true, true, "r2c1", ""])
check("an empty table gives an empty grid",
  T.tableGrid([], [], 392, 68), { columns: 0, rows: 0, widths: [], cells: [] })

report()
