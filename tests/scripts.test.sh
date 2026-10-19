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
#
# The transform swap is the same one bin/cursor-pos applies: a rotated panel
# (transform 1/3/5/7) presents its logical extents swapped against the mode
# width/height, so on a portrait display the reported width is height/scale.
# Comparing against the unswapped numbers would fail against correct code the
# first time this suite ran on one, and this machine reports transform 0.
logical_extents() { # logical_extents <monitor-json> -> "<logical-w> <logical-h>"
  printf '%s' "$1" | jq -r '
    (if (.transform == 1 or .transform == 3 or .transform == 5 or .transform == 7)
      then (.height / .scale) else (.width / .scale) end | floor) as $w
    | (if (.transform == 1 or .transform == 3 or .transform == 5 or .transform == 7)
      then (.width / .scale) else (.height / .scale) end | floor) as $h
    | "\($w) \($h)"'
}
logical="$(logical_extents "$mon")"
check "reported width is the logical width" \
  "$(printf '%s' "$out" | awk '{print $4}')" "${logical%% *}"
check "reported height is the logical height" \
  "$(printf '%s' "$out" | awk '{print $5}')" "${logical##* }"

lx="$(printf '%s' "$out" | awk '{print $2}')"
ly="$(printf '%s' "$out" | awk '{print $3}')"
check_match "local x is inside the screen" "$(awk -v a="$lx" -v w="$(printf '%s' "$out" | awk '{print $4}')" 'BEGIN{print (a>=0 && a<=w) ? "yes" : "no"}')" '^yes$'
check_match "local y is inside the screen" "$(awk -v a="$ly" -v h="$(printf '%s' "$out" | awk '{print $5}')" 'BEGIN{print (a>=0 && a<=h) ? "yes" : "no"}')" '^yes$'

# The invariant that matters: the local offset plus the monitor's origin must
# reproduce hyprctl's global position. Both sides are logical, so there is NO
# scale factor in this relationship — multiplying by scale here would encode
# the very bug this suite exists to catch, and would pass anyway at scale 1.
#
# Read a FRESH run for this comparison, and only trust it when the global
# position is the same on both sides of that run. The pointer is alive while
# the suite runs, so a single sample taken after the run can disagree with what
# the run itself saw; the check then reports "the cursor moved" as a conversion
# failure (it did exactly that once: expected 834, actual 815). Retrying while
# the two readings disagree is not slowness to be "simplified" out — without it
# a moving pointer fails correct code. A wrong conversion still fails here:
# every attempt reconstructs the same wrong number.
live_out=""
live_global=""
for _ in $(seq 5); do
  live_before="$(hyprctl cursorpos | tr -d ' ')"
  live_out="$("$ROOT/bin/cursor-pos")"
  live_after="$(hyprctl cursorpos | tr -d ' ')"
  if [ "$live_before" = "$live_after" ]; then
    live_global="$live_before"
    break
  fi
done
# Every attempt saw the pointer move. Compare against the reading taken before
# the last run rather than dropping the comparison and passing vacuously.
[ -n "$live_global" ] || live_global="$live_before"

# The origin must come from the monitor the run itself named, not from the
# earlier $mon: a retry may have caught the pointer on a different screen.
live_mon="$(hyprctl -j monitors | jq -c --arg n "$(printf '%s' "$live_out" | awk '{print $1}')" '.[] | select(.name==$n)')"
llx="$(printf '%s' "$live_out" | awk '{print $2}')"
lly="$(printf '%s' "$live_out" | awk '{print $3}')"
lox="$(printf '%s' "$live_mon" | jq -r '.x')"
loy="$(printf '%s' "$live_mon" | jq -r '.y')"
lgx="${live_global%,*}"
lgy="${live_global#*,}"
check "local x reconstructs the global position" \
  "$(awk -v l="$llx" -v o="$lox" 'BEGIN{printf "%d", l + o}')" "$lgx"
check "local y reconstructs the global position" \
  "$(awk -v l="$lly" -v o="$loy" 'BEGIN{printf "%d", l + o}')" "$lgy"

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
#
# These cases pin the wl-copy FALLBACK, which is now only reachable on purpose:
# CLIPBOARD_WRITE=/bin/false below makes bin/clipboard-write fail, so the
# assertions can see what the fallback writes. Left unset, these runs would
# spawn the real writer and clobber the caller's clipboard instead of a stub.
#
# The two cases are also separated by what the restore may write. Every
# wl-copy invocation REPLACES the clipboard offer rather than adding to it —
# writing text/html and then text/plain leaves no text/html behind — so at most
# one write can survive. With a text payload to put back, that write is the
# text one, and replaying the captured types ahead of it was N spawns whose
# result got overwritten; the replay is now skipped there. It still runs when
# there is no text flavour at all, where it is the only thing that can restore
# anything.
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
  CLIPBOARD_WRITE=/bin/false \
  "$ROOT/bin/pick-text" >/dev/null 2>&1
# "default" is what the wl-copy stub records for a write with no --type, i.e.
# the text restore. Exactly one line: the text, and nothing else.
check "a text clipboard is restored from its text payload" \
  "$(cat "$stub2/log")" "default before-rich"
# The per-type replay is skipped here on purpose — it could only be overwritten
# by the text write. This fails if it is ever brought back.
check "no per-type replay is issued when text will be restored" \
  "$(grep -vc '^default ' "$stub2/log")" "0"

printf 'image/png\n' > "$stub2/types"
: > "$stub2/data"
printf 'PNGDATA' > "$stub2/payload/image_png"
: > "$stub2/log"

STUB_DIR="$stub2" STUB_LOG="$stub2/log" \
  WL_PASTE="$stub2/wl-paste" WL_COPY="$stub2/wl-copy" WTYPE="$stub2/wtype" \
  CLIPBOARD_WRITE=/bin/false \
  "$ROOT/bin/pick-text" >/dev/null 2>&1
check_match "restore still replays when the clipboard holds no text" \
  "$(cat "$stub2/log")" '^image/png PNGDATA$'

rm -rf "$stub2"

# ------------------------------------- pick-text: the multi-type restore, stubbed
#
# bin/clipboard-write can put every captured flavour back in ONE selection;
# wl-copy cannot, which is why the restore prefers it. These cases assert the
# two properties that matter and that the real clipboard cannot show:
#   - every captured flavour is handed over in a single call, not one call per
#     type (which is what a wl-copy-shaped implementation would do);
#   - nothing falls back to wl-copy when that call succeeds.
#
# The third case flips the writer to a failing exit and checks the fallback
# still runs, so "prefer the writer" cannot turn into "depend on the writer".
stub5="$(mktemp -d)"
mkdir -p "$stub5/payload"

cat > "$stub5/wl-paste" <<'STUB'
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

cat > "$stub5/wl-copy" <<'STUB'
#!/usr/bin/env bash
printf 'wl-copy called\n' >> "$STUB_LOG_COPY"
exit 0
STUB

cat > "$stub5/wtype" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# One line per INVOCATION, arguments joined on the line: that is what lets an
# assertion tell "two flavours in one call" (one line) apart from "one flavour
# per call" (two lines), which is exactly the wl-copy shape being replaced.
cat > "$stub5/clipboard-write" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG_WRITE"
exit "${STUB_WRITE_EXIT:-0}"
STUB

chmod +x "$stub5/wl-paste" "$stub5/wl-copy" "$stub5/wtype" "$stub5/clipboard-write"

printf 'text/plain;charset=utf-8\ntext/html\nimage/png\n' > "$stub5/types"
printf 'before-rich' > "$stub5/data"
printf 'before-rich' > "$stub5/payload/text_plain;charset=utf-8"
printf '<b>before-rich</b>' > "$stub5/payload/text_html"
# Deliberately empty. A flavour whose payload could not be read is skipped
# rather than offered: a client picks the type first and only then discovers it
# is empty, so an empty offer is worse than no offer at all.
: > "$stub5/payload/image_png"
: > "$stub5/log-write"
: > "$stub5/log-copy"

STUB_DIR="$stub5" STUB_LOG_WRITE="$stub5/log-write" STUB_LOG_COPY="$stub5/log-copy" \
  WL_PASTE="$stub5/wl-paste" WL_COPY="$stub5/wl-copy" WTYPE="$stub5/wtype" \
  CLIPBOARD_WRITE="$stub5/clipboard-write" \
  "$ROOT/bin/pick-text" >/dev/null 2>&1

# The backup directory is pick-text's own mktemp, so the paths cannot be
# written out; the flavour names and the by-type/ shape can.
check "restore makes exactly one clipboard-write call" \
  "$(wc -l < "$stub5/log-write" | tr -d ' ')" "1"
check_match "that one call carries the text flavour" \
  "$(cat "$stub5/log-write")" \
  'text/plain;charset=utf-8:/[^ ]+/by-type/text_plain;charset=utf-8'
check_match "that one call carries the html flavour" \
  "$(cat "$stub5/log-write")" 'text/html:/[^ ]+/by-type/text_html'
# Empty image/png is absent from both: a flavour whose payload could not be
# read is skipped rather than offered, because the client picks the type first
# and only then discovers it is empty.
check "an empty flavour is not offered" \
  "$(grep -c 'image/png' "$stub5/log-write")" "0"
check "no wl-copy fallback runs when clipboard-write succeeds" \
  "$(cat "$stub5/log-copy")" ""

# Same setup, writer fails: the fallback must still put the text back.
: > "$stub5/log-write"
: > "$stub5/log-copy"

STUB_DIR="$stub5" STUB_LOG_WRITE="$stub5/log-write" STUB_LOG_COPY="$stub5/log-copy" \
  STUB_WRITE_EXIT=2 \
  WL_PASTE="$stub5/wl-paste" WL_COPY="$stub5/wl-copy" WTYPE="$stub5/wtype" \
  CLIPBOARD_WRITE="$stub5/clipboard-write" \
  "$ROOT/bin/pick-text" >/dev/null 2>&1

check_match "restore falls back to wl-copy when clipboard-write fails" \
  "$(cat "$stub5/log-copy")" 'wl-copy called'

rm -rf "$stub5"

# ------------------------------- pick-text: the poll reads before it sleeps
#
# The poll loop must check the clipboard before paying the interval, or every
# pick is charged one full interval even when the copy landed before the loop
# was entered. Asserted by stubbing `sleep` and counting what the loop asked
# for: the pre-copy delay is pinned to 0 and the interval to 1000, so a
# sleep-first loop cannot avoid logging a 1.000 sleep. Counting is used rather
# than measuring elapsed time so the check cannot flake on a loaded machine.
stub4="$(mktemp -d)"
printf 'before' > "$stub4/data"
: > "$stub4/sleeps"

cat > "$stub4/wl-paste" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --primary) exit 1 ;;
  --list-types) printf 'text/plain\n'; exit 0 ;;
  *) cat "$STUB_DIR/data"; exit 0 ;;
esac
STUB
cat > "$stub4/wl-copy" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
STUB
# The "app" answers the synthetic Ctrl+C immediately: the clipboard changes
# before the poll loop runs at all.
cat > "$stub4/wtype" <<'STUB'
#!/usr/bin/env bash
printf 'after' > "$STUB_DIR/data"
STUB
cat > "$stub4/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$STUB_DIR/sleeps"
exit 0
STUB
chmod +x "$stub4/wl-paste" "$stub4/wl-copy" "$stub4/wtype" "$stub4/sleep"

out4="$(STUB_DIR="$stub4" PATH="$stub4:$PATH" \
  WL_PASTE="$stub4/wl-paste" WL_COPY="$stub4/wl-copy" WTYPE="$stub4/wtype" \
  PRE_COPY_DELAY_MS=0 POLL_INTERVAL_MS=1000 PICK_DEBUG_LOG=/dev/null \
  "$ROOT/bin/pick-text" 2>/dev/null)"
check "a copy that is already there is picked up on the first read" "$out4" "after"
check "the poll charges no interval when the first read already succeeds" \
  "$(grep -c '^1\.000$' "$stub4/sleeps")" "0"

rm -rf "$stub4"

# --------------------------------------- pick-text: flavours and config, stubbed

# Headless: flavour preference on the primary path and the config-file tuning
# knobs, all driven with stubs. Asserts the list-types-once shape (one
# --list-types instead of one probe per flavour) and that PICK_CONFIG_PATH is
# honoured with environment precedence.
stub3="$(mktemp -d)"

cat > "$stub3/wl-paste" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
a="$*"
case "$a" in
  *--primary*)
    [ "${STUB_PRIMARY:-0}" = "1" ] || exit 1 ;;
esac
case "$a" in
  *--list-types*)
    printf '%s\n' "$STUB_TYPES"; exit 0 ;;
  *"--type text/markdown"*)
    [ -n "${STUB_MD:-}" ] && { printf '%s' "$STUB_MD"; exit 0; }; exit 1 ;;
  *"--type text/html"*)
    [ -n "${STUB_HTML:-}" ] && { printf '%s' "$STUB_HTML"; exit 0; }; exit 1 ;;
  *--no-newline*)
    printf '%s' "${STUB_TEXT:-}"; [ -n "${STUB_TEXT:-}" ] && exit 0 || exit 1 ;;
esac
exit 1
STUB
chmod +x "$stub3/wl-paste"
# A wtype that changes nothing: the clipboard genuinely never changes, so the
# poll loop runs its full budget.
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub3/wtype-noop"
chmod +x "$stub3/wtype-noop"

export STUB_DIR="$stub3" STUB_LOG="$stub3/log"
export WL_PASTE="$stub3/wl-paste" WL_COPY=true WTYPE="$stub3/wtype-noop"
export PRE_COPY_DELAY_MS=0 POLL_INTERVAL_MS=1 PICK_DEBUG_LOG=/dev/null

TYPES_MDH='text/markdown
text/html
text/plain'

export STUB_PRIMARY=1 STUB_TYPES="$TYPES_MDH" STUB_MD='# T' STUB_HTML='<h1>T</h1>' STUB_TEXT='plain'
: > "$stub3/log"
check "pick-text prefers markdown on the primary path" "$("$ROOT/bin/pick-text")" "# T"
check "pick-text lists types once on the primary path" "$(grep -c -- '--list-types' "$stub3/log")" "1"

export STUB_TYPES='text/html
text/plain' STUB_MD=''
check "pick-text converts html to markdown" "$("$ROOT/bin/pick-text")" "# T"

# Config knobs: the fallback poll loop is the observable. Primary plain probe
# + backup read + N poll reads of --no-newline.
printf '{"pollAttempts":3,"preCopyDelayMs":0,"pollIntervalMs":1}\n' > "$stub3/config.json"
export STUB_PRIMARY=0 STUB_TYPES='text/plain' STUB_MD='' STUB_HTML='' STUB_TEXT='same' PICK_CONFIG_PATH="$stub3/config.json"
unset POLL_ATTEMPTS
: > "$stub3/log"
"$ROOT/bin/pick-text" >/dev/null 2>&1
check "pick-text honours pollAttempts from the config file" "$(grep -c -- '--no-newline' "$stub3/log")" "5"
export POLL_ATTEMPTS=5
: > "$stub3/log"
"$ROOT/bin/pick-text" >/dev/null 2>&1
check "environment wins over the config file" "$(grep -c -- '--no-newline' "$stub3/log")" "7"
unset POLL_ATTEMPTS PICK_CONFIG_PATH

unset WL_PASTE WL_COPY WTYPE PRE_COPY_DELAY_MS POLL_INTERVAL_MS PICK_DEBUG_LOG
unset STUB_DIR STUB_LOG STUB_PRIMARY STUB_TYPES STUB_MD STUB_HTML STUB_TEXT
rm -rf "$stub3"

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
