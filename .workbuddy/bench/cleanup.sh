#!/usr/bin/env bash
# Puts the machine back the way the tests found it: no stray selection owners,
# and the caller's clipboard text restored from clipsave/.
#
# A script file rather than an inline `bash -c` on purpose: pkill -f matches
# the whole command line, and an inline command containing the process name
# matches itself and kills the shell that is running the check.
cd "$(dirname "$0")" || exit 1

echo "=== 残留 clipboard-write 进程 ==="
pkill -f 'billy.translate/bin/clipboard-write' 2>/dev/null
sleep 0.2
left="$(pgrep -af 'clipboard-write' | grep -v pgrep || true)"
[ -n "$left" ] && printf '%s\n' "$left" || echo "(none)"

echo "=== 恢复备份的剪贴板 ==="
printf '备份内容: '
cat clipsave/data
echo
wl-copy < clipsave/data
sleep 0.3
echo "类型: $(wl-paste --list-types | tr '\n' ' ')"
echo "内容: $(wl-paste --no-newline)"
