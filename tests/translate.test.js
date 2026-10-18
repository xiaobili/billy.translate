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
check("a configured prompt replaces the default",
  T.buildBody({ model: "m", systemPrompt: "custom" }, "x").messages[0].content, "custom")
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
check("the default prompt states both directions", /Chinese/.test(prompt) && /English/.test(prompt), true)
check("the default prompt preserves Markdown structure", /Markdown/i.test(prompt), true)

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

// A client-side heuristic, deliberately not the rule the prompt hands the
// model: "predominantly Chinese" is the model's judgement, while this counts
// any CJK character as Chinese. The two can disagree at the margin.
check("empty text labels as non-Chinese", T.directionLabel(""), "→ 中文")
check("Chinese text labels the other way", T.directionLabel("你好，世界"), "中文 → EN")
check("English text labels to Chinese", T.directionLabel("hello world"), "→ 中文")
check("CJK among Latin text is enough", T.directionLabel("hello 你好"), "中文 → EN")
check("one CJK character alone is enough", T.directionLabel("好"), "中文 → EN")

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

report()
