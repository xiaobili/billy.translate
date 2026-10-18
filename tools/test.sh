#!/usr/bin/env bash
# Everything that can be checked without starting the shell — but not inert: the
# bin/ section drives the real clipboard and synthesises a Ctrl+C into the focused
# window, so run it from a terminal you can afford to have interrupted.
#
# The QML layer is covered by the two offscreen render checks below, which
# instantiate real components against the installed shell modules. That still is
# not the shell itself: a plugin the shell rejects stays broken through
# hot-reload, so a restart remains the only honest end-to-end test. See
# docs/specs for that reasoning.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
status=0

echo "== qml syntax =="
./tools/check-syntax.sh || status=1

echo
echo "== pure functions =="
node tests/layout.test.js || status=1
node tests/translate.test.js || status=1
bash tests/ocr-progress.test.sh || status=1

echo
echo "== language picker renders =="
# Offscreen: proves Qt accepts the chips and labels, not that the shell loaded
# the plugin. A watchdog timer inside the harness turns a hang into an exit 2.
render_out="$(QT_QPA_PLATFORM=offscreen timeout 30 /usr/lib/qt6/bin/qml tests/lang-render.qml 2>&1)"
render_rc=$?
printf '%s\n' "$render_out" | grep -E '^qml:' || true
[ "$render_rc" -eq 0 ] || { echo "language render check failed (exit $render_rc)" >&2; status=1; }

echo
echo "== bubble grows for the picker =="
# The real Bubble.qml against the installed qs.Commons/qs.Ui, with the core
# plugin stubbed — the closest thing to the shell short of running it. Skips
# when Omarchy's modules are absent. Offscreen noise (missing DBus theme, the
# stub's absent hyprctl) is filtered so only the verdict reads.
bubble_out="$(./tests/bubble-render.sh 2>&1)"
bubble_rc=$?
printf '%s\n' "$bubble_out" | grep -E '^(skip:|qml: (ok|FAIL))|^FAIL ' || true
[ "$bubble_rc" -eq 0 ] || { echo "bubble render check failed (exit $bubble_rc)" >&2; status=1; }

echo
echo "== bin/ scripts =="
./tests/scripts.test.sh || status=1

exit "$status"
