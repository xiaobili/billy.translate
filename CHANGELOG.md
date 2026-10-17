# Changelog

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
