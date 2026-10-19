#!/usr/bin/env bash
# 判定：连续多次 wl-copy --type 调用，剪贴板 offer 是"替换"还是"追加"
set -uo pipefail
export PATH=/usr/bin:/bin

wl-copy --clear 2>/dev/null; sleep 0.1
echo "1) 只写 text/html:"
printf '<b>H</b>' | wl-copy --type text/html
sleep 0.1; wl-paste --list-types 2>/dev/null | sort -u | sed 's/^/     /'

echo "2) 再写 text/plain（第二次独立调用）:"
printf 'PLAIN' | wl-copy --type text/plain
sleep 0.1; wl-paste --list-types 2>/dev/null | sort -u | sed 's/^/     /'
echo "   此时 wl-paste 得到: $(wl-paste --no-newline 2>/dev/null)"
echo "   此时 text/html 还在吗: $(wl-paste --type text/html 2>/dev/null | head -c 20)"

echo
echo "3) 再写 image/png（第三次独立调用）:"
printf 'PNG' | wl-copy --type image/png
sleep 0.1; wl-paste --list-types 2>/dev/null | sort -u | sed 's/^/     /'

echo
echo "4) 最后用无 --type 的 wl-copy 写文本:"
printf 'FINAL' | wl-copy
sleep 0.1; wl-paste --list-types 2>/dev/null | sort -u | sed 's/^/     /'

wl-copy --clear 2>/dev/null; true
