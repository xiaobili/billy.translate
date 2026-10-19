#!/usr/bin/env bash
# 隔离验证：python3(html-to-markdown) 与 preCopyDelay 各自贡献
set -uo pipefail
B="$(cd "$(dirname "$0")" && pwd)"
PICK="/home/billy/.config/omarchy/plugins/billy.translate/bin/pick-text"
export PATH=/usr/bin:/bin

cat > "$B/stub/wtype-plain" <<'EOF'
#!/usr/bin/env bash
printf 'Hello\nSome bold text and a link.\n' | wl-copy
EOF
cat > "$B/stub/wtype-html" <<'EOF'
#!/usr/bin/env bash
printf '<h1>Hello</h1><p>Some <b>bold</b> text.</p>' | wl-copy --type text/html
EOF
chmod +x "$B/stub/wtype-plain" "$B/stub/wtype-html"

avg() { # avg <wtype> <env...>
  local wt="$1"; shift
  local t=0
  for i in 1 2 3 4 5; do
    s=$(date +%s%N); env "$@" WTYPE="$wt" bash "$PICK" --rich >/dev/null 2>&1
    e=$(date +%s%N); t=$(( t + (e-s)/1000000 ))
  done
  echo $((t/5))
}

echo "A 纯文本供给(不触发 python3), preCopyDelay=0 : $(avg "$B/stub/wtype-plain" PRE_COPY_DELAY_MS=0) ms"
echo "B HTML 供给(触发 python3),   preCopyDelay=0 : $(avg "$B/stub/wtype-html"  PRE_COPY_DELAY_MS=0) ms"
echo "   → python3 html-to-markdown 净增          : $(( $(avg "$B/stub/wtype-html" PRE_COPY_DELAY_MS=0) - $(avg "$B/stub/wtype-plain" PRE_COPY_DELAY_MS=0) )) ms"
echo
echo "C HTML 供给, preCopyDelay=350(默认)         : $(avg "$B/stub/wtype-html") ms"
echo "   → preCopyDelay 净增                      : $(( $(avg "$B/stub/wtype-html") - $(avg "$B/stub/wtype-html" PRE_COPY_DELAY_MS=0) )) ms"
