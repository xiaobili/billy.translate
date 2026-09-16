#!/usr/bin/env bash
# Everything that can be checked without starting the shell.
#
# The QML layer is not covered here: there is no harness for it, and a plugin
# that fails to compile stays broken through hot-reload, so a restart is the
# only honest test. See docs/specs for that reasoning.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
status=0

echo "== qml syntax =="
./tools/check-syntax.sh || status=1

echo
echo "== pure functions =="
node tests/layout.test.js || status=1
node tests/translate.test.js || status=1

echo
echo "== bin/ scripts =="
./tests/scripts.test.sh || status=1

exit "$status"
