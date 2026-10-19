#!/usr/bin/env bash
# 严格 A/B：从 git HEAD 取出修复前的版本，与当前版本交替测量，消除负载波动
set -uo pipefail
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
B="$ROOT/.workbuddy/bench"
OLD="$B/old"
export PATH=/usr/bin:/bin

mkdir -p "$OLD"
git -C "$ROOT" show HEAD:bin/pick-text > "$OLD/pick-text"
git -C "$ROOT" show HEAD:bin/html-to-markdown > "$OLD/html-to-markdown"
chmod +x "$OLD/pick-text" "$OLD/html-to-markdown"
# 旧版本按自身目录推导转换器路径，两边都用同一个 stub wtype
cp "$B/stub/wtype-html" "$OLD/wtype-html" 2>/dev/null
chmod +x "$OLD/wtype-html"

# 旧版读的是 config.json 里的 preCopyDelayMs（修复前 350）。
# 为了让 A/B 只比较"代码改动"，两边都显式钉住同一个值。
run_old() { PRE_COPY_DELAY_MS="$1" WTYPE="$B/stub/wtype-html" bash "$OLD/pick-text" --rich >/dev/null 2>&1; }
run_new() { PRE_COPY_DELAY_MS="$1" WTYPE="$B/stub/wtype-html" bash "$ROOT/bin/pick-text" --rich >/dev/null 2>&1; }

ab() { # ab <preCopyDelayMs>
  local d="$1" ao=0 an=0 i s e
  for i in 1 2 3 4 5 6; do
    s=$(date +%s%N); run_old "$d"; e=$(date +%s%N); ao=$(( ao + (e-s)/1000000 ))
    s=$(date +%s%N); run_new "$d"; e=$(date +%s%N); an=$(( an + (e-s)/1000000 ))
  done
  printf '  preCopyDelayMs=%-4s  修复前 %4d ms   修复后 %4d ms   省 %4d ms\n' \
    "$d" $((ao/6)) $((an/6)) $(( (ao-an)/6 ))
}

echo "=== 代码改动本身的收益（两边钉住同一个 preCopyDelayMs）==="
ab 350
ab 150
ab 0

echo
echo "=== 实际生效配置下的总收益 ==="
t=0
for i in 1 2 3 4 5 6; do
  s=$(date +%s%N); WTYPE="$B/stub/wtype-html" bash "$OLD/pick-text" --rich >/dev/null 2>&1
  e=$(date +%s%N); t=$(( t + (e-s)/1000000 ))
done
printf '  修复前（config 350）: %d ms\n' $((t/6))
t=0
for i in 1 2 3 4 5 6; do
  s=$(date +%s%N); WTYPE="$B/stub/wtype-html" bash "$ROOT/bin/pick-text" --rich >/dev/null 2>&1
  e=$(date +%s%N); t=$(( t + (e-s)/1000000 ))
done
printf '  修复后（config 150）: %d ms\n' $((t/6))
rm -rf "$OLD"
