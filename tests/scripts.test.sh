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

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
