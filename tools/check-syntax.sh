#!/usr/bin/env bash
# QML syntax gate. Fails on syntax errors before the shell gets a chance to
# cache them -- and proves nothing beyond that.
#
# Passing this script is NOT evidence that the plugin loads. It cannot see a
# load-time rejection that is not a parser error (an unannotated IpcHandler
# parameter, an unresolvable import, a manifest field the shell dislikes), and
# a plugin that fails to compile stays broken through hot-reload and
# rescanPlugins -- both re-emit the same stale error at the same stale line
# number. A green run here can therefore sit in front of a shell that is still
# refusing the file. The load check is a different thing:
#
#   omarchy restart shell   # only a shell restart recompiles
#   journalctl --user --since "2 min ago" \
#     | grep "omarchy-shell\[$(pgrep -x quickshell)\]"
#
# (pgrep matches `quickshell`, the live process's argv[0]; journald labels the
# resulting lines `omarchy-shell[PID]`.)
#
# Why only the [syntax] tag is read: qmllint cannot resolve qs.* imports or
# PanelWindow (the running shell registers those), so it emits a pile of
# unresolved-type noise -- 23 lines for the clean Overlay.qml -- that is not
# worth reading. The [syntax] subset is the part that actually blocks a
# compile, and it was measured to be zero-false-positive on first-party files:
# Clipboard.qml reports none, while a missing paren or a truncated expression
# reports one. qmllint exits 0 when all it has is warnings, so a non-zero exit
# means real trouble, and is failed on below.
#
# Not covered here: IpcHandler method parameters must be type-annotated, since
# an unannotated one is a QVariant and is rejected across IPC. Every IpcHandler
# method in this plugin currently takes zero parameters, so that trap cannot
# fire; if a parameterised IPC method is ever added, this gate will not catch
# it.
set -uo pipefail

Qmllint="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
[ -x "$Qmllint" ] || { echo "qmllint not found at $Qmllint" >&2; exit 2; }

cd "$(dirname "$0")/.." || exit 2
status=0

# The manifest gate: what `omarchy plugin validate` genuinely checks --
# schemaVersion, the id charset and its reserved-namespace rule, kinds/
# entryPoints pairing, and symlink refusal. It does not load the plugin either,
# so it is not the load check described above.
if ! validate_out="$(omarchy plugin validate . 2>&1)"; then
  [ -n "$validate_out" ] && echo "$validate_out" >&2
  echo "manifest validation failed" >&2
  status=1
fi

# find rather than a *.qml glob: a future components/*.qml would otherwise
# escape the gate silently. Process substitution keeps the loop in this shell,
# so `status` survives it.
while IFS= read -r file; do
  out="$("$Qmllint" "$file" 2>&1)"
  rc=$?
  hits="$(printf '%s\n' "$out" | grep '\[syntax\]')"
  if [ -n "$hits" ]; then
    echo "$hits"
    status=1
  fi
  # Without this, qmllint crashing or being misinvoked produces no [syntax]
  # line, the loop leaves status=0, and the script prints "qml syntax ok" over
  # a file it never actually checked -- a false pass. Warnings alone exit 0,
  # so a non-zero status is never noise.
  if [ "$rc" -ne 0 ]; then
    echo "qmllint exited $rc on $file:" >&2
    printf '%s\n' "$out" | tail -n 20 >&2
    status=1
  fi
done < <(find . -name '*.qml' -not -path './.git/*' | sort)

[ "$status" -eq 0 ] && echo "qml syntax ok"
exit "$status"
