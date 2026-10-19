#!/usr/bin/env bash
# 变异测试：把 rendersMarkdown 改回旧语义，确认新断言会失败。
set -uo pipefail
ROOT=/home/billy/.config/omarchy/plugins/billy.translate
JS="$ROOT/Translate.js"
BAK="$ROOT/.workbuddy/bench/Translate.js.orig"
RUN="env -i PATH=/usr/bin:/bin:/home/billy/.workbuddy/binaries/node/versions/22.22.2/bin HOME=/home/billy"
NODE=/home/billy/.workbuddy/binaries/node/versions/22.22.2/bin/node

cp "$JS" "$BAK"
restore() { cp "$BAK" "$JS"; }
trap restore EXIT

echo "=========== 基线 ==========="
$RUN "$NODE" "$ROOT/tests/translate.test.js" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"

echo
echo "=========== 变异 A：回到旧语义（input 永远渲染）==========="
"$NODE" -e '
const fs = require("fs");
const p = "/home/billy/.config/omarchy/plugins/billy.translate/Translate.js";
let s = fs.readFileSync(p, "utf8");
const old = "function rendersMarkdown(mode, rich) {\n  if (rich !== true) return false\n  return mode === \"selection\" || mode === \"input\"\n}";
if (!s.includes(old)) { console.error("锚点未命中"); process.exit(1); }
s = s.replace(old, "function rendersMarkdown(mode, rich) {\n  return mode === \"input\" || (rich === true && mode === \"selection\")\n}");
fs.writeFileSync(p, s);
console.log("已注入变异 A");
'
$RUN "$NODE" "$ROOT/tests/translate.test.js" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
restore

echo
echo "=========== 变异 B：rich 不做布尔严格判断（1 也算）==========="
"$NODE" -e '
const fs = require("fs");
const p = "/home/billy/.config/omarchy/plugins/billy.translate/Translate.js";
let s = fs.readFileSync(p, "utf8");
const old = "  if (rich !== true) return false";
if (!s.includes(old)) { console.error("锚点未命中"); process.exit(1); }
s = s.replace(old, "  if (!rich) return false");
fs.writeFileSync(p, s);
console.log("已注入变异 B");
'
$RUN "$NODE" "$ROOT/tests/translate.test.js" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
restore

echo
echo "=========== 变异 C：丢失 OCR 排除（任何 mode 都渲染）==========="
"$NODE" -e '
const fs = require("fs");
const p = "/home/billy/.config/omarchy/plugins/billy.translate/Translate.js";
let s = fs.readFileSync(p, "utf8");
const old = "  return mode === \"selection\" || mode === \"input\"";
if (!s.includes(old)) { console.error("锚点未命中"); process.exit(1); }
s = s.replace(old, "  return true");
fs.writeFileSync(p, s);
console.log("已注入变异 C");
'
$RUN "$NODE" "$ROOT/tests/translate.test.js" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
restore

echo
echo "=========== 还原确认 ==========="
diff -q "$BAK" "$JS" && echo "Translate.js 已还原"
$RUN "$NODE" "$ROOT/tests/translate.test.js" 2>&1 | grep -E "^(FAIL|[0-9]+/[0-9]+)"
