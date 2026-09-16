#!/usr/bin/env bash
# Command-line checks for the bin/ scripts. These run outside the shell, which
# is the whole reason the timing-sensitive work lives in scripts rather than
# in QML.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0
failures=0

check() { # check <description> <actual> <expected>
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected $3"
    echo "       actual   $2"
  fi
}

check_match() { # check_match <description> <actual> <extended-regex>
  checks=$((checks + 1))
  if printf '%s' "$2" | grep -qE "$3"; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected to match $3"
    echo "       actual   $2"
  fi
}

# ---------------------------------------------------------------- cursor-pos

out="$("$ROOT/bin/cursor-pos")"
check "cursor-pos exits 0" "$?" "0"
# Counted from a fresh run, not from $out: command substitution strips the
# trailing newline, so `printf '%s' "$out" | wc -l` is 0 no matter what.
check "cursor-pos emits exactly one line" "$("$ROOT/bin/cursor-pos" | wc -l)" "1"
check "cursor-pos emits five fields" "$(printf '%s' "$out" | awk '{print NF}')" "5"

# The screen it reports must be a screen hyprctl knows, and the local
# coordinates must land inside it. Compared against hyprctl directly rather
# than a hard-coded value so the test survives a resolution change.
mon="$(hyprctl -j monitors | jq -c --arg n "$(printf '%s' "$out" | awk '{print $1}')" '.[] | select(.name==$n)')"
check_match "cursor-pos names a real monitor" "$mon" '^\{'
check "reported width matches hyprctl" "$(printf '%s' "$out" | awk '{print $4}')" "$(printf '%s' "$mon" | jq -r '.width')"
check "reported height matches hyprctl" "$(printf '%s' "$out" | awk '{print $5}')" "$(printf '%s' "$mon" | jq -r '.height')"

lx="$(printf '%s' "$out" | awk '{print $2}')"
ly="$(printf '%s' "$out" | awk '{print $3}')"
check_match "local x is inside the screen" "$(awk -v a="$lx" -v w="$(printf '%s' "$out" | awk '{print $4}')" 'BEGIN{print (a>=0 && a<=w) ? "yes" : "no"}')" '^yes$'
check_match "local y is inside the screen" "$(awk -v a="$ly" -v h="$(printf '%s' "$out" | awk '{print $5}')" 'BEGIN{print (a>=0 && a<=h) ? "yes" : "no"}')" '^yes$'

# The invariant that matters: local + monitor origin must reproduce hyprctl's
# global cursor position (scale is 1 on this machine).
global="$(hyprctl cursorpos | tr -d ' ')"
gx="${global%,*}"
gy="${global#*,}"
ox="$(printf '%s' "$mon" | jq -r '.x')"
oy="$(printf '%s' "$mon" | jq -r '.y')"
scale="$(printf '%s' "$mon" | jq -r '.scale')"
check "local x reconstructs the global position" \
  "$(awk -v l="$lx" -v s="$scale" -v o="$ox" 'BEGIN{printf "%d", l*s + o}')" "$gx"
check "local y reconstructs the global position" \
  "$(awk -v l="$ly" -v s="$scale" -v o="$oy" 'BEGIN{printf "%d", l*s + o}')" "$gy"

# ---------------------------------------------- cursor-pos, scaled monitors
# Everything above runs against this machine, where a single scale-1 screen
# makes every coordinate space collapse onto the same numbers -- which is
# exactly why a conversion that confuses those spaces passes all of it. The
# stub below is a layout where the spaces differ: a scale-2 screen whose 3840
# physical columns are only 1920 logical ones, sitting left of a scale-1 one.
#
# Because hyprctl reports width/height in physical mode pixels but x/y in the
# logical layout space, a conversion that compares the logical cursor against
# physical extents picks the wrong screen here, and one that divides the
# already-logical cursor by the scale reports the wrong local coordinates.
stubdir="$(mktemp -d)"
trap 'rm -rf "$stubdir"' EXIT
cat > "$stubdir/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  cursorpos) printf '%s\n' "$STUB_CURSOR" ;;
  -j)        printf '%s\n' "$STUB_MONITORS" ;;
  *)         exit 1 ;;
esac
STUB
chmod +x "$stubdir/hyprctl"

STUB_MONITORS='[
  {"name": "DP-1",     "x": 0,    "y": 0, "width": 3840, "height": 2160, "scale": 2, "transform": 0},
  {"name": "HDMI-A-1", "x": 1920, "y": 0, "width": 1920, "height": 1080, "scale": 1, "transform": 0}
]'

pos() { # pos <global cursor> -> the script's line, under the stub layout
  STUB_CURSOR="$1" STUB_MONITORS="$STUB_MONITORS" \
    HYPRCTL="$stubdir/hyprctl" "$ROOT/bin/cursor-pos"
}

check "scaled layout: cursor at 2500 is on the second screen, not the first" \
  "$(pos '2500, 500')" "HDMI-A-1 580 500 1920 1080"
check "scaled layout: scale-2 screen reports logical size and logical coords" \
  "$(pos '900, 400')" "DP-1 900 400 1920 1080"
check "scaled layout: the boundary column stays on the left screen" \
  "$(pos '1919, 0')" "DP-1 1919 0 1920 1080"
check "scaled layout: the next column starts the right screen" \
  "$(pos '1920, 0')" "HDMI-A-1 0 0 1920 1080"

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
