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
# Compared against the LOGICAL extent, not hyprctl's raw width: raw width is
# physical, and the script reports width/scale by design. Comparing to the raw
# value passes only where scale is 1, and would tempt a future red run into
# "fixing" correct code.
check "reported width is the logical width" \
  "$(printf '%s' "$out" | awk '{print $4}')" \
  "$(printf '%s' "$mon" | jq -r '((.width / .scale) | floor)')"
check "reported height is the logical height" \
  "$(printf '%s' "$out" | awk '{print $5}')" \
  "$(printf '%s' "$mon" | jq -r '((.height / .scale) | floor)')"

lx="$(printf '%s' "$out" | awk '{print $2}')"
ly="$(printf '%s' "$out" | awk '{print $3}')"
check_match "local x is inside the screen" "$(awk -v a="$lx" -v w="$(printf '%s' "$out" | awk '{print $4}')" 'BEGIN{print (a>=0 && a<=w) ? "yes" : "no"}')" '^yes$'
check_match "local y is inside the screen" "$(awk -v a="$ly" -v h="$(printf '%s' "$out" | awk '{print $5}')" 'BEGIN{print (a>=0 && a<=h) ? "yes" : "no"}')" '^yes$'

# The invariant that matters: the local offset plus the monitor's origin must
# reproduce hyprctl's global position. Both sides are logical, so there is NO
# scale factor in this relationship — multiplying by scale here would encode
# the very bug this suite exists to catch, and would pass anyway at scale 1.
global="$(hyprctl cursorpos | tr -d ' ')"
gx="${global%,*}"
gy="${global#*,}"
ox="$(printf '%s' "$mon" | jq -r '.x')"
oy="$(printf '%s' "$mon" | jq -r '.y')"
check "local x reconstructs the global position" \
  "$(awk -v l="$lx" -v o="$ox" 'BEGIN{printf "%d", l + o}')" "$gx"
check "local y reconstructs the global position" \
  "$(awk -v l="$ly" -v o="$oy" 'BEGIN{printf "%d", l + o}')" "$gy"

# ------------------------------------------------- scaled / multi-monitor
# A scale-1 single-monitor machine cannot discriminate this conversion at all:
# every coordinate space coincides and the scale factor is an identity, so a
# wrong implementation and a right one produce byte-identical output. These
# cases stub hyprctl with a two-monitor mixed-scale layout to exercise the
# arithmetic for real. DP-1 is physical 3840x2160 at scale 2 (logical
# 1920x1080 at 0,0); HDMI-A-1 is physical 1920x1080 at scale 1 (logical
# 1920x1080 at 1920,0).
stub="$(mktemp -d)"
cat > "$stub/hyprctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  cursorpos) printf '%s\n' "$STUB_CURSOR" ;;
  -j) printf '%s\n' "$STUB_MONITORS" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub/hyprctl"
export STUB_MONITORS='[{"name":"DP-1","x":0,"y":0,"width":3840,"height":2160,"scale":2,"transform":0},
{"name":"HDMI-A-1","x":1920,"y":0,"width":1920,"height":1080,"scale":1,"transform":0}]'

scaled() { # scaled <cursor-x> <cursor-y> -> the script's single output line
  STUB_CURSOR="$1, $2" HYPRCTL="$stub/hyprctl" "$ROOT/bin/cursor-pos"
}

# The cursor is on the right-hand screen. A containment test that uses the
# PHYSICAL width lets the left screen swallow it (0 + 3840 > 2500) and then
# reports the wrong monitor with wrong offsets.
check "scaled layout: picks the screen the cursor is actually on" \
  "$(scaled 2500 500)" "HDMI-A-1 580 500 1920 1080"
# On the scaled screen: offsets are logical, and the reported size must be the
# logical 1920x1080, not the physical 3840x2160.
check "scaled layout: reports logical offsets and logical screen size" \
  "$(scaled 900 400)" "DP-1 900 400 1920 1080"
check "scaled layout: the boundary stays on the left screen" \
  "$(scaled 1919 0)" "DP-1 1919 0 1920 1080"
check "scaled layout: the boundary flips to the right screen" \
  "$(scaled 1920 0)" "HDMI-A-1 0 0 1920 1080"

# A rotated panel: mode 1920x1080 at transform 1 presents a LOGICAL 1080x1920
# rectangle. Containment has to use that swapped extent. Testing the unswapped
# numbers makes the monitor match nothing at all — the script exits 1 with
# empty output even though the cursor is plainly sitting on it, and the feature
# disappears entirely on any portrait display.
PORTRAIT='[{"name":"eDP-1","x":0,"y":0,"width":1920,"height":1080,"scale":1,"transform":1}]'

onPortrait() { # onPortrait <cursor-x> <cursor-y>
  STUB_MONITORS="$PORTRAIT" STUB_CURSOR="$1, $2" HYPRCTL="$stub/hyprctl" "$ROOT/bin/cursor-pos"
}

check "rotated layout: finds the monitor the cursor is on" \
  "$(onPortrait 500 1500)" "eDP-1 500 1500 1080 1920"
check "rotated layout: reports the swapped logical extents" \
  "$(onPortrait 1079 1919)" "eDP-1 1079 1919 1080 1920"
# The same point lies outside the rotated rectangle, so there is no match and
# the script must fail rather than emit a plausible-looking line.
STUB_MONITORS="$PORTRAIT" STUB_CURSOR="1500, 500" HYPRCTL="$stub/hyprctl" \
  "$ROOT/bin/cursor-pos" >/dev/null 2>&1
check "rotated layout: a point off the rotated monitor fails" "$?" "1"

rm -rf "$stub"

# ----------------------------------------------------------------- pick-text

# pick-text synthesises a real Ctrl+C, and the focused surface while a test
# runs is the terminal that started it. The terminal turns that into SIGINT
# for its foreground process group — this script. Ignoring SIGINT here is what
# keeps the fallback test from killing its own runner. The disposition is
# inherited across exec, so the children ignore it too.
trap '' INT

# Path 1: a populated primary selection is used as-is, with no clipboard
# side effects at all.
printf 'primary-selection-probe' | wl-copy --primary
before="$(wl-paste --no-newline)"
check "pick-text prefers the primary selection" "$("$ROOT/bin/pick-text")" "primary-selection-probe"
check "the primary path leaves the clipboard untouched" "$(wl-paste --no-newline)" "$before"
wl-copy --clear --primary

# Path 2: an empty primary selection falls back to the clipboard, and the
# clipboard is restored afterwards. Verified against a distinctive sentinel so
# a partially-restored clipboard cannot pass.
printf 'clipboard-sentinel-do-not-lose' | wl-copy
wl-copy --clear --primary
out2="$("$ROOT/bin/pick-text" 2>/dev/null)"; status2=$?
check "the fallback path leaves the clipboard restored" "$(wl-paste --no-newline)" "clipboard-sentinel-do-not-lose"
# Nothing was selected and nothing received the synthetic Ctrl+C, so the
# script must report failure rather than return the clipboard's own contents.
#
# The status is captured on the assignment line above, NOT read as $? here:
# the intervening check() call would overwrite $? with its own status, which
# is 0, so the assertion would pass no matter what pick-text returned.
check "the fallback reports failure when nothing is selected" "$status2" "1"
check "no text is emitted on failure" "$out2" ""

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
