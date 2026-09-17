# Translate (billy.translate)

Select text anywhere, press `ALT + D`, read the translation in a
bubble at the cursor. Translations stream in, and the bubble copies with one
click.

- **Selects Chinese** → translates to English
- **Selects anything else** → translates to Simplified Chinese

## Installing

Third-party plugins are not enabled by default. The id has to be in
`~/.config/omarchy/shell.json`'s top-level `plugins` list, which
`omarchy plugin enable billy.translate` does. Without it, summoning is refused
— the shell logs `plugin not enabled, not summoning: billy.translate` — while
`omarchy-shell shell toggle` still exits 0, so the failure is silent.

## Keys

| Key | Action |
|---|---|
| `ALT + D` | Translate the selection; press again to dismiss |
| `ALT + I` | Type or paste text to translate; Enter translates, Shift+Enter adds a line |
| *(unbound)* | Copy the translation — use the bubble's copy button, or the IPC verb below |
| `Esc`, or click outside | Dismiss |

Bind the chords in `~/.config/hypr/bindings.lua`:

```lua
o.bind("ALT + D", "Translate selection", "omarchy-shell shell toggle billy.translate '{}'")
o.bind("ALT + I", "Translate typing", "omarchy-shell billy.translate input")
-- Copy has no chord on this machine: use the bubble's copy button,
-- or `omarchy-shell billy.translate copy`.
```

## Typing text

`ALT + I` opens the bubble with an input field instead of the
selection. Enter translates, Shift+Enter adds a line, and editing the text and
pressing Enter again re-translates — the request in flight is cancelled first.
A result whose text you have since changed is dimmed, so an old translation
never reads as the current one.

The draft lives in memory: it survives closing the bubble and comes back
selected next time, but a shell restart clears it.

## Configuration

`~/.local/state/omarchy/translate/config.json` (mode 0600), written on first
run from the chat plugin's config:

| Key | Meaning |
|---|---|
| `baseUrl` | Any OpenAI-compatible root, e.g. `https://api.deepseek.com/v1` |
| `model` | Model id |
| `apiKey` | Bearer token; leave empty for a local server that needs none |
| `systemPrompt` | Empty uses the built-in translation prompt |
| `temperature` | `0.2` by default — translation wants determinism |
| `maxTokens` | `0` means "do not send the field" |
| `timeoutSec` | Request timeout, `60` by default |

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

## How the selection is read

The primary selection first — that is what a mouse drag fills, and reading it
touches nothing. Only when it is empty does the plugin synthesise `Ctrl+C` and
read the clipboard, restoring the *text* flavour afterwards. Nothing richer
comes back as it was: `wl-copy` takes one type per call and each call becomes
the selection owner, so only the flavour replayed last survives — and that is
deliberately the text one, which is why a rich-text clipboard returns as plain
text.

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
4. There is no settings UI. Edit the JSON.
5. The draft in the input field is in memory only — a shell restart clears it.

## Tests

```bash
./tools/test.sh
```

Covers QML syntax (`qmllint`'s `[syntax]` class only), the pure functions in
`Layout.js` and `Translate.js`, both `bin/` scripts, and one static assertion on
`Transport.qml`. The QML layer has no
harness — after any QML edit, restart the shell rather than trusting a
hot-reload, because a plugin that fails to compile keeps reporting the stale
error and the stale line number.

The entry point is not inert: the `bin/` section drives the real clipboard, and
`pick-text`'s fallback case synthesises a `Ctrl+C` into whichever window has
focus. Run it from a terminal you can afford to have interrupted. It puts your
*text* selections back afterwards; a clipboard holding anything else — an image,
a file list — is not restored.
