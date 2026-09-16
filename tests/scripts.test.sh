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

# The checks below drive the real wl-clipboard, so they replace both of the
# caller's selections. Save them first and put them back at the end: this suite
# is run by hand on a live desktop, and a test that eats the caller's clipboard
# is a test they stop running.
saved_clip="$(wl-paste --no-newline 2>/dev/null || true)"
saved_primary="$(wl-paste --primary --no-newline 2>/dev/null || true)"

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

# ---------------------------------------------- pick-text: the restore, stubbed

# The replay cannot be exercised against the real clipboard: it needs a
# rich-text or image selection, and setting one up would itself clobber the
# caller's. So it is driven here with stubbed client binaries, asserting on what
# was actually replayed. Both cases are invisible to the real-wl-clipboard
# checks above:
#   - a MIME type containing a slash — which is every type a real clipboard
#     advertises (text/plain;charset=utf-8, text/html, image/png). The capture
#     sanitises the slash out of the file name, so the replay has to look it up
#     the same way.
#   - a clipboard with no text flavour, where the plain payload is empty and
#     must not be mistaken for "nothing to restore".
stub2="$(mktemp -d)"
mkdir -p "$stub2/payload"

cat > "$stub2/wl-paste" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
case "${1:-}" in
  --primary) exit 1 ;;
  --list-types) cat "$d/types"; exit 0 ;;
  --type)
    file="$d/payload/${2//\//_}"
    [ -s "$file" ] && { cat "$file"; exit 0; }
    exit 1 ;;
  *) [ -s "$d/data" ] && { cat "$d/data"; exit 0; }; exit 1 ;;
esac
STUB

cat > "$stub2/wl-copy" <<'STUB'
#!/usr/bin/env bash
type=default
while [ $# -gt 0 ]; do
  case "$1" in
    --type) type="$2"; shift 2 ;;
    *) shift ;;
  esac
done
body="$(cat)"
printf '%s %s\n' "$type" "$body" >> "$STUB_LOG"
STUB

cat > "$stub2/wtype" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$stub2/wl-paste" "$stub2/wl-copy" "$stub2/wtype"

printf 'text/plain;charset=utf-8\ntext/html\n' > "$stub2/types"
printf 'before-rich' > "$stub2/data"
printf 'before-rich' > "$stub2/payload/text_plain;charset=utf-8"
printf '<b>before-rich</b>' > "$stub2/payload/text_html"
: > "$stub2/log"

STUB_DIR="$stub2" STUB_LOG="$stub2/log" \
  WL_PASTE="$stub2/wl-paste" WL_COPY="$stub2/wl-copy" WTYPE="$stub2/wtype" \
  "$ROOT/bin/pick-text" >/dev/null 2>&1
check "restore replays a slash-bearing MIME type under its captured name" \
  "$(grep -c '^text/html ' "$stub2/log")" "1"

printf 'image/png\n' > "$stub2/types"
: > "$stub2/data"
printf 'PNGDATA' > "$stub2/payload/image_png"
: > "$stub2/log"

STUB_DIR="$stub2" STUB_LOG="$stub2/log" \
  WL_PASTE="$stub2/wl-paste" WL_COPY="$stub2/wl-copy" WTYPE="$stub2/wtype" \
  "$ROOT/bin/pick-text" >/dev/null 2>&1
check_match "restore still replays when the clipboard holds no text" \
  "$(cat "$stub2/log")" '^image/png PNGDATA$'

rm -rf "$stub2"

# Put the caller's selections back — including "nothing was copied", which the
# sentinel and the cleared primary are not.
if [ -n "$saved_clip" ]; then
  printf '%s' "$saved_clip" | wl-copy 2>/dev/null
else
  wl-copy --clear 2>/dev/null
fi
if [ -n "$saved_primary" ]; then
  printf '%s' "$saved_primary" | wl-copy --primary 2>/dev/null
else
  wl-copy --clear --primary 2>/dev/null
fi

# --------------------------------------------------------------- transport

# The status marker has to reach curl with real line breaks around it. Routed
# through quote() — which folds newlines to spaces — it glues onto the response
# body and parseHttpMarker reads -1, silently bypassing every status branch of
# errorText. This asserts the call site, which is the only place it can regress.
check_match "transport routes the status marker through curlEscape" \
  "$(grep 'write-out' "$ROOT/Transport.qml")" 'curlEscape\(Translate\.httpMarker\(\)\)'

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
