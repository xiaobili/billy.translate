#!/usr/bin/env bash
# Fails on QML syntax errors before the shell gets a chance to cache them.
#
# qmllint cannot resolve qs.* imports or PanelWindow (the running shell
# registers those), so it emits a lot of unresolved-type noise that is not
# worth reading. The [syntax] tag is the subset that actually blocks a
# compile, and it is clean: a good file reports none.
set -uo pipefail

Qmllint="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
[ -x "$Qmllint" ] || { echo "qmllint not found at $Qmllint" >&2; exit 2; }

cd "$(dirname "$0")/.." || exit 2
status=0
for file in *.qml; do
  [ -e "$file" ] || continue
  hits="$("$Qmllint" "$file" 2>&1 | grep '\[syntax\]')"
  if [ -n "$hits" ]; then
    echo "$hits"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "qml syntax ok"
exit "$status"
