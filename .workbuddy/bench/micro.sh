#!/usr/bin/env bash
# 微基准：逐项测 clean 环境下各子进程 / 往返的真实成本
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
H2M="/home/billy/.config/omarchy/plugins/billy.translate/bin/html-to-markdown"
CFG="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/translate/config.json"
export PATH=/usr/bin:/bin

ms() { local s=$(date +%s%N); "$@" >/dev/null 2>&1; local e=$(date +%s%N); echo $(( (e-s)/1000000 )); }

echo "=== 进程派生基线 ==="
echo "  bash -c true          : $(ms bash -c true) ms"
echo "  awk (一次)            : $(ms awk 'BEGIN{}') ms"

echo
echo "=== 配置读取（pick_num 每个旋钮一次 jq，共 3 次）==="
t=0; for i in 1 2 3; do
  s=$(date +%s%N)
  for k in pollIntervalMs pollAttempts preCopyDelayMs; do
    jq -r --arg key "$k" '.[$key] | select(type == "number") | tostring' "$CFG" >/dev/null 2>&1
  done
  e=$(date +%s%N); t=$(( t + (e-s)/1000000 ))
done
echo "  3x jq                 : $((t/3)) ms"

echo
echo "=== python3 启动（html-to-markdown 真实成本）==="
t=0; for i in 1 2 3 4 5; do
  s=$(date +%s%N)
  printf '<h1>H</h1><p>a <b>b</b></p>' | python3 "$H2M" >/dev/null 2>&1
  e=$(date +%s%N); t=$(( t + (e-s)/1000000 ))
done
echo "  python3 单次           : $((t/5)) ms"
echo "  python -c pass        : $(ms python3 -c pass) ms"

echo
echo "=== 剪贴板往返 ==="
printf 'x' | wl-copy >/dev/null 2>&1
echo "  wl-paste --list-types : $(ms wl-paste --list-types) ms"
echo "  wl-paste (文本)       : $(ms wl-paste --no-newline) ms"
echo "  wl-paste --type       : $(ms wl-paste --type text/plain) ms"
echo "  wl-copy (写入)        : $(ms sh -c 'printf x | wl-copy') ms"
echo "  wl-copy --clear       : $(ms wl-copy --clear) ms"

echo
echo "=== 多种类型时：备份 / 还原 的 N 倍放大 ==="
# 造一个含多种类型的剪贴板场景（纯文本应用通常提供 ~6 种）
printf 'sample' | wl-copy >/dev/null 2>&1
types=$(wl-paste --list-types 2>/dev/null | sort -u)
n=$(printf '%s\n' "$types" | grep -c .)
echo "  当前剪贴板类型数 N = $n"
s=$(date +%s%N)
while IFS= read -r ty; do [ -n "$ty" ] || continue; wl-paste --type "$ty" >/dev/null 2>&1; done <<< "$types"
e=$(date +%s%N); echo "  备份 N x wl-paste    : $(( (e-s)/1000000 )) ms"
s=$(date +%s%N)
while IFS= read -r ty; do [ -n "$ty" ] || continue; printf 'sample' | wl-copy --type "$ty" >/dev/null 2>&1; done <<< "$types"
e=$(date +%s%N); echo "  还原 N x wl-copy     : $(( (e-s)/1000000 )) ms"
