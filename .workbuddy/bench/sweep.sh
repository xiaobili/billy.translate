#!/usr/bin/env bash
# 旋钮扫描：量化每个环节对 rich 路径总耗时的贡献。
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
PICK="/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text"
export PATH=/usr/bin:/bin

run() { # run <label> <env赋>
  local label="$1"; shift
  local total=0 best=99999 worst=0
  for i in 1 2 3 4 5; do
    local s=$(date +%s%N)
    env "$@" WTYPE="$B/stub/wtype" bash "$PICK" --rich >/dev/null 2>&1
    local e=$(date +%s%N)
    local ms=$(( (e-s)/1000000 ))
    total=$((total+ms)); [ "$ms" -lt "$best" ] && best=$ms; [ "$ms" -gt "$worst" ] && worst=$ms
  done
  printf '%-46s  avg %4d ms   (min %4d / max %4d)\n' "$label" $((total/5)) "$best" "$worst"
}

echo "===== A. 当前默认配置 ====="
run "preCopyDelay=350 poll=25ms x16(→32)"

echo
echo "===== B. 单独关掉 preCopyDelay ====="
run "preCopyDelay=0   poll=25ms x16(→32)"   PRE_COPY_DELAY_MS=0

echo
echo "===== C. 再收紧 poll 间隔 ====="
run "preCopyDelay=0   poll=5ms  x16(→32)"   PRE_COPY_DELAY_MS=0 POLL_INTERVAL_MS=5

echo
echo "===== D. 只收紧 poll 间隔（保留 350ms）====="
run "preCopyDelay=350 poll=5ms  x16(→32)"   POLL_INTERVAL_MS=5

echo
echo "===== E. 模拟应用“不响应合成 Ctrl+C”的最坏情况 ====="
cat > "$B/stub/wtype-slow" <<'EOF'
#!/usr/bin/env bash
exit 0   # 什么都不放，模拟 app 忽略 Ctrl+C
EOF
chmod +x "$B/stub/wtype-slow"
local_best=99999
for i in 1 2 3; do
  s=$(date +%s%N)
  WTYPE="$B/stub/wtype-slow" bash "$PICK" --rich >/dev/null 2>&1
  e=$(date +%s%N); ms=$(( (e-s)/1000000 ))
  printf '  失败路径 run %d: %d ms（用户此时才开始看到报错）\n' "$i" "$ms"
done

echo
echo "===== F. 对照：ALT+D 纯文本快路径 ====="
printf 'plain selection text' | wl-copy --primary
t=0
for i in 1 2 3 4 5; do
  s=$(date +%s%N); bash "$PICK" >/dev/null 2>&1; e=$(date +%s%N)
  t=$(( t + (e-s)/1000000 ))
done
printf '  pure primary-selection 平均 %d ms\n' $((t/5))
