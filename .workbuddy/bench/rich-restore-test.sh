#!/usr/bin/env bash
# End-to-end check of the clipboard restore: does a rich-text clipboard survive
# a pick-text run?
#
# Sets up a two-flavour clipboard, then drives pick-text through a path that is
# guaranteed to fail (WTYPE stubbed so no Ctrl+C is ever delivered), which is
# the path that always reaches restore(). Compares the multi-type writer against
# the old wl-copy fallback, which can only ever put back one flavour.
#
#   env -i PATH=/usr/bin:/bin HOME=$USER XDG_RUNTIME_DIR=... WAYLAND_DISPLAY=... \
#     bash rich-restore-test.sh
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
cd "$(dirname "$0")" || exit 1

printf '<b>rich</b> content <i>here</i>' > payload/text_html
printf 'rich content here' > payload/text_plain

setup_clipboard() {
  pkill -f 'bin/clipboard-write' 2>/dev/null
  sleep 0.2
  "$ROOT/bin/clipboard-write" \
    "text/html:payload/text_html" \
    "text/plain;charset=utf-8:payload/text_plain"
  sleep 0.4
}

run_pick() {
  PRE_COPY_DELAY_MS=0 POLL_INTERVAL_MS=5 POLL_ATTEMPTS=2 WTYPE=/bin/true \
    CLIPBOARD_WRITE="$1" "$ROOT/bin/pick-text" --rich >/dev/null 2>&1
  echo "pick-text exit=$?"
  sleep 0.4
}

show() {
  echo "  types: $(wl-paste --list-types 2>&1 | tr '\n' ' ')"
  echo "  html:  $(wl-paste --type text/html 2>&1 | head -1)"
  echo "  text:  $(wl-paste --no-newline 2>&1 | head -1)"
}

echo "=== 基线：两类型剪贴板 ==="
setup_clipboard
show

echo
echo "=== 新路径：clipboard-write 可用 ==="
setup_clipboard
run_pick "$ROOT/bin/clipboard-write"
show

echo
echo "=== 对照：回退到 wl-copy（CLIPBOARD_WRITE=/bin/false）==="
setup_clipboard
run_pick /bin/false
show

pkill -f 'bin/clipboard-write' 2>/dev/null
