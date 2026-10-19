#!/usr/bin/env bash
set -uo pipefail
export PATH=/usr/bin:/bin
ms() { local s=$(date +%s%N); eval "$1" >/dev/null 2>&1; local e=$(date +%s%N); echo $(( (e-s)/1000000 )); }

echo "=== wl-copy 成本：连续写入（剪贴板已有所有者）==="
for i in 1 2 3 4 5; do echo "  第 $i 次: $(ms 'printf hello | wl-copy') ms"; done

echo
echo "=== wl-copy 成本：先 --clear 再写入（rich 路径的真实序列）==="
for i in 1 2 3 4 5; do
  wl-copy --clear >/dev/null 2>&1
  echo "  clear 后第 $i 次写入: $(ms 'printf hello | wl-copy') ms"
done

echo
echo "=== wl-copy --type 成本 ==="
for i in 1 2 3; do echo "  第 $i 次: $(ms 'printf hello | wl-copy --type text/plain') ms"; done

echo
echo "=== 对照：wl-copy 在管道下（脚本里就是这么用的）==="
for i in 1 2 3; do
  s=$(date +%s%N); printf hello | wl-copy; e=$(date +%s%N)
  echo "  第 $i 次: $(( (e-s)/1000000 )) ms"
done
