#!/usr/bin/env bash
set -euo pipefail

state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
venv_dir="$state_home/omarchy/translate/easyocr/.venv"
python_cmd="${PYTHON:-}"

if [ -z "$python_cmd" ]; then
  python_cmd="$(command -v python3 || command -v python || true)"
fi
if [ -z "$python_cmd" ]; then
  echo "Python 3 is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$venv_dir")"
if [ ! -x "$venv_dir/bin/python" ]; then
  "$python_cmd" -m venv "$venv_dir"
fi

venv_python="$venv_dir/bin/python"
"$venv_python" -m pip install --upgrade pip
"$venv_python" -m pip install \
  --index-url https://download.pytorch.org/whl/cpu \
  torch torchvision
"$venv_python" -m pip install easyocr==1.7.2
"$venv_python" -c 'import easyocr; print("EasyOCR", easyocr.__version__)'

printf 'EasyOCR environment ready: %s\n' "$venv_dir"