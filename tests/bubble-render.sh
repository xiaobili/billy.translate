#!/bin/sh
# Loads the real Bubble.qml offscreen, against the installed qs.Commons/qs.Ui,
# and checks that opening the language picker actually grows the card.
#
# The one thing this cannot use as-is is `import Quickshell`: the core plugin is
# statically linked into the shell binary, so a plain `qml` process cannot
# resolve it. Everything the shell's own modules need from it (env,
# execDetached) is stubbed; Commons/Ui are the installed files themselves, with
# only their own `import Quickshell` lines redirected at the stub and their
# FileView/Process blocks commented out. Bubble.qml is never edited — a
# rewritten copy is generated into .renderroot/copy each run.
#
# Skips (exit 0) when the shell's modules are not installed, so the suite still
# runs on a machine without Omarchy.
set -eu

PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOT="$PLUGIN_ROOT/.renderroot"
QML=/usr/lib/qt6/bin/qml

fail() { echo "FAIL $*"; exit 1; }

[ -x "$QML" ] || { echo "skip: $QML not installed"; exit 0; }
[ -d /usr/share/omarchy/shell/Ui ] || { echo "skip: shell modules not installed"; exit 0; }

# 1. Stub for the core plugin, and the shell modules copied over it.
#    Copies are refreshed in place rather than deleted and re-created: `rm -rf`
#    can land in a trash directory, and a `.Trash-0` inside the plugin folder
#    then trips the manifest validator's symlink rule.
mkdir -p "$ROOT/qs/qs" "$ROOT/qs/stub"
cp "$ROOT/stub/qmldir" "$ROOT/stub/QuickshellSingleton.qml" "$ROOT/qs/stub/"
for mod in Ui Commons; do
  mkdir -p "$ROOT/qs/qs/$mod"
  cp -r "/usr/share/omarchy/shell/$mod/." "$ROOT/qs/qs/$mod/"
  find "$ROOT/qs/qs/$mod" -name '*.qml' -print0 |
    xargs -0 perl -0pi -e 's{^import Quickshell(\.\w+)?$}{import "file://'"$ROOT"'/qs/stub"}gm'
done
perl -0pi -e 's{^(import "file://[^"]*/qs/stub"\n)\1+}{$1}gm' \
  "$ROOT"/qs/qs/Commons/*.qml "$ROOT"/qs/qs/Ui/*.qml
perl "$ROOT/stubify.pl" "$ROOT"/qs/qs/Commons/*.qml "$ROOT"/qs/qs/Ui/*.qml >/dev/null

# 2. Bubble.qml with its three imports redirected at the stub and the copied
#    module directories. The type prefixes are re-qualified because the copy
#    binds Commons/Ui to `C`/`U` rather than importing them unqualified. Nothing
#    else changes, so the measurements below describe the shipping component.
mkdir -p "$ROOT/copy"
cp "$PLUGIN_ROOT/Translate.js" "$PLUGIN_ROOT/Table.qml" "$ROOT/copy/"
perl -pe '
  s{^import Quickshell$}{import "file://'"$ROOT"'/qs/stub"};
  s{^import qs\.Commons$}{import "file://'"$ROOT"'/qs/qs/Commons" as C};
  s{^import qs\.Ui$}{import "file://'"$ROOT"'/qs/qs/Ui" as U};
  s{(?<![\w.])Style\.}{C.Style.}g;
  s{(?<![\w.])Border\.}{C.Border.}g;
  s{(?<![\w.])(Button|PanelSeparator|BorderSurface)(\s*\{)}{U.$1$2}g;
' "$PLUGIN_ROOT/Bubble.qml" > "$ROOT/copy/Bubble.qml"
grep -q 'import Quickshell' "$ROOT/copy/Bubble.qml" && fail "unredirected Quickshell import"

# 3. Run. The harness's imports are written absolute (RENDER_ROOT, substituted
#    below), so nothing has to be linked into tests/ — a leftover symlink there
#    would trip the manifest validator's "no symlinks in a plugin folder" rule,
#    and `rm` is not a reliable way to tidy up under a trash-wrapper.
sed "s|@ROOT@|$ROOT|g" "$PLUGIN_ROOT/tests/bubble-render.qml" > "$ROOT/bubble-render.qml"
cd "$ROOT"
QT_QPA_PLATFORM=offscreen timeout 25 "$QML" -I "$ROOT/qs" bubble-render.qml
