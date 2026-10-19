#!/usr/bin/env bash
# 交替 A/B，消除系统负载波动对测量的影响
set -uo pipefail
export PATH=/usr/bin:/bin
H2M=/home/billy/.config/omarchy/plugins/billy.translate/bin/html-to-markdown
IN='<h1>T</h1><table><tr><th>a</th></tr><tr><td>1</td></tr></table><pre>code</pre><a href="u">L</a>'

a=0; b=0
for i in $(seq 8); do
  s=$(date +%s%N); printf '%s' "$IN" | python3 "$H2M" >/dev/null 2>&1; e=$(date +%s%N)
  a=$(( a + (e-s)/1000000 ))
  s=$(date +%s%N); printf '%s' "$IN" | python3 -S -E "$H2M" >/dev/null 2>&1; e=$(date +%s%N)
  b=$(( b + (e-s)/1000000 ))
done
echo "python3        平均 $((a/8)) ms"
echo "python3 -S -E  平均 $((b/8)) ms"
echo "节省           $(( (a-b)/8 )) ms"

echo
echo "=== env -S 是否可用（用于 shebang）==="
cat > /tmp/h2m-shebang-test <<'EOF'
#!/usr/bin/env -S python3 -S -E
import sys
print("env -S OK", sys.version_info[:2])
EOF
chmod +x /tmp/h2m-shebang-test 2>/dev/null
/tmp/h2m-shebang-test; echo "exit=$?"

echo
echo "=== 单参数 shebang 备选：#!/usr/bin/python3 -S ==="
printf '#!/usr/bin/python3 -S\nimport sys\nprint("ok", sys.version_info[:2])\n' > /tmp/h2m-shebang-test2
chmod +x /tmp/h2m-shebang-test2
/tmp/h2m-shebang-test2; echo "exit=$?"
