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

rm -rf "$stub"

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
