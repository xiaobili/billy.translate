# Changelog

## 0.5.1

Fix: a rich pick left the clipboard as plain text. `wl-copy` takes one MIME
type per invocation and every invocation becomes the selection owner, so
restoring `text/html` and then `text/plain` leaves only the plain types. The
backup had the HTML; there was simply no way to offer it alongside the text.
The restore now hands every captured flavour to `bin/clipboard-write`, which
offers them all in a single selection.

- `bin/clipboard-write` (new): a small `zwlr_data_control_v1` client, stdlib
  Python only. That protocol's `set_selection` takes no serial, so owning the
  selection needs no surface and no input focus — which is what makes this
  possible from a script. It offers N types at once and serves `send` requests
  until something else takes the selection. Forks into the background like
  `wl-copy` and drops the inherited stdio, so the QML `Process` that reads
  pick-text's stdout is not held open by the owner.
- It re-adds `UTF8_STRING` / `STRING` / `TEXT` beside the `text/plain` payload.
  `wl-copy` with no `--type` offered those implicitly; restoring through a
  single `--type` would have left XWayland apps with nothing to paste.
- A flavour whose payload is empty is skipped rather than offered: a client
  picks the type first and only then learns there is nothing there.
- The old wl-copy path is kept as a fallback — no `zwlr_data_control_v1`, or
  the writer exits non-zero — so compositors without the protocol behave
  exactly as before.
- Two wire-level details worth recording, both found by measuring rather than
  reading: client object ids have to start at 2 and be handed out in the order
  the requests are sent (`wl_display.sync` must come *after* `get_registry`, or
  its callback fires before the globals are announced), and arguments are
  separated with `:` because a MIME type can contain `=` — `text/plain;charset=
  utf-8` would otherwise split inside the type name.
- Tests: 6 new cases (39 in `tests/scripts.test.sh`), verified by mutation —
  never using the writer fails 4, offering empty flavours fails 1, handing over
  only the first flavour fails 1, one call per flavour fails 1.

## 0.5.0

New chord: `ALT + SHIFT + I` opens the same input field as `ALT + I` but
renders the answer as Markdown. `ALT + I` is now the plain one — it shows the
translation verbatim, like `ALT + D` and `ALT + O` already did. Markdown
rendering is opt-in per *hotkey* from now on, never inferred from the mode: the
mode alone cannot tell the two input chords apart, and it could not tell the
two selection chords apart either.

- The input field is unchanged apart from rendering: same draft, same Enter /
  Shift+Enter, same re-translate. Pressing the chord that is already open
  dismisses the bubble; pressing the other input chord switches the open bubble
  over, keeping the text in the field.
- The request sent to the model is identical between the two input chords —
  only the rendering differs — so switching re-renders what is already on
  screen instead of asking again.
- `richPick` is now `rich`: one flag for "opened through a rich chord", shared
  by both modes, instead of a selection-only one next to a second flag for
  input. Which combinations render Markdown lives in
  `Translate.rendersMarkdown(mode, rich)` — a pure function, so it can be
  asserted on directly rather than sitting in a QML binding.
- Behaviour change worth knowing: a Markdown table typed into `ALT + I` now
  reads as `| a | b |` instead of a drawn grid. `ALT + SHIFT + I` brings the
  grid back.
- Tests: 9 new cases (175 in `tests/translate.test.js`), verified by mutation —
  restoring the old "input always renders" rule fails 3, dropping the strict
  boolean check on `rich` fails 1, and letting `rich` into every mode fails 2.

## 0.4.2

Performance: `ALT + SHIFT + D` (rich pick) had roughly half a second of dead
time between the keypress and anything happening — the surface stays hidden
while picking, so all of it reads as lag. Profiling put every millisecond of it
in `bin/pick-text --rich`, none in the QML or the request. Five cuts:

- `preCopyDelayMs` default 350 → 150. This is the wait before synthesising
  Ctrl+C so the hotkey's own Alt/Shift are released first; 350 was the single
  largest item on the path and mostly padding. Releasing a chord takes tens of
  milliseconds. Raise it again if some app still sees a modified copy.
- The poll loop reads the clipboard *before* paying the poll interval instead
  of after, so a copy that landed during the pre-copy delay costs no interval
  at all.
- `restore()` no longer replays every captured MIME type when a text payload is
  going to be written anyway. Each `wl-copy` invocation *replaces* the whole
  clipboard offer rather than adding to it — writing text/html and then
  text/plain leaves no text/html behind — so those writes could only be
  overwritten by the text write that followed. The replay still runs when there
  is no text flavour at all, where it is the only thing that can restore
  anything.
- The three tuning knobs are read from `config.json` in one `jq` pass instead
  of one pass per knob.
- `html-to-markdown` runs python with `-S -E`. Skipping the `site` module
  removes ~120 ms of interpreter startup, and the script imports nothing but
  the standard library.

Measured end to end, interleaved against the previous code on the same
machine: rich path ~493 ms → ~391 ms for a copy that is ready immediately
(the code changes alone are worth 56–89 ms at matched settings); the failure
path where the app ignores the synthetic Ctrl+C, ~2.1 s → ~1.5 s. Absolute
numbers on this box swing with load, which is why the comparison is
interleaved rather than sequential.

Tests: 2 new cases in `tests/scripts.test.sh` (33 total), both verified by
mutation — reinstating the sleep-first loop fails one, reinstating the
per-type replay fails two.

## 0.4.1

- Fixed: Chinese read as Portuguese in rich mode (`ALT + SHIFT + D`). That mode
  hands in HTML converted to Markdown, so the text carries URLs, link targets,
  code spans, file names and HTML attributes — and detection is a *density*
  measurement, where a few foreign tokens outvote a short passage. `a` inside
  `https://example.com` was a Portuguese stopword hit at 0.33 density, so
  "参考 https://example.com/docs 这个页面。" scored `pt`; "运行 `npm run build`
  即可。" scored `en` on three command words.
- Detection now runs on a cleaned copy of the text (`Translate.stripNonLanguage`):
  fenced and inline code, URLs, bare `www` hosts, e-mail addresses, HTML tags
  and entities, image alt text, link targets (labels are kept), reference
  definitions, file paths and bare file names, version numbers and hex colours.
  Script counting uses the cleaned text too, so URL letters no longer count as
  Latin script.
- A passage that is *only* a URL or a code block reports Latin with no
  language (`en`) rather than scoring the hostname's `a` as Portuguese.
- Tests: 12 new cases (166 total) covering each stripped construct; verified by
  mutation — bypassing the cleaning step fails 7 of them. Cost: 0.16 ms for a
  short line, 2.5 ms for a 4.4 KB rich-mode passage.

## 0.4.0

Languages:

- The Chinese↔English pair is gone as a hard-coded assumption. The source
  language is detected from the text itself (`Translate.detectLang`): Unicode
  script ranges for CJK, kana, Hangul, Cyrillic, Arabic, Thai and Devanagari,
  then stopword density plus characteristic spelling for Latin-script
  languages. No model call, so it costs nothing and works before the first
  token arrives.
- A default target language is now a setting (`targetLang` in `config.json`,
  `""` = the built-in pair). When the configured target turns out to be the
  detected source, the plugin falls back to the built-in pair instead of
  "translating" into the same language.
- The direction label in the card header is the picker: click it (or `Ctrl+L`)
  for a row of language chips, `Auto` first. Esc closes the picker before it
  closes the bubble. The card grows by a row or two while it is open and
  re-measures itself; starting a translation closes it.
- Twelve languages ship: Chinese (Simplified and Traditional), English,
  Japanese, Korean, Spanish, French, German, Russian, Portuguese, Italian,
  Arabic.
- The built-in prompt now states the direction explicitly, and custom prompts
  can interpolate `{{lang}}` / `{{source}}`. A custom prompt without
  placeholders is appended to the built-in rules rather than replacing them,
  so the echo guard and formatting rules still apply.
- The direction is part of the cache key, so the same text translated into two
  languages is no longer served from the wrong cache entry.
- Known limit: detection is heuristic. Short Latin-script strings ("OK",
  "Bonjour") can land on the wrong Romance/Germanic language, and mixed-script
  text falls back to whichever script dominates. A wrong guess is correctable
  from the picker.

Tests:

- 154 pure-function cases (was 107), covering detection across all twelve
  languages, mixed text, target resolution, prompt directions and templates,
  and the direction-aware cache key.
- Two new offscreen render checks in `tools/test.sh`. `tests/lang-render.qml`
  instantiates the picker chips and label; `tests/bubble-render.sh` loads the
  real `Bubble.qml` against the installed `qs.Commons`/`qs.Ui` (only the
  statically linked core plugin is stubbed) and asserts the card actually grows
  when the picker opens, without exceeding `maxHeight`. Both were verified by
  mutation: blank chips and a hidden picker each fail the corresponding check.

## 0.3.0

- Tables in Markdown-rendered modes (`ALT + SHIFT + D`, `ALT + I`) now render
  as real framed grids instead of crashing the shell. The answer is split into
  blocks: prose stays a Markdown `Text`, each table is drawn by a new
  `Table.qml` (borders, bold header row, columns proportioned to their widest
  cell with a 60% width cap and a minimum column width). `Text.MarkdownText`
  never sees a table, so the `QTextTable` re-layout that killed the scene
  graph cannot happen — streaming or not.
- The prose/tables split happens per flush (`Translate.splitBlocks`); a
  `flattenTables` pass behind it is the safety net for anything the splitter
  cannot parse. Copy still returns the original Markdown.
- Tests: 14 cases for `splitBlocks` / `tableWidths` / `tableGrid` on top of the
  flattener's 11 (107 total). Verified by rendering the crashing answer in a
  live `Text.MarkdownText` + `Table.qml` harness under `QT_QPA_PLATFORM=
  wayland`: the old path segfaulted 3/3 runs, the new one exits cleanly 3/3.

## 0.2.2

- Translating a table no longer kills the shell. `Text.MarkdownText` cannot
  re-lay out a Markdown table: the second layout corrupts the scene graph and
  the next frame dies in `QSGBatchRenderer::Renderer::prepareAlphaBatches`
  (SIGSEGV). A streaming translation re-lays out every 100 ms, so any table in
  the answer — which is exactly what a rich `ALT + SHIFT + D` capture of a
  table produces — crashed quickshell. Tables are now flattened to a list
  (one item per row, header first) before rendering; other Markdown is
  unchanged. Copy still returns the original Markdown.
- Streaming Markdown is transformed in one whole-text pass again (escape +
  table flattening). Flattening needs the line after each line — the delimiter
  row — so a growing stream can rewrite an already-emitted header and no
  prefix cache stays valid. Measured cost: 0.16 ms per pass on a 2.3 KB
  answer, against text layouts that cost far more.

## 0.2.1

- A stream that comes back identical to the input (a lazy model echo) is
  retried once with an explicit "translate, do not repeat" nudge. If the retry
  repeats it too, the bubble reports "The model returned the input unchanged."
  instead of presenting it as a translation. URLs are exempt.

## 0.2.0

Transport (requests):

- 429/5xx responses are retried automatically, twice with 1s/2s backoff.
  Auth failures, bad URLs, timeouts and dismissals still fail fast.
- Requests longer than `maxChars` (default 8000) are truncated before sending,
  never splitting a surrogate pair; the bubble notes the truncation.
- Repeated translations of the same text through the same model and prompt
  are served from an in-memory LRU cache (8 entries) — no second API call.

Input:

- The input-mode draft is persisted to `draft.txt` in the state directory, so
  a shell restart no longer clears it.

pick-text:

- `preCopyDelayMs`, `pollAttempts` and `pollIntervalMs` are now configurable
  in `config.json` (environment variables still win).
- Clipboard flavours are probed with a single `wl-paste --list-types` instead
  of one invocation per flavour.

OCR:

- The tesseract/easyocr paths are separate workers with real invocations;
  EasyOCR is no longer hidden behind a fake `tesseract` on PATH.
- The 2x upscale falls back to a Pillow one-liner when ImageMagick is absent,
  and logs the skip instead of silently running on the raw capture.

Bubble:

- Selection mode gets the same height budget input mode already had — the
  card no longer clips its last line at small `[spacing]` scales.
- Markdown escaping during streaming is incremental: only new lines go
  through the escaper instead of the whole translation on every flush.
