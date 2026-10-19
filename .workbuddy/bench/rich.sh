#!/usr/bin/env bash
# 诊断用：在干净环境下跑 pick-text --rich，并分阶段计时。
# 不修改插件本体，只是把环境变量和 wtype stub 换掉。
set -uo pipefail

B="$(cd "$(dirname "$0")" && pwd)"
PICK="/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text"
H2M="/home/billy/.config/omarchy/plugins/billy.translate/bin/html-to-markdown"

# 干净环境：PATH 只含系统目录，模拟 Quickshell 派生子进程的环境
export PATH=/usr/bin:/bin

echo "=== 1) html-to-markdown 单独验证 ==="
printf '<h1>Hello</h1><p>Some <b>bold</b> text and a <a href="https://example.com">link</a>.</p><ul><li>one</li><li>two</li></ul>' \
  | python3 "$H2M"
echo
echo "[exit=$?]"
echo

echo "=== 2) pick-text --rich 端到端（wtype stub 立即响应）==="
for i in 1 2 3; do
  s=$(date +%s%N)
  out=$(WTYPE="$B/stub/wtype" PICK_DEBUG_LOG="$B/dbg.log" bash "$PICK" --rich 2>&1)
  e=$(date +%s%N)
  printf 'run %d: %d ms | %d 字符\n' "$i" $(( (e-s)/1000000 )) "${#out}"
  printf '  first line: %s\n' "$(printf '%s' "$out" | head -1)"
done
echo
echo "=== 3) 对照：pick-text 纯文本路径（--primary 命中）==="
printf 'plain selection text' | wl-copy --primary
for i in 1 2 3; do
  s=$(date +%s%N)
  out=$(bash "$PICK" 2>&1)
  e=$(date +%s%N)
  printf 'run %d: %d ms | %d 字符\n' "$i" $(( (e-s)/1000000 )) "${#out}"
done
