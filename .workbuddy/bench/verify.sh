#!/usr/bin/env bash
# 修复后的验收：正确性 + 端到端耗时，与修复前的基线对比
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
PICK=/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text
export PATH=/usr/bin:/bin
CFG="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/translate/config.json"

echo "=== 0) 生效中的配置 ==="
jq -c '{preCopyDelayMs, pollAttempts, pollIntervalMs}' "$CFG" 2>/dev/null

echo
echo "=== 1) 正确性：rich 抓取仍应得到 Markdown ==="
out=$(WTYPE="$B/stub/wtype-html" bash "$PICK" --rich 2>&1)
printf '%s\n' "$out" | head -5
case "$out" in
  "<h1>"*) echo "  ✗ 退化成了原始 HTML" ;;
  "# Hello"*) echo "  ✓ Markdown 正常" ;;
  *) echo "  ? 意外输出" ;;
esac

echo
echo "=== 2) 端到端耗时：rich 路径（应用立即响应）==="
t=0; best=99999; worst=0
for i in 1 2 3 4 5; do
  s=$(date +%s%N); WTYPE="$B/stub/wtype-html" bash "$PICK" --rich >/dev/null 2>&1
  e=$(date +%s%N); ms=$(( (e-s)/1000000 ))
  t=$((t+ms)); [ "$ms" -lt "$best" ] && best=$ms; [ "$ms" -gt "$worst" ] && worst=$ms
done
printf '  修复后 avg %d ms (min %d / max %d)   修复前基线 avg 875 ms\n' $((t/5)) "$best" "$worst"

echo
echo "=== 3) 端到端耗时：纯文本快路径（对照）==="
printf 'plain selection text' | wl-copy --primary
t=0
for i in 1 2 3 4 5; do
  s=$(date +%s%N); bash "$PICK" >/dev/null 2>&1; e=$(date +%s%N)
  t=$(( t + (e-s)/1000000 ))
done
printf '  avg %d ms   修复前基线 58 ms\n' $((t/5))

echo
echo "=== 4) 失败路径（app 忽略 Ctrl+C）耗时 ==="
for i in 1 2; do
  s=$(date +%s%N); WTYPE="$B/stub/wtype-slow" bash "$PICK" --rich >/dev/null 2>&1
  e=$(date +%s%N)
  printf '  run %d: %d ms   修复前基线 ~2100 ms\n' "$i" $(( (e-s)/1000000 ))
done

echo
echo "=== 5) 剪贴板还原仍然生效 ==="
printf 'sentinel-do-not-lose' | wl-copy
wl-copy --clear --primary
bash "$PICK" >/dev/null 2>&1
got=$(wl-paste --no-newline 2>/dev/null)
[ "$got" = "sentinel-do-not-lose" ] && echo "  ✓ 还原正确: $got" || echo "  ✗ 还原失败: [$got]"
