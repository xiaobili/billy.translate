#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
stub="$(mktemp -d)" || exit 1
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/bin"

checks=0
failures=0

check() {
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected $3"
    echo "       actual   $2"
  fi
}

cat > "$stub/bin/hyprpicker" <<'FREEZE'
#!/usr/bin/env bash
exit 0
FREEZE
cat > "$stub/bin/slurp" <<'SLURP'
#!/usr/bin/env bash
printf '10,20 100x50\n'
SLURP
cat > "$stub/bin/grim" <<'GRIM'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OCR_TEST_GRIM_ARGS"
printf 'synthetic-png' > "${@: -1}"
GRIM
cat > "$stub/bin/magick" <<'MAGICK'
#!/usr/bin/env bash
printf '%s %s\n' "${1##*/}" "${*:2}" > "$OCR_TEST_MAGICK_ARGS"
cat "$1"
MAGICK
cat > "$stub/bin/easyocr-python" <<'PYTHON'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OCR_TEST_PYTHON_ARGS"
printf '%s\n' "$OMARCHY_OCR_LANGS" > "$OCR_TEST_LANGUAGES"
cat > "$OCR_TEST_IMAGE"
if [ "${OCR_TEST_BLOCK_OCR:-0}" = "1" ]; then
  printf '%s\n' "$$" > "$OCR_TEST_OCR_PID"
  printf 'ready\n' > "$OCR_TEST_READY"
  exec cat "$OCR_TEST_BLOCK" >/dev/null
fi
if [ "${OCR_TEST_OCR_ERROR:-0}" = "1" ]; then exit 7; fi
if [ "${OCR_TEST_OCR_EMPTY:-0}" = "1" ]; then exit 0; fi
printf '%s' "$OCR_TEST_OCR_RESULT"
PYTHON
cat > "$stub/bin/tesseract" <<'TESSERACT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OCR_TEST_TESSERACT_ARGS"
cat > "$OCR_TEST_IMAGE"
if [ "${OCR_TEST_TESSERACT_ERROR:-0}" = "1" ]; then exit 7; fi
if [ "${OCR_TEST_TESSERACT_EMPTY:-0}" = "1" ]; then exit 0; fi
printf '%s' "$OCR_TEST_OCR_RESULT"
TESSERACT
cat > "$stub/bin/wl-copy" <<'COPY'
#!/usr/bin/env bash
printf 'called' > "$OCR_TEST_REAL_COPY"
COPY
chmod +x "$stub/bin"/*

export PATH="$stub/bin:$PATH"
export OCR_CONFIG_PATH="$stub/config.json"
export OCR_MAGICK_BIN="$stub/bin/magick"
export EASYOCR_PYTHON="$stub/bin/easyocr-python"
export OCR_TESSERACT_BIN="$stub/bin/tesseract"
export OCR_TEST_GRIM_ARGS="$stub/grim-args"
export OCR_TEST_MAGICK_ARGS="$stub/magick-args"
export OCR_TEST_PYTHON_ARGS="$stub/python-args"
export OCR_TEST_LANGUAGES="$stub/languages"
export OCR_TEST_TESSERACT_ARGS="$stub/tesseract-args"
export OCR_TEST_IMAGE="$stub/image-input"
export OCR_TEST_REAL_COPY="$stub/real-clipboard"

printf '{"ocrEngine":"easyocr","ocrLanguages":"chi_sim+eng"}\n' > "$stub/config.json"
export OCR_TEST_OCR_RESULT="recognized line one
recognized line two"
actual="$("$ROOT/bin/ocr-text" 2> "$stub/events")"
exit_code=$?
check "configured EasyOCR exits successfully" "$exit_code" "0"
check "EasyOCR output is returned" "$actual" "recognized line one
recognized line two"
check "region capture completion is signaled" "$(grep -Fx "OCR_SELECTION_READY" "$stub/events" || true)" "OCR_SELECTION_READY"
check "EasyOCR receives captured image" "$(cat "$stub/image-input")" "synthetic-png"
check "EasyOCR helper runs from configured venv" "$(cat "$stub/python-args")" "$ROOT/bin/easyocr-stdin.py"
check "configured languages reach EasyOCR" "$(cat "$stub/languages")" "chi_sim+eng"
check "captured PNG is enlarged before OCR" "$(cat "$stub/magick-args")" "selection.png -filter Lanczos -resize 200% png:-"
check "OCR does not modify clipboard" "$([ -e "$stub/real-clipboard" ] && printf touched || printf untouched)" "untouched"

printf '{"ocrEngine":"tesseract","ocrLanguages":"eng+chi_sim"}\n' > "$stub/config.json"
export OCR_TEST_OCR_RESULT="Tesseract result"
actual="$("$ROOT/bin/ocr-text" 2> "$stub/events")"
check "configured Tesseract engine returns text" "$actual" "Tesseract result"
check "configured languages reach Tesseract" \
  "$(cat "$stub/tesseract-args")" "stdin stdout --oem 1 --psm 6 -l eng+chi_sim --dpi 300 -c preserve_interword_spaces=1"

printf '{"ocrEngine":"easyocr","ocrLanguages":"chi_sim+eng"}\n' > "$stub/config.json"
export OCR_TEST_OCR_ERROR=1
"$ROOT/bin/ocr-text" >/dev/null 2>&1
check "EasyOCR errors propagate" "$?" "7"
unset OCR_TEST_OCR_ERROR
export OCR_TEST_OCR_EMPTY=1
"$ROOT/bin/ocr-text" >/dev/null 2>&1
check "empty OCR result fails" "$?" "1"
unset OCR_TEST_OCR_EMPTY

mkfifo "$stub/ready" "$stub/block"
export OCR_TEST_BLOCK_OCR=1 OCR_TEST_READY="$stub/ready" OCR_TEST_BLOCK="$stub/block"
export OCR_TEST_OCR_PID="$stub/ocr-pid"
"$ROOT/bin/ocr-text" > "$stub/blocked-output" 2> "$stub/blocked-events" &
wrapper_pid=$!
IFS= read -r _ < "$stub/ready"
ocr_pid="$(cat "$stub/ocr-pid")"
check "selection signal arrives while OCR is still running" \
  "$(grep -Fx "OCR_SELECTION_READY" "$stub/blocked-events" || true)" "OCR_SELECTION_READY"
kill -TERM "$wrapper_pid"
wait "$wrapper_pid" 2>/dev/null
ocr_state="$(ps -o stat= -p "$ocr_pid" 2>/dev/null | tr -d ' ' || true)"
case "$ocr_state" in
  ""|Z*) ocr_stopped="yes" ;;
  *) ocr_stopped="no" ;;
esac
check "closing the OCR process stops its worker" "$ocr_stopped" "yes"

printf '\n%d/%d passed\n' "$((checks - failures))" "$checks"
[ "$failures" -eq 0 ]
