#!/usr/bin/env bash
# 变异测试：故意把两个优化改回旧写法，确认新增断言会失败。
# 任何一步都会把 pick-text 从备份还原，避免留下被破坏的文件。
set -uo pipefail
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
PICK="$ROOT/bin/pick-text"
BAK="$ROOT/.workbuddy/bench/pick-text.orig"
RUN="env -i PATH=/usr/bin:/bin HOME=/home/billy USER=billy XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-}"

cp "$PICK" "$BAK"
restore() { cp "$BAK" "$PICK"; }
trap restore EXIT

echo "=========== 基线（未变异）应全通过 ==========="
$RUN bash "$ROOT/tests/scripts.test.sh" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"

echo
echo "=========== 变异 1：轮询改回「先睡后查」 ==========="
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text")
s = p.read_text()
old = '''for _ in $(seq "$poll_attempts"); do
  after_text="$("$WL_PASTE" --no-newline 2>/dev/null || true)"
  after_html="$("$WL_PASTE" --type text/html 2>/dev/null || true)"
  if [ "$after_text" != "$before_text" ] || [ "$after_html" != "$before_html" ]; then
    break
  fi
  sleep "$(awk -v ms="$POLL_INTERVAL_MS" 'BEGIN{printf "%.3f", ms/1000}')"
done'''
new = '''for _ in $(seq "$poll_attempts"); do
  sleep "$(awk -v ms="$POLL_INTERVAL_MS" 'BEGIN{printf "%.3f", ms/1000}')"
  after_text="$("$WL_PASTE" --no-newline 2>/dev/null || true)"
  after_html="$("$WL_PASTE" --type text/html 2>/dev/null || true)"
  if [ "$after_text" != "$before_text" ] || [ "$after_html" != "$before_html" ]; then
    break
  fi
done'''
assert old in s, "锚点未命中，变异脚本需要更新"
p.write_text(s.replace(old, new))
print("已注入变异 1")
PY
$RUN bash "$ROOT/tests/scripts.test.sh" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
restore

echo
echo "=========== 变异 2：restore 改回「总是重放所有类型」 ==========="
python3 - <<'PY'
import pathlib
p = pathlib.Path("/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text")
s = p.read_text()
old = '''  if [ ! -s "$backup/data" ]; then'''
new = '''  if true; then'''
assert old in s, "锚点未命中，变异脚本需要更新"
p.write_text(s.replace(old, new))
print("已注入变异 2")
PY
$RUN bash "$ROOT/tests/scripts.test.sh" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
restore

echo
echo "=========== 还原后确认 ==========="
diff -q "$BAK" "$PICK" && echo "pick-text 已还原，与原始一致"
$RUN bash "$ROOT/tests/scripts.test.sh" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
