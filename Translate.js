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
  "- When the input is Markdown, preserve its structure: headings, lists,",
  "  bold/italic, links, code blocks and tables stay as valid Markdown,",
  "  translating only the human-readable text inside them.",
  "- Keep proper nouns, code identifiers, and URLs unchanged.",
  "- If the input is a single word, give the most common translation, plus its part of speech if useful."
].join("\n")

function defaultSystemPrompt() {
  return DEFAULT_SYSTEM_PROMPT
}

// Which way the label points, in one place: the bubble shows it and the input
// field recomputes it on every keystroke. Any CJK character counts as Chinese
// — a label is a glance, not a language-detection pass of our own.
function directionLabel(text) {
  var chinese = /[一-鿿]/.test(String(text === undefined || text === null ? "" : text))
  return chinese ? "中文 → EN" : "→ 中文"
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
    stream: true,
    // Translation wants the answer, not the model's chain of thought.
    // `deepseek-flash` enables thinking by default at effort "high", which
    // costs latency and tokens and — per DeepSeek's API docs — also makes the
    // endpoint ignore `temperature`, silently discarding the determinism this
    // tool asks for. An endpoint that rejects unknown body fields would need
    // this line removed.
    thinking: { type: "disabled" }
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

// Qt's Text.MarkdownText parses inline HTML the CommonMark way, so a `<...>`
// that survives translation — a generic like List<String>, a placeholder like
// <name>, a literal tag the model was told to keep — is swallowed as a tag
// instead of displayed. Escape the `<` of anything tag-shaped to `&lt;`, which
// the Markdown renderer shows literally.
//
// Fenced code blocks and inline code spans are skipped: their contents are
// already literal, and escaping there would print the entity text itself.
// Indented code blocks are not recognised — the model is instructed to emit
// fences, so a 4-space indent in a translation is prose, not code.
function escapeHtmlTags(text) {
  var s = String(text === undefined || text === null ? "" : text)
  var lines = s.split("\n")
  var out = []
  var fenceChar = ""
  var fenceLen = 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var fence = line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (fence) {
      var mark = fence[1]
      var ch = mark.charAt(0)
      var rest = line.substring(fence[0].length)
      if (fenceChar === "") {
        fenceChar = ch
        fenceLen = mark.length
      } else if (ch === fenceChar && mark.length >= fenceLen && rest.trim() === "") {
        fenceChar = ""
        fenceLen = 0
      }
      out.push(line)
      continue
    }
    out.push(fenceChar === "" ? escapeCodeSpans(line) : line)
  }
  return out.join("\n")
}

// Escape tag-shaped `<...>` outside inline code spans. A span opens with a
// run of N backticks and closes with a run of the same length; an unmatched
// run is literal text, not code.
function escapeCodeSpans(line) {
  var out = ""
  var i = 0
  var n = line.length
  while (i < n) {
    if (line.charAt(i) !== "`") {
      var start = i
      while (i < n && line.charAt(i) !== "`") i++
      out += escapeTagOpen(line.substring(start, i))
      continue
    }
    var runStart = i
    while (i < n && line.charAt(i) === "`") i++
    var runLen = i - runStart
    var close = -1
    var j = i
    while (j < n) {
      if (line.charAt(j) === "`") {
        var k = j
        while (k < n && line.charAt(k) === "`") k++
        if (k - j === runLen) { close = j; break }
        j = k
      } else {
        j++
      }
    }
    if (close === -1) {
      // No matching run: the backticks are literal text.
      out += escapeTagOpen(line.substring(runStart))
      break
    }
    // Delimiters and contents are literal; escape nothing inside.
    out += line.substring(runStart, close + runLen)
    i = close + runLen
  }
  return out
}

// The `<` of anything shaped like an HTML tag becomes `&lt;`, which the
// Markdown renderer shows literally instead of parsing as a tag. The lookahead
// keeps lone `<` (a < b, 1 < 2) untouched — those already render literally —
// and `>` is never escaped: mid-text it is literal, and at a line start it may
// be a blockquote the model meant.
function escapeTagOpen(segment) {
  return segment.replace(/<(?=[A-Za-z/?!][^<>\n]*>)/g, "&lt;")
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
