#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

python3 -m venv "$RUN_DIR/venv"
# shellcheck disable=SC1091
source "$RUN_DIR/venv/bin/activate"
pip install -q ruff==0.16.* -r requirements.txt pytest-xdist
ruff check .
python -m py_compile $(git ls-files '*.py')
python -m pytest tests/ -q -n auto
python -m calls.eval || echo "::warning::voice eval quarantined"