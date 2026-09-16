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
