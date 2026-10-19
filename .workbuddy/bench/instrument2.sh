#!/usr/bin/env bash
# 完整阶段插桩：覆盖抓词之后的 read_rich(html→md) 与 restore 还原阶段
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
SRC="/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text"
DST="$B/pick-text.timed2"

{
  cat <<'EOF'
T0=$(date +%s%N); LAST=$T0
T() { local n=$(date +%s%N); printf '  %-30s +%4d ms  (累计 %4d)\n' "$1" $(( (n-LAST)/1000000 )) $(( (n-T0)/1000000 )) >&2; LAST=$n; }
T "bash 启动"
EOF
  awk '
    { print }
    /^POLL_INTERVAL_MS=/ { }
    /^PRE_COPY_DELAY_MS=/ { print "T \"读配置(3x jq)\"" }
    /^WL_PASTE="\$\{WL_PASTE/ { print "T \"stub 变量初始化\"" }
    /^backup="\$\(mktemp -d\)"/ { print "T \"mktemp\"" }
    /^mkdir -p "\$backup\/by-type"/ { print "T \"mkdir\"" }
    /--list-types 2>\/dev\/null > "\$backup\/types"/ { print "T \"备份 list-types\"" }
    /--no-newline 2>\/dev\/null > "\$backup\/data"/ { print "T \"备份 整份数据\"" }
    /^  "\$WL_COPY" --clear 2>\/dev\/null/ { print "T \"wl-copy --clear\"" }
    /^sleep "\$\(awk -v ms="\$PRE_COPY_DELAY_MS/ { print "T \"awk(算延时)\"" }
    /^"\$WTYPE" -M ctrl -k c -m ctrl/ { print "T \"sleep PRE_COPY_DELAY\""; print "T \"wtype 发 Ctrl+C\"" }
  ' "$SRC"
} > "$DST"

# 在 read_rich 调用点前后加探针
awk '
  { print }
  /^read_rich && exit 0$/ { print "T \"read_rich (list+html+python3)\"" }
' "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"

# restore 里加探针（trap 阶段）
awk '
  { print }
  /^  if \[ -s "\$backup\/data" \]; then$/ { print "    T \"restore: N x wl-copy --type\"" }
  /^  rm -rf "\$backup"$/ { print "    T \"restore: 最后 wl-copy(文本)\"" }
' "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"
# restore 结束探针追加到函数尾部
awk '
  { print }
  /^}$/ { if (in_restore) { print "  T \"restore 全部完成\""; in_restore=0 } }
  /^restore\(\) \{$/ { in_restore=1 }
' "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"

chmod +x "$DST"
export PATH=/usr/bin:/bin
echo "=== rich 路径完整阶段（PRE_COPY_DELAY_MS=0，隔离 wtype stub 之外的一切）==="
PRE_COPY_DELAY_MS=0 WTYPE="$B/stub/wtype-html" bash "$DST" --rich >/dev/null
echo
echo "=== rich 路径完整阶段（默认 preCopyDelay=350）==="
WTYPE="$B/stub/wtype-html" bash "$DST" --rich >/dev/null
