#!/usr/bin/env bash
# 生成一份带阶段时间戳的 pick-text 副本（不改插件本体），然后跑一次 rich 路径。
set -uo pipefail

B="$(cd "$(dirname "$0")" && pwd)"
SRC="/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text"
DST="$B/pick-text.timed"

# 在头部注入 T() 计时函数
{
  cat <<'EOF'
T0=$(date +%s%N)
T() { local n=$(date +%s%N); printf '  %-28s +%4d ms  (累计 %4d)\n' "$1" $(( (n-LAST)/1000000 )) $(( (n-T0)/1000000 )) >&2; LAST=$n; }
LAST=$T0
T "脚本启动"
EOF
  # 逐行复制，在锚点后插入探针
  awk '
    { print }
    /^POLL_INTERVAL_MS=/ { print "T \"配置读取完成(3x jq)\"" }
    /^backup="\$\(mktemp -d\)"/ { print "T \"mktemp\"" }
    /^mkdir -p "\$backup\/by-type"/ { print "T \"mkdir by-type\"" }
    /--list-types 2>\/dev\/null > "\$backup\/types"/ { print "T \"备份: list-types\"" }
    /--no-newline 2>\/dev\/null > "\$backup\/data"/ { print "T \"备份: 读整份数据\"" }
    /^done < "\$backup\/types"$/ { if (!seen1++) print "T \"备份: 逐类型读取 x N\"" }
    /^  "\$WL_COPY" --clear 2>\/dev\/null/ { print "T \"清空剪贴板(wl-copy --clear)\"" }
    /^sleep "\$\(awk -v ms="\$PRE_COPY_DELAY_MS/ { print "T \"PRE_COPY_DELAY 前(awk)\"" }
    /^"\$WTYPE" -M ctrl -k c -m ctrl/ { print "T \"PRE_COPY_DELAY 结束(350ms)\"" }
    /^done$/ { print "T \"poll 结束\"" }
  ' "$SRC"
} > "$DST"

# 在 poll 循环体内加每次迭代的探针
awk '
  { print }
  /^  after_html="\$\("\$WL_PASTE" --type text\/html/ {
    print "  T \"  poll 迭代 $_ (sleep+2x wl-paste)\""
  }
' "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"

# 结尾探针
cat >> "$DST" <<'EOF'
T "read_rich 完成(html-to-markdown)"
EOF

chmod +x "$DST"

export PATH=/usr/bin:/bin
echo "=== rich 路径阶段耗时（wtype stub 立即响应）==="
WTYPE="$B/stub/wtype" PICK_DEBUG_LOG="$B/dbg.log" bash "$DST" --rich >/dev/null
echo
echo "=== pure 对照（--primary 命中）==="
printf 'plain selection text' | wl-copy --primary
bash "$DST" >/dev/null
