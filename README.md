# Translate (billy.translate)

Select text anywhere, press `ALT + D`, read the translation in a
bubble at the cursor. Translations stream in, and the bubble copies with one
click.

The source language is detected from the text and the target follows a default
you set once; out of the box that is Chinese → English, everything else →
Simplified Chinese. Click the arrow in the bubble's header (or press `Ctrl+L`)
to pick a different target for the session.

## Languages

Twelve targets ship: Chinese (Simplified and Traditional), English, Japanese,
Korean, Spanish, French, German, Russian, Portuguese, Italian, Arabic.

- **Detection is local.** `Translate.detectLang` counts Unicode script ranges
  (CJK, kana, Hangul, Cyrillic, Arabic, Thai, Devanagari) and, for Latin text,
  scores stopword density plus characteristic spelling. No extra request, no
  latency, and it works before the model's first token.
- **Non-prose is stripped first.** URLs, code (fenced and inline), HTML tags
  and attributes, file names, paths and Markdown link targets are removed
  before counting. Detection is a density measurement, so without this a
  single URL could outvote a short sentence — `a` inside `example.com` once
  made Chinese read as Portuguese in rich mode. Link *labels* and image
  captions are dropped too; neither is the author's prose.
- **The target defaults to `targetLang`.** When that language is also the
  detected source, the built-in pair takes over instead (Chinese → English,
  anything else → Chinese) — asking a model to translate German into German
  produces nothing useful.
- **Detection is heuristic, not authoritative.** Short Latin-script strings
  ("OK", "Bonjour") can land on the wrong Romance or Germanic language, and
  mixed-script text resolves to whichever script dominates. A short Latin
  sentence with a long URL can also lose the evidence it needed to be
  identified. Correct a wrong guess from the picker; the translation re-runs
  immediately.

## Installing

Third-party plugins are not enabled by default. The id has to be in
`~/.config/omarchy/shell.json`'s top-level `plugins` list, which
`omarchy plugin enable billy.translate` does. Without it, summoning is refused
— the shell logs `plugin not enabled, not summoning: billy.translate` — while
`omarchy-shell shell toggle` still exits 0, so the failure is silent.

## Keys

| Key                     | Action                                                                     |
| ----------------------- | -------------------------------------------------------------------------- |
| `ALT + D`               | Translate the selection; press again to dismiss                            |
| `ALT + SHIFT + D`       | Translate the selection **with formatting** (see below); press again to dismiss |
| `ALT + O`               | Select a screen region, OCR it, and translate the text                     |
| `ALT + I`               | Type or paste text to translate; Enter translates, Shift+Enter adds a line |
| `ALT + SHIFT + I`       | The same field, with the answer **rendered as Markdown** (see below)      |
| `Ctrl + L`              | Open/close the language picker (or click the arrow in the header)          |
| *(unbound)*             | Copy the translation — use the bubble's copy button, or the IPC verb below |
| `Esc`, or click outside | Close the picker first, then dismiss                                       |

Bind the chords in `~/.config/hypr/bindings.lua`:

```lua
o.bind("ALT + D", "Translate selection", "omarchy-shell shell toggle billy.translate '{}'")
o.bind("ALT + SHIFT + D", "Translate selection with formatting", "omarchy-shell billy.translate rich")
o.bind("ALT + O", "Translate screenshot text", "omarchy-shell billy.translate ocr")
o.bind("ALT + I", "Translate typing", "omarchy-shell billy.translate input")
o.bind("ALT + SHIFT + I", "Translate typing with formatting", "omarchy-shell billy.translate richInput")
-- Copy has no chord on this machine: use the bubble's copy button,
-- or `omarchy-shell billy.translate copy`.
```

## Translating with formatting (`ALT + SHIFT + D`)

`ALT + D` reads the **primary selection**, which in practice carries only plain
text — a mouse drag in a browser fills it with the rendered words, not the
HTML behind them. That is why selecting a *rendered* preview (webpage, rendered
Markdown) translated as flat text with no Markdown to render, while selecting
the *source* (raw Markdown/HTML) worked: the source's syntax was already in the
plain text.

`ALT + SHIFT + D` (`omarchy-shell billy.translate rich`) instead skips the
primary selection and synthesises `Ctrl+C`, capturing the clipboard's richest
flavour like a real copy: `text/html` is converted to Markdown, so headings,
lists, bold/links survive into the translation and render formatted in the
bubble. Plain text remains the fallback when the app offers nothing richer.

Trade-offs of the rich path (it is opt-in for these reasons):

- It takes the synthetic-`Ctrl+C` path on every invocation (~400ms worst case),
  and the selection may land in the omarchy clipboard history (same documented
  side effect as the plain fallback path).
- Previews rendered as plain text (terminal pagers, `glow` output) have no
  HTML flavour at all — the formatting is lost at the source and nothing can
  recover it. Select the Markdown source in that case.

## Typing text

`ALT + I` opens the bubble with an input field instead of the
selection. Enter translates, Shift+Enter adds a line, and editing the text and
pressing Enter again re-translates — the request in flight is cancelled first.
A result whose text you have since changed is dimmed, so an old translation
never reads as the current one.

`ALT + SHIFT + I` opens the same field and renders the answer as Markdown —
for pasting Markdown in and reading it back formatted. The two chords differ
*only* in rendering: the request sent to the model is identical, so switching
between them re-renders what is already on screen without asking again. Pressing
the chord that is already open dismisses the bubble; pressing the other one
switches the open bubble over, keeping the text in the field.

No cursor query runs in input mode, so the bubble opens where the cursor was
last queried — wherever the pointer was for the last `ALT + D`, or centred on
the screen the first time. Querying it here would only make the card jump out
from under you once it was already visible.

The draft lives in `~/.local/state/omarchy/translate/draft.txt`: it survives
closing the bubble and shell restarts, and comes back selected next time.

## Screenshot OCR

`ALT + O` opens a region selector. As soon as the screenshot is captured, the
translation panel appears with a recognition spinner; OCR and translation then
continue in the background.
The OCR engine is selected in `~/.local/state/omarchy/translate/config.json`:
`ocrEngine` defaults to `tesseract`; set it to `easyocr` to use the optional
EasyOCR virtual environment. The default Tesseract engine needs no extra setup;
run `./tools/install-easyocr.sh` only if you choose EasyOCR. Both choices use
Omarchy's region selector, enlarge the captured image 2x in memory, and leave
the clipboard unchanged. The 2x enlargement uses ImageMagick when available and
falls back to a Pillow one-liner (`python3 -c 'import PIL.Image'`); with neither,
the raw capture goes through and the skip is logged to
`/tmp/billy-translate-ocr.log`. EasyOCR runs in CPU mode and downloads model weights
on first use to `~/.EasyOCR/model` if they are not cached.

## Configuration

`~/.local/state/omarchy/translate/config.json` (mode 0600), written on first
run from the chat plugin's config:

| Key            | Meaning                                                        |
| -------------- | -------------------------------------------------------------- |
| `baseUrl`      | Any OpenAI-compatible root, e.g. `https://api.deepseek.com/v1` |
| `model`        | Model id                                                       |
| `apiKey`       | Bearer token; leave empty for a local server that needs none   |
| `systemPrompt` | Empty uses the built-in translation prompt; see below          |
| `targetLang`   | Default target language, e.g. `ja`; empty means the built-in pair |
| `temperature`  | `0.2` by default — translation wants determinism               |
| `maxTokens`    | `0` means "do not send the field"                              |
| `timeoutSec`   | Request timeout, `60` by default                               |
| `maxChars`     | Inputs longer than this are truncated before sending (`8000`)  |
| `ocrEngine`    | `tesseract` (default) or `easyocr`                             |
| `ocrLanguages` | `chi_sim+eng` by default; language codes separated by `+`      |
| `preCopyDelayMs` | Wait before the synthetic Ctrl+C, so the hotkey's modifiers are released (`350`) |
| `pollAttempts` | How many 25ms polls wait for the synthetic copy to land (`16`) |
| `pollIntervalMs` | Interval between those polls in ms (`25`)                   |

A failed request with a 429 or 5xx status is retried automatically — twice,
after 1s and 2s — since those are usually transient. Anything else (auth,
bad URL, timeout, dismissal) fails fast as before. A repeated translation of
the same text through the same model and prompt is answered from an in-memory
cache (8 entries) instead of another API call. The detected direction is part
of the cache key, so the same text into two languages is two entries.

### Language codes and prompts

`targetLang` takes one of `zh`, `zh-TW`, `en`, `ja`, `ko`, `es`, `fr`, `de`,
`ru`, `pt`, `it`, `ar`; anything unrecognised is ignored and the built-in pair
applies. The picker writes this key when you choose a language, so
`config.json` and the UI never disagree.

The built-in prompt names the direction it wants ("translate from German into
Japanese"). A custom `systemPrompt` can interpolate `{{lang}}` (the target's
English name) and `{{source}}` (the detected source's). With neither
placeholder, the text is **appended** to the built-in rules rather than
replacing them — the no-echo rule and the formatting rules are what keep a
stream usable, and dropping them silently was the old behaviour's sharpest
edge. Use a placeholder when you want full control instead:

```json
{ "systemPrompt": "Translate into {{lang}}. Keep code fences. Output only the translation." }
```

If a completed stream comes back identical to the input — a lazy model
response, most often when the input is already near the target language — it
is retried once with an explicit "translate, do not repeat" nudge. If the
retry repeats it too, the answer stands but the bubble says so ("The model
returned the input unchanged.") instead of reading as a successful
translation. URLs are exempt: keeping them unchanged is by design.

The tuning knobs (`preCopyDelayMs`, `pollAttempts`, `pollIntervalMs`) can also
be set per-invocation via the `PRE_COPY_DELAY_MS`, `POLL_ATTEMPTS` and
`POLL_INTERVAL_MS` environment variables, which win over the config file.

Inputs longer than `maxChars` are truncated before sending (never splitting a
surrogate pair), and the bubble says so under the result.

The request disables the provider's thinking mode (`thinking: {type: "disabled"}`).
This tool only translates, and on DeepSeek thinking mode also ignores
`temperature` — so leaving it on costs latency and tokens while quietly making
the setting above do nothing. The field is DeepSeek's and is sent
unconditionally: an endpoint that rejects unknown body fields would answer 400
and would need that one line removed in `Translate.js`.

The API key deliberately does **not** live in `~/.config/omarchy/shell.json`:
plugin settings there are inline on the bar entry, and the shell rewrites that
file on every layout change. It is also kept out of `argv` — curl reads it from
a 0600 config file, because `/proc/<pid>/cmdline` is world-readable.

## Markdown rendering

Whether the translation bubble renders Markdown depends on **the hotkey**, not
on the mode: only the two rich chords ask for it — `ALT + SHIFT + D`, which
captures the selection for its text/html flavour, and `ALT + SHIFT + I`, which
renders what you typed. Both render Markdown (`Text.MarkdownText`): headings,
lists, bold/italic, links, inline code and code blocks from the translation
appear formatted, while plain text without Markdown syntax renders unchanged.

Everything else renders as plain text — `ALT + D`, `ALT + O`, and now
`ALT + I`. Their `*`, `#`, backticks and `<...>` are usually literal
characters, and Markdown rendering would mangle the display. Note the
consequence for the input field: `ALT + I` shows the answer verbatim, so a
Markdown table in it reads as `| a | b |` rather than as a drawn grid. Use
`ALT + SHIFT + I` when you want the formatting back.

Angle-bracket sequences shaped like HTML tags (`List<String>`, `<name>`) are
escaped before Markdown rendering so they display literally instead of being
parsed as tags; fenced code blocks and inline code spans are already literal
and are left alone. The
built-in system prompt asks the model to preserve Markdown structure —
translating only the human-readable text inside it — so a structured source
stays structured in the target language. Copy still copies the Markdown source,
so pasting elsewhere keeps the formatting.

**Tables are rendered by the bubble itself, not by `Text.MarkdownText`.** Qt's
Markdown importer builds a `QTextTable` for a Markdown table, and re-laying
that table out when the text changes again crashes the scene graph
(`QSGBatchRenderer::Renderer::prepareAlphaBatches`, SIGSEGV — the whole shell
goes down with it). A streaming translation changes the text ten times a
second, so a table in the answer was enough to take the shell out mid-stream;
this is what `ALT + SHIFT + D` on a table used to do.

The answer is therefore split into blocks (`Translate.splitBlocks`): prose goes
to a Markdown `Text` as before, and each table goes to `Table.qml`, which
draws the grid as ordinary QML rectangles — full borders, a bold header row,
column widths proportioned to the widest cell in each column (never narrower
than `minColumnWidth`, never wider than 60% of the card). Cells render their
own inline Markdown (code, bold, links) and wrap inside their column.

Prose keeps every other construct — headings, lists, emphasis, code — and a
`flattenTables` pass behind the splitter is the safety net: if a table ever
slipped past `splitBlocks`, it degrades to a list instead of reaching
`MarkdownText`. Copy is unaffected: it takes the untransformed translation.

## How the selection is read

The primary selection first — that is what a mouse drag fills, and reading it
touches nothing. Only when it is empty does the plugin synthesise `Ctrl+C` and
read the clipboard, restoring the *text* flavour afterwards.

Like a real `Ctrl+C`, the reader captures rich flavours when the source offers
them: `text/markdown` is used as-is, and `text/html` is converted to Markdown
via `bin/html-to-markdown` (stdlib-only Python, no extra dependencies), so a
selection from a browser or rich-text editor arrives with its headings, lists
and emphasis intact instead of as a flat paragraph. Plain text remains the
fallback when no richer flavour exists.

Explicit flavour requests are also available for scripting:

```bash
bin/pick-text --html      # raw text/html, else non-zero exit
bin/pick-text --markdown  # text/markdown, or text/html converted to Markdown
```

**Restore limitation (unchanged):** `wl-copy` takes one type per call and each
call becomes the selection owner, so only the flavour replayed last survives —
and that is deliberately the text one. A rich-text clipboard therefore comes
back as plain text after the fallback path, even though the translation itself
saw the rich version.

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
4. There is no settings UI for the connection (base URL, model, key). Edit the
   JSON. Language choice *does* have a UI — the picker in the header.
5. Language detection is heuristic (see Languages above). Very short or heavily
   mixed text can be misread; the picker is the escape hatch.

## Tests

```bash
./tools/test.sh
```

Covers QML syntax (`qmllint`'s `[syntax]` class only), the pure functions in
`Layout.js` and `Translate.js` (166 cases, including language detection, the
non-prose stripping, target resolution and prompt directions), the `bin/`
scripts, and two offscreen render checks:

- `tests/lang-render.qml` — the picker chips and the direction label
  instantiate, and the row is non-empty. Verified by mutation: blanking a chip's
  text fails it.
- `tests/bubble-render.sh` — the **real** `Bubble.qml` loaded against the
  installed `qs.Commons`/`qs.Ui`, with only the statically linked
  `quickshell-coreplugin` stubbed. Asserts the card grows when the picker opens
  and stays under `maxHeight`. Verified by mutation: hiding the picker fails it.
  Skips (exit 0) on a machine without Omarchy's shell modules.

Neither replaces a restart. After any QML edit, restart the shell rather than
trusting a hot-reload, because a plugin that fails to compile keeps reporting the
stale error and the stale line number. Check `journalctl --user -f` for
`billy.translate` while the shell comes up.

Table handling (block splitting, column layout, and the flattening safety net)
is covered by the pure-function tests, which is also what keeps the crash from
coming back: the failure mode is a scene-graph crash on a *second* layout of a
table, so it can only be reproduced against a real renderer. The
offscreen QML platform is not one — it reports `GraphicsInfo.api == 0` and never
builds batches — so a headless render test would pass whether the transform
runs or not. To check it by hand, stream a Markdown table into a
`Text.MarkdownText` under `QT_QPA_PLATFORM=wayland`; unflattened it segfaults in
`QSGBatchRenderer::Renderer::prepareAlphaBatches`, split into blocks it renders
as prose plus a `Table.qml` grid.

The entry point is not inert: the `bin/` section drives the real clipboard, and
`pick-text`'s fallback case synthesises a `Ctrl+C` into whichever window has
focus. Run it from a terminal you can afford to have interrupted. It puts your
*text* selections back afterwards; a clipboard holding anything else — an image,
a file list — is not restored.
