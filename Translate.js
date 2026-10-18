// Pure helpers for the translate plugin: the prompt, the request body, SSE
// parsing, and error copy. No QML objects, no state. Imported with
// `import "Translate.js" as Translate`.

var SSE_PREFIX = "data:"
var HTTP_MARKER = "@@HTTP:"

// The languages the bubble can name, keyed by the code that goes into the
// prompt. `name` is what the model is told to translate into; `label` is the
// compact form the direction label and the picker show.
//
// Only languages a model reliably translates *into* are listed. Source
// detection is never on this list — that is the detector's job (detectLang),
// which knows every language below plus a set of source-only ones.
var LANGUAGES = {
  zh:  { name: "Simplified Chinese", label: "中文" },
  "zh-TW": { name: "Traditional Chinese", label: "繁中" },
  en:  { name: "English", label: "EN" },
  ja:  { name: "Japanese", label: "日本語" },
  ko:  { name: "Korean", label: "한국어" },
  es:  { name: "Spanish", label: "ES" },
  fr:  { name: "French", label: "FR" },
  de:  { name: "German", label: "DE" },
  ru:  { name: "Russian", label: "RU" },
  pt:  { name: "Portuguese", label: "PT" },
  it:  { name: "Italian", label: "IT" },
  ar:  { name: "Arabic", label: "AR" }
}

// The picker's order: the two the plugin was built around first, then the rest
// by rough number of speakers. Anything else the config names still works —
// it just is not offered in the picker.
var LANGUAGE_ORDER = ["zh", "en", "ja", "ko", "es", "fr", "de", "ru", "pt", "it", "ar", "zh-TW"]

// Names for languages the detector can recognise but the picker does not offer.
// Kept apart from LANGUAGES so the picker cannot accidentally list a language
// as a target that the prompt was never checked against.
var SOURCE_ONLY_NAMES = {
  th: "Thai", vi: "Vietnamese", id: "Indonesian", tr: "Turkish",
  nl: "Dutch", pl: "Polish", uk: "Ukrainian", hi: "Hindi", la: "Latin script"
}

function languageCodes() {
  return LANGUAGE_ORDER.slice()
}

// A code -> {name, label}, or null when the code is unknown. Unknown is a real
// answer: the picker and the label both need to fall back rather than invent a
// name for "xx".
function languageInfo(code) {
  var key = String(code === undefined || code === null ? "" : code).trim()
  if (LANGUAGES[key]) return LANGUAGES[key]
  if (SOURCE_ONLY_NAMES[key]) return { name: SOURCE_ONLY_NAMES[key], label: key.toUpperCase() }
  return null
}

function languageName(code) {
  var info = languageInfo(code)
  return info === null ? String(code || "") : info.name
}

function languageLabel(code) {
  var info = languageInfo(code)
  return info === null ? String(code || "") : info.label
}

// Normalises whatever the config holds into a code the prompt can use. An
// empty or unknown code means "no default": the model decides (see
// defaultSystemPrompt). Case and separators are forgiven — "zh_TW", "ZH-tw".
function normalizeLang(code) {
  var key = String(code === undefined || code === null ? "" : code).trim()
    .replace(/_/g, "-").toLowerCase()
  if (key === "") return ""
  for (var i = 0; i < LANGUAGE_ORDER.length; i++) {
    if (LANGUAGE_ORDER[i].toLowerCase() === key) return LANGUAGE_ORDER[i]
  }
  for (var src in SOURCE_ONLY_NAMES) {
    if (src === key) return src
  }
  return key
}

// ----------------------------------------------------------- detection
//
// A script-level guess at what the text is written in, which decides the
// direction the label shows and the direction the prompt states. It is
// deliberately cheap and dependency-free: the model is still the authority on
// the language of a sentence, and this only has to be right about which way
// round the pair is.
//
// Counting characters by script rather than matching words is what makes it
// work for any language in a script it knows, without a dictionary: 100
// characters of Thai are as recognisable as 100 of Cyrillic.

// Ranges are [start, end] pairs. `weight` lets a script count for more than
// one character when it is highly diagnostic (Hangul syllables are almost
// always Korean) and for less when it is shared (Latin, Cyrillic, Arabic).
var SCRIPT_RANGES = [
  // CJK ideographs: shared by Chinese and Japanese.
  { code: "zh", weight: 1, ranges: [[0x4E00, 0x9FFF], [0x3400, 0x4DBF], [0xF900, 0xFAFF]] },
  // Hiragana and katakana are Japanese only — and anything kana in the text is
  // what makes a Japanese sentence label as Japanese rather than Chinese.
  { code: "ja", weight: 1, ranges: [[0x3040, 0x309F], [0x30A0, 0x30FF]] },
  { code: "ko", weight: 1.5, ranges: [[0xAC00, 0xD7AF], [0x1100, 0x11FF], [0x3130, 0x318F]] },
  { code: "ru", weight: 1, ranges: [[0x0400, 0x04FF]] },
  { code: "ar", weight: 1, ranges: [[0x0600, 0x06FF], [0x0750, 0x077F], [0xFB50, 0xFDFF], [0xFE70, 0xFEFF]] },
  { code: "th", weight: 1, ranges: [[0x0E00, 0x0E7F]] },
  { code: "hi", weight: 1, ranges: [[0x0900, 0x097F]] },
  // Latin, weighed in at the bottom of latinLanguage() instead of by count.
  { code: "la", weight: 0, ranges: [[0x0041, 0x005A], [0x0061, 0x007A], [0x00C0, 0x024F]] }
]

// Latin text needs more than a script check: the same letters carry a dozen
// languages. These are each language's most frequent function words — the one
// kind of vocabulary a language does not share freely with its neighbours.
// Deliberately orthogonal: "en" leaves out "in"/"a"/"no" (shared with half the
// list), and each list is built around words the others do not use. Cognates
// ("in", "de", "la") are the enemy here: they make every language look like
// every other one, and a tiny list of diagnostics beats a long one.
var LATIN_STOPWORDS = {
  en: ["the", "and", "is", "are", "was", "were", "of", "to", "it", "that", "this", "with", "for", "you", "have", "not", "but", "be", "as", "at", "by", "from", "they", "we", "will", "would", "what", "when", "how", "there", "which", "been", "had", "about", "than", "then", "its", "if", "or", "because", "into", "your", "should", "could", "just"],
  es: ["el", "los", "las", "que", "es", "en", "un", "una", "por", "con", "para", "no", "se", "su", "al", "como", "más", "pero", "este", "esta", "son", "del", "lo", "muy", "también", "cuando", "porque", "todo", "hay", "sin", "sobre", "entre", "donde", "puede", "sus"],
  fr: ["les", "des", "et", "est", "une", "du", "que", "pour", "dans", "pas", "sur", "avec", "ce", "cette", "il", "elle", "nous", "vous", "sont", "au", "aux", "par", "mais", "plus", "tout", "qui", "comme", "leur", "ses", "était", "être", "aussi", "très", "quand", "parce", "sans", "entre", "où", "peut", "comment", "monde"],
  de: ["der", "die", "das", "und", "ist", "nicht", "ein", "eine", "zu", "den", "von", "mit", "sich", "auf", "für", "im", "dem", "des", "auch", "es", "werden", "wird", "bei", "oder", "aus", "als", "aber", "noch", "nur", "wie", "wenn", "kann", "sind", "wir", "sie", "ich", "haben", "hat", "wurde", "über", "durch", "sehr", "dass"],
  pt: ["os", "as", "que", "do", "da", "em", "um", "uma", "com", "não", "se", "por", "mais", "como", "mas", "seu", "sua", "é", "são", "ao", "dos", "muito", "também", "quando", "porque", "todo", "há", "sem", "sobre", "entre", "onde", "pode", "seus", "isso", "você"],
  it: ["il", "le", "di", "che", "un", "una", "per", "con", "non", "del", "della", "sono", "è", "come", "più", "anche", "si", "su", "da", "al", "lo", "gli", "ma", "questo", "questa", "essere", "era", "molto", "quando", "perché", "senza", "tra", "dove", "può", "suo", "sua"],
  id: ["yang", "dan", "di", "ke", "dari", "ini", "itu", "dengan", "untuk", "tidak", "adalah", "saya", "anda", "akan", "ada", "dalam", "pada", "juga", "kita", "mereka", "banyak", "atau", "saat", "sudah"],
  tr: ["bir", "ve", "bu", "için", "ile", "değil", "olarak", "çok", "daha", "var", "olan", "gibi", "ama", "ben", "sen", "kadar", "sonra", "çünkü", "her"],
  nl: ["het", "een", "en", "van", "dat", "niet", "op", "te", "met", "voor", "zijn", "aan", "er", "ook", "maar", "bij", "om", "worden", "wordt", "deze", "die", "kan", "nog", "wel", "als", "dan"],
  pl: ["się", "jest", "że", "jak", "dla", "ale", "po", "od", "tym", "tak", "już", "oraz", "przez", "który", "która", "może", "tylko", "bardzo", "gdy"],
  vi: ["và", "là", "của", "có", "không", "được", "trong", "cho", "một", "này", "với", "người", "các", "những", "để", "như", "rất", "cũng", "nhưng", "khi", "vì", "đã", "sẽ", "nên"],
  uk: ["і", "що", "з", "до", "це", "як", "для", "але", "по", "від", "так", "вже", "який", "яка", "мене", "мені", "може", "щоб", "тому", "дуже", "тільки"]
}

// Spelling that no other language on the list uses — one of these in the text
// is worth several function words, because it is not a coincidence. Matched
// against the whole text, so a phrase or a diacritic pattern both fit.
var LATIN_TELLS = [
  { code: "de", pattern: /[äöüß]|\b(ich|nicht|und|sie|wir|mit|auf|ist)\b/ },
  { code: "pt", pattern: /[ãõ]|\b(não|você|obrigado|muito|também|é)\b/ },
  { code: "es", pattern: /[ñ¿¡]|\b(está|años|también|estoy|usted)\b/ },
  { code: "fr", pattern: /[àèùâêîôûëïüÿœæç]|\b(c'est|j'ai|n'est|qu'il|très|être)\b/ },
  { code: "tr", pattern: /[ğış]|\b(değil|için|bir|ve)\b/ },
  { code: "vi", pattern: /[ơưđạảấầẩẫậắằẳẵặẹẻẽếềểễệịỉọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/ },
  { code: "pl", pattern: /[ąćęłńóśźż]|\b(się|jest|które|która|który)\b/ },
  { code: "it", pattern: /\b(è|sono|questo|questa|anche|perché|più|gli)\b/ }
]

// Text with the parts that are not the author's language taken out: URLs,
// code, HTML tags and attributes, and Markdown syntax. Detection is a density
// measurement, so a handful of foreign-looking tokens can outvote a whole
// paragraph when the passage is short — "参考 https://example.com/docs 这个页面。"
// used to score Portuguese because `a` sat inside the URL, and
// "运行 `npm run build` 即可。" used to score English on three command words.
//
// Done in one pass with ordered rules rather than a chain of replaces: a URL
// inside a code span has to disappear as code, and a Markdown link has to lose
// its target without losing its label.
var NON_LANGUAGE_PATTERNS = [
  // Fenced blocks first: everything inside is code, including what looks like
  // prose. Unterminated fences are common in a stream, hence the `$` branch.
  /```[\s\S]*?(?:```|$)/g,
  /~~~[\s\S]*?(?:~~~|$)/g,
  // Inline code, backticks paired or not.
  /`[^`\n]*`/g,
  // URLs before link syntax, so the URL inside `[label](url)` is gone by the
  // time the label is unwrapped. Bare www hosts too, with or without scheme.
  /\b(?:https?|ftp|file):\/\/[^\s<>()[\]{}"']+/gi,
  /\bwww\.[^\s<>()[\]{}"']+/gi,
  // Email addresses.
  /[\w.+-]+@[\w-]+\.[\w.-]+/g,
  // HTML/XML tags, with their attributes, and HTML entities.
  /<\/?[a-zA-Z][^>]*>/g,
  /&(?:#\d+|#x[\da-fA-F]+|[a-zA-Z]+);/g,
  // Images: the alt text is a caption, not the passage, and is often a slug.
  /!\[[^\]]*\]\([^)]*\)/g,
  // Links keep their label, drop the target: `[label](target)` -> `label`.
  /\[([^\]]*)\]\([^)]*\)/g,
  // Reference-style link definitions and bare autolinks.
  /^\s*\[[^\]]+\]:\s*\S+.*$/gm,
  /<[^\s@>]+@[^\s@>]+>/g,
  // Bare paths and file names: /usr/local/bin, C:\Users, package.json, v1.2.3.
  /\b[a-zA-Z]:\\[^\s]*/g,
  /(?:^|[\s(])(?:\/[\w.@-]+){2,}\/?/g,
  /\b[\w-]+\.(?:json|ya?ml|toml|md|txt|js|ts|jsx|tsx|css|scss|html?|py|rs|go|sh|lock|log|conf|ini|xml|svg|png|jpe?g|gif|pdf|zip)\b/gi,
  // Version numbers and standalone hex colours: digits and letters, no words.
  /\bv?\d+(?:\.\d+)+[\w.-]*/gi,
  /#[\da-fA-F]{3,8}\b/g
]

function stripNonLanguage(text) {
  var s = String(text === undefined || text === null ? "" : text)
  if (s === "") return ""
  // Underscores and asterisks are Markdown emphasis *and* code characters; a
  // word wrapped in them (__init__, _private) is an identifier, so drop the
  // word rather than leaving a fragment behind for the stopword lists.
  s = s.replace(/\b_{1,2}[\w]+_{1,2}\b/g, " ")
  s = s.replace(/\b_{1,2}\w+\b|\b\w+_{1,2}\b/g, " ")
  for (var i = 0; i < NON_LANGUAGE_PATTERNS.length; i++) {
    s = s.replace(NON_LANGUAGE_PATTERNS[i], i === 9 || i === 10 ? "$1" : " ")
  }
  return s
}

function latinWords(text) {
  var s = String(text === undefined || text === null ? "" : text).toLowerCase()
  // Apostrophes are part of a word (l'été, don't); hyphens split it, since a
  // compound is usually two words for this purpose.
  return s.split(/[^a-z\u00c0-\u024f'\u0300-\u036f]+/).filter(function (w) { return w.length > 0 })
}

// Word lists are indexed once, not scanned per lookup: detection runs on every
// keystroke in input mode.
function indexWords(list) {
  var out = {}
  for (var i = 0; i < list.length; i++) out[list[i]] = true
  return out
}

var _wordIndex = null
function wordIndex() {
  if (_wordIndex === null) {
    _wordIndex = {}
    for (var code in LATIN_STOPWORDS) _wordIndex[code] = indexWords(LATIN_STOPWORDS[code])
  }
  return _wordIndex
}

// Which Latin language the text is in, and how sure. The score is
//   (distinct function words + 2 × tells) / the number of words
// — a *density*, not a count, which is what lets three words ("das ist nicht")
// decide without letting a hundred words of one language drown in a hundred
// ambiguous ones. A tie goes to English, which is the most common source and
// the language a Latin-script text is likeliest to be.
function latinLanguage(text) {
  var lower = String(text === undefined || text === null ? "" : text).toLowerCase()
  var words = latinWords(lower)
  var index = wordIndex()
  var hits = {}
  var i, code

  // One hit per distinct word: "the the the" says no more than "the".
  var seen = {}
  for (i = 0; i < words.length; i++) {
    var w = words[i]
    if (seen[w]) continue
    seen[w] = true
    for (code in index) {
      if (index[code][w]) hits[code] = (hits[code] || 0) + 1
    }
  }
  for (i = 0; i < LATIN_TELLS.length; i++) {
    if (LATIN_TELLS[i].pattern.test(lower)) hits[LATIN_TELLS[i].code] = (hits[LATIN_TELLS[i].code] || 0) + 1.5
  }

  var best = "en"
  var bestScore = 0
  var total = Math.max(1, words.length)
  for (code in hits) {
    var score = hits[code] / total
    if (score > bestScore) {
      best = code
      bestScore = score
    }
  }
  return { code: best, score: bestScore, words: words.length, hits: hits }
}

// The detected source language, as a code, or "" when there is no signal at
// all (empty text, or nothing but digits and emoji).
function detectLang(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  if (raw.trim() === "") return ""

  // Script counts run on the cleaned text too: a URL is Latin letters, and
  // counting them as Latin script was half of the same bug the word lists had.
  // CJK, kana and the rest are never inside a URL or a tag, so nothing that
  // matters is lost.
  var s = stripNonLanguage(raw)
  var noWords = s.trim() === ""
  // Nothing but URLs or code: count the raw text, so the verdict is "Latin,
  // unknown which" rather than "no language at all". The word lists still get
  // the empty string, so the hostname's `a` cannot become a stopword hit.
  var scriptText = noWords ? raw : s

  var counts = {}
  var latin = 0
  for (var i = 0; i < scriptText.length; i++) {
    var c = scriptText.charCodeAt(i)
    // Surrogate pairs are astral planes (emoji, rare ideographs): neither is a
    // language signal, and counting half of a pair would be arbitrary.
    if (c >= 0xD800 && c <= 0xDFFF) continue
    for (var r = 0; r < SCRIPT_RANGES.length; r++) {
      var range = SCRIPT_RANGES[r]
      var hit = false
      for (var k = 0; k < range.ranges.length; k++) {
        if (c < range.ranges[k][0] || c > range.ranges[k][1]) continue
        hit = true
        break
      }
      if (!hit) continue
      if (range.code === "la") latin++
      else counts[range.code] = (counts[range.code] || 0) + range.weight
      break
    }
  }

  // Kana anywhere outranks the ideographs Japanese shares with Chinese: most
  // of a Japanese sentence is kanji, but the kana are the proof.
  if (counts.ja) return "ja"

  var bestScript = ""
  var bestScore = 0
  var cjk = 0
  for (var key in counts) {
    if (key === "zh") cjk = counts[key]
    if (counts[key] > bestScore) {
      bestScript = key
      bestScore = counts[key]
    }
  }

  if (latin > 0) {
    // Nothing survived stripping (a bare URL, a code block): there is no word
    // evidence left to weigh, and tokenising the raw text would score the
    // hostname's `a` as Portuguese. The script alone is the honest answer.
    if (noWords) return "en"
    var guess = latinLanguage(s)
    // Latin is weighed by character count, not by confidence, because it
    // shares its alphabet: "hello 你好" has no word-list hit at all and still
    // has to lose to two ideographs. The margin is not 1:1 either — a word or
    // two of Latin inside a Chinese sentence is terminology, not the language
    // ("React 是用于构建界面的库" is Chinese), while one Cyrillic word inside
    // English ("the word привет means hi") is still English.
    var latinScore = guess.score + latin * 0.3
    if (bestScript === "" || (latinScore > bestScore && latin >= cjk * 0.2)) return guess.code
    // One Cyrillic word quoted inside an English sentence is still English:
    // the quoted word is a specimen, not the language being used. Function,
    // not raw counts — "the word привет means hi" is 23 Latin characters to 6
    // Cyrillic, while a genuinely mixed sentence leans the other way.
    if (latin >= 1.5 * (s.length / Math.max(1, s.split(/\s+/).length)) &&
        latin > 1.5 * bestScore) return guess.code
  }
  // Digits, punctuation and emoji only: no language signal at all.
  return bestScript
}

// The language a translation is going *to*, given the source. The default
// target wins unless it is the source's own language — translating English to
// English is never what was asked, so that case falls back to the built-in
// pair (Chinese <-> English). `defaultLang` "" means the built-in pair only.
function targetLang(sourceLang, defaultLang) {
  var src = normalizeLang(sourceLang)
  var def = normalizeLang(defaultLang)
  if (def === "" || def === src) {
    // The built-in rule: Chinese in, English out, everything else to Chinese.
    return (src === "zh" || src === "zh-TW") ? "en" : "zh"
  }
  return def
}

// The compact "source → target" label the bubble shows. Empty source (no
// text yet) shows only the destination. The labels are short on purpose: this
// sits in a 20px header row next to two buttons.
function directionLabel(sourceLang, defaultLang) {
  var src = normalizeLang(sourceLang)
  var dst = targetLang(src, defaultLang)
  var dstLabel = languageLabel(dst)
  if (src === "") return "→ " + dstLabel
  return languageLabel(src) + " → " + dstLabel
}

// Translation, not conversation. The direction rules are generated from the
// detected source and the resolved target rather than left to the model's
// judgement: the prompt states the direction the label shows, so the two
// cannot disagree at the margin. Without a default target the model gets the
// original Chinese/English pair and decides "predominantly" itself.
//
// The "only the translation" line is what keeps a bubble from filling with
// commentary; it is not negotiable by a prompt override below.
function builtInSystemPrompt(sourceLang, targetCode) {
  var code = targetCode === undefined || targetCode === null || targetCode === "" ? "zh" : targetCode
  var target = languageName(code)
  var src = normalizeLang(sourceLang)
  // The source is named only when it is a language we can actually name
  // *and* it is not the target: "translate English into English" would be an
  // instruction to do nothing.
  var direction = src === "" || languageInfo(src) === null || languageName(src) === target
    ? "- Translate the text into " + target + "."
    : "- The text is in " + languageName(src) + ". Translate it into " + target + "."

  return [
    "You are a translation engine. Translate the user's text and output only the translation.",
    "",
    direction,
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
}

// The prompt with no direction information at all — what the tests and an
// unconfigured caller get. Equivalent to the pre-language-setting behaviour.
function defaultSystemPrompt(targetCode) {
  return builtInSystemPrompt("", targetCode || "zh")
}

// What actually goes to the model: a configured prompt wins, with `{{lang}}`
// standing for the target language's name (and `{{source}}` for the detected
// one). Without the placeholder the configured prompt is appended *after* the
// built-in direction rules, so a user's own house style cannot silently
// remove the one instruction this plugin exists for. The empty-config case
// reproduces the built-in prompt exactly.
function systemPrompt(config, sourceLang, targetCode) {
  var custom = String((config && config.systemPrompt) || "").trim()
  var source = normalizeLang(sourceLang)
  var target = targetCode === undefined || targetCode === null || targetCode === "" ? "zh" : targetCode
  if (custom === "") return builtInSystemPrompt(source, target)

  if (custom.indexOf("{{lang}}") !== -1 || custom.indexOf("{{source}}") !== -1) {
    // Fully templated: the user has taken responsibility for the direction.
    return custom
      .replace(/\{\{lang\}\}/g, languageName(target))
      .replace(/\{\{source\}\}/g, source === "" ? "the detected language" : languageName(source))
  }
  return builtInSystemPrompt(source, target) + "\n\n" + custom
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
//
// sourceLang / targetCode decide the direction clause of the prompt (see
// builtInSystemPrompt). Leaving them out keeps the old behaviour: no source
// named, Chinese as the target.
//
// systemSuffix (optional) is appended to the system prompt: the verbatim-echo
// retry uses it to nudge a lazy model without rebuilding the prompt.
function buildBody(config, text, systemSuffix, sourceLang, targetCode) {
  var system = systemPrompt(config, sourceLang, targetCode)
  if (systemSuffix !== undefined && systemSuffix !== null && String(systemSuffix) !== "") {
    system = system + "\n\n" + String(systemSuffix)
  }

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

// Cap the request size: a whole-page rich capture can be tens of thousands
// of characters, which burns tokens and risks the provider's context limit.
// Never splits a surrogate pair at the cut — a dangling lead surrogate would
// serialise as U+FFFD and confuse the model's tokeniser.
function truncateText(text, maxChars) {
  var s = String(text === undefined || text === null ? "" : text)
  var max = Math.floor(Number(maxChars))
  if (!(max > 0) || s.length <= max) return s
  var cut = s.substring(0, max)
  var last = cut.charCodeAt(cut.length - 1)
  if (last >= 0xD800 && last <= 0xDBFF) cut = cut.substring(0, cut.length - 1)
  return cut
}

// Stable key for the in-memory request cache: the same text through the same
// model, prompt and direction is the same request, whatever mode captured it —
// hence the caller-supplied tag (selection/input/ocr, plus the rich marker).
// The direction is part of it because switching the target language must
// re-ask, not replay the previous answer.
//
// djb2 over the parts: collisions across a handful of entries are a
// non-issue, and the 32-bit shifts keep it exact without Math.imul.
function cacheKey(tag, config, text, sourceLang, targetCode) {
  var system = systemPrompt(config, sourceLang, targetCode)
  var s = String(tag || "") + "\n" + String((config && config.model) || "") + "\n" +
      system + "\n" + String(text === undefined || text === null ? "" : text)
  var h = 5381
  for (var i = 0; i < s.length; i++) {
    h = (((h << 5) + h) + s.charCodeAt(i)) >>> 0
  }
  return h.toString(16)
}

// Detects a model echo: the "translation" is the input verbatim. URLs are
// excluded — keeping them unchanged is by design. Everything else identical
// counts: a false positive (a proper noun correctly left alone) costs one
// retry that confirms it, while a false negative is the bug this exists for.
// Whitespace is ignored: a model that merely re-wraps the input still echoed.
function isVerbatimEcho(input, output) {
  var a = String(input === undefined || input === null ? "" : input).replace(/\s+/g, "")
  var b = String(output === undefined || output === null ? "" : output).replace(/\s+/g, "")
  if (a === "" || b === "" || a !== b) return false
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(String(input).trim())) return false
  return true
}

// Appended to the system prompt for the echo retry: the model already proved
// it will repeat the input unless told not to. The direction comes from the
// same resolver as the prompt, so a retry can never nudge toward a language
// the prompt did not ask for.
function echoNudge(targetCode) {
  return [
    "Your previous response repeated the user's input verbatim instead of",
    "translating it. Translate the text into " +
      languageName(targetCode === undefined || targetCode === null || targetCode === "" ? "zh" : targetCode) + ".",
    "Output only the translation."
  ].join(" ")
}

// The default nudge, in the pre-language-setting direction (Chinese).
var ECHO_NUDGE = echoNudge("zh")

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
// Escape one chunk of complete lines, carrying fence state across calls so a
// caller can escape a growing stream incrementally: only the new lines go
// through here, and the trailing partial line (no "\n" yet) is escaped
// separately without committing fence state — a fence opener split across two
// flushes must not flip the state early. Returns
// {text, fenceChar, fenceLen}.
function escapeHtmlLines(chunk, fenceChar, fenceLen) {
  var lines = String(chunk === undefined || chunk === null ? "" : chunk).split("\n")
  var out = []
  var fc = fenceChar || ""
  var fl = fenceLen || 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var fence = line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (fence) {
      var mark = fence[1]
      var ch = mark.charAt(0)
      var rest = line.substring(fence[0].length)
      if (fc === "") {
        fc = ch
        fl = mark.length
      } else if (ch === fc && mark.length >= fl && rest.trim() === "") {
        fc = ""
        fl = 0
      }
      out.push(line)
      continue
    }
    out.push(fc === "" ? escapeCodeSpans(line) : line)
  }
  return { text: out.join("\n"), fenceChar: fc, fenceLen: fl }
}

function escapeHtmlTags(text) {
  return escapeHtmlLines(text, "", 0).text
}

// A Markdown table cannot be handed to Text.MarkdownText in this bubble.
//
// Qt's Markdown importer builds a QTextTable for it, and re-laying that table
// out when the text changes again corrupts the scene graph: the next frame
// dies in QSGBatchRenderer::Renderer::prepareAlphaBatches (SIGSEGV). It is not
// specific to huge tables — a two-column table of 22 rows takes the shell down
// on the first re-layout, and a streaming translation re-lays out ten times a
// second. A single, final layout survives, which is why this only ever showed
// up while translating.
//
// So tables are flattened before rendering: one list item per row, cells
// separated by an em dash, the delimiter row dropped. The structure survives
// (the header row becomes the first item) and MarkdownText never sees a table.
// Rows are only recognised outside fenced code blocks, where table syntax is
// sample text and must stay literal.
function flattenTables(text) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var out = []
  var fence = ""
  var i = 0
  while (i < lines.length) {
    var line = lines[i]
    var fenceMark = line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (fenceMark) {
      var mark = fenceMark[1]
      var rest = line.substring(fenceMark[0].length)
      if (fence === "") fence = mark
      else if (mark.charAt(0) === fence.charAt(0) && mark.length >= fence.length && rest.trim() === "") fence = ""
      out.push(line)
      i++
      continue
    }
    if (fence === "") {
      var head = splitTableRow(line)
      var delim = i + 1 < lines.length ? splitTableRow(lines[i + 1]) : null
      if (head.length > 0 && delim && delim.length > 0 && isDelimiterRow(delim)) {
        out.push(tableRowToItem(head))
        i += 2
        while (i < lines.length) {
          var row = splitTableRow(lines[i])
          if (row.length === 0) break
          out.push(tableRowToItem(row))
          i++
        }
        continue
      }
    }
    out.push(line)
    i++
  }
  return out.join("\n")
}

// One table line -> its cells. An empty array means "not a table row": no
// unescaped pipe outside a code span. `\|` is an escaped pipe and stays inside
// the cell; a pipe inside `code` is content, not a separator.
function splitTableRow(line) {
  var s = String(line === undefined || line === null ? "" : line)
  var cells = []
  var cur = ""
  var sawPipe = false
  var i = 0
  var n = s.length
  while (i < n) {
    var ch = s.charAt(i)
    if (ch === "\\" && s.charAt(i + 1) === "|") {
      cur += "|"
      i += 2
      continue
    }
    if (ch === "`") {
      var runStart = i
      while (i < n && s.charAt(i) === "`") i++
      var runLen = i - runStart
      var close = -1
      var j = i
      while (j < n) {
        if (s.charAt(j) === "`") {
          var k = j
          while (k < n && s.charAt(k) === "`") k++
          if (k - j === runLen) { close = j; break }
          j = k
        } else {
          j++
        }
      }
      if (close === -1) {
        cur += s.substring(runStart)
        i = n
        break
      }
      cur += s.substring(runStart, close + runLen)
      i = close + runLen
      continue
    }
    if (ch === "|") {
      sawPipe = true
      cells.push(cur)
      cur = ""
      i++
      continue
    }
    cur += ch
    i++
  }
  cells.push(cur)
  if (!sawPipe) return []
  // The pipes that frame the row produce an empty cell at each end.
  if (cells.length > 1 && cells[0].trim() === "") cells.shift()
  if (cells.length > 1 && cells[cells.length - 1].trim() === "") cells.pop()
  var nonEmpty = false
  for (var c = 0; c < cells.length; c++) if (cells[c].trim() !== "") nonEmpty = true
  return nonEmpty ? cells : []
}

// The `| --- | :---: |` line that makes the line above it a header rather than
// prose with pipes in it.
function isDelimiterRow(cells) {
  for (var i = 0; i < cells.length; i++) {
    if (!/^:?-+:?$/.test(cells[i].trim())) return false
  }
  return true
}

function tableRowToItem(cells) {
  var parts = []
  for (var i = 0; i < cells.length; i++) {
    var cell = cells[i].trim()
    if (cell !== "") parts.push(cell)
  }
  return "- " + parts.join(" — ")
}

// A translation cut into renderable blocks: prose that Text.MarkdownText can
// draw, and tables that it must not (see flattenTables). One entry per block,
// in reading order:
//
//   { kind: "md", text: "## Files\n\nhttps://…" }
//   { kind: "table", header: ["File", "Purpose"], rows: [["`SKILL.md`", "…"]] }
//
// The header row is split out of `rows` because it is drawn differently; the
// `| --- |` line is the only thing the parser throws away. Fenced code blocks
// are never read as tables — a table in a code sample is literal text.
function splitBlocks(text) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var blocks = []
  var buf = []
  var fence = ""
  var i = 0

  function flush() {
    if (buf.length === 0) return
    var text = buf.join("\n").replace(/^\n+/, "").replace(/\n+$/, "")
    buf = []
    if (text.trim() !== "") blocks.push({ kind: "md", text: text })
  }

  while (i < lines.length) {
    var line = lines[i]
    var fenceMark = line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (fenceMark) {
      var mark = fenceMark[1]
      var rest = line.substring(fenceMark[0].length)
      if (fence === "") fence = mark
      else if (mark.charAt(0) === fence.charAt(0) && mark.length >= fence.length && rest.trim() === "") fence = ""
      buf.push(line)
      i++
      continue
    }
    if (fence === "") {
      var head = splitTableRow(line)
      var delim = i + 1 < lines.length ? splitTableRow(lines[i + 1]) : null
      if (head.length > 0 && delim && delim.length > 0 && isDelimiterRow(delim)) {
        flush()
        var rows = []
        i += 2
        while (i < lines.length) {
          var row = splitTableRow(lines[i])
          if (row.length === 0) break
          rows.push(row.map(function (cell) { return cell.trim() }))
          i++
        }
        blocks.push({ kind: "table", header: head.map(function (cell) { return cell.trim() }), rows: rows })
        continue
      }
    }
    buf.push(line)
    i++
  }
  flush()
  return blocks
}

// How wide one cell "wants" to be, in em: full-width CJK counts as 1, anything
// else as 0.55. Backticks are markup, not ink. Used only to split the card's
// width between columns, so an estimate is enough — every cell wraps anyway.
function textWeight(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/`/g, "")
  var w = 0
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    w += (c > 0x2e7f && c < 0xa000) || (c >= 0xff01 && c <= 0xff60) ? 1 : 0.55
  }
  return w
}

// Column widths for a table, in whole pixels that add up to `available`.
// Each column asks for the widest cell it holds; a column below `minColumn`
// is topped up from the ones with room to spare, and no column may take more
// than 60% of the row — a wide description column must not squeeze a label
// column into mid-word wrapping.
function tableWidths(header, rows, available, minColumn) {
  var head = header || []
  var body = rows || []
  var columns = head.length
  var i, j
  for (i = 0; i < body.length; i++) columns = Math.max(columns, body[i].length)
  if (columns <= 0) return []

  var avail = Math.max(1, Math.floor(Number(available) || 0))
  var min = Math.max(1, Math.floor(Number(minColumn) || 0))

  var weights = []
  for (j = 0; j < columns; j++) weights.push(0)
  for (j = 0; j < columns; j++) weights[j] = Math.max(weights[j], textWeight(head[j]))
  for (i = 0; i < body.length; i++) {
    for (j = 0; j < columns; j++) weights[j] = Math.max(weights[j], textWeight(body[i][j]))
  }
  var total = 0
  for (j = 0; j < columns; j++) {
    // A header of dashes or an empty column still needs room for its border
    // and a couple of characters.
    weights[j] = Math.max(weights[j], 2)
    total += weights[j]
  }

  var px = []
  for (j = 0; j < columns; j++) px.push(avail * weights[j] / total)

  if (min * columns >= avail) {
    // Too many columns for the card: equal shares, minColumn cannot be honoured.
    for (j = 0; j < columns; j++) px[j] = avail / columns
  } else {
    // 1. Top up columns narrower than the minimum, taking the pixels from the
    //    ones with room to spare.
    var deficit = 0
    var flexible = 0
    for (j = 0; j < columns; j++) {
      if (px[j] < min) {
        deficit += min - px[j]
        px[j] = min
      } else {
        flexible += px[j]
      }
    }
    if (deficit > 0 && flexible > deficit) {
      var scale = (flexible - deficit) / flexible
      for (j = 0; j < columns; j++) if (px[j] > min) px[j] *= scale
    }

    // 2. Cap the widest column so a huge description cannot squeeze the rest.
    //    The pixels it gives up go to the other columns (growing them past
    //    their minimum if needed) — with two columns a hard cap is otherwise
    //    impossible, and a balanced 40/60 beats 20/80. A single-column table
    //    fills the row by definition.
    if (columns > 1) {
      var cap = Math.max(min, avail * 0.6)
      for (var pass = 0; pass < 2; pass++) {
        var excess = 0
        var room = 0
        for (j = 0; j < columns; j++) {
          if (px[j] > cap) {
            excess += px[j] - cap
            px[j] = cap
          }
        }
        for (j = 0; j < columns; j++) if (px[j] < cap) room += px[j]
        if (excess === 0 || room === 0) break
        for (j = 0; j < columns; j++) {
          if (px[j] < cap) px[j] += excess * px[j] / room
        }
      }
    }
  }

  var out = []
  var used = 0
  for (j = 0; j < columns; j++) {
    out.push(Math.floor(px[j]))
    used += out[j]
  }
  // Integer widths must still fill the row exactly, or the right border falls
  // short of the card edge. The spare pixels go back in proportionally, one
  // pixel at a time to the widest column first.
  var order = []
  for (j = 0; j < columns; j++) order.push(j)
  order.sort(function (a, b) { return out[b] - out[a] })
  var rest = avail - used
  for (j = 0; rest > 0; j++) {
    out[order[j % columns]] += 1
    rest--
  }
  return out
}

// Everything Table.qml needs, flattened so the QML side stays a plain Repeater
// over one array: GridLayout reads `columns`, the repeater reads `cells`, and
// each cell carries its own width and its edges' "am I on the border" flags.
function tableGrid(header, rows, available, minColumn) {
  var head = header || []
  var body = rows || []
  var columns = head.length
  var i, j
  for (i = 0; i < body.length; i++) columns = Math.max(columns, body[i].length)
  if (columns <= 0) return { columns: 0, rows: 0, widths: [], cells: [] }

  var widths = tableWidths(head, body, available, minColumn)
  var cells = []

  function pushRow(cellsOfRow, isHeader) {
    for (var c = 0; c < columns; c++) {
      cells.push({
        text: String(cellsOfRow[c] === undefined || cellsOfRow[c] === null ? "" : cellsOfRow[c]).trim(),
        width: widths[c],
        header: isHeader,
        lastColumn: c === columns - 1,
        lastRow: false,
        column: c
      })
    }
  }

  pushRow(head, true)
  for (i = 0; i < body.length; i++) pushRow(body[i], false)
  for (i = cells.length - columns; i < cells.length; i++) cells[i].lastRow = true

  return { columns: columns, rows: body.length + 1, widths: widths, cells: cells }
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
