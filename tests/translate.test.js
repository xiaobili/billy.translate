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

// ---------------------------------------------------------------- direction

// A client-side heuristic, deliberately not the rule the prompt hands the
// model: "predominantly Chinese" is the model's judgement, while this counts
// any CJK character as Chinese. The two can disagree at the margin.
check("empty text labels as non-Chinese", T.directionLabel(""), "→ 中文")
check("Chinese text labels the other way", T.directionLabel("你好，世界"), "中文 → EN")
check("English text labels to Chinese", T.directionLabel("hello world"), "→ 中文")
check("a single CJK character is enough", T.directionLabel("hello 你好"), "中文 → EN")

report()
