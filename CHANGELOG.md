# Changelog

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
