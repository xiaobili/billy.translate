#!/usr/bin/env bash
# Mutation check for the multi-type restore: each case breaks ONE property of
# bin/pick-text and asserts the suite turns red, and for the right reason.
#
# A green suite proves nothing on its own — an assertion that cannot fail is
# just a comment. These cases are the evidence that the new checks are wired to
# behaviour.
#
#   env -i PATH=node:/usr/bin:/bin HOME=$USER ... bash mutate-restore.sh
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
F="$ROOT/bin/pick-text"
BAK="$(mktemp)"
cp "$F" "$BAK"
trap 'cp "$BAK" "$F"; rm -f "$BAK"' EXIT

mutate() { # mutate <old> <new>
  /usr/bin/python3 - "$F" "$1" "$2" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if src.count(old) != 1:
    raise SystemExit("mutation target appeared %d times, expected 1: %r"
                     % (src.count(old), old))
open(path, "w").write(src.replace(old, new))
PY
}

run_case() { # run_case <label>
  local label="$1" out fails
  out="$(cd "$ROOT" && bash tests/scripts.test.sh 2>&1)"
  fails="$(printf '%s\n' "$out" | grep -c '^FAIL')"
  printf '%-52s %s failure(s)\n' "$label" "$fails"
  printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'
  cp "$BAK" "$F"
}

echo "=== 基线（未变异）==="
run_case "no mutation (expect 0)"

echo
echo "=== 变异 ==="

mutate 'if [ -x "$CLIPBOARD_WRITE" ]; then' 'if false; then'
run_case "A. never use clipboard-write"

mutate '      [ -s "$backup/by-type/$safe" ] || continue' \
       '      :'
run_case "B. offer flavours whose payload is empty"

mutate '"$CLIPBOARD_WRITE" "${specs[@]}"' '"$CLIPBOARD_WRITE" "${specs[0]}"'
run_case "C. hand over only the first flavour"

mutate 'if [ "${#specs[@]}" -gt 0 ] && "$CLIPBOARD_WRITE" "${specs[@]}" 2>/dev/null; then' \
       'cw_rc=0; for s in "${specs[@]}"; do "$CLIPBOARD_WRITE" "$s" 2>/dev/null || cw_rc=$?; done; if [ "${#specs[@]}" -gt 0 ] && [ "$cw_rc" -eq 0 ]; then'
run_case "D. one call per flavour (the wl-copy shape)"
