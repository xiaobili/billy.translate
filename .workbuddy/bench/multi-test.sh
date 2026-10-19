#!/usr/bin/env bash
# Manual check for bin/clipboard-write: does one selection carry several MIME
# types at once, and does every one of them come back intact?
#
# Run with a clean PATH (see .workbuddy/memory) from the bench directory:
#   env -i PATH=/usr/bin:/bin HOME=$USER ... bash multi-test.sh
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
BIN="$ROOT/bin/clipboard-write"
cd "$(dirname "$0")" || exit 1

printf '<b>hello</b> <i>rich</i>' > payload/text_html
printf 'hello rich' > payload/text_plain

# Old runs fork a server each; they would fight over the selection.
pkill -f 'bin/clipboard-write' 2>/dev/null
sleep 0.2

CW_WIRE_DEBUG=1 "$BIN" \
  "text/html:payload/text_html" \
  "text/plain;charset=utf-8:payload/text_plain" 2>err.txt
echo "parent exit=$?"
sleep 0.5

echo "=== wl-paste --list-types ==="
wl-paste --list-types 2>&1

for t in text/html text/plain "text/plain;charset=utf-8" UTF8_STRING STRING; do
  printf '%-28s %s\n' "$t" "$(wl-paste --type "$t" 2>&1 | head -1)"
done
echo "=== default ==="
wl-paste --no-newline 2>&1
echo
echo "=== 后台服务进程 ==="
pgrep -af 'clipboard-write' | grep -v pgrep || echo "(none)"

echo "=== WIRE 前 14 条 ==="
head -14 err.txt
