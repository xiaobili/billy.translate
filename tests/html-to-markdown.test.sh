#!/usr/bin/env bash
# Tests for bin/html-to-markdown: HTML -> Markdown conversion.
# Pure stdin/stdout, no clipboard involved.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/html-to-markdown"
checks=0
failures=0

check() { # check <description> <actual> <expected>
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    echo "       expected: $3"
    echo "       actual:   $2"
  fi
}

check "headings" \
  "$(printf '<h1>Title</h1>' | "$BIN")" \
  "# Title"

check "bold and italic" \
  "$(printf '<p><strong>bold</strong> and <em>italic</em></p>' | "$BIN")" \
  "**bold** and *italic*"

check "link" \
  "$(printf '<a href="https://example.com">click</a>' | "$BIN")" \
  "[click](https://example.com)"

check "unordered list" \
  "$(printf '<ul><li>one</li><li>two</li></ul>' | "$BIN")" \
  "- one
- two"

check "ordered list" \
  "$(printf '<ol><li>first</li><li>second</li></ol>' | "$BIN")" \
  "1. first
2. second"

check "loose list keeps the marker on its item" \
  "$(printf '<ul><li><p>one</p></li><li><p>two</p></li></ul>' | "$BIN")" \
  "- one

- two"

check "loose ordered list keeps the marker on its item" \
  "$(printf '<ol><li><p>first</p></li><li><p>second</p></li></ol>' | "$BIN")" \
  "1. first

2. second"

check "div inside li stays on the marker line" \
  "$(printf '<ul><li><div>text</div></li></ul>' | "$BIN")" \
  "- text"

check "nested list keeps its indentation" \
  "$(printf '<ul><li>outer<ul><li>inner</li></ul></li></ul>' | "$BIN")" \
  "- outer

  - inner"

check "loose nested list stays nested, not deeper" \
  "$(printf '<ul><li><p>outer</p><ul><li><p>inner</p></li></ul></li></ul>' | "$BIN")" \
  "- outer

  - inner"

check "inline code" \
  "$(printf '<p>use <code>foo()</code> here</p>' | "$BIN")" \
  "use \`foo()\` here"

check "code block" \
  "$(printf '<pre><code>line1
line2</code></pre>' | "$BIN")" \
  '```
line1
line2
```'

check "blockquote" \
  "$(printf '<blockquote>quoted</blockquote>' | "$BIN")" \
  "> quoted"

check "line break" \
  "$(printf '<p>a<br>b</p>' | "$BIN")" \
  "a
b"

check "empty input yields empty output" \
  "$(printf '' | "$BIN")" \
  ""

check "plain text passes through" \
  "$(printf 'just text' | "$BIN")" \
  "just text"

check "table becomes GitHub markdown" \
  "$(printf '<table><tr><th>Name</th><th>Age</th></tr><tr><td>Alice</td><td>30</td></tr></table>' | "$BIN")" \
  "| Name | Age |
| --- | --- |
| Alice | 30 |"

check "table without th uses first row as header" \
  "$(printf '<table><tr><td>H1</td><td>H2</td></tr><tr><td>a</td><td>b</td></tr></table>' | "$BIN")" \
  "| H1 | H2 |
| --- | --- |
| a | b |"

check "table cell keeps inline formatting and links" \
  "$(printf '<table><tr><th>I</th></tr><tr><td><b>bold</b> <a href="https://x.com">click</a></td></tr></table>' | "$BIN")" \
  "| I |
| --- |
| **bold** [click](https://x.com) |"

check "table cell escapes pipes" \
  "$(printf '<table><tr><th>A</th></tr><tr><td>x|y</td></tr></table>' | "$BIN")" \
  "| A |
| --- |
| x\\|y |"

check "uneven table rows are padded" \
  "$(printf '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td></tr></table>' | "$BIN")" \
  "| A | B |
| --- | --- |
| 1 |  |"

echo
echo "$((checks - failures))/$checks passed"
[ "$failures" -eq 0 ]
